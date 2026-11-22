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

// MARK: - Ранобэ: читалка
func readerPalette(_ id: String) -> (bg: UIColor, fg: UIColor) {
    switch id {
    case "sepia": return (UIColor(red: 0.96, green: 0.93, blue: 0.85, alpha: 1), UIColor(red: 0.23, green: 0.18, blue: 0.18, alpha: 1))
    case "light": return (.white, UIColor(white: 0.1, alpha: 1))
    case "black": return (.black, UIColor(white: 0.85, alpha: 1))
    case "quiet": return (UIColor(white: 0.27, alpha: 1), UIColor(white: 0.72, alpha: 1))
    case "paper": return (UIColor(white: 0.93, alpha: 1), UIColor(white: 0.12, alpha: 1))
    case "accent": return (.white, .black)
    case "focus": return (UIColor(red: 0.99, green: 0.98, blue: 0.95, alpha: 1), UIColor(white: 0.1, alpha: 1))
    default: return (UIColor(white: 0.07, alpha: 1), UIColor(white: 0.9, alpha: 1))
    }
}

func readerThemeIsDark(_ id: String) -> Bool { id == "dark" || id == "black" || id == "quiet" }

/// Панель «Темы и настройки» в стиле Apple Books.
struct NovelReaderSettings: View {
    @Binding var fontSize: Double
    @Binding var lineGap: Double
    @Binding var serif: Bool
    @Binding var family: String
    @Binding var bold: Bool
    @Binding var theme: String
    @Binding var margin: Double
    @Binding var justify: Bool
    @Binding var indent: Bool
    @Binding var dim: Double
    @Binding var warm: Double
    @Binding var mode: String
    @Binding var anim: String
    let activeTheme: String
    let canSearch: Bool
    let downloaded: Bool
    let onSearch: () -> Void
    let onBookmarks: () -> Void
    let onDownload: () -> Void

    struct Snap {
        var fs = 18.0, lg = 0.4, serif = true, family = "", bold = false, margin = 24.0
        var justify = false, indent = false, theme = "dark", mode = "pages", anim = "book"
        var dim = 0.0, warm = 0.0
    }

    @State private var lg = 0.4
    @State private var mg = 24.0
    @State private var brightness = Double(UIScreen.main.brightness)
    @State private var showCustom = false
    @State private var layoutOn = false
    @State private var snap = Snap()
    @Environment(\.dismiss) private var dismiss

    private var isDark: Bool { readerThemeIsDark(activeTheme) }
    private var boldOn: Bool { bold || activeTheme == "accent" }
    private let glass = Color.primary.opacity(0.08)

    private let tiles: [(id: String, title: String, serif: Bool, bold: Bool)] = [
        ("light", "Оригинал", false, false), ("quiet", "Тишина", true, false), ("paper", "Бумага", false, false),
        ("accent", "Акцент", false, true), ("sepia", "Покой", true, false), ("focus", "Фокус", true, false)
    ]

    private let fonts: [(id: String, title: String)] = [
        ("orig", "Исходный"), ("sans", "Без засечек"), ("Georgia", "Georgia"), ("Palatino-Roman", "Palatino"),
        ("IowanOldStyle-Roman", "Iowan Old Style"), ("Charter-Roman", "Charter"), ("AvenirNext-Regular", "Avenir Next")
    ]

    // MARK: главная панель

    var body: some View {
        VStack(spacing: 18) {
            HStack(spacing: 12) {
                Button { dismiss() } label: { roundIcon("xmark") }.buttonStyle(.plain)
                Text("Темы и настройки").font(.headline)
                Spacer()
            }

            HStack(spacing: 12) {
                HStack(spacing: 0) {
                    Button { step(-1) } label: {
                        Text("A").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    }
                    Divider().frame(height: 28)
                    Button { step(1) } label: {
                        Text("A").font(.system(size: 28, weight: .semibold)).frame(maxWidth: .infinity, minHeight: 50)
                    }
                }
                .buttonStyle(.plain)
                .foregroundStyle(.primary)
                .background(glass, in: Capsule())

                HStack(spacing: 0) {
                    modeMenu
                    appearanceMenu
                }
                .frame(width: 150)
                .background(glass, in: Capsule())
            }


            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                ForEach(tiles, id: \.id) { tile($0) }
            }

            Button {
                snap = Snap(fs: fontSize, lg: lineGap, serif: serif, family: family, bold: bold, margin: margin,
                            justify: justify, indent: indent, theme: theme, mode: mode, anim: anim,
                            dim: dim, warm: warm)
                showCustom = true
            } label: {
                Label("Настроить", systemImage: "gearshape")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(maxWidth: .infinity, minHeight: 54)
                    .foregroundStyle(.primary)
                    .background(glass, in: Capsule())
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .padding(.bottom, 10)
        .frame(maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(isDark ? .dark : .light)
        .presentationDetents([.height(610)])
        .presentationDragIndicator(.hidden)
        .onAppear { lg = lineGap; mg = margin }
        .macSheet(isPresented: $showCustom) { customize }
    }

    private func roundIcon(_ name: String) -> some View {
        Image(systemName: name)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 46, height: 46)
            .glassShape(Circle())
    }

    private func step(_ d: Double) {
        let v = min(34, max(12, fontSize + d))
        if v != fontSize { fontSize = v; Haptics.select() }
    }

    private func tile(_ t: (id: String, title: String, serif: Bool, bold: Bool)) -> some View {
        let p = readerPalette(t.id)
        let on = activeTheme == t.id
        return Button {
            Haptics.select()
            theme = t.id
        } label: {
            VStack(spacing: 4) {
                Text("Aa").font(.system(size: 40, weight: t.bold ? .bold : .regular, design: t.serif ? .serif : .default))
                Text(t.title).font(.system(size: 15, weight: .medium, design: t.serif ? .serif : .default))
            }
            .foregroundStyle(Color(p.fg))
            .frame(maxWidth: .infinity, minHeight: 112)
            .background(Color(p.bg), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.primary, lineWidth: on ? 3.5 : 0))
        }
        .buttonStyle(.plain)
    }

