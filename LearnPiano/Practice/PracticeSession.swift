import Foundation
import Observation

/// The observable practice session behind the practice screen: one score, the learner's settings, the
/// transport, the active follower and the statistics. Views read its published state; PracticeUI forwards
/// input events and transport buttons to it.
///
/// ## Transport state machine (`TransportState`)
///
///     stopped ──play──▶ countingIn ──count-in done──▶ playing ⇄ paused        (Just Play / Listen)
///     stopped ──play──────────────────────────────▶ playing ⇄ paused          (Wait Mode: no count-in)
///     playing ──end of material──▶ finished ──play──▶ (new session from the start)
///     playing ──loop end──▶ playing (back at the loop start; never `finished` while a loop is set)
///     any ──stop──▶ stopped (the session ends: a `PracticeSessionRecord` is emitted)
///     any ──restart──▶ stopped ──▶ play again from the start/loop start (same statistics session)
///
/// * Count-in: Just Play and Listen count `countInMeasures` measures in before the transport starts (also
///   when resuming from pause). Wait Mode needs none: it waits for the learner anyway.
/// * Pausing during the count-in cancels it; `play()` then counts in again.
/// * Just Play: note-ons during the count-in are buffered; those within one timing window of the downbeat
///   are replayed into the follower when the transport starts and judged as early against the first step,
///   so landing the first note a little early is not lost (also after resuming from pause).
/// * A statistics "session" runs from the first `play()` to `stop()` or `finished`. Settings changes in the
///   middle (mode, hands, speed, loop…) rebuild the follower at the current position and keep the counters.
///
/// ## Driving
/// All timing comes from the injected `PracticeClock`. With `drivesItself` (the default in the app) the
/// session runs a ~60 Hz main-actor task while the transport is active and calls `refresh()`; tests and the
/// harness pass `drivesItself: false` and call `refresh()` themselves after advancing a manual clock.
///
/// ## Audio
/// With a `ScorePlaybackControlling` player attached, Just Play and Listen play the timeline through it and
/// Wait Mode sounds the other hands with `playImmediately`. Without a player a silent clock-driven
/// `PracticeVirtualTransport` stands in, so every mode works (and is testable) without audio.
@MainActor
@Observable
final class PracticeSession {
    // MARK: Published state

    /// The score being practiced.
    private(set) var score: Score
    /// The score flattened into playback order.
    private(set) var timeline: PlaybackTimeline
    /// Current learner settings (change them with the convenience properties or `updateSettings`).
    private(set) var settings: PracticeSettings
    /// Transport status.
    private(set) var transportState: TransportState = .stopped
    /// Fractional playback tick for the cursor (interpolated during Wait Mode gaps and timed playback).
    private(set) var cursorTick: Double = 0
    /// Highlight states for keyboard and notation.
    private(set) var feedback: FeedbackSnapshot = .empty
    /// The timeline step the learner should play now (Wait) / is due now (Just Play); nil otherwise.
    private(set) var currentStep: TimelineStep?
    /// Pitches expected for `currentStep`.
    private(set) var expectedPitches: [Int] = []
    /// 0-based beat of the running count-in, nil when not counting in.
    private(set) var countInBeat: Int?
    /// Number of beats in the running count-in.
    private(set) var countInTotalBeats: Int = 0
    /// Counters of the current statistics session.
    private(set) var statistics = PracticeStatistics()
    /// Seconds spent in `playing` during the current statistics session.
    private(set) var practicedSeconds: Double = 0
    /// Most recent judged attack (for a toast or a sound cue).
    private(set) var lastPlayed: PlayedRecord?
    /// Number of times the loop region wrapped in this session.
    private(set) var loopsCompleted = 0
    /// Record of the last ended session (also delivered through `onSessionEnded`).
    private(set) var lastRecord: PracticeSessionRecord?

    // MARK: Derived state

