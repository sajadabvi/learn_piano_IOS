import AVFoundation
import Foundation
import Observation
import os
import UIKit

/// Microphone recording permission as the UI needs to present it.
enum InputMicrophonePermission: String, Sendable, Hashable {
    /// The user has not been asked yet; `start()` or `requestPermission()` asks.
    case undetermined
    /// Refused; only the Settings app can change it.
    case denied
    /// Allowed.
    case granted

    /// The current system permission.
    static var current: InputMicrophonePermission {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return .granted
        case .denied: return .denied
        case .undetermined: return .undetermined
        @unknown default: return .undetermined
        }
    }
}

/// Note input from an acoustic or digital piano through the microphone.
///
/// An `AVAudioEngine` input tap feeds mono buffers to `InputMicrophoneProcessor`, which runs the
/// `InputPitchPipeline` (4096-sample Hann-windowed vDSP FFT with a 1024-sample hop at 44.1/48 kHz, polyphonic
/// fundamental estimation with harmonic subtraction for up to four notes in A0…C8, spectral-flux onsets,
/// confirmation/release hysteresis) on a serial queue. Note events go out through `onEvent` on that queue,
/// stamped with the onset time on the host clock; level, sounding notes and permission state are main-actor
/// observable.
///
/// The source never changes the audio session category (Audio's `AudioSessionConfigurator` sets
/// `.playAndRecord` at launch); with another category the input node has no channels and the source reports
/// `.unavailable`. Route changes, interruptions and media-services resets restart the engine automatically
/// while the source is meant to be running.
@MainActor
@Observable
final class InputMicrophoneSource: NoteInputSource {
    // MARK: NoteInputSource (nonisolated, thread-safe)

    nonisolated let kind: InputSourceKind = .microphone

    nonisolated var state: InputSourceState { status.value }

    nonisolated var displayName: String { InputSourceKind.microphone.displayName }

    nonisolated var onEvent: ((NoteInputEvent) -> Void)? {
        get { relay.onEvent }
        set { relay.onEvent = newValue }
    }

    // MARK: Observable state

    /// Recording permission (refreshed on `start()` and `refreshPermission()`).
    private(set) var permission: InputMicrophonePermission
    /// Lifecycle state for the UI (mirrors `state`).
    private(set) var sourceState: InputSourceState = .idle
    /// Input level for a meter, 0…1 (−60 … 0 dBFS).
    private(set) var level: Double = 0
    /// Input level in dBFS (−120 for silence).
    private(set) var levelDecibels: Double = -120
    /// Notes currently detected as sounding, ascending.
    private(set) var soundingNotes: [Int] = []
    /// The most recently started notes (one attack or chord), ascending.
    private(set) var lastDetectedNotes: [Int] = []
    /// Tuning reference in Hz (415…466).
    private(set) var a4Hertz: Double = 440
    /// Detection sensitivity 0 (loud notes only) … 1 (quiet notes, more false positives).
    private(set) var sensitivity: Double = 0.5
    /// Hardware sample rate of the running input, 0 when stopped.
    private(set) var sampleRate: Double = 0
    /// Description of the last failure, nil when healthy.
    private(set) var errorMessage: String?

    /// URL of this app's page in the Settings app (for a "microphone access denied" prompt).
    static var systemSettingsURL: URL? { URL(string: UIApplication.openSettingsURLString) }

    // MARK: Private

    private let relay = InputEventRelay()
    private let status = InputLockedValue<InputSourceState>(.idle)
    private let notificationTokens = InputLockedValue<[NSObjectProtocol]>([])
    @ObservationIgnored private var processor: InputMicrophoneProcessor?
    @ObservationIgnored private var engine: AVAudioEngine?
    @ObservationIgnored private var wantsRunning = false
    @ObservationIgnored private var isRequestingPermission = false
    private static let log = Logger(subsystem: "LearnPiano", category: "InputMicrophone")

    init() {
        permission = InputMicrophonePermission.current
        let relay = self.relay
        processor = InputMicrophoneProcessor(
            deliverEvents: { events in relay.send(events) },
            publish: { [weak self] snapshot in InputMainActor.run { self?.apply(snapshot) } }
        )
        observeSession()
    }

    deinit {
        for token in notificationTokens.value { NotificationCenter.default.removeObserver(token) }
    }

    // MARK: Configuration

    /// Applies the learner's microphone settings (A4 calibration and sensitivity).
    func apply(_ settings: UserSettings) {
        configure(a4Hertz: settings.a4Hertz, sensitivity: settings.microphoneSensitivity)
    }

    /// Sets the tuning reference and sensitivity; takes effect from the next analysis frame.
    func configure(a4Hertz: Double, sensitivity: Double) {
        self.a4Hertz = max(415, min(466, a4Hertz))
        self.sensitivity = max(0, min(1, sensitivity))
        var configuration = InputPitchDetectorConfiguration()
        configuration.a4Hertz = self.a4Hertz
        configuration.sensitivity = self.sensitivity
        processor?.update(detector: configuration)
    }

    // MARK: Permission

    /// Re-reads the system permission (e.g. when returning from the Settings app).
    func refreshPermission() {
        permission = InputMicrophonePermission.current
        if permission == .denied, wantsRunning { setState(.permissionDenied) }
        if permission == .granted, wantsRunning, engine == nil { startEngine() }
    }

    /// Asks for microphone access when undetermined and returns the resulting permission.
    @discardableResult
    func requestPermission() async -> InputMicrophonePermission {
        permission = InputMicrophonePermission.current
        guard permission == .undetermined else { return permission }
        let granted = await AVAudioApplication.requestRecordPermission()
        permission = granted ? .granted : .denied
        return permission
    }