    private var modeMenu: some View {
        Menu {
            Picker("Режим чтения", selection: $mode) {
                Label("Горизонтально", systemImage: "rectangle.split.2x1").tag("pages")
                Label("Вертикально", systemImage: "rectangle.split.1x2").tag("scroll")
            }
            if mode == "pages" {
                Menu {
                    Picker("Листание", selection: $anim) {
                        Text("Сдвиг").tag("slide")
                        Text("Плавно").tag("fade")
                        Text("Как в книге").tag("book")
                    }
                } label: {
                    Label("Анимация листания", systemImage: "book")
                }
            }
        } label: {
            Image(systemName: "doc.plaintext")
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    private var appearance: String {
        switch theme {
        case "auto", "ambient", "black": return theme
        case "dark", "quiet": return "dark"
        default: return "light"
        }
    }

    private var appearanceIcon: String {
        switch appearance {
        case "dark", "black": return "moon.stars"
        case "auto": return "circle.lefthalf.filled"
        case "ambient": return "sun.max"
        default: return "sunrise"
        }
    }

    private var appearanceMenu: some View {
        Menu {
            Picker("Оформление", selection: Binding(get: { appearance }, set: { v in
                switch v {
                case "light":
                    if readerThemeIsDark(theme) || theme == "auto" || theme == "ambient" { theme = "light" }
                case "dark":
                    if theme != "quiet" { theme = "dark" }
                default:
                    theme = v
                }
            })) {
                Label("Светлая", systemImage: "sunrise").tag("light")
                Label("Тёмная", systemImage: "moon.stars").tag("dark")
                Label("Чёрная (AMOLED)", systemImage: "moon.fill").tag("black")
                Label("Как на устройстве", systemImage: "circle.lefthalf.filled").tag("auto")
                Label("Как вокруг", systemImage: "sun.max").tag("ambient")
            }
        } label: {
            Image(systemName: appearanceIcon)
                .font(.system(size: 22))
                .foregroundStyle(.primary)
                .frame(maxWidth: .infinity, minHeight: 50)
        }
    }

    // MARK: экран «Настройка темы»

    private var fontChoice: Binding<String> {
        Binding(get: { family.isEmpty ? (serif ? "orig" : "sans") : family },
                set: { v in
                    switch v {
                    case "orig": serif = true; family = ""
                    case "sans": serif = false; family = ""
                    default: family = v
                    }
                })
    }

    private var fontTitle: String { fonts.first { $0.id == fontChoice.wrappedValue }?.title ?? "Исходный" }

    private func previewFont(_ size: CGFloat) -> Font {
        let w: Font.Weight = boldOn ? .semibold : .regular
        if !family.isEmpty { return Font.custom(family, size: size).weight(w) }
        return .system(size: size, weight: w, design: serif ? .serif : .default)
    }

    private func sectionTitle(_ t: String) -> some View {
        Text(t).font(.title3.weight(.bold)).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
    }

    private func card<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func toggleRow(_ title: String, icon: String? = nil, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 14) {
            if let icon { Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 26) }
            Toggle(title, isOn: on).tint(Theme.accent)
        }
        .font(.system(size: 17))
        .frame(minHeight: 54)
    }

