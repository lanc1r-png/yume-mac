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

// MARK: - Друзья
struct Friend: Identifiable, Hashable, Codable {
    let id: Int
    var username: String
    var avatar: URL?
    var cover: URL?
    var online: Bool?
    var lastSeen: Date?
    var level: Int?
    var streak: Int?
    var premium = false

    var statusText: String {
        if online == true { return "в сети" }
        if let d = lastSeen { return "был(а) " + Friend.relFmt.localizedString(for: d, relativeTo: Date()) }
        return ""
    }

    private static let relFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.unitsStyle = .short
        return f
    }()

    /// Дополняем пустые поля данными из другой записи.
    mutating func merge(_ o: Friend) {
        if avatar == nil { avatar = o.avatar }
        if cover == nil { cover = o.cover }
        if online == nil { online = o.online }
        if lastSeen == nil { lastSeen = o.lastSeen }
        if level == nil { level = o.level }
        if streak == nil { streak = o.streak }
        premium = premium || o.premium
    }
}

enum FriendParser {
    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ v: Any?) -> Date? {
        guard let s = v as? String, !s.isEmpty else { return nil }
        if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return d }
        return parseLibDate(s)
    }

    /// Запись о друге может быть самим пользователем или обёрткой с вложенным user.
    static func friend(_ d: [String: Any]) -> Friend? {
        var cands: [[String: Any]] = [d]
        for v in d.values { if let sub = v as? [String: Any] { cands.append(sub) } }
        for c in cands {
            guard let id = J.int(c["id"]), let name = J.str(c["username"]) ?? J.str(c["name"]) else { continue }
            var online = (c["is_online"] as? Bool) ?? (c["online"] as? Bool)
            var seen: Date?
            for k in ["last_online_at", "last_seen_at", "last_online", "last_activity_at", "last_seen"] {
                if let dt = date(c[k]) { seen = dt; break }
            }
            if online == nil, let sn = seen { online = Date().timeIntervalSince(sn) < 300 }
            let st = c["login_streak"] as? [String: Any]
            return Friend(id: id, username: name, avatar: J.url(c["avatar"]),
                          cover: AuthStore.coverURL(c), online: online, lastSeen: seen,
                          level: J.int(c["level"]) ?? J.int((c["user_level"] as? [String: Any])?["level"]),
                          streak: J.int(st?["login_streak"]) ?? J.int(c["login_streak"]),
                          premium: ((c["premium"] as? [String: Any])?["enabled"] as? Bool) ?? false)
        }
        return nil
    }

    static func detail(id: Int, token: String?) async -> Friend? {
        guard let data = try? await AnimelibAPI.shared.rawData("/user/\(id)", token: token),
              let root = J.obj(data) as? [String: Any] else { return nil }
        let d = (root["data"] as? [String: Any]) ?? root
        return friend(d)
    }

    /// Достаёт id из числа или ссылки вида …/user/123 или …/user/123-name.
    static func userID(from text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let n = Int(t) { return n }
        guard let r = t.range(of: "/user/") else { return nil }
        let digits = t[r.upperBound...].prefix { $0.isNumber }
        return Int(digits)
    }
}