    // MARK: Lifecycle

    nonisolated func start() {
        InputMainActor.run { [weak self] in self?.startOnMain() }
    }

    nonisolated func stop() {
        InputMainActor.run { [weak self] in self?.stopOnMain() }
    }

    private func startOnMain() {
        wantsRunning = true
        permission = InputMicrophonePermission.current
        switch permission {
        case .granted:
            if engine == nil { startEngine() }
        case .denied:
            setState(.permissionDenied)
        case .undetermined:
            guard !isRequestingPermission else { return }
            isRequestingPermission = true
            setState(.starting)
            AVAudioApplication.requestRecordPermission { [weak self] granted in
                InputMainActor.run {
                    guard let self else { return }
                    self.isRequestingPermission = false
                    self.permission = granted ? .granted : .denied
                    guard self.wantsRunning else {
                        self.setState(.idle)
                        return
                    }
                    if granted { self.startEngine() } else { self.setState(.permissionDenied) }
                }
            }
        }
    }

    private func stopOnMain() {
        wantsRunning = false
        tearDownEngine()
        setState(.idle)
    }

    // MARK: Engine

    /// Builds a fresh engine with an input tap and starts it.
    private func startEngine() {
        tearDownEngine()
        setState(.starting)
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            errorMessage = "No microphone input is available."
            setState(.unavailable)
            return
        }
        guard let processor else {
            setState(.failed)
            return
        }
        processor.prepare(sampleRate: format.sampleRate)
        var configuration = InputPitchDetectorConfiguration()
        configuration.a4Hertz = a4Hertz
        configuration.sensitivity = sensitivity
        processor.update(detector: configuration)

        let sampleRate = format.sampleRate
        input.installTap(onBus: 0, bufferSize: 2048, format: format,
                         block: Self.makeTapBlock(processor: processor, sampleRate: sampleRate))
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            errorMessage = "The microphone could not be started: \(error.localizedDescription)"
            Self.log.error("AVAudioEngine.start failed: \(error.localizedDescription, privacy: .public)")
            setState(.failed)
            return
        }
        self.engine = engine
        self.sampleRate = sampleRate
        errorMessage = nil
        observeConfigurationChanges(of: engine)
        setState(.running)
    }

    /// Builds the input tap block outside the main actor's isolation domain.
    ///
    /// The tap runs on a real-time audio thread; a closure formed inside a `@MainActor` method would be
    /// inferred main-actor isolated (and trap under Swift 6 dynamic isolation checks), so it is created here.
    /// The block only copies the first channel and hands it to the processor's serial queue.
    nonisolated private static func makeTapBlock(processor: InputMicrophoneProcessor, sampleRate: Double) -> AVAudioNodeTapBlock {
        { buffer, when in
            guard let channels = buffer.floatChannelData else { return }
            let count = Int(buffer.frameLength)
            guard count > 0 else { return }
            let samples = Array(UnsafeBufferPointer(start: channels[0], count: count))
            let start = when.isHostTimeValid
                ? InputClock.seconds(hostTime: when.hostTime)
                : InputClock.now - Double(count) / sampleRate
            processor.enqueue(samples: samples, startTime: start)
        }
    }

    /// Stops the engine, removes the tap and releases sounding notes.
    private func tearDownEngine() {
        guard let engine else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        self.engine = nil
        sampleRate = 0
        processor?.flush(at: InputClock.now)
        removeConfigurationObserver()
    }

    /// Restarts after a route change, interruption or media-services reset when the source should run.
    private func restartIfWanted() {
        guard wantsRunning else { return }
        permission = InputMicrophonePermission.current
        guard permission == .granted else {
            tearDownEngine()
            setState(.permissionDenied)
            return
        }
        startEngine()
    }

    private func apply(_ snapshot: InputMicrophoneProcessor.Snapshot) {
        level = snapshot.level
        levelDecibels = snapshot.decibels
        if soundingNotes != snapshot.soundingNotes { soundingNotes = snapshot.soundingNotes }
        if !snapshot.newNotes.isEmpty { lastDetectedNotes = snapshot.newNotes }
    }

    private func setState(_ newState: InputSourceState) {
        sourceState = newState
        status.value = newState
        if newState != .running {
            level = 0
            levelDecibels = -120
            soundingNotes = []
        }
    }

    // MARK: Notifications

    /// Observes session-wide events once for the lifetime of the source.
    private func observeSession() {
        let center = NotificationCenter.default
        let interruption = center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let rawType = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            MainActor.assumeIsolated {
                guard let self, let rawType, let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
                switch type {
                case .began:
                    self.tearDownEngine()
                    if self.wantsRunning { self.setState(.starting) }
                case .ended:
                    self.restartIfWanted()
                @unknown default:
                    break
                }
            }
        }
        let reset = center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.engine = nil
                self.restartIfWanted()
            }
        }
        notificationTokens.withValue { $0 += [interruption, reset] }
    }

    @ObservationIgnored private var configurationObserver: NSObjectProtocol?

    /// Rebuilds the tap when the hardware format changes (headset plugged in, sample-rate change…).
    private func observeConfigurationChanges(of engine: AVAudioEngine) {
        removeConfigurationObserver()
        let token = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.restartIfWanted() }
        }
        configurationObserver = token
        notificationTokens.withValue { $0.append(token) }
    }

    private func removeConfigurationObserver() {
        guard let token = configurationObserver else { return }
        NotificationCenter.default.removeObserver(token)
        notificationTokens.withValue { tokens in tokens.removeAll { $0 === token } }
        configurationObserver = nil
    }
}
