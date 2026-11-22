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

// MARK: - Тема и общие элементы дизайна

enum Theme {
    static let defaultAccentHex = "A87AFF"
    /// Акцентный цвет берётся из настроек и меняется на лету.
    private static var cachedHex = ""
    private static var cachedColor = Color(hex: defaultAccentHex)
    private static var cachedSecondary = Color(hex: defaultAccentHex)
    private static var dirty = true
    private static let observer: NSObjectProtocol = NotificationCenter.default.addObserver(
        forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { _ in Theme.dirty = true }

    /// Второй цвет фона: тот же акцент, сдвинутый по оттенку. Меняется вместе с акцентом.
    private static func shifted(_ hex: String) -> Color {
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(Color(hex: hex)).getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        let nh = (h + 0.07).truncatingRemainder(dividingBy: 1)
        return Color(hue: Double(nh), saturation: Double(s), brightness: Double(b))
    }

    private static func refresh() {
        _ = observer
        guard dirty else { return }
        dirty = false
        let hex = UserDefaults.standard.string(forKey: "accent.hex") ?? defaultAccentHex
        if hex != cachedHex {
            cachedHex = hex
            cachedColor = Color(hex: hex)
            cachedSecondary = shifted(hex)
            rebuildPalette(UIColor(Color(hex: hex)))
        }
    }

    /// Смешивает два цвета: t = доля второго.
    static func mix(_ a: UIColor, _ b: UIColor, _ t: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        a.getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
        b.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        return UIColor(red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t, alpha: 1)
    }

    private static var cachedBase = Color(uiColor: .systemBackground)
    private static var cachedCard = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.08) : UIColor(white: 0, alpha: 0.06) })
    private static var cachedChip = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark
        ? UIColor(white: 1, alpha: 0.10) : UIColor(white: 0, alpha: 0.08) })
    /// «Серый с оттенком акцента» — для неактивных иконок и подписей
    private(set) static var mutedUI: UIColor = .secondaryLabel

    /// Палитра из акцента: светлый фон — белый с 5% акцента, тёмный — почти чёрный с оттенком акцента,
    /// плашки и чипы в светлой теме — с лёгким оттенком акцента вместо серого.
    private static func rebuildPalette(_ acc: UIColor) {
        let lightBase = mix(.white, acc, 0.05)
        let darkBase = mix(UIColor(red: 0.04, green: 0.035, blue: 0.06, alpha: 1), acc, 0.07)
        cachedBase = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? darkBase : lightBase })
        let lightCard = acc.withAlphaComponent(0.07)
        cachedCard = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.08) : lightCard })
        let lightChip = acc.withAlphaComponent(0.11)
        cachedChip = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.10) : lightChip })
        let lightMuted = mix(UIColor(white: 0.45, alpha: 1), acc, 0.25)
        mutedUI = UIColor { $0.userInterfaceStyle == .dark ? UIColor(white: 1, alpha: 0.55) : lightMuted }
    }

    static var accent2: Color { refresh(); return cachedSecondary }

    /// Цвета, которые сами подстраиваются под светлую и тёмную тему.
    static var card: Color { refresh(); return cachedCard }
    static var chip: Color { refresh(); return cachedChip }
    static var base: Color { refresh(); return cachedBase }
    static var muted: Color { refresh(); return Color(uiColor: mutedUI) }

    static var accent: Color { refresh(); return cachedColor }
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
    var isManga: Bool { key == "manga" || key == "hentai" }
    var isHentai: Bool { key == "hentai" }
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

    static let hentai = LibSite(key: "hentai", id: "4", referer: "https://kz.hentailib.me/",
                                origin: "https://kz.hentailib.me", apiPath: "/manga",
                                postType: "manga", title: "Хентай")

    static var current: LibSite {
        switch UserDefaults.standard.string(forKey: "set.platform") {
        case "ranobe": return .ranobe
        case "manga": return .manga
        case "hentai": return .hentai
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
            // светлая: белый с 5% акцента; тёмная: почти чёрный с оттенком акцента (не чистый чёрный)
            Theme.base
            // мягкое пятно акцента слева сверху
            RadialGradient(colors: [Theme.accent.opacity(dark ? 0.32 : 0.16), .clear],
                           center: UnitPoint(x: 0.05, y: 0.0), startRadius: 10, endRadius: 380)
            // соседний оттенок справа
            RadialGradient(colors: [Theme.accent2.opacity(dark ? 0.22 : 0.13), .clear],
                           center: UnitPoint(x: 1.0, y: 0.18), startRadius: 10, endRadius: 340)
            // слабое свечение у таб-бара, чтобы стеклу было что преломлять
            RadialGradient(colors: [Theme.accent.opacity(dark ? 0.16 : 0.07), .clear],
                           center: UnitPoint(x: 0.5, y: 1.02), startRadius: 10, endRadius: 300)
            // зерно 2–3%: убирает полосы на плавных переходах
            Image(uiImage: Grain.tile)
                .resizable(resizingMode: .tile)
                .opacity(dark ? 0.10 : 0.08)
                .blendMode(.softLight)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// Маленькая текстура шума, генерируется один раз.
enum Grain {
    static let tile: UIImage = {
        let n = 96
        var px = [UInt8](repeating: 0, count: n * n * 4)
        var seed: UInt32 = 0x9E3779B9
        for i in 0..<(n * n) {
            seed = seed &* 1664525 &+ 1013904223
            let v = UInt8(truncatingIfNeeded: seed >> 24)
            px[i * 4] = v; px[i * 4 + 1] = v; px[i * 4 + 2] = v; px[i * 4 + 3] = 255
        }
        guard let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let cg = ctx.makeImage() else { return UIImage() }
        return UIImage(cgImage: cg, scale: 2, orientation: .up)
    }()
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

// MARK: - Страница тайтла: общие детали оформления
struct GlassPill: View {
    let icon: String
    let text: String
    var tint: Color? = nil
    var body: some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(tint ?? Color.primary)
            .padding(.horizontal, 11).padding(.vertical, 6)
            .glassCapsule()
    }
}

struct TitleHero: View {
    let cover: URL?
    let title: String
    let subtitle: String?
    let pills: [(String, String)]
    var body: some View {
        VStack(spacing: 14) {
            RemoteImage(url: cover, maxPixel: 700)
                .frame(width: 172, height: 258)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.7))
                .shadow(color: .black.opacity(0.45), radius: 22, y: 12)
            VStack(spacing: 5) {
                Text(title)
                    .font(.title2.weight(.bold))
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
            .padding(.horizontal, 8)
            if !pills.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(Array(pills.enumerated()), id: \.offset) { _, p in
                            GlassPill(icon: p.0, text: p.1, tint: p.0 == "star.fill" ? .yellow : nil)
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.horizontal, -16)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }
}

struct PrimaryActionButton: View {
    let icon: String
    let title: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.headline)
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing),
                        in: Capsule())
            .shadow(color: Theme.accent.opacity(0.45), radius: 14, y: 6)
        }
        .buttonStyle(.pressable)
    }
}

