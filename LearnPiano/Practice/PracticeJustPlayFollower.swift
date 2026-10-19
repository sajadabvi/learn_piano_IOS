import Foundation

/// Just Play follower: the transport runs at tempo × speed and the learner is scored against it.
///
/// State: `idle → running → finished`. While running, every material step *i* has a scheduled time
/// `scheduled[i]` (seconds from tick 0 at the current speed) and is in one of three states:
/// * **open** — not yet resolved; the first open step is the `frontier` (the "current" step for the UI).
/// * **hit** — all expected pitches arrived within ±`timingWindowSeconds` of the schedule; the completing
///   press decides the outcome: |offset| ≤ window/2 → `correct`, earlier → `early`, later → `late`.
/// * **missed** — the window closed with pitches still missing. The miss is final only once
///   `position > scheduled + window + missGraceSeconds`, so a note whose onset was inside the window but whose
///   event is still in flight (microphone detection latency) is judged by its onset time, not marked missed.
/// A note-on that matches no open step inside its window is `wrong` (reported against the nearest open step).
///
/// Input timing: a note is judged at its onset stamp (`PracticeInputTiming`), extrapolated from the last
/// position update: `pos = positionSeconds + (onset − lastUpdateNow)`. The injected clock must therefore share
/// the input clock's epoch (see `PracticeInputTiming`).
///
/// Loop wrap: near the loop end the learner may land the first step of the next pass slightly early. Such a
/// note (offset measured against `loopEnd + (scheduled[0] − loopStart)`) is buffered in `pendingNextPass`
/// instead of being judged against the ending pass, and credited to step 0 when the transport wraps.
///
/// Re-sync: wrong notes are also matched against steps *outside* the window (open or already missed). When
/// three consecutive learner attacks match three consecutive steps at a consistent offset (within one window
/// of each other), the learner is clearly elsewhere: the three steps become `correct`, their wrong records
/// are withdrawn, steps skipped by a forward jump become `missed`, steps re-opened by a backward jump are
/// cleared, and `.resyncRequested(toTick:)` asks the session to seek the transport.
///
/// `statistics` is computed from the per-step outcome maps, so re-sync corrections are reflected; `records`
/// is the uncorrected stream. The transport position is pushed in through `update(positionTick:)`.
final class PracticeJustPlayFollower {
    /// Lifecycle of the follower.
    enum Phase: Hashable { case idle, running, finished }

    /// One step of a candidate re-sync run: the step the learner seems to be playing, the offset of that
    /// step's schedule from the transport (seconds, + = learner ahead), and the wrong records it would withdraw.
    private struct ChainLink {
        var position: Int
        var offset: Double
        var wrongIDs: [Int]
        var played: [Int]
    }

    let material: PracticeMaterial
    let settings: PracticeSettings
    let clock: PracticeClock
    /// How long a resolved outcome stays visible in the feedback snapshot.
    let flashSeconds: Double = 0.5
    /// Steps marked `upcoming` after the current one.
    let upcomingSteps: Int = 2
    /// How far (in steps) around the frontier a re-sync chain may start.
    let resyncSearchRadius: Int = 16
    /// Consecutive matched attacks needed before a re-sync.
    let resyncChainLength: Int = 3
    /// Extra time after a step's window closes before it is marked missed: covers input events whose onset
    /// lies inside the window but which reach the follower later (microphone detection takes ~100–130 ms).
    let missGraceSeconds: Double = 0.15

    private(set) var phase: Phase = .idle
    /// Transport position at the last `update`.
    private(set) var positionTick: Double = 0
    private var positionSeconds: Double = 0
    private var lastUpdateNow: TimeInterval = 0
    private let scheduled: [Double]
    /// Seconds (from tick 0 at the current speed) of the material's start and end; the loop bounds when looping.
    private let rangeStartSeconds: Double
    private let rangeEndSeconds: Double
    /// Expected pitch of step 0 → (played MIDI, offset) for presses that belong to the next loop pass.
    private var pendingNextPass: [Int: (midi: Int, offset: Double)] = [:]
    private let groups: [(measureIndex: Int, first: Int, last: Int)]

