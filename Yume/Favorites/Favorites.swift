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

// MARK: - Favorites
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore(key: "favorites.v1")
    static let novels = FavoritesStore(key: "favorites.novels.v1")
    static let manga = FavoritesStore(key: "favorites.manga.v1")
    static let hentai = FavoritesStore(key: "favorites.hentai.v1")
    static var current: FavoritesStore { store(for: LibSite.current) }

    static func store(for site: LibSite) -> FavoritesStore {
        if site.isHentai { return hentai }
        return site.isManga ? manga : (site.isRanobe ? novels : shared)
    }
    @Published private(set) var items: [Anime] = []
    private let key: String

    init(key: String) {
        self.key = key
        if let d = UserDefaults.standard.data(forKey: key),
           let a = try? JSONDecoder().decode([Anime].self, from: d) {
            items = a
        }
    }

    func contains(_ a: Anime) -> Bool { items.contains { $0.id == a.id } }

    /// Тайтлы из списков на сайте: новые добавляются в конец, а те, что раньше пришли с сайта
    /// и оттуда убраны, — убираются и здесь. Добавленное только в приложении не трогаем.
    func mergeFromSite(_ list: [Anime], siteKey: String) {
        let idsKey = "sitelists.ids.\(siteKey)"
        let before = Set((UserDefaults.standard.array(forKey: idsKey) as? [Int]) ?? [])
        let now = Set(list.map { $0.id })
        var out = items.filter { !(before.contains($0.id) && !now.contains($0.id)) }
        var have = Set(out.map { $0.id })
        for a in list where have.insert(a.id).inserted { out.append(a) }
        if out.map({ $0.id }) != items.map({ $0.id }) {
            items = out
            if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
        }
        UserDefaults.standard.set(Array(now), forKey: idsKey)
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: key)
    }

    func toggle(_ a: Anime) {
        Haptics.tap()
        if let i = items.firstIndex(where: { $0.id == a.id }) {
            items.remove(at: i)
        } else {
            items.insert(a, at: 0)
        }
        if let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }
}

// MARK: - Списки избранного: статусы, сортировка, «Продолжить»
/// Свои названия для папок избранного («Читаю», «В планах»…): хранятся отдельно, уходят в бэкап.
enum FavNames {
    private static let key = "fav.names.v1"
    private static var cache: [String: String]?
    private static func all() -> [String: String] {
        if let c = cache { return c }
        var v: [String: String] = [:]
        if let d = UserDefaults.standard.string(forKey: key)?.data(using: .utf8),
           let dec = try? JSONDecoder().decode([String: String].self, from: d) { v = dec }
        cache = v
        return v
    }
    private static func k(_ st: ListStatus, _ book: Bool) -> String { st.rawValue + (book ? ".b" : ".a") }
    static func get(_ st: ListStatus, book: Bool) -> String? {
        let v = all()[k(st, book)]
        return (v?.isEmpty ?? true) ? nil : v
    }
    static func set(_ st: ListStatus, book: Bool, _ name: String?) {
        var v = all()
        let t = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if t.isEmpty { v.removeValue(forKey: k(st, book)) } else { v[k(st, book)] = String(t.prefix(24)) }
        cache = v
        if let d = try? JSONEncoder().encode(v), let str = String(data: d, encoding: .utf8) {
            UserDefaults.standard.set(str, forKey: key)
        }
    }
}

/// Главный цвет обложки: фон страницы и карточек слегка подкрашивается им.
enum CoverTint {
    @MainActor private static var cache: [String: Color] = [:]

    @MainActor
    static func color(_ url: URL?) async -> Color? {
        guard let url else { return nil }
        if let c = cache[url.absoluteString] { return c }
        guard let img = await ImageLoader.shared.image(url, referer: LibSite.current.referer, maxPixel: 40),
              let cg = img.cgImage else { return nil }
        let w = 8, h = 8
        var px = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .medium
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        var r = 0.0, g = 0.0, b = 0.0, n = 0.0
        for i in 0..<(w * h) {
            let rr = Double(px[i * 4]) / 255, gg = Double(px[i * 4 + 1]) / 255, bb = Double(px[i * 4 + 2]) / 255
            let mx = max(rr, gg, bb), mn = min(rr, gg, bb)
            let wgt = 0.15 + (mx - mn) * 2          // яркие, цветные пиксели весомее серых
            r += rr * wgt; g += gg * wgt; b += bb * wgt; n += wgt
        }
        guard n > 0 else { return nil }
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, al: CGFloat = 0
        UIColor(red: r / n, green: g / n, blue: b / n, alpha: 1).getHue(&hue, saturation: &sat, brightness: &bri, alpha: &al)
        let c = Color(hue: Double(hue), saturation: Double(min(1, max(sat, 0.4) * 1.15)), brightness: Double(min(0.85, max(bri, 0.55))))
        cache[url.absoluteString] = c
        return c
    }
}

