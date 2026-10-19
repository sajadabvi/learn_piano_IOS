import Foundation

// MARK: - Shared helpers for the Parsers module
//
// Everything in this file is Foundation-only so that the importers can be compiled and exercised
// on macOS by `scripts/parsecheck`.

/// Converts positions expressed in a file's own "divisions per quarter" units into Core ticks.
///
/// Positions are kept as a `Double` cursor and rounded only when an onset or an end is materialised,
/// so odd division counts (e.g. 7 or 16384) never accumulate drift across a measure.
struct ParsersTickConverter: Hashable, Sendable {
    /// Division units per quarter note in the source file.
    private(set) var divisions: Int

    /// Creates a converter; a non-positive value falls back to 1.
    init(divisions: Int) { self.divisions = max(1, divisions) }

    /// Ticks per division unit.
    var ticksPerUnit: Double { Double(Ticks.perQuarter) / Double(divisions) }

    /// Tick length of a span of `units` division units measured from `cursor` (both rounded independently so
    /// that consecutive spans stay contiguous).
    func span(from cursor: Double, units: Int) -> (onset: Ticks, end: Ticks) {
        let onset = Int(cursor.rounded())
        let end = Int((cursor + Double(units) * ticksPerUnit).rounded())
        return (onset, max(onset, end))
    }
}

/// Collects diagnostics while parsing and protects the review screen from floods: identical messages are reported
/// at most `perMessageCap` times and the total is capped, with one summary line at the end.
struct ParsersDiagnosticLog {
    private(set) var items: [ScoreDiagnostic] = []
    private var counts: [String: Int] = [:]
    private var suppressed = 0
    /// Maximum number of times the same message text is kept.
    var perMessageCap = 12
    /// Maximum number of diagnostics kept overall.
    var totalCap = 400

    init() {}

    /// Appends one diagnostic, honouring the caps.
    mutating func add(_ severity: DiagnosticSeverity, measureIndex: Int? = nil, hand: Hand? = nil, voice: Int? = nil, _ message: String) {
        let key = "\(severity.rawValue)|\(message)"
        let n = (counts[key] ?? 0) + 1
        counts[key] = n
        if n > perMessageCap || items.count >= totalCap {
            suppressed += 1
            return
        }
        items.append(ScoreDiagnostic(severity, measureIndex: measureIndex, hand: hand, voice: voice, message: message))
    }

    /// Appends an already built diagnostic.
    mutating func add(_ diagnostic: ScoreDiagnostic) {
        add(diagnostic.severity, measureIndex: diagnostic.measureIndex, hand: diagnostic.hand, voice: diagnostic.voice, diagnostic.message)
    }

    /// Whether any error-level diagnostic was recorded.
    var hasErrors: Bool { items.contains { $0.severity == .error } }

    /// The collected diagnostics sorted by measure, plus a summary line when some were suppressed.
    var result: [ScoreDiagnostic] {
        var out = items.sorted { ($0.measureIndex ?? -1, $0.severity > $1.severity ? 0 : 1) < ($1.measureIndex ?? -1, 0) }
        if suppressed > 0 {
            out.append(ScoreDiagnostic(.info, message: "\(suppressed) further repeated message(s) were not listed."))
        }
        return out
    }
}

/// Breaks a tick length that is not a single note value into a short chain of notatable durations to be tied
/// (notes) or written back to back (rests).
///
/// The split is found by dynamic programming over the candidate values (plain, dotted and double-dotted values
/// from the whole note to the 32nd, plus triplet values), minimising first the number of pieces and then the
/// number of tuplet pieces and dots, so 5 sixteenths become "quarter + 16th" rather than five 16ths.
enum ParsersDurationSplitter {
    /// One piece of a split.
    struct Piece: Hashable {
        var ticks: Ticks
        /// nil only for a remainder that no supported note value can express.
        var notated: NoteDuration?
    }

    /// Candidate note values with their DP cost (10 per piece, +4 for a tuplet, +1 per dot).
    private static let candidates: [(duration: NoteDuration, cost: Int)] = {
        var out: [(NoteDuration, Int)] = []
        let values: [NoteValue] = [.whole, .half, .quarter, .eighth, .sixteenth, .thirtySecond]
        for v in values {
            for dots in 0...2 where !(v == .thirtySecond && dots == 2) {
                out.append((NoteDuration(value: v, dots: dots), 10 + dots))
            }
            out.append((NoteDuration(value: v, tuplet: .triplet), 14))
        }
        return out.sorted { $0.0.ticks > $1.0.ticks }
    }()

