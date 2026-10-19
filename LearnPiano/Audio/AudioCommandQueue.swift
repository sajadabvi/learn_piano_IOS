import Foundation
import Synchronization
import os

// MARK: - Host clock

/// Conversions between `mach_absolute_time` host ticks and seconds. The Audio module schedules everything
/// (notes, clicks, UI callbacks) on this clock because the render thread receives the same clock in its
/// `AudioTimeStamp`, which is what makes ahead-of-time scheduling sample-accurate.
enum AudioHostClock {
    private static let timebase: (numer: Double, denom: Double) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        let numer = Double(info.numer == 0 ? 1 : info.numer)
        let denom = Double(info.denom == 0 ? 1 : info.denom)
        return (numer, denom)
    }()

    /// Current host time in raw ticks.
    static func now() -> UInt64 { mach_absolute_time() }

    /// Current host time in seconds (arbitrary origin, monotonic).
    static var nowSeconds: Double { seconds(forHostTime: mach_absolute_time()) }

    /// Seconds for a raw host-tick value.
    static func seconds(forHostTime hostTime: UInt64) -> Double {
        Double(hostTime) * timebase.numer / timebase.denom / 1_000_000_000
    }

    /// Raw host ticks for a time in seconds on this clock (clamped at 0).
    static func hostTime(forSeconds seconds: Double) -> UInt64 {
        guard seconds > 0, seconds.isFinite else { return 0 }
        return UInt64(seconds * 1_000_000_000 * timebase.denom / timebase.numer)
    }

    /// A `DispatchTime` for a host-clock instant (both are based on `mach_absolute_time`).
    static func dispatchTime(forSeconds seconds: Double) -> DispatchTime {
        let now = nowSeconds
        let delta = max(0, seconds - now)
        return DispatchTime.now() + delta
    }
}

// MARK: - Render commands

/// One instruction for the real-time render thread. Plain-old-data: no references, so it can cross threads
/// through the lock-free queue and live in render-owned storage without ARC traffic.
struct AudioRenderCommand: Equatable {
    /// What to do.
    enum Kind: UInt8, Equatable {
        /// Start a note (`midi`, `value` = velocity 0…1).
        case noteOn
        /// Release a note (`midi`).
        case noteOff
        /// Release every sounding note.
        case allNotesOff
        /// Hand-over cut for the producer `tag`. With `hostTime` 0, drop every not-yet-due `noteOn`/`click` of
        /// the tag (its note-offs are kept so nothing hangs). With a non-zero `hostTime` (the *cutoff*), drop only
        /// the tag's pending `noteOn`/`click`/`noteOff` entries due at or after the cutoff: everything before it
        /// still plays, and the producer re-supplies the note-offs it still owes (see `AudioScheduleJob`).
        case cancelPending
        /// Drop every not-yet-due `noteOn`/`click` with the same `tag` and apply its pending note-offs now
        /// (used by stop/seek/pause: the producer's notes are released immediately).
        case flushPending
        /// A metronome click (`value` > 0.5 = accented downbeat).
        case click
    }

    var kind: Kind
    /// MIDI note number for note commands.
    var midi: UInt8
    /// Velocity (0…1) for `noteOn`, accent flag for `click`.
    var value: Float
    /// Host time (raw ticks) at which the command becomes due; 0 = as soon as possible.
    var hostTime: UInt64
    /// Producer tag so a client (player, metronome) can cancel only its own pending commands. 0 = untagged.
    var tag: UInt32

    static func noteOn(_ midi: Int, velocity: Double, hostTime: UInt64 = 0, tag: UInt32 = 0) -> AudioRenderCommand {
        AudioRenderCommand(kind: .noteOn, midi: UInt8(clamping: midi), value: Float(max(0, min(1, velocity))), hostTime: hostTime, tag: tag)
    }
    static func noteOff(_ midi: Int, hostTime: UInt64 = 0, tag: UInt32 = 0) -> AudioRenderCommand {
        AudioRenderCommand(kind: .noteOff, midi: UInt8(clamping: midi), value: 0, hostTime: hostTime, tag: tag)
    }
    static func allNotesOff(hostTime: UInt64 = 0) -> AudioRenderCommand {
        AudioRenderCommand(kind: .allNotesOff, midi: 0, value: 0, hostTime: hostTime, tag: 0)
    }
    /// See `Kind.cancelPending`; `cutoffHostTime` 0 cancels every pending note-on/click of the tag.
    static func cancelPending(tag: UInt32, cutoffHostTime: UInt64 = 0) -> AudioRenderCommand {
        AudioRenderCommand(kind: .cancelPending, midi: 0, value: 0, hostTime: cutoffHostTime, tag: tag)
    }
    static func flushPending(tag: UInt32) -> AudioRenderCommand {
        AudioRenderCommand(kind: .flushPending, midi: 0, value: 0, hostTime: 0, tag: tag)
    }
    static func click(accented: Bool, hostTime: UInt64 = 0, tag: UInt32 = 0) -> AudioRenderCommand {
        AudioRenderCommand(kind: .click, midi: 0, value: accented ? 1 : 0, hostTime: hostTime, tag: tag)
    }
}

// MARK: - Queue

