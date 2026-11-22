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

// MARK: - Автор: все его тайтлы
struct AuthorRef: Hashable {
    let id: Int
    let name: String
    var slug: String? = nil
}

@MainActor
final class AuthorViewModel: ObservableObject {
    @Published var items: [Anime] = []
    @Published var isLoading = false
    @Published var error: String?
    private var page = 1
    private var finished = false
    let authorID: Int
    let slug: String?

    init(authorID: Int, slug: String?) {
        self.authorID = authorID
        self.slug = slug
    }

    func loadMore() async {
        guard !isLoading, !finished else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            let r = try await AnimelibAPI.shared.byAuthor(authorID, slug: slug, page: page)
            let known = Set(items.map { $0.id })
            let fresh = r.items.filter { !known.contains($0.id) }
            items += fresh
            ImageLoader.prefetch(fresh.compactMap { $0.posterURL ?? $0.imageURL }, maxPixel: 520)
            page += 1
            if fresh.isEmpty || !r.hasNext { finished = true }
            error = nil
        } catch {
            if items.isEmpty { self.error = error.localizedDescription } else { finished = true }
        }
    }
}

struct AuthorView: View {
    let author: AuthorRef
    @StateObject private var vm: AuthorViewModel
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    init(author: AuthorRef) {
        self.author = author
        _vm = StateObject(wrappedValue: AuthorViewModel(authorID: author.id, slug: author.slug))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 12) {
                    Image(systemName: "person.crop.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(author.name).font(.title3.bold())
                        Text("Все тайтлы автора").font(.footnote).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 18))

                if let e = vm.error {
                    Text(e).font(.footnote).foregroundStyle(.red).textSelection(.enabled)
                    HStack(spacing: 16) {
                        Button("Повторить") { Task { await vm.loadMore() } }
                        Button("Скопировать текст ошибки") { UIPasteboard.general.string = e }
                    }
                    .font(.footnote)
                    NavigationLink {
                        SiteLogView(path: "people/\(author.slug ?? String(author.id))")
                    } label: {
                        Label("Открыть страницу автора на сайте и записать запросы", systemImage: "waveform.path.ecg")
                            .font(.footnote.weight(.semibold))
                    }
                }
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(vm.items) { a in
                        TitleLink(anime: a) { AnimeCard(anime: a) }
                            .buttonStyle(.pressable)
                            .onAppear {
                                if vm.items.suffix(8).contains(where: { $0.id == a.id }) { Task { await vm.loadMore() } }
                            }
                    }
                }
                if vm.isLoading { ProgressView().frame(maxWidth: .infinity) }
                if vm.items.isEmpty && !vm.isLoading && vm.error == nil {
                    Text("Тайтлов не найдено").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                }
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle(author.name)
        .navigationBarTitleDisplayMode(.inline)
        .task { await vm.loadMore() }
    }
}
