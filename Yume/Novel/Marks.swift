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

// MARK: - Закладки, выделения и заметки
struct ReaderSelection: Identifiable {
    let id = UUID()
    let range: NSRange
    let text: String
}

struct NoteRequest: Identifiable {
    let id = UUID()
    let title: String
    let initial: String
    let save: (String) -> Void
}

struct Bookmark: Codable, Identifiable {
    var id = UUID()
    let titleKey: Int
    let chapterID: Int
    let chapterLabel: String
    /// Манга: номер страницы (с нуля). Ранобэ: смещение в тексте главы.
    let position: Int
    let isText: Bool
    let snippet: String
    var note: String
    let created: Date
}

@MainActor
final class BookmarkStore: ObservableObject {
    static let shared = BookmarkStore()
    @Published private(set) var items: [Bookmark] = []
    private let key = "bookmarks.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([Bookmark].self, from: d) { items = v }
    }

    func forTitle(_ k: Int) -> [Bookmark] {
        items.filter { $0.titleKey == k }.sorted { $0.created > $1.created }
    }

    func find(titleKey: Int, chapterID: Int, from: Int, to: Int) -> Bookmark? {
        items.first { $0.titleKey == titleKey && $0.chapterID == chapterID && $0.position >= from && $0.position < to }
    }

    func add(_ b: Bookmark) {
        items.append(b)
        save()
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].note = note
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct Highlight: Codable, Identifiable {
    var id = UUID()
    let titleKey: Int
    let chapterID: Int
    let chapterLabel: String
    let start: Int
    let length: Int
    var color: Int
    var note: String
    let snippet: String
    let created: Date

    static let palette: [UIColor] = [
        UIColor(red: 1.0, green: 0.84, blue: 0.2, alpha: 0.5),
        UIColor(red: 0.35, green: 0.85, blue: 0.45, alpha: 0.45),
        UIColor(red: 0.3, green: 0.65, blue: 1.0, alpha: 0.45),
        UIColor(red: 1.0, green: 0.45, blue: 0.7, alpha: 0.45)
    ]

    var uiColor: UIColor { Highlight.palette[min(max(color, 0), Highlight.palette.count - 1)] }
    var swiftUIColor: Color { Color(uiColor.withAlphaComponent(1)) }
}

@MainActor
final class HighlightStore: ObservableObject {
    static let shared = HighlightStore()
    @Published private(set) var items: [Highlight] = []
    private let key = "highlights.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([Highlight].self, from: d) { items = v }
    }

    func forChapter(_ k: Int, _ chapter: Int) -> [Highlight] {
        items.filter { $0.titleKey == k && $0.chapterID == chapter }
    }

    func forTitle(_ k: Int) -> [Highlight] {
        items.filter { $0.titleKey == k }.sorted { $0.created > $1.created }
    }

    func exact(_ k: Int, _ chapter: Int, _ r: NSRange) -> Highlight? {
        items.first { $0.titleKey == k && $0.chapterID == chapter && $0.start == r.location && $0.length == r.length }
    }

    @discardableResult
    func set(titleKey: Int, chapterID: Int, label: String, range: NSRange, snippet: String,
             color: Int?, note: String?) -> Highlight {
        if let i = items.firstIndex(where: {
            $0.titleKey == titleKey && $0.chapterID == chapterID && $0.start == range.location && $0.length == range.length
        }) {
            if let c = color { items[i].color = c }
            if let n = note { items[i].note = n }
            save()
            return items[i]
        }
        let h = Highlight(titleKey: titleKey, chapterID: chapterID, chapterLabel: label,
                          start: range.location, length: range.length, color: color ?? 0,
                          note: note ?? "", snippet: String(snippet.prefix(160)), created: Date())
        items.append(h)
        save()
        return h
    }

    func remove(_ id: UUID) {
        items.removeAll { $0.id == id }
        save()
    }

    func setNote(_ id: UUID, _ note: String) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        items[i].note = note
        save()
    }

    private func save() {
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct NoteSheet: View {
    let title: String
    let onSave: (String) -> Void
    @State private var text: String
    @Environment(\.dismiss) private var dismiss

    init(title: String, initial: String, onSave: @escaping (String) -> Void) {
        self.title = title
        self.onSave = onSave
        _text = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text(title).font(.footnote).foregroundStyle(.secondary).lineLimit(4)
                TextEditor(text: $text)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: 12))
                    .frame(minHeight: 160)
                Spacer()
            }
            .padding(14)
            .background(AppBackground())
            .navigationTitle("Заметка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Отмена") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Сохранить") {
                        onSave(text.trimmingCharacters(in: .whitespacesAndNewlines))
                        dismiss()
                    }
                    .bold()
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

/// Список закладок, выделений и заметок одного тайтла.
struct BookmarksSheet: View {
    let titleKey: Int
    let titleName: String
    let showHighlights: Bool
    let onBookmark: (Bookmark) -> Void
    let onHighlight: (Highlight) -> Void
    @ObservedObject private var bms = BookmarkStore.shared
    @ObservedObject private var hls = HighlightStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var noteFor: NoteRequest?