    private func sliderRow(_ title: String, _ v: Binding<Double>, _ range: ClosedRange<Double>, step: Double? = nil,
                           _ fmt: String, commit: (() -> Void)? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 16))
                Spacer()
                Text(fmt).font(.system(size: 15).monospacedDigit()).foregroundStyle(.secondary)
            }
            if let step {
                Slider(value: v, in: range, step: step) { if !$0 { commit?() } }.tint(Theme.accent)
            } else {
                Slider(value: v, in: range) { if !$0 { commit?() } }.tint(Theme.accent)
            }
        }
        .padding(.vertical, 10)
    }

    private func actionRow(_ title: String, _ icon: String, enabled: Bool = true, tint: Color = .primary,
                           _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 14) {
                Image(systemName: icon).font(.system(size: 18, weight: .semibold)).frame(width: 26)
                Text(title).font(.system(size: 17))
                Spacer()
            }
            .foregroundStyle(enabled ? tint : Color.secondary)
            .frame(minHeight: 54)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }

    private func restore() {
        fontSize = snap.fs; lineGap = snap.lg; serif = snap.serif; family = snap.family; bold = snap.bold
        margin = snap.margin; justify = snap.justify; indent = snap.indent; theme = snap.theme
        mode = snap.mode; anim = snap.anim; dim = snap.dim; warm = snap.warm
        lg = snap.lg; mg = snap.margin
    }

    private func reset() {
        fontSize = 18; lineGap = 0.4; serif = true; family = ""; bold = false
        margin = 24; justify = false; indent = false; theme = "auto"
        dim = 0; warm = 0
        lg = 0.4; mg = 24
    }

    private var customize: some View {
        let p = readerPalette(activeTheme)
        return VStack(spacing: 0) {
            ZStack {
                Text("Настройка темы").font(.headline)
                HStack {
                    Button { restore(); showCustom = false } label: { roundIcon("xmark") }.buttonStyle(.plain)
                    Spacer()
                    Button { showCustom = false } label: {
                        Image(systemName: "checkmark")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color(.systemBackground))
                            .frame(width: 46, height: 46)
                            .background(Color.primary, in: Circle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 10)

            ScrollView {
                VStack(spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Aa").font(.system(size: 46, weight: .bold)).padding(.leading, 4)
                        Text("Жизнь — странная штука, однако: никогда не знаешь, чего от нее ждать… Достаточно подружиться с одной красавицей, как все твои лучшие друзья в одночасье")
                            .font(previewFont(min(CGFloat(fontSize), 24)))
                            .lineSpacing(min(CGFloat(fontSize), 24) * CGFloat(lg))
                            .foregroundStyle(Color(p.fg))
                            .padding(14)
                            .frame(maxWidth: .infinity, minHeight: 150, maxHeight: 150, alignment: .topLeading)
                            .background(Color(p.bg), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .clipped()
                    }

                    sectionTitle("Текст")
                    card {
                        Menu {
                            Picker("Шрифт", selection: fontChoice) {
                                ForEach(fonts, id: \.id) { Text($0.title).tag($0.id) }
                            }
                        } label: {
                            HStack(spacing: 14) {
                                Text("Aa").font(.system(size: 18, weight: .semibold)).frame(width: 26)
                                Text("Шрифт").font(.system(size: 17))
                                Spacer()
                                Text(fontTitle).foregroundStyle(.secondary)
                                Image(systemName: "chevron.right").font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 54)
                        }
                        Divider().padding(.leading, 40)
                        toggleRow("Жирный шрифт", icon: "bold", $bold)
                    }

                    sectionTitle("Универсальный доступ и макет")
                    card {
                        toggleRow("Настроить", $layoutOn.animation())
                        if layoutOn {
                            Divider()
                            sliderRow("Межстрочный интервал", $lg, 0.15...0.9, "\(Int(lg * 100))%") { lineGap = lg }
                            Divider()
                            sliderRow("Поля", $mg, 8...48, step: 2, "\(Int(mg))") { margin = mg }
                            Divider()
                            toggleRow("Выравнивание по ширине", $justify)
                            Divider()
                            toggleRow("Красная строка", $indent)
                        }
                    }
                    if layoutOn {
                        Text("Выравнивание и красная строка работают при горизонтальном чтении.")
                            .font(.footnote).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 6)
                            .offset(y: -10)
                    }

                    sectionTitle("Режим чтения")
                    card {
                        VStack(spacing: 12) {
                            Picker("", selection: $mode) {
                                Text("Горизонтально").tag("pages")
                                Text("Вертикально").tag("scroll")
                            }
                            .pickerStyle(.segmented)
                            if mode == "pages" {
                                Picker("", selection: $anim) {
                                    Text("Сдвиг").tag("slide")
                                    Text("Плавно").tag("fade")
                                    Text("Как в книге").tag("book")
                                }
                                .pickerStyle(.segmented)
                            }
                        }
                        .padding(.vertical, 14)
                    }

                    sectionTitle("Экран")
                    card {
                        sliderRow("Затемнение", $dim, 0...0.7, "\(Int(dim * 100))%")
                        Divider()
                        sliderRow("Тёплый свет", $warm, 0...0.5, "\(Int(warm * 200))%")
                    }

                    sectionTitle("Глава")
                    card {
                        actionRow("Поиск по главе", "magnifyingglass", enabled: canSearch) {
                            showCustom = false
                            onSearch()
                        }
                        Divider().padding(.leading, 40)
                        actionRow("Закладки и заметки", "bookmark") {
                            showCustom = false
                            onBookmarks()
                        }
                        Divider().padding(.leading, 40)
                        actionRow(downloaded ? "Удалить главу с телефона" : "Скачать главу",
                                  downloaded ? "trash" : "arrow.down.circle",
                                  tint: downloaded ? .red : .primary) {
                            onDownload()
                            Haptics.tap()
                        }
                    }

                    Button(role: .destructive) { reset() } label: {
                        Text("Сбросить тему")
                            .font(.system(size: 17))
                            .frame(maxWidth: .infinity, minHeight: 54)
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.red)
                    .padding(.bottom, 20)
                }
                .padding(.horizontal, 16)
            }
        }
        .background(Color(.systemGroupedBackground).ignoresSafeArea())
        .preferredColorScheme(isDark ? .dark : .light)
        .presentationDetents([.large])
    }
}

