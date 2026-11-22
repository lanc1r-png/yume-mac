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

// MARK: - Кино (kinomig.tv): модели

/// Фильм, сериал, мультфильм, аниме или ТВ-шоу с kinomig.tv
struct KinoItem: Codable, Hashable, Identifiable {
    var id: Int
    /// Путь страницы на сайте: /film/583-obitel-zla-2026.html
    var path: String
    var title: String
    var orig: String? = nil
    /// Постер как на сайте: /uploads/posters/7378605_xs.webp
    var poster: String? = nil
    /// Год, страна, жанр, длительность…
    var meta: [String] = []
    var desc: String? = nil
    var quality: String? = nil
    var rating: String? = nil
    /// «2 сез. 10 серия» — для новых серий
    var badge: String? = nil

    /// film / serial / multfilm / anime / tv-shou
    var kind: String { path.split(separator: "/").first.map(String.init) ?? "film" }

    var kindTitle: String {
        switch kind {
        case "serial": return "Сериал"
        case "multfilm": return "Мультфильм"
        case "anime": return "Аниме"
        case "tv-shou": return "ТВ-шоу"
        default: return "Фильм"
        }
    }

    var pageURL: URL? { URL(string: KinoNet.base + path) }

    /// Карточки — средний размер (_s), страница — большой (без суффикса)
    func posterURL(big: Bool = false) -> URL? {
        guard var p = poster, !p.isEmpty else { return nil }
        if big { p = p.replacingOccurrences(of: "_xs.", with: ".").replacingOccurrences(of: "_s.", with: ".") }
        else { p = p.replacingOccurrences(of: "_xs.", with: "_s.") }
        if p.hasPrefix("http") { return URL(string: p) }
        return URL(string: KinoNet.base + p)
    }

    static func id(fromPath p: String) -> Int? {
        guard let r = p.range(of: #"/(\d+)-"#, options: .regularExpression) else { return nil }
        return Int(p[r].dropFirst().dropLast())
    }
}

/// Источник плеера на странице (одна озвучка)
struct KinoSource: Hashable {
    /// alloha — родной плеер; остальные (collaps…) — веб-плеер сайта
    var balancer: String = "alloha"
    var isNative: Bool { balancer == "alloha" }
    let translation: String
    let url: URL
    let quality: String?
    /// сезон → номера серий
    let seasons: [Int: [Int]]
}

struct KinoDetail {
    var item: KinoItem
    var info: [(String, String)] = []
    var genres: [String] = []
    var actors: [String] = []
    var director: String?
    var sources: [KinoSource] = []
    /// сезон → серия → дата выхода
    var dates: [Int: [Int: String]] = [:]
    /// Что нашли на странице про плееры — показываем, если смотреть не получается
    var playersNote: String?

    var isSerial: Bool { sources.contains { $0.isNative && !$0.seasons.isEmpty } }
    var seasons: [Int] {
        Array(Set(sources.flatMap { $0.seasons.keys })).sorted()
    }
    func episodes(_ season: Int, source: KinoSource?) -> [Int] {
        if let s = source?.seasons[season], !s.isEmpty { return s.sorted() }
        return Array(Set(sources.flatMap { $0.seasons[season] ?? [] })).sorted()
    }
}

/// Готовый поток для плеера
struct KinoStream {
    struct Track: Hashable {
        let label: String
        /// качество (1080, 720…) → ссылка (и запасная)
        let qualities: [(Int, [URL])]
        static func == (a: Track, b: Track) -> Bool { a.label == b.label }
        func hash(into h: inout Hasher) { h.combine(label) }
    }
    var tracks: [Track]
    var skip: ClosedRange<Double>?
    var origin: String
    var referer: String
}

enum KinoError: LocalizedError {
    case blocked, empty, player(String)
    var errorDescription: String? {
        switch self {
        case .blocked: return "Сайт не пустил (защита Cloudflare). Попробуй ещё раз через минуту."
        case .empty: return "Сайт ничего не вернул"
        case .player(let s): return "Плеер: " + s
        }
    }
}

// MARK: - Сеть: обычные запросы, а если мешает Cloudflare — через невидимый браузер

@MainActor
final class KinoNet: NSObject, WKNavigationDelegate {
    static let shared = KinoNet()
    nonisolated static let base = "https://kinomig.tv"
    nonisolated static let ua = Kodik.ua

