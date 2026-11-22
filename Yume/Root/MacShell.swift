import SwiftUI

/// Боковая панель в стиле Mac: слева разделы и выбор платформы, справа контент.
struct MacShell: View {
    @Binding var selection: Int
    @Binding var platform: String
    var newBadge: Int
    @State private var visited: Set<Int> = [0]
    @State private var query = ""
    @State private var visibility = NavigationSplitViewVisibility.all

    private struct Item: Identifiable { let id: Int; let title: String; let icon: String }

    private var isKino: Bool { platform == "kino" }
    private var library: [Item] {
        [Item(id: 0, title: "Главная", icon: "house"),
         Item(id: 1, title: "Каталог", icon: "square.grid.2x2"),
         Item(id: 2, title: "Избранное", icon: "heart")]
    }
    private var account: [Item] {
        (isKino ? [] : [Item(id: 3, title: "Профиль", icon: "person.crop.circle")])
            + [Item(id: 4, title: "Настройки", icon: "gearshape")]
    }
    static let platforms: [(String, String, String)] = [
        ("anime", "Аниме", "play.rectangle"),
        ("manga", "Манга", "books.vertical"),
        ("ranobe", "Ранобэ", "text.book.closed"),
        ("hentai", "Hentai", "flame"),
        ("kino", "Кино", "film")
    ]

    private var selectionOpt: Binding<Int?> {
        Binding(get: { selection }, set: { if let v = $0 { selection = v } })
    }

    var body: some View {
        NavigationSplitView(columnVisibility: $visibility) {
            List(selection: selectionOpt) {
                Section {
                    Picker("Платформа", selection: $platform) {
                        ForEach(MacShell.platforms, id: \.0) { p in
                            SwiftUI.Label(p.1, systemImage: p.2).tag(p.0)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                }
                Section("Библиотека") {
                    ForEach(library) { item in
                        row(item)
                    }
                }
                Section("Аккаунт") {
                    ForEach(account) { item in
                        row(item)
                    }
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 280)
        } detail: {
            ZStack {
                ForEach(0..<5, id: \.self) { i in
                    if visited.contains(i) || selection == i {
                        screen(i)
                            .opacity(selection == i ? 1 : 0)
                            .allowsHitTesting(selection == i)
                            .accessibilityHidden(selection != i)
                    }
                }
            }
            .onChange(of: selection) { _, new in visited.insert(new) }
            .onAppear { visited.insert(selection) }
        }
        .navigationSplitViewStyle(.balanced)
        .searchable(text: $query, placement: .toolbar, prompt: "Поиск по названию")
        .onSubmit(of: .search) {
            let q = query.trimmingCharacters(in: .whitespaces)
            guard !q.isEmpty, !isKino else { return }
            SearchHistory.shared.add(q)
            AppRouter.shared.openCatalog(query: q)
            query = ""
        }
    }

    @ViewBuilder
    private func row(_ item: Item) -> some View {
        if item.id == 2 && newBadge > 0 {
            SwiftUI.Label(item.title, systemImage: item.icon).badge(newBadge).tag(item.id)
        } else {
            SwiftUI.Label(item.title, systemImage: item.icon).tag(item.id)
        }
    }

    @ViewBuilder
    private func screen(_ i: Int) -> some View {
        if isKino {
            switch i {
            case 0: KinoHomeView()
            case 1: KinoCatalogView()
            case 2: KinoFavoritesView()
            default: SettingsView()
            }
        } else {
            switch i {
            case 0: HomeView()
            case 1: CatalogView()
            case 2: FavoritesView()
            case 3: ProfileView()
            default: SettingsView()
            }
        }
    }
}
