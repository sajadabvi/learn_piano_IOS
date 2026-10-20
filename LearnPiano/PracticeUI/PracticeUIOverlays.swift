import SwiftUI

// MARK: - Input status

/// Status chip on the dark demo region: "Listening…" with a level meter for the microphone, the device name
/// for MIDI, and an inline banner (with a switch to the on-screen keyboard) when the source needs attention.
struct PracticeUIInputStatusView: View {
    let controller: PracticeUISessionController
    @Environment(\.openURL) private var openURL
    @State private var showsBluetoothPairing = false

    var body: some View {
        let status = currentStatus
        VStack(alignment: .leading, spacing: 8) {
            chip(status)
            if status.needsAttention { banner(status) }
        }
        .sheet(isPresented: $showsBluetoothPairing) {
            InputBluetoothMIDIPairingView { showsBluetoothPairing = false }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            controller.hub?.microphoneSource?.refreshPermission()
        }
    }

    private var currentStatus: PracticeUIInputStatus {
        let hub = controller.hub
        let mic = hub?.microphoneSource
        return PracticeUIInputStatus.make(selection: controller.inputSelection,
                                          microphonePermission: mic?.permission,
                                          microphoneState: mic?.sourceState,
                                          microphoneError: mic?.errorMessage,
                                          midiDeviceNames: hub?.midiSource?.connectedDeviceNames ?? [])
    }

    private func chip(_ status: PracticeUIInputStatus) -> some View {
        HStack(spacing: 8) {
            Image(systemName: status.systemImage)
                .font(.caption.weight(.bold))
            Text(status.chipText)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
            if status == .microphoneListening, let mic = controller.hub?.microphoneSource {
                InputLevelMeterView(level: mic.level)
                    .frame(width: 64)
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.white.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Input")
        .accessibilityValue(status.chipText)
    }

    private func banner(_ status: PracticeUIInputStatus) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(message(status))
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                Button {
                    controller.selectInput(.onScreenOnly)
                } label: {
                    Label("Use on-screen keyboard", systemImage: "hand.tap")
                        .font(.subheadline.weight(.semibold))
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                switch status {
                case .microphoneDenied:
                    if let url = controller.microphoneSettingsURL {
                        Button("Open Settings") { openURL(url) }
                            .buttonStyle(.bordered)
                    }
                case .midiNoDevice:
                    Button("Pair Bluetooth MIDI") { showsBluetoothPairing = true }
                        .buttonStyle(.bordered)
                default:
                    EmptyView()
                }
            }
        }
        .padding(14)
        .frame(maxWidth: 420, alignment: .leading)
        .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .shadow(color: .black.opacity(0.25), radius: 10, y: 3)
        .accessibilityElement(children: .contain)
    }

    private func message(_ status: PracticeUIInputStatus) -> String {
        switch status {
        case .microphoneDenied:
            return "LearnPiano can't hear your piano because microphone access is off. Allow it in Settings, or play on the on-screen keyboard."
        case .microphoneUnavailable(let detail):
            return "The microphone isn't working: \(detail) You can play on the on-screen keyboard instead."
        case .midiNoDevice:
            return "No MIDI keyboard is connected. Plug one in with USB, pair a Bluetooth keyboard, or play on the on-screen keyboard."
        default:
            return status.chipText
        }
    }
}

// MARK: - Wrong-note pill

/// "Expected: C4 E4" after a wrong note in Wait Mode.
struct PracticeUIWrongNotePillView: View {
    let pill: PracticeUIWrongNotePill

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
            Text(pill.text)
                .font(.subheadline.weight(.semibold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(Theme.wrong, in: Capsule())
        .shadow(color: .black.opacity(0.3), radius: 8, y: 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(pill.spoken)
        .accessibilityAddTraits(.updatesFrequently)
    }
}

// MARK: - Count-in

/// Big beat numbers during the count-in.
struct PracticeUICountInOverlay: View {
    let controller: PracticeUISessionController
    @ScaledMetric(relativeTo: .largeTitle) private var size: CGFloat = 120

    var body: some View {
        let session = controller.session
        if session.transportState == .countingIn, let beat = session.countInBeat {
            let shown = PracticeUICountIn.displayBeat(beat: beat, totalBeats: session.countInTotalBeats, measures: max(1, session.countInMeasures))
            Text("\(shown)")
                .font(.system(size: size, weight: .heavy, design: .rounded).monospacedDigit())
                .foregroundStyle(.white)
                .frame(width: size * 1.6, height: size * 1.6)
                .background(Theme.mediaBackground.opacity(0.78), in: Circle())
                .overlay(Circle().stroke(Theme.accent, lineWidth: 4))
                .id(beat)
                .transition(.scale(scale: 1.25).combined(with: .opacity))
                .animation(.easeOut(duration: 0.18), value: beat)
                .allowsHitTesting(false)
                .accessibilityElement()
                .accessibilityLabel("Count-in")
                .accessibilityValue("Beat \(beat + 1) of \(session.countInTotalBeats)")
        }
    }
}

// MARK: - Banners

/// Exercise instructions shown above the practice regions.
struct PracticeUIExerciseBanner: View {
    let instructions: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "lightbulb.fill")
                .foregroundStyle(Theme.waiting)
                .font(.headline)
            Text(instructions)
                .font(.subheadline)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(Theme.waiting.opacity(0.12))
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Exercise instructions")
        .accessibilityValue(instructions)
    }
}

