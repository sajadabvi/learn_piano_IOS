import Foundation
import Synchronization

// MARK: - Scheduler

/// A note-off that a job cancelled with a hand-over cutoff still owes: the note was struck before the cutoff,
/// keeps sounding past it, and its scheduled release (which lay at or after the cutoff) was dropped from the
/// render queue together with the rest of the job's future.
struct AudioOwedNoteOff: Equatable, Sendable {
    /// MIDI number of the sounding note.
    var midi: Int
    /// Host-clock seconds at which the note was struck.
    var onsetHostSeconds: Double
    /// Host-clock seconds at which the note is due to be released.
    var hostSeconds: Double
    /// Render-queue tag of the producer that struck it.
    var tag: UInt32
}

/// Work driven by `AudioLookaheadScheduler`. After being handed to the scheduler a job is touched only on
/// the scheduler's serial queue.
protocol AudioScheduleJob: AnyObject {
    /// Pushes every command due before `untilHostSeconds` (host-clock seconds). Returns true when the job
    /// has nothing more to schedule, which stops the scheduler's timer.
    func pump(untilHostSeconds: Double, sink: AudioRenderCommandSink) -> Bool

    /// Stops the job (it schedules nothing afterwards).
    ///
    /// - With `releaseSounding`, every pending command of the job is dropped and its notes are released now;
    ///   `cutoffHostSeconds` is ignored and nothing is returned.
    /// - Otherwise this is a seamless hand-over at `cutoffHostSeconds`: everything the job has to play before
    ///   the cutoff still plays (the job first catches up to it), nothing it scheduled at or after the cutoff
    ///   does (its render-queue entries from there on are dropped, note-offs included). The note-offs still owed
    ///   for notes that keep sounding across the cutoff are returned, for the successor (or the scheduler) to
    ///   push.
    func cancel(releaseSounding: Bool, cutoffHostSeconds: Double, sink: AudioRenderCommandSink) -> [AudioOwedNoteOff]

    /// Offered the note-offs owed by the job this one replaces, before this job's first pump. Returns true when
    /// the job takes ownership of them (it then releases those notes itself, merged with its own notes of the
    /// same pitch); false lets the scheduler push them as they are.
    func adopt(_ offs: [AudioOwedNoteOff]) -> Bool
}

extension AudioScheduleJob {
    /// Jobs that do not sound notes do not adopt note-offs.
    func adopt(_ offs: [AudioOwedNoteOff]) -> Bool { false }
}

/// Ahead-of-time scheduler: a high-resolution `DispatchSourceTimer` on a user-interactive serial queue
/// wakes every few milliseconds and pushes host-time-stamped commands up to `lookaheadSeconds` ahead into
/// the synth's render queue, where they are applied at their exact sample frame. Timing precision is
/// therefore sample-accurate and independent of timer jitter as long as the timer wakes once per lookahead.
final class AudioLookaheadScheduler: @unchecked Sendable {
    /// How far ahead commands are pushed.
    static let lookaheadSeconds: Double = 0.12
    /// Timer period.
    static let intervalSeconds: Double = 0.01

    private let queue: DispatchQueue
    private let sink: AudioRenderCommandSink
    // Queue-confined state.
    private var timer: DispatchSourceTimer?
    private var job: AudioScheduleJob?

    /// - Parameters:
    ///   - label: dispatch queue label.
    ///   - sink: the synth's command sink.
    init(label: String, sink: AudioRenderCommandSink) {
        self.queue = DispatchQueue(label: label, qos: .userInteractive)
        self.sink = sink
    }

    deinit {
        // Nothing else references the scheduler any more, so touching queue-confined state here is safe.
        // Release whatever the job started so no note is left hanging when its owner goes away.
        _ = job?.cancel(releaseSounding: true, cutoffHostSeconds: 0, sink: sink)
        timer?.cancel()
    }