    var body: some View {
        let marks = bms.forTitle(titleKey)
        let lights = hls.forTitle(titleKey)
        NavigationStack {
            List {
                Section("Закладки") {
                    if marks.isEmpty {
                        Text("Пока нет закладок. Нажми значок закладки в читалке.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(marks) { b in
                        Button {
                            dismiss()
                            onBookmark(b)
                        } label: {
                            VStack(alignment: .leading, spacing: 3) {
                                Text(b.chapterLabel).font(.subheadline.weight(.semibold))
                                Text(b.isText ? b.snippet : "Страница \(b.position + 1)")
                                    .font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                if !b.note.isEmpty {
                                    Text(b.note).font(.caption).foregroundStyle(Theme.accent)
                                }
                            }
                        }
                        .swipeActions {
                            Button(role: .destructive) { bms.remove(b.id) } label: { Label("Удалить", systemImage: "trash") }
                            Button {
                                noteFor = NoteRequest(title: b.chapterLabel, initial: b.note) { bms.setNote(b.id, $0) }
                            } label: { Label("Заметка", systemImage: "note.text") }
                            .tint(.orange)
                        }
                    }
                }
                if showHighlights {
                    Section("Выделения и заметки") {
                        if lights.isEmpty {
                            Text("Удерживай палец на абзаце в читалке, чтобы выделить его или добавить заметку.")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(lights) { h in
                            Button {
                                dismiss()
                                onHighlight(h)
                            } label: {
                                HStack(alignment: .top, spacing: 10) {
                                    RoundedRectangle(cornerRadius: 2).fill(h.swiftUIColor).frame(width: 4)
                                    VStack(alignment: .leading, spacing: 3) {
                                        Text(h.chapterLabel).font(.caption).foregroundStyle(.secondary)
                                        Text(h.snippet).font(.subheadline).lineLimit(3)
                                        if !h.note.isEmpty {
                                            Text(h.note).font(.caption).foregroundStyle(Theme.accent)
                                        }
                                    }
                                }
                            }
                            .swipeActions {
                                Button(role: .destructive) { hls.remove(h.id) } label: { Label("Удалить", systemImage: "trash") }
                                Button {
                                    noteFor = NoteRequest(title: h.snippet, initial: h.note) { hls.setNote(h.id, $0) }
                                } label: { Label("Заметка", systemImage: "note.text") }
                                .tint(.orange)
                            }
                        }
                    }
                }
            }
            .navigationTitle(titleName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            }
            .sheet(item: $noteFor) { r in
                NoteSheet(title: r.title, initial: r.initial, onSave: r.save)
            }
        }
    }
}

/// Поиск по тексту открытой главы (ранобэ, постраничный режим).
struct ChapterSearchSheet: View {
    let pages: [NovelPage]
    let onPick: (Int) -> Void
    @State private var query = ""
    @Environment(\.dismiss) private var dismiss

    struct Hit: Identifiable {
        let id: Int
        let page: Int
        let snippet: String
    }

    private func search(_ q: String) -> [Hit] {
        let needle = q.trimmingCharacters(in: .whitespaces)
        guard needle.count >= 2 else { return [] }
        var out: [Hit] = []
        for (i, p) in pages.enumerated() {
            let s = p.plainText as NSString
            guard s.length > 0 else { continue }
            var from = 0
            while from < s.length, out.count < 300 {
                let r = s.range(of: needle, options: [.caseInsensitive, .diacriticInsensitive],
                                range: NSRange(location: from, length: s.length - from))
                if r.location == NSNotFound { break }
                let a = max(0, r.location - 30)
                let b = min(s.length, NSMaxRange(r) + 50)
                let snip = s.substring(with: NSRange(location: a, length: b - a))
                    .replacingOccurrences(of: "\n", with: " ")
                out.append(Hit(id: out.count, page: i,
                               snippet: (a > 0 ? "…" : "") + snip + (b < s.length ? "…" : "")))
                from = NSMaxRange(r)
            }
        }
        return out
    }

    var body: some View {
        let hits = search(query)
        NavigationStack {
            List {
                if query.trimmingCharacters(in: .whitespaces).count < 2 {
                    Text("Введи слово или фразу (от 2 букв).").foregroundStyle(.secondary)
                } else if hits.isEmpty {
                    Text("В этой главе ничего не найдено.").foregroundStyle(.secondary)
                }
                ForEach(hits) { h in
                    Button {
                        dismiss()
                        onPick(h.page)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Страница \(h.page + 1)").font(.caption).foregroundStyle(Theme.accent)
                            Text(h.snippet).font(.subheadline).lineLimit(3)
                        }
                    }
                }
            }
            .navigationTitle("Поиск по главе")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $query, placement: .navigationBarDrawer(displayMode: .always), prompt: "Слово или фраза")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Закрыть") { dismiss() } }
            }
        }
    }
}