/// Номер видимого абзаца в ленте ранобэ (ссылочный тип, чтобы не вызывать перерисовку).
final class BlockTracker {
    var value = -1
    var pending: DispatchWorkItem?
    func reset() { pending?.cancel(); pending = nil; value = -1 }
}

struct NovelReaderView: View {
    let novel: Anime
    let chapters: [NovelChapter]
    @State private var index: Int
    @State private var blocks: [ReaderBlock] = []
    @State private var loading = true
    @State private var error: String?
    @State private var debug = ""
    @AppStorage("reader.font") private var fontSize = 18.0
    @AppStorage("reader.theme") private var theme = "dark"
    @AppStorage("reader.serif") private var serif = true
    @AppStorage("reader.family") private var family = ""
    @AppStorage("reader.bold") private var bold = false
    @AppStorage("reader.lh") private var lineGap = 0.4
    @AppStorage("reader.margin") private var margin = 24.0
    @AppStorage("reader.justify") private var justify = false
    @AppStorage("reader.indent") private var indentOn = false
    @AppStorage("reader.dim") private var dimV = 0.0
    @AppStorage("reader.warm") private var warmV = 0.0
    @State private var showReaderSettings = false
    @AppStorage("novel.mode") private var mode = "pages"
    @State private var historyTask: Task<Void, Never>?
    @State private var showBookmarks = false
    @State private var showSearch = false
    @State private var pendingSel: ReaderSelection?
    @State private var noteFor: NoteRequest?
    @State private var lastLongPress = Date.distantPast
    @State private var pendingOffset: Int?
    @State private var restoreBlock: Int?
    /// Видимый абзац хранится вне состояния экрана: его смена не пересчитывает всю читалку.
    @State private var blockTracker = BlockTracker()
    private var visibleBlock: Int { blockTracker.value }
    @State private var hlRev = 0
    @ObservedObject private var bms = BookmarkStore.shared
    @ObservedObject private var hls = HighlightStore.shared
    @AppStorage("novel.anim") private var novelAnim = "book"
    @State private var pages: [NovelPage] = []
    @State private var pageIndex = 0
    @State private var paginating = false
    @State private var chromeHidden = false
    @ObservedObject private var store = OfflineStore.shared
    @Environment(\.hostDismiss) private var dismiss

    init(novel: Anime, chapters: [NovelChapter], start: Int) {
        self.novel = novel
        self.chapters = chapters
        _index = State(initialValue: min(max(start, 0), max(chapters.count - 1, 0)))
    }

    private var activeTheme: String {
        if theme == "ambient" { return UIScreen.main.brightness < 0.35 ? "dark" : "light" }
        if theme == "auto" {
            switch UserDefaults.standard.string(forKey: "set.theme") ?? "system" {
            case "light": return "light"
            case "dark": return "dark"
            default: return UIScreen.main.traitCollection.userInterfaceStyle == .dark ? "dark" : "light"
            }
        }
        return theme
    }

    private var bg: Color { Color(readerPalette(activeTheme).bg) }
    private var fg: Color { Color(readerPalette(activeTheme).fg) }

    private var readMinutes: Int {
        var n = 0
        for b in blocks {
            switch b {
            case .paragraph(_, let t), .heading(_, let t), .quote(_, let t):
                n += t.split(separator: " ").count
            case .rich(_, let t):
                n += String(t.characters).split(separator: " ").count
            default:
                break
            }
        }
        return max(1, Int((Double(n) / 180).rounded()))
    }

    private var boldOn: Bool { bold || activeTheme == "accent" }
    private func rf(_ size: CGFloat, heavy: Bool = false) -> Font {
        let w: Font.Weight = heavy ? .bold : (boldOn ? .semibold : .regular)
        if !family.isEmpty { return Font.custom(family, size: size).weight(w) }
        return .system(size: size, weight: w, design: serif ? .serif : .default)
    }
    private var bodyFont: Font { rf(fontSize) }

    private var fgUI: UIColor { readerPalette(activeTheme).fg }

    private var windowInsets: UIEdgeInsets {
        return UIEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    }

    private func pageMargins() -> UIEdgeInsets {
        let ins = windowInsets
        return UIEdgeInsets(top: ins.top + 58, left: CGFloat(margin), bottom: ins.bottom + 76, right: CGFloat(margin))
    }

