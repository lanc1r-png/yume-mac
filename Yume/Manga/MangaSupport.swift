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

struct MangaPageView: View {
    let page: MangaPage
    var vertical = false
    var dim: CGFloat = 1
    var autoBG = false
    let onTap: (CGFloat) -> Void
    var onSwipeUp: (() -> Void)? = nil
    @State private var image: UIImage?
    @State private var failed = false
    @State private var note = ""
    @State private var attempt = 0
    @State private var scale: CGFloat = 1
    @State private var base: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero
    @State private var bg: Color?

    /// Белое или чёрное поле по краям самой страницы.
    nonisolated static func edgeColor(_ img: UIImage) -> Color? {
        guard let cg = img.cgImage else { return nil }
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var ok = false
        px.withUnsafeMutableBytes { buf in
            guard let ctx = CGContext(data: buf.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                      bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            ok = true
        }
        guard ok else { return nil }
        var sum = 0.0
        var cnt = 0.0
        for y in 0..<n {
            for x in 0..<n where x < 2 || y < 2 || x >= n - 2 || y >= n - 2 {
                let i = (y * n + x) * 4
                sum += 0.299 * Double(px[i]) + 0.587 * Double(px[i + 1]) + 0.114 * Double(px[i + 2])
                cnt += 1
            }
        }
        return sum / max(cnt, 1) / 255 > 0.5 ? Color.white : Color.black
    }

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
        .background(autoBG ? (bg ?? Color.clear) : Color.clear)
        .task(id: "\(page.id)-\(attempt)") { await load() }
    }

    /// Режим ленты: страницы идут одна под другой, высота по картинке.
    @ViewBuilder
    private var flow: some View {
        if let image {
            Image(uiImage: image)
                .resizable()
                .interpolation(.high)
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
                    Image(uiImage: image).resizable().interpolation(.high).scaledToFit().frame(width: size.width)
                }
                .simultaneousGesture(SpatialTapGesture().onEnded { v in onTap(v.location.x / max(size.width, 1)) })
            } else {
                ZoomableImageView(image: image, dim: dim, onTap: onTap, onSwipeUp: onSwipeUp)
                    .frame(width: size.width, height: size.height)
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
            // Цвет полей считается в фоне: для длинной страницы это заметная работа.
            bg = await Task.detached(priority: .utility) { MangaPageView.edgeColor(img) }.value
            return
        }
        if Task.isCancelled { return }
        note = await MangaImageStore.shared.lastNote
        failed = true
    }
}

/// NSClipView, который держит страницу по центру, пока она меньше окна.
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        if let doc = documentView {
            if rect.width > doc.frame.width { rect.origin.x = (doc.frame.width - rect.width) / 2 }
            if rect.height > doc.frame.height { rect.origin.y = (doc.frame.height - rect.height) / 2 }
        }
        return rect
    }
}

/// Страница манги с зумом: щипок и Cmd+колесо приближают, двойной щелчок приближает к месту и возвращает обратно.
final class FitScrollView: NSScrollView {
    let imageView = NSImageView()
    private var lastSize: CGSize = .zero
    private weak var lastImage: NSImage?

    override init(frame: NSRect) {
        super.init(frame: frame)
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        drawsBackground = false
        hasVerticalScroller = false
        hasHorizontalScroller = false
        allowsMagnification = true
        minMagnification = 1
        maxMagnification = 5
        imageView.imageScaling = .scaleAxesIndependently
        documentView = imageView
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        guard let img = imageView.image, bounds.width > 1, bounds.height > 1,
              img.size.width > 0, img.size.height > 0 else { return }
        if bounds.size != lastSize || lastImage !== img {
            lastSize = bounds.size
            lastImage = img
            magnification = 1
            let r = min(bounds.width / img.size.width, bounds.height / img.size.height)
            imageView.frame = CGRect(origin: .zero, size: CGSize(width: img.size.width * r, height: img.size.height * r))
        }
    }
}

struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    var dim: CGFloat = 1
    let onTap: (CGFloat) -> Void
    /// Свайп вверх по странице: на Mac не используется
    var onSwipeUp: (() -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onTap: ((CGFloat) -> Void)?
        private var pending: DispatchWorkItem?

        @objc func single(_ g: NSClickGestureRecognizer) {
            guard let s = g.view as? NSScrollView else { return }
            let x = g.location(in: s).x
            let frac = x / max(s.bounds.width, 1)
            pending?.cancel()
            let w = DispatchWorkItem { [weak self] in self?.onTap?(frac) }
            pending = w
            // ждём: вдруг это первая половина двойного щелчка
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28, execute: w)
        }

        @objc func double(_ g: NSClickGestureRecognizer) {
            pending?.cancel()
            guard let s = g.view as? FitScrollView else { return }
            if s.magnification > s.minMagnification + 0.05 {
                s.setMagnification(s.minMagnification, centeredAt: g.location(in: s.imageView))
            } else {
                s.setMagnification(2.6, centeredAt: g.location(in: s.imageView))
            }
        }
    }

    func makeUIView(context: Context) -> FitScrollView {
        let s = FitScrollView(frame: .zero)
        let dbl = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.double(_:)))
        dbl.numberOfClicksRequired = 2
        let one = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.single(_:)))
        s.addGestureRecognizer(dbl)
        s.addGestureRecognizer(one)
        return s
    }

    func updateUIView(_ s: FitScrollView, context: Context) {
        context.coordinator.onTap = onTap
        if s.imageView.image !== image {
            s.imageView.image = image
            s.needsLayout = true
        }
        s.imageView.alphaValue = dim
    }
}

/// Комментарии глав, загруженные заранее: открываются мгновенно, без ожидания сети.
@MainActor
final class ChapterCommentsCache {
    private var vms: [Int: CommentsViewModel] = [:]

    func vm(_ chapter: NovelChapter, novel: Anime) -> CommentsViewModel {
        if let v = vms[chapter.id] { return v }
        let v = CommentsViewModel(animeID: chapter.id, slug: novel.slugUrl ?? String(novel.id), postType: "chapter")
        vms[chapter.id] = v
        if vms.count > 6, let old = vms.keys.first(where: { $0 != chapter.id }) { vms[old] = nil }
        return v
    }

    /// Тихо подгружает первую страницу комментариев главы.
    func prefetch(_ chapter: NovelChapter, novel: Anime) {
        let v = vm(chapter, novel: novel)
        guard v.items.isEmpty, !v.isLoading else { return }
        Task { await v.loadMore() }
    }
}

/// Превью комментариев в конце главы (режим «Лента»): долистал — и видишь первые комментарии.
struct ChapterCommentsPreview: View {
    @ObservedObject var vm: CommentsViewModel
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Комментарии", systemImage: "bubble.left.and.bubble.right.fill")
                    .font(.headline)
                Spacer()
                if vm.isLoading && vm.items.isEmpty { ProgressView().tint(.white) }
            }
            if vm.items.isEmpty && !vm.isLoading {
                Text("Комментариев пока нет — будь первым").font(.subheadline).foregroundStyle(.white.opacity(0.6))
            }
            ForEach(Array(vm.sorted.prefix(3))) { c in
                HStack(alignment: .top, spacing: 10) {
                    RemoteImage(url: c.avatar, maxPixel: 96)
                        .frame(width: 32, height: 32)
                        .clipShape(Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(c.username).font(.caption.weight(.semibold)).foregroundStyle(.white.opacity(0.75))
                        Text(c.text).font(.subheadline).lineLimit(4).foregroundStyle(.white)
                    }
                }
            }
            Button(action: open) {
                Text(vm.items.count > 3 ? "Все комментарии (\(vm.items.count)\(vm.items.count >= 20 ? "+" : ""))" : "Открыть комментарии")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.white.opacity(0.1), in: Capsule())
            }
            .buttonStyle(.pressable)
        }
        .foregroundStyle(.white)
        .padding(18)
        .background(Color.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .padding(.horizontal, 14)
        .padding(.bottom, 40)
    }
}

