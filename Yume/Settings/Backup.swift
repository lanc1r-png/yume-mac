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

// MARK: - Резервная копия (прогресс, избранное, история, настройки)
enum BackupManager {
    private static let prefixes = ["favorites", "history", "progress", "read", "search.", "set.",
                                   "accent.", "reader.", "manga.", "novel.", "off.",
                                   "activity", "bookmarks", "highlights", "favmeta", "fav.", "friends", "profile."]

    private static func allowed(_ key: String) -> Bool {
        if key.hasPrefix("friends.cache") { return false }   // кэш, подтянется заново
        return prefixes.contains { key.hasPrefix($0) }
    }

    static var autoURL: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Yume-backup.plist")
    }

    static func snapshot() -> [String: Any] {
        let all = UserDefaults.standard.persistentDomain(forName: Bundle.main.bundleIdentifier ?? "") ?? [:]
        return all.filter { allowed($0.key) }
    }

    static func data(date: Date = Date()) -> Data? {
        var root: [String: Any] = ["app": "Yume", "version": 1, "date": date, "defaults": snapshot()]
        let files = ProfileLook.backupFiles()   // своя шапка/аватарка (фото и GIF)
        if !files.isEmpty { root["files"] = files }
        return try? PropertyListSerialization.data(fromPropertyList: root, format: .binary, options: 0)
    }

    // Копия живёт только в папке приложения (Файлы → На iPhone → Yume).
    private static let mineKey = "backup.mine"
    /// Время изменения файла копии, записанной самим приложением: позволяет не читать файл при каждом запуске.
    private static let mineMTimeKey = "backup.mine.mtime"
    private static func fileMTime() -> Double? {
        (try? FileManager.default.attributesOfItem(atPath: autoURL.path)[.modificationDate] as? Date)?.timeIntervalSince1970
    }   // дата последней копии, записанной самим приложением
    /// После восстановления в работающем приложении копии не пишутся, чтобы старые данные в памяти не затёрли файл.
    private static var frozen = false

    private static func fileDate(_ d: Data) -> Date? {
        guard let root = (try? PropertyListSerialization.propertyList(from: d, format: nil)) as? [String: Any],
              (root["app"] as? String) == "Yume" else { return nil }
        return root["date"] as? Date
    }

    /// Дата копии в папке приложения, если её положил пользователь (а не записало само приложение).
    static func externalCopyDate() -> Date? {
        // Быстрая проверка без чтения файла: если файла нет или он ровно тот, что записали мы сами, читать нечего.
        guard let m = fileMTime() else { return nil }
        if let mine = UserDefaults.standard.object(forKey: mineMTimeKey) as? Double, abs(m - mine) < 0.001 { return nil }
        guard let d = try? Data(contentsOf: autoURL), !d.isEmpty, let fd = fileDate(d) else { return nil }
        if let m = UserDefaults.standard.object(forKey: mineKey) as? Date, abs(m.timeIntervalSince(fd)) < 1.5 { return nil }
        return fd
    }

    /// «Не нужно»: считаем лежащую копию своей, дальше она будет обычно обновляться.
    static func acceptExternal() {
        if let d = try? Data(contentsOf: autoURL), let fd = fileDate(d) {
            UserDefaults.standard.set(fd, forKey: mineKey)
            if let m = fileMTime() { UserDefaults.standard.set(m, forKey: mineMTimeKey) }
        }
    }

    /// Вызывается до создания хранилищ: тихо подхватывает копию, которую положили в папку приложения.
    @discardableResult
    static func restoreOnLaunch() -> Bool {
        UserDefaults.standard.removeObject(forKey: "backup.folder.bookmark")
        guard externalCopyDate() != nil, let d = try? Data(contentsOf: autoURL), restore(d) != nil else { return false }
        acceptExternal()
        frozen = false
        return true
    }

    /// Пишет копию в папку приложения. Если там лежит чужая (новая) копия, не затирает её.
    @discardableResult
    static func writeAuto() -> URL? {
        if frozen || externalCopyDate() != nil { return nil }
        let stamp = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))
        guard let d = data(date: stamp) else { return nil }
        do {
            try d.write(to: autoURL, options: .atomic)
            UserDefaults.standard.set(stamp, forKey: mineKey)
            if let m = fileMTime() { UserDefaults.standard.set(m, forKey: mineMTimeKey) }
            return autoURL
        } catch {
            return nil
        }
    }

    /// Файл для кнопки «Отправить»: свежая копия или та, что уже лежит.
    static func shareURL() -> URL? {
        if let u = writeAuto() { return u }
        return FileManager.default.fileExists(atPath: autoURL.path) ? autoURL : nil
    }

    static var lastAuto: Date? {
        (try? FileManager.default.attributesOfItem(atPath: autoURL.path))?[.modificationDate] as? Date
    }

    /// Читает копию из папки приложения.
    static func readAppFolderCopy() -> (Data?, String) {
        guard FileManager.default.fileExists(atPath: autoURL.path) else {
            return (nil, "в папке приложения нет файла Yume-backup.plist")
        }
        guard let d = try? Data(contentsOf: autoURL), !d.isEmpty else { return (nil, "файл пустой или не читается") }
        return (d, "")
    }

    /// Возвращает число восстановленных записей.
    static func restore(_ data: Data) -> Int? {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              (root["app"] as? String) == "Yume",
              let defs = root["defaults"] as? [String: Any] else { return nil }
        var n = 0
        for (k, v) in defs where allowed(k) {
            UserDefaults.standard.set(v, forKey: k)
            n += 1
        }
        if let files = root["files"] as? [String: Data] { ProfileLook.restoreFiles(files) }
        UserDefaults.standard.synchronize()
        frozen = true
        return n
    }

    /// Что лежит в копии: для сообщения после восстановления.
    static func summary(_ data: Data) -> String {
        guard let root = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let defs = root["defaults"] as? [String: Any] else { return "" }
        func count(_ keys: [String]) -> Int {
            keys.reduce(0) { sum, k in
                guard let d = defs[k] as? Data, let a = (try? JSONSerialization.jsonObject(with: d)) as? [Any] else { return sum }
                return sum + a.count
            }
        }
        let fav = count(["favorites.v1", "favorites.novels.v1", "favorites.manga.v1", "favorites.hentai.v1"])
        let hist = count(["history.v1", "history.novels.v1", "history.manga.v1", "history.hentai.v1"])
        var s = "В копии: избранное \(fav), история \(hist)"
        if let d = root["date"] as? Date { s += ", сохранена \(ruDate(d))" }
        return s + "."
    }
}

struct BackupDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.propertyList] }
    var data: Data

    init(data: Data) { self.data = data }

    init(configuration: ReadConfiguration) throws {
        data = configuration.file.regularFileContents ?? Data()
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}

struct ShareItem: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.zipper").font(.system(size: 38)).foregroundStyle(Theme.accent)
            Text(url.lastPathComponent).font(.headline)
            Text("Файл копии готов.").font(.footnote).foregroundStyle(.secondary)
            HStack(spacing: 12) {
                ShareLink(item: url) { SwiftUI.Label("Поделиться", systemImage: "square.and.arrow.up") }
                Button("Показать в Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                Button("Закрыть") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(28)
        .frame(minWidth: 420)
    }
}
