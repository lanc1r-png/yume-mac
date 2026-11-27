import SwiftUI
import AVKit
import AVFoundation
import Foundation
import WebKit
import Security
import Network
import Combine
import ImageIO
import CoreImage
import UniformTypeIdentifiers
import PhotosUI
#if os(macOS)
import AppKit
#endif

// MARK: - Манга: страницы и читалка
struct MangaPage: Identifiable, Hashable {
    let id: Int
    let urls: [URL]
    let width: CGFloat
    let height: CGFloat

    var url: URL { urls[0] }
    var ratio: CGFloat { width > 0 && height > 0 ? height / width : 0 }
    /// Страница должна занять по ширине экран, поэтому длинным полосам разрешаем больше пикселей.
    nonisolated(unsafe) static var screenPx = CGSize(width: 2560, height: 1664)
    nonisolated(unsafe) static var fill = true
    /// Ширина в пикселях, в которую страница реально выводится: декодируем ровно столько, чтобы не было мыла.
    var pxWidth: CGFloat {
        let r = ratio > 0 ? ratio : 1.5
        return MangaPage.fill ? MangaPage.screenPx.width : min(MangaPage.screenPx.width, MangaPage.screenPx.height / r)
    }
    var maxPixel: CGFloat { min(8192, pxWidth * max(1, ratio > 0 ? ratio : 1.5)) }
}

actor MangaImageServers {
    static let shared = MangaImageServers()
    private var cachedBy: [String: [String]] = [:]
    private let fallback = "https://img3.cdnlibs.org"

    func bases(site: LibSite? = nil) async -> [String] {
        let siteID = (site ?? LibSite.current).id
        if let c = cachedBy[siteID] { return c }
        var list: [String] = []
        let q = [URLQueryItem(name: "fields[]", value: "imageServers")]
        if let data = try? await AnimelibAPI.shared.rawData("/constants", query: q, site: site),
           let root = J.obj(data) as? [String: Any],
           let d = root["data"] as? [String: Any],
           let arr = d["imageServers"] as? [[String: Any]] {
            let matched = arr.filter { srv in
                guard let ids = srv["site_ids"] as? [Any], !ids.isEmpty else { return true }
                return ids.contains { J.int($0) == Int(siteID) }
            }
            let mine = matched.isEmpty ? arr : matched
            // Главный сервер первым, «сжатые» зеркала (мыльные картинки) — в самый конец
            func packed(_ srv: [String: Any]) -> Bool {
                let id = (J.str(srv["id"]) ?? "").lowercased()
                let label = (J.str(srv["label"]) ?? "").lowercased()
                return id.contains("compress") || label.contains("compress") || label.contains("сжат")
            }
            let main = mine.filter { ($0["id"] as? String) == "main" }
            let rest = mine.filter { ($0["id"] as? String) != "main" && !packed($0) }
            let packedList = mine.filter { ($0["id"] as? String) != "main" && packed($0) }
            list = (main + rest + packedList).compactMap { J.str($0["url"]) }
            if !list.isEmpty { cachedBy[siteID] = list + (list.contains(fallback) ? [] : [fallback]) }
        }
        if !list.contains(fallback) { list.append(fallback) }
        return list
    }

    private var rankedBy: [String: [String]] = [:]

    /// Сравнивает размер первой страницы на каждом сервере и ставит вперёд тот, что отдаёт файл побольше:
    /// сжатая копия всегда меньше оригинала. Результат запоминается для сайта.
    func ranked(_ bases: [String], samplePath: String) async -> [String] {
        let siteID = LibSite.current.id
        if let r = rankedBy[siteID] { return r }
        guard bases.count > 1 else { return bases }
        let referer = LibSite.current.isManga ? LibSite.current.referer : LibSite.manga.referer
        let probe = Array(bases.prefix(4))
        var sizes: [String: Int] = [:]
        await withTaskGroup(of: (String, Int).self) { group in
            for b in probe {
                group.addTask {
                    guard let u = MangaImageServers.resolve(samplePath, base: b) else { return (b, 0) }
                    var req = URLRequest(url: u)
                    req.timeoutInterval = 7
                    req.setValue("bytes=0-0", forHTTPHeaderField: "Range")
                    req.setValue(referer, forHTTPHeaderField: "Referer")
                    req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    guard let (data, resp) = try? await URLSession.shared.data(for: req),
                          let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { return (b, 0) }
                    if let cr = http.value(forHTTPHeaderField: "Content-Range"),
                       let total = cr.split(separator: "/").last.flatMap({ Int($0) }) { return (b, total) }
                    return (b, http.statusCode == 200 ? max(data.count, Int(http.expectedContentLength)) : 0)
                }
            }
            for await (b, n) in group { sizes[b] = n }
        }
        // сортировка устойчивая: при равных размерах порядок серверов не меняется
        let order = Dictionary(uniqueKeysWithValues: bases.enumerated().map { ($1, $0) })
        let sorted = bases.sorted {
            let a = sizes[$0] ?? 0, b = sizes[$1] ?? 0
            return a != b ? a > b : (order[$0] ?? 0) < (order[$1] ?? 0)
        }
        if sizes.values.contains(where: { $0 > 0 }) { rankedBy[siteID] = sorted }
        return sorted
    }

    /// Адрес «как есть»: сервер + путь без правок (так делают сайт и сторонние клиенты).
    static func raw(_ path: String, base: String) -> URL? {
        if path.hasPrefix("http") { return nil }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))
    }

    static func resolve(_ path: String, base: String) -> URL? {
        // Путь страницы приходит как «//manga/…»: это часть адреса на сервере картинок, а не хост.
        if path.hasPrefix("http") { return URL(string: path) }
        var b = base
        while b.hasSuffix("/") { b.removeLast() }
        var p = path
        while p.hasPrefix("/") { p.removeFirst() }
        return URL(string: b + "/" + p)
    }
}

