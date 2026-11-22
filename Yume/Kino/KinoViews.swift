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

// MARK: - Мелкие виды

struct KinoImage: View {
    let url: URL?
    var maxPixel: CGFloat = 480
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().allowsHitTesting(false)
                } else if failed {
                    Image(systemName: "film").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .task(id: url) {
                guard let url else { failed = true; return }
                let key = ImageCache.key(url, maxPixel)
                if let c = ImageCache.shared.object(forKey: key) { image = c; return }
                if let img = await KinoNet.shared.image(url, maxPixel: maxPixel) {
                    ImageCache.store(img, key)
                    withAnimation(.easeOut(duration: 0.2)) { image = img }
                } else if !Task.isCancelled { failed = true }
            }
    }
}

struct KinoPoster: View {
    let item: KinoItem
    var width: CGFloat = 118
    var subtitle: String? = nil
    var progress: Double? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            KinoImage(url: item.posterURL(), maxPixel: width * 3)
                .frame(width: width, height: width * 1.5)
                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay(alignment: .bottomLeading) {
                    if let r = item.rating, !r.isEmpty { RatingBadge(text: r, compact: true).padding(6) }
                }
                .overlay(alignment: .topTrailing) {
                    if let q = item.quality, q.contains("4K") || q.contains("2160") {
                        Text("4K").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Theme.accent, in: Capsule()).padding(6)
                    }
                }
                .overlay(alignment: .bottom) {
                    if let progress {
                        GeometryReader { g in
                            ZStack(alignment: .leading) {
                                Capsule().fill(Color.black.opacity(0.45))
                                Capsule().fill(Theme.accent).frame(width: max(4, g.size.width * min(progress, 1)))
                            }
                        }
                        .frame(height: 4).padding(8)
                    }
                }
            Text(item.title.noHyphens)
                .font(.footnote.weight(.semibold))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(width: width, alignment: .leading)
            let sub = subtitle ?? item.badge ?? item.meta.prefix(2).joined(separator: " · ")
            if !sub.isEmpty {
                Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    .frame(width: width, alignment: .leading)
            }
        }
        .contentShape(Rectangle())
    }
}

/// Переход на страницу тайтла
struct KinoLink<Label: View>: View {
    let item: KinoItem
    var season: Int? = nil
    var episode: Int? = nil
    @ViewBuilder let label: () -> Label
    @ObservedObject private var store = KinoStore.shared

    var body: some View {
        NavigationLink {
            KinoDetailView(item: item, startSeason: season, startEpisode: episode)
        } label: { label() }
        .buttonStyle(.pressable)
        .contextMenu {
            Button { store.toggleFavorite(item) } label: {
                SwiftUI.Label(store.isFavorite(item) ? "Убрать из избранного" : "В избранное",
                              systemImage: store.isFavorite(item) ? "heart.slash" : "heart")
            }
            if let u = item.pageURL {
                ShareLink(item: u) { SwiftUI.Label("Поделиться", systemImage: "square.and.arrow.up") }
            }
        }
    }
}

struct KinoRail: View {
    let title: String
    let items: [KinoItem]
    var action: (() -> Void)? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, action: action).padding(.horizontal, 14)
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(items) { it in KinoLink(item: it) { KinoPoster(item: it) } }
                }
                .padding(.horizontal, 14)
            }
        }
    }
}

struct KinoSearchField: View {
    @Binding var text: String
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Фильмы и сериалы", text: $text)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.search)
            if !text.isEmpty {
                Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
        .glassShape(Capsule())
    }
}

/// Результаты поиска списком
struct KinoSearchResults: View {
    let query: String
    @State private var items: [KinoItem] = []
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        VStack(spacing: 0) {
            if loading && items.isEmpty { ProgressView().padding(30) }
            if let error, items.isEmpty { Text(error).font(.footnote).foregroundStyle(.secondary).padding(20) }
            if !loading && error == nil && items.isEmpty && query.count >= 2 {
                Text("Ничего не нашлось").foregroundStyle(.secondary).padding(30)
            }
            ForEach(items) { it in
                KinoLink(item: it) {
                    HStack(spacing: 12) {
                        KinoImage(url: it.posterURL(), maxPixel: 200)
                            .frame(width: 50, height: 75)
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 3) {
                            Text(it.title.noHyphens).font(.subheadline.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.leading).foregroundStyle(.primary)
                            Text(it.meta.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer(minLength: 6)
                        if let r = it.rating, !r.isEmpty {
                            HStack(spacing: 3) {
                                Image(systemName: "star.fill").font(.caption2).foregroundStyle(Theme.accent)
                                Text(r).font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
                            }
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                }
                Divider().padding(.leading, 76)
            }
        }
        .task(id: query) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard q.count >= 2 else { items = []; return }
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            loading = true
            defer { loading = false }
            do { items = try await KinoAPI.search(q); error = nil }
            catch { if !Task.isCancelled { self.error = error.localizedDescription } }
        }
    }
}

// MARK: - Главная

@MainActor
final class KinoHomeModel: ObservableObject {
    @Published var home = KinoAPI.Home()
    @Published var loading = false
    @Published var error: String?

