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
    /// Номер страницы главы, к которой написан комментарий (если сайт его сообщает).
    let page: Int?

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
        page = J.int(d["post_page"]) ?? J.int(d["chapter_page"])
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
    @Published var sampleKeys = ""
    var postPage: Int?

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

    /// id комментариев, пришедших по запросу конкретной страницы манги (как делает сайт: `post_page`).
    @Published var pageIDs: [Int: Set<Int>] = [:]
    @Published var loadingPages: Set<Int> = []

    /// Загружает комментарии одной страницы главы напрямую с сервера — один быстрый запрос
    /// вместо перебора всех комментариев главы (раньше к дальним страницам они могли не дойти).
    func loadPostPage(_ pp: Int) async {
        guard pageIDs[pp] == nil, !loadingPages.contains(pp) else { return }
        loadingPages.insert(pp)
        defer { loadingPages.remove(pp) }
        var ids = Set<Int>()
        var pg = 1
        while pg <= 5 {
            guard let (list, hasNext) = try? await fetch(page: pg, postPage: pp) else { break }
            let known = Set(items.map { $0.id })
            items += list.filter { !known.contains($0.id) }
            ids.formUnion(list.map { $0.id })
            if hasNext != true || list.isEmpty { break }
            pg += 1
        }
        pageIDs[pp] = ids
    }

    func onPostPage(_ c: CommentItem, _ pp: Int) -> Bool {
        c.page == pp || (pageIDs[pp]?.contains(c.id) ?? false)
    }

    private func fetch(page: Int, postPage: Int? = nil) async throws -> ([CommentItem], Bool?) {
        let attempts: [(String, [URLQueryItem])] = types.map {
            var items = [q("post_id", String(animeID)), q("post_type", $0), q("page", String(page))]
            if let pp = postPage {
                items += [q("post_page", String(pp)), q("sort_by", "id"), q("sort_type", "desc")]
            }
            return ("/comments", items)
        }
        var lastError: Error = APIError.badURL
        for (path, query) in attempts {
            do {
                let data = try await AnimelibAPI.shared.rawData(path, query: query, token: AuthStore.shared.token)
                guard let root = J.obj(data) else { continue }
                let list = CommentParser.parse(root)
                if sampleKeys.isEmpty {
                    var raw: [[String: Any]] = []
                    CommentParser.collect(root, into: &raw)
                    if let f = raw.first { sampleKeys = f.keys.sorted().joined(separator: ", ") }
                }
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

    func loadAll(max: Int = 10) async {
        var n = 0
        while !finished && n < max {
            // страница уже грузится (например, предзагрузкой) — ждём её, а не пропускаем
            if isLoading {
                try? await Task.sleep(nanoseconds: 100_000_000)
                if Task.isCancelled { return }
                continue
            }
            await loadMore(); n += 1
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
        // сайт ждёт текст как документ (абзацы) и уровень вложенности
        let paragraphs: [[String: Any]] = text.components(separatedBy: "\n").map { line in
            line.isEmpty ? ["type": "paragraph"] : ["type": "paragraph", "content": [["type": "text", "text": line]]]
        }
        // формат точно как у сайта (по журналу запросов): документ, attachments, root_id, уровень 0
        let doc: [String: Any] = ["type": "doc", "content": paragraphs]
        func body(level: Int, root: Any, pp: Bool = true) -> [String: Any] {
            var b: [String: Any] = ["comment": doc, "attachments": [Any](), "post_type": type, "post_id": animeID,
                                    "parent_comment": parent ?? NSNull(), "root_id": root, "comment_level": level]
            if pp, let page = postPage { b["post_page"] = page }
            return b
        }
        var variants: [(String, [String: Any])] = []
        if parent == nil {
            variants.append(("A", body(level: 0, root: NSNull())))
            variants.append(("B", body(level: 0, root: NSNull(), pp: false)))
        } else if let pid = parent {
            variants.append(("A", body(level: 1, root: pid)))
            variants.append(("B", body(level: 1, root: NSNull())))
            variants.append(("C", body(level: 2, root: pid)))
        }
        var errors: [String] = []
        for (name, b) in variants {
            do {
                _ = try await AnimelibAPI.shared.rawData("/comments", token: t, method: "POST", json: b)
                return nil
            } catch {
                errors.append("\(name): \(error.localizedDescription)")
                // Ошибка сервера (5xx): комментарий мог уже создаться — не шлём другой вариант, чтобы не было дубля.
                if case APIError.http(let code, _) = error, code >= 500 { break }
            }
        }
        return errors.joined(separator: "\n")
    }

    func like(_ id: Int) async -> String? {
        guard let t = AuthStore.shared.token else { return "Сначала войдите во вкладке «Профиль»" }
        let attempts: [(String, [String: Any])] = [
            ("/comments/\(id)/vote", ["vote": 1]),      // формат сайта (по журналу запросов)
            ("/comments/\(id)/vote", ["type": "up"]),
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
    var filter: ((CommentItem) -> Bool)? = nil

    var body: some View {
        LazyVStack(spacing: 10) {
            ForEach(filter.map { vm.sorted.filter($0) } ?? vm.sorted) { c in
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
            .macSheet(isPresented: showCompose) {
                ComposeSheet(title: "Новый комментарий",
                             send: { await vm.send($0, parent: nil) },
                             onSent: { Task { await vm.reload() } })
            }
            .macSheet(item: Binding(get: { vm.replyTarget }, set: { vm.replyTarget = $0 })) { target in
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
