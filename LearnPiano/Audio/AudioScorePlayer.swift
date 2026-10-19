import Foundation
import Observation
import QuartzCore

/// One run of the transport as seen by followers (the metronome): the tick/time mapping and the host-clock
/// instant of elapsed 0. A new snapshot is published whenever playback starts, seeks or re-times.
struct AudioTransportSnapshot: Equatable, Sendable {
    var mapper: AudioTransportMapper
    /// Host-clock seconds at which `mapper.startTick` sounds.
    var anchorHostSeconds: Double
    /// Increases with every run; stale callbacks compare against it.
    var generation: Int
    /// Visual latency used for UI callbacks of this run.
    var latencySeconds: Double
    /// Set when this run *seamlessly replaces* the previous one (a re-time): the previous run still plays
    /// everything before this host-clock instant and this run everything from it on. Nil for a fresh start,
    /// a seek or a resume, where the previous run (if any) is cut.
    var takeoverHostSeconds: Double? = nil
}

/// Plays a Core `PlaybackTimeline` through `AudioPianoSynth`, implementing `ScorePlaybackControlling`.
///
/// Timing: every note is stamped with a host-clock time computed from the tempo map, the speed multiplier
/// and the loop region (`AudioTransportMapper`), and is pushed into the synth's lock-free render queue up to
/// 120 ms ahead by `AudioLookaheadScheduler`; the render thread applies it at its exact sample frame. The
/// main actor never sits in the timing path.
///
/// Position: `positionTick` is interpolated from the host clock on every read (so it is exact whenever it is
/// read), shifted by the output latency so it matches what is heard; while playing, a display link bumps an
/// observed counter every frame so SwiftUI views that read `positionTick` redraw continuously.
///
/// Muting: `audibleHands` selects the hands that sound; nil mutes all of them while the transport still
/// runs (position, end callback). Changing speed, mutes or the loop while playing re-times the run seamlessly
/// from the current position: notes already sounding finish, upcoming ones are rescheduled.
@MainActor
@Observable
final class AudioScorePlayer: @preconcurrency ScorePlaybackControlling {
    /// Time between `play` and the first note when no count-in hand-off is pending.
    static let startLeadSeconds: Double = 0.05

    /// The synth that sounds the notes.
    @ObservationIgnored let synth: AudioPianoSynth

    /// The loaded material.
    private(set) var timeline: PlaybackTimeline?

    /// Hands sounded during timeline playback (nil = none). Defaults to both.
    var audibleHands: HandSelection? = .both {
        didSet { if oldValue != audibleHands { retimeIfPlaying() } }
    }

    /// Practice speed multiplier (clamped to 0.1…2).
    var speed: Double = 1.0 {
        didSet {
            let clamped = max(0.1, min(2.0, speed.isFinite ? speed : 1.0))
            if clamped != speed { speed = clamped; return }
            if oldValue != speed { retimeIfPlaying() }
        }
    }

    /// Loop region in playback ticks (end exclusive). Playback that reaches its end wraps to its start
    /// seamlessly. Ignored while the position is already past its end.
    var loopTicks: Range<Ticks>? {
        didSet { if oldValue != loopTicks { retimeIfPlaying() } }
    }

    /// Multiplier on note velocities for timeline playback (clamped to 0…1.5; non-finite values reset to 1).
    /// Takes effect from the next note scheduled.
    ///
    /// Under `@Observable` this is a computed property, so the clamp re-assigns only when the value actually
    /// changes (an unconditional re-assignment inside `didSet` would recurse forever).
    var playbackVolume: Double = 1.0 {
        didSet {
            let clamped = max(0, min(1.5, playbackVolume.isFinite ? playbackVolume : 1))
            if clamped != playbackVolume { playbackVolume = clamped; return }
            if oldValue != playbackVolume { retimeIfPlaying() }
        }
    }

    /// Whether the transport is running.
    private(set) var isPlaying = false

    /// The most recent audio problem (engine could not start), for the UI.
    private(set) var lastError: String?

