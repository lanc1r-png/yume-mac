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

// MARK: - Ранобэ: экран тайтла
@MainActor
final class NovelDetailViewModel: ObservableObject {
    @Published var anime: Anime
    @Published var chapters: [NovelChapter] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var offline = false

    init(anime: Anime) { self.anime = anime }

    func load() async {
        isLoading = true
        error = nil
        guard let slug = anime.slugUrl else {
            error = "У тайтла нет адреса"
            isLoading = false
            return
        }
        async let d = AnimelibAPI.shared.details(slug: slug)
        async let c = NovelService.chapters(slug: slug)
        if let full = try? await d { anime = full }
        do {
            let list = try await c
            chapters = list
            offline = false
            OfflineStore.current.refresh(novel: anime, chapters: list)
        } catch {
            let saved = OfflineStore.current.savedChapters(anime.id)
            if saved.isEmpty {
                self.error = error.localizedDescription
            } else {
                chapters = saved
                offline = true
            }
        }
        isLoading = false
    }

    var volumeGroups: [(volume: String, indices: [Int])] {
        var order: [String] = []
        var map: [String: [Int]] = [:]
        for (i, c) in chapters.enumerated() {
            if map[c.volume] == nil { order.append(c.volume) }
            map[c.volume, default: []].append(i)
        }
        return order.map { ($0, map[$0] ?? []) }
    }
}

struct ReaderStart: Identifiable {
    let id: Int
}

/// Плашка загрузки: закреплена внизу экрана, поэтому не двигает список глав при появлении и исчезновении.
struct DownloadBannerView: View {
    @ObservedObject var dl: DownloadManager
    @ObservedObject var progress: DownloadProgress

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
            Text("Загрузка: \(dl.done) из \(dl.total)" + (progress.status.isEmpty ? "" : " · " + progress.status))
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("Стоп") { dl.cancelAll() }
                .font(.caption.bold())
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.white.opacity(0.1), lineWidth: 0.5))
        .padding(.horizontal, 16).padding(.bottom, 8)
    }
}

struct NovelDetailView: View {
    @StateObject private var vm: NovelDetailViewModel
    @ObservedObject private var read = ReadStore.shared
    @ObservedObject private var favorites = FavoritesStore.current
    @ObservedObject private var quick = QuickAccessStore.shared
    @State private var expanded = false
    @State private var reversed = false
    @State private var reader: ReaderStart?
    @State private var showComments = false
    @State private var showBookmark = false
    @ObservedObject private var store = OfflineStore.current
    @ObservedObject private var dl = DownloadManager.shared
    @State private var confirmRemove = false
    @State private var showEstimate = false
    @State private var estimateMsg = ""
    @State private var estimateIdx: [Int] = []
    private var isManga: Bool { LibSite.current.isManga }
    private let autoContinue: Bool
    @State private var didAutoContinue = false

    init(novel: Novel, autoContinue: Bool = false) {
        _vm = StateObject(wrappedValue: NovelDetailViewModel(anime: novel.anime))
        self.autoContinue = autoContinue
    }

    private var backdrop: some View {
        ZStack {
            Theme.base
            BlurredCover(url: vm.anime.imageURL, radius: 16).opacity(0.55)
            CoverTintLayer(url: vm.anime.imageURL, strength: 0.6)
            LinearGradient(colors: [.clear, Theme.base.opacity(0.85), Theme.base], startPoint: .top, endPoint: .bottom)
        }
        .ignoresSafeArea()
    }

    private var resumePctText: String {
        if let rp = ReadPosStore.shared.get(vm.anime.readKey), rp.pct > 0,
           vm.chapters.indices.contains(resumeIndex), vm.chapters[resumeIndex].id == rp.c {
            return " · \(rp.pct)%"
        }
        return ""
    }

    private var resumeIndex: Int {
        if let last = read.lastChapter(vm.anime.readKey),
           let i = vm.chapters.firstIndex(where: { $0.id == last }) { return i }
        return 0
    }

    private func doQueue(_ idx: [Int]) {
        dl.enqueue(novel: vm.anime, all: vm.chapters, targets: idx.map { vm.chapters[$0] })
    }

    private func queue(_ idx: [Int]) {
        let todo = idx.filter { !store.isDownloaded(vm.anime.id, vm.chapters[$0].id) }
        guard !todo.isEmpty else { return }
        let avg = store.avgChapterBytes ?? (isManga ? 20_000_000 : 800_000)
        let est = avg * todo.count
        let used = OfflineStore.usedBytes
        let limit = OfflineStore.limitBytes
        let over = limit > 0 && used + est > limit
        if over || todo.count >= 10 {
            var m = "Примерно \(fmtBytes(est))"
            m += store.avgChapterBytes == nil ? " (грубая оценка, пока нет скачанных глав). " : " (по среднему размеру ваших глав). "
            m += "Сейчас занято \(fmtBytes(used))" + (limit > 0 ? " из \(fmtBytes(limit))." : ".")
            if over { m += OfflineStore.purgeMode ? " Лимит превышен: удалю самые старые прочитанные главы." : " Лимит будет превышен, скачивание остановится на нём." }
            estimateMsg = m
            estimateIdx = todo
            showEstimate = true
        } else {
            doQueue(todo)
        }
    }