struct CoverTintLayer: View {
    let url: URL?
    var strength: Double = 0.5
    var horizontal = false
    @State private var color: Color?
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        // в светлой теме цвет обложки сильно разбавляется белым (светлота ~90%) — только лёгкий оттенок, без мути
        let base = color ?? .clear
        let c = scheme == .dark || color == nil ? base : Color(uiColor: Theme.mix(UIColor(base), .white, 0.72))
        LinearGradient(colors: [c.opacity(strength), c.opacity(0)],
                       startPoint: horizontal ? .leading : .top, endPoint: horizontal ? .trailing : .bottom)
            .opacity(color == nil ? 0 : 1)
            .animation(.easeOut(duration: 0.6), value: color != nil)
            .allowsHitTesting(false)
            .task(id: url) { color = await CoverTint.color(url) }
    }
}

enum ListStatus: String, CaseIterable, Codable {
    case active, planned, done, dropped

    func title(book: Bool) -> String {
        if let custom = FavNames.get(self, book: book) { return custom }
        return defaultTitle(book: book)
    }

    func defaultTitle(book: Bool) -> String {
        switch self {
        case .active: return book ? "Читаю" : "Смотрю"
        case .planned: return "В планах"
        case .done: return book ? "Прочитано" : "Просмотрено"
        case .dropped: return "Брошено"
        }
    }

    /// Единый значок статуса для всех экранов: «Читаю» — открытая книга, «Смотрю» — глаз, «В планах» — календарь,
    /// «Прочитано/Просмотрено» — галочка, «Брошено» — крестик. Закладка — только у своих списков.
    func icon(book: Bool) -> String {
        switch self {
        case .active: return book ? "book.fill" : "eye.fill"
        case .planned: return "calendar"
        case .done: return "checkmark.circle.fill"
        case .dropped: return "xmark.circle.fill"
        }
    }

    /// Значок для маленькой круглой метки на обложке (без своего круга — круг рисует метка)
    func badgeIcon(book: Bool) -> String {
        switch self {
        case .active: return book ? "book.fill" : "eye.fill"
        case .planned: return "calendar"
        case .done: return "checkmark"
        case .dropped: return "xmark"
        }
    }

    /// Статус по названию папки сайта («Читаю», «В планах»…) — чтобы и в профиле были те же значки и цвета
    static func fromFolderName(_ name: String) -> ListStatus? {
        let n = name.lowercased()
        if n.contains("смотрю") || n.contains("читаю") { return .active }
        if n.contains("план") { return .planned }
        if n.contains("просмотр") || n.contains("прочитан") { return .done }
        if n.contains("брош") { return .dropped }
        return nil
    }

    /// Цвета статусов в одной палитре: «в процессе» — акцент, остальные — мягкие соседние тона.
    var color: Color {
        switch self {
        case .active: return Color(red: 0.25, green: 0.80, blue: 0.48)
        case .planned: return Color(red: 1.0, green: 0.70, blue: 0.30)
        case .done: return Color(red: 0.35, green: 0.62, blue: 1.0)
        case .dropped: return Color(red: 1.0, green: 0.40, blue: 0.48)
        }
    }
}

enum FavSort: String, CaseIterable {
    case added, updated, opened, title, rating

    var title: String {
        switch self {
        case .added: return "По добавлению"
        case .updated: return "По обновлению (новые серии и главы)"
        case .opened: return "Недавно открытые"
        case .title: return "По названию"
        case .rating: return "По рейтингу"
        }
    }
}

struct FavMeta: Codable {
    var status: String?
    /// Статус по спискам сайта при прошлой синхронизации: меняем свой, только когда на сайте он сменился
    var site: String?
    var count: Int?
    var release: Date?
    var changed: Date?
    var checked: Date?
    var seen: Int?
}

enum FavUpdate {
    /// Достаёт из ответа сайта число серий/глав и дату последнего выхода (поля ищем по смыслу имени).
    static func parse(_ root: Any) -> (count: Int?, date: String?) {
        var count: Int?
        var date: String?
        func walk(_ v: Any, _ depth: Int) {
            guard depth < 3 else { return }
            if let o = v as? [String: Any] {
                for (k, x) in o {
                    let lk = k.lowercased()
                    if count == nil, ["episodes_count", "chapters_count", "items_count"].contains(lk), let n = J.int(x) {
                        count = n
                    }
                    if date == nil, lk.contains("last"), lk.contains("episode") || lk.contains("chapter"),
                       let str = x as? String, str.count >= 10, str.first?.isNumber == true {
                        date = str
                    }
                    if x is [String: Any] || x is [Any] { walk(x, depth + 1) }
                }
            } else if let arr = v as? [Any] {
                for x in arr.prefix(5) { walk(x, depth + 1) }
            }
        }
        walk(root, 0)
        return (count, date)
    }
}

func makeLibFmt(_ pattern: String) -> DateFormatter {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = pattern
    return f
}
let libLongFmt = makeLibFmt("yyyy-MM-dd HH:mm:ss")
let libShortFmt = makeLibFmt("yyyy-MM-dd")