@MainActor
final class LocalFriends: ObservableObject {
    static let shared = LocalFriends()
    @Published private(set) var items: [Friend] = []
    private let key = "friends.local.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([Friend].self, from: d) { items = v }
    }

    func contains(_ id: Int) -> Bool { items.contains { $0.id == id } }

    func toggle(_ f: Friend) {
        if let i = items.firstIndex(where: { $0.id == f.id }) { items.remove(at: i) } else { items.insert(f, at: 0) }
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

@MainActor
final class FriendsViewModel: ObservableObject {
    @Published var friends: [Friend] = []
    @Published var isLoading = false
    @Published var loaded = false
    @Published var debug = ""
    private let cacheKey = "friends.cache.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: cacheKey),
           let v = try? JSONDecoder().decode([Friend].self, from: d) { friends = v }
    }

    private var syncReplaced = false
    private static let endpointKey = "friends.endpoint"

    func beginSync() { syncReplaced = false }

    /// Друзья, пойманные из запросов сайта. Адрес запроса запоминаем, чтобы дальше брать список напрямую.
    func absorb(_ list: [Friend], endpoint: String) {
        if !syncReplaced { friends = []; syncReplaced = true }
        for f in list {
            if let i = friends.firstIndex(where: { $0.id == f.id }) { friends[i].merge(f) } else { friends.append(f) }
        }
        UserDefaults.standard.set(endpoint, forKey: Self.endpointKey)
        debug = ""
        loaded = true
        if let d = try? JSONEncoder().encode(friends) { UserDefaults.standard.set(d, forKey: cacheKey) }
    }

    /// Превращает пойманный адрес вида https://api…/api/путь?параметры в путь и параметры для нашего клиента.
    private static func savedEndpoint() -> (String, [URLQueryItem])? {
        guard let e = UserDefaults.standard.string(forKey: endpointKey),
              let c = URLComponents(string: e),
              let r = c.path.range(of: "/api/") else { return nil }
        let path = "/" + c.path[r.upperBound...]
        let q = (c.queryItems ?? []).filter { $0.name != "page" }
        return (path, q)
    }

    /// Список с сайта плюс друзья, добавленные вручную, без повторов и в порядке «сначала в сети».
    static func merged(_ api: [Friend], _ local: [Friend]) -> [Friend] {
        var all = api
        for l in local where !all.contains(where: { $0.id == l.id }) { all.append(l) }
        return all.sorted { a, b in
            if (a.online == true) != (b.online == true) { return a.online == true }
            if let x = a.lastSeen, let y = b.lastSeen, x != y { return x > y }
            return a.username.localizedCaseInsensitiveCompare(b.username) == .orderedAscending
        }
    }

    func parseList(_ data: Data) -> [Friend]? {
        guard let root = J.obj(data) else { return nil }
        var arr: [[String: Any]]?
        if let o = root as? [String: Any] {
            arr = o["data"] as? [[String: Any]]
            if arr == nil, let inner = o["data"] as? [String: Any] {
                arr = (inner["items"] as? [[String: Any]]) ?? (inner["friends"] as? [[String: Any]])
                    ?? (inner["data"] as? [[String: Any]])
            }
            if arr == nil { arr = o["friends"] as? [[String: Any]] }
            if arr == nil { arr = o["items"] as? [[String: Any]] }
        } else if let a = root as? [[String: Any]] {
            arr = a
        }
        return arr?.compactMap { FriendParser.friend($0) }
    }

    func load(userID: Int, token: String) async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false; loaded = true }
        let uid = String(userID)
        let u = URLQueryItem(name: "user_id", value: uid)
        let p1 = URLQueryItem(name: "page", value: "1")
        var candidates: [(String, [URLQueryItem])] = [
            ("/user/friends", [p1]),
            ("/user/friends", [u]),
            ("/user/friends", [u, p1]),
            ("/user/friends", []),
            ("/user/\(uid)/friends", [p1]),
            ("/user/\(uid)/friends", []),
            ("/users/\(uid)/friends", []),
            ("/friends", [u]),
            ("/friends", []),
            ("/social/friends", [u]),
            ("/user/\(uid)/relations", []),
            ("/user/relations", [u]),
            ("/user/\(uid)/subscriptions", [])
        ]
        if let saved = Self.savedEndpoint() { candidates.insert(saved, at: 0) }
        var log: [String] = []
        var result: [Friend]?
        var usedPath: (String, [URLQueryItem])?
        for (path, q) in candidates {
            let tag = path + (q.isEmpty ? "" : "?" + q.map { $0.name }.joined(separator: "&"))
            do {
                let data = try await AnimelibAPI.shared.rawData(path, query: q, token: token)
                if let list = parseList(data) {
                    result = list
                    usedPath = (path, q)
                    break
                }
                log.append("\(tag): ответ без списка")
            } catch APIError.http(let code, let body) {
                let b = String("\(body)".replacingOccurrences(of: "\n", with: " ").prefix(70))
                log.append("\(tag): \(code) \(b)")
            } catch {
                log.append("\(tag): сбой")
            }
        }
        if let r = result {
            var all = r
            if let (path, q) = usedPath, !all.isEmpty {
                var page = 2
                while page <= 8 {
                    let base = q.filter { $0.name != "page" }
                    let qq = base + [URLQueryItem(name: "page", value: String(page))]
                    guard let data = try? await AnimelibAPI.shared.rawData(path, query: qq, token: token),
                          let more = parseList(data) else { break }
                    let known = Set(all.map { $0.id })
                    let fresh = more.filter { !known.contains($0.id) }
                    if fresh.isEmpty { break }
                    all += fresh
                    page += 1
                }
            }
            friends = all
            debug = ""
            await enrich(token: token)
            if let d = try? JSONEncoder().encode(friends) { UserDefaults.standard.set(d, forKey: cacheKey) }
        } else {
            debug = log.joined(separator: "\n")
        }
    }

    /// Если список не сообщил, кто в сети, спрашиваем профили по одному.
    func enrich(token: String) async {
        let need = friends.filter { $0.online == nil }.prefix(40).map { $0.id }
        var i = 0
        while i < need.count {
            let chunk = Array(need[i..<min(i + 4, need.count)])
            i += 4
            await withTaskGroup(of: Friend?.self) { group in
                for id in chunk { group.addTask { await FriendParser.detail(id: id, token: token) } }
                for await d in group {
                    guard let d, let idx = friends.firstIndex(where: { $0.id == d.id }) else { continue }
                    friends[idx].merge(d)
                }
            }
        }
    }
}

