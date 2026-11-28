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

// MARK: - Навигация между вкладками
@MainActor
final class AppRouter: ObservableObject {
    static let shared = AppRouter()
    @Published var tab = UserDefaults.standard.integer(forKey: "debug.tab")
    @Published var pendingQuery: String?
    @Published var pendingSort: CatalogFilter.SortOption?
    @Published var pendingGenres: Set<Int>?
    @Published var pendingTags: Set<Int>?
    @Published var toast: String?
    /// Тайтл, который нужно открыть сразу (например, экранизация с другого сайта).
    @Published var pendingTitle: Anime?
    /// Избранное с фильтром: статус («Читаю»…) или своя папка сайта («Любимые»…)
    @Published var pendingFavStatus: ListStatus?
    @Published var pendingFavFolder: Int?

    func openFavorites(status: ListStatus? = nil, folder: Int? = nil) {
        pendingFavStatus = status
        pendingFavFolder = folder
        tab = 2
    }

    /// Каталог с одним выбранным жанром или тегом (по нажатию на него на странице тайтла).
    func openCatalog(genre: Int? = nil, tag: Int? = nil) {
        pendingQuery = ""
        pendingSort = .views
        pendingGenres = genre.map { [$0] } ?? []
        pendingTags = tag.map { [$0] } ?? []
        tab = 1
    }

    func openCatalog(query: String = "", sort: CatalogFilter.SortOption? = nil) {
        pendingQuery = query
        pendingSort = sort ?? .views
        tab = 1
    }
}

// MARK: - История просмотра («Продолжить смотреть»)
struct HistoryItem: Codable, Identifiable {
    let anime: Anime
    var episodeID: Int
    var episodeTitle: String
    var updated: Date
    var id: Int { anime.id }
}

@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore(key: "history.v1")
    static let novels = HistoryStore(key: "history.novels.v1")
    static let manga = HistoryStore(key: "history.manga.v1")
    static let hentai = HistoryStore(key: "history.hentai.v1")
    static var current: HistoryStore {
        let site = LibSite.current
        if site.isHentai { return hentai }
        return site.isManga ? manga : (site.isRanobe ? novels : shared)
    }
    @Published private(set) var items: [HistoryItem] = []
    private let key: String

    init(key: String) {
        self.key = key
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([HistoryItem].self, from: d) {
            items = v
        }
    }

    func recordChapter(anime: Anime, chapterID: Int, title: String) {
        FavMetaStore.shared.markSeen(anime)
        items.removeAll { $0.anime.id == anime.id }
        items.insert(HistoryItem(anime: anime, episodeID: chapterID, episodeTitle: title, updated: Date()), at: 0)
        if items.count > 30 { items = Array(items.prefix(30)) }
        save()
    }

    func record(anime: Anime, episode: EpisodeShort) {
        FavMetaStore.shared.markSeen(anime)
        items.removeAll { $0.anime.id == anime.id }
        items.insert(HistoryItem(anime: anime, episodeID: episode.id,
                                 episodeTitle: episode.title, updated: Date()), at: 0)
        if items.count > 30 { items = Array(items.prefix(30)) }
        save()
    }

    func remove(_ animeID: Int) {
        items.removeAll { $0.anime.id == animeID }
        save()
    }

    func clear() {
        items = []
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}
