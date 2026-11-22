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

// MARK: - Своя шапка и аватарка профиля (видны только в этом приложении)

/// Своя картинка, GIF или короткое видео для шапки/аватарки + положение кадра.
struct ProfileMedia: Codable, Equatable {
    var file: String
    /// "image", "gif" или "video"
    var kind: String
    /// Пропорции самого файла: ширина / высота
    var aspect: Double
    var scale: Double = 1
    var x: Double = 0
    var y: Double = 0

    var isVideo: Bool { kind == "video" }
}

@MainActor
final class ProfileLook: ObservableObject {
    static let shared = ProfileLook()

    @Published private(set) var header: ProfileMedia?
    @Published private(set) var avatar: ProfileMedia?
    /// Показывать свою шапку/аватарку (иначе — с сайта)
    @Published var useHeader: Bool { didSet { UserDefaults.standard.set(useHeader, forKey: "profile.header.on") } }
    @Published var useAvatar: Bool { didSet { UserDefaults.standard.set(useAvatar, forKey: "profile.avatar.on") } }

    private init() {
        useHeader = UserDefaults.standard.bool(forKey: "profile.header.on")
        useAvatar = UserDefaults.standard.bool(forKey: "profile.avatar.on")
        header = Self.read("profile.header")
        avatar = Self.read("profile.avatar")
    }

    nonisolated static var dir: URL {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ProfileLook", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated static func url(_ m: ProfileMedia) -> URL { dir.appendingPathComponent(m.file) }

    nonisolated static func read(_ key: String) -> ProfileMedia? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ProfileMedia.self, from: d)
    }

    private static func write(_ m: ProfileMedia?, _ key: String) {
        if let m, let d = try? JSONEncoder().encode(m) { UserDefaults.standard.set(d, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }

    private func exists(_ m: ProfileMedia?) -> ProfileMedia? {
        guard let m, FileManager.default.fileExists(atPath: Self.url(m).path) else { return nil }
        return m
    }

    /// То, что реально показывать (nil — брать с сайта)
    var activeHeader: ProfileMedia? { useHeader ? exists(header) : nil }
    var activeAvatar: ProfileMedia? { useAvatar ? exists(avatar) : nil }

    func setHeader(_ m: ProfileMedia?) {
        if let old = header, old.file != m?.file { try? FileManager.default.removeItem(at: Self.url(old)) }
        header = m
        Self.write(m, "profile.header")
        useHeader = m != nil
    }

    func setAvatar(_ m: ProfileMedia?) {
        if let old = avatar, old.file != m?.file { try? FileManager.default.removeItem(at: Self.url(old)) }
        avatar = m
        Self.write(m, "profile.avatar")
        useAvatar = m != nil
    }

    /// Только кадр (масштаб/сдвиг) без смены файла
    func updateCrop(header m: ProfileMedia) { header = m; Self.write(m, "profile.header") }
    func updateCrop(avatar m: ProfileMedia) { avatar = m; Self.write(m, "profile.avatar") }

    /// Файлы для резервной копии: фото и GIF (видео — слишком большие).
    nonisolated static func backupFiles() -> [String: Data] {
        var out: [String: Data] = [:]
        for key in ["profile.header", "profile.avatar"] {
            guard let m = read(key), !m.isVideo,
                  let d = try? Data(contentsOf: url(m)), d.count < 12_000_000 else { continue }
            out[m.file] = d
        }
        return out
    }

    nonisolated static func restoreFiles(_ files: [String: Data]) {
        for (name, d) in files where !name.contains("/") {
            try? d.write(to: dir.appendingPathComponent(name), options: .atomic)
        }
    }
}

/// Видео из галереи (копируется во временную папку).
struct PickedMovie: Transferable {
    let url: URL
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { SentTransferredFile($0.url) } importing: { f in
            let ext = f.file.pathExtension.isEmpty ? "mov" : f.file.pathExtension
            let dst = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "." + ext)
            try FileManager.default.copyItem(at: f.file, to: dst)
            return PickedMovie(url: dst)
        }
    }
}

