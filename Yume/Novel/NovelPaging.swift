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

// MARK: - Ранобэ: постраничное чтение
enum NovelPage: Identifiable {
    case text(Int, NSAttributedString)
    case image(Int, URL)

    var id: Int {
        switch self {
        case .text(let i, _), .image(let i, _): return i
        }
    }
}

/// Режет текст главы на страницы по размеру экрана средствами TextKit.
enum NovelPaginator {
    static func font(_ size: CGFloat, serif: Bool, bold: Bool = false, italic: Bool = false) -> UIFont {
        var d = UIFont.systemFont(ofSize: size).fontDescriptor
        if serif, let s = d.withDesign(.serif) { d = s }
        var traits = d.symbolicTraits
        if bold { traits.insert(.bold) }
        if italic { traits.insert(.italic) }
        d = d.withSymbolicTraits(traits)
        return UIFont(descriptor: d, size: size) ?? UIFont.systemFont(ofSize: size)
    }

    static func split(_ text: NSAttributedString, size: CGSize) -> [NSRange] {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let ns = text.string as NSString
        var ranges: [NSRange] = []
        var loc = 0
        while loc < text.length && ranges.count < 3000 {
            let tc = NSTextContainer(size: size)
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            let glyphs = lm.glyphRange(for: tc)
            if glyphs.length == 0 { break }
            var r = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)
            loc = NSMaxRange(r)
            while r.length > 0 && ns.character(at: r.location) == 10 {
                r.location += 1
                r.length -= 1
            }
            if r.length > 0 { ranges.append(r) }
        }
        return ranges
    }

    static func paginate(blocks: [ReaderBlock], title: String, size: CGSize, fontSize: CGFloat,
                         serif: Bool, lineGap: CGFloat, color: UIColor,
                         bodyAlign: NSTextAlignment = .natural, firstIndent: CGFloat = 0,
                         family: String = "", allBold: Bool = false) -> [NovelPage] {
        let fam = family, ab = allBold
        func font(_ size: CGFloat, serif: Bool, bold: Bool = false, italic: Bool = false) -> UIFont {
            let b = bold || ab
            if !fam.isEmpty, let base = UIFont(name: fam, size: size) {
                var traits = base.fontDescriptor.symbolicTraits
                if b { traits.insert(.bold) }
                if italic { traits.insert(.italic) }
                return UIFont(descriptor: base.fontDescriptor.withSymbolicTraits(traits), size: size) ?? base
            }
            return NovelPaginator.font(size, serif: serif, bold: b, italic: italic)
        }
        var pages: [NovelPage] = []
        let text = NSMutableAttributedString()

        func style(spacing: CGFloat, before: CGFloat = 0, indent: CGFloat = 0,
                   align: NSTextAlignment = .natural, first: CGFloat = 0) -> NSParagraphStyle {
            let p = NSMutableParagraphStyle()
            p.lineSpacing = fontSize * lineGap
            p.paragraphSpacing = spacing
            p.paragraphSpacingBefore = before
            p.headIndent = indent
            p.firstLineHeadIndent = indent + first
            p.alignment = align
            p.lineBreakMode = .byWordWrapping
            return p
        }
        func add(_ s: String, _ f: UIFont, _ st: NSParagraphStyle) {
            text.append(NSAttributedString(string: s, attributes: [.font: f, .foregroundColor: color, .paragraphStyle: st]))
        }
        var globalBase = 0
        func flush() {
            guard text.length > 0 else { return }
            for r in split(text, size: size) {
                let sub = NSMutableAttributedString(attributedString: text.attributedSubstring(from: r))
                sub.addAttribute(.heheBase, value: globalBase + r.location, range: NSRange(location: 0, length: sub.length))
                pages.append(.text(pages.count, sub))
            }
            globalBase += text.length
            text.deleteCharacters(in: NSRange(location: 0, length: text.length))
        }

        let body = font(fontSize, serif: serif)
        add(title + "\n", font(fontSize + 6, serif: serif, bold: true), style(spacing: fontSize))
        for b in blocks {
            switch b {
            case .paragraph(_, let t):
                add(t + "\n", body, style(spacing: fontSize * 0.6, align: bodyAlign, first: firstIndent))
            case .rich(_, let a):
                let st = style(spacing: fontSize * 0.6, align: bodyAlign, first: firstIndent)
                for run in a.runs {
                    let piece = String(a[run.range].characters)
                    let intent = run.inlinePresentationIntent ?? []
                    let f = font(fontSize, serif: serif, bold: intent.contains(.stronglyEmphasized),
                                 italic: intent.contains(.emphasized))
                    add(piece, f, st)
                }
                add("\n", body, st)
            case .heading(_, let t):
                add(t + "\n", font(fontSize + 4, serif: serif, bold: true),
                    style(spacing: fontSize * 0.6, before: fontSize * 0.6))
            case .quote(_, let t):
                add(t + "\n", font(fontSize, serif: serif, italic: true),
                    style(spacing: fontSize * 0.6, indent: 14))
            case .rule:
                add("* * *\n", body, style(spacing: fontSize * 0.6, align: .center))
            case .image(_, let u):
                flush()
                pages.append(.image(pages.count, u))
            }
        }
        flush()
        return pages
    }
}

