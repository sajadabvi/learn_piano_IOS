import Foundation
import CoreGraphics

/// SMuFL codepoints and the Bravura glyph metrics the engraver depends on.
///
/// All metrics are expressed in staff spaces with the SMuFL convention: the glyph origin is on the
/// baseline at the left edge, x grows to the right and y grows **upwards** (the renderer flips y).
/// Values are copied from `docs/smufl/Bravura.json` so the layout engine needs no file access.
enum NotationSMuFL {
    // MARK: Codepoints

    static let brace: UInt32 = 0xE000
    static let repeatDot: UInt32 = 0xE044
    static let gClef: UInt32 = 0xE050
    static let fClef: UInt32 = 0xE062
    static let timeSigCommon: UInt32 = 0xE08A
    static let noteheadWhole: UInt32 = 0xE0A2
    static let noteheadHalf: UInt32 = 0xE0A3
    static let noteheadBlack: UInt32 = 0xE0A4
    static let augmentationDot: UInt32 = 0xE1E7
    static let flag8thUp: UInt32 = 0xE240
    static let flag8thDown: UInt32 = 0xE241
    static let flag16thUp: UInt32 = 0xE242
    static let flag16thDown: UInt32 = 0xE243
    static let flag32ndUp: UInt32 = 0xE244
    static let flag32ndDown: UInt32 = 0xE245
    static let accidentalFlat: UInt32 = 0xE260
    static let accidentalNatural: UInt32 = 0xE261
    static let accidentalSharp: UInt32 = 0xE262
    static let accidentalDoubleSharp: UInt32 = 0xE263
    static let accidentalDoubleFlat: UInt32 = 0xE264
    static let restWhole: UInt32 = 0xE4E3
    static let restHalf: UInt32 = 0xE4E4
    static let restQuarter: UInt32 = 0xE4E5
    static let rest8th: UInt32 = 0xE4E6
    static let rest16th: UInt32 = 0xE4E7
    static let rest32nd: UInt32 = 0xE4E8

    /// `timeSig0`…`timeSig9` (U+E080…U+E089).
    static func timeSignatureDigit(_ digit: Int) -> UInt32 { 0xE080 + UInt32(max(0, min(9, digit))) }
    /// `tuplet0`…`tuplet9` (U+E880…U+E889).
    static func tupletDigit(_ digit: Int) -> UInt32 { 0xE880 + UInt32(max(0, min(9, digit))) }
    /// `fingering0`…`fingering5` (U+ED10…U+ED15).
    static func fingering(_ finger: Int) -> UInt32 { 0xED10 + UInt32(max(0, min(5, finger))) }

    /// Notehead glyph for a notated value (whole and longer are hollow ovals without a stem).
    static func notehead(for value: NoteValue) -> UInt32 {
        switch value {
        case .maxima, .long, .breve, .whole: return noteheadWhole
        case .half: return noteheadHalf
        default: return noteheadBlack
        }
    }

    /// Rest glyph for a notated value (32nd is the shortest rest glyph the font set includes here).
    static func rest(for value: NoteValue) -> UInt32 {
        switch value {
        case .maxima, .long, .breve, .whole: return restWhole
        case .half: return restHalf
        case .quarter: return restQuarter
        case .eighth: return rest8th
        case .sixteenth: return rest16th
        default: return rest32nd
        }
    }

    /// Combined flag glyph for a number of flags (1 = 8th, 2 = 16th, 3+ = 32nd) and a stem direction; nil when no flag is drawn.
    static func flag(count: Int, stemUp: Bool) -> UInt32? {
        switch count {
        case ..<1: return nil
        case 1: return stemUp ? flag8thUp : flag8thDown
        case 2: return stemUp ? flag16thUp : flag16thDown
        default: return stemUp ? flag32ndUp : flag32ndDown
        }
    }

    /// Accidental glyph for a displayed accidental.
    static func accidental(_ accidental: Accidental) -> UInt32 {
        switch accidental {
        case .doubleFlat: return accidentalDoubleFlat
        case .flat: return accidentalFlat
        case .natural: return accidentalNatural
        case .sharp: return accidentalSharp
        case .doubleSharp: return accidentalDoubleSharp
        }
    }