    /// Accuracy so far (0…1) in the mode's own sense (see `PracticeSummaryBuilder`).
    var accuracy: Double {
        switch settings.mode {
        case .wait: return statistics.stepsExpected == 0 ? 0 : Double(statistics.cleanSteps) / Double(statistics.stepsExpected)
        case .justPlay: return statistics.accuracy
        case .listen: return 0
        }
    }
    /// Notes the learner played (correct and wrong).
    var notesPlayed: Int { statistics.notesPlayed }
    /// Distinct notated measures completed this session.
    var measuresCompletedCount: Int { statistics.measuresCompleted.count }
    /// Wrong notes per notated measure index.
    var mistakesByMeasure: [Int: Int] { statistics.mistakesByMeasure }
    /// Notated measure (and repeat pass) under the cursor.
    var cursorMeasure: (measureIndex: Int, tickInMeasure: Ticks, pass: Int) { timeline.measurePosition(atTick: Int(cursorTick.rounded(.down))) }
    /// Whether the transport is moving or counting in.
    var isActive: Bool { transportState == .playing || transportState == .countingIn }
    /// Keyboard state of one MIDI pitch (nil = neutral).
    func keyState(for midi: Int) -> NoteFeedbackState? { feedback.keyStates[midi] }
    /// Notation state of one timeline event (nil = neutral).
    func eventState(for eventID: String) -> NoteFeedbackState? { feedback.eventStates[eventID] }

    // MARK: Settings conveniences

    /// Practice mode. Changing it mid-session rebuilds the follower at the current position.
    var mode: PracticeMode {
        get { settings.mode }
        set { var s = settings; s.mode = newValue; updateSettings(s) }
    }
    /// Hands the learner plays.
    var hands: HandSelection {
        get { settings.hands }
        set { var s = settings; s.hands = newValue; updateSettings(s) }
    }
    /// Speed multiplier, clamped to 0.25…1.0 and snapped to 0.05 steps.
    var speed: Double {
        get { settings.speed }
        set { var s = settings; s.speed = newValue; updateSettings(s) }
    }
    /// Loop region in notated measures (nil = whole piece).
    var loop: MeasureRange? {
        get { settings.loop }
        set { var s = settings; s.loop = newValue; updateSettings(s) }
    }
    /// Metronome during timed playback.
    var metronomeEnabled: Bool {
        get { settings.metronome }
        set { var s = settings; s.metronome = newValue; updateSettings(s) }
    }
    /// Count-in measures before timed playback (0…2).
    var countInMeasures: Int {
        get { settings.countInMeasures }
        set { var s = settings; s.countInMeasures = newValue; updateSettings(s) }
    }

    // MARK: Integration hooks

    /// Identifier of the arrangement (for the summary).
    let arrangementID: String
    /// Every follower event, after the session has acted on it (sound chords are already sent to the player).
    @ObservationIgnored var onFollowerEvent: ((PracticeFollowerEvent) -> Void)?
    /// Called once per ended statistics session (stop or finish) with the record to persist.
    @ObservationIgnored var onSessionEnded: ((PracticeSessionRecord) -> Void)?

    // MARK: Dependencies and internals

    @ObservationIgnored let clock: PracticeClock
    @ObservationIgnored private(set) var player: ScorePlaybackControlling?
    @ObservationIgnored private(set) var metronome: MetronomeControlling?
    @ObservationIgnored private let dateProvider: () -> Date
    @ObservationIgnored private let drivesItself: Bool
    @ObservationIgnored private let waitOptions: PracticeWaitOptions
    @ObservationIgnored private var material: PracticeMaterial
    @ObservationIgnored private var waitFollower: PracticeWaitFollower?
    @ObservationIgnored private var justPlayFollower: PracticeJustPlayFollower?
    @ObservationIgnored private var virtualTransport: PracticeVirtualTransport
    @ObservationIgnored private var listenDemos = PracticeDemoTracker()
    @ObservationIgnored private var lastListenTick: Double = 0
    @ObservationIgnored private var heldPitches: Set<Int> = []
    /// Statistics/records of followers replaced earlier in this statistics session.
    @ObservationIgnored private var bankedStatistics = PracticeStatistics()
    @ObservationIgnored private var bankedRecords: [PlayedRecord] = []
    /// Where `play()` starts from when stopped.
    @ObservationIgnored private var startTick: Ticks = 0
    @ObservationIgnored private var sessionStartedAt: Date?
    @ObservationIgnored private var accumulatedSeconds: Double = 0
    @ObservationIgnored private var playingSince: TimeInterval?
    @ObservationIgnored private var needsFreshSession = true
    /// Clock-driven count-in when no metronome is attached.
    @ObservationIgnored private var countInStartedAt: TimeInterval?
    @ObservationIgnored private var countInBeatSeconds: Double = 0
    /// Whether the running count-in resumes a paused transport (vs. starting it).
    @ObservationIgnored private var countInResumes = false
    /// Just Play note-ons received during the count-in, with their onset times (newest last, bounded).
    @ObservationIgnored private var countInPresses: [(event: NoteInputEvent, time: TimeInterval)] = []
    /// Upper bound on `countInPresses` (only the last timing window before the downbeat matters).
    private static let countInPressLimit = 16
    @ObservationIgnored private var driverTask: Task<Void, Never>?
    /// Identifies the current driver task so a stale task never clears a newer one.
    @ObservationIgnored private var driverGeneration = 0