struct GenreStrip: View {
    let genres: [NamedItem]
    var tags: [NamedItem] = []
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(Array(genres.enumerated()), id: \.offset) { _, g in
                    Button {
                        guard let id = g.id else { return }
                        Haptics.tap()
                        AppRouter.shared.openCatalog(genre: id)
                    } label: {
                        Text(g.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.accent.opacity(0.2), in: Capsule())
                            .overlay(Capsule().stroke(Theme.accent.opacity(0.35), lineWidth: 0.6))
                    }
                    .buttonStyle(.pressable)
                }
                ForEach(Array(tags.enumerated()), id: \.offset) { _, t in
                    Button {
                        guard let id = t.id else { return }
                        Haptics.tap()
                        AppRouter.shared.openCatalog(tag: id)
                    } label: {
                        Text("#" + t.title)
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 12).padding(.vertical, 7)
                            .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.horizontal, -16)
    }
}

struct SummaryCard: View {
    let text: String
    @Binding var expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).font(.callout).lineSpacing(3).lineLimit(expanded ? nil : 5)
            if text.count > 220 {
                Button(expanded ? "Свернуть" : "Читать полностью") {
                    withAnimation(.easeInOut(duration: 0.25)) { expanded.toggle() }
                }
                .font(.footnote.weight(.bold))
                .foregroundStyle(Theme.accent)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
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