enum ProfileMediaImporter {
    enum Failure: LocalizedError {
        case unreadable, tooBig, noVideo, export(String)
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Не получилось прочитать файл"
            case .tooBig: return "Файл слишком большой (GIF — до 20 МБ)"
            case .noVideo: return "В видео нет картинки"
            case .export(let s): return "Не получилось подготовить видео: \(s)"
            }
        }
    }

    private static func name(_ prefix: String, _ ext: String) -> String {
        "\(prefix)-\(Int(Date().timeIntervalSince1970 * 1000)).\(ext)"
    }

    /// Фото уменьшается до разумного размера; GIF и другие анимации сохраняются как есть, чтобы двигались.
    static func importImage(_ data: Data, prefix: String, maxPixel: CGFloat) async throws -> ProfileMedia {
        try await Task.detached(priority: .userInitiated) { () throws -> ProfileMedia in
            guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { throw Failure.unreadable }
            let frames = CGImageSourceGetCount(src)
            let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any]
            var w = (props?[kCGImagePropertyPixelWidth] as? Double) ?? 1
            var h = (props?[kCGImagePropertyPixelHeight] as? Double) ?? 1
            if let o = props?[kCGImagePropertyOrientation] as? Int, (5...8).contains(o) { swap(&w, &h) }
            if frames > 1 {
                guard data.count < 20_000_000 else { throw Failure.tooBig }
                let n = name(prefix, "gif")
                try data.write(to: ProfileLook.dir.appendingPathComponent(n), options: .atomic)
                return ProfileMedia(file: n, kind: "gif", aspect: w / max(h, 1))
            }
            guard let img = ImageLoader.downsample(data, maxPixel: maxPixel),
                  let jpg = img.jpegData(compressionQuality: 0.9) else { throw Failure.unreadable }
            let n = name(prefix, "jpg")
            try jpg.write(to: ProfileLook.dir.appendingPathComponent(n), options: .atomic)
            return ProfileMedia(file: n, kind: "image", aspect: img.size.width / max(img.size.height, 1))
        }.value
    }

    /// Видео: первые 15 секунд, без звука (чтобы не перебивать музыку), до Full HD.
    static func importVideo(_ src: URL, prefix: String) async throws -> ProfileMedia {
        defer { try? FileManager.default.removeItem(at: src) }
        let asset = AVURLAsset(url: src)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else { throw Failure.noVideo }
        let (natural, transform) = try await track.load(.naturalSize, .preferredTransform)
        let shown = natural.applying(transform)
        let aspect = abs(shown.width) / max(abs(shown.height), 1)
        let duration = try await asset.load(.duration)
        let length = CMTimeMinimum(duration, CMTime(seconds: 15, preferredTimescale: 600))

        let comp = AVMutableComposition()
        guard let vt = comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            throw Failure.export("дорожка")
        }
        try vt.insertTimeRange(CMTimeRange(start: .zero, duration: length), of: track, at: .zero)
        vt.preferredTransform = transform

        guard let ex = AVAssetExportSession(asset: comp, presetName: AVAssetExportPreset1920x1080) else {
            throw Failure.export("кодировщик")
        }
        let n = name(prefix, "mp4")
        let out = ProfileLook.dir.appendingPathComponent(n)
        ex.outputURL = out
        ex.outputFileType = .mp4
        ex.shouldOptimizeForNetworkUse = true
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            ex.exportAsynchronously { c.resume() }
        }
        guard ex.status == .completed else { throw Failure.export(ex.error?.localizedDescription ?? "ошибка") }
        return ProfileMedia(file: n, kind: "video", aspect: Double(aspect))
    }

    /// Не даёт сдвинуть кадр так, чтобы появились пустые края.
    static func clamp(_ m: inout ProfileMedia, frame: CGSize) {
        let W = max(frame.width, 1), H = max(frame.height, 1)
        m.scale = min(max(m.scale, 1), 4)
        let a = max(m.aspect, 0.05)
        let base = a > Double(W / H) ? CGSize(width: H * a, height: H) : CGSize(width: W, height: W / a)
        let mx = max(0, (base.width * m.scale - W) / 2 / W)
        let my = max(0, (base.height * m.scale - H) / 2 / H)
        m.x = min(max(m.x, -mx), mx)
        m.y = min(max(m.y, -my), my)
    }
}