func parseLibDate(_ s: String) -> Date? {
    let t = s.replacingOccurrences(of: "T", with: " ")
    let long = t.count >= 19
    let f = long ? libLongFmt : libShortFmt
    return f.date(from: String(t.prefix(long ? 19 : 10)))
}

@MainActor
final class FavMetaStore: ObservableObject {
    static let shared = FavMetaStore()
    @Published private(set) var items: [String: FavMeta] = [:]
    private let key = "favmeta.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: FavMeta].self, from: d) { items = v }
    }

    static func key(_ a: Anime) -> String { "\(LibSite.current.key)-\(a.id)" }

    func status(_ a: Anime) -> ListStatus? {
        items[Self.key(a)]?.status.flatMap { ListStatus(rawValue: $0) }
    }

    func setStatus(_ a: Anime, _ s: ListStatus?) {
        var m = items[Self.key(a)] ?? FavMeta()
        m.status = s?.rawValue
        items[Self.key(a)] = m
        save()
    }

    func applySiteStatuses(_ list: [(Anime, ListStatus?)], site: String) {
        var all = items
        var changed = false
        for (a, st) in list {
            let k = "\(site)-\(a.id)"
            var m = all[k] ?? FavMeta()
            let s = st?.rawValue
            guard m.site != s else { continue }
            if let s { m.status = s }
            m.site = s
            all[k] = m
            changed = true
        }
        if changed { items = all; save() }
    }

    func updateDate(_ a: Anime) -> Date? {
        guard let m = items[Self.key(a)] else { return nil }
        return m.release ?? m.changed
    }

    /// Сколько серий или глав вышло с тех пор, как ты в последний раз заглядывал в тайтл.
    func newCount(_ a: Anime) -> Int {
        guard let m = items[Self.key(a)], let c = m.count, let s = m.seen else { return 0 }
        return max(0, c - s)
    }

    func totalNew(_ list: [Anime]) -> Int { list.filter { newCount($0) > 0 }.count }

    func markSeen(_ a: Anime) {
        let k = Self.key(a)
        guard var m = items[k], let c = m.count, m.seen != c else { return }
        m.seen = c
        items[k] = m
        save()
    }

    func markAllSeen(_ list: [Anime]) {
        for a in list {
            let k = Self.key(a)
            if var m = items[k], let c = m.count { m.seen = c; items[k] = m }
        }
        UserDefaults.standard.set(Date(), forKey: "new.lastVisit")
        save()
    }

    func needsCheck(_ a: Anime) -> Bool {
        guard let c = items[Self.key(a)]?.checked else { return true }
        return Date().timeIntervalSince(c) > 1800
    }

    func apply(_ a: Anime, count: Int?, date: String?) {
        applyBatch([(a, count, date)])
    }

    /// Применяет сразу пачку результатов: одна запись на диск и одна перерисовка вместо десятков.
    func applyBatch(_ results: [(Anime, Int?, String?)]) {
        guard !results.isEmpty else { return }
        var all = items
        for (a, count, date) in results {
            var m = all[Self.key(a)] ?? FavMeta()
            if m.seen == nil, let n = count { m.seen = m.count ?? n }
            if let old = m.count, let n = count, n > old { m.changed = Date() }
            if let n = count { m.count = n }
            if let d = date, let parsed = parseLibDate(d) { m.release = parsed }
            m.checked = Date()
            all[Self.key(a)] = m
        }
        items = all
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Статистика по жанрам из профиля на сайте (`/user/{id}/stats`) — отдельно для каждой платформы.
@MainActor
final class UserGenreStats: ObservableObject {
    static let shared = UserGenreStats()
    struct Genre: Codable, Hashable {
        let name: String
        let count: Int
        var id: Int?
    }
    @Published private(set) var version = 0
    /// Сырой ответ, если разобрать не получилось (покажем, чтобы прислать разработчику)
    @Published private(set) var debug: [String: String] = [:]
    private var cache: [String: [Genre]] = [:]
    private var loadedAt: [String: Date] = [:]

    private func key(_ s: String) -> String { "userstats.genres.\(s)" }

    func genres(_ site: String = LibSite.current.key) -> [Genre] {
        if let c = cache[site] { return c }
        var v: [Genre] = []
        if let d = UserDefaults.standard.data(forKey: key(site)),
           let dec = try? JSONDecoder().decode([Genre].self, from: d) { v = dec }
        cache[site] = v
        return v
    }

    func load(userID: Int, token: String) async {
        let site = LibSite.current.key
        if let t = loadedAt[site], Date().timeIntervalSince(t) < 1800 { return }
        loadedAt[site] = Date()
        guard let data = try? await RequestGate.inBackground({
                  try await AnimelibAPI.shared.rawData("/user/\(userID)/stats", token: token)
              }),
              let root = J.obj(data) else { loadedAt[site] = nil; return }
        guard LibSite.current.key == site else { return }
        let list = Self.parse(root)
        if list.isEmpty {
            debug[site] = String((String(data: data, encoding: .utf8) ?? "").prefix(700))
        } else {
            debug[site] = nil
            cache[site] = list
            if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key(site)) }
        }
        version += 1
    }

    /// Ищем в ответе список «название — число»; список под ключом с «genre» важнее остальных.
    static func parse(_ root: Any) -> [Genre] {
        let nameKeys = ["rus_name", "name", "title", "label"]
        let countKeys = ["count", "value", "total", "cnt", "items_count", "chapters_count", "titles_count", "amount"]
        func item(_ d: [String: Any]) -> Genre? {
            var src = d
            for k in ["genre", "item", "model"] { if let sub = d[k] as? [String: Any] { src.merge(sub) { a, _ in a } } }
            guard let name = nameKeys.lazy.compactMap({ J.str(src[$0]) }).first(where: { !$0.isEmpty }),
                  let n = countKeys.lazy.compactMap({ J.int(d[$0]) ?? J.int(src[$0]) }).first else { return nil }
            return Genre(name: name, count: n, id: J.int(src["id"]))
        }
        var best: (score: Int, list: [Genre]) = (0, [])
        func walk(_ v: Any, _ path: String, _ depth: Int) {
            guard depth < 6 else { return }
            if let arr = v as? [[String: Any]], !arr.isEmpty {
                let got = arr.compactMap(item)
                if got.count >= max(2, arr.count / 2) {
                    let score = got.count + (path.contains("genre") ? 1000 : 0) - (path.contains("tag") ? 500 : 0)
                    if score > best.score { best = (score, got) }
                }
                for x in arr.prefix(3) { walk(x, path, depth + 1) }
            } else if let o = v as? [String: Any] {
                // вид «{"Романтика": 383, …}» под ключом с genre
                if path.contains("genre") {
                    let pairs = o.compactMap { k, x -> Genre? in J.int(x).map { Genre(name: k, count: $0) } }
                    if pairs.count >= 2, pairs.count + 900 > best.score { best = (pairs.count + 900, pairs) }
                }
                for (k, x) in o { walk(x, path + "/" + k.lowercased(), depth + 1) }
            }
        }
        walk(root, "", 0)
        return best.list.filter { $0.count > 0 }.sorted { $0.count > $1.count }
    }
}

