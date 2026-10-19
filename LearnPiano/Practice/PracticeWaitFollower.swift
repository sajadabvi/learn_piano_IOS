import Foundation

/// Wait Mode score follower (the engine behind "the score waits for you").
///
/// State machine (`Phase`):
///
///     idle ──start──▶ waiting(k) ──all pitches of E(k) satisfied──▶ gap(k → k+1)
///                        ▲                                              │
///                        └──────────── gap elapsed (scaled rest) ◀──────┘
///     gap(last → loop start, wraps)  ──elapsed──▶ waiting(0)          (loop region set)
///     gap(last → end)                ──elapsed──▶ finished            (no loop)
///
/// * `waiting(k)`: the cursor sits on material step *k*; `E = expected[k]`. A note-on that matches an
///   unsatisfied pitch of `E` satisfies it (octave tolerance compares pitch classes). A note-on matching
///   nothing is a wrong note: reported with the expected set, counted per measure, never advances.
///   Re-pressing an already satisfied pitch is ignored. Keys held from before the step became current
///   never count because no new note-on arrives for them; tie continuations are already excluded from `E`.
/// * Completion: every pitch of `E` satisfied. With the `lenient` window policy the chord window only
///   restarts at the latest press; with `strict` satisfactions older than one window expire first.
/// * On completion a `.played(correct)` record is emitted (deltaSeconds = time since the step became
///   current), the other hands' events of the step are emitted as `.soundChord`, and the follower enters
///   `gap`. The gap lasts `seconds(step k → step k+1, speed) × waitModeRestScale`; other-hand events whose
///   onsets fall in the gap are sounded at their scaled offsets. A zero-length gap resolves immediately.
/// * Note-ons during a gap that match the next step are credited when it becomes current (early attacks).
/// * Held keys (`PracticeWaitOptions.creditsHeldKeys`): a key still down when a step becomes current is
///   credited at most once per physical press (`creditedHeld`), so holding a key cannot replay a loop by itself.
///
/// Gap resolution is iterative: `complete` only opens the gap; `update()` (called after every input and by
/// `start`) loops while gaps have elapsed. Each round that completes a step at once consumes the early-attack
/// buffer or a held key's single credit, so the loop terminates.
///
/// All timing comes from the injected `PracticeClock`; call `update()` regularly (once per frame) so gaps
/// resolve and scheduled demo chords fire. Note-ons are judged at their onset stamp (`PracticeInputTiming`),
/// so the clock must share the input clock's epoch. Pure logic: no Observation, no audio, usable from any
/// thread as long as calls are serialized.
final class PracticeWaitFollower {
    /// Where the follower is. See the type documentation for the transitions.
    enum Phase: Hashable {
        case idle
        /// Step `position` (index into `material.steps`) is expected.
        case waiting(position: Int)
        /// Between two steps. `to == steps.count` means "heading for the end"; `wraps` means heading for the loop start.
        case gap(from: Int, to: Int, wraps: Bool, startedAt: TimeInterval, duration: TimeInterval)
        case finished
    }

    private struct Satisfaction: Hashable {
        var played: Int
        var time: TimeInterval
    }

    private struct PendingDemo {
        var fireAt: TimeInterval
        var event: TimelineEvent
        var chord: ImmediateChord
    }

    let material: PracticeMaterial
    let settings: PracticeSettings
    let options: PracticeWaitOptions
    let clock: PracticeClock

    private(set) var phase: Phase = .idle
    /// Expected pitch → how/when it was satisfied, for the current step.
    private var satisfied: [Int: Satisfaction] = [:]
    private var windowStart: TimeInterval?
    private var stepBecameCurrentAt: TimeInterval = 0
    /// Expected pitch of the upcoming step → press that arrived during the gap.
    private var earlyAttacks: [Int: Satisfaction] = [:]
    private var pendingDemos: [PendingDemo] = []
    private var demos = PracticeDemoTracker()
    private var recentWrong: [Int: TimeInterval] = [:]
    private var recentCorrectEvents: [String: TimeInterval] = [:]
    private var pausedAt: TimeInterval?
    /// Wrong notes played while the current step was expected.
    private var wrongsInStep = 0
    /// Held keys that already earned their one held-key credit (cleared by the key's next note-on/off).
    private var creditedHeld: Set<Int> = []

