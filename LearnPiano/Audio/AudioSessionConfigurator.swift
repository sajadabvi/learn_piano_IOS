import AVFoundation
import Foundation

/// Configures the shared `AVAudioSession` so the synth/metronome can play while the Input module records
/// from the microphone. The integrator calls `configure()` once at app start (and `activate()` when the app
/// is ready to make sound); neither the synth nor the microphone source touches the session category.
enum AudioSessionConfigurator {
    /// Short I/O buffers keep key-to-sound latency low (~5 ms at 48 kHz).
    static let preferredIOBufferDuration: TimeInterval = 0.005
    /// Preferred hardware sample rate.
    static let preferredSampleRate: Double = 48_000

    /// Category options: speaker output by default, Bluetooth headsets, and coexistence with other apps' audio.
    /// `.allowBluetoothHFP` is the iOS 26 SDK name of `.allowBluetooth` (same bit, available back to iOS 1).
    static var categoryOptions: AVAudioSession.CategoryOptions {
        [.defaultToSpeaker, .allowBluetoothHFP, .mixWithOthers]
    }

    /// Sets `.playAndRecord` / `.default` with `categoryOptions` and the preferred I/O parameters.
    /// Does not activate the session. Throws the session's error.
    static func configure(session: AVAudioSession = .sharedInstance()) throws {
        try session.setCategory(.playAndRecord, mode: .default, options: categoryOptions)
        try session.setPreferredSampleRate(preferredSampleRate)
        try session.setPreferredIOBufferDuration(preferredIOBufferDuration)
    }

    /// Activates (or deactivates) the session. Call after `configure()`.
    static func activate(_ active: Bool = true, session: AVAudioSession = .sharedInstance()) throws {
        try session.setActive(active, options: active ? [] : [.notifyOthersOnDeactivation])
    }

    /// Delay between a sample being rendered and it reaching the listener (output latency plus one I/O
    /// buffer), clamped to 0…0.25 s. Used to line visual callbacks up with what is heard.
    static func outputLatencySeconds(session: AVAudioSession = .sharedInstance()) -> Double {
        let latency = session.outputLatency + session.ioBufferDuration
        guard latency.isFinite else { return 0 }
        return max(0, min(0.25, latency))
    }

    /// Whether the session already has the category this module needs.
    static func isConfigured(session: AVAudioSession = .sharedInstance()) -> Bool {
        session.category == .playAndRecord && session.categoryOptions.isSuperset(of: categoryOptions)
    }
}
