import AVFoundation
import Foundation
import Observation
import Synchronization

// MARK: - Synth

/// Errors raised while bringing the audio graph up.
enum AudioSynthError: Error, LocalizedError {
    case formatUnavailable
    case soundFontUnreadable(URL)

    var errorDescription: String? {
        switch self {
        case .formatUnavailable: return "The audio output format could not be created."
        case .soundFontUnreadable(let url): return "The SoundFont at \(url.lastPathComponent) could not be loaded."
        }
    }
}

/// Where the piano sound comes from.
enum AudioSoundSource: Equatable {
    /// The built-in additive model.
    case synthesized
    /// An `AVAudioUnitSampler` playing the acoustic-grand preset of a SoundFont.
    case soundFont(name: String)
}

/// Polyphonic piano synthesizer on `AVAudioEngine`.
///
/// Notes render on an `AVAudioSourceNode` through the additive model in `AudioSynthVoice` (48 voices with
/// stealing). If a `.sf2` is found in the app bundle or `Documents/SoundFonts`, an `AVAudioUnitSampler`
/// takes over the notes (same scheduling path, so timing is identical); the metronome click always uses
/// the built-in render node.
///
/// All methods are main-actor. Other threads (the player's scheduler) use `sink`, which is thread-safe.
///
/// **Engine lifecycle.** Commands pushed while no render callback runs (before the first start, while
/// stopped, during an interruption or a configuration-change gap) are not applied in a burst when the engine
/// starts again: right before every (re)start the queue is filtered and only commands still due in the future
/// are kept (`AudioCommandQueue.discardStale`), and every voice is silenced. `noteOn`, `play(chord:)` and
/// `click` start the engine themselves. When the engine stops, for `stop()` or because the system interrupted
/// it, the engine-stop handlers run (`addEngineStopHandler`): `AudioScorePlayer` pauses and `AudioMetronome`
/// halts, so nothing keeps feeding a dead queue. The integrator should still call `player.pause()` before
/// `synth.stop()` so the practice session's own state changes first.
@MainActor
@Observable
final class AudioPianoSynth {
    /// Thread-safe command entry point shared with `AudioScorePlayer` and `AudioMetronome`.
    nonisolated let sink: AudioRenderCommandSink
    /// Polyphony of the built-in model.
    nonisolated let voiceCount: Int
    /// Tuning reference for the built-in model.
    nonisolated let a4Hertz: Double

    /// Whether the engine is running.
    private(set) var isRunning = false
    /// Current source of the piano sound.
    private(set) var soundSource: AudioSoundSource = .synthesized
    /// The most recent engine problem, for the Settings screen.
    private(set) var lastError: String?
    /// Master output level 0…1 (out-of-range values are clamped, non-finite ones reset to 0.9).
    ///
    /// Under `@Observable` this is a computed property, so the clamp re-assigns only when the value actually
    /// changes; an unconditional re-assignment inside `didSet` would recurse forever.
    var masterVolume: Float = 0.9 {
        didSet {
            let clamped = Self.clampedVolume(masterVolume)
            if clamped != masterVolume { masterVolume = clamped; return }
            engine?.mainMixerNode.outputVolume = masterVolume
        }
    }

    /// Clamps a master-volume value to 0…1, mapping NaN and infinities to the 0.9 default.
    nonisolated static func clampedVolume(_ value: Float) -> Float {
        value.isFinite ? max(0, min(1, value)) : 0.9
    }

    /// Render-queue tags that let each producer cancel only its own scheduled commands.
    enum Tag {
        /// Immediate notes ("demo this note", on-screen keyboard).
        static let immediate: UInt32 = 0
        /// `AudioScorePlayer` timeline playback.
        static let player: UInt32 = 1
        /// `AudioMetronome` clicks during playback.
        static let metronome: UInt32 = 2
        /// `AudioMetronome` count-in clicks.
        static let countIn: UInt32 = 3
    }