    /// Called on the main actor when playback reaches the end of the timeline (never while looping).
    @ObservationIgnored var onReachedEnd: (() -> Void)?
    /// Called on the main actor when an audible event starts sounding (aligned with the output latency).
    @ObservationIgnored var onEventStarted: ((TimelineEvent) -> Void)?
    /// Follower hook (the metronome): a new run started (snapshot) or the transport stopped (nil).
    @ObservationIgnored var onTransportChanged: ((AudioTransportSnapshot?) -> Void)?

    /// The current run, nil while stopped or paused.
    @ObservationIgnored private(set) var transport: AudioTransportSnapshot?

    /// Bumped every display frame while playing; reading `positionTick` registers a dependency on it.
    private var frameCounter: UInt64 = 0
    /// Position while not playing.
    private var restingTick: Double = 0

    @ObservationIgnored private var items: [AudioPlaybackItem] = []
    /// Run generations: which late scheduler callbacks still count (see `AudioRunGenerations`).
    @ObservationIgnored private var runs = AudioRunGenerations()
    @ObservationIgnored private let scheduler: AudioLookaheadScheduler
    @ObservationIgnored private var endWorkItem: DispatchWorkItem?
    @ObservationIgnored private var displayLink: CADisplayLink?

    /// - Parameter synth: the synth to play through (shared with the metronome and immediate notes).
    init(synth: AudioPianoSynth) {
        self.synth = synth
        self.scheduler = AudioLookaheadScheduler(label: "LearnPiano.AudioScorePlayer", sink: synth.sink)
    }

    // MARK: Position

    /// Current playback position in ticks, interpolated at the moment of reading and compensated for the
    /// output latency. Main-actor only.
    var positionTick: Double {
        _ = frameCounter
        guard isPlaying, let transport else { return restingTick }
        return Self.tick(of: transport, atHostSeconds: AudioHostClock.nowSeconds - transport.latencySeconds)
    }

    /// Tick of a run at a host-clock instant (the start tick during the pre-roll).
    static func tick(of transport: AudioTransportSnapshot, atHostSeconds host: Double) -> Double {
        let elapsed = host - transport.anchorHostSeconds
        guard elapsed > 0 else { return Double(transport.mapper.startTick) }
        return transport.mapper.tick(atElapsed: elapsed)
    }

    // MARK: ScorePlaybackControlling

    /// Replaces the material. Playback stops (notes are released); mutes, speed and loop are kept.
    func load(timeline: PlaybackTimeline) {
        endRun(releaseSounding: true)
        self.timeline = timeline
        self.items = AudioPlaybackPlan.items(from: timeline)
        restingTick = 0
    }

    /// Starts playback at `tick`. If a count-in just finished, the first note lands exactly on the beat
    /// after its last click; otherwise playback starts `startLeadSeconds` from now.
    func play(fromTick tick: Ticks) {
        guard let timeline else { return }
        guard synth.ensureRunning() else {
            lastError = synth.lastError ?? "The audio engine could not start."
            return
        }
        lastError = nil
        let start = max(0, min(tick, timeline.totalTicks))
        let anchor = synth.transportStart(lead: AudioScorePlayer.startLeadSeconds, consume: true)
        beginRun(fromTick: start, anchorHostSeconds: anchor, takeoverHostSeconds: nil)
    }

    /// Stops at the current position (notes are released); `play(fromTick:)` with `positionTick` resumes.
    func pause() {
        guard isPlaying else { return }
        let position = positionTick
        endRun(releaseSounding: true)
        restingTick = position
    }

    /// Stops and rewinds to the loop start (or 0 without a loop). Notes are released.
    func stop() {
        endRun(releaseSounding: true)
        restingTick = Double(effectiveLoopStart ?? 0)
    }

    /// Moves the position. While playing, playback continues from `tick` (sounding notes are released).
    func seek(toTick tick: Ticks) {
        let total = timeline?.totalTicks ?? 0
        let target = max(0, min(tick, total))
        if isPlaying {
            beginRun(fromTick: target, anchorHostSeconds: AudioHostClock.nowSeconds + AudioScorePlayer.startLeadSeconds, takeoverHostSeconds: nil)
        } else {
            restingTick = Double(target)
        }
    }