/// Показывает свою картинку/GIF/видео с учётом кадра; заполняет весь отведённый прямоугольник.
struct ProfileMediaView: View {
    let media: ProfileMedia
    var maxPixel: CGFloat = 1600

    var body: some View {
        GeometryReader { g in
            let W = max(g.size.width, 1), H = max(g.size.height, 1)
            let a = max(media.aspect, 0.05)
            let base = a > Double(W / H) ? CGSize(width: H * a, height: H) : CGSize(width: W, height: W / a)
            content
                .frame(width: base.width * media.scale, height: base.height * media.scale)
                .offset(x: media.x * W, y: media.y * H)
                .frame(width: W, height: H)
        }
        .clipped()
    }

    @ViewBuilder private var content: some View {
        let u = ProfileLook.url(media)
        if media.isVideo {
            LoopingVideoView(url: u)
        } else {
            AnimatedRemoteImage(url: u, maxPixel: maxPixel)
        }
    }
}

/// Беззвучное видео по кругу (для шапки профиля).
struct LoopingVideoView: UIViewRepresentable {
    let url: URL

    final class PlayerView: NSView {
        let playerLayer = AVPlayerLayer()
        override init(frame: NSRect) {
            super.init(frame: frame)
            wantsLayer = true
            layer?.addSublayer(playerLayer)
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func layout() {
            super.layout()
            playerLayer.frame = bounds
        }
        var looper: AVPlayerLooper?
        var player: AVQueuePlayer?
        var current: URL?

        func play(_ u: URL) {
            guard current != u else { return }
            current = u
            player?.pause()
            let p = AVQueuePlayer()
            p.isMuted = true
            p.preventsDisplaySleepDuringVideoPlayback = false
            looper = AVPlayerLooper(player: p, templateItem: AVPlayerItem(url: u))
            playerLayer.player = p
            playerLayer.videoGravity = .resizeAspectFill
            player = p
            p.play()
        }
    }

    func makeUIView(context: Context) -> PlayerView {
        let v = PlayerView(frame: .zero)
        v.play(url)
        return v
    }

    func updateUIView(_ v: PlayerView, context: Context) { v.play(url) }

    static func dismantleUIView(_ v: PlayerView, coordinator: ()) {
        v.player?.pause()
        v.looper = nil
        v.player = nil
    }
}

/// Кадрирование: двигай и увеличивай пальцами, как будет в шапке или аватарке.
struct MediaCropEditor: View {
    let title: String
    let aspect: CGFloat
    let rounded: Bool
    @State var media: ProfileMedia
    let onSave: (ProfileMedia) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var start: ProfileMedia?

    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                Spacer(minLength: 0)
                GeometryReader { g in
                    ProfileMediaView(media: media, maxPixel: 1800)
                        .clipShape(RoundedRectangle(cornerRadius: rounded ? 40 : 20, style: .continuous))
                        .overlay(RoundedRectangle(cornerRadius: rounded ? 40 : 20, style: .continuous)
                            .stroke(Color.white.opacity(0.5), lineWidth: 1))
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture()
                                .onChanged { v in
                                    let s = start ?? media
                                    if start == nil { start = media }
                                    var m = media
                                    m.x = s.x + v.translation.width / g.size.width
                                    m.y = s.y + v.translation.height / g.size.height
                                    ProfileMediaImporter.clamp(&m, frame: g.size)
                                    media = m
                                }
                                .onEnded { _ in start = nil }
                                .simultaneously(with:
                                    MagnificationGesture()
                                        .onChanged { k in
                                            let s = start ?? media
                                            if start == nil { start = media }
                                            var m = media
                                            m.scale = s.scale * k
                                            ProfileMediaImporter.clamp(&m, frame: g.size)
                                            media = m
                                        }
                                        .onEnded { _ in start = nil }
                                )
                        )
                }
                .aspectRatio(aspect, contentMode: .fit)
                .padding(.horizontal, rounded ? 60 : 16)
                Text("Двигай и увеличивай двумя пальцами")
                    .font(.footnote).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            .background(Color.black.ignoresSafeArea())
            .preferredColorScheme(.dark)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Готово") { onSave(media); dismiss() }.fontWeight(.semibold)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Сбросить") {
                        withAnimation(.easeOut(duration: 0.2)) { media.scale = 1; media.x = 0; media.y = 0 }
                    }
                }
            }
        }
    }
}

