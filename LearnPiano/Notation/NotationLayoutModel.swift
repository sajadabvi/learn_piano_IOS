import Foundation
import CoreGraphics

// MARK: - Options

/// How the systems of an engraved score are arranged.
enum NotationLayoutMode: Hashable, Sendable {
    /// One long system for horizontal scrolling (iPad landscape practice screen).
    case scroll
    /// Systems wrapped to a page width given in points (portrait / reading).
    case page(width: CGFloat)
}

/// Inputs that, together with the score, fully determine a `NotationLayout`.
struct NotationLayoutOptions: Hashable, Sendable {
    /// Size of one staff space in points. Bravura is drawn at a font size of four staff spaces.
    var staffSpace: CGFloat
    var mode: NotationLayoutMode
    /// Draw fingering numbers stored on `ChordNote.fingering`.
    var showsFingering: Bool
    /// Draw measure numbers (every measure in scroll mode, at system starts in page mode).
    var showsMeasureNumbers: Bool
    /// Multiplier applied to the proportional spacing in scroll mode (page mode justifies instead).
    var scrollSpacingFactor: CGFloat

    init(staffSpace: CGFloat = 9, mode: NotationLayoutMode = .scroll, showsFingering: Bool = true, showsMeasureNumbers: Bool = true, scrollSpacingFactor: CGFloat = 1.2) {
        self.staffSpace = max(2, staffSpace)
        self.mode = mode
        self.showsFingering = showsFingering
        self.showsMeasureNumbers = showsMeasureNumbers
        self.scrollSpacingFactor = max(0.5, scrollSpacingFactor)
    }

    /// Available system width in staff spaces for page mode (nil in scroll mode).
    var pageWidthInStaffSpaces: CGFloat? {
        if case .page(let width) = mode { return max(20, width / staffSpace) }
        return nil
    }
}

// MARK: - Positioned elements
//
// Every coordinate in a `NotationLayout` is in STAFF SPACES with y growing DOWNWARDS (screen convention).
// The renderer multiplies by `NotationLayoutOptions.staffSpace` to get points.

/// What a glyph represents (used by tests, hit testing and colouring decisions).
enum NotationGlyphRole: String, Hashable, Sendable {
    case brace, clef, keySignature, keyCancellation, timeSignature
    case notehead, accidental, augmentationDot, flag, rest, measureRest
    case fingering, tupletNumber, repeatDot
}

/// Ownership of an element: static ink, ink that belongs to one hand (beams, ties, fingering), or one event.
enum NotationInkOwner: Hashable, Sendable {
    /// Staff lines, clefs, signatures, barlines, measure numbers: always drawn in the ink colour.
    case score
    /// Shared by several events of one hand; dimmed with that hand.
    case hand(Hand)
    /// Belongs to one notated event; coloured by its feedback state.
    case event(UUID, Hand)

    /// The hand the element belongs to, if any.
    var hand: Hand? {
        switch self {
        case .score: return nil
        case .hand(let h): return h
        case .event(_, let h): return h
        }
    }

    /// The owning event, if any.
    var eventID: UUID? {
        if case .event(let id, _) = self { return id }
        return nil
    }
}

/// A SMuFL glyph placed at its origin (left edge, on the baseline).
struct NotationGlyph: Equatable, Sendable {
    var codepoint: UInt32
    var origin: CGPoint
    /// Uniform scale relative to the normal glyph size (1 = font size of four staff spaces).
    var scale: CGFloat
    var role: NotationGlyphRole
    var measureIndex: Int
    var owner: NotationInkOwner

    /// Bounding box in layout coordinates (y down).
    var frame: CGRect {
        let bb = NotationSMuFL.boundingBox(codepoint)
        return CGRect(x: origin.x + bb.left * scale, y: origin.y - bb.top * scale, width: bb.width * scale, height: bb.height * scale)
    }
}

/// Kinds of filled rectangles.
enum NotationRectRole: String, Hashable, Sendable {
    case staffLine, ledgerLine, stem, barline, thickBarline, systemLine, voltaLine
}

/// A filled axis-aligned rectangle (lines are thin rectangles).
struct NotationRect: Equatable, Sendable {
    var rect: CGRect
    var role: NotationRectRole
    var measureIndex: Int
    var owner: NotationInkOwner
}

/// One beam (or beamlet) segment: a parallelogram from `start` to `end` along its outer edge.
struct NotationBeam: Equatable, Sendable {
    /// Outer-edge endpoints (the edge that touches the stem tips for the primary beam).
    var start: CGPoint
    var end: CGPoint
    /// Signed vertical thickness: positive grows downwards (stems up), negative upwards (stems down).
    var thickness: CGFloat
    /// 1 = primary (8th) beam, 2 = 16th, 3 = 32nd.
    var level: Int
    var measureIndex: Int
    var hand: Hand
    /// Events joined by the beam group this segment belongs to.
    var eventIDs: [UUID]
}