    /// Creates a session.
    /// - Parameters:
    ///   - score: the score to practice.
    ///   - arrangementID: catalog arrangement id used in the summary.
    ///   - settings: initial settings (speed is snapped to 0.25…1.0 in 0.05 steps).
    ///   - clock: time source for every timing decision.
    ///   - player: audio player (nil = silent clock-driven transport).
    ///   - metronome: metronome (nil = clock-driven count-in without sound).
    ///   - waitOptions: Wait Mode tunables.
    ///   - drivesItself: run a ~60 Hz refresh task while active (false for tests).
    ///   - dateProvider: wall-clock date for `PracticeSummary.startedAt`.
    init(score: Score, arrangementID: String, settings: PracticeSettings = PracticeSettings(), clock: PracticeClock = SystemPracticeClock(), player: ScorePlaybackControlling? = nil, metronome: MetronomeControlling? = nil, waitOptions: PracticeWaitOptions = PracticeWaitOptions(), drivesItself: Bool = true, dateProvider: @escaping () -> Date = Date.init) {
        var s = settings
        s.speed = PracticeSpeedRules.snap(settings.speed)
        let timeline = score.makeTimeline()
        if let l = s.loop { s.loop = score.measures.isEmpty ? nil : l.clamped(toMeasureCount: score.measures.count) }
        self.score = score
        self.timeline = timeline
        self.settings = s
        self.arrangementID = arrangementID
        self.clock = clock
        self.waitOptions = waitOptions
        self.drivesItself = drivesItself
        self.dateProvider = dateProvider
        self.material = PracticeMaterial(timeline: timeline, hands: s.hands, loop: s.loop)
        self.virtualTransport = PracticeVirtualTransport(timeline: timeline, speed: s.speed)
        self.startTick = material.tickRange.lowerBound
        self.cursorTick = Double(material.steps.first?.tick ?? material.tickRange.lowerBound)
        attach(player: player, metronome: metronome)
        publish()
    }

    /// Attaches (or replaces) the audio player and metronome. Loads the timeline and installs callbacks.
    func attach(player: ScorePlaybackControlling?, metronome: MetronomeControlling?) {
        self.player?.onReachedEnd = nil
        self.player?.onEventStarted = nil
        self.player = player
        self.metronome = metronome
        guard let player else { return }
        player.load(timeline: timeline)
        player.onReachedEnd = { [weak self] in self?.playerReachedEnd() }
        player.onEventStarted = { [weak self] event in self?.playerStartedEvent(event) }
    }

    // MARK: - Transport commands

    /// Starts, resumes, or (after `finished`) starts a new session from the beginning / loop start.
    func play() {
        switch transportState {
        case .playing, .countingIn:
            return
        case .paused:
            if hasFollowerForMode { resumeFromPause() } else { begin(resuming: false) }
        case .finished:
            startTick = material.tickRange.lowerBound
            begin(resuming: false)
        case .stopped:
            begin(resuming: false)
        }
        publish()
    }

    /// Pauses playback (or cancels a running count-in).
    func pause() {
        let now = clock.now
        switch transportState {
        case .countingIn:
            cancelCountIn()
            transportState = .paused
        case .playing:
            bankPlayingTime(now: now)
            waitFollower?.pause()
            justPlayFollower?.pause()
            player?.pause()
            metronome?.stop()
            virtualTransport.pause(now: now)
            transportState = .paused
        case .stopped, .paused, .finished:
            return
        }
        updateDriver()
        publish()
    }

    /// Toggles between playing and paused (stopped/finished → play).
    func togglePlayPause() {
        if isActive { pause() } else { play() }
    }

    /// Ends the statistics session (emitting its record) and rewinds to the start / loop start.
    @discardableResult
    func stop() -> PracticeSessionRecord? {
        guard transportState != .stopped || !needsFreshSession else { return nil }
        let wasFinished = transportState == .finished
        halt()
        startTick = material.tickRange.lowerBound
        transportState = .stopped
        let record = wasFinished ? nil : endSession(reachedEnd: false)
        resetCursor()
        updateDriver()
        publish()
        return record
    }

