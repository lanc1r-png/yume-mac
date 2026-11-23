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

struct MangaReaderView: View {
    let novel: Anime
    let chapters: [NovelChapter]
    @State private var index: Int
    @State private var pages: [MangaPage] = []
    @State private var loading = true
    @State private var error: String?
    @State private var chromeHidden = false
    @State private var fillWidth = false
    @State private var current = 0
    @State private var scrollPage = 0
    @State private var historyTask: Task<Void, Never>?
    @State private var showChapters = false
    @State private var pendingPage: Int?
    @State private var jumpTick = 0
    @State private var showComments = false
    /// Комментарии глав подгружаются заранее, чтобы открывались сразу
    @State private var commentsCache = ChapterCommentsCache()
    @State private var preloadTask: Task<Void, Never>?
    @State private var titleMode: String
    @State private var prefs: MangaTitlePrefs
    @State private var showSettings = false
    @State private var sliding = false
    @State private var sliderValue = 0.0
    @State private var scroller = AutoScroller()
    @State private var autoOn = false
    @State private var reachedEnd = false
    @State private var autoNote = ""
    @AppStorage("manga.auto.speed") private var autoSpeed = 60.0
    @AppStorage("manga.auto.next") private var autoNext = true
    @AppStorage("manga.mode.default") private var defaultMode = "auto"
    @AppStorage("manga.anim") private var anim = "slide"
    @AppStorage("manga.autobg") private var gAutoBG = false
    @AppStorage("manga.f.dim") private var gDim = 0.0
    @AppStorage("manga.f.warm") private var gWarm = 0.0
    @AppStorage("manga.f.gray") private var gGray = false
    @Environment(\.hostDismiss) private var dismiss

    init(novel: Anime, chapters: [NovelChapter], start: Int) {
        self.novel = novel
        self.chapters = chapters
        _titleMode = State(initialValue: UserDefaults.standard.string(forKey: "manga.mode.\(novel.id)") ?? "auto")
        let saved = UserDefaults.standard.data(forKey: "manga.tprefs.\(novel.id)")
            .flatMap { try? JSONDecoder().decode(MangaTitlePrefs.self, from: $0) }
        _prefs = State(initialValue: saved ?? MangaTitlePrefs())
        _index = State(initialValue: min(max(start, 0), max(chapters.count - 1, 0)))
    }

    private var own: Bool { prefs.enabled }
    private var effAnim: String { own ? prefs.anim : anim }
    private var effAutoBG: Bool { own ? prefs.autoBG : gAutoBG }
    private var effAutoNext: Bool { own ? prefs.autoNext : autoNext }
    private var effSpeed: Double { own ? prefs.speed : autoSpeed }
    private var effDim: Double { own ? prefs.dim : gDim }
    private var effWarm: Double { own ? prefs.warm : gWarm }
    private var effGray: Bool { own ? prefs.gray : gGray }

    /// Значение читается и пишется либо в свои настройки тайтла, либо в общие.
    private func bind<T>(_ path: WritableKeyPath<MangaTitlePrefs, T>, _ global: Binding<T>) -> Binding<T> {
        Binding(get: { own ? prefs[keyPath: path] : global.wrappedValue },
                set: { v in if own { prefs[keyPath: path] = v } else { global.wrappedValue = v } })
    }