    let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpCookieStorage = .shared
        c.httpAdditionalHeaders = ["User-Agent": KinoNet.ua, "Accept-Language": "ru-RU,ru;q=0.9"]
        c.timeoutIntervalForRequest = 25
        return URLSession(configuration: c)
    }()

    private var web: WKWebView?
    private var ready = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    private var loadingWeb = false

    static func isChallenge(_ status: Int, _ body: String) -> Bool {
        if body.contains("<title>Just a moment") || body.contains("cf_chl_opt") || body.contains("cf-chl-") { return true }
        return (status == 403 || status == 503) && body.lowercased().contains("cloudflare")
    }

    /// Текст страницы или API сайта (путь от корня или полный адрес)
    func text(_ pathOrURL: String, ajax: Bool = false) async throws -> String {
        let urlStr = pathOrURL.hasPrefix("http") ? pathOrURL : Self.base + pathOrURL
        guard let url = URL(string: urlStr) else { throw KinoError.empty }
        if let t = try? await plain(url, ajax: ajax) { return t }
        // Cloudflare: проходим проверку браузером, забираем «пропуск» и пробуем снова
        await warmUp()
        if let t = try? await plain(url, ajax: ajax) { return t }
        if let t = try await viaWeb(url, ajax: ajax) { return t }
        throw KinoError.blocked
    }