struct FriendsSniffWebView: UIViewRepresentable {
    let url: URL
    let onData: (String, String) -> Void

    static let script = """
    (function(){
      if (window.__hehe2) return; window.__hehe2 = true;
      function take(u, t){
        try {
          if (!/friend/i.test(String(u))) return;
          if (/request|invit|incoming|outgoing|sent/i.test(String(u))) return;
          window.webkit.messageHandlers.hfriends.postMessage({u: String(u), t: String(t).slice(0, 3000000)});
        } catch (e) {}
      }
      var of = window.fetch;
      if (of) window.fetch = function(a, o){
        var u = typeof a === 'string' ? a : (a && a.url);
        var p = of.apply(this, arguments);
        p.then(function(r){ try { r.clone().text().then(function(t){ take(u, t); }); } catch (e) {} }).catch(function(){});
        return p;
      };
      var oo = XMLHttpRequest.prototype.open;
      XMLHttpRequest.prototype.open = function(m, u){
        var x = this; x.__u = u;
        x.addEventListener('loadend', function(){
          try {
            var t = (x.responseType === '' || x.responseType === 'text') ? x.responseText : JSON.stringify(x.response);
            take(x.__u, t);
          } catch (e) {}
        });
        return oo.apply(this, arguments);
      };
      var tries = 0, clicked = false;
      var iv = setInterval(function(){
        tries++; if (tries > 30) { clearInterval(iv); return; }
        if (!clicked) {
          var el = document.querySelector('a[href*="friends"]');
          if (!el) {
            var all = document.querySelectorAll('a,button,li,[role=tab],span,div');
            for (var i = 0; i < all.length; i++) {
              var t = (all[i].children.length === 0 ? all[i].textContent : '').trim();
              if (t === 'Список друзей' || t === 'Друзья') { el = all[i]; break; }
            }
          }
          if (el) { el.click(); clicked = true; }
        } else {
          window.scrollTo(0, document.body.scrollHeight);
          var se = document.scrollingElement; if (se) se.scrollTop = se.scrollHeight;
        }
      }, 1000);
    })();
    """

    final class Coordinator: NSObject, WKScriptMessageHandler {
        let onData: (String, String) -> Void
        init(_ f: @escaping (String, String) -> Void) { onData = f }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let o = m.body as? [String: Any], let u = o["u"] as? String, let t = o["t"] as? String else { return }
            DispatchQueue.main.async { self.onData(u, t) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(onData) }

