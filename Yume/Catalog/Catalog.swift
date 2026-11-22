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

// MARK: - Catalog
@MainActor
final class CatalogViewModel: ObservableObject {
    @Published var items: [Anime] = []
    @Published var filter = CatalogFilter()
    @Published var isLoading = false
    @Published var error: String?
    @Published var options = FilterOptions()
    @Published var optionsLoading = false

    private var page = 1
    private var hasNext = true
    private var generation = 0
    private(set) var loadedQuery = ""
    /// id недавно добавленных тайтлов: нужны только для пометок в списке «Последние обновления»
    @Published private(set) var newIDs: Set<Int> = []
    private var newIDsLoaded = false

    var showsUpdateMarks: Bool { LibSite.current.isBook && filter.sortBy == .lastEpisode }

    func loadNewIDs() async {
        guard showsUpdateMarks, !newIDsLoaded else { return }
        newIDsLoaded = true
        var f = CatalogFilter()
        f.sortBy = .newest
        var ids = Set<Int>()
        for pg in 1...3 {
            guard let r = try? await AnimelibAPI.shared.catalog(filter: f, page: pg) else { break }
            ids.formUnion(r.items.map { $0.id })
            if !r.hasNext { break }
        }
        newIDs = ids
    }

    func reload() async {
        generation += 1
        loadedQuery = filter.query
        page = 1; hasNext = true; items = []; error = nil
        isLoading = false
        await loadMore()
    }

    func loadMore() async {
        guard hasNext, !isLoading else { return }
        isLoading = true
        let gen = generation
        defer { if gen == generation { isLoading = false } }
        do {
            let r: (items: [Anime], hasNext: Bool, next: Int)
            if filter.sortBy == .rating {
                r = try await AnimelibAPI.shared.catalogRated(filter: filter, startPage: page)
            } else {
                let x = try await AnimelibAPI.shared.catalog(filter: filter, page: page)
                r = (x.items, x.hasNext, page + 1)
            }
            guard gen == generation else { return }
            let known = Set(items.map(\.id))
            let fresh = r.items.filter { !known.contains($0.id) }
            items += fresh
            ImageLoader.prefetch(fresh.compactMap { $0.posterURL ?? $0.imageURL }, maxPixel: 520)
            hasNext = r.hasNext
            page = r.next
        } catch {
            guard gen == generation else { return }
            self.error = error.localizedDescription
        }
    }

    func toggle(_ kp: WritableKeyPath<CatalogFilter, Set<Int>>, _ id: Int) {
        if filter[keyPath: kp].contains(id) {
            filter[keyPath: kp].remove(id)
        } else {
            filter[keyPath: kp].insert(id)
        }
    }

    func resetFilters() {
        filter.genres = []; filter.tags = []; filter.types = []; filter.statuses = []
    }

    func loadOptionsIfNeeded(force: Bool = false) async {
        guard !optionsLoading, force || options.isEmpty else { return }
        optionsLoading = true
        options = await AnimelibAPI.shared.filterOptions()
        optionsLoading = false
    }
}

struct SearchBar: View {
    @Binding var text: String
    var onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Поиск по названию", text: $text)
                .submitLabel(.search)
                .onSubmit(onSubmit)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !text.isEmpty {
                Button {
                    text = ""
                    onSubmit()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.pressable)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .glassShape(Capsule())
    }
}

struct OptionBlock: View {
    let title: String
    let items: [NamedItem]
    let keyPath: WritableKeyPath<CatalogFilter, Set<Int>>
    @ObservedObject var vm: CatalogViewModel

    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.headline)
                FlowLayout(spacing: 8) {
                    ForEach(items, id: \.id) { item in
                        Chip(title: item.title,
                             selected: item.id.map { vm.filter[keyPath: keyPath].contains($0) } ?? false) {
                            if let id = item.id { vm.toggle(keyPath, id) }
                        }
                    }
                }
            }
        }
    }
}

