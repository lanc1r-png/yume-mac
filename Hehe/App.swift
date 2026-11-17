import SwiftUI
import AVKit
import AVFoundation
import Foundation
import WebKit
import Security
import Network
import ImageIO
import UniformTypeIdentifiers

// MARK: - Тема и общие элементы дизайна

enum Theme {
    static let defaultAccentHex = "A87AFF"
    /// Акцентный цвет берётся из настроек и меняется на лету.
    private static var cachedHex = ""
    private static var cachedColor = Color(hex: defaultAccentHex)

    /// Цвета, которые сами подстраиваются под светлую и тёмную тему.
    static let card = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06) })
    static let chip = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08) })
    static let base = Color(uiColor: .systemBackground)

    static var accent: Color {
        let hex = UserDefaults.standard.string(forKey: "accent.hex") ?? defaultAccentHex
        if hex != cachedHex {
            cachedHex = hex
            cachedColor = Color(hex: hex)
        }
        return cachedColor
    }
}

/// Сайт сети Lib, с которым сейчас работает приложение (аниме или ранобэ).
struct LibSite: Hashable {
    let key: String
    let id: String
    let referer: String
    let origin: String
    let apiPath: String
    let postType: String
    let title: String

    var isRanobe: Bool { key == "ranobe" }
    var isManga: Bool { key == "manga" }
    /// Ранобэ и манга устроены одинаково: тайтл, тома и главы.
    var isBook: Bool { key != "anime" }

    static let anime = LibSite(key: "anime", id: "5", referer: "https://v5.animelib.org/",
                               origin: "https://v5.animelib.org", apiPath: "/anime",
                               postType: "anime", title: "Аниме")
    static let ranobe = LibSite(key: "ranobe", id: "3", referer: "https://ranobelib.me/",
                                origin: "https://ranobelib.me", apiPath: "/manga",
                                postType: "manga", title: "Ранобэ")

    static let manga = LibSite(key: "manga", id: "1", referer: "https://mangalib.me/",
                               origin: "https://mangalib.me", apiPath: "/manga",
                               postType: "manga", title: "Манга")

    static var current: LibSite {
        switch UserDefaults.standard.string(forKey: "set.platform") {
        case "ranobe": return .ranobe
        case "manga": return .manga
        default: return .anime
        }
    }
}

enum Settings {
    static func bool(_ key: String, _ def: Bool) -> Bool {
        (UserDefaults.standard.object(forKey: key) as? Bool) ?? def
    }
}

extension Color {
    init(hex: String) {
        let t = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var v: UInt64 = 0
        Scanner(string: t).scanHexInt64(&v)
        self.init(red: Double((v >> 16) & 255) / 255,
                  green: Double((v >> 8) & 255) / 255,
                  blue: Double(v & 255) / 255)
    }

    var hexString: String {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return String(format: "%02X%02X%02X", Int(r * 255), Int(g * 255), Int(b * 255))
    }
}

struct AppBackground: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            Theme.base
            RadialGradient(colors: [Theme.accent.opacity(dark ? 0.35 : 0.22), .clear],
                           center: .topLeading, startRadius: 20, endRadius: 460)
            RadialGradient(colors: [Color.pink.opacity(dark ? 0.18 : 0.10), .clear],
                           center: .bottomTrailing, startRadius: 20, endRadius: 460)
        }
        .ignoresSafeArea()
    }
}

struct Chip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button { Haptics.select(); action() } label: {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chip), in: Capsule())
        }
        .buttonStyle(.pressable)
    }
}

struct Pill: View {
    let icon: String
    let text: String
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Theme.chip, in: Capsule())
    }
}

/// Раскладка «теги в несколько строк».
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0, width: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > maxW && x > 0 { y += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
            width = max(width, x - spacing)
        }
        return CGSize(width: width, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX { y += rowH + spacing; x = bounds.minX; rowH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}

// MARK: - Models

struct Envelope<T: Decodable>: Decodable {
    let data: T
    let meta: PageMeta?
}

struct PageMeta: Decodable {
    let hasNextPage: Bool?
    let currentPage: Int?

    enum CodingKeys: String, CodingKey {
        case hasNextPage = "has_next_page"
        case currentPage = "current_page"
    }
}

struct NamedItem: Codable, Hashable {
    let id: Int?
    let name: String?
    let label: String?
    let slug: String?
    var title: String { name ?? label ?? "" }

    enum CodingKeys: String, CodingKey { case id, name, label, slug = "slug_url" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .id)).flatMap { Int($0) }
        name = try? c.decode(String.self, forKey: .name)
        label = try? c.decode(String.self, forKey: .label)
        slug = try? c.decode(String.self, forKey: .slug)
    }
}

struct RichNode: Decodable {
    let type: String?
    let text: String?
    let content: [RichNode]?

    var plainText: String {
        if type == "text" { return text ?? "" }
        let inner = (content ?? []).map { $0.plainText }.joined()
        switch type {
        case "paragraph", "heading": return inner + "\n"
        case "hardBreak": return "\n"
        default: return inner
        }
    }
}

struct RichText: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            text = s
        } else if let node = try? c.decode(RichNode.self) {
            text = node.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
    }
}

struct Cover: Codable, Hashable {
    let thumbnail: String?
    let `default`: String?
    let md: String?
}

struct RatingBox: Decodable {
    let average: String?
    enum K: String, CodingKey { case average }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let s = try? c.decode(String.self, forKey: .average) { average = s }
        else if let x = try? c.decode(Double.self, forKey: .average) { average = String(format: "%.1f", x) }
        else { average = nil }
    }
}

struct Anime: Codable, Identifiable, Hashable {
    private enum RatingKeys: String, CodingKey { case rating }

    let id: Int
    let name: String?
    let rusName: String?
    let engName: String?
    let slugUrl: String?
    let cover: Cover?
    let summary: String?
    let genres: [NamedItem]?
    let authors: [NamedItem]?
    let otherNames: [String]?
    let episodesCount: Int?
    let rateAvg: String?
    let status: NamedItem?
    let type: NamedItem?
    let ageRestriction: NamedItem?
    let releaseDateString: String?

    var displayTitle: String {
        if let r = rusName, !r.isEmpty { return r }
        return name ?? engName ?? "Без названия"
    }
    var imageURL: URL? {
        let s = cover?.thumbnail ?? cover?.md ?? cover?.default
        return s.flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, genres, authors, cover, status, type
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugUrl = "slug_url"
        case otherNames
        case episodesCount = "episodes_count"
        case rateAvg = "rate_avg"
        case ageRestriction
        case releaseDateString
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        rusName = try? c.decode(String.self, forKey: .rusName)
        engName = try? c.decode(String.self, forKey: .engName)
        slugUrl = try? c.decode(String.self, forKey: .slugUrl)
        cover = try? c.decode(Cover.self, forKey: .cover)
        summary = (try? c.decode(RichText.self, forKey: .summary))?.text
        genres = try? c.decode([NamedItem].self, forKey: .genres)
        authors = try? c.decode([NamedItem].self, forKey: .authors)
        otherNames = try? c.decode([String].self, forKey: .otherNames)
        episodesCount = try? c.decode(Int.self, forKey: .episodesCount)
        status = try? c.decode(NamedItem.self, forKey: .status)
        type = try? c.decode(NamedItem.self, forKey: .type)
        ageRestriction = try? c.decode(NamedItem.self, forKey: .ageRestriction)
        releaseDateString = try? c.decode(String.self, forKey: .releaseDateString)
        if let s = try? c.decode(String.self, forKey: .rateAvg) { rateAvg = s }
        else if let d = try? c.decode(Double.self, forKey: .rateAvg) { rateAvg = String(format: "%.1f", d) }
        else if let rc = try? decoder.container(keyedBy: RatingKeys.self),
                let rb = try? rc.decode(RatingBox.self, forKey: .rating),
                let av = rb.average { rateAvg = av }
        else { rateAvg = nil }
    }
}

struct EpisodeShort: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let number: String?
    let season: String?
    let date: String?

    var title: String {
        let n = number.map { "Серия \($0)" } ?? "Серия"
        if let name, !name.isEmpty { return "\(n) · \(name)" }
        return n
    }

    enum CodingKeys: String, CodingKey { case id, name, number, season, date = "created_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        season = (try? c.decode(String.self, forKey: .season))
            ?? (try? c.decode(Int.self, forKey: .season)).map(String.init)
        number = (try? c.decode(String.self, forKey: .number))
            ?? (try? c.decode(Int.self, forKey: .number)).map(String.init)
        date = try? c.decode(String.self, forKey: .date)
    }
}

struct VideoQuality: Decodable, Hashable {
    let href: String?
    let quality: Int?
}

struct VideoInfo: Decodable, Hashable {
    let quality: [VideoQuality]?
}

struct SubtitleInfo: Decodable, Hashable {
    let src: String?
    let format: String?
}

struct Team: Decodable, Hashable {
    let name: String?
}

struct EpisodePlayer: Decodable, Hashable {
    let id: Int?
    let player: String?
    let team: Team?
    let translationType: NamedItem?
    let video: VideoInfo?
    let subtitles: [SubtitleInfo]?
    let src: String?

    var isNative: Bool { (player ?? "").lowercased() == "animelib" }
    var label: String {
        let t = team?.name ?? "—"
        let k = translationType?.title ?? ""
        return k.isEmpty ? t : "\(t) (\(k))"
    }

    enum CodingKeys: String, CodingKey {
        case id, player, team, video, subtitles, src
        case translationType = "translation_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(Int.self, forKey: .id)
        player = try? c.decode(String.self, forKey: .player)
        team = try? c.decode(Team.self, forKey: .team)
        translationType = try? c.decode(NamedItem.self, forKey: .translationType)
        video = try? c.decode(VideoInfo.self, forKey: .video)
        subtitles = try? c.decode([SubtitleInfo].self, forKey: .subtitles)
        src = try? c.decode(String.self, forKey: .src)
    }
}

struct EpisodeDetail: Decodable {
    let id: Int
    let players: [EpisodePlayer]?
}

struct VideoServer: Decodable, Hashable {
    let id: String?
    let label: String?
    let url: String?
}

struct Constants: Decodable {
    let videoServers: [VideoServer]?
}

struct PlayableVariant: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let subtitle: URL?
    var isWeb = false
    var kodik = false
    var player = ""
    var options: [PlayableVariant] = []
    var alts: [URL] = []
}

struct FilterOptions {
    var genres: [NamedItem] = []
    var tags: [NamedItem] = []
    var types: [NamedItem] = []
    var statuses: [NamedItem] = []
    var isEmpty: Bool { genres.isEmpty && tags.isEmpty && types.isEmpty && statuses.isEmpty }
}

// MARK: - API
enum APIError: LocalizedError {
    case badURL, http(Int, String), noVideo
    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректный адрес запроса"
        case .http(let c, let body): return "Сервер вернул ошибку \(c): \(body)"
        case .noVideo: return "Для этой серии нет доступного видео"
        }
    }
}

struct CatalogFilter: Equatable {
    var query: String = ""
    var sortBy: SortOption = .rating
    var genres: Set<Int> = []
    var tags: Set<Int> = []
    var types: Set<Int> = []
    var statuses: Set<Int> = []

    var activeCount: Int { genres.count + tags.count + types.count + statuses.count }

    enum SortOption: String, CaseIterable, Identifiable {
        case rating = "rate_avg"
        case views = "views"
        case newest = "created_at"
        case lastEpisode = "last_episode_at"
        case name = "name"
        var id: String { rawValue }

        /// Названия полей сортировки у разных сайтов отличаются, пробуем по очереди.
        func aliases(_ site: LibSite) -> [String] {
            guard site.isBook else { return [rawValue] }
            switch self {
            case .rating: return ["rate_avg", "rating_score"]
            case .views: return ["views"]
            case .newest: return ["created_at"]
            case .lastEpisode: return ["last_chapter_at", "last_episode_at"]
            case .name: return ["name", "rus_name"]
            }
        }

        func label(_ ranobe: Bool) -> String {
            if ranobe && self == .lastEpisode { return "Свежие главы" }
            if ranobe && self == .views { return "По чтению" }
            return title
        }
        var title: String {
            switch self {
            case .rating: return "По рейтингу"
            case .views: return "По просмотрам"
            case .newest: return "Новинки"
            case .lastEpisode: return "Свежие серии"
            case .name: return "По названию"
            }
        }
    }
}

actor AnimelibAPI {
    static let shared = AnimelibAPI()

    private let apiURL = "https://api.cdnlibs.org/api"
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var cachedServers: [VideoServer]?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    nonisolated var siteHeaders: [String: String] {
        let site = LibSite.current
        return ["Referer": site.referer, "Origin": site.origin, "Site-Id": site.id]
    }

    nonisolated var playbackHeaders: [String: String] {
        ["Referer": "https://v5.animelib.org/", "Origin": "https://v5.animelib.org"]
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [], as type: T.Type) async throws -> T {
        guard var comps = URLComponents(string: apiURL + path) else { throw APIError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        for (k, v) in siteHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw APIError.http(http.statusCode, body)
        }
        return try decoder.decode(T.self, from: data)
    }

    func catalog(filter: CatalogFilter, page: Int) async throws -> (items: [Anime], hasNext: Bool) {
        let site = LibSite.current
        var lastError: Error = APIError.badURL
        for sort in filter.sortBy.aliases(site) {
            for withSite in [true, false] {
                do {
                    return try await fetchCatalog(filter: filter, page: page, withSite: withSite, sort: sort, site: site)
                } catch APIError.http(let code, let body) where code == 422 || code == 400 {
                    lastError = APIError.http(code, body)
                }
            }
        }
        throw lastError
    }

    private func fetchCatalog(filter: CatalogFilter, page: Int, withSite: Bool, sort: String, site: LibSite) async throws -> (items: [Anime], hasNext: Bool) {
        var q: [URLQueryItem] = [
            .init(name: "page", value: String(page)),
            .init(name: "sort_by", value: sort),
            .init(name: "sort_type", value: "desc"),
        ]
        if withSite { q.append(.init(name: "site_id[]", value: site.id)) }
        let text = filter.query.trimmingCharacters(in: .whitespaces)
        if !text.isEmpty { q.append(.init(name: "q", value: text)) }
        for id in filter.genres.sorted() { q.append(.init(name: "genres[]", value: String(id))) }
        for id in filter.tags.sorted() { q.append(.init(name: "tags[]", value: String(id))) }
        for id in filter.types.sorted() { q.append(.init(name: "types[]", value: String(id))) }
        for id in filter.statuses.sorted() { q.append(.init(name: "status[]", value: String(id))) }
        let r = try await get(site.apiPath, query: q, as: Envelope<[Anime]>.self)
        let hasNext = r.meta?.hasNextPage ?? !r.data.isEmpty
        return (r.data, hasNext)
    }

    private var authorParam: [String: String] = [:]

    /// Все тайтлы одного автора. Имя параметра фильтра сайт нигде не описывает,
    /// поэтому пробуем варианты (по id и по slug) и принимаем тот, что реально меняет выдачу.
    func byAuthor(_ id: Int, slug: String?, page: Int) async throws -> (items: [Anime], hasNext: Bool) {
        let site = LibSite.current
        func run(_ extra: [URLQueryItem]) async throws -> (items: [Anime], hasNext: Bool) {
            for withSite in [true, false] {
                var q: [URLQueryItem] = [
                    .init(name: "page", value: String(page)),
                    .init(name: "sort_by", value: "rate_avg"),
                    .init(name: "sort_type", value: "desc")
                ] + extra
                if withSite { q.append(.init(name: "site_id[]", value: site.id)) }
                do {
                    let r = try await get(site.apiPath, query: q, as: Envelope<[Anime]>.self)
                    return (r.data, r.meta?.hasNextPage ?? !r.data.isEmpty)
                } catch APIError.http(let code, _) where (code == 422 || code == 400) && withSite {
                    continue
                }
            }
            throw APIError.badURL
        }
        // Уже найденный параметр: имя и вид значения («id» или «slug»).
        if let known = authorParam[site.key] {
            let parts = known.split(separator: "|").map(String.init)
            let value = (parts.count > 1 && parts[1] == "slug") ? (slug ?? String(id)) : String(id)
            return try await run([.init(name: parts[0], value: value)])
        }
        let baseline = (try? await run([]))?.items.map { $0.id } ?? []
        let names = ["authors[]", "people[]", "author[]", "peoples[]", "persons[]", "authors", "people",
                     "author", "person", "artists[]", "creators[]", "staff[]", "people_id", "author_id"]
        var values: [(String, String)] = [("id", String(id))]
        if let sl = slug, !sl.isEmpty { values.append(("slug", sl)) }
        var log: [String] = []
        for (kind, value) in values {
            for name in names {
                do {
                    let r = try await run([.init(name: name, value: value)])
                    let ids = r.items.map { $0.id }
                    if !ids.isEmpty && ids != baseline {
                        authorParam[site.key] = "\(name)|\(kind)"
                        return r
                    }
                    log.append("\(name)=\(kind): \(ids.isEmpty ? "пусто" : "как в общем списке")")
                } catch APIError.http(let code, _) {
                    log.append("\(name)=\(kind): \(code)")
                } catch {
                    log.append("\(name)=\(kind): сбой")
                }
            }
        }
        // Подсказка для разбора: как выглядит страница автора на сервере.
        let key = (slug?.isEmpty == false) ? slug! : String(id)
        let sample = await rawText("/people/\(key)")
        throw APIError.http(404, "Фильтр по автору не сработал.\n" + log.prefix(12).joined(separator: "; ")
                            + "\n/people/\(key): " + String(sample.prefix(260)))
    }

    /// Списки жанров, тегов, типов и статусов берём у сайта.
    func filterOptions() async -> FilterOptions {
        var o = FilterOptions()
        o.genres = await constantList("genres", keys: ["genres"])
        o.tags = await constantList("tags", keys: ["tags"])
        o.types = await constantList("types", keys: ["types", "type"])
        o.statuses = await constantList("status", keys: ["status", "statuses"])
        return o
    }

    private func constantList(_ field: String, keys: [String]) async -> [NamedItem] {
        let q = [URLQueryItem(name: "fields[]", value: field)]
        guard let dict = try? await get("/constants", query: q, as: Envelope<[String: [NamedItem]]>.self).data else {
            return []
        }
        var list: [NamedItem] = []
        for k in keys {
            if let v = dict[k] { list = v; break }
        }
        if list.isEmpty { list = dict.values.first ?? [] }
        return list.filter { $0.id != nil && !$0.title.isEmpty }
    }

    func rawData(_ path: String, query: [URLQueryItem] = [], token: String? = nil,
                 method: String = "GET", json: [String: Any]? = nil) async throws -> Data {
        guard var comps = URLComponents(string: apiURL + path) else { throw APIError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        for (k, v) in siteHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        req.httpMethod = method
        if let j = json {
            req.httpBody = try JSONSerialization.data(withJSONObject: j)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data.prefix(300), encoding: .utf8) ?? "")
        }
        return data
    }

    func rawText(_ path: String, query: [URLQueryItem] = [], token: String? = nil) async -> String {
        guard var comps = URLComponents(string: apiURL + path) else { return "bad url" }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { return "bad url" }
        var req = URLRequest(url: url)
        for (k, v) in siteHeaders { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        if let t = token { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        do {
            let (data, resp) = try await session.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            return "HTTP \(code)\n" + (String(data: data.prefix(1800), encoding: .utf8) ?? "")
        } catch {
            return "Ошибка: \(error.localizedDescription)"
        }
    }

    func details(slug: String) async throws -> Anime {
        let base = ["summary", "genres", "authors", "otherNames"]
        func query(_ f: [String]) -> [URLQueryItem] { f.map { URLQueryItem(name: "fields[]", value: $0) } }
        let path = LibSite.current.apiPath + "/" + slug
        do {
            return try await get(path, query: query(base + ["rate_avg"]), as: Envelope<Anime>.self).data
        } catch {
            return try await get(path, query: query(base), as: Envelope<Anime>.self).data
        }
    }

    func episodes(animeID: Int) async throws -> [EpisodeShort] {
        let q = [URLQueryItem(name: "anime_id", value: String(animeID))]
        return try await get("/episodes", query: q, as: Envelope<[EpisodeShort]>.self).data
    }

    func episodeDetail(id: Int) async throws -> EpisodeDetail {
        try await get("/episodes/\(id)", as: Envelope<EpisodeDetail>.self).data
    }

    private(set) var variantNote = ""

    private func videoServers() async throws -> [VideoServer] {
        if let c = cachedServers, !c.isEmpty { return c }
        let q = [URLQueryItem(name: "fields[]", value: "videoServers")]
        let data = try await rawData("/constants", query: q)
        guard let root = J.obj(data) as? [String: Any] else { return [] }
        let d = (root["data"] as? [String: Any]) ?? root
        let arr = (d["videoServers"] as? [[String: Any]]) ?? []
        let list = arr.compactMap { e -> VideoServer? in
            guard let u = J.str(e["url"]) else { return nil }
            return VideoServer(id: J.str(e["id"]), label: J.str(e["label"]), url: u)
        }
        if !list.isEmpty { cachedServers = list }
        return list
    }

    func variants(episodeID: Int) async throws -> [PlayableVariant] {
        let token = Keychain.get("lib.token")
        async let dataTask = rawData("/episodes/\(episodeID)", token: token)
        async let serversTask = videoServers()
        let data = try await dataTask
        let servers = (try? await serversTask) ?? []
        let mainServer = servers.first { ($0.id ?? "").lowercased().contains("main") } ?? servers.first
        let base: String? = mainServer?.url
        let otherBases: [String] = servers.compactMap { $0.url }.filter { $0 != base }

        guard let root = J.obj(data) as? [String: Any] else { throw APIError.badURL }
        let d = (root["data"] as? [String: Any]) ?? root
        let players = (d["players"] as? [[String: Any]]) ?? []

        var native: [PlayableVariant] = []
        var web: [PlayableVariant] = []
        var seen: [String: Int] = [:]
        for p in players {
            let name = J.str(p["player"]) ?? ""
            seen[name, default: 0] += 1
            let team = J.str((p["team"] as? [String: Any])?["name"]) ?? "—"
            let tt = p["translation_type"] as? [String: Any]
            let kind = J.str(tt?["label"]) ?? J.str(tt?["title"]) ?? J.str(tt?["name"]) ?? ""
            let label = kind.isEmpty ? team : "\(team) (\(kind))"

            if name.lowercased() == "animelib" {
                guard let base = base else { continue }
                let video = p["video"] as? [String: Any]
                let list = (video?["quality"] as? [[String: Any]]) ?? []
                let sub: URL? = ((p["subtitles"] as? [[String: Any]])?.first).flatMap { J.str($0["src"]) }
                    .flatMap { URL(string: absolute($0, base: base)) }
                var options: [PlayableVariant] = []
                for q in list.sorted(by: { (J.int($0["quality"]) ?? 0) > (J.int($1["quality"]) ?? 0) }) {
                    guard let href = J.str(q["href"]), let url = URL(string: absolute(href, base: base)) else { continue }
                    let h = J.int(q["quality"]).map { "\($0)p" } ?? "—"
                    var opt = PlayableVariant(title: h, url: url, subtitle: sub)
                    opt.alts = otherBases.compactMap { URL(string: absolute(href, base: $0)) }
                    options.append(opt)
                }
                guard let best = options.first else { continue }
                var v = PlayableVariant(title: label, url: best.url, subtitle: sub)
                v.player = "Animelib"
                v.options = options
                native.append(v)
            } else if let src = J.str(p["src"]) {
                let full = src.hasPrefix("//") ? "https:" + src : src
                if let url = URL(string: full) {
                    let isK = full.contains("kodik")
                    var v = PlayableVariant(title: "\(label) · \(name.isEmpty ? "Плеер" : name)", url: url,
                                            subtitle: nil, isWeb: true, kodik: isK)
                    v.player = name.isEmpty ? "Плеер" : name
                    web.append(v)
                }
            }
        }

        var note = ""
        if native.isEmpty {
            let list = seen.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: ", ")
            if seen.keys.contains(where: { $0.lowercased() == "animelib" }) {
                note = base == nil
                    ? "Animelib: адрес видео-сервера не получен (в ответе: \(list))"
                    : "Animelib: в ответе есть плеер, но без ссылок на видео"
            } else {
                note = "Animelib: сервер не отдал этот плеер (в ответе: \(list.isEmpty ? "пусто" : list))"
            }
        }
        variantNote = note

        let result = native + web
        if result.isEmpty { throw APIError.noVideo }
        return result
    }

    private func absolute(_ href: String, base: String) -> String {
        if href.hasPrefix("http") { return href }
        if href.hasPrefix("//") { return "https:" + href }
        let b = base.hasSuffix("/") ? String(base.dropLast()) : base
        let h = href.hasPrefix("/") ? href : "/" + href
        return b + "/" + h
    }
}