    func makeUIView(context: Context) -> WKWebView {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(context.coordinator, name: "hfriends")
        cfg.userContentController.addUserScript(
            WKUserScript(source: Self.script, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let v = WKWebView(frame: .zero, configuration: cfg)
        v.customUserAgent = Kodik.ua
        v.load(URLRequest(url: url))
        return v
    }

    func updateUIView(_ v: WKWebView, context: Context) {}

    static func dismantleNSView(_ v: WKWebView, coordinator: Coordinator) {
        v.configuration.userContentController.removeScriptMessageHandler(forName: "hfriends")
    }
}

struct FriendsSyncView: View {
    let userID: Int
    @ObservedObject var vm: FriendsViewModel
    @Environment(\.hostDismiss) private var dismiss
    @State private var found = 0
    @State private var lastHit = Date()

    private var start: URL {
        let host: String
        switch LibSite.current.key {
        case "ranobe": host = "https://ranobelib.me"
        case "manga": host = "https://mangalib.me"
        case "hentai": host = "https://kz.hentailib.me"
        default: host = "https://animelib.org"
        }
        return URL(string: "\(host)/ru/user/\(userID)") ?? URL(string: host)!
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    if found == 0 { ProgressView() } else { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green) }
                    VStack(alignment: .leading, spacing: 2) {
                        Text(found == 0 ? "Ищу список друзей на сайте…" : "Найдено друзей: \(found)")
                            .font(.subheadline.weight(.semibold))
                        Text(found == 0 ? "Если сайт попросит войти, войди. Если список сам не открылся, нажми на нём «Друзья»." : "Окно закроется само.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(12)
                .background(Theme.card)
                FriendsSniffWebView(url: start) { u, t in
                    guard let d = t.data(using: .utf8), let list = vm.parseList(d), !list.isEmpty else { return }
                    vm.absorb(list, endpoint: u)
                    found = vm.friends.count
                    lastHit = Date()
                }
            }
            .navigationTitle("Синхронизация")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("Готово") { dismiss() } }
            }
            .task {
                vm.beginSync()
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if found > 0 && Date().timeIntervalSince(lastHit) > 5 { dismiss(); break }
                }
            }
        }
    }
}

struct StatusDot: View {
    let online: Bool?
    var size: CGFloat = 14

    var body: some View {
        if let o = online {
            Circle().fill(o ? Color.green : Color.gray.opacity(0.7))
                .frame(width: size, height: size)
                .overlay(Circle().stroke(Theme.base, lineWidth: 2.5))
        }
    }
}

struct FriendsView: View {
    let userID: Int
    @ObservedObject var vm: FriendsViewModel
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var local = LocalFriends.shared
    @State private var search = ""
    @State private var onlyOnline = false
    @State private var showAdd = false
    @State private var showSync = false
    @State private var manual = ""
    @State private var manualMsg = ""
    @State private var opened: Friend?
    @State private var pushOpened = false

    private var all: [Friend] { FriendsViewModel.merged(vm.friends, local.items) }
    private var onlineCount: Int { all.filter { $0.online == true }.count }

    private var shown: [Friend] {
        var list = all
        if onlyOnline { list = list.filter { $0.online == true } }
        let q = search.trimmingCharacters(in: .whitespaces)
        return q.isEmpty ? list : list.filter { $0.username.localizedCaseInsensitiveContains(q) }
    }