struct FilterSheet: View {
    @ObservedObject var vm: CatalogViewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Сортировка").font(.headline)
                        FlowLayout(spacing: 8) {
                            ForEach(CatalogFilter.SortOption.allCases) { opt in
                                Chip(title: opt.label(LibSite.current.isBook), selected: vm.filter.sortBy == opt) {
                                    vm.filter.sortBy = opt
                                }
                            }
                        }
                    }

                    if vm.optionsLoading {
                        HStack { ProgressView(); Text("Загружаю жанры и теги…").foregroundStyle(.secondary) }
                    } else if vm.options.isEmpty {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Не удалось загрузить жанры и теги.").foregroundStyle(.secondary)
                            Button("Повторить") { Task { await vm.loadOptionsIfNeeded(force: true) } }
                        }
                    }

                    OptionBlock(title: "Тип", items: vm.options.types, keyPath: \.types, vm: vm)
                    OptionBlock(title: "Статус", items: vm.options.statuses, keyPath: \.statuses, vm: vm)
                    OptionBlock(title: "Жанры", items: vm.options.genres, keyPath: \.genres, vm: vm)
                    OptionBlock(title: "Теги", items: vm.options.tags, keyPath: \.tags, vm: vm)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(AppBackground())
            .navigationTitle("Фильтры")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Сбросить") { vm.resetFilters() }
                        .disabled(vm.filter.activeCount == 0)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Показать") {
                        dismiss()
                        Task { await vm.reload() }
                    }
                    .bold()
                }
            }
        }
        .task { await vm.loadOptionsIfNeeded() }
    }
}

struct CatalogView: View {
    @ObservedObject private var favMeta = FavMetaStore.shared
    /// Статус тайтла из твоих списков — показываем маленьким значком на обложке
    private func favStatus(_ a: Anime) -> ListStatus? {
        FavoritesStore.current.contains(a) ? favMeta.status(a) : nil
    }
    @StateObject private var vm = CatalogViewModel()
    @ObservedObject private var router = AppRouter.shared
    @State private var showFilters = false
    @ObservedObject private var searches = SearchHistory.shared
    @State private var randomTarget: Anime?
    @State private var showRandom = false
    @State private var rolling = false
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    private func roll() {
        guard !rolling else { return }
        rolling = true
        Haptics.tap()
        let filter = vm.filter
        Task { @MainActor in
            var pick: Anime?
            for _ in 0..<3 where pick == nil {
                if let r = try? await AnimelibAPI.shared.catalog(filter: filter, page: Int.random(in: 1...25)) {
                    pick = r.items.randomElement()
                }
            }
            if pick == nil, let r = try? await AnimelibAPI.shared.catalog(filter: filter, page: 1) {
                pick = r.items.randomElement()
            }
            rolling = false
            if let a = pick {
                randomTarget = a
                showRandom = true
                Haptics.success()
            }
        }
    }

    @ViewBuilder
    private var randomDestination: some View {
        if let a = randomTarget {
            if LibSite.current.isBook { NovelDetailView(novel: Novel(a)) } else { DetailView(anime: a) }
        }
    }

    private var randomButton: some View {
        Button { roll() } label: {
            Group {
                if rolling { ProgressView() } else { Image(systemName: "dice.fill").font(.headline) }
            }
            .frame(width: 44, height: 44)
            .glassShape(Circle())
        }
        .buttonStyle(.pressable)
    }

