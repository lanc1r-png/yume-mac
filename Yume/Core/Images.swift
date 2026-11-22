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

// MARK: - Images (с заголовком Referer)
final class ImageCache {
    static let shared: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 260 * 1024 * 1024
        c.countLimit = 500
        return c
    }()

    static func key(_ url: URL, _ px: CGFloat) -> NSString { "\(url.absoluteString)#\(Int(px))" as NSString }

    static func store(_ img: UIImage, _ key: NSString) {
        let cost = Int(img.size.width * img.scale * img.size.height * img.scale * 4)
        shared.setObject(img, forKey: key, cost: cost)
    }
}

/// Загрузка картинок: общий дисковый кэш, один запрос на один адрес,
/// декодирование и уменьшение вне главного потока.
actor ImageLoader {
    static let shared = ImageLoader()
    private let session: URLSession
    private var inflight: [String: Task<UIImage?, Never>] = [:]

    init() {
        let cfg = URLSessionConfiguration.default
        cfg.urlCache = ImageLoader.diskCache
        cfg.requestCachePolicy = .returnCacheDataElseLoad
        cfg.httpMaximumConnectionsPerHost = 8
        cfg.timeoutIntervalForRequest = 20
        session = URLSession(configuration: cfg)
    }

    func clearDisk() { session.configuration.urlCache?.removeAllCachedResponses() }

    /// Дисковый кэш обложек (до 500 МБ).
    nonisolated static let diskCache = URLCache(memoryCapacity: 24 * 1024 * 1024, diskCapacity: 500 * 1024 * 1024, diskPath: "hehe-images")

    /// Сколько занимают оба временных кэша картинок: обложки и просмотренные страницы манги (не скачанные главы).
    nonisolated static var cachesBytes: Int { diskCache.currentDiskUsage + MangaImageStore.diskCache.currentDiskUsage }

    /// Очищает оба кэша картинок: в памяти и на диске. Скачанные главы не трогаются.
    nonisolated static func clearAllCaches() {
        ImageCache.shared.removeAllObjects()
        diskCache.removeAllCachedResponses()
        MangaImageStore.diskCache.removeAllCachedResponses()
    }

    func image(_ url: URL, referer: String, maxPixel: CGFloat) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))"
        if let t = inflight[key] { return await t.value }
        let session = self.session
        let t = Task.detached(priority: .userInitiated) { () -> UIImage? in
            for attempt in 0..<3 {
                if Task.isCancelled { return nil }
                var req = URLRequest(url: url)
                req.setValue(referer, forHTTPHeaderField: "Referer")
                req.setValue("image/*", forHTTPHeaderField: "Accept")
                if let (data, resp) = try? await session.data(for: req),
                   (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
                   let img = ImageLoader.downsample(data, maxPixel: maxPixel) {
                    return img
                }
                try? await Task.sleep(nanoseconds: UInt64(500_000_000 * (attempt + 1)))
            }
            return nil
        }
        inflight[key] = t
        let r = await t.value
        inflight[key] = nil
        return r
    }

    /// Для страниц манги: уменьшаем по ширине (не больше width пикселей), а длинным лентам разрешаем большую высоту.
    nonisolated static func downsampleWidth(_ data: Data, width: CGFloat, maxSide: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        guard let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let pw = props[kCGImagePropertyPixelWidth] as? CGFloat,
              let ph = props[kCGImagePropertyPixelHeight] as? CGFloat, pw > 0, ph > 0 else {
            return downsample(data, maxPixel: 4096)
        }
        // Обычные страницы держим крупнее, чтобы при зуме не мылились; длинные ленты — как было.
        let target = ph / pw <= 2.2 ? width * 1.7 : width
        let scale = min(1, target / pw)
        let side = min(max(pw, ph) * scale, maxSide)
        return downsample(data, maxPixel: max(side, 64))
    }

    nonisolated static func downsample(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        let srcOpts = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let src = CGImageSourceCreateWithData(data as CFData, srcOpts) else { return nil }
        let opts = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ] as CFDictionary
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts) else { return nil }
        return UIImage(cgImage: cg)
    }
}