    func load(force: Bool = false) async {
        if loading || (!force && (!home.decks.isEmpty || !home.updates.isEmpty)) { return }
        loading = true
        defer { loading = false }
        do { home = try await KinoAPI.home(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}

struct KinoHomeView: View {
    @StateObject private var vm = KinoHomeModel()
    @ObservedObject private var store = KinoStore.shared
    @State private var query = ""

    static let collections: [(String, String)] = [
        ("Топ-100 фильмов", "/podborki/top-100-filmov/"), ("Топ-100 сериалов", "/podborki/top-100-serialov/"),
        ("Лучшие фильмы 2026", "/podborki/luchshie-filmy-2026/"), ("Лучшие сериалы 2026", "/podborki/luchshie-serialy-2026/"),
        ("Топ-100 мультфильмов", "/podborki/top-100-multfilmov/"), ("Топ-100 аниме", "/podborki/top-100-anime/"),
        ("Лучшие русские фильмы", "/podborki/luchshie-russkie-filmy/"), ("Лучшие русские сериалы", "/podborki/luchshie-russkie-serialy/"),
        ("В 4K", "/podborki/4k/"), ("Про космос", "/podborki/kosmos/"), ("Зомби", "/podborki/zombi/"),
        ("Вампиры", "/podborki/vampiry/"), ("Катастрофы", "/podborki/katastrofy/"), ("Хакеры", "/podborki/hakery/"),
        ("Маньяки", "/podborki/manyaki/"), ("Реальные события", "/podborki/realnye-sobytiya/"),
        ("Про любовь", "/podborki/pro-lyubov/"), ("Подростки", "/podborki/podrostki/"),
        ("Новый год", "/podborki/novyj-god/"), ("Хеллоуин", "/podborki/hellouin/"),
        ("Про роботов", "/podborki/pro-robotov/"), ("Про инопланетян", "/podborki/pro-inoplanetyan/"),
        ("Про динозавров", "/podborki/pro-dinozavrov/"), ("Про собак", "/podborki/pro-sobak/"),
        ("Про врачей", "/podborki/pro-vrachej/"), ("Про полицию", "/podborki/pro-policiyu/"),
        ("Про тюрьму", "/podborki/pro-tyurmu/"), ("Акулы", "/podborki/akuly/"), ("Танцы", "/podborki/tancy/"),
        ("Великая Отечественная", "/podborki/velikaya-otechestvennaya/"), ("Для слабослышащих", "/podborki/dlya-slaboslyshashchih/")
    ]

    private var continueItems: [KinoStore.Watch] { Array(store.history.prefix(12)) }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Кино").font(.largeTitle.bold())
                        KinoSearchField(text: $query)
                    }
                    .padding(.horizontal, 14)
                    .padding(.top, 10)

                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        KinoSearchResults(query: query)
                    } else {
                        if !continueItems.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Продолжить смотреть").padding(.horizontal, 14)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    LazyHStack(alignment: .top, spacing: 12) {
                                        ForEach(continueItems) { w in
                                            KinoLink(item: w.item, season: w.season, episode: w.episode) {
                                                KinoPoster(item: w.item, width: 128,
                                                           subtitle: w.season.map { "\($0) сез. \(w.episode ?? 1) серия" } ?? w.item.kindTitle,
                                                           progress: store.position(w.item.id, w.season, w.episode).flatMap { $0.d > 0 ? $0.t / $0.d : nil })
                                            }
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                }
                            }
                        }

                        if vm.loading && vm.home.decks.isEmpty {
                            ProgressView().frame(maxWidth: .infinity).padding(40)
                        }
                        if let e = vm.error, vm.home.decks.isEmpty {
                            VStack(spacing: 10) {
                                Text(e).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                                Button("Повторить") { Task { await vm.load(force: true) } }.foregroundStyle(Theme.accent)
                            }
                            .frame(maxWidth: .infinity).padding(30)
                        }

                        ForEach(Array(vm.home.decks.enumerated()), id: \.offset) { i, deck in
                            KinoRail(title: deck.0, items: deck.1) {
                                let path: String
                                switch deck.0 {
                                case "Фильмы": path = "/film/"
                                case "Сериалы": path = "/serial/"
                                case "Мультфильмы": path = "/multfilm/"
                                case "Аниме": path = "/anime/"
                                case "ТВ-шоу": path = "/tv-shou/"
                                default: path = "/"
                                }
                                KinoRouter.shared.open(path: path, title: deck.0)
                            }
                            if i == 0, !vm.home.updates.isEmpty { updatesBlock }
                        }

                        if !vm.home.decks.isEmpty {
                            VStack(alignment: .leading, spacing: 10) {
                                SectionHeader(title: "Подборки").padding(.horizontal, 14)
                                ScrollView(.horizontal, showsIndicators: false) {
                                    HStack(spacing: 8) {
                                        ForEach(Self.collections, id: \.1) { c in
                                            NavigationLink {
                                                KinoListView(title: c.0, path: c.1, sort: .popular)
                                            } label: {
                                                Text(c.0).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                                                    .padding(.horizontal, 14).padding(.vertical, 9)
                                                    .background(Theme.chip, in: Capsule())
                                            }
                                            .buttonStyle(.pressable)
                                        }
                                    }
                                    .padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                    Color.clear.frame(height: 100)
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await vm.load(force: true) }
            .statusBarBlur()
            .background(AppBackground())
            .toolbar(.hidden, for: .navBar)
            .task { await vm.load() }
        }
    }