struct ChapterCommentsView: View {
    let novel: Anime
    let chapter: NovelChapter
    let pageCount: Int
    @State private var page: Int
    @State private var wholeChapter = false
    @StateObject private var vm: CommentsViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var showCompose = false

    init(novel: Anime, chapter: NovelChapter, page: Int = 1, pageCount: Int = 0, vm ready: CommentsViewModel? = nil) {
        self.novel = novel
        self.chapter = chapter
        self.pageCount = pageCount
        _page = State(initialValue: max(page, 1))
        _vm = StateObject(wrappedValue: ready ?? CommentsViewModel(animeID: chapter.id, slug: novel.slugUrl ?? String(novel.id),
                                                                   postType: "chapter"))
    }

    private var hasPages: Bool { pageCount > 0 || vm.items.contains { $0.page != nil } }
    private var perPage: Bool { !wholeChapter && hasPages }
    private var onPage: [CommentItem] { vm.items.filter { vm.onPostPage($0, page) } }
    private var pageLoading: Bool { vm.loadingPages.contains(page) || vm.pageIDs[page] == nil }

    /// Комментарии текущей страницы + соседних заранее, чтобы перелистывание в окне было мгновенным.
    private func loadAround() {
        let p = page
        Task { await vm.loadPostPage(p) }
        Task {
            if p + 1 <= max(pageCount, p + 1) { await vm.loadPostPage(p + 1) }
            if p > 1 { await vm.loadPostPage(p - 1) }
        }
    }

    private func syncPostPage() { vm.postPage = perPage ? page : nil }

