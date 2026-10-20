import Foundation
import Observation

/// Maps the Settings form's controls onto `ProfileStore.settings` (`UserSettings`). It holds no state of its own:
/// every property reads and writes the store, so views observing it stay in sync with every other screen.
/// Values are clamped to the ranges Core and the engines accept.
@MainActor
@Observable
final class SettingsViewModel {
    let store: ProfileStore

    init(store: ProfileStore) {
        self.store = store
    }

    // MARK: Ranges

    nonisolated static let a4Range: ClosedRange<Double> = 415...466
    nonisolated static let a4Default: Double = 440
    nonisolated static let countInRange: ClosedRange<Int> = 0...2
    nonisolated static let sensitivityRange: ClosedRange<Double> = 0...1

    /// A4 rounded to whole hertz and clamped to 415…466 Hz (non-finite values reset to 440).
    nonisolated static func clampA4(_ hertz: Double) -> Double {
        guard hertz.isFinite else { return a4Default }
        return min(a4Range.upperBound, max(a4Range.lowerBound, hertz.rounded()))
    }

    nonisolated static func clampSensitivity(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }

    nonisolated static func clampCountIn(_ measures: Int) -> Int {
        min(countInRange.upperBound, max(countInRange.lowerBound, measures))
    }

    /// The offered speed closest to a stored multiplier.
    nonisolated static func nearestSpeed(_ value: Double) -> PracticeSpeed {
        PracticeSpeed.allCases.min { abs($0.rawValue - value) < abs($1.rawValue - value) } ?? .full
    }

    /// "440 Hz", "442 Hz".
    nonisolated static func a4Label(_ hertz: Double) -> String { "\(Int(clampA4(hertz))) Hz" }

    /// "Low", "Medium", "High" description of a sensitivity value.
    nonisolated static func sensitivityLabel(_ value: Double) -> String {
        switch clampSensitivity(value) {
        case ..<0.34: return "Low"
        case ..<0.67: return "Medium"
        default: return "High"
        }
    }

    /// "1 measure", "2 measures", "None".
    nonisolated static func countInLabel(_ measures: Int) -> String {
        switch clampCountIn(measures) {
        case 0: return "None"
        case 1: return "1 measure"
        default: return "\(clampCountIn(measures)) measures"
        }
    }

    // MARK: Instrument & input

    var preferredInput: InputSourceKind {
        get { store.settings.preferredInput }
        set { store.settings.preferredInput = newValue }
    }

    var microphoneSensitivity: Double {
        get { store.settings.microphoneSensitivity }
        set { store.settings.microphoneSensitivity = Self.clampSensitivity(newValue) }
    }

    var a4Hertz: Double {
        get { store.settings.a4Hertz }
        set { store.settings.a4Hertz = Self.clampA4(newValue) }
    }

    func resetA4() { a4Hertz = Self.a4Default }

    // MARK: Practice defaults

    var defaultMode: PracticeMode {
        get { store.settings.defaultPractice.mode }
        set { store.settings.defaultPractice.mode = newValue }
    }

    var defaultHands: HandSelection {
        get { store.settings.defaultPractice.hands }
        set { store.settings.defaultPractice.hands = newValue }
    }

    var defaultSpeed: PracticeSpeed {
        get { Self.nearestSpeed(store.settings.defaultPractice.speed) }
        set { store.settings.defaultPractice.speed = newValue.rawValue }
    }

    var countInMeasures: Int {
        get { store.settings.defaultPractice.countInMeasures }
        set { store.settings.defaultPractice.countInMeasures = Self.clampCountIn(newValue) }
    }

    var playOtherHands: Bool {
        get { store.settings.defaultPractice.playOtherHands }
        set { store.settings.defaultPractice.playOtherHands = newValue }
    }

    var octaveTolerance: Bool {
        get { store.settings.defaultPractice.octaveTolerance }
        set { store.settings.defaultPractice.octaveTolerance = newValue }
    }

