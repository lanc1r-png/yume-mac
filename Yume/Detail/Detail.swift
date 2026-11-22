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

// MARK: - Detail
@MainActor
final class DetailViewModel: ObservableObject {
    @Published var anime: Anime
    @Published var episodes: [EpisodeShort] = []
    @Published var isLoading = true
    @Published var error: String?

    init(anime: Anime) { self.anime = anime }

    func load() async {
        isLoading = true; error = nil
        do {
            if let slug = anime.slugUrl {
                async let d = AnimelibAPI.shared.details(slug: slug)
                async let e = AnimelibAPI.shared.episodes(animeID: anime.id)
                if let full = try? await d { anime = full }
                episodes = try await e
            } else {
                episodes = try await AnimelibAPI.shared.episodes(animeID: anime.id)
            }
        } catch { self.error = error.localizedDescription }
        isLoading = false
    }
}

struct DetailView: View {
    @StateObject private var vm: DetailViewModel
    @State private var selected: EpisodeShort?
    @State private var showComments = false
    @State private var showBookmark = false
    @ObservedObject private var progress = ProgressStore.shared
    @State private var expanded = false
    @ObservedObject private var favorites = FavoritesStore.shared
    private let autoContinue: Bool
    @State private var didAutoContinue = false

    init(anime: Anime, autoContinue: Bool = false) {
        _vm = StateObject(wrappedValue: DetailViewModel(anime: anime))
        self.autoContinue = autoContinue
    }

    /// Открывает серию, на которой остановились (или следующую, если она досмотрена).
    private func openContinue() {
        guard !vm.episodes.isEmpty else { return }
        var idx = 0
        if let h = HistoryStore.shared.items.first(where: { $0.anime.id == vm.anime.id }),
           let i = vm.episodes.firstIndex(where: { $0.id == h.episodeID }) {
            idx = i
            if progress.get(h.episodeID)?.finished == true, i + 1 < vm.episodes.count { idx = i + 1 }
        }
        selected = vm.episodes[idx]
    }

    private var animePills: [(String, String)] {
        var p: [(String, String)] = []
        if let r = vm.anime.rateAvg { p.append(("star.fill", r)) }
        if let s = vm.anime.status?.title, !s.isEmpty { p.append(("dot.radiowaves.left.and.right", s)) }
        if let t = vm.anime.type?.title, !t.isEmpty { p.append(("tv", t)) }
        if let a = vm.anime.ageRestriction?.title, !a.isEmpty { p.append(("exclamationmark.shield", a)) }
        if let n = vm.anime.episodesCount { p.append(("list.bullet", "\(n) эп.")) }
        return p
    }

    private var continueTitle: String {
        if let h = HistoryStore.shared.items.first(where: { $0.anime.id == vm.anime.id }),
           let i = vm.episodes.firstIndex(where: { $0.id == h.episodeID }) {
            let next = progress.get(h.episodeID)?.finished == true && i + 1 < vm.episodes.count ? i + 1 : i
            return "Продолжить: серия \(vm.episodes[next].number ?? "")"
        }
        return "Смотреть"
    }

    private var backdrop: some View {
        ZStack {
            Theme.base
            BlurredCover(url: vm.anime.imageURL, radius: 16)
                .opacity(0.55)
            CoverTintLayer(url: vm.anime.imageURL, strength: 0.6)
            LinearGradient(colors: [.clear, Theme.base.opacity(0.85), Theme.base], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TitleHero(cover: vm.anime.largeImageURL ?? vm.anime.imageURL, title: vm.anime.displayTitle,
                          subtitle: (vm.anime.name != nil && vm.anime.name != vm.anime.displayTitle) ? vm.anime.name : nil,
                          pills: animePills,
                          action: vm.episodes.isEmpty ? nil : AnyView(
                            PrimaryActionButton(icon: "play.fill", title: continueTitle) { openContinue() }))

                if !(vm.anime.genres ?? []).isEmpty || !(vm.anime.tags ?? []).isEmpty {
                    GenreStrip(genres: vm.anime.genres ?? [], tags: vm.anime.tags ?? [])
                }

                if let s = vm.anime.summary, !s.isEmpty { SummaryCard(text: s, expanded: $expanded) }

                TitleActionsRow(anime: vm.anime) { showComments = true }

                HStack(alignment: .firstTextBaseline) {
                    Text("Серии").font(.title2.bold())
                    if !vm.episodes.isEmpty { Text("\(vm.episodes.count)").font(.subheadline).foregroundStyle(.secondary) }
                }
                if vm.isLoading { ProgressView() }
                if let e = vm.error { Text(e).foregroundStyle(.red).font(.footnote) }
                if !vm.isLoading && vm.episodes.isEmpty && vm.error == nil {
                    Text("Серий пока нет").foregroundStyle(.secondary)
                }
                AdaptiveList(minWidth: 340) {
                    ForEach(vm.episodes) { ep in
                        let pr = progress.get(ep.id)
                        Button { selected = ep } label: {
                            HStack(spacing: 12) {
                                Text(ep.number ?? "–")
                                    .font(.subheadline.bold())
                                    .foregroundStyle(pr != nil ? Color.secondary : Color.primary)
                                    .frame(width: 44, height: 44)
                                    .background(pr != nil ? Color.gray.opacity(0.22) : Theme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text((ep.name?.isEmpty == false ? ep.name! : "Серия \(ep.number ?? "")"))
                                        .font(.subheadline)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                    if let s = ep.season, s != "1" {
                                        Text("Сезон \(s)").font(.caption2).foregroundStyle(.secondary)
                                    }
                                    if let pr = pr {
                                        Text(episodeStatus(pr))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                .foregroundStyle(pr != nil ? Color.secondary : Color.primary)
                                Spacer()
                                Image(systemName: (pr?.finished ?? false) ? "checkmark.circle.fill" : "play.fill")
                                    .foregroundStyle(pr != nil ? Color.gray : Theme.accent)
                            }
                            .padding(10)
                            .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
                        }
                        .buttonStyle(.pressable)
                    }
                }
            }
            .padding(16)
        }
        .background(backdrop)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navBar)
        .navigationDestination(for: AuthorRef.self) { AuthorView(author: $0).macPushed() }
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if let u = titleURL(vm.anime) {
                    Link(destination: u) { Image(systemName: "safari") }
                    ShareLink(item: u) { Image(systemName: "square.and.arrow.up") }
                }
                Button { showBookmark = true } label: { Image(systemName: "bookmark") }
                Button { favorites.toggle(vm.anime) } label: {
                    Image(systemName: favorites.contains(vm.anime) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.contains(vm.anime) ? Color.pink : Color.primary)
                }
            }
        }
        .task {
            await vm.load()
            if autoContinue, !didAutoContinue {
                didAutoContinue = true
                openContinue()
            }
        }
        .macSheet(isPresented: $showComments) { CommentsView(anime: vm.anime) }
        .macSheet(isPresented: $showBookmark) { BookmarkSheet(anime: vm.anime) }
        .fullScreenCover(item: $selected) { ep in
            PlayerScreen(episode: ep, animeTitle: vm.anime.displayTitle, anime: vm.anime, episodes: vm.episodes)
        }
    }
}

private func episodeStatus(_ pr: WatchProgress) -> String {
    if pr.finished { return "Просмотрено" }
    if pr.position > 5 { return "Остановились на " + formatTime(pr.position) }
    return "Открывали"
}
