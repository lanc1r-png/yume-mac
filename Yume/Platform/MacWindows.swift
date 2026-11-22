import SwiftUI
import AppKit

/// Закрытие отдельного окна (плеер, читалка), в которое хостится экран.
struct HostDismiss {
    var close: () -> Void = {}
    func callAsFunction() { close() }
}

private struct HostDismissKey: EnvironmentKey { static let defaultValue = HostDismiss() }

extension EnvironmentValues {
    var hostDismiss: HostDismiss {
        get { self[HostDismissKey.self] }
        set { self[HostDismissKey.self] = newValue }
    }
}

/// Обычное окно macOS с SwiftUI-содержимым.
@MainActor
final class HostWindow: NSObject, NSWindowDelegate {
    private static var alive: [ObjectIdentifier: HostWindow] = [:]

    let window: NSWindow
    var onClose: (() -> Void)?
    private var closed = false

    init<V: View>(title: String, size: CGSize, content: V) {
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.title = title
        w.contentMinSize = NSSize(width: 720, height: 480)
        window = w
        super.init()
        let root = AnyView(
            content
                .environment(\.hostDismiss, HostDismiss { [weak self] in self?.close() })
                .tint(Theme.accent)
        )
        let hc = NSHostingController(rootView: root)
        hc.sizingOptions = []
        w.contentViewController = hc
        w.setContentSize(size)
        w.center()
        w.delegate = self
        Self.alive[ObjectIdentifier(self)] = self
        w.makeKeyAndOrderFront(nil)
    }

    func close() {
        guard !closed else { return }
        window.close()
    }

    func windowWillClose(_ notification: Notification) {
        guard !closed else { return }
        closed = true
        window.contentViewController = nil
        let cb = onClose
        onClose = nil
        Self.alive[ObjectIdentifier(self)] = nil
        cb?()
    }

    static func closeAll() {
        for h in Array(alive.values) { h.close() }
    }
}

struct WindowPresenter<C: View>: ViewModifier {
    @Binding var isPresented: Bool
    var onDismiss: (() -> Void)?
    var size: CGSize
    @ViewBuilder var content: () -> C
    @State private var host: HostWindow?

    func body(content c: Content) -> some View {
        c.onChange(of: isPresented) { _, now in
            if now { open() } else { host?.close() }
        }
        .onAppear { if isPresented { open() } }
    }

    private func open() {
        guard host == nil else { return }
        let h = HostWindow(title: "Yume", size: size, content: content())
        h.onClose = {
            host = nil
            if isPresented { isPresented = false }
            onDismiss?()
        }
        host = h
    }
}

struct ItemWindowPresenter<I: Identifiable, C: View>: ViewModifier {
    @Binding var item: I?
    var onDismiss: (() -> Void)?
    var size: CGSize
    @ViewBuilder var content: (I) -> C
    @State private var host: HostWindow?

    func body(content c: Content) -> some View {
        c.onChange(of: item?.id) { _, now in
            if now != nil { open() } else { host?.close() }
        }
        .onAppear { if item != nil { open() } }
    }

    private func open() {
        guard host == nil, let i = item else { return }
        let h = HostWindow(title: "Yume", size: size, content: content(i))
        h.onClose = {
            host = nil
            if item != nil { item = nil }
            onDismiss?()
        }
        host = h
    }
}

extension View {
    func hostWindow<C: View>(isPresented: Binding<Bool>, size: CGSize = CGSize(width: 1280, height: 800),
                             onDismiss: (() -> Void)? = nil,
                             @ViewBuilder content: @escaping () -> C) -> some View {
        modifier(WindowPresenter(isPresented: isPresented, onDismiss: onDismiss, size: size, content: content))
    }

    func hostWindow<I: Identifiable, C: View>(item: Binding<I?>, size: CGSize = CGSize(width: 1280, height: 800),
                                              onDismiss: (() -> Void)? = nil,
                                              @ViewBuilder content: @escaping (I) -> C) -> some View {
        modifier(ItemWindowPresenter(item: item, onDismiss: onDismiss, size: size, content: content))
    }
}

/// Корректный выход: закрыть окна, остановить фон, подстраховаться от зависания.
final class YumeAppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Если главный поток занят, процесс всё равно завершится.
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) { exit(0) }
        HostWindow.closeAll()
        return .terminateNow
    }

    func applicationWillTerminate(_ notification: Notification) {
        UserDefaults.standard.synchronize()
    }
}
