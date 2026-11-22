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

struct ProfileView: View {
    @ObservedObject private var auth = AuthStore.shared
    @ObservedObject private var localFriends = LocalFriends.shared
    @StateObject private var vm = ProfileViewModel()
    @StateObject private var friendsVM = FriendsViewModel()
    @State private var showLogin = false
    @State private var confirmSignOut = false
    @State private var styleFolder: BookmarkFolder?
    @State private var spin = false
    @ObservedObject private var folderStyles = FolderStyles.shared
    @Environment(\.colorScheme) private var scheme
    /// Основной цвет обложки (или аватарки): им подкрашены фон страницы и обводка аватарки
    @State private var tint: Color?
    @State private var viewer: ProfileImageViewer.Item?
    /// Пропорции баннера (ширина / высота), когда он загрузился
    @State private var bannerRatio: CGFloat?
    @ObservedObject private var look = ProfileLook.shared
    @State private var showLook = false
    @ObservedObject private var siteFolders = SiteFolders.shared
    @ObservedObject private var favStore: FavoritesStore = FavoritesStore.current
    @ObservedObject private var history: HistoryStore = HistoryStore.current
    @ObservedObject private var activity = ActivityStore.shared
    /// Насколько прокручена страница — размытие под часами появляется, когда шапка уехала
    @State private var scrollY: CGFloat = 0
    @ObservedObject private var genreStats = UserGenreStats.shared
    @ObservedObject private var readStore = ReadStore.shared
    @ObservedObject private var favMeta = FavMetaStore.shared
    private let columns = [GridItem(.adaptive(minimum: 110), spacing: 14, alignment: .top)]

    /// Папка «Прочитано/Просмотрено», если она есть
    private var doneFolder: BookmarkFolder? {
        vm.folders.first {
            let n = $0.name.lowercased()
            return n.contains("прочитан") || n.contains("просмотрен")
        }
    }

    /// Отступ под часы (вью игнорирует безопасную зону сверху)
    private var topInset: CGFloat {
        0
    }

