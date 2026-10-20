import AudioToolbox
import AVFoundation
import Foundation
import Synchronization

/// Everything the render callback touches. Owned by `AudioPianoSynth`, mutated only on the render thread
/// except for the write-once SoundFont hand-off (published through an atomic flag) and `killAllVoices()`,
/// which is called only while no render callback runs. No locks, no allocation on the render path.
///
/// Commands arrive through the lock-free `AudioCommandQueue`, wait in a fixed-size pending table until
/// their host time falls inside the buffer being rendered, and are applied at their exact frame offset.
/// Commands due at the same frame are applied in the order they were pushed, so a scheduled note-off of
/// one note never cuts a later note-on of the same key.
///
/// Releases are strike-specific: a note-off with a `strikeID` releases only the voice of that strike, and an
/// anonymous note-off (`strikeID` 0) releases only the voices of its key struck by the same producer `tag`.
/// So the score player's releases never cut immediate notes, and an earlier immediate chord's release never
/// cuts a newer strike of the same key.
final class AudioSynthRenderState: @unchecked Sendable {
    /// A command waiting for its host time, with the frame offset resolved for the current buffer.
    struct Pending {
        var command: AudioRenderCommand
        /// Frame offset inside the current buffer (or beyond it) at which the command is due.
        var dueFrame: Int
        /// Arrival order, used to apply simultaneous commands first-in first-out.
        var sequence: UInt64
    }

    /// Knee of the output soft clip: samples below it in magnitude pass unchanged.
    static let softClipKnee: Float = 0.6
    /// Strikes with an identity that the SoundFont key ledger can track at once (more are tracked per key only).
    static let samplerLedgerCapacity = 256

    let voiceCount: Int
    let pendingCapacity: Int
    let sampleRate: Float
    let a4Hertz: Float
    let queue: AudioCommandQueue
    private let voices: UnsafeMutablePointer<AudioSynthVoice>
    /// Partial banks of all voices, `AudioSynthVoice.bankFloats` floats each.
    private let banks: UnsafeMutablePointer<Float>
    /// Per-voice scratch for one sub-block.
    private let scratch: UnsafeMutablePointer<Float>
    private let pending: UnsafeMutablePointer<Pending>
    private var pendingCount = 0
    private var sequenceCounter: UInt64 = 0
    private var click = AudioClickVoice()
    private var ageCounter: UInt64 = 0
    private let hostTicksPerFrame: Double