    /// Keys physically down right now (from the input stream).
    private(set) var heldPitches: Set<Int> = []
    /// Counters for the whole life of this follower (loop passes included).
    private(set) var statistics = PracticeStatistics()
    /// Every record emitted, in order.
    private(set) var records: [PlayedRecord] = []

    init(material: PracticeMaterial, settings: PracticeSettings, clock: PracticeClock, options: PracticeWaitOptions = PracticeWaitOptions()) {
        self.material = material
        self.settings = settings
        self.clock = clock
        self.options = options
    }

    /// Convenience: builds the material from a timeline.
    convenience init(timeline: PlaybackTimeline, settings: PracticeSettings, clock: PracticeClock, options: PracticeWaitOptions = PracticeWaitOptions()) {
        self.init(material: PracticeMaterial(timeline: timeline, hands: settings.hands, loop: settings.loop), settings: settings, clock: clock, options: options)
    }

    // MARK: Position

    /// Material index of the step the learner should play now (during a gap: the step being approached).
    var currentPosition: Int? {
        switch phase {
        case .waiting(let k): return k
        case .gap(_, let to, _, _, _): return to < material.steps.count ? to : nil
        case .idle, .finished: return nil
        }
    }

    /// The timeline step currently expected, if any.
    var currentStep: TimelineStep? { currentPosition.map { material.steps[$0] } }

    /// Pitches the learner must play for the current step.
    var expectedPitches: [Int] { currentPosition.map { material.expected[$0] } ?? [] }

    /// Pitches of the current step not yet satisfied.
    var missingPitches: [Int] { expectedPitches.filter { satisfied[$0] == nil } }

    /// Pitches of the current step already satisfied.
    var satisfiedPitches: [Int] { expectedPitches.filter { satisfied[$0] != nil } }

    var isFinished: Bool { phase == .finished }

    /// Playback tick for the views: the current step's tick, interpolated towards the next during a gap.
    var cursorTick: Double {
        switch phase {
        case .idle:
            return Double(material.steps.first?.tick ?? material.tickRange.lowerBound)
        case .waiting(let k):
            return Double(material.steps[k].tick)
        case .gap(let from, let to, let wraps, let startedAt, let duration):
            let a = Double(material.steps[from].tick)
            let b = Double((to < material.steps.count && !wraps) ? material.steps[to].tick : material.tickRange.upperBound)
            let reference = pausedAt ?? clock.now
            let progress = duration <= 0 ? 1 : min(1, max(0, (reference - startedAt) / duration))
            return a + (b - a) * progress
        case .finished:
            return Double(material.tickRange.upperBound)
        }
    }

    // MARK: Transport

    /// Starts (or restarts) at the first step at/after `tick` (clamped to the last step). Empty material finishes at once.
    @discardableResult
    func start(atTick tick: Ticks? = nil) -> [PracticeFollowerEvent] {
        satisfied = [:]
        windowStart = nil
        earlyAttacks = [:]
        pendingDemos = []
        demos.removeAll()
        recentWrong = [:]
        recentCorrectEvents = [:]
        pausedAt = nil
        guard !material.isEmpty else {
            phase = .finished
            return [.finished]
        }
        let position = tick.map { material.position(atOrAfter: $0) } ?? 0
        var out = makeCurrent(min(position, material.steps.count - 1), at: clock.now)
        out += update()
        return out
    }

    /// Freezes gap timers and pending demos (the cursor stops moving).
    func pause() {
        guard pausedAt == nil, phase != .finished, phase != .idle else { return }
        pausedAt = clock.now
    }

