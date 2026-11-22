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

// MARK: - Прогресс просмотра
struct WatchProgress: Codable {
    var position: Double
    var duration: Double
    var updated: Date
    var finished: Bool { duration > 0 && position / duration > 0.92 }
}

@MainActor
final class ProgressStore: ObservableObject {
    static let shared = ProgressStore()
    private(set) var items: [String: WatchProgress] = [:]
    private let key = "progress.v1"

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: WatchProgress].self, from: d) {
            items = v
        }
        prune()
    }

    /// Убирает брошенный прогресс: недосмотренные серии, которые не открывались больше года.
    /// Досмотренные остаются — по ним рисуются галочки «Просмотрено» и считается статистика.
    private func prune() {
        let cutoff = Date().addingTimeInterval(-365 * 24 * 3600)
        let before = items.count
        items = items.filter { $0.value.finished || $0.value.updated > cutoff }
        if items.count != before, let d = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(d, forKey: key)
        }
    }

    func clear() {
        objectWillChange.send()
        items = [:]
        UserDefaults.standard.removeObject(forKey: key)
    }

    func get(_ id: Int) -> WatchProgress? { items[String(id)] }
    func position(_ id: Int) -> Double { items[String(id)]?.position ?? 0 }

    func opened(_ id: Int) {
        if items[String(id)] == nil {
            objectWillChange.send()
            items[String(id)] = WatchProgress(position: 0, duration: 0, updated: Date())
            save()
        }
    }

    func update(_ id: Int, position: Double, duration: Double) {
        let new = WatchProgress(position: position, duration: duration, updated: Date())
        let old = items[String(id)]
        // перерисовываем экраны только при заметных изменениях, а не каждые 5 секунд
        if old == nil || old?.finished != new.finished || abs((old?.position ?? 0) - position) >= 30 {
            objectWillChange.send()
        }
        items[String(id)] = new
        if new.finished && !(old?.finished ?? false) { ActivityStore.shared.addEpisode() }
        save()
    }

    private var dirty = false
    private var lastSave = Date.distantPast

    private func save() {
        dirty = true
        if Date().timeIntervalSince(lastSave) >= 20 { flush() }
    }

    /// Записывает накопленное на диск (вызывается при сворачивании и выходе из плеера).
    func flush() {
        guard dirty else { return }
        dirty = false
        lastSave = Date()
        if let d = try? JSONEncoder().encode(items) { UserDefaults.standard.set(d, forKey: key) }
    }
}

func formatTime(_ t: Double) -> String {
    let s = Int(t)
    let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
}