    private func nextIndices(_ n: Int) -> [Int] {
        let start = read.lastChapter(vm.anime.readKey) == nil ? 0 : resumeIndex
        return Array(vm.chapters.indices.dropFirst(start).prefix(n))
    }

    private var downloadMenu: some View {
        Menu {
            Button { queue(Array(vm.chapters.indices)) } label: {
                Label("Скачать все главы", systemImage: "arrow.down.circle")
            }
            Button {
                queue(vm.chapters.indices.filter { !read.isRead(vm.anime.readKey, vm.chapters[$0].id) })
            } label: {
                Label("Скачать непрочитанные", systemImage: "book.closed")
            }
            Menu {
                ForEach([5, 10, 25, 50], id: \.self) { n in
                    Button("\(n) глав") { queue(nextIndices(n)) }
                }
            } label: {
                Label("Следующие главы…", systemImage: "forward.end")
            }
            if store.downloadedCount(vm.anime.id) > 0 {
                Divider()
                Button(role: .destructive) { confirmRemove = true } label: {
                    Label("Удалить загруженные", systemImage: "trash")
                }
            }
        } label: {
            let n = store.downloadedCount(vm.anime.id)
            Label(n > 0 ? "Скачано: \(n)" : "Скачать", systemImage: "arrow.down.circle")
                .font(.footnote)
        }
    }