    /// Back to the start (or loop start) and play again, keeping the statistics session.
    func restart() {
        if transportState == .finished { stop() }
        halt()
        transportState = .stopped
        startTick = material.tickRange.lowerBound
        begin(resuming: false)
        publish()
    }

    /// Moves the cursor to the start of a notated measure (clamped into the loop region).
    func seek(toMeasure index: Int) {
        guard !score.measures.isEmpty else { return }
        let clamped = max(0, min(score.measures.count - 1, index))
        guard let tick = timeline.startTick(ofMeasure: clamped) else { return }
        seek(toTick: tick)
    }

    /// Jumps to the start of the next phrase (no-op at the last phrase).
    func nextPhrase() {
        let starts = PracticePhraseNavigator.phraseStarts(of: score)
        guard let target = PracticePhraseNavigator.nextPhraseStart(after: cursorMeasure.measureIndex, starts: starts) else { return }
        seek(toMeasure: target)
    }

    /// Jumps to the start of the current phrase, or the previous one when already at its start.
    func previousPhrase() {
        let starts = PracticePhraseNavigator.phraseStarts(of: score)
        let position = cursorMeasure
        let beat = score.timeSignature(atMeasure: position.measureIndex).beatTicks
        seek(toMeasure: PracticePhraseNavigator.previousPhraseStart(from: position.measureIndex, tickInMeasure: position.tickInMeasure, beatTicks: beat, starts: starts))
    }

    /// Replaces the settings. Mode/hands/speed/loop/matching changes rebuild the follower at the current position.
    func updateSettings(_ newValue: PracticeSettings) {
        var new = newValue
        new.speed = PracticeSpeedRules.snap(newValue.speed)
        if let l = new.loop { new.loop = score.measures.isEmpty ? nil : l.clamped(toMeasureCount: score.measures.count) }
        let old = settings
        guard new != old else { return }
        settings = new
        var structural = old
        structural.metronome = new.metronome
        structural.countInMeasures = new.countInMeasures
        if structural != new {
            rebuild(previous: old)
        } else if old.metronome != new.metronome {
            metronome?.isEnabled = new.metronome
            if transportState == .playing, new.mode != .wait {
                if new.metronome { startMetronome(fromTick: Int(cursorTick)) } else { metronome?.stop() }
            }
        }
        publish()
    }

    /// One step faster/slower through the `PracticeSpeed` presets.
    func stepSpeed(up: Bool) {
        speed = PracticeSpeedRules.preset(from: settings.speed, up: up)
    }

    // MARK: - Input

    /// Feeds one note event from the Input hub (call on the main actor).
    func handle(_ event: NoteInputEvent) {
        switch event.kind {
        case .on: heldPitches.insert(event.midi)
        case .off: heldPitches.remove(event.midi)
        }
        var events: [PracticeFollowerEvent] = []
        switch settings.mode {
        case .wait:
            if let f = waitFollower { events = f.handle(event) }
        case .justPlay:
            if transportState == .countingIn, event.kind == .on {
                // No transport yet: keep the press for `countInFinished` (it may be an early first note).
                countInPresses.append((event, PracticeInputTiming.time(of: event, now: clock.now)))
                if countInPresses.count > Self.countInPressLimit { countInPresses.removeFirst(countInPresses.count - Self.countInPressLimit) }
            }
            if let f = justPlayFollower {
                // Bring the follower to the transport's position first so the input is judged against it.
                if transportState == .playing { events = f.update(positionTick: transportPosition()) }
                events += f.handle(event)
            }
        case .listen:
            break
        }
        process(events)
        publish()
    }

    // MARK: - Frame update

    /// Advances timers, polls the transport and republishes state. Call once per frame when not self-driven.
    func refresh() {
        let now = clock.now
        if transportState == .countingIn, metronome == nil, let started = countInStartedAt {
            let beat = countInBeatSeconds > 0 ? Int((now - started) / countInBeatSeconds) : countInTotalBeats
            if beat >= countInTotalBeats {
                countInFinished()
            } else if countInBeat != beat {
                countInBeat = beat
            }
        }
        if transportState == .playing {
            switch settings.mode {
            case .wait:
                if let f = waitFollower { process(f.update()) }
            case .justPlay:
                if let f = justPlayFollower {
                    process(f.update(positionTick: transportPosition()))
                    if player == nil, transportState == .playing, virtualTransport.reachedEnd(now: now) { reachedEndOfTimeline() }
                }
            case .listen:
                let position = transportPosition()
                if player == nil { mirrorListenDemos(to: position, now: now) }
                listenDemos.expire(now: now)
                lastListenTick = position
                if player == nil, virtualTransport.reachedEnd(now: now) { reachedEndOfTimeline() }
            }
        }
        publish()
    }