    private var filterButton: some View {
        Button { showFilters = true } label: {
            Group {
                if vm.filter.activeCount > 0 {
                    Image(systemName: "slider.horizontal.3").font(.headline)
                        .frame(width: 44, height: 44)
                        .background(Theme.accent, in: Circle())
                } else {
                    Image(systemName: "slider.horizontal.3").font(.headline)
                        .frame(width: 44, height: 44)
                        .glassShape(Circle())
                }
            }
                .overlay(alignment: .topTrailing) {
                    if vm.filter.activeCount > 0 {
                        Text("\(vm.filter.activeCount)")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(4)
                            .background(Color.pink, in: Circle())
                            .offset(x: 4, y: -4)
                    }
                }
        }
        .buttonStyle(.pressable)
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
            ScrollView {
                VStack(spacing: 10) {
                    HStack {
                        Text(LibSite.current.title)
                            .font(.largeTitle.bold())
                        Spacer()
                        randomButton
                        filterButton
                    }
                    SearchBar(text: $vm.filter.query) {
                        searches.add(vm.filter.query)
                        Task { await vm.reload() }
                    }
                    if vm.filter.query.isEmpty && !searches.items.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                                ForEach(searches.items, id: \.self) { q in
                                    Chip(title: q, selected: false) {
                                        vm.filter.query = q
                                        Task { await vm.reload() }
                                    }
                                }
                                Button { searches.clear() } label: {
                                    Image(systemName: "xmark.circle").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.pressable)
                            }
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, geo.safeAreaInsets.top + 4)
                .padding(.bottom, 10)

                if let e = vm.error, vm.items.isEmpty {
                    VStack(spacing: 12) {
                        Text(e).multilineTextAlignment(.center).foregroundStyle(.secondary)
                        Button("Повторить") { Task { await vm.reload() } }
                    }
                    .padding(.top, 60).padding(.horizontal)
                } else if vm.items.isEmpty && !vm.isLoading {
                    Text("Ничего не найдено")
                        .foregroundStyle(.secondary)
                        .padding(.top, 80)
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(vm.items) { anime in
                        TitleLink(anime: anime) { AnimeCard(anime: anime, status: favStatus(anime), mark: vm.showsUpdateMarks ? (vm.newIDs.contains(anime.id) ? "НОВОЕ" : "НОВАЯ ГЛАВА") : nil) }
                            .buttonStyle(.pressable)
                            .task { await vm.loadNewIDs() }
                            .onAppear {
                                if vm.items.suffix(8).contains(where: { $0.id == anime.id }) { Task { await vm.loadMore() } }
                            }
                    }
                }
                .padding(.horizontal, 14)
                if vm.isLoading { ProgressView().padding() }
            }
            .scrollDismissesKeyboard(.immediately)
            .refreshable { await vm.reload() }
            .ignoresSafeArea(edges: .top)
            .overlay(alignment: .top) {
                // мягкое размытие под строкой состояния: обложки заезжают под неё, как в системных приложениях
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .frame(height: geo.safeAreaInsets.top + 14)
                    .mask(LinearGradient(stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black, location: 0.75),
                        .init(color: .clear, location: 1)
                    ], startPoint: .top, endPoint: .bottom))
                    .allowsHitTesting(false)
                    .offset(y: -geo.safeAreaInsets.top)
            }
            }
            .background(AppBackground())
            .toolbar(.hidden, for: .navBar)
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .navigationDestination(isPresented: $showRandom) { randomDestination }
            .sheet(isPresented: $showFilters) { FilterSheet(vm: vm) }
            .task { if vm.items.isEmpty { await vm.reload() } }
            .task { await SiteListSync.syncIfDue() }
            .onReceive(RateLimitState.shared.$resumed.dropFirst()) { _ in
                if vm.error != nil || vm.items.isEmpty { Task { await vm.reload() } }
            }
            .task(id: vm.filter.query) {
                // живой поиск: ждём, пока вы закончите печатать
                guard vm.filter.query != vm.loadedQuery else { return }
                try? await Task.sleep(nanoseconds: 450_000_000)
                if Task.isCancelled || vm.filter.query == vm.loadedQuery { return }
                await vm.reload()
            }
            .onAppear {
                var changed = false
                if let q = router.pendingQuery { vm.filter.query = q; router.pendingQuery = nil; changed = true }
                if let so = router.pendingSort { vm.filter.sortBy = so; router.pendingSort = nil; changed = true }
                if let g = router.pendingGenres, let t = router.pendingTags {
                    vm.filter.genres = g; vm.filter.tags = t; vm.filter.types = []; vm.filter.statuses = []
                    router.pendingGenres = nil; router.pendingTags = nil; changed = true
                }
                if changed { Task { await vm.reload() } }
            }
        }
    }
}

struct AnimeCard: View {
    let anime: Anime
    /// Статус, если тайтл есть в твоих списках (значок слева сверху)
    var status: ListStatus? = nil
    /// Пометка в правом верхнем углу («НОВОЕ» / «НОВАЯ ГЛАВА») — только в списке по последним обновлениям
    var mark: String? = nil
    /// В «Избранном» рейтинг не нужен — вместо него прогресс и где остановился
    var showRating = true
    var subtitle: String? = nil
    var progress: Double? = nil
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            RemoteImage(url: anime.posterURL ?? anime.imageURL, maxPixel: 520)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 18, style: .continuous).stroke(Color.white.opacity(0.08), lineWidth: 0.5))
                .overlay(alignment: .topTrailing) {
                    if let mark { UpdateMark(text: mark) }
                }
                .overlay(alignment: .topLeading) {
                    if let status { StatusBadge(status: status, book: LibSite.current.isBook) }
                }
                .overlay(alignment: .bottomLeading) {
                    if showRating, let r = anime.rateAvg { RatingBadge(text: r, compact: true).padding(7) }
                }
            if let progress {
                // тонкая полоска прогресса под обложкой
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Color.primary.opacity(0.12))
                        Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                            .frame(width: max(4, g.size.width * min(max(progress, 0), 1)))
                    }
                }
                .frame(height: 3)
                .padding(.horizontal, 4)
                .padding(.top, -2)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(anime.cardTitle)
                    .font(.footnote.weight(.semibold))
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .lineLimit(1)
                }
            }
        }
    }
}