    private func statTile(_ icon: String, _ value: String, _ label: String, _ tint: Color) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon)
                .font(.subheadline.weight(.bold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.16), in: Circle())
            VStack(alignment: .leading, spacing: 0) {
                Text(value).font(.title3.bold())
                Text(label).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).stroke(Theme.chip))
    }

    private func pill(_ title: String, _ on: Bool, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.footnote.weight(.semibold))
                .padding(.horizontal, 14).padding(.vertical, 7)
                .foregroundStyle(on ? Color.white : Color.primary)
                .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chip), in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func row(_ f: Friend) -> some View {
        NavigationLink {
            FriendProfileView(friend: f)
        } label: {
            HStack(spacing: 14) {
                AnimatedRemoteImage(url: f.avatar, maxPixel: 200)
                    .frame(width: 54, height: 54)
                    .clipShape(Circle())
                    .overlay(Circle().stroke(f.online == true ? Color.green.opacity(0.9) : Color.white.opacity(0.12), lineWidth: 2))
                    .overlay(alignment: .bottomTrailing) { StatusDot(online: f.online, size: 15).offset(x: 2, y: 2) }
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(f.username).font(.subheadline.weight(.semibold)).lineLimit(1)
                        if f.premium { Image(systemName: "crown.fill").font(.caption2).foregroundStyle(.yellow) }
                    }
                    if !f.statusText.isEmpty {
                        Text(f.statusText)
                            .font(.caption)
                            .foregroundStyle(f.online == true ? Color.green : Color.secondary)
                    }
                    HStack(spacing: 10) {
                        if let lv = f.level { Label("\(lv)", systemImage: "star.fill").foregroundStyle(.yellow) }
                        if let st = f.streak { Label("\(st)", systemImage: "flame.fill").foregroundStyle(.orange) }
                    }
                    .font(.caption2.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(12)
            .background(
                LinearGradient(colors: [Theme.accent.opacity(f.online == true ? 0.20 : 0.08), Theme.card],
                               startPoint: .topLeading, endPoint: .bottomTrailing),
                in: RoundedRectangle(cornerRadius: 20))
            .overlay(RoundedRectangle(cornerRadius: 20).stroke(Theme.chip))
        }
        .buttonStyle(.pressable)
    }

    private func openManual() async {
        guard let id = FriendParser.userID(from: manual) else {
            manualMsg = "Не понял. Вставь ссылку вида …/user/123 или просто число."
            return
        }
        manualMsg = "Ищу…"
        if let f = await FriendParser.detail(id: id, token: auth.token) {
            manualMsg = ""
            manual = ""
            showAdd = false
            try? await Task.sleep(nanoseconds: 400_000_000)
            opened = f
            pushOpened = true
        } else {
            manualMsg = "Пользователь не найден или профиль закрыт."
        }
    }

    private var addSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Добавить друга").font(.headline)
            Text("Вставь ссылку на профиль или номер пользователя. Профиль откроется, и его можно добавить в свой список.")
                .font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                TextField("https://…/user/123", text: $manual)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .padding(12)
                    .background(Theme.chip, in: RoundedRectangle(cornerRadius: 14))
                Button { Task { await openManual() } } label: {
                    Image(systemName: "arrow.right")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .frame(width: 46, height: 46)
                        .background(Theme.accent, in: Circle())
                }
                .buttonStyle(.pressable)
            }
            if !manualMsg.isEmpty { Text(manualMsg).font(.caption).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
        .padding(20)
        .background(AppBackground())
        .presentationDetents([.height(270)])
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
                .frame(width: 76, height: 76)
                .background(Theme.accent.opacity(0.15), in: Circle())
            Text("Здесь пока никого").font(.headline)
            Text("Приложение может подтянуть список прямо с сайта, пока ты в нём вошёл. Или добавь друзей вручную по ссылке.")
                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            Button { showSync = true } label: {
                Label("Синхронизировать с сайтом", systemImage: "arrow.triangle.2.circlepath")
                    .font(.footnote.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(Theme.accent, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.pressable)
            Button { showAdd = true } label: {
                Label("Добавить по ссылке", systemImage: "person.badge.plus")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.accent)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(22)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.chip))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !all.isEmpty {
                    HStack(spacing: 10) {
                        statTile("person.2.fill", "\(all.count)", "друзей", Theme.accent)
                        statTile("dot.radiowaves.left.and.right", "\(onlineCount)", "в сети", .green)
                    }
                    HStack(spacing: 8) {
                        pill("Все", !onlyOnline) { onlyOnline = false }
                        pill("В сети", onlyOnline) { onlyOnline = true }
                        Spacer()
                    }
                    .padding(.top, 2)
                }
                if vm.isLoading && all.isEmpty { ProgressView().padding(.top, 30) }
                ForEach(shown) { row($0) }
                if vm.loaded && all.isEmpty && !vm.isLoading { emptyState.padding(.top, 8) }
                if !all.isEmpty && onlyOnline && shown.isEmpty {
                    Text("Сейчас никого нет в сети").font(.footnote).foregroundStyle(.secondary).padding(.top, 16)
                }

                if !vm.debug.isEmpty {
                    DisclosureGroup {
                        Text(vm.debug)
                            .font(.system(size: 10, design: .monospaced))
                            .textSelection(.enabled)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    } label: {
                        Text("Технические подробности").font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(12)
                    .background(Theme.card.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
                    .padding(.top, 6)
                }
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle("Друзья")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $search, prompt: "Поиск среди друзей")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                HStack(spacing: 14) {
                    Button { showSync = true } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                    Button { showAdd = true } label: { Image(systemName: "person.badge.plus") }
                }
            }
        }
        .macSheet(isPresented: $showAdd) { addSheet }
        .fullScreenCover(isPresented: $showSync, onDismiss: {
            if let t = auth.token { Task { await vm.enrich(token: t) } }
        }) { FriendsSyncView(userID: userID, vm: vm) }
        .refreshable { if let t = auth.token { await vm.load(userID: userID, token: t) } }
        .task {
            if !vm.loaded, let t = auth.token { await vm.load(userID: userID, token: t) }
        }
        .navigationDestination(isPresented: $pushOpened) {
            if let f = opened { FriendProfileView(friend: f) }
        }
    }
}

