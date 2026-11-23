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

// MARK: - Главная
@MainActor
final class HomeViewModel: ObservableObject {
    @Published var fresh: [Anime] = []
    @Published var popular: [Anime] = []
    @Published var newest: [Anime] = []
    @Published var top: [Anime] = []
    @Published var isLoading = false
    @Published var loadingMore = false
    @Published var error: String?
    private var popularPage = 1
    private var popularHasNext = true

    var canLoadMorePopular: Bool { popularHasNext && !popular.isEmpty }

    private func fetch(_ sort: CatalogFilter.SortOption, page: Int = 1) async -> (items: [Anime], hasNext: Bool)? {
        var f = CatalogFilter()
        f.sortBy = sort
        if sort == .rating {
            // «Лучшее» меняется редко: сутки берём из памяти телефона, а обновляем в фоне
            let key = "home.top.\(LibSite.current.key)"
            if page == 1, let d = UserDefaults.standard.object(forKey: key + ".at") as? Date,
               Date().timeIntervalSince(d) < 86400,
               let data = UserDefaults.standard.data(forKey: key),
               let list = try? JSONDecoder().decode([Anime].self, from: data), !list.isEmpty {
                return (list, true)
            }
            guard let r = try? await RequestGate.inBackground({
                try await AnimelibAPI.shared.catalogRated(filter: f, startPage: page)
            }) else { return nil }
            if page == 1, !r.items.isEmpty, let data = try? JSONEncoder().encode(r.items) {
                UserDefaults.standard.set(data, forKey: key)
                UserDefaults.standard.set(Date(), forKey: key + ".at")
            }
            return (r.items, r.hasNext)
        }
        return try? await AnimelibAPI.shared.catalog(filter: f, page: page)
    }

    func load(force: Bool = false) async {
        guard !isLoading else { return }
        if !force && !fresh.isEmpty { return }
        isLoading = true
        defer { isLoading = false }
        func uniq(_ l: [Anime]) -> [Anime] { var seen = Set<Int>(); return l.filter { seen.insert($0.id).inserted } }
        // Каждая лента показывается, как только пришла: «Лучшее по рейтингу» перебирает много страниц
        // и раньше задерживало весь экран.
        enum Part { case fresh, popular, newest, top }
        var gotAny = false
        await withTaskGroup(of: (Part, (items: [Anime], hasNext: Bool)?).self) { group in
            group.addTask { (.fresh, await self.fetch(.lastEpisode)) }
            group.addTask { (.popular, await self.fetch(.views)) }
            group.addTask { (.newest, await self.fetch(.newest)) }
            group.addTask { (.top, await self.fetch(.rating)) }
            for await (part, res) in group {
                guard let r = res else { continue }
                gotAny = true
                let list = uniq(r.items)
                switch part {
                case .fresh: fresh = list
                case .popular: popular = list; popularPage = 1; popularHasNext = r.hasNext
                case .newest: newest = list
                case .top: top = list
                }
                // Обложки тех же размеров, что берут карточки, иначе подгрузка уходит впустую.
                switch part {
                case .fresh:
                    ImageLoader.prefetch(list.prefix(14).compactMap { $0.imageURL }, maxPixel: 480)
                case .newest:
                    ImageLoader.prefetch(list.prefix(10).compactMap { $0.posterURL ?? $0.imageURL }, maxPixel: 420)
                case .popular:
                    ImageLoader.prefetch(list.prefix(1).compactMap { $0.posterURL }, maxPixel: 720)
                    ImageLoader.prefetch(list.dropFirst().prefix(14).compactMap { $0.posterURL }, maxPixel: AnimeRow.thumbPixels)
                case .top:
                    ImageLoader.prefetch(list.prefix(10).compactMap { $0.imageURL }, maxPixel: 480)
                }
            }
        }
        error = gotAny ? nil : (RateLimitState.shared.until != nil
                                ? "Сайт просит подождать. Загрузка повторится сама."
                                : "Не удалось загрузить данные. Проверьте соединение.")
    }

    func morePopular() async {
        guard !loadingMore, popularHasNext else { return }
        loadingMore = true
        defer { loadingMore = false }
        if let r = await fetch(.views, page: popularPage + 1) {
            let known = Set(popular.map { $0.id })
            popular += r.items.filter { !known.contains($0.id) }
            popularPage += 1
            popularHasNext = r.hasNext && !r.items.isEmpty
        } else {
            popularHasNext = false
        }
    }
}