    /// Sounds a chord now, independent of the timeline ("demo this note", other hand in Wait Mode).
    func playImmediately(_ chord: ImmediateChord) {
        guard !chord.pitches.isEmpty else { return }
        guard synth.ensureRunning() else {
            lastError = synth.lastError ?? "The audio engine could not start."
            return
        }
        synth.play(chord: chord.pitches, velocity: chord.velocity, durationSeconds: chord.durationSeconds)
    }

    // MARK: Extras

    /// Sounds one timeline event now for its notated length at the current speed (capped at 4 s), e.g. when
    /// the learner taps a note in the score. Rests do nothing.
    func playImmediately(event: TimelineEvent, velocity: Double = 0.8) {
        guard !event.isRest else { return }
        let seconds: Double
        if let timeline {
            seconds = timeline.tempoMap.seconds(from: event.tick, length: event.duration, speed: speed)
        } else {
            seconds = Double(event.duration) / Double(Ticks.perQuarter) * 0.6 / speed
        }
        playImmediately(ImmediateChord(pitches: event.pitches, durationSeconds: min(4, max(0.15, seconds)), velocity: velocity))
    }

    /// Seconds of playback from `positionTick` to the end of the material at the current speed (ignores the loop).
    var remainingSeconds: Double {
        guard let timeline else { return 0 }
        let now = AudioTempoMath.seconds(atFractionalTick: positionTick, in: timeline.tempoMap, speed: speed)
        return max(0, timeline.totalSeconds(speed: speed) - now)
    }

    // MARK: Runs