    // MARK: Metrics (staff spaces, y up)

    /// Glyph bounding box in staff spaces relative to the glyph origin (SMuFL `glyphBBoxes`).
    struct BoundingBox: Equatable, Sendable {
        var left: CGFloat
        var bottom: CGFloat
        var right: CGFloat
        var top: CGFloat
        var width: CGFloat { right - left }
        var height: CGFloat { top - bottom }
    }

    /// Bounding boxes hard-coded from Bravura.json for the glyphs the engraver measures.
    static func boundingBox(_ codepoint: UInt32) -> BoundingBox {
        switch codepoint {
        case brace: return BoundingBox(left: 0, bottom: 0, right: 0.277, top: 4.002)
        case repeatDot, augmentationDot: return BoundingBox(left: 0, bottom: -0.2, right: 0.4, top: 0.2)
        case gClef: return BoundingBox(left: 0, bottom: -2.632, right: 2.684, top: 4.392)
        case fClef: return BoundingBox(left: -0.02, bottom: -2.54, right: 2.736, top: 1.048)
        case noteheadWhole: return BoundingBox(left: 0, bottom: -0.5, right: 1.688, top: 0.5)
        case noteheadHalf, noteheadBlack: return BoundingBox(left: 0, bottom: -0.5, right: 1.18, top: 0.5)
        case flag8thUp: return BoundingBox(left: 0, bottom: -3.24, right: 1.056, top: 0.036)
        case flag8thDown: return BoundingBox(left: 0, bottom: -0.056, right: 1.224, top: 3.232)
        case flag16thUp: return BoundingBox(left: 0, bottom: -3.252, right: 1.116, top: 0.008)
        case flag16thDown: return BoundingBox(left: 0, bottom: -0.036, right: 1.164, top: 3.248)
        case flag32ndUp: return BoundingBox(left: 0, bottom: -3.248, right: 1.044, top: 0.596)
        case flag32ndDown: return BoundingBox(left: 0, bottom: -0.688, right: 1.092, top: 3.248)
        case accidentalFlat: return BoundingBox(left: 0, bottom: -0.7, right: 0.904, top: 1.756)
        case accidentalNatural: return BoundingBox(left: 0, bottom: -1.34, right: 0.672, top: 1.364)
        case accidentalSharp: return BoundingBox(left: 0, bottom: -1.392, right: 0.996, top: 1.4)
        case accidentalDoubleSharp: return BoundingBox(left: 0, bottom: -0.5, right: 0.988, top: 0.508)
        case accidentalDoubleFlat: return BoundingBox(left: 0, bottom: -0.7, right: 1.644, top: 1.748)
        case restWhole: return BoundingBox(left: 0, bottom: -0.54, right: 1.128, top: 0.036)
        case restHalf: return BoundingBox(left: 0, bottom: -0.008, right: 1.128, top: 0.568)
        case restQuarter: return BoundingBox(left: 0.004, bottom: -1.5, right: 1.08, top: 1.492)
        case rest8th: return BoundingBox(left: 0, bottom: -1.004, right: 0.988, top: 0.696)
        case rest16th: return BoundingBox(left: 0, bottom: -2.0, right: 1.28, top: 0.716)
        case rest32nd: return BoundingBox(left: 0, bottom: -2.0, right: 1.452, top: 1.704)
        case 0xE080...0xE089:
            return BoundingBox(left: 0.08, bottom: -1.0, right: timeSignatureDigitAdvance[Int(codepoint - 0xE080)] - 0.08, top: 1.0)
        case 0xE880...0xE889: return BoundingBox(left: 0.04, bottom: -0.032, right: 1.224, top: 1.5)
        case 0xED10...0xED15: return BoundingBox(left: 0.08, bottom: 0, right: fingeringAdvance[Int(codepoint - 0xED10)] - 0.08, top: 1.016)
        default: return BoundingBox(left: 0, bottom: -0.5, right: 1.0, top: 0.5)
        }
    }