enum Haptics {
    private static var on: Bool { Settings.bool("set.haptics", true) }
    static func tap() { if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    static func select() { if on { UISelectionFeedbackGenerator().selectionChanged() } }
    static func success() { if on { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func bump() { if on { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
}

// MARK: - Mac (Catalyst): общие помощники
enum KeepAwake {
    private static var token: NSObjectProtocol?
    static func set(_ on: Bool) {
        #if targetEnvironment(macCatalyst)
        if on {
            if token == nil {
                token = ProcessInfo.processInfo.beginActivity(
                    options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Yume: чтение и просмотр")
            }
        } else if let t = token {
            ProcessInfo.processInfo.endActivity(t)
            token = nil
        }
        #else
        UIApplication.shared.isIdleTimerDisabled = on
        #endif
    }
}

enum Platform {
    /// Нужна ли своя кнопка закрытия у родного полноэкранного плеера.
    static var showsOwnCloseButton: Bool {
        #if targetEnvironment(macCatalyst)
        return true
        #else
        if #unavailable(iOS 26) { return true } else { return false }
        #endif
    }
}

enum MacWindow {
    static func configure() {
        #if targetEnvironment(macCatalyst)
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            ws.sizeRestrictions?.minimumSize = CGSize(width: 900, height: 600)
            ws.titlebar?.titleVisibility = .hidden
        }
        #endif
    }
}

/// Невидимая кнопка, которая даёт горячую клавишу (стрелки, пробел, Esc).
struct KeyShortcut: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let action: () -> Void

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], action: @escaping () -> Void) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

extension View {
    @ViewBuilder
    func chromeStatusBar(_ hidden: Bool) -> some View {
        #if targetEnvironment(macCatalyst)
        self
        #else
        self.statusBarHidden(hidden)
        #endif
    }
}

/// Адрес тайтла на сайте (для «Поделиться»).
func titleURL(_ a: Anime) -> URL? {
    guard let slug = a.slugUrl else { return nil }
    switch LibSite.current.key {
    case "ranobe": return URL(string: "https://ranobelib.me/ru/book/\(slug)")
    case "manga": return URL(string: "https://mangalib.me/ru/manga/\(slug)")
    default: return URL(string: "https://animelib.org/ru/anime/\(slug)")
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}

// MARK: - Images (с заголовком Referer)
final class ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 140 * 1024 * 1024
        c.countLimit = 500
        return c
    }()

    static func key(_ url: URL, _ px: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(px))" as NSString }

    static func store(_ img: UIImage, _ key: NSString) {
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        shared.setObject(img, forKey: key, cost: cost)
    }
}

/// Загрузка картинок: общий дисковый кэш, один запрос на один адрес,
/// декодирование и уменьшение вне главного потока.
actor ImageLoader {
    static let shared = ImageLoader()
    private let session: URLSession
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 500 * 1024 * 1024, diskPath: "hehe-images")
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func clearDisk() { session.configuration.urlCache?.removeAllCachedResponses() }

    func image(_ url: URL, referer: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))"
        if let t = inflight[key] { return await t.value }
        let session = self.session
        let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
            for attempt in 0..<3 {
                if Task.isCancelled { return nil }
                var req = URLRequest(url: url)
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (data, resp) = try? await session.data(for: req),
                   (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                   let img = ImageLoader.downsample(data, maxPixel: maxPixel) {
                    return img
                }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
            return nil
        }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        return r
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension ImageLoader {
    /// Заранее подгружает обложки, которые ещё не показаны на экране.
    nonisolated static func prefetch(_ urls: [URL], maxPixel: CGFloat = 480) {
        let list = Array(urls.prefix(40))
        guard !list.isEmpty else { return }
        let referer = LibSite.current.referer
        Task.detached(priority: .utility) {
            var start = 0
            while start < list.count {
                let chunk = Array(list[start..<min(start + 4, list.count)])
                start += 4
                await withTaskGroup(of: Void.self) { group in
                    for u in chunk {
                        group.addTask {
                            let key = ImageCache.key(u, maxPixel)
                            if ImageCache.shared.object(forKey: key) != nil { return }
                            if let img = await ImageLoader.shared.image(u, referer: referer, maxPixel: maxPixel) {
                                ImageCache.store(img, key)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Анимированные картинки (GIF, WebP, APNG)
enum AnimatedLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60_000_000
        return c
    }()

    static func cached(_ url: URL, _ px: CGFloat) -> UIImage? {
        cache.object(forKey: "\(url.absoluteString)#\(Int(px))" as NSString)
    }

    static func load(_ url: URL, maxPixel: CGFloat, referer: String) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))" as NSString
        if let c = cache.object(forKey: key) { return c }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            var req = URLRequest(url: url)
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return AnimatedLoader.decode(data, maxPixel: maxPixel)
        }.value
        if let img {
            let frames = max(1, img.images?.count ?? 1)
            cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4) * frames)
        }
        return img
    }

    nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if n <= 1 {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        // Ключи ImageIO для GIF, WebP и APNG записаны строками: так они есть во всех версиях SDK.
        let dicts = ["{GIF}", "{WebP}", "{PNG}"]
        func delay(_ i: Int) -> Double {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any] else { return 0.1 }
            for name in dicts {
                if let d = props[name] as? [String: Any] {
                    let v = (d["UnclampedDelayTime"] as? Double) ?? (d["DelayTime"] as? Double) ?? 0
                    if v > 0 || d["DelayTime"] != nil || d["UnclampedDelayTime"] != nil {
                        return v < 0.02 ? 0.1 : v
                    }
                }
            }
            return 0.1
        }
        // Слишком длинные анимации прореживаем, чтобы не съесть память.
        let step = Int((Double(n) / 90).rounded(.up))
        var frames: [UIImage] = []
        var total = 0.0
        var i = 0
        while i < n {
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                frames.append(UIImage(cgImage: cg))
            }
            for j in i..<min(i + step, n) { total += delay(j) }
            i += step
        }
        if frames.isEmpty { return nil }
        if frames.count == 1 { return frames[0] }
        return UIImage.animatedImage(with: frames, duration: max(total, 0.4))
    }
}

struct AnimatedImageView: UIViewRepresentable {
    let image: UIImage

    func makeUIView(context: Context) -> UIImageView {
        let v = UIImageView()
        v.contentMode = .scaleAspectFill
        v.clipsToBounds = true
        v.setContentHuggingPriority(.defaultLow, for: .horizontal)
        v.setContentHuggingPriority(.defaultLow, for: .vertical)
        v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        v.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        v.image = image
        return v
    }

    func updateUIView(_ v: UIImageView, context: Context) {
        if v.image !== image { v.image = image }
    }
}

/// Как RemoteImage, но GIF и другие анимации воспроизводятся.
struct AnimatedRemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 400
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image { AnimatedImageView(image: image).transition(.opacity) }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                if let c = AnimatedLoader.cached(url, maxPixel) { image = c; return }
                image = nil
                if let img = await AnimatedLoader.load(url, maxPixel: maxPixel, referer: LibSite.current.referer) {
                    withAnimation(.easeOut(duration: 0.25)) { image = img }
                }
            }
    }
}

struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 480
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity)
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { failed = true; return }
        if url.isFileURL {
            if let img = UIImage(contentsOfFile: url.path) { image = img } else { failed = true }
            return
        }
        let key = ImageCache.key(url, maxPixel)
        if let cached = ImageCache.shared.object(forKey: key) { image = cached; failed = false; return }
        image = nil
        failed = false
        if let img = await ImageLoader.shared.image(url, referer: LibSite.current.referer, maxPixel: maxPixel) {
            ImageCache.store(img, key)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}

// MARK: - Favorites
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore(key: "favorites.v1")
    static let novels = FavoritesStore(key: "favorites.novels.v1")
    static let manga = FavoritesStore(key: "favorites.manga.v1")
    static var current: FavoritesStore {
        let site = LibSite.current
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

struct FavoritesView: View {
    @ObservedObject private var favorites: FavoritesStore = FavoritesStore.current
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if favorites.items.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "heart.slash").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Пока пусто.\nОткройте тайтл и нажмите сердечко.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.top, 100)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(favorites.items) { anime in
                        TitleLink(anime: anime) { AnimeCard(anime: anime) }
                            .buttonStyle(.pressable)
                    }
                }
                .padding(.horizontal, 14)
            }
            .background(AppBackground())
            .navigationTitle("Избранное")
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
        }
    }
}

// MARK: - Резервная копия (прогресс, избранное, история, настройки)
enum BackupManager {
    private static let prefixes = ["favorites", "history", "progress", "read", "search.", "set.",
                                   "accent.", "reader.", "manga.", "novel.", "off."]

    private static func allowed(_ key: String) -> Bool {
        prefixes.contains { key.hasPrefix($0) }
    }

    static var autoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yume-backup.plist")
    }

    static func snapshot() -> [String: Any] {
        let all = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return all.filter { allowed($0.key) }
    }

    static func data() -> Data? {
        let root: [String: Any] = ["app": "Yume", "version": 1, "date": Date(), "defaults": snapshot()]
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .xml, options: 0)
    }

    // Папка, выбранная пользователем (например, в iCloud Drive). Запоминается закладкой.
    private static let bmKey = "backup.folder.bookmark"

    private static func resolveFolder() -> URL? {
        guard let b = UserDefaults.standard.data(forKey: bmKey) else { return nil }
        var stale = false
        guard let u = try? URL(resolvingBookmarkData: b, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale, u.startAccessingSecurityScopedResource() {
            if let nb = try? u.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
                UserDefaults.standard.set(nb, forKey: bmKey)
            }
            u.stopAccessingSecurityScopedResource()
        }
        return u
    }

    static var folderName: String? { resolveFolder()?.lastPathComponent }

    static func setFolder(_ url: URL) -> Bool {
        let ok = url.startAccessingSecurityScopedResource()
        defer { if ok { url.stopAccessingSecurityScopedResource() } }
        guard let b = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) else { return false }
        UserDefaults.standard.set(b, forKey: bmKey)
        return writeAuto() != nil
    }

    static func clearFolder() { UserDefaults.standard.removeObject(forKey: bmKey) }

    static var lastFolderWrite: Date? {
        UserDefaults.standard.object(forKey: "backup.folder.date") as? Date
    }

    private static func writeToFolder(_ d: Data) {
        guard let target = resolveFolder() else { return }
        let ok = target.startAccessingSecurityScopedResource()
        defer { if ok { target.stopAccessingSecurityScopedResource() } }
        var err: NSError?
        var wrote = false
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &err) { u in
            wrote = (try? d.write(to: u)) != nil
        }
        UserDefaults.standard.set(!wrote, forKey: "backup.folder.fail")
        if wrote { UserDefaults.standard.set(Date(), forKey: "backup.folder.date") }
    }

    static var lastFolderFailed: Bool { UserDefaults.standard.bool(forKey: "backup.folder.fail") }

    /// Пишет копию в папку приложения и, если выбрана, в папку пользователя (iCloud Drive).
    @discardableResult
    static func writeAuto() -> URL? {
        guard let d = data() else { return nil }
        writeToFolder(d)
        do {
            try d.write(to: autoURL, options: .atomic)
            return autoURL
        } catch {
            return nil
        }
    }

    static var lastAuto: Date? {
        (try? FileManager.default.attributesOfItem(atPath: autoURL.path))?[.modificationDate] as? Date
    }

    /// Возвращает число восстановленных записей.
    static func restore(_ data: Data) -> Int? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (root["app"] as? String) == "Yume",
              let defs = root["defaults"] as? [String: Any] else { return nil }
        var n = 0
        for (k, v) in defs where allowed(k) {
            UserDefaults.standard.set(v, forKey: k)
            n += 1
        }
        return n
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ c: UIActivityViewController, context: Context) {}
}

// MARK: - Журнал запросов сайта (чтобы найти, как сайт хранит прогресс)
@MainActor
final class SiteLog: ObservableObject {
    @Published var lines: [String] = []

    func add(_ s: String) {
        if lines.count > 400 { lines.removeFirst(100) }
        lines.append(s)
    }
}

struct SiteWebView: UIViewRepresentable {
    let url: URL
    let log: SiteLog

