import AudioToolbox
import AVFoundation
import Foundation
import Synchronization

/// Everything the render callback touches. Owned by `AudioPianoSynth`, mutated only on the render thread
/// except for the write-once SoundFont hand-off (published through an atomic flag). No locks, no allocation.
///
/// Commands arrive through the lock-free `AudioCommandQueue`, wait in a fixed-size pending table until
/// their host time falls inside the buffer being rendered, and are applied at their exact frame offset.
/// Commands due at the same frame are applied in the order they were pushed, so a scheduled note-off of
/// one note never cuts a later note-on of the same key.
final class AudioSynthRenderState: @unchecked Sendable {
    /// A command waiting for its host time, with the frame offset resolved for the current buffer.
    struct Pending {
        var command: AudioRenderCommand
        /// Frame offset inside the current buffer (or beyond it) at which the command is due.
        var dueFrame: Int
        /// Arrival order, used to apply simultaneous commands first-in first-out.
        var sequence: UInt64
    }

    let voiceCount: Int
    let pendingCapacity: Int
    let sampleRate: Float
    let a4Hertz: Float
    let queue: AudioCommandQueue
    private let voices: UnsafeMutablePointer<AudioSynthVoice>
    private let pending: UnsafeMutablePointer<Pending>
    private var pendingCount = 0
    private var sequenceCounter: UInt64 = 0
    private var click = AudioClickVoice()
    private var ageCounter: UInt64 = 0
    private let hostTicksPerFrame: Double

    /// Set to true (after `scheduleMIDIEvent` is stored) when a SoundFont sampler should receive notes instead.
    private let samplerEnabled = Atomic<Bool>(false)
    /// Set by the control thread to have the render thread drop every voice and pending command.
    private let resetRequested = Atomic<Bool>(false)
    /// Written once, before `samplerEnabled` first becomes true; read only on the render thread afterwards.
    private var scheduleMIDIEvent: AUScheduleMIDIEventBlock?

    /// - Parameters:
    ///   - voiceCount: polyphony (at least 1).
    ///   - sampleRate: render rate in Hz.
    ///   - a4Hertz: tuning reference.
    ///   - queue: the command queue this state drains.
    ///   - pendingCapacity: maximum number of future commands held at once (overflow is applied immediately).
    init(voiceCount: Int, sampleRate: Double, a4Hertz: Double, queue: AudioCommandQueue, pendingCapacity: Int = 1024) {
        self.voiceCount = max(1, voiceCount)
        self.pendingCapacity = max(16, pendingCapacity)
        self.sampleRate = Float(sampleRate > 0 ? sampleRate : 48_000)
        self.a4Hertz = Float(a4Hertz)
        self.queue = queue
        self.voices = UnsafeMutablePointer<AudioSynthVoice>.allocate(capacity: self.voiceCount)
        self.voices.initialize(repeating: AudioSynthVoice(), count: self.voiceCount)
        self.pending = UnsafeMutablePointer<Pending>.allocate(capacity: self.pendingCapacity)
        self.pending.initialize(repeating: Pending(command: .allNotesOff(), dueFrame: 0, sequence: 0), count: self.pendingCapacity)
        self.hostTicksPerFrame = Double(AudioHostClock.hostTime(forSeconds: 1)) / Double(self.sampleRate)
    }

    deinit {
        voices.deinitialize(count: voiceCount)
        voices.deallocate()
        pending.deinitialize(count: pendingCapacity)
        pending.deallocate()
    }

    // MARK: Sampler hand-off

    /// Routes future notes to a sampler. Called from the control thread after the sampler is live. The block
    /// is stored only the first time: the sampler instance lives as long as this render state, so its
    /// scheduling block never changes, and not rewriting it keeps the render thread's read race-free.
    func enableSampler(_ block: @escaping AUScheduleMIDIEventBlock) {
        if scheduleMIDIEvent == nil { scheduleMIDIEvent = block }
        samplerEnabled.store(true, ordering: .releasing)
    }

    /// Returns notes to the built-in synth.
    func disableSampler() {
        samplerEnabled.store(false, ordering: .releasing)
    }