extension NSAttributedString.Key {
    /// Смещение первого символа страницы в тексте всей главы (нужно для выделений и закладок).
    static let heheBase = NSAttributedString.Key("hehe.base")
}

/// Накладывает цветные выделения на текст страницы.
func applyHighlights(_ t: NSAttributedString, _ list: [Highlight]) -> NSAttributedString {
    guard !list.isEmpty, t.length > 0,
          let base = t.attribute(.heheBase, at: 0, effectiveRange: nil) as? Int else { return t }
    let m = NSMutableAttributedString(attributedString: t)
    let page = NSRange(location: base, length: t.length)
    for h in list {
        let r = NSIntersectionRange(page, NSRange(location: h.start, length: h.length))
        guard r.length > 0 else { continue }
        let local = NSRange(location: r.location - base, length: r.length)
        m.addAttribute(.backgroundColor, value: h.uiColor, range: local)
        if !h.note.isEmpty {
            m.addAttribute(.underlineStyle, value: NSUnderlineStyle.single.rawValue, range: local)
        }
    }
    return m
}

extension NovelPage {
    var plainText: String {
        if case .text(_, let t) = self { return t.string }
        return ""
    }
}

final class PageTextUIView: NSView {
    var text = NSAttributedString() {
        didSet { needsDisplay = true }
    }
    /// Долгое нажатие: диапазон абзаца внутри страницы и его текст.
    var onLongPress: ((NSRange, String) -> Void)?

    override var isFlipped: Bool { true }

    override init(frame: CGRect) {
        super.init(frame: frame)
        let g = NSPressGestureRecognizer(target: self, action: #selector(handleLong(_:)))
        g.minimumPressDuration = 0.5
        addGestureRecognizer(g)
    }

    @objc private func handleLong(_ g: NSPressGestureRecognizer) {
        guard g.state == .began, let cb = onLongPress, text.length > 0 else { return }
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: bounds.width, height: 100_000))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        lm.ensureLayout(for: tc)
        let idx = lm.characterIndex(for: g.location(in: self), in: tc, fractionOfDistanceBetweenInsertionPoints: nil)
        let ns = text.string as NSString
        guard idx < ns.length else { return }
        var r = ns.paragraphRange(for: NSRange(location: idx, length: 0))
        while r.length > 0, ns.character(at: NSMaxRange(r) - 1) == 10 { r.length -= 1 }
        guard r.length > 0 else { return }
        cb(r, ns.substring(with: r))
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func draw(_ dirtyRect: NSRect) {
        let storage = NSTextStorage(attributedString: text)
        let lm = NSLayoutManager()
        storage.addLayoutManager(lm)
        let tc = NSTextContainer(size: CGSize(width: bounds.width, height: 100_000))
        tc.lineFragmentPadding = 0
        lm.addTextContainer(tc)
        let r = lm.glyphRange(for: tc)
        lm.drawBackground(forGlyphRange: r, at: .zero)
        lm.drawGlyphs(forGlyphRange: r, at: .zero)
    }
}

struct PageText: UIViewRepresentable {
    let text: NSAttributedString
    var onLongPress: ((NSRange, String) -> Void)? = nil

    func makeUIView(context: Context) -> PageTextUIView {
        let v = PageTextUIView(frame: .zero)
        v.text = text
        v.onLongPress = onLongPress
        return v
    }

    func updateUIView(_ v: PageTextUIView, context: Context) {
        v.onLongPress = onLongPress
        if !v.text.isEqual(to: text) { v.text = text }
    }
}

/// Одна страница книги: текст или иллюстрация на фоне темы, с номером внизу.
struct NovelPageCard: View {
    let page: NovelPage
    let number: Int
    let total: Int
    let bg: Color
    let fg: Color
    let margins: UIEdgeInsets
    let onTap: (CGFloat) -> Void
    var highlights: [Highlight] = []
    var onLongPress: ((NSRange, String) -> Void)? = nil

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - margins.left - margins.right
            let h = geo.size.height - margins.top - margins.bottom
            ZStack {
                bg
                Group {
                    switch page {
                    case .text(_, let t):
                        PageText(text: applyHighlights(t, highlights), onLongPress: { local, str in
                            let base = (t.attribute(.heheBase, at: 0, effectiveRange: nil) as? Int) ?? 0
                            onLongPress?(NSRange(location: base + local.location, length: local.length), str)
                        })
                    case .image(_, let u):
                        FitImage(url: u)
                    }
                }
                .frame(width: w, height: h, alignment: .topLeading)
                .position(x: margins.left + w / 2, y: margins.top + h / 2)

                Text("\(number) / \(total)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(fg.opacity(0.45))
                    .position(x: geo.size.width / 2, y: geo.size.height - max(margins.bottom / 2 - 12, 20))
            }
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { v in onTap(v.location.x / max(geo.size.width, 1)) })
        }
        .ignoresSafeArea()
    }
}