    private var pageBar: some View {
        VStack(spacing: 8) {
            Picker("", selection: $wholeChapter) {
                Text("Эта страница").tag(false)
                Text("Вся глава").tag(true)
            }
            .pickerStyle(.segmented)
            if !wholeChapter && hasPages {
                HStack {
                    Button { page = max(1, page - 1) } label: { Image(systemName: "chevron.left") }
                        .disabled(page <= 1)
                    Spacer()
                    Text("Страница \(page)" + (pageCount > 0 ? " из \(pageCount)" : "") + " · комментариев: \(onPage.count)")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button { page = pageCount > 0 ? min(pageCount, page + 1) : page + 1 } label: { Image(systemName: "chevron.right") }
                        .disabled(pageCount > 0 && page >= pageCount)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                pageBar
                ScrollView {
                    VStack(spacing: 10) {
                        if perPage {
                            let p = page
                            CommentsList(vm: vm, filter: { vm.onPostPage($0, p) })
                            if onPage.isEmpty {
                                if pageLoading {
                                    ProgressView().padding(.top, 30)
                                } else {
                                    Text("К этой странице комментариев нет").foregroundStyle(.secondary).padding(.top, 30)
                                }
                            }
                        } else {
                            CommentsList(vm: vm)
                            if !vm.items.isEmpty && !hasPages && !vm.isLoading {
                                Text("Сайт не передаёт номера страниц у комментариев, поэтому показана вся глава. Поля комментария: \(vm.sampleKeys)")
                                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(14)
                }
            }
            .background(AppBackground())
            .navigationTitle("Глава \(chapter.number)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    HStack(spacing: 12) {
                        CommentSortMenu(vm: vm)
                        Button { syncPostPage(); showCompose = true } label: { Image(systemName: "square.and.pencil") }
                    }
                }
            }
            .commentSheets(vm, showCompose: $showCompose)
            .task {
                syncPostPage()
                if hasPages { loadAround() }
                // вся глава: первая порция сразу, остальное — по мере прокрутки списка
                if vm.items.isEmpty { await vm.loadMore() }
            }
            .onChange(of: page) { _, _ in syncPostPage(); loadAround() }
            .onChange(of: wholeChapter) { _, _ in syncPostPage() }
        }
    }
}

/// Перелистывание страниц с плавной сменой (на Mac без page curl).
struct BookPager: View {
    let count: Int
    @Binding var current: Int
    var backColor: UIColor = .black
    var themedBack = false
    let content: (Int) -> AnyView

    var body: some View {
        ZStack {
            Color(nsColor: backColor)
            content(min(max(current, 0), max(count - 1, 0)))
                .id(current)
                .transition(.opacity.combined(with: .scale(scale: 0.985)))
        }
        .clipped()
        .animation(.easeInOut(duration: 0.22), value: current)
    }
}

/// Свои настройки читалки для одного тайтла (как в Mihon). Пока «enabled» выключено, работают общие.
struct MangaTitlePrefs: Codable, Equatable {
    var enabled = false
    var anim = "slide"
    var autoBG = false
    var autoNext = true
    var speed = 60.0
    var dim = 0.0
    var warm = 0.0
    var gray = false
}

struct GrayIf: ViewModifier {
    let on: Bool
    func body(content: Content) -> some View {
        if on { content.saturation(0) } else { content }
    }
}

struct MangaReaderSettings: View {
    @Binding var titleMode: String
    @Binding var defaultMode: String
    @Binding var own: Bool
    @Binding var anim: String
    @Binding var autoBG: Bool
    @Binding var autoNext: Bool
    @Binding var speed: Double
    @Binding var dim: Double
    @Binding var warm: Double
    @Binding var gray: Bool
    let detected: String
    @Environment(\.dismiss) private var dismiss

    // MARK: кирпичики
    private func header(_ icon: String, _ t: String, _ color: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon).font(.system(size: 13, weight: .bold)).foregroundStyle(color)
            Text(t.uppercased()).font(.footnote.weight(.bold)).tracking(0.6).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 6)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 0) { content() }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.footnote).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.vertical, 12)
    }

    /// Плитки с иконкой: выбранная заливается акцентным градиентом.
    private func tiles(_ options: [(String, String, String)], _ sel: Binding<String>) -> some View {
        HStack(spacing: 10) {
            ForEach(options, id: \.0) { o in
                let on = sel.wrappedValue == o.0
                Button {
                    Haptics.select()
                    withAnimation(.easeOut(duration: 0.18)) { sel.wrappedValue = o.0 }
                } label: {
                    VStack(spacing: 8) {
                        Image(systemName: o.2).font(.system(size: 22, weight: .semibold))
                        Text(o.1).font(.system(size: 14, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(on ? Color.white : Color.primary.opacity(0.85))
                    .frame(maxWidth: .infinity, minHeight: 76)
                    .background {
                        if on {
                            RoundedRectangle(cornerRadius: 20, style: .continuous)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                                .shadow(color: Theme.accent.opacity(0.45), radius: 10, y: 4)
                        } else {
                            RoundedRectangle(cornerRadius: 20, style: .continuous).fill(Color.primary.opacity(0.08))
                        }
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 14)
    }

    private func iconBox(_ icon: String, _ color: Color) -> some View {
        Image(systemName: icon)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(color.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func slider(_ icon: String, _ color: Color, _ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, _ fmt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 12) {
                iconBox(icon, color)
                Text(title).font(.system(size: 17))
                Spacer()
                Text(fmt).font(.system(size: 15, weight: .medium).monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: v, in: range).tint(Theme.accent)
        }
        .padding(.vertical, 12)
    }

    private func toggle(_ icon: String, _ color: Color, _ title: String, _ on: Binding<Bool>) -> some View {
        Toggle(isOn: on) {
            HStack(spacing: 12) {
                iconBox(icon, color)
                Text(title).font(.system(size: 17))
            }
        }
        .tint(Theme.accent)
        .frame(minHeight: 54)
    }

    private func str(_ b: Binding<Bool>) -> Binding<String> {
        Binding(get: { b.wrappedValue ? "own" : "all" }, set: { b.wrappedValue = ($0 == "own") })
    }

    /// Выбор режима: для этого тайтла пишет его режим, для всех — ещё и общий по умолчанию (отдельный блок больше не нужен).
    private var modeBinding: Binding<String> {
        Binding(get: { titleMode },
                set: { v in
                    titleMode = v
                    if !own { defaultMode = v }
                })
    }

    // MARK: экран
    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                Text("Настройки читалки").font(.headline)
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 46, height: 46)
                            .glassShape(Circle())
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)

            ScrollView {
                VStack(spacing: 18) {
                    // для кого настройки
                    VStack(spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach([("all", "Для всех"), ("own", "Для этого тайтла")], id: \.0) { o in
                                let on = str($own).wrappedValue == o.0
                                Button {
                                    Haptics.select()
                                    withAnimation(.easeOut(duration: 0.2)) { str($own).wrappedValue = o.0 }
                                } label: {
                                    Text(o.1)
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundStyle(on ? Color.white : Color.primary.opacity(0.8))
                                        .frame(maxWidth: .infinity, minHeight: 42)
                                        .background {
                                            if on {
                                                Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                                            }
                                        }
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(4)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                        Text(own ? "Эти настройки действуют только в этом тайтле, остальные не меняются."
                                 : "Изменения касаются всех тайтлов, у которых нет своих настроек.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 6)
                    }

                    header("rectangle.split.1x2", "Режим чтения", Theme.accent)
                    card {
                        tiles([("auto", "Авто", "wand.and.stars"), ("pages", "Страницы", "book"), ("scroll", "Лента", "arrow.up.and.down.text.horizontal")], modeBinding)
                        Divider()
                        note("«Страницы» для манги: листаешь свайпом. «Лента» для манхвы: прокручиваешь вниз. «Авто»: сейчас выбрано «\(detected)». Режим запоминается для тайтла\(own ? "." : ", а выбранный здесь станет режимом по умолчанию для остальных.")")
                    }

                    header("hand.draw", "Листание", .orange)
                    card {
                        tiles([("slide", "Сдвиг", "arrow.left.and.right"), ("fade", "Плавно", "circle.lefthalf.filled"), ("book", "Как в книге", "book.pages")], $anim)
                        Divider()
                        note("Работает в режиме «Страницы».")
                    }

                    header("play.circle", "Автопрокрутка", .green)
                    card {
                        slider("speedometer", .green, "Скорость", $speed, 15...240, "\(Int(speed))")
                        Divider()
                        toggle("forward.end.fill", .blue, "Сама переходить к следующей главе", $autoNext)
                        Divider()
                        note("Кнопка ▶ внизу в режиме «Лента». Касание ставит прокрутку на паузу.")
                    }

                    header("sun.max", "Экран", .yellow)
                    card {
                        slider("moon.fill", .indigo, "Затемнение", $dim, 0...0.7, "\(Int(dim * 100))%")
                        Divider()
                        slider("flame.fill", .orange, "Тёплый свет", $warm, 0...0.5, "\(Int(warm * 200))%")
                        Divider()
                        toggle("circle.lefthalf.striped.horizontal", .gray, "Чёрно-белый режим", $gray)
                        Divider()
                        toggle("rectangle.inset.filled", .teal, "Фон под страницу", $autoBG)
                        Divider()
                        note("Фон под страницу делает поля вокруг белыми или чёрными, чтобы не было тёмных полос у светлых страниц.")
                    }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 28)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.hidden)
    }
}

/// Список глав внутри читалки: поиск, сортировка, группы по томам, отметки прочитанного, быстрый переход.
struct MangaChapterPicker: View {
    let chapters: [NovelChapter]
    let current: Int
    let readKey: Int
    let onPick: (Int) -> Void
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var read = ReadStore.shared
    @State private var query = ""
    @State private var newestFirst = true

    private var entries: [(i: Int, ch: NovelChapter)] {
        var list = chapters.enumerated().map { (i: $0.offset, ch: $0.element) }
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        if !q.isEmpty {
            list = list.filter { $0.ch.number.lowercased().contains(q) || $0.ch.name.lowercased().contains(q) || "том \($0.ch.volume)".contains(q) }
        }
        return newestFirst ? Array(list.reversed()) : list
    }

    private var groups: [(vol: String, items: [(i: Int, ch: NovelChapter)])] {
        var out: [(vol: String, items: [(i: Int, ch: NovelChapter)])] = []
        for e in entries {
            if let last = out.last, last.vol == e.ch.volume { out[out.count - 1].items.append(e) }
            else { out.append((vol: e.ch.volume, items: [e])) }
        }
        return out
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ru_RU"); f.dateStyle = .medium; return f
    }()

    private func row(_ e: (i: Int, ch: NovelChapter)) -> some View {
        let isCur = e.i == current
        let isRead = read.isRead(readKey, e.ch.id)
        return Button {
            onPick(e.i)
            dismiss()
        } label: {
            HStack(spacing: 14) {
                Text(e.ch.number)
                    .font(.system(size: 15, weight: .bold).monospacedDigit())
                    .minimumScaleFactor(0.6).lineLimit(1)
                    .foregroundStyle(isCur ? Color.white : Color.primary)
                    .frame(width: 52, height: 44)
                    .background {
                        if isCur {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                        } else {
                            RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color.primary.opacity(0.08))
                        }
                    }
                VStack(alignment: .leading, spacing: 3) {
                    Text(e.ch.name.isEmpty ? "Глава \(e.ch.number)" : e.ch.name)
                        .font(.system(size: 16, weight: isCur ? .semibold : .regular))
                        .foregroundStyle(isRead && !isCur ? Color.secondary : Color.primary)
                        .lineLimit(2).multilineTextAlignment(.leading)
                    if let d = e.ch.date {
                        Text(Self.dateFmt.string(from: d)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if isCur {
                    Image(systemName: "book.fill").foregroundStyle(Theme.accent)
                } else if isRead {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.accent.opacity(0.7))
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(isCur ? Theme.accent.opacity(0.14) : Color.clear, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .id(e.i)
    }

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                VStack(spacing: 2) {
                    Text("Главы").font(.headline)
                    Text("\(chapters.count) всего · прочитано \(chapters.filter { read.isRead(readKey, $0.id) }.count)")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.primary).frame(width: 46, height: 46).glassShape(Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            HStack(spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Номер или название", text: $query)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    if !query.isEmpty {
                        Button { query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 14).frame(height: 44)
                .background(Color.primary.opacity(0.08), in: Capsule())
                Button {
                    Haptics.select()
                    newestFirst.toggle()
                } label: {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(.primary)
                        .frame(width: 44, height: 44)
                        .background(Color.primary.opacity(0.08), in: Circle())
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16).padding(.bottom, 8)

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(spacing: 4, pinnedViews: [.sectionHeaders]) {
                        ForEach(groups, id: \.vol) { g in
                            Section {
                                ForEach(g.items, id: \.i) { row($0) }
                            } header: {
                                Text("Том \(g.vol)")
                                    .font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 12).padding(.vertical, 6)
                                    .background(.ultraThinMaterial)
                            }
                        }
                        if groups.isEmpty {
                            Text("Ничего не найдено").foregroundStyle(.secondary).padding(.top, 40)
                        }
                    }
                    .padding(.horizontal, 10).padding(.bottom, 24)
                }
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { proxy.scrollTo(current, anchor: .center) }
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        query = ""
                        withAnimation { proxy.scrollTo(current, anchor: .center) }
                    } label: {
                        Label("К текущей", systemImage: "scope")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 14).padding(.vertical, 10)
                            .glassShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .padding(16)
                }
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .preferredColorScheme(.dark)
        .presentationDetents([.large])
        .presentationDragIndicator(.hidden)
    }
}

extension View {
    /// Стекло в духе iOS: размытие, лёгкая светлая подложка, блик по краю и мягкая тень.
    @ViewBuilder func liquidGlass<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            legacyGlass(shape)
        }
    }

    func legacyGlass<S: Shape>(_ shape: S) -> some View {
        self
            .background(shape.fill(.ultraThinMaterial))
            .background(shape.fill(Color.white.opacity(0.10)))
            .overlay(shape.stroke(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06), .white.opacity(0.25)],
                                                 startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 0.9))
            .shadow(color: .black.opacity(0.4), radius: 14, y: 6)
    }
}

/// Группа стеклянных элементов: на iOS 26 они делят одну область и не «просвечивают» друг сквозь друга.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: () -> Content

    var body: some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { content() }
        } else {
            content()
        }
    }
}

/// Верхняя панель читалки: на iOS 26 системная стеклянная, ниже — размытая.
struct ReaderBarBackground: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content
        } else {
            content
                .toolbarBackground(.ultraThinMaterial, for: .navBar)
                .toolbarBackground(.visible, for: .navBar)
        }
    }
}