    @ViewBuilder
    private var updatesBlock: some View {
        ForEach(Array(vm.home.updates.enumerated()), id: \.offset) { _, sec in
            VStack(alignment: .leading, spacing: 10) {
                SectionHeader(title: sec.0).padding(.horizontal, 14)
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 12) {
                        ForEach(Array(sec.1.enumerated()), id: \.offset) { _, u in
                            KinoLink(item: u.0, season: u.1, episode: u.2) { KinoPoster(item: u.0, width: 110) }
                        }
                    }
                    .padding(.horizontal, 14)
                }
            }
        }
    }
}

/// Переход из Главной в Каталог с нужным разделом
@MainActor
final class KinoRouter: ObservableObject {
    static let shared = KinoRouter()
    @Published var pending: (path: String, title: String)?
    func open(path: String, title: String) {
        pending = (path, title)
        AppRouter.shared.tab = 1
    }
}

// MARK: - Список (раздел, жанр, подборка)

struct KinoListView: View {
    let title: String
    let path: String
    @State var sort: KinoAPI.Sort
    @State private var items: [KinoItem] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14, alignment: .top)]

    private func reload() async {
        items = []; page = 0; pages = 1; error = nil
        await more()
    }

    private func more() async {
        guard !loading, page < pages else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await KinoAPI.list(path: path, sort: sort, page: page + 1)
            var seen = Set(items.map(\.id))
            items += r.items.filter { seen.insert($0.id).inserted }
            page += 1
            pages = max(r.pages, r.items.isEmpty ? page : page)
            if r.items.isEmpty { pages = page }
        } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { it in
                    KinoLink(item: it) {
                        GeometryReader { g in KinoPoster(item: it, width: g.size.width) }
                            .aspectRatio(0.5, contentMode: .fit)
                    }
                    .onAppear { if it.id == items.last?.id { Task { await more() } } }
                }
            }
            .padding(14)
            if loading { ProgressView().padding() }
            if let error, items.isEmpty {
                VStack(spacing: 10) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Повторить") { Task { await reload() } }.foregroundStyle(Theme.accent)
                }
                .padding(30)
            }
            Color.clear.frame(height: 90)
        }
        .background(AppBackground())
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Сортировка", selection: $sort) {
                        ForEach(KinoAPI.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                } label: { Image(systemName: "arrow.up.arrow.down") }
            }
        }
        .onChange(of: sort) { _, _ in Task { await reload() } }
        .task { if items.isEmpty { await more() } }
    }
}

// MARK: - Каталог

struct KinoCatalogView: View {
    @ObservedObject private var router = KinoRouter.shared
    @State private var query = ""
    @State private var type = "/"
    @State private var filterPath: String?
    @State private var filterTitle: String?
    @State private var sort: KinoAPI.Sort = .popular
    @State private var reloadKey = 0

    static let types: [(String, String)] = [("Всё", "/"), ("Фильмы", "/film/"), ("Сериалы", "/serial/"),
                                            ("Мультфильмы", "/multfilm/"), ("Аниме", "/anime/"), ("ТВ-шоу", "/tv-shou/")]
    static let genres: [(String, String)] = [
        ("Биографии", "biografii"), ("Боевики", "boeviki"), ("Вестерны", "vesterny"), ("Военные", "voennoe-kino"),
        ("Детективы", "detektivy"), ("Документальные", "dokumentalnoe-kino"), ("Драмы", "dramy"),
        ("Исторические", "istoricheskie-filmy"), ("Комедии", "komedii"), ("Криминал", "kriminalnye-filmy"),
        ("Мелодрамы", "melodramy"), ("Музыкальные", "muzykalnye-filmy"), ("Мюзиклы", "myuzikly"),
        ("Приключения", "priklyucheniya"), ("Семейные", "semeynoe-kino"), ("Спорт", "sport"),
        ("Триллеры", "trillery"), ("Ужасы", "uzhasy"), ("Фантастика", "fantastika"), ("Фэнтези", "fentezi")
    ]
    static let countries: [(String, String)] = [
        ("США", "ssha"), ("Россия", "rossiya"), ("СССР", "sssr"), ("Великобритания", "velikobritaniya"),
        ("Франция", "franciya"), ("Германия", "germaniya"), ("Италия", "italiya"), ("Южная Корея", "koreya-yuzhnaya"),
        ("Индия", "indiya"), ("Турция", "turciya")
    ]
    static let voices: [(String, String)] = [
        ("LostFilm", "lostfilm"), ("HDrezka Studio", "hdrezka-studio"), ("Кубик в Кубе", "kubik-v-kube"),
        ("NewStudio", "newstudio"), ("TVShows", "tvshows"), ("AlexFilm", "alexfilm"), ("BaibaKo", "baibako"),
        ("ColdFilm", "coldfilm"), ("Jaskier", "jaskier"), ("Goblin", "goblin"), ("AniLibria", "anilibria"),
        ("AniDub", "anidub"), ("Animaunt", "animaunt"), ("SHIZA Project", "shiza-project"),
        ("Red Head Sound", "red-head-sound"), ("Кураж-Бамбей", "kurazh-bambey"), ("NewComers", "newcomers")
    ]