/// Bounded FIFO from the control threads to the render thread.
///
/// The consumer side (`pop`) is wait-free and allocation-free, as required inside an audio render callback.
/// The producer side (`push`) may be called from any non-real-time thread; producers are serialized with an
/// unfair lock so the main actor and the player's scheduler thread can both feed the same queue.
final class AudioCommandQueue: @unchecked Sendable {
    private let capacity: Int
    private let mask: Int
    private let slots: UnsafeMutablePointer<AudioRenderCommand>
    /// Next slot the consumer reads.
    private let head = Atomic<Int>(0)
    /// Next slot a producer writes.
    private let tail = Atomic<Int>(0)
    private let producerLock = OSAllocatedUnfairLock()

    /// - Parameter capacity: rounded up to a power of two (minimum 16).
    init(capacity: Int = 2048) {
        var c = 16
        while c < capacity { c <<= 1 }
        self.capacity = c
        self.mask = c - 1
        self.slots = UnsafeMutablePointer<AudioRenderCommand>.allocate(capacity: c)
        self.slots.initialize(repeating: AudioRenderCommand(kind: .allNotesOff, midi: 0, value: 0, hostTime: 0, tag: 0), count: c)
    }

    deinit {
        slots.deinitialize(count: capacity)
        slots.deallocate()
    }

    /// Enqueues a command. Returns `false` (and drops the command) when the queue is full.
    @discardableResult
    func push(_ command: AudioRenderCommand) -> Bool {
        producerLock.withLock {
            let t = tail.load(ordering: .relaxed)
            let h = head.load(ordering: .acquiring)
            if t - h >= capacity { return false }
            slots[t & mask] = command
            tail.store(t + 1, ordering: .releasing)
            return true
        }
    }

    /// Dequeues the oldest command, or nil when empty. Render-thread only; never blocks or allocates.
    func pop() -> AudioRenderCommand? {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        if h == t { return nil }
        let c = slots[h & mask]
        head.store(h + 1, ordering: .releasing)
        return c
    }

    /// Number of commands waiting (approximate: racy by design).
    var approximateCount: Int {
        max(0, tail.load(ordering: .relaxed) - head.load(ordering: .relaxed))
    }

    /// Whether the queue currently holds no commands (approximate).
    var isEmpty: Bool { approximateCount == 0 }
}

/// Thread-safe front door to the synth's render thread. The main actor (immediate notes), the score
/// player's scheduler thread and the metronome all push through the same sink.
final class AudioRenderCommandSink: @unchecked Sendable {
    let queue: AudioCommandQueue

    init(queue: AudioCommandQueue = AudioCommandQueue()) { self.queue = queue }

    /// Starts a note at `hostTime` (0 = now).
    @discardableResult
    func noteOn(_ midi: Int, velocity: Double, hostTime: UInt64 = 0, tag: UInt32 = 0) -> Bool {
        guard (0...127).contains(midi) else { return false }
        return queue.push(.noteOn(midi, velocity: velocity, hostTime: hostTime, tag: tag))
    }

    /// Releases a note at `hostTime` (0 = now).
    @discardableResult
    func noteOff(_ midi: Int, hostTime: UInt64 = 0, tag: UInt32 = 0) -> Bool {
        guard (0...127).contains(midi) else { return false }
        return queue.push(.noteOff(midi, hostTime: hostTime, tag: tag))
    }

    /// Releases every sounding note at `hostTime` (0 = now).
    @discardableResult
    func allNotesOff(hostTime: UInt64 = 0) -> Bool { queue.push(.allNotesOff(hostTime: hostTime)) }

    /// Drops not-yet-due note-ons and clicks carrying `tag`; its scheduled note-offs still happen on time.
    /// With a non-zero `cutoffHostTime`, only the tag's commands due at or after the cutoff are dropped, its
    /// note-offs included (the caller must re-supply the note-offs of notes that keep sounding).
    @discardableResult
    func cancelPending(tag: UInt32, cutoffHostTime: UInt64 = 0) -> Bool {
        queue.push(.cancelPending(tag: tag, cutoffHostTime: cutoffHostTime))
    }

    /// Drops not-yet-due note-ons and clicks carrying `tag` and releases its notes now.
    @discardableResult
    func flushPending(tag: UInt32) -> Bool { queue.push(.flushPending(tag: tag)) }

    /// Schedules a metronome click.
    @discardableResult
    func click(accented: Bool, hostTime: UInt64 = 0, tag: UInt32 = 0) -> Bool {
        queue.push(.click(accented: accented, hostTime: hostTime, tag: tag))
    }

    /// Sounds a chord at `hostTime` and releases it `durationSeconds` later (at least 30 ms).
    func playChord(_ pitches: [Int], velocity: Double, durationSeconds: Double, hostTime: UInt64 = 0, tag: UInt32 = 0) {
        let start = hostTime == 0 ? AudioHostClock.now() : hostTime
        let length = durationSeconds.isFinite ? max(0.03, durationSeconds) : 0.8
        let end = AudioHostClock.hostTime(forSeconds: AudioHostClock.seconds(forHostTime: start) + length)
        for p in Set(pitches) {
            noteOn(p, velocity: velocity, hostTime: hostTime, tag: tag)
            noteOff(p, hostTime: end, tag: tag)
        }
    }
}