/// Настройки → Шапка и аватарка профиля.
struct ProfileAppearanceView: View {
    @ObservedObject private var look = ProfileLook.shared
    @ObservedObject private var auth = AuthStore.shared
    @State private var headerItem: PhotosPickerItem?
    @State private var avatarItem: PhotosPickerItem?
    @State private var busy: String?
    @State private var error: String?
    @State private var editHeader: ProfileMedia?
    @State private var editAvatar: ProfileMedia?

    private func card<C: View>(_ title: String, footer: String? = nil, @ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase)
                .padding(.horizontal, 18)
            VStack(alignment: .leading, spacing: 0) { c() }
                .padding(.horizontal, 16).padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            if let footer {
                Text(footer).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func row(_ icon: String, _ title: String, tint: Color = .primary) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).foregroundStyle(tint == .primary ? Theme.accent : tint).frame(width: 26)
            Text(title).foregroundStyle(tint)
            Spacer()
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
    }

    private func source(_ on: Binding<Bool>, hasOwn: Bool) -> some View {
        Picker("", selection: Binding(get: { on.wrappedValue && hasOwn }, set: { on.wrappedValue = $0 })) {
            Text("С сайта").tag(false)
            Text("Своя").tag(true)
        }
        .pickerStyle(.segmented)
        .disabled(!hasOwn)
        .padding(.vertical, 10)
    }

    /// Мини-превью: шапка 4:3 и аватарка поверх
    private var preview: some View {
        VStack(spacing: 0) {
            Group {
                if let h = look.activeHeader {
                    ProfileMediaView(media: h, maxPixel: 900)
                } else if let c = auth.user?.cover {
                    AnimatedRemoteImage(url: c, maxPixel: 900)
                } else {
                    LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.accent2.opacity(0.35)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                }
            }
            .aspectRatio(4 / 3, contentMode: .fit)
            .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.7),
                                         .init(color: .black.opacity(0), location: 1)],
                                 startPoint: .top, endPoint: .bottom))
            Group {
                if let a = look.activeAvatar {
                    ProfileMediaView(media: a, maxPixel: 400)
                } else {
                    AnimatedRemoteImage(url: auth.user?.avatar, maxPixel: 300)
                }
            }
            .frame(width: 76, height: 76)
            .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Theme.accent, lineWidth: 2.5))
            .padding(.top, -44)
            Text(auth.user?.username ?? "Профиль").font(.headline).padding(.top, 8).padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity)
        .background(Theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                preview

                if let busy {
                    HStack(spacing: 10) { ProgressView(); Text(busy).font(.subheadline) }
                }
                if let error {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }

                card("Шапка профиля", footer: "Фото, GIF или видео. Видео — первые 15 секунд, без звука, крутится по кругу.") {
                    source($look.useHeader, hasOwn: look.header != nil)
                    Divider()
                    let headerTitle = look.header == nil ? "Выбрать из галереи" : "Заменить"
                    PhotosPicker(selection: $headerItem, matching: .any(of: [.images, .videos])) {
                        row("photo.on.rectangle.angled", headerTitle)
                    }
                    if let h = look.header {
                        Divider()
                        Button { editHeader = h } label: { row("crop", "Настроить кадр") }
                        Divider()
                        Button { look.setHeader(nil) } label: { row("trash", "Удалить свою шапку", tint: .red) }
                    }
                }

                card("Аватарка", footer: "Фото или GIF — GIF останется анимированной.") {
                    source($look.useAvatar, hasOwn: look.avatar != nil)
                    Divider()
                    let avatarTitle = look.avatar == nil ? "Выбрать из галереи" : "Заменить"
                    PhotosPicker(selection: $avatarItem, matching: .images) {
                        row("person.crop.square", avatarTitle)
                    }
                    if let a = look.avatar {
                        Divider()
                        Button { editAvatar = a } label: { row("crop", "Настроить кадр") }
                        Divider()
                        Button { look.setAvatar(nil) } label: { row("trash", "Удалить свою аватарку", tint: .red) }
                    }
                }

                Text("Всё это видно только тебе в этом приложении — на сайте и у друзей ничего не меняется. В резервную копию попадают фото и GIF, видео — нет.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 18)
            }
            .padding(16)
        }
        .background(AppBackground())
        .navigationTitle("Шапка и аватарка")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: headerItem) { _, item in
            guard let item else { return }
            Task { await importItem(item, header: true) }
        }
        .onChange(of: avatarItem) { _, item in
            guard let item else { return }
            Task { await importItem(item, header: false) }
        }
        .macSheet(item: Binding(get: { editHeader.map { CropTarget(media: $0, header: true) } ?? editAvatar.map { CropTarget(media: $0, header: false) } },
                             set: { if $0 == nil { editHeader = nil; editAvatar = nil } })) { t in
            MediaCropEditor(title: t.header ? "Кадр шапки" : "Кадр аватарки",
                            aspect: t.header ? 4 / 3 : 1, rounded: !t.header, media: t.media) { m in
                if t.header { look.updateCrop(header: m) } else { look.updateCrop(avatar: m) }
            }
        }
    }

    private struct CropTarget: Identifiable {
        let media: ProfileMedia
        let header: Bool
        var id: String { media.file }
    }

    private func importItem(_ item: PhotosPickerItem, header: Bool) async {
        error = nil
        busy = header ? "Готовлю шапку…" : "Готовлю аватарку…"
        defer {
            busy = nil
            if header { headerItem = nil } else { avatarItem = nil }
        }
        do {
            let m: ProfileMedia
            if header, item.supportedContentTypes.contains(where: { $0.conforms(to: .movie) }) {
                guard let mv = try await item.loadTransferable(type: PickedMovie.self) else {
                    throw ProfileMediaImporter.Failure.unreadable
                }
                m = try await ProfileMediaImporter.importVideo(mv.url, prefix: "header")
            } else {
                guard let d = try await item.loadTransferable(type: Data.self) else {
                    throw ProfileMediaImporter.Failure.unreadable
                }
                m = try await ProfileMediaImporter.importImage(d, prefix: header ? "header" : "avatar",
                                                               maxPixel: header ? 2400 : 900)
            }
            if header {
                look.setHeader(m)
                editHeader = m
            } else {
                look.setAvatar(m)
                editAvatar = m
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}

/// Иконка своего цвета, текст — обычного
struct TintedIconLabel: LabelStyle {
    let tint: Color
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 5) {
            configuration.icon.foregroundStyle(tint)
            configuration.title
        }
    }
}