    /// Replaces the current job and starts pumping `newJob`.
    ///
    /// - Parameters:
    ///   - newJob: the job to run.
    ///   - releaseSounding: release the previous job's notes now (stop, seek) instead of handing over.
    ///   - cutoffHostSeconds: hand-over instant when not releasing: the previous job still plays what lies
    ///     before it, `newJob` everything from it on. Nil means "now" (on the scheduler queue).
    func run(_ newJob: AudioScheduleJob, releasePrevious releaseSounding: Bool, cutoffHostSeconds: Double? = nil) {
        let box = AudioUncheckedBox(newJob)
        queue.async { [self] in
            let next = box.value
            if let previous = job {
                let cutoff = cutoffHostSeconds ?? AudioHostClock.nowSeconds
                let owed = previous.cancel(releaseSounding: releaseSounding, cutoffHostSeconds: cutoff, sink: sink)
                if !owed.isEmpty, !next.adopt(owed) { AudioLookaheadScheduler.push(owed, to: sink) }
            }
            job = next
            pumpNow()
            if job != nil { startTimerIfNeeded() }
        }
    }

    /// Stops the current job. Without `releaseSounding`, notes already sounding end at their scheduled time.
    func halt(releaseSounding: Bool) {
        queue.async { [self] in
            if let previous = job {
                let owed = previous.cancel(releaseSounding: releaseSounding, cutoffHostSeconds: AudioHostClock.nowSeconds, sink: sink)
                AudioLookaheadScheduler.push(owed, to: sink)
            }
            job = nil
            stopTimer()
        }
    }

    /// Pushes owed note-offs that no successor adopted: one release per key and tag, at the latest owed time,
    /// so overlapping notes of one pitch all sound until the longest of them ends.
    static func push(_ offs: [AudioOwedNoteOff], to sink: AudioRenderCommandSink) {
        guard !offs.isEmpty else { return }
        var latest: [AudioOwedNoteOff] = []
        for off in offs {
            if let index = latest.firstIndex(where: { $0.midi == off.midi && $0.tag == off.tag }) {
                if off.hostSeconds > latest[index].hostSeconds { latest[index] = off }
            } else {
                latest.append(off)
            }
        }
        for off in latest.sorted(by: { $0.hostSeconds < $1.hostSeconds }) {
            sink.noteOff(off.midi, hostTime: AudioHostClock.hostTime(forSeconds: off.hostSeconds), tag: off.tag)
        }
    }

    private func pumpNow() {
        guard let current = job else { return }
        let until = AudioHostClock.nowSeconds + AudioLookaheadScheduler.lookaheadSeconds
        if current.pump(untilHostSeconds: until, sink: sink) {
            job = nil
            stopTimer()
        }
    }

    private func startTimerIfNeeded() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(flags: .strict, queue: queue)
        t.schedule(deadline: .now() + AudioLookaheadScheduler.intervalSeconds,
                   repeating: AudioLookaheadScheduler.intervalSeconds,
                   leeway: .milliseconds(2))
        t.setEventHandler { [weak self] in self?.pumpNow() }
        t.resume()
        timer = t
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
    }
}

/// Bookkeeping that decides which scheduler callbacks (UI notifications) of past runs still count.
///
/// Every run of a transport gets a generation number. A run ended outright (stop, pause, seek) is discarded:
/// its late callbacks are ignored. A run *replaced seamlessly* at a cutoff instant (a re-time) keeps
/// delivering callbacks for what it played before the cutoff, since those notes really sounded. Pure value
/// type; owned by a main-actor object.
struct AudioRunGenerations: Equatable, Sendable {
    /// How many replaced runs are remembered (older ones can no longer have callbacks in flight).
    static let retainedRuns = 16

    /// Generation of the current run.
    private(set) var current = 0
    /// Cutoff (host seconds) of each run that was replaced seamlessly.
    private var cutoffs: [Int: Double] = [:]

    init() {}

    /// Starts a new generation. With a `cutoff`, callbacks of the run being replaced still count for host
    /// times before it; without one, every earlier run is discarded. Returns the new generation.
    mutating func advance(keepingPreviousBefore cutoff: Double?) -> Int {
        if let cutoff {
            cutoffs[current] = cutoff
        } else {
            cutoffs.removeAll()
        }
        current += 1
        let oldest = current - AudioRunGenerations.retainedRuns
        cutoffs = cutoffs.filter { $0.key >= oldest }
        return current
    }

    /// Whether a callback of `generation` for an event at `hostSeconds` should still be delivered.
    func accepts(generation: Int, hostSeconds: Double) -> Bool {
        if generation == current { return true }
        guard let cutoff = cutoffs[generation] else { return false }
        return hostSeconds < cutoff
    }
}

/// Moves a non-Sendable reference onto the scheduler queue; the value is used only there afterwards.
struct AudioUncheckedBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}