    @ViewBuilder
    private func volumeButton(_ idx: [Int]) -> some View {
        let all = idx.allSatisfy { store.isDownloaded(vm.anime.id, vm.chapters[$0].id) }
        if all {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.green).font(.footnote)
        } else {
            Button { queue(idx) } label: {
                Label("Скачать том", systemImage: "arrow.down.circle").font(.caption)
            }
            .buttonStyle(.pressable)
            .foregroundStyle(Theme.accent)
        }
    }

    private var novelPills: [(String, String)] {
        var p: [(String, String)] = []
        if let r = vm.anime.rateAvg { p.append(("star.fill", r)) }
        if let s = vm.anime.status?.title, !s.isEmpty { p.append(("dot.radiowaves.left.and.right", s)) }
        if let t = vm.anime.type?.title, !t.isEmpty { p.append(("book", t)) }
        if let a = vm.anime.ageRestriction?.title, !a.isEmpty { p.append(("exclamationmark.shield", a)) }
        if !vm.chapters.isEmpty { p.append(("list.bullet", "\(vm.chapters.count) гл.")) }
        if let last = vm.chapters.compactMap({ $0.date }).max() { p.append(("clock", ChapterAge.ago(last))) }
        return p
    }

    private func row(_ i: Int) -> some View {
        let c = vm.chapters[i]
        let isRead = read.isRead(vm.anime.readKey, c.id)
        let saved = store.isDownloaded(vm.anime.id, c.id)
        return HStack(spacing: 8) {
            Button { reader = ReaderStart(id: i) } label: {
                HStack(spacing: 12) {
                    Text(c.number)
                        .font(.footnote.bold())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .foregroundStyle(isRead ? Color.secondary : Color.primary)
                        .frame(width: 46, height: 46)
                        .background(isRead ? Color.gray.opacity(0.22) : Theme.accent.opacity(0.28), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(c.name.isEmpty ? "Глава \(c.number)" : c.name)
                            .font(.subheadline)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                        if let f = dl.failed[c.id] {
                            Text(f).font(.caption2).foregroundStyle(Color.orange).lineLimit(1)
                        } else if let dt = c.date {
                            Text((isRead ? "Прочитано · " : "") + ChapterAge.ago(dt) + " · " + ChapterAge.full(dt))
                                .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        } else if isRead {
                            Text("Прочитано").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(isRead ? Color.secondary : Color.primary)
                    Spacer()
                    Image(systemName: isRead ? "checkmark.circle.fill" : "book.fill")
                        .foregroundStyle(isRead ? Color.gray : Theme.accent)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.pressable)
            ChapterDownloadButton(novel: vm.anime, chapters: vm.chapters, chapter: c)
        }
        .padding(10)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.06), lineWidth: 0.5))
        .contextMenu {
            if saved {
                Button(role: .destructive) { store.remove(novel: vm.anime.id, chapter: c.id) } label: {
                    Label("Удалить загрузку", systemImage: "trash")
                }
            } else {
                Button { queue([i]) } label: { Label("Скачать главу", systemImage: "arrow.down.circle") }
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                TitleHero(cover: vm.anime.largeImageURL, title: vm.anime.displayTitle,
                          subtitle: (vm.anime.name != nil && vm.anime.name != vm.anime.displayTitle) ? vm.anime.name : nil,
                          pills: novelPills,
                          action: vm.chapters.isEmpty ? nil : AnyView(
                            PrimaryActionButton(icon: "book.fill",
                                                title: read.lastChapter(vm.anime.readKey) == nil
                                                    ? "Начать читать"
                                                    : "Продолжить: Глава \(vm.chapters[resumeIndex].number)" + resumePctText) {
                                reader = ReaderStart(id: resumeIndex)
                            }))

                if !(vm.anime.genres ?? []).isEmpty || !(vm.anime.tags ?? []).isEmpty {
                    GenreStrip(genres: vm.anime.genres ?? [], tags: vm.anime.tags ?? [])
                }

                if let s = vm.anime.summary, !s.isEmpty { SummaryCard(text: s, expanded: $expanded) }

                TitleActionsRow(anime: vm.anime) { showComments = true }

                HStack {
                    Text("Главы").font(.title2.bold())
                    Spacer()
                    if !vm.chapters.isEmpty { downloadMenu }
                    if vm.chapters.count > 1 {
                        Button { withAnimation { reversed.toggle() } } label: {
                            Label(reversed ? "Сначала новые" : "Сначала старые", systemImage: "arrow.up.arrow.down")
                                .font(.footnote)
                        }
                        .padding(.leading, 6)
                    }
                }
                if let n = dl.notice {
                    Text(n).font(.footnote).foregroundStyle(Color.orange)
                }
                if vm.offline {
                    Text("Нет сети: показаны только скачанные главы.")
                        .font(.footnote).foregroundStyle(Color.orange)
                }
                if vm.isLoading { ProgressView() }
                if let e = vm.error { Text(e).foregroundStyle(.red).font(.footnote) }
                if !vm.isLoading && vm.chapters.isEmpty && vm.error == nil {
                    Text("Глав пока нет").foregroundStyle(.secondary)
                }
                LazyVStack(alignment: .leading, spacing: 8) {
                    let groups = reversed ? Array(vm.volumeGroups.reversed()) : vm.volumeGroups
                    ForEach(Array(groups.enumerated()), id: \.offset) { _, g in
                        HStack {
                            Text("Том \(g.volume)")
                                .font(.footnote.weight(.bold))
                                .padding(.horizontal, 12).padding(.vertical, 5)
                                .glassCapsule()
                            Spacer()
                            volumeButton(g.indices)
                        }
                        .padding(.top, 12)
                        ForEach(reversed ? Array(g.indices.reversed()) : g.indices, id: \.self) { i in
                            row(i)
                        }
                    }
                }
            }
            .padding(16)
        }
        .background(backdrop)
        .safeAreaInset(edge: .bottom) {
            if dl.total > 0 { DownloadBannerView(dl: dl, progress: dl.progress) }
        }
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
                Button { quick.toggle(vm.anime) } label: { Image(systemName: quick.contains(vm.anime) ? "pin.fill" : "pin") }
                    .help(quick.contains(vm.anime) ? "Убрать из быстрого доступа" : "В быстрый доступ")
                Button { showBookmark = true } label: { Image(systemName: "bookmark") }
                Button { favorites.toggle(vm.anime) } label: {
                    Image(systemName: favorites.contains(vm.anime) ? "heart.fill" : "heart")
                        .foregroundStyle(favorites.contains(vm.anime) ? Color.pink : Color.primary)
                }
            }
        }
        .task {
            await vm.load()
            if autoContinue, !didAutoContinue, !vm.chapters.isEmpty {
                didAutoContinue = true
                reader = ReaderStart(id: resumeIndex)
            }
        }
        .macSheet(isPresented: $showComments) { CommentsView(anime: vm.anime) }
        .macSheet(isPresented: $showBookmark) { BookmarkSheet(anime: vm.anime) }
        .confirmationDialog("Скачать \(estimateIdx.count) гл.?", isPresented: $showEstimate, titleVisibility: .visible) {
            Button("Скачать") { doQueue(estimateIdx) }
            Button("Отмена", role: .cancel) {}
        } message: {
            Text(estimateMsg)
        }
        .confirmationDialog("Удалить загруженные главы этого тайтла?", isPresented: $confirmRemove, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) {
                store.remove(novel: vm.anime.id)
                if vm.offline { vm.chapters = [] }
            }
        }
        .fullScreenCover(item: $reader) { r in
            if isManga {
                MangaReaderView(novel: vm.anime, chapters: vm.chapters, start: r.id)
            } else {
                NovelReaderView(novel: vm.anime, chapters: vm.chapters, start: r.id)
            }
        }
    }
}