    private var ownBinding: Binding<Bool> {
        Binding(get: { prefs.enabled },
                set: { on in
                    if on && !prefs.enabled {
                        prefs.anim = anim; prefs.autoBG = gAutoBG; prefs.autoNext = autoNext
                        prefs.speed = autoSpeed; prefs.dim = gDim; prefs.warm = gWarm; prefs.gray = gGray
                    }
                    prefs.enabled = on
                })
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

    private func persistPos() {
        guard let ch = chapter, !loading, !pages.isEmpty, pendingPage == nil else { return }
        let n = min(shown, pages.count)
        let pct = pages.count > 1 ? min(100, n * 100 / (pages.count - 1)) : 0
        ReadPosStore.shared.set(novel.readKey, ReadPos(c: ch.id, p: n, b: 0, pct: pct, t: Int(Date().timeIntervalSince1970),
                                                       n: pages.count))
    }

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

    private func pagesReady() -> Bool {
        guard !pages.isEmpty else { return false }
        let lo = min(max(scrollPage, 0), pages.count - 1)
        let hi = min(lo + 1, pages.count - 1)
        for k in lo...hi {
            let p = pages[k]
            if ImageCache.shared.object(forKey: ImageCache.key(p.url, p.maxPixel)) == nil { return false }
        }
        return true
    }

    private func setAuto(_ on: Bool) {
        autoOn = on
        if on {
            scroller.speed = CGFloat(effSpeed)
            scroller.canAdvance = { !showSettings && !showComments && !showChapters && pagesReady() }
            scroller.onEnd = {
                guard reachedEnd else { return false }
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 1_200_000_000)
                    guard autoOn else { return }
                    if effAutoNext && index + 1 < chapters.count {
                        go(1)
                    } else {
                        setAuto(false)
                        chromeHidden = false
                    }
                }
                return true
            }
            scroller.onBlocked = { b in autoNote = b ? "Жду загрузки страниц…" : "" }
            autoNote = ""
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = true }
            scroller.start()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 2_500_000_000)
                if autoOn && scroller.scrollView == nil { autoNote = "Не нашёл ленту для прокрутки" }
            }
        } else {
            scroller.stop()
            autoNote = ""
        }
    }

    private func handleTap(_ x: CGFloat) {
        if vertical && autoOn {
            setAuto(false)
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = false }
            return
        }
        if vertical || !Settings.bool("manga.tapzones", true) {
            withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() }
            return
        }
        if x < 0.3 { turn(-1) }
        else if x > 0.7 { turn(1) }
        else { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
    }

    /// Фоновая подгрузка. Декодируются (занимают память) только страницы рядом с текущей:
    /// одна назад и три вперёд. Остальные страницы главы лишь скачиваются в дисковый кэш.
    private func preload(from start: Int) {
        preloadTask?.cancel()
        let list = pages
        guard !list.isEmpty else { return }
        let first = min(max(start, 0), list.count - 1)
        let cellular = DownloadManager.shared.expensive
        preloadTask = Task {
            // 1. Текущая страница, затем соседние: готовые картинки в памяти.
            _ = await MangaImageStore.shared.image(for: list[first])
            var near: [Int] = []
            for k in 1...3 where first + k < list.count { near.append(first + k) }
            if first > 0 { near.append(first - 1) }
            await withTaskGroup(of: Void.self) { group in
                for id in near { group.addTask { _ = await MangaImageStore.shared.image(for: list[id]) } }
            }
            // 2. Дальше по главе только скачиваем, по три за раз: сначала вперёд, потом назад.
            //    По мобильной сети — только ~10 страниц вперёд: модем чаще отдыхает, заряд и трафик экономятся.
            //    Окно сдвигается вместе с чтением, поэтому следующие страницы всё равно успевают подгрузиться.
            let aheadEnd = cellular ? min(first + 12, list.count) : list.count
            var rest = Array((first + 4)..<max(first + 4, aheadEnd))
            if !cellular { rest += Array((0..<max(first - 1, 0)).reversed()) }
            var i = 0
            while i < rest.count {
                if Task.isCancelled { return }
                let chunk = Array(rest[i..<min(i + 3, rest.count)])
                i += 3
                await withTaskGroup(of: Void.self) { group in
                    for id in chunk { group.addTask { await MangaImageStore.shared.warm(list[id]) } }
                }
            }
        }
    }

    /// Mac: страница по ширине окна, листается по вертикали.
    private var fillView: some View {
        ScrollView(.vertical) {
            Group {
                if current < pages.count {
                    MangaPageView(page: pages[current], vertical: true, autoBG: effAutoBG, onTap: handleTap)
                } else {
                    endCard.frame(height: 420)
                }
            }
            .background(ScrollFinder { scroller.scrollView = $0 })
        }
        .id("f\(index)-\(current)")
        .ignoresSafeArea()
    }

    private func toggleFill() {
        let on = !fillWidth
        fillWidth = on
        withAnimation(.easeInOut(duration: 0.2)) { chromeHidden = on }
        if MacFullscreen.isOn != on { MacFullscreen.toggle() }
    }

    /// Прокрутка внутри страницы; дошли до края — следующая или предыдущая страница.
    private func fillStep(_ dir: CGFloat, page: Bool) {
        guard let sv = scroller.scrollView, let doc = sv.documentView else { turn(dir > 0 ? 1 : -1); return }
        let clip = sv.contentView
        let maxY = max(doc.frame.height - clip.bounds.height, 0)
        let y = clip.bounds.origin.y
        let step = page ? clip.bounds.height * 0.88 : 140
        if dir > 0, y >= maxY - 1 { turn(1); return }
        if dir < 0, y <= 1 { if page { turn(-1) }; return }
        let ny = min(max(y + dir * step, 0), maxY)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: ny))
        }
        sv.reflectScrolledClipView(clip)
    }

    @ViewBuilder
    private var pagedView: some View {
        switch effAnim {
        case "book":
            GeometryReader { geo in
                let ref = pages[min(current, max(pages.count - 1, 0))]
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
                            ? AnyView(MangaPageView(page: pages[i], dim: 0.9, autoBG: effAutoBG, onTap: handleTap, onSwipeUp: openComments))
                            : AnyView(endCard)
                    }
                    .frame(width: fitW, height: fitH)
                }
                .frame(width: geo.size.width, height: geo.size.height)
            }
        case "fade":
            ZStack {
                if current < pages.count {
                    MangaPageView(page: pages[current], autoBG: effAutoBG, onTap: handleTap, onSwipeUp: openComments)
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
                    MangaPageView(page: p, autoBG: effAutoBG, onTap: handleTap, onSwipeUp: openComments).tag(p.id)
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
        GlassGroup(spacing: 10) {
        HStack(spacing: 10) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                    .frame(width: 46, height: 46)
                    .liquidGlass(Circle())
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(novel.displayTitle).font(.footnote.bold()).lineLimit(1)
                if let c = chapter {
                    Text("Том \(c.volume) · Глава \(c.number)").font(.caption2).opacity(0.7)
                }
            }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, minHeight: 46, alignment: .leading)
            .liquidGlass(Capsule())
            HStack(spacing: 0) {
                Button { showSettings = true } label: {
                    Image(systemName: "slider.horizontal.3")
                        .frame(width: 42, height: 46)
                }
                Button { showChapters = true } label: {
                    Image(systemName: "list.bullet").frame(width: 42, height: 46)
                }
                Button { showComments = true } label: {
                    Image(systemName: "bubble.left.and.bubble.right").frame(width: 42, height: 46)
                }
            }
            .padding(.horizontal, 4)
            .liquidGlass(Capsule())
        }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 8)
    }

    private func seek(_ p: Int) {
        let n = min(max(p, 0), max(pages.count - 1, 0))
        if vertical {
            current = n
            scrollPage = n
            jumpTick += 1
        } else {
            withAnimation(.easeOut(duration: 0.2)) { current = n }
        }
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if vertical {
                HStack(spacing: 10) {
                    Button { setAuto(!autoOn) } label: {
                        Image(systemName: autoOn ? "pause.circle.fill" : "play.circle.fill").font(.title2)
                    }
                    Image(systemName: "tortoise.fill").font(.caption)
                    Slider(value: bind(\.speed, $autoSpeed), in: 15...240, step: 5).tint(Theme.accent)
                    Image(systemName: "hare.fill").font(.caption)
                    Text("\(Int(effSpeed))").font(.caption2.monospacedDigit()).frame(width: 28)
                }
                .padding(.horizontal, 16)
                if !autoNote.isEmpty {
                    Text(autoNote).font(.caption2).opacity(0.7)
                }
            }
            if pages.count > 1 {
                Slider(value: $sliderValue, in: 0...Double(pages.count - 1), step: 1) { editing in
                    sliding = editing
                    if !editing { seek(Int(sliderValue)) }
                }
                .tint(Theme.accent)
                .padding(.horizontal, 16)
                .onChange(of: shown) { _, v in
                    if !sliding { sliderValue = Double(min(v, pages.count - 1)) }
                }
                .onChange(of: pages.count) { _, _ in
                    sliderValue = Double(min(shown, max(pages.count - 1, 0)))
                }
                .onChange(of: sliderValue) { _, v in
                    if sliding { Haptics.select() }
                }
            }
            HStack {
                Button { go(-1) } label: { Image(systemName: "backward.end").frame(width: 48, height: 40) }
                    .disabled(index == 0)
                Spacer()
                Text(pages.isEmpty ? "…" : "\(sliding ? Int(sliderValue) + 1 : min(shown + 1, pages.count)) / \(pages.count)")
                    .font(.footnote.monospacedDigit())
                Spacer()
                Button { go(1) } label: { Image(systemName: "forward.end").frame(width: 48, height: 40) }
                    .disabled(index + 1 >= chapters.count)
            }
        }
        .foregroundStyle(.white)
        .environment(\.colorScheme, .dark)
        .padding(.horizontal, 6)
        .padding(.top, 12)
        .padding(.bottom, 4)
        .liquidGlass(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 4)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            Group {
            if !pages.isEmpty {
                if vertical {
                    ScrollViewReader { proxy in
                        ScrollView {
                            LazyVStack(spacing: 0) {
                                ForEach(pages) { p in
                                    MangaPageView(page: p, vertical: true, autoBG: effAutoBG, onTap: handleTap)
                                        .id(p.id)
                                        .onAppear { scrollPage = p.id }
                                }
                                endCard.frame(height: 360).id(pages.count)
                                    .onAppear { reachedEnd = true }
                                // Долистал до конца — ниже сразу комментарии к главе
                                if let c = chapter {
                                    ChapterCommentsPreview(vm: commentsCache.vm(c, novel: novel), open: openComments)
                                }
                            }
                            .background(ScrollFinder { scroller.scrollView = $0 })
                        }
                        .onAppear {
                            if current > 0 { proxy.scrollTo(current, anchor: .top) }
                        }
                    }
                    .id("v\(index)-\(jumpTick)")
                    .ignoresSafeArea(edges: .bottom)
                } else if fillWidth {
                    fillView
                } else {
                    pagedView
                        .id("p\(index)-\(effAnim)")
                        .ignoresSafeArea()
                }
            }
            }
            .modifier(GrayIf(on: effGray))
            if effDim > 0.001 {
                Color.black.opacity(effDim).ignoresSafeArea().allowsHitTesting(false)
            }
            if effWarm > 0.001 {
                Color(red: 1, green: 0.6, blue: 0.2).opacity(effWarm * 0.5).ignoresSafeArea().allowsHitTesting(false)
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
            if chromeHidden, autoOn, !autoNote.isEmpty {
                VStack {
                    Spacer()
                    Text(autoNote)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.black.opacity(0.5), in: Capsule())
                        .padding(.bottom, 44)
                }
                .allowsHitTesting(false)
            }
            // маленький счётчик страниц, пока меню скрыто
            if chromeHidden, !vertical, !pages.isEmpty, !loading {
                VStack {
                    Spacer()
                    Text("\(min(shown + 1, pages.count)) / \(pages.count)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white.opacity(0.92))
                        .padding(.horizontal, 12).padding(.vertical, 5)
                        .background(Color.black.opacity(0.45), in: Capsule())
                        .overlay(Capsule().stroke(Color.white.opacity(0.15), lineWidth: 0.5))
                        .padding(.bottom, 10)
                }
                .allowsHitTesting(false)
                .transition(.opacity)
            }
        }
        .onChange(of: shown) { _, _ in persistPos() }
        .background {
            ZStack {
                KeyShortcut(.leftArrow) { turn(-1) }
                KeyShortcut(.rightArrow) { turn(1) }
                KeyShortcut(.space) { if fillWidth { fillStep(1, page: true) } else { turn(1) } }
                KeyShortcut(.space, .shift) { if fillWidth { fillStep(-1, page: true) } else { turn(-1) } }
                KeyShortcut(.downArrow) { if fillWidth { fillStep(1, page: false) } }
                KeyShortcut(.upArrow) { if fillWidth { fillStep(-1, page: false) } }
            }
            .disabled(vertical || loading || showComments || showSettings || showChapters)
            KeyShortcut("f") { toggleFill() }
                .disabled(vertical || loading || showComments || showSettings || showChapters)
            ZStack {
                KeyShortcut(.leftArrow, .command) { go(-1) }
                KeyShortcut(.rightArrow, .command) { go(1) }
                KeyShortcut(.escape) { dismiss() }
            }
            .disabled(showComments || showSettings || showChapters)
        }
        .background(FullBleedWindow())
        .statusBarHidden(chromeHidden)
        .preferredColorScheme(.dark)
        .task(id: index) { await load() }
        .onChange(of: current) { _, v in
            Haptics.select()
            if !vertical && v < pages.count { preload(from: v) }
        }
        .onChange(of: scrollPage) { _, v in
            if vertical && v < pages.count { preload(from: v) }
        }
        .onChange(of: vertical) { _, v in
            if v { scrollPage = current } else { current = min(scrollPage, pages.count) }
            if !v && autoOn { setAuto(false) }
        }
        .onChange(of: effSpeed) { _, v in scroller.speed = CGFloat(v) }
        .onChange(of: prefs) { _, v in
            if let d = try? JSONEncoder().encode(v) { UserDefaults.standard.set(d, forKey: "manga.tprefs.\(novel.id)") }
        }
        .onChange(of: titleMode) { _, v in
            UserDefaults.standard.set(v, forKey: "manga.mode.\(novel.id)")
        }
        .macSheet(isPresented: $showSettings) {
            MangaReaderSettings(titleMode: $titleMode, defaultMode: $defaultMode, own: ownBinding,
                                anim: bind(\.anim, $anim), autoBG: bind(\.autoBG, $gAutoBG),
                                autoNext: bind(\.autoNext, $autoNext), speed: bind(\.speed, $autoSpeed),
                                dim: bind(\.dim, $gDim), warm: bind(\.warm, $gWarm), gray: bind(\.gray, $gGray),
                                detected: autoVertical ? "лента" : "страницы")
        }
        .macSheet(isPresented: $showChapters) {
            MangaChapterPicker(chapters: chapters, current: index, readKey: novel.readKey) { i in
                guard i != index else { return }
                Haptics.tap()
                pendingPage = nil
                index = i
            }
        }
        .macSheet(isPresented: $showComments) {
            if let c = chapter {
                ChapterCommentsView(novel: novel, chapter: c,
                                    page: min(shown + 1, max(pages.count, 1)), pageCount: pages.count,
                                    vm: commentsCache.vm(c, novel: novel))
                    .presentationDetents([.medium, .large])
                    .presentationDragIndicator(.visible)
            }
        }
        .task(id: index) {
            // Пока читаешь начало главы, тихо подгружаем первые комментарии к ней.
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard !Task.isCancelled, let c = chapter else { return }
            commentsCache.prefetch(c, novel: novel)
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = Settings.bool("set.keepAwake", true) }
        .onDisappear {
            persistPos()
            UIApplication.shared.isIdleTimerDisabled = false
            preloadTask?.cancel()
            historyTask?.cancel()
            scroller.stop()
            scroller.detach()
        }
    }

    /// Открыть комментарии (свайп вверх по странице, кнопка или превью в конце главы).
    private func openComments() {
        guard chapter != nil, !showComments else { return }
        Haptics.tap()
        showComments = true
    }

    private func scheduleHistory(_ ch: NovelChapter) {
        historyTask?.cancel()
        HistoryStore.current.recordChapter(anime: novel, chapterID: ch.id, title: ch.title)
    }

    private func load() async {
        guard let ch = chapter, let slug = novel.slugUrl else { return }
        preloadTask?.cancel()
        loading = true
        error = nil
        pages = []
        current = 0
        scrollPage = 0
        reachedEnd = false
        if pendingPage == nil, let pos = ReadPosStore.shared.get(novel.readKey), pos.c == ch.id, pos.p > 0 {
            pendingPage = pos.p
        }
        ReadStore.shared.mark(novel.readKey, ch.id)
        SiteSync.view(novelID: novel.id, chapterID: ch.id)
        scheduleHistory(ch)
        do {
            let result = try await MangaService.pages(slug: slug, chapter: ch, novelID: novel.id)
            if Task.isCancelled { return }
            pages = result
            if result.isEmpty {
                error = "У главы нет страниц или она недоступна."
            } else {
                if let pp = pendingPage {
                    current = min(max(pp, 0), result.count - 1)
                    scrollPage = current
                    pendingPage = nil
                }
                preload(from: current)
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}
