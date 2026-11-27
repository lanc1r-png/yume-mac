// Слой совместимости: позволяет iOS-коду из hehe-ios компилироваться на macOS почти без правок.
// Всё, что действительно завязано на UIKit (зум, page curl, WebView-обёртки), переписано отдельно.
#if os(macOS)
import SwiftUI
import AppKit
import AVKit
import WebKit
import ObjectiveC

typealias UIColor = NSColor
typealias UIImage = NSImage
typealias UIFont = NSFont
typealias UIEdgeInsets = NSEdgeInsets

enum UIUserInterfaceStyle { case unspecified, light, dark }
struct UITraitCollection { var userInterfaceStyle: UIUserInterfaceStyle }
enum UIImageOrientation { case up }

// MARK: Цвета
extension NSColor {
    /// `UIColor { trait in ... }`: цвет, зависящий от светлой и тёмной темы.
    convenience init(_ provider: @escaping (UITraitCollection) -> NSColor) {
        self.init(name: nil, dynamicProvider: { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return provider(UITraitCollection(userInterfaceStyle: dark ? .dark : .light))
        })
    }
    static var label: NSColor { .labelColor }
    static var secondaryLabel: NSColor { .secondaryLabelColor }
    static var tertiaryLabel: NSColor { .tertiaryLabelColor }
    static var systemBackground: NSColor { .windowBackgroundColor }
    static var secondarySystemBackground: NSColor { .controlBackgroundColor }
    static var systemGroupedBackground: NSColor { .windowBackgroundColor }

    /// Оттенок, насыщенность, яркость: безопасно для любых цветовых пространств.
    var hsb: (h: CGFloat, s: CGFloat, b: CGFloat, a: CGFloat) {
        let c = usingColorSpace(.deviceRGB) ?? self
        var h: CGFloat = 0, s: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getHue(&h, saturation: &s, brightness: &b, alpha: &a)
        return (h, s, b, a)
    }
    var rgba: (r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat) {
        let c = usingColorSpace(.deviceRGB) ?? self
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        c.getRed(&r, green: &g, blue: &b, alpha: &a)
        return (r, g, b, a)
    }
}

extension Color {
    init(uiColor: NSColor) { self.init(nsColor: uiColor) }
}

// MARK: Картинки
extension NSImage {
    convenience init(cgImage: CGImage) {
        self.init(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }
    convenience init(cgImage: CGImage, scale: CGFloat, orientation: UIImageOrientation) {
        let s = max(scale, 1)
        self.init(cgImage: cgImage, size: NSSize(width: CGFloat(cgImage.width) / s, height: CGFloat(cgImage.height) / s))
    }
    convenience init?(systemName: String) {
        self.init(systemSymbolName: systemName, accessibilityDescription: nil)
    }
    var cgImage: CGImage? {
        var rect = CGRect(origin: .zero, size: size)
        return cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
    var scale: CGFloat { 1 }

    func pngData() -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .png, properties: [:])
    }
    func jpegData(compressionQuality q: CGFloat) -> Data? {
        guard let cg = cgImage else { return nil }
        return NSBitmapImageRep(cgImage: cg).representation(using: .jpeg, properties: [.compressionFactor: q])
    }