    // MARK: - Session lifecycle internals

    private var hasFollowerForMode: Bool {
        switch settings.mode {
        case .wait: return waitFollower != nil
        case .justPlay: return justPlayFollower != nil
        case .listen: return true
        }
    }

    /// Starts the transport at `startTick` in the current mode (count-in first for timed modes).
    private func begin(resuming: Bool) {
        if needsFreshSession { startStatisticsSession() }
        startTick = clampedIntoLoop(startTick)
        if settings.mode != .wait, settings.countInMeasures > 0 {
            beginCountIn(resuming: resuming)
        } else {
            startPlaying(resuming: resuming)
        }
        updateDriver()
    }

    private func startStatisticsSession() {
        needsFreshSession = false
        bankedStatistics = PracticeStatistics()
        bankedRecords = []
        waitFollower = nil
        justPlayFollower = nil
        accumulatedSeconds = 0
        playingSince = nil
        loopsCompleted = 0
        lastPlayed = nil
        sessionStartedAt = dateProvider()
    }

    /// Resumes from `paused` (count-in again in timed modes when configured).
    private func resumeFromPause() {
        startTick = Int(cursorTick.rounded(.down))
        if settings.mode != .wait, settings.countInMeasures > 0 {
            beginCountIn(resuming: true)
        } else {
            startPlaying(resuming: true)
        }
        updateDriver()
    }

    private func beginCountIn(resuming: Bool) {
        transportState = .countingIn
        countInResumes = resuming
        countInPresses = []
        let measure = timeline.measurePosition(atTick: startTick).measureIndex
        let time = score.timeSignature(atMeasure: measure)
        let bpm = timeline.tempoMap.bpm(at: startTick)
        countInTotalBeats = time.pulsesPerMeasure * settings.countInMeasures
        countInBeat = 0
        // Pulse length in seconds at the practice speed (a dotted quarter in compound meters).
        countInBeatSeconds = Double(time.pulseTicks) / Double(Ticks.perQuarter) * 60.0 / bpm / max(0.01, settings.speed)
        if let metronome {
            countInStartedAt = nil
            metronome.countIn(measures: settings.countInMeasures, timeSignature: time, bpm: bpm, speed: settings.speed, onBeat: { [weak self] beat, total in
                guard let self, self.transportState == .countingIn else { return }
                self.countInBeat = beat
                self.countInTotalBeats = total
            }, completion: { [weak self] in
                self?.countInFinished()
            })
        } else {
            countInStartedAt = clock.now
        }
    }

    private func countInFinished() {
        guard transportState == .countingIn else { return }
        countInStartedAt = nil
        countInBeat = nil
        let presses = countInPresses
        countInPresses = []
        startPlaying(resuming: countInResumes)
        replayCountInPresses(presses)
        publish()
    }

    /// Feeds the Just Play follower the count-in presses from the last timing window before the downbeat,
    /// at their onset times: the follower extrapolates its position backwards from the transport start, so
    /// they are judged as early (or correct) against the first step instead of being dropped.
    private func replayCountInPresses(_ presses: [(event: NoteInputEvent, time: TimeInterval)]) {
        guard settings.mode == .justPlay, transportState == .playing, let f = justPlayFollower else { return }
        let start = clock.now
        var events: [PracticeFollowerEvent] = []
        for press in presses where press.time >= start - settings.timingWindowSeconds && press.time <= start {
            events += f.handle(press.event, inputTime: press.time)
            if !heldPitches.contains(press.event.midi) {
                f.handle(.off(press.event.midi, time: start, source: press.event.source))
            }
        }
        process(events)
    }

    private func cancelCountIn() {
        metronome?.cancelCountIn()
        countInStartedAt = nil
        countInBeat = nil
        countInPresses = []
    }

