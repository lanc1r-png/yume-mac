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

// MARK: - Models

struct Envelope<T: Decodable>: Decodable {
    let data: T
    let meta: PageMeta?
}

struct PageMeta: Decodable {
    let hasNextPage: Bool?
    let currentPage: Int?

    enum CodingKeys: String, CodingKey {
        case hasNextPage = "has_next_page"
        case currentPage = "current_page"
    }
}

struct NamedItem: Codable, Hashable {
    let id: Int?
    let name: String?
    let label: String?
    let slug: String?
    var title: String { name ?? label ?? "" }

    enum CodingKeys: String, CodingKey { case id, name, label, slug = "slug_url" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? c.decode(Int.self, forKey: .id))
            ?? (try? c.decode(String.self, forKey: .id)).flatMap { Int($0) }
        name = try? c.decode(String.self, forKey: .name)
        label = try? c.decode(String.self, forKey: .label)
        slug = try? c.decode(String.self, forKey: .slug)
    }
}

struct RichNode: Decodable {
    let type: String?
    let text: String?
    let content: [RichNode]?

    var plainText: String {
        if type == "text" { return text ?? "" }
        let inner = (content ?? []).map { $0.plainText }.joined()
        switch type {
        case "paragraph", "heading": return inner + "\n"
        case "hardBreak": return "\n"
        default: return inner
        }
    }
}

struct RichText: Decodable {
    let text: String
    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let s = try? c.decode(String.self) {
            text = s
        } else if let node = try? c.decode(RichNode.self) {
            text = node.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            text = ""
        }
    }
}

struct Cover: Codable, Hashable {
    let thumbnail: String?
    let `default`: String?
    let md: String?
}

struct RatingBox: Decodable {
    let average: String?
    let votes: Int?
    enum K: String, CodingKey { case average, votes }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        if let v = try? c.decode(Int.self, forKey: .votes) { votes = v }
        else if let sv = try? c.decode(String.self, forKey: .votes), let v = Int(sv) { votes = v }
        else { votes = nil }
        if let s = try? c.decode(String.self, forKey: .average) { average = s }
        else if let x = try? c.decode(Double.self, forKey: .average) { average = String(format: "%.1f", x) }
        else { average = nil }
    }
}

extension String {
    /// Без переносов внутри слов: iOS сама ставит «примор-ского» в коротких названиях.
    /// Между буквами одного слова — невидимый «соединитель слов» (U+2060): строка переносится только между словами.
    var noHyphens: String {
        var out = ""
        out.reserveCapacity(count * 2)
        var prevLetter = false
        for ch in self {
            let letter = ch.isLetter || ch.isNumber
            if letter && prevLetter { out.append("\u{2060}") }
            out.append(ch)
            prevLetter = letter
        }
        return out
    }
}

struct Anime: Codable, Identifiable, Hashable {
    private enum RatingKeys: String, CodingKey { case rating }

    let id: Int
    let name: String?
    let rusName: String?
    let engName: String?
    let slugUrl: String?
    let cover: Cover?
    let summary: String?
    let genres: [NamedItem]?
    let tags: [NamedItem]?
    let authors: [NamedItem]?
    let otherNames: [String]?
    let episodesCount: Int?
    let rateAvg: String?
    let rateVotes: Int?
    let status: NamedItem?
    let type: NamedItem?
    let ageRestriction: NamedItem?
    let releaseDateString: String?

