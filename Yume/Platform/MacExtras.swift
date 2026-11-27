import SwiftUI
import AppKit

// MARK: - Наведение на карточку
struct MacHover: ViewModifier {
    var scale: CGFloat = 1.03
    @State private var on = false

    func body(content: Content) -> some View {
        content
            .scaleEffect(on ? scale : 1)
            .shadow(color: .black.opacity(on ? 0.35 : 0), radius: on ? 12 : 0, y: on ? 6 : 0)
            .animation(.easeOut(duration: 0.15), value: on)
            .onHover { on = $0 }
    }
}

extension View {
    /// Карточка слегка увеличивается и отбрасывает тень, когда на неё наведён курсор.
    func macHover(scale: CGFloat = 1.03) -> some View { modifier(MacHover(scale: scale)) }
}

// MARK: - Горизонтальная лента со стрелками
final class RailHolder: ObservableObject {
    weak var view: NSView?
}

struct RailFinder: NSViewRepresentable {
    let holder: RailHolder

    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        holder.view = v
        return v
    }

    func updateNSView(_ v: NSView, context: Context) { holder.view = v }
}

/// Лента, которая листается трекпадом, Shift+колесом и кнопками-стрелками при наведении.
struct HScroll<Content: View>: View {
    private let content: () -> Content
    @StateObject private var holder = RailHolder()
    @State private var hover = false

    init(@ViewBuilder content: @escaping () -> Content) { self.content = content }

    private func scroll(_ dir: CGFloat) {
        guard let sv = holder.view?.enclosingScrollView else { return }
        let clip = sv.contentView
        let docW = sv.documentView?.frame.width ?? 0
        let step = max(300, clip.bounds.width * 0.8)
        let maxX = max(0, docW - clip.bounds.width)
        let x = min(max(0, clip.bounds.origin.x + dir * step), maxX)
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.3
            clip.animator().setBoundsOrigin(NSPoint(x: x, y: clip.bounds.origin.y))
        }
        sv.reflectScrolledClipView(clip)
    }

    private func arrow(_ name: String, _ dir: CGFloat) -> some View {
        Button { scroll(dir) } label: {
            Image(systemName: name)
                .font(.system(size: 15, weight: .bold))
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.2), lineWidth: 0.6))
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
    }

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            content().background(RailFinder(holder: holder))
        }
        .overlay(alignment: .leading) {
            if hover { arrow("chevron.left", -1).transition(.opacity) }
        }
        .overlay(alignment: .trailing) {
            if hover { arrow("chevron.right", 1).transition(.opacity) }
        }
        .onHover { hover = $0 }
        .animation(.easeOut(duration: 0.15), value: hover)
    }
}

// MARK: - Быстрый доступ (закреплённые тайтлы в боковой панели)
struct QuickItem: Codable, Identifiable, Hashable {
    var site: String
    var anime: Anime
    var id: String { "\(site)#\(anime.id)" }
}

@MainActor
final class QuickAccessStore: ObservableObject {
    static let shared = QuickAccessStore()
    @Published private(set) var items: [QuickItem] = []
    private let key = "quick.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([QuickItem].self, from: d) {
            items = v
        }
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }

    private func makeID(_ a: Anime) -> String { "\(LibSite.current.key)#\(a.id)" }

    func contains(_ a: Anime) -> Bool { items.contains { $0.id == makeID(a) } }

    func toggle(_ a: Anime) {
        if let i = items.firstIndex(where: { $0.id == makeID(a) }) {
            items.remove(at: i)
        } else {
            items.append(QuickItem(site: LibSite.current.key, anime: a))
        }
        save()
    }

    func remove(_ item: QuickItem) {
        items.removeAll { $0.id == item.id }
        save()
    }

    func move(from: IndexSet, to: Int, site: String) {
        var mine = items.filter { $0.site == site }
        mine.move(fromOffsets: from, toOffset: to)
        items = items.filter { $0.site != site } + mine
        save()
    }
}