/// Аватарка или обложка на весь экран (GIF остаётся анимированным). Нажатие или свайп закрывают.
/// Баннер профиля в родных пропорциях: во всю ширину, высота по картинке — без растягивания и мыла.
struct ProfileBanner: View {
    let url: URL
    var ratio: Binding<CGFloat?>? = nil
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                // очень «высокие» картинки ограничиваем, чтобы шапка не занимала полэкрана
                let ratio = max(image.size.width / max(image.size.height, 1), 1.6)
                AnimatedImageView(image: image)
                    .aspectRatio(ratio, contentMode: .fit)
                    .frame(maxWidth: .infinity)
                    .transition(.opacity)
            } else {
                Color.clear.frame(height: 120)
            }
        }
        .task(id: url) {
            if let c = AnimatedLoader.cached(url, 2400) {
                image = c
                ratio?.wrappedValue = c.size.width / max(c.size.height, 1)
                return
            }
            if let img = await AnimatedLoader.load(url, maxPixel: 2400, referer: LibSite.current.referer) {
                withAnimation(.easeOut(duration: 0.25)) {
                    image = img
                    ratio?.wrappedValue = img.size.width / max(img.size.height, 1)
                }
            }
        }
    }
}

struct ProfileImageViewer: View {
    struct Item: Identifiable { let url: URL; var id: String { url.absoluteString } }
    let item: Item
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AnimatedRemoteImage(url: item.url, maxPixel: 1600, fit: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .contentShape(Rectangle())
        .onTapGesture { dismiss() }
        .gesture(DragGesture(minimumDistance: 30).onEnded { if abs($0.translation.height) > 80 { dismiss() } })
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                    .frame(width: 44, height: 44).glassShape(Circle())
            }
            .padding(16)
        }
    }
}