struct FriendProfileView: View {
    @State var friend: Friend
    @StateObject private var vm = ProfileViewModel()
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var local = LocalFriends.shared
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

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
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
    }

    private var header: some View {
        VStack(spacing: 0) {
            Group {
                if let c = friend.cover {
                    AnimatedRemoteImage(url: c, maxPixel: 900)
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.55), Theme.accent.opacity(0.15)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .frame(height: 130)
            .clipped()
            .overlay(alignment: .bottom) {
                LinearGradient(colors: [.clear, Theme.base.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                    .frame(height: 60)
            }

            AnimatedRemoteImage(url: friend.avatar, maxPixel: 360)
                .frame(width: 88, height: 88)
                .clipShape(RoundedRectangle(cornerRadius: 22))
                .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.base, lineWidth: 4))
                .overlay(alignment: .topTrailing) { StatusDot(online: friend.online, size: 18).offset(x: 6, y: -6) }
                .padding(.top, -44)

            VStack(spacing: 10) {
                Text(friend.username).font(.title2.bold())
                if !friend.statusText.isEmpty {
                    Text(friend.statusText)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(friend.online == true ? Color.green : Color.secondary)
                }
                if friend.premium {
                    Label("Premium", systemImage: "crown.fill").font(.caption.bold()).foregroundStyle(.yellow)
                }
                HStack(spacing: 8) {
                    if let st = friend.streak { stat("flame.fill", .orange, "Серия: \(st) дн.") }
                    if let lv = friend.level { stat("star.fill", .yellow, "Уровень \(lv)") }
                    if vm.totalTitles > 0 { stat("rectangle.stack.fill", Theme.accent, "\(vm.totalTitles) тайтлов") }
                }
                Button {
                    Haptics.tap()
                    local.toggle(friend)
                } label: {
                    Label(local.contains(friend.id) ? "В моём списке друзей" : "Добавить в свой список",
                          systemImage: local.contains(friend.id) ? "checkmark.circle.fill" : "person.badge.plus")
                        .font(.footnote.weight(.semibold))
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(local.contains(friend.id) ? AnyShapeStyle(Theme.chip) : AnyShapeStyle(Theme.accent), in: Capsule())
                        .foregroundStyle(local.contains(friend.id) ? Color.primary : Color.white)
                }
                .buttonStyle(.pressable)
            }
            .padding(.top, 10)
            .padding(.horizontal, 14)
            .padding(.bottom, 16)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .overlay(RoundedRectangle(cornerRadius: 22).stroke(Theme.chip))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                header

                if !vm.folders.isEmpty {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                        ForEach(vm.folders) { f in
                            Button { Task { await vm.select(f.id) } } label: {
                                VStack(alignment: .leading, spacing: 6) {
                                    HStack {
                                        Image(systemName: folderIcon(f.name)).font(.subheadline)
                                        Spacer()
                                        Text(f.count.map(String.init) ?? "").font(.title3.bold())
                                    }
                                    Text(f.name).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
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
                    Text("Списки недоступны: \(e)").font(.footnote).foregroundStyle(.orange)
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
                if vm.items.isEmpty && !vm.isLoading && vm.error == nil {
                    Text("В этом списке пока ничего нет или он скрыт").foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle(friend.username)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let t = auth.token {
                if let d = await FriendParser.detail(id: friend.id, token: t) { friend.merge(d) }
                vm.configure(userID: friend.id, token: t)
                await vm.loadFolders()
            }
        }
    }
}