/// Свои папки на сайте («Любимые», «Геншин»…) и какие тайтлы в них лежат — для чипов в «Избранном» и подборок в профиле.
@MainActor
final class SiteFolders: ObservableObject {
    static let shared = SiteFolders()
    struct Folder: Codable, Identifiable, Equatable {
        let id: Int
        let name: String
        var ids: [Int]
    }
    /// Меняется при каждой записи — чтобы экраны перерисовались
    @Published private(set) var version = 0
    private var cache: [String: [Folder]] = [:]

    private func key(_ s: String) -> String { "sitelists.folders.\(s)" }

    /// Папки текущей платформы
    var current: [Folder] {
        let s = LibSite.current.key
        if let c = cache[s] { return c }
        var v: [Folder] = []
        if let d = UserDefaults.standard.data(forKey: key(s)),
           let dec = try? JSONDecoder().decode([Folder].self, from: d) { v = dec }
        cache[s] = v
        return v
    }

    func set(_ list: [Folder], site s: String) {
        if let d = try? JSONEncoder().encode(list) { UserDefaults.standard.set(d, forKey: key(s)) }
        cache[s] = list
        version += 1
    }

    var favorite: Folder? { current.first { $0.name.lowercased().contains("любим") } }
}

/// Списки на сайте → «Избранное» и значки статусов в «Каталоге». Не чаще раза в полчаса (по свайпу — сразу).
@MainActor
enum SiteListSync {
    /// Идущая синхронизация по платформе. Отдельная задача, а не задача экрана: экран может пересоздаться
    /// (смена платформы) или закрыться — раньше из-за этого синхронизация обрывалась с «cancelled».
    private static var tasks: [String: Task<Void, Never>] = [:]
    /// Последняя ошибка синхронизации по платформе — покажем в «Избранном»
    static var lastError: [String: String] = [:]

    static func syncIfDue(force: Bool = false) async {
        let site = LibSite.current
        if let t = tasks[site.key] { await t.value; return }
        let t = Task { @MainActor in
            await RequestGate.inBackground { await sync(site, force: force) }
        }
        tasks[site.key] = t
        await t.value
        tasks[site.key] = nil
    }