/// Свой цвет или эмодзи для списков в профиле (только в приложении; попадает в резервную копию).
@MainActor
final class FolderStyles: ObservableObject {
    static let shared = FolderStyles()
    struct Style: Codable, Equatable {
        var hex: String?
        var emoji: String?
        var color: Color? { hex.map { Color(hex: $0) } }
    }
    @Published private var items: [Int: Style] = [:]
    private let key = "profile.folderStyles"

    private init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([Int: Style].self, from: d) { items = v }
    }

    func style(_ id: Int) -> Style? { items[id] }

    func set(_ id: Int, _ s: Style?) {
        items[id] = (s?.hex == nil && (s?.emoji ?? "").isEmpty) ? nil : s
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct FolderStyleSheet: View {
    let folder: BookmarkFolder
    @ObservedObject private var styles = FolderStyles.shared
    @Environment(\.dismiss) private var dismiss
    private let colors = ["#A78BFA", "#F472B6", "#FB7185", "#F59E0B", "#FACC15", "#34D399", "#2DD4BF", "#38BDF8", "#60A5FA", "#94A3B8"]
    private let emojis = ["⭐️", "🔥", "💜", "❤️", "🌸", "🎮", "⚔️", "🗡️", "🐉", "👑", "😂", "😭", "🥀", "🌙", "☀️", "🍜", "📚", "🎧", "💤", "✨", "🧩", "🏆", "💀", "👻"]

    var body: some View {
        let cur = styles.style(folder.id) ?? FolderStyles.Style()
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Цвет").font(.headline)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
                        ForEach(colors, id: \.self) { h in
                            Button {
                                Haptics.select()
                                var s = cur; s.hex = (cur.hex == h ? nil : h); styles.set(folder.id, s)
                            } label: {
                                Circle().fill(Color(hex: h))
                                    .frame(height: 44)
                                    .overlay(Circle().stroke(Color.primary, lineWidth: cur.hex == h ? 3 : 0).padding(-4))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Text("Эмодзи вместо значка").font(.headline).padding(.top, 6)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 6), spacing: 8) {
                        ForEach(emojis, id: \.self) { e in
                            Button {
                                Haptics.select()
                                var s = cur; s.emoji = (cur.emoji == e ? nil : e); styles.set(folder.id, s)
                            } label: {
                                Text(e).font(.system(size: 28))
                                    .frame(maxWidth: .infinity, minHeight: 50)
                                    .background(cur.emoji == e ? Theme.accent.opacity(0.25) : Theme.card,
                                                in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    Button(role: .destructive) { styles.set(folder.id, nil) } label: {
                        Text("Сбросить").frame(maxWidth: .infinity).padding(.vertical, 12)
                    }
                    .padding(.top, 8)
                }
                .padding(20)
            }
            .navigationTitle(folder.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } } }
        }
        .presentationDetents([.medium, .large])
    }
}