/// Мягкое размытие у края экрана под панелями читалки: текст не наезжает на кнопки.
struct EdgeBlur: View {
    let top: Bool
    let height: CGFloat

    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: height)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black.opacity(0.8), location: 0.55),
                .init(color: .clear, location: 1)
            ], startPoint: top ? .top : .bottom, endPoint: top ? .bottom : .top))
            .allowsHitTesting(false)
    }
}

struct SolidSheetBackground: ViewModifier {
    let color: Color
    func body(content: Content) -> some View {
        if #available(iOS 16.4, macOS 13.3, *) {
            content.presentationBackground(color)
        } else {
            content
        }
    }
}

/// Находит NSScrollView, внутри которого лежит SwiftUI-лента.
struct ScrollFinder: UIViewRepresentable {
    let onFound: (NSScrollView) -> Void

    final class Finder: NSView {
        var onFound: (NSScrollView) -> Void = { _ in }
        private weak var last: NSScrollView?

        private func find() {
            var p: NSView? = superview
            while let x = p {
                if let sv = x as? NSScrollView {
                    if sv !== last { last = sv; onFound(sv) }
                    return
                }
                p = x.superview
            }
            if let sv = enclosingScrollView, sv !== last { last = sv; onFound(sv) }
        }

        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); find() }
        override func layout() { super.layout(); find() }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    func makeUIView(context: Context) -> Finder {
        let v = Finder()
        v.onFound = onFound
        return v
    }

    func updateUIView(_ v: Finder, context: Context) {
        v.onFound = onFound
    }
}