    /// Enters `playing` at `startTick`; `resuming` continues the existing follower instead of restarting it.
    private func startPlaying(resuming: Bool) {
        let now = clock.now
        transportState = .playing
        playingSince = now
        var events: [PracticeFollowerEvent] = []
        switch settings.mode {
        case .wait:
            if resuming, let f = waitFollower {
                f.resume()
            } else {
                let f = waitFollower ?? PracticeWaitFollower(material: material, settings: settings, clock: clock, options: waitOptions)
                waitFollower = f
                events = f.start(atTick: startTick)
            }
        case .justPlay:
            if resuming, let f = justPlayFollower {
                f.resume()
            } else {
                let f = justPlayFollower ?? PracticeJustPlayFollower(material: material, settings: settings, clock: clock)
                justPlayFollower = f
                events = f.start(atTick: startTick)
            }
            startTimedTransport(audible: settings.playOtherHands ? Self.handSelection(settings.hands.otherHands) : nil, now: now)
        case .listen:
            listenDemos.removeAll()
            lastListenTick = Double(startTick)
            startTimedTransport(audible: .both, now: now)
        }
        process(events)
    }

    /// Configures and starts the player (or the virtual transport) and the metronome at `startTick`.
    private func startTimedTransport(audible: HandSelection?, now: TimeInterval) {
        let loopTicks = settings.loop.flatMap { timeline.tickRange(of: $0) }
        virtualTransport.speed = settings.speed
        virtualTransport.loopTicks = loopTicks
        virtualTransport.play(fromTick: Double(startTick), now: now)
        if let player {
            player.speed = settings.speed
            player.loopTicks = loopTicks
            player.audibleHands = audible
            player.play(fromTick: startTick)
        }
        metronome?.isEnabled = settings.metronome
        if settings.metronome { startMetronome(fromTick: startTick) }
    }

    private func startMetronome(fromTick tick: Ticks) {
        guard let metronome else { return }
        let score = self.score
        let timeline = self.timeline
        metronome.isEnabled = true
        metronome.start(timeline: timeline, timeSignatureProvider: { t in
            score.timeSignature(atMeasure: timeline.measurePosition(atTick: t).measureIndex)
        }, fromTick: tick, speed: settings.speed)
    }

    /// Stops sound, count-in and timers without ending the statistics session.
    private func halt() {
        let now = clock.now
        if transportState == .countingIn { cancelCountIn() }
        bankPlayingTime(now: now)
        player?.stop()
        metronome?.stop()
        virtualTransport.stop(atTick: Double(material.tickRange.lowerBound))
        bankFollowers()
        listenDemos.removeAll()
        countInBeat = nil
        updateDriver()
    }

    /// Folds the active followers into the banked counters and drops them.
    private func bankFollowers() {
        if let f = waitFollower {
            bankedStatistics = bankedStatistics.merged(with: f.statistics)
            bankedRecords += f.records
            waitFollower = nil
        }
        if let f = justPlayFollower {
            bankedStatistics = bankedStatistics.merged(with: f.statistics)
            bankedRecords += f.records
            justPlayFollower = nil
        }
    }

    private func bankPlayingTime(now: TimeInterval) {
        if let since = playingSince {
            accumulatedSeconds += max(0, now - since)
            playingSince = nil
        }
    }

    /// Applies structural settings changes: banks the follower, rebuilds the material, continues at the cursor.
    private func rebuild(previous: PracticeSettings) {
        let wasState = transportState
        let resumeTick = Int(cursorTick.rounded(.down))
        if wasState == .playing || wasState == .countingIn || wasState == .paused {
            halt()
        } else {
            bankFollowers()
        }
        material = PracticeMaterial(timeline: timeline, hands: settings.hands, loop: settings.loop)
        virtualTransport = PracticeVirtualTransport(timeline: timeline, speed: settings.speed)
        switch wasState {
        case .playing, .countingIn:
            transportState = .stopped
            startTick = clampedIntoLoop(resumeTick)
            begin(resuming: false)
        case .paused:
            // Stay paused; `play()` rebuilds the follower at the cursor (no follower now).
            transportState = .paused
            startTick = clampedIntoLoop(resumeTick)
            cursorTick = Double(startTick)
        case .stopped, .finished:
            if previous.loop != settings.loop || wasState == .finished {
                startTick = material.tickRange.lowerBound
                if wasState == .finished { transportState = .stopped }
                resetCursor()
            }
        }
    }

