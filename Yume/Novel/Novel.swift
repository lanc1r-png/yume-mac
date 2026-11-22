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

// MARK: - Ранобэ: модели и сервис
struct Novel: Codable, Identifiable, Hashable {
    let anime: Anime
    var id: Int { anime.id }
    init(_ a: Anime) { anime = a }
    init(from decoder: Decoder) throws { anime = try Anime(from: decoder) }
    func encode(to encoder: Encoder) throws { try anime.encode(to: encoder) }
}

extension Anime {
    /// Ключ в хранилище прочитанного: у манги и ранобэ id тайтлов могут совпасть.
    var readKey: Int {
        let site = LibSite.current
        return site.isHentai ? -(id + 500_000_000) : (site.isManga ? -id : id)
    }
}

struct NovelChapter: Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String
    let date: Date?

    init(id: Int, volume: String, number: String, name: String, date: Date? = nil) {
        self.id = id; self.volume = volume; self.number = number; self.name = name; self.date = date
    }

    var saved: SavedChapter { SavedChapter(id: id, volume: volume, number: number, name: name, date: date) }

    init?(_ d: [String: Any]) {
        guard let cid = J.int(d["id"]) else { return nil }
        id = cid
        volume = J.s(d["volume"]) ?? "1"
        number = J.s(d["number"]) ?? "0"
        name = J.str(d["name"]) ?? ""
        // Дата выхода: самая ранняя загрузка среди переводов этой главы.
        var dates: [Date] = []
        for b in (d["branches"] as? [[String: Any]]) ?? [] {
            if let dt = FriendParser.date(b["created_at"]) { dates.append(dt) }
        }
        if dates.isEmpty, let dt = FriendParser.date(d["created_at"]) ?? FriendParser.date(d["date"]) { dates.append(dt) }
        date = dates.min()
    }

    var title: String { name.isEmpty ? "Глава \(number)" : "Глава \(number) · \(name)" }
}

enum ReaderBlock: Identifiable {
    case paragraph(Int, String)
    case heading(Int, String)
    case quote(Int, String)
    case image(Int, URL)
    case rule(Int)
    case rich(Int, AttributedString)

    var id: Int {
        switch self {
        case .paragraph(let i, _), .heading(let i, _), .quote(let i, _), .image(let i, _), .rich(let i, _): return i
        case .rule(let i): return i
        }
    }
}

/// Текст главы приходит как документ ProseMirror (или как HTML-строка).
enum ReaderParser {
    static func absolute(_ s: String?) -> URL? {
        guard var t = s, !t.isEmpty else { return nil }
        if t.hasPrefix("//") { t = "https:" + t }
        else if t.hasPrefix("/") { t = "https://ranobelib.me" + t }
        else if !t.hasPrefix("http") { t = "https://ranobelib.me/" + t }
        return URL(string: t)
    }

    static func parse(_ content: Any?, attachments: [[String: Any]]) -> [ReaderBlock] {
        var out: [ReaderBlock] = []
        var map: [String: URL] = [:]
        for a in attachments {
            guard let u = absolute(J.str(a["url"])) else { continue }
            for k in ["name", "filename", "id"] {
                if let key = J.s(a[k]) { map[key] = u }
            }
        }
        if let s = content as? String {
            out = parseHTML(s)
        } else if let d = content as? [String: Any] {
            walk(d, map: map, out: &out)
        }
        return out
    }