    /// Resumes after `pause()`, shifting every timer by the paused duration.
    func resume() {
        guard let p = pausedAt else { return }
        let shift = clock.now - p
        pausedAt = nil
        if case .gap(let from, let to, let wraps, let startedAt, let duration) = phase {
            phase = .gap(from: from, to: to, wraps: wraps, startedAt: startedAt + shift, duration: duration)
        }
        stepBecameCurrentAt += shift
        for i in pendingDemos.indices { pendingDemos[i].fireAt += shift }
    }

    var isPaused: Bool { pausedAt != nil }

    // MARK: Input

    /// Feeds one note on/off. Returns the events it caused (timers that became due are resolved first, and
    /// zero-length gaps opened by a completion are resolved after). A note-on is judged at its onset stamp.
    @discardableResult
    func handle(_ event: NoteInputEvent) -> [PracticeFollowerEvent] {
        var out = update()
        creditedHeld.remove(event.midi)
        switch event.kind {
        case .off:
            heldPitches.remove(event.midi)
            return out
        case .on:
            heldPitches.insert(event.midi)
        }
        guard pausedAt == nil else { return out }
        let now = clock.now
        let time = PracticeInputTiming.time(of: event, now: now)
        switch phase {
        case .waiting(let k):
            out += attack(event.midi, step: k, at: time, now: now, early: false)
        case .gap(_, let to, _, _, _) where to < material.steps.count:
            out += attack(event.midi, step: to, at: time, now: now, early: true)
        case .idle, .finished, .gap:
            break
        }
        out += update()
        return out
    }

    /// Resolves timers that are due at `clock.now`: gap endings, scheduled demo chords, feedback flashes.
    @discardableResult
    func update() -> [PracticeFollowerEvent] {
        let now = pausedAt ?? clock.now
        var out: [PracticeFollowerEvent] = []
        out += fireDueDemos(now: now)
        demos.expire(now: now)
        recentWrong = recentWrong.filter { now - $0.value <= options.wrongFlashSeconds }
        recentCorrectEvents = recentCorrectEvents.filter { now - $0.value <= options.correctFlashSeconds }
        guard pausedAt == nil else { return out }
        // A gap may end and make the next step current, which an early attack or a held key may complete at
        // once, opening a new gap… Each such round consumes the early-attack buffer or a held key's single
        // credit (`creditedHeld`), so this loop terminates; `complete` never re-enters it.
        while case .gap(_, let to, let wraps, let startedAt, let duration) = phase, now >= startedAt + duration {
            out += fireDueDemos(now: .infinity)
            if to >= material.steps.count {
                phase = .finished
                out.append(.finished)
                break
            }
            if wraps { out.append(.loopWrapped) }
            out += makeCurrent(to, at: now)
        }
        return out
    }

    // MARK: Feedback

    /// Snapshot for the keyboard and the notation at `clock.now`.
    func feedback() -> FeedbackSnapshot {
        let now = pausedAt ?? clock.now
        var keys: [Int: NoteFeedbackState] = [:]
        var events: [String: NoteFeedbackState] = [:]
        for p in heldPitches { keys[p] = .pressed }
        var current: Int?
        var missing: [Int] = []
        if let k = currentPosition {
            let step = material.steps[k]
            current = step.index
            let expected = material.expected[k]
            for p in expected { keys[p] = satisfied[p] != nil ? .correct : .expected }
            missing = expected.filter { satisfied[$0] == nil }
            for e in step.events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty {
                events[e.id] = e.attackPitches.allSatisfy { satisfied[$0] != nil } ? .correct : .expected
            }
            if options.upcomingSteps > 0 {
                for j in (k + 1)...(k + options.upcomingSteps) where j < material.steps.count {
                    for e in material.steps[j].events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty && events[e.id] == nil {
                        events[e.id] = .upcoming
                    }
                }
            }
        }
        for (id, t) in recentCorrectEvents where now - t <= options.correctFlashSeconds && events[id] == nil { events[id] = .correct }
        demos.apply(to: &keys, events: &events, now: now)
        for (p, t) in recentWrong where now - t <= options.wrongFlashSeconds { keys[p] = .wrong }
        return FeedbackSnapshot(keyStates: keys, eventStates: events, currentStepIndex: current, missingPitches: missing)
    }

