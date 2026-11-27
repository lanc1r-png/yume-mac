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

// MARK: - Kodik (прямое получение потока)
enum KodikError: LocalizedError {
    case page, params, noLinks, decode
    case server(String)
    var errorDescription: String? {
        switch self {
        case .page: return "не открылась страница плеера"
        case .params: return "не найдены параметры плеера"
        case .noLinks: return "плеер не вернул ссылки на видео"
        case .decode: return "не удалось расшифровать ссылку"
        case .server(let t): return "ответ Kodik: " + t
        }
    }
}

enum Kodik {
    static let ua = "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1"

    static func match(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    static func fetch(_ url: URL, referer: String) async throws -> String {
        var req = URLRequest(url: url)
        req.timeoutInterval = 12
        req.setValue(referer, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        if let code = (resp as? HTTPURLResponse)?.statusCode, code >= 400 { throw KodikError.server("HTTP \(code)") }
        guard let t = String(data: data, encoding: .utf8) else { throw KodikError.page }
        return t
    }

    static func resolve(_ pageURL: URL) async throws -> [(Int, URL)] {
        let html = try await fetch(pageURL, referer: "https://animelib.org/")
        // параметры подписи: ищем каждое поле отдельно, формат страницы может меняться
        var params: [String: Any] = [:]
        for k in ["d", "d_sign", "pd", "pd_sign", "ref", "ref_sign"] {
            if let v = match("\\\\?[\"']" + k + "\\\\?[\"']\\s*:\\s*\\\\?[\"']([^\"'\\\\]*)", in: html) { params[k] = v }
        }
        if params["d_sign"] == nil || params["pd_sign"] == nil {
            let hasKey = html.contains("urlParams")
            let head = String(html.prefix(70)).replacingOccurrences(of: "\n", with: " ")
            throw KodikError.server("нет параметров (страница \(html.count) симв., urlParams: \(hasKey ? "есть" : "нет"), начало: \(head))")
        }

        let parts = pageURL.pathComponents.filter { $0 != "/" }
        let type = match("videoInfo\\.type\\s*=\\s*'([^']+)'", in: html) ?? (parts.count > 0 ? parts[0] : "")
        let id = match("videoInfo\\.id\\s*=\\s*'?([0-9]+)'?", in: html) ?? (parts.count > 1 ? parts[1] : "")
        let hash = match("videoInfo\\.hash\\s*=\\s*'([^']+)'", in: html) ?? (parts.count > 2 ? parts[2] : "")
        guard !type.isEmpty, !id.isEmpty, !hash.isEmpty else { throw KodikError.params }

        // путь запроса прячется в скрипте плеера, по умолчанию /ftor
        var path = "/ftor"
        if let script = match("<script[^>]+src=\"(/assets/js/app\\.player[^\"]+)\"", in: html),
           let su = URL(string: "https://" + (pageURL.host ?? "kodikplayer.com") + script),
           let js = try? await fetch(su, referer: pageURL.absoluteString),
           let b64 = match("url:\\s*atob\\(\\s*[\"']([^\"']+)[\"']\\s*\\)", in: js),
           let d = Data(base64Encoded: b64), let p = String(data: d, encoding: .utf8), p.hasPrefix("/") {
            path = p
        }

        var fields: [(String, String)] = []
        for k in ["d", "d_sign", "pd", "pd_sign", "ref", "ref_sign"] {
            fields.append((k, (params[k] as? String) ?? ""))
        }
        fields += [("bad_user", "true"), ("cdn_is_working", "true"),
                   ("type", type), ("hash", hash), ("id", id), ("info", "{}")]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let body = fields.map { k, v in
            k + "=" + (v.addingPercentEncoding(withAllowedCharacters: allowed) ?? v)
        }.joined(separator: "&")

        guard let ftor = URL(string: "https://" + (pageURL.host ?? "kodikplayer.com") + path) else { throw KodikError.page }
        var req = URLRequest(url: ftor)
        req.timeoutInterval = 12
        req.httpMethod = "POST"
        req.httpBody = body.data(using: .utf8)
        req.setValue("application/x-www-form-urlencoded; charset=UTF-8", forHTTPHeaderField: "Content-Type")
        req.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
        req.setValue("https://" + (pageURL.host ?? "kodikplayer.com"), forHTTPHeaderField: "Origin")
        req.setValue(pageURL.absoluteString, forHTTPHeaderField: "Referer")
        req.setValue(ua, forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let links = obj["links"] as? [String: Any] else {
            let t = String(data: data.prefix(140), encoding: .utf8) ?? ""
            throw KodikError.server(t)
        }

        var result: [(Int, URL)] = []
        for (q, v) in links {
            guard let arr = v as? [[String: Any]], let src = arr.first?["src"] as? String,
                  let quality = Int(q) else { continue }
            guard var text = decode(src) else { throw KodikError.decode }
            if text.hasPrefix("//") { text = "https:" + text }
            if let u = URL(string: text) { result.append((quality, u)) }
        }
        if result.isEmpty { throw KodikError.noLinks }
        return result.sorted { $0.0 > $1.0 }
    }

    /// Ссылка зашифрована сдвигом букв (ROT-N) и base64; перебираем сдвиг.
    static func decode(_ s: String) -> String? {
        if s.hasPrefix("http") || s.hasPrefix("//") { return s }
        for shift in 0..<26 {
            var out = ""
            for c in s.unicodeScalars {
                let v = c.value
                if v >= 65 && v <= 90 {
                    if let u = UnicodeScalar((v - 65 + UInt32(shift)) % 26 + 65) { out.unicodeScalars.append(u) }
                } else if v >= 97 && v <= 122 {
                    if let u = UnicodeScalar((v - 97 + UInt32(shift)) % 26 + 97) { out.unicodeScalars.append(u) }
                } else {
                    out.unicodeScalars.append(c)
                }
            }
            var b = out.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            while b.count % 4 != 0 { b += "=" }
            if let d = Data(base64Encoded: b), let t = String(data: d, encoding: .utf8),
               t.hasPrefix("http") || t.hasPrefix("//") {
                return t
            }
        }
        return nil
    }
}