    private var path: String { filterPath ?? type }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Каталог").font(.largeTitle.bold()).padding(.horizontal, 14).padding(.top, 10)
                    KinoSearchField(text: $query).padding(.horizontal, 14)
                    if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                        KinoSearchResults(query: query)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                ForEach(Self.types, id: \.1) { t in
                                    chip(t.0, on: filterPath == nil && type == t.1) {
                                        type = t.1; filterPath = nil; filterTitle = nil
                                    }
                                }
                            }
                            .padding(.horizontal, 14)
                        }
                        HStack(spacing: 8) {
                            Menu {
                                Picker("Сортировка", selection: $sort) {
                                    ForEach(KinoAPI.Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                                }
                            } label: { menuPill(sort.title, icon: "arrow.up.arrow.down") }
                            Menu {
                                Menu("Жанр") {
                                    ForEach(Self.genres, id: \.1) { g in
                                        Button(g.0) { setFilter("/genre/\(g.1)/", g.0) }
                                    }
                                }
                                Menu("Страна") {
                                    ForEach(Self.countries, id: \.1) { c in
                                        Button(c.0) { setFilter("/country/\(c.1)/", c.0) }
                                    }
                                }
                                Menu("Год") {
                                    ForEach((2000...2026).reversed(), id: \.self) { y in
                                        Button("\(y)") { setFilter("/year/\(y)/", "\(y)") }
                                    }
                                }
                                Menu("Озвучка") {
                                    ForEach(Self.voices, id: \.1) { v in
                                        Button(v.0) { setFilter("/ozvucheno/\(v.1)/", v.0) }
                                    }
                                }
                                Menu("Подборка") {
                                    ForEach(KinoHomeView.collections, id: \.1) { c in
                                        Button(c.0) { setFilter(c.1, c.0) }
                                    }
                                }
                                if filterPath != nil {
                                    Button("Сбросить", role: .destructive) { filterPath = nil; filterTitle = nil }
                                }
                            } label: { menuPill(filterTitle ?? "Фильтр", icon: "line.3.horizontal.decrease") }
                            Spacer()
                        }
                        .padding(.horizontal, 14)

                        KinoGrid(path: path, sort: sort)
                            .id("\(path)|\(sort.rawValue)|\(reloadKey)")
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { reloadKey += 1 }
            .statusBarBlur()
            .background(AppBackground())
            .toolbar(.hidden, for: .navBar)
            .onAppear(perform: applyPending)
            .onChange(of: router.pending?.path) { _, _ in applyPending() }
        }
    }

    private func applyPending() {
        guard let p = router.pending else { return }
        router.pending = nil
        if Self.types.contains(where: { $0.1 == p.path }) { type = p.path; filterPath = nil; filterTitle = nil }
        else { filterPath = p.path; filterTitle = p.title }
    }

    private func setFilter(_ p: String, _ t: String) { filterPath = p; filterTitle = t }

    private func chip(_ t: String, on: Bool, _ action: @escaping () -> Void) -> some View {
        Button { Haptics.select(); action() } label: {
            Text(t).font(.subheadline.weight(.semibold))
                .foregroundStyle(on ? Color.white : Color.primary)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chip), in: Capsule())
        }
        .buttonStyle(.pressable)
    }

    private func menuPill(_ t: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(t).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(Theme.accent.opacity(0.12), in: Capsule())
    }
}

/// Сетка с бесконечной прокруткой
struct KinoGrid: View {
    let path: String
    let sort: KinoAPI.Sort
    @State private var items: [KinoItem] = []
    @State private var page = 0
    @State private var pages = 1
    @State private var loading = false
    @State private var error: String?
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14, alignment: .top)]

    private func more() async {
        guard !loading, page < pages else { return }
        loading = true
        defer { loading = false }
        do {
            let r = try await KinoAPI.list(path: path, sort: sort, page: page + 1)
            var seen = Set(items.map(\.id))
            items += r.items.filter { seen.insert($0.id).inserted }
            page += 1
            pages = r.items.isEmpty ? page : max(r.pages, page)
            error = nil
        } catch { self.error = error.localizedDescription }
    }

    var body: some View {
        VStack {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(items) { it in
                    KinoLink(item: it) {
                        GeometryReader { g in KinoPoster(item: it, width: g.size.width) }
                            .aspectRatio(0.5, contentMode: .fit)
                    }
                    .onAppear { if it.id == items.last?.id { Task { await more() } } }
                }
            }
            .padding(.horizontal, 14)
            if loading { ProgressView().padding() }
            if let error, items.isEmpty {
                VStack(spacing: 10) {
                    Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("Повторить") { Task { await more() } }.foregroundStyle(Theme.accent)
                }
                .padding(30)
            }
            Color.clear.frame(height: 100)
        }
        .task { if items.isEmpty { await more() } }
    }
}

// MARK: - Избранное

