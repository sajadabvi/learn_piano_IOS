import Foundation
import CoreGraphics

/// Pure staff-position rules of common practice notation for the grand staff.
///
/// Staff steps count diatonic positions downwards from the top line of a staff: 0 = top line,
/// 1 = first space below it, 4 = middle line, 8 = bottom line; negative values lie above the staff.
/// Treble (staff of `Hand.right`) has F5 on its top line; bass (`Hand.left`) has A3.
enum NotationStaffGeometry {
    /// Staff step of the middle line.
    static let middleStep = 4

    /// Diatonic number (`Pitch.diatonicNumber`) of the top line of a staff.
    static func topLineDiatonic(_ staff: Hand) -> Int {
        // F5 = 5*7+3, A3 = 3*7+5.
        staff == .right ? 38 : 26
    }

    /// Staff step of a pitch on a staff.
    static func staffStep(of pitch: Pitch, on staff: Hand) -> Int {
        topLineDiatonic(staff) - pitch.diatonicNumber
    }

    /// y offset in staff spaces from the top line for a staff step.
    static func yOffset(forStep step: Int) -> CGFloat { CGFloat(step) / 2 }

    /// Whether a staff step lies on a line (even steps) rather than in a space.
    static func isOnLine(_ step: Int) -> Bool { step % 2 == 0 }

    /// Staff steps where ledger lines are needed for a note at `step` (above: −2, −4…; below: 10, 12…).
    static func ledgerSteps(for step: Int) -> [Int] {
        if step <= -2 { return Array(stride(from: -2, through: step, by: -2)) }
        if step >= 10 { return Array(stride(from: 10, through: step, by: 2)) }
        return []
    }

    // MARK: Key signatures

    /// Staff steps of the sharps of a key signature on the treble staff, in order F C G D A E B.
    static let trebleSharpSteps = [0, 3, -1, 2, 5, 1, 4]
    /// Staff steps of the flats on the treble staff, in order B E A D G C F.
    static let trebleFlatSteps = [4, 1, 5, 2, 6, 3, 7]

    /// Staff steps of the accidentals of a key signature (bass sits a third lower than treble, i.e. two steps).
    static func keySignatureSteps(fifths: Int, staff: Hand) -> [Int] {
        let shift = staff == .right ? 0 : 2
        if fifths > 0 { return trebleSharpSteps.prefix(min(7, fifths)).map { $0 + shift } }
        if fifths < 0 { return trebleFlatSteps.prefix(min(7, -fifths)).map { $0 + shift } }
        return []
    }

    /// Staff steps that need a cancelling natural when the key changes from `old` to `new`:
    /// every step altered by the old key that the new key does not alter in the same direction.
    static func cancellationSteps(from old: KeySignature, to new: KeySignature, staff: Hand) -> [Int] {
        let oldSteps = keySignatureSteps(fifths: old.fifths, staff: staff)
        let cancelled = old.alteredSteps.enumerated().filter { _, item in new.alteration(of: item.step) != item.alter }
        return cancelled.map { oldSteps[$0.offset] }
    }

    // MARK: Stems

    /// Stem direction for a set of staff steps: up when the note farthest from the middle line lies below it,
    /// down when it lies above or at equal distance (a single note on the middle line is stemmed down).
    static func stemUp(forSteps steps: [Int]) -> Bool {
        guard let highest = steps.min(), let lowest = steps.max() else { return false }
        let above = middleStep - highest   // > 0 when above the middle line
        let below = lowest - middleStep    // > 0 when below the middle line
        return below > above
    }

    /// Which chord notes sit on the "wrong" side of the stem because of second intervals.
    /// `steps` must be sorted from the lowest pitch to the highest (descending staff step).
    /// Up stems: walking upwards, a note a second above an undisplaced neighbour moves right.
    /// Down stems: walking downwards, a note a second below an undisplaced neighbour moves left.
    static func displacedNotes(stepsLowToHigh steps: [Int], stemUp: Bool) -> [Bool] {
        var displaced = Array(repeating: false, count: steps.count)
        guard steps.count > 1 else { return displaced }
        if stemUp {
            for i in 1..<steps.count where steps[i - 1] - steps[i] <= 1 && !displaced[i - 1] {
                displaced[i] = true
            }
        } else {
            for i in stride(from: steps.count - 2, through: 0, by: -1) where steps[i] - steps[i + 1] <= 1 && !displaced[i + 1] {
                displaced[i] = true
            }
        }
        return displaced
    }

    // MARK: Accidentals