    /// Whether notes currently go to the sampler.
    var isSamplerEnabled: Bool { samplerEnabled.load(ordering: .acquiring) }

    /// Number of voices currently sounding (approximate when read off the render thread; for diagnostics and tests).
    var activeVoiceCount: Int {
        var n = 0
        for i in 0..<voiceCount where voices[i].isActive { n += 1 }
        return n
    }

    /// MIDI numbers of the voices currently sounding and not releasing (diagnostics and tests).
    var heldMIDINotes: [Int] {
        var result: [Int] = []
        for i in 0..<voiceCount where voices[i].isActive && !voices[i].isReleasing { result.append(voices[i].midi) }
        return result.sorted()
    }

    /// Number of commands waiting for their time (diagnostics and tests).
    var pendingCommandCount: Int { pendingCount }

    // MARK: Render entry

    /// Fills one mono buffer. Called by the `AVAudioSourceNode` render block. Real-time safe.
    func render(timestamp: UnsafePointer<AudioTimeStamp>, frameCount: Int, into out: UnsafeMutablePointer<Float>) {
        for i in 0..<frameCount { out[i] = 0 }
        let hostValid = timestamp.pointee.mFlags.contains(.hostTimeValid)
        let bufferHost = hostValid ? timestamp.pointee.mHostTime : 0

        if resetRequested.exchange(false, ordering: .acquiringAndReleasing) {
            killAllVoices()
            while queue.pop() != nil {}
        }
        // 1. Pull everything new off the queue (control commands act right away; the rest waits in `pending`).
        while let command = queue.pop() {
            accept(command)
        }
        // 2. Resolve due frames for the pending commands against this buffer.
        for i in 0..<pendingCount {
            pending[i].dueFrame = dueFrame(for: pending[i].command, bufferHost: bufferHost)
        }
        // 3. Render in segments split at command boundaries.
        var frame = 0
        while frame < frameCount {
            applyDueCommands(atFrame: frame)
            var nextBoundary = frameCount
            for i in 0..<pendingCount where pending[i].dueFrame < nextBoundary {
                nextBoundary = pending[i].dueFrame
            }
            let count = nextBoundary - frame
            if count > 0 {
                for v in 0..<voiceCount where voices[v].isActive {
                    voices[v].render(into: out, start: frame, count: count)
                }
                click.render(into: out, start: frame, count: count)
            }
            frame = max(nextBoundary, frame + 1)
        }
        // 4. Gentle soft clip so dense chords never hard-clip.
        for i in 0..<frameCount {
            let x = out[i]
            if x > 0.6 || x < -0.6 { out[i] = tanhf(x) }
        }
    }

    /// Asks the render thread to silence everything at the start of its next buffer (safe while running).
    func requestReset() {
        resetRequested.store(true, ordering: .releasing)
    }

    /// Silences everything instantly and forgets pending commands. Call only while the engine is stopped
    /// (no render callback in flight); while running use `requestReset()`.
    func killAllVoices() {
        for i in 0..<voiceCount { voices[i].kill() }
        pendingCount = 0
    }

    // MARK: Command handling

    private func dueFrame(for command: AudioRenderCommand, bufferHost: UInt64) -> Int {
        guard command.hostTime != 0, bufferHost != 0, command.hostTime > bufferHost else { return 0 }
        let frames = Double(command.hostTime - bufferHost) / hostTicksPerFrame
        if frames > 1e9 { return Int.max / 2 }
        return Int(frames)
    }

    /// Applies, in arrival order, every pending command due at or before `frame`.
    private func applyDueCommands(atFrame frame: Int) {
        while true {
            var best = -1
            var bestSequence = UInt64.max
            for i in 0..<pendingCount where pending[i].dueFrame <= frame && pending[i].sequence < bestSequence {
                best = i
                bestSequence = pending[i].sequence
            }
            guard best >= 0 else { return }
            let command = pending[best].command
            removePending(at: best)
            apply(command, frameOffset: frame)
        }
    }