    private func textSize(_ full: CGSize, _ m: UIEdgeInsets) -> CGSize {
        CGSize(width: max(full.width - m.left - m.right, 50), height: max(full.height - m.top - m.bottom, 50))
    }

    private func turn(_ delta: Int) {
        let n = pageIndex + delta
        guard n >= 0, n <= pages.count else { return }
        withAnimation(.easeOut(duration: 0.2)) { pageIndex = n }
    }

    private func handleTap(_ x: CGFloat) {
        // после долгого нажатия палец отпускается: этот «тап» игнорируем
        if Date().timeIntervalSince(lastLongPress) < 0.8 { return }
        if x < 0.3 { turn(-1) }
        else if x > 0.7 { turn(1) }
        else { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
    }

    private var chapterID: Int { chapters.indices.contains(index) ? chapters[index].id : 0 }

    /// Абзац показался на экране: запоминаем его и сохраняем позицию с небольшой паузой.
    private func blockSeen(_ id: Int) {
        guard blockTracker.value != id else { return }
        blockTracker.value = id
        blockTracker.pending?.cancel()
        let work = DispatchWorkItem { persistPos() }
        blockTracker.pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    /// Запоминает место в главе: страницы (смещение в тексте) или прокрутка (номер блока).
    private func persistPos() {
        guard chapters.indices.contains(index), !loading, !paginating else { return }
        let now = Int(Date().timeIntervalSince1970)
        if mode == "pages" {
            guard pendingOffset == nil, !pages.isEmpty, let r = pageRange(pageIndex) else { return }
            let pct = pages.count > 1 ? min(100, pageIndex * 100 / (pages.count - 1)) : 0
            ReadPosStore.shared.set(novel.readKey, ReadPos(c: chapterID, p: r.0, b: 0, pct: pct, t: now))
        } else {
            guard restoreBlock == nil, visibleBlock >= 0, !blocks.isEmpty else { return }
            let b = max(visibleBlock - 3, 0)
            let pct = min(100, b * 100 / max(blocks.count - 1, 1))
            ReadPosStore.shared.set(novel.readKey, ReadPos(c: chapterID, p: 0, b: b, pct: pct, t: now))
        }
    }

    private var chapterLabel: String {
        chapters.indices.contains(index) ? "Том \(chapters[index].volume) · \(chapters[index].title)" : ""
    }

    /// Диапазон символов главы, который занимает страница.
    private func pageRange(_ i: Int) -> (Int, Int)? {
        guard i >= 0, i < pages.count, case .text(_, let t) = pages[i], t.length > 0,
              let b = t.attribute(.heheBase, at: 0, effectiveRange: nil) as? Int else { return nil }
        return (b, b + t.length)
    }

    private func pageFor(offset: Int) -> Int? {
        for i in 0..<pages.count {
            if let r = pageRange(i), offset >= r.0, offset < r.1 { return i }
        }
        return nil
    }

    private var currentBookmark: Bookmark? {
        guard let r = pageRange(pageIndex) else { return nil }
        return bms.find(titleKey: novel.readKey, chapterID: chapterID, from: r.0, to: r.1)
    }

    private func toggleBookmark() {
        guard let r = pageRange(pageIndex), case .text(_, let t) = pages[pageIndex] else {
            Haptics.tap()
            return
        }
        if let b = currentBookmark {
            bms.remove(b.id)
            Haptics.tap()
            return
        }
        let snip = String(t.string.trimmingCharacters(in: .whitespacesAndNewlines).prefix(110))
        bms.add(Bookmark(titleKey: novel.readKey, chapterID: chapterID, chapterLabel: chapterLabel,
                         position: r.0, isText: true, snippet: snip, note: "", created: Date()))
        Haptics.success()
    }

    private func jumpTo(offset: Int, chapterID cid: Int) {
        guard let ci = chapters.firstIndex(where: { $0.id == cid }) else { return }
        if mode != "pages" { mode = "pages" }
        if ci == index {
            if let p = pageFor(offset: offset) { withAnimation { pageIndex = p } }
        } else {
            pendingOffset = offset
            index = ci
        }
    }

    private func handleLong(_ r: NSRange, _ text: String) {
        lastLongPress = Date()
        Haptics.bump()
        pendingSel = ReaderSelection(range: r, text: text)
    }

    private func applyHighlight(_ sel: ReaderSelection, color: Int) {
        hls.set(titleKey: novel.readKey, chapterID: chapterID, label: chapterLabel,
                range: sel.range, snippet: sel.text, color: color, note: nil)
        hlRev += 1
        Haptics.success()
    }

    private func removeHighlight(_ sel: ReaderSelection) {
        if let h = hls.exact(novel.readKey, chapterID, sel.range) {
            hls.remove(h.id)
            hlRev += 1
        }
    }

    private func openNote(_ sel: ReaderSelection) {
        let existing = hls.exact(novel.readKey, chapterID, sel.range)
        let key = novel.readKey, cid = chapterID, label = chapterLabel
        noteFor = NoteRequest(title: String(sel.text.prefix(140)), initial: existing?.note ?? "") { text in
            hls.set(titleKey: key, chapterID: cid, label: label, range: sel.range, snippet: sel.text,
                    color: existing?.color ?? 0, note: text)
            hlRev += 1
        }
    }

    private func paginate(_ full: CGSize) async {
        guard !loading, !blocks.isEmpty, chapters.indices.contains(index), full.width > 100 else {
            pages = []
            return
        }
        paginating = true
        let m = pageMargins()
        let size = textSize(full, m)
        let list = blocks
        let title = chapters[index].title
        let fs = CGFloat(fontSize), sf = serif, lg = CGFloat(lineGap), col = fgUI
        let al: NSTextAlignment = justify ? .justified : .natural
        let ind: CGFloat = indentOn ? CGFloat(fontSize) * 1.4 : 0
        let fam = family, ab = boldOn
        let result = await Task.detached(priority: .userInitiated) {
            NovelPaginator.paginate(blocks: list, title: title, size: size, fontSize: fs,
                                    serif: sf, lineGap: lg, color: col, bodyAlign: al, firstIndent: ind,
                                    family: fam, allBold: ab)
        }.value
        if Task.isCancelled { return }
        let old = pages.count
        pages = result
        pageIndex = old > 0 ? min(Int(Double(pageIndex) / Double(old) * Double(result.count)), max(result.count - 1, 0)) : 0
        if let off = pendingOffset {
            if let p = pageFor(offset: off) { pageIndex = p }
            pendingOffset = nil
        }
        paginating = false
    }

    private var endPage: some View {
        VStack(spacing: 16) {
            Text(index + 1 < chapters.count ? "Глава закончилась" : "Это последняя глава")
                .font(.subheadline).opacity(0.7)
            if index + 1 < chapters.count {
                Button { Haptics.tap(); index += 1 } label: {
                    Text("Следующая глава")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                        .foregroundStyle(.white)
                }
                .buttonStyle(.pressable)
            }
        }
        .foregroundStyle(fg)
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(bg.ignoresSafeArea())
    }

    @ViewBuilder
    private func pageContent(_ i: Int, margins m: UIEdgeInsets) -> some View {
        if i < pages.count {
            NovelPageCard(page: pages[i], number: i + 1, total: pages.count, bg: bg, fg: fg,
                          margins: m, onTap: handleTap,
                          highlights: hls.forChapter(novel.readKey, chapterID),
                          onLongPress: { r, s in handleLong(r, s) })
        } else {
            endPage
        }
    }

    @ViewBuilder
    private var pagedBody: some View {
        GeometryReader { geo in
            let m = pageMargins()
            ZStack {
                bg
                if loading || paginating {
                    ProgressView()
                } else if let e = error {
                    Text(e).font(.footnote).foregroundStyle(.orange).padding(24)
                } else if !pages.isEmpty {
                    let count = pages.count + 1
                    switch novelAnim {
                    case "book":
                        BookPager(count: count, current: $pageIndex, backColor: UIColor(bg),
                                  themedBack: true) { i in AnyView(pageContent(i, margins: m)) }
                    case "fade":
                        ZStack {
                            pageContent(pageIndex, margins: m)
                                .id(pageIndex)
                                .transition(.asymmetric(insertion: .opacity.combined(with: .scale(scale: 1.03)),
                                                        removal: .opacity))
                        }
                        .animation(.easeInOut(duration: 0.25), value: pageIndex)
                        .gesture(
                            DragGesture(minimumDistance: 30).onEnded { v in
                                let dx = v.translation.width
                                guard abs(dx) > 60, abs(dx) > abs(v.translation.height) else { return }
                                turn(dx < 0 ? 1 : -1)
                            }
                        )
                    default:
                        TabView(selection: $pageIndex) {
                            ForEach(0..<count, id: \.self) { i in
                                pageContent(i, margins: m).tag(i)
                            }
                        }
                        .tabViewStyle(.page(indexDisplayMode: .never))
                    }
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .id("\(index)-\(novelAnim)-\(activeTheme)-\(hlRev)")
            .task(id: "\(index)-\(loading)-\(blocks.count)-\(fontSize)-\(serif)-\(family)-\(boldOn)-\(lineGap)-\(margin)-\(justify)-\(indentOn)-\(activeTheme)-\(Int(geo.size.width))x\(Int(geo.size.height))") {
                await paginate(geo.size)
            }
        }
        .ignoresSafeArea()
        .onAppear { if mode == "pages" { chromeHidden = true } }
    }

    @ViewBuilder
    private func blockView(_ b: ReaderBlock) -> some View {
        switch b {
        case .paragraph(_, let t):
            Text(t).font(bodyFont).lineSpacing(fontSize * lineGap)
        case .rich(_, let t):
            Text(t).font(bodyFont).lineSpacing(fontSize * lineGap)
        case .heading(_, let t):
            Text(t).font(rf(fontSize + 4, heavy: true))
        case .quote(_, let t):
            Text(t).font(bodyFont.italic()).lineSpacing(fontSize * lineGap)
                .padding(.leading, 12)
                .overlay(alignment: .leading) { Rectangle().fill(Theme.accent).frame(width: 3) }
        case .image(_, let u):
            FitImage(url: u).frame(maxWidth: .infinity)
        case .rule:
            Divider()
        }
    }

    var body: some View {
        NavigationStack {
            Group {
            if mode == "scroll" {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: fontSize * (0.5 + lineGap)) {
                        Color.clear.frame(height: 1).id("top")
                        if chapters.indices.contains(index) {
                            Text(chapters[index].title)
                                .font(rf(fontSize + 6, heavy: true))
                        }
                        if !loading && !blocks.isEmpty {
                            Text("≈ \(readMinutes) мин чтения")
                                .font(.caption)
                                .opacity(0.55)
                        }
                        if loading { ProgressView().frame(maxWidth: .infinity).padding(.top, 40) }
                        ForEach(blocks) { b in blockView(b).id(b.id).onAppear { blockSeen(b.id) } }
                        if let e = error {
                            Text(e).font(.footnote).foregroundStyle(.orange)
                        }
                        if !debug.isEmpty {
                            Text(debug)
                                .font(.system(size: 9, design: .monospaced))
                                .textSelection(.enabled)
                                .opacity(0.6)
                        }
                        if !loading, index < chapters.count - 1 {
                            Button {
                                index += 1
                            } label: {
                                Text("Следующая глава")
                                    .font(.subheadline.weight(.semibold))
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 12)
                                    .background(Theme.accent.opacity(0.25), in: Capsule())
                            }
                            .padding(.top, 16)
                        }
                        Color.clear.frame(height: 90)
                    }
                    .frame(maxWidth: 700, alignment: .leading)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, CGFloat(margin))
                    .padding(.top, 8)
                    .foregroundStyle(fg)
                    .contentShape(Rectangle())
                    .onTapGesture { withAnimation(.easeInOut(duration: 0.2)) { chromeHidden.toggle() } }
                }
                .background(bg.ignoresSafeArea())
                .onChange(of: index) { _, _ in proxy.scrollTo("top", anchor: .top) }
                .onChange(of: loading) { _, l in
                    if !l, let b = restoreBlock {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                            proxy.scrollTo(b, anchor: .top)
                            restoreBlock = nil
                        }
                    }
                }
            }
            } else {
                pagedBody
            }
            }
            .task(id: index) { await load() }
            .overlay {
                if !chromeHidden {
                    VStack(spacing: 0) {
                        EdgeBlur(top: true, height: windowInsets.top + 64)
                        Spacer(minLength: 0)
                        EdgeBlur(top: false, height: windowInsets.bottom + 84)
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
            }
            .safeAreaInset(edge: .bottom) {
                if !chromeHidden {
                HStack {
                    Button { Haptics.tap(); index -= 1 } label: { Image(systemName: "chevron.left").frame(width: 44, height: 40) }
                        .disabled(index <= 0)
                    Spacer()
                    Text("\(index + 1) из \(chapters.count)").font(.footnote.weight(.semibold))
                    Spacer()
                    Button { Haptics.tap(); index += 1 } label: { Image(systemName: "chevron.right").frame(width: 44, height: 40) }
                        .disabled(index >= chapters.count - 1)
                }
                .padding(.horizontal, 12).padding(.vertical, 6)
                .liquidGlass(Capsule())
                .foregroundStyle(fg)
                .padding(.horizontal, 24).padding(.bottom, 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .toolbar(chromeHidden ? .hidden : .visible, for: .navBar)
            .onChange(of: pageIndex) { _, _ in persistPos() }
            .background {
                ZStack {
                    KeyShortcut(.leftArrow) { turn(-1) }
                    KeyShortcut(.rightArrow) { turn(1) }
                    KeyShortcut(.space) { turn(1) }
                }
                .disabled(mode != "pages" || loading || paginating || showReaderSettings || showBookmarks || showSearch)
                KeyShortcut(.escape) { dismiss() }
                    .disabled(showReaderSettings || showBookmarks || showSearch)
            }
            .statusBarHidden(chromeHidden)
            .navigationTitle(novel.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(readerThemeIsDark(activeTheme) ? .dark : .light, for: .navBar)
            .modifier(ReaderBarBackground())
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    if mode == "pages" {
                        Button { toggleBookmark() } label: {
                            Image(systemName: currentBookmark == nil ? "bookmark" : "bookmark.fill")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showReaderSettings = true } label: { Image(systemName: "textformat.size") }
                }
            }
        }
        .preferredColorScheme(readerThemeIsDark(activeTheme) ? .dark : .light)
        .overlay {
            ZStack {
                if dimV > 0.001 { Color.black.opacity(dimV).ignoresSafeArea() }
                if warmV > 0.001 { Color(red: 1, green: 0.6, blue: 0.2).opacity(warmV * 0.5).ignoresSafeArea() }
            }
            .allowsHitTesting(false)
        }
        .macSheet(isPresented: $showReaderSettings) {
            NovelReaderSettings(fontSize: $fontSize, lineGap: $lineGap, serif: $serif, family: $family,
                                bold: $bold, theme: $theme, margin: $margin, justify: $justify,
                                indent: $indentOn, dim: $dimV, warm: $warmV, mode: $mode, anim: $novelAnim,
                                activeTheme: activeTheme,
                                canSearch: mode == "pages",
                                downloaded: chapters.indices.contains(index) && store.isDownloaded(novel.id, chapters[index].id),
                                onSearch: {
                                    showReaderSettings = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showSearch = true }
                                },
                                onBookmarks: {
                                    showReaderSettings = false
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { showBookmarks = true }
                                },
                                onDownload: {
                                    guard chapters.indices.contains(index) else { return }
                                    let cur = chapters[index]
                                    if store.isDownloaded(novel.id, cur.id) {
                                        store.remove(novel: novel.id, chapter: cur.id)
                                    } else {
                                        DownloadManager.shared.enqueue(novel: novel, all: chapters, targets: [cur])
                                    }
                                })
        }
        .macSheet(isPresented: $showBookmarks) {
            BookmarksSheet(titleKey: novel.readKey, titleName: novel.displayTitle, showHighlights: true,
                           onBookmark: { jumpTo(offset: $0.position, chapterID: $0.chapterID) },
                           onHighlight: { jumpTo(offset: $0.start, chapterID: $0.chapterID) })
        }
        .macSheet(isPresented: $showSearch) {
            ChapterSearchSheet(pages: pages) { p in withAnimation { pageIndex = p } }
        }
        .macSheet(item: $noteFor) { r in
            NoteSheet(title: r.title, initial: r.initial, onSave: r.save)
        }
        .confirmationDialog("Выделение", isPresented: Binding(get: { pendingSel != nil },
                                                              set: { if !$0 { pendingSel = nil } }),
                            titleVisibility: .visible, presenting: pendingSel) { sel in
            Button("Выделить жёлтым") { applyHighlight(sel, color: 0) }
            Button("Выделить зелёным") { applyHighlight(sel, color: 1) }
            Button("Выделить синим") { applyHighlight(sel, color: 2) }
            Button("Выделить розовым") { applyHighlight(sel, color: 3) }
            Button("Заметка…") { openNote(sel) }
            if hls.exact(novel.readKey, chapterID, sel.range) != nil {
                Button("Убрать выделение", role: .destructive) { removeHighlight(sel) }
            }
            Button("Копировать текст") { UIPasteboard.general.string = sel.text }
            Button("Отмена", role: .cancel) {}
        } message: { sel in
            Text(String(sel.text.prefix(120)))
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = Settings.bool("set.keepAwake", true) }
        .onDisappear {
            persistPos()
            UIApplication.shared.isIdleTimerDisabled = false
            historyTask?.cancel()
        }
    }

    private func scheduleHistory(_ ch: NovelChapter) {
        historyTask?.cancel()
        HistoryStore.current.recordChapter(anime: novel, chapterID: ch.id, title: ch.title)
    }

    private func load() async {
        guard chapters.indices.contains(index), let slug = novel.slugUrl else { return }
        let ch = chapters[index]
        loading = true
        error = nil
        debug = ""
        blocks = []
        pages = []
        pageIndex = 0
        blockTracker.reset()
        if pendingOffset == nil, restoreBlock == nil, let pos = ReadPosStore.shared.get(novel.readKey), pos.c == ch.id {
            if mode == "pages" { if pos.p > 0 { pendingOffset = pos.p } }
            else if pos.b > 0 { restoreBlock = pos.b }
        }
        ReadStore.shared.mark(novel.readKey, ch.id)
        SiteSync.view(novelID: novel.id, chapterID: ch.id)
        scheduleHistory(ch)
        if let local = store.blocks(novel: novel.id, chapter: ch.id) {
            blocks = local
            loading = false
            return
        }
        do {
            let result = try await NovelService.content(slug: slug, chapter: ch)
            if Task.isCancelled { return }
            blocks = result
            if !result.isEmpty, Settings.bool("off.prefetch", false), index + 1 < chapters.count {
                DownloadManager.shared.enqueue(novel: novel, all: chapters,
                                               targets: Array(chapters[(index + 1)..<min(index + 4, chapters.count)]))
            }
            if result.isEmpty {
                error = "Текст главы пуст или недоступен."
                debug = await AnimelibAPI.shared.rawText(NovelService.chapterPath(slug: slug),
                                                         query: NovelService.chapterQuery(ch))
            }
        } catch {
            if Task.isCancelled { return }
            self.error = error.localizedDescription
        }
        loading = false
    }
}
