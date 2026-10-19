import Foundation

// MARK: - Shared engine vocabulary (Foundation only)

/// Rule applied when the notes of one chord arrive more than `PracticeSettings.chordWindowSeconds` apart.
enum PracticeChordWindowPolicy: String, Codable, Hashable, Sendable {
    /// Keep every satisfied pitch and restart the window at the latest press (ARCHITECTURE §3, default).
    /// Slow chords are not punished; the learner simply has to play all notes.
    case lenient
    /// Satisfactions older than one window (relative to the newest press) expire and must be re-attacked.
    case strict
}

/// Tunables of the Wait Mode follower that are not part of the user-facing `PracticeSettings`.
struct PracticeWaitOptions: Hashable, Sendable {
    /// How chord notes that straddle the completion window are treated.
    var chordWindowPolicy: PracticeChordWindowPolicy = .lenient
    /// Credit note-ons that arrive during the gap before the next step becomes current (anticipation).
    /// Keys still held from a previous step never count: a note must be re-attacked.
    var acceptsEarlyAttacks: Bool = true
    /// How long a wrong key stays marked `wrong` in the feedback snapshot.
    var wrongFlashSeconds: Double = 0.4
    /// How long a completed event stays marked `correct` in the feedback snapshot.
    var correctFlashSeconds: Double = 0.5
    /// Number of steps after the current one marked `upcoming`.
    var upcomingSteps: Int = 2
    /// When a step becomes current, credit expected pitches whose keys are still held down from before.
    /// Off by default (ARCHITECTURE §3: a note must be re-attacked, otherwise holding C would complete C C C);
    /// useful for very young learners or a sustain-heavy microphone source.
    var creditsHeldKeys: Bool = false

    init(chordWindowPolicy: PracticeChordWindowPolicy = .lenient, acceptsEarlyAttacks: Bool = true, wrongFlashSeconds: Double = 0.4, correctFlashSeconds: Double = 0.5, upcomingSteps: Int = 2, creditsHeldKeys: Bool = false) {
        self.chordWindowPolicy = chordWindowPolicy
        self.acceptsEarlyAttacks = acceptsEarlyAttacks
        self.creditsHeldKeys = creditsHeldKeys
        self.wrongFlashSeconds = max(0, wrongFlashSeconds)
        self.correctFlashSeconds = max(0, correctFlashSeconds)
        self.upcomingSteps = max(0, upcomingSteps)
    }
}

/// When a note input actually happened, as far as the followers are concerned.
///
/// The Input module stamps `NoteInputEvent.time` with the onset time on the monotonic host clock (CoreMIDI
/// packet time, or the audio frame time of a detected onset), so the main-actor hop and, for the microphone,
/// the whole detection latency (FFT frame plus confirmation hops, roughly 100–130 ms) do not count against
/// the learner. This only works when the injected `PracticeClock` shares the input clock's epoch:
/// `SystemPracticeClock` (`ProcessInfo.systemUptime`) and the Input module's host-time conversion do, and a
/// `ManualPracticeClock` does when tests stamp events with `clock.now`. A stamp that is implausible for that
/// clock (in the future, or more than `maximumAge` in the past) falls back to `now`.
enum PracticeInputTiming {
    /// Oldest accepted stamp, relative to `now` (seconds).
    static let maximumAge: TimeInterval = 1.0
    /// Tolerated lead of a stamp over `now` (rounding between clock reads).
    static let maximumLead: TimeInterval = 0.005

    /// The time to judge `event` at: its own stamp when plausible, otherwise `now`.
    static func time(of event: NoteInputEvent, now: TimeInterval) -> TimeInterval {
        (event.time <= now + maximumLead && event.time >= now - maximumAge) ? min(event.time, now) : now
    }
}

/// Pitch comparison shared by both followers.
enum PracticePitchMatcher {
    /// The expected pitch that a played MIDI number satisfies, or nil when it matches nothing.
    /// An exact match wins; with `octaveTolerance` any expected pitch of the same pitch class matches.
    static func match(_ played: Int, in expected: [Int], octaveTolerance: Bool) -> Int? {
        if expected.contains(played) { return played }
        guard octaveTolerance else { return nil }
        return expected.first { MusicHelpers.samePitchClass($0, played) }
    }
}