    private var resolved: [Int: PlayedRecord] = [:]
    private var resolvedAt: [Int: TimeInterval] = [:]
    private var partial: [Int: [Int: Int]] = [:]
    private var wrongs: [Int: PlayedRecord] = [:]
    private var wrongSerial = 0
    private var committed = PracticeStatistics()
    private var passMeasures: Set<Int> = []
    private var frontier = 0
    private var chain: [ChainLink] = []
    private var expectingSeek = false
    private var pausedAt: TimeInterval?
    private var demos = PracticeDemoTracker()
    private var recentWrong: [Int: TimeInterval] = [:]

    private(set) var heldPitches: Set<Int> = []
    /// Notated measures completed (all learner steps resolved, at least one hit) across all passes.
    private(set) var measuresCompleted: Set<Int> = []
    /// Every record emitted, in order (uncorrected by re-sync).
    private(set) var records: [PlayedRecord] = []

    init(material: PracticeMaterial, settings: PracticeSettings, clock: PracticeClock) {
        self.material = material
        self.settings = settings
        self.clock = clock
        scheduled = material.steps.map { material.timeline.seconds(atTick: $0.tick, speed: settings.speed) }
        rangeStartSeconds = material.timeline.seconds(atTick: material.tickRange.lowerBound, speed: settings.speed)
        rangeEndSeconds = material.timeline.seconds(atTick: material.tickRange.upperBound, speed: settings.speed)
        groups = material.measureGroups
    }

    convenience init(timeline: PlaybackTimeline, settings: PracticeSettings, clock: PracticeClock) {
        self.init(material: PracticeMaterial(timeline: timeline, hands: settings.hands, loop: settings.loop), settings: settings, clock: clock)
    }

    // MARK: Observable-ish state

    /// Material index of the first open step (nil when everything is resolved or not running).
    var currentPosition: Int? { phase == .running && frontier < material.steps.count ? frontier : nil }
    var currentStep: TimelineStep? { currentPosition.map { material.steps[$0] } }
    var expectedPitches: [Int] { currentPosition.map { material.expected[$0] } ?? [] }
    var missingPitches: [Int] {
        guard let k = currentPosition else { return [] }
        let got = partial[k] ?? [:]
        return material.expected[k].filter { got[$0] == nil }
    }
    var isFinished: Bool { phase == .finished }
    var cursorTick: Double { positionTick }

    /// Corrected counters: committed passes + this pass's outcome maps.
    var statistics: PracticeStatistics {
        var s = committed
        for r in resolved.values { s.record(r) }
        for r in wrongs.values { s.record(r) }
        s.measuresCompleted.formUnion(measuresCompleted)
        return s
    }

    /// Running accuracy (hit / expected so far).
    var accuracy: Double { statistics.accuracy }

    // MARK: Transport

    /// Starts (or restarts) following from a transport tick; steps before it are neither expected nor missed.
    /// Outcomes of an earlier run are banked, so `statistics` covers the follower's whole life (like Wait Mode).
    @discardableResult
    func start(atTick tick: Ticks) -> [PracticeFollowerEvent] {
        bankPass()
        pendingNextPass = [:]
        recentWrong = [:]
        demos.removeAll()
        expectingSeek = false
        pausedAt = nil
        frontier = material.position(atOrAfter: tick)
        positionTick = Double(tick)
        positionSeconds = material.seconds(atFractionalTick: positionTick, speed: settings.speed)
        lastUpdateNow = clock.now
        if material.isEmpty || frontier >= material.steps.count {
            // Nothing to play: finish when the transport does; the session calls `finish()`.
            phase = .running
            return []
        }
        phase = .running
        return [.stepBecameCurrent(stepIndex: material.steps[frontier].index)]
    }

    /// Freezes input-time extrapolation while the transport is paused.
    func pause() { if pausedAt == nil, phase == .running { pausedAt = clock.now } }