    // SoundFont key ledger (render thread only). The sampler knows keys, not strikes, so a key is released
    // (0x80) only when no strike of it is left: neither an identified strike nor an anonymous one.
    private let samplerStrikeKeys: UnsafeMutablePointer<UInt8>
    private let samplerStrikeIDs: UnsafeMutablePointer<UInt32>
    private var samplerStrikeCount = 0
    /// Per MIDI key: held by an anonymous strike (or by an identified strike the full ledger could not record).
    private let samplerAnonymousHeld: UnsafeMutablePointer<Bool>
    /// Routing seen by the previous applied command, to silence the sampler when notes move back to the synth.
    private var routedToSampler = false

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
        let bankFloats = AudioSynthVoice.bankFloats
        self.banks = UnsafeMutablePointer<Float>.allocate(capacity: self.voiceCount * bankFloats)
        self.banks.initialize(repeating: 0, count: self.voiceCount * bankFloats)
        self.voices = UnsafeMutablePointer<AudioSynthVoice>.allocate(capacity: self.voiceCount)
        for i in 0..<self.voiceCount {
            (self.voices + i).initialize(to: AudioSynthVoice(bank: self.banks + i * bankFloats))
        }
        self.scratch = UnsafeMutablePointer<Float>.allocate(capacity: AudioSynthVoice.subBlockLength)
        self.scratch.initialize(repeating: 0, count: AudioSynthVoice.subBlockLength)
        self.pending = UnsafeMutablePointer<Pending>.allocate(capacity: self.pendingCapacity)
        self.pending.initialize(repeating: Pending(command: .allNotesOff(), dueFrame: 0, sequence: 0), count: self.pendingCapacity)
        let ledger = AudioSynthRenderState.samplerLedgerCapacity
        self.samplerStrikeKeys = UnsafeMutablePointer<UInt8>.allocate(capacity: ledger)
        self.samplerStrikeKeys.initialize(repeating: 0, count: ledger)
        self.samplerStrikeIDs = UnsafeMutablePointer<UInt32>.allocate(capacity: ledger)
        self.samplerStrikeIDs.initialize(repeating: 0, count: ledger)
        self.samplerAnonymousHeld = UnsafeMutablePointer<Bool>.allocate(capacity: 128)
        self.samplerAnonymousHeld.initialize(repeating: false, count: 128)
        self.hostTicksPerFrame = Double(AudioHostClock.hostTime(forSeconds: 1)) / Double(self.sampleRate)
    }

    deinit {
        voices.deinitialize(count: voiceCount)
        voices.deallocate()
        banks.deinitialize(count: voiceCount * AudioSynthVoice.bankFloats)
        banks.deallocate()
        scratch.deinitialize(count: AudioSynthVoice.subBlockLength)
        scratch.deallocate()
        pending.deinitialize(count: pendingCapacity)
        pending.deallocate()
        samplerStrikeKeys.deinitialize(count: AudioSynthRenderState.samplerLedgerCapacity)
        samplerStrikeKeys.deallocate()
        samplerStrikeIDs.deinitialize(count: AudioSynthRenderState.samplerLedgerCapacity)
        samplerStrikeIDs.deallocate()
        samplerAnonymousHeld.deinitialize(count: 128)
        samplerAnonymousHeld.deallocate()
    }

    // MARK: Sampler hand-off

    /// Routes future notes to a sampler. Called from the control thread after the sampler is live. The block
    /// is stored only the first time: the sampler instance lives as long as this render state, so its
    /// scheduling block never changes, and not rewriting it keeps the render thread's read race-free.
    func enableSampler(_ block: @escaping AUScheduleMIDIEventBlock) {
        if scheduleMIDIEvent == nil { scheduleMIDIEvent = block }
        samplerEnabled.store(true, ordering: .releasing)
    }

    /// Returns notes to the built-in synth (notes still sounding on the sampler are released).
    func disableSampler() {
        samplerEnabled.store(false, ordering: .releasing)
    }

    /// Whether notes currently go to the sampler.
    var isSamplerEnabled: Bool { samplerEnabled.load(ordering: .acquiring) }

    // MARK: Diagnostics

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
        var i = 0
        while i < frameCount {
            out[i] = 0
            i += 1
        }
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
        for p in 0..<pendingCount {
            pending[p].dueFrame = dueFrame(for: pending[p].command, bufferHost: bufferHost)
        }
        // 3. Render in segments split at command boundaries.
        var frame = 0
        while frame < frameCount {
            applyDueCommands(atFrame: frame)
            var nextBoundary = frameCount
            for p in 0..<pendingCount where pending[p].dueFrame < nextBoundary {
                nextBoundary = pending[p].dueFrame
            }
            let count = nextBoundary - frame
            if count > 0 {
                var v = 0
                while v < voiceCount {
                    if voices[v].isActive { voices[v].render(into: out, start: frame, count: count, scratch: scratch) }
                    v += 1
                }
                click.render(into: out, start: frame, count: count)
            }
            frame = max(nextBoundary, frame + 1)
        }
        // 4. Soft clip with a continuous knee so dense chords never hard-clip and never step.
        i = 0
        while i < frameCount {
            out[i] = AudioSynthRenderState.softClip(out[i])
            i += 1
        }
    }

    /// Output saturation: identity up to `softClipKnee`, then a tanh curve that joins it with matching value
    /// and slope (1) and approaches ±1 asymptotically. Continuous and monotonic, so a slowly varying level
    /// never produces a step. NaN maps to 0.
    @inline(__always)
    static func softClip(_ x: Float) -> Float {
        let k = softClipKnee
        let magnitude = abs(x)
        guard magnitude > k else { return magnitude.isNaN ? 0 : x }
        let shaped = k + (1 - k) * tanhf((magnitude - k) / (1 - k))
        return x < 0 ? -shaped : shaped
    }

    /// Asks the render thread to silence everything at the start of its next buffer (safe while running).
    func requestReset() {
        resetRequested.store(true, ordering: .releasing)
    }

    /// Silences everything instantly (voices, click, sampler ledger) and forgets pending commands. Call only
    /// while the engine is stopped (no render callback in flight); while running use `requestReset()`.
    func killAllVoices() {
        // A reset requested while the engine was down (an interruption) is fulfilled here; leaving the flag set
        // would make the first buffer after the restart drop the commands pushed since.
        resetRequested.store(false, ordering: .releasing)
        for v in 0..<voiceCount { voices[v].kill() }
        click.reset()
        pendingCount = 0
        clearSamplerLedger()
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
            for p in 0..<pendingCount where pending[p].dueFrame <= frame && pending[p].sequence < bestSequence {
                best = p
                bestSequence = pending[p].sequence
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
            var p = 0
            while p < pendingCount {
                let c = pending[p].command
                guard c.tag == command.tag else { p += 1; continue }
                if cutoff != 0 {
                    let timed = c.kind == .noteOn || c.kind == .click || c.kind == .noteOff
                    if timed && c.hostTime >= cutoff { removePending(at: p) } else { p += 1 }
                    continue
                }
                switch c.kind {
                case .noteOn, .click:
                    removePending(at: p)
                case .noteOff where releaseNow:
                    removePending(at: p)
                    apply(c, frameOffset: 0)
                default:
                    p += 1
                }
            }
        case .allNotesOff where command.hostTime == 0:
            // An immediate "all off" also discards queued note-ons so a stop is really a stop.
            var p = 0
            while p < pendingCount {
                if pending[p].command.kind == .noteOn { removePending(at: p) } else { p += 1 }
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
        if routedToSampler && !useSampler {
            // Notes moved back to the synth: nothing may keep ringing on the sampler.
            sendMIDI(0xB0, 123, 0, frameOffset: frameOffset)
            clearSamplerLedger()
        }
        routedToSampler = useSampler
        switch command.kind {
        case .noteOn:
            if useSampler {
                samplerNoteOn(command, frameOffset: frameOffset)
            } else {
                let midi = Int(command.midi)
                // A restruck key damps its previous vibration quickly; the new strike takes a fresh voice.
                for v in 0..<voiceCount where voices[v].isActive && voices[v].midi == midi {
                    voices[v].release(sampleRate: sampleRate, force: true)
                }
                let buffer = UnsafeBufferPointer(start: voices, count: voiceCount)
                guard let index = AudioSynthVoiceAllocator.voiceIndex(forNewNote: midi, in: buffer) else { return }
                ageCounter &+= 1
                voices[index].start(midi: midi, velocity: command.value, sampleRate: sampleRate, a4: a4Hertz,
                                    age: ageCounter, tag: command.tag, strikeID: command.strikeID)
            }
        case .noteOff:
            if useSampler {
                samplerNoteOff(command, frameOffset: frameOffset)
            } else {
                let midi = Int(command.midi)
                for v in 0..<voiceCount where voices[v].isActive && voices[v].midi == midi && !voices[v].isReleasing {
                    let matches = command.strikeID != 0 ? voices[v].strikeID == command.strikeID : voices[v].tag == command.tag
                    if matches { voices[v].release(sampleRate: sampleRate) }
                }
            }
        case .allNotesOff:
            if useSampler {
                sendMIDI(0xB0, 123, 0, frameOffset: frameOffset)
                clearSamplerLedger()
            }
            for v in 0..<voiceCount where voices[v].isActive {
                voices[v].release(sampleRate: sampleRate)
            }
        case .click:
            click.trigger(accented: command.value > 0.5, sampleRate: sampleRate)
        case .cancelPending, .flushPending:
            break
        }
    }

    // MARK: SoundFont key ledger

    /// Strikes a sampler key and records who holds it.
    private func samplerNoteOn(_ command: AudioRenderCommand, frameOffset: Int) {
        let key = command.midi & 0x7F
        if command.strikeID != 0 && samplerStrikeCount < AudioSynthRenderState.samplerLedgerCapacity {
            samplerStrikeKeys[samplerStrikeCount] = key
            samplerStrikeIDs[samplerStrikeCount] = command.strikeID
            samplerStrikeCount += 1
        } else {
            samplerAnonymousHeld[Int(key)] = true
        }
        let velocity = UInt8(clamping: Int(1 + command.value * 126))
        sendMIDI(0x90, key, velocity, frameOffset: frameOffset)
    }

    /// Drops one holder of a sampler key and releases the key once nobody holds it any more.
    private func samplerNoteOff(_ command: AudioRenderCommand, frameOffset: Int) {
        let key = command.midi & 0x7F
        var found = false
        if command.strikeID != 0 {
            var e = 0
            while e < samplerStrikeCount {
                if samplerStrikeIDs[e] == command.strikeID && samplerStrikeKeys[e] == key {
                    samplerStrikeCount -= 1
                    samplerStrikeIDs[e] = samplerStrikeIDs[samplerStrikeCount]
                    samplerStrikeKeys[e] = samplerStrikeKeys[samplerStrikeCount]
                    found = true
                    break
                }
                e += 1
            }
        }
        // Anonymous releases, and identified strikes the ledger could not record, clear the anonymous hold.
        if !found { samplerAnonymousHeld[Int(key)] = false }
        guard !samplerAnonymousHeld[Int(key)] else { return }
        var e = 0
        while e < samplerStrikeCount {
            if samplerStrikeKeys[e] == key { return }
            e += 1
        }
        sendMIDI(0x80, key, 0, frameOffset: frameOffset)
    }

    private func clearSamplerLedger() {
        samplerStrikeCount = 0
        for key in 0..<128 { samplerAnonymousHeld[key] = false }
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