    /// Синхронизация конкретной платформы: результат пишется в её хранилища, даже если ты уже переключился
    private static func sync(_ site: LibSite, force: Bool) async {
        let auth = AuthStore.shared
        guard let t = auth.token, let uid = auth.user?.id else { return }
        let lastKey = "sitelists.last.\(site.key)"
        if !force, let d = UserDefaults.standard.object(forKey: lastKey) as? Date, Date().timeIntervalSince(d) < 1800 { return }
        func fail(_ e: Error?) {
            // отмена — не ошибка сайта: просто повторим в следующий раз
            if let e, e is CancellationError || (e as? URLError)?.code == .cancelled { return }
            lastError[site.key] = e.map { "\($0.localizedDescription)" } ?? "неожиданный ответ сайта"
        }
        let data: Data
        do { data = try await AnimelibAPI.shared.rawData("/bookmarks/folder/\(uid)", token: t, site: site) }
        catch { fail(error); return }
        guard let root = J.obj(data) as? [String: Any],
              let arr = root["data"] as? [[String: Any]] else { fail(nil); return }
        let folders: [(Int, String)] = arr.compactMap { d in
            guard let id = J.int(d["id"]) else { return nil }
            return (id, J.str(d["name"]) ?? J.str(d["title"]) ?? "")
        }
        var titles: [Anime] = []
        var status: [Int: ListStatus] = [:]
        var seenAll = Set<Int>()
        var custom: [SiteFolders.Folder] = []
        for (fid, name) in folders {
            let st = ListStatus.fromFolderName(name)
            var members: [Int] = []
            var seen = Set<Int>()
            var page = 1
            while page <= 40 {
                let q = [URLQueryItem(name: "user_id", value: String(uid)),
                         URLQueryItem(name: "page", value: String(page)),
                         URLQueryItem(name: "status", value: String(fid))]
                // ошибка посреди — ничего не меняем, чтобы не убрать лишнего
                let d: Data
                do { d = try await AnimelibAPI.shared.rawData("/bookmarks", query: q, token: t, site: site) }
                catch { fail(error); return }
                guard let r = J.obj(d) as? [String: Any],
                      let list = r["data"] as? [[String: Any]] else { fail(nil); return }
                let got = list.compactMap { ProfileViewModel.anime(from: $0) }.filter { seen.insert($0.id).inserted }
                if got.isEmpty { break }
                for a in got {
                    if seenAll.insert(a.id).inserted { titles.append(a) }
                    if let st { status[a.id] = st }
                    members.append(a.id)
                }
                page += 1
            }
            if st == nil { custom.append(.init(id: fid, name: name, ids: members)) }
        }
        guard !folders.isEmpty else { return }
        FavoritesStore.store(for: site).mergeFromSite(titles, siteKey: site.key)
        FavMetaStore.shared.applySiteStatuses(titles.map { ($0, status[$0.id]) }, site: site.key)
        SiteFolders.shared.set(custom, site: site.key)
        lastError[site.key] = nil
        UserDefaults.standard.set(Date(), forKey: lastKey)
    }
}

/// Плановая проверка обновлений избранного: при запуске и возвращении в приложение, не чаще раза в час.
@MainActor
enum FavUpdater {
    static func refresh(_ list: [Anime], force: Bool) async {
        let meta = FavMetaStore.shared
        let site = LibSite.current.key
        // только то, что читаешь (и добавленное без статуса): «В планах», «Брошено», «Прочитано» не проверяем
        let todo = list.filter { a in
            let st = meta.status(a)
            return (st == nil || st == .active) && (force || meta.needsCheck(a))
        }.prefix(80).map { $0 }
        var results: [(Anime, Int?, String?)] = []
        var i = 0
        while i < todo.count {
            let chunk = Array(todo[i..<min(i + 4, todo.count)])
            await withTaskGroup(of: (Anime, Int?, String?).self) { group in
                for a in chunk {
                    group.addTask {
                        let r = await RequestGate.inBackground { await AnimelibAPI.shared.updateInfo(slug: a.slugUrl) }
                        return (a, r.count, r.date)
                    }
                }
                var got: [(Anime, Int?, String?)] = []
                for await r in group { got.append(r) }
                if LibSite.current.key == site { results += got }
            }
            i += 4
            // Записываем пачками по 20 тайтлов: прогресс не теряется, а экран перерисовывается редко.
            if results.count >= 20 || i >= todo.count {
                if LibSite.current.key == site { meta.applyBatch(results) }
                results.removeAll()
            }
        }
    }

    static func refreshIfDue() async {
        let last = UserDefaults.standard.object(forKey: "new.lastRun") as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 3600 else { return }
        UserDefaults.standard.set(Date(), forKey: "new.lastRun")
        await refresh(FavoritesStore.current.items, force: false)
    }
}

struct NewInFavoritesView: View {
    @ObservedObject private var favorites: FavoritesStore = FavoritesStore.current
    @ObservedObject private var meta = FavMetaStore.shared
    @State private var refreshing = false
    private let unit = LibSite.current.isBook ? "гл." : "сер."

    private var fresh: [Anime] {
        favorites.items.filter { meta.newCount($0) > 0 }
            .sorted { (meta.updateDate($0) ?? .distantPast) > (meta.updateDate($1) ?? .distantPast) }
    }

    private var recent: [Anime] {
        favorites.items.filter { a in
            meta.newCount(a) == 0 && (meta.updateDate(a).map { Date().timeIntervalSince($0) < 14 * 86400 } ?? false)
        }
        .sorted { (meta.updateDate($0) ?? .distantPast) > (meta.updateDate($1) ?? .distantPast) }
    }

