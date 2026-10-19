import Foundation
import CoreGraphics
import CoreText
import SwiftUI
import os

/// Glyph outlines from the bundled Bravura font (and the system font for numbers), cached per codepoint.
///
/// Outlines are produced at a font size of 4, so one unit equals one staff space, with y flipped downwards
/// and the SMuFL origin at (0, 0). Thread-safe; shared by every render plan.
final class NotationGlyphOutlines: @unchecked Sendable {
    static let shared = NotationGlyphOutlines()

    private static let logger = Logger(subsystem: "LearnPiano", category: "Notation")
    private let lock = NSLock()
    private var cache: [UInt32: CGPath] = [:]
    private let bravura: CTFont?
    private let textFont: CTFont

    /// Whether the Bravura font could be loaded (noteheads fall back to ellipses otherwise).
    var isBravuraAvailable: Bool { bravura != nil }

    init() {
        bravura = Self.loadBravura()
        textFont = CTFontCreateUIFontForLanguage(.system, 4, nil) ?? CTFontCreateWithName("Helvetica" as CFString, 4, nil)
        if bravura == nil {
            Self.logger.error("Bravura font is unavailable; music glyphs other than noteheads cannot be drawn.")
        }
    }

    /// Loads Bravura by name (registered through UIAppFonts) or, failing that, straight from the bundled file.
    private static func loadBravura() -> CTFont? {
        let named = CTFontCreateWithName("Bravura" as CFString, 4, nil)
        if (CTFontCopyFamilyName(named) as String) == "Bravura" { return named }
        guard let url = Bundle.main.url(forResource: "Bravura", withExtension: "otf") else {
            logger.error("Bravura.otf is missing from the app bundle.")
            return nil
        }
        do {
            let data = try Data(contentsOf: url) as CFData
            guard let descriptor = CTFontManagerCreateFontDescriptorFromData(data) else {
                logger.error("Bravura.otf could not be parsed.")
                return nil
            }
            return CTFontCreateWithFontDescriptor(descriptor, 4, nil)
        } catch {
            logger.error("Reading Bravura.otf failed: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Outline of a SMuFL glyph in staff-space units (y down), or nil when the font or glyph is missing.
    func outline(_ codepoint: UInt32) -> CGPath? {
        lock.lock()
        defer { lock.unlock() }
        if let cached = cache[codepoint] { return cached }
        guard let font = bravura, codepoint <= 0xFFFF else { return nil }
        var character = UniChar(codepoint)
        var glyph = CGGlyph(0)
        guard CTFontGetGlyphsForCharacters(font, &character, &glyph, 1) else { return nil }
        var flip = CGAffineTransform(scaleX: 1, y: -1)
        guard let path = CTFontCreatePathForGlyph(font, glyph, &flip) else { return nil }
        cache[codepoint] = path
        return path
    }

    /// Outline of a short string in the system font at `fontSize` staff spaces, baseline at y = 0 (y down).
    func textOutline(_ string: String, fontSize: CGFloat) -> CGPath {
        let font = CTFontCreateCopyWithAttributes(textFont, fontSize, nil, nil)
        let characters = Array(string.utf16)
        var glyphs = Array(repeating: CGGlyph(0), count: characters.count)
        let path = CGMutablePath()
        guard !characters.isEmpty, CTFontGetGlyphsForCharacters(font, characters, &glyphs, characters.count) else { return path }
        var advances = Array(repeating: CGSize.zero, count: glyphs.count)
        CTFontGetAdvancesForGlyphs(font, .horizontal, glyphs, &advances, glyphs.count)
        var x: CGFloat = 0
        for (glyph, advance) in zip(glyphs, advances) {
            var transform = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: x, ty: 0)
            if let g = CTFontCreatePathForGlyph(font, glyph, &transform) { path.addPath(g) }
            x += advance.width
        }
        return path
    }
}

/// Ink of one event, filled in a single call with the event's feedback colour.
struct NotationEventInk: @unchecked Sendable {
    var id: UUID
    var hand: Hand
    var isRest: Bool
    var path: Path
    /// Notehead frames in points (for the "expected" halo).
    var headRects: [CGRect]
}

/// All ink of one measure, grouped by colouring rule.
struct NotationMeasureInk: @unchecked Sendable {
    var index: Int
    /// Staff lines, clefs, signatures, barlines, numbers.
    var scoreInk: Path
    /// Beams, ties, tuplet numbers and fingering of each hand.
    var rightHandInk: Path
    var leftHandInk: Path
    var events: [NotationEventInk]
    /// Union of everything in this measure (points), for culling.
    var bounds: CGRect

    func handInk(_ hand: Hand) -> Path { hand == .right ? rightHandInk : leftHandInk }
}

/// A layout converted into ready-to-fill paths in points. Built once per layout, off the main thread.
struct NotationRenderPlan: @unchecked Sendable {
    let layout: NotationLayout
    /// Points per staff space.
    let scale: CGFloat
    let measures: [NotationMeasureInk]

    /// Content size in points.
    var contentSize: CGSize { CGSize(width: layout.size.width * scale, height: layout.size.height * scale) }

    /// Converts a layout and its glyphs into per-measure paths.
    static func make(layout: NotationLayout, outlines: NotationGlyphOutlines = .shared) -> NotationRenderPlan {
        let s = layout.options.staffSpace
        let count = layout.measures.count
        let scoreInk = (0..<count).map { _ in CGMutablePath() }
        let handInk: [Hand: [CGMutablePath]] = [.right: (0..<count).map { _ in CGMutablePath() }, .left: (0..<count).map { _ in CGMutablePath() }]
        var eventInk: [UUID: CGMutablePath] = [:]
        var eventHeads: [UUID: [CGRect]] = [:]
        for e in layout.events { eventInk[e.id] = CGMutablePath() }

        func target(_ owner: NotationInkOwner, measure: Int) -> CGMutablePath? {
            guard measure >= 0 && measure < count else { return nil }
            switch owner {
            case .score: return scoreInk[measure]
            case .hand(let h): return handInk[h]?[measure]
            case .event(let id, _): return eventInk[id]
            }
        }

        for g in layout.glyphs {
            guard let path = target(g.owner, measure: g.measureIndex) else { continue }
            let k = s * g.scale
            let transform = CGAffineTransform(a: k, b: 0, c: 0, d: k, tx: g.origin.x * s, ty: g.origin.y * s)
            if let outline = outlines.outline(g.codepoint) {
                path.addPath(outline, transform: transform)
            } else if g.role == .notehead {
                path.addEllipse(in: scaled(g.frame, s))
            }
            if g.role == .notehead, let id = g.owner.eventID {
                eventHeads[id, default: []].append(scaled(g.frame, s))
            }
        }
        for r in layout.rects {
            target(r.owner, measure: r.measureIndex)?.addRect(scaled(r.rect, s))
        }
        func handPath(_ hand: Hand, _ measure: Int) -> CGMutablePath? {
            guard measure >= 0 && measure < count else { return nil }
            return handInk[hand]?[measure]
        }
        for b in layout.beams {
            guard let path = handPath(b.hand, b.measureIndex) else { continue }
            path.move(to: CGPoint(x: b.start.x * s, y: b.start.y * s))
            path.addLine(to: CGPoint(x: b.end.x * s, y: b.end.y * s))
            path.addLine(to: CGPoint(x: b.end.x * s, y: (b.end.y + b.thickness) * s))
            path.addLine(to: CGPoint(x: b.start.x * s, y: (b.start.y + b.thickness) * s))
            path.closeSubpath()
        }
        for t in layout.ties {
            guard let path = handPath(t.hand, t.measureIndex) else { continue }
            addTie(t, to: path, scale: s)
        }
        for t in layout.texts {
            guard t.measureIndex >= 0 && t.measureIndex < count else { continue }
            let outline = outlines.textOutline(t.string, fontSize: t.fontSize)
            scoreInk[t.measureIndex].addPath(outline, transform: CGAffineTransform(a: s, b: 0, c: 0, d: s, tx: t.origin.x * s, ty: t.origin.y * s))
        }

        var measures: [NotationMeasureInk] = []
        for m in layout.measures {
            let i = m.index
            let eventsInMeasure = layout.events[m.eventIndices].map { e in
                NotationEventInk(id: e.id, hand: e.hand, isRest: e.isRest, path: Path(eventInk[e.id] ?? CGMutablePath()), headRects: eventHeads[e.id] ?? [])
            }
            let right = Path(handInk[.right]?[i] ?? CGMutablePath())
            let left = Path(handInk[.left]?[i] ?? CGMutablePath())
            let score = Path(scoreInk[i])
            var bounds = scaled(m.frame, s)
            for p in [score, right, left] + eventsInMeasure.map(\.path) where !p.isEmpty {
                bounds = bounds.union(p.boundingRect)
            }
            measures.append(NotationMeasureInk(index: i, scoreInk: score, rightHandInk: right, leftHandInk: left, events: eventsInMeasure, bounds: bounds.insetBy(dx: -s, dy: -s)))
        }
        return NotationRenderPlan(layout: layout, scale: s, measures: measures)
    }

    private static func scaled(_ r: CGRect, _ s: CGFloat) -> CGRect {
        CGRect(x: r.minX * s, y: r.minY * s, width: r.width * s, height: r.height * s)
    }

    /// A filled crescent between the tie endpoints: thin at the ends, `tieMidpointThickness` in the middle.
    private static func addTie(_ t: NotationTie, to path: CGMutablePath, scale s: CGFloat) {
        let p0 = CGPoint(x: t.start.x * s, y: t.start.y * s)
        let p1 = CGPoint(x: t.end.x * s, y: t.end.y * s)
        let length = hypot(p1.x - p0.x, p1.y - p0.y) / s
        let height = min(1.2, 0.45 + 0.06 * length) * s
        let thickness = NotationEngraving.tieMidpointThickness * s
        let sign: CGFloat = t.above ? -1 : 1
        let dx = (p1.x - p0.x) * 0.25
        // Cubic control points sit at 4/3 of the wanted bulge.
        let outer = sign * height * 4 / 3
        let inner = sign * (height - thickness) * 4 / 3
        path.move(to: p0)
        path.addCurve(to: p1, control1: CGPoint(x: p0.x + dx, y: p0.y + outer), control2: CGPoint(x: p1.x - dx, y: p1.y + outer))
        path.addCurve(to: p0, control1: CGPoint(x: p1.x - dx, y: p1.y + inner), control2: CGPoint(x: p0.x + dx, y: p0.y + inner))
        path.closeSubpath()
    }
}
