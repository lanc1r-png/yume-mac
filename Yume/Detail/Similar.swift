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

// MARK: - Похожие тайтлы
@MainActor
final class SimilarViewModel: ObservableObject {
    @Published var similar: [Anime] = []
    @Published var related: [Anime] = []
    @Published var adapt: [Anime] = []
    @Published var note = ""
    @Published var loaded = false
    private var loadedFor: Int?

    func load(_ a: Anime) async {
        guard loadedFor != a.id, let slug = a.slugUrl else { return }
        loadedFor = a.id
        let r = await AnimelibAPI.shared.similarTitles(slug: slug)
        similar = r.similar
        related = r.related
        adapt = r.adapt
        note = r.note
        loaded = true
        ImageLoader.prefetch((r.similar + r.related + r.adapt).compactMap { $0.imageURL }, maxPixel: 320)
    }
}

/// Ряд кнопок под описанием: комментарии, связанное, похожие. Списки открываются снизу, а не лежат на странице.
struct TitleActionsRow: View {
    let anime: Anime
    let onComments: () -> Void
    @StateObject private var vm = SimilarViewModel()
    @State private var showSheet = false
    @State private var startTab = 0
    @State private var pushed: Anime?
    @State private var pushActive = false

    private func chipLabel(_ icon: String, _ title: String, _ count: Int?) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
            Text(title)
            if let c = count {
                Text("\(c)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(Theme.accent.opacity(0.22), in: Capsule())
            }
        }
        .font(.subheadline.weight(.medium))
        .foregroundStyle(Theme.accent)
        .padding(.horizontal, 12).padding(.vertical, 7)
        .background(Theme.chip, in: Capsule())
    }

    private func chip(_ icon: String, _ title: String, _ count: Int?, _ action: @escaping () -> Void) -> some View {
        Button(action: action) { chipLabel(icon, title, count) }
            .buttonStyle(.pressable)
    }

    var body: some View {
        FlowLayout(spacing: 8) {
            ForEach(Array((anime.authors ?? []).enumerated()), id: \.offset) { _, a in
                if let aid = a.id {
                    NavigationLink(value: AuthorRef(id: aid, name: a.title, slug: a.slug)) {
                        HStack(spacing: 6) {
                            Image(systemName: "person.fill")
                            Text(a.title)
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.accent)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.chip, in: Capsule())
                    }
                    .buttonStyle(.pressable)
                } else {
                    Text(a.title)
                        .font(.subheadline)
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(Theme.chip, in: Capsule())
                }
            }
            chip("bubble.left.and.bubble.right.fill", "Комментарии", nil, onComments)
            if !vm.related.isEmpty || !vm.similar.isEmpty || !vm.adapt.isEmpty {
                let relEmpty = vm.related.isEmpty && vm.adapt.isEmpty
                let both = !relEmpty && !vm.similar.isEmpty
                chip(both ? "square.stack.3d.up.fill" : (relEmpty ? "sparkles" : "link"),
                     both ? "Похожее" : (relEmpty ? "Похожие" : "Связанное"),
                     vm.related.count + vm.similar.count + vm.adapt.count) { showSheet = true }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: anime.id) { await vm.load(anime) }
        .macSheet(isPresented: $showSheet) {
            SimilarSheet(related: vm.related, similar: vm.similar, adapt: vm.adapt, start: startTab) { a, isAdapt in
                showSheet = false
                if isAdapt {
                    // экранизация живёт на сайте аниме: переключаем платформу и ищем её в каталоге
                    UserDefaults.standard.set("anime", forKey: "set.platform")
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        AppRouter.shared.openCatalog(query: a.displayTitle)
                        AppRouter.shared.toast = "Платформа: Аниме"
                    }
                    return
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    pushed = a
                    pushActive = true
                }
            }
        }
        .navigationDestination(isPresented: $pushActive) {
            if let a = pushed {
                if LibSite.current.isBook { NovelDetailView(novel: Novel(a)) } else { DetailView(anime: a) }
            }
        }
    }
}