/// Running counters shared by both followers and summed by the session. Codable so a session record can carry it.
struct PracticeStatistics: Hashable, Codable, Sendable {
    var stepsExpected = 0
    var stepsCorrect = 0
    var stepsLate = 0
    var stepsEarly = 0
    var stepsMissed = 0
    var wrongNotes = 0
    var notesPlayed = 0
    /// Wait Mode: steps that were completed only after at least one wrong note.
    var stepsWithMistakes = 0
    /// Wrong notes per notated measure index.
    var mistakesByMeasure: [Int: Int] = [:]
    /// Notated measures the learner got through at least once.
    var measuresCompleted: Set<Int> = []

    init() {}

    /// Steps whose pitches were all played (on time or not).
    var stepsHit: Int { stepsCorrect + stepsLate + stepsEarly }
    /// Share of expected steps hit (any timing). 0 before anything was expected.
    var accuracy: Double { stepsExpected == 0 ? 0 : Double(stepsHit) / Double(stepsExpected) }
    /// Share of expected steps hit on time.
    var strictAccuracy: Double { stepsExpected == 0 ? 0 : Double(stepsCorrect) / Double(stepsExpected) }
    /// Hit steps that needed no wrong note first (Wait Mode's notion of "correct").
    var cleanSteps: Int { max(0, stepsHit - stepsWithMistakes) }

    /// Folds one record into the counters.
    mutating func record(_ r: PlayedRecord) {
        switch r.outcome {
        case .correct:
            stepsExpected += 1; stepsCorrect += 1; notesPlayed += r.played.count
        case .late:
            stepsExpected += 1; stepsLate += 1; notesPlayed += r.played.count
        case .early:
            stepsExpected += 1; stepsEarly += 1; notesPlayed += r.played.count
        case .missed:
            stepsExpected += 1; stepsMissed += 1
        case .wrong:
            wrongNotes += 1; notesPlayed += r.played.count
            mistakesByMeasure[r.measureIndex, default: 0] += 1
        }
    }

    /// Element-wise sum of two statistics.
    func merged(with other: PracticeStatistics) -> PracticeStatistics {
        var s = self
        s.stepsExpected += other.stepsExpected
        s.stepsCorrect += other.stepsCorrect
        s.stepsLate += other.stepsLate
        s.stepsEarly += other.stepsEarly
        s.stepsMissed += other.stepsMissed
        s.wrongNotes += other.wrongNotes
        s.notesPlayed += other.notesPlayed
        s.stepsWithMistakes += other.stepsWithMistakes
        for (m, n) in other.mistakesByMeasure { s.mistakesByMeasure[m, default: 0] += n }
        s.measuresCompleted.formUnion(other.measuresCompleted)
        return s
    }
}

/// What a follower reports back to the session (and to the harness) after an input or a clock update.
enum PracticeFollowerEvent: Hashable {
    /// A new step is now expected from the learner (`TimelineStep.index`).
    case stepBecameCurrent(stepIndex: Int)
    /// An expected step was resolved (correct/late/early/missed) or a wrong note was played.
    case played(PlayedRecord)
    /// Sound this chord now: demo of a hand the learner is not practicing (`eventID` = `TimelineEvent.id`).
    case soundChord(ImmediateChord, eventID: String)
    /// The learner got through a notated measure.
    case measureCompleted(measureIndex: Int)
    /// The loop region wrapped back to its start.
    case loopWrapped
    /// The end of the material was reached (never emitted while a loop is active).
    case finished
    /// Just Play: the learner is consistently somewhere else; the transport should seek to this tick.
    case resyncRequested(toTick: Ticks)
}

/// Demo highlights (keys/events the app is currently sounding) kept by both followers and by Listen mode.
struct PracticeDemoTracker {
    private var sounding: [String: (pitches: [Int], until: TimeInterval)] = [:]

    init() {}

    /// Registers an event that just started sounding.
    mutating func started(_ event: TimelineEvent, until: TimeInterval) {
        sounding[event.id] = (event.pitches, until)
    }

    /// Drops entries whose sound has ended.
    mutating func expire(now: TimeInterval) {
        sounding = sounding.filter { $0.value.until > now }
    }

    mutating func removeAll() { sounding.removeAll() }

    /// Writes `.demo` into both maps of a snapshot (never overrides an existing state).
    func apply(to keys: inout [Int: NoteFeedbackState], events: inout [String: NoteFeedbackState], now: TimeInterval) {
        for (id, d) in sounding where d.until > now {
            if events[id] == nil { events[id] = .demo }
            for p in d.pitches where keys[p] == nil { keys[p] = .demo }
        }
    }
}

// MARK: - Material