    // MARK: - Internals

    /// Enters `waiting(k)`: clears the chord state, then credits early attacks (and held keys if enabled).
    private func makeCurrent(_ k: Int, at now: TimeInterval) -> [PracticeFollowerEvent] {
        phase = .waiting(position: k)
        satisfied = [:]
        windowStart = nil
        wrongsInStep = 0
        stepBecameCurrentAt = now
        var out: [PracticeFollowerEvent] = [.stepBecameCurrent(stepIndex: material.steps[k].index)]
        let early = earlyAttacks
        earlyAttacks = [:]
        let expected = material.expected[k]
        for (pitch, s) in early where expected.contains(pitch) {
            satisfied[pitch] = s
            windowStart = min(windowStart ?? s.time, s.time)
        }
        if options.creditsHeldKeys {
            for held in heldPitches.sorted() where !creditedHeld.contains(held) {
                guard let m = PracticePitchMatcher.match(held, in: expected, octaveTolerance: settings.octaveTolerance), satisfied[m] == nil else { continue }
                satisfied[m] = Satisfaction(played: held, time: now)
                windowStart = windowStart ?? now
                creditedHeld.insert(held)
            }
        }
        if !expected.isEmpty, satisfied.count == expected.count {
            out += complete(k, now: now)
        }
        return out
    }

    /// A matched or unmatched note-on at onset `time` while step `k` is current (`early` = during the gap
    /// before it). `now` is the processing time, used only for feedback flashes.
    private func attack(_ midi: Int, step k: Int, at time: TimeInterval, now: TimeInterval, early: Bool) -> [PracticeFollowerEvent] {
        let expected = material.expected[k]
        guard let matched = PracticePitchMatcher.match(midi, in: expected, octaveTolerance: settings.octaveTolerance) else {
            return wrong(midi, step: k, at: time, now: now)
        }
        if early {
            if options.acceptsEarlyAttacks { earlyAttacks[matched] = Satisfaction(played: midi, time: time) }
            return []
        }
        guard satisfied[matched] == nil else { return [] }
        if options.chordWindowPolicy == .strict {
            satisfied = satisfied.filter { time - $0.value.time <= settings.chordWindowSeconds }
        }
        satisfied[matched] = Satisfaction(played: midi, time: time)
        if let ws = windowStart {
            if time - ws > settings.chordWindowSeconds { windowStart = time }
        } else {
            windowStart = time
        }
        return satisfied.count == expected.count ? complete(k, now: max(time, stepBecameCurrentAt)) : []
    }