struct KinoFavoritesView: View {
    @ObservedObject private var store = KinoStore.shared
    @State private var tab = 0
    private let columns = [GridItem(.adaptive(minimum: 108), spacing: 14, alignment: .top)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Избранное").font(.largeTitle.bold()).padding(.horizontal, 14).padding(.top, 10)
                    Picker("", selection: $tab) {
                        Text("Избранное \(store.favorites.count)").tag(0)
                        Text("История \(store.history.count)").tag(1)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 14)

                    if tab == 0 {
                        if store.favorites.isEmpty {
                            empty("Пока пусто. Открой фильм и нажми сердечко.", icon: "heart.slash")
                        }
                        LazyVGrid(columns: columns, spacing: 18) {
                            ForEach(store.favorites) { it in
                                let w = store.watch(it)
                                KinoLink(item: it, season: w?.season, episode: w?.episode) {
                                    GeometryReader { g in
                                        KinoPoster(item: it, width: g.size.width,
                                                   subtitle: w?.season.map { "\($0) сез. \(w?.episode ?? 1) серия" })
                                    }
                                    .aspectRatio(0.5, contentMode: .fit)
                                }
                            }
                        }
                        .padding(.horizontal, 14)
                    } else {
                        if store.history.isEmpty { empty("Здесь будет то, что ты смотрел.", icon: "clock") }
                        ForEach(store.history) { w in
                            KinoLink(item: w.item, season: w.season, episode: w.episode) {
                                HStack(spacing: 12) {
                                    KinoImage(url: w.item.posterURL(), maxPixel: 200)
                                        .frame(width: 50, height: 75)
                                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(w.item.title).font(.subheadline.weight(.semibold)).lineLimit(2)
                                            .foregroundStyle(.primary).multilineTextAlignment(.leading)
                                        Text([w.season.map { "\($0) сезон, \(w.episode ?? 1) серия" }, w.translation]
                                            .compactMap { $0 }.joined(separator: " · "))
                                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                        Text(w.updated.formatted(.relative(presentation: .named)))
                                            .font(.caption2).foregroundStyle(.tertiary)
                                    }
                                    Spacer()
                                }
                                .padding(.horizontal, 14).padding(.vertical, 4)
                            }
                            .swipeActions { Button("Убрать", role: .destructive) { store.removeHistory(w.item) } }
                            .contextMenu { Button("Убрать из истории", role: .destructive) { store.removeHistory(w.item) } }
                        }
                    }
                    Color.clear.frame(height: 100)
                }
            }
            .statusBarBlur()
            .background(AppBackground())
            .toolbar(.hidden, for: .navBar)
        }
    }

    private func empty(_ t: String, icon: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 40)).foregroundStyle(.secondary)
            Text(t).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity).padding(.top, 80)
    }
}

// MARK: - Страница тайтла

struct KinoDetailView: View {
    let item: KinoItem
    var startSeason: Int? = nil
    var startEpisode: Int? = nil
    @ObservedObject private var store = KinoStore.shared
    @State private var detail: KinoDetail?
    @State private var error: String?
    @State private var season = 1
    @State private var sourceIndex = 0
    @State private var playing: KinoPlayRequest?
    @State private var webPlayer: KinoWebTarget?
    @State private var showAllInfo = false
    @AppStorage("kino.pref.translation") private var prefTranslation = ""

