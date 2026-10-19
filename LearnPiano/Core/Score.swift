import Foundation

// MARK: - Hands

/// Which hand (and therefore which staff) an event belongs to. Staff 1 = right, staff 2 = left.
public enum Hand: String, Codable, Hashable, CaseIterable, Sendable {
    case right, left

    public var staffNumber: Int { self == .right ? 1 : 2 }
    public init(staffNumber: Int) { self = staffNumber == 2 ? .left : .right }
    public var displayName: String { self == .right ? "Right hand" : "Left hand" }
}

/// Which hands the learner is practicing / which hands are expected from input.
public enum HandSelection: String, Codable, Hashable, CaseIterable, Sendable {
    case right, left, both

    public func includes(_ hand: Hand) -> Bool {
        switch self {
        case .both: return true
        case .right: return hand == .right
        case .left: return hand == .left
        }
    }

    /// The hands NOT selected (the app plays these for the learner).
    public var otherHands: [Hand] { Hand.allCases.filter { !includes($0) } }
    public var displayName: String {
        switch self {
        case .right: return "Right hand"
        case .left: return "Left hand"
        case .both: return "Both hands"
        }
    }
}

// MARK: - Notes, events, measures

/// One pitch inside a chord event with its notation attributes.
public struct ChordNote: Hashable, Codable, Sendable {
    public var pitch: Pitch
    /// This note begins a tie (it keeps sounding into the next event).
    public var tieStart: Bool
    /// This note continues a tie from the previous event (it is NOT re-attacked, so the follower must not expect it).
    public var tieStop: Bool
    /// Finger number 1…5, when the arrangement specifies one.
    public var fingering: Int?
    /// Accidental to display in front of the notehead (nil = nothing drawn; the key signature or measure memory covers it).
    public var accidental: Accidental?

    public init(pitch: Pitch, tieStart: Bool = false, tieStop: Bool = false, fingering: Int? = nil, accidental: Accidental? = nil) {
        self.pitch = pitch
        self.tieStart = tieStart
        self.tieStop = tieStop
        self.fingering = fingering.flatMap { (1...5).contains($0) ? $0 : nil }
        self.accidental = accidental
    }

    public var midi: Int { pitch.midi }
}

/// A chord (one or more simultaneous notes) or a rest within one voice of one hand.
/// Everything in the model is event-based: a MusicXML `<chord/>` group becomes ONE event with several notes.
public struct MeasureEvent: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    /// Onset relative to the start of its measure.
    public var onset: Ticks
    /// Sounding length in ticks.
    public var duration: Ticks
    /// The notated value when it corresponds exactly to `duration`; nil when an importer could not express it.
    public var notated: NoteDuration?
    /// Notes sorted ascending by pitch; empty means this event is a rest.
    public var notes: [ChordNote]
    public var hand: Hand
    /// Voice number within the hand (1 = main voice).
    public var voice: Int
    /// Cross-staff notation: draw on the other hand's staff while still belonging to `hand`.
    public var drawnOnOtherStaff: Bool

    public init(id: UUID = UUID(), onset: Ticks, duration: Ticks, notated: NoteDuration? = nil, notes: [ChordNote], hand: Hand, voice: Int = 1, drawnOnOtherStaff: Bool = false) {
        self.id = id
        self.onset = max(0, onset)
        self.duration = max(1, duration)
        self.notated = notated ?? NoteDuration.exact(ticks: duration)
        self.notes = notes.sorted { $0.pitch < $1.pitch }
        self.hand = hand
        self.voice = max(1, voice)
        self.drawnOnOtherStaff = drawnOnOtherStaff
    }

    public var isRest: Bool { notes.isEmpty }
    public var end: Ticks { onset + duration }
    public var midiPitches: [Int] { notes.map { $0.midi } }
    /// Pitches that are struck at this event (tie continuations excluded).
    public var attackedMidiPitches: [Int] { notes.filter { !$0.tieStop }.map { $0.midi } }
    /// The staff this event is drawn on.
    public var drawnStaff: Hand { drawnOnOtherStaff ? (hand == .right ? .left : .right) : hand }
}