    /// Resumes after `pause()`.
    func resume() {
        guard let p = pausedAt else { return }
        lastUpdateNow += clock.now - p
        pausedAt = nil
    }

    var isPaused: Bool { pausedAt != nil }

    /// The transport is about to jump on purpose (user seek, phrase skip). The current pass is banked (steps
    /// skipped by the jump are not counted as missed), following restarts at `tick`, and the next backwards
    /// position change is not mistaken for a loop wrap.
    @discardableResult
    func willSeek(toTick tick: Ticks) -> [PracticeFollowerEvent] {
        guard phase == .running else { return [] }
        bankPass()
        pendingNextPass = [:]
        expectingSeek = true
        positionTick = Double(tick)
        positionSeconds = material.seconds(atFractionalTick: positionTick, speed: settings.speed)
        lastUpdateNow = clock.now
        frontier = material.position(atOrAfter: tick)
        guard frontier < material.steps.count else { return [] }
        return [.stepBecameCurrent(stepIndex: material.steps[frontier].index)]
    }

    /// Marks every open step missed and finishes. Returns the missed records and `.finished`.
    @discardableResult
    func finish() -> [PracticeFollowerEvent] {
        guard phase != .finished else { return [] }
        pendingNextPass = [:]
        var out: [PracticeFollowerEvent] = []
        for i in frontier..<material.steps.count where resolved[i] == nil { out.append(miss(i)) }
        advanceFrontier()
        out += checkMeasures()
        phase = .finished
        out.append(.finished)
        return out
    }

    /// A demo event started sounding (from `ScorePlaybackControlling.onEventStarted`).
    func noteDemo(_ event: TimelineEvent) {
        let seconds = material.seconds(from: event.tick, to: event.endTick, speed: settings.speed)
        demos.started(event, until: clock.now + max(0.05, seconds))
    }

    // MARK: Updates

    /// Pushes the transport position (fractional playback tick). Resolves missed steps and detects loop wraps.
    @discardableResult
    func update(positionTick tick: Double) -> [PracticeFollowerEvent] {
        guard phase == .running else { return [] }
        let now = clock.now
        var out: [PracticeFollowerEvent] = []
        demos.expire(now: now)
        recentWrong = recentWrong.filter { now - $0.value <= flashSeconds }
        let movedBack = tick < positionTick - Double(Ticks.perQuarter) / 2
        if movedBack, expectingSeek {
            expectingSeek = false
        } else if movedBack, material.loop != nil {
            out += wrapLoop()
        } else if !movedBack {
            expectingSeek = false
        }
        positionTick = tick
        positionSeconds = material.seconds(atFractionalTick: tick, speed: settings.speed)
        lastUpdateNow = now
        guard pausedAt == nil else { return out }
        for i in frontier..<material.steps.count where resolved[i] == nil {
            if scheduled[i] + settings.timingWindowSeconds + missGraceSeconds < positionSeconds {
                out.append(miss(i))
            } else if scheduled[i] - settings.timingWindowSeconds > positionSeconds {
                break
            }
        }
        advanceFrontier()
        out += checkMeasures()
        return out
    }

    /// Feeds one note on/off, judged at its onset stamp (`PracticeInputTiming`).
    @discardableResult
    func handle(_ event: NoteInputEvent) -> [PracticeFollowerEvent] {
        handle(event, inputTime: PracticeInputTiming.time(of: event, now: clock.now))
    }