enum MangaService {
    private static func num(_ v: Any?) -> CGFloat {
        if let x = v as? Double { return CGFloat(x) }
        return CGFloat(J.int(v) ?? 0)
    }

    /// Скачанная глава: страницы лежат файлами на телефоне, сеть не нужна.
    @MainActor
    static func localPages(novel: Int, chapter: Int) -> [MangaPage]? {
        let store = OfflineStore.manga
        guard store.isDownloaded(novel, chapter),
              let data = try? Data(contentsOf: store.chapterFile(novel, chapter)),
              let root = J.obj(data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }
        let raw = (d["pages"] as? [[String: Any]]) ?? []
        var out: [MangaPage] = []
        for p in raw {
            guard J.str(p["url"]) ?? J.str(p["image"]) != nil else { continue }
            let f = store.mangaPageFile(novel, chapter, out.count)
            guard FileManager.default.fileExists(atPath: f.path) else { return nil }
            out.append(MangaPage(id: out.count, urls: [f], width: num(p["width"]), height: num(p["height"])))
        }
        return out.isEmpty ? nil : out
    }

    static func pages(slug: String, chapter c: NovelChapter, novelID: Int? = nil) async throws -> [MangaPage] {
        if let n = novelID, let local = await localPages(novel: n, chapter: c.id) { return local }
        let data = try await AnimelibAPI.shared.rawData(NovelService.chapterPath(slug: slug),
                                                        query: NovelService.chapterQuery(c))
        guard let root = J.obj(data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { throw APIError.badURL }
        var bases = await MangaImageServers.shared.bases()
        if let first = (d["pages"] as? [[String: Any]])?.first, let path = J.str(first["url"]) ?? J.str(first["image"]) {
            bases = await MangaImageServers.shared.ranked(bases, samplePath: path)
        }
        return parse(d, bases: bases)
    }

    static func parse(_ d: [String: Any], bases: [String]) -> [MangaPage] {
        let raw = (d["pages"] as? [[String: Any]]) ?? []
        var out: [MangaPage] = []
        for p in raw {
            guard let path = J.str(p["url"]) ?? J.str(p["image"]) else { continue }
            var urls: [URL] = []
            for b in bases {
                for u in [MangaImageServers.resolve(path, base: b), MangaImageServers.raw(path, base: b)] {
                    if let u = u, !urls.contains(u) { urls.append(u) }
                }
            }
            if urls.isEmpty { continue }
            out.append(MangaPage(id: out.count, urls: urls, width: num(p["width"]), height: num(p["height"])))
        }
        return out
    }
}

/// Загрузка страниц манги: по одной попытке на каждый адрес, повтор кругом, без дублей.
actor MangaImageStore {
    static let shared = MangaImageStore()
    private var inflight: [String: Task<(UIImage?, String), Never>] = [:]
    private(set) var lastNote = ""

    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 25
        cfg.httpMaximumConnectionsPerHost = 4
        cfg.urlCache = MangaImageStore.diskCache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    /// Временный кэш просмотренных страниц манги (до 400 МБ). Скачанные главы лежат отдельно.
    nonisolated static let diskCache = URLCache(memoryCapacity: 30_000_000, diskCapacity: 400_000_000)

    func image(for page: MangaPage) async -> UIImage? {
        let key = ImageCache.key(page.url, page.maxPixel)
        if let c = ImageCache.shared.object(forKey: key) { return c }
        let id = key as String
        if let t = inflight[id] { return await t.value.0 }
        let urls = page.urls
        let pxW = page.pxWidth
        let t = Task.detached(priority: .userInitiated) { () -> (UIImage?, String) in
            var note = ""
            for round in 0..<2 {
                for u in urls {
                    if u.isFileURL {
                        if let data = try? Data(contentsOf: u),
                           let img = ImageLoader.downsampleWidth(data, width: pxW, maxSide: 16000, sharpen: true) {
                            ImageCache.store(img, key)
                            return (img, "")
                        }
                        note = "файл страницы не читается"
                        continue
                    }
                    var req = URLRequest(url: u)
                    req.setValue(LibSite.current.isManga ? LibSite.current.referer : LibSite.manga.referer, forHTTPHeaderField: "Referer")
                    req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    req.setValue(MangaImageStore.agent, forHTTPHeaderField: "User-Agent")
                    do {
                        let (data, resp) = try await MangaImageStore.session.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(code) {
                            if let img = ImageLoader.downsampleWidth(data, width: pxW, maxSide: 16000, sharpen: true) {
                                ImageCache.store(img, key)
                                return (img, "")
                            }
                            note = "не удалось разобрать картинку (\(data.count) байт, \(resp.mimeType ?? "?"))"
                        } else {
                            note = "HTTP \(code) · \(u.host ?? "")"
                        }
                    } catch {
                        note = error.localizedDescription
                    }
                }
                if round == 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
            }
            return (nil, note + "\n" + (urls.first?.absoluteString ?? ""))
        }
        inflight[id] = t
        let r = await t.value
        inflight[id] = nil
        if r.0 == nil { lastNote = r.1 }
        return r.0
    }

    /// Только скачивает страницу в дисковый кэш, не декодируя её: память не занимается,
    /// а когда до страницы дойдёт очередь, она откроется из кэша без сети.
    nonisolated func warm(_ page: MangaPage) async {
        if ImageCache.shared.object(forKey: ImageCache.key(page.url, page.maxPixel)) != nil { return }
        for u in page.urls {
            if Task.isCancelled || u.isFileURL { return }
            var req = URLRequest(url: u)
            req.setValue(LibSite.current.isManga ? LibSite.current.referer : LibSite.manga.referer, forHTTPHeaderField: "Referer")
            req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
            req.setValue(MangaImageStore.agent, forHTTPHeaderField: "User-Agent")
            if let (_, resp) = try? await MangaImageStore.session.data(for: req),
               let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code) { return }
        }
    }
}