/// The learner's steps of a timeline, filtered by hand selection and loop region, plus the lookups both followers need.
struct PracticeMaterial {
    let timeline: PlaybackTimeline
    let hands: HandSelection
    let loop: MeasureRange?
    /// Playback ticks covered (the loop's first-pass range, or the whole timeline).
    let tickRange: Range<Ticks>
    /// Steps that contain at least one attack for `hands`, inside `tickRange`, in playback order.
    let steps: [TimelineStep]
    /// `steps[i].attackPitches(for: hands)`, precomputed.
    let expected: [[Int]]
    /// Hands the app plays for the learner.
    let otherHands: [Hand]

    init(timeline: PlaybackTimeline, hands: HandSelection, loop: MeasureRange?) {
        self.timeline = timeline
        self.hands = hands
        self.loop = loop
        let whole: Range<Ticks> = 0..<max(1, timeline.totalTicks)
        let range = loop.flatMap { timeline.tickRange(of: $0) } ?? whole
        tickRange = range
        let learner = timeline.steps(for: hands).filter { range.contains($0.tick) }
        steps = learner
        expected = learner.map { $0.attackPitches(for: hands) }
        otherHands = hands.otherHands
    }

    var isEmpty: Bool { steps.isEmpty }

    /// Index into `steps` of the first step at or after a playback tick (`steps.count` if none).
    func position(atOrAfter tick: Ticks) -> Int {
        var lo = 0, hi = steps.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if steps[mid].tick < tick { lo = mid + 1 } else { hi = mid }
        }
        return lo
    }

    /// Attack-bearing events of the other hands whose onset lies in a half-open tick range.
    func otherHandEvents(in range: Range<Ticks>) -> [TimelineEvent] {
        guard !otherHands.isEmpty, !range.isEmpty else { return [] }
        return timeline.events(in: range).filter { otherHands.contains($0.hand) && !$0.attackPitches.isEmpty }
    }

    /// Attack-bearing events of the other hands that start together with a step.
    func otherHandEvents(ofStep step: TimelineStep) -> [TimelineEvent] {
        guard !otherHands.isEmpty else { return [] }
        return step.events.filter { otherHands.contains($0.hand) && !$0.attackPitches.isEmpty }
    }

    /// Seconds between two playback ticks at a speed (never negative).
    func seconds(from a: Ticks, to b: Ticks, speed: Double) -> Double {
        max(0, timeline.seconds(atTick: b, speed: speed) - timeline.seconds(atTick: a, speed: speed))
    }

    /// Seconds from tick 0 to a fractional playback tick at a speed.
    func seconds(atFractionalTick tick: Double, speed: Double) -> Double {
        let whole = Int(tick.rounded(.down))
        let frac = tick - Double(whole)
        let base = timeline.seconds(atTick: whole, speed: speed)
        guard frac > 0 else { return base }
        return base + frac * (timeline.seconds(atTick: whole + 1, speed: speed) - base)
    }

    /// The chord to sound for a demo event: its attacked pitches for the event's duration at the speed.
    func demoChord(for event: TimelineEvent, speed: Double) -> ImmediateChord {
        ImmediateChord(pitches: event.attackPitches, durationSeconds: max(0.05, seconds(from: event.tick, to: event.endTick, speed: speed)))
    }

    /// Notated measures fully passed when the cursor moves from playback tick `a` to tick `b` (a < b): every
    /// segment from the one containing `a` up to (not including) the one containing `b`; when `b` reaches the end
    /// of the material, the segment containing the last tick is included too.
    func measuresPassed(fromTick a: Ticks, toTick b: Ticks) -> [Int] {
        guard !timeline.segments.isEmpty, b > a else { return [] }
        let first = timeline.segmentIndex(atTick: a)
        let reachesEnd = b >= tickRange.upperBound
        let last = reachesEnd ? timeline.segmentIndex(atTick: tickRange.upperBound - 1) : timeline.segmentIndex(atTick: b) - 1
        guard last >= first else { return [] }
        return (first...last).map { timeline.segments[$0].measureIndex }
    }

    /// Runs of consecutive positions that belong to the same notated measure occurrence: `(measureIndex, first, last)`.
    var measureGroups: [(measureIndex: Int, first: Int, last: Int)] {
        var groups: [(measureIndex: Int, first: Int, last: Int)] = []
        for (i, s) in steps.enumerated() {
            if let g = groups.last, g.measureIndex == s.measureIndex, steps[g.last].pass == s.pass {
                groups[groups.count - 1].last = i
            } else {
                groups.append((s.measureIndex, i, i))
            }
        }
        return groups
    }
}