/// A tie arc between two noteheads (or a half arc at a system break).
struct NotationTie: Equatable, Sendable {
    var start: CGPoint
    var end: CGPoint
    /// Arc bulges upwards when true.
    var above: Bool
    var measureIndex: Int
    var hand: Hand
    var fromEventID: UUID
    /// The event the tie lands on; nil when no continuation was found (a short "let ring" arc is drawn).
    var toEventID: UUID?
    var midi: Int
}

/// Roles of text items drawn with the system font.
enum NotationTextRole: String, Hashable, Sendable { case measureNumber, volta }

/// A short text (measure number, volta label) placed at its baseline-left origin.
struct NotationTextItem: Equatable, Sendable {
    var string: String
    var origin: CGPoint
    /// Font size in staff spaces.
    var fontSize: CGFloat
    var role: NotationTextRole
    var measureIndex: Int
}

// MARK: - Structure

/// One notehead of a laid-out event.
struct NotationNoteheadLayout: Equatable, Sendable {
    var midi: Int
    var pitch: Pitch
    /// Notehead centre-left origin (glyph origin): x at the left edge, y on the line/space.
    var origin: CGPoint
    /// Staff step from the top line (0 = top line, 8 = bottom line, negative above the staff).
    var staffStep: Int
    /// Moved to the other side of the stem because of a second interval.
    var isDisplaced: Bool
    /// Accidental drawn in front of this head (after accidental memory).
    var accidental: Accidental?
    var fingering: Int?
    var tieStart: Bool
    var tieStop: Bool
}

/// The engraved form of one `MeasureEvent`.
struct NotationEventLayout: Equatable, Sendable {
    var id: UUID
    var measureIndex: Int
    var hand: Hand
    /// Staff the event is drawn on (differs from `hand` for cross-staff notes).
    var staff: Hand
    var voice: Int
    var onset: Ticks
    var duration: Ticks
    var isRest: Bool
    var value: NoteValue
    var dots: Int
    var columnIndex: Int
    /// Column origin x (left edge of a normally placed notehead).
    var x: CGFloat
    var noteheads: [NotationNoteheadLayout]
    /// nil for rests and stemless notes.
    var stemUp: Bool?
    var stem: CGRect?
    /// Index into `NotationLayout.beamGroups` when beamed.
    var beamGroup: Int?
    /// Union of everything drawn for the event.
    var bounds: CGRect
}

/// A beat-group of beamed events.
struct NotationBeamGroup: Equatable, Sendable {
    var measureIndex: Int
    var hand: Hand
    var voice: Int
    var eventIDs: [UUID]
    var stemUp: Bool
}

/// One onset column of a measure (shared by both staves so simultaneous notes align).
struct NotationColumn: Equatable, Sendable {
    /// Onset relative to the measure start.
    var tick: Ticks
    /// Origin x of a normally placed notehead in this column.
    var x: CGFloat
}

/// Placement of one notated measure.
struct NotationMeasureLayout: Equatable, Sendable {
    var index: Int
    var number: Int
    var systemIndex: Int
    /// From the left edge (previous barline) to the right barline, spanning both staves vertically.
    var frame: CGRect
    /// First x after clef/key/time/repeat prefixes.
    var contentStartX: CGFloat
    /// Last x before trailing padding and barline.
    var contentEndX: CGFloat
    var columns: [NotationColumn]
    /// Effective length in ticks.
    var length: Ticks
    /// Start tick in notated order (no repeats).
    var notatedStart: Ticks
    var timeSignature: TimeSignature
    var keySignature: KeySignature
    /// Indices into `NotationLayout.events`.
    var eventIndices: Range<Int>
}

/// One grand-staff system.
struct NotationSystemLayout: Equatable, Sendable {
    var index: Int
    /// Whole system band including paddings.
    var frame: CGRect
    var trebleTop: CGFloat
    var bassTop: CGFloat
    var measureIndices: Range<Int>

    /// Bottom line of the bass staff.
    var bassBottom: CGFloat { bassTop + 4 }
    /// y of the top line of a staff.
    func staffTop(_ staff: Hand) -> CGFloat { staff == .right ? trebleTop : bassTop }
}

// MARK: - Layout

/// The complete engraving of a score for one set of options. Pure value; computed off the main thread and cached.
struct NotationLayout: Sendable {
    var options: NotationLayoutOptions
    /// Content size in staff spaces.
    var size: CGSize
    var systems: [NotationSystemLayout]
    var measures: [NotationMeasureLayout]
    var events: [NotationEventLayout]
    var beamGroups: [NotationBeamGroup]
    var glyphs: [NotationGlyph]
    var rects: [NotationRect]
    var beams: [NotationBeam]
    var ties: [NotationTie]
    var texts: [NotationTextItem]
    /// Event index by event id.
    var eventIndexByID: [UUID: Int]