/// A notice that the piano sound is unavailable.
struct PracticeUIAudioBanner: View {
    let message: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "speaker.slash.fill")
                .foregroundStyle(Theme.wrong)
            Text(message)
                .font(.footnote)
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.wrong.opacity(0.08))
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Summary sheet

/// End-of-session summary: accuracy, time, wrong notes, trouble measures, the exercise verdict, and the
/// Practice again / Loop the trouble spot / Done actions.
struct PracticeUISummarySheet: View {
    let presentation: PracticeUISummaryPresentation
    let onPracticeAgain: () -> Void
    let onLoopTroubleSpot: () -> Void
    let onDone: () -> Void

    private var text: PracticeUISummaryText { presentation.text }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                header
                stats
                if !text.troubleMeasures.isEmpty { trouble }
                actions
            }
            .padding(24)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
    }

    private var header: some View {
        VStack(spacing: 8) {
            if let result = text.exerciseResult, let passed = text.passed {
                Image(systemName: passed ? "checkmark.seal.fill" : "arrow.clockwise.circle.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(passed ? Theme.correct : Theme.waiting)
                    .accessibilityHidden(true)
                Text(result)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(passed ? Theme.correct : Theme.textPrimary)
                Text(text.headline)
                    .font(.headline)
                    .foregroundStyle(Theme.textSecondary)
            } else {
                Text(text.headline)
                    .font(.system(.largeTitle, design: .rounded).weight(.bold))
                    .foregroundStyle(Theme.textPrimary)
            }
            Text(detailLine)
                .font(.subheadline)
                .foregroundStyle(Theme.textSecondary)
        }
        .multilineTextAlignment(.center)
        .accessibilityElement(children: .combine)
    }

    private var detailLine: String {
        let s = presentation.summary
        return "\(s.mode.displayName) · \(s.hands.displayName) · \(PracticeUISpeedText.label(s.speed))"
    }

    private var stats: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 12)], spacing: 12) {
            statCard("Accuracy", text.accuracy, color: Theme.correct)
            statCard("Time", text.time, color: Theme.accent)
            statCard("Wrong notes", text.wrongNotes, color: Theme.wrong)
            statCard("Steps", text.steps, color: Theme.textPrimary)
        }
    }

    private func statCard(_ title: String, _ value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Text(value)
                .font(.system(.title, design: .rounded).weight(.bold).monospacedDigit())
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            Text(title)
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(value)
    }

    private var trouble: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Trouble spots")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
            ForEach(text.troubleMeasures, id: \.self) { line in
                Label(line, systemImage: "exclamationmark.triangle.fill")
                    .font(.subheadline)
                    .foregroundStyle(Theme.textPrimary)
                    .symbolRenderingMode(.multicolor)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    private var actions: some View {
        VStack(spacing: 10) {
            Button(action: onPracticeAgain) {
                Label("Practice again", systemImage: "arrow.counterclockwise")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.borderedProminent)
            .tint(Theme.accent)
            if text.troubleLoop != nil {
                Button(action: onLoopTroubleSpot) {
                    Label("Loop the trouble spot", systemImage: "repeat")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 44)
                }
                .buttonStyle(.bordered)
                .tint(Theme.accent)
            }
            Button(action: onDone) {
                Text("Done")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .buttonStyle(.bordered)
            .tint(Theme.textSecondary)
        }
    }
}
