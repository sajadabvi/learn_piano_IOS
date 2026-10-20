import SwiftUI

/// Keyboard range and key states for "Test your setup": the default range, widened to the full piano when a
/// detected note falls outside it.
enum SettingsSetupTestLayout {
    static func visibleRange(for held: Set<Int>, recent: [Int]) -> ClosedRange<Int> {
        let base = KeyboardRangeFitter.defaultRange
        let notes = Array(held) + recent
        guard let low = notes.min(), let high = notes.max() else { return base }
        if low >= base.lowerBound, high <= base.upperBound { return base }
        return Pitch.pianoRange
    }

    static func keyStates(for held: Set<Int>) -> [Int: KeyboardKeyState] {
        Dictionary(uniqueKeysWithValues: held.filter { Pitch.pianoRange.contains($0) }.map { ($0, KeyboardKeyState.correct) })
    }

    /// The note-ons in `events` played at or after `since` (all of them when `since` is nil). The shared monitor's
    /// hub keeps its history for the whole app, so screens that check "play a key" pass the time they appeared.
    static func noteOns(_ events: [NoteInputEvent], since: TimeInterval?) -> [NoteInputEvent] {
        events.filter { $0.kind == .on && isFresh($0, since: since) }
    }

    /// `event` when it is a note-on played at or after `since` (any time when `since` is nil), otherwise nil.
    static func freshNoteOn(_ event: NoteInputEvent?, since: TimeInterval?) -> NoteInputEvent? {
        guard let event, event.kind == .on, isFresh(event, since: since) else { return nil }
        return event
    }

    private static func isFresh(_ event: NoteInputEvent, since: TimeInterval?) -> Bool {
        guard let since else { return true }
        return event.time >= since
    }

    /// "C4 E4 G4" for the most recent note-ons (at most `limit`, oldest first).
    static func recentNames(_ events: [NoteInputEvent], limit: Int = 8) -> String {
        let names = events.suffix(limit).map { MusicHelpers.noteName(midi: $0.midi) }
        return names.isEmpty ? "–" : names.joined(separator: "  ")
    }
}

/// Live keyboard that lights up every key the selected input detects. Used by the "Test your setup" sheet and the
/// last onboarding page. Touches on the keys go through the hub as on-screen keyboard input. "Recent" lists only
/// note-ons played at or after `since` (nil shows the hub's whole history).
struct SettingsLiveKeyboardPanel: View {
    var monitor: SettingsInputMonitor
    var showsNoteNames: Bool
    var height: CGFloat = 180
    var since: TimeInterval?

    var body: some View {
        let held = monitor.heldNotes
        let recent = SettingsSetupTestLayout.noteOns(monitor.recentEvents, since: since)
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Detected now")
                        .font(Theme.caption())
                        .foregroundStyle(.white.opacity(0.6))
                    Text(held.isEmpty ? "–" : held.sorted().map { MusicHelpers.noteName(midi: $0) }.joined(separator: " "))
                        .font(Theme.title(34).monospacedDigit())
                        .foregroundStyle(.white)
                        .contentTransition(.numericText())
                        .accessibilityLabel("Keys detected now")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text("Recent")
                        .font(Theme.caption())
                        .foregroundStyle(.white.opacity(0.6))
                    Text(SettingsSetupTestLayout.recentNames(recent))
                        .font(Theme.body().monospacedDigit())
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(1)
                }
            }
            KeyboardView(visibleRange: SettingsSetupTestLayout.visibleRange(for: held, recent: recent.suffix(8).map(\.midi)),
                         keyStates: SettingsSetupTestLayout.keyStates(for: held),
                         labels: showsNoteNames ? .all : .cOnly,
                         showsMiddleCMarker: true,
                         isTouchEnabled: true,
                         highlightsTouches: true,
                         onNoteEvent: { event in monitor.inject(event) })
                .frame(height: height)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .padding(Theme.cardPadding)
        .background(Theme.mediaBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

/// The "Test your setup" sheet: input status plus the live keyboard. Notes played before the sheet opened are not
/// shown, so "Recent" and "Last note detected" start empty each time.
struct SettingsSetupTestSheet: View {
    var monitor: SettingsInputMonitor
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.dismiss) private var dismiss
    @State private var testStart: TimeInterval = InputClock.now

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(instructions)
                        .font(Theme.body())
                        .foregroundStyle(Theme.textSecondary)
                    SettingsLiveKeyboardPanel(monitor: monitor, showsNoteNames: profileStore.settings.showNoteNames, height: 200,
                                              since: testStart)
                    SettingsInputStatusView(monitor: monitor, preferredInput: profileStore.settings.preferredInput,
                                            lastNoteSince: testStart)
                        .card()
                }
                .padding(24)
            }
            .background(Theme.background)
            .navigationTitle("Test your setup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .onAppear { testStart = InputClock.now }
        .settingsInputMonitoring()
    }

    private var instructions: String {
        switch profileStore.settings.preferredInput {
        case .midi: return "Press keys on your MIDI keyboard. Each key you hold lights up below."
        case .microphone: return "Play single notes, then simple chords, at a normal volume. Detected keys light up below. If notes are missed, raise the microphone sensitivity; if extra notes appear, lower it."
        case .virtualKeyboard: return "Tap the keys below to check the on-screen keyboard."
        }
    }
}