/// Плавная прокрутка ленты по таймеру. Ждёт, если следующие страницы ещё не загрузились.
@MainActor
final class AutoScroller {
    weak var scrollView: NSScrollView? {
        didSet {
            if scrollView !== oldValue { atEnd = false; pos = scrollView?.contentView.bounds.origin.y ?? 0 }
        }
    }
    var speed: CGFloat = 60
    var canAdvance: () -> Bool = { true }
    /// Возвращает true, если конец главы обработан; иначе проверка повторится.
    var onEnd: () -> Bool = { true }
    var onBlocked: (Bool) -> Void = { _ in }
    private var blocked = false
    private var timer: Timer?
    private var last: CFTimeInterval = 0
    private var blockedSince: CFTimeInterval = 0
    private var atEnd = false
    private var pos: CGFloat = 0

    func start() {
        guard timer == nil else { return }
        atEnd = false
        last = 0
        blockedSince = 0
        pos = scrollView?.contentView.bounds.origin.y ?? 0
        let t = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Читалка закрыта: отпускаем замыкания, которые держат её экран.
    func detach() {
        canAdvance = { false }
        onEnd = { true }
        onBlocked = { _ in }
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let dt = last == 0 ? 0 : min(now - last, 0.1)
        last = now
        guard dt > 0, let sv = scrollView, let doc = sv.documentView else { return }
        let clip = sv.contentView
        let viewport = clip.bounds.height
        let total = doc.frame.height
        if canAdvance() {
            blockedSince = 0
            if blocked { blocked = false; onBlocked(false) }
        } else {
            if blockedSince == 0 { blockedSince = now }
            if !blocked { blocked = true; onBlocked(true) }
            if now - blockedSince < 3 { return }
        }
        let maxY = total - viewport
        let cur = clip.bounds.origin.y
        if total > viewport, cur >= maxY - 1 {
            if !atEnd, onEnd() { atEnd = true }
            return
        }
        atEnd = false
        // Если пользователь сам прокрутил, продолжаем с его места.
        if abs(cur - pos) > 3 { pos = cur }
        pos = min(pos + speed * CGFloat(dt), max(maxY, 0))
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: pos))
        sv.reflectScrolledClipView(clip)
    }
}