    private static func decode(_ s: String) -> String {
        var t = s
        let pairs = [("&nbsp;", " "), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""), ("&#39;", "'"),
                     ("&laquo;", "«"), ("&raquo;", "»"), ("&mdash;", "—"), ("&ndash;", "–"),
                     ("&hellip;", "…"), ("&amp;", "&")]
        for (a, b) in pairs { t = t.replacingOccurrences(of: a, with: b) }
        return t
    }

    /// Глава как HTML-строка: абзацы, заголовки, цитаты, <img>, курсив и жирный.
    static func parseHTML(_ html: String) -> [ReaderBlock] {
        var out: [ReaderBlock] = []
        if !html.contains("<") {
            for line in decode(html).components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out.append(.paragraph(out.count, t)) }
            }
            return out
        }
        var cur = AttributedString()
        var bold = 0, italic = 0, kind = 0
        func flush() {
            while let l = cur.characters.last, l.isWhitespace || l.isNewline { cur.characters.removeLast() }
            if !cur.characters.isEmpty {
                let plain = String(cur.characters)
                switch kind {
                case 1: out.append(.heading(out.count, plain))
                case 2: out.append(.quote(out.count, plain))
                default: out.append(.rich(out.count, cur))
                }
            }
            cur = AttributedString()
        }
        func addText(_ raw: String) {
            var t = decode(raw).replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            if cur.characters.isEmpty { while t.hasPrefix(" ") { t.removeFirst() } }
            if t.isEmpty { return }
            var run = AttributedString(t)
            if bold > 0 && italic > 0 { run.inlinePresentationIntent = [.stronglyEmphasized, .emphasized] }
            else if bold > 0 { run.inlinePresentationIntent = .stronglyEmphasized }
            else if italic > 0 { run.inlinePresentationIntent = .emphasized }
            cur.append(run)
        }
        let ns = html as NSString
        guard let re = try? NSRegularExpression(pattern: "<[^>]*>"),
              let srcRe = try? NSRegularExpression(pattern: "(?:data-src|src)\\s*=\\s*[\"']([^\"']+)[\"']") else { return out }
        var pos = 0
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            if m.range.location > pos {
                addText(ns.substring(with: NSRange(location: pos, length: m.range.location - pos)))
            }
            pos = m.range.location + m.range.length
            let tag = ns.substring(with: m.range)
            let low = tag.lowercased()
            let closing = low.hasPrefix("</")
            let name = String(low.dropFirst(closing ? 2 : 1).prefix { $0.isLetter || $0.isNumber })
            switch name {
            case "p", "div": flush()
            case "br": cur.append(AttributedString("\n"))
            case "h1", "h2", "h3", "h4", "h5", "h6": flush(); kind = closing ? 0 : 1
            case "blockquote": flush(); kind = closing ? 0 : 2
            case "strong", "b": bold = max(0, bold + (closing ? -1 : 1))
            case "em", "i": italic = max(0, italic + (closing ? -1 : 1))
            case "hr": flush(); out.append(.rule(out.count))
            case "img":
                flush()
                let r = NSRange(location: 0, length: (tag as NSString).length)
                if let sm = srcRe.firstMatch(in: tag, range: r) {
                    let src = (tag as NSString).substring(with: sm.range(at: 1))
                    if let u = absolute(decode(src)) { out.append(.image(out.count, u)) }
                }
            default: break
            }
        }
        if pos < ns.length { addText(ns.substring(from: pos)) }
        flush()
        return out
    }

    private static func inline(_ node: [String: Any]) -> String {
        let type = (node["type"] as? String) ?? ""
        if type == "text" { return (node["text"] as? String) ?? "" }
        if type == "hardBreak" { return "\n" }
        let ch = (node["content"] as? [[String: Any]]) ?? []
        return ch.map { inline($0) }.joined()
    }

    private static func walk(_ node: [String: Any], map: [String: URL], out: inout [ReaderBlock]) {
        let type = (node["type"] as? String) ?? ""
        let children = (node["content"] as? [[String: Any]]) ?? []
        switch type {
        case "paragraph":
            let t = inline(node).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(out.count, t)) }
        case "heading":
            let t = inline(node).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.heading(out.count, t)) }
        case "blockquote":
            let t = children.map { inline($0) }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.quote(out.count, t)) }
        case "listItem":
            let t = inline(node).trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { out.append(.paragraph(out.count, "• " + t)) }
        case "horizontalRule":
            out.append(.rule(out.count))
        case "image":
            let attrs = node["attrs"] as? [String: Any]
            let imgs = (attrs?["images"] as? [[String: Any]]) ?? []
            for im in imgs {
                if let key = J.s(im["image"]), let u = map[key] { out.append(.image(out.count, u)) }
            }
            if imgs.isEmpty, let u = absolute(J.str(attrs?["src"])) { out.append(.image(out.count, u)) }
        default:
            for c in children { walk(c, map: map, out: &out) }
        }
    }
}