    var displayTitle: String {
        if let r = rusName, !r.isEmpty { return r }
        return name ?? engName ?? "Без названия"
    }
    /// Название для карточек: без переносов внутри слов
    var cardTitle: String { displayTitle.noHyphens }
    /// Для карточек. У манги и ранобэ миниатюра слишком мелкая и выглядит пиксельной, берём средний размер.
    var imageURL: URL? {
        let s = LibSite.current.isBook
            ? (cover?.md ?? cover?.default ?? cover?.thumbnail)
            : (cover?.thumbnail ?? cover?.md ?? cover?.default)
        return s.flatMap(URL.init(string:))
    }
    /// Для крупных карточек на главной: средний размер, чтобы не мылилось.
    var posterURL: URL? {
        (cover?.md ?? cover?.default ?? cover?.thumbnail).flatMap(URL.init(string:))
    }
    /// Для крупной обложки на странице тайтла.
    var largeImageURL: URL? {
        (cover?.default ?? cover?.md ?? cover?.thumbnail).flatMap(URL.init(string:))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, summary, genres, tags, authors, cover, status, type
        case rusName = "rus_name"
        case engName = "eng_name"
        case slugUrl = "slug_url"
        case otherNames
        case episodesCount = "episodes_count"
        case rateAvg = "rate_avg"
        case ageRestriction
        case releaseDateString
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        rusName = try? c.decode(String.self, forKey: .rusName)
        engName = try? c.decode(String.self, forKey: .engName)
        slugUrl = try? c.decode(String.self, forKey: .slugUrl)
        cover = try? c.decode(Cover.self, forKey: .cover)
        summary = (try? c.decode(RichText.self, forKey: .summary))?.text
        genres = try? c.decode([NamedItem].self, forKey: .genres)
        tags = try? c.decode([NamedItem].self, forKey: .tags)
        authors = try? c.decode([NamedItem].self, forKey: .authors)
        otherNames = try? c.decode([String].self, forKey: .otherNames)
        episodesCount = try? c.decode(Int.self, forKey: .episodesCount)
        status = try? c.decode(NamedItem.self, forKey: .status)
        type = try? c.decode(NamedItem.self, forKey: .type)
        ageRestriction = try? c.decode(NamedItem.self, forKey: .ageRestriction)
        releaseDateString = try? c.decode(String.self, forKey: .releaseDateString)
        rateVotes = (try? decoder.container(keyedBy: RatingKeys.self))
            .flatMap { try? $0.decode(RatingBox.self, forKey: .rating) }?.votes
        if let s = try? c.decode(String.self, forKey: .rateAvg) { rateAvg = s }
        else if let d = try? c.decode(Double.self, forKey: .rateAvg) { rateAvg = String(format: "%.1f", d) }
        else if let rc = try? decoder.container(keyedBy: RatingKeys.self),
                let rb = try? rc.decode(RatingBox.self, forKey: .rating),
                let av = rb.average { rateAvg = av }
        else { rateAvg = nil }
    }
}

struct EpisodeShort: Decodable, Identifiable, Hashable {
    let id: Int
    let name: String?
    let number: String?
    let season: String?
    let date: String?

    var title: String {
        let n = number.map { "Серия \($0)" } ?? "Серия"
        if let name, !name.isEmpty { return "\(n) · \(name)" }
        return n
    }

    enum CodingKeys: String, CodingKey { case id, name, number, season, date = "created_at" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try? c.decode(String.self, forKey: .name)
        season = (try? c.decode(String.self, forKey: .season))
            ?? (try? c.decode(Int.self, forKey: .season)).map(String.init)
        number = (try? c.decode(String.self, forKey: .number))
            ?? (try? c.decode(Int.self, forKey: .number)).map(String.init)
        date = try? c.decode(String.self, forKey: .date)
    }
}

struct VideoQuality: Decodable, Hashable {
    let href: String?
    let quality: Int?
}

struct VideoInfo: Decodable, Hashable {
    let quality: [VideoQuality]?
}

struct SubtitleInfo: Decodable, Hashable {
    let src: String?
    let format: String?
}

struct Team: Decodable, Hashable {
    let name: String?
}

struct EpisodePlayer: Decodable, Hashable {
    let id: Int?
    let player: String?
    let team: Team?
    let translationType: NamedItem?
    let video: VideoInfo?
    let subtitles: [SubtitleInfo]?
    let src: String?

    var isNative: Bool { (player ?? "").lowercased() == "animelib" }
    var label: String {
        let t = team?.name ?? "—"
        let k = translationType?.title ?? ""
        return k.isEmpty ? t : "\(t) (\(k))"
    }

    enum CodingKeys: String, CodingKey {
        case id, player, team, video, subtitles, src
        case translationType = "translation_type"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(Int.self, forKey: .id)
        player = try? c.decode(String.self, forKey: .player)
        team = try? c.decode(Team.self, forKey: .team)
        translationType = try? c.decode(NamedItem.self, forKey: .translationType)
        video = try? c.decode(VideoInfo.self, forKey: .video)
        subtitles = try? c.decode([SubtitleInfo].self, forKey: .subtitles)
        src = try? c.decode(String.self, forKey: .src)
    }
}

struct EpisodeDetail: Decodable {
    let id: Int
    let players: [EpisodePlayer]?
}

struct VideoServer: Decodable, Hashable {
    let id: String?
    let label: String?
    let url: String?
}

struct Constants: Decodable {
    let videoServers: [VideoServer]?
}

struct PlayableVariant: Identifiable, Hashable {
    let id = UUID()
    let title: String
    let url: URL
    let subtitle: URL?
    var isWeb = false
    var kodik = false
    var player = ""
    var options: [PlayableVariant] = []
    var alts: [URL] = []
}

struct FilterOptions {
    var genres: [NamedItem] = []
    var tags: [NamedItem] = []
    var types: [NamedItem] = []
    var statuses: [NamedItem] = []
    var isEmpty: Bool { genres.isEmpty && tags.isEmpty && types.isEmpty && statuses.isEmpty }
}
