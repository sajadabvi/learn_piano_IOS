import AVFoundation
import Foundation
import Observation

/// Live input and sound used by the Settings screen and onboarding: an `InputHub` (MIDI, microphone, on-screen
/// keyboard) for the status row and "Test your setup", and an `AudioPianoSynth` for the "Play A4" tone.
///
/// One shared instance serves both screens. Views hold it with `acquire(settings:)` / `release()` (see
/// `settingsInputMonitoring(active:)`); the hardware runs only while at least one visible screen holds it, and
/// stops when the practice screen is presented so it never competes with the practice screen's own hub.
///
/// The microphone permission prompt is never triggered implicitly: while the permission is undetermined the hub
/// listens to the on-screen keyboard only, and the UI offers an explicit "Allow microphone" button.
@MainActor
@Observable
final class SettingsInputMonitor {
    static let shared = SettingsInputMonitor()

    /// The hub, created on first use.
    private(set) var hub: InputHub?
    /// The synth for the test tone, created on first "Play A4" (rebuilt when A4 changes; its tuning is fixed).
    private(set) var synth: AudioPianoSynth?
    /// Whether the hub is listening.
    private(set) var isActive = false
    /// System microphone permission as last read.
    private(set) var microphonePermission: InputMicrophonePermission = InputMicrophonePermission.current
    /// SoundFonts found in Documents/SoundFonts and the bundle (first one is used).
    private(set) var discoveredSoundFonts: [URL] = []
    /// Last audio session or engine problem, for the Sound section.
    private(set) var audioProblem: String?
    /// The current settings applied to the hub.
    private(set) var settings = UserSettings()

    @ObservationIgnored private var holders = 0
    @ObservationIgnored private var discoveryTask: Task<Void, Never>?

    init() {}

    // MARK: Holding

    /// Starts listening (once per holder) with the given settings.
    func acquire(settings: UserSettings) {
        holders += 1
        apply(settings)
        guard holders == 1 else { return }
        start()
    }

    /// Stops listening when the last holder releases.
    func release() {
        holders = max(0, holders - 1)
        guard holders == 0 else { return }
        stop()
    }

    private func start() {
        ensureAudioSession()
        let hub = self.hub ?? InputHub.makeDefault(settings: settings)
        self.hub = hub
        refreshPermission()
        hub.select(effectiveSelection)
        hub.start()
        hub.midiSource?.refreshDevices()
        isActive = true
        refreshSoundFonts()
    }

    private func stop() {
        hub?.stop()
        hub?.clearAppSounding()
        synth?.stop()
        isActive = false
    }

    // MARK: Settings

    /// Applies input preference, A4 and sensitivity to the hub (and the test-tone synth tuning lazily).
    func apply(_ newSettings: UserSettings) {
        settings = newSettings
        guard let hub else { return }
        hub.microphoneSource?.apply(newSettings)
        hub.select(effectiveSelection)
    }

    /// The hub selection: the preferred input, except that an undetermined microphone permission falls back to
    /// on-screen only until the learner taps "Allow microphone".
    var effectiveSelection: InputHubSelection {
        Self.selection(for: settings.preferredInput, permission: microphonePermission)
    }

    nonisolated static func selection(for preferred: InputSourceKind, permission: InputMicrophonePermission) -> InputHubSelection {
        if preferred == .microphone, permission == .undetermined { return .onScreenOnly }
        return InputHubSelection(preferred: preferred)
    }

    // MARK: Permission

    func refreshPermission() {
        microphonePermission = InputMicrophonePermission.current
        hub?.microphoneSource?.refreshPermission()
        if let hub, hub.selection != effectiveSelection { hub.select(effectiveSelection) }
    }

    /// Asks for microphone access, then starts listening if allowed.
    func requestMicrophonePermission() async {
        if let source = hub?.microphoneSource {
            microphonePermission = await source.requestPermission()
        } else {
            microphonePermission = await AVAudioApplication.requestRecordPermission() ? .granted : .denied
        }
        hub?.select(effectiveSelection)
    }

    // MARK: Status

    var midiDevices: [InputMIDIDevice] { hub?.midiSource?.devices ?? [] }

    var connectedMIDIDeviceNames: [String] { hub?.midiSource?.connectedDeviceNames ?? [] }

    var microphoneLevel: Double { hub?.microphoneSource?.level ?? 0 }

    var microphoneState: InputSourceState { hub?.microphoneSource?.sourceState ?? .idle }

    var midiState: InputSourceState { hub?.midiSource?.sourceState ?? .idle }