    /// Splits `ticks` (starting `onset` ticks into its measure) into pieces.
    ///
    /// A length that is already a single value (including dotted and triplet values) is returned as one piece.
    /// Pieces are ordered longest-first when the span starts on a beat and shortest-first when it starts off the
    /// beat, so syncopations read "short tied to long" the way engravers write them.
    static func split(ticks: Ticks, onset: Ticks = 0, beatTicks: Ticks = Ticks.perQuarter) -> [Piece] {
        guard ticks > 0 else { return [] }
        if let one = NoteDuration.exact(ticks: ticks) { return [Piece(ticks: ticks, notated: one)] }
        var pieces: [Piece] = []
        var remaining = ticks
        // Peel off whole notes first so the DP table stays small for very long spans.
        let whole = NoteDuration(value: .whole)
        while remaining > 2 * Ticks.perWhole {
            pieces.append(Piece(ticks: whole.ticks, notated: whole))
            remaining -= whole.ticks
        }
        pieces += dynamicSplit(remaining)
        let onBeat = beatTicks <= 0 || onset % beatTicks == 0
        pieces.sort { onBeat ? $0.ticks > $1.ticks : $0.ticks < $1.ticks }
        // A remainder without a notated value always goes last so the notated pieces keep their grid positions.
        if let i = pieces.firstIndex(where: { $0.notated == nil }) {
            let r = pieces.remove(at: i)
            pieces.append(r)
        }
        return pieces
    }

    /// Minimum-cost decomposition of `ticks`; any amount no candidate can reach is returned as a final un-notated piece.
    private static func dynamicSplit(_ ticks: Ticks) -> [Piece] {
        guard ticks > 0 else { return [] }
        let unit = candidates.reduce(ticks) { ParsersMath.gcd($0, $1.duration.ticks) }
        let n = ticks / unit
        let inf = Int.max / 2
        var cost = [Int](repeating: inf, count: n + 1)
        var choice = [Int](repeating: -1, count: n + 1)
        cost[0] = 0
        for i in 1...n {
            for (k, c) in candidates.enumerated() {
                let u = c.duration.ticks / unit
                guard u <= i, cost[i - u] < inf else { continue }
                let total = cost[i - u] + c.cost
                if total < cost[i] { cost[i] = total; choice[i] = k }
            }
        }
        if cost[n] < inf {
            var out: [Piece] = []
            var i = n
            while i > 0 {
                let c = candidates[choice[i]].duration
                out.append(Piece(ticks: c.ticks, notated: c))
                i -= c.ticks / unit
            }
            return out
        }
        // Unreachable length (not a multiple of the smallest value): greedy fill plus an un-notated remainder.
        var out: [Piece] = []
        var remaining = ticks
        for c in candidates where c.duration.tuplet == nil {
            while c.duration.ticks <= remaining {
                out.append(Piece(ticks: c.duration.ticks, notated: c.duration))
                remaining -= c.duration.ticks
            }
        }
        if remaining > 0 { out.append(Piece(ticks: remaining, notated: nil)) }
        return out
    }
}

/// XML text helpers used by the exporter.
enum ParsersXMLText {
    /// Escapes the five XML special characters.
    static func escape(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(ch)
            }
        }
        return out
    }
}

/// Integer helpers shared by the importers.
enum ParsersMath {
    /// Greatest common divisor (non-negative; gcd(0, b) = b).
    static func gcd(_ a: Int, _ b: Int) -> Int {
        var x = abs(a), y = abs(b)
        while y != 0 { (x, y) = (y, x % y) }
        return x
    }

    /// Maps a MusicXML `<accidental>` text to a Core accidental (nil for unsupported or microtonal kinds).
    static func accidental(musicXML name: String) -> Accidental? {
        switch name.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "sharp": return .sharp
        case "flat": return .flat
        case "natural": return .natural
        case "double-sharp", "sharp-sharp": return .doubleSharp
        case "flat-flat": return .doubleFlat
        case "natural-sharp": return .sharp
        case "natural-flat": return .flat
        default: return nil
        }
    }

    /// MusicXML `<accidental>` text for a Core accidental.
    static func musicXMLName(of accidental: Accidental) -> String {
        switch accidental {
        case .sharp: return "sharp"
        case .flat: return "flat"
        case .natural: return "natural"
        case .doubleSharp: return "double-sharp"
        case .doubleFlat: return "flat-flat"
        }
    }

    /// Extracts the first decimal number in a string ("ca. 72", "72-80", "♩ = 100").
    static func firstNumber(in s: String) -> Double? {
        var current = ""
        var seenDigit = false
        for ch in s {
            if ch.isNumber || (ch == "." && seenDigit && !current.contains(".")) {
                current.append(ch)
                if ch.isNumber { seenDigit = true }
            } else if seenDigit {
                break
            } else {
                current = ""
            }
        }
        return seenDigit ? Double(current) : nil
    }
}
