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

struct SectionTintKey: EnvironmentKey { static let defaultValue = Color(hex: "8E8E93") }
extension EnvironmentValues {
    var sectionTint: Color {
        get { self[SectionTintKey.self] }
        set { self[SectionTintKey.self] = newValue }
    }
}

/// Значок строки в настройках: цвет задаёт раздел, а не случай
struct SettingsIcon: View {
    let name: String
    @Environment(\.sectionTint) private var tint
    var body: some View {
        Image(systemName: name)
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 30, height: 30)
            .background(tint.gradient, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

/// Цвета разделов настроек
enum SettingsTint {
    static let feel = Color(hex: "64D2FF")
    static let reading = Color(hex: "FF9F0A")
    static let playback = Color(hex: "FF375F")
    static let downloads = Color(hex: "0A84FF")
    static let data = Color(hex: "5E5CE6")
    static let profile = Color(hex: "BF5AF2")
    static let backup = Color(hex: "30D158")
    static let dev = Color(hex: "8E8E93")
    static let danger = Color(hex: "FF453A")
}

struct SettingsView: View {
    @State private var imageCacheBytes = 0
    @AppStorage("accent.hex") private var accentHex = Theme.defaultAccentHex
    @AppStorage("set.autoNative") private var autoNative = true
    @AppStorage("set.resume") private var resume = true
    @AppStorage("set.autoNext") private var autoNext = true
    @AppStorage("set.kodikDirect") private var kodikDirect = true
    @AppStorage("set.theme") private var appTheme = "system"
    @AppStorage("set.platform") private var platform = "anime"
    @AppStorage("set.haptics") private var haptics = true
    @AppStorage("set.keepAwake") private var keepAwake = true
    @AppStorage("manga.mode.default") private var mangaMode = "auto"
    @AppStorage("manga.tapzones") private var tapZones = true
    @AppStorage("manga.anim") private var mangaAnim = "slide"
    @AppStorage("manga.autobg") private var mangaAutoBG = false
    @AppStorage("novel.mode") private var novelMode = "pages"
    @AppStorage("novel.anim") private var novelAnim = "book"
    @AppStorage("off.wifi") private var offWifi = false
    @AppStorage("off.prefetch") private var offPrefetch = false
    @AppStorage("off.limitGB") private var offLimit = 0
    @AppStorage("off.overflow") private var offOverflow = "refuse"
    @ObservedObject private var offline = OfflineStore.current
    @State private var confirmOffline = false
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var heroLook = ProfileLook.shared
    @State private var custom: Color = Theme.accent
    @State private var info: String?
    @State private var shareItem: ShareItem?
    @State private var showImporter = false
    @State private var showExporter = false
    @State private var restored = false
    @State private var showRestartAlert = false
    @State private var showFolderImporter = false
    @State private var backupInfo = ""
    @State private var confirmSignOut = false
    @State private var confirmHistory = false
    @State private var confirmFavorites = false
    @AppStorage("backup.sent") private var backupSent: Double = 0

    private func finishRestore(_ d: Data?, _ reason: String) {
        guard let d else {
            backupInfo = "Файл не прочитался: \(reason)."
            return
        }
        let sum = BackupManager.summary(d)
        if let n = BackupManager.restore(d) {
            backupInfo = "Восстановлено записей: \(n). \(sum)"
            restored = true
            showRestartAlert = true
            Haptics.success()
        } else {
            backupInfo = "Это не файл копии Yume (или он повреждён)."
        }
    }

    private let presets: [(String, String)] = [
        ("Фиолетовый", "A87AFF"), ("Розовый", "FF6FA8"), ("Синий", "4F9DFF"),
        ("Бирюзовый", "2EC4B6"), ("Зелёный", "5BD16A"), ("Оранжевый", "FF9F43"), ("Красный", "FF5A5F")
    ]
    private let platforms: [(String, String, String, Bool)] = [
        ("anime", "Аниме", "AnimeLib", true),
        ("ranobe", "Ранобэ", "RanobeLib", true),
        ("manga", "Манга", "MangaLib", true),
        ("hentai", "Хентай", "HentaiLib", true),
        ("kino", "Кино", "Kinomig", true)
    ]

    private func platformIcon(_ id: String) -> String {
        switch id {
        case "ranobe": return "text.book.closed.fill"
        case "manga": return "books.vertical.fill"
        case "hentai": return "flame.fill"
        case "kino": return "film.stack.fill"
        default: return "play.rectangle.fill"
        }
    }

    private var platformHint: String {
        switch platform {
        case "ranobe": return "Ранобэ: читалка с темами и шрифтами, скачивание глав для чтения без сети."
        case "manga": return "Манга: страницы или лента, комментарии к главам, прогресс чтения."
        case "hentai": return "HentaiLib (18+): та же читалка, что у манги; избранное и история отдельные."
        case "kino": return "Кино: фильмы, сериалы, мультфильмы и аниме с kinomig.tv — родной плеер без рекламы, выбор озвучки, своё избранное."
        default: return "Аниме: плеер с озвучкой и субтитрами, комментарии к сериям, автопереход."
        }
    }

    private func choosePlatform(_ id: String) {
        guard platform != id else { return }
        Haptics.bump()
        let name = platforms.first { $0.0 == id }?.1 ?? ""
        AppRouter.shared.toast = "Платформа: \(name)"
        withAnimation(.easeInOut(duration: 0.3)) { platform = id }
    }

    private func card<Content: View>(_ title: String, icon: String = "gearshape.fill", tint: Color = Theme.accent,
                                     @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
                    .background(Theme.accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                Text(title).font(.headline).lineLimit(1).minimumScaleFactor(0.8)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private func groupTitle(_ t: String) -> some View {
        Text(t.uppercased())
            .font(.caption.weight(.bold))
            .tracking(1.2)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, 10)
            .padding(.leading, 6)
    }

    private var heroSubtitle: String {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let pl = platforms.first { $0.0 == platform }?.2 ?? "AnimeLib"
        return "Версия \(v) · \(pl)"
    }

    private var hero: some View {
        VStack(spacing: 14) {
            HStack(spacing: 14) {
                // твоя аватарка (своя из галереи или с сайта); без входа — значок приложения
                Group {
                    if heroLook.useAvatar, let a = heroLook.avatar {
                        ProfileMediaView(media: a, maxPixel: 300)
                    } else if let av = auth.user?.avatar {
                        AnimatedRemoteImage(url: av, maxPixel: 300)
                    } else {
                        Image(systemName: "sparkles.tv.fill")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .background(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .topLeading, endPoint: .bottomTrailing))
                    }
                }
                .frame(width: 64, height: 64)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                VStack(alignment: .leading, spacing: 3) {
                    Text(auth.user?.username ?? "Yume").font(.title3.weight(.bold)).lineLimit(1)
                    Text(heroSubtitle).font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                heroStat("arrow.down.circle.fill", "\(offline.allEntries.count)", "скачано")
                heroStat("internaldrive.fill", offline.totalBytes == 0 ? "0 МБ" : fmtBytes(offline.totalBytes), "занято")
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 28, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    private func heroStat(_ icon: String, _ value: String, _ title: String) -> some View {
        VStack(spacing: 3) {
            Image(systemName: icon).font(.system(size: 14, weight: .semibold)).foregroundStyle(Theme.accent)
            Text(value).font(.headline.monospacedDigit()).lineLimit(1).minimumScaleFactor(0.7)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(Theme.chip, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    // MARK: ряды в стиле «Настроек» iOS

    private func iconBadge(_ name: String) -> some View { SettingsIcon(name: name) }

    private var rowDivider: some View { Divider().padding(.leading, 42) }

    private func listCard<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        VStack(spacing: 0) { content() }
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 26, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
    }

    private func section<C: View>(_ title: String, tint: Color = SettingsTint.dev, footer: String? = nil,
                                  @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.footnote.weight(.semibold)).foregroundStyle(.secondary).textCase(.uppercase).padding(.horizontal, 18)
            listCard { content() }
                .environment(\.sectionTint, tint)
            if let footer {
                Text(footer.noHyphens).font(.footnote).foregroundStyle(.secondary)
                    .padding(.horizontal, 18)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Короткое название в одну строку и, если нужно, серая подпись под ним
    private func rowText(_ title: String, _ subtitle: String?, tint: Color = .primary) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(title).font(.body).foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.85)
            if let subtitle {
                Text(subtitle.noHyphens).font(.footnote).foregroundStyle(.secondary).lineLimit(2)
            }
        }
    }

    private func toggleRow(_ icon: String, _ title: String, _ subtitle: String? = nil, _ on: Binding<Bool>) -> some View {
        HStack(spacing: 12) {
            iconBadge(icon)
            rowText(title, subtitle)
            Spacer(minLength: 8)
            Toggle("", isOn: on).labelsHidden().tint(Theme.accent)
        }
        .padding(.vertical, subtitle == nil ? 9 : 8)
    }

    private func actionRow(_ icon: String, _ title: String, _ subtitle: String? = nil, tint: Color = .primary,
                           _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            HStack(spacing: 12) {
                iconBadge(icon)
                rowText(title, subtitle, tint: tint)
                Spacer(minLength: 0)
            }
            .padding(.vertical, subtitle == nil ? 12 : 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func linkRow<D: View>(_ icon: String, _ title: String, _ subtitle: String? = nil, value: String? = nil,
                                  @ViewBuilder _ dest: @escaping () -> D) -> some View {
        NavigationLink {
            dest()
        } label: {
            HStack(spacing: 12) {
                iconBadge(icon)
                rowText(title, subtitle)
                Spacer(minLength: 8)
                if let value { Text(value).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(.vertical, subtitle == nil ? 12 : 9)
            .contentShape(Rectangle())
        }
        .buttonStyle(.pressable)
    }

    private func textRow(_ t: String) -> some View {
        Text(t.noHyphens).font(.subheadline).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 12)
    }

    private func segRow(_ title: String, _ sel: Binding<String>, _ options: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Picker(title, selection: sel) {
                ForEach(options, id: \.0) { Text($0.1).tag($0.0) }
            }
            .pickerStyle(.segmented)
        }
        .padding(.vertical, 12)
    }

    // MARK: внешний вид

    private func themePreview(_ id: String) -> some View {
        let darkBG = Color(white: 0.11), lightBG = Color(white: 0.96)
        func screen(_ bg: Color, _ fg: Color) -> some View {
            ZStack(alignment: .topLeading) {
                bg
                VStack(alignment: .leading, spacing: 4) {
                    RoundedRectangle(cornerRadius: 2).fill(fg.opacity(0.5)).frame(width: 22, height: 4)
                    RoundedRectangle(cornerRadius: 3).fill(fg.opacity(0.18)).frame(height: 10)
                    RoundedRectangle(cornerRadius: 3).fill(fg.opacity(0.18)).frame(height: 10)
                }
                .padding(7)
            }
        }
        return ZStack {
            if id == "dark" { screen(darkBG, .white) }
            else if id == "light" { screen(lightBG, .black) }
            else { HStack(spacing: 0) { screen(lightBG, .black); screen(darkBG, .white) } }
        }
        .frame(height: 58)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.18), lineWidth: 0.5))
    }

    private var platformSwitch: some View {
        VStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(platforms, id: \.0) { pl in
                    let on = platform == pl.0
                    Button { choosePlatform(pl.0) } label: {
                        VStack(spacing: 4) {
                            Image(systemName: platformIcon(pl.0)).font(.system(size: 19, weight: .semibold))
                            Text(pl.1).font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
                        }
                        .foregroundStyle(on ? Color.white : Color.primary)
                        .frame(maxWidth: .infinity, minHeight: 58)
                        .background {
                            if on { RoundedRectangle(cornerRadius: 22, style: .continuous).fill(Theme.accent) }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(5)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: 27, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 27, style: .continuous).stroke(Color.white.opacity(0.07), lineWidth: 0.5))
            Text(platformHint.noHyphens)
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
        }
    }

    private var appearanceBlock: some View {
        section("Внешний вид") {
            HStack(spacing: 10) {
                ForEach([("system", "Системная"), ("dark", "Тёмная"), ("light", "Светлая")], id: \.0) { t in
                    let on = appTheme == t.0
                    Button { Haptics.select(); appTheme = t.0 } label: {
                        VStack(spacing: 8) {
                            themePreview(t.0)
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                                    .stroke(Theme.accent, lineWidth: on ? 2.5 : 0))
                            Text(t.1).font(.footnote.weight(on ? .semibold : .regular))
                                .foregroundStyle(on ? Theme.accent : Color.primary)
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.vertical, 14)
            rowDivider
            HStack(spacing: 0) {
                ForEach(presets, id: \.1) { p in
                    let on = accentHex.uppercased() == p.1
                    Circle()
                        .fill(Color(hex: p.1))
                        .frame(width: 30, height: 30)
                        .overlay { if on { Image(systemName: "checkmark").font(.caption2.bold()).foregroundStyle(.white) } }
                        .padding(3)
                        .overlay(Circle().stroke(Color(hex: p.1), lineWidth: on ? 2 : 0))
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                        .onTapGesture { Haptics.select(); accentHex = p.1 }
                }
                ColorPicker("Свой цвет", selection: $custom, supportsOpacity: false)
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .onChange(of: custom) { _, c in accentHex = c.hexString }
            }
            .padding(.vertical, 14)
        }
    }

    // MARK: чтение и просмотр

    private var feelBlock: some View {
        section("Отклик", tint: SettingsTint.feel) {
            toggleRow("hand.tap.fill", "Вибрация", "при нажатиях", $haptics)
                .onChange(of: haptics) { _, on in if on { Haptics.bump() } }
            rowDivider
            toggleRow("sun.max.fill", "Не гасить экран", "пока читаешь или смотришь", $keepAwake)
        }
    }

    private var ranobeBlock: some View {
        section("Чтение ранобэ", tint: SettingsTint.reading,
                footer: "В режиме «Страницы» глава режется на страницы по размеру экрана. Шрифт и тему можно менять в самой читалке.") {
            segRow("Режим", $novelMode, [("pages", "Страницы"), ("scroll", "Прокрутка")])
            rowDivider
            segRow("Листание", $novelAnim, [("slide", "Сдвиг"), ("fade", "Плавно"), ("book", "Как в книге")])
        }
    }

    private var mangaBlock: some View {
        section("Чтение манги", tint: SettingsTint.reading,
                footer: "Режим можно поменять для каждого тайтла прямо в читалке, он запомнится.") {
            segRow("Режим по умолчанию", $mangaMode, [("auto", "Авто"), ("pages", "Страницы"), ("scroll", "Лента")])
            rowDivider
            segRow("Листание", $mangaAnim, [("slide", "Сдвиг"), ("fade", "Плавно"), ("book", "Как в книге")])
            rowDivider
            toggleRow("hand.point.up.left.fill", "Тап по краям", "листает страницы", $tapZones)
            rowDivider
            toggleRow("rectangle.inset.filled", "Фон под страницу", "белый или чёрный по краям", $mangaAutoBG)
        }
    }

    private var playbackBlock: some View {
        section("Воспроизведение", tint: SettingsTint.playback,
                footer: "Kodik открывается в веб-плеере: выбери качество и нажми «на весь экран» — включится родной плеер iOS.") {
            toggleRow("play.rectangle.fill", "Родной плеер", "на весь экран", $autoNative)
            rowDivider
            toggleRow("bolt.fill", "Kodik без веб-плеера", "сразу родной плеер", $kodikDirect)
            rowDivider
            toggleRow("gobackward", "С места остановки", "продолжать серию, где закончил", $resume)
            rowDivider
            toggleRow("forward.end.fill", "Автопереход", "следующая серия после конца", $autoNext)
        }
    }

    // MARK: данные

    private var downloadsBlock: some View {
        section("Загрузки", tint: SettingsTint.downloads) {
            linkRow("arrow.down.circle.fill", "Скачанное",
                    value: offline.allEntries.isEmpty ? "пусто" : "\(offline.allEntries.count) · \(fmtBytes(offline.totalBytes))") { OfflineLibraryView() }
            rowDivider
            HStack(spacing: 12) {
                iconBadge("externaldrive.fill")
                rowText("Лимит места", nil)
                Spacer(minLength: 8)
                Picker("Лимит места", selection: $offLimit) {
                    Text("Без лимита").tag(0)
                    ForEach([1, 2, 3, 5, 10, 20, 50], id: \.self) { Text("\($0) ГБ").tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .tint(.secondary)
            }
            .padding(.vertical, 6)
            if offLimit > 0 {
                rowDivider
                segRow("При превышении", $offOverflow, [("refuse", "Отказаться"), ("purge", "Удалять прочитанное")])
                textRow("Занято \(fmtBytes(OfflineStore.usedBytes)) из \(offLimit) ГБ. «Отказаться» — загрузка встанет на лимите, «Удалять прочитанное» — сначала сотрутся самые давние прочитанные главы.")
            }
            rowDivider
            toggleRow("wifi", "Только по Wi‑Fi", nil, $offWifi)
            rowDivider
            toggleRow("arrow.down.to.line", "Докачивать вперёд", "3 следующие главы при чтении", $offPrefetch)
            if offline.totalBytes > 0 {
                rowDivider
                actionRow("trash.fill", "Удалить все загрузки", tint: .red) { confirmOffline = true }
            }
        }
        .confirmationDialog("Удалить все скачанные главы?", isPresented: $confirmOffline, titleVisibility: .visible) {
            Button("Удалить", role: .destructive) { offline.removeAll() }
        }
    }

    private var dataBlock: some View {
        section("Данные", tint: SettingsTint.data, footer: info) {
            HStack(spacing: 12) {
                iconBadge("photo.stack.fill")
                rowText("Кэш картинок", "обложки и просмотренные страницы")
                Spacer(minLength: 8)
                Text(fmtBytes(imageCacheBytes)).font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                Button("Очистить") {
                    Haptics.tap()
                    ImageLoader.clearAllCaches()
                    imageCacheBytes = ImageLoader.cachesBytes
                    info = "Кэш картинок очищен. Скачанные главы на месте."
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.accent)
                .buttonStyle(.pressable)
                .disabled(imageCacheBytes == 0)
            }
            .padding(.vertical, 9)
            .onAppear { imageCacheBytes = ImageLoader.cachesBytes }
        }
    }

    /// Шапка, аватарка и статистика — одним разделом
    private var profileLookBlock: some View {
        section("Профиль", tint: SettingsTint.profile) {
            linkRow("paintbrush.fill", "Шапка и аватарка", "фото, GIF или видео — видны только тебе") { ProfileAppearanceView() }
            rowDivider
            linkRow("chart.bar.xaxis", "Моя активность", "серия дней, сколько прочитано и просмотрено") { StatsView() }
        }
    }

    /// Сбросы отдельно от обычных пунктов, каждый — с подтверждением
    private var resetBlock: some View {
        section("Сброс", tint: SettingsTint.danger,
                footer: auth.user != nil ? "Тайтлы из твоих списков на сайте вернутся в «Избранное» при следующей синхронизации." : nil) {
            actionRow("clock.arrow.circlepath", "Сбросить историю", "прогресс чтения и просмотра", tint: .red) { confirmHistory = true }
            rowDivider
            actionRow("heart.slash.fill", "Очистить избранное", "на всех платформах", tint: .red) { confirmFavorites = true }
        }
        .confirmationDialog("Сбросить историю просмотра и чтения?", isPresented: $confirmHistory, titleVisibility: .visible) {
            Button("Сбросить", role: .destructive) {
                ProgressStore.shared.clear(); HistoryStore.shared.clear()
                HistoryStore.novels.clear(); HistoryStore.manga.clear(); HistoryStore.hentai.clear(); ReadStore.shared.clear(); ReadPosStore.shared.clear()
                info = "История просмотра и чтения сброшена"
            }
        }
        .confirmationDialog("Очистить избранное?", isPresented: $confirmFavorites, titleVisibility: .visible) {
            Button("Очистить", role: .destructive) {
                FavoritesStore.shared.clear(); FavoritesStore.novels.clear(); FavoritesStore.manga.clear(); FavoritesStore.hentai.clear()
                info = "Избранное очищено"
            }
        }
    }

    private var hasDataToLose: Bool {
        !(FavoritesStore.shared.items.isEmpty && FavoritesStore.novels.items.isEmpty
          && FavoritesStore.manga.items.isEmpty && FavoritesStore.hentai.items.isEmpty
          && HistoryStore.shared.items.isEmpty && HistoryStore.novels.items.isEmpty
          && HistoryStore.manga.items.isEmpty && HistoryStore.hentai.items.isEmpty)
    }

    @ViewBuilder
    private var backupWarning: some View {
        let days = backupSent == 0 ? nil : Int((Date().timeIntervalSince1970 - backupSent) / 86400)
        if hasDataToLose, days == nil || days! >= 7 {
            Button {
                if let u = BackupManager.shareURL() { backupSent = Date().timeIntervalSince1970; shareItem = ShareItem(url: u) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "exclamationmark.icloud.fill").font(.title3).foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(days.map { "Копия не отправлялась \($0) дн." } ?? "Копия ещё не отправлялась")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                        Text("Отправь файл в Telegram или Файлы: при переустановке данные не пропадут.".noHyphens)
                            .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                    }
                    Spacer(minLength: 0)
                    Image(systemName: "square.and.arrow.up").foregroundStyle(Theme.accent)
                }
                .padding(14)
                .background(Color.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.orange.opacity(0.35), lineWidth: 0.5))
            }
            .buttonStyle(.pressable)
        }
    }

    /// Внутри только действия, пояснение — подписью под карточкой
    private var backupBlock: some View {
        section("Резервная копия", tint: SettingsTint.backup,
                footer: "Прогресс, избранное, история и настройки. Файл сам обновляется при каждом сворачивании. Перед удалением приложения скопируй его, а после установки положи в ту же папку — всё подхватится само.") {
            HStack(spacing: 12) {
                iconBadge("folder.fill")
                rowText("Файл копии",
                        "Файлы → На iPhone → Yume" + (BackupManager.lastAuto.map { " · \(ruDate($0))" } ?? ""))
                Spacer(minLength: 0)
            }
            .padding(.vertical, 9)
            rowDivider
            actionRow("arrow.down.doc.fill", "Загрузить копию", "из папки приложения") {
                let r = BackupManager.readAppFolderCopy()
                BackupManager.acceptExternal()
                finishRestore(r.0, r.1)
            }
            rowDivider
            actionRow("square.and.arrow.up.fill", "Отправить копию", "в Telegram, Файлы и т. п.") {
                if let u = BackupManager.shareURL() { backupSent = Date().timeIntervalSince1970; shareItem = ShareItem(url: u) }
                else { backupInfo = "Не удалось подготовить файл." }
            }
            if restored {
                rowDivider
                actionRow("power", "Закрыть приложение", "чтобы применить копию") { exit(0) }
            }
            if !backupInfo.isEmpty {
                rowDivider
                textRow(backupInfo)
            }
        }
        .macSheet(item: $shareItem) { item in ShareSheet(url: item.url) }
    }

    private var devBlock: some View {
        section("Для разработчика", tint: SettingsTint.dev) {
            linkRow("waveform.path.ecg", "Журнал запросов сайта", "чтобы настроить синхронизацию с сайтом") { SiteLogView() }
            rowDivider
            linkRow("globe", "Любой сайт", "открыть адрес и записать все его запросы") { AnySiteLogView() }
        }
    }

    @ViewBuilder
    private var accountBlock: some View {
        if let u = auth.user {
            listCard {
                Button { confirmSignOut = true } label: {
                    Text("Выйти из аккаунта \(u.username)")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.red)
                        .lineLimit(1).minimumScaleFactor(0.8)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.pressable)
            }
        } else {
            Text("Вход — во вкладке «Профиль».")
                .font(.footnote).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        }
    }

    private var versionFooter: some View {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let host = platform == "kino" ? "kinomig.tv" : (URL(string: LibSite.current.origin)?.host ?? "animelib.org")
        return VStack(spacing: 2) {
            Text("Yume \(v)").font(.footnote.weight(.semibold))
            Text("Данные: \(host) · неофициальное приложение")
                .font(.caption)
        }
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    // заголовок как на остальных вкладках: на той же высоте, без пустой полосы сверху
                    Text("Настройки")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, -4)
                        .padding(.bottom, -10)
                    backupWarning
                    hero
                    platformSwitch
                    appearanceBlock
                    feelBlock
                    if platform == "ranobe" { ranobeBlock }
                    if platform == "manga" || platform == "hentai" { mangaBlock }
                    // каждый раздел — только там, где он работает
                    if platform == "anime" || platform == "kino" { playbackBlock } else { downloadsBlock }
                    dataBlock
                    profileLookBlock
                    backupBlock
                    devBlock
                    resetBlock
                    accountBlock
                    versionFooter
                }
                .padding(14)
                .padding(.bottom, 90)
            }
            .statusBarBlur()
            .background(AppBackground())
            .toolbar(.hidden, for: .navBar)
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { auth.signOut() }
                Button("Отмена", role: .cancel) {}
            }
            .alert("Данные восстановлены", isPresented: $showRestartAlert) {
                Button("Закрыть приложение") { UserDefaults.standard.synchronize(); exit(0) }
            } message: {
                Text("Чтобы всё подхватилось, приложение закроется. Открой Yume снова.")
            }
        }
    }
}
