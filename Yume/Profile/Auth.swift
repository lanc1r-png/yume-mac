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
        v.setOpaque(false)
        v.backgroundColor = .black
        if let home = URL(string: "https://animelib.org/ru/") { v.load(URLRequest(url: home)) }
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

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
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

struct BookmarkFolder: Identifiable, Hashable, Codable {
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
    /// В своём профиле обложки списков больше не показываем (они в «Избранном») — тайтлы не грузим
    var loadItems = true

    private var userID: Int?
    private var token: String?
    private var page = 1
    private var finished = false

    func configure(userID: Int, token: String) {
        self.userID = userID
        self.token = token
    }

    private var foldersCacheKey: String { "profile.folders.\(LibSite.current.key)" }

    /// Прошлые списки из памяти телефона: при ошибке сайта профиль не пустеет
    func restoreCachedFolders() {
        guard folders.isEmpty, let d = UserDefaults.standard.data(forKey: foldersCacheKey),
              let v = try? JSONDecoder().decode([BookmarkFolder].self, from: d) else { return }
        folders = v
    }

    func loadFolders() async {
        guard let uid = userID, let t = token else { return }
        restoreCachedFolders()
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
            if let d = try? JSONEncoder().encode(folders) { UserDefaults.standard.set(d, forKey: foldersCacheKey) }
            if selected == nil || !folders.contains(where: { $0.id == selected }) {
                selected = folders.first?.id
            }
            error = nil
            if loadItems { await reload() }
        } catch {
            if case APIError.http(let code, _) = error, code == 429 {
                self.error = folders.isEmpty ? "Сайт просит подождать — списки загрузятся чуть позже" : nil
            } else {
                self.error = folders.isEmpty ? error.localizedDescription : nil
            }
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
            if score > (best?.0 ?? Int.min) { best = (score, a) }
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
        var bodies: [[String: Any]] = []
        // формат сайта (по журналу запросов)
        if let slug = anime.slugUrl {
            bodies.append(["media_type": LibSite.current.postType, "media_slug": slug, "bookmark": ["status": f.id], "meta": [String: Any]()])
        }
        bodies += [
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