    private var shown: KinoItem { detail?.item ?? item }
    private var source: KinoSource? {
        guard let d = detail, !d.sources.isEmpty else { return nil }
        return d.sources[min(sourceIndex, d.sources.count - 1)]
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if let error, detail == nil {
                    VStack(spacing: 10) {
                        Text(error).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await load() } }.foregroundStyle(Theme.accent)
                    }
                    .frame(maxWidth: .infinity)
                }
                if detail == nil && error == nil { ProgressView().frame(maxWidth: .infinity).padding(20) }
                if let d = detail {
                    playBlock(d)
                    if d.isSerial { episodesBlock(d) }
                    infoBlock(d)
                }
                Color.clear.frame(height: 90)
            }
        }
        .background(AppBackground())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                HStack {
                    if let u = shown.pageURL { ShareLink(item: u) { Image(systemName: "square.and.arrow.up") } }
                    Button { store.toggleFavorite(shown) } label: {
                        Image(systemName: store.isFavorite(shown) ? "heart.fill" : "heart")
                            .foregroundStyle(store.isFavorite(shown) ? Color.pink : Theme.accent)
                    }
                }
            }
        }
        .fullScreenCover(item: $playing) { req in KinoPlayerScreen(request: req) }
        .fullScreenCover(item: $webPlayer) { t in KinoWebPlayerScreen(url: t.url, title: shown.title) }
        .task { if detail == nil { await load() } }
    }

    private func load() async {
        error = nil
        do {
            let d = try await KinoAPI.detail(item)
            detail = d
            let w = store.watch(item)
            if let t = w?.translation ?? (prefTranslation.isEmpty ? nil : prefTranslation),
               let i = d.sources.firstIndex(where: { $0.translation == t }) { sourceIndex = i }
            if let s = startSeason ?? w?.season, d.seasons.contains(s) { season = s }
            else { season = d.seasons.first ?? 1 }
        } catch { self.error = error.localizedDescription }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            KinoImage(url: shown.posterURL(big: true), maxPixel: 600)
                .frame(width: 130, height: 195)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .shadow(color: .black.opacity(0.25), radius: 10, y: 5)
            VStack(alignment: .leading, spacing: 6) {
                Text(shown.title.noHyphens).font(.title3.bold()).fixedSize(horizontal: false, vertical: true)
                if let o = shown.orig { Text(o).font(.subheadline).foregroundStyle(.secondary) }
                Text(([shown.kindTitle] + shown.meta.prefix(3)).joined(separator: " · "))
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    if let r = shown.rating, !r.isEmpty { RatingBadge(text: r) }
                    if let q = detail?.info.first(where: { $0.0 == "Качество" })?.1 ?? shown.quality {
                        Text(q).font(.caption.bold()).foregroundStyle(Theme.accent)
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(Theme.accent.opacity(0.14), in: Capsule())
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .background(alignment: .top) {
            KinoImage(url: shown.posterURL(), maxPixel: 300)
                .frame(height: 260)
                .blur(radius: 40)
                .opacity(0.45)
                .mask(LinearGradient(colors: [.black, .clear], startPoint: .top, endPoint: .bottom))
                .offset(y: -60)
                .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func playBlock(_ d: KinoDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if d.sources.isEmpty {
                Text("Плеер не найден" + (d.playersNote.map { ": " + $0 } ?? "") + ".")
                    .font(.footnote).foregroundStyle(.secondary)
                if let u = shown.pageURL {
                    Button { webPlayer = KinoWebTarget(url: u) } label: {
                        Label("Открыть страницу сайта", systemImage: "safari")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
                    }
                }
            } else {
                let w = store.watch(shown)
                let s = d.isSerial ? (w?.season ?? startSeason ?? d.seasons.first) : nil
                let e = d.isSerial ? (w?.episode ?? startEpisode ?? d.episodes(s ?? 1, source: source).first) : nil
                if let src = source, !src.isNative {
                    Text("Этот плеер откроется как на сайте: озвучку и серии выбирай внутри него.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Button {
                    play(d, season: startSeason ?? s, episode: startEpisode ?? e)
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "play.fill")
                        if let s = startSeason ?? s, let e = startEpisode ?? e {
                            Text(w != nil ? "Продолжить · \(s) сезон, \(e) серия" : "Смотреть · \(s) сезон, \(e) серия")
                        } else {
                            Text(w != nil ? "Продолжить" : "Смотреть")
                        }
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
                .buttonStyle(.pressable)

                if d.sources.count > 1 {
                    Menu {
                        ForEach(Array(d.sources.enumerated()), id: \.offset) { i, src in
                            Button {
                                sourceIndex = i
                                prefTranslation = src.translation
                            } label: {
                                if i == sourceIndex { SwiftUI.Label(src.translation, systemImage: "checkmark") }
                                else { Text([src.translation, src.quality].compactMap { $0 }.joined(separator: " · ")) }
                            }
                        }
                    } label: {
                        HStack {
                            Image(systemName: "waveform")
                            Text("Озвучка: \(source?.translation ?? "")").lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.up.chevron.down").font(.caption)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 14).padding(.vertical, 11)
                        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                }
            }
        }
        .padding(.horizontal, 14)
    }

    @ViewBuilder
    private func episodesBlock(_ d: KinoDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Серии").font(.title3.bold())
                Spacer()
                if d.seasons.count > 1 {
                    Menu {
                        ForEach(d.seasons, id: \.self) { s in Button("\(s) сезон") { season = s } }
                    } label: {
                        HStack(spacing: 4) {
                            Text("\(season) сезон")
                            Image(systemName: "chevron.down").font(.caption.bold())
                        }
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Theme.accent)
                    }
                }
            }
            let eps = d.episodes(season, source: source)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                ForEach(eps, id: \.self) { e in
                    let seen = store.watched(shown.id, season, e)
                    let last = store.watch(shown).map { $0.season == season && $0.episode == e } ?? false
                    Button { play(d, season: season, episode: e) } label: {
                        VStack(spacing: 2) {
                            Text("\(e)").font(.headline.monospacedDigit())
                            if let date = d.dates[season]?[e], !date.isEmpty {
                                Text(shortDate(date)).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(last ? Color.white : (seen ? Color.secondary : Color.primary))
                        .frame(maxWidth: .infinity, minHeight: 50)
                        .background(last ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.card),
                                    in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .overlay(alignment: .topTrailing) {
                            if seen && !last {
                                Image(systemName: "checkmark").font(.system(size: 8, weight: .heavy))
                                    .foregroundStyle(Theme.accent).padding(5)
                            }
                        }
                    }
                    .buttonStyle(.pressable)
                }
            }
        }
        .padding(.horizontal, 14)
    }

    private func shortDate(_ s: String) -> String {
        let p = s.split(separator: "-")
        guard p.count == 3 else { return s }
        return "\(p[2]).\(p[1]).\(p[0].suffix(2))"
    }

    @ViewBuilder
    private func infoBlock(_ d: KinoDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let desc = d.item.desc, !desc.isEmpty {
                Text(desc.noHyphens).font(.subheadline).foregroundStyle(.primary.opacity(0.9))
                    .lineLimit(showAllInfo ? nil : 6)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !d.genres.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(d.genres, id: \.self) { g in
                        Text(g).font(.caption.weight(.semibold))
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Theme.chip, in: Capsule())
                    }
                }
            }
            let rows = showAllInfo ? d.info : Array(d.info.prefix(6))
            VStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, r in
                    HStack(alignment: .top) {
                        Text(r.0).font(.subheadline).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(r.1).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                    Divider().opacity(0.4)
                }
                if !d.actors.isEmpty && showAllInfo {
                    HStack(alignment: .top) {
                        Text("В ролях").font(.subheadline).foregroundStyle(.secondary).frame(width: 120, alignment: .leading)
                        Text(d.actors.joined(separator: ", ")).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.vertical, 7)
                }
            }
            .padding(.horizontal, 14).padding(.vertical, 6)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            if d.info.count > 6 || !d.actors.isEmpty || (d.item.desc?.count ?? 0) > 300 {
                Button(showAllInfo ? "Свернуть" : "Подробнее") { withAnimation { showAllInfo.toggle() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.accent)
            }
        }
        .padding(.horizontal, 14)
    }

    private func play(_ d: KinoDetail, season: Int?, episode: Int?) {
        guard let src = source else { return }
        Haptics.tap()
        if !src.isNative {
            store.record(shown, season: nil, episode: nil, translation: src.translation)
            webPlayer = KinoWebTarget(url: src.url)
            return
        }
        var eps: [(Int, Int)] = []
        if d.isSerial {
            for s in d.seasons { for e in d.episodes(s, source: src) { eps.append((s, e)) } }
        }
        playing = KinoPlayRequest(item: shown, sources: d.sources, sourceIndex: min(sourceIndex, d.sources.count - 1),
                                  season: d.isSerial ? season : nil, episode: d.isSerial ? episode : nil,
                                  episodes: eps.map { KinoPlayRequest.Ep(season: $0.0, episode: $0.1) })
    }
}

