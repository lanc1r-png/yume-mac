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

// MARK: - Ранобэ: офлайн-хранилище
struct SavedChapter: Codable {
    let id: Int
    let volume: String
    let number: String
    let name: String
    var date: Date? = nil
}

struct OfflineEntry: Codable {
    var novel: Anime
    var chapters: [SavedChapter]
    var files: [Int: Int]
    var updated: Date
}

/// Размер по-русски: «0 КБ», «820 КБ», «107,7 МБ», «1,25 ГБ» (системный формат давал «Zero KB»).
func fmtBytes(_ n: Int) -> String {
    func num(_ v: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", v).replacingOccurrences(of: ".", with: ",")
    }
    if n <= 0 { return "0 КБ" }
    let kb = Double(n) / 1000
    if kb < 1000 { return "\(max(1, Int(kb.rounded()))) КБ" }
    let mb = kb / 1000
    if mb < 1000 { return num(mb, mb < 100 ? 1 : 0) + " МБ" }
    return num(mb / 1000, 2) + " ГБ"
}

let ruDateFmt: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "ru_RU")
    f.dateFormat = "d MMMM, HH:mm"
    return f
}()
/// «21 ноября, 23:51»
func ruDate(_ d: Date) -> String { ruDateFmt.string(from: d) }

/// Скачанные главы лежат в Application Support/Offline/<id тайтла>/:
/// <id главы>.json (ответ сайта как есть) и картинки <id главы>_<хэш>.img.
@MainActor
final class OfflineStore: ObservableObject {
    static let shared = OfflineStore()
    static let manga = OfflineStore(folder: "OfflineManga")
    static var current: OfflineStore { LibSite.current.isManga ? manga : shared }
    @Published private(set) var entries: [Int: OfflineEntry] = [:]
    nonisolated let root: URL

