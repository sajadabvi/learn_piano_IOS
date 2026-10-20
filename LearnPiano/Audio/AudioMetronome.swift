import Foundation
import Observation

/// Metronome and count-in, implementing `MetronomeControlling`.
///
/// Clicks are rendered by the synth's built-in click voice and scheduled ahead of time on the host clock,
/// like the score player's notes, so they are sample-accurate.
///
/// When created with a `player`, the metronome *follows* it while it plays: clicks are scheduled on the
/// player's own transport mapping, so they stay locked to the notes through speed changes, seeks and loop
/// wraps, and they pause when the player pauses. If `start` is called while the player is not playing, the
/// metronome clicks on its own from the given tick and switches to following as soon as the player starts.
///
/// `countIn` plays N measures of clicks and hands the exact downbeat time to the synth
/// (`pendingTransportStartHostSeconds`), so a `play` issued from its completion starts precisely on the beat.
@MainActor
@Observable
final class AudioMetronome: @preconcurrency MetronomeControlling {
    /// Lead between the call and the first count-in click.
    static let countInLeadSeconds: Double = 0.05
    /// How long before the downbeat the count-in completion fires, leaving time to start playback on it.
    static let completionLeadSeconds: Double = 0.06

    @ObservationIgnored let synth: AudioPianoSynth
    @ObservationIgnored private weak var player: AudioScorePlayer?

    /// Clicks during playback are audible. Toggling while running takes effect from the next click.
    var isEnabled: Bool = false {
        didSet { enabledFlag.value = isEnabled }
    }

    /// `start` was called and `stop` was not.
    private(set) var isActive = false
    /// A count-in is in progress.
    private(set) var isCountingIn = false
    /// The last click delivered to the UI during playback (aligned with the output latency).
    private(set) var currentBeat: AudioMetronomeBeat?
    /// Increments with every delivered playback click (handy for a flashing beat indicator).
    private(set) var beatCounter = 0
    /// The beat index (0-based) last reported by the count-in, nil outside a count-in.
    private(set) var countInBeatIndex: Int?

    @ObservationIgnored private let enabledFlag = AudioAtomicFlag(false)
    @ObservationIgnored private let alwaysOn = AudioAtomicFlag(true)
    @ObservationIgnored private let clickScheduler: AudioLookaheadScheduler
    @ObservationIgnored private let countInScheduler: AudioLookaheadScheduler

    // Playback clicks
    @ObservationIgnored private var beats: [AudioMetronomeBeat] = []
    @ObservationIgnored private var timeline: PlaybackTimeline?
    @ObservationIgnored private var independentSpeed: Double = 1
    /// Click-run generations: which late click callbacks still count (see `AudioRunGenerations`).
    @ObservationIgnored private var clickRuns = AudioRunGenerations()
    @ObservationIgnored private var isFollowingPlayer = false

    // Count-in
    @ObservationIgnored private var countInGeneration = 0
    @ObservationIgnored private var countInOnBeat: ((Int, Int) -> Void)?
    @ObservationIgnored private var countInCompletion: (() -> Void)?
    @ObservationIgnored private var countInTotalBeats = 0
    @ObservationIgnored private var countInDelivered = 0
    @ObservationIgnored private var countInWorkItem: DispatchWorkItem?

    /// - Parameters:
    ///   - synth: the synth whose click voice sounds the metronome.
    ///   - player: the score player to follow during playback (optional). The metronome installs itself as
    ///     the player's `onTransportChanged` observer.
    init(synth: AudioPianoSynth, player: AudioScorePlayer? = nil) {
        self.synth = synth
        self.player = player
        self.clickScheduler = AudioLookaheadScheduler(label: "LearnPiano.AudioMetronome.clicks", sink: synth.sink)
        self.countInScheduler = AudioLookaheadScheduler(label: "LearnPiano.AudioMetronome.countIn", sink: synth.sink)
        player?.onTransportChanged = { [weak self] snapshot in
            self?.playerTransportChanged(snapshot)
        }
        synth.addEngineStopHandler { [weak self] in self?.engineStopped() }
    }

