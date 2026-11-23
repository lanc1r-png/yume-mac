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
        v.setOpaque(false)
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

struct FullscreenPlayer: NSViewRepresentable {
    let player: AVPlayer?
    var onPiPStart: () -> Void = {}
    var onPiPStop: () -> Void = {}
    var onRestore: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, AVPlayerViewPictureInPictureDelegate {
        var parent: FullscreenPlayer
        init(_ p: FullscreenPlayer) { parent = p }

        func playerViewShouldAutomaticallyDismissAtPicture(inPictureStart playerView: AVPlayerView) -> Bool {
            parent.onPiPStart()
            return true
        }

        func playerViewWillStartPicture(inPicture playerView: AVPlayerView) {
            parent.onPiPStart()
        }

        func playerViewDidStopPicture(inPicture playerView: AVPlayerView) {
            parent.onPiPStop()
        }

        func playerView(_ playerView: AVPlayerView,
                        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
            parent.onRestore()
            completionHandler(true)
        }
    }

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.allowsPictureInPicturePlayback = true
        v.showsFullScreenToggleButton = true
        v.pictureInPictureDelegate = context.coordinator
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        context.coordinator.parent = self
        if v.player !== player { v.player = player }
    }
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
    /// Наблюдатель прерываний звука (звонок, будильник): после них видео продолжается само, если iOS это разрешает.
    private var interruptObs: NSObjectProtocol?
    private var rateObs: NSObjectProtocol?
    /// Видео поставила на паузу сама система из-за прерывания (а не ты): только тогда продолжаем.
    private var pausedByInterruption = false
    private var lastWebStream: URL?
    private var attempts: [(URL, [String: String])] = []
    private var attemptIndex = 0
    private var attemptLog: [String] = []
    private var statusObs: NSKeyValueObservation?
    private var lastQualityTitle: String?
    var autoNative = true
    private var autoSwitch = false
    var onEnd: (() -> Void)?
    var onWatched: (() -> Void)?
    private var watchedFired = false
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
        watchedFired = false
        self.episodeID = episodeID
        ProgressStore.shared.opened(episodeID)
        ActivityStore.shared.episodeOpened()
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
        autoSwitch = false
        showWeb = false
        autoNative = Settings.bool("set.autoNative", true)
        qualities = []
        current = v
        if v.kodik {
            savePosition(); detachObserver()
            player?.pause(); player = nil
            // Сначала веб-плеер Kodik: качество выбирается в нём, а родной плеер открывается по кнопке «на весь экран».
            if Settings.bool("set.kodikDirect", true) { Task { await playKodik(v) } } else { showWeb = true }
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
            let why = String(error.localizedDescription.replacingOccurrences(of: "\n", with: " ").prefix(60))
            note = "Прямой поток не получен (\(why)). Нажми ▶ один раз: после запуска включится родной плеер."
            autoSwitch = true
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

    var pipActive = false

    func pipStarted() { pipActive = true }

    func pipRestored() {
        pipActive = false
        showNative = true
    }

    /// Окошко «картинка в картинке» закрыли: останавливаем видео, если экран плеера не открыт.
    func pipStopped() {
        pipActive = false
        guard !showNative else { return }
        if let p = fsPlayer {
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? 0
            if t.isFinite, d.isFinite, d > 0 { ProgressStore.shared.update(episodeID, position: t, duration: d) }
            if p !== player { p.pause() }
        }
        fsPlayer = nil
    }

    func closeNative() {
        if pipActive {
            showNative = false
            return
        }
        if let p = fsPlayer {
            let t = p.currentTime().seconds
            let d = p.currentItem?.duration.seconds ?? 0
            if t.isFinite, d.isFinite, d > 0 { ProgressStore.shared.update(episodeID, position: t, duration: d) }
            if t.isFinite { markWatched(t) }
            if p !== player { p.pause() }
        }
        fsPlayer = nil
        showNative = false
    }

    func forceWeb() { autoNative = false; showWeb = true; note = nil }

    /// Веб-плеер Kodik отдал адрес потока: запоминаем его для полноэкранного режима.
    func webStream(_ u: URL) {
        lastWebStream = u
        // Mac: веб-плеер запущен, адрес потока получен — переходим на родной плеер.
        if autoSwitch {
            autoSwitch = false
            note = nil
            showWeb = false
            startAV(u, headers: ["Referer": "https://kodikplayer.com/", "Origin": "https://kodikplayer.com", "User-Agent": Kodik.ua])
        }
    }

    private func startAV(_ url: URL, headers: [String: String]) {
        guard !stopped else { return }
        if interruptObs == nil {
            rateObs = NotificationCenter.default.addObserver(
                forName: AVPlayer.rateDidChangeNotification, object: nil, queue: .main) { [weak self] n in
                let reason = n.userInfo?[AVPlayer.rateDidChangeReasonKey] as? AVPlayer.RateDidChangeReason
                let rate = (n.object as? AVPlayer)?.rate ?? 0
                let obj = n.object as AnyObject?
                Task { @MainActor [weak self] in
                    guard let self, obj === self.player || obj === self.fsPlayer else { return }
                    if reason == .audioSessionInterrupted, rate == 0 { self.pausedByInterruption = true }
                    else if rate > 0 { self.pausedByInterruption = false }
                }
            }
        }
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
                self?.markWatched(pos)
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

    /// Серия считается начатой после 20 секунд просмотра, а не после простого открытия.
    func markWatched(_ pos: Double) {
        guard !watchedFired, pos >= 20 else { return }
        watchedFired = true
        onWatched?()
    }

    func stop() {
        savePosition(); stopped = true; detachObserver(); statusObs = nil; player?.pause(); player = nil
        if let o = interruptObs { NotificationCenter.default.removeObserver(o); interruptObs = nil }
        if let o = rateObs { NotificationCenter.default.removeObserver(o); rateObs = nil }
        pausedByInterruption = false
        // Замыкания держат экран серии, а экран держит этот объект: разрываем кольцо, иначе он не освобождается.
        onEnd = nil
        onWatched = nil
        ProgressStore.shared.flush()
    }
}

struct PlayerScreen: View {
    let animeTitle: String
    var anime: Anime? = nil
    let episodes: [EpisodeShort]
    @State private var current: EpisodeShort
    @StateObject private var vm = PlayerViewModel()
    @Environment(\.hostDismiss) private var dismiss

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

    private func seekPlayer(_ seconds: Double) {
        guard let p = vm.player else { return }
        let now = p.currentTime().seconds
        guard now.isFinite else { return }
        p.seek(to: CMTime(seconds: max(now + seconds, 0), preferredTimescale: 600))
    }

    private func go(_ ep: EpisodeShort?) {
        guard let ep = ep else { return }
        Haptics.tap()
        vm.stop()
        current = ep
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
        if let n = vm.note, !n.isEmpty {
            Text(n)
                .font(.caption2)
                .foregroundStyle(.orange)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        if !vm.sourceNote.isEmpty, Keychain.get("lib.token") == nil {
            Button {
                AppRouter.shared.tab = 3
                if let w = NSApp.windows.first(where: { !($0.delegate is HostWindow) && $0.isVisible && $0.canBecomeMain }) {
                    w.makeKeyAndOrderFront(nil)
                    NSApp.activate(ignoringOtherApps: true)
                }
            } label: {
                Label("Войти в аккаунт, чтобы открылся плеер Animelib", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.footnote.weight(.semibold))
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity, alignment: .leading)
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
            HStack(spacing: 0) {
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
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Divider()
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
                .frame(width: 360)
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
            let ep = current
            vm.onWatched = { if let a = anime { HistoryStore.shared.record(anime: a, episode: ep) } }
            vm.onEnd = { go(nextEpisode) }
            await vm.load(episodeID: ep.id)
            // Веб-плеер не сообщает позицию: считаем просмотром 45 секунд на экране серии.
            if vm.player == nil, vm.error == nil, vm.current != nil {
                try? await Task.sleep(nanoseconds: 45_000_000_000)
                if !Task.isCancelled, vm.player == nil { vm.onWatched?() }
            }
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
            KeyCodeShortcut(keyCode: 3, enabled: !vm.usesWeb && vm.player != nil && !vm.showNative) { vm.openFullscreen() }
                .frame(width: 0, height: 0)
            ZStack {
                KeyShortcut(.leftArrow, .command) { go(prevEpisode) }
                KeyShortcut(.rightArrow, .command) { go(nextEpisode) }
                KeyShortcut(.escape) { vm.stop(); dismiss() }
            }
            .disabled(vm.showNative)
        }
        .fullScreenCover(isPresented: $vm.showNative, onDismiss: { vm.closeNative() }) {
            ZStack(alignment: .topLeading) {
                Color.black.ignoresSafeArea()
                FullscreenPlayer(player: vm.fsPlayer,
                                 onPiPStart: { vm.pipStarted() },
                                 onPiPStop: { vm.pipStopped() },
                                 onRestore: { vm.pipRestored() })
                    .ignoresSafeArea()
                if true {
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