    /// Moves the transport/follower to a playback tick.
    private func seek(toTick rawTick: Ticks) {
        let tick = clampedIntoLoop(rawTick)
        let now = clock.now
        switch transportState {
        case .stopped, .finished:
            if transportState == .finished { transportState = .stopped }
            startTick = tick
            cursorTick = Double(material.steps.first(where: { $0.tick >= tick })?.tick ?? tick)
        case .paused where !hasFollowerForMode:
            startTick = tick
            cursorTick = Double(tick)
        case .countingIn:
            startTick = tick
            cursorTick = Double(tick)
        case .playing, .paused:
            let paused = transportState == .paused
            var events: [PracticeFollowerEvent] = []
            switch settings.mode {
            case .wait:
                if let f = waitFollower {
                    events = f.start(atTick: tick)
                    if paused { f.pause() }
                }
            case .justPlay:
                if let f = justPlayFollower { events = f.willSeek(toTick: tick) }
                player?.seek(toTick: tick)
                virtualTransport.seek(toTick: Double(tick), now: now)
                if settings.metronome, !paused { startMetronome(fromTick: tick) }
            case .listen:
                listenDemos.removeAll()
                lastListenTick = Double(tick)
                player?.seek(toTick: tick)
                virtualTransport.seek(toTick: Double(tick), now: now)
                if settings.metronome, !paused { startMetronome(fromTick: tick) }
            }
            cursorTick = Double(tick)
            process(events)
        }
        publish()
    }

    /// The material reached its end (Wait follower finished, or the timed transport ran out).
    private func reachedEndOfTimeline() {
        guard transportState == .playing else { return }
        if settings.mode == .justPlay, let f = justPlayFollower { processFollowerEvents(f.finish()) }
        finishSession()
    }

    private func finishSession() {
        guard transportState == .playing || transportState == .paused else { return }
        let now = clock.now
        bankPlayingTime(now: now)
        player?.stop()
        metronome?.stop()
        virtualTransport.pause(now: now)
        transportState = .finished
        endSession(reachedEnd: true)
        updateDriver()
    }

    /// Builds and emits the session record; the next `play()` starts a fresh statistics session.
    @discardableResult
    private func endSession(reachedEnd: Bool) -> PracticeSessionRecord? {
        guard !needsFreshSession else { return nil }
        needsFreshSession = true
        let stats = currentStatistics()
        let played = bankedRecords + (waitFollower?.records ?? []) + (justPlayFollower?.records ?? [])
        statistics = stats
        practicedSeconds = accumulatedSeconds
        guard accumulatedSeconds > 0 || !played.isEmpty else { return nil }
        let started = sessionStartedAt ?? dateProvider()
        let record = PracticeSummaryBuilder.record(arrangementID: arrangementID, scoreTitle: score.metadata.title, startedAt: started, endedAt: started.addingTimeInterval(accumulatedSeconds), durationSeconds: accumulatedSeconds, settings: settings, statistics: stats, played: played, reachedEnd: reachedEnd)
        lastRecord = record
        onSessionEnded?(record)
        return record
    }

    // MARK: - Events from followers and the player

    private func process(_ events: [PracticeFollowerEvent]) {
        processFollowerEvents(events)
        if events.contains(.finished), settings.mode == .wait { finishSession() }
    }

    private func processFollowerEvents(_ events: [PracticeFollowerEvent]) {
        for e in events {
            switch e {
            case .soundChord(let chord, _):
                player?.playImmediately(chord)
            case .played(let record):
                lastPlayed = record
            case .loopWrapped:
                loopsCompleted += 1
            case .resyncRequested(let tick):
                player?.seek(toTick: tick)
                virtualTransport.seek(toTick: Double(tick), now: clock.now)
                if settings.metronome, transportState == .playing { startMetronome(fromTick: tick) }
            case .stepBecameCurrent, .measureCompleted, .finished:
                break
            }
            onFollowerEvent?(e)
        }
    }

    private func playerReachedEnd() {
        guard settings.mode != .wait else { return }
        reachedEndOfTimeline()
        publish()
    }

    private func playerStartedEvent(_ event: TimelineEvent) {
        switch settings.mode {
        case .justPlay:
            justPlayFollower?.noteDemo(event)
        case .listen:
            guard !event.isRest else { return }
            let seconds = timeline.tempoMap.seconds(from: event.tick, length: event.duration, speed: settings.speed)
            listenDemos.started(event, until: clock.now + max(0.05, seconds))
        case .wait:
            break
        }
    }

    /// Listen without a player: mark events whose onsets the virtual transport crossed as demo.
    private func mirrorListenDemos(to position: Double, now: TimeInterval) {
        let from = Int(lastListenTick.rounded(.up))
        let to = Int(position.rounded(.down)) + 1
        var ranges: [Range<Ticks>] = []
        if to > from {
            ranges.append(from..<to)
        } else if position < lastListenTick, let loop = virtualTransport.loopTicks {
            if from < loop.upperBound { ranges.append(from..<loop.upperBound) }
            if to > loop.lowerBound { ranges.append(loop.lowerBound..<to) }
        }
        for r in ranges {
            for e in timeline.events(in: r) where !e.isRest {
                let seconds = timeline.tempoMap.seconds(from: e.tick, length: e.duration, speed: settings.speed)
                listenDemos.started(e, until: now + max(0.05, seconds))
            }
        }
    }