    static let script = """
    (function(){
      if (window.__heheLog) return; window.__heheLog = true;
      function want(m, u){
        if (m !== 'GET') return true;
        return /(view|read|watch|progress|history|continue|last|chapter|episode)/i.test(String(u));
      }
      function send(m, u, b, s){
        try {
          window.webkit.messageHandlers.hlog.postMessage(JSON.stringify({
            m: m, u: String(u), b: b ? String(b).slice(0, 400) : '', s: s || 0
          }));
        } catch (e) {}
      }
      var of = window.fetch;
      if (of) window.fetch = function(a, o){
        var u = typeof a === 'string' ? a : (a && a.url);
        var m = ((o && o.method) || (a && a.method) || 'GET').toUpperCase();
        var b = o && o.body;
        var p = of.apply(this, arguments);
        p.then(function(r){ if (want(m, u)) send(m, u, b, r.status); }).catch(function(){});
        return p;
      };
      var oo = XMLHttpRequest.prototype.open, os = XMLHttpRequest.prototype.send;
      XMLHttpRequest.prototype.open = function(m, u){ this.__m = String(m).toUpperCase(); this.__u = u; return oo.apply(this, arguments); };
      XMLHttpRequest.prototype.send = function(b){
        var x = this;
        this.addEventListener('loadend', function(){ if (want(x.__m, x.__u)) send(x.__m, x.__u, b, x.status); });
        return os.apply(this, arguments);
      };
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let log: SiteLog
        init(_ l: SiteLog) { log = l }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let t = m.body as? String,
                  let d = t.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
            let line = "\(o["m"] as? String ?? "?") \(o["u"] as? String ?? "") [\(o["s"] as? Int ?? 0)]"
                + ((o["b"] as? String).flatMap { $0.isEmpty ? nil : "\n    тело: " + $0 } ?? "")
            Task { @MainActor in self.log.add(line) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(log) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "hlog")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Kodik.ua
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "hlog")
    }
}

struct SiteLogView: View {
    @StateObject private var log = SiteLog()
    @State private var showLog = false

    private var start: URL {
        switch LibSite.current.key {
        case "ranobe": return URL(string: "https://ranobelib.me/ru/")!
        case "manga": return URL(string: "https://mangalib.me/ru/")!
        default: return URL(string: "https://animelib.org/ru/")!
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            SiteWebView(url: start, log: log)
            Button { showLog = true } label: {
                Label("Журнал запросов: \(log.lines.count)", systemImage: "list.bullet.rectangle")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 12))
                    .foregroundStyle(.white)
                    .padding(12)
            }
        }
        .navigationTitle("Сайт")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showLog) {
            NavigationStack {
                ScrollView {
                    Text(log.lines.isEmpty ? "Пока пусто. Открой на сайте главу или серию, отметь прочитанное и вернись сюда." : log.lines.joined(separator: "\n"))
                        .font(.system(size: 10, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .navigationTitle("Журнал")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { showLog = false } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack {
                            Button("Очистить") { log.lines = [] }
                            Button("Копировать") { UIPasteboard.general.string = log.lines.joined(separator: "\n") }
                        }
                    }
                }
            }
        }
    }
}

struct SettingsView: View {
    @AppStorage("accent.hex") private var accentHex = Theme.defaultAccentHex
    @AppStorage("set.autoNative") private var autoNative = true
    @AppStorage("set.resume") private var resume = true
    @AppStorage("set.autoNext") private var autoNext = true
    @AppStorage("set.kodikDirect") private var kodikDirect = false
    @AppStorage("set.theme") private var appTheme = "system"
    @AppStorage("set.platform") private var platform = "anime"
    @AppStorage("set.haptics") private var haptics = true
    @AppStorage("set.keepAwake") private var keepAwake = true
    @AppStorage("manga.mode.default") private var mangaMode = "auto"
    @AppStorage("manga.tapzones") private var tapZones = true
    @AppStorage("manga.anim") private var mangaAnim = "slide"
    @AppStorage("novel.mode") private var novelMode = "pages"
    @AppStorage("novel.anim") private var novelAnim = "book"
    @AppStorage("off.wifi") private var offWifi = false
    @AppStorage("off.prefetch") private var offPrefetch = false
    @ObservedObject private var offline = OfflineStore.shared
    @State private var confirmOffline = false
    @ObservedObject private var auth = AuthStore.shared
    @State private var custom: Color = Theme.accent
    @State private var info: String?
    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var backupInfo = ""

    private let presets: [(String, String)] = [
        ("Фиолетовый", "A87AFF"), ("Розовый", "FF6FA8"), ("Синий", "4F9DFF"),
        ("Бирюзовый", "2EC4B6"), ("Зелёный", "5BD16A"), ("Оранжевый", "FF9F43"), ("Красный", "FF5A5F")
    ]
    private let platforms: [(String, String, String, Bool)] = [
        ("anime", "Аниме", "AnimeLib", true),
        ("ranobe", "Ранобэ", "RanobeLib", true),
        ("manga", "Манга", "MangaLib", true)
    ]

    private func platformIcon(_ id: String) -> String {
        switch id {
        case "ranobe": return "text.book.closed.fill"
        case "manga": return "books.vertical.fill"
        default: return "play.rectangle.fill"
        }
    }

    private var platformHint: String {
        switch platform {
        case "ranobe": return "Ранобэ: читалка с темами и шрифтами, скачивание глав для чтения без сети."
        case "manga": return "Манга: страницы или лента, комментарии к главам, прогресс чтения."
        default: return "Аниме: плеер с озвучкой и субтитрами, комментарии к сериям, автопереход."
        }
    }

    private func choosePlatform(_ id: String) {
        guard platform != id else { return }
        Haptics.bump()
        let name = platforms.first { $0.0 == id }?.1 ?? ""
        AppRouter.shared.toast = "Платформа: \(name)"
        withAnimation(.easeInOut(duration: 0.3)) { platform = id }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title.uppercased()).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    card("Оформление") {
                        Picker("Тема", selection: $appTheme) {
                            Text("Как в системе").tag("system")
                            Text("Тёмная").tag("dark")
                            Text("Светлая").tag("light")
                        }
                        .pickerStyle(.segmented)
                    }

                    card("Цвет акцента") {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 12) {
                                ForEach(presets, id: \.1) { p in
                                    Circle()
                                        .fill(Color(hex: p.1))
                                        .frame(width: 36, height: 36)
                                        .overlay {
                                            if accentHex.uppercased() == p.1 {
                                                Image(systemName: "checkmark").font(.footnote.bold()).foregroundStyle(.white)
                                            }
                                        }
                                        .onTapGesture { accentHex = p.1 }
                                }
                            }
                        }
                        ColorPicker("Свой цвет", selection: $custom, supportsOpacity: false)
                            .onChange(of: custom) { c in accentHex = c.hexString }
                    }

                    card("Платформа") {
                        HStack(spacing: 10) {
                            ForEach(platforms, id: \.0) { pl in
                                let on = platform == pl.0
                                Button { choosePlatform(pl.0) } label: {
                                    VStack(spacing: 6) {
                                        Image(systemName: platformIcon(pl.0)).font(.title2)
                                        Text(pl.1).font(.subheadline.weight(.semibold))
                                        Text(pl.2).font(.caption2).opacity(0.7)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 14)
                                    .foregroundStyle(on ? Color.white : Color.primary)
                                    .background(
                                        on ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                                                          startPoint: .topLeading, endPoint: .bottomTrailing))
                                           : AnyShapeStyle(Theme.chip),
                                        in: RoundedRectangle(cornerRadius: 16))
                                    .overlay(alignment: .topTrailing) {
                                        if on {
                                            Image(systemName: "checkmark.circle.fill")
                                                .font(.footnote)
                                                .foregroundStyle(.white)
                                                .padding(7)
                                                .transition(.scale.combined(with: .opacity))
                                        }
                                    }
                                    .scaleEffect(on ? 1 : 0.96)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                        Text(platformHint)
                            .font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    card("Ощущения") {
                        Toggle("Вибрация при нажатиях", isOn: $haptics)
                            .onChange(of: haptics) { on in if on { Haptics.bump() } }
                        Toggle("Не гасить экран при чтении", isOn: $keepAwake)
                    }
                    .tint(Theme.accent)

                    if platform == "ranobe" {
                        card("Чтение ранобэ") {
                            Picker("Режим", selection: $novelMode) {
                                Text("Страницы").tag("pages")
                                Text("Прокрутка").tag("scroll")
                            }
                            .pickerStyle(.segmented)
                            Picker("Листание", selection: $novelAnim) {
                                Text("Сдвиг").tag("slide")
                                Text("Плавно").tag("fade")
                                Text("Как в книге").tag("book")
                            }
                            .pickerStyle(.segmented)
                            Text("В режиме «Страницы» глава режется на страницы по размеру экрана. Размер шрифта и тему можно менять в самой читалке.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tint(Theme.accent)
                    }

                    if platform == "manga" {
                        card("Чтение манги") {
                            Picker("Режим по умолчанию", selection: $mangaMode) {
                                Text("Авто").tag("auto")
                                Text("Страницы").tag("pages")
                                Text("Лента").tag("scroll")
                            }
                            .pickerStyle(.segmented)
                            Picker("Листание", selection: $mangaAnim) {
                                Text("Сдвиг").tag("slide")
                                Text("Плавно").tag("fade")
                                Text("Как в книге").tag("book")
                            }
                            .pickerStyle(.segmented)
                            Toggle("Листать тапом по краям экрана", isOn: $tapZones)
                            Text("Для каждого тайтла режим можно поменять прямо в читалке, он запомнится.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        .tint(Theme.accent)
                    }

                    card("Воспроизведение") {
                        Toggle("Весь экран в родном плеере iOS", isOn: $autoNative)
                        Toggle("Kodik: сразу родной плеер, без веб-плеера", isOn: $kodikDirect)
                        Toggle("Продолжать с места остановки", isOn: $resume)
                        Toggle("Следующая серия сама после конца", isOn: $autoNext)
                        Text("Kodik открывается в веб-плеере: выбери качество и нажми «на весь экран», тогда включится родной плеер iOS. Если выключить первый пункт, весь экран останется внутри веб-плеера.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    .tint(Theme.accent)

                    card("Загрузки · ранобэ") {
                        if platform == "ranobe" {
                            NavigationLink {
                                OfflineLibraryView()
                            } label: {
                                HStack {
                                    Label("Скачанное", systemImage: "arrow.down.circle")
                                    Spacer()
                                    Text("\(offline.allEntries.count) · \(fmtBytes(offline.totalBytes))")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            .buttonStyle(.pressable)
                        } else {
                            Text(platform == "manga" ? "Для манги загрузки пока недоступны: главы читаются онлайн." : "Скачанные главы доступны на платформе «Ранобэ».")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Скачивать только по Wi‑Fi", isOn: $offWifi)
                        Toggle("Докачивать 3 следующие главы при чтении", isOn: $offPrefetch)
                        if offline.totalBytes > 0 {
                            Button("Удалить все загрузки", role: .destructive) { confirmOffline = true }
                        }
                    }
                    .tint(Theme.accent)
                    .confirmationDialog("Удалить все скачанные главы?", isPresented: $confirmOffline, titleVisibility: .visible) {
                        Button("Удалить", role: .destructive) { offline.removeAll() }
                    }

                    card("Данные") {
                        Button("Очистить кэш обложек") {
                            ImageCache.shared.removeAllObjects(); Task { await ImageLoader.shared.clearDisk() }; info = "Кэш обложек очищен"
                        }
                        Button("Сбросить историю просмотра") {
                            ProgressStore.shared.clear(); HistoryStore.shared.clear()
                            HistoryStore.novels.clear(); HistoryStore.manga.clear(); ReadStore.shared.clear()
                            info = "История просмотра и чтения сброшена"
                        }
                        Button("Очистить избранное") {
                            FavoritesStore.shared.clear(); FavoritesStore.novels.clear(); FavoritesStore.manga.clear(); info = "Избранное очищено"
                        }
                        if let i = info { Text(i).font(.caption).foregroundStyle(.secondary) }
                    }

                    card("Резервная копия") {
                        Text("Прогресс просмотра и чтения, избранное, история и настройки. Один раз выбери место в iCloud Drive: файл будет обновляться сам при каждом сворачивании приложения и переживёт даже удаление Yume.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button { showExporter = true } label: {
                            Label(BackupManager.folderName == nil ? "Выбрать место в iCloud Drive" : "Файл копии: \(BackupManager.folderName ?? "") (сменить)",
                                  systemImage: "icloud")
                        }
                        .fileExporter(isPresented: $showExporter,
                                      document: BackupDocument(data: BackupManager.data() ?? Data()),
                                      contentType: .propertyList,
                                      defaultFilename: "Yume-backup") { result in
                            guard case .success(let url) = result else { return }
                            if BackupManager.setFolder(url) {
                                backupInfo = "Готово: копия будет обновляться сама."
                                Haptics.success()
                            } else {
                                backupInfo = "Не удалось привязать файл. Попробуй выбрать другое место."
                            }
                        }
                        if BackupManager.folderName != nil {
                            if let d = BackupManager.lastFolderWrite {
                                Text("Последнее обновление в iCloud: \(d.formatted(date: .abbreviated, time: .shortened))")
                                    .font(.caption2).foregroundStyle(.secondary)
                            }
                            if BackupManager.lastFolderFailed {
                                Text("Последняя запись не удалась. Выбери место заново.")
                                    .font(.caption2).foregroundStyle(.red)
                            }
                            Button("Отключить автокопию", role: .destructive) {
                                BackupManager.clearFolder(); backupInfo = "Автокопия в iCloud отключена."
                            }
                        }
                        Button {
                            if let u = BackupManager.writeAuto() { shareItem = ShareItem(url: u) }
                        } label: {
                            Label("Отправить копию (Telegram, Файлы…)", systemImage: "square.and.arrow.up")
                        }
                        .sheet(item: $shareItem) { item in ShareSheet(url: item.url) }
                        Button { showImporter = true } label: {
                            Label("Восстановить из копии", systemImage: "arrow.down.doc")
                        }
                        .fileImporter(isPresented: $showImporter, allowedContentTypes: [.propertyList, .data]) { result in
                            guard case .success(let url) = result else { return }
                            let access = url.startAccessingSecurityScopedResource()
                            defer { if access { url.stopAccessingSecurityScopedResource() } }
                            if let d = try? Data(contentsOf: url), let n = BackupManager.restore(d) {
                                backupInfo = "Восстановлено записей: \(n). Закрой приложение полностью и открой заново."
                                Haptics.success()
                            } else {
                                backupInfo = "Не удалось прочитать файл копии."
                            }
                        }
                        if !backupInfo.isEmpty {
                            Text(backupInfo).font(.caption).foregroundStyle(.secondary)
                        }
                    }

                    card("Для разработчика") {
                        NavigationLink {
                            SiteLogView()
                        } label: {
                            Label("Журнал запросов сайта", systemImage: "waveform.path.ecg")
                        }
                        Text("Открывает сайт внутри приложения и записывает, какие запросы он отправляет, когда ты отмечаешь серию или главу. Нужен, чтобы настроить синхронизацию с сайтом.")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    card("Аккаунт") {
                        if let u = auth.user {
                            Text("Вы вошли как \(u.username)")
                            Button("Выйти", role: .destructive) { auth.signOut() }
                        } else {
                            Text("Вход выполняется во вкладке «Профиль».").foregroundStyle(.secondary)
                        }
                    }

                    card("О приложении") {
                        Text("Yume · версия 1.0")
                        Text("Данные: animelib.org. Приложение неофициальное.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(14)
            }
            .background(AppBackground())
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// MARK: - Навигация между вкладками
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var tab = 0
    @Published var pendingQuery: String?
    @Published var pendingSort: CatalogFilter.SortOption?
    @Published var toast: String?

    func openCatalog(query: String = "", sort: CatalogFilter.SortOption? = nil) {
        pendingQuery = query
        pendingSort = sort ?? .rating
        tab = 1
    }
}

// MARK: - История просмотра («Продолжить смотреть»)
struct HistoryItem: Codable, Identifiable {
    let anime: Anime
    var episodeID: Int
    var episodeTitle: String
    var updated: Date
    var id: Int { anime.id }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(key: "history.v1")
    static let novels = HistoryStore(key: "history.novels.v1")
    static let manga = HistoryStore(key: "history.manga.v1")
    static var current: HistoryStore {
        let site = LibSite.current
        return site.isManga ? manga : (site.isRanobe ? novels : shared)
    }
    @Published private(set) var items: [HistoryItem] = []
    private let key: String

    init(key: String) {
        self.key = key
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([HistoryItem].self, from: d) {
            items = v
        }
    }

    func recordChapter(anime: Anime, chapterID: Int, title: String) {
        items.removeAll { $0.anime.id == anime.id }
        items.insert(HistoryItem(anime: anime, episodeID: chapterID, episodeTitle: title, updated: Date()), at: 0)
        if items.count > 30 { items = Array(items.prefix(30)) }
        save()
    }

    func record(anime: Anime, episode: EpisodeShort) {
        items.removeAll { $0.anime.id == anime.id }
        items.insert(HistoryItem(anime: anime, episodeID: episode.id,
                                 episodeTitle: episode.title, updated: Date()), at: 0)
        if items.count > 30 { items = Array(items.prefix(30)) }
        save()
    }

    func remove(_ animeID: Int) {
        items.removeAll { $0.anime.id == animeID }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

// MARK: - Главная
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var fresh: [Anime] = []
    @Published var popular: [Anime] = []
    @Published var newest: [Anime] = []
    @Published var top: [Anime] = []
    @Published var isLoading = false
    @Published var loadingMore = false
    @Published var error: String?
    private var popularPage = 1
    private var popularHasNext = true

    var canLoadMorePopular: Bool { popularHasNext && !popular.isEmpty }

    private func fetch(_ sort: CatalogFilter.SortOption, page: Int = 1) async -> (items: [Anime], hasNext: Bool)? {
        var f = CatalogFilter()
        f.sortBy = sort
        return try? await AnimelibAPI.shared.catalog(filter: f, page: page)
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force && !fresh.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        async let a = fetch(.lastEpisode)
        async let b = fetch(.views)
        async let c = fetch(.newest)
        async let d = fetch(.rating)
        let (ra, rb, rc, rd) = await (a, b, c, d)
        if let r = ra { fresh = r.items }
        if let r = rb { popular = r.items; popularPage = 1; popularHasNext = r.hasNext }
        if let r = rc { newest = r.items }
        if let r = rd { top = r.items }
        ImageLoader.prefetch((fresh + newest + top + popular).compactMap { $0.imageURL })
        error = (ra == nil && rb == nil && rc == nil && rd == nil) ? "Не удалось загрузить данные. Проверьте соединение." : nil
    }

    func morePopular() async {
        guard !loadingMore, popularHasNext else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let r = await fetch(.views, page: popularPage + 1) {
            let known = Set(popular.map { $0.id })
            popular += r.items.filter { !known.contains($0.id) }
            popularPage += 1
            popularHasNext = r.hasNext && !r.items.isEmpty
        } else {
            popularHasNext = false
        }
    }
}

struct TopBlur: View {
    let inset: CGFloat
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: inset + 14)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.75),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .offset(y: -inset)
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil

    var body: some View {
        HStack {
            if let action, actionTitle == nil {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title).font(.title3.bold())
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(.pressable)
            } else {
                Text(title).font(.title3.bold())
            }
            Spacer()
            if let action, let t = actionTitle {
                Button(t, action: action).font(.footnote).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
    }
}

struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 124

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: anime.imageURL)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                .overlay(alignment: .topLeading) {
                    if let t = anime.type?.title, !t.isEmpty {
                        Text(t)
                            .font(.system(size: 10, weight: .bold))
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if let r = anime.rateAvg {
                        Label(r, systemImage: "star.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7).padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            Text(anime.displayTitle)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
        }
    }
}

struct AnimeRow: View {
    let anime: Anime
    var rank: Int? = nil

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                Text("\(rank)")
                    .font(.headline.bold())
                    .foregroundStyle(rank <= 3 ? Theme.accent : Color.secondary)
                    .frame(width: 22)
            }
            RemoteImage(url: anime.imageURL)
                .frame(width: 52, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 4) {
                Text(anime.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text([anime.type?.title, LibSite.current.isBook ? nil : anime.episodesCount.map { "\($0) эп." }]
                    .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            if let r = anime.rateAvg {
                Label(r, systemImage: "star.fill")
                    .font(.caption.bold())
                    .foregroundStyle(.yellow)
            }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
    }
}

struct ContinueCard: View {
    let item: HistoryItem
    @ObservedObject private var progress = ProgressStore.shared

    var body: some View {
        let p = LibSite.current.isBook ? nil : progress.get(item.episodeID)
        HStack(spacing: 12) {
            RemoteImage(url: item.anime.imageURL)
                .frame(width: 56, height: 84)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.anime.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.episodeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let p, p.position > 5 {
                    Text(p.duration > 0 ? "\(formatTime(p.position)) из \(formatTime(p.duration))" : formatTime(p.position))
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    if p.duration > 0 {
                        ProgressView(value: min(p.position / p.duration, 1))
                            .tint(Theme.accent)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(width: 290)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.card))
    }
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var history: HistoryStore = HistoryStore.current
    @ObservedObject private var router = AppRouter.shared
    @State private var query = ""
    private let ranobe = LibSite.current.isBook

    private func poster(_ list: [Anime]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(list) { a in
                    TitleLink(anime: a) { PosterCard(anime: a) }
                        .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
        }
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(LibSite.current.title)
                                .font(.system(size: 32, weight: .heavy, design: .rounded))
                            SearchBar(text: $query) {
                                let q = query.trimmingCharacters(in: .whitespaces)
                                guard !q.isEmpty else { return }
                                SearchHistory.shared.add(q)
                                router.openCatalog(query: q)
                                query = ""
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, geo.safeAreaInsets.top + 4)

                        if let e = vm.error, vm.fresh.isEmpty {
                            VStack(spacing: 12) {
                                Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Повторить") { Task { await vm.load(force: true) } }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }

                        if !history.items.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: ranobe ? "Продолжить читать" : "Продолжить смотреть",
                                              action: { history.clear() }, actionTitle: "Очистить")
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(history.items) { h in
                                            TitleLink(anime: h.anime) { ContinueCard(item: h) }
                                                .buttonStyle(.pressable)
                                                .contextMenu {
                                                    Button(role: .destructive) { history.remove(h.anime.id) } label: {
                                                        Label("Убрать", systemImage: "trash")
                                                    }
                                                }
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                }
                            }
                        }

                        if !vm.fresh.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: ranobe ? "Свежие главы" : "Свежие серии") { router.openCatalog(sort: .lastEpisode) }
                                poster(Array(vm.fresh.prefix(14)))
                            }
                        }

                        if !vm.popular.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: ranobe ? "Сейчас читают" : "Сейчас смотрят") { router.openCatalog(sort: .views) }
                                LazyVStack(spacing: 8) {
                                    ForEach(Array(vm.popular.enumerated()), id: \.element.id) { i, a in
                                        TitleLink(anime: a) { AnimeRow(anime: a, rank: i + 1) }
                                            .buttonStyle(.pressable)
                                    }
                                    if vm.canLoadMorePopular {
                                        Button { Task { await vm.morePopular() } } label: {
                                            Group {
                                                if vm.loadingMore { ProgressView() } else { Text("Показать ещё") }
                                            }
                                            .font(.subheadline.weight(.semibold))
                                            .frame(maxWidth: .infinity)
                                            .padding(.vertical, 12)
                                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                                        }
                                        .buttonStyle(.pressable)
                                    }
                                }
                                .padding(.horizontal, 14)
                            }
                        }

                        if !vm.newest.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Новинки") { router.openCatalog(sort: .newest) }
                                poster(vm.newest)
                            }
                        }

                        if !vm.top.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Лучшее по рейтингу") { router.openCatalog(sort: .rating) }
                                poster(vm.top)
                            }
                        }

                        if vm.isLoading && vm.fresh.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                        Color.clear.frame(height: 80)
                    }
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await vm.load(force: true) }
                .ignoresSafeArea(edges: .top)
                .overlay(alignment: .top) { TopBlur(inset: geo.safeAreaInsets.top) }
            }
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .task { await vm.load() }
        }
    }
}

struct RootView: View {
    @AppStorage("accent.hex") private var accentHex = Theme.defaultAccentHex
    @AppStorage("set.platform") private var platform = "anime"
    @AppStorage("set.theme") private var appTheme = "system"
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var router = AppRouter.shared

    private var scheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        TabView(selection: $router.tab) {
            HomeView()
                .tabItem { Label("Главная", systemImage: "house.fill") }
                .tag(0)
            CatalogView()
                .tabItem { Label("Каталог", systemImage: "square.grid.2x2") }
                .tag(1)
            FavoritesView()
                .tabItem { Label("Избранное", systemImage: "heart") }
                .tag(2)
            ProfileView()
                .tabItem { Label("Профиль", systemImage: "person.crop.circle") }
                .tag(3)
            SettingsView()
                .tabItem { Label("Настройки", systemImage: "gearshape") }
                .tag(4)
        }
        .id(accentHex + platform)
        .transition(.opacity)
        .tint(Color(hex: accentHex))
        .preferredColorScheme(scheme)
        .onChange(of: router.tab) { _ in Haptics.select() }
        .onChange(of: scenePhase) { phase in
            if phase == .background || phase == .inactive { BackupManager.writeAuto() }
        }
        .task { BackupManager.writeAuto() }
        .overlay(alignment: .top) {
            if let t = router.toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        if router.toast == t { router.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: router.toast)
    }
}

@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    @Published private(set) var items: [String] = []

    init() { items = UserDefaults.standard.stringArray(forKey: "search.history") ?? [] }

    func add(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        items.removeAll { $0.lowercased() == t.lowercased() }
        items.insert(t, at: 0)
        items = Array(items.prefix(8))
        UserDefaults.standard.set(items, forKey: "search.history")
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: "search.history")
    }
}

// MARK: - Catalog
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var items: [Anime] = []
    @Published var filter = CatalogFilter()
    @Published var isLoading = false
    @Published var error: String?
    @Published var options = FilterOptions()
    @Published var optionsLoading = false

    private var page = 1
    private var hasNext = true
    private var generation = 0
    private(set) var loadedQuery = ""

    func reload() async {
        generation += 1
        loadedQuery = filter.query
        page = 1; hasNext = true; items = []; error = nil
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard hasNext, !isLoading else { return }
        isLoading = true
        let gen = generation
        defer { if gen == generation { isLoading = false } }
        do {
            let r = try await AnimelibAPI.shared.catalog(filter: filter, page: page)
            guard gen == generation else { return }
            let known = Set(items.map(\.id))
            let fresh = r.items.filter { !known.contains($0.id) }
            items += fresh
            ImageLoader.prefetch(fresh.compactMap { $0.imageURL })
            hasNext = r.hasNext
            page += 1
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func toggle(_ kp: WritableKeyPath<CatalogFilter, Set<Int>>, _ id: Int) {
        if filter[keyPath: kp].contains(id) {
            filter[keyPath: kp].remove(id)
        } else {
            filter[keyPath: kp].insert(id)
        }
    }

    func resetFilters() {
        filter.genres = []; filter.tags = []; filter.types = []; filter.statuses = []
    }

    func loadOptionsIfNeeded(force: Bool = false) async {
        guard !optionsLoading, force || options.isEmpty else { return }
        optionsLoading = true
        options = await AnimelibAPI.shared.filterOptions()
        optionsLoading = false
    }
}

struct SearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по названию", text: $text)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(.ultraThinMaterial, in: Capsule())
    }
}

struct OptionBlock: View {
    let title: String
    let items: [NamedItem]
    let keyPath: WritableKeyPath<CatalogFilter, Set<Int>>
    @ObservedObject var vm: CatalogViewModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        Chip(title: item.title,
                             selected: item.id.map { vm.filter[keyPath: keyPath].contains($0) } ?? false) {
                            if let id = item.id { vm.toggle(keyPath, id) }
                        }
                    }
                }
            }
        }
    }
}

struct FilterSheet: View {
    @ObservedObject var vm: CatalogViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сортировка").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(CatalogFilter.SortOption.allCases) { opt in
                                Chip(title: opt.label(LibSite.current.isBook), selected: vm.filter.sortBy == opt) {
                                    vm.filter.sortBy = opt
                                }
                            }
                        }
                    }

                    if vm.optionsLoading {
                        HStack { ProgressView(); Text("Загружаю жанры и теги…").foregroundStyle(.secondary) }
                    } else if vm.options.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Не удалось загрузить жанры и теги.").foregroundStyle(.secondary)
                            Button("Повторить") { Task { await vm.loadOptionsIfNeeded(force: true) } }
                        }
                    }

                    OptionBlock(title: "Тип", items: vm.options.types, keyPath: \.types, vm: vm)
                    OptionBlock(title: "Статус", items: vm.options.statuses, keyPath: \.statuses, vm: vm)
                    OptionBlock(title: "Жанры", items: vm.options.genres, keyPath: \.genres, vm: vm)
                    OptionBlock(title: "Теги", items: vm.options.tags, keyPath: \.tags, vm: vm)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppBackground())
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить") { vm.resetFilters() }
                        .disabled(vm.filter.activeCount == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Показать") {
                        dismiss()
                        Task { await vm.reload() }
                    }
                    .bold()
                }
            }
        }
        .task { await vm.loadOptionsIfNeeded() }
    }
}

struct CatalogView: View {
    @StateObject private var vm = CatalogViewModel()
    @ObservedObject private var router = AppRouter.shared
    @State private var showFilters = false
    @ObservedObject private var searches = SearchHistory.shared
    @State private var randomTarget: Anime?
    @State private var showRandom = false
    @State private var rolling = false
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    private func roll() {
        guard !rolling else { return }
        rolling = true
        Haptics.tap()
        let filter = vm.filter
        Task { @MainActor in
            var pick: Anime?
            for _ in 0..<3 where pick == nil {
                if let r = try? await AnimelibAPI.shared.catalog(filter: filter, page: Int.random(in: 1...25)) {
                    pick = r.items.randomElement()
                }
            }
            if pick == nil, let r = try? await AnimelibAPI.shared.catalog(filter: filter, page: 1) {
                pick = r.items.randomElement()
            }
            rolling = false
            if let a = pick {
                randomTarget = a
                showRandom = true
                Haptics.success()
            }
        }
    }

    @ViewBuilder
    private var randomDestination: some View {
        if let a = randomTarget {
            if LibSite.current.isBook { NovelDetailView(novel: Novel(a)) } else { DetailView(anime: a) }
        }
    }

    private var randomButton: some View {
        Button { roll() } label: {
            Group {
                if rolling { ProgressView() } else { Image(systemName: "dice.fill").font(.headline) }
            }
            .frame(width: 42, height: 42)
            .background(Material.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.pressable)
    }

    private var filterButton: some View {
        Button { showFilters = true } label: {
            Image(systemName: "slider.horizontal.3")
                .font(.headline)
                .frame(width: 42, height: 42)
                .background(vm.filter.activeCount > 0 ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Material.ultraThinMaterial), in: Circle())
                .overlay(alignment: .topTrailing) {
                    if vm.filter.activeCount > 0 {
                        Text("\(vm.filter.activeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.pink, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.pressable)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text(LibSite.current.title)
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                        Spacer()
                        randomButton
                        filterButton
                    }
                    SearchBar(text: $vm.filter.query) {
                        searches.add(vm.filter.query)
                        Task { await vm.reload() }
                    }
                    if vm.filter.query.isEmpty && !searches.items.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                ForEach(searches.items, id: \.self) { q in
                                    Chip(title: q, selected: false) {
                                        vm.filter.query = q
                                        Task { await vm.reload() }
                                    }
                                }
                                Button { searches.clear() } label: {
                                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, geo.safeAreaInsets.top + 4)
                .padding(.bottom, 10)

                if let e = vm.error, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Повторить") { Task { await vm.reload() } }
                    }
                    .padding(.top, 60).padding(.horizontal)
                } else if vm.items.isEmpty && !vm.isLoading {
                    Text("Ничего не найдено")
                        .foregroundStyle(.secondary)
                        .padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(vm.items) { anime in
                        TitleLink(anime: anime) { AnimeCard(anime: anime) }
                            .buttonStyle(.pressable)
                            .onAppear {
                                if vm.items.suffix(8).contains(where: { $0.id == anime.id }) { Task { await vm.loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, 14)
                if vm.isLoading { ProgressView().padding() }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await vm.reload() }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                // мягкое размытие под строкой состояния: обложки заезжают под неё, как в системных приложениях
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: geo.safeAreaInsets.top + 14)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.75),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                    .offset(y: -geo.safeAreaInsets.top)
            }
            }
            .background(AppBackground())
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .navigationDestination(isPresented: $showRandom) { randomDestination }
            .sheet(isPresented: $showFilters) { FilterSheet(vm: vm) }
            .task { if vm.items.isEmpty { await vm.reload() } }
            .task(id: vm.filter.query) {
                // живой поиск: ждём, пока вы закончите печатать
                guard vm.filter.query != vm.loadedQuery else { return }
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled || vm.filter.query == vm.loadedQuery { return }
                await vm.reload()
            }
            .onAppear {
                var changed = false
                if let q = router.pendingQuery { vm.filter.query = q; router.pendingQuery = nil; changed = true }
                if let so = router.pendingSort { vm.filter.sortBy = so; router.pendingSort = nil; changed = true }
                if changed { Task { await vm.reload() } }
            }
        }
    }
}

struct AnimeCard: View {
    let anime: Anime
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: anime.imageURL)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .shadow(color: .black.opacity(0.4), radius: 6, y: 3)
                .overlay(alignment: .bottomLeading) {
                    if let r = anime.rateAvg {
                        Label(r, systemImage: "star.fill")
                            .font(.caption2.bold())
                            .padding(.horizontal, 7)
                            .padding(.vertical, 4)
                            .background(.ultraThinMaterial, in: Capsule())
                            .padding(6)
                    }
                }
            Text(anime.displayTitle)
                .font(.footnote.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

// MARK: - Автор: все его тайтлы
struct AuthorRef: Hashable {
    let id: Int
    let name: String
    var slug: String? = nil
}

@MainActor
final class AuthorViewModel: ObservableObject {
    @Published var items: [Anime] = []
    @Published var isLoading = false
    @Published var error: String?
    private var page = 1
    private var finished = false
    let authorID: Int
    let slug: String?

    init(authorID: Int, slug: String?) {
        self.authorID = authorID
        self.slug = slug
    }

    func loadMore() async {
        guard !isLoading, !finished else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await AnimelibAPI.shared.byAuthor(authorID, slug: slug, page: page)
            let known = Set(items.map { $0.id })
            let fresh = r.items.filter { !known.contains($0.id) }
            items += fresh
            ImageLoader.prefetch(fresh.compactMap { $0.imageURL })
            page += 1
            if fresh.isEmpty || !r.hasNext { finished = true }
            error = nil
        } catch {
            finished = true
            if items.isEmpty { self.error = error.localizedDescription }
        }
    }
}

struct AuthorView: View {
    let author: AuthorRef
    @StateObject private var vm: AuthorViewModel
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    init(author: AuthorRef) {
        self.author = author
        _vm = StateObject(wrappedValue: AuthorViewModel(authorID: author.id, slug: author.slug))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.name).font(.title3.bold())
                        Text("Все тайтлы автора").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))

                if let e = vm.error {
                    Text(e).font(.footnote).foregroundStyle(.red)
                    Button("Повторить") { Task { await vm.loadMore() } }
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(vm.items) { a in
                        TitleLink(anime: a) { AnimeCard(anime: a) }
                            .buttonStyle(.pressable)
                            .onAppear {
                                if vm.items.suffix(8).contains(where: { $0.id == a.id }) { Task { await vm.loadMore() } }
                            }
                    }
                }
                if vm.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if vm.items.isEmpty && !vm.isLoading && vm.error == nil {
                    Text("Тайтлов не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle(author.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadMore() }
    }
}

// MARK: - Detail
@MainActor
final class DetailViewModel: ObservableObject {
    @Published var anime: Anime
    @Published var episodes: [EpisodeShort] = []
    @Published var isLoading = true
    @Published var error: String?

    init(anime: Anime) { self.anime = anime }

    func load() async {
        isLoading = true; error = nil
        do {
            if let slug = anime.slugUrl {
                async let d = AnimelibAPI.shared.details(slug: slug)
                async let e = AnimelibAPI.shared.episodes(animeID: anime.id)
                if let full = try? await d { anime = full }
                episodes = try await e
            } else {
                episodes = try await AnimelibAPI.shared.episodes(animeID: anime.id)
            }
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

struct DetailView: View {
    @StateObject private var vm: DetailViewModel
    @State private var selected: EpisodeShort?
    @State private var showComments = false
    @State private var showBookmark = false
    @ObservedObject private var progress = ProgressStore.shared
    @State private var expanded = false
    @ObservedObject private var favorites = FavoritesStore.shared

    init(anime: Anime) { _vm = StateObject(wrappedValue: DetailViewModel(anime: anime)) }

    private var backdrop: some View {
        ZStack {
            Theme.base
            RemoteImage(url: vm.anime.imageURL, maxPixel: 96)
                .blur(radius: 16)
                .opacity(0.55)
            LinearGradient(colors: [.clear, Theme.base.opacity(0.85), Theme.base], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(url: vm.anime.imageURL)
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(vm.anime.displayTitle).font(.title3.bold())
                        if let n = vm.anime.name, n != vm.anime.displayTitle {
                            Text(n).font(.caption).foregroundStyle(.secondary)
                        }
                        FlowLayout(spacing: 6) {
                            if let s = vm.anime.status?.title, !s.isEmpty { Pill(icon: "dot.radiowaves.left.and.right", text: s) }
                            if let t = vm.anime.type?.title, !t.isEmpty { Pill(icon: "tv", text: t) }
                            if let a = vm.anime.ageRestriction?.title, !a.isEmpty { Pill(icon: "exclamationmark.shield", text: a) }
                            if let r = vm.anime.rateAvg { Pill(icon: "star.fill", text: r) }
                        }
                    }
                }

                if let g = vm.anime.genres, !g.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(g, id: \.id) { item in
                            Text(item.title)
                                .font(.caption)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 5)
                                .background(Theme.accent.opacity(0.28), in: Capsule())
                        }
                    }
                }

                if let s = vm.anime.summary, !s.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s).font(.callout).lineLimit(expanded ? nil : 5)
                        if s.count > 220 {
                            Button(expanded ? "Свернуть" : "Читать полностью") {
                                withAnimation { expanded.toggle() }
                            }
                            .font(.footnote.bold())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                }

                if let au = vm.anime.authors, !au.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Автор оригинала").font(.footnote.bold()).foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(Array(au.enumerated()), id: \.offset) { _, a in
                                if let aid = a.id {
                                    NavigationLink(value: AuthorRef(id: aid, name: a.title, slug: a.slug)) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "person.fill")
                                            Text(a.title)
                                            Image(systemName: "chevron.right").font(.caption2)
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.chip, in: Capsule())
                                    }
                                    .buttonStyle(.pressable)
                                } else {
                                    Text(a.title)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.chip, in: Capsule())
                                }
                            }
                        }
                    }
                }

                if let slug = vm.anime.slugUrl, let url = URL(string: "https://animelib.org/ru/anime/\(slug)") {
                    Link(destination: url) {
                        Label("Открыть на сайте", systemImage: "safari")
                            .font(.subheadline)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(Theme.chip, in: Capsule())
                    }
                }

                Button { showComments = true } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.accent)
                        Text("Комментарии").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.pressable)

                Text("Серии").font(.title3.bold())
                if vm.isLoading { ProgressView() }
                if let e = vm.error { Text(e).foregroundStyle(.red).font(.footnote) }
                if !vm.isLoading && vm.episodes.isEmpty && vm.error == nil {
                    Text("Серий пока нет").foregroundStyle(.secondary)
                }
                LazyVStack(spacing: 8) {
                    ForEach(vm.episodes) { ep in
                        let pr = progress.get(ep.id)
                        Button { selected = ep } label: {
                            HStack(spacing: 12) {
                                Text(ep.number ?? "–")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(pr != nil ? Color.secondary : Color.primary)
                                    .frame(width: 38, height: 38)
                                    .background(pr != nil ? Color.gray.opacity(0.3) : Theme.accent.opacity(0.28), in: Circle())
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((ep.name?.isEmpty == false ? ep.name! : "Серия \(ep.number ?? "")"))
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let s = ep.season, s != "1" {
                                        Text("Сезон \(s)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let pr = pr {
                                        Text(pr.finished ? "Просмотрено"
                                             : pr.position > 5 ? "Остановились на \(formatTime(pr.position))"
                                             : "Открывали")
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(pr != nil ? Color.secondary : Color.primary)
                                Spacer()
                                Image(systemName: (pr?.finished ?? false) ? "checkmark.circle.fill" : "play.fill")
                                    .foregroundStyle(pr != nil ? Color.gray : Theme.accent)
                            }
                            .padding(10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .padding(16)
        }
        .background(backdrop)
        .navigationTitle(vm.anime.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AuthorRef.self) { AuthorView(author: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let u = titleURL(vm.anime) {
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                }
                Button { showBookmark = true } label: { Image(systemName: "bookmark") }
                Button { favorites.toggle(vm.anime) } label: {
                    Image(systemName: favorites.contains(vm.anime) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.contains(vm.anime) ? Color.pink : Color.primary)
                }
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showComments) { CommentsView(anime: vm.anime) }
        .sheet(isPresented: $showBookmark) { BookmarkSheet(anime: vm.anime) }
        .fullScreenCover(item: $selected) { ep in
            PlayerScreen(episode: ep, animeTitle: vm.anime.displayTitle, anime: vm.anime, episodes: vm.episodes)
        }
    }
}

// MARK: - Прогресс просмотра
struct WatchProgress: Codable {
    var position: Double
    var duration: Double
    var updated: Date
    var finished: Bool { duration > 0 && position / duration > 0.92 }
}

@MainActor
final class ProgressStore: ObservableObject {
    static let shared = ProgressStore()
    private(set) var items: [String: WatchProgress] = [:]
    private let key = "progress.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: WatchProgress].self, from: d) {
            items = v
        }
    }

    func clear() {
        objectWillChange.send()
        items = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    func get(_ id: Int) -> WatchProgress? { items[String(id)] }
    func position(_ id: Int) -> Double { items[String(id)]?.position ?? 0 }

    func opened(_ id: Int) {
        if items[String(id)] == nil {
            objectWillChange.send()
            items[String(id)] = WatchProgress(position: 0, duration: 0, updated: Date())
            save()
        }
    }

    func update(_ id: Int, position: Double, duration: Double) {
        let new = WatchProgress(position: position, duration: duration, updated: Date())
        let old = items[String(id)]
        // перерисовываем экраны только при заметных изменениях, а не каждые 5 секунд
        if old == nil || old?.finished != new.finished || abs((old?.position ?? 0) - position) >= 30 {
            objectWillChange.send()
        }
        items[String(id)] = new
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

func formatTime(_ t: Double) -> String {
    let s = Int(t)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}

// MARK: - Kodik (прямое получение потока)
enum KodikError: LocalizedError {
    case page, params, noLinks, decode
    case server(String)
    var errorDescription: String? {
        switch self {
        case .page: return "не открылась страница плеера"
        case .params: return "не найдены параметры плеера"
        case .noLinks: return "плеер не вернул ссылки на видео"
        case .decode: return "не удалось расшифровать ссылку"
        case .server(let t): return "ответ Kodik: " + t
        }
    }
}

enum Kodik {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func match(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func fetch(_ url: URL, referer: String) async throws -> String {
        var req = URLRequest(url: url)
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let t = String(data: data, encoding: .utf8) else { throw KodikError.page }
        return t
    }

    static func resolve(_ pageURL: URL) async throws -> [(Int, URL)] {
        let html = try await fetch(pageURL, referer: "https://animelib.org/")
        // параметры подписи: ищем каждое поле отдельно, формат страницы может меняться
        var params: [String: Any] = [:]
        for k in ["d", "d_sign", "pd", "pd_sign", "ref", "ref_sign"] {
            if let v = match("\\\\?[\"']" + k + "\\\\?[\"']\\s*:\\s*\\\\?[\"']([^\"'\\\\]*)", in: html) { params[k] = v }
        }
        if params["d_sign"] == nil || params["pd_sign"] == nil {
            let hasKey = html.contains("urlParams")
            let head = String(html.prefix(70)).replacingOccurrences(of: "\n", with: " ")
            throw KodikError.server("нет параметров (страница \(html.count) симв., urlParams: \(hasKey ? "есть" : "нет"), начало: \(head))")
        }

        let parts = pageURL.pathComponents.filter { $0 != "/" }
        let type = match("videoInfo\\.type\\s*=\\s*'([^']+)'", in: html) ?? (parts.count > 0 ? parts[0] : "")
        let id = match("videoInfo\\.id\\s*=\\s*'?([0-9]+)'?", in: html) ?? (parts.count > 1 ? parts[1] : "")
        let hash = match("videoInfo\\.hash\\s*=\\s*'([^']+)'", in: html) ?? (parts.count > 2 ? parts[2] : "")
        guard !type.isEmpty, !id.isEmpty, !hash.isEmpty else { throw KodikError.params }

        // путь запроса прячется в скрипте плеера, по умолчанию /ftor
        var path = "/ftor"
        if let script = match("<script[^>]+src=\"(/assets/js/app\\.player[^\"]+)\"", in: html),
           let su = URL(string: "https://" + (pageURL.host ?? "kodikplayer.com") + script),
           let js = try? await fetch(su, referer: pageURL.absoluteString),
           let b64 = match("url:\\s*atob\\(\\s*[\"']([^\"']+)[\"']\\s*\\)", in: js),
           let d = Data(base64Encoded: b64), let p = String(data: d, encoding: .utf8), p.hasPrefix("/") {
            path = p
        }

        var fields: [(String, String)] = []
        for k in ["d", "d_sign", "pd", "pd_sign", "ref", "ref_sign"] {
            fields.append((k, (params[k] as? String) ?? ""))
        }
        fields += [("bad_user", "true"), ("cdn_is_working", "true"),
                   ("type", type), ("hash", hash), ("id", id), ("info", "{}")]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.map { k, v in
            k + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)
        }.joined(separator: "&")

        guard let ftor = URL(string: "https://" + (pageURL.host ?? "kodikplayer.com") + path) else { throw KodikError.page }
        var req = URLRequest(url: ftor)
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://" + (pageURL.host ?? "kodikplayer.com"), forHTTPHeaderField: "Origin")
        req.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let links = obj["links"] as? [String: Any] else {
            let t = String(data: data.prefix(140), encoding: .utf8) ?? ""
            throw KodikError.server(t)
        }

        var result: [(Int, URL)] = []
        for (q, v) in links {
            guard let arr = v as? [[String: Any]], let src = arr.first?["src"] as? String,
                  let quality = Int(q) else { continue }
            guard var text = decode(src) else { throw KodikError.decode }
            if text.hasPrefix("//") { text = "https:" + text }
            if let u = URL(string: text) { result.append((quality, u)) }
        }
        if result.isEmpty { throw KodikError.noLinks }
        return result.sorted { $0.0 > $1.0 }
    }

    /// Ссылка зашифрована сдвигом букв (ROT-N) и base64; перебираем сдвиг.
    static func decode(_ s: String) -> String? {
        if s.hasPrefix("http") || s.hasPrefix("//") { return s }
        for shift in 0..<26 {
            var out = ""
            for c in s.unicodeScalars {
                let v = c.value
                if v >= 65 && v <= 90 {
                    out.unicodeScalars.append(UnicodeScalar((v - 65 + UInt32(shift)) % 26 + 65)!)
                } else if v >= 97 && v <= 122 {
                    out.unicodeScalars.append(UnicodeScalar((v - 97 + UInt32(shift)) % 26 + 97)!)
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            var b = out.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            if let d = Data(base64Encoded: b), let t = String(data: d, encoding: .utf8),
               t.hasPrefix("http") || t.hasPrefix("//") {
                return t
            }
        }
        return nil
    }
}

// MARK: - Player
/// Страница плеера Kodik встраивается как iframe на «странице сайта» (baseURL),
/// так же, как это делает сам сайт.
struct WebPlayerView: UIViewRepresentable {
    let url: URL
    var onStream: ((URL) -> Void)? = nil
    var onFullscreen: ((Double, URL?) -> Void)? = nil
    var interceptFS = false

    final class Coordinator: NSObject, WKScriptMessageHandler {
        var loaded: URL?
        var onStream: ((URL) -> Void)?
        var onFullscreen: ((Double, URL?) -> Void)?
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let t = m.body as? String else { return }
            if t.hasPrefix("FS|") {
                let parts = t.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false)
                let time = parts.count > 1 ? (Double(parts[1]) ?? 0) : 0
                var link: URL?
                if parts.count > 2, parts[2].hasPrefix("http") { link = URL(string: String(parts[2])) }
                DispatchQueue.main.async { self.onFullscreen?(time, link) }
                return
            }
            guard t.hasPrefix("http"), let u = URL(string: t) else { return }
            DispatchQueue.main.async { self.onStream?(u) }
        }
    }

    /// Кнопка «на весь экран» в веб-плеере вместо этого открывает родной плеер iOS.
    static let fsHook = """
    (function(){
      if (window.__heheFS) return; window.__heheFS = true;
      function fs(el){
        try {
          var v = (el && el.tagName === 'VIDEO') ? el : document.getElementsByTagName('video')[0];
          var u = v ? (v.currentSrc || v.src || '') : '';
          var t = v ? (v.currentTime || 0) : 0;
          if (v) { try { v.pause(); } catch (e) {} }
          window.webkit.messageHandlers.hehe.postMessage('FS|' + t + '|' + u);
        } catch (e) {}
      }
      try {
        HTMLVideoElement.prototype.webkitEnterFullscreen = function(){ fs(this); };
        HTMLVideoElement.prototype.webkitEnterFullScreen = function(){ fs(this); };
        var rf = function(){ fs(null); return Promise.resolve(); };
        Element.prototype.requestFullscreen = rf;
        Element.prototype.webkitRequestFullscreen = rf;
        Element.prototype.webkitRequestFullScreen = rf;
        Object.defineProperty(document, 'fullscreenEnabled', { get: function(){ return true; } });
        Object.defineProperty(document, 'webkitFullscreenEnabled', { get: function(){ return true; } });
      } catch (e) {}
    })();
    """

    func makeCoordinator() -> Coordinator { Coordinator() }

    static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "hehe")
        v.stopLoading()
        v.loadHTMLString("", baseURL: nil)
    }

    static let sniffer = """
    (function(){
      if (window.__heheSniff) return; window.__heheSniff = true;
      var sent = {};
      function post(u){
        try { if (!sent[u]) { sent[u] = 1; window.webkit.messageHandlers.hehe.postMessage(u); } } catch (e) {}
      }
      function report(u){
        try {
          if (!u) return;
          var a = new URL(String(u), location.href).href;
          if (/\\.m3u8|\\.mp4/.test(a)) post(a);
        } catch (e) {}
      }
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u){ report(u); return oo.apply(this, arguments); };
      var of = window.fetch;
      if (of) window.fetch = function(a){ report(typeof a === 'string' ? a : (a && a.url)); return of.apply(this, arguments); };
      setInterval(function(){
        var vs = document.getElementsByTagName('video');
        for (var i = 0; i < vs.length; i++) {
          var u = vs[i].currentSrc || vs[i].src;
          if (u && u.indexOf('http') === 0) report(u);
        }
      }, 700);
    })();
    """

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.allowsInlineMediaPlayback = true
        cfg.userContentController.add(context.coordinator, name: "hehe")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.sniffer, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        if interceptFS {
            cfg.userContentController.addUserScript(
                WKUserScript(source: Self.fsHook, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        }
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Kodik.ua
        v.isOpaque = false
        v.backgroundColor = .black
        v.scrollView.isScrollEnabled = false
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {
        context.coordinator.onStream = onStream
        context.coordinator.onFullscreen = onFullscreen
        guard context.coordinator.loaded != url else { return }
        context.coordinator.loaded = url
        let html = """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
        <style>html,body{margin:0;height:100%;background:#000}
        iframe{position:absolute;top:0;left:0;width:100%;height:100%;border:0}</style>
        </head><body>
        <iframe src="\(url.absoluteString)" allow="autoplay; fullscreen; picture-in-picture" allowfullscreen></iframe>
        </body></html>
        """
        v.loadHTMLString(html, baseURL: URL(string: "https://animelib.org/"))
    }
}

struct FullscreenPlayer: UIViewControllerRepresentable {
    let player: AVPlayer?

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let c = AVPlayerViewController()
        c.player = player
        c.allowsPictureInPicturePlayback = true
        return c
    }

    func updateUIViewController(_ c: AVPlayerViewController, context: Context) {}
}

@MainActor
final class PlayerViewModel: ObservableObject {
    @Published var variants: [PlayableVariant] = []
    @Published var current: PlayableVariant?
    @Published var player: AVPlayer?
    @Published var qualities: [PlayableVariant] = []
    @Published var currentQuality: UUID?
    @Published var showWeb = false
    @Published var isResolving = false
    @Published var note: String?
    @Published var error: String?
    @Published var isLoading = true
    @Published var debug = ""
    @Published var sourceNote = ""
    @Published var playbackError: String?
    @Published var showNative = false
    var fsPlayer: AVPlayer?
    private var lastWebStream: URL?
    private var attempts: [(URL, [String: String])] = []
    private var attemptIndex = 0
    private var attemptLog: [String] = []
    private var statusObs: NSKeyValueObservation?
    private var lastQualityTitle: String?
    var autoNative = true
    var onEnd: (() -> Void)?
    private var endObserver: NSObjectProtocol?
    var episodeID = 0
    var lastPosition: Double = 0
    private var timeObserver: Any?
    private var observedPlayer: AVPlayer?
    private var stopped = false

    var usesWeb: Bool {
        guard let v = current, v.isWeb else { return false }
        return !v.kodik || showWeb
    }

    func load(episodeID: Int) async {
        let prevTitle = current?.title
        isLoading = true; error = nil
        detachObserver(); player?.pause(); player = nil
        variants = []; current = nil; qualities = []; currentQuality = nil
        showWeb = false; note = nil; debug = ""; sourceNote = ""
        playbackError = nil; lastWebStream = nil; statusObs = nil
        stopped = false
        self.episodeID = episodeID
        ProgressStore.shared.opened(episodeID)
        lastPosition = Settings.bool("set.resume", true) ? ProgressStore.shared.position(episodeID) : 0
        do {
            variants = try await AnimelibAPI.shared.variants(episodeID: episodeID)
            sourceNote = await AnimelibAPI.shared.variantNote
            if let first = variants.first { select(variants.first(where: { $0.title == prevTitle }) ?? first) }
        } catch {
            self.error = error.localizedDescription
            let a = await AnimelibAPI.shared.rawText("/episodes/\(episodeID)")
            debug = a
        }
        isLoading = false
    }

    func select(_ v: PlayableVariant) {
        note = nil
        showWeb = false
        autoNative = Settings.bool("set.autoNative", true)
        qualities = []
        current = v
        if v.kodik {
            savePosition(); detachObserver()
            player?.pause(); player = nil
            // Сначала веб-плеер Kodik: качество выбирается в нём, а родной плеер открывается по кнопке «на весь экран».
            if Settings.bool("set.kodikDirect", false) { Task { await playKodik(v) } } else { showWeb = true }
        } else if v.isWeb {
            savePosition(); detachObserver()
            player?.pause(); player = nil
            showWeb = true
        } else if !v.options.isEmpty {
            qualities = v.options
            // Сначала не выше 1080p: 2160p часто в формате, который iPhone не показывает (звук есть, картинки нет).
            let q = v.options.first(where: { $0.title == lastQualityTitle })
                ?? v.options.first(where: { (Int($0.title.dropLast()) ?? 0) <= 1080 })
                ?? v.options[0]
            pickQuality(q)
        } else {
            startAV(v.url, headers: AnimelibAPI.shared.playbackHeaders)
        }
    }

    func playKodik(_ v: PlayableVariant) async {
        isResolving = true
        defer { isResolving = false }
        do {
            let links = try await Kodik.resolve(v.url)
            guard current?.id == v.id else { return }
            qualities = links.map { PlayableVariant(title: "\($0.0)p", url: $0.1, subtitle: nil) }
            if let best = qualities.first { pickQuality(best) }
        } catch {
            guard current?.id == v.id else { return }
            note = "Прямой поток не получен (\(error.localizedDescription)). Пробую получить его через веб-плеер."
            showWeb = true
        }
    }

    func pickQuality(_ q: PlayableVariant) {
        currentQuality = q.id
        lastQualityTitle = q.title
        if current?.isWeb == true {
            startAV(q.url, headers: ["Referer": "https://kodikplayer.com/", "Origin": "https://kodikplayer.com", "User-Agent": Kodik.ua])
        } else {
            playNative(q)
        }
    }

    /// Родной плеер Animelib: пробуем разные серверы и заголовки, пока видео не откроется.
    private func playNative(_ q: PlayableVariant) {
        let sets: [[String: String]] = [
            AnimelibAPI.shared.playbackHeaders,
            ["Referer": "https://animelib.org/", "Origin": "https://animelib.org"],
            [:]
        ]
        attempts = []
        for u in [q.url] + q.alts {
            for h in sets { attempts.append((u, h)) }
        }
        attemptIndex = 0
        attemptLog = []
        playbackError = nil
        runAttempt()
    }

    private func runAttempt() {
        guard attemptIndex < attempts.count else { return }
        let (u, h) = attempts[attemptIndex]
        startAV(u, headers: h)
        guard let item = player?.currentItem else { return }
        statusObs = item.observe(\.status, options: [.new]) { [weak self] it, _ in
            Task { @MainActor in self?.itemStatus(it) }
        }
    }

    private func itemStatus(_ item: AVPlayerItem) {
        guard item === player?.currentItem, attemptIndex < attempts.count else { return }
        if item.status == .readyToPlay {
            playbackError = nil
            checkVideo(item)
            return
        }
        guard item.status == .failed else { return }
        let code = item.errorLog()?.events.last?.errorStatusCode ?? 0
        let msg = item.error?.localizedDescription ?? "неизвестная ошибка"
        let host = attempts[attemptIndex].0.host ?? "?"
        attemptLog.append("\(host): \(code > 0 ? "HTTP \(code)" : msg)")
        attemptIndex += 1
        if attemptIndex < attempts.count {
            runAttempt()
        } else {
            var seen: [String] = []
            for l in attemptLog where !seen.contains(l) { seen.append(l) }
            playbackError = "Видео не открылось.\n" + seen.joined(separator: "\n")
        }
    }

    /// Звук идёт, а картинки нет (формат не поддерживается): переключаемся на качество ниже.
    private func checkVideo(_ item: AVPlayerItem) {
        Task { @MainActor [weak self, weak item] in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard let self, let item, item === self.player?.currentItem,
                  item.status == .readyToPlay, item.presentationSize == .zero else { return }
            self.lowerQuality()
        }
    }

    private func lowerQuality() {
        guard let i = qualities.firstIndex(where: { $0.id == currentQuality }), i + 1 < qualities.count else {
            playbackError = "Звук есть, но видео не показывается: этот формат не поддерживается устройством. Выбери другое качество или озвучку."
            return
        }
        let next = qualities[i + 1]
        note = "\(qualities[i].title) не показывает картинку на этом устройстве, включил \(next.title)."
        pickQuality(next)
    }

    /// Веб-плеер Kodik просит весь экран: открываем родной плеер с тем же потоком и временем.
    func webFullscreen(time: Double, url: URL?) {
        guard let stream = url ?? lastWebStream else {
            note = "Видео ещё не запущено. Нажми ▶ в плеере, затем «на весь экран»."
            return
        }
        let headers = ["Referer": "https://kodikplayer.com/", "Origin": "https://kodikplayer.com", "User-Agent": Kodik.ua]
        let asset = AVURLAsset(url: stream, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        if time > 1 { p.seek(to: CMTime(seconds: time, preferredTimescale: 600)) }
        fsPlayer = p
        showNative = true
        Haptics.tap()
        p.play()
    }

    /// Родной полноэкранный режим для уже играющего видео.
    func openFullscreen() {
        guard let p = player else { return }
        fsPlayer = p
        showNative = true
        Haptics.tap()
    }

    func closeNative() {
        if let p = fsPlayer {
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? 0
            if t.isFinite, d.isFinite, d > 0 { ProgressStore.shared.update(episodeID, position: t, duration: d) }
            if p !== player { p.pause() }
        }
        fsPlayer = nil
        showNative = false
    }

    func forceWeb() { autoNative = false; showWeb = true; note = nil }

    /// Веб-плеер Kodik отдал адрес потока: запоминаем его для полноэкранного режима.
    func webStream(_ u: URL) {
        lastWebStream = u
    }

    private func startAV(_ url: URL, headers: [String: String]) {
        guard !stopped else { return }
        savePosition()
        if let t = player?.currentTime(), t.isValid, t.seconds > 1 { lastPosition = t.seconds }
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let p = AVPlayer(playerItem: AVPlayerItem(asset: asset))
        if lastPosition > 1 { p.seek(to: CMTime(seconds: lastPosition, preferredTimescale: 600)) }
        detachObserver()
        player?.pause()
        player = p
        let id = episodeID
        timeObserver = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 5, preferredTimescale: 1), queue: .main) { [weak self, weak p] t in
            let dur = p?.currentItem?.duration.seconds ?? 0
            let pos = t.seconds
            Task { @MainActor in
                guard pos.isFinite, pos > 1 else { return }
                self?.lastPosition = pos
                ProgressStore.shared.update(id, position: pos, duration: dur.isFinite ? dur : 0)
            }
        }
        observedPlayer = p
        if let o = endObserver { NotificationCenter.default.removeObserver(o) }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime, object: p.currentItem, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.finishedPlaying() }
        }
        p.play()
    }

    private func finishedPlaying() {
        guard !stopped else { return }
        if let d = player?.currentItem?.duration.seconds, d.isFinite, d > 0 {
            ProgressStore.shared.update(episodeID, position: d, duration: d)
        }
        if Settings.bool("set.autoNext", true) { onEnd?() }
    }

    private func detachObserver() {
        if let o = timeObserver, let p = observedPlayer { p.removeTimeObserver(o) }
        timeObserver = nil; observedPlayer = nil
        if let o = endObserver { NotificationCenter.default.removeObserver(o); endObserver = nil }
    }

    private func savePosition() {
        guard let p = player else { return }
        let pos = p.currentTime().seconds
        let dur = p.currentItem?.duration.seconds ?? 0
        if pos.isFinite, pos > 1, episodeID != 0 {
            lastPosition = pos
            ProgressStore.shared.update(episodeID, position: pos, duration: dur.isFinite ? dur : 0)
        }
    }

    func stop() { savePosition(); stopped = true; detachObserver(); player?.pause(); player = nil }
}

struct PlayerScreen: View {
    let animeTitle: String
    var anime: Anime? = nil
    let episodes: [EpisodeShort]
    @State private var current: EpisodeShort
    @StateObject private var vm = PlayerViewModel()
    @Environment(\.dismiss) private var dismiss

    init(episode: EpisodeShort, animeTitle: String, anime: Anime? = nil, episodes: [EpisodeShort] = []) {
        self.animeTitle = animeTitle
        self.anime = anime
        self.episodes = episodes
        _current = State(initialValue: episode)
    }

    private var index: Int? { episodes.firstIndex(where: { $0.id == current.id }) }
    private var prevEpisode: EpisodeShort? {
        guard let i = index, i > 0 else { return nil }
        return episodes[i - 1]
    }
    private var nextEpisode: EpisodeShort? {
        guard let i = index, i < episodes.count - 1 else { return nil }
        return episodes[i + 1]
    }

    private func go(_ ep: EpisodeShort?) {
        guard let ep = ep else { return }
        Haptics.tap()
        vm.stop()
        current = ep
    }

    private func seekPlayer(_ seconds: Double) {
        guard let p = vm.player else { return }
        let now = p.currentTime().seconds
        guard now.isFinite else { return }
        p.seek(to: CMTime(seconds: max(now + seconds, 0), preferredTimescale: 600))
    }

    private func pill(_ text: String) -> some View {
        HStack(spacing: 6) {
            Text(text).font(.subheadline.weight(.medium)).lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 14).padding(.vertical, 10)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func arrow(_ name: String, _ ep: EpisodeShort?) -> some View {
        Button { go(ep) } label: {
            Image(systemName: name)
                .font(.headline)
                .frame(width: 42, height: 40)
                .background(.ultraThinMaterial, in: Circle())
        }
        .buttonStyle(.pressable)
        .disabled(ep == nil)
        .opacity(ep == nil ? 0.35 : 1)
    }

    private var sourceNames: [String] {
        var out: [String] = []
        for v in vm.variants {
            let n = v.player.isEmpty ? "Другие" : v.player
            if !out.contains(n) { out.append(n) }
        }
        return out
    }

    private var controls: some View {
        VStack(spacing: 4) {
        HStack(spacing: 8) {
            arrow("chevron.left", prevEpisode)
            Menu {
                ForEach(sourceNames, id: \.self) { n in
                    Section(n) {
                        ForEach(vm.variants.filter { ($0.player.isEmpty ? "Другие" : $0.player) == n }) { v in
                            Button { vm.select(v) } label: {
                                if v.id == vm.current?.id { Label(v.title, systemImage: "checkmark") }
                                else { Text(v.title) }
                            }
                        }
                    }
                }
                if let v = vm.current, v.isWeb {
                    Divider()
                    if v.kodik && !vm.showWeb {
                        Button { vm.forceWeb() } label: { Label("Веб-плеер вместо прямого", systemImage: "globe") }
                    }
                    Link(destination: v.url) { Label("Открыть в Safari", systemImage: "safari") }
                }
            } label: {
                pill(vm.current?.title ?? (vm.isLoading ? "Загрузка…" : "Озвучка"))
            }
            .disabled(vm.variants.isEmpty)
            if vm.qualities.count > 1 {
                Menu {
                    ForEach(vm.qualities) { q in
                        Button { vm.pickQuality(q) } label: {
                            if q.id == vm.currentQuality { Label(q.title, systemImage: "checkmark") }
                            else { Text(q.title) }
                        }
                    }
                } label: {
                    pill(vm.qualities.first(where: { $0.id == vm.currentQuality })?.title ?? "Качество")
                        .frame(maxWidth: 110)
                }
            }
            arrow("chevron.right", nextEpisode)
        }
        if !vm.sourceNote.isEmpty {
            Text(vm.sourceNote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        }
        .padding(.horizontal, 14).padding(.vertical, 10)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ZStack {
                    Color.black
                    if vm.usesWeb, let v = vm.current {
                        WebPlayerView(url: v.url,
                                      onStream: v.kodik ? { vm.webStream($0) } : nil,
                                      onFullscreen: v.kodik ? { t, u in vm.webFullscreen(time: t, url: u) } : nil,
                                      interceptFS: v.kodik && Settings.bool("set.autoNative", true))
                    } else if let p = vm.player {
                        VideoPlayer(player: p)
                            .overlay(alignment: .topTrailing) {
                                Button { vm.openFullscreen() } label: {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.footnote.weight(.semibold))
                                        .foregroundStyle(.white)
                                        .frame(width: 34, height: 34)
                                        .background(.ultraThinMaterial, in: Circle())
                                }
                                .padding(8)
                            }
                    } else if vm.isLoading || vm.isResolving {
                        ProgressView().tint(.white)
                    } else if let e = vm.error {
                        Text(e).foregroundStyle(.white).padding()
                    }
                }
                .overlay(alignment: .bottom) {
                    if let e = vm.playbackError {
                        Text(e)
                            .font(.caption2)
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.leading)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.black.opacity(0.75))
                            .textSelection(.enabled)
                    }
                }
                .aspectRatio(16/9, contentMode: .fit)

                controls

                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        if !vm.debug.isEmpty {
                            Text(vm.debug)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                        }
                        CommentsSection(postID: current.id, postType: "episode")
                            .id(current.id)
                    }
                    .padding(.horizontal, 14)
                    .padding(.bottom, 20)
                }
            }
            .background(AppBackground())
            .navigationTitle(current.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Закрыть") { vm.stop(); dismiss() }
                }
            }
        }
        .task(id: current.id) {
            if let a = anime { HistoryStore.shared.record(anime: a, episode: current) }
            vm.onEnd = { go(nextEpisode) }
            await vm.load(episodeID: current.id)
        }
        .background {
            ZStack {
                KeyShortcut(.space) {
                    if let p = vm.player {
                        if p.timeControlStatus == .paused { p.play() } else { p.pause() }
                    }
                }
                KeyShortcut(.leftArrow) { seekPlayer(-10) }
                KeyShortcut(.rightArrow) { seekPlayer(10) }
            }
            .disabled(vm.usesWeb || vm.player == nil || vm.showNative)
            ZStack {
                KeyShortcut(.leftArrow, .command) { go(prevEpisode) }
                KeyShortcut(.rightArrow, .command) { go(nextEpisode) }
            }
            .disabled(vm.showNative)
        }
        .fullScreenCover(isPresented: $vm.showNative, onDismiss: { vm.closeNative() }) {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                FullscreenPlayer(player: vm.fsPlayer).ignoresSafeArea()
                if Platform.showsOwnCloseButton {
                    Button { vm.closeNative() } label: {
                        Image(systemName: "xmark")
                            .font(.headline)
                            .foregroundStyle(.white)
                            .frame(width: 40, height: 40)
                            .background(.ultraThinMaterial, in: Circle())
                    }
                    .padding(14)
                }
            }
        }
        .onDisappear { vm.stop() }
    }
}

// MARK: - JSON-помощники (формат ответов сайта разный, разбираем мягко)
enum J {
    static func obj(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    /// Строка из числа или строки (номера глав приходят и так, и так).
    static func s(_ v: Any?) -> String? {
        if let x = v as? String { return x.isEmpty ? nil : x }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
        return nil
    }

    static func text(_ v: Any?) -> String {
        if let s = v as? String { return stripHTML(s) }
        if let d = v as? [String: Any] {
            let type = (d["type"] as? String) ?? ""
            if type == "text" { return (d["text"] as? String) ?? "" }
            let inner = ((d["content"] as? [Any]) ?? []).map { text($0) }.joined()
            switch type {
            case "paragraph", "heading": return inner + "\n"
            case "hardBreak": return "\n"
            default: return inner
            }
        }
        if let a = v as? [Any] { return a.map { text($0) }.joined() }
        return ""
    }

    static func stripHTML(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var t = s.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func url(_ v: Any?) -> URL? {
        var s: String?
        if let x = v as? String { s = x }
        else if let d = v as? [String: Any] {
            s = str(d["url"]) ?? str(d["default"]) ?? str(d["md"]) ?? str(d["thumbnail"]) ?? str(d["src"])
        }
        guard var t = s else { return nil }
        if t.hasPrefix("//") { t = "https:" + t }
        if t.hasPrefix("/") { t = "https://cover.cdnlibs.org" + t }
        return URL(string: t)
    }

    static func date(_ s: String?) -> String {
        guard let s = s else { return "" }
        let f1 = ISO8601DateFormatter()
        f1.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let f2 = ISO8601DateFormatter()
        f2.formatOptions = [.withInternetDateTime]
        if let d = f1.date(from: s) ?? f2.date(from: s) {
            let out = DateFormatter()
            out.locale = Locale(identifier: "ru_RU")
            out.dateFormat = "d MMM yyyy"
            return out.string(from: d)
        }
        return String(s.prefix(10))
    }
}

// MARK: - Keychain (токен входа хранится в защищённом хранилище)
enum Keychain {
    static func set(_ value: String, key: String) {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func delete(_ key: String) {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}

// MARK: - Комментарии
struct CommentItem: Identifiable {
    let id: Int
    let text: String
    let username: String
    let avatar: URL?
    let up: Int
    let down: Int
    let date: String
    let created: String
    let replyCount: Int
    let replies: [CommentItem]

    init?(_ d: [String: Any], extra: [CommentItem] = []) {
        guard let cid = J.int(d["id"]) else { return nil }
        id = cid
        text = J.text(d["comment"] ?? d["content"] ?? d["text"] ?? d["body"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let u = (d["user"] as? [String: Any]) ?? [:]
        username = J.str(u["username"]) ?? J.str(u["name"]) ?? "Аноним"
        avatar = J.url(u["avatar"])
        let votes = d["votes"] as? [String: Any]
        up = J.int(votes?["up"]) ?? J.int(d["likes_count"]) ?? J.int(d["likes"]) ?? J.int(d["votes_up"]) ?? 0
        down = J.int(votes?["down"]) ?? J.int(d["dislikes_count"]) ?? 0
        date = J.date(J.str(d["created_at"]) ?? J.str(d["date"]))
        created = J.str(d["created_at"]) ?? J.str(d["date"]) ?? ""
        let rawReplies = (d["replies"] as? [[String: Any]])
            ?? (d["children"] as? [[String: Any]])
            ?? (d["comments"] as? [[String: Any]]) ?? []
        let parsed = rawReplies.compactMap { CommentItem($0) } + extra
        replies = parsed
        replyCount = max(parsed.count, J.int(d["comments_count"]) ?? J.int(d["replies_count"])
            ?? J.int(d["children_count"]) ?? 0)
    }
}

/// Ответ сервера может быть списком или объектом со вложенными массивами:
/// собираем все комментарии, где бы они ни лежали, и выстраиваем ветки по parent_comment.
enum CommentParser {
    static func collect(_ v: Any, into out: inout [[String: Any]]) {
        if let d = v as? [String: Any] {
            if J.int(d["id"]) != nil, d["comment"] != nil { out.append(d); return }
            for k in d.keys.sorted() { if let x = d[k] { collect(x, into: &out) } }
        } else if let a = v as? [Any] {
            for x in a { collect(x, into: &out) }
        }
    }

    static func parse(_ root: Any) -> [CommentItem] {
        var raw: [[String: Any]] = []
        collect(root, into: &raw)
        var seen = Set<Int>()
        raw = raw.filter { d in
            guard let id = J.int(d["id"]) else { return false }
            return seen.insert(id).inserted
        }
        let ids = Set(raw.compactMap { J.int($0["id"]) })
        var children: [Int: [[String: Any]]] = [:]
        var tops: [[String: Any]] = []
        for d in raw {
            if let p = J.int(d["parent_comment"]), p != J.int(d["id"]), ids.contains(p) {
                children[p, default: []].append(d)
            } else {
                tops.append(d)
            }
        }
        func build(_ d: [String: Any], depth: Int) -> CommentItem? {
            let id = J.int(d["id"]) ?? 0
            let kids = depth < 6 ? (children[id] ?? []).compactMap { build($0, depth: depth + 1) } : []
            return CommentItem(d, extra: kids)
        }
        return tops.compactMap { build($0, depth: 0) }
    }
}

enum CommentSort: String, CaseIterable {
    case new = "Новые"
    case popular = "Популярные"
}

@MainActor
final class CommentsViewModel: ObservableObject {
    @Published var items: [CommentItem] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var debug = ""
    @Published var loadingReplies: Set<Int> = []
    @Published var repliesLoaded: [Int: [CommentItem]] = [:]
    @Published var replyTarget: CommentItem?

    @Published var sort: CommentSort = .new
    let animeID: Int
    let slug: String
    private(set) var types: [String]
    var type: String { types.first ?? "anime" }
    private var page = 1
    private var finished = false

    init(animeID: Int, slug: String, postType: String? = nil, alternatives: [String] = []) {
        self.animeID = animeID
        self.slug = slug
        self.types = [postType ?? LibSite.current.postType] + alternatives
    }

    var sorted: [CommentItem] {
        switch sort {
        case .new:
            return items.sorted { $0.created == $1.created ? $0.id > $1.id : $0.created > $1.created }
        case .popular:
            return items.sorted { $0.up == $1.up ? $0.created > $1.created : $0.up > $1.up }
        }
    }

    func setSort(_ s: CommentSort) async {
        sort = s
        if s == .popular {
            var n = 0
            while !finished && n < 4 { await loadMore(); n += 1 }
        }
    }

    private func q(_ n: String, _ v: String) -> URLQueryItem { URLQueryItem(name: n, value: v) }

    private func firstPageQuery() -> [URLQueryItem] {
        [q("post_id", String(animeID)), q("post_type", type), q("page", "1")]
    }

    private func fetch(page: Int) async throws -> ([CommentItem], Bool?) {
        let attempts: [(String, [URLQueryItem])] = types.map {
            ("/comments", [q("post_id", String(animeID)), q("post_type", $0), q("page", String(page))])
        }
        var lastError: Error = APIError.badURL
        for (path, query) in attempts {
            do {
                let data = try await AnimelibAPI.shared.rawData(path, query: query, token: AuthStore.shared.token)
                guard let root = J.obj(data) else { continue }
                let list = CommentParser.parse(root)
                let meta = (root as? [String: Any])?["meta"] as? [String: Any]
                if let used = query.first(where: { $0.name == "post_type" })?.value, types.count > 1 {
                    types = [used]
                }
                return (list, meta?["has_next_page"] as? Bool)
            } catch {
                lastError = error
            }
        }
        if types.count > 1 {
            throw NSError(domain: "comments", code: 1, userInfo: [NSLocalizedDescriptionKey:
                "Сайт не принял ни один тип комментариев (\(types.joined(separator: ", "))). Последняя ошибка: \(lastError.localizedDescription)"])
        }
        throw lastError
    }

    func loadMore() async {
        guard !isLoading, !finished else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let (list, hasNext) = try await fetch(page: page)
            let known = Set(items.map { $0.id })
            let fresh = list.filter { !known.contains($0.id) }
            items += fresh
            page += 1
            if fresh.isEmpty || hasNext == false { finished = true }
            error = nil
            if items.isEmpty {
                debug = await AnimelibAPI.shared.rawText("/comments", query: firstPageQuery())
            }
        } catch {
            finished = true
            if items.isEmpty {
                self.error = error.localizedDescription
                debug = await AnimelibAPI.shared.rawText("/comments", query: firstPageQuery())
            }
        }
    }

    func reload() async {
        items = []
        repliesLoaded = [:]
        page = 1
        finished = false
        await loadMore()
    }

    /// Возвращает текст ошибки или nil при успехе.
    func send(_ text: String, parent: Int?) async -> String? {
        guard let t = AuthStore.shared.token else { return "Сначала войдите во вкладке «Профиль»" }
        var base: [String: Any] = ["comment": text, "post_id": animeID, "post_type": type]
        if let p = parent { base["parent_comment"] = p }
        var alt = base
        alt["is_spoiler"] = false
        alt["attachments"] = [Any]()
        var last = ""
        for b in [base, alt] {
            do {
                _ = try await AnimelibAPI.shared.rawData("/comments", token: t, method: "POST", json: b)
                return nil
            } catch {
                last = error.localizedDescription
            }
        }
        return last
    }

    func like(_ id: Int) async -> String? {
        guard let t = AuthStore.shared.token else { return "Сначала войдите во вкладке «Профиль»" }
        let attempts: [(String, [String: Any])] = [
            ("/comments/\(id)/vote", ["type": "up"]),
            ("/comments/\(id)/vote", ["vote": 1]),
            ("/comments/\(id)/like", [:])
        ]
        var last = ""
        for (path, body) in attempts {
            do {
                _ = try await AnimelibAPI.shared.rawData(path, token: t, method: "POST", json: body)
                return nil
            } catch {
                last = error.localizedDescription
            }
        }
        return last
    }

    func loadReplies(_ c: CommentItem) async {
        loadingReplies.insert(c.id)
        defer { loadingReplies.remove(c.id) }
        let known = Set(items.map { $0.id })
        for key in ["parent_comment", "parent_id", "parent_comment_id"] {
            let query = [q("post_id", String(animeID)), q("post_type", type), q(key, String(c.id))]
            if let data = try? await AnimelibAPI.shared.rawData("/comments", query: query, token: AuthStore.shared.token),
               let root = J.obj(data) {
                let list = CommentParser.parse(root).filter { $0.id != c.id && !known.contains($0.id) }
                if !list.isEmpty { repliesLoaded[c.id] = list; return }
            }
        }
        repliesLoaded[c.id] = []
    }
}

struct CommentRow: View {
    let c: CommentItem
    var depth = 0
    @ObservedObject var vm: CommentsViewModel
    @State private var expanded = false
    @State private var liked = false
    @State private var note: String?

    private var children: [CommentItem] {
        c.replies.isEmpty ? (vm.repliesLoaded[c.id] ?? []) : c.replies
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                RemoteImage(url: c.avatar)
                    .frame(width: 38, height: 38)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text(c.username).font(.subheadline.bold())
                        Text(c.date).font(.caption).foregroundStyle(.secondary)
                    }
                    Text(c.text)
                        .font(.subheadline)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 16) {
                        Button {
                            Task {
                                if let e = await vm.like(c.id) { note = e } else { liked = true; note = nil; Haptics.tap() }
                            }
                        } label: {
                            Label("\(c.up + (liked ? 1 : 0))", systemImage: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                                .font(.caption)
                                .foregroundStyle(liked ? Theme.accent : Color.secondary)
                        }
                        .buttonStyle(.pressable)
                        if c.down > 0 {
                            Label("\(c.down)", systemImage: "hand.thumbsdown").font(.caption)
                        }
                        if AuthStore.shared.token != nil {
                            Button { vm.replyTarget = c } label: {
                                Text("Ответить").font(.caption.bold()).foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.pressable)
                        }
                        if c.replyCount > 0 {
                            Button {
                                expanded.toggle()
                                if expanded && children.isEmpty { Task { await vm.loadReplies(c) } }
                            } label: {
                                Text(expanded ? "Скрыть ответы" : "Ответы (\(c.replyCount))")
                                    .font(.caption.bold())
                                    .foregroundStyle(Theme.accent)
                            }
                            .buttonStyle(.pressable)
                        }
                    }
                    .foregroundStyle(.secondary)
                    .padding(.top, 2)
                    if let n = note {
                        Text("Не вышло: " + n).font(.caption2).foregroundStyle(.orange)
                    }
                }
                Spacer(minLength: 0)
            }
            if expanded {
                if vm.loadingReplies.contains(c.id) { ProgressView() }
                ForEach(children) { r in
                    CommentRow(c: r, depth: depth + 1, vm: vm)
                }
                .padding(.leading, depth < 2 ? 18 : 0)
            }
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct ComposeSheet: View {
    let title: String
    let send: (String) async -> String?
    let onSent: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var error: String?
    @State private var sending = false

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(10)
                    .frame(minHeight: 180)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                if let e = error {
                    Text(e).font(.footnote).foregroundStyle(.orange)
                }
                Spacer()
            }
            .padding(14)
            .background(AppBackground())
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(sending ? "…" : "Отправить") {
                        Task {
                            sending = true
                            error = await send(text.trimmingCharacters(in: .whitespacesAndNewlines))
                            sending = false
                            if error == nil { onSent(); dismiss() }
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || sending)
                }
            }
        }
    }
}

struct CommentSortMenu: View {
    @ObservedObject var vm: CommentsViewModel

    var body: some View {
        Menu {
            Picker("Сортировка", selection: Binding(get: { vm.sort }, set: { s in Task { await vm.setSort(s) } })) {
                ForEach(CommentSort.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Label(vm.sort.rawValue, systemImage: "arrow.up.arrow.down")
                .font(.subheadline)
        }
    }
}

struct CommentsList: View {
    @ObservedObject var vm: CommentsViewModel

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(vm.sorted) { c in
                CommentRow(c: c, vm: vm)
                    .onAppear {
                        if c.id == vm.items.last?.id { Task { await vm.loadMore() } }
                    }
            }
            if vm.isLoading { ProgressView().padding() }
            if let e = vm.error {
                Text(e).font(.footnote).foregroundStyle(.red).padding(.top, 30)
            }
            if vm.items.isEmpty && !vm.isLoading {
                if vm.error == nil {
                    Text("Комментариев пока нет").foregroundStyle(.secondary).padding(.top, 30)
                }
                if !vm.debug.isEmpty {
                    Text(vm.debug)
                        .font(.system(size: 9, design: .monospaced))
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

extension View {
    func commentSheets(_ vm: CommentsViewModel, showCompose: Binding<Bool>) -> some View {
        self
            .sheet(isPresented: showCompose) {
                ComposeSheet(title: "Новый комментарий",
                             send: { await vm.send($0, parent: nil) },
                             onSent: { Task { await vm.reload() } })
            }
            .sheet(item: Binding(get: { vm.replyTarget }, set: { vm.replyTarget = $0 })) { target in
                ComposeSheet(title: "Ответ для \(target.username)",
                             send: { await vm.send($0, parent: target.id) },
                             onSent: { Task { await vm.reload() } })
            }
    }
}

/// Комментарии к серии: встраиваются под плеером.
struct CommentsSection: View {
    @StateObject private var vm: CommentsViewModel
    @State private var showCompose = false

    init(postID: Int, postType: String) {
        _vm = StateObject(wrappedValue: CommentsViewModel(animeID: postID, slug: "", postType: postType,
                                                                alternatives: postType == "episode"
                                                                    ? ["episodes", "anime_episode", "animeEpisode", "anime-episode", "video", "chapter"] : []))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Комментарии").font(.headline)
                Spacer()
                CommentSortMenu(vm: vm)
                Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                    .padding(.leading, 8)
            }
            CommentsList(vm: vm)
        }
        .padding(.top, 4)
        .commentSheets(vm, showCompose: $showCompose)
        .task { await vm.loadMore() }
    }
}

struct CommentsView: View {
    let anime: Anime
    @StateObject private var vm: CommentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCompose = false

    init(anime: Anime) {
        self.anime = anime
        _vm = StateObject(wrappedValue: CommentsViewModel(animeID: anime.id, slug: anime.slugUrl ?? String(anime.id)))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                CommentsList(vm: vm).padding(14)
            }
            .background(AppBackground())
            .navigationTitle("Комментарии")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        CommentSortMenu(vm: vm)
                        Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .commentSheets(vm, showCompose: $showCompose)
            .task { await vm.loadMore() }
        }
    }
}

// MARK: - Вход через сайт и профиль
struct ProfileUser {
    let id: Int
    let username: String
    let avatar: URL?
    var streak: Int? = nil
    var maxStreak: Int? = nil
    var level: Int? = nil
    var premium = false
    var cover: URL? = nil
}

@MainActor
final class AuthStore: ObservableObject {
    static let shared = AuthStore()
    @Published var token: String?
    @Published var user: ProfileUser?
    @Published var error: String?
    @Published var coverDebug = ""

    init() {
        token = Keychain.get("lib.token")
        if token != nil { Task { await refreshUser() } }
    }

    func signIn(access: String, refresh: String?) async {
        token = access
        Keychain.set(access, key: "lib.token")
        if let r = refresh { Keychain.set(r, key: "lib.refresh") }
        await refreshUser()
    }

    func signOut() {
        token = nil
        user = nil
        Keychain.delete("lib.token")
        Keychain.delete("lib.refresh")
        WKWebsiteDataStore.default().removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(),
                                                modifiedSince: .distantPast) {}
    }

    nonisolated static func coverURL(_ d: [String: Any]) -> URL? { deepCover(d, depth: 0) }

    /// Ищем баннер по любому ключу с «cover», «background» или «banner», в том числе во вложенных объектах.
    nonisolated private static func deepCover(_ d: [String: Any], depth: Int) -> URL? {
        let hints = ["cover", "background", "banner", "header", "bg"]
        for (k, v) in d where hints.contains(where: { k.lowercased().contains($0) }) {
            if let u = J.url(v) { return u }
        }
        if depth < 3 {
            for (_, v) in d {
                if let nested = v as? [String: Any], let u = deepCover(nested, depth: depth + 1) { return u }
            }
        }
        return nil
    }

    /// Баннер может прийти только в публичном профиле, поэтому спрашиваем его отдельно.
    private func loadCover(id: Int, token: String) async {
        var log: [String] = []
        let variants: [[String]] = [[], ["background"], ["cover"], ["banner"]]
        for fields in variants {
            let q = fields.map { URLQueryItem(name: "fields[]", value: $0) }
            let label = fields.first ?? "без полей"
            do {
                let data = try await AnimelibAPI.shared.rawData("/user/\(id)", query: q, token: token)
                guard let root = J.obj(data) as? [String: Any] else { log.append("\(label): не JSON"); continue }
                let d = (root["data"] as? [String: Any]) ?? root
                if let u = AuthStore.coverURL(d) { user?.cover = u; coverDebug = ""; return }
                log.append("\(label): ключи " + d.keys.sorted().joined(separator: ","))
            } catch APIError.http(let code, _) {
                log.append("\(label): HTTP \(code)")
            } catch {
                log.append("\(label): сбой")
            }
        }
        coverDebug = log.joined(separator: "\n")
    }

    func refreshUser() async {
        guard let t = token else { return }
        do {
            let data = try await AnimelibAPI.shared.rawData("/auth/me", token: t)
            guard let root = J.obj(data) as? [String: Any] else { throw APIError.badURL }
            let d = (root["data"] as? [String: Any]) ?? root
            guard let id = J.int(d["id"]) else { throw APIError.badURL }
            let st = d["login_streak"] as? [String: Any]
            user = ProfileUser(id: id,
                               username: J.str(d["username"]) ?? J.str(d["name"]) ?? "Профиль",
                               avatar: J.url(d["avatar"]),
                               streak: J.int(st?["login_streak"]) ?? J.int(d["login_streak"]),
                               maxStreak: J.int(st?["max_login_streak"]),
                               level: J.int(d["level"]) ?? J.int((d["user_level"] as? [String: Any])?["level"]),
                               premium: ((d["premium"] as? [String: Any])?["enabled"] as? Bool) ?? false,
                               cover: AuthStore.coverURL(d))
            error = nil
            if user?.cover == nil { await loadCover(id: id, token: t) }
        } catch {
            if case APIError.http(let code, _) = error, code == 401 || code == 403 {
                signOut()
                self.error = "Сессия закончилась, войдите снова"
            } else {
                self.error = error.localizedDescription
            }
        }
    }
}

struct LoginWebView: UIViewRepresentable {
    var onToken: (String, String?) -> Void

    final class Coordinator {
        var timer: Timer?
        weak var web: WKWebView?
        var onToken: ((String, String?) -> Void)?
        var done = false
    }
    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let v = WKWebView(frame: .zero, configuration: WKWebViewConfiguration())
        v.customUserAgent = Kodik.ua
        v.isOpaque = false
        v.backgroundColor = .black
        v.load(URLRequest(url: URL(string: "https://animelib.org/ru/")!))
        let c = context.coordinator
        c.web = v
        c.onToken = onToken
        c.timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak c] _ in
            guard let c = c, let web = c.web, !c.done else { return }
            web.evaluateJavaScript("JSON.stringify(Object.assign({}, window.localStorage))") { res, _ in
                guard let s = res as? String,
                      let data = s.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data),
                      let tok = LoginWebView.findToken(obj) else { return }
                c.done = true
                c.timer?.invalidate()
                DispatchQueue.main.async { c.onToken?(tok.0, tok.1) }
            }
        }
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) { context.coordinator.onToken = onToken }

    static func dismantleUIView(_ v: WKWebView, coordinator: Coordinator) {
        coordinator.timer?.invalidate()
    }

    static func findToken(_ obj: Any) -> (String, String?)? {
        if let d = obj as? [String: Any] {
            if let a = d["access_token"] as? String, !a.isEmpty { return (a, d["refresh_token"] as? String) }
            for v in d.values { if let r = findToken(v) { return r } }
        } else if let arr = obj as? [Any] {
            for v in arr { if let r = findToken(v) { return r } }
        } else if let s = obj as? String, s.hasPrefix("{") || s.hasPrefix("["),
                  let data = s.data(using: .utf8),
                  let o = try? JSONSerialization.jsonObject(with: data) {
            return findToken(o)
        }
        return nil
    }
}

struct LoginSheet: View {
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("Войдите на сайте как обычно. Как только вход завершится, приложение подхватит его само.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(10)
                LoginWebView { access, refresh in
                    Task {
                        await auth.signIn(access: access, refresh: refresh)
                        dismiss()
                    }
                }
            }
            .background(AppBackground())
            .navigationTitle("Вход через сайт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            }
        }
    }
}

struct BookmarkFolder: Identifiable, Hashable {
    let id: Int
    let name: String
    let count: Int?
}

@MainActor
final class ProfileViewModel: ObservableObject {
    @Published var folders: [BookmarkFolder] = []
    @Published var selected: Int?
    @Published var items: [Anime] = []
    @Published var isLoading = false
    @Published var error: String?
    @Published var debug = ""
    var totalTitles: Int { folders.compactMap { $0.count }.reduce(0, +) }

    private var userID: Int?
    private var token: String?
    private var page = 1
    private var finished = false

    func configure(userID: Int, token: String) {
        self.userID = userID
        self.token = token
    }

    func loadFolders() async {
        guard let uid = userID, let t = token else { return }
        do {
            let data = try await AnimelibAPI.shared.rawData("/bookmarks/folder/\(uid)", token: t)
            guard let root = J.obj(data) as? [String: Any],
                  let arr = root["data"] as? [[String: Any]] else {
                error = "Неожиданный ответ сервера для списков"
                debug = await AnimelibAPI.shared.rawText("/bookmarks/folder/\(uid)", token: t)
                return
            }
            folders = arr.compactMap { d -> BookmarkFolder? in
                guard let id = J.int(d["id"]) else { return nil }
                return BookmarkFolder(id: id,
                                      name: J.str(d["name"]) ?? J.str(d["title"]) ?? "Список",
                                      count: J.int(d["count"]) ?? J.int(d["items_count"]) ?? J.int(d["titles_count"]))
            }
            let nonEmpty = folders.filter { ($0.count ?? 1) > 0 }
            if !nonEmpty.isEmpty { folders = nonEmpty }
            if selected == nil || !folders.contains(where: { $0.id == selected }) {
                selected = folders.first?.id
            }
            error = nil
            await reload()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func select(_ id: Int) async {
        selected = id
        await reload()
    }

    func reload() async {
        items = []
        page = 1
        finished = false
        debug = ""
        await loadMore()
    }

    func loadMore() async {
        guard !isLoading, !finished, let uid = userID, let t = token else { return }
        isLoading = true
        defer { isLoading = false }
        var query = [URLQueryItem(name: "user_id", value: String(uid)),
                     URLQueryItem(name: "page", value: String(page))]
        if let s = selected { query.append(URLQueryItem(name: "status", value: String(s))) }
        do {
            let data = try await AnimelibAPI.shared.rawData("/bookmarks", query: query, token: t)
            guard let root = J.obj(data) as? [String: Any],
                  let arr = root["data"] as? [[String: Any]] else { finished = true; return }
            let list = arr.compactMap { Self.anime(from: $0) }
            let known = Set(items.map { $0.id })
            let fresh = list.filter { !known.contains($0.id) }
            items += fresh
            page += 1
            if fresh.isEmpty { finished = true }
            error = nil
            if items.isEmpty {
                debug = await AnimelibAPI.shared.rawText("/bookmarks", query: query, token: t)
            }
        } catch {
            finished = true
            self.error = error.localizedDescription
        }
    }

    static func anime(from d: [String: Any]) -> Anime? {
        var candidates: [[String: Any]] = []
        for v in d.values { if let sub = v as? [String: Any] { candidates.append(sub) } }
        candidates.append(d)
        var best: (Int, Anime)?
        for c in candidates {
            guard J.int(c["id"]) != nil else { continue }
            var score = 0
            if J.str(c["rus_name"]) != nil { score += 4 }
            if J.str(c["name"]) != nil { score += 2 }
            if c["cover"] != nil { score += 2 }
            if J.str(c["slug_url"]) != nil { score += 1 }
            guard score >= 3,
                  let data = try? JSONSerialization.data(withJSONObject: c),
                  let a = try? JSONDecoder().decode(Anime.self, from: data) else { continue }
            if best == nil || score > best!.0 { best = (score, a) }
        }
        return best?.1
    }
}

struct BookmarkSheet: View {
    let anime: Anime
    @ObservedObject private var auth = AuthStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var folders: [BookmarkFolder] = []
    @State private var message: String?
    @State private var done: Int?
    @State private var busy = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    if auth.token == nil {
                        Text("Войдите во вкладке «Профиль», чтобы добавлять тайтлы в свои списки на сайте.")
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.top, 40)
                    } else {
                        ForEach(folders) { f in
                            Button { Task { await add(f) } } label: {
                                HStack {
                                    Text(f.name).foregroundStyle(.primary)
                                    Spacer()
                                    if done == f.id {
                                        Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent)
                                    }
                                }
                                .padding(14)
                                .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                            }
                            .buttonStyle(.pressable)
                            .disabled(busy)
                        }
                        if !folders.isEmpty {
                            Button(role: .destructive) { Task { await remove() } } label: {
                                Text("Убрать из списков").frame(maxWidth: .infinity).padding(12)
                            }
                            .disabled(busy)
                        }
                    }
                    if let m = message {
                        Text(m).font(.footnote).foregroundStyle(.orange).padding(.top, 6)
                    }
                }
                .padding(14)
            }
            .background(AppBackground())
            .navigationTitle("В список")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } } }
            .task { await loadFolders() }
        }
    }

    private func loadFolders() async {
        guard let t = auth.token, let uid = auth.user?.id else { return }
        do {
            let data = try await AnimelibAPI.shared.rawData("/bookmarks/folder/\(uid)", token: t)
            guard let root = J.obj(data) as? [String: Any],
                  let arr = root["data"] as? [[String: Any]] else { return }
            folders = arr.compactMap { d in
                guard let id = J.int(d["id"]) else { return nil }
                return BookmarkFolder(id: id, name: J.str(d["name"]) ?? J.str(d["title"]) ?? "Список", count: nil)
            }
        } catch {
            message = error.localizedDescription
        }
    }

    private func add(_ f: BookmarkFolder) async {
        guard let t = auth.token else { return }
        busy = true
        defer { busy = false }
        let bodies: [[String: Any]] = [
            ["id": anime.id, "type": f.id, "model": LibSite.current.postType],
            ["bookmark": ["type": f.id], "id": anime.id, "model": LibSite.current.postType],
            ["type": f.id, "relation_id": anime.id, "relation_type": LibSite.current.postType]
        ]
        var last = ""
        for b in bodies {
            do {
                _ = try await AnimelibAPI.shared.rawData("/bookmarks", token: t, method: "POST", json: b)
                done = f.id
                message = nil
                return
            } catch {
                last = error.localizedDescription
            }
        }
        message = "Не получилось добавить: " + last
    }

    private func remove() async {
        guard let t = auth.token else { return }
        busy = true
        defer { busy = false }
        for q in [[URLQueryItem(name: "type", value: LibSite.current.postType)], []] {
            do {
                _ = try await AnimelibAPI.shared.rawData("/bookmarks/\(anime.id)", query: q, token: t, method: "DELETE")
                done = nil
                message = "Убрано из списков"
                return
            } catch {
                message = "Не получилось убрать: " + error.localizedDescription
            }
        }
    }
}

struct ProfileView: View {
    @ObservedObject private var auth = AuthStore.shared
    @StateObject private var vm = ProfileViewModel()
    @State private var showLogin = false
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14)]

    private func folderIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("любим") { return "heart.fill" }
        if n.contains("смотрю") || n.contains("читаю") { return "play.circle.fill" }
        if n.contains("план") { return "calendar" }
        if n.contains("просмотр") || n.contains("прочитан") { return "checkmark.circle.fill" }
        if n.contains("брош") { return "xmark.circle.fill" }
        if n.contains("отлож") { return "pause.circle.fill" }
        if n.contains("не нрав") { return "hand.thumbsdown.fill" }
        return "bookmark.fill"
    }

    private func stat(_ icon: String, _ tint: Color, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let u = auth.user {
                    VStack(spacing: 16) {
                        VStack(spacing: 0) {
                            Group {
                                if let c = u.cover {
                                    AnimatedRemoteImage(url: c, maxPixel: 900)
                                } else {
                                    LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.15)],
                                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                                }
                            }
                            .frame(height: 150)
                            .clipped()
                            .overlay(alignment: .bottom) {
                                LinearGradient(colors: [.clear, Theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 70)
                            }

                            AnimatedRemoteImage(url: u.avatar, maxPixel: 360)
                                .frame(width: 92, height: 92)
                                .clipShape(RoundedRectangle(cornerRadius: 22))
                                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.base, lineWidth: 4))
                                .overlay(alignment: .topTrailing) {
                                    Circle().fill(Color.green)
                                        .frame(width: 18, height: 18)
                                        .overlay(Circle().stroke(Theme.base, lineWidth: 3))
                                        .offset(x: 6, y: -6)
                                }
                                .padding(.top, -46)

                            VStack(spacing: 10) {
                                Text(u.username).font(.title2.bold())
                                if u.premium {
                                    Label("Premium", systemImage: "crown.fill")
                                        .font(.caption.bold())
                                        .foregroundStyle(.yellow)
                                }
                                HStack(spacing: 8) {
                                    if let st = u.streak { stat("flame.fill", .orange, "Серия: \(st) дн.") }
                                    if let lv = u.level { stat("star.fill", .yellow, "Уровень \(lv)") }
                                    if vm.totalTitles > 0 { stat("rectangle.stack.fill", Theme.accent, "\(vm.totalTitles) тайтлов") }
                                }
                                Button("Выйти") { auth.signOut() }
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                            .padding(.top, 10)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 16)
                        }
                        .frame(maxWidth: .infinity)
                        .background(Theme.card)
                        .clipShape(RoundedRectangle(cornerRadius: 22))
                        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.chip))

                        if u.cover == nil && !auth.coverDebug.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Баннер профиля не найден. Пришли этот текст разработчику:")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(auth.coverDebug)
                                    .font(.system(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !vm.folders.isEmpty {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                                ForEach(vm.folders) { f in
                                    Button { Task { await vm.select(f.id) } } label: {
                                        VStack(alignment: .leading, spacing: 6) {
                                            HStack {
                                                Image(systemName: folderIcon(f.name)).font(.subheadline)
                                                Spacer()
                                                Text(f.count.map(String.init) ?? "")
                                                    .font(.title3.bold())
                                            }
                                            Text(f.name)
                                                .font(.caption.weight(.semibold))
                                                .lineLimit(1)
                                                .minimumScaleFactor(0.8)
                                        }
                                        .padding(12)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .foregroundStyle(f.id == vm.selected ? Color.white : Color.primary)
                                        .background(
                                            f.id == vm.selected
                                                ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent.opacity(0.6)],
                                                                               startPoint: .topLeading, endPoint: .bottomTrailing))
                                                : AnyShapeStyle(Material.ultraThinMaterial),
                                            in: RoundedRectangle(cornerRadius: 16))
                                        .overlay(RoundedRectangle(cornerRadius: 16).stroke(Theme.chip))
                                    }
                                    .buttonStyle(.pressable)
                                }
                            }
                        }

                        if let e = vm.error {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(vm.items) { anime in
                                TitleLink(anime: anime) { AnimeCard(anime: anime) }
                                    .buttonStyle(.pressable)
                                    .onAppear {
                                        if anime.id == vm.items.last?.id { Task { await vm.loadMore() } }
                                    }
                            }
                        }
                        if vm.isLoading { ProgressView() }
                        if vm.items.isEmpty && !vm.isLoading {
                            Text("В этом списке пока ничего нет").foregroundStyle(.secondary)
                            if !vm.debug.isEmpty && ((vm.folders.first { $0.id == vm.selected }?.count ?? 0) > 0) {
                                Text(vm.debug)
                                    .font(.system(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .padding(14)
                } else if auth.token != nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        if let e = auth.error {
                            Text(e).font(.footnote).foregroundStyle(.red)
                            Button("Повторить") { Task { await auth.refreshUser() } }
                            Button("Выйти") { auth.signOut() }.foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 80)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accent)
                        Text("Профиль").font(.title2.bold())
                        Text("Войдите через сайт, чтобы видеть свои списки: смотрю, в планах, просмотрено и другие.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if let e = auth.error {
                            Text(e).font(.footnote).foregroundStyle(.orange)
                        }
                        Button { showLogin = true } label: {
                            Text("Войти через сайт")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.pressable)
                    }
                    .padding(24)
                    .padding(.top, 40)
                }
            }
            .background(AppBackground())
            .navigationTitle("Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .sheet(isPresented: $showLogin) { LoginSheet() }
            .task(id: auth.user?.id) {
                if let u = auth.user, let t = auth.token {
                    vm.configure(userID: u.id, token: t)
                    await vm.loadFolders()
                }
            }
        }
    }
}

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
    var readKey: Int { LibSite.current.isManga ? -id : id }
}

struct NovelChapter: Identifiable, Hashable {
    let id: Int
    let volume: String
    let number: String
    let name: String

    init(id: Int, volume: String, number: String, name: String) {
        self.id = id; self.volume = volume; self.number = number; self.name = name
    }

    var saved: SavedChapter { SavedChapter(id: id, volume: volume, number: number, name: name) }

    init?(_ d: [String: Any]) {
        guard let cid = J.int(d["id"]) else { return nil }
        id = cid
        volume = J.s(d["volume"]) ?? "1"
        number = J.s(d["number"]) ?? "0"
        name = J.str(d["name"]) ?? ""
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
@MainActor
final class ReadStore: ObservableObject {
    static let shared = ReadStore()
    @Published private(set) var read: [String: [Int]] = [:]
    @Published private(set) var last: [String: Int] = [:]

    init() {
        if let d = UserDefaults.standard.data(forKey: "read.v1"),
           let v = try? JSONDecoder().decode([String: [Int]].self, from: d) { read = v }
        if let d = UserDefaults.standard.data(forKey: "readlast.v1"),
           let v = try? JSONDecoder().decode([String: Int].self, from: d) { last = v }
    }

    func isRead(_ novel: Int, _ chapter: Int) -> Bool { read[String(novel)]?.contains(chapter) ?? false }
    func lastChapter(_ novel: Int) -> Int? { last[String(novel)] }

    func mark(_ novel: Int, _ chapter: Int) {
        var list = read[String(novel)] ?? []
        if !list.contains(chapter) { list.append(chapter) }
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
            if let img = UIImage(contentsOfFile: url.path) { image = img } else { failed = true }
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


// MARK: - Ранобэ: офлайн-хранилище
struct SavedChapter: Codable {
    let id: Int
    let volume: String
    let number: String
    let name: String
}

struct OfflineEntry: Codable {
    var novel: Anime
    var chapters: [SavedChapter]
    var files: [Int: Int]
    var updated: Date
}

func fmtBytes(_ n: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
}

/// Скачанные главы лежат в Application Support/Offline/<id тайтла>/:
/// <id главы>.json (ответ сайта как есть) и картинки <id главы>_<хэш>.img.
@MainActor
final class OfflineStore: ObservableObject {
    static let shared = OfflineStore()
    @Published private(set) var entries: [Int: OfflineEntry] = [:]
    nonisolated let root: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent("Offline", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var rv = URLResourceValues()
        rv.isExcludedFromBackup = true
        try? dir.setResourceValues(rv)
        root = dir
        if let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
           let v = try? JSONDecoder().decode([Int: OfflineEntry].self, from: d) { entries = v }
    }

    nonisolated func folder(_ novel: Int) -> URL { root.appendingPathComponent(String(novel), isDirectory: true) }
    nonisolated func chapterFile(_ novel: Int, _ chapter: Int) -> URL { folder(novel).appendingPathComponent("\(chapter).json") }
    nonisolated func coverFile(_ novel: Int) -> URL { folder(novel).appendingPathComponent("cover.img") }
    nonisolated func imageFile(novel: Int, chapter: Int, url: URL) -> URL {
        var h: UInt64 = 5381
        for b in url.absoluteString.utf8 { h = (h &* 33) &+ UInt64(b) }
        return folder(novel).appendingPathComponent("\(chapter)_\(String(h, radix: 36)).img")
    }

    private func persist() {
        if let d = try? JSONEncoder().encode(entries) {
            try? d.write(to: root.appendingPathComponent("manifest.json"), options: .atomic)
        }
    }

    var allEntries: [OfflineEntry] { entries.values.sorted { $0.updated > $1.updated } }
    var totalBytes: Int { entries.values.reduce(0) { $0 + $1.files.values.reduce(0, +) } }
    func isDownloaded(_ novel: Int, _ chapter: Int) -> Bool { entries[novel]?.files[chapter] != nil }
    func downloadedCount(_ novel: Int) -> Int { entries[novel]?.files.count ?? 0 }

    func coverURL(_ novel: Int) -> URL? {
        let f = coverFile(novel)
        return FileManager.default.fileExists(atPath: f.path) ? f : nil
    }

    /// Список глав, сохранённый вместе с тайтлом, только скачанные.
    func savedChapters(_ novel: Int) -> [NovelChapter] {
        guard let e = entries[novel] else { return [] }
        return e.chapters
            .filter { e.files[$0.id] != nil }
            .map { NovelChapter(id: $0.id, volume: $0.volume, number: $0.number, name: $0.name) }
    }

    /// Обновляем сохранённый список глав, пока есть сеть (чтобы офлайн было что показать).
    func refresh(novel: Anime, chapters: [NovelChapter]) {
        guard var e = entries[novel.id] else { return }
        e.novel = novel
        e.chapters = chapters.map { $0.saved }
        entries[novel.id] = e
        persist()
    }

    func record(novel: Anime, chapters: [NovelChapter], chapter: NovelChapter, raw: Data, extraBytes: Int) {
        try? FileManager.default.createDirectory(at: folder(novel.id), withIntermediateDirectories: true)
        try? raw.write(to: chapterFile(novel.id, chapter.id), options: .atomic)
        var e = entries[novel.id] ?? OfflineEntry(novel: novel, chapters: [], files: [:], updated: Date())
        e.novel = novel
        if !chapters.isEmpty { e.chapters = chapters.map { $0.saved } }
        e.files[chapter.id] = raw.count + extraBytes
        e.updated = Date()
        entries[novel.id] = e
        persist()
    }

    func remove(novel: Int, chapter: Int) {
        guard var e = entries[novel] else { return }
        try? FileManager.default.removeItem(at: chapterFile(novel, chapter))
        let prefix = "\(chapter)_"
        if let names = try? FileManager.default.contentsOfDirectory(atPath: folder(novel).path) {
            for n in names where n.hasPrefix(prefix) {
                try? FileManager.default.removeItem(at: folder(novel).appendingPathComponent(n))
            }
        }
        e.files[chapter] = nil
        if e.files.isEmpty {
            remove(novel: novel)
        } else {
            entries[novel] = e
            persist()
        }
    }

    func remove(novel: Int) {
        try? FileManager.default.removeItem(at: folder(novel))
        entries[novel] = nil
        persist()
    }

    func removeAll() {
        for id in Array(entries.keys) { try? FileManager.default.removeItem(at: folder(id)) }
        entries = [:]
        persist()
    }

    /// Глава с телефона: картинки подменяются локальными файлами.
    func blocks(novel: Int, chapter: Int) -> [ReaderBlock]? {
        guard isDownloaded(novel, chapter),
              let data = try? Data(contentsOf: chapterFile(novel, chapter)),
              let root = J.obj(data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { return nil }
        let att = (d["attachments"] as? [[String: Any]]) ?? []
        let parsed = ReaderParser.parse(d["content"], attachments: att)
        if parsed.isEmpty { return nil }
        return parsed.map { (b: ReaderBlock) -> ReaderBlock in
            if case .image(let i, let u) = b {
                let f = imageFile(novel: novel, chapter: chapter, url: u)
                if FileManager.default.fileExists(atPath: f.path) { return .image(i, f) }
            }
            return b
        }
    }
}

// MARK: - Ранобэ: очередь загрузок
final class BackgroundBox {
    var id = UIBackgroundTaskIdentifier.invalid
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    struct Job {
        let novel: Anime
        let chapters: [NovelChapter]
        let chapter: NovelChapter
    }

    @Published private(set) var pending: Set<Int> = []
    @Published private(set) var current: Int?
    @Published private(set) var failed: [Int: String] = [:]
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    @Published private(set) var status = ""

    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    private var expensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let exp = path.isExpensive
            Task { @MainActor in self?.expensive = exp }
        }
        monitor.start(queue: DispatchQueue(label: "hehe.netmonitor"))
    }

    func enqueue(novel: Anime, all: [NovelChapter], targets: [NovelChapter]) {
        let store = OfflineStore.shared
        for c in targets where !store.isDownloaded(novel.id, c.id) && !pending.contains(c.id) {
            jobs.append(Job(novel: novel, chapters: all, chapter: c))
            pending.insert(c.id)
            failed[c.id] = nil
            total += 1
        }
        startIfNeeded()
    }

    func cancel(chapter id: Int) {
        guard let i = jobs.firstIndex(where: { $0.chapter.id == id }) else { return }
        jobs.remove(at: i)
        pending.remove(id)
        total = max(0, total - 1)
    }

    func cancelAll() {
        jobs.removeAll()
        pending = []
        worker?.cancel()
        worker = nil
        current = nil
        total = 0; done = 0; status = ""
    }

    private func startIfNeeded() {
        guard worker == nil, !jobs.isEmpty else { return }
        worker = Task { [weak self] in await self?.run() }
    }

    private func run() async {
        let box = BackgroundBox()
        box.id = UIApplication.shared.beginBackgroundTask(withName: "hehe.download") {
            let id = box.id
            box.id = .invalid
            if id != .invalid { UIApplication.shared.endBackgroundTask(id) }
        }
        while !Task.isCancelled, !jobs.isEmpty {
            let job = jobs.removeFirst()
            current = job.chapter.id
            if Settings.bool("off.wifi", false) {
                while expensive && !Task.isCancelled {
                    status = "Ждём Wi‑Fi…"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            if Task.isCancelled { break }
            status = job.chapter.title
            do {
                try await download(job)
            } catch {
                if Task.isCancelled { break }
                failed[job.chapter.id] = error.localizedDescription
            }
            if Task.isCancelled { break }
            done += 1
            pending.remove(job.chapter.id)
            try? await Task.sleep(nanoseconds: 350_000_000)
        }
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
        if Task.isCancelled { return }
        if done > 0 { Haptics.success() }
        current = nil
        status = ""
        total = 0
        done = 0
        worker = nil
    }

    private func download(_ job: Job) async throws {
        guard let slug = job.novel.slugUrl else { throw APIError.badURL }
        let c = job.chapter
        var raw: Data?
        var lastError: Error = APIError.badURL
        for attempt in 0..<3 {
            do {
                raw = try await AnimelibAPI.shared.rawData(NovelService.chapterPath(slug: slug),
                                                           query: NovelService.chapterQuery(c))
                break
            } catch APIError.http(let code, let body) where code == 429 || code >= 500 {
                lastError = APIError.http(code, body)
                try await Task.sleep(nanoseconds: UInt64(3_000_000_000 * (attempt + 1)))
            }
        }
        guard let raw, let root = J.obj(raw) as? [String: Any],
              let d = root["data"] as? [String: Any] else { throw lastError }
        let att = (d["attachments"] as? [[String: Any]]) ?? []
        let blocks = ReaderParser.parse(d["content"], attachments: att)
        if blocks.isEmpty {
            throw NSError(domain: "offline", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Текст главы пуст или недоступен"])
        }
        var urls: [URL] = []
        for b in blocks {
            if case .image(_, let u) = b, !urls.contains(u) { urls.append(u) }
        }
        let store = OfflineStore.shared
        let nid = job.novel.id
        try? FileManager.default.createDirectory(at: store.folder(nid), withIntermediateDirectories: true)
        let targets: [(URL, URL)] = urls.map { ($0, store.imageFile(novel: nid, chapter: c.id, url: $0)) }
        var imageBytes = 0
        var start = 0
        while start < targets.count {
            let chunk = Array(targets[start..<min(start + 4, targets.count)])
            start += 4
            imageBytes += await withTaskGroup(of: Int.self) { group -> Int in
                for (u, f) in chunk { group.addTask { await DownloadManager.fetchImage(u, to: f) } }
                var sum = 0
                for await n in group { sum += n }
                return sum
            }
            if Task.isCancelled { throw CancellationError() }
        }
        if let cover = job.novel.imageURL, store.coverURL(nid) == nil {
            _ = await DownloadManager.fetchImage(cover, to: store.coverFile(nid))
        }
        store.record(novel: job.novel, chapters: job.chapters, chapter: c, raw: raw, extraBytes: imageBytes)
    }

    nonisolated static func fetchImage(_ url: URL, to file: URL) async -> Int {
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return size }
        for attempt in 0..<3 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("https://ranobelib.me/", forHTTPHeaderField: "Referer")
            if let (data, resp) = try? await URLSession.shared.data(for: req),
               (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
               !data.isEmpty, UIImage(data: data) != nil {
                try? data.write(to: file, options: .atomic)
                return data.count
            }
            try? await Task.sleep(nanoseconds: UInt64(600_000_000 * (attempt + 1)))
        }
        return 0
    }
}

struct ChapterDownloadButton: View {
    let novel: Anime
    let chapters: [NovelChapter]
    let chapter: NovelChapter
    @ObservedObject private var store = OfflineStore.shared
    @ObservedObject private var dl = DownloadManager.shared

    var body: some View {
        let saved = store.isDownloaded(novel.id, chapter.id)
        let queued = dl.pending.contains(chapter.id)
        Button {
            if queued { dl.cancel(chapter: chapter.id) }
            else if !saved { dl.enqueue(novel: novel, all: chapters, targets: [chapter]) }
        } label: {
            Group {
                if saved {
                    Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.green)
                } else if queued {
                    if dl.current == chapter.id { ProgressView() }
                    else { Image(systemName: "clock").foregroundStyle(.secondary) }
                } else if dl.failed[chapter.id] != nil {
                    Image(systemName: "exclamationmark.circle").foregroundStyle(Color.orange)
                } else {
                    Image(systemName: "arrow.down.circle").foregroundStyle(.secondary)
                }
            }
            .font(.title3)
            .frame(width: 34, height: 34)
        }
        .buttonStyle(.pressable)
    }
}

struct OfflineLibraryView: View {
    @ObservedObject private var store = OfflineStore.shared
    @State private var confirmAll = false

    var body: some View {
        List {
            if store.allEntries.isEmpty {
                Text("Пока ничего не скачано. Откройте тайтл и нажмите «Скачать» над списком глав.")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Color.clear)
            }
            ForEach(store.allEntries, id: \.novel.id) { e in
                NavigationLink(value: Novel(e.novel)) {
                    HStack(spacing: 12) {
                        RemoteImage(url: store.coverURL(e.novel.id) ?? e.novel.imageURL)
                            .frame(width: 50, height: 74)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(e.novel.displayTitle)
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text("\(e.files.count) гл. · \(fmtBytes(e.files.values.reduce(0, +)))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listRowBackground(Color.clear)
                .swipeActions {
                    Button(role: .destructive) { store.remove(novel: e.novel.id) } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(AppBackground())
        .navigationTitle("Скачанное")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
        .navigationDestination(for: AuthorRef.self) { AuthorView(author: $0) }
        .toolbar {
            if !store.allEntries.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Удалить всё", role: .destructive) { confirmAll = true }
                }
            }
        }
        .confirmationDialog("Удалить все скачанные главы?", isPresented: $confirmAll, titleVisibility: .visible) {
            Button("Удалить всё", role: .destructive) { store.removeAll() }
        }
    }
}

// MARK: - Ранобэ: экран тайтла
@MainActor
final class NovelDetailViewModel: ObservableObject {
    @Published var anime: Anime
    @Published var chapters: [NovelChapter] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var offline = false

    init(anime: Anime) { self.anime = anime }

    func load() async {
        isLoading = true
        error = nil
        guard let slug = anime.slugUrl else {
            error = "У тайтла нет адреса"
            isLoading = false
            return
        }
        async let d = AnimelibAPI.shared.details(slug: slug)
        async let c = NovelService.chapters(slug: slug)
        if let full = try? await d { anime = full }
        do {
            let list = try await c
            chapters = list
            offline = false
            if !LibSite.current.isManga { OfflineStore.shared.refresh(novel: anime, chapters: list) }
        } catch {
            let saved = OfflineStore.shared.savedChapters(anime.id)
            if saved.isEmpty {
                self.error = error.localizedDescription
            } else {
                chapters = saved
                offline = true
            }
        }
        isLoading = false
    }

    var volumeGroups: [(volume: String, indices: [Int])] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (i, c) in chapters.enumerated() {
            if map[c.volume] == nil { order.append(c.volume) }
            map[c.volume, default: []].append(i)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

struct ReaderStart: Identifiable {
    let id: Int
}

struct NovelDetailView: View {
    @StateObject private var vm: NovelDetailViewModel
    @ObservedObject private var read = ReadStore.shared
    @ObservedObject private var favorites = FavoritesStore.current
    @State private var expanded = false
    @State private var reversed = false
    @State private var reader: ReaderStart?
    @State private var showComments = false
    @State private var showBookmark = false
    @ObservedObject private var store = OfflineStore.shared
    @ObservedObject private var dl = DownloadManager.shared
    @State private var confirmRemove = false
    private var isManga: Bool { LibSite.current.isManga }

    init(novel: Novel) { _vm = StateObject(wrappedValue: NovelDetailViewModel(anime: novel.anime)) }

    private var backdrop: some View {
        ZStack {
            Theme.base
            RemoteImage(url: vm.anime.imageURL, maxPixel: 96).blur(radius: 16).opacity(0.55)
            LinearGradient(colors: [.clear, Theme.base.opacity(0.85), Theme.base], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var resumeIndex: Int {
        if let last = read.lastChapter(vm.anime.readKey),
           let i = vm.chapters.firstIndex(where: { $0.id == last }) { return i }
        return 0
    }

    private func queue(_ idx: [Int]) {
        dl.enqueue(novel: vm.anime, all: vm.chapters, targets: idx.map { vm.chapters[$0] })
    }

    private func nextIndices(_ n: Int) -> [Int] {
        let start = read.lastChapter(vm.anime.readKey) == nil ? 0 : resumeIndex
        return Array(vm.chapters.indices.dropFirst(start).prefix(n))
    }

    private var downloadMenu: some View {
        Menu {
            Button { queue(Array(vm.chapters.indices)) } label: {
                Label("Скачать все главы", systemImage: "arrow.down.circle")
            }
            Button {
                queue(vm.chapters.indices.filter { !read.isRead(vm.anime.readKey, vm.chapters[$0].id) })
            } label: {
                Label("Скачать непрочитанные", systemImage: "book.closed")
            }
            Menu {
                ForEach([5, 10, 25, 50], id: \.self) { n in
                    Button("\(n) глав") { queue(nextIndices(n)) }
                }
            } label: {
                Label("Следующие главы…", systemImage: "forward.end")
            }
            if store.downloadedCount(vm.anime.id) > 0 {
                Divider()
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Удалить загруженные", systemImage: "trash")
                }
            }
        } label: {
            let n = store.downloadedCount(vm.anime.id)
            Label(n > 0 ? "Скачано: \(n)" : "Скачать", systemImage: "arrow.down.circle")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func volumeButton(_ idx: [Int]) -> some View {
        let all = idx.allSatisfy { store.isDownloaded(vm.anime.id, vm.chapters[$0].id) }
        if all {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.footnote)
        } else {
            Button { queue(idx) } label: {
                Label("Скачать том", systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.accent)
        }
    }

    private var downloadBanner: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Загрузка: \(dl.done) из \(dl.total)" + (dl.status.isEmpty ? "" : " · " + dl.status))
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Стоп") { dl.cancelAll() }
                .font(.caption.bold())
        }
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
    }

    private func row(_ i: Int) -> some View {
        let c = vm.chapters[i]
        let isRead = read.isRead(vm.anime.readKey, c.id)
        let saved = store.isDownloaded(vm.anime.id, c.id)
        return HStack(spacing: 8) {
            Button { reader = ReaderStart(id: i) } label: {
                HStack(spacing: 12) {
                    Text(c.number)
                        .font(.footnote.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isRead ? Color.secondary : Color.primary)
                        .frame(width: 42, height: 42)
                        .background(isRead ? Color.gray.opacity(0.3) : Theme.accent.opacity(0.28), in: Circle())
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name.isEmpty ? "Глава \(c.number)" : c.name)
                            .font(.subheadline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let f = dl.failed[c.id] {
                            Text(f).font(.caption2).foregroundStyle(Color.orange).lineLimit(1)
                        } else if isRead {
                            Text("Прочитано").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(isRead ? Color.secondary : Color.primary)
                    Spacer()
                    Image(systemName: isRead ? "checkmark.circle.fill" : "book.fill")
                        .foregroundStyle(isRead ? Color.gray : Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            if !isManga { ChapterDownloadButton(novel: vm.anime, chapters: vm.chapters, chapter: c) }
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
        .contextMenu {
            if isManga {
                Button { reader = ReaderStart(id: i) } label: { Label("Читать", systemImage: "book") }
            } else if saved {
                Button(role: .destructive) { store.remove(novel: vm.anime.id, chapter: c.id) } label: {
                    Label("Удалить загрузку", systemImage: "trash")
                }
            } else {
                Button { queue([i]) } label: { Label("Скачать главу", systemImage: "arrow.down.circle") }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    RemoteImage(url: vm.anime.imageURL)
                        .frame(width: 120, height: 180)
                        .clipShape(RoundedRectangle(cornerRadius: 16))
                        .shadow(color: .black.opacity(0.5), radius: 10, y: 5)
                    VStack(alignment: .leading, spacing: 8) {
                        Text(vm.anime.displayTitle).font(.title3.bold())
                        if let n = vm.anime.name, n != vm.anime.displayTitle {
                            Text(n).font(.caption).foregroundStyle(.secondary)
                        }
                        FlowLayout(spacing: 6) {
                            if let s = vm.anime.status?.title, !s.isEmpty { Pill(icon: "dot.radiowaves.left.and.right", text: s) }
                            if let t = vm.anime.type?.title, !t.isEmpty { Pill(icon: "book", text: t) }
                            if let a = vm.anime.ageRestriction?.title, !a.isEmpty { Pill(icon: "exclamationmark.shield", text: a) }
                            if let r = vm.anime.rateAvg { Pill(icon: "star.fill", text: r) }
                            if !vm.chapters.isEmpty { Pill(icon: "list.bullet", text: "\(vm.chapters.count) гл.") }
                        }
                    }
                }

                if !vm.chapters.isEmpty {
                    Button { reader = ReaderStart(id: resumeIndex) } label: {
                        HStack {
                            Image(systemName: "book.fill")
                            Text(read.lastChapter(vm.anime.readKey) == nil
                                 ? "Начать читать"
                                 : "Продолжить: Глава \(vm.chapters[resumeIndex].number)")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 16))
                        .foregroundStyle(.white)
                    }
                    .buttonStyle(.pressable)
                }

                if let g = vm.anime.genres, !g.isEmpty {
                    FlowLayout(spacing: 6) {
                        ForEach(g, id: \.id) { item in
                            Text(item.title)
                                .font(.caption)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(Theme.accent.opacity(0.28), in: Capsule())
                        }
                    }
                }

                if let s = vm.anime.summary, !s.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(s).font(.callout).lineLimit(expanded ? nil : 5)
                        if s.count > 220 {
                            Button(expanded ? "Свернуть" : "Читать полностью") {
                                withAnimation { expanded.toggle() }
                            }
                            .font(.footnote.bold())
                        }
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))
                }

                if let au = vm.anime.authors, !au.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Автор").font(.footnote.bold()).foregroundStyle(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(Array(au.enumerated()), id: \.offset) { _, a in
                                if let aid = a.id {
                                    NavigationLink(value: AuthorRef(id: aid, name: a.title, slug: a.slug)) {
                                        HStack(spacing: 6) {
                                            Image(systemName: "person.fill")
                                            Text(a.title)
                                            Image(systemName: "chevron.right").font(.caption2)
                                        }
                                        .font(.subheadline.weight(.medium))
                                        .foregroundStyle(Theme.accent)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.chip, in: Capsule())
                                    }
                                    .buttonStyle(.pressable)
                                } else {
                                    Text(a.title)
                                        .font(.subheadline)
                                        .padding(.horizontal, 12).padding(.vertical, 7)
                                        .background(Theme.chip, in: Capsule())
                                }
                            }
                        }
                    }
                }

                if let url = titleURL(vm.anime) {
                    Link(destination: url) {
                        Label("Открыть на сайте", systemImage: "safari")
                            .font(.subheadline)
                            .padding(.horizontal, 14).padding(.vertical, 9)
                            .background(Theme.chip, in: Capsule())
                    }
                }

                Button { showComments = true } label: {
                    HStack {
                        Image(systemName: "bubble.left.and.bubble.right.fill").foregroundStyle(Theme.accent)
                        Text("Комментарии").font(.subheadline.weight(.semibold))
                        Spacer()
                        Image(systemName: "chevron.right").font(.footnote).foregroundStyle(.secondary)
                    }
                    .padding(14)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                }
                .buttonStyle(.pressable)

                HStack {
                    Text("Главы").font(.title3.bold())
                    Spacer()
                    if !vm.chapters.isEmpty && !isManga { downloadMenu }
                    if vm.chapters.count > 1 {
                        Button { withAnimation { reversed.toggle() } } label: {
                            Label(reversed ? "Сначала новые" : "Сначала старые", systemImage: "arrow.up.arrow.down")
                                .font(.footnote)
                        }
                        .padding(.leading, 6)
                    }
                }
                if dl.total > 0 { downloadBanner }
                if vm.offline {
                    Text("Нет сети: показаны только скачанные главы.")
                        .font(.footnote).foregroundStyle(Color.orange)
                }
                if vm.isLoading { ProgressView() }
                if let e = vm.error { Text(e).foregroundStyle(.red).font(.footnote) }
                if !vm.isLoading && vm.chapters.isEmpty && vm.error == nil {
                    Text("Глав пока нет").foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    let groups = reversed ? Array(vm.volumeGroups.reversed()) : vm.volumeGroups
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        HStack {
                            Text("Том \(g.volume)")
                                .font(.footnote.bold())
                                .foregroundStyle(.secondary)
                            Spacer()
                            if !isManga { volumeButton(g.indices) }
                        }
                        .padding(.top, 8)
                        ForEach(reversed ? Array(g.indices.reversed()) : g.indices, id: \.self) { i in
                            row(i)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(backdrop)
        .navigationTitle(vm.anime.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: AuthorRef.self) { AuthorView(author: $0) }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let u = titleURL(vm.anime) {
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                }
                Button { showBookmark = true } label: { Image(systemName: "bookmark") }
                Button { favorites.toggle(vm.anime) } label: {
                    Image(systemName: favorites.contains(vm.anime) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.contains(vm.anime) ? Color.pink : Color.primary)
                }
            }
        }
        .task { await vm.load() }
        .sheet(isPresented: $showComments) { CommentsView(anime: vm.anime) }
        .sheet(isPresented: $showBookmark) { BookmarkSheet(anime: vm.anime) }
        .confirmationDialog("Удалить загруженные главы этого тайтла?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                store.remove(novel: vm.anime.id)
                if vm.offline { vm.chapters = [] }
            }
        }
        .fullScreenCover(item: $reader) { r in
            if isManga {
                MangaReaderView(novel: vm.anime, chapters: vm.chapters, start: r.id)
            } else {
                NovelReaderView(novel: vm.anime, chapters: vm.chapters, start: r.id)
            }
        }
    }
}

// MARK: - Манга: страницы и читалка
struct MangaPage: Identifiable, Hashable {
    let id: Int
    let urls: [URL]
    let width: CGFloat
    let height: CGFloat

    var url: URL { urls[0] }
    var ratio: CGFloat { width > 0 && height > 0 ? height / width : 0 }
    /// Страница должна занять по ширине экран, поэтому длинным полосам разрешаем больше пикселей.
    var maxPixel: CGFloat { min(4096, max(1300, 1300 * (ratio > 0 ? ratio : 1.5))) }
}

actor MangaImageServers {
    static let shared = MangaImageServers()
    private var cached: [String]?
    private let fallback = "https://img3.cdnlibs.org"

    func bases() async -> [String] {
        if let c = cached { return c }
        var list: [String] = []
        let q = [URLQueryItem(name: "fields[]", value: "imageServers")]
        if let data = try? await AnimelibAPI.shared.rawData("/constants", query: q),
           let root = J.obj(data) as? [String: Any],
           let d = root["data"] as? [String: Any],
           let arr = d["imageServers"] as? [[String: Any]] {
            let mine = arr.filter { srv in
                guard let ids = srv["site_ids"] as? [Any], !ids.isEmpty else { return true }
                return ids.contains { J.int($0) == 1 }
            }
            let main = mine.filter { ($0["id"] as? String) == "main" }
            let rest = mine.filter { ($0["id"] as? String) != "main" }
            list = (main + rest).compactMap { J.str($0["url"]) }
            if !list.isEmpty { cached = list + (list.contains(fallback) ? [] : [fallback]) }
        }
        if !list.contains(fallback) { list.append(fallback) }
        return list
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
    static func pages(slug: String, chapter c: NovelChapter) async throws -> [MangaPage] {
        let data = try await AnimelibAPI.shared.rawData(NovelService.chapterPath(slug: slug),
                                                        query: NovelService.chapterQuery(c))
        guard let root = J.obj(data) as? [String: Any],
              let d = root["data"] as? [String: Any] else { throw APIError.badURL }
        let raw = (d["pages"] as? [[String: Any]]) ?? []
        let bases = await MangaImageServers.shared.bases()
        func num(_ v: Any?) -> CGFloat {
            if let x = v as? Double { return CGFloat(x) }
            return CGFloat(J.int(v) ?? 0)
        }
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
        cfg.urlCache = URLCache(memoryCapacity: 30_000_000, diskCapacity: 400_000_000)
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        return URLSession(configuration: cfg)
    }()

    private static let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    func image(for page: MangaPage) async -> UIImage? {
        let key = ImageCache.key(page.url, page.maxPixel)
        if let c = ImageCache.shared.object(forKey: key) { return c }
        let id = key as String
        if let t = inflight[id] { return await t.value.0 }
        let urls = page.urls
        let px = page.maxPixel
        let t = Task.detached(priority: .userInitiated) { () -> (UIImage?, String) in
            var note = ""
            for round in 0..<2 {
                for u in urls {
                    var req = URLRequest(url: u)
                    req.setValue(LibSite.manga.referer, forHTTPHeaderField: "Referer")
                    req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                    req.setValue(MangaImageStore.agent, forHTTPHeaderField: "User-Agent")
                    do {
                        let (data, resp) = try await MangaImageStore.session.data(for: req)
                        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
                        if (200..<300).contains(code) {
                            if let img = ImageLoader.downsample(data, maxPixel: px) {
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
}

struct MangaPageView: View {
    let page: MangaPage
    var vertical = false
    var dim: CGFloat = 1
    let onTap: (CGFloat) -> Void
    @State private var image: UIImage?
    @State private var failed = false
    @State private var note = ""
    @State private var attempt = 0
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    private func resetZoom() {
        scale = 1; base = 1; offset = .zero; lastOffset = .zero
    }

    var body: some View {
        Group {
            if vertical {
                flow
            } else {
                GeometryReader { geo in content(geo.size) }
            }
        }
        .task(id: "\(page.id)-\(attempt)") { await load() }
    }

    /// Режим ленты: страницы идут одна под другой, высота по картинке.
    @ViewBuilder
    private var flow: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { onTap(0.5) }
        } else if failed {
            Button { failed = false; attempt += 1 } label: {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise").font(.title3)
                    Text("Страница \(page.id + 1) не загрузилась. Нажми, чтобы повторить.")
                        .font(.footnote).multilineTextAlignment(.center)
                    if !note.isEmpty {
                        Text(note).font(.caption2).opacity(0.6).multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(20)
                .frame(maxWidth: .infinity, minHeight: 200)
            }
        } else {
            ZStack {
                Color.white.opacity(0.04)
                ProgressView().tint(.white)
            }
            .aspectRatio(page.ratio > 0 ? 1 / page.ratio : 0.7, contentMode: .fit)
            .frame(maxWidth: .infinity)
        }
    }

    @ViewBuilder
    private func content(_ size: CGSize) -> some View {
        if let image {
            if page.ratio > 2.2 {
                ScrollView(.vertical, showsIndicators: false) {
                    Image(uiImage: image).resizable().scaledToFit().frame(width: size.width)
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { v in onTap(v.location.x / max(size.width, 1)) })
            } else {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .colorMultiply(Color(white: dim))
                    .frame(width: size.width, height: size.height)
                    .scaleEffect(scale)
                    .offset(offset)
                    .contentShape(Rectangle())
                    .gesture(
                        TapGesture(count: 2).onEnded {
                            withAnimation(.easeOut(duration: 0.2)) {
                                if scale > 1 { resetZoom() } else { scale = 2.4; base = 2.4 }
                            }
                        }
                        .exclusively(before: SpatialTapGesture().onEnded { v in
                            onTap(v.location.x / max(size.width, 1))
                        })
                    )
                    .simultaneousGesture(
                        MagnificationGesture()
                            .onChanged { scale = min(max(base * $0, 1), 4) }
                            .onEnded { _ in
                                base = scale
                                if scale <= 1.02 { withAnimation { resetZoom() } }
                            }
                    )
                    .gesture(
                        DragGesture()
                            .onChanged { v in
                                offset = CGSize(width: lastOffset.width + v.translation.width,
                                                height: lastOffset.height + v.translation.height)
                            }
                            .onEnded { _ in lastOffset = offset },
                        including: scale > 1 ? .all : .none
                    )
            }
        } else if failed {
            Button { failed = false; attempt += 1 } label: {
                VStack(spacing: 10) {
                    Image(systemName: "arrow.clockwise").font(.title2)
                    Text("Страница \(page.id + 1) не загрузилась. Нажми, чтобы повторить.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                    if !note.isEmpty {
                        Text(note).font(.caption2).opacity(0.6).multilineTextAlignment(.center)
                    }
                }
                .foregroundStyle(.white.opacity(0.8))
                .padding(24)
                .frame(width: size.width, height: size.height)
            }
        } else {
            ProgressView().tint(.white).frame(width: size.width, height: size.height)
        }
    }

    private func load() async {
        if let img = await MangaImageStore.shared.image(for: page) {
            withAnimation(.easeOut(duration: 0.15)) { image = img }
            return
        }
        if Task.isCancelled { return }
        note = await MangaImageStore.shared.lastNote
        failed = true
    }
}

struct ChapterCommentsView: View {
    let novel: Anime
    let chapter: NovelChapter
    @StateObject private var vm: CommentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCompose = false

    init(novel: Anime, chapter: NovelChapter) {
        self.novel = novel
        self.chapter = chapter
        _vm = StateObject(wrappedValue: CommentsViewModel(animeID: chapter.id, slug: novel.slugUrl ?? String(novel.id),
                                                          postType: "chapter"))
    }

    var body: some View {
        NavigationStack {
            ScrollView { CommentsList(vm: vm).padding(14) }
                .background(AppBackground())
                .navigationTitle("Глава \(chapter.number)")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                    ToolbarItem(placement: .topBarTrailing) {
                        HStack(spacing: 12) {
                            CommentSortMenu(vm: vm)
                            Button { showCompose = true } label: { Image(systemName: "square.and.pencil") }
                        }
                    }
                }
                .commentSheets(vm, showCompose: $showCompose)
                .task { await vm.loadMore() }
        }
    }
}

/// Перелистывание как в Apple Books: страница загибается и переворачивается за край.
struct BookPager: UIViewControllerRepresentable {
    let count: Int
    @Binding var current: Int
    let content: (Int) -> AnyView

    final class Host: UIHostingController<AnyView> {
        var index = 0
    }

    final class Coordinator: NSObject, UIPageViewControllerDataSource, UIPageViewControllerDelegate {
        var parent: BookPager
        var shown = 0
        init(_ p: BookPager) { parent = p }

        func host(_ i: Int) -> Host? {
            guard i >= 0, i < parent.count else { return nil }
            let h = Host(rootView: parent.content(i))
            h.index = i
            h.view.backgroundColor = .black
            return h
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerBefore vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host else { return nil }
            return host(h.index - 1)
        }

        func pageViewController(_ pvc: UIPageViewController, viewControllerAfter vc: UIViewController) -> UIViewController? {
            guard let h = vc as? Host else { return nil }
            return host(h.index + 1)
        }

        func pageViewController(_ pvc: UIPageViewController, didFinishAnimating finished: Bool,
                                previousViewControllers: [UIViewController], transitionCompleted completed: Bool) {
            guard completed, let h = pvc.viewControllers?.first as? Host else { return }
            shown = h.index
            if parent.current != h.index { parent.current = h.index }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIPageViewController {
        let pvc = UIPageViewController(transitionStyle: .pageCurl, navigationOrientation: .horizontal)
        pvc.dataSource = context.coordinator
        pvc.delegate = context.coordinator
        pvc.isDoubleSided = false
        pvc.view.backgroundColor = .black
        // Свои зоны касаний у нас есть, встроенные отключаем, чтобы страницы не листались дважды.
        for g in pvc.gestureRecognizers where g is UITapGestureRecognizer { g.isEnabled = false }
        if let h = context.coordinator.host(current) {
            pvc.setViewControllers([h], direction: .forward, animated: false)
            context.coordinator.shown = current
        }
        return pvc
    }

    func updateUIViewController(_ pvc: UIPageViewController, context: Context) {
        let c = context.coordinator
        c.parent = self
        if c.shown != current, let h = c.host(current) {
            let dir: UIPageViewController.NavigationDirection = current > c.shown ? .forward : .reverse
            c.shown = current
            pvc.setViewControllers([h], direction: dir, animated: true)
        }
    }
}

struct MangaReaderSettings: View {
    @Binding var titleMode: String
    @Binding var defaultMode: String
    @Binding var anim: String
    let detected: String
    @Environment(\.dismiss) private var dismiss

    private func picker(_ sel: Binding<String>) -> some View {
        Picker("", selection: sel) {
            Text("Авто").tag("auto")
            Text("Страницы").tag("pages")
            Text("Лента").tag("scroll")
        }
        .pickerStyle(.segmented)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    picker($titleMode)
                } header: {
                    Text("Для этого тайтла")
                } footer: {
                    Text("«Страницы» для манги: листаешь свайпом. «Лента» для манхвы и веб-комиксов: прокручиваешь вниз. «Авто»: сейчас выбрано «\(detected)».")
                }
                Section {
                    Picker("", selection: $anim) {
                        Text("Сдвиг").tag("slide")
                        Text("Плавно").tag("fade")
                        Text("Как в книге").tag("book")
                    }
                    .pickerStyle(.segmented)
                } header: {
                    Text("Листание страниц")
                } footer: {
                    Text("«Сдвиг»: страница уезжает вбок. «Плавно»: одна страница мягко сменяет другую. «Как в книге»: тяни за край, и страница переворачивается. Работает в режиме «Страницы».")
                }
                Section {
                    picker($defaultMode)
                } header: {
                    Text("По умолчанию для остальных")
                } footer: {
                    Text("Работает, пока для тайтла выбрано «Авто» и у него нет своей настройки.")
                }
            }
            .navigationTitle("Режим чтения")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium])
    }
}

struct MangaReaderView: View {
    let novel: Anime
    let chapters: [NovelChapter]
    @State private var index: Int
    @State private var pages: [MangaPage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var chromeHidden = false
    @State private var current = 0
    @State private var scrollPage = 0
    @State private var showComments = false
    @State private var preloadTask: Task<Void, Never>?
    @State private var titleMode: String
    @State private var showSettings = false
    @AppStorage("manga.mode.default") private var defaultMode = "auto"
    @AppStorage("manga.anim") private var anim = "slide"
    @Environment(\.dismiss) private var dismiss

    init(novel: Anime, chapters: [NovelChapter], start: Int) {
        self.novel = novel
        self.chapters = chapters
        _titleMode = State(initialValue: UserDefaults.standard.string(forKey: "manga.mode.\(novel.id)") ?? "auto")
        _index = State(initialValue: min(max(start, 0), max(chapters.count - 1, 0)))
    }

    private var chapter: NovelChapter? { chapters.indices.contains(index) ? chapters[index] : nil }

    /// Манхву, маньхуа и длинные полосы читаем лентой, обычную мангу листаем.
    private var autoVertical: Bool {
        let t = (novel.type?.title ?? "").lowercased()
        if t.contains("манхв") || t.contains("маньхуа") || t.contains("веб") { return true }
        let r = pages.map { $0.ratio }.filter { $0 > 0 }.sorted()
        if r.isEmpty { return false }
        return r[r.count / 2] > 1.9
    }

    private var shown: Int { vertical ? scrollPage : current }

    private var vertical: Bool {
        switch titleMode == "auto" ? defaultMode : titleMode {
        case "scroll": return true
        case "pages": return false
        default: return autoVertical
        }
    }

    private func go(_ delta: Int) {
        let n = index + delta
        guard chapters.indices.contains(n) else { return }
        Haptics.tap()
        index = n
    }

    private func turn(_ delta: Int) {
        let n = current + delta
        if n < 0 { return }
        if n > pages.count { return }
        withAnimation(.easeOut(duration: 0.2)) { current = n }
    }

    private func handleTap(_ x: CGFloat) {
        if vertical || !Settings.bool("manga.tapzones", true) {
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
            return
        }
        if x < 0.3 { turn(-1) }
        else if x > 0.7 { turn(1) }
        else { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
    }

    /// Фоновая подгрузка: сначала открытая страница, потом остальные по порядку, по две за раз.
    private func preload(from start: Int) {
        preloadTask?.cancel()
        let list = pages
        guard !list.isEmpty else { return }
        let first = min(max(start, 0), list.count - 1)
        preloadTask = Task {
            var order = Array(first..<list.count)
            order += Array((0..<first).reversed())
            var i = 0
            while i < order.count {
                if Task.isCancelled { return }
                let n = i == 0 ? 1 : 2
                let chunk = Array(order[i..<min(i + n, order.count)])
                i += n
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk {
                        group.addTask { _ = await MangaImageStore.shared.image(for: list[id]) }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var pagedView: some View {
        switch anim {
        case "book":
            GeometryReader { geo in
                let ref = pages[min(current, pages.count - 1)]
                let ratio = ref.ratio > 0 ? ref.ratio : 1.5
                let w0 = geo.size.width
                let h0 = w0 * ratio
                let fitH = min(h0, geo.size.height)
                let fitW = h0 > geo.size.height ? fitH / ratio : w0
                ZStack {
                    Color.black
                        .contentShape(Rectangle())
                        .onTapGesture { handleTap(0.5) }
                    BookPager(count: pages.count + 1, current: $current) { i in
                        i < pages.count
                            ? AnyView(MangaPageView(page: pages[i], dim: 0.9, onTap: handleTap))
                            : AnyView(endCard)
                    }
                    .frame(width: fitW, height: fitH)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        case "fade":
            ZStack {
                if current < pages.count {
                    MangaPageView(page: pages[current], onTap: handleTap)
                        .id(current)
                        .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.04)),
                                                removal: .opacity))
                } else {
                    endCard.id(current).transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.25), value: current)
            .gesture(
                DragGesture(minimumDistance: 30).onEnded { v in
                    let dx = v.translation.width
                    guard abs(dx) > 60, abs(dx) > abs(v.translation.height) else { return }
                    turn(dx < 0 ? 1 : -1)
                }
            )
        default:
            TabView(selection: $current) {
                ForEach(pages) { p in
                    MangaPageView(page: p, onTap: handleTap).tag(p.id)
                }
                endCard.tag(pages.count)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
    }

    private var endCard: some View {
        VStack(spacing: 14) {
            Text(index + 1 < chapters.count ? "Глава закончилась" : "Это последняя глава")
                .font(.subheadline).foregroundStyle(.white.opacity(0.7))
            if index + 1 < chapters.count {
                Button { go(1) } label: {
                    Label("Следующая глава", systemImage: "chevron.right.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            }
            Button { showComments = true } label: {
                Label("Комментарии к главе", systemImage: "bubble.left.and.bubble.right")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.85))
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).frame(width: 40, height: 40)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(novel.displayTitle).font(.footnote.bold()).lineLimit(1)
                if let c = chapter {
                    Text("Том \(c.volume) · Глава \(c.number)").font(.caption2).opacity(0.7)
                }
            }
            Spacer()
            Button { showSettings = true } label: {
                Image(systemName: vertical ? "arrow.up.and.down.text.horizontal" : "book")
                    .frame(width: 40, height: 40)
            }
            Button { showComments = true } label: {
                Image(systemName: "bubble.left.and.bubble.right").frame(width: 40, height: 40)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.top, 6)
        .padding(.bottom, 10)
        .background(LinearGradient(colors: [.black.opacity(0.85), .clear], startPoint: .top, endPoint: .bottom))
    }

    private var bottomBar: some View {
        HStack {
            Button { go(-1) } label: { Image(systemName: "backward.end").frame(width: 48, height: 40) }
                .disabled(index == 0)
            Spacer()
            Text(pages.isEmpty ? "…" : "\(min(shown + 1, pages.count)) / \(pages.count)")
                .font(.footnote.monospacedDigit())
            Spacer()
            Button { go(1) } label: { Image(systemName: "forward.end").frame(width: 48, height: 40) }
                .disabled(index + 1 >= chapters.count)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.top, 10)
        .padding(.bottom, 6)
        .background(LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if !pages.isEmpty {
                if vertical {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pages) { p in
                                    MangaPageView(page: p, vertical: true, onTap: handleTap)
                                        .id(p.id)
                                        .onAppear { scrollPage = p.id }
                                }
                                endCard.frame(height: 360).id(pages.count)
                            }
                        }
                        .onAppear {
                            if current > 0 { proxy.scrollTo(current, anchor: .top) }
                        }
                    }
                    .id("v\(index)")
                    .ignoresSafeArea(edges: .bottom)
                } else {
                    pagedView
                        .id("p\(index)-\(anim)")
                        .ignoresSafeArea()
                }
            }
            if loading {
                ProgressView().tint(.white)
            }
            if let e = error {
                VStack(spacing: 10) {
                    Text(e).font(.footnote).foregroundStyle(.red).multilineTextAlignment(.center)
                    Button("Повторить") { Task { await load() } }
                }
                .padding(24)
            }

            VStack {
                if !chromeHidden { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
                Spacer()
                if !chromeHidden { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
            }
        }
        .chromeStatusBar(chromeHidden)
        .background {
            ZStack {
                KeyShortcut(.leftArrow) { turn(-1) }
                KeyShortcut(.rightArrow) { turn(1) }
                KeyShortcut(.space) { turn(1) }
            }
            .disabled(vertical || loading || showComments || showSettings)
            ZStack {
                KeyShortcut(.leftArrow, .command) { go(-1) }
                KeyShortcut(.rightArrow, .command) { go(1) }
                KeyShortcut(.escape) { dismiss() }
            }
            .disabled(showComments || showSettings)
        }
        .preferredColorScheme(.dark)
        .task(id: index) { await load() }
        .onChange(of: current) { v in
            Haptics.select()
            if !vertical && v < pages.count { preload(from: v) }
        }
        .onChange(of: scrollPage) { v in
            if vertical && v < pages.count { preload(from: v) }
        }
        .onChange(of: vertical) { v in
            if v { scrollPage = current } else { current = min(scrollPage, pages.count) }
        }
        .onChange(of: titleMode) { v in
            UserDefaults.standard.set(v, forKey: "manga.mode.\(novel.id)")
        }
        .sheet(isPresented: $showSettings) {
            MangaReaderSettings(titleMode: $titleMode, defaultMode: $defaultMode, anim: $anim,
                                detected: autoVertical ? "лента" : "страницы")
        }
        .sheet(isPresented: $showComments) {
            if let c = chapter { ChapterCommentsView(novel: novel, chapter: c) }
        }
        .onAppear { KeepAwake.set(Settings.bool("set.keepAwake", true)) }
        .onDisappear {
            KeepAwake.set(false)
            preloadTask?.cancel()
        }
    }

    private func load() async {
        guard let ch = chapter, let slug = novel.slugUrl else { return }
        preloadTask?.cancel()
        loading = true
        error = nil
        pages = []
        current = 0
        scrollPage = 0
        ReadStore.shared.mark(novel.readKey, ch.id)
        HistoryStore.current.recordChapter(anime: novel, chapterID: ch.id, title: ch.title)
        do {
            let result = try await MangaService.pages(slug: slug, chapter: ch)
            if Task.isCancelled { return }
            pages = result
            if result.isEmpty {
                error = "У главы нет страниц или она недоступна."
            } else {
                preload(from: 0)
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - Ранобэ: постраничное чтение
enum NovelPage: Identifiable {
    case text(Int, NSAttributedString)
    case image(Int, URL)

    var id: Int {
        switch self {
        case .text(let i, _), .image(let i, _): return i
        }
    }
}

/// Режет текст главы на страницы по размеру экрана средствами TextKit.
enum NovelPaginator {
    static func font(_ size: CGFloat, serif: Bool, bold: Bool = false, italic: Bool = false) -> UIFont {
        var d = UIFont.systemFont(ofSize: size).fontDescriptor
        if serif, let s = d.withDesign(.serif) { d = s }
        var traits = d.symbolicTraits
        if bold { traits.insert(.traitBold) }
        if italic { traits.insert(.traitItalic) }
        if let t = d.withSymbolicTraits(traits) { d = t }
        return UIFont(descriptor: d, size: size)
    }

    static func split(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let ns = text.string as NSString
        var ranges: [NSRange] = []
        var loc = 0
        while loc < text.length && ranges.count < 3000 {
            let tc = NSTextContainer(size: size)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let glyphs = lm.glyphRange(for: tc)
            if glyphs.length == 0 { break }
            var r = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            loc = NSMaxRange(r)
            while r.length > 0 && ns.character(at: r.location) == 10 {
                r.location += 1
                r.length -= 1
            }
            if r.length > 0 { ranges.append(r) }
        }
        return ranges
    }

    static func paginate(blocks: [ReaderBlock], title: String, size: CGSize, fontSize: CGFloat,
                         serif: Bool, lineGap: CGFloat, color: UIColor) -> [NovelPage] {
        var pages: [NovelPage] = []
        let text = NSMutableAttributedString()

        func style(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0,
                   align: NSTextAlignment = .natural) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = fontSize * lineGap
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            p.headIndent = indent
            p.firstLineHeadIndent = indent
            p.alignment = align
            p.lineBreakMode = .byWordWrapping
            return p
        }
        func add(_ s: String, _ f: UIFont, _ st: NSParagraphStyle) {
            text.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: st]))
        }
        func flush() {
            guard text.length > 0 else { return }
            for r in split(text, size: size) {
                pages.append(.text(pages.count, text.attributedSubstring(from: r)))
            }
            text.deleteCharacters(in: NSRange(location: 0, length: text.length))
        }

        let body = font(fontSize, serif: serif)
        add(title + "\n", font(fontSize + 6, serif: serif, bold: true), style(spacing: fontSize))
        for b in blocks {
            switch b {
            case .paragraph(_, let t):
                add(t + "\n", body, style(spacing: fontSize * 0.6))
            case .rich(_, let a):
                let st = style(spacing: fontSize * 0.6)
                for run in a.runs {
                    let piece = String(a[run.range].characters)
                    let intent = run.inlinePresentationIntent ?? []
                    let f = font(fontSize, serif: serif, bold: intent.contains(.stronglyEmphasized),
                                 italic: intent.contains(.emphasized))
                    add(piece, f, st)
                }
                add("\n", body, st)
            case .heading(_, let t):
                add(t + "\n", font(fontSize + 4, serif: serif, bold: true),
                    style(spacing: fontSize * 0.6, before: fontSize * 0.6))
            case .quote(_, let t):
                add(t + "\n", font(fontSize, serif: serif, italic: true),
                    style(spacing: fontSize * 0.6, indent: 14))
            case .rule:
                add("* * *\n", body, style(spacing: fontSize * 0.6, align: .center))
            case .image(_, let u):
                flush()
                pages.append(.image(pages.count, u))
            }
        }
        flush()
        return pages
    }
}

final class PageTextUIView: UIView {
    var text = NSAttributedString() {
        didSet { setNeedsDisplay() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        contentMode = .redraw
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ rect: CGRect) {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: bounds.width, height: 100_000))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let r = lm.glyphRange(for: tc)
        lm.drawGlyphs(forGlyphRange: r, at: .zero)
    }
}

struct PageText: UIViewRepresentable {
    let text: NSAttributedString

    func makeUIView(context: Context) -> PageTextUIView {
        let v = PageTextUIView()
        v.text = text
        return v
    }

    func updateUIView(_ v: PageTextUIView, context: Context) {
        if !v.text.isEqual(to: text) { v.text = text }
    }
}

/// Одна страница книги: текст или иллюстрация на фоне темы, с номером внизу.
struct NovelPageCard: View {
    let page: NovelPage
    let number: Int
    let total: Int
    let bg: Color
    let fg: Color
    let margins: UIEdgeInsets
    let onTap: (CGFloat) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - margins.left - margins.right
            let h = geo.size.height - margins.top - margins.bottom
            ZStack {
                bg
                Group {
                    switch page {
                    case .text(_, let t):
                        PageText(text: t)
                    case .image(_, let u):
                        FitImage(url: u)
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .position(x: margins.left + w / 2, y: margins.top + h / 2)

                Text("\(number) / \(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(fg.opacity(0.45))
                    .position(x: geo.size.width / 2, y: geo.size.height - margins.bottom / 2 - 2)
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in onTap(v.location.x / max(geo.size.width, 1)) })
        }
        .ignoresSafeArea()
    }
}

// MARK: - Ранобэ: читалка
struct NovelReaderView: View {
    let novel: Anime
    let chapters: [NovelChapter]
    @State private var index: Int
    @State private var blocks: [ReaderBlock] = []
    @State private var loading = true
    @State private var error: String?
    @State private var debug = ""
    @AppStorage("reader.font") private var fontSize = 18.0
    @AppStorage("reader.theme") private var theme = "dark"
    @AppStorage("reader.serif") private var serif = true
    @AppStorage("reader.lh") private var lineGap = 0.4
    @AppStorage("novel.mode") private var mode = "pages"
    @AppStorage("novel.anim") private var novelAnim = "book"
    @State private var pages: [NovelPage] = []
    @State private var pageIndex = 0
    @State private var paginating = false
    @State private var chromeHidden = false
    @ObservedObject private var store = OfflineStore.shared
    @Environment(\.dismiss) private var dismiss

    init(novel: Anime, chapters: [NovelChapter], start: Int) {
        self.novel = novel
        self.chapters = chapters
        _index = State(initialValue: min(max(start, 0), max(chapters.count - 1, 0)))
    }

    private var activeTheme: String {
        if theme == "auto" {
            switch UserDefaults.standard.string(forKey: "set.theme") ?? "system" {
            case "light": return "light"
            case "dark": return "dark"
            default: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            }
        }
        return theme
    }

    private var bg: Color {
        switch activeTheme {
        case "sepia": return Color(red: 0.96, green: 0.93, blue: 0.85)
        case "light": return .white
        default: return Color(white: 0.07)
        }
    }

    private var fg: Color {
        switch activeTheme {
        case "sepia": return Color(red: 0.23, green: 0.18, blue: 0.18)
        case "light": return Color(white: 0.1)
        default: return Color(white: 0.9)
        }
    }

    private var readMinutes: Int {
        var n = 0
        for b in blocks {
            switch b {
            case .paragraph(_, let t), .heading(_, let t), .quote(_, let t):
                n += t.split(separator: " ").count
            case .rich(_, let t):
                n += String(t.characters).split(separator: " ").count
            default:
                break
            }
        }
        return max(1, Int((Double(n) / 180).rounded()))
    }

    private var bodyFont: Font { .system(size: fontSize, design: serif ? .serif : .default) }

    private var fgUI: UIColor {
        switch activeTheme {
        case "sepia": return UIColor(red: 0.23, green: 0.18, blue: 0.18, alpha: 1)
        case "light": return UIColor(white: 0.1, alpha: 1)
        default: return UIColor(white: 0.9, alpha: 1)
        }
    }

    private var windowInsets: UIEdgeInsets {
        let w = UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.keyWindow }.first
        return w?.safeAreaInsets ?? UIEdgeInsets(top: 47, left: 0, bottom: 34, right: 0)
    }

    private func pageMargins() -> UIEdgeInsets {
        let ins = windowInsets
        return UIEdgeInsets(top: ins.top + 16, left: 24, bottom: ins.bottom + 36, right: 24)
    }

    private func textSize(_ full: CGSize, _ m: UIEdgeInsets) -> CGSize {
        CGSize(width: max(full.width - m.left - m.right, 50), height: max(full.height - m.top - m.bottom, 50))
    }

    private func turn(_ delta: Int) {
        let n = pageIndex + delta
        guard n >= 0, n <= pages.count else { return }
        withAnimation(.easeOut(duration: 0.2)) { pageIndex = n }
    }

    private func handleTap(_ x: CGFloat) {
        if x < 0.3 { turn(-1) }
        else if x > 0.7 { turn(1) }
        else { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
    }

    private func paginate(_ full: CGSize) async {
        guard !loading, !blocks.isEmpty, chapters.indices.contains(index), full.width > 100 else {
            pages = []
            return
        }
        paginating = true
        let m = pageMargins()
        let size = textSize(full, m)
        let list = blocks
        let title = chapters[index].title
        let fs = CGFloat(fontSize), sf = serif, lg = CGFloat(lineGap), col = fgUI
        let result = await Task.detached(priority: .userInitiated) {
            NovelPaginator.paginate(blocks: list, title: title, size: size, fontSize: fs,
                                    serif: sf, lineGap: lg, color: col)
        }.value
        if Task.isCancelled { return }
        let old = pages.count
        pages = result
        pageIndex = old > 0 ? min(Int(Double(pageIndex) / Double(old) * Double(result.count)), max(result.count - 1, 0)) : 0
        paginating = false
    }

    private var endPage: some View {
        VStack(spacing: 16) {
            Text(index + 1 < chapters.count ? "Глава закончилась" : "Это последняя глава")
                .font(.subheadline).opacity(0.7)
            if index + 1 < chapters.count {
                Button { Haptics.tap(); index += 1 } label: {
                    Text("Следующая глава")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            }
        }
        .foregroundStyle(fg)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func pageContent(_ i: Int, margins m: UIEdgeInsets) -> some View {
        if i < pages.count {
            NovelPageCard(page: pages[i], number: i + 1, total: pages.count, bg: bg, fg: fg,
                          margins: m, onTap: handleTap)
        } else {
            endPage
        }
    }

    @ViewBuilder
    private var pagedBody: some View {
        GeometryReader { geo in
            let m = pageMargins()
            ZStack {
                bg
                if loading || paginating {
                    ProgressView()
                } else if let e = error {
                    Text(e).font(.footnote).foregroundStyle(.orange).padding(24)
                } else if !pages.isEmpty {
                    let count = pages.count + 1
                    switch novelAnim {
                    case "book":
                        BookPager(count: count, current: $pageIndex) { i in AnyView(pageContent(i, margins: m)) }
                    case "fade":
                        ZStack {
                            pageContent(pageIndex, margins: m)
                                .id(pageIndex)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                                        removal: .opacity))
                        }
                        .animation(.easeInOut(duration: 0.25), value: pageIndex)
                        .gesture(
                            DragGesture(minimumDistance: 30).onEnded { v in
                                let dx = v.translation.width
                                guard abs(dx) > 60, abs(dx) > abs(v.translation.height) else { return }
                                turn(dx < 0 ? 1 : -1)
                            }
                        )
                    default:
                        TabView(selection: $pageIndex) {
                            ForEach(0..<count, id: \.self) { i in
                                pageContent(i, margins: m).tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .id("\(index)-\(novelAnim)-\(activeTheme)")
            .task(id: "\(index)-\(loading)-\(blocks.count)-\(fontSize)-\(serif)-\(lineGap)-\(activeTheme)-\(Int(geo.size.width))x\(Int(geo.size.height))") {
                await paginate(geo.size)
            }
        }
        .ignoresSafeArea()
        .onAppear { if mode == "pages" { chromeHidden = true } }
    }

    @ViewBuilder
    private func blockView(_ b: ReaderBlock) -> some View {
        switch b {
        case .paragraph(_, let t):
            Text(t).font(bodyFont).lineSpacing(fontSize * lineGap)
        case .rich(_, let t):
            Text(t).font(bodyFont).lineSpacing(fontSize * lineGap)
        case .heading(_, let t):
            Text(t).font(.system(size: fontSize + 4, weight: .bold, design: serif ? .serif : .default))
        case .quote(_, let t):
            Text(t).font(bodyFont.italic()).lineSpacing(fontSize * lineGap)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
        case .image(_, let u):
            FitImage(url: u).frame(maxWidth: .infinity)
        case .rule:
            Divider()
        }
    }

    var body: some View {
        NavigationStack {
            Group {
            if mode == "scroll" {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: fontSize * (0.5 + lineGap)) {
                        Color.clear.frame(height: 1).id("top")
                        if chapters.indices.contains(index) {
                            Text(chapters[index].title)
                                .font(.system(size: fontSize + 6, weight: .bold, design: serif ? .serif : .default))
                        }
                        if !loading && !blocks.isEmpty {
                            Text("≈ \(readMinutes) мин чтения")
                                .font(.caption)
                                .opacity(0.55)
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                        ForEach(blocks) { b in blockView(b) }
                        if let e = error {
                            Text(e).font(.footnote).foregroundStyle(.orange)
                        }
                        if !debug.isEmpty {
                            Text(debug)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .opacity(0.6)
                        }
                        if !loading, index < chapters.count - 1 {
                            Button {
                                index += 1
                            } label: {
                                Text("Следующая глава")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Theme.accent.opacity(0.25), in: Capsule())
                            }
                            .padding(.top, 16)
                        }
                        Color.clear.frame(height: 90)
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .foregroundStyle(fg)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                }
                .background(bg.ignoresSafeArea())
                .onChange(of: index) { _ in proxy.scrollTo("top", anchor: .top) }
            }
            } else {
                pagedBody
            }
            }
            .task(id: index) { await load() }
            .safeAreaInset(edge: .bottom) {
                if !chromeHidden {
                HStack {
                    Button { Haptics.tap(); index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
                        .disabled(index <= 0)
                    Spacer()
                    Text("\(index + 1) из \(chapters.count)").font(.footnote.weight(.semibold))
                    Spacer()
                    Button { Haptics.tap(); index += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                        .disabled(index >= chapters.count - 1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.horizontal, 24).padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navigationBar)
            .chromeStatusBar(chromeHidden)
            .background {
                ZStack {
                    KeyShortcut(.leftArrow) { turn(-1) }
                    KeyShortcut(.rightArrow) { turn(1) }
                    KeyShortcut(.space) { turn(1) }
                }
                .disabled(mode != "pages" || loading || paginating)
                ZStack {
                    KeyShortcut(.leftArrow, .command) { if index > 0 { index -= 1 } }
                    KeyShortcut(.rightArrow, .command) { if index < chapters.count - 1 { index += 1 } }
                    KeyShortcut(.escape) { dismiss() }
                }
            }
            .navigationTitle(novel.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(activeTheme == "dark" ? .dark : .light, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button { fontSize = min(fontSize + 2, 34) } label: { Label("Крупнее", systemImage: "textformat.size.larger") }
                        Button { fontSize = max(fontSize - 2, 12) } label: { Label("Мельче", systemImage: "textformat.size.smaller") }
                        Toggle("Шрифт с засечками", isOn: $serif)
                        if chapters.indices.contains(index) {
                            let cur = chapters[index]
                            if store.isDownloaded(novel.id, cur.id) {
                                Button(role: .destructive) { store.remove(novel: novel.id, chapter: cur.id) } label: {
                                    Label("Удалить загрузку", systemImage: "trash")
                                }
                            } else {
                                Button {
                                    DownloadManager.shared.enqueue(novel: novel, all: chapters, targets: [cur])
                                } label: {
                                    Label("Скачать главу", systemImage: "arrow.down.circle")
                                }
                            }
                        }
                        Picker("Режим", selection: $mode) {
                            Text("Страницы").tag("pages")
                            Text("Прокрутка").tag("scroll")
                        }
                        Picker("Листание", selection: $novelAnim) {
                            Text("Сдвиг").tag("slide")
                            Text("Плавно").tag("fade")
                            Text("Как в книге").tag("book")
                        }
                        Picker("Интервал", selection: $lineGap) {
                            Text("Плотный").tag(0.25)
                            Text("Обычный").tag(0.4)
                            Text("Свободный").tag(0.6)
                        }
                        Picker("Тема", selection: $theme) {
                            Text("Как в системе").tag("auto")
                            Text("Тёмная").tag("dark")
                            Text("Сепия").tag("sepia")
                            Text("Светлая").tag("light")
                        }
                    } label: { Image(systemName: "textformat") }
                }
            }
        }
        .preferredColorScheme(activeTheme == "dark" ? .dark : .light)
        .onAppear { KeepAwake.set(Settings.bool("set.keepAwake", true)) }
        .onDisappear { KeepAwake.set(false) }
    }

    private func load() async {
        guard chapters.indices.contains(index), let slug = novel.slugUrl else { return }
        let ch = chapters[index]
        loading = true
        error = nil
        debug = ""
        blocks = []
        pages = []
        pageIndex = 0
        ReadStore.shared.mark(novel.readKey, ch.id)
        HistoryStore.current.recordChapter(anime: novel, chapterID: ch.id, title: ch.title)
        if let local = store.blocks(novel: novel.id, chapter: ch.id) {
            blocks = local
            loading = false
            return
        }
        do {
            let result = try await NovelService.content(slug: slug, chapter: ch)
            if Task.isCancelled { return }
            blocks = result
            if !result.isEmpty, Settings.bool("off.prefetch", false), index + 1 < chapters.count {
                DownloadManager.shared.enqueue(novel: novel, all: chapters,
                                               targets: Array(chapters[(index + 1)..<min(index + 4, chapters.count)]))
            }
            if result.isEmpty {
                error = "Текст главы пуст или недоступен."
                debug = await AnimelibAPI.shared.rawText(NovelService.chapterPath(slug: slug),
                                                         query: NovelService.chapterQuery(ch))
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}

// MARK: - App
@main
struct HeheApp: App {
    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .onAppear { MacWindow.configure() }
        }
    }
}