    private func plain(_ url: URL, ajax: Bool) async throws -> String {
        var r = URLRequest(url: url)
        r.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        r.setValue(ajax ? "application/json, text/javascript, */*; q=0.01" : "text/html,application/xhtml+xml,*/*;q=0.8",
                   forHTTPHeaderField: "Accept")
        if ajax { r.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With") }
        let (d, resp) = try await session.data(for: r)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let t = String(data: d, encoding: .utf8) ?? ""
        if Self.isChallenge(status, t) || !(200..<300).contains(status) { throw KinoError.blocked }
        return t
    }

    /// Невидимый браузер открывает сайт, проходит проверку и отдаёт cookie обычным запросам
    func warmUp() async {
        if ready { return }
        if loadingWeb {
            await withCheckedContinuation { waiting.append($0) }
            return
        }
        loadingWeb = true
        let cfg = WKWebViewConfiguration()
        cfg.websiteDataStore = .default()
        let v = WKWebView(frame: CGRect(x: 0, y: 0, width: 2, height: 2), configuration: cfg)
        v.customUserAgent = Self.ua
        v.navigationDelegate = self
        v.alpha = 0.01
        v.isUserInteractionEnabled = false
        HiddenWebHost.attach(v)
        web = v
        v.load(URLRequest(url: URL(string: Self.base + "/")!))
        // ждём, пока страница перестанет быть проверкой (до 25 с)
        for _ in 0..<50 {
            try? await Task.sleep(nanoseconds: 500_000_000)
            let title = (try? await v.evaluateJavaScript("document.title") as? String) ?? ""
            let done = (try? await v.evaluateJavaScript("document.readyState") as? String) == "complete"
            if done, !title.isEmpty, !title.contains("Just a moment"), !title.contains("Подождите") { break }
        }
        await copyCookies()
        ready = true
        loadingWeb = false
        waiting.forEach { $0.resume() }
        waiting = []
    }

    private func copyCookies() async {
        guard let store = web?.configuration.websiteDataStore.httpCookieStore else { return }
        let cookies = await withCheckedContinuation { (c: CheckedContinuation<[HTTPCookie], Never>) in
            store.getAllCookies { c.resume(returning: $0) }
        }
        for ck in cookies where ck.domain.contains("kinomig") { HTTPCookieStorage.shared.setCookie(ck) }
    }

    private func viaWeb(_ url: URL, ajax: Bool) async throws -> String? {
        guard let v = web else { return nil }
        let js = """
        const r = await fetch(u, { credentials: 'include', headers: ajax ? { 'X-Requested-With': 'XMLHttpRequest' } : {} });
        return await r.text();
        """
        let res = try? await v.callAsyncJavaScript(js, arguments: ["u": url.absoluteString, "ajax": ajax], contentWorld: .page)
        guard let t = res as? String, !Self.isChallenge(200, t) else { return nil }
        return t
    }

    /// Картинка с сайта (с тем же «пропуском»)
    func image(_ url: URL, maxPixel: CGFloat) async -> UIImage? {
        var r = URLRequest(url: url)
        r.setValue(Self.base + "/", forHTTPHeaderField: "Referer")
        r.setValue("image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        let px = maxPixel
        if !webImages, let (d, resp) = try? await session.data(for: r),
           ((resp as? HTTPURLResponse)?.statusCode ?? 200) < 300,
           let img = await Task.detached(priority: .userInitiated, operation: { ImageLoader.downsample(d, maxPixel: px) }).value {
            return img
        }
        // Cloudflare не отдал картинку обычному запросу: берём её браузером, который прошёл проверку
        webImages = true
        await warmUp()
        guard let v = web else { return nil }
        let js = """
        const r = await fetch(u, { credentials: 'include' });
        if (!r.ok) return '';
        const b = await r.blob();
        return await new Promise(res => { const f = new FileReader(); f.onloadend = () => res(String(f.result || '')); f.readAsDataURL(b); });
        """
        guard let res = try? await v.callAsyncJavaScript(js, arguments: ["u": url.absoluteString], contentWorld: .page) as? String,
              let comma = res.firstIndex(of: ","),
              let data = Data(base64Encoded: String(res[res.index(after: comma)...])) else { return nil }
        return await Task.detached(priority: .userInitiated, operation: { ImageLoader.downsample(data, maxPixel: px) }).value
    }

    /// Картинки обычными запросами не идут — сразу через браузер
    private var webImages = false
}

// MARK: - Разбор страниц сайта

enum KinoParse {
    static func unescapeHTML(_ s: String) -> String {
        var t = s
        let map = ["&quot;": "\"", "&#39;": "'", "&#039;": "'", "&apos;": "'", "&lt;": "<", "&gt;": ">", "&nbsp;": " ", "&laquo;": "«", "&raquo;": "»", "&mdash;": "—", "&ndash;": "–", "&hellip;": "…"]
        for (k, v) in map { t = t.replacingOccurrences(of: k, with: v) }
        // числовые &#1234;
        if t.contains("&#") {
            let re = try? NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
            let ns = t as NSString
            var out = ""
            var last = 0
            for m in re?.matches(in: t, range: NSRange(location: 0, length: ns.length)) ?? [] {
                out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
                let hex = ns.substring(with: m.range(at: 1)) == "x"
                let num = ns.substring(with: m.range(at: 2))
                if let n = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(n) { out += String(Character(u)) }
                last = m.range.location + m.range.length
            }
            out += ns.substring(from: last)
            t = out
        }
        return t.replacingOccurrences(of: "&amp;", with: "&")
    }

    static func strip(_ s: String) -> String {
        let noTags = s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return unescapeHTML(noTags).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func first(_ pattern: String, _ s: String, group: Int = 1) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return nil }
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)),
              m.numberOfRanges > group, m.range(at: group).location != NSNotFound else { return nil }
        return ns.substring(with: m.range(at: group))
    }

    static func all(_ pattern: String, _ s: String) -> [[String]] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else { return [] }
        let ns = s as NSString
        return re.matches(in: s, range: NSRange(location: 0, length: ns.length)).map { m in
            (0..<m.numberOfRanges).map { i in
                m.range(at: i).location == NSNotFound ? "" : ns.substring(with: m.range(at: i))
            }
        }
    }

    /// Путь без домена: https://kinomig.tv/film/1-x.html?season=2 → /film/1-x.html
    static func path(_ href: String) -> String {
        var p = unescapeHTML(href)
        if let r = p.range(of: "kinomig.tv") { p = String(p[r.upperBound...]) }
        if let q = p.firstIndex(of: "?") { p = String(p[..<q]) }
        return p
    }

    static func query(_ href: String, _ name: String) -> Int? {
        let h = unescapeHTML(href)
        guard let c = URLComponents(string: h.hasPrefix("http") ? h : KinoNet.base + h) else { return nil }
        return c.queryItems?.first { $0.name == name }?.value.flatMap(Int.init)
    }

    /// Карточки каталога (<article class="card">)
    static func cards(_ html: String) -> [KinoItem] {
        var out: [KinoItem] = []
        for block in html.components(separatedBy: "<article class=\"card").dropFirst() {
            let b = block.components(separatedBy: "</article>").first ?? block
            guard let href = first(#"<a class="go" href="([^"]+)""#, b) ?? first(#"href="([^"]+\.html)""#, b) else { continue }
            let p = path(href)
            guard let id = KinoItem.id(fromPath: p) else { continue }
            let title = first(#"<a class="go"[^>]*>(.*?)</a>"#, b).map(strip) ?? first(#"alt="([^"]*)""#, b).map(unescapeHTML) ?? ""
            var it = KinoItem(id: id, path: p, title: title)
            it.poster = first(#"<img src="([^"]+)""#, b)
            it.orig = first(#"<div class="orig">(.*?)</div>"#, b).map(strip).flatMap { $0.isEmpty ? nil : $0 }
            it.meta = all(#"<span class="mi">(.*?)</span>"#, b).map { strip($0[1]) }.filter { !$0.isEmpty }
            it.badge = first(#"<span class="ep">(.*?)</span>"#, b).map(strip)
            it.desc = first(#"<p>(.*?)</p>"#, b).map(strip)
            it.quality = first(#"<span class="q">(.*?)</span>"#, b).map(strip)
            it.rating = first(#"class="(?:rt|rating)[^"]*"[^>]*>(.*?)</"#, b).map(strip).flatMap { $0.isEmpty ? nil : $0 }
            out.append(it)
        }
        return out
    }

    /// Плитки главной (<a class="tile">)
    static func tiles(_ html: String) -> [KinoItem] {
        all(#"<a class="tile" href="([^"]+)"[^>]*title="([^"]*)"(.*?)</a>"#, html).compactMap { m in
            let p = path(m[1])
            guard let id = KinoItem.id(fromPath: p) else { return nil }
            var it = KinoItem(id: id, path: p, title: unescapeHTML(m[2]))
            it.poster = first(#"<img src="([^"]+)""#, m[3])
            return it
        }
    }

    /// Новые серии (<a class="ucard">)
    static func updates(_ html: String) -> [(KinoItem, Int?, Int?)] {
        all(#"<a class="ucard" href="([^"]+)"[^>]*title="([^"]*)"(.*?)</a>"#, html).compactMap { m in
            let p = path(m[1])
            guard let id = KinoItem.id(fromPath: p) else { return nil }
            var it = KinoItem(id: id, path: p, title: unescapeHTML(m[2]))
            it.poster = first(#"<img src="([^"]+)""#, m[3])
            it.badge = first(#"<span class="ep">(.*?)</span>"#, m[3]).map(strip)
            return (it, query(m[1], "season"), query(m[1], "episode"))
        }
    }

    /// Подсказки поиска
    static func suggest(_ html: String) -> [KinoItem] {
        all(#"<a class="row" href="([^"]+)">(.*?)</a>"#, html).compactMap { m in
            let p = path(m[1])
            guard let id = KinoItem.id(fromPath: p) else { return nil }
            let b = m[2]
            var it = KinoItem(id: id, path: p, title: first(#"<span class="nm">(.*?)</span>"#, b).map(strip) ?? "")
            it.poster = first(#"<img class="po" src="([^"]+)""#, b)
            if let mt = first(#"<span class="mt">(.*?)</span>"#, b).map(strip) {
                it.meta = mt.components(separatedBy: " · ").filter { !$0.isEmpty }
            }
            it.rating = first(#"<span class="rt"><b>(.*?)</b>"#, b).map(strip)
            return it
        }
    }

    /// Значение атрибута: сайт пишет его и в "двойных" (&quot; внутри), и в 'одинарных' кавычках (сырой JSON)
    static func attr(_ name: String, _ html: String) -> String? {
        if let v = first(name + #"\s*=\s*"([^"]*)""#, html) { return v }
        if let v = first(name + #"\s*=\s*'([^']*)'"#, html) { return v }
        return nil
    }

    static func attrJSON(_ name: String, _ html: String) -> Any? {
        guard let raw = attr(name, html) else { return nil }
        for candidate in [raw, unescapeHTML(raw)] {
            if let o = try? JSONSerialization.jsonObject(with: Data(candidate.utf8)) { return o }
        }
        return nil
    }

    /// Страница фильма или сериала
    static func detail(_ html: String, base: KinoItem) -> KinoDetail {
        var it = base
        if let h1 = first(#"<h1[^>]*>(.*?)</h1>"#, html).map(strip), !h1.isEmpty { it.title = h1 }
        if let o = first(#"<div class="film-titles">.*?<div class="orig">(.*?)</div>"#, html).map(strip), !o.isEmpty { it.orig = o }
        if let p = attr("data-poster", html), !p.isEmpty { it.poster = unescapeHTML(p) }
        var d = KinoDetail(item: it)

        // сведения: год, страна, жанр…
        if let dl = first(#"<dl class="kv">(.*?)</dl>"#, html) {
            d.info = all(#"<dt>(.*?)</dt>\s*<dd[^>]*>(.*?)</dd>"#, dl).map { (strip($0[1]), strip($0[2])) }.filter { !$0.1.isEmpty }
        }
        // ld+json: описание, жанры, актёры, режиссёр
        for m in all(#"<script type="application/ld\+json">(.*?)</script>"#, html) {
            guard let o = try? JSONSerialization.jsonObject(with: Data(m[1].utf8)) as? [String: Any] else { continue }
            let graph = (o["@graph"] as? [[String: Any]]) ?? [o]
            for g in graph where ["Movie", "TVSeries"].contains(g["@type"] as? String ?? "") {
                if d.item.desc == nil || (d.item.desc ?? "").isEmpty, var desc = g["description"] as? String {
                    if let r = desc.range(of: "⭐") { desc = String(desc[..<r.lowerBound]) }
                    d.item.desc = desc.trimmingCharacters(in: .whitespaces)
                }
                d.genres = (g["genre"] as? [String]) ?? []
                d.actors = ((g["actor"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }
                d.director = ((g["director"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.first
                if d.item.poster == nil, let img = g["image"] as? String { d.item.poster = img }
                if let r = g["aggregateRating"] as? [String: Any], let v = r["ratingValue"] {
                    d.item.rating = "\(v)"
                }
            }
        }
        if d.item.meta.isEmpty {
            d.item.meta = d.info.filter { ["Год", "Страна", "Жанр", "Длительность"].contains($0.0) }.map { $0.1 }
        }
        // источники плеера (берём Alloha — его поток умеем открывать в родном плеере)
        if let arr = attrJSON("data-players", html) as? [[String: Any]] {
            let names = arr.compactMap { $0["balancer"] as? String }
            d.playersNote = names.isEmpty ? "на странице пустой список плееров" : "плееры на странице: " + names.joined(separator: ", ")
            // сначала Alloha (родной плеер), потом остальные (веб-плеер)
            let sorted = arr.filter { ($0["balancer"] as? String) == "alloha" } + arr.filter { ($0["balancer"] as? String) != "alloha" }
            for p in sorted {
                let bal = (p["balancer"] as? String) ?? "web"
                guard let u = (p["url"] as? String).flatMap({ URL(string: $0.hasPrefix("//") ? "https:" + $0 : $0) }) else { continue }
                var seasons: [Int: [Int]] = [:]
                if let s = p["seasons"] as? [String: Any] {
                    for (k, v) in s { if let n = Int(k) { seasons[n] = (v as? [Any])?.compactMap { ($0 as? Int) ?? Int("\($0)") } ?? [] } }
                }
                var name = (p["translation"] as? String) ?? "Озвучка"
                if bal != "alloha" { name += " (\(bal.capitalized), веб-плеер)" }
                d.sources.append(KinoSource(balancer: bal, translation: name, url: u,
                                            quality: p["quality"] as? String, seasons: bal == "alloha" ? seasons : [:]))
            }
        } else {
            if let r = html.range(of: "data-players") {
                let snippet = html[r.lowerBound...].prefix(160)
                d.playersNote = "не разобрал список плееров (" + String(snippet) + "…)"
            } else {
                d.playersNote = "на странице нет списка плееров"
            }
            // запасной вариант: любой iframe плеера на странице
            if let src = first(#"<iframe[^>]+src="([^"]+)""#, html), let u = URL(string: src.hasPrefix("//") ? "https:" + src : src) {
                d.sources.append(KinoSource(balancer: "web", translation: "Плеер сайта", url: u, quality: nil, seasons: [:]))
            }
        }
        if let eps = attrJSON("data-episodes", html) as? [String: [String: Any]] {
            for (s, m) in eps {
                guard let sn = Int(s) else { continue }
                var e: [Int: String] = [:]
                for (k, v) in m { if let en = Int(k) { e[en] = ((v as? [Any])?.last as? String) ?? "" } }
                d.dates[sn] = e
            }
        }
        return d
    }

    /// Строковый литерал JavaScript ('...') → текст
    static func jsUnescape(_ s: String) -> String {
        var out = ""
        var it = s.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let n = it.next() else { break }
            switch n {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "u":
                var hex = ""
                for _ in 0..<4 { if let h = it.next() { hex.append(h) } }
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) {
                    // экранируем, если внутри строки JSON это кавычка или слэш
                    let ch = Character(u)
                    if ch == "\"" { out += "\\\"" } else if ch == "\\" { out += "\\\\" } else { out.append(ch) }
                }
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default: out.append(n)
            }
        }
        return out
    }
}

// MARK: - Сервис

@MainActor
enum KinoAPI {
    enum Sort: String, CaseIterable {
        case popular = "news_read", new = "new", rating = "rating"
        var title: String {
            switch self { case .popular: return "Популярные"; case .new: return "Новые"; case .rating: return "По рейтингу" }
        }
    }

    struct Home {
        var decks: [(String, [KinoItem])] = []
        var updates: [(String, [(KinoItem, Int?, Int?)])] = []
    }

    static func home() async throws -> Home {
        let html = try await KinoNet.shared.text("/")
        var h = Home()
        let deckNames = [("deck-new", "Популярное"), ("deck-f", "Фильмы"), ("deck-s", "Сериалы"),
                         ("deck-c", "Мультфильмы"), ("deck-a", "Аниме"), ("deck-t", "ТВ-шоу")]
        for (id, name) in deckNames {
            guard let r = html.range(of: "id=\"\(id)\"") else { continue }
            let rest = html[r.upperBound...]
            let end = rest.range(of: "<div class=\"deck\"")?.lowerBound ?? rest.range(of: "</section>")?.lowerBound ?? rest.endIndex
            let items = KinoParse.tiles(String(rest[..<end]))
            if !items.isEmpty { h.decks.append((name, items)) }
        }
        for sec in html.components(separatedBy: "<section class=\"upd\"").dropFirst() {
            let s = sec.components(separatedBy: "</section>").first ?? sec
            let name = KinoParse.first(#"<div class="uhead">(.*?)</div>"#, s).map(KinoParse.strip) ?? "Новые серии"
            let list = KinoParse.updates(s)
            if !list.isEmpty { h.updates.append((name, list)) }
        }
        if h.decks.isEmpty && h.updates.isEmpty {
            // запасной вариант: первая страница каталога
            let l = try await list(path: "/", sort: .popular, page: 1)
            if !l.items.isEmpty { h.decks.append(("Популярное", l.items)) }
        }
        return h
    }

    /// Список: раздел (/film/), жанр (/genre/komedii/), подборка (/podborki/…/), год, страна
    static func list(path: String, sort: Sort, page: Int) async throws -> (items: [KinoItem], pages: Int) {
        let types = ["film", "serial", "multfilm", "anime", "tv-shou"]
        var q = [URLQueryItem(name: "sort", value: sort.rawValue)]
        let seg = path.split(separator: "/").map(String.init)
        if seg.count == 1, types.contains(seg[0]) { q.append(URLQueryItem(name: "type", value: seg[0])) }
        if page > 1 { q.append(URLQueryItem(name: "page", value: String(page))) }
        q.append(URLQueryItem(name: "path", value: path))
        q.append(URLQueryItem(name: "part", value: "list"))
        var c = URLComponents(string: KinoNet.base + "/api/filter.php")!
        c.queryItems = q
        if let t = try? await KinoNet.shared.text(c.url!.absoluteString, ajax: true),
           let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
           let html = o["html"] as? String {
            let items = KinoParse.cards(html)
            if !items.isEmpty { return (items, (o["pages"] as? Int) ?? Int("\(o["pages"] ?? 1)") ?? 1) }
        }
        // запасной путь: обычная страница сайта
        var pc = URLComponents(string: KinoNet.base + path)!
        pc.queryItems = [URLQueryItem(name: "sort", value: sort.rawValue)] + (page > 1 ? [URLQueryItem(name: "page", value: String(page))] : [])
        let html = try await KinoNet.shared.text(pc.url!.absoluteString)
        let items = KinoParse.cards(html)
        let maxPage = KinoParse.all(#"/page/(\d+)/"#, html).compactMap { Int($0[1]) }.max() ?? (items.isEmpty ? page : page + 1)
        return (items, maxPage)
    }

    static func search(_ q: String) async throws -> [KinoItem] {
        var c = URLComponents(string: KinoNet.base + "/api/suggest.php")!
        c.queryItems = [URLQueryItem(name: "q", value: q)]
        let t = try await KinoNet.shared.text(c.url!.absoluteString, ajax: true)
        guard let o = try? JSONSerialization.jsonObject(with: Data(t.utf8)) as? [String: Any],
              let html = o["html"] as? String else { return [] }
        return KinoParse.suggest(html)
    }

    static func detail(_ item: KinoItem) async throws -> KinoDetail {
        let html = try await KinoNet.shared.text(item.path)
        return KinoParse.detail(html, base: item)
    }

    /// Плеер Alloha: страница плеера → номер файла → ссылки на поток
    static func stream(_ source: KinoSource, season: Int?, episode: Int?) async throws -> KinoStream {
        var c = URLComponents(url: source.url, resolvingAgainstBaseURL: false)!
        var items = (c.queryItems ?? []).filter { $0.name != "season" && $0.name != "episode" }
        if let season { items.append(URLQueryItem(name: "season", value: String(season))) }
        if let episode { items.append(URLQueryItem(name: "episode", value: String(episode))) }
        c.queryItems = items
        guard let pageURL = c.url, let host = pageURL.host else { throw KinoError.player("нет адреса") }
        let origin = "\(pageURL.scheme ?? "https")://\(host)"
        let token = items.first { $0.name == "token" }?.value ?? ""
        var note = ""
        if let s = try? await direct(pageURL: pageURL, origin: origin, token: token, note: &note) { return s }
        // прямой путь не сработал — открываем плеер браузером и берём его собственный ответ
        let sniffed: String
        do { sniffed = try await KinoSniffer.capture(pageURL) } catch {
            throw KinoError.player(note.isEmpty ? "плеер не ответил" : note)
        }
        if sniffed.hasPrefix("M3U8 "), let u = URL(string: String(sniffed.dropFirst(5))) {
            return KinoStream(tracks: [.init(label: source.translation.isEmpty ? "Озвучка" : source.translation, qualities: [(720, [u])])],
                              skip: nil, origin: origin, referer: pageURL.absoluteString)
        }
        do {
            return try parseStream(Data(sniffed.utf8), origin: origin, referer: pageURL.absoluteString)
        } catch {
            throw KinoError.player("нет ссылок на видео (\(note.isEmpty ? String(sniffed.prefix(160)) : note))")
        }
    }

    private static func direct(pageURL: URL, origin: String, token: String, note: inout String) async throws -> KinoStream {
        var r = URLRequest(url: pageURL)
        r.setValue(KinoNet.base + "/", forHTTPHeaderField: "Referer")
        r.setValue("text/html,*/*", forHTTPHeaderField: "Accept")
        let (d, _) = try await KinoNet.shared.session.data(for: r)
        let html = String(data: d, encoding: .utf8) ?? ""
        guard let lit = KinoParse.first(#"fileList\s*=\s*JSON\.parse\(\s*['"](.*?)['"]\s*\)"#, html) else {
            note = "страница плеера: " + String(KinoParse.strip(html).prefix(120))
            throw KinoError.player("не нашёл список файлов")
        }
        let json = KinoParse.jsUnescape(lit)
        guard let fl = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else {
            throw KinoError.player("не разобрал список файлов")
        }
        guard let active = fl["active"] as? [String: Any],
              let fileID = (active["id"] as? Int) ?? Int("\(active["id"] ?? "")") else {
            throw KinoError.player("нет этой серии")
        }

        var post = URLRequest(url: URL(string: origin + "/bnsi/movies/\(fileID)")!)
        post.httpMethod = "POST"
        post.httpBody = "token=\(token)&av1=false&autoplay=0&audio=&subtitle=".data(using: .utf8)
        post.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        post.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        post.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        post.setValue(origin, forHTTPHeaderField: "Origin")
        post.setValue("application/json, */*", forHTTPHeaderField: "Accept")
        let (pd, _) = try await KinoNet.shared.session.data(for: post)
        do { return try parseStream(pd, origin: origin, referer: pageURL.absoluteString) } catch {
            note = "ответ: " + (String(data: pd.prefix(120), encoding: .utf8) ?? "")
            throw error
        }
    }

    static func parseStream(_ pd: Data, origin: String, referer: String) throws -> KinoStream {
        guard let o = try? JSONSerialization.jsonObject(with: pd) as? [String: Any] else {
            throw KinoError.player("непонятный ответ")
        }
        var tracks: [KinoStream.Track] = []
        for s in (o["hlsSource"] as? [[String: Any]]) ?? [] {
            let label = (s["label"] as? String) ?? "Озвучка"
            var qs: [(Int, [URL])] = []
            func urls(_ v: Any) -> [URL] {
                if let str = v as? String {
                    return str.components(separatedBy: " or ").compactMap { URL(string: $0.trimmingCharacters(in: .whitespaces)) }
                }
                if let arr = v as? [Any] { return arr.flatMap(urls) }
                if let d = v as? [String: Any] { return ["url", "file", "src", "hls"].compactMap { d[$0] }.flatMap(urls) }
                return []
            }
            for (k, v) in (s["quality"] as? [String: Any]) ?? [:] {
                guard let qn = Int(k.filter(\.isNumber)) else { continue }
                let u = urls(v)
                if !u.isEmpty { qs.append((qn, u)) }
            }
            if qs.isEmpty, let one = (s["file"] ?? s["url"] ?? s["src"]) { let u = urls(one); if !u.isEmpty { qs.append((720, u)) } }
            qs.sort { $0.0 > $1.0 }
            if !qs.isEmpty { tracks.append(.init(label: label, qualities: qs)) }
        }
        guard !tracks.isEmpty else { throw KinoError.player("нет ссылок на видео") }
        var skip: ClosedRange<Double>?
        if let st = o["skipTime"] as? String {
            let p = st.split(separator: "-").compactMap { Double($0) }
            if p.count == 2, p[1] > p[0] { skip = p[0]...p[1] }
        }
        return KinoStream(tracks: tracks, skip: skip, origin: origin, referer: referer)
    }
}

// MARK: - Своё избранное, история и прогресс (у kinomig нет аккаунта)

@MainActor
final class KinoStore: ObservableObject {
    static let shared = KinoStore()

    struct Watch: Codable, Identifiable, Hashable {
        var item: KinoItem
        var season: Int?
        var episode: Int?
        var translation: String?
        var updated: Date
        var id: Int { item.id }
    }
    struct Pos: Codable { var t: Double; var d: Double }

    @Published private(set) var favorites: [KinoItem] = []
    @Published private(set) var history: [Watch] = []
    @Published private(set) var positions: [String: Pos] = [:]

    private init() {
        let ud = UserDefaults.standard
        if let d = ud.data(forKey: "kino.fav.v1"), let v = try? JSONDecoder().decode([KinoItem].self, from: d) { favorites = v }
        if let d = ud.data(forKey: "kino.history.v1"), let v = try? JSONDecoder().decode([Watch].self, from: d) { history = v }
        if let d = ud.data(forKey: "kino.pos.v1"), let v = try? JSONDecoder().decode([String: Pos].self, from: d) { positions = v }
    }

    private func save<T: Encodable>(_ v: T, _ key: String) {
        if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: key) }
    }

    func isFavorite(_ i: KinoItem) -> Bool { favorites.contains { $0.id == i.id } }
    func toggleFavorite(_ i: KinoItem) {
        if isFavorite(i) { favorites.removeAll { $0.id == i.id } } else { favorites.insert(i, at: 0) }
        save(favorites, "kino.fav.v1")
        Haptics.tap()
    }

    func watch(_ i: KinoItem) -> Watch? { history.first { $0.item.id == i.id } }

    func record(_ i: KinoItem, season: Int?, episode: Int?, translation: String?) {
        var h = history.filter { $0.item.id != i.id }
        var item = i
        if let old = history.first(where: { $0.item.id == i.id }) {
            // не теряем описание и постер, если пришли из короткой карточки
            if item.desc == nil { item.desc = old.item.desc }
            if item.poster == nil { item.poster = old.item.poster }
        }
        h.insert(Watch(item: item, season: season, episode: episode, translation: translation, updated: Date()), at: 0)
        history = Array(h.prefix(200))
        save(history, "kino.history.v1")
    }

    func removeHistory(_ i: KinoItem) {
        history.removeAll { $0.item.id == i.id }
        save(history, "kino.history.v1")
    }

    static func posKey(_ id: Int, _ s: Int?, _ e: Int?) -> String { "\(id)-\(s ?? 0)-\(e ?? 0)" }
    func position(_ id: Int, _ s: Int?, _ e: Int?) -> Pos? { positions[Self.posKey(id, s, e)] }
    func setPosition(_ id: Int, _ s: Int?, _ e: Int?, t: Double, d: Double) {
        positions[Self.posKey(id, s, e)] = Pos(t: t, d: d)
        save(positions, "kino.pos.v1")
    }
    func watched(_ id: Int, _ s: Int?, _ e: Int?) -> Bool {
        guard let p = position(id, s, e), p.d > 0 else { return false }
        return p.t / p.d > 0.9
    }
}