/// Repeat and ending information attached to the END of a measure (plus a forward repeat at its start).
public struct Barline: Hashable, Codable, Sendable {
    /// A forward repeat sign at the start of this measure.
    public var repeatForward: Bool
    /// A backward repeat at the end of this measure; the value is the total number of times the section plays (2 = play twice).
    public var repeatBackwardTimes: Int?
    /// Volta numbers this measure belongs to (e.g. [1] for a first ending, [2] for a second); empty = no ending bracket.
    public var endings: [Int]
    /// Draw a final (thin–thick) barline.
    public var isFinal: Bool

    public init(repeatForward: Bool = false, repeatBackwardTimes: Int? = nil, endings: [Int] = [], isFinal: Bool = false) {
        self.repeatForward = repeatForward
        self.repeatBackwardTimes = repeatBackwardTimes.map { max(2, $0) }
        self.endings = endings
        self.isFinal = isFinal
    }

    public static let plain = Barline()
}

/// One notated measure. Attribute changes (time, key, tempo) are stored where they occur; use `Score` helpers for effective values.
public struct Measure: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    /// Display number (pickup measures are usually 0).
    public var number: Int
    public var timeSignature: TimeSignature?
    public var keySignature: KeySignature?
    /// Tempo change (quarter BPM) at the start of this measure.
    public var tempoBPM: Double?
    /// Incomplete first measure (anacrusis); its length is the content length, not the meter's.
    public var isPickup: Bool
    public var events: [MeasureEvent]
    public var barline: Barline

    public init(id: UUID = UUID(), number: Int, timeSignature: TimeSignature? = nil, keySignature: KeySignature? = nil, tempoBPM: Double? = nil, isPickup: Bool = false, events: [MeasureEvent], barline: Barline = .plain) {
        self.id = id
        self.number = number
        self.timeSignature = timeSignature
        self.keySignature = keySignature
        self.tempoBPM = tempoBPM
        self.isPickup = isPickup
        self.events = events.sorted { ($0.onset, $0.hand == .right ? 0 : 1, $0.voice) < ($1.onset, $1.hand == .right ? 0 : 1, $1.voice) }
        self.barline = barline
    }

    /// Furthest tick reached by any event (0 for an empty measure).
    public var contentLength: Ticks { events.map { $0.end }.max() ?? 0 }

    /// Events of one hand, in onset order.
    public func events(for hand: Hand) -> [MeasureEvent] { events.filter { $0.hand == hand } }

    /// Effective length given the meter in force: a pickup measure is as long as its content; a normal measure is at least the meter's length.
    public func length(in time: TimeSignature) -> Ticks {
        isPickup ? max(1, contentLength) : max(time.measureTicks, contentLength)
    }
}

// MARK: - Score

/// Where a score came from.
public enum ScoreSource: String, Codable, Hashable, Sendable {
    case bundled, musicXML, midi, compactJSON, sheetTranscription, exercise
}

/// Difficulty levels of arrangements.
public enum Difficulty: String, Codable, Hashable, CaseIterable, Comparable, Sendable {
    case beginner, intermediate, advanced, pro

    public var rank: Int { Difficulty.allCases.firstIndex(of: self) ?? 0 }
    public static func < (lhs: Difficulty, rhs: Difficulty) -> Bool { lhs.rank < rhs.rank }
    public var displayName: String { rawValue.prefix(1).uppercased() + rawValue.dropFirst() }
}

/// Descriptive information about a score.
public struct ScoreMetadata: Hashable, Codable, Sendable {
    public var title: String
    public var composer: String
    public var arrangementLabel: String
    public var difficulty: Difficulty?
    public var genre: String
    public var source: ScoreSource
    /// Original file name for imported scores.
    public var sourceFileName: String?
    /// Free-form notes (teaching points, import remarks).
    public var notes: String

    public init(title: String, composer: String = "", arrangementLabel: String = "", difficulty: Difficulty? = nil, genre: String = "", source: ScoreSource = .bundled, sourceFileName: String? = nil, notes: String = "") {
        self.title = title
        self.composer = composer
        self.arrangementLabel = arrangementLabel
        self.difficulty = difficulty
        self.genre = genre
        self.source = source
        self.sourceFileName = sourceFileName
        self.notes = notes
    }
}

/// A complete two-hand piano score in notated order. Playback order (with repeats expanded) comes from `makeTimeline()`.
public struct Score: Hashable, Codable, Identifiable, Sendable {
    public var id: UUID
    public var metadata: ScoreMetadata
    public var initialTime: TimeSignature
    public var initialKey: KeySignature
    /// Quarter-note BPM at the start.
    public var initialTempoBPM: Double
    public var measures: [Measure]

