import SwiftUI
import AppKit

@main
struct YumeApp: App {
    init() {
        BackupManager.restoreOnLaunch()
        _ = Theme.accent
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .frame(minWidth: 960, minHeight: 640)
        }
        .defaultSize(width: 1280, height: 820)
        .commands { YumeCommands() }

        SwiftUI.Settings {
            SettingsView()
                .frame(width: 640, height: 720)
        }
    }
}

/// Пункты меню приложения и горячие клавиши.
struct YumeCommands: Commands {
    var body: some Commands {
        CommandMenu("Разделы") {
            Button("Главная") { Task { @MainActor in AppRouter.shared.tab = 0 } }.keyboardShortcut("1", modifiers: .command)
            Button("Каталог") { Task { @MainActor in AppRouter.shared.tab = 1 } }.keyboardShortcut("2", modifiers: .command)
            Button("Избранное") { Task { @MainActor in AppRouter.shared.tab = 2 } }.keyboardShortcut("3", modifiers: .command)
            Button("Профиль") { Task { @MainActor in AppRouter.shared.tab = 3 } }.keyboardShortcut("4", modifiers: .command)
            Divider()
            Button("Поиск") { Task { @MainActor in AppRouter.shared.tab = 1 } }.keyboardShortcut("f", modifiers: .command)
        }
    }
}
