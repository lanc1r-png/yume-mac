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

// MARK: - API
enum APIError: LocalizedError {
    case badURL, http(Int, String), noVideo
    var errorDescription: String? {
        switch self {
        case .badURL: return "Некорректный адрес запроса"
        case .http(let c, let body):
            // ответ сайта — JSON с \u-кодами: достаём из него читаемые сообщения
            if let d = body.data(using: .utf8), let obj = try? JSONSerialization.jsonObject(with: d) {
                var msgs: [String] = []
                func walk(_ v: Any) {
                    if let s = v as? String { msgs.append(s) }
                    else if let a = v as? [Any] { a.forEach(walk) }
                    else if let o = v as? [String: Any] { o.keys.sorted().forEach { walk(o[$0]!) } }
                }
                walk(obj)
                if !msgs.isEmpty { return "Ошибка \(c): " + msgs.joined(separator: "; ") }
            }
            return "Сервер вернул ошибку \(c): \(body.prefix(200))"
        case .noVideo: return "Для этой серии нет доступного видео"
        }
    }
}

struct CatalogFilter: Equatable {
    var query: String = ""
    var sortBy: SortOption = .views
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
            if ranobe && self == .lastEpisode { return "Последние обновления" }
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

/// Общая очередь запросов к сайту: не больше 4 одновременно; фоновые (проверка обновлений, синхронизация,
/// подписи, жанры) идут по одному и пропускают вперёд то, что нужно экрану. На 429 все ждут, сколько просит сайт.
actor RequestGate {
    static let shared = RequestGate()
    @TaskLocal static var background = false

    private var fg = 0
    private var bg = 0
    private var fgWaiting = 0
    private var cooldownUntil = Date.distantPast
    private var lastBG = Date.distantPast

    func acquire(background: Bool) async {
        if !background { fgWaiting += 1 }
        defer { if !background { fgWaiting -= 1 } }
        while true {
            if Task.isCancelled { if background { bg += 1 } else { fg += 1 }; return }
            let now = Date()
            let wait = cooldownUntil.timeIntervalSince(now)
            if wait > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(wait, 1) * 1_000_000_000))
                continue
            }
            if background {
                if fgWaiting == 0, fg < 3, bg < 1, now.timeIntervalSince(lastBG) > 0.35 {
                    bg += 1; lastBG = now; return
                }
            } else if fg + bg < 4 {
                fg += 1; return
            }
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    func release(background: Bool) {
        if background { bg = max(0, bg - 1) } else { fg = max(0, fg - 1) }
    }

    /// Сайт ответил 429: пауза для всех запросов
    func tooMany(retryAfter: Double?) {
        let until = Date().addingTimeInterval(min(max(retryAfter ?? 15, 3), 90))
        guard until > cooldownUntil else { return }
        cooldownUntil = until
        Task { @MainActor in RateLimitState.shared.pause(until: until) }
    }

    /// Запуск фоновой работы: её запросы встают в конец очереди
    static func inBackground<T>(_ work: () async throws -> T) async rethrows -> T {
        try await $background.withValue(true) { try await work() }
    }
}

/// Для экрана: сайт попросил подождать (показываем плашку с отсчётом, по окончании экраны сами повторяют загрузку)
@MainActor
final class RateLimitState: ObservableObject {
    static let shared = RateLimitState()
    @Published private(set) var until: Date?
    /// Меняется, когда пауза закончилась — по нему экраны перезагружаются
    @Published private(set) var resumed = 0

    func pause(until d: Date) {
        until = d
        Task { @MainActor in
            while let u = self.until, u > Date() {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            if self.until != nil {
                self.until = nil
                self.resumed += 1
            }
        }
    }
}

struct RateLimitBanner: View {
    @ObservedObject private var state = RateLimitState.shared
    var body: some View {
        if let u = state.until {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                let left = max(0, Int(u.timeIntervalSince(ctx.date).rounded(.up)))
                HStack(spacing: 8) {
                    Image(systemName: "hourglass").font(.footnote.weight(.semibold))
                    Text("Сайт просит подождать · повтор через \(left) с")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(Capsule().fill(Color.black.opacity(0.75)))
                .glassCapsule()
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)
            }
            .transition(.move(edge: .top).combined(with: .opacity))
            .padding(.top, 6)
            .allowsHitTesting(false)
        }
    }
}

