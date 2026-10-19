import Foundation

// MARK: - Practice configuration and feedback types shared by Practice, Audio, Notation, Keyboard and the UI

/// How the practice screen responds to the learner.
public enum PracticeMode: String, Codable, Hashable, CaseIterable, Sendable {
    /// The score advances only when the expected notes are played.
    case wait
    /// Playback runs at tempo; the learner's notes are scored against it and the cursor follows them.
    case justPlay
    /// Demonstration: the app plays everything and the learner watches.
    case listen

    public var displayName: String {
        switch self {
        case .wait: return "Wait"
        case .justPlay: return "Just Play"
        case .listen: return "Listen"
        }
    }
}

/// Speeds offered by the UI (fraction of the written tempo).
public enum PracticeSpeed: Double, Codable, CaseIterable, Hashable, Sendable {
    case quarter = 0.25, half = 0.5, threeQuarters = 0.75, full = 1.0
    public var displayName: String { self == .full ? "Full" : "\(Int(rawValue * 100))%" }
}

/// Everything the learner can adjust for one practice session.
public struct PracticeSettings: Hashable, Codable, Sendable {
    public var mode: PracticeMode
    public var hands: HandSelection
    /// 0.25…1.0 multiplier on the written tempo.
    public var speed: Double
    /// Loop region in notated measure indices, nil = whole piece.
    public var loop: MeasureRange?
    public var metronome: Bool
    /// Number of count-in measures before playback starts (0 = none).
    public var countInMeasures: Int
    /// Play the hand(s) the learner is not practicing.
    public var playOtherHands: Bool
    /// Accept a note in any octave as matching the expected pitch class (helps small keyboards).
    public var octaveTolerance: Bool
    /// Wait Mode: window in which all notes of a chord must arrive to count as one chord.
    public var chordWindowSeconds: Double
    /// Just Play: ± window around the expected onset in which a note counts as on time.
    public var timingWindowSeconds: Double
    /// Wait Mode: when the cursor advances, rests and note durations are shortened by this factor (0 = skip instantly, 1 = full length at speed).
    public var waitModeRestScale: Double

    public init(mode: PracticeMode = .wait, hands: HandSelection = .both, speed: Double = 1.0, loop: MeasureRange? = nil, metronome: Bool = false, countInMeasures: Int = 1, playOtherHands: Bool = true, octaveTolerance: Bool = false, chordWindowSeconds: Double = 0.25, timingWindowSeconds: Double = 0.3, waitModeRestScale: Double = 0.5) {
        self.mode = mode
        self.hands = hands
        self.speed = max(0.1, min(1.5, speed))
        self.loop = loop
        self.metronome = metronome
        self.countInMeasures = max(0, min(2, countInMeasures))
        self.playOtherHands = playOtherHands
        self.octaveTolerance = octaveTolerance
        self.chordWindowSeconds = max(0.05, chordWindowSeconds)
        self.timingWindowSeconds = max(0.05, timingWindowSeconds)
        self.waitModeRestScale = max(0, min(1, waitModeRestScale))
    }
}

/// Visual state of a key/note at this instant. Notation and Keyboard render these; Practice computes them.
public enum NoteFeedbackState: String, Codable, Hashable, Sendable {
    /// Waiting for the learner to play it.
    case expected
    /// Learner played it correctly (recently).
    case correct
    /// Learner pressed a key that was not expected.
    case wrong
    /// Coming up next (preview).
    case upcoming
    /// Sounded by the app's demonstration playback.
    case demo
    /// Learner is holding it (no judgement).
    case pressed
}

/// Per-pitch and per-event feedback snapshot published by the practice engine for the views.
public struct FeedbackSnapshot: Hashable, Codable, Sendable {
    /// Keyboard: state per MIDI pitch (absent = neutral).
    public var keyStates: [Int: NoteFeedbackState]
    /// Notation: state per timeline event id (absent = neutral).
    public var eventStates: [String: NoteFeedbackState]
    /// Timeline step currently expected (Wait) / current (Just Play), nil before start or after end.
    public var currentStepIndex: Int?
    /// Pitches still missing from the current chord (Wait Mode).
    public var missingPitches: [Int]

    public init(keyStates: [Int: NoteFeedbackState] = [:], eventStates: [String: NoteFeedbackState] = [:], currentStepIndex: Int? = nil, missingPitches: [Int] = []) {
        self.keyStates = keyStates
        self.eventStates = eventStates
        self.currentStepIndex = currentStepIndex
        self.missingPitches = missingPitches
    }

    public static let empty = FeedbackSnapshot()
}

/// Transport status of a session.
public enum TransportState: String, Codable, Hashable, Sendable {
    case stopped, countingIn, playing, paused, finished
}