struct ProfileScrollKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    /// Мягкое размытие под часами: содержимое уезжает под строку состояния, как в системных приложениях
    func statusBarBlur(opacity: Double = 1) -> some View {
        overlay(alignment: .top) {
            GeometryReader { g in
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: g.safeAreaInsets.top + 14)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.75),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
            }
            .ignoresSafeArea(edges: .top)
            .opacity(opacity)
            .allowsHitTesting(false)
        }
    }
}

struct TopBlur: View {
    let inset: CGFloat
    var body: some View {
        Rectangle()
            .fill(.ultraThinMaterial)
            .frame(height: inset + 14)
            .mask(LinearGradient(stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.75),
                .init(color: .clear, location: 1)
            ], startPoint: .top, endPoint: .bottom))
            .allowsHitTesting(false)
            .offset(y: -inset)
    }
}

extension View {
    /// Маленькая стеклянная капсула для бейджей и кнопок (на iOS 26 настоящее стекло, ниже — блюр).
    @ViewBuilder func glassCapsule() -> some View {
        glassShape(Capsule())
    }

    /// Настоящее стекло iOS 26 (подчиняется системным настройкам прозрачности), ниже — обычный блюр.
    @ViewBuilder func glassShape<S: Shape>(_ shape: S) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            self.glassEffect(.regular, in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
    }
}

struct SectionHeader: View {
    let title: String
    var action: (() -> Void)? = nil
    var actionTitle: String? = nil
    var inset: CGFloat = 28

    var body: some View {
        HStack {
            if let action, actionTitle == nil {
                Button(action: action) {
                    HStack(spacing: 4) {
                        Text(title).font(.title3.bold())
                        Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Theme.accent)
                    }
                }
                .buttonStyle(.pressable)
            } else {
                Text(title).font(.title3.bold())
            }
            Spacer()
            if let action, let t = actionTitle {
                Button(t, action: action).font(.footnote).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, inset)
    }
}

/// Компактная иконка-пометка на обложке: «НОВОЕ» — искра, «НОВАЯ ГЛАВА» — плюс главы. Почти не закрывает обложку.
struct UpdateMark: View {
    let text: String
    private var isNew: Bool { text == "НОВОЕ" }
    var body: some View {
        Image(systemName: isNew ? "sparkles" : "plus")
            .font(.system(size: 11, weight: .heavy))
            .foregroundStyle(.white)
            .frame(width: 24, height: 24)
            .background {
                if isNew {
                    Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Circle().fill(Color.black.opacity(0.55))
                }
            }
            .overlay(Circle().stroke(Color.white.opacity(0.3), lineWidth: 0.6))
            .padding(6)
            .accessibilityLabel(text)
    }
}

/// Сколько глав/серий и когда вышла последняя — для подписи в «Свежих главах». Один запрос на тайтл, с кэшем.
@MainActor
final class FreshInfo: ObservableObject {
    static let shared = FreshInfo()
    @Published private(set) var items: [String: (count: Int?, date: Date?)] = [:]
    private var loading = Set<String>()
    private func key(_ a: Anime) -> String { "\(LibSite.current.key)-\(a.id)" }
    func get(_ a: Anime) -> (count: Int?, date: Date?)? { items[key(a)] }
    private struct Saved: Codable { var count: Int?; var date: Date?; var at: Date }
    private var disk: [String: Saved] = {
        guard let d = UserDefaults.standard.data(forKey: "freshinfo.v1"),
              let v = try? JSONDecoder().decode([String: Saved].self, from: d) else { return [:] }
        return v.filter { Date().timeIntervalSince($0.value.at) < 86400 }
    }()

    func load(_ a: Anime) async {
        let k = key(a)
        guard items[k] == nil, !loading.contains(k) else { return }
        if let s = disk[k], Date().timeIntervalSince(s.at) < 86400 {
            items[k] = (s.count, s.date)
            return
        }
        loading.insert(k)
        let r = await RequestGate.inBackground { await AnimelibAPI.shared.updateInfo(slug: a.slugUrl) }
        loading.remove(k)
        let v = (count: r.count, date: r.date.flatMap(parseLibDate))
        items[k] = v
        if v.count != nil || v.date != nil {
            disk[k] = Saved(count: v.count, date: v.date, at: Date())
            if let d = try? JSONEncoder().encode(disk) { UserDefaults.standard.set(d, forKey: "freshinfo.v1") }
        }
    }
}