    /// Круглая кнопка из нейтрального стекла с белой иконкой — не окрашивается баннером
    private func glassCircle(_ icon: String) -> some View {
        Image(systemName: icon)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(Circle().fill(Color.black.opacity(0.28)))
            .glassShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.22), lineWidth: 0.6))
            .shadow(color: .black.opacity(0.2), radius: 6, y: 2)
    }

    private func topButtons(_ u: ProfileUser) -> some View {
        HStack(spacing: 10) {
            Button { showLook = true } label: { glassCircle("pencil") }
                .buttonStyle(.pressable)
            // «Поделиться» сразу открывает системное окно со ссылкой на профиль на сайте (там есть и «Скопировать»).
            // Выход из аккаунта — в Настройках.
            if let link = URL(string: LibSite.current.referer + "ru/user/\(u.id)") {
                ShareLink(item: link) { glassCircle("square.and.arrow.up") }
                    .buttonStyle(.pressable)
            }
        }
        .padding(.top, topInset + 4)
        .padding(.trailing, 16)
    }

    // MARK: шапка профиля (формат 4:3, своя или с сайта)
    @ViewBuilder
    private func headerArt(_ u: ProfileUser) -> some View {
        if let h = look.activeHeader {
            ProfileMediaView(media: h, maxPixel: 2000)
        } else if let c = u.cover {
            if let r = bannerRatio, r <= 2.3 {
                // высокий баннер с сайта заполняет шапку целиком
                AnimatedRemoteImage(url: c, maxPixel: 2400)
            } else {
                // широкий баннер — резкий по центру, вокруг он же, размытый
                ZStack {
                    BlurredCover(url: c, radius: 26, scale: 1.25)
                    ProfileBanner(url: c, ratio: $bannerRatio)
                        .mask(LinearGradient(stops: [.init(color: .black.opacity(0), location: 0),
                                                     .init(color: .black, location: 0.18),
                                                     .init(color: .black, location: 0.82),
                                                     .init(color: .black.opacity(0), location: 1)],
                                             startPoint: .top, endPoint: .bottom))
                        .padding(.top, 40)
                }
            }
        } else {
            LinearGradient(colors: [Theme.accent.opacity(0.7), Theme.accent2.opacity(0.35)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
        }
    }

    /// Что открыть на весь экран по нажатию на шапку
    private func headerViewerURL(_ u: ProfileUser) -> URL? {
        if let h = look.activeHeader { return h.isVideo ? nil : ProfileLook.url(h) }
        return u.cover
    }

    /// Откуда брать цвет для фона страницы и кольца аватарки
    private func tintSource(_ u: ProfileUser) -> URL? {
        if let h = look.activeHeader, !h.isVideo { return ProfileLook.url(h) }
        if let a = look.activeAvatar { return ProfileLook.url(a) }
        return u.cover ?? u.avatar
    }

    @ViewBuilder
    private func profileHeader(_ u: ProfileUser) -> some View {
        VStack(spacing: 0) {
            // Шапка 4:3 от самого верха экрана: тянется при свайпе вниз, низ растворяется в фоне
            Color.clear
                .aspectRatio(4 / 3, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .overlay(alignment: .top) {
                    GeometryReader { g in
                        let y = g.frame(in: .named("profileScroll")).minY
                        let pull = max(0, y)
                        // шапка уходит ниже рамки 4:3 и растворяется длинным мягким градиентом — без видимой границы
                        let extra: CGFloat = 110
                        headerArt(u)
                            .frame(width: g.size.width, height: g.size.height + pull + extra)
                            .clipped()
                            // при прокрутке вниз картинка уезжает медленнее и слегка размывается
                            .blur(radius: y < 0 ? min(14, -y / 14) : 0)
                            .overlay(alignment: .top) {
                                LinearGradient(colors: [.black.opacity(0.45), .clear], startPoint: .top, endPoint: .bottom)
                                    .frame(height: 120)
                                    .allowsHitTesting(false)
                            }
                            .mask(LinearGradient(stops: [.init(color: .black, location: 0),
                                                         .init(color: .black, location: 0.5),
                                                         .init(color: .black.opacity(0.6), location: 0.7),
                                                         .init(color: .black.opacity(0.2), location: 0.86),
                                                         .init(color: .black.opacity(0), location: 1)],
                                                 startPoint: .top, endPoint: .bottom))
                            .offset(y: y > 0 ? -y : -y * 0.35)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture { if let v = headerViewerURL(u) { viewer = .init(url: v) } }
                .contextMenu {
                    Button { showLook = true } label: { Label("Изменить шапку и аватарку", systemImage: "paintbrush") }
                }
                // кнопки — часть шапки и уезжают вместе с ней
                .overlay(alignment: .topTrailing) { topButtons(u) }
                .background {
                    GeometryReader { g in
                        Color.clear.preference(key: ProfileScrollKey.self, value: g.frame(in: .named("profileScroll")).minY)
                    }
                }

            // Аватарка: одно кольцо с ровным зазором и мягким свечением
            let side: CGFloat = 106
            let r: CGFloat = 28
            let gap: CGFloat = 0   // картинка упирается прямо в рамку
            let line: CGFloat = 3.5
            ZStack {
                // одна обводка: медленно вращающийся градиент из акцента и цвета баннера
                let bc = tint ?? Theme.accent2
                RoundedRectangle(cornerRadius: r + gap + line / 2, style: .continuous)
                    .stroke(AngularGradient(gradient: Gradient(colors: [Theme.accent, bc, Theme.accent2, bc, Theme.accent]),
                                            center: .center, angle: .degrees(spin ? 360 : 0)),
                            lineWidth: line)
                    .frame(width: side + 2 * gap + line, height: side + 2 * gap + line)
                    .shadow(color: bc.opacity(0.45), radius: 10)
                Group {
                    if let a = look.activeAvatar {
                        ProfileMediaView(media: a, maxPixel: 420)
                    } else {
                        AnimatedRemoteImage(url: u.avatar, maxPixel: 420)
                    }
                }
                .frame(width: side, height: side)
                .clipShape(RoundedRectangle(cornerRadius: r, style: .continuous))
            }
            .padding(.top, -70)
            .onTapGesture {
                if let a = look.activeAvatar { viewer = .init(url: ProfileLook.url(a)) }
                else if let a = u.avatar { viewer = .init(url: a) }
            }
            .contextMenu {
                Button { showLook = true } label: { Label("Изменить шапку и аватарку", systemImage: "paintbrush") }
            }
            .onAppear {
                withAnimation(.linear(duration: 14).repeatForever(autoreverses: false)) { spin = true }
            }

            HStack(spacing: 6) {
                Text(u.username).font(.title.bold()).lineLimit(1).minimumScaleFactor(0.7)
                if u.premium {
                    Image(systemName: "crown.fill").font(.headline).foregroundStyle(.yellow)
                }
            }
            .padding(.top, 14)
            .padding(.horizontal, 20)

            // Статистика: цифра крупно, подпись под ней
            let items: [(String, Color, String, String)] = [
                u.streak.map { ("flame.fill", Color.orange, "\($0)", "дней подряд") },
                u.level.map { ("star.fill", Color.yellow, "\($0)", "уровень") },
                vm.totalTitles > 0 ? (LibSite.current.isBook ? "books.vertical.fill" : "film.stack.fill", Theme.accent, "\(vm.totalTitles)", "тайтлов") : nil,
                doneFolder.map { ("trophy.fill", Color(red: 1, green: 0.76, blue: 0.3), "\($0.count ?? 0)", "завершено") }
            ].compactMap { $0 }
            if !items.isEmpty {
                HStack(spacing: 0) {
                    ForEach(Array(items.enumerated()), id: \.offset) { i, it in
                        if i > 0 {
                            Rectangle().fill(Color.primary.opacity(0.15)).frame(width: 0.5, height: 30)
                        }
                        VStack(spacing: 3) {
                            HStack(spacing: 5) {
                                Image(systemName: it.0).foregroundStyle(it.1)
                                Text(it.2).monospacedDigit()
                            }
                            .font(.headline)
                            Text(it.3)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.8)
                        }
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                // та же карточка, что у «Друзей» и списков: один стиль на всём экране
                .background(cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .overlay {
                    if scheme != .dark {
                        RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.6)
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
            }
        }
        .frame(maxWidth: .infinity)
        .task(id: tintSource(u)) { tint = await CoverTint.color(tintSource(u)) }
    }

    /// Цвет иконки списка: системные списки — по статусу, свои — выбранный цвет.
    private func folderColor(_ f: BookmarkFolder) -> Color {
        if let c = folderStyles.style(f.id)?.color { return c }
        let n = f.name.lowercased()
        if n.contains("смотрю") || n.contains("читаю") { return ListStatus.active.color }
        if n.contains("план") { return ListStatus.planned.color }
        if n.contains("просмотр") || n.contains("прочитан") { return ListStatus.done.color }
        if n.contains("брош") { return ListStatus.dropped.color }
        if n.contains("любим") { return Color(red: 1, green: 0.42, blue: 0.62) }
        if n.contains("отлож") { return Color(red: 0.55, green: 0.62, blue: 0.8) }
        if n.contains("не нрав") { return .gray }
        return Theme.accent
    }

    private var cardFill: AnyShapeStyle {
        // светлая тема: белое стекло плотнее, тёмная — как было
        scheme == .dark ? AnyShapeStyle(Theme.card) : AnyShapeStyle(Color.white.opacity(0.72))
    }

    private func folderIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("любим") { return "heart.fill" }
        if let st = ListStatus.fromFolderName(name) { return st.icon(book: LibSite.current.isBook) }
        if n.contains("отлож") { return "pause.circle.fill" }
        if n.contains("не нрав") { return "hand.thumbsdown.fill" }
        return "bookmark.fill"
    }

    private func stat(_ icon: String, _ tint: Color, _ text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.8)
            .foregroundStyle(tint)
            .padding(.horizontal, 10).padding(.vertical, 6)
            .glassCapsule()
    }

    private func folderTile(_ f: BookmarkFolder) -> some View {
        // плитка открывает «Избранное» с этим списком
        return Button {
            Haptics.select()
            if let st = ListStatus.fromFolderName(f.name) {
                AppRouter.shared.openFavorites(status: st)
            } else {
                AppRouter.shared.openFavorites(folder: f.id)
            }
        } label: {
            HStack(spacing: 10) {
                Group {
                    if let e = folderStyles.style(f.id)?.emoji, !e.isEmpty {
                        Text(e).font(.system(size: 19))
                    } else {
                        Image(systemName: folderIcon(f.name)).font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(folderColor(f))
                    }
                }
                .frame(width: 24)
                // одно слово — в одну строку с уменьшением (без «Люби-мые»), несколько слов — переносим по словам
                let multiWord = f.name.trimmingCharacters(in: .whitespaces).contains(" ")
                Text(f.name)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(multiWord ? 2 : 1)
                    .minimumScaleFactor(multiWord ? 0.85 : 0.65)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 4)
                Text(f.count.map(String.init) ?? "")
                    .font(.title3.bold().monospacedDigit())
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 58, alignment: .leading)
            .foregroundStyle(Color.primary)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                if scheme != .dark {
                    RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.6)
                }
            }
        }
        .buttonStyle(.pressable)
        .contextMenu {
            Button { styleFolder = f } label: { Label("Цвет и эмодзи списка", systemImage: "paintpalette") }
        }
    }

    private func friendsTile(userID: Int) -> some View {
        let list = FriendsViewModel.merged(friendsVM.friends, localFriends.items)
        // три аватарки и кружок «+N», если друзей больше
        let shownAv = Array(list.prefix(list.count > 4 ? 3 : 4))
        let rest = list.count - shownAv.count
        let online = list.filter { $0.online == true }.count
        return NavigationLink {
            FriendsView(userID: userID, vm: friendsVM)
        } label: {
            HStack(spacing: 14) {
                ZStack(alignment: .leading) {
                    if shownAv.isEmpty {
                        Image(systemName: "person.2.fill")
                            .foregroundStyle(Theme.accent)
                            .frame(width: 44, height: 44)
                            .background(Theme.accent.opacity(0.18), in: Circle())
                    }
                    ForEach(Array(shownAv.enumerated()), id: \.element.id) { i, f in
                        Group {
                            if f.avatar != nil {
                                AnimatedRemoteImage(url: f.avatar, maxPixel: 120)
                            } else {
                                Image(systemName: "person.fill").font(.system(size: 16))
                                    .foregroundStyle(.white)
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    .background(Theme.accent.opacity(0.6))
                            }
                        }
                        .frame(width: 40, height: 40)
                        .clipShape(Circle())
                        .overlay(Circle().stroke(Theme.base, lineWidth: 2.5))
                        .offset(x: CGFloat(i) * 26)
                    }
                    if rest > 0 {
                        Text("+\(rest)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(Theme.accent)
                            .frame(width: 40, height: 40)
                            .background {
                                ZStack {
                                    Circle().fill(.ultraThinMaterial)
                                    Circle().fill(Theme.accent.opacity(0.12))
                                }
                            }
                            .overlay(Circle().stroke(Theme.accent.opacity(0.35), lineWidth: 1))
                            .overlay(Circle().stroke(Theme.base, lineWidth: 2.5).padding(-1.25))
                            .offset(x: CGFloat(shownAv.count) * 26)
                    }
                }
                .frame(width: shownAv.isEmpty ? 44 : CGFloat(shownAv.count + (rest > 0 ? 1 : 0) - 1) * 26 + 40, height: 44, alignment: .leading)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Друзья").font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
                    if list.isEmpty {
                        Text("Профили и списки друзей").font(.caption).foregroundStyle(.secondary)
                    } else if online > 0 {
                        Text("\(list.count) · \(online) в сети").font(.caption).foregroundStyle(Color.green)
                    } else {
                        Text("\(list.count) друзей").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(cardFill, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if scheme != .dark {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.6)
                }
            }
        }
        .buttonStyle(.pressable)
    }

    // MARK: подборки вместо сетки обложек

    private var book: Bool { LibSite.current.isBook }

    private func showcaseHeader(_ title: String, action: (() -> Void)? = nil) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.title3.bold())
            if action != nil {
                Image(systemName: "chevron.right").font(.footnote.bold()).foregroundStyle(Theme.accent)
            }
            Spacer()
        }
        .contentShape(Rectangle())
        .onTapGesture { action?() }
        .padding(.horizontal, 4)
    }

    private func coverRail(_ list: [Anime]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(list) { a in
                    TitleLink(anime: a) { PosterCard(anime: a, width: 118) }
                        .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.horizontal, -14)
    }

    /// Тайтлы из папки «Любимые» на сайте — твой топ
    private var favoriteTitles: [Anime] {
        guard let f = siteFolders.favorite else { return [] }
        let byID = Dictionary(favStore.items.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return f.ids.compactMap { byID[$0] }
    }

    /// Жанры, которые у тебя чаще всего: по избранному и недавно открытому
    private var topGenres: [(String, Int)] {
        var seen = Set<Int>()
        var counts: [String: Int] = [:]
        for a in favStore.items + history.items.map({ $0.anime }) where seen.insert(a.id).inserted {
            for g in a.genres ?? [] where !g.title.isEmpty { counts[g.title, default: 0] += 1 }
        }
        return counts.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }.prefix(5).map { ($0.key, $0.value) }
    }

    /// Последние 7 дней: сколько глав (или серий) за день
    private var week: [(String, Int)] {
        let cal = Calendar.current
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "EEEEEE"
        return (0..<7).reversed().map { back in
            let d = cal.date(byAdding: .day, value: -back, to: Date()) ?? Date()
            let a = activity.days[ActivityStore.dayKey(d)]
            let n = book ? ((a?.manga ?? 0) + (a?.novels ?? 0)) : (a?.episodes ?? 0)
            return (f.string(from: d).capitalized, n)
        }
    }

    private var showcaseCard: AnyShapeStyle { cardFill }

    private func cardBox<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 14) { c() }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(showcaseCard, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                if scheme != .dark {
                    RoundedRectangle(cornerRadius: 24, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.6)
                }
            }
    }

    /// Полоса из цветных кусков по доле (статусы, жанры)
    private func shareBar(_ parts: [(Color, Int)]) -> some View {
        let total = max(parts.map { $0.1 }.reduce(0, +), 1)
        return GeometryReader { g in
            let gaps = CGFloat(max(parts.count - 1, 0)) * 3
            HStack(spacing: 3) {
                ForEach(Array(parts.enumerated()), id: \.offset) { _, p in
                    Capsule().fill(p.0.gradient)
                        .frame(width: max(6, (g.size.width - gaps) * CGFloat(p.1) / CGFloat(total)))
                }
            }
        }
        .frame(height: 12)
    }

    // MARK: Библиотека — вместо плиток списков

    private var libraryCard: some View {
        let book = LibSite.current.isBook
        let statusFolders: [(BookmarkFolder, ListStatus)] = ListStatus.allCases.compactMap { st in
            vm.folders.first { ListStatus.fromFolderName($0.name) == st }.map { ($0, st) }
        }
        let custom = vm.folders.filter { ListStatus.fromFolderName($0.name) == nil }
        let total = statusFolders.map { $0.0.count ?? 0 }.reduce(0, +)
        return cardBox {
            HStack(alignment: .firstTextBaseline) {
                Text("Библиотека").font(.title3.bold())
                Spacer()
                Text("\(total) в статусах").font(.subheadline).foregroundStyle(.secondary)
            }
            if total > 0 {
                shareBar(statusFolders.filter { ($0.0.count ?? 0) > 0 }.map { ($0.1.color, $0.0.count ?? 0) })
            }
            // легенда: нажатие — «Избранное» с этим статусом
            FlowLayout(spacing: 8) {
                ForEach(statusFolders, id: \.0.id) { f, st in
                    Button {
                        Haptics.select()
                        AppRouter.shared.openFavorites(status: st)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: st.badgeIcon(book: book))
                                .font(.system(size: 9, weight: .heavy))
                                .foregroundStyle(.white)
                                .frame(width: 18, height: 18)
                                .background(st.color, in: Circle())
                            Text(f.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                            Text("\(f.count ?? 0)").font(.subheadline.weight(.bold).monospacedDigit()).foregroundStyle(.primary)
                        }
                        .padding(.leading, 5).padding(.trailing, 11).padding(.vertical, 5)
                        .background(st.color.opacity(0.14), in: Capsule())
                    }
                    .buttonStyle(.pressable)
                }
            }
            if !custom.isEmpty {
                Divider().opacity(0.5)
                FlowLayout(spacing: 8) {
                    ForEach(custom) { f in
                        Button {
                            Haptics.select()
                            AppRouter.shared.openFavorites(folder: f.id)
                        } label: {
                            HStack(spacing: 6) {
                                if let e = folderStyles.style(f.id)?.emoji, !e.isEmpty {
                                    Text(e).font(.system(size: 14))
                                } else {
                                    Image(systemName: folderIcon(f.name)).font(.system(size: 12, weight: .semibold))
                                        .foregroundStyle(folderColor(f))
                                }
                                Text(f.name).font(.subheadline.weight(.medium)).foregroundStyle(.primary).lineLimit(1)
                                Text("\(f.count ?? 0)").font(.subheadline.monospacedDigit()).foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 11).padding(.vertical, 6)
                            .background(Color.primary.opacity(0.07), in: Capsule())
                        }
                        .buttonStyle(.pressable)
                        .contextMenu {
                            Button { styleFolder = f } label: { Label("Цвет и эмодзи списка", systemImage: "paintpalette") }
                        }
                    }
                }
            }
        }
    }

    // MARK: Сейчас читаю — обложка, полоска прогресса, где остановился

    private func progress(_ a: Anime) -> Double? {
        if LibSite.current.isBook {
            guard let total = favMeta.items[FavMetaStore.key(a)]?.count, total > 0 else { return nil }
            let done = readStore.read[String(a.readKey)]?.count ?? 0
            return done > 0 ? min(1, Double(done) / Double(total)) : nil
        }
        return nil
    }

    private func recentRail(_ items: [HistoryItem]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            LazyHStack(alignment: .top, spacing: 12) {
                ForEach(items) { h in
                    TitleLink(anime: h.anime) {
                        VStack(alignment: .leading, spacing: 6) {
                            RemoteImage(url: h.anime.imageURL, maxPixel: 420)
                                .frame(width: 112, height: 168)
                                .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                                .overlay(alignment: .bottom) {
                                    if let p = progress(h.anime) {
                                        GeometryReader { g in
                                            ZStack(alignment: .leading) {
                                                Capsule().fill(Color.black.opacity(0.45))
                                                Capsule().fill(LinearGradient(colors: [Theme.accent, Theme.accent2], startPoint: .leading, endPoint: .trailing))
                                                    .frame(width: max(5, g.size.width * p))
                                            }
                                        }
                                        .frame(height: 5)
                                        .padding(8)
                                    }
                                }
                            Text(h.anime.cardTitle).font(.footnote.weight(.semibold)).lineLimit(2)
                                .multilineTextAlignment(.leading)
                            Text(h.episodeTitle).font(.caption2.weight(.medium)).foregroundStyle(Theme.accent).lineLimit(1)
                        }
                        .frame(width: 112, alignment: .leading)
                    }
                    .buttonStyle(.pressable)
                }
            }
            .padding(.horizontal, 14)
        }
        .padding(.horizontal, -14)
    }

    // MARK: Жанры — как на сайте: полоса долей и цветные плашки

    private static let genrePalette: [Color] = [
        Color(hex: "E5615E"), Color(hex: "F07A6A"), Color(hex: "F2956A"), Color(hex: "F4B489"), Color(hex: "EFC75E"),
        Color(hex: "BFD465"), Color(hex: "9ED6D2"), Color(hex: "8EC5E5"), Color(hex: "6C9BD8"), Color(hex: "7B5EA8")
    ]

    /// С сайта, а если он ничего не отдал — по своим тайтлам
    private var genreList: [(String, Int, Int?)] {
        _ = genreStats.version
        let site = genreStats.genres()
        if !site.isEmpty { return site.map { ($0.name, $0.count, $0.id) } }
        return topGenres.map { ($0.0, $0.1, nil) }
    }

    private var genresCard: some View {
        let list = genreList
        let shown = Array(list.prefix(10))
        let rest = list.dropFirst(10).map { $0.1 }.reduce(0, +)
        let total = max(list.map { $0.1 }.reduce(0, +), 1)
        var parts: [(Color, Int)] = shown.enumerated().map { (Self.genrePalette[$0.offset % Self.genrePalette.count], $0.element.1) }
        if rest > 0 { parts.append((Color.gray.opacity(0.5), rest)) }
        return cardBox {
            shareBar(parts)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 10) {
                    ForEach(Array(shown.enumerated()), id: \.offset) { i, g in
                        Button {
                            if let id = g.2 { AppRouter.shared.openCatalog(genre: id) }
                        } label: {
                            VStack(spacing: 6) {
                                Text(g.0)
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(.white)
                                    .lineLimit(1)
                                    .padding(.horizontal, 12).padding(.vertical, 7)
                                    .background(Self.genrePalette[i % Self.genrePalette.count].gradient,
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                                HStack(spacing: 4) {
                                    Text("\(g.1)").font(.subheadline.weight(.semibold).monospacedDigit())
                                    Text("· \(Int((Double(g.1) / Double(total) * 100).rounded()))%")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .buttonStyle(.pressable)
                        .disabled(g.2 == nil)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.horizontal, -16)
            if let d = genreStats.debug[LibSite.current.key], genreStats.genres().isEmpty {
                Text("Сайт отдал статистику в незнакомом виде, жанры посчитаны по твоим тайтлам. Пришли этот текст разработчику:")
                    .font(.caption2).foregroundStyle(.secondary)
                Text(d).font(.system(size: 9, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
    }

    // MARK: За неделю

    private var weekCard: some View {
        let days = week
        let total = days.map { $0.1 }.reduce(0, +)
        let top = max(days.map { $0.1 }.max() ?? 0, 1)
        return cardBox {
            HStack(alignment: .firstTextBaseline) {
                Text(total == 0 ? "Пока ни одной \(book ? "главы" : "серии")" : "\(total) \(book ? "гл." : "эп.")")
                    .font(.title3.bold().monospacedDigit())
                Spacer()
                Text("за 7 дней").font(.subheadline).foregroundStyle(.secondary)
            }
            HStack(alignment: .bottom, spacing: 8) {
                ForEach(Array(days.enumerated()), id: \.offset) { i, d in
                    VStack(spacing: 6) {
                        Text(d.1 > 0 ? "\(d.1)" : " ").font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(d.1 > 0
                                  ? AnyShapeStyle(LinearGradient(colors: [Theme.accent2, Theme.accent], startPoint: .top, endPoint: .bottom))
                                  : AnyShapeStyle(Color.primary.opacity(0.1)))
                            .frame(height: max(6, 80 * CGFloat(d.1) / CGFloat(top)))
                        Text(d.0).font(.caption2.weight(i == days.count - 1 ? .bold : .regular))
                            .foregroundStyle(i == days.count - 1 ? Theme.accent : Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: 118, alignment: .bottom)
        }
    }

    // MARK: Достижения — уровни по тому, что уже известно

    private struct Achievement: Identifiable {
        let id: String
        let icon: String
        let colors: [Color]
        let title: String
        let value: Int
        let steps: [Int]
        let unit: String
        var level: Int { steps.filter { value >= $0 }.count }
        var next: Int? { steps.first { value < $0 } }
    }

    private func achievements(_ u: ProfileUser) -> [Achievement] {
        let chapters = activity.days.values.map { book ? $0.manga + $0.novels : $0.episodes }.reduce(0, +)
        return [
            Achievement(id: "streak", icon: "flame.fill", colors: [Color(hex: "FF9F0A"), Color(hex: "FF453A")],
                        title: "Дней подряд", value: u.streak ?? 0, steps: [3, 7, 30, 100, 365], unit: "дн."),
            Achievement(id: "read", icon: book ? "book.fill" : "play.fill", colors: [Theme.accent, Theme.accent2],
                        title: book ? "Глав прочитано" : "Серий просмотрено", value: chapters,
                        steps: [10, 100, 500, 1000, 5000], unit: book ? "гл." : "эп."),
            Achievement(id: "done", icon: "trophy.fill", colors: [Color(hex: "FFD60A"), Color(hex: "FF9F0A")],
                        title: book ? "Дочитано" : "Досмотрено", value: doneFolder?.count ?? 0,
                        steps: [1, 10, 50, 100, 500], unit: "тайтл."),
            Achievement(id: "library", icon: "books.vertical.fill", colors: [Color(hex: "64D2FF"), Color(hex: "0A84FF")],
                        title: "В библиотеке", value: vm.totalTitles, steps: [10, 50, 100, 300, 1000], unit: "тайтл.")
        ]
    }

    private func achievementCell(_ a: Achievement) -> some View {
        let unlocked = a.level > 0
        let lo = a.level > 0 ? a.steps[a.level - 1] : 0
        let frac: Double = a.next.map { Double(a.value - lo) / Double(max($0 - lo, 1)) } ?? 1
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(unlocked
                                  ? AnyShapeStyle(LinearGradient(colors: a.colors, startPoint: .topLeading, endPoint: .bottomTrailing))
                                  : AnyShapeStyle(Color.primary.opacity(0.1)))
                    Image(systemName: a.icon).font(.system(size: 17, weight: .bold))
                        .foregroundStyle(unlocked ? Color.white : Color.secondary)
                }
                .frame(width: 40, height: 40)
                .overlay(alignment: .bottomTrailing) {
                    if unlocked {
                        Text("\(a.level)")
                            .font(.system(size: 10, weight: .heavy, design: .rounded))
                            .foregroundStyle(.white)
                            .frame(width: 17, height: 17)
                            .background(Color.black.opacity(0.75), in: Circle())
                            .overlay(Circle().stroke(Color.white.opacity(0.6), lineWidth: 0.8))
                            .offset(x: 3, y: 3)
                    }
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(a.title).font(.caption).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
                    Text("\(a.value)").font(.title3.bold().monospacedDigit())
                }
            }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.1))
                    Capsule().fill(LinearGradient(colors: a.colors, startPoint: .leading, endPoint: .trailing))
                        .frame(width: max(4, g.size.width * min(max(frac, 0), 1)))
                }
            }
            .frame(height: 5)
            Text(a.next.map { "до уровня \(a.level + 1): \($0) \(a.unit)" } ?? "максимальный уровень")
                .font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(showcaseCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay {
            if scheme != .dark {
                RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Color.white.opacity(0.9), lineWidth: 0.6)
            }
        }
    }

    @ViewBuilder
    private func showcase(_ u: ProfileUser) -> some View {
        let favs = favoriteTitles
        if !favs.isEmpty {
            showcaseHeader("Любимые") { AppRouter.shared.openFavorites(folder: siteFolders.favorite?.id) }
                .padding(.top, 6)
            coverRail(Array(favs.prefix(15)))
        }

        let recent = Array(history.items.prefix(10))
        if !recent.isEmpty {
            showcaseHeader(book ? "Сейчас читаю" : "Сейчас смотрю").padding(.top, 6)
            recentRail(recent)
        }

        if genreList.count >= 3 {
            showcaseHeader("Жанры").padding(.top, 6)
            genresCard
        }

        showcaseHeader("За неделю").padding(.top, 6)
        weekCard

        showcaseHeader("Достижения").padding(.top, 6)
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            ForEach(achievements(u)) { achievementCell($0) }
        }
        Color.clear.frame(height: 90)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                if let u = auth.user {
                    VStack(spacing: 16) {
                        profileHeader(u)
                            .padding(.horizontal, -14)
                            .padding(.top, -14)

                        friendsTile(userID: u.id)

                        if u.cover == nil && !auth.coverDebug.isEmpty {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Баннер профиля не найден. Пришли этот текст разработчику:")
                                    .font(.caption2).foregroundStyle(.secondary)
                                Text(auth.coverDebug)
                                    .font(.system(size: 9, design: .monospaced))
                                    .textSelection(.enabled)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }

                        if !vm.folders.isEmpty { libraryCard }

                        if let e = vm.error {
                            Text(e).font(.footnote).foregroundStyle(.red)
                        }
                        showcase(u)
                    }
                    .padding(14)
                } else if auth.token != nil {
                    VStack(spacing: 12) {
                        ProgressView()
                        if let e = auth.error {
                            Text(e).font(.footnote).foregroundStyle(.red)
                            Button("Повторить") { Task { await auth.refreshUser() } }
                            Button("Выйти") { auth.signOut() }.foregroundStyle(.red)
                        }
                    }
                    .padding(.top, 80)
                } else {
                    VStack(spacing: 16) {
                        Image(systemName: "person.crop.circle.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(Theme.accent)
                        Text("Профиль").font(.title2.bold())
                        Text("Войдите через сайт, чтобы видеть свои списки: смотрю, в планах, просмотрено и другие.")
                            .multilineTextAlignment(.center)
                            .foregroundStyle(.secondary)
                        if let e = auth.error {
                            Text(e).font(.footnote).foregroundStyle(.orange)
                        }
                        Button { showLogin = true } label: {
                            Text("Войти через сайт")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                                .foregroundStyle(.white)
                        }
                        .buttonStyle(.pressable)
                    }
                    .padding(24)
                    .padding(.top, 40)
                }
            }
            .coordinateSpace(name: "profileScroll")
            .ignoresSafeArea(edges: auth.user != nil ? .top : [])
            .background {
                ZStack {
                    AppBackground()
                    if auth.user != nil, let t = tint {
                        // вся страница слегка окрашена в цвета обложки
                        LinearGradient(colors: [t.opacity(0.45), t.opacity(0.12), .clear],
                                       startPoint: .top, endPoint: .bottom)
                            .ignoresSafeArea()
                            .allowsHitTesting(false)
                    }
                }
            }
            .fullScreenCover(item: $viewer) { ProfileImageViewer(item: $0) }
            .sheet(isPresented: $showLook) { NavigationStack { ProfileAppearanceView() } }
            .sheet(item: $styleFolder) { f in FolderStyleSheet(folder: f) }
            .toolbarBackground(.hidden, for: .navBar)
            // в профиле своя панель кнопок (нейтральное стекло), системная скрыта
            .toolbar(auth.user != nil ? .hidden : .visible, for: .navBar)
            .onPreferenceChange(ProfileScrollKey.self) { scrollY = $0 }
            .onReceive(RateLimitState.shared.$resumed.dropFirst()) { _ in
                if vm.error != nil { Task { await vm.loadFolders() } }
            }
            .statusBarBlur(opacity: auth.user == nil ? 1 : Double(min(1, max(0, (-scrollY - 110) / 50))))
            .navigationTitle(auth.user != nil ? "" : "Профиль")
            .navigationBarTitleDisplayMode(.inline)
            .confirmationDialog("Выйти из аккаунта?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Выйти", role: .destructive) { auth.signOut() }
                Button("Отмена", role: .cancel) {}
            }
            .navigationDestination(for: Anime.self) { DetailView(anime: $0) }
            .navigationDestination(for: Novel.self) { NovelDetailView(novel: $0) }
            .sheet(isPresented: $showLogin) { LoginSheet() }
            .task(id: auth.user?.id) {
                if let u = auth.user, let t = auth.token {
                    if !friendsVM.loaded { Task { await friendsVM.load(userID: u.id, token: t) } }
                    vm.configure(userID: u.id, token: t)
                    vm.loadItems = false
                    await vm.loadFolders()
                    await SiteListSync.syncIfDue()
                    await genreStats.load(userID: u.id, token: t)
                }
            }
        }
    }
}
