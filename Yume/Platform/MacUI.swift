import SwiftUI
import AppKit

/// Размеры и константы, зависящие от платформы.
enum Metrics {
    static let actionWidth: CGFloat = 380
    static let actionHeight: CGFloat = 46
    static let contentWidth: CGFloat = 1100
}

/// Невидимая кнопка, которая даёт горячую клавишу (стрелки, пробел, Esc).
struct KeyShortcut: View {
    let key: KeyEquivalent
    var modifiers: EventModifiers = []
    let action: () -> Void

    init(_ key: KeyEquivalent, _ modifiers: EventModifiers = [], action: @escaping () -> Void) {
        self.key = key
        self.modifiers = modifiers
        self.action = action
    }

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(key, modifiers: modifiers)
            .opacity(0)
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
    }
}

/// Открытые экраны: ограничивают ширину контента по центру и дают ⌘[ как «Назад».
struct MacPushed: ViewModifier {
    var width: CGFloat
    @Environment(\.dismiss) private var dismiss

    func body(content: Content) -> some View {
        content
            .frame(maxWidth: width)
            .frame(maxWidth: .infinity)
            .background(AppBackground())
            .background(KeyShortcut("[", .command) { dismiss() })
    }
}

extension View {
    func macPushed(_ width: CGFloat = Metrics.contentWidth) -> some View { modifier(MacPushed(width: width)) }

    /// Лист с нормальным для Mac размером окна.
    func macSheet<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                           @ViewBuilder content: @escaping () -> C) -> some View {
        sheet(isPresented: isPresented, onDismiss: onDismiss) {
            content().frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 720)
        }
    }

    func macSheet<I: Identifiable, C: View>(item: Binding<I?>, onDismiss: (() -> Void)? = nil,
                                            @ViewBuilder content: @escaping (I) -> C) -> some View {
        sheet(item: item, onDismiss: onDismiss) { i in
            content(i).frame(minWidth: 560, idealWidth: 680, minHeight: 520, idealHeight: 720)
        }
    }
}

/// Адаптивная сетка: в широком окне несколько колонок.
struct AdaptiveList<Content: View>: View {
    var minWidth: CGFloat = 340
    @ViewBuilder var content: () -> Content
    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: minWidth), spacing: 10, alignment: .top)], spacing: 10) {
            content()
        }
    }
}

/// Окно без полосы заголовка: содержимое идёт под кнопки окна (читалка манги).
struct FullBleedWindow: NSViewRepresentable {
    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let w = window else { return }
            DispatchQueue.main.async {
                w.titlebarAppearsTransparent = true
                w.titleVisibility = .hidden
                w.styleMask.insert(.fullSizeContentView)
                w.backgroundColor = .black
            }
        }
    }
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ nsView: NSView, context: Context) {}
}

enum MacFullscreen {
    @MainActor static func toggle() { NSApp.keyWindow?.toggleFullScreen(nil) }
    @MainActor static var isOn: Bool { NSApp.keyWindow?.styleMask.contains(.fullScreen) ?? false }
}

/// Горячая клавиша по коду кнопки: работает в любой раскладке (русской тоже).
struct KeyCodeShortcut: NSViewRepresentable {
    let keyCode: UInt16
    var enabled = true
    let action: () -> Void

    final class Probe: NSView {
        var keyCode: UInt16 = 0
        var enabled = true
        var action: () -> Void = {}
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let m = monitor { NSEvent.removeMonitor(m); monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
                guard let self, self.enabled, e.window === self.window, e.keyCode == self.keyCode,
                      e.modifierFlags.intersection([.command, .control, .option]).isEmpty,
                      !(e.window?.firstResponder is NSTextView) else { return e }
                self.action()
                return nil
            }
        }

        deinit { if let m = monitor { NSEvent.removeMonitor(m) } }
    }

    func makeNSView(context: Context) -> Probe {
        let p = Probe()
        p.keyCode = keyCode; p.enabled = enabled; p.action = action
        return p
    }

    func updateNSView(_ p: Probe, context: Context) {
        p.keyCode = keyCode; p.enabled = enabled; p.action = action
    }
}