    /// Measure-scoped accidental memory for one staff: which alteration is currently in force per letter+octave.
    struct AccidentalMemory {
        let key: KeySignature
        private var inForce: [Int: Int] = [:]

        init(key: KeySignature) { self.key = key }

        /// The accidental to draw for a note (nil when the key signature or an earlier accidental already covers it).
        /// Tie continuations never draw an accidental and leave the memory untouched.
        mutating func accidental(for pitch: Pitch, isTieContinuation: Bool) -> Accidental? {
            if isTieContinuation { return nil }
            let current = inForce[pitch.diatonicNumber] ?? key.alteration(of: pitch.step)
            guard pitch.alter != current else { return nil }
            inForce[pitch.diatonicNumber] = pitch.alter
            return Accidental(rawValue: max(-2, min(2, pitch.alter)))
        }
    }

    /// Assigns accidentals to stacked columns so tall glyphs never collide: a column is shared only by
    /// accidentals at least six steps (a sixth) apart. Input is ordered top to bottom; output is the column index per input.
    static func accidentalColumns(stepsTopToBottom steps: [Int]) -> [Int] {
        var columns: [[Int]] = []
        var result: [Int] = []
        for step in steps {
            if let c = columns.firstIndex(where: { col in col.allSatisfy { abs($0 - step) >= 6 } }) {
                columns[c].append(step)
                result.append(c)
            } else {
                columns.append([step])
                result.append(columns.count - 1)
            }
        }
        return result
    }

    // MARK: Beaming

    /// A minimal description of an event for beam grouping.
    struct BeamCandidate {
        var onset: Ticks
        var duration: Ticks
        var flags: Int
        var isRest: Bool
    }

    /// Groups consecutive beamable events (8th or shorter, no rests, no gaps) that start in the same beat group.
    /// `beatOffset` shifts onsets so pickup measures group against the end of the bar. Only groups of two or more are returned.
    static func beamGroups(_ events: [BeamCandidate], pulse: Ticks, beatOffset: Ticks = 0) -> [[Int]] {
        let pulse = max(1, pulse)
        var groups: [[Int]] = []
        var current: [Int] = []
        func flush() {
            if current.count >= 2 { groups.append(current) }
            current = []
        }
        for (i, e) in events.enumerated() {
            guard !e.isRest, e.flags >= 1 else { flush(); continue }
            if let last = current.last {
                let prev = events[last]
                let sameBeat = (prev.onset + beatOffset) / pulse == (e.onset + beatOffset) / pulse
                if !(sameBeat && prev.onset + prev.duration == e.onset) { flush() }
            }
            current.append(i)
        }
        flush()
        return groups
    }

    /// Beam line through stem tips: slope limited to a total rise of one staff space, then shifted so every
    /// stem keeps at least its natural length. Returns (intercept, slope) of y = a + b·x in layout space.
    /// `tips` are the natural stem tips (x = stem centre, y = tip) of the group's stems.
    static func beamLine(tips: [CGPoint], stemUp: Bool, middleLineY: CGFloat) -> (a: CGFloat, b: CGFloat) {
        guard let first = tips.first, let last = tips.last else { return (0, 0) }
        let dx = last.x - first.x
        var rise = last.y - first.y
        rise = max(-1, min(1, rise))
        // A group whose inner notes poke past both ends gets a flat beam.
        if tips.count > 2 {
            let inner = tips.dropFirst().dropLast()
            let pokes = stemUp ? inner.contains { $0.y < min(first.y, last.y) } : inner.contains { $0.y > max(first.y, last.y) }
            if pokes { rise = 0 }
        }
        let b = dx > 0.001 ? rise / dx : 0
        var a: CGFloat
        if stemUp {
            a = tips.map { $0.y - b * $0.x }.min() ?? first.y
            // Stems of notes far below the staff reach the middle line.
            a = min(a, tips.map { middleLineY - b * $0.x }.min() ?? a)
        } else {
            a = tips.map { $0.y - b * $0.x }.max() ?? first.y
            a = max(a, tips.map { middleLineY - b * $0.x }.max() ?? a)
        }
        return (a, b)
    }

    // MARK: Spacing

    /// Proportional horizontal room for a column lasting `ticks` (∝ √duration, quarter = `quarterNoteSpacing`).
    static func proportionalWidth(ticks: Ticks) -> CGFloat {
        let ratio = Double(max(1, ticks)) / Double(Ticks.perQuarter)
        return max(NotationEngraving.minimumColumnWidth, NotationEngraving.quarterNoteSpacing * CGFloat(ratio.squareRoot()))
    }
}