struct PosterCard: View {
    let anime: Anime
    var width: CGFloat = 124
    /// Необязательная пометка в правом верхнем углу («Новое» и т. п.)
    var mark: String? = nil
    /// Подпись под названием: тип и что вышло («Манхва · 87 гл. · сегодня»)
    var showFresh = false
    @ObservedObject private var fresh = FreshInfo.shared

    private var subtitle: String {
        var parts: [String] = []
        if let t = anime.type?.title, !t.isEmpty { parts.append(t) }
        if showFresh, let f = fresh.get(anime) {
            let book = LibSite.current.isBook
            if let n = f.count, n > 0 { parts.append(book ? "\(n) гл." : "\(n) эп.") }
            if let d = f.date { parts.append(ChapterAge.ago(d)) }
        }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: width > 140 ? anime.posterURL : anime.imageURL, maxPixel: width > 140 ? 720 : 480)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(Theme.chip, lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if let mark { UpdateMark(text: mark) }
                }
                .overlay(alignment: .bottomLeading) {
                    if let r = anime.rateAvg { RatingBadge(text: r, compact: true).padding(6) }
                }
            Text(anime.cardTitle)
                .font(width > 140 ? .subheadline.weight(.medium) : .footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            if !subtitle.isEmpty {
                Text(subtitle)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
        .task(id: anime.id) { if showFresh { await fresh.load(anime) } }
    }
}

struct AnimeRow: View {
    /// Миниатюра 62×93 pt — это 279 пикселей экрана по длинной стороне; 300 хватает без потери резкости.
    static let thumbPixels: CGFloat = 300
    let anime: Anime
    var rank: Int? = nil
    /// Лёгкий вид без плашки: обложка, название, рейтинг.
    var light = false
    /// Статус из твоих списков — маленький значок на обложке
    var status: ListStatus? = nil
    /// Показать число оценок рядом с рейтингом
    var showVotes = false