/// Outcome of one expected attack, recorded for statistics.
public struct PlayedRecord: Hashable, Codable, Sendable {
    public enum Outcome: String, Codable, Sendable { case correct, late, early, missed, wrong }
    public var stepIndex: Int
    public var measureIndex: Int
    public var expected: [Int]
    public var played: [Int]
    public var outcome: Outcome
    /// Seconds between the first expected onset and the completing input (Wait Mode: time the learner took).
    public var deltaSeconds: Double
    public init(stepIndex: Int, measureIndex: Int, expected: [Int], played: [Int], outcome: Outcome, deltaSeconds: Double) {
        self.stepIndex = stepIndex
        self.measureIndex = measureIndex
        self.expected = expected
        self.played = played
        self.outcome = outcome
        self.deltaSeconds = deltaSeconds
    }
}

/// Summary of one practice session, persisted by the Library module into `SongProgress`.
public struct PracticeSummary: Hashable, Codable, Sendable {
    public var arrangementID: String
    public var startedAt: Date
    public var durationSeconds: Double
    public var mode: PracticeMode
    public var hands: HandSelection
    public var speed: Double
    public var stepsExpected: Int
    public var stepsCorrect: Int
    public var wrongNotes: Int
    /// Mistakes per notated measure index.
    public var mistakesByMeasure: [Int: Int]
    /// Measures the learner completed at least once this session.
    public var measuresCompleted: Set<Int>
    public var reachedEnd: Bool

    public init(arrangementID: String, startedAt: Date, durationSeconds: Double, mode: PracticeMode, hands: HandSelection, speed: Double, stepsExpected: Int, stepsCorrect: Int, wrongNotes: Int, mistakesByMeasure: [Int: Int], measuresCompleted: Set<Int>, reachedEnd: Bool) {
        self.arrangementID = arrangementID
        self.startedAt = startedAt
        self.durationSeconds = durationSeconds
        self.mode = mode
        self.hands = hands
        self.speed = speed
        self.stepsExpected = stepsExpected
        self.stepsCorrect = stepsCorrect
        self.wrongNotes = wrongNotes
        self.mistakesByMeasure = mistakesByMeasure
        self.measuresCompleted = measuresCompleted
        self.reachedEnd = reachedEnd
    }

    /// 0…1 share of expected steps played correctly.
    public var accuracy: Double { stepsExpected == 0 ? 0 : Double(stepsCorrect) / Double(stepsExpected) }
}

// MARK: - Playback control contract (implemented by Audio, driven by Practice)

/// A chord to sound immediately (used for demo of the other hand in Wait Mode and for "play this note").
public struct ImmediateChord: Hashable, Sendable {
    public var pitches: [Int]
    public var durationSeconds: Double
    public var velocity: Double
    public init(pitches: [Int], durationSeconds: Double, velocity: Double = 0.8) {
        self.pitches = pitches
        self.durationSeconds = durationSeconds
        self.velocity = velocity
    }
}

/// What the practice engine needs from the audio player. All calls happen on the main actor.
public protocol ScorePlaybackControlling: AnyObject {
    /// Replace the material to play. Mutes/loops are kept.
    func load(timeline: PlaybackTimeline)
    /// Hands the player sounds during timeline playback (the learner's hands are usually muted).
    var audibleHands: HandSelection? { get set }
    var speed: Double { get set }
    /// Loop region in playback ticks (end exclusive), nil = none.
    var loopTicks: Range<Ticks>? { get set }
    var isPlaying: Bool { get }
    /// Current playback position in ticks (fractional, interpolated).
    var positionTick: Double { get }
    func play(fromTick tick: Ticks)
    func pause()
    func stop()
    func seek(toTick tick: Ticks)
    /// Sound a chord right now, independent of the timeline.
    func playImmediately(_ chord: ImmediateChord)
    /// Called on the main actor when the timeline reaches its end (not when looping).
    var onReachedEnd: (() -> Void)? { get set }
    /// Called on the main actor each time an event starts sounding (for demo highlights).
    var onEventStarted: ((TimelineEvent) -> Void)? { get set }
}

/// Metronome contract used by the practice engine.
public protocol MetronomeControlling: AnyObject {
    var isEnabled: Bool { get set }
    /// Starts clicking from a playback tick using the timeline's meter and tempo.
    func start(timeline: PlaybackTimeline, timeSignatureProvider: @escaping (Ticks) -> TimeSignature, fromTick tick: Ticks, speed: Double)
    func stop()
    /// Plays `measures` of clicks at the meter in force, calling back on each beat (beatIndex, totalBeats) on the main actor and `completion` at the end.
    func countIn(measures: Int, timeSignature: TimeSignature, bpm: Double, speed: Double, onBeat: @escaping (Int, Int) -> Void, completion: @escaping () -> Void)
    func cancelCountIn()
}
