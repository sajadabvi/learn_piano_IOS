import SwiftUI
import UIKit

/// Holds `SettingsInputMonitor.shared` while the view is on screen, the app is active and `active` is true
/// (callers pass false while the practice screen is presented). Re-applies settings whenever they change.
struct SettingsInputMonitoring: ViewModifier {
    var active: Bool
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var isVisible = false
    @State private var isHolding = false

    func body(content: Content) -> some View {
        content
            .onAppear {
                isVisible = true
                sync()
            }
            .onDisappear {
                isVisible = false
                sync()
            }
            .onChange(of: active) { _, _ in sync() }
            .onChange(of: scenePhase) { _, phase in
                sync()
                if phase == .active { SettingsInputMonitor.shared.refreshPermission() }
            }
            .onChange(of: profileStore.settings) { _, settings in
                SettingsInputMonitor.shared.apply(settings)
            }
    }

    private func sync() {
        let shouldHold = isVisible && active && scenePhase != .background
        guard shouldHold != isHolding else { return }
        isHolding = shouldHold
        if shouldHold {
            SettingsInputMonitor.shared.acquire(settings: profileStore.settings)
        } else {
            SettingsInputMonitor.shared.release()
        }
    }
}

extension View {
    /// See `SettingsInputMonitoring`.
    func settingsInputMonitoring(active: Bool = true) -> some View {
        modifier(SettingsInputMonitoring(active: active))
    }
}

/// The live status block: MIDI devices, microphone permission and level, and the last detected note. Used in the
/// Settings form and in onboarding. "Last note detected" ignores notes played before `lastNoteSince` (nil shows
/// the last note ever detected).
struct SettingsInputStatusView: View {
    var monitor: SettingsInputMonitor
    var preferredInput: InputSourceKind
    var lastNoteSince: TimeInterval?
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch preferredInput {
            case .midi: midiStatus
            case .microphone: microphoneStatus
            case .virtualKeyboard: onScreenStatus
            }
            Divider()
            lastNoteRow
        }
        .padding(.vertical, 4)
    }

    // MARK: MIDI

    @ViewBuilder private var midiStatus: some View {
        let devices = monitor.midiDevices
        if devices.isEmpty {
            statusLine(icon: "cable.connector.slash", color: Theme.textSecondary,
                       title: "No MIDI keyboard connected",
                       detail: "Plug one in over USB, or pair a Bluetooth keyboard below.")
        } else {
            ForEach(devices) { device in
                statusLine(icon: "pianokeys", color: device.isOffline ? Theme.textSecondary : Theme.correct,
                           title: device.name,
                           detail: device.isOffline ? "Offline" : "Connected" + (device.manufacturer.map { " · \($0)" } ?? ""))
            }
        }
        if monitor.midiState == .failed {
            Text("CoreMIDI could not start. Restart the app and try again.")
                .font(Theme.caption())
                .foregroundStyle(Theme.wrong)
        }
    }

    // MARK: Microphone

    @ViewBuilder private var microphoneStatus: some View {
        switch monitor.microphonePermission {
        case .undetermined:
            statusLine(icon: "mic", color: Theme.waiting,
                       title: "Microphone not allowed yet",
                       detail: "LearnPiano needs the microphone to hear which keys you play.")
            Button {
                Task { await monitor.requestMicrophonePermission() }
            } label: {
                Label("Allow microphone", systemImage: "mic.badge.plus")
            }
            .buttonStyle(.borderedProminent)
        case .denied:
            statusLine(icon: "mic.slash", color: Theme.wrong,
                       title: "Microphone access is off",
                       detail: "Turn on Microphone for LearnPiano in the Settings app.")
            if let url = InputMicrophoneSource.systemSettingsURL {
                Button {
                    openURL(url)
                } label: {
                    Label("Open Settings", systemImage: "gear")
                }
                .buttonStyle(.bordered)
            }
        case .granted:
            statusLine(icon: "mic.fill", color: microphoneColor,
                       title: microphoneTitle,
                       detail: "Play a few notes; the meter should move with your piano.")
            InputLevelMeterView(level: monitor.microphoneLevel)
        }
    }

    private var microphoneTitle: String {
        switch monitor.microphoneState {
        case .running: return "Listening"
        case .starting: return "Starting…"
        case .idle: return "Not listening"
        case .permissionDenied: return "No permission"
        case .unavailable: return "No microphone input available"
        case .failed: return "Microphone error"
        }
    }

    private var microphoneColor: Color {
        switch monitor.microphoneState {
        case .running: return Theme.correct
        case .starting, .idle: return Theme.waiting
        case .permissionDenied, .unavailable, .failed: return Theme.wrong
        }
    }

    // MARK: On-screen

    private var onScreenStatus: some View {
        statusLine(icon: "hand.tap", color: Theme.accent,
                   title: "On-screen keyboard",
                   detail: "Tap the keys on screen. Useful when no piano is nearby.")
    }

    // MARK: Last note

    private var lastNoteRow: some View {
        HStack {
            Text("Last note detected")
                .font(Theme.body())
                .foregroundStyle(Theme.textPrimary)
            Spacer()
            if let note = SettingsSetupTestLayout.freshNoteOn(monitor.lastNoteOn, since: lastNoteSince) {
                Text(MusicHelpers.noteName(midi: note.midi))
                    .font(Theme.heading(18).monospacedDigit())
                    .foregroundStyle(Theme.accent)
                Text(note.source.displayName)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text("–")
                    .font(Theme.heading(18))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private func statusLine(icon: String, color: Color, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textPrimary)
                Text(detail)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Input source picker shown as three large choice cards (onboarding) or a segmented-style list.
struct SettingsInputChoiceCards: View {
    @Binding var selection: InputSourceKind

    var body: some View {
        HStack(spacing: 14) {
            ForEach(InputSourceKind.allCases, id: \.self) { kind in
                Button {
                    selection = kind
                } label: {
                    VStack(spacing: 10) {
                        Image(systemName: SettingsInputChoiceCards.icon(for: kind))
                            .font(.system(size: 30, weight: .medium))
                        Text(kind.displayName)
                            .font(Theme.heading(16))
                        Text(SettingsInputChoiceCards.detail(for: kind))
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                            .multilineTextAlignment(.center)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .foregroundStyle(selection == kind ? Theme.accent : Theme.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 150)
                    .padding(12)
                    .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                            .strokeBorder(selection == kind ? Theme.accent : Theme.separator, lineWidth: selection == kind ? 2 : 1)
                    )
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == kind ? .isSelected : [])
            }
        }
    }

    static func icon(for kind: InputSourceKind) -> String {
        switch kind {
        case .midi: return "pianokeys"
        case .microphone: return "mic"
        case .virtualKeyboard: return "hand.tap"
        }
    }

    static func detail(for kind: InputSourceKind) -> String {
        switch kind {
        case .midi: return "Digital piano over USB or Bluetooth. Most precise."
        case .microphone: return "Acoustic or digital piano heard through the iPad."
        case .virtualKeyboard: return "Tap keys on the screen."
        }
    }
}