    /// The engine stopped: a count-in in progress is cancelled (no completion) and clicks halt. The metronome
    /// stays active, so it clicks again with the player's next run; an independent run needs a new `start`.
    private func engineStopped() {
        cancelCountIn()
        _ = clickRuns.advance(keepingPreviousBefore: nil)
        clickScheduler.halt(releaseSounding: true)
        currentBeat = nil
    }

    // MARK: MetronomeControlling

    /// Starts clicking from `tick` using the timeline's segments and tempo, the meter from
    /// `timeSignatureProvider`, and `speed`. Clicks sound only while `isEnabled`; with a player that is
    /// playing, the clicks follow its transport instead (including its loop and later speed changes).
    func start(timeline: PlaybackTimeline, timeSignatureProvider: @escaping (Ticks) -> TimeSignature, fromTick tick: Ticks, speed: Double) {
        self.timeline = timeline
        self.beats = AudioMetronomeBeats.beats(timeline: timeline, timeSignature: timeSignatureProvider)
        self.independentSpeed = speed
        isActive = true
        guard synth.ensureRunning() else { return }
        if let snapshot = player?.transport {
            isFollowingPlayer = false
            follow(snapshot)
        } else {
            isFollowingPlayer = false
            let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: speed, startTick: tick, endTick: timeline.totalTicks, loop: nil)
            let anchor = synth.transportStart(lead: AudioScorePlayer.startLeadSeconds, consume: false)
            runClicks(mapper: mapper, anchorHostSeconds: anchor, latency: AudioSessionConfigurator.outputLatencySeconds())
        }
    }

    /// Stops playback clicks (a count-in in progress is not affected; see `cancelCountIn`).
    func stop() {
        isActive = false
        isFollowingPlayer = false
        _ = clickRuns.advance(keepingPreviousBefore: nil)
        clickScheduler.halt(releaseSounding: true)
        currentBeat = nil
    }

    /// Plays `measures` measures of clicks of `timeSignature` at quarter-note `bpm` and `speed` (always audible,
    /// regardless of `isEnabled`). `onBeat(beatIndex, totalBeats)` is called on the main actor as each click is
    /// heard, with a 0-based `beatIndex`; `completion` fires on the main actor just before the downbeat that
    /// follows the last click, and a `play` started from it lands exactly on that downbeat. With 0 measures the
    /// completion is called right away.
    func countIn(measures: Int, timeSignature: TimeSignature, bpm: Double, speed: Double, onBeat: @escaping (Int, Int) -> Void, completion: @escaping () -> Void) {
        cancelCountIn()
        let beats = AudioMetronomeBeats.countInBeats(measures: measures, timeSignature: timeSignature)
        guard !beats.isEmpty else {
            completion()
            return
        }
        guard synth.ensureRunning() else {
            // Without audio, still let the session proceed.
            completion()
            return
        }
        countInGeneration += 1
        let runGeneration = countInGeneration
        let pulseTicks = max(1, timeSignature.pulseTicks)
        let mapper = AudioTransportMapper(tempoMap: TempoMap(bpm: bpm), speed: speed, startTick: 0, endTick: beats.count * pulseTicks, loop: nil)
        let anchor = AudioHostClock.nowSeconds + AudioMetronome.countInLeadSeconds
        let endHost = anchor + mapper.firstLapDuration
        let latency = AudioSessionConfigurator.outputLatencySeconds()

        countInOnBeat = onBeat
        countInCompletion = completion
        countInTotalBeats = beats.count
        countInDelivered = 0
        countInBeatIndex = nil
        isCountingIn = true
        synth.pendingTransportStartHostSeconds = endHost

        let job = AudioClickJob(mapper: mapper, anchorHostSeconds: anchor, beats: beats, tag: AudioPianoSynth.Tag.countIn,
                                enabled: alwaysOn) { [weak self] index, _, host in
            let metronome = self
            AudioMainDelivery.at(hostSeconds: host, latency: latency) {
                metronome?.deliverCountInBeat(index, generation: runGeneration)
            }
        }
        countInScheduler.run(job, releasePrevious: true)

        let pulseSeconds = mapper.firstLapDuration / Double(beats.count)
        let completionHost = endHost - min(AudioMetronome.completionLeadSeconds, pulseSeconds / 2)
        let item = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finishCountIn(generation: runGeneration) }
        }
        countInWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: AudioHostClock.dispatchTime(forSeconds: completionHost), execute: item)
    }

    /// Cancels a running count-in: no further beats and no completion.
    func cancelCountIn() {
        guard isCountingIn || countInWorkItem != nil else { return }
        countInGeneration += 1
        countInWorkItem?.cancel()
        countInWorkItem = nil
        countInScheduler.halt(releaseSounding: true)
        countInOnBeat = nil
        countInCompletion = nil
        countInBeatIndex = nil
        isCountingIn = false
        synth.pendingTransportStartHostSeconds = nil
    }

    // MARK: Following the player

    private func playerTransportChanged(_ snapshot: AudioTransportSnapshot?) {
        guard isActive else { return }
        if let snapshot {
            follow(snapshot)
        } else if isFollowingPlayer {
            // The player paused, stopped or finished: stay active and resume with it.
            _ = clickRuns.advance(keepingPreviousBefore: nil)
            clickScheduler.halt(releaseSounding: true)
            currentBeat = nil
        }
    }

    /// Clicks along a player run. A run that seamlessly replaces the one already being followed (a re-time)
    /// hands over at the same instant as the notes, so no click before it is lost or doubled.
    private func follow(_ snapshot: AudioTransportSnapshot) {
        let cutoff = isFollowingPlayer ? snapshot.takeoverHostSeconds : nil
        isFollowingPlayer = true
        runClicks(mapper: snapshot.mapper, anchorHostSeconds: snapshot.anchorHostSeconds, latency: snapshot.latencySeconds,
                  takeoverHostSeconds: cutoff)
    }

    /// Starts a click run, replacing the current one: seamlessly at `takeoverHostSeconds` when given,
    /// otherwise cutting it now.
    private func runClicks(mapper: AudioTransportMapper, anchorHostSeconds anchor: Double, latency: Double, takeoverHostSeconds cutoff: Double? = nil) {
        let runGeneration = clickRuns.advance(keepingPreviousBefore: cutoff)
        let job = AudioClickJob(mapper: mapper, anchorHostSeconds: anchor, beats: beats, tag: AudioPianoSynth.Tag.metronome,
                                enabled: enabledFlag) { [weak self] _, beat, host in
            let metronome = self
            AudioMainDelivery.at(hostSeconds: host, latency: latency) {
                metronome?.deliverClick(beat, generation: runGeneration, hostSeconds: host)
            }
        }
        clickScheduler.run(job, releasePrevious: cutoff == nil, cutoffHostSeconds: cutoff)
    }

    // MARK: Main-actor deliveries

    private func deliverClick(_ beat: AudioMetronomeBeat, generation runGeneration: Int, hostSeconds: Double) {
        guard clickRuns.accepts(generation: runGeneration, hostSeconds: hostSeconds), isActive, isEnabled else { return }
        currentBeat = beat
        beatCounter &+= 1
    }

    private func deliverCountInBeat(_ index: Int, generation runGeneration: Int) {
        guard runGeneration == countInGeneration, isCountingIn, index >= countInDelivered else { return }
        // Deliver in order even if a callback was coalesced.
        while countInDelivered <= index {
            let beatIndex = countInDelivered
            countInDelivered += 1
            countInBeatIndex = beatIndex
            countInOnBeat?(beatIndex, countInTotalBeats)
        }
    }

    private func finishCountIn(generation runGeneration: Int) {
        guard runGeneration == countInGeneration, isCountingIn else { return }
        // Report any beat whose (latency-shifted) callback has not arrived yet, so the UI never skips a number.
        if countInDelivered < countInTotalBeats {
            deliverCountInBeat(countInTotalBeats - 1, generation: runGeneration)
        }
        let completion = countInCompletion
        countInWorkItem = nil
        countInOnBeat = nil
        countInCompletion = nil
        countInBeatIndex = nil
        isCountingIn = false
        countInGeneration += 1
        completion?()
    }
}