    private func row(_ a: Anime) -> some View {
        let n = meta.newCount(a)
        return TitleLink(anime: a) {
            HStack(spacing: 12) {
                RemoteImage(url: a.imageURL, maxPixel: 200)
                    .frame(width: 56, height: 84)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 6) {
                    Text(a.displayTitle)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if n > 0 {
                            Text("+\(n) \(unit)")
                                .font(.caption.weight(.bold))
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Theme.accent, in: Capsule())
                                .foregroundStyle(.white)
                        }
                        if let d = meta.updateDate(a) {
                            Text(ChapterAge.ago(d)).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .foregroundStyle(.primary)
            .padding(10)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
            .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.chip))
        }
        .buttonStyle(.pressable)
        .simultaneousGesture(TapGesture().onEnded { meta.markSeen(a) })
    }

    private func header(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.caption.weight(.bold)).tracking(1.1)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 8)
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                let f = fresh
                HStack(spacing: 12) {
                    Image(systemName: f.isEmpty ? "checkmark.seal.fill" : "bell.badge.fill")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(f.isEmpty ? "Всё прочитано" : "Новое в \(f.count) тайтлах").font(.headline)
                        if let d = UserDefaults.standard.object(forKey: "new.lastVisit") as? Date {
                            Text("Отмечено: " + ChapterAge.ago(d)).font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text(refreshing ? "Проверяю…" : "Избранное проверяется само").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.accent.opacity(0.14), in: RoundedRectangle(cornerRadius: 20))

                if !f.isEmpty {
                    Button {
                        Haptics.success()
                        withAnimation { meta.markAllSeen(favorites.items) }
                    } label: {
                        Label("Отметить всё просмотренным", systemImage: "checkmark.circle")
                            .font(.footnote.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                    header("Новое")
                    ForEach(f) { row($0) }
                }
                let r = recent
                if !r.isEmpty {
                    header("Недавно обновлялись")
                    ForEach(r) { row($0) }
                }
                if f.isEmpty && r.isEmpty {
                    Text("Пока ничего нового. Потяни вниз, чтобы проверить сейчас.")
                        .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        .padding(.top, 30)
                }
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle("Новое")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable {
            refreshing = true
            await FavUpdater.refresh(favorites.items, force: true)
            refreshing = false
        }
        .task {
            refreshing = true
            await FavUpdater.refresh(favorites.items, force: false)
            refreshing = false
        }
    }
}

/// Маленький значок статуса на обложке (тот же вид, что в «Избранном»).
struct StatusBadge: View {
    let status: ListStatus
    let book: Bool
    var size: CGFloat = 24
    var body: some View {
        Image(systemName: status.badgeIcon(book: book))
            .font(.system(size: size * 0.42, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background {
                ZStack {
                    Circle().fill(.ultraThinMaterial)
                    Circle().fill(status.color.opacity(0.85))
                }
            }
            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            .padding(size < 24 ? 4 : 6)
            .allowsHitTesting(false)
    }
}

/// «12 тыс.», «1,2 млн», «850»
func fmtVotes(_ n: Int) -> String {
    if n >= 1_000_000 { return String(format: "%.1f млн", Double(n) / 1_000_000).replacingOccurrences(of: ".", with: ",") }
    if n >= 10_000 { return "\(n / 1000) тыс." }
    if n >= 1000 { return String(format: "%.1f тыс.", Double(n) / 1000).replacingOccurrences(of: ".", with: ",") }
    return "\(n)"
}

struct FavCard: View {
    let anime: Anime
    let status: ListStatus?
    let book: Bool
    var newCount: Int = 0
    var subtitle: String? = nil
    var progress: Double? = nil
    let onStatus: (ListStatus?) -> Void
    let onContinue: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            TitleLink(anime: anime) { AnimeCard(anime: anime, showRating: false, subtitle: subtitle, progress: progress) }
                .buttonStyle(.pressable)
            GeometryReader { geo in
                ZStack {
                    Menu {
                        ForEach(ListStatus.allCases, id: \.self) { st in
                            Button { onStatus(st) } label: { Label(st.title(book: book), systemImage: st.icon(book: book)) }
                        }
                        if status != nil {
                            Button(role: .destructive) { onStatus(nil) } label: {
                                Label("Без статуса", systemImage: "tag.slash")
                            }
                        }
                    } label: {
                        // стеклянная подложка + цвет статуса из общей палитры
                        Image(systemName: status?.badgeIcon(book: book) ?? "tag")
                            .font(.system(size: 11, weight: .heavy))
                            .foregroundStyle(.white)
                            .frame(width: 28, height: 28)
                            .background {
                                ZStack {
                                    Circle().fill(.ultraThinMaterial)
                                    Circle().fill((status?.color ?? Color.black).opacity(status == nil ? 0.25 : 0.82))
                                }
                            }
                            .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
                            .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                    }
                    .position(x: 22, y: 22)

                    Button(action: onContinue) {
                        Image(systemName: "play.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .frame(width: 30, height: 30)
                            .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.6))
                            .shadow(color: Theme.accent.opacity(0.45), radius: 4, y: 1)
                    }
                    .buttonStyle(.plain)
                    .position(x: geo.size.width - 22, y: geo.size.width * 1.5 - 22)
                }
            }
        }
        .overlay(alignment: .topTrailing) {
            if newCount > 0 {
                Text("+\(newCount)")
                    .font(.system(size: 11, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(Theme.accent, in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.5), lineWidth: 0.8))
                    .shadow(color: .black.opacity(0.3), radius: 3, y: 1)
                    .padding(7)
                    .allowsHitTesting(false)
            }
        }
    }
}

