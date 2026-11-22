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

/// На iOS 26 таб-бар сворачивается в компактную капсулу при прокрутке вниз.
struct TabBarMinimize: ViewModifier {
    func body(content: Content) -> some View {
        if #available(iOS 26.0, macOS 26.0, *) {
            content.tabBarMinimizeBehavior(.onScrollDown)
        } else {
            content
        }
    }
}

struct RootView: View {
    @AppStorage("accent.hex") private var accentHex = Theme.defaultAccentHex
    @AppStorage("set.platform") private var platform = "anime"
    @AppStorage("set.theme") private var appTheme = "system"
    @Environment(\.scenePhase) private var scenePhase
    @ObservedObject private var router = AppRouter.shared
    @State private var newBadge = 0
    @State private var showFound = false
    @State private var showDone = false
    @State private var foundText = ""

    private func applyFound() {
        let r = BackupManager.readAppFolderCopy()
        if let d = r.0, BackupManager.restore(d) != nil {
            BackupManager.acceptExternal()
            Haptics.success()
            showDone = true
        }
    }

    private var scheme: ColorScheme? {
        switch appTheme {
        case "light": return .light
        case "dark": return .dark
        default: return nil
        }
    }

    var body: some View {
        MacShell(selection: $router.tab, platform: $platform, newBadge: newBadge)
        .id(accentHex + platform)
        .overlay(alignment: .top) { RateLimitBanner() }
        .transition(.opacity)
        .tint(Color(hex: accentHex))
        .preferredColorScheme(scheme)
        .onChange(of: scenePhase) { phase in
            if phase != .active { ProgressStore.shared.flush(); ActivityStore.shared.flush() }
            if phase == .background { BackupManager.writeAuto() }
            if phase == .active { Task { await FavUpdater.refreshIfDue() } }
            if phase == .active, let d = BackupManager.externalCopyDate() {
                foundText = ruDate(d)
                showFound = true
            }
        }
        .task {
            // Копия при запуске пишется в фоне: сборка и запись всего хранилища не задерживают первый экран.
            Task.detached(priority: .utility) { BackupManager.writeAuto() }
            newBadge = FavMetaStore.shared.totalNew(FavoritesStore.current.items)
            await FavUpdater.refreshIfDue()
        }
        .onReceive(FavMetaStore.shared.$items.debounce(for: .seconds(1), scheduler: RunLoop.main)) { _ in
            newBadge = FavMetaStore.shared.totalNew(FavoritesStore.current.items)
        }
        .alert("Найдена копия в папке приложения", isPresented: $showFound) {
            Button("Загрузить") { applyFound() }
            Button("Не нужно", role: .cancel) { BackupManager.acceptExternal() }
        } message: {
            Text("Файл Yume-backup от \(foundText). Загрузить из него прогресс, избранное и настройки?")
        }
        .overlay {
            Color.clear.allowsHitTesting(false)
                .alert("Готово", isPresented: $showDone) {
                    Button("Закрыть приложение") { exit(0) }
                } message: {
                    Text("Открой Yume заново, чтобы всё применилось.")
                }
        }
        .overlay(alignment: .top) {
            if let t = router.toast {
                Text(t)
                    .font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .background(.ultraThinMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.25), radius: 10, y: 4)
                    .padding(.top, 8)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task(id: t) {
                        try? await Task.sleep(nanoseconds: 1_800_000_000)
                        if router.toast == t { router.toast = nil }
                    }
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.8), value: router.toast)
    }
}

@MainActor
final class SearchHistory: ObservableObject {
    static let shared = SearchHistory()
    @Published private(set) var items: [String] = []

    init() { items = UserDefaults.standard.stringArray(forKey: "search.history") ?? [] }

    func add(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        items.removeAll { $0.lowercased() == t.lowercased() }
        items.insert(t, at: 0)
        items = Array(items.prefix(8))
        UserDefaults.standard.set(items, forKey: "search.history")
    }

    func clear() {
        items = []
        UserDefaults.standard.removeObject(forKey: "search.history")
    }
}
