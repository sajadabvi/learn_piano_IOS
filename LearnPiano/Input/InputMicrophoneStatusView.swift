import SwiftUI
import UIKit

/// Horizontal input-level meter (0…1) with green/yellow/red zones; reads `InputMicrophoneSource.level`.
struct InputLevelMeterView: View {
    /// Meter value 0…1 (−60 … 0 dBFS).
    var level: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.secondary.opacity(0.2))
                Capsule()
                    .fill(color)
                    .frame(width: proxy.size.width * max(0, min(1, level)))
                    .animation(.linear(duration: 0.05), value: level)
            }
        }
        .frame(height: 8)
        .accessibilityElement()
        .accessibilityLabel("Microphone level")
        .accessibilityValue("\(Int((max(0, min(1, level)) * 100).rounded())) percent")
    }

    /// Green for normal playing, yellow when loud, red near clipping.
    private var color: Color {
        switch level {
        case ..<0.75: return .green
        case ..<0.92: return .yellow
        default: return .red
        }
    }
}

/// Microphone status block for Settings and the practice input popover: permission handling, level meter
/// and the last detected notes. Uses system semantic styles so it inherits the app's tint.
struct InputMicrophoneStatusView: View {
    /// The microphone source shown.
    var source: InputMicrophoneSource
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch source.permission {
            case .denied:
                Text("Microphone access is off. Allow it in Settings so LearnPiano can hear your piano.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                if let url = InputMicrophoneSource.systemSettingsURL {
                    Button("Open Settings") { openURL(url) }
                }
            case .undetermined:
                Text("LearnPiano needs the microphone to hear which keys you play.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Button("Allow Microphone") {
                    Task { await source.requestPermission() }
                }
            case .granted:
                InputLevelMeterView(level: source.level)
                HStack {
                    Text(stateText)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text(notesText)
                        .font(.body.monospacedDigit())
                        .foregroundStyle(.primary)
                        .accessibilityLabel("Last detected notes")
                        .accessibilityValue(notesText)
                }
            }
            if let error = source.errorMessage {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            source.refreshPermission()
        }
    }

    private var stateText: String {
        switch source.sourceState {
        case .running: return "Listening"
        case .starting: return "Starting…"
        case .idle: return "Not listening"
        case .permissionDenied: return "No permission"
        case .unavailable: return "No microphone input"
        case .failed: return "Microphone error"
        }
    }

    private var notesText: String {
        let notes = source.soundingNotes.isEmpty ? source.lastDetectedNotes : source.soundingNotes
        return notes.isEmpty ? "–" : notes.map { MusicHelpers.noteName(midi: $0) }.joined(separator: " ")
    }
}