struct FavoritesView: View {
    @ObservedObject private var favorites: FavoritesStore = FavoritesStore.current
    @ObservedObject private var meta = FavMetaStore.shared
    @ObservedObject private var history: HistoryStore = HistoryStore.current
    @ObservedObject private var readStore = ReadStore.shared
    @AppStorage("fav.sort") private var sortRaw = FavSort.added.rawValue
    @State private var filter: ListStatus?
    /// Своя папка сайта («Любимые»…) — вместо статуса
    @State private var folderFilter: Int?
    @ObservedObject private var siteFolders = SiteFolders.shared
    @ObservedObject private var favRouter = AppRouter.shared
    @ObservedObject private var folderStyles = FolderStyles.shared
    @State private var continueAnime: Anime?
    @State private var pushContinue = false
    @State private var refreshing = false
    @State private var showNew = false
    @State private var renaming: ListStatus?
    @State private var renameText = ""
    @State private var namesTick = 0
    private let book = LibSite.current.isBook
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    private var sort: FavSort { FavSort(rawValue: sortRaw) ?? .added }

    private func opened(_ a: Anime) -> Date {
        history.items.first(where: { $0.anime.id == a.id })?.updated ?? Date.distantPast
    }

    private var visible: [Anime] {
        var list = favorites.items
        if let f = filter { list = list.filter { meta.status($0) == f } }
        if let fid = folderFilter, let folder = siteFolders.current.first(where: { $0.id == fid }) {
            let ids = Set(folder.ids)
            list = list.filter { ids.contains($0.id) }
        }
        switch sort {
        case .added:
            break
        case .updated:
            list.sort { (meta.updateDate($0) ?? Date.distantPast) > (meta.updateDate($1) ?? Date.distantPast) }
        case .opened:
            list.sort { opened($0) > opened($1) }
        case .title:
            list.sort { $0.displayTitle.localizedCaseInsensitiveCompare($1.displayTitle) == .orderedAscending }
        case .rating:
            list.sort { (Double($0.rateAvg ?? "") ?? 0) > (Double($1.rateAvg ?? "") ?? 0) }
        }
        return list
    }