    /// Horizontal advance of each time-signature digit 0…9 (Bravura `glyphAdvanceWidths`).
    static let timeSignatureDigitAdvance: [CGFloat] = [1.88, 1.336, 1.784, 1.684, 1.88, 1.612, 1.736, 1.764, 1.744, 1.736]
    /// Horizontal advance of `fingering0`…`fingering5`.
    static let fingeringAdvance: [CGFloat] = [1.02, 0.628, 0.968, 0.9, 0.944, 0.9]

    /// Width of the notehead used for a notated value.
    static func noteheadWidth(for value: NoteValue) -> CGFloat { boundingBox(notehead(for: value)).width }

    // MARK: Anchors (staff spaces, y up)

    /// Stem attachment on the right side of a black/half notehead for an upward stem (`stemUpSE`).
    static let stemUpSE = CGPoint(x: 1.18, y: 0.168)
    /// Stem attachment on the left side of a black/half notehead for a downward stem (`stemDownNW`).
    static let stemDownNW = CGPoint(x: 0.0, y: -0.168)

    /// Point of a flag glyph that coincides with the end of the stem (`stemUpNW` for up flags, `stemDownSW` for down flags).
    static func flagStemAnchor(count: Int, stemUp: Bool) -> CGPoint {
        switch (min(3, max(1, count)), stemUp) {
        case (1, true): return CGPoint(x: 0, y: -0.04)
        case (1, false): return CGPoint(x: 0, y: 0.132)
        case (2, true): return CGPoint(x: 0, y: -0.088)
        case (2, false): return CGPoint(x: 0, y: 0.128)
        case (_, true): return CGPoint(x: 0, y: 0.376)
        case (_, false): return CGPoint(x: 0, y: -0.448)
        }
    }
}

/// Engraving constants in staff spaces (Bravura `engravingDefaults` plus house-style spacing choices).
enum NotationEngraving {
    static let staffLineThickness: CGFloat = 0.13
    static let stemThickness: CGFloat = 0.12
    static let thinBarlineThickness: CGFloat = 0.16
    static let thickBarlineThickness: CGFloat = 0.5
    static let barlineSeparation: CGFloat = 0.4
    static let legerLineThickness: CGFloat = 0.16
    static let legerLineExtension: CGFloat = 0.4
    static let beamThickness: CGFloat = 0.5
    static let beamSpacing: CGFloat = 0.25
    static let tieMidpointThickness: CGFloat = 0.22
    static let tupletBracketThickness: CGFloat = 0.16
    static let repeatEndingLineThickness: CGFloat = 0.16

    /// Standard stem length for an unbeamed note.
    static let stemLength: CGFloat = 3.5
    /// Minimum stem length a beam may shorten a stem to.
    static let minimumBeamedStemLength: CGFloat = 2.75
    /// Horizontal room given to a quarter note; other durations scale with the square root of their length.
    static let quarterNoteSpacing: CGFloat = 3.5
    /// Narrowest column, whatever its duration.
    static let minimumColumnWidth: CGFloat = 1.6
    /// Gap between an accidental and its notehead.
    static let accidentalGap: CGFloat = 0.25
    /// Gap between stacked accidental columns.
    static let accidentalColumnGap: CGFloat = 0.15
    /// Horizontal room taken by one augmentation dot (gap + dot).
    static let dotAdvance: CGFloat = 0.9

    /// Distance from the top of the treble staff to the top of the bass staff.
    static let staffDistance: CGFloat = 12
    /// Room above the treble staff (ledger lines, measure numbers, volta brackets).
    static let systemTopPadding: CGFloat = 7
    /// Room below the bass staff (ledger lines, fingering).
    static let systemBottomPadding: CGFloat = 7
    /// Vertical gap between systems in page mode.
    static let systemSpacing: CGFloat = 3
    /// Height of one grand-staff system including paddings.
    static var systemHeight: CGFloat { systemTopPadding + staffDistance + 4 + systemBottomPadding }
    /// Horizontal room for the brace to the left of the first barline.
    static let systemLeftInset: CGFloat = 2.5
    /// Room to the right of the last barline of a system.
    static let systemRightInset: CGFloat = 1.0
    /// Space between the start of a measure's content and its first column.
    static let measureLeadingPadding: CGFloat = 1.0
    /// Space between the last column and the barline.
    static let measureTrailingPadding: CGFloat = 0.75
}