    // MARK: - Publishing

    private func transportPosition() -> Double {
        if let player { return player.positionTick }
        return virtualTransport.position(now: clock.now)
    }

    private func currentStatistics() -> PracticeStatistics {
        var s = bankedStatistics
        if let f = waitFollower { s = s.merged(with: f.statistics) }
        if let f = justPlayFollower { s = s.merged(with: f.statistics) }
        return s
    }

    /// Recomputes the published state, assigning only values that changed (Observation fires on every set).
    private func publish() {
        let now = clock.now
        var newCursor = cursorTick
        var newFeedback = FeedbackSnapshot.empty
        var newStep: TimelineStep?
        var newExpected: [Int] = []
        switch (settings.mode, transportState) {
        case (_, .stopped), (_, .countingIn):
            newCursor = transportState == .countingIn ? Double(startTick) : cursorTick
            newFeedback = pressedOnlySnapshot()
        case (.wait, _):
            if let f = waitFollower {
                newCursor = f.cursorTick
                newFeedback = f.feedback()
                newStep = f.currentStep
                newExpected = f.expectedPitches
            } else {
                newFeedback = pressedOnlySnapshot()
            }
        case (.justPlay, _):
            if let f = justPlayFollower {
                if transportState == .playing { newCursor = transportPosition() }
                newFeedback = f.feedback()
                newStep = f.currentStep
                newExpected = f.expectedPitches
            } else {
                newFeedback = pressedOnlySnapshot()
            }
        case (.listen, _):
            if transportState == .playing { newCursor = transportPosition() }
            var keys: [Int: NoteFeedbackState] = [:]
            var events: [String: NoteFeedbackState] = [:]
            for p in heldPitches { keys[p] = .pressed }
            listenDemos.apply(to: &keys, events: &events, now: now)
            let index = timeline.stepIndex(atOrAfter: Int(newCursor.rounded(.down)) + 1) - 1
            newFeedback = FeedbackSnapshot(keyStates: keys, eventStates: events, currentStepIndex: index >= 0 ? timeline.steps[index].index : nil, missingPitches: [])
        }
        if newCursor != cursorTick { cursorTick = newCursor }
        if newFeedback != feedback { feedback = newFeedback }
        if newStep != currentStep { currentStep = newStep }
        if newExpected != expectedPitches { expectedPitches = newExpected }
        if !needsFreshSession {
            let stats = currentStatistics()
            if stats != statistics { statistics = stats }
            let seconds = accumulatedSeconds + (playingSince.map { max(0, now - $0) } ?? 0)
            if seconds != practicedSeconds { practicedSeconds = seconds }
        }
    }

    private func pressedOnlySnapshot() -> FeedbackSnapshot {
        var keys: [Int: NoteFeedbackState] = [:]
        for p in heldPitches { keys[p] = .pressed }
        return FeedbackSnapshot(keyStates: keys)
    }

    private func resetCursor() {
        cursorTick = Double(material.steps.first(where: { $0.tick >= startTick })?.tick ?? startTick)
    }

    /// A tick moved into the loop's playback range (its start when outside).
    private func clampedIntoLoop(_ tick: Ticks) -> Ticks {
        let range = material.tickRange
        return range.contains(tick) ? tick : range.lowerBound
    }

    /// `HandSelection` covering a list of hands (nil for none).
    static func handSelection(_ hands: [Hand]) -> HandSelection? {
        switch (hands.contains(.right), hands.contains(.left)) {
        case (true, true): return .both
        case (true, false): return .right
        case (false, true): return .left
        case (false, false): return nil
        }
    }

    // MARK: - Self-driving refresh loop

    /// Runs (or stops) the ~60 Hz refresh task depending on the transport state.
    private func updateDriver() {
        guard drivesItself else { return }
        if isActive {
            guard driverTask == nil else { return }
            driverGeneration += 1
            let generation = driverGeneration
            driverTask = Task { @MainActor [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 16_666_667)
                    guard let self, self.isActive, self.driverGeneration == generation else { break }
                    self.refresh()
                }
                if let self, self.driverGeneration == generation { self.driverTask = nil }
            }
        } else {
            driverTask?.cancel()
            driverTask = nil
        }
    }
}