struct SimilarCell: View {
    let anime: Anime

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            RemoteImage(url: anime.imageURL, maxPixel: 320)
                .aspectRatio(2/3, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(alignment: .bottomLeading) {
                    if let r = anime.rateAvg {
                        Text("★ " + r)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6).padding(.vertical, 3)
                            .background(Color.black.opacity(0.55), in: Capsule())
                            .padding(5)
                    }
                }
            Text(anime.displayTitle)
                .font(.caption.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }
}

struct SimilarSheet: View {
    let related: [Anime]
    let similar: [Anime]
    var adapt: [Anime] = []
    let start: Int
    let onPick: (Anime, Bool) -> Void
    @State private var tab = 0
    @State private var limit = 18
    @Environment(\.dismiss) private var dismiss
    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 12)]

    private var tabs: [(title: String, icon: String, list: [Anime])] {
        var t: [(title: String, icon: String, list: [Anime])] = []
        if !related.isEmpty { t.append(("Связанное", "link", related)) }
        if !adapt.isEmpty { t.append(("Экранизации", "tv", adapt)) }
        if !similar.isEmpty { t.append(("Похожие", "sparkles", similar)) }
        return t
    }

    private func tabButton(_ i: Int, _ t: (title: String, icon: String, list: [Anime])) -> some View {
        let on = i == tab
        return Button {
            Haptics.select()
            tab = i
            limit = 18
        } label: {
            HStack(spacing: 6) {
                Image(systemName: t.icon)
                Text(t.title)
                Text("\(t.list.count)")
                    .font(.caption2.weight(.bold))
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background((on ? Color.white : Theme.accent).opacity(0.25), in: Capsule())
            }
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .foregroundStyle(on ? Color.white : Color.primary)
            .background(on ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(Theme.chip), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    var body: some View {
        let all = tabs
        let cur = all.indices.contains(tab) ? all[tab].list : []
        let shown = Array(cur.prefix(limit))
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if all.count > 1 {
                        HStack(spacing: 8) {
                            ForEach(Array(all.enumerated()), id: \.offset) { i, t in tabButton(i, t) }
                        }
                    }
                    LazyVGrid(columns: columns, spacing: 14) {
                        ForEach(shown) { a in
                            Button { Haptics.tap(); onPick(a, all.indices.contains(tab) && all[tab].title == "Экранизации") } label: { SimilarCell(anime: a) }
                                .buttonStyle(.plain)
                        }
                    }
                    if cur.count > shown.count {
                        Button {
                            limit += 24
                        } label: {
                            Text("Показать ещё · \(cur.count - shown.count)")
                                .font(.subheadline.weight(.semibold))
                                .padding(.horizontal, 18).padding(.vertical, 10)
                                .background(Theme.chip, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
            }
            .background(AppBackground())
            .navigationTitle(all.count == 1 ? all[0].title : "Связанное и похожее")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) { Button("Готово") { dismiss() } }
            }
        }
        .onAppear { tab = min(start, max(all.count - 1, 0)) }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

struct SimilarSection: View {
    let anime: Anime
    @StateObject private var vm = SimilarViewModel()

    private func row(_ title: String, _ list: [Anime]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: 12) {
                    ForEach(Array(list.prefix(20))) { a in
                        TitleLink(anime: a) { PosterCard(anime: a) }
                            .buttonStyle(.pressable)
                    }
                }
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            if !vm.related.isEmpty { row("Связанное", vm.related) }
            if !vm.similar.isEmpty { row("Похожие", vm.similar) }
            if vm.loaded, vm.related.isEmpty, vm.similar.isEmpty, !vm.note.isEmpty {
                Text("Похожие: сайт не вернул список (\(vm.note))")
                    .font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .task(id: anime.id) { await vm.load(anime) }
    }
}