actor AnimelibAPI {
    static let shared = AnimelibAPI()

    /// Все запросы к API — через общую очередь; на 429 ждём и повторяем (экранные — до 2 раз, фоновые — 1)
    private func send(_ req: URLRequest) async throws -> (Data, URLResponse) {
        let bg = RequestGate.background
        var attempt = 0
        while true {
            await RequestGate.shared.acquire(background: bg)
            let r: (Data, URLResponse)
            do {
                r = try await session.data(for: req)
            } catch {
                await RequestGate.shared.release(background: bg)
                throw error
            }
            await RequestGate.shared.release(background: bg)
            if let h = r.1 as? HTTPURLResponse, h.statusCode == 429 {
                let ra = h.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0.trimmingCharacters(in: .whitespaces)) }
                await RequestGate.shared.tooMany(retryAfter: ra)
                if attempt < (bg ? 1 : 2) { attempt += 1; continue }
            }
            return r
        }
    }

    private let apiURL = "https://api.cdnlibs.org/api"
    private let session: URLSession
    private let decoder = JSONDecoder()
    private var cachedServers: [VideoServer]?

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 30
        session = URLSession(configuration: cfg)
    }

    nonisolated var siteHeaders: [String: String] { headers(for: LibSite.current) }

    nonisolated func headers(for site: LibSite) -> [String: String] {
        ["Referer": site.referer, "Origin": site.origin, "Site-Id": site.id]
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
        // вошедшему пользователю сайт показывает и тайтлы 18+ (гостям они скрыты)
        let tok = Keychain.get("lib.token")
        if let t = tok { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        var (data, resp) = try await send(req)
        if tok != nil, let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            req.setValue(nil, forHTTPHeaderField: "Authorization")   // токен устарел: пробуем как гость
            (data, resp) = try await send(req)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data.prefix(1500), encoding: .utf8) ?? ""
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

    /// «По рейтингу» без тайтлов с парой оценок: иначе наверх попадает всё, что оценили один-два человека на десятку.
    func catalogRated(filter: CatalogFilter, startPage: Int) async throws -> (items: [Anime], hasNext: Bool, next: Int) {
        // мало оценок — не «лучшее»: иначе наверху тайтлы с парой десяток
        let minVotes = LibSite.current.isBook ? 300 : 500
        var page = startPage
        var out: [Anime] = []
        var firstRaw: [Anime] = []
        var hasNext = true
        var batches = 0
        var lastError: Error?
        while batches < 6 && hasNext && out.count < 18 {
            let pages = Array(page..<(page + 4))
            // Четыре страницы сразу: наверху рейтинга много тайтлов с парой оценок, их надо быстро пролистать.
            let results: [(Int, [Anime]?, Bool, Error?)] = await withTaskGroup(of: (Int, [Anime]?, Bool, Error?).self) { group in
                for pg in pages {
                    group.addTask {
                        do {
                            let r = try await AnimelibAPI.shared.catalog(filter: filter, page: pg)
                            return (pg, r.items, r.hasNext, nil)
                        } catch {
                            return (pg, nil, false, error)
                        }
                    }
                }
                var all: [(Int, [Anime]?, Bool, Error?)] = []
                for await r in group { all.append(r) }
                return all.sorted { $0.0 < $1.0 }
            }
            var stop = false
            for (_, items, next, err) in results {
                guard let items else { lastError = err; stop = true; break }
                if batches == 0 { firstRaw += items }
                out += items.filter { ($0.rateVotes ?? Int.max) >= minVotes }
                hasNext = next
                if !next { stop = true; break }
            }
            page += pages.count
            batches += 1
            if stop { break }
        }
        if out.isEmpty {
            if firstRaw.isEmpty, let e = lastError { throw e }
            // Фильтр по числу оценок ничего не нашёл: лучше показать список как есть, чем пустой экран.
            out = firstRaw
        }
        return (out, hasNext, page)
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
        // Настоящий запрос сайта: тайтлы автора = каталог с target_id и target_model=people.
        if let r = try? await run([.init(name: "target_id", value: String(id)),
                                   .init(name: "target_model", value: "people")]) {
            return r
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
        // Запасной путь: страница автора сама может отдавать список его работ.
        let key = (slug?.isEmpty == false) ? slug! : String(id)
        var tryLog: [String] = []
        if page == 1 {
            let tail = site.apiPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            var tries: [(String, [URLQueryItem])] = [("/people/\(key)", [])]
            for f in ["titles", "manga", "anime", "ranobe", "works", "books", "comics", "projects"] {
                tries.append(("/people/\(key)", [.init(name: "fields[]", value: f)]))
            }
            for sub in ["titles", "works", tail, "books", "projects"] {
                tries.append(("/people/\(key)/\(sub)", []))
            }
            for (path, q) in tries {
                let label = path + (q.isEmpty ? "" : "?" + q.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&"))
                do {
                    let data = try await rawData(path, query: q)
                    guard let root = J.obj(data) else { tryLog.append("\(label): не JSON"); continue }
                    let found = titlesIn(root)
                    if !found.isEmpty { return (found, false) }
                    tryLog.append("\(label): ответ есть, тайтлов нет")
                } catch APIError.http(let code, _) {
                    tryLog.append("\(label): HTTP \(code)")
                } catch {
                    tryLog.append("\(label): сбой")
                }
            }
        }
        var keys = ""
        if let data = try? await rawData("/people/\(key)"), let root = J.obj(data) as? [String: Any],
           let d = root["data"] as? [String: Any] {
            keys = d.keys.sorted().joined(separator: ", ")
        }
        throw APIError.http(404, "Фильтр по автору не сработал (параметры каталога не меняют выдачу).\n"
                            + tryLog.joined(separator: "\n") + "\nПоля автора: " + keys)
    }

    /// Собирает тайтлы из любого ответа: объекты с id и slug_url (авторов, людей и команды пропускаем).
    private func titlesIn(_ root: Any, onlyAnime: Bool = false) -> [Anime] {
        var out: [Anime] = []
        var seen = Set<Int>()
        let siteKey = LibSite.current.key
        func walk(_ v: Any) {
            if let d = v as? [String: Any] {
                let model = (d["model"] as? String)?.lowercased() ?? ""
                let isTitleLike = J.int(d["id"]) != nil && d["slug_url"] != nil
                    && !["people", "user", "team"].contains(model)
                let sameSite = !["anime", "manga", "ranobe", "hentai"].contains(model) || model == siteKey
                let wanted = onlyAnime ? (model == "anime" && isTitleLike) : sameSite
                if isTitleLike, wanted,
                   let data = try? JSONSerialization.data(withJSONObject: d),
                   let a = try? decoder.decode(Anime.self, from: data) {
                    if seen.insert(a.id).inserted { out.append(a) }
                    return
                }
                for x in d.values { walk(x) }
            } else if let arr = v as? [Any] {
                for x in arr { walk(x) }
            }
        }
        walk(root)
        return out
    }

    /// «Похожие» и «Связанное» для карточки тайтла (формат ответа разбираем мягко).
    func similarTitles(slug: String) async -> (similar: [Anime], related: [Anime], adapt: [Anime], note: String) {
        let base = LibSite.current.apiPath + "/" + slug
        var notes: [String] = []
        var lists: [[Anime]] = []
        var adapt: [Anime] = []
        for sub in ["similar", "relations"] {
            do {
                let data = try await rawData(base + "/" + sub)
                if let root = J.obj(data) {
                    lists.append(titlesIn(root).filter { $0.slugUrl != slug })
                    if sub == "relations", LibSite.current.isBook { adapt = titlesIn(root, onlyAnime: true) }
                } else {
                    lists.append([])
                    notes.append("\(sub): не JSON")
                }
            } catch {
                lists.append([])
                notes.append("\(sub): \(error.localizedDescription)")
            }
        }
        let sim = lists[0]
        let simIDs = Set(sim.map { $0.id })
        let rel = lists[1].filter { !simIDs.contains($0.id) }
        return (sim, rel, adapt, notes.joined(separator: "; "))
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

    /// `site` — для фоновых задач (загрузки): запрос идёт к сайту задачи, даже если ты переключил вкладку.
    func rawData(_ path: String, query: [URLQueryItem] = [], token: String? = nil,
                 method: String = "GET", json: [String: Any]? = nil, site: LibSite? = nil) async throws -> Data {
        guard var comps = URLComponents(string: apiURL + path) else { throw APIError.badURL }
        if !query.isEmpty { comps.queryItems = query }
        guard let url = comps.url else { throw APIError.badURL }
        var req = URLRequest(url: url)
        for (k, v) in headers(for: site ?? LibSite.current) { req.setValue(v, forHTTPHeaderField: k) }
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        // у HentaiLib контент закрыт для гостей: отправляем токен вошедшего пользователя
        let auth = token ?? Keychain.get("lib.token")
        if let t = auth { req.setValue("Bearer " + t, forHTTPHeaderField: "Authorization") }
        req.httpMethod = method
        if let j = json {
            req.httpBody = try JSONSerialization.data(withJSONObject: j)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        var (data, resp) = try await send(req)
        if token == nil, auth != nil, let http = resp as? HTTPURLResponse, http.statusCode == 401 || http.statusCode == 403 {
            req.setValue(nil, forHTTPHeaderField: "Authorization")
            (data, resp) = try await send(req)
        }
        if let http = resp as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw APIError.http(http.statusCode, String(data: data.prefix(1500), encoding: .utf8) ?? "")
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
            let (data, resp) = try await send(req)
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
        if let a = try? await get(path, query: query(base + ["tags", "rate_avg"]), as: Envelope<Anime>.self).data { return a }
        do {
            return try await get(path, query: query(base + ["rate_avg"]), as: Envelope<Anime>.self).data
        } catch {
            return try await get(path, query: query(base), as: Envelope<Anime>.self).data
        }
    }

    /// Сколько серий/глав у тайтла и когда вышла последняя (если сайт сообщает дату).
    func updateInfo(slug: String?) async -> (count: Int?, date: String?) {
        guard let slug, !slug.isEmpty else { return (nil, nil) }
        let path = LibSite.current.apiPath + "/" + slug
        guard let data = try? await rawData(path), let root = J.obj(data) else { return (nil, nil) }
        return FavUpdate.parse(root)
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