    init(folder: String = "Offline") {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var dir = base.appendingPathComponent(folder, isDirectory: true)
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
    nonisolated func mangaPageFile(_ novel: Int, _ chapter: Int, _ index: Int) -> URL {
        folder(novel).appendingPathComponent("\(chapter)_\(index).img")
    }
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

    static var usedBytes: Int { shared.totalBytes + manga.totalBytes }
    static var limitBytes: Int { UserDefaults.standard.integer(forKey: "off.limitGB") * 1_000_000_000 }
    static var purgeMode: Bool { UserDefaults.standard.string(forKey: "off.overflow") == "purge" }

    var avgChapterBytes: Int? {
        let n = entries.values.reduce(0) { $0 + $1.files.count }
        return n > 0 ? totalBytes / n : nil
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
            .map { NovelChapter(id: $0.id, volume: $0.volume, number: $0.number, name: $0.name, date: $0.date) }
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
final class DownloadProgress: ObservableObject {
    @Published var status = ""
}

@MainActor
final class DownloadManager: ObservableObject {
    static let shared = DownloadManager()

    struct Job {
        let novel: Anime
        let chapters: [NovelChapter]
        let chapter: NovelChapter
        let store: OfflineStore
        /// Сайт, с которого поставили загрузку: запоминаем, чтобы переключение вкладки её не ломало.
        var site = LibSite.current
    }

    @Published private(set) var pending: Set<Int> = []
    @Published private(set) var active: Set<Int> = []
    @Published private(set) var failed: [Int: String] = [:]
    @Published private(set) var total = 0
    @Published private(set) var done = 0
    /// Текст состояния живёт в отдельном объекте: его частые обновления не должны перерисовывать список глав.
    let progress = DownloadProgress()
    var status: String {
        get { progress.status }
        set { progress.status = newValue }
    }
    @Published var notice: String?

    private var jobs: [Job] = []
    private var worker: Task<Void, Never>?
    private let monitor = NWPathMonitor()
    /// Мобильная сеть (или режим экономии трафика): тогда тратим меньше трафика и заряда.
    private(set) var expensive = false

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            let exp = path.isExpensive
            Task { @MainActor in self?.expensive = exp }
        }
        monitor.start(queue: DispatchQueue(label: "hehe.netmonitor"))
    }

    /// Удаляет самые давние прочитанные главы, пока занято не больше target. Возвращает, получилось ли.
    private func purgeRead(target: Int) -> Bool {
        var list: [(OfflineStore, Int, Int, Date)] = []
        for st in [OfflineStore.shared, OfflineStore.manga] {
            for e in st.entries.values {
                let key = st === OfflineStore.manga ? -e.novel.id : e.novel.id
                for cid in e.files.keys where ReadStore.shared.isRead(key, cid) {
                    list.append((st, e.novel.id, cid, e.updated))
                }
            }
        }
        list.sort { $0.3 < $1.3 }
        for (st, nid, cid, _) in list {
            if OfflineStore.usedBytes <= target { break }
            st.remove(novel: nid, chapter: cid)
        }
        return OfflineStore.usedBytes <= target
    }

    func enqueue(novel: Anime, all: [NovelChapter], targets: [NovelChapter]) {
        notice = nil
        let store = OfflineStore.current
        // Всё накапливаем и публикуем один раз: иначе экран перерисовывается на каждую главу из сотни.
        var newPending = pending
        var newFailed = failed
        var added = 0
        for c in targets where !store.isDownloaded(novel.id, c.id) && !newPending.contains(c.id) {
            jobs.append(Job(novel: novel, chapters: all, chapter: c, store: store))
            newPending.insert(c.id)
            newFailed[c.id] = nil
            added += 1
        }
        if added > 0 {
            pending = newPending
            failed = newFailed
            total += added
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
        active = []
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
        // Несколько глав качаются одновременно: на мобильной сети две, на Wi‑Fi три.
        // Манга: главы по одной, иначе сервер картинок рвёт десятки одновременных соединений и всё встаёт.
        let lanes = (jobs.first?.store === OfflineStore.manga) ? 1 : (expensive ? 2 : 3)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<lanes { group.addTask { await self.lane() } }
        }
        if box.id != .invalid { UIApplication.shared.endBackgroundTask(box.id); box.id = .invalid }
        if Task.isCancelled { return }
        if done >= 3 { Haptics.success() }
        active = []
        status = ""
        total = 0
        done = 0
        worker = nil
    }

    /// Одна «полоса» загрузки: берёт следующую главу из очереди, пока очередь не опустеет.
    private func lane() async {
        while !Task.isCancelled, !jobs.isEmpty {
            let job = jobs.removeFirst()
            let limit = OfflineStore.limitBytes
            if limit > 0 && OfflineStore.usedBytes >= limit {
                var ok = false
                if OfflineStore.purgeMode { ok = purgeRead(target: Int(Double(limit) * 0.9)) }
                if !ok {
                    notice = "Достигнут лимит места (\(fmtBytes(limit))). Скачивание остановлено."
                    jobs.removeAll()
                    pending = []
                    return
                }
            }
            if Settings.bool("off.wifi", false) {
                while expensive && !Task.isCancelled {
                    status = "Ждём Wi‑Fi…"
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                }
            }
            if Task.isCancelled { return }
            active.insert(job.chapter.id)
            status = job.chapter.title
            do {
                try await download(job)
            } catch {
                if Task.isCancelled { return }
                failed[job.chapter.id] = error.localizedDescription
            }
            active.remove(job.chapter.id)
            if Task.isCancelled { return }
            done += 1
            pending.remove(job.chapter.id)
            try? await Task.sleep(nanoseconds: 60_000_000)
        }
    }

    /// Качает элементы с «скользящим окном»: как только одна загрузка закончилась, стартует следующая.
    nonisolated static func pool<T>(_ items: [T], width: Int, _ work: @escaping (T) async -> Int) async -> [Int] {
        await withTaskGroup(of: Int.self) { group -> [Int] in
            var out: [Int] = []
            var it = items.makeIterator()
            for _ in 0..<min(width, items.count) {
                if let x = it.next() { group.addTask { await work(x) } }
            }
            while let n = await group.next() {
                out.append(n)
                if Task.isCancelled { group.cancelAll(); continue }
                if let x = it.next() { group.addTask { await work(x) } }
            }
            return out
        }
    }

    nonisolated static let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.httpMaximumConnectionsPerHost = 12
        c.timeoutIntervalForRequest = 30
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        c.urlCache = nil
        return URLSession(configuration: c)
    }()