    public init(id: UUID = UUID(), metadata: ScoreMetadata, initialTime: TimeSignature = .common, initialKey: KeySignature = .cMajor, initialTempoBPM: Double = 100, measures: [Measure]) {
        self.id = id
        self.metadata = metadata
        self.initialTime = initialTime
        self.initialKey = initialKey
        self.initialTempoBPM = max(10, min(400, initialTempoBPM))
        self.measures = measures
    }

    // MARK: Effective attributes

    /// Time signature in force at a measure index.
    public func timeSignature(atMeasure index: Int) -> TimeSignature {
        var current = initialTime
        for (i, m) in measures.enumerated() where i <= index {
            if let t = m.timeSignature { current = t }
        }
        return current
    }

    /// Key signature in force at a measure index.
    public func keySignature(atMeasure index: Int) -> KeySignature {
        var current = initialKey
        for (i, m) in measures.enumerated() where i <= index {
            if let k = m.keySignature { current = k }
        }
        return current
    }

    /// Tempo in force at a measure index (ignores repeats).
    public func tempoBPM(atMeasure index: Int) -> Double {
        var current = initialTempoBPM
        for (i, m) in measures.enumerated() where i <= index {
            if let t = m.tempoBPM { current = t }
        }
        return current
    }

    /// Effective tick length of a measure.
    public func measureLength(at index: Int) -> Ticks {
        guard measures.indices.contains(index) else { return 0 }
        return measures[index].length(in: timeSignature(atMeasure: index))
    }

    /// Start tick of each measure in NOTATED order (no repeats), plus the total notated length as a final element.
    public var notatedMeasureStarts: [Ticks] {
        var starts: [Ticks] = []
        var t: Ticks = 0
        for i in measures.indices {
            starts.append(t)
            t += measureLength(at: i)
        }
        starts.append(t)
        return starts
    }

    /// Total notated length in ticks (no repeats).
    public var notatedLength: Ticks { notatedMeasureStarts.last ?? 0 }

    // MARK: Content queries

    public var allEvents: [MeasureEvent] { measures.flatMap { $0.events } }

    /// Lowest…highest MIDI pitch used, or nil for an empty score.
    public var pitchRange: ClosedRange<Int>? {
        let pitches = allEvents.flatMap { $0.midiPitches }
        guard let lo = pitches.min(), let hi = pitches.max() else { return nil }
        return lo...hi
    }

    /// Pitch range used by one hand.
    public func pitchRange(for hand: Hand) -> ClosedRange<Int>? {
        let pitches = allEvents.filter { $0.hand == hand }.flatMap { $0.midiPitches }
        guard let lo = pitches.min(), let hi = pitches.max() else { return nil }
        return lo...hi
    }

    public func hasNotes(for hand: Hand) -> Bool { allEvents.contains { $0.hand == hand && !$0.isRest } }

    /// Number of attacked notes (what a learner has to press) for a hand selection.
    public func noteCount(for hands: HandSelection = .both) -> Int {
        allEvents.filter { hands.includes($0.hand) }.reduce(0) { $0 + $1.attackedMidiPitches.count }
    }

    /// A copy with only the selected hands' events kept (other hands become empty measures).
    public func filtered(to hands: HandSelection) -> Score {
        var copy = self
        copy.measures = measures.map { m in
            var mm = m
            mm.events = m.events.filter { hands.includes($0.hand) }
            return mm
        }
        return copy
    }
}

/// An inclusive range of notated measure indices (0-based), used for loop regions and lesson passages.
public struct MeasureRange: Hashable, Codable, Sendable {
    public var start: Int
    public var end: Int
    public init(start: Int, end: Int) {
        self.start = min(start, end)
        self.end = max(start, end)
    }
    public init(single index: Int) { self.init(start: index, end: index) }
    public var count: Int { end - start + 1 }
    public func contains(_ index: Int) -> Bool { index >= start && index <= end }
    public func clamped(toMeasureCount n: Int) -> MeasureRange {
        MeasureRange(start: max(0, min(start, n - 1)), end: max(0, min(end, n - 1)))
    }
}