    /// Reports a wrong note (onset `time`) against step `k` (never advances).
    private func wrong(_ midi: Int, step k: Int, at time: TimeInterval, now: TimeInterval) -> [PracticeFollowerEvent] {
        let step = material.steps[k]
        recentWrong[midi] = now
        if case .waiting = phase { wrongsInStep += 1 }
        let record = PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: material.expected[k], played: [midi], outcome: .wrong, deltaSeconds: max(0, time - stepBecameCurrentAt))
        statistics.record(record)
        records.append(record)
        return [.played(record)]
    }

    /// Step `k` is complete at `now` (the completing onset): record it, sound the other hands, credit passed
    /// measures and open the gap. It does not resolve the gap; the caller's `update()` does.
    private func complete(_ k: Int, now: TimeInterval) -> [PracticeFollowerEvent] {
        let step = material.steps[k]
        let expected = material.expected[k]
        let played = expected.compactMap { satisfied[$0]?.played }.sorted()
        let record = PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: expected, played: played, outcome: .correct, deltaSeconds: max(0, now - stepBecameCurrentAt))
        statistics.record(record)
        if wrongsInStep > 0 { statistics.stepsWithMistakes += 1 }
        wrongsInStep = 0
        records.append(record)
        var out: [PracticeFollowerEvent] = [.played(record)]
        for e in step.events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty { recentCorrectEvents[e.id] = now }
        if settings.playOtherHands {
            for e in material.otherHandEvents(ofStep: step) { out.append(sound(e, now: now)) }
        }

        let scale = settings.waitModeRestScale
        let speed = settings.speed
        let next = k + 1
        let fromTick = step.tick
        if next < material.steps.count {
            let toTick = material.steps[next].tick
            for m in material.measuresPassed(fromTick: fromTick, toTick: toTick) { out.append(completeMeasure(m)) }
            schedule(in: (fromTick + 1)..<toTick, baseTick: fromTick, baseOffset: 0, now: now)
            let duration = material.seconds(from: fromTick, to: toTick, speed: speed) * scale
            phase = .gap(from: k, to: next, wraps: false, startedAt: now, duration: duration)
        } else {
            let end = material.tickRange.upperBound
            for m in material.measuresPassed(fromTick: fromTick, toTick: end) { out.append(completeMeasure(m)) }
            schedule(in: (fromTick + 1)..<max(fromTick + 1, end), baseTick: fromTick, baseOffset: 0, now: now)
            let tail = material.seconds(from: fromTick, to: end, speed: speed) * scale
            if material.loop != nil, let first = material.steps.first {
                let lower = material.tickRange.lowerBound
                schedule(in: lower..<first.tick, baseTick: lower, baseOffset: tail, now: now)
                let head = material.seconds(from: lower, to: first.tick, speed: speed) * scale
                phase = .gap(from: k, to: 0, wraps: true, startedAt: now, duration: tail + head)
            } else {
                phase = .gap(from: k, to: material.steps.count, wraps: false, startedAt: now, duration: tail)
            }
        }
        return out
    }

    /// Records a completed measure.
    private func completeMeasure(_ index: Int) -> PracticeFollowerEvent {
        statistics.measuresCompleted.insert(index)
        return .measureCompleted(measureIndex: index)
    }

    /// Queues the other hands' events in a tick range at `baseOffset + scaled seconds from baseTick`.
    private func schedule(in range: Range<Ticks>, baseTick: Ticks, baseOffset: Double, now: TimeInterval) {
        guard settings.playOtherHands, !range.isEmpty else { return }
        for e in material.otherHandEvents(in: range) {
            let offset = baseOffset + material.seconds(from: baseTick, to: e.tick, speed: settings.speed) * settings.waitModeRestScale
            pendingDemos.append(PendingDemo(fireAt: now + offset, event: e, chord: material.demoChord(for: e, speed: settings.speed)))
        }
        pendingDemos.sort { $0.fireAt < $1.fireAt }
    }

    /// Sounds one other-hand event now and marks it as a demo highlight.
    private func sound(_ event: TimelineEvent, now: TimeInterval) -> PracticeFollowerEvent {
        let chord = material.demoChord(for: event, speed: settings.speed)
        demos.started(event, until: now + chord.durationSeconds)
        return .soundChord(chord, eventID: event.id)
    }

    /// Emits every scheduled demo chord due at `now`.
    private func fireDueDemos(now: TimeInterval) -> [PracticeFollowerEvent] {
        var out: [PracticeFollowerEvent] = []
        while let next = pendingDemos.first, next.fireAt <= now {
            pendingDemos.removeFirst()
            demos.started(next.event, until: min(now, clock.now) + next.chord.durationSeconds)
            out.append(.soundChord(next.chord, eventID: next.event.id))
        }
        return out
    }
}

/// Name used in the module brief for the Wait Mode follower.
typealias PracticeScoreFollower = PracticeWaitFollower
