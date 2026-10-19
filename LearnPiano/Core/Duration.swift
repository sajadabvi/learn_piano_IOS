import Foundation

/// Musical time is measured in integer ticks; `Ticks.perQuarter` ticks make one quarter note.
/// 960 divides evenly by 2…10, 12, 15, 16, 20, 24, 32, 40, 48, 60, 64, 80, 96, 120, 160, 192, 240, 320, 480,
/// so every common tuplet and note value stays integral.
public typealias Ticks = Int

public extension Ticks {
    static let perQuarter: Ticks = 960
    static let perWhole: Ticks = 960 * 4
}

/// Notated note values.
public enum NoteValue: Int, Codable, CaseIterable, Hashable, Sendable {
    case maxima = -3, long = -2, breve = -1, whole = 0, half = 1, quarter = 2, eighth = 3, sixteenth = 4, thirtySecond = 5, sixtyFourth = 6, oneTwentyEighth = 7

    /// Undotted length in ticks.
    public var ticks: Ticks {
        if rawValue >= 0 { return Ticks.perWhole >> rawValue }
        return Ticks.perWhole << (-rawValue)
    }

    /// Number of flags/beams (0 for quarter and longer).
    public var flags: Int { max(0, rawValue - 2) }

    /// MusicXML `<type>` text.
    public var musicXMLName: String {
        switch self {
        case .maxima: return "maxima"
        case .long: return "long"
        case .breve: return "breve"
        case .whole: return "whole"
        case .half: return "half"
        case .quarter: return "quarter"
        case .eighth: return "eighth"
        case .sixteenth: return "16th"
        case .thirtySecond: return "32nd"
        case .sixtyFourth: return "64th"
        case .oneTwentyEighth: return "128th"
        }
    }

    public init?(musicXMLName: String) {
        guard let v = NoteValue.allCases.first(where: { $0.musicXMLName == musicXMLName }) else { return nil }
        self = v
    }

    /// Whether the notehead is hollow (whole, half and longer).
    public var isHollow: Bool { rawValue <= 1 }
    /// Whether the note has a stem (half and shorter).
    public var hasStem: Bool { rawValue >= 1 }
}

/// A tuplet ratio: `actual` notes in the time of `normal` (3:2 = triplet).
public struct Tuplet: Hashable, Codable, Sendable {
    public var actual: Int
    public var normal: Int
    public init(actual: Int, normal: Int) {
        self.actual = max(1, actual)
        self.normal = max(1, normal)
    }
    public static let triplet = Tuplet(actual: 3, normal: 2)
}

/// A notated duration: value + dots + optional tuplet. Converts exactly to ticks.
public struct NoteDuration: Hashable, Codable, Sendable {
    public var value: NoteValue
    public var dots: Int
    public var tuplet: Tuplet?

    public init(value: NoteValue, dots: Int = 0, tuplet: Tuplet? = nil) {
        self.value = value
        self.dots = max(0, min(3, dots))
        self.tuplet = tuplet
    }

    /// Sounding length in ticks (dots add 1/2, 1/4 …; tuplets scale by normal/actual).
    public var ticks: Ticks {
        var t = value.ticks
        var add = value.ticks
        for _ in 0..<dots { add /= 2; t += add }
        if let tuplet { t = t * tuplet.normal / tuplet.actual }
        return t
    }

    /// Finds the simplest notated duration for a tick length (no tuplet), or nil if none fits exactly.
    public static func exact(ticks: Ticks) -> NoteDuration? {
        for v in NoteValue.allCases where v.rawValue >= 0 {
            for d in 0...2 {
                let nd = NoteDuration(value: v, dots: d)
                if nd.ticks == ticks { return nd }
            }
        }
        for v in NoteValue.allCases where v.rawValue >= 0 {
            let nd = NoteDuration(value: v, tuplet: .triplet)
            if nd.ticks == ticks { return nd }
        }
        return nil
    }

    /// Splits an arbitrary tick length into a chain of notated durations to be tied (largest first).
    public static func tiedChain(ticks: Ticks) -> [NoteDuration] {
        var remaining = max(0, ticks)
        var chain: [NoteDuration] = []
        let candidates: [NoteDuration] = NoteValue.allCases.filter { $0.rawValue >= 0 }.flatMap { v in
            [NoteDuration(value: v, dots: 1), NoteDuration(value: v)]
        }.sorted { $0.ticks > $1.ticks }
        while remaining > 0 {
            guard let fit = candidates.first(where: { $0.ticks <= remaining }) else { break }
            chain.append(fit)
            remaining -= fit.ticks
        }
        return chain
    }
}

// MARK: - Tempo

/// A tempo change at an absolute playback tick.
public struct TempoEvent: Hashable, Codable, Sendable {
    public var tick: Ticks
    /// Quarter-note beats per minute.
    public var bpm: Double
    public init(tick: Ticks, bpm: Double) {
        self.tick = tick
        self.bpm = max(10, min(400, bpm))
    }
}

/// Piecewise-constant tempo map over playback ticks with exact tick↔seconds conversion.
public struct TempoMap: Hashable, Codable, Sendable {
    /// Sorted by tick; the first event is at tick 0.
    public private(set) var events: [TempoEvent]

    public init(events: [TempoEvent]) {
        var sorted = events.sorted { $0.tick < $1.tick }
        if sorted.isEmpty { sorted = [TempoEvent(tick: 0, bpm: 100)] }
        if sorted[0].tick != 0 { sorted.insert(TempoEvent(tick: 0, bpm: sorted[0].bpm), at: 0) }
        // Remove duplicates at the same tick, keeping the last.
        var dedup: [TempoEvent] = []
        for e in sorted {
            if let last = dedup.last, last.tick == e.tick { dedup[dedup.count - 1] = e } else { dedup.append(e) }
        }
        self.events = dedup
    }

    public init(bpm: Double) { self.init(events: [TempoEvent(tick: 0, bpm: bpm)]) }

    /// Tempo in effect at a tick.
    public func bpm(at tick: Ticks) -> Double {
        var current = events[0].bpm
        for e in events where e.tick <= tick { current = e.bpm }
        return current
    }

    /// Seconds from tick 0 to `tick` at the given speed multiplier (1.0 = original tempo).
    public func seconds(at tick: Ticks, speed: Double = 1.0) -> Double {
        var seconds = 0.0
        for (i, e) in events.enumerated() {
            let end = i + 1 < events.count ? min(events[i + 1].tick, tick) : tick
            if end <= e.tick { break }
            seconds += Double(end - e.tick) / Double(Ticks.perQuarter) * 60.0 / e.bpm
        }
        return seconds / max(0.01, speed)
    }

    /// Inverse of `seconds(at:)`: the (fractional) tick reached after `seconds` at `speed`.
    public func tick(atSeconds seconds: Double, speed: Double = 1.0) -> Double {
        var remaining = seconds * max(0.01, speed)
        for (i, e) in events.enumerated() {
            let secondsPerTick = 60.0 / e.bpm / Double(Ticks.perQuarter)
            if i + 1 < events.count {
                let segment = Double(events[i + 1].tick - e.tick) * secondsPerTick
                if remaining < segment { return Double(e.tick) + remaining / secondsPerTick }
                remaining -= segment
            } else {
                return Double(e.tick) + remaining / secondsPerTick
            }
        }
        return 0
    }

    /// Duration in seconds of a span of ticks starting at `tick`.
    public func seconds(from tick: Ticks, length: Ticks, speed: Double = 1.0) -> Double {
        seconds(at: tick + length, speed: speed) - seconds(at: tick, speed: speed)
    }
}