    private func chip(_ title: String, _ count: Int, _ on: Bool, dot: Color? = nil, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                // цветная точка статуса
                if let dot {
                    Circle().fill(on ? Color.white : dot).frame(width: 8, height: 8)
                }
                Text("\(title) \(count)")
            }
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(on ? Theme.accent : Theme.chip, in: Capsule())
            .foregroundStyle(on ? Color.white : Color.primary)
        }
        .buttonStyle(.pressable)
    }

    private var chips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("Все", favorites.items.count, filter == nil && folderFilter == nil) { filter = nil; folderFilter = nil }
                // пустые списки не показываем (кроме выбранного)
                ForEach(ListStatus.allCases.filter { st in filter == st || favorites.items.contains { meta.status($0) == st } }, id: \.self) { st in
                    chip(st.title(book: book), favorites.items.filter { meta.status($0) == st }.count, filter == st, dot: st.color) {
                        filter = st
                        folderFilter = nil
                    }
                    .contextMenu {
                        Button {
                            renameText = st.title(book: book)
                            renaming = st
                        } label: { Label("Переименовать", systemImage: "pencil") }
                        if FavNames.get(st, book: book) != nil {
                            Button {
                                FavNames.set(st, book: book, nil)
                                namesTick += 1
                            } label: { Label("Вернуть название", systemImage: "arrow.uturn.backward") }
                        }
                    }
                }
                // свои папки с сайта — после статусов
                ForEach(siteFolders.current.filter { !$0.ids.isEmpty || folderFilter == $0.id }) { f in
                    let have = Set(favorites.items.map { $0.id })
                    chip(f.name, f.ids.filter { have.contains($0) }.count, folderFilter == f.id,
                         dot: folderStyles.style(f.id)?.color ?? (f.name.lowercased().contains("любим") ? Color(red: 1, green: 0.42, blue: 0.62) : Theme.accent)) {
                        folderFilter = f.id
                        filter = nil
                    }
                }
            }
            .padding(.horizontal, 14)
        }
    }

    /// Пришли из профиля по нажатию на плитку списка
    private func applyPending() {
        if favRouter.pendingFavStatus != nil || favRouter.pendingFavFolder != nil {
            filter = favRouter.pendingFavStatus
            folderFilter = favRouter.pendingFavFolder
            favRouter.pendingFavStatus = nil
            favRouter.pendingFavFolder = nil
        }
    }

    private func refresh(force: Bool) async {
        refreshing = true
        await SiteListSync.syncIfDue(force: force)
        await FavUpdater.refresh(favorites.items, force: force)
        refreshing = false
    }

    /// Где остановился: последняя открытая глава/серия, иначе сколько всего вышло
    private func cardSubtitle(_ a: Anime) -> String? {
        if let h = history.items.first(where: { $0.anime.id == a.id }), !h.episodeTitle.isEmpty { return h.episodeTitle }
        if let n = meta.items[FavMetaStore.key(a)]?.count, n > 0 { return book ? "\(n) гл." : "\(n) эп." }
        return nil
    }

    /// Прочитано глав из вышедших (для манги и ранобэ)
    private func cardProgress(_ a: Anime) -> Double? {
        guard book, let total = meta.items[FavMetaStore.key(a)]?.count, total > 0 else { return nil }
        let done = readStore.read[String(a.readKey)]?.count ?? 0
        return done > 0 ? Double(done) / Double(total) : nil
    }

    private func headerButton(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.headline)
            .foregroundStyle(Theme.accent)
            .frame(width: 44, height: 44)
            .glassShape(Circle())
    }

    /// Шапка как в «Каталоге»: заголовок слева, кнопки на той же строке
    private var header: some View {
        HStack(spacing: 10) {
            Text("Избранное").font(.largeTitle.bold())
            Spacer()
            Button { showNew = true } label: {
                headerButton(meta.totalNew(favorites.items) > 0 ? "bell.badge.fill" : "bell")
            }
            .buttonStyle(.pressable)
            Menu {
                Picker("Сортировка", selection: $sortRaw) {
                    ForEach(FavSort.allCases, id: \.rawValue) { o in
                        Text(o.title).tag(o.rawValue)
                    }
                }
            } label: { headerButton("arrow.up.arrow.down") }
        }
        .padding(.horizontal, 14)
        .padding(.top, 4)
    }

    @ViewBuilder
    private var continueDestination: some View {
        if let a = continueAnime {
            if book {
                NovelDetailView(novel: Novel(a), autoContinue: true)
            } else {
                DetailView(anime: a, autoContinue: true)
            }
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    header
                    if !favorites.items.isEmpty { chips }
                    if let e = SiteListSync.lastError[LibSite.current.key], !refreshing {
                        Label("Списки с сайта не подтянулись: \(e). Потяни вниз, чтобы повторить.", systemImage: "exclamationmark.arrow.triangle.2.circlepath")
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 18)
                    }
                    if sort == .updated, !favorites.items.isEmpty,
                       favorites.items.allSatisfy({ meta.updateDate($0) == nil }) {
                        Text(refreshing ? "Проверяю обновления…"
                             : "Сайт не сообщил даты выхода: порядок по обновлению появится, когда приложение заметит новые серии или главы.")
                            .font(.caption2).foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                    }
                    if favorites.items.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: "heart.slash").font(.largeTitle).foregroundStyle(.secondary)
                            Text("Пока пусто.\nОткройте тайтл и нажмите сердечко.")
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                        .padding(.top, 100)
                    } else if visible.isEmpty {
                        Text("В этом списке пока пусто.\nНажми значок ярлыка на обложке, чтобы задать статус.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 60)
                    }
                    LazyVGrid(columns: columns, spacing: 18) {
                        ForEach(visible) { anime in
                            FavCard(anime: anime, status: meta.status(anime), book: book, newCount: meta.newCount(anime),
                                    subtitle: cardSubtitle(anime), progress: cardProgress(anime),
                                    onStatus: { st in
                                        meta.setStatus(anime, st)
                                        Haptics.select()
                                    },
                                    onContinue: {
                                        Haptics.tap()
                                        continueAnime = anime
                                        pushContinue = true
                                    })
                        }
                    }
                    .padding(.horizontal, 14)
                    Color.clear.frame(height: 110)
                }
                .padding(.top, 6)
            }
            .refreshable { await refresh(force: true) }
            .statusBarBlur()
            .task { await refresh(force: false) }
            .onAppear { applyPending() }
            .onChange(of: favRouter.tab) { _, _ in applyPending() }
            .background(AppBackground())
            .alert("Название папки", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Название", text: $renameText)
                Button("Сохранить") {
                    if let st = renaming { FavNames.set(st, book: book, renameText); namesTick += 1 }
                    renaming = nil
                }
                Button("Отмена", role: .cancel) { renaming = nil }
            } message: {
                Text("Папка «\(renaming?.defaultTitle(book: book) ?? "")» будет называться так. Фильтр и статус не изменятся.")
            }
            .id(namesTick)
            .toolbar(.hidden, for: .navBar)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .navigationDestination(isPresented: $pushContinue) { continueDestination }
            .navigationDestination(isPresented: $showNew) { NewInFavoritesView() }
        }
    }
}