    /// Feeds one note on/off that happened at `inputTime` (on the follower's clock). The position it is judged
    /// at is extrapolated from the last position update, so an onset before the transport (re)started counts
    /// as early against the first step: the session replays presses from the end of the count-in this way.
    @discardableResult
    func handle(_ event: NoteInputEvent, inputTime: TimeInterval) -> [PracticeFollowerEvent] {
        switch event.kind {
        case .off:
            heldPitches.remove(event.midi)
            return []
        case .on:
            heldPitches.insert(event.midi)
        }
        guard phase == .running, pausedAt == nil else { return [] }
        let now = clock.now
        let pos = positionSeconds + (inputTime - lastUpdateNow)
        let window = settings.timingWindowSeconds

        // 1. An open step inside the window whose unsatisfied pitches include this note.
        var best: (position: Int, offset: Double, matched: Int)?
        for i in frontier..<material.steps.count where resolved[i] == nil {
            let offset = pos - scheduled[i]
            if offset < -window { break }
            if offset > window { continue }
            guard let m = PracticePitchMatcher.match(event.midi, in: material.expected[i], octaveTolerance: settings.octaveTolerance), partial[i]?[m] == nil else { continue }
            if best == nil || abs(offset) < abs(best?.offset ?? .infinity) { best = (i, offset, m) }
        }
        // 1b. Near the loop end: step 0 of the next pass, if it fits better.
        if let next = nextPassCandidate(midi: event.midi, pos: pos, window: window), best.map({ abs(next.offset) < abs($0.offset) }) ?? true {
            chain = []
            pendingNextPass[next.matched] = (event.midi, next.offset)
            return []
        }
        if let hit = best {
            chain = []
            var got = partial[hit.position] ?? [:]
            got[hit.matched] = event.midi
            partial[hit.position] = got
            guard got.count == material.expected[hit.position].count else { return [] }
            let record = hitRecord(hit.position, played: got, offset: hit.offset)
            resolve(hit.position, record, now: now)
            var out: [PracticeFollowerEvent] = [.played(record)]
            advanceFrontier()
            out += checkMeasures()
            return out
        }

        // 2. Wrong note, reported against the nearest open step (or the frontier).
        var nearest = min(frontier, material.steps.count - 1)
        if nearest >= 0 {
            for i in frontier..<material.steps.count where resolved[i] == nil {
                if abs(pos - scheduled[i]) < abs(pos - scheduled[nearest]) || resolved[nearest] != nil { nearest = i }
                if scheduled[i] > pos + window { break }
            }
        }
        var out: [PracticeFollowerEvent] = []
        var wrongID = -1
        if nearest >= 0 {
            let step = material.steps[nearest]
            recentWrong[event.midi] = now
            let record = PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: material.expected[nearest], played: [event.midi], outcome: .wrong, deltaSeconds: pos - scheduled[nearest])
            wrongSerial += 1
            wrongID = wrongSerial
            wrongs[wrongID] = record
            records.append(record)
            out.append(.played(record))
        }