    private func download(_ job: Job) async throws {
        guard let slug = job.novel.slugUrl else { throw APIError.badURL }
        let c = job.chapter
        var raw: Data?
        var lastError: Error = APIError.badURL
        for attempt in 0..<3 {
            do {
                raw = try await AnimelibAPI.shared.rawData(NovelService.chapterPath(slug: slug),
                                                           query: NovelService.chapterQuery(c), site: job.site)
                break
            } catch APIError.http(let code, let body) where code == 429 || code >= 500 {
                lastError = APIError.http(code, body)
                try await Task.sleep(nanoseconds: UInt64(3_000_000_000 * (attempt + 1)))
            }
        }
        guard let raw, let root = J.obj(raw) as? [String: Any],
              let d = root["data"] as? [String: Any] else { throw lastError }
        if job.store === OfflineStore.manga {
            try await downloadManga(job, raw: raw, data: d)
            return
        }
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
        let store = job.store
        let nid = job.novel.id
        try? FileManager.default.createDirectory(at: store.folder(nid), withIntermediateDirectories: true)
        let targets: [(URL, URL)] = urls.map { ($0, store.imageFile(novel: nid, chapter: c.id, url: $0)) }
        let imageBytes = await DownloadManager.pool(targets, width: 6) { t in
            await DownloadManager.fetchImage(t.0, to: t.1)
        }.reduce(0, +)
        if Task.isCancelled { throw CancellationError() }
        if let cover = job.novel.imageURL, store.coverURL(nid) == nil {
            _ = await DownloadManager.fetchImage(cover, to: store.coverFile(nid))
        }
        store.record(novel: job.novel, chapters: job.chapters, chapter: c, raw: raw, extraBytes: imageBytes)
    }

    /// Манга: все страницы главы кладём в файлы 〈глава〉_〈номер〉.img. Глава сохраняется, только если скачались все.
    private func downloadManga(_ job: Job, raw: Data, data d: [String: Any]) async throws {
        let c = job.chapter
        let bases = await MangaImageServers.shared.bases(site: job.site)
        let pages = MangaService.parse(d, bases: bases)
        if pages.isEmpty {
            throw NSError(domain: "offline", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "У главы нет страниц или она недоступна"])
        }
        let store = job.store
        let nid = job.novel.id
        try? FileManager.default.createDirectory(at: store.folder(nid), withIntermediateDirectories: true)
        var bytes = 0
        var failedPages = 0
        let targets: [([URL], URL)] = pages.map { ($0.urls, store.mangaPageFile(nid, c.id, $0.id)) }
        let titleText = c.title
        let totalPages = targets.count
        let referer = job.site.isManga ? job.site.referer : LibSite.manga.referer
        let counter = PageCounter()
        status = "\(titleText) · 0/\(totalPages)"
        let sizes = await DownloadManager.pool(targets, width: expensive ? 4 : 6) { t in
            let n = await DownloadManager.fetchMangaPage(t.0, to: t.1, referer: referer)
            let k = await counter.bump()
            await MainActor.run { DownloadManager.shared.status = "\(titleText) · \(k)/\(totalPages)" }
            return n
        }
        if Task.isCancelled { throw CancellationError() }
        for n in sizes { if n == 0 { failedPages += 1 } else { bytes += n } }
        if failedPages > 0 {
            throw NSError(domain: "offline", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "Не скачалось страниц: \(failedPages). Попробуй ещё раз"])
        }
        if let cover = job.novel.imageURL, store.coverURL(nid) == nil {
            _ = await DownloadManager.fetchImage(cover, to: store.coverFile(nid))
        }
        store.record(novel: job.novel, chapters: job.chapters, chapter: c, raw: raw, extraBytes: bytes)
    }

    actor PageCounter {
        private var n = 0
        func bump() -> Int { n += 1; return n }
    }

    nonisolated static func fetchMangaPage(_ urls: [URL], to file: URL, referer: String) async -> Int {
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return size }
        let agent = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"
        for round in 0..<2 {
            for u in urls {
                var req = URLRequest(url: u)
                req.timeoutInterval = 20
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue("image/avif,image/webp,image/apng,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
                req.setValue(agent, forHTTPHeaderField: "User-Agent")
                if let (data, resp) = try? await DownloadManager.session.data(for: req),
                   let code = (resp as? HTTPURLResponse)?.statusCode, (200..<300).contains(code),
                   !data.isEmpty,
                   let src = CGImageSourceCreateWithData(data as CFData, nil), CGImageSourceGetCount(src) > 0 {
                    try? data.write(to: file, options: .atomic)
                    return data.count
                }
            }
            if round == 0 { try? await Task.sleep(nanoseconds: 700_000_000) }
        }
        return 0
    }

    nonisolated static func fetchImage(_ url: URL, to file: URL) async -> Int {
        if let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > 0 { return size }
        for attempt in 0..<3 {
            var req = URLRequest(url: url)
            req.timeoutInterval = 30
            req.setValue("https://ranobelib.me/", forHTTPHeaderField: "Referer")
            if let (data, resp) = try? await DownloadManager.session.data(for: req),
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
    @ObservedObject private var store = OfflineStore.current
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
                    if dl.active.contains(chapter.id) { ProgressView() }
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
    @ObservedObject private var store = OfflineStore.current
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
        .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0).macPushed(980) }
        .navigationDestination(for: AuthorRef.self) { AuthorView(author: $0).macPushed() }
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