    /// Host-clock instant (seconds) at which the next transport should start, set by a finishing count-in
    /// so playback lands exactly on the beat after the last count-in click. See `transportStart(lead:)`.
    @ObservationIgnored var pendingTransportStartHostSeconds: Double?

    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var sourceNode: AVAudioSourceNode?
    @ObservationIgnored private var sampler: AVAudioUnitSampler?
    @ObservationIgnored private var renderState: AudioSynthRenderState?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var soundFontLoadGeneration = 0
    @ObservationIgnored private var engineStopHandlers: [(id: Int, handler: () -> Void)] = []
    @ObservationIgnored private var nextEngineStopHandlerID = 0

    /// - Parameters:
    ///   - voiceCount: polyphony of the built-in model (minimum 32).
    ///   - a4Hertz: tuning reference.
    init(voiceCount: Int = 48, a4Hertz: Double = 440) {
        self.sink = AudioRenderCommandSink()
        self.voiceCount = max(32, voiceCount)
        self.a4Hertz = max(415, min(466, a4Hertz))
    }

    // MARK: Lifecycle

    /// Builds the graph on first call and starts the engine. Safe to call repeatedly.
    func start() throws {
        if engine == nil { try buildGraph() }
        guard let engine, !engine.isRunning else { isRunning = engine?.isRunning ?? false; return }
        engine.prepare()
        do {
            try startEngineDiscardingStale(engine)
            isRunning = true
            lastError = nil
        } catch {
            isRunning = false
            lastError = error.localizedDescription
            throw error
        }
        if sampler != nil, renderState?.isSamplerEnabled == false, case .soundFont = soundSource {
            activateSamplerRouting()
        }
    }

    /// Stops the engine (notes are cut). The engine-stop handlers run first, so the player and the metronome
    /// stop scheduling before the queue's consumer goes away.
    func stop() {
        notifyEngineStopped()
        engine?.stop()
        renderState?.killAllVoices()
        isRunning = false
    }

    /// Registers a main-actor callback run whenever the engine stops (`stop()`, an interruption, a failed
    /// restart). Returns a token for `removeEngineStopHandler`.
    @discardableResult
    func addEngineStopHandler(_ handler: @escaping () -> Void) -> Int {
        nextEngineStopHandlerID += 1
        engineStopHandlers.append((nextEngineStopHandlerID, handler))
        return nextEngineStopHandlerID
    }

    /// Removes a handler added with `addEngineStopHandler`.
    func removeEngineStopHandler(_ token: Int) {
        engineStopHandlers.removeAll { $0.id == token }
    }

    private func notifyEngineStopped() {
        for entry in engineStopHandlers { entry.handler() }
    }

    /// Starts a stopped engine after silencing every voice and dropping the commands that went stale while no
    /// render callback drained the queue (both are safe only while the engine is stopped).
    private func startEngineDiscardingStale(_ engine: AVAudioEngine) throws {
        renderState?.killAllVoices()
        sink.queue.discardStale(atHostTime: AudioHostClock.now())
        try engine.start()
    }

    private func buildGraph() throws {
        let engine = AVAudioEngine()
        let outputRate = engine.outputNode.outputFormat(forBus: 0).sampleRate
        let sessionRate = AVAudioSession.sharedInstance().sampleRate
        let sampleRate = outputRate > 0 ? outputRate : (sessionRate > 0 ? sessionRate : 48_000)
        guard let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1) else {
            throw AudioSynthError.formatUnavailable
        }
        let state = AudioSynthRenderState(voiceCount: voiceCount, sampleRate: sampleRate, a4Hertz: a4Hertz, queue: sink.queue)
        let node = AVAudioSourceNode(format: format) { _, timestamp, frameCount, audioBufferList -> OSStatus in
            let buffers = UnsafeMutableAudioBufferListPointer(audioBufferList)
            guard buffers.count > 0, let data = buffers[0].mData else { return noErr }
            state.render(timestamp: timestamp, frameCount: Int(frameCount), into: data.assumingMemoryBound(to: Float.self))
            return noErr
        }
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.outputVolume = masterVolume