    /// An empty layout (no measures).
    static func empty(options: NotationLayoutOptions) -> NotationLayout {
        NotationLayout(options: options, size: .zero, systems: [], measures: [], events: [], beamGroups: [], glyphs: [], rects: [], beams: [], ties: [], texts: [], eventIndexByID: [:])
    }

    /// Layout of one event by id.
    func event(_ id: UUID) -> NotationEventLayout? { eventIndexByID[id].map { events[$0] } }

    /// Events of a measure.
    func events(inMeasure index: Int) -> ArraySlice<NotationEventLayout> {
        guard measures.indices.contains(index) else { return [] }
        return events[measures[index].eventIndices]
    }

    // MARK: Cursor

    /// x of the cursor (centre of a black notehead) for a fractional tick inside a measure; interpolates between columns.
    ///
    /// After the last column the cursor glides towards the next measure's first column when that measure is on the
    /// same system, so `cursorX(i, length) == cursorX(i + 1, 0)` and continuous playback never jumps at a barline.
    /// At a system's last measure it glides towards the content end instead (the cursor moves to the next system anyway).
    func cursorX(measureIndex: Int, tickInMeasure: Double) -> CGFloat? {
        guard measures.indices.contains(measureIndex) else { return nil }
        let m = measures[measureIndex]
        let headCentre = NotationSMuFL.boundingBox(NotationSMuFL.noteheadBlack).width / 2
        let t = max(0, min(Double(m.length), tickInMeasure.isFinite ? tickInMeasure : 0))
        // An empty measure glides from its content start like a measure with a single column at tick 0.
        var previous = m.columns.first.map { (tick: Double($0.tick), x: $0.x + headCentre) } ?? (tick: 0, x: m.contentStartX)
        if t <= previous.tick { return previous.x }
        for column in m.columns.dropFirst() {
            let current = (tick: Double(column.tick), x: column.x + headCentre)
            if t < current.tick {
                let f = (t - previous.tick) / max(1, current.tick - previous.tick)
                return previous.x + CGFloat(f) * (current.x - previous.x)
            }
            previous = current
        }
        let endX = max(previous.x, glideTargetX(after: measureIndex))
        let span = Double(m.length) - previous.tick
        guard span > 0 else { return previous.x }
        return previous.x + CGFloat((t - previous.tick) / span) * (endX - previous.x)
    }

    /// Where the cursor heads after the last column of a measure: the next measure's tick-0 cursor position when it
    /// is on the same system, else the measure's content end.
    private func glideTargetX(after measureIndex: Int) -> CGFloat {
        let m = measures[measureIndex]
        let nextIndex = measureIndex + 1
        guard measures.indices.contains(nextIndex), measures[nextIndex].systemIndex == m.systemIndex else { return m.contentEndX }
        // Tick 0 returns before any glide, so this never recurses further.
        return cursorX(measureIndex: nextIndex, tickInMeasure: 0) ?? m.contentEndX
    }

    /// Horizontal content offset (same unit as the inputs) that keeps `cursorX` at `anchor` of a viewport, clamped to the content.
    static func scrollOffset(cursorX: CGFloat, viewportWidth: CGFloat, contentWidth: CGFloat, anchor: CGFloat = 0.35) -> CGFloat {
        let maxOffset = max(0, contentWidth - viewportWidth)
        return max(0, min(maxOffset, cursorX - anchor * viewportWidth))
    }

    // MARK: Hit testing

    /// The measure under a point in layout coordinates (nearest system vertically; nearest measure horizontally within it).
    func measureIndex(at point: CGPoint) -> Int? {
        guard !systems.isEmpty else { return nil }
        let system = systems.first(where: { point.y >= $0.frame.minY && point.y < $0.frame.maxY })
            ?? (point.y < (systems.first?.frame.minY ?? 0) ? systems.first : systems.last)
        guard let system, !system.measureIndices.isEmpty else { return nil }
        for i in system.measureIndices where point.x < measures[i].frame.maxX {
            return i
        }
        return system.measureIndices.last
    }

    /// Measures whose frames intersect a horizontal span of a system (used for culling).
    func measureIndices(system: Int, intersectingX range: ClosedRange<CGFloat>) -> [Int] {
        guard systems.indices.contains(system) else { return [] }
        return systems[system].measureIndices.filter { i in
            measures[i].frame.maxX >= range.lowerBound && measures[i].frame.minX <= range.upperBound
        }
    }

    /// Glyphs of one role (test and debug helper).
    func glyphs(role: NotationGlyphRole) -> [NotationGlyph] { glyphs.filter { $0.role == role } }
}