    private var effectiveLoopStart: Ticks? {
        guard let loopTicks, let timeline else { return nil }
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: speed, startTick: loopTicks.lowerBound, endTick: timeline.totalTicks, loop: loopTicks)
        return mapper.loop?.lowerBound
    }

    /// Starts a new run from `tick` with elapsed 0 at `anchorHostSeconds`, replacing the current one.
    ///
    /// With `takeoverHostSeconds` the replacement is seamless (a re-time): the previous run still sounds, and
    /// still reports, everything before that instant, and notes sounding across it end on time. Without it the
    /// previous run's notes are released now (start, seek).
    private func beginRun(fromTick tick: Ticks, anchorHostSeconds anchor: Double, takeoverHostSeconds cutoff: Double?) {
        guard let timeline else { return }
        let runGeneration = runs.advance(keepingPreviousBefore: cutoff)
        let latency = AudioSessionConfigurator.outputLatencySeconds()
        let mapper = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: speed, startTick: tick, endTick: timeline.totalTicks, loop: loopTicks)
        let snapshot = AudioTransportSnapshot(mapper: mapper, anchorHostSeconds: anchor, generation: runGeneration,
                                              latencySeconds: latency, takeoverHostSeconds: cutoff)
        transport = snapshot
        isPlaying = true

        let job = AudioPlaybackJob(mapper: mapper, anchorHostSeconds: anchor, items: items, audibleHands: audibleHands,
                                   tag: AudioPianoSynth.Tag.player, velocityScale: playbackVolume) { [weak self] item, host in
            let player = self
            let eventIndex = item.eventIndex
            AudioMainDelivery.at(hostSeconds: host, latency: latency) {
                player?.deliverEventStarted(eventIndex: eventIndex, generation: runGeneration, hostSeconds: host)
            }
        }
        scheduler.run(job, releasePrevious: cutoff == nil, cutoffHostSeconds: cutoff)

        endWorkItem?.cancel()
        endWorkItem = nil
        if let finish = mapper.finishElapsed {
            let item = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.reachEnd(generation: runGeneration) }
            }
            endWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: AudioHostClock.dispatchTime(forSeconds: anchor + finish + latency), execute: item)
        }
        startDisplayLink()
        onTransportChanged?(snapshot)
    }

    /// How far ahead of "now" a re-time takes effect, leaving the hand-over time to reach the render thread.
    static let retimeLeadSeconds: Double = 0.02

    /// Re-times the current run from the present position (speed, mute, loop or volume changed).
    ///
    /// The hand-over instant (`cutoff`) is the moment the change takes effect; the new run starts at the first
    /// whole tick at or after the position reached then, so every note before the cutoff belongs to the old
    /// run and every note from it on to the new one: nothing is lost or struck twice.
    private func retimeIfPlaying() {
        guard isPlaying, let transport, let timeline else { return }
        let decisionHost = AudioHostClock.nowSeconds + AudioScorePlayer.retimeLeadSeconds
        guard decisionHost > transport.anchorHostSeconds else {
            // Still in the pre-roll: restart the same start point at the same instant with the new settings.
            beginRun(fromTick: transport.mapper.startTick, anchorHostSeconds: transport.anchorHostSeconds,
                     takeoverHostSeconds: transport.anchorHostSeconds)
            return
        }
        let position = transport.mapper.tick(atElapsed: decisionHost - transport.anchorHostSeconds)
        var start = Ticks(position.rounded(.up))
        var anchor = decisionHost
        let newMapperProbe = AudioTransportMapper(tempoMap: timeline.tempoMap, speed: speed, startTick: start, endTick: timeline.totalTicks, loop: loopTicks)
        if let loop = loopTicks, newMapperProbe.loop == nil, Double(loop.lowerBound) <= position, position < Double(loop.upperBound) {
            // Rounding up landed exactly on the loop end: continue from the loop start.
            start = loop.lowerBound
        } else {
            let gap = AudioTempoMath.seconds(atFractionalTick: Double(start), in: timeline.tempoMap, speed: speed)
                - AudioTempoMath.seconds(atFractionalTick: position, in: timeline.tempoMap, speed: speed)
            anchor += max(0, gap)
        }
        if start >= timeline.totalTicks && loopTicks == nil {
            // Re-timing exactly at the end: let the pending end callback finish the run.
            return
        }
        beginRun(fromTick: start, anchorHostSeconds: anchor, takeoverHostSeconds: decisionHost)
    }

    /// Ends the current run (if any) without callbacks.
    private func endRun(releaseSounding: Bool) {
        let wasPlaying = isPlaying || transport != nil
        _ = runs.advance(keepingPreviousBefore: nil)
        endWorkItem?.cancel()
        endWorkItem = nil
        scheduler.halt(releaseSounding: releaseSounding)
        stopDisplayLink()
        isPlaying = false
        transport = nil
        if wasPlaying { onTransportChanged?(nil) }
    }

    private func reachEnd(generation runGeneration: Int) {
        guard runGeneration == runs.current, isPlaying else { return }
        let end = Double(timeline?.totalTicks ?? 0)
        endRun(releaseSounding: false)
        restingTick = end
        onReachedEnd?()
    }

    /// Reports an event that started sounding, unless its run was discarded (or replaced before it played).
    private func deliverEventStarted(eventIndex: Int, generation runGeneration: Int, hostSeconds: Double) {
        guard runs.accepts(generation: runGeneration, hostSeconds: hostSeconds),
              let timeline, timeline.events.indices.contains(eventIndex) else { return }
        onEventStarted?(timeline.events[eventIndex])
    }

    // MARK: Display link

    private func startDisplayLink() {
        guard displayLink == nil else { return }
        let target = AudioDisplayLinkTarget { [weak self] in
            guard let self else { return false }
            self.frameCounter &+= 1
            return self.isPlaying
        }
        let link = CADisplayLink(target: target, selector: #selector(AudioDisplayLinkTarget.step(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 30, maximum: 120, preferred: 60)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    private func stopDisplayLink() {
        displayLink?.invalidate()
        displayLink = nil
    }
}

/// `CADisplayLink` target that forwards frames to a main-actor closure. The closure returns false when it
/// no longer needs frames (its owner is gone or stopped), and the link then invalidates itself, so the
/// link never keeps a player alive.
final class AudioDisplayLinkTarget: NSObject {
    private let onFrame: @MainActor () -> Bool

    init(onFrame: @escaping @MainActor () -> Bool) {
        self.onFrame = onFrame
    }

    /// Display-link callback (main run loop).
    @objc func step(_ link: CADisplayLink) {
        let keepGoing = MainActor.assumeIsolated { onFrame() }
        if !keepGoing { link.invalidate() }
    }
}