    private func accept(_ command: AudioRenderCommand) {
        switch command.kind {
        case .cancelPending, .flushPending:
            let releaseNow = command.kind == .flushPending
            // A cancel with a cutoff only cuts the producer's future from that instant on (a seamless hand-over).
            let cutoff = command.kind == .cancelPending ? command.hostTime : 0
            var i = 0
            while i < pendingCount {
                let c = pending[i].command
                guard c.tag == command.tag else { i += 1; continue }
                if cutoff != 0 {
                    let timed = c.kind == .noteOn || c.kind == .click || c.kind == .noteOff
                    if timed && c.hostTime >= cutoff { removePending(at: i) } else { i += 1 }
                    continue
                }
                switch c.kind {
                case .noteOn, .click:
                    removePending(at: i)
                case .noteOff where releaseNow:
                    removePending(at: i)
                    apply(c, frameOffset: 0)
                default:
                    i += 1
                }
            }
        case .allNotesOff where command.hostTime == 0:
            // An immediate "all off" also discards queued note-ons so a stop is really a stop.
            var i = 0
            while i < pendingCount {
                if pending[i].command.kind == .noteOn { removePending(at: i) } else { i += 1 }
            }
            apply(command, frameOffset: 0)
        default:
            if pendingCount < pendingCapacity {
                sequenceCounter &+= 1
                pending[pendingCount] = Pending(command: command, dueFrame: 0, sequence: sequenceCounter)
                pendingCount += 1
            } else {
                apply(command, frameOffset: 0)
            }
        }
    }

    private func removePending(at index: Int) {
        pendingCount -= 1
        if index != pendingCount { pending[index] = pending[pendingCount] }
    }

    private func apply(_ command: AudioRenderCommand, frameOffset: Int) {
        let useSampler = samplerEnabled.load(ordering: .acquiring)
        switch command.kind {
        case .noteOn:
            if useSampler {
                let velocity = UInt8(clamping: Int(1 + command.value * 126))
                sendMIDI(0x90, command.midi, velocity, frameOffset: frameOffset)
            } else {
                let midi = Int(command.midi)
                // A restruck key damps its previous vibration quickly; the new strike takes a fresh voice.
                for i in 0..<voiceCount where voices[i].isActive && voices[i].midi == midi {
                    voices[i].release(sampleRate: sampleRate, force: true)
                }
                let buffer = UnsafeBufferPointer(start: voices, count: voiceCount)
                guard let index = AudioSynthVoiceAllocator.voiceIndex(forNewNote: midi, in: buffer) else { return }
                ageCounter &+= 1
                voices[index].start(midi: midi, velocity: command.value, sampleRate: sampleRate, a4: a4Hertz, age: ageCounter)
            }
        case .noteOff:
            if useSampler {
                sendMIDI(0x80, command.midi, 0, frameOffset: frameOffset)
            } else {
                let midi = Int(command.midi)
                for i in 0..<voiceCount where voices[i].isActive && voices[i].midi == midi && !voices[i].isReleasing {
                    voices[i].release(sampleRate: sampleRate)
                }
            }
        case .allNotesOff:
            if useSampler {
                sendMIDI(0xB0, 123, 0, frameOffset: frameOffset)
            }
            for i in 0..<voiceCount where voices[i].isActive {
                voices[i].release(sampleRate: sampleRate)
            }
        case .click:
            click.trigger(accented: command.value > 0.5, sampleRate: sampleRate)
        case .cancelPending, .flushPending:
            break
        }
    }

    private func sendMIDI(_ status: UInt8, _ data1: UInt8, _ data2: UInt8, frameOffset: Int) {
        guard let block = scheduleMIDIEvent else { return }
        var bytes: (UInt8, UInt8, UInt8) = (status, data1, data2)
        withUnsafeBytes(of: &bytes) { raw in
            guard let base = raw.baseAddress else { return }
            block(AUEventSampleTimeImmediate + AUEventSampleTime(frameOffset), 0, 3, base.assumingMemoryBound(to: UInt8.self))
        }
    }
}