// MARK: - Плеер

struct KinoPlayRequest: Identifiable {
    struct Ep: Hashable { let season: Int; let episode: Int }
    let id = UUID()
    let item: KinoItem
    let sources: [KinoSource]
    var sourceIndex: Int
    var season: Int?
    var episode: Int?
    var episodes: [Ep]
}

@MainActor
final class KinoPlayerModel: ObservableObject {
    @Published var player: AVPlayer?
    @Published var stream: KinoStream?
    @Published var track = 0
    @Published var quality = 0
    @Published var loading = false
    @Published var error: String?
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var ended = false

    private var observer: Any?
    private var endObs: NSObjectProtocol?
    private var key: (Int, Int?, Int?) = (0, nil, nil)

    func load(_ src: KinoSource, item: KinoItem, season: Int?, episode: Int?, keepTrack: String?) async {
        stop()
        loading = true
        error = nil
        ended = false
        key = (item.id, season, episode)
        defer { loading = false }
        do {
            let s = try await KinoAPI.stream(src, season: season, episode: episode)
            stream = s
            track = keepTrack.flatMap { t in s.tracks.firstIndex { $0.label == t } } ?? 0
            quality = 0
            let resume = KinoStore.shared.position(item.id, season, episode).flatMap { $0.d > 0 && $0.t / $0.d < 0.95 ? $0.t : nil }
            start(at: resume ?? 0)
        } catch {
            self.error = error.localizedDescription
        }
    }

    func start(at t: Double) {
        guard let s = stream, s.tracks.indices.contains(track) else { return }
        let tr = s.tracks[track]
        guard tr.qualities.indices.contains(quality), let url = tr.qualities[quality].1.first else { return }
        let headers = ["Referer": s.origin + "/", "Origin": s.origin, "User-Agent": KinoNet.ua]
        let asset = AVURLAsset(url: url, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
        let itemAV = AVPlayerItem(asset: asset)
        if let p = player {
            p.replaceCurrentItem(with: itemAV)
        } else {
            player = AVPlayer(playerItem: itemAV)
        }
        if t > 1 { player?.seek(to: CMTime(seconds: t, preferredTimescale: 600)) }
        player?.play()
        observe(itemAV)
    }

    /// Смена дорожки или качества с того же места
    func switchTo(track: Int? = nil, quality: Int? = nil) {
        let t = player?.currentTime().seconds ?? 0
        if let track { self.track = track; self.quality = 0 }
        if let quality { self.quality = quality }
        start(at: t.isFinite ? t : 0)
    }

    private func observe(_ it: AVPlayerItem) {
        if let o = observer { player?.removeTimeObserver(o) }
        observer = player?.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 2), queue: .main) { [weak self] tm in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.time = tm.seconds.isFinite ? tm.seconds : 0
                let d = self.player?.currentItem?.duration.seconds ?? 0
                self.duration = d.isFinite ? d : 0
                if Int(self.time) % 5 == 0, self.duration > 0 {
                    KinoStore.shared.setPosition(self.key.0, self.key.1, self.key.2, t: self.time, d: self.duration)
                }
            }
        }
        if let e = endObs { NotificationCenter.default.removeObserver(e) }
        endObs = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: it, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.duration > 0 {
                    KinoStore.shared.setPosition(self.key.0, self.key.1, self.key.2, t: self.duration, d: self.duration)
                }
                self.ended = true
            }
        }
    }

    func stop() {
        if duration > 0, time > 0 {
            KinoStore.shared.setPosition(key.0, key.1, key.2, t: time, d: duration)
        }
        if let o = observer { player?.removeTimeObserver(o); observer = nil }
        if let e = endObs { NotificationCenter.default.removeObserver(e); endObs = nil }
        player?.pause()
    }

    func skipIntro() {
        guard let r = stream?.skip else { return }
        player?.seek(to: CMTime(seconds: r.upperBound, preferredTimescale: 600))
    }
}

struct KinoPlayerScreen: View {
    @State var request: KinoPlayRequest
    @StateObject private var vm = KinoPlayerModel()
    @ObservedObject private var store = KinoStore.shared
    @Environment(\.dismiss) private var dismiss
    @AppStorage("set.autoNext") private var autoNext = true
    @AppStorage("kino.pref.translation") private var prefTranslation = ""