    private var subtitle: String {
        [anime.type?.title, anime.status?.title, LibSite.current.isBook ? nil : anime.episodesCount.map { "\($0) эп." }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    var body: some View {
        HStack(spacing: 12) {
            if let rank {
                if light {
                    Text("\(rank)")
                        .font(.system(size: rank >= 10 ? 22 : 28, weight: .heavy, design: .rounded))
                        .foregroundStyle(rank <= 3
                                         ? AnyShapeStyle(LinearGradient(colors: [Theme.accent, Theme.accent2],
                                                                        startPoint: .top, endPoint: .bottom))
                                         : AnyShapeStyle(Color.secondary.opacity(0.55)))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(width: 38)
                } else {
                    Text("\(rank)")
                        .font(.headline.bold())
                        .foregroundStyle(rank <= 3 ? Theme.accent : Color.secondary)
                        .frame(width: 22)
                }
            }
            RemoteImage(url: light ? anime.posterURL : anime.imageURL, maxPixel: AnimeRow.thumbPixels)
                .frame(width: 52, height: 78)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(alignment: .topLeading) {
                    if let status { StatusBadge(status: status, book: LibSite.current.isBook, size: 18) }
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(anime.cardTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 6)
            if let r = anime.rateAvg {
                if light {
                    // в списке — просто звезда и цифра: капсула нужна только поверх пёстрой обложки
                    VStack(alignment: .trailing, spacing: 1) {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.accent)
                            Text(r).font(.subheadline.weight(.semibold).monospacedDigit())
                        }
                        if showVotes, let v = anime.rateVotes, v > 0 {
                            Text(fmtVotes(v)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .fixedSize()
                } else {
                    RatingBadge(text: r)
                }
            }
        }
        .padding(light ? EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0) : EdgeInsets(top: 10, leading: 10, bottom: 10, trailing: 10))
        .background {
            if !light { RoundedRectangle(cornerRadius: 16).fill(Theme.card) }
        }
        .overlay(alignment: .bottom) {
            if light { Divider().opacity(0.5).padding(.leading, 50) }
        }
        .contentShape(Rectangle())
    }
}

/// Первое место списка «Сейчас смотрят/читают»: крупная карточка с размытым фоном из обложки.
struct PopularHero: View {
    let anime: Anime

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            BlurredCover(url: anime.posterURL, radius: 28, scale: 1.4)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(LinearGradient(colors: [.black.opacity(0.30), .black.opacity(0.72)],
                                        startPoint: .top, endPoint: .bottom))
            HStack(alignment: .bottom, spacing: 16) {
                RemoteImage(url: anime.posterURL, maxPixel: 720)
                    .frame(width: 112, height: 168)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 8) {
                    Label("№1 сейчас", systemImage: "flame.fill")
                        .font(.caption.bold())
                        .foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .glassCapsule()
                    Text(anime.cardTitle)
                        .font(.title3.bold())
                        .foregroundStyle(.white)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                    Text([anime.type?.title, LibSite.current.isBook ? nil : anime.episodesCount.map { "\($0) эп." }]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "))
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.75))
                    if let r = anime.rateAvg {
                        RatingBadge(text: r)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 200)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
    }
}

struct ContinueCard: View {
    let item: HistoryItem
    @ObservedObject private var progress = ProgressStore.shared

    var body: some View {
        let p = LibSite.current.isBook ? nil : progress.get(item.episodeID)
        HStack(spacing: 12) {
            RemoteImage(url: item.anime.imageURL)
                .frame(width: 44, height: 66)
                .clipShape(RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.anime.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.episodeTitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let p, p.position > 5 {
                    Text(p.duration > 0 ? "\(formatTime(p.position)) из \(formatTime(p.duration))" : formatTime(p.position))
                        .font(.caption2)
                        .foregroundStyle(Theme.accent)
                    if p.duration > 0 {
                        ProgressView(value: min(p.position / p.duration, 1))
                            .tint(Theme.accent)
                    }
                }
                if LibSite.current.isBook, let rp = ReadPosStore.shared.get(item.anime.readKey),
                   rp.c == item.episodeID, rp.pct > 0 {
                    Text("Прочитано \(rp.pct)%").font(.caption2).foregroundStyle(Theme.accent)
                    ProgressView(value: Double(rp.pct) / 100).tint(Theme.accent)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(8)
        .frame(width: 240)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .background {
            CoverTintLayer(url: item.anime.imageURL, strength: 0.4, horizontal: true)
                .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
    }
}

/// Единая плашка рейтинга: белая звезда на тёмной капсуле, как на обложках в каталоге.
struct RatingBadge: View {
    let text: String
    /// Плотность тёмной подложки: плотная, чтобы читалась и на светлых обложках
    var opacity: Double = 0.74
    /// Маленькая — для обложек в сетке и лентах
    var compact = false
    var body: some View {
        Label(text, systemImage: "star.fill")
            .font(compact ? .caption2.bold() : .caption.bold())
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 8 : 9).padding(.vertical, 4)
            .background(Color.black.opacity(opacity), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 0.5))
    }
}

/// Размытая обложка для фона. Размытие делается один раз в фоне по маленькой картинке и кэшируется,
/// а не пересчитывается видеочипом в каждом кадре прокрутки (как `.blur`). На вид то же, заряда тратит меньше.
/// Общий контекст Core Image для размытия обложек (вне View, чтобы использовать из фоновых задач).
enum BlurContext {
    static let ci = CIContext(options: [.cacheIntermediates: false])
}

struct BlurredCover: View {
    let url: URL?
    /// Радиус в точках экрана, как у `.blur(radius:)`
    var radius: CGFloat
    var scale: CGFloat = 1
    @State private var image: UIImage?

    private static let source: CGFloat = 160

    var body: some View {
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill()
                        .scaleEffect(scale)
                        .transition(.opacity)
                }
            }
            .clipped()
            .allowsHitTesting(false)
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { image = nil; return }
        let key = "\(url.absoluteString)#blur\(Int(radius))" as NSString
        if let c = ImageCache.shared.object(forKey: key) { image = c; return }
        guard let src = await ImageLoader.shared.image(url, referer: LibSite.current.referer, maxPixel: Self.source) else { return }
        // Радиус в пикселях маленькой картинки: экран ~390 pt по ширине.
        let r = radius * Self.source / 390
        let out = await Task.detached(priority: .utility) { BlurredCover.blur(src, r) }.value
        guard let out else { return }
        ImageCache.store(out, key)
        withAnimation(.easeOut(duration: 0.2)) { image = out }
    }

    nonisolated private static func blur(_ img: UIImage, _ r: CGFloat) -> UIImage? {
        guard let cg = img.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let f = CIFilter(name: "CIGaussianBlur") else { return nil }
        f.setValue(input.clampedToExtent(), forKey: kCIInputImageKey)
        f.setValue(max(r, 1), forKey: kCIInputRadiusKey)
        guard let o = f.outputImage?.cropped(to: input.extent),
              let res = BlurContext.ci.createCGImage(o, from: input.extent) else { return nil }
        return UIImage(cgImage: res)
    }
}

struct TodayHero: View {
    let anime: Anime
    @Environment(\.colorScheme) private var scheme
    private var todayMeta: String {
        let g = (anime.genres ?? []).map { $0.title }.filter { !$0.isEmpty }.prefix(2)
        if !g.isEmpty { return g.joined(separator: " · ") }
        return [anime.status?.title, LibSite.current.isBook ? nil : anime.episodesCount.map { "\($0) эп." }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    /// Доминантный цвет обложки — им окрашена карточка (как в Apple Music)
    @State private var tint: Color?

    var body: some View {
        let dark = scheme == .dark
        let c = tint ?? Theme.accent
        // светлая тема: светлая пастельная карточка с тёмным текстом; тёмная — насыщенная с белым
        let pastel = Color(uiColor: Theme.mix(UIColor(c), .white, 0.78))
        let fg: Color = dark ? .white : .primary
        ZStack {
            BlurredCover(url: anime.posterURL ?? anime.imageURL, radius: 30, scale: 1.5)
            if dark {
                LinearGradient(colors: [c.opacity(0.55), c.opacity(0.8)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
                LinearGradient(colors: [.black.opacity(0), .black.opacity(0.35)], startPoint: .top, endPoint: .bottom)
                    .allowsHitTesting(false)
            } else {
                LinearGradient(colors: [pastel.opacity(0.86), pastel.opacity(0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)
                    .allowsHitTesting(false)
            }
            HStack(spacing: 16) {
                // обложка целиком, без обрезки
                RemoteImage(url: anime.posterURL ?? anime.imageURL, maxPixel: 600)
                    .frame(width: 128, height: 192)
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.18), lineWidth: 0.6))
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text("ВЫБОР ДНЯ").tracking(1.2)
                    }
                    .font(.caption2.weight(.heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing),
                                in: Capsule())
                    Text(anime.cardTitle)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(fg)
                        .lineLimit(4)
                        .minimumScaleFactor(0.8)
                        .multilineTextAlignment(.leading)
                    HStack(spacing: 8) {
                        if let r = anime.rateAvg { RatingBadge(text: r) }
                        // вместо типа (он и так в заголовке экрана) — жанры, а если их нет — статус выпуска
                        if !todayMeta.isEmpty { Text(todayMeta).foregroundStyle(fg.opacity(0.75)).lineLimit(1) }
                    }
                    .font(.footnote.weight(.semibold))
                    Spacer(minLength: 0)
                    HStack(spacing: 8) {
                        // ▶ и для чтения: книга — это значок статуса «Читаю»
                        Image(systemName: "play.fill")
                        Text(LibSite.current.isBook ? "Читать" : "Смотреть")
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18).padding(.vertical, 9)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    .shadow(color: Theme.accent.opacity(0.5), radius: 8, y: 3)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .frame(height: 192)
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 220)
        .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.14), lineWidth: 0.6))
        .padding(.horizontal, 14)
        .task(id: anime.id) { tint = await CoverTint.color(anime.posterURL ?? anime.imageURL) }
    }
}

/// Последний тайтл крупно: прогресс и кнопка «Продолжить».
struct ContinueHero: View {
    let item: HistoryItem
    @ObservedObject private var progress = ProgressStore.shared
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let book = LibSite.current.isBook
        let p = book ? nil : progress.get(item.episodeID)
        let rp = book ? ReadPosStore.shared.get(item.anime.readKey) : nil
        let here = rp.flatMap { $0.c == item.episodeID ? $0 : nil }
        let frac: Double? = {
            if let p, p.duration > 0, p.position > 5 { return min(p.position / p.duration, 1) }
            // манга: известно число страниц — полоска сразу; ранобэ — только с 1%, чтобы не было «0%»
            if let r = here, let total = r.n, total > 0 { return Double(min(r.p + 1, total)) / Double(total) }
            if let r = here, r.pct > 0 { return Double(min(r.pct, 100)) / 100 }
            return nil
        }()
        let progressText: String? = {
            if let r = here, let total = r.n, total > 0 { return "стр. \(min(r.p + 1, total)) из \(total)" }
            return frac.map { "\(Int($0 * 100))%" }
        }()
        HStack(spacing: 14) {
            RemoteImage(url: item.anime.posterURL ?? item.anime.imageURL, maxPixel: 480)
                .frame(width: 76, height: 114)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            VStack(alignment: .leading, spacing: 8) {
                Text(item.anime.displayTitle)
                    .font(.headline)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(item.episodeTitle)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Theme.accent, in: Capsule())
                    .lineLimit(1)
                if let frac {
                    HStack(spacing: 8) {
                        // тонкая полоска прогресса цветом акцента
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.primary.opacity(0.12))
                                Capsule()
                                    .fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                                    .frame(width: max(4, g.size.width * frac))
                            }
                        }
                        .frame(height: 4)
                        Text(progressText ?? "").font(.caption2.weight(.semibold).monospacedDigit()).foregroundStyle(Theme.accent)
                            .lineLimit(1).fixedSize()
                    }
                }
            }
            Spacer(minLength: 0)
            Image(systemName: book ? "book.fill" : "play.fill")
                .font(.headline.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing), in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.28), lineWidth: 0.8))
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: 138)
        .background {
            // за стеклом — размытая обложка тайтла
            ZStack {
                BlurredCover(url: item.anime.posterURL ?? item.anime.imageURL, radius: 24, scale: 1.4)
                // тёмная тема — затемняем обложку, светлая — осветляем: текст читается на любой картинке
                if scheme == .dark {
                    Color.black.opacity(0.5)
                } else {
                    Rectangle().fill(.ultraThinMaterial)
                    Color.white.opacity(0.45)
                    // лёгкий пастельный оттенок обложки, как у «Выбора дня»
                    CoverTintLayer(url: item.anime.posterURL ?? item.anime.imageURL, strength: 0.6, horizontal: true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}

/// Широкая карточка: обложка слева, данные справа.
struct WideCard: View {
    let anime: Anime
    var mark: String? = nil
    @ObservedObject private var fresh = FreshInfo.shared

    private var meta: String {
        let g = (anime.genres ?? []).map { $0.title }.filter { !$0.isEmpty }.prefix(2)
        var parts: [String] = g.isEmpty ? [anime.status?.title].compactMap { $0 }.filter { !$0.isEmpty } : Array(g)
        if let n = fresh.get(anime)?.count, n > 0 { parts.append(LibSite.current.isBook ? "\(n) гл." : "\(n) эп.") }
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 12) {
            RemoteImage(url: anime.posterURL ?? anime.imageURL, maxPixel: 420)
                .frame(width: 92, height: 138)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                Text(anime.cardTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                if let t = anime.type?.title {
                    Text(t).font(.caption).foregroundStyle(.secondary)
                }
                if !meta.isEmpty {
                    Text(meta).font(.caption).foregroundStyle(Theme.accent).lineLimit(2)
                }
                Spacer(minLength: 0)
                HStack(spacing: 6) {
                    if let r = anime.rateAvg { RatingBadge(text: r) }
                    if let mark {
                        Text(mark == "НОВОЕ" ? "Новое" : "Глава")
                            .font(.system(size: 11, weight: .heavy))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .foregroundStyle(.white)
                            .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(width: 290, height: 162)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .background {
            CoverTintLayer(url: anime.imageURL, strength: 0.35, horizontal: true)
                .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
        }
        .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
        .task(id: anime.id) { await fresh.load(anime) }
    }
}

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var favMeta = FavMetaStore.shared
    private func favStatus(_ a: Anime) -> ListStatus? {
        FavoritesStore.current.contains(a) ? favMeta.status(a) : nil
    }

    /// «Лучшее по рейтингу»: лента обложек с местом, чтобы не сливалось со списком «Сейчас читают»
    private func rankedRail(_ list: [Anime]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(Array(list.enumerated()), id: \.element.id) { i, a in
                    TitleLink(anime: a) {
                        PosterCard(anime: a, width: 168)
                            .overlay(alignment: .topLeading) {
                                Text("\(i + 1)")
                                    .font(.system(size: 15, weight: .heavy, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(minWidth: 28, minHeight: 28)
                                    .background {
                                        if i < 3 {
                                            Circle().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .top, endPoint: .bottom))
                                        } else {
                                            Circle().fill(Color.black.opacity(0.7))
                                        }
                                    }
                                    .overlay(Circle().stroke(Color.white.opacity(0.35), lineWidth: 0.6))
                                    .padding(6)
                            }
                            .overlay(alignment: .topTrailing) {
                                if let st = favStatus(a) { StatusBadge(status: st, book: LibSite.current.isBook) }
                            }
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 28)
        }
    }
    @ObservedObject private var history: HistoryStore = HistoryStore.current
    @ObservedObject private var router = AppRouter.shared
    @State private var query = ""
    @State private var confirmClear = false
    /// «Продолжить»: открываем тайтл и сразу читалку/плеер на нужной главе или серии
    @State private var continueAnime: Anime?
    @State private var pushContinue = false
    private let ranobe = LibSite.current.isBook

    /// «Выбор дня»: из лучших и популярных, один и тот же в течение суток.
    private var todayPick: Anime? {
        var seen = Set<Int>()
        let pool = (vm.top.prefix(12) + vm.popular.prefix(10)).filter { seen.insert($0.id).inserted }
        guard !pool.isEmpty else { return nil }
        let day = Calendar.current.ordinality(of: .day, in: .year, for: Date()) ?? 1
        return pool[day % pool.count]
    }

    private func wideRail(_ list: [Anime], newIDs: Set<Int>? = nil) -> some View {
        var seen = Set<Int>()
        let unique = list.filter { seen.insert($0.id).inserted }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(spacing: 12) {
                ForEach(unique) { a in
                    TitleLink(anime: a) { WideCard(anime: a, mark: newIDs.map { $0.contains(a.id) ? "НОВОЕ" : "НОВАЯ ГЛАВА" }) }
                        .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 28)
        }
    }

    /// Открывает тайтл и сразу читалку (или плеер) на главе/серии, где ты остановился.
    private func openContinue(_ a: Anime) {
        Haptics.tap()
        continueAnime = a
        pushContinue = true
    }

    private func poster(_ list: [Anime], newIDs: Set<Int> = []) -> some View {
        // повторяющиеся id ломают ленивую ленту: карточки перестают нажиматься и листаться
        var seen = Set<Int>()
        let unique = list.filter { seen.insert($0.id).inserted }
        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(unique) { a in
                    // поменьше, чтобы было видно 3+ карточки и что лента листается
                    TitleLink(anime: a) { PosterCard(anime: a, width: 168, mark: newIDs.contains(a.id) ? "НОВОЕ" : nil, showFresh: true) }
                        .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 28)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Text(LibSite.current.title).font(.largeTitle.bold())
                            .padding(.horizontal, 28)
                            .padding(.top, 8)

                        if let e = vm.error, vm.fresh.isEmpty {
                            VStack(spacing: 12) {
                                Text(e).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Повторить") { Task { await vm.load(force: true) } }
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.top, 40)
                        }

                        HStack(alignment: .top, spacing: 18) {
                            if let pick = todayPick {
                                TitleLink(anime: pick) { TodayHero(anime: pick) }
                                    .buttonStyle(.pressable)
                                    .frame(maxWidth: .infinity)
                            }
                            if let h = history.items.first {
                                VStack(alignment: .leading, spacing: 10) {
                                    SectionHeader(title: ranobe ? "Продолжить читать" : "Продолжить смотреть",
                                                  action: { confirmClear = true }, actionTitle: "Очистить", inset: 0)
                                    Button { openContinue(h.anime) } label: { ContinueHero(item: h) }
                                        .buttonStyle(.pressable)
                                }
                                .frame(width: 440)
                            }
                        }
                        .padding(.horizontal, 28)
                        .confirmationDialog("Очистить список?", isPresented: $confirmClear, titleVisibility: .visible) {
                            Button("Очистить всё", role: .destructive) {
                                withAnimation { history.clear() }
                            }
                            Button("Отмена", role: .cancel) {}
                        }

                        if history.items.count > 1 {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Ещё в процессе")
                                // все карточки одинаковые, в карусели; следующая выглядывает краешком
                                let list = Array(history.items.dropFirst().prefix(12))
                                let w: CGFloat = 520
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(spacing: 12) {
                                        ForEach(list) { h in
                                            ZStack(alignment: .topTrailing) {
                                                Button { openContinue(h.anime) } label: { ContinueHero(item: h) }
                                                    .buttonStyle(.pressable)
                                                Button {
                                                    Haptics.tap()
                                                    withAnimation(.easeInOut(duration: 0.25)) { history.remove(h.anime.id) }
                                                } label: {
                                                    Image(systemName: "xmark")
                                                        .font(.system(size: 11, weight: .bold))
                                                        .foregroundStyle(.white)
                                                        .frame(width: 26, height: 26)
                                                        .background(Color.black.opacity(0.45), in: Circle())
                                                        .padding(10)
                                                }
                                                .buttonStyle(.plain)
                                            }
                                            .frame(width: list.count == 1 ? w : w * 0.88)
                                            .transition(.opacity.combined(with: .scale(scale: 0.9)))
                                            .contextMenu {
                                                Button(role: .destructive) { history.remove(h.anime.id) } label: {
                                                    Label("Убрать из списка", systemImage: "trash")
                                                }
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 28)
                                }
                            }
                        }

                        if !vm.fresh.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: ranobe ? "Свежие главы" : "Свежие серии") { router.openCatalog(sort: .lastEpisode) }
                                poster(Array(vm.fresh.prefix(14)))
                            }
                        }

                        if !vm.popular.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: ranobe ? "Сейчас читают" : "Сейчас смотрят") { router.openCatalog(sort: .views) }
                                LazyVStack(spacing: 0) {
                                    if let first = vm.popular.first {
                                        TitleLink(anime: first) { PopularHero(anime: first) }
                                            .buttonStyle(.pressable)
                                            .padding(.bottom, 8)
                                    }
                                    // на главной — только первая десятка, весь список открывается в Каталоге
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 460), spacing: 10, alignment: .top)], spacing: 0) {
                                        ForEach(Array(vm.popular.prefix(10).enumerated()).dropFirst(), id: \.element.id) { i, a in
                                            TitleLink(anime: a) { AnimeRow(anime: a, rank: i + 1, light: true, status: favStatus(a)) }
                                                .buttonStyle(.pressable)
                                        }
                                    }
                                    Button { router.openCatalog(sort: .views) } label: {
                                        HStack(spacing: 6) {
                                            Text("Весь список")
                                            Image(systemName: "chevron.right").font(.caption.weight(.bold))
                                        }
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(Theme.accent)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 12)
                                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
                                    }
                                    .buttonStyle(.pressable)
                                    .padding(.top, 10)
                                }
                                .padding(.horizontal, 28)
                            }
                        }

                        // только новые тайтлы: вышедшие главы уже в «Свежих главах» наверху
                        if !vm.newest.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Новинки") { router.openCatalog(sort: .newest) }
                                wideRail(vm.newest)
                            }
                        }

                        if !vm.top.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Лучшее по рейтингу") { router.openCatalog(sort: .rating) }
                                rankedRail(Array(vm.top.prefix(10)))
                            }
                        }

                        if vm.isLoading && vm.fresh.isEmpty { ProgressView().frame(maxWidth: .infinity).padding(.top, 30) }
                        Color.clear.frame(height: 120)
                    }
                    .padding(.top, 6)
                    .frame(maxWidth: 1600)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.immediately)
                .refreshable { await vm.load(force: true) }
                .statusBarBlur()
                // сайт просил подождать — как только пауза кончилась, догружаем
                .onReceive(RateLimitState.shared.$resumed.dropFirst()) { _ in
                    if vm.error != nil || vm.fresh.isEmpty { Task { await vm.load(force: true) } }
                }
            }
            .background {
                ZStack(alignment: .top) {
                    AppBackground()
                    if let pick = todayPick {
                        CoverTintLayer(url: pick.posterURL ?? pick.imageURL, strength: 0.5)
                            .frame(height: 560)
                            .ignoresSafeArea()
                    }
                }
            }
            .toolbar(.hidden, for: .navBar)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0).macPushed() }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0).macPushed(980) }
            .navigationDestination(isPresented: $pushContinue) {
                if let a = continueAnime {
                    if ranobe {
                        NovelDetailView(novel: Novel(a), autoContinue: true)
                    } else {
                        DetailView(anime: a, autoContinue: true)
                    }
                }
            }
            .task { await vm.load() }
        }
    }
}