/// A Boolean shared between the main actor and the scheduler queue.
final class AudioAtomicFlag: Sendable {
    private let storage: Atomic<Bool>
    init(_ value: Bool) { storage = Atomic(value) }
    var value: Bool {
        get { storage.load(ordering: .acquiring) }
        set { storage.store(newValue, ordering: .releasing) }
    }
}

/// Posts a main-actor callback at a host-clock instant (plus a visual latency), for UI that must line up
/// with what is heard.
enum AudioMainDelivery {
    /// Runs `body` on the main actor at `hostSeconds + latency` (immediately if that is in the past).
    static func at(hostSeconds: Double, latency: Double, _ body: @escaping @MainActor @Sendable () -> Void) {
        let deadline = AudioHostClock.dispatchTime(forSeconds: hostSeconds + max(0, latency))
        DispatchQueue.main.asyncAfter(deadline: deadline) {
            MainActor.assumeIsolated { body() }
        }
    }
}

// MARK: - Score playback job

/// Schedules the notes of a timeline run (`AudioTransportMapper` + host anchor) into the render queue.
///
/// Note-offs are held here and pushed only when they come within the lookahead, which keeps the render
/// thread's pending table small even for long notes at slow speeds. Keys are reference-counted: the render
/// thread releases every voice of a MIDI number on a note-off, so when notes of the same pitch overlap (a
/// unison between hands or voices, a hand crossing) only the release of the *last* one is pushed, and the
/// key sounds until the longest of them ends. Strikes and releases are processed in time order (a release
/// before a strike at the same instant) so the counts are exact.
final class AudioPlaybackJob: AudioScheduleJob, @unchecked Sendable {
    /// A scheduled release of one struck note.
    struct HeldOff: Equatable {
        /// Host-clock seconds of the release.
        var hostSeconds: Double
        /// Host-clock seconds at which the note was struck.
        var onsetHostSeconds: Double
        var midi: Int
    }

    /// When a hand-over cancel reaches the render thread late, a note struck up to this long after the cutoff
    /// may already have sounded; its release is then owed too, so a late cancel can never leave a note hanging
    /// (the worst case is a re-struck key ringing until that release).
    static let renderSlackSeconds: Double = 0.025
    /// Processed releases are remembered this long behind the pump horizon, for hand-overs.
    static let issuedOffRetentionSeconds: Double = 1.0

    let mapper: AudioTransportMapper
    let anchorHostSeconds: Double
    let items: [AudioPlaybackItem]
    let audibleHands: HandSelection?
    let tag: UInt32
    let velocityScale: Double
    /// Called on the scheduler queue for every audible item emitted (item, onset host seconds).
    private let onItem: (AudioPlaybackItem, Double) -> Void
    /// Host clock in seconds (injectable for tests).
    private let clock: () -> Double
    private var cursor: AudioScheduleCursor
    /// Releases not processed yet, sorted by time.
    private var heldOffs: [HeldOff] = []
    /// Releases already processed (pushed, or absorbed by a longer note of the same key) that may still lie
    /// ahead of the render thread, sorted by time.
    private var issuedOffs: [HeldOff] = []
    /// Notes struck and not yet released, per MIDI number.
    private var sounding: [Int: Int] = [:]
    /// Host time of the latest strike per MIDI number (a unison struck twice at one instant sounds once).
    private var lastStrikeHost: [Int: Double] = [:]

    /// - Parameters:
    ///   - mapper: the run's tick/time mapping.
    ///   - anchorHostSeconds: host time of elapsed 0.
    ///   - items: tick-sorted playback items.
    ///   - audibleHands: hands to sound (nil = none; the run still advances and reports nothing).
    ///   - tag: render-queue tag used for cancellation.
    ///   - velocityScale: multiplier applied to item velocities.
    ///   - startElapsed: first elapsed time to emit (later starts skip earlier items).
    ///   - clock: host clock in seconds, used only to size the late-cancel safety margin.
    ///   - onItem: callback for audible items, on the scheduler queue.
    init(mapper: AudioTransportMapper, anchorHostSeconds: Double, items: [AudioPlaybackItem], audibleHands: HandSelection?,
         tag: UInt32, velocityScale: Double = 1, startElapsed: Double = 0,
         clock: @escaping () -> Double = { AudioHostClock.nowSeconds },
         onItem: @escaping (AudioPlaybackItem, Double) -> Void) {
        self.mapper = mapper
        self.anchorHostSeconds = anchorHostSeconds
        self.items = items
        self.audibleHands = audibleHands
        self.tag = tag
        self.velocityScale = max(0, min(1.5, velocityScale.isFinite ? velocityScale : 1))
        self.clock = clock
        self.onItem = onItem
        self.cursor = mapper.cursor(for: items, atElapsed: startElapsed)
    }

