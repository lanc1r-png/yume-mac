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

// MARK: - Статистика
struct DayActivity: Codable {
    var watch: Double = 0
    var episodes = 0
    var novels = 0
    var manga = 0
    /// Время чтения (манга, хентай, ранобэ) в секундах — старые данные, больше не пополняется
    var read: Double = 0
    /// Сколько раз за день открывалась серия (даже недосмотренная) — для «дней подряд»
    var opened = 0

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        watch = (try? c.decode(Double.self, forKey: .watch)) ?? 0
        episodes = (try? c.decode(Int.self, forKey: .episodes)) ?? 0
        novels = (try? c.decode(Int.self, forKey: .novels)) ?? 0
        manga = (try? c.decode(Int.self, forKey: .manga)) ?? 0
        read = (try? c.decode(Double.self, forKey: .read)) ?? 0
        opened = (try? c.decode(Int.self, forKey: .opened)) ?? 0
    }
}

@MainActor
final class ActivityStore: ObservableObject {
    static let shared = ActivityStore()
    @Published private(set) var days: [String: DayActivity] = [:]
    private let key = "activity.v1"
    private var dirty = false
    private var lastSave = Date.distantPast

    private static let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    static func dayKey(_ d: Date = Date()) -> String { fmt.string(from: d) }

    init() {
        if let d = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode([String: DayActivity].self, from: d) { days = v }
    }

    private func mutate(_ f: (inout DayActivity) -> Void) {
        let k = Self.dayKey()
        var d = days[k] ?? DayActivity()
        f(&d)
        days[k] = d
        dirty = true
        if Date().timeIntervalSince(lastSave) > 30 { flush() }
    }

    func addEpisode() { mutate { $0.episodes += 1 } }
    func episodeOpened() { mutate { $0.opened += 1 } }
    func addChapter(manga: Bool) {
        mutate { if manga { $0.manga += 1 } else { $0.novels += 1 } }
    }

    func flush() {
        guard dirty else { return }
        dirty = false
        lastSave = Date()
        if let d = try? JSONEncoder().encode(days) { UserDefaults.standard.set(d, forKey: key) }
    }
}

struct StatsView: View {
    @ObservedObject private var act = ActivityStore.shared
    @ObservedObject private var prog = ProgressStore.shared
    @ObservedObject private var reads = ReadStore.shared
    @State private var chart = 0

    private struct Bar: Identifiable {
        let id: String
        let label: String
        let value: Double
    }

    private func lastDays(_ n: Int) -> [(String, Date)] {
        let cal = Calendar.current
        var out: [(String, Date)] = []
        for i in (0..<n).reversed() {
            if let d = cal.date(byAdding: .day, value: -i, to: Date()) { out.append((ActivityStore.dayKey(d), d)) }
        }
        return out
    }

    private func total(_ n: Int, _ f: (DayActivity) -> Double) -> Double {
        var t = 0.0
        for (k, _) in lastDays(n) { t += f(act.days[k] ?? DayActivity()) }
        return t
    }

    private var streak: Int {
        let cal = Calendar.current
        func active(_ d: Date) -> Bool {
            guard let a = act.days[ActivityStore.dayKey(d)] else { return false }
            // день считается, если читал, досмотрел серию или хотя бы открывал её
            // (watch и read — минуты из старых версий, чтобы прошлые дни тоже засчитывались)
            return a.episodes > 0 || a.novels > 0 || a.manga > 0 || a.opened > 0 || a.watch > 0 || a.read > 0
        }
        var day = Date()
        if !active(day) { day = cal.date(byAdding: .day, value: -1, to: day) ?? day }
        var n = 0
        while active(day), n < 3650 {
            n += 1
            guard let prev = cal.date(byAdding: .day, value: -1, to: day) else { break }
            day = prev
        }
        return n
    }

    private var episodesFinished: Int { prog.items.values.filter { $0.finished }.count }
    private var mangaChapters: Int {
        reads.read.filter { (Int($0.key) ?? 0) < 0 }.values.reduce(0) { $0 + $1.count }
    }
    private var novelChapters: Int {
        reads.read.filter { (Int($0.key) ?? 0) >= 0 }.values.reduce(0) { $0 + $1.count }
    }

    private func chaptersIn(_ n: Int) -> Int {
        Int(total(n) { Double($0.novels + $0.manga) })
    }

    private var bars: [Bar] {
        let f = DateFormatter()
        f.dateFormat = "d"
        var out: [Bar] = []
        for (k, d) in lastDays(14) {
            let a = act.days[k] ?? DayActivity()
            let v = chart == 0 ? Double(a.novels + a.manga) : Double(a.episodes)
            out.append(Bar(id: k, label: f.string(from: d), value: v))
        }
        return out
    }

    private func tile(_ title: String, _ value: String, _ icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Image(systemName: icon).foregroundStyle(Theme.accent)
            Text(value).font(.title2.bold())
            Text(title).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 14))
    }

    var body: some View {
        let list = bars
        let maxV = max(list.map { $0.value }.max() ?? 1, 1)
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    tile("Дней подряд", "\(streak)", "flame.fill")
                    tile("Серий досмотрено", "\(episodesFinished)", "checkmark.circle.fill")
                    tile("Глав за неделю", "\(chaptersIn(7))", "book.fill")
                    tile("Глав за месяц", "\(chaptersIn(30))", "books.vertical.fill")
                    tile("Глав манги прочитано", "\(mangaChapters)", "photo.on.rectangle")
                    tile("Глав ранобэ прочитано", "\(novelChapters)", "text.book.closed.fill")
                }

                VStack(alignment: .leading, spacing: 10) {
                    Picker("", selection: $chart) {
                        Text("Чтение, глав").tag(0)
                        Text("Просмотр, серий").tag(1)
                    }
                    .pickerStyle(.segmented)
                    HStack(alignment: .bottom, spacing: 5) {
                        ForEach(list) { b in
                            VStack(spacing: 4) {
                                Spacer(minLength: 0)
                                RoundedRectangle(cornerRadius: 4)
                                    .fill(b.value > 0 ? Theme.accent : Theme.chip)
                                    .frame(height: max(4, CGFloat(b.value / maxV) * 90))
                                Text(b.label).font(.system(size: 9)).foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .frame(height: 118)
                }
                .padding(14)
                .background(Theme.card, in: RoundedRectangle(cornerRadius: 16))

                Text("Считаются прочитанные главы, досмотренные серии и дни подряд. Время не отслеживается.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(14)
        }
        .background(AppBackground())
        .navigationTitle("Статистика")
        .navigationBarTitleDisplayMode(.inline)
    }
}