enum ChapterAge {
    private static let absFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    /// «сегодня», «вчера», «3 дн. назад», «2 нед. назад», «5 мес. назад», «год назад».
    static func ago(_ d: Date) -> String {
        let cal = Calendar.current
        let days = max(0, cal.dateComponents([.day], from: cal.startOfDay(for: d), to: cal.startOfDay(for: Date())).day ?? 0)
        switch days {
        case 0: return "сегодня"
        case 1: return "вчера"
        case 2..<7: return "\(days) дн. назад"
        case 7..<30: return "\(days / 7) нед. назад"
        case 30..<365: return "\(max(1, days / 30)) мес. назад"
        default:
            let y = days / 365
            return y == 1 ? "год назад" : "\(y) г. назад"
        }
    }

    static func full(_ d: Date) -> String { absFmt.string(from: d) }
}

enum NovelService {
    static func chapters(slug: String) async throws -> [NovelChapter] {
        let data = try await AnimelibAPI.shared.rawData("/manga/\(slug)/chapters")
        guard let root = J.obj(data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { throw APIError.badURL }
        return arr.compactMap { NovelChapter($0) }
    }

    static func chapterPath(slug: String) -> String { "/manga/\(slug)/chapter" }

    static func chapterQuery(_ c: NovelChapter) -> [URLQueryItem] {
        [URLQueryItem(name: "number", value: c.number), URLQueryItem(name: "volume", value: c.volume)]
    }

    static func content(slug: String, chapter c: NovelChapter) async throws -> [ReaderBlock] {
        let data = try await AnimelibAPI.shared.rawData(chapterPath(slug: slug), query: chapterQuery(c))
        guard let root = J.obj(data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { throw APIError.badURL }
        let att = (d["attachments"] as? [[String: Any]]) ?? []
        return ReaderParser.parse(d["content"], attachments: att)
    }
}

// MARK: - Ранобэ: что уже прочитано
/// Отправка прочитанных глав на сайт (как делает сайт: POST .../chapters/{id}/view). Только для вошедших в аккаунт.
enum SiteSync {
    private static var sent = Set<String>()

    static func view(novelID: Int, chapterID: Int) {
        guard let token = Keychain.get("lib.token"), !token.isEmpty else { return }
        let site = LibSite.current
        guard site.isBook else { return }
        let key = "\(site.key):\(novelID):\(chapterID)"
        guard sent.insert(key).inserted else { return }
        let path = "\(site.apiPath)/\(novelID)/chapters/\(chapterID)/view"
        Task.detached(priority: .utility) {
            do {
                _ = try await AnimelibAPI.shared.rawData(path, token: token, method: "POST", json: [:])
            } catch {
                await MainActor.run { _ = SiteSync.sent.remove(key) }
            }
        }
    }
}

@MainActor
final class ReadStore: ObservableObject {
    static let shared = ReadStore()
    @Published private(set) var read: [String: Set<Int>] = [:]
    @Published private(set) var last: [String: Int] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "read.v1"),
           let v = try? JSONDecoder().decode([String: Set<Int>].self, from: d) { read = v }
        if let d = UserDefaults.standard.data(forKey: "readlast.v1"),
           let v = try? JSONDecoder().decode([String: Int].self, from: d) { last = v }
    }

    func isRead(_ novel: Int, _ chapter: Int) -> Bool { read[String(novel)]?.contains(chapter) ?? false }
    func lastChapter(_ novel: Int) -> Int? { last[String(novel)] }