    func pump(untilHostSeconds until: Double, sink: AudioRenderCommandSink) -> Bool {
        let occurrences = mapper.advance(&cursor, items: items, until: until - anchorHostSeconds)
        var starts: [(item: AudioPlaybackItem, host: Double)] = []
        for occurrence in occurrences {
            let item = items[occurrence.itemIndex]
            guard let hands = audibleHands, hands.includes(item.hand) else { continue }
            let onsetHost = anchorHostSeconds + occurrence.onsetElapsed
            for note in item.notes {
                let release = mapper.releaseElapsed(endTick: note.endTick, lap: occurrence.lap, onsetElapsed: occurrence.onsetElapsed)
                insertHeldOff(HeldOff(hostSeconds: anchorHostSeconds + release, onsetHostSeconds: onsetHost, midi: note.midi))
            }
            starts.append((item, onsetHost))
        }
        // Merge releases and strikes in time order; at equal times the release goes first, so a key released
        // and struck at the same instant is queued as off-then-on. Every release lies strictly after its own
        // strike (notes last at least 30 ms), so a note's strike is always counted before its release.
        var offIndex = 0
        var startIndex = 0
        while true {
            let hasOff = offIndex < heldOffs.count && heldOffs[offIndex].hostSeconds < until
            let hasStart = startIndex < starts.count
            if hasOff && (!hasStart || heldOffs[offIndex].hostSeconds <= starts[startIndex].host) {
                release(heldOffs[offIndex], sink: sink)
                offIndex += 1
            } else if hasStart {
                strike(starts[startIndex].item, atHostSeconds: starts[startIndex].host, sink: sink)
                startIndex += 1
            } else {
                break
            }
        }
        heldOffs.removeFirst(offIndex)
        let horizon = until - AudioPlaybackJob.issuedOffRetentionSeconds
        if let first = issuedOffs.first, first.hostSeconds < horizon {
            issuedOffs.removeAll { $0.hostSeconds < horizon }
        }
        return cursor.isFinished && heldOffs.isEmpty
    }

    func cancel(releaseSounding: Bool, cutoffHostSeconds cutoff: Double, sink: AudioRenderCommandSink) -> [AudioOwedNoteOff] {
        defer {
            heldOffs.removeAll()
            issuedOffs.removeAll()
            sounding.removeAll()
            lastStrikeHost.removeAll()
            cursor.isFinished = true
        }
        if releaseSounding {
            sink.flushPending(tag: tag)
            var keys = Set(heldOffs.map(\.midi))
            keys.formUnion(sounding.keys)
            for midi in keys.sorted() { sink.noteOff(midi, tag: tag) }
            return []
        }
        // Everything due before the cutoff still plays: catch up to it first (a no-op when already pumped past).
        _ = pump(untilHostSeconds: cutoff, sink: sink)
        sink.cancelPending(tag: tag, cutoffHostTime: max(1, AudioHostClock.hostTime(forSeconds: cutoff)))
        // The render thread dropped this job's releases at or after the cutoff; the notes struck before it
        // (plus, defensively, those struck within the late-cancel margin) still need theirs.
        let onsetLimit = max(cutoff, clock() + AudioPlaybackJob.renderSlackSeconds)
        let candidates = issuedOffs.filter { $0.hostSeconds >= cutoff } + heldOffs
        return candidates
            .filter { $0.onsetHostSeconds < onsetLimit }
            .sorted { $0.hostSeconds < $1.hostSeconds }
            .map { AudioOwedNoteOff(midi: $0.midi, onsetHostSeconds: $0.onsetHostSeconds, hostSeconds: $0.hostSeconds, tag: tag) }
    }

    func adopt(_ offs: [AudioOwedNoteOff]) -> Bool {
        guard offs.allSatisfy({ $0.tag == tag }) else { return false }
        for off in offs {
            sounding[off.midi, default: 0] += 1
            insertHeldOff(HeldOff(hostSeconds: off.hostSeconds, onsetHostSeconds: off.onsetHostSeconds, midi: off.midi))
        }
        return true
    }

