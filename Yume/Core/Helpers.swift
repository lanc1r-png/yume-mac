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

enum Haptics {
    #if os(iOS)
    private static var on: Bool { Settings.bool("set.haptics", true) }
    static func tap() { if on { UIImpactFeedbackGenerator(style: .light).impactOccurred() } }
    static func select() { if on { UISelectionFeedbackGenerator().selectionChanged() } }
    static func success() { if on { UINotificationFeedbackGenerator().notificationOccurred(.success) } }
    static func bump() { if on { UIImpactFeedbackGenerator(style: .medium).impactOccurred() } }
    #else
    // На Mac тактильной отдачи нет.
    static func tap() {}
    static func select() {}
    static func success() {}
    static func bump() {}
    #endif
}

/// Адрес тайтла на сайте (для «Поделиться»).
func titleURL(_ a: Anime) -> URL? {
    guard let slug = a.slugUrl else { return nil }
    switch LibSite.current.key {
    case "ranobe": return URL(string: "https://ranobelib.me/ru/book/\(slug)")
    case "manga": return URL(string: "https://mangalib.me/ru/manga/\(slug)")
    case "hentai": return URL(string: "https://kz.hentailib.me/ru/manga/\(slug)")
    default: return URL(string: "https://animelib.org/ru/anime/\(slug)")
    }
}

struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PressableBody(configuration: configuration)
    }
}

struct PressableBody: View {
    let configuration: PressableStyle.Configuration
    @State private var hover = false

    var body: some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : (hover ? hoverScale : 1))
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
            .animation(.easeOut(duration: 0.15), value: hover)
            .onHover { h in
                hover = h
                if h { NSCursor.pointingHand.set() } else { NSCursor.arrow.set() }
            }
    }

    private var hoverScale: CGFloat {
        #if os(macOS)
        return 1.025
        #else
        return 1
        #endif
    }
}

extension ButtonStyle where Self == PressableStyle {
    static var pressable: PressableStyle { PressableStyle() }
}