        // 3. Re-sync chain: does this note continue (or start) a run of consecutive steps elsewhere?
        extendChain(midi: event.midi, pos: pos, window: window, wrongID: wrongID)
        if chain.count >= resyncChainLength, let last = chain.last {
            out += resync(to: last.position, now: now)
        }
        return out
    }

    // MARK: Feedback

    /// Snapshot for the keyboard and the notation at `clock.now`.
    func feedback() -> FeedbackSnapshot {
        let now = clock.now
        var keys: [Int: NoteFeedbackState] = [:]
        var events: [String: NoteFeedbackState] = [:]
        for p in heldPitches { keys[p] = .pressed }
        var current: Int?
        var missing: [Int] = []
        if let k = currentPosition {
            let step = material.steps[k]
            current = step.index
            let got = partial[k] ?? [:]
            for p in material.expected[k] { keys[p] = got[p] != nil ? .correct : .expected }
            missing = material.expected[k].filter { got[$0] == nil }
            for e in step.events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty {
                events[e.id] = e.attackPitches.allSatisfy { got[$0] != nil } ? .correct : .expected
            }
            for j in (k + 1)...(k + upcomingSteps) where j < material.steps.count {
                for e in material.steps[j].events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty && events[e.id] == nil {
                    events[e.id] = .upcoming
                }
            }
        }
        for (i, t) in resolvedAt where now - t <= flashSeconds {
            guard let r = resolved[i] else { continue }
            let state: NoteFeedbackState = r.outcome == .missed ? .wrong : .correct
            for e in material.steps[i].events where material.hands.includes(e.hand) && !e.attackPitches.isEmpty && events[e.id] == nil {
                events[e.id] = state
            }
        }
        demos.apply(to: &keys, events: &events, now: now)
        for (p, t) in recentWrong where now - t <= flashSeconds { keys[p] = .wrong }
        return FeedbackSnapshot(keyStates: keys, eventStates: events, currentStepIndex: current, missingPitches: missing)
    }

    // MARK: - Internals

    /// The record of a completed step: the completing press's offset decides correct / early / late.
    private func hitRecord(_ i: Int, played got: [Int: Int], offset: Double) -> PlayedRecord {
        let window = settings.timingWindowSeconds
        let outcome: PlayedRecord.Outcome = abs(offset) <= window / 2 ? .correct : (offset < 0 ? .early : .late)
        let step = material.steps[i]
        return PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: material.expected[i], played: material.expected[i].compactMap { got[$0] }.sorted(), outcome: outcome, deltaSeconds: offset)
    }

    /// When looping and `pos` is within one window of the loop end, the match of `midi` against step 0 of the
    /// next pass: its offset from that step's time (`loopEnd + scheduled[0] − loopStart`) and the expected pitch.
    private func nextPassCandidate(midi: Int, pos: Double, window: Double) -> (offset: Double, matched: Int)? {
        guard material.loop != nil, !material.isEmpty, pos > rangeEndSeconds - window else { return nil }
        let offset = pos - (rangeEndSeconds + scheduled[0] - rangeStartSeconds)
        guard abs(offset) <= window,
              let m = PracticePitchMatcher.match(midi, in: material.expected[0], octaveTolerance: settings.octaveTolerance),
              pendingNextPass[m] == nil else { return nil }
        return (offset, m)
    }

    /// Folds the current pass's outcome maps into `committed` and clears them.
    private func bankPass() {
        committed = statistics
        resolved = [:]; resolvedAt = [:]; partial = [:]; wrongs = [:]
        passMeasures = []
        chain = []
    }

    private func resolve(_ i: Int, _ record: PlayedRecord, now: TimeInterval) {
        resolved[i] = record
        resolvedAt[i] = now
        partial[i] = nil
        records.append(record)
    }

    private func reopen(_ i: Int) {
        resolved[i] = nil
        resolvedAt[i] = nil
        partial[i] = nil
    }

    private func miss(_ i: Int) -> PracticeFollowerEvent {
        let step = material.steps[i]
        let record = PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: material.expected[i], played: material.expected[i].compactMap { partial[i]?[$0] }.sorted(), outcome: .missed, deltaSeconds: settings.timingWindowSeconds)
        resolve(i, record, now: clock.now)
        return .played(record)
    }

    private func advanceFrontier() {
        while frontier < material.steps.count, resolved[frontier] != nil { frontier += 1 }
    }

    /// Emits `.measureCompleted` for measure groups fully behind the frontier with at least one hit.
    private func checkMeasures() -> [PracticeFollowerEvent] {
        var out: [PracticeFollowerEvent] = []
        for g in groups where g.last < frontier && !passMeasures.contains(g.first) {
            passMeasures.insert(g.first)
            let hit = (g.first...g.last).contains { resolved[$0].map { $0.outcome != .missed } ?? false }
            if hit {
                measuresCompleted.insert(g.measureIndex)
                out.append(.measureCompleted(measureIndex: g.measureIndex))
            }
        }
        return out
    }

    /// The transport jumped back to the loop start: close the pass and start a fresh one.
    private func wrapLoop() -> [PracticeFollowerEvent] {
        var out: [PracticeFollowerEvent] = []
        for i in frontier..<material.steps.count where resolved[i] == nil { out.append(miss(i)) }
        frontier = material.steps.count
        out += checkMeasures()
        bankPass()
        frontier = 0
        out.append(.loopWrapped)
        guard !material.isEmpty else { return out }
        out.append(.stepBecameCurrent(stepIndex: material.steps[0].index))
        // Presses that landed just before the wrap belong to step 0 of this new pass.
        let early = pendingNextPass
        pendingNextPass = [:]
        guard !early.isEmpty else { return out }
        var got: [Int: Int] = [:]
        for (pitch, press) in early { got[pitch] = press.midi }
        guard got.count == material.expected[0].count else {
            partial[0] = got
            return out
        }
        let completing = early.values.map { $0.offset }.max() ?? 0
        let record = hitRecord(0, played: got, offset: completing)
        resolve(0, record, now: clock.now)
        out.append(.played(record))
        advanceFrontier()
        out += checkMeasures()
        if frontier < material.steps.count { out.append(.stepBecameCurrent(stepIndex: material.steps[frontier].index)) }
        return out
    }

    /// Extends (or restarts) the re-sync run with a note that matched nothing inside the timing window.
    /// A further note of the chord at the head of the run stays on that link; a note of the next step at a
    /// consistent offset appends a link; anything else starts a new run at the closest matching step.
    private func extendChain(midi: Int, pos: Double, window: Double, wrongID: Int) {
        func matches(_ j: Int) -> Double? {
            guard material.steps.indices.contains(j) else { return nil }
            if let r = resolved[j], r.outcome != .missed { return nil }
            guard PracticePitchMatcher.match(midi, in: material.expected[j], octaveTolerance: settings.octaveTolerance) != nil else { return nil }
            let offset = scheduled[j] - pos
            return abs(offset) > window ? offset : nil
        }
        let ids = wrongID >= 0 ? [wrongID] : []
        if let last = chain.last {
            if !last.played.contains(midi), matches(last.position) != nil {
                chain[chain.count - 1].wrongIDs += ids
                chain[chain.count - 1].played.append(midi)
                return
            }
            if let offset = matches(last.position + 1), abs(offset - last.offset) <= window {
                chain.append(ChainLink(position: last.position + 1, offset: offset, wrongIDs: ids, played: [midi]))
                return
            }
        }
        let lo = max(0, frontier - resyncSearchRadius)
        let hi = min(material.steps.count - 1, frontier + resyncSearchRadius)
        var start: ChainLink?
        if lo <= hi {
            for j in lo...hi {
                guard let offset = matches(j) else { continue }
                if start == nil || abs(offset) < abs(start?.offset ?? .infinity) {
                    start = ChainLink(position: j, offset: offset, wrongIDs: ids, played: [midi])
                }
            }
        }
        chain = start.map { [$0] } ?? []
    }

    /// The learner is at step `target`: credit the chain, fix skipped/re-opened steps, move the position.
    private func resync(to target: Int, now: TimeInterval) -> [PracticeFollowerEvent] {
        var out: [PracticeFollowerEvent] = []
        let links = chain
        chain = []
        pendingNextPass = [:]
        let firstPosition = links.map { $0.position }.min() ?? target
        if firstPosition > frontier {
            for i in frontier..<firstPosition where resolved[i] == nil { out.append(miss(i)) }
        }
        if target < frontier {
            for i in (target + 1)..<material.steps.count { reopen(i) }
        }
        for link in links {
            for id in link.wrongIDs { wrongs[id] = nil }
            let step = material.steps[link.position]
            let record = PlayedRecord(stepIndex: step.index, measureIndex: step.measureIndex, expected: material.expected[link.position], played: link.played.sorted(), outcome: .correct, deltaSeconds: 0)
            resolve(link.position, record, now: now)
            out.append(.played(record))
        }
        passMeasures = passMeasures.filter { first in groups.first { $0.first == first }.map { $0.last <= target } ?? false }
        let tick = material.steps[target].tick
        expectingSeek = true
        positionTick = Double(tick)
        positionSeconds = scheduled[target]
        lastUpdateNow = now
        frontier = min(frontier, target + 1)
        advanceFrontier()
        out += checkMeasures()
        out.append(.resyncRequested(toTick: tick))
        return out
    }
}