    func mark(_ novel: Int, _ chapter: Int) {
        var list = read[String(novel)] ?? []
        if list.insert(chapter).inserted {
            ActivityStore.shared.addChapter(manga: novel < 0)
        }
        read[String(novel)] = list
        last[String(novel)] = chapter
        if let d = try? JSONEncoder().encode(read) { UserDefaults.standard.set(d, forKey: "read.v1") }
        if let d = try? JSONEncoder().encode(last) { UserDefaults.standard.set(d, forKey: "readlast.v1") }
    }

    func clear() {
        read = [:]; last = [:]
        UserDefaults.standard.removeObject(forKey: "read.v1")
        UserDefaults.standard.removeObject(forKey: "readlast.v1")
    }
}

/// Где остановился читатель: глава и место внутри неё (страница манги или смещение в тексте ранобэ).
struct ReadPos: Codable {
    var c: Int      // id главы
    var p: Int      // манга: страница с нуля; ранобэ (страницы): смещение в тексте
    var b: Int      // ранобэ (прокрутка): номер блока
    var pct: Int    // прочитано в главе, %
    var t: Int      // когда, секунды
    var n: Int? = nil   // манга: всего страниц в главе
}

@MainActor
final class ReadPosStore {
    static let shared = ReadPosStore()
    private var items: [String: ReadPos] = [:]
    private let key = "readpos.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: ReadPos].self, from: d) { items = v }
    }

    func get(_ k: Int) -> ReadPos? { items[String(k)] }

    private var saveTask: Task<Void, Never>?

    func set(_ k: Int, _ pos: ReadPos) {
        items[String(k)] = pos
        if items.count > 300 {
            let keep = items.sorted { $0.value.t > $1.value.t }.prefix(250)
            items = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        // на диск не чаще раза в секунду: при прокрутке позиция меняется десятки раз
        saveTask?.cancel()
        saveTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_000_000_000)
            guard !Task.isCancelled, let self else { return }
            if let d = try? JSONEncoder().encode(self.items) { UserDefaults.standard.set(d, forKey: self.key) }
        }
    }

    func clear() {
        items = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }
}

/// Ссылка на тайтл: для аниме ведёт на экран аниме, для ранобэ на экран ранобэ.
struct TitleLink<Content: View>: View {
    let anime: Anime
    let label: () -> Content

    init(anime: Anime, @ViewBuilder label: @escaping () -> Content) {
        self.anime = anime
        self.label = label
    }

    var body: some View {
        Group {
            if LibSite.current.isBook {
                NavigationLink(value: Novel(anime)) { label() }
            } else {
                NavigationLink(value: anime) { label() }
            }
        }
        .contextMenu {
            let store = FavoritesStore.current
            Button { store.toggle(anime) } label: {
                SwiftUI.Label(store.contains(anime) ? "Убрать из избранного" : "В избранное",
                      systemImage: store.contains(anime) ? "heart.slash" : "heart")
            }
            if let u = titleURL(anime) {
                ShareLink(item: u) { SwiftUI.Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

struct FitImage: View {
    let url: URL
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image).resizable().scaledToFit().transition(.opacity)
            } else if failed {
                Label("Иллюстрация не загрузилась", systemImage: "photo")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 120)
            }
        }
        .task(id: url) { await load() }
    }

    private func load() async {
        if url.isFileURL {
            let key = ImageCache.key(url, 1600)
            if let c = ImageCache.shared.object(forKey: key) { image = c; return }
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let d = try? Data(contentsOf: url) else { return nil }
                return ImageLoader.downsample(d, maxPixel: 1600)
            }.value
            if let img { ImageCache.store(img, key); image = img } else { failed = true }
            return
        }
        let key = ImageCache.key(url, 1600)
        if let c = ImageCache.shared.object(forKey: key) { image = c; return }
        if let img = await ImageLoader.shared.image(url, referer: LibSite.ranobe.referer, maxPixel: 1600) {
            ImageCache.store(img, key)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}