        self.engine = engine
        self.sourceNode = node
        self.renderState = state
        installObservers(for: engine)
        loadFirstAvailableSoundFont()
    }

    private func installObservers(for engine: AVAudioEngine) {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleConfigurationChange() }
        })
        observers.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.handleInterruption(note) }
        })
        observers.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMediaServicesReset() }
        })
    }

    private func handleConfigurationChange() {
        guard isRunning, let engine, !engine.isRunning else { return }
        do {
            try startEngineDiscardingStale(engine)
        } catch {
            lastError = error.localizedDescription
            notifyEngineStopped()
            isRunning = false
        }
    }

    private func handleInterruption(_ note: Notification) {
        guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
        switch type {
        case .began:
            // The system has stopped (or is stopping) the engine: playback pauses; sound resumes on demand.
            notifyEngineStopped()
            renderState?.requestReset()
        case .ended:
            guard isRunning, let engine, !engine.isRunning else { return }
            do {
                try startEngineDiscardingStale(engine)
            } catch {
                lastError = error.localizedDescription
                isRunning = false
            }
        @unknown default:
            break
        }
    }

    private func handleMediaServicesReset() {
        let wasRunning = isRunning
        notifyEngineStopped()
        for o in observers { NotificationCenter.default.removeObserver(o) }
        observers.removeAll()
        engine?.stop()
        engine = nil
        sourceNode = nil
        sampler = nil
        renderState = nil
        soundSource = .synthesized
        isRunning = false
        guard wasRunning else { return }
        do { try start() } catch { lastError = error.localizedDescription }
    }

    // MARK: Notes

    /// Starts a note now (or at `hostTime`), starting the engine if needed (e.g. the on-screen keyboard).
    /// The note is anonymous: `noteOff` of the same key releases it.
    func noteOn(_ midi: Int, velocity: Double = 0.8, hostTime: UInt64 = 0) {
        guard ensureRunning() else { return }
        sink.noteOn(midi, velocity: velocity, hostTime: hostTime, tag: Tag.immediate)
    }

    /// Releases the anonymous immediate notes of a key now (or at `hostTime`). Notes of the score player and
    /// identified strikes (`play(chord:)`) are not affected. Nothing is sent while the engine is stopped.
    func noteOff(_ midi: Int, hostTime: UInt64 = 0) {
        guard isRunning else { return }
        sink.noteOff(midi, hostTime: hostTime, tag: Tag.immediate)
    }

    /// Releases every note now.
    func allNotesOff() {
        guard isRunning else { return }
        sink.allNotesOff()
    }

    /// Sounds a chord for `durationSeconds` ("demo this note"), starting the engine if needed. Each pitch is
    /// an identified strike, so the chord's release never cuts a later strike of the same key. Returns the
    /// strike identities (empty when the engine could not start).
    @discardableResult
    func play(chord pitches: [Int], velocity: Double = 0.8, durationSeconds: Double = 0.8, hostTime: UInt64 = 0) -> [UInt32] {
        guard ensureRunning() else { return [] }
        return sink.playChord(pitches, velocity: velocity, durationSeconds: durationSeconds, hostTime: hostTime, tag: Tag.immediate)
    }

    /// Schedules a metronome click (always rendered by the built-in node), starting the engine if needed.
    func click(accented: Bool, hostTime: UInt64 = 0) {
        guard ensureRunning() else { return }
        sink.click(accented: accented, hostTime: hostTime)
    }

    /// The host-clock time at which a transport started now should begin: the count-in hand-off time when
    /// one is pending and still at least 3 ms away (and at most 0.5 s), otherwise `now + lead`.
    /// - Parameter consume: clear the hand-off so only one transport uses it.
    func transportStart(lead: Double, consume: Bool) -> Double {
        let now = AudioHostClock.nowSeconds
        defer { if consume { pendingTransportStartHostSeconds = nil } }
        if let hint = pendingTransportStartHostSeconds, hint >= now + 0.003, hint <= now + 0.5 {
            return hint
        }
        return now + max(0, lead)
    }

    /// Starts the engine if needed, recording a failure in `lastError`. Returns whether it is running.
    @discardableResult
    func ensureRunning() -> Bool {
        if isRunning, engine?.isRunning == true { return true }
        do {
            try start()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Voices sounding in the built-in model right now (diagnostics).
    var activeVoiceCount: Int { renderState?.activeVoiceCount ?? 0 }

    // MARK: SoundFont

    /// Candidate SoundFonts: user files in `Documents/SoundFonts/*.sf2` first, then any `.sf2` in the bundle.
    nonisolated static func discoverSoundFonts(fileManager: FileManager = .default, bundle: Bundle = .main) -> [URL] {
        var found: [URL] = []
        if let documents = fileManager.urls(for: .documentDirectory, in: .userDomainMask).first {
            let folder = documents.appendingPathComponent("SoundFonts", isDirectory: true)
            if let items = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                found += items.filter { $0.pathExtension.lowercased() == "sf2" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            }
        }
        if let bundled = bundle.urls(forResourcesWithExtension: "sf2", subdirectory: nil) {
            found += bundled.sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        return found
    }

    private func loadFirstAvailableSoundFont() {
        let generation = soundFontLoadGeneration
        Task.detached(priority: .utility) {
            let candidates = AudioPianoSynth.discoverSoundFonts()
            guard let url = candidates.first else { return }
            await MainActor.run {
                guard generation == self.soundFontLoadGeneration else { return }
                self.loadSoundFont(at: url)
            }
        }
    }

    /// Loads the acoustic-grand preset (program 0) of a SoundFont and routes notes to it. The file is parsed
    /// off the main thread; on failure the built-in model keeps playing and `lastError` is set.
    func loadSoundFont(at url: URL) {
        guard let engine else { lastError = AudioSynthError.formatUnavailable.localizedDescription; return }
        soundFontLoadGeneration += 1
        let generation = soundFontLoadGeneration
        let sampler: AVAudioUnitSampler
        if let existing = self.sampler {
            sampler = existing
        } else {
            sampler = AVAudioUnitSampler()
            engine.attach(sampler)
            engine.connect(sampler, to: engine.mainMixerNode, format: nil)
            self.sampler = sampler
        }
        renderState?.disableSampler()
        Task.detached(priority: .utility) {
            let result: Result<Void, Error>
            do {
                try sampler.loadSoundBankInstrument(at: url, program: 0,
                                                    bankMSB: UInt8(kAUSampler_DefaultMelodicBankMSB),
                                                    bankLSB: UInt8(kAUSampler_DefaultBankLSB))
                result = .success(())
            } catch {
                result = .failure(error)
            }
            await MainActor.run {
                guard generation == self.soundFontLoadGeneration else { return }
                switch result {
                case .success:
                    self.soundSource = .soundFont(name: url.deletingPathExtension().lastPathComponent)
                    self.activateSamplerRouting()
                case .failure(let error):
                    self.soundSource = .synthesized
                    self.lastError = "\(AudioSynthError.soundFontUnreadable(url).localizedDescription) \(error.localizedDescription)"
                }
            }
        }
    }

    /// Hands the sampler's MIDI scheduling block to the render thread. Falls back to the synth when the unit
    /// cannot schedule MIDI yet (engine not running); `start()` retries.
    private func activateSamplerRouting() {
        guard let sampler, let state = renderState, isRunning else { return }
        guard let block = sampler.auAudioUnit.scheduleMIDIEventBlock else {
            lastError = "The SoundFont sampler is not ready; using the built-in piano."
            return
        }
        state.enableSampler(block)
    }

    /// Drops the SoundFont and returns to the built-in model.
    func useSynthesizedPiano() {
        soundFontLoadGeneration += 1
        renderState?.disableSampler()
        soundSource = .synthesized
    }
}