extension ImageLoader {
    /// Заранее подгружает обложки, которые ещё не показаны на экране.
    nonisolated static func prefetch(_ urls: [URL], maxPixel: CGFloat = 480) {
        let list = Array(urls.prefix(40))
        guard !list.isEmpty else { return }
        let referer = LibSite.current.referer
        Task.detached(priority: .utility) {
            var start = 0
            while start < list.count {
                let chunk = Array(list[start..<min(start + 4, list.count)])
                start += 4
                await withTaskGroup(of: Void.self) { group in
                    for u in chunk {
                        group.addTask {
                            let key = ImageCache.key(u, maxPixel)
                            if ImageCache.shared.object(forKey: key) != nil { return }
                            if let img = await ImageLoader.shared.image(u, referer: referer, maxPixel: maxPixel) {
                                ImageCache.store(img, key)
                            }
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Анимированные картинки (GIF, WebP, APNG)
enum AnimatedLoader {
    private static let cache: NSCache<NSString, UIImage> = {
        let c = NSCache<NSString, UIImage>()
        c.totalCostLimit = 60_000_000
        return c
    }()

    static func cached(_ url: URL, _ px: CGFloat) -> UIImage? {
        cache.object(forKey: "\(url.absoluteString)#\(Int(px))" as NSString)
    }

    static func load(_ url: URL, maxPixel: CGFloat, referer: String) async -> UIImage? {
        let key = "\(url.absoluteString)#\(Int(maxPixel))" as NSString
        if let c = cache.object(forKey: key) { return c }
        let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            var req = URLRequest(url: url)
            req.setValue(referer, forHTTPHeaderField: "Referer")
            req.setValue("image/*", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req),
                  (resp as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true
            else { return nil }
            return AnimatedLoader.decode(data, maxPixel: maxPixel)
        }.value
        if let img {
            let frames = max(1, img.images?.count ?? 1)
            cache.setObject(img, forKey: key, cost: Int(img.size.width * img.size.height * 4) * frames)
        }
        return img
    }

    nonisolated static func decode(_ data: Data, maxPixel: CGFloat) -> UIImage? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let n = CGImageSourceGetCount(src)
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if n <= 1 {
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
            return UIImage(cgImage: cg)
        }
        // Ключи ImageIO для GIF, WebP и APNG записаны строками: так они есть во всех версиях SDK.
        let dicts = ["{GIF}", "{WebP}", "{PNG}"]
        func delay(_ i: Int) -> Double {
            guard let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any] else { return 0.1 }
            for name in dicts {
                if let d = props[name] as? [String: Any] {
                    let v = (d["UnclampedDelayTime"] as? Double) ?? (d["DelayTime"] as? Double) ?? 0
                    if v > 0 || d["DelayTime"] != nil || d["UnclampedDelayTime"] != nil {
                        return v < 0.02 ? 0.1 : v
                    }
                }
            }
            return 0.1
        }
        // Слишком длинные анимации прореживаем, чтобы не съесть память.
        let step = Int((Double(n) / 90).rounded(.up))
        var frames: [UIImage] = []
        var total = 0.0
        var i = 0
        while i < n {
            if let cg = CGImageSourceCreateThumbnailAtIndex(src, i, opts as CFDictionary) {
                frames.append(UIImage(cgImage: cg))
            }
            for j in i..<min(i + step, n) { total += delay(j) }
            i += step
        }
        if frames.isEmpty { return nil }
        if frames.count == 1 { return frames[0] }
        return UIImage.animatedImage(with: frames, duration: max(total, 0.4))
    }
}

struct AnimatedImageView: View {
    let image: UIImage
    var fit = false

    var body: some View {
        if let frames = image.animationFrames, frames.count > 1, image.animationDuration > 0 {
            let total = image.animationDuration
            TimelineView(.animation) { ctx in
                let t = ctx.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: total)
                let i = min(Int(t / total * Double(frames.count)), frames.count - 1)
                Image(nsImage: frames[i]).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
            }
        } else {
            Image(nsImage: image).resizable().aspectRatio(contentMode: fit ? .fit : .fill)
        }
    }
}

/// Как RemoteImage, но GIF и другие анимации воспроизводятся.
struct AnimatedRemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 400
    /// Показать целиком (без обрезки), для просмотра на весь экран
    var fit = false
    @State private var image: UIImage?

    var body: some View {
        Rectangle().fill(fit ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.quaternary))
            .overlay {
                if let image { AnimatedImageView(image: image, fit: fit).transition(.opacity) }
            }
            .clipped()
            .task(id: url) {
                guard let url else { return }
                if let c = AnimatedLoader.cached(url, maxPixel) { image = c; return }
                image = nil
                if let img = await AnimatedLoader.load(url, maxPixel: maxPixel, referer: LibSite.current.referer) {
                    withAnimation(.easeOut(duration: 0.25)) { image = img }
                }
            }
    }
}

struct RemoteImage: View {
    let url: URL?
    var maxPixel: CGFloat = 480
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Rectangle().fill(.quaternary)
            .overlay {
                if let image {
                    Image(uiImage: image).resizable().scaledToFill().transition(.opacity).allowsHitTesting(false)
                } else if failed {
                    Image(systemName: "photo").foregroundStyle(.secondary)
                }
            }
            .clipped()
            .contentShape(Rectangle())
            .task(id: url) { await load() }
    }

    private func load() async {
        guard let url else { failed = true; return }
        if url.isFileURL {
            // Скачанная обложка: читаем и уменьшаем в фоне, а не целиком на главном потоке.
            let key = ImageCache.key(url, maxPixel)
            if let cached = ImageCache.shared.object(forKey: key) { image = cached; return }
            let px = maxPixel
            let img = await Task.detached(priority: .userInitiated) { () -> UIImage? in
                guard let d = try? Data(contentsOf: url) else { return nil }
                return ImageLoader.downsample(d, maxPixel: px)
            }.value
            if let img { ImageCache.store(img, key); image = img } else { failed = true }
            return
        }
        let key = ImageCache.key(url, maxPixel)
        if let cached = ImageCache.shared.object(forKey: key) { image = cached; failed = false; return }
        image = nil
        failed = false
        if let img = await ImageLoader.shared.image(url, referer: LibSite.current.referer, maxPixel: maxPixel) {
            ImageCache.store(img, key)
            withAnimation(.easeOut(duration: 0.25)) { image = img }
        } else if !Task.isCancelled {
            failed = true
        }
    }
}