    private var source: KinoSource { request.sources[min(request.sourceIndex, request.sources.count - 1)] }
    private var index: Int? {
        guard let s = request.season, let e = request.episode else { return nil }
        return request.episodes.firstIndex(of: .init(season: s, episode: e))
    }
    private var next: KinoPlayRequest.Ep? {
        guard let i = index, i + 1 < request.episodes.count else { return nil }
        return request.episodes[i + 1]
    }
    private var prev: KinoPlayRequest.Ep? {
        guard let i = index, i > 0 else { return nil }
        return request.episodes[i - 1]
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Button { vm.stop(); dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).foregroundStyle(.white)
                        .frame(width: 40, height: 40).background(Color.white.opacity(0.12), in: Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.item.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    if let s = request.season, let e = request.episode {
                        Text("\(s) сезон, \(e) серия").font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 14).padding(.vertical, 10)

            ZStack {
                Color.black
                if let p = vm.player {
                    FullscreenPlayer(player: p)
                }
                if vm.loading { ProgressView().tint(.white) }
                if let e = vm.error {
                    VStack(spacing: 10) {
                        Text(e).font(.footnote).foregroundStyle(.white.opacity(0.8)).multilineTextAlignment(.center)
                        Button("Повторить") { Task { await reload() } }.foregroundStyle(Theme.accent)
                    }
                    .padding()
                }
            }
            .aspectRatio(16 / 9, contentMode: .fit)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    controls
                    if !request.episodes.isEmpty { episodesStrip }
                }
                .padding(14)
            }
        }
        .background(Color.black.ignoresSafeArea())
        .preferredColorScheme(.dark)
        .task { await reload() }
        .onChange(of: vm.ended) { _, e in
            if e, autoNext, let n = next { go(n) }
        }
        .onDisappear { vm.stop() }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                if request.sources.count > 1 {
                    Menu {
                        ForEach(Array(request.sources.enumerated()), id: \.offset) { i, s in
                            Button {
                                request.sourceIndex = i
                                prefTranslation = s.translation
                                Task { await reload() }
                            } label: {
                                if i == request.sourceIndex { SwiftUI.Label(s.translation, systemImage: "checkmark") }
                                else { Text(s.translation) }
                            }
                        }
                    } label: { pill(source.translation, icon: "person.wave.2") }
                }
                if let s = vm.stream, s.tracks.count > 1 {
                    Menu {
                        ForEach(Array(s.tracks.enumerated()), id: \.offset) { i, t in
                            Button { vm.switchTo(track: i) } label: {
                                if i == vm.track { SwiftUI.Label(t.label, systemImage: "checkmark") } else { Text(t.label) }
                            }
                        }
                    } label: { pill(s.tracks[vm.track].label, icon: "waveform") }
                }
                if let s = vm.stream, s.tracks.indices.contains(vm.track) {
                    let qs = s.tracks[vm.track].qualities
                    Menu {
                        ForEach(Array(qs.enumerated()), id: \.offset) { i, q in
                            Button { vm.switchTo(quality: i) } label: {
                                if i == vm.quality { SwiftUI.Label("\(q.0)p", systemImage: "checkmark") } else { Text("\(q.0)p") }
                            }
                        }
                    } label: { pill(qs.indices.contains(vm.quality) ? "\(qs[vm.quality].0)p" : "Качество", icon: "sparkles.tv") }
                }
            }
            if request.season != nil {
                HStack(spacing: 10) {
                    Button { if let p = prev { go(p) } } label: { pill("Предыдущая", icon: "backward.end.fill") }
                        .disabled(prev == nil).opacity(prev == nil ? 0.4 : 1)
                    Button { if let n = next { go(n) } } label: { pill("Следующая", icon: "forward.end.fill") }
                        .disabled(next == nil).opacity(next == nil ? 0.4 : 1)
                }
            }
        }
    }

    private var episodesStrip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Серии").font(.headline).foregroundStyle(.white)
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 8) {
                        ForEach(request.episodes, id: \.self) { ep in
                            let on = ep.season == request.season && ep.episode == request.episode
                            let seen = store.watched(request.item.id, ep.season, ep.episode)
                            Button { go(ep) } label: {
                                VStack(spacing: 1) {
                                    Text("\(ep.episode)").font(.headline.monospacedDigit())
                                    Text("\(ep.season) сез.").font(.system(size: 9))
                                }
                                .foregroundStyle(on ? Color.white : (seen ? Color.white.opacity(0.45) : Color.white))
                                .frame(width: 58, height: 50)
                                .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Color.white.opacity(0.1)),
                                            in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                            }
                            .id(ep)
                        }
                    }
                }
                .onAppear {
                    if let s = request.season, let e = request.episode { proxy.scrollTo(KinoPlayRequest.Ep(season: s, episode: e), anchor: .center) }
                }
            }
        }
    }

    private func pill(_ t: String, icon: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption.weight(.bold))
            Text(t).font(.subheadline.weight(.semibold)).lineLimit(1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12).padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .background(Color.white.opacity(0.12), in: Capsule())
    }

    private func go(_ ep: KinoPlayRequest.Ep) {
        Haptics.tap()
        request.season = ep.season
        request.episode = ep.episode
        Task { await reload() }
    }

    private func reload() async {
        let keep = vm.stream.flatMap { $0.tracks.indices.contains(vm.track) ? $0.tracks[vm.track].label : nil }
        store.record(request.item, season: request.season, episode: request.episode, translation: source.translation)
        await vm.load(source, item: request.item, season: request.season, episode: request.episode, keepTrack: keep)
    }
}