    var heldNotes: Set<Int> { hub?.heldNotes ?? [] }

    var lastNoteOn: NoteInputEvent? { hub?.lastNoteOn }

    /// The hub's recent events (on and off), newest last. The history is never cleared, so callers that need
    /// "new since this screen appeared" filter with `SettingsSetupTestLayout.noteOns(_:since:)`.
    var recentEvents: [NoteInputEvent] { hub?.recentEvents ?? [] }

    func refreshMIDIDevices() { hub?.midiSource?.refreshDevices() }

    /// Routes an on-screen keyboard touch into the hub.
    func inject(_ event: NoteInputEvent) { hub?.inject(event) }

    // MARK: Test tone

    /// Plays A4 (MIDI 69) at the current tuning for `seconds`. The microphone is told the app is sounding it so the
    /// tone is not reported as a played note.
    func playA4(seconds: Double = 1.5) {
        let a4 = SettingsViewModel.clampA4(settings.a4Hertz)
        let synth: AudioPianoSynth
        if let existing = self.synth, existing.a4Hertz == a4 {
            synth = existing
        } else {
            self.synth?.stop()
            synth = AudioPianoSynth(a4Hertz: a4)
            self.synth = synth
        }
        synth.masterVolume = Float(SettingsAudioPreferences.masterVolume)
        guard synth.ensureRunning() else {
            audioProblem = synth.lastError ?? "The audio engine could not start."
            return
        }
        audioProblem = nil
        let now = InputClock.now
        hub?.noteAppSounding(pitches: [69], from: now, until: now + seconds)
        synth.play(chord: [69], velocity: 0.75, durationSeconds: seconds)
    }

    /// Applies a master volume change to the running test synth.
    func setMasterVolume(_ value: Double) {
        SettingsAudioPreferences.setMasterVolume(value)
        synth?.masterVolume = Float(SettingsAudioPreferences.masterVolume)
    }

    // MARK: SoundFonts

    /// Folder the learner drops `.sf2` files into through the Files app.
    nonisolated static var soundFontsFolder: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first?.appendingPathComponent("SoundFonts", isDirectory: true)
    }

    /// Creates Documents/SoundFonts (so it shows up in Files) and rescans for SoundFonts off the main thread.
    func refreshSoundFonts() {
        discoveryTask?.cancel()
        discoveryTask = Task { [weak self] in
            let result = await Task.detached(priority: .utility) { () -> (urls: [URL], problem: String?) in
                var problem: String?
                if let folder = SettingsInputMonitor.soundFontsFolder {
                    do {
                        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    } catch {
                        problem = "Could not create the SoundFonts folder: \(error.localizedDescription)"
                    }
                }
                return (AudioPianoSynth.discoverSoundFonts(), problem)
            }.value
            guard let self, !Task.isCancelled else { return }
            self.discoveredSoundFonts = result.urls
            if let problem = result.problem { self.audioProblem = problem }
            if let synth = self.synth, synth.isRunning, let first = result.urls.first {
                if case .soundFont(let name) = synth.soundSource, name == first.deletingPathExtension().lastPathComponent { return }
                synth.loadSoundFont(at: first)
            }
        }
    }

    /// Human-readable sound source: the loaded SoundFont, the one that will load, or the built-in synth.
    var soundSourceDescription: String {
        if let synth, case .soundFont(let name) = synth.soundSource { return "SoundFont: \(name)" }
        if let first = discoveredSoundFonts.first { return "SoundFont: \(first.deletingPathExtension().lastPathComponent)" }
        return "Built-in synth"
    }

    var soundSourceDetail: String {
        if let synth, case .soundFont = synth.soundSource { return "Loaded and playing." }
        if let first = discoveredSoundFonts.first {
            let origin = first.path.contains("/Documents/") ? "from your SoundFonts folder" : "bundled with the app"
            return "\(first.lastPathComponent), \(origin). It loads when the piano starts."
        }
        return "No .sf2 file found. The built-in additive piano is used."
    }

    var soundError: String? { synth?.lastError ?? audioProblem }

    // MARK: Audio session

    /// Makes sure the session allows playing and recording at once (normally done at launch by the app).
    private func ensureAudioSession() {
        guard !AudioSessionConfigurator.isConfigured() else { return }
        do {
            try AudioSessionConfigurator.configure()
            try AudioSessionConfigurator.activate()
            audioProblem = nil
        } catch {
            audioProblem = "Audio setup failed: \(error.localizedDescription)"
            NSLog("SettingsInputMonitor: audio session setup failed: \(error)")
        }
    }
}