    /// Кадры анимации (GIF и т.п.) хранятся рядом с картинкой.
    private static var framesKey = 0
    private static var durationKey = 0
    var animationFrames: [NSImage]? {
        get { objc_getAssociatedObject(self, &NSImage.framesKey) as? [NSImage] }
        set { objc_setAssociatedObject(self, &NSImage.framesKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    var animationDuration: Double {
        get { (objc_getAssociatedObject(self, &NSImage.durationKey) as? Double) ?? 0 }
        set { objc_setAssociatedObject(self, &NSImage.durationKey, newValue, .OBJC_ASSOCIATION_RETAIN_NONATOMIC) }
    }
    static func animatedImage(with frames: [NSImage], duration: TimeInterval) -> NSImage? {
        guard let first = frames.first else { return nil }
        let img = NSImage(size: first.size)
        img.addRepresentations(first.representations)
        img.animationFrames = frames
        img.animationDuration = duration
        return img
    }
}

extension Image {
    init(uiImage: NSImage) { self.init(nsImage: uiImage) }
}

// MARK: Буфер обмена, экран, приложение
final class UIPasteboard {
    static let general = UIPasteboard()
    var string: String? {
        get { NSPasteboard.general.string(forType: .string) }
        set {
            NSPasteboard.general.clearContents()
            if let v = newValue { NSPasteboard.general.setString(v, forType: .string) }
        }
    }
}

final class UIScreen {
    static let main = UIScreen()
    var brightness: CGFloat = 1
    var bounds: CGRect { NSScreen.main?.frame ?? CGRect(x: 0, y: 0, width: 1440, height: 900) }
    var traitCollection: UITraitCollection {
        let dark = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
    }
}

struct UIBackgroundTaskIdentifier: Equatable {
    var raw: Int
    static let invalid = UIBackgroundTaskIdentifier(raw: 0)
}

final class UIApplication {
    static let shared = UIApplication()
    private var awake: NSObjectProtocol?
    private var tasks: [Int: NSObjectProtocol] = [:]
    private var nextTask = 1

    var isIdleTimerDisabled: Bool {
        get { awake != nil }
        set {
            if newValue {
                if awake == nil {
                    awake = ProcessInfo.processInfo.beginActivity(
                        options: [.idleDisplaySleepDisabled, .userInitiated], reason: "Yume: чтение и просмотр")
                }
            } else if let a = awake {
                ProcessInfo.processInfo.endActivity(a)
                awake = nil
            }
        }
    }

    func beginBackgroundTask(withName name: String?, expirationHandler: (() -> Void)?) -> UIBackgroundTaskIdentifier {
        let id = nextTask
        nextTask += 1
        tasks[id] = ProcessInfo.processInfo.beginActivity(options: [.userInitiated, .suddenTerminationDisabled],
                                                          reason: name ?? "Yume")
        return UIBackgroundTaskIdentifier(raw: id)
    }
    func endBackgroundTask(_ id: UIBackgroundTaskIdentifier) {
        if let t = tasks.removeValue(forKey: id.raw) { ProcessInfo.processInfo.endActivity(t) }
    }
    func open(_ url: URL) { NSWorkspace.shared.open(url) }
}

// MARK: UIViewRepresentable поверх NSViewRepresentable
protocol UIViewRepresentable: NSViewRepresentable where NSViewType == UIViewType {
    associatedtype UIViewType: NSView
    func makeUIView(context: Context) -> UIViewType
    func updateUIView(_ uiView: UIViewType, context: Context)
    static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator)
}
extension UIViewRepresentable {
    static func dismantleUIView(_ uiView: UIViewType, coordinator: Coordinator) {}
    static func dismantleNSView(_ nsView: UIViewType, coordinator: Coordinator) {
        dismantleUIView(nsView, coordinator: coordinator)
    }
    func makeNSView(context: Context) -> UIViewType { makeUIView(context: context) }
    func updateNSView(_ nsView: UIViewType, context: Context) { updateUIView(nsView, context: context) }
}

protocol UIViewControllerRepresentable: NSViewControllerRepresentable where NSViewControllerType == UIViewControllerType {
    associatedtype UIViewControllerType: NSViewController
    func makeUIViewController(context: Context) -> UIViewControllerType
    func updateUIViewController(_ uiViewController: UIViewControllerType, context: Context)
}
extension UIViewControllerRepresentable {
    func makeNSViewController(context: Context) -> UIViewControllerType { makeUIViewController(context: context) }
    func updateNSViewController(_ nsViewController: UIViewControllerType, context: Context) {
        updateUIViewController(nsViewController, context: context)
    }
}

// MARK: SwiftUI-модификаторы, которых нет на macOS
enum NavigationBarTitleDisplayModeShim { case automatic, inline, large }
enum StatusBarShim { case hidden, visible }

struct TextInputAutocapitalization {
    static let never = TextInputAutocapitalization()
    static let words = TextInputAutocapitalization()
    static let sentences = TextInputAutocapitalization()
    static let characters = TextInputAutocapitalization()
}
enum UIKeyboardType { case `default`, URL, numberPad, emailAddress, decimalPad, numbersAndPunctuation, webSearch }

struct PageTabViewStyle {
    enum IndexDisplayMode { case automatic, always, never }
}
extension TabViewStyle where Self == DefaultTabViewStyle {
    static func page(indexDisplayMode: PageTabViewStyle.IndexDisplayMode = .automatic) -> DefaultTabViewStyle { .automatic }
}

extension View {
    func navigationBarTitleDisplayMode(_ mode: NavigationBarTitleDisplayModeShim) -> some View { self }
    func textInputAutocapitalization(_ c: TextInputAutocapitalization?) -> some View { self }
    func keyboardType(_ t: UIKeyboardType) -> some View { self }
    func statusBarHidden(_ hidden: Bool = true) -> some View { self }
    func persistentSystemOverlays(_ v: Visibility) -> some View { self }
    func fullScreenCover<C: View>(isPresented: Binding<Bool>, onDismiss: (() -> Void)? = nil,
                                  @ViewBuilder content: @escaping () -> C) -> some View {
        hostWindow(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }
    func fullScreenCover<I: Identifiable, C: View>(item: Binding<I?>, onDismiss: (() -> Void)? = nil,
                                                   @ViewBuilder content: @escaping (I) -> C) -> some View {
        hostWindow(item: item, onDismiss: onDismiss, content: content)
    }
}

extension ToolbarItemPlacement {
    static var topBarLeading: ToolbarItemPlacement { .navigation }
    static var topBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var navigationBarLeading: ToolbarItemPlacement { .navigation }
    static var navigationBarTrailing: ToolbarItemPlacement { .primaryAction }
    static var bottomBar: ToolbarItemPlacement { .automatic }
}

extension NSColor {
    static var secondarySystemGroupedBackground: NSColor { .controlBackgroundColor }
    static var tertiarySystemBackground: NSColor { .underPageBackgroundColor }
}

// MARK: WKWebView: свойства UIKit, которых нет в AppKit
final class WKScrollShim { var isScrollEnabled = true }

extension WKWebView {
    func setOpaque(_ opaque: Bool) { setValue(opaque, forKey: "drawsBackground") }
    var backgroundColor: NSColor? {
        get { nil }
        set { wantsLayer = true; layer?.backgroundColor = newValue?.cgColor }
    }
    var scrollView: WKScrollShim { WKScrollShim() }
    var alpha: CGFloat {
        get { alphaValue }
        set { alphaValue = newValue }
    }
    var isUserInteractionEnabled: Bool {
        get { true }
        set {}
    }
}

extension WKWebViewConfiguration {
    var allowsInlineMediaPlayback: Bool { get { true } set {} }
    var allowsPictureInPictureMediaPlayback: Bool { get { true } set {} }
}

/// Скрытые WebView (Cloudflare, сниффер потока) живут в невидимом окне, как на iOS живут в окне приложения.
enum HiddenWebHost {
    private static var window: NSWindow?
    static func attach(_ v: NSView) {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: -4000, y: -4000, width: 400, height: 300),
                             styleMask: [.borderless], backing: .buffered, defer: false)
            w.isReleasedWhenClosed = false
            w.alphaValue = 0
            w.ignoresMouseEvents = true
            w.hasShadow = false
            w.orderBack(nil)
            window = w
        }
        window?.contentView?.addSubview(v)
    }
}

extension ToolbarPlacement {
    static var navBar: ToolbarPlacement { .windowToolbar }
}
#endif