    /// Counts and pushes the strikes of one item, then reports it.
    private func strike(_ item: AudioPlaybackItem, atHostSeconds host: Double, sink: AudioRenderCommandSink) {
        let hostTime = AudioHostClock.hostTime(forSeconds: host)
        for note in item.notes {
            let held = sounding[note.midi] ?? 0
            sounding[note.midi] = held + 1
            if held > 0, lastStrikeHost[note.midi] == host { continue }
            lastStrikeHost[note.midi] = host
            sink.noteOn(note.midi, velocity: note.velocity * velocityScale, hostTime: hostTime, tag: tag)
        }
        onItem(item, host)
    }

    /// Releases one note: the key is released only when no other note of the same pitch still holds it.
    private func release(_ off: HeldOff, sink: AudioRenderCommandSink) {
        let remaining = (sounding[off.midi] ?? 0) - 1
        if remaining > 0 {
            sounding[off.midi] = remaining
        } else {
            sounding[off.midi] = nil
            sink.noteOff(off.midi, hostTime: AudioHostClock.hostTime(forSeconds: off.hostSeconds), tag: tag)
        }
        issuedOffs.append(off)
    }

    private func insertHeldOff(_ off: HeldOff) {
        var lo = 0, hi = heldOffs.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if heldOffs[mid].hostSeconds <= off.hostSeconds { lo = mid + 1 } else { hi = mid }
        }
        heldOffs.insert(off, at: lo)
    }
}

// MARK: - Click job

/// Schedules metronome clicks for a run (`AudioTransportMapper` + host anchor). While `enabled` is false
/// the cursor keeps advancing silently, so re-enabling resumes in time without a restart.
final class AudioClickJob: AudioScheduleJob, @unchecked Sendable {
    let mapper: AudioTransportMapper
    let anchorHostSeconds: Double
    let beats: [AudioMetronomeBeat]
    let tag: UInt32
    private let enabled: AudioAtomicFlag
    /// Called on the scheduler queue for every beat emitted (beat index, beat, onset host seconds), even when muted.
    private let onBeat: (Int, AudioMetronomeBeat, Double) -> Void
    private var cursor: AudioScheduleCursor

    /// - Parameters:
    ///   - mapper: the run's tick/time mapping.
    ///   - anchorHostSeconds: host time of elapsed 0.
    ///   - beats: tick-sorted clicks.
    ///   - tag: render-queue tag used for cancellation.
    ///   - enabled: shared mute switch.
    ///   - startElapsed: first elapsed time to emit.
    ///   - onBeat: callback per beat, on the scheduler queue.
    init(mapper: AudioTransportMapper, anchorHostSeconds: Double, beats: [AudioMetronomeBeat], tag: UInt32,
         enabled: AudioAtomicFlag, startElapsed: Double = 0, onBeat: @escaping (Int, AudioMetronomeBeat, Double) -> Void) {
        self.mapper = mapper
        self.anchorHostSeconds = anchorHostSeconds
        self.beats = beats
        self.tag = tag
        self.enabled = enabled
        self.onBeat = onBeat
        self.cursor = mapper.cursor(for: beats, atElapsed: startElapsed)
    }

    func pump(untilHostSeconds until: Double, sink: AudioRenderCommandSink) -> Bool {
        let occurrences = mapper.advance(&cursor, items: beats, until: until - anchorHostSeconds)
        let audible = enabled.value
        for occurrence in occurrences {
            let beat = beats[occurrence.itemIndex]
            let host = anchorHostSeconds + occurrence.onsetElapsed
            if audible {
                sink.click(accented: beat.isDownbeat, hostTime: AudioHostClock.hostTime(forSeconds: host), tag: tag)
            }
            onBeat(occurrence.itemIndex, beat, host)
        }
        return cursor.isFinished
    }

    func cancel(releaseSounding: Bool, cutoffHostSeconds cutoff: Double, sink: AudioRenderCommandSink) -> [AudioOwedNoteOff] {
        if releaseSounding {
            sink.cancelPending(tag: tag)
        } else {
            // Clicks before the cutoff still sound; the successor run clicks from there on.
            _ = pump(untilHostSeconds: cutoff, sink: sink)
            sink.cancelPending(tag: tag, cutoffHostTime: max(1, AudioHostClock.hostTime(forSeconds: cutoff)))
        }
        cursor.isFinished = true
        return []
    }
}
