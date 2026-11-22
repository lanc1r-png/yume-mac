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

// MARK: - JSON-помощники (формат ответов сайта разный, разбираем мягко)
enum J {
    static func obj(_ d: Data) -> Any? { try? JSONSerialization.jsonObject(with: d) }

    static func int(_ v: Any?) -> Int? {
        if let i = v as? Int { return i }
        if let d = v as? Double { return Int(d) }
        if let s = v as? String { return Int(s) }
        return nil
    }

    static func str(_ v: Any?) -> String? {
        if let s = v as? String, !s.isEmpty { return s }
        return nil
    }

    /// Строка из числа или строки (номера глав приходят и так, и так).
    static func s(_ v: Any?) -> String? {
        if let x = v as? String { return x.isEmpty ? nil : x }
        if let i = v as? Int { return String(i) }
        if let d = v as? Double { return d == d.rounded() ? String(Int(d)) : String(d) }
        return nil
    }

    static func text(_ v: Any?) -> String {
        if let s = v as? String { return stripHTML(s) }
        if let d = v as? [String: Any] {
            let type = (d["type"] as? String) ?? ""
            if type == "text" { return (d["text"] as? String) ?? "" }
            let inner = ((d["content"] as? [Any]) ?? []).map { text($0) }.joined()
            switch type {
            case "paragraph", "heading": return inner + "\n"
            case "hardBreak": return "\n"
            default: return inner
            }
        }
        if let a = v as? [Any] { return a.map { text($0) }.joined() }
        return ""
    }

    static func stripHTML(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var t = s.replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: "</p>", with: "\n")
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        return t.replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
    }

    static func url(_ v: Any?) -> URL? {
        var s: String?
        if let x = v as? String { s = x }
        else if let d = v as? [String: Any] {
            s = str(d["url"]) ?? str(d["default"]) ?? str(d["md"]) ?? str(d["thumbnail"]) ?? str(d["src"])
        }
        guard var t = s else { return nil }
        if t.hasPrefix("//") { t = "https:" + t }
        if t.hasPrefix("/") { t = "https://cover.cdnlibs.org" + t }
        return URL(string: t)
    }

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    private static let outFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ru_RU")
        f.dateFormat = "d MMM yyyy"
        return f
    }()

    static func date(_ s: String?) -> String {
        guard let s = s else { return "" }
        if let d = isoFrac.date(from: s) ?? isoPlain.date(from: s) { return outFmt.string(from: d) }
        return String(s.prefix(10))
    }
}

// MARK: - Keychain (токен входа хранится в защищённом хранилище)
enum Keychain {
    /// Значения держим в памяти: токен читается на каждый сетевой запрос, а Keychain — сравнительно медленный вызов.
    private static let lock = NSLock()
    private static var cache: [String: String] = [:]

    static func set(_ value: String, key: String) {
        lock.lock(); cache[key] = value; lock.unlock()
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrAccount as String: key]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = Data(value.utf8)
        SecItemAdd(add as CFDictionary, nil)
    }

    static func get(_ key: String) -> String? {
        lock.lock()
        if let v = cache[key] { lock.unlock(); return v }
        lock.unlock()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key,
                                kSecReturnData as String: true,
                                kSecMatchLimit as String: kSecMatchLimitOne]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess,
              let d = out as? Data, let v = String(data: d, encoding: .utf8) else { return nil }
        lock.lock(); cache[key] = v; lock.unlock()
        return v
    }

    static func delete(_ key: String) {
        lock.lock(); cache[key] = nil; lock.unlock()
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }
}