    var metronome: Bool {
        get { store.settings.defaultPractice.metronome }
        set { store.settings.defaultPractice.metronome = newValue }
    }

    var showNoteNames: Bool {
        get { store.settings.showNoteNames }
        set { store.settings.showNoteNames = newValue }
    }

    var showFallingNotes: Bool {
        get { store.settings.showFallingNotes }
        set { store.settings.showFallingNotes = newValue }
    }

    // MARK: Sheet import

    var transcriptionModel: SettingsTranscriptionModel {
        get { SettingsTranscriptionModel(storedID: store.settings.transcriptionModel) }
        set { store.settings.transcriptionModel = newValue.rawValue }
    }

    // MARK: Library & onboarding

    var hasCompletedOnboarding: Bool {
        get { store.settings.hasCompletedOnboarding }
        set { store.settings.hasCompletedOnboarding = newValue }
    }

    /// Shows onboarding again (the integrator presents it while the flag is false).
    func replayOnboarding() { hasCompletedOnboarding = false }

    func completeOnboarding() { hasCompletedOnboarding = true }

    /// Erases progress and favorites (keeps settings).
    func resetProgress() { store.resetProgress() }

    /// Number of arrangements and lessons with recorded progress (for the reset confirmation).
    var progressSummary: String {
        let songs = store.profile.progress.count
        let lessons = store.profile.lessons.count
        let favorites = store.profile.favoriteSongIDs.count
        return "\(songs) practiced arrangement\(songs == 1 ? "" : "s"), \(lessons) lesson\(lessons == 1 ? "" : "s"), \(favorites) favorite\(favorites == 1 ? "" : "s")"
    }
}

/// Master volume preference. `UserSettings` has no volume field, so it lives in `UserDefaults`; the practice
/// screen can apply it with `synth.masterVolume = Float(SettingsAudioPreferences.masterVolume)`.
enum SettingsAudioPreferences {
    static let masterVolumeKey = "com.sajadabvi.LearnPiano.masterVolume"
    static let defaultMasterVolume: Double = 0.9

    static func masterVolume(in defaults: UserDefaults = .standard) -> Double {
        guard defaults.object(forKey: masterVolumeKey) != nil else { return defaultMasterVolume }
        let value = defaults.double(forKey: masterVolumeKey)
        return value.isFinite ? min(1, max(0, value)) : defaultMasterVolume
    }

    static func setMasterVolume(_ value: Double, in defaults: UserDefaults = .standard) {
        let clamped = value.isFinite ? min(1, max(0, value)) : defaultMasterVolume
        defaults.set(clamped, forKey: masterVolumeKey)
    }

    static var masterVolume: Double { masterVolume(in: .standard) }
}

/// Pure formatting and file helpers for the Library and About sections.
enum SettingsFormatting {
    /// "1.2 MB" style size string.
    static func byteCount(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, bytes), countStyle: .file)
    }

    /// "Version 0.1.0 (1)" from an Info.plist dictionary.
    static func versionString(info: [String: Any]?) -> String {
        let version = (info?["CFBundleShortVersionString"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? "–"
        let build = (info?["CFBundleVersion"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return build.map { "Version \(version) (\($0))" } ?? "Version \(version)"
    }

    /// The last four characters of a key, masked ("••••abcd"), for showing which key is saved.
    static func maskedKey(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return String(repeating: "•", count: max(4, trimmed.count)) }
        return "••••" + String(trimmed.suffix(4))
    }

    /// Whether a pasted key looks like an Anthropic API key (a hint only; the Test button is authoritative).
    static func looksLikeAnthropicKey(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.hasPrefix("sk-ant-") && trimmed.count > 20 && !trimmed.contains(" ")
    }

    /// Total size of the regular files under `directory` (0 when it does not exist). Runs synchronously; call it
    /// off the main thread.
    static func directorySize(at directory: URL, fileManager: FileManager = .default) -> Int64 {
        guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in enumerator {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true else { continue }
            total += Int64(values.fileSize ?? 0)
        }
        return total
    }
}
