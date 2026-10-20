import SwiftUI

// MARK: - Segmented control

/// One option of `PracticeUISegmentedControl`.
struct PracticeUISegment<Value: Hashable>: Identifiable {
    var value: Value
    var label: String
    var isEnabled: Bool = true
    var id: Value { value }
}

/// Capsule segmented control in the app's accent color (individual segments can be disabled).
struct PracticeUISegmentedControl<Value: Hashable>: View {
    let title: String
    let segments: [PracticeUISegment<Value>]
    let selection: Value
    let onSelect: (Value) -> Void

    var body: some View {
        HStack(spacing: 2) {
            ForEach(segments) { segment in
                let selected = segment.value == selection
                Button {
                    onSelect(segment.value)
                } label: {
                    Text(segment.label)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .frame(minHeight: 32)
                        .foregroundStyle(selected ? Color.white : (segment.isEnabled ? Theme.textPrimary : Theme.textSecondary.opacity(0.5)))
                        .background(selected ? Theme.accent : Color.clear, in: Capsule())
                        .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .disabled(!segment.isEnabled)
                .accessibilityLabel(segment.label)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Theme.background, in: Capsule())
        .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
    }
}

// MARK: - Chip button

/// Small rounded header button with an icon and optional text; filled with the accent when `isOn`.
struct PracticeUIChipLabel: View {
    let systemImage: String
    var text: String?
    var isOn: Bool = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.semibold))
            if let text {
                Text(text)
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, text == nil ? 9 : 12)
        .frame(minWidth: 38, minHeight: 38)
        .foregroundStyle(isOn ? Color.white : Theme.textPrimary)
        .background(isOn ? Theme.accent : Theme.background, in: Capsule())
        .overlay(Capsule().stroke(isOn ? Color.clear : Theme.separator, lineWidth: 1))
        .contentShape(Capsule())
    }
}

// MARK: - Header

/// The slim practice header: close, title, mode, hands, speed, metronome, loop and the settings popover.
/// Falls back to two rows when the width cannot hold everything in one.
struct PracticeUIHeaderView: View {
    let controller: PracticeUISessionController
    let onClose: () -> Void

    @State private var showsSettings = false

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                closeButton
                titleBlock
                Spacer(minLength: 8)
                modeControl
                handsControl
                speedMenu
                metronomeButton
                loopButton
                settingsButton
            }
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    closeButton
                    titleBlock
                    Spacer(minLength: 8)
                    metronomeButton
                    settingsButton
                }
                HStack(spacing: 10) {
                    modeControl
                    handsControl
                    Spacer(minLength: 0)
                    speedMenu
                    loopButton
                }
            }
            VStack(spacing: 8) {
                HStack(spacing: 10) {
                    closeButton
                    titleBlock
                    Spacer(minLength: 4)
                    settingsButton
                }
                HStack(spacing: 8) {
                    modeControl
                    Spacer(minLength: 0)
                    speedMenu
                    metronomeButton
                }
                HStack(spacing: 8) {
                    handsControl
                    Spacer(minLength: 0)
                    loopButton
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(Theme.card)
        .overlay(alignment: .bottom) { Theme.separator.frame(height: 1) }
    }

    private var session: PracticeSession { controller.session }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.headline)
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 40, height: 40)
                .background(Theme.background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Close practice")
        .accessibilityHint("Stops the session and returns to the library")
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(controller.request.title)
                .font(.system(.headline, design: .rounded))
                .foregroundStyle(Theme.textPrimary)
                .lineLimit(1)
            if !controller.request.subtitle.isEmpty {
                Text(controller.request.subtitle)
                    .font(.caption)
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
        }
        .layoutPriority(1)
        .frame(minWidth: 80, maxWidth: 280, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var modeControl: some View {
        PracticeUISegmentedControl(
            title: "Practice mode",
            segments: PracticeMode.allCases.map { PracticeUISegment(value: $0, label: $0.displayName) },
            selection: session.mode,
            onSelect: { controller.setMode($0) }
        )
    }

    private var handsControl: some View {
        let available = controller.availableHands
        let labels: [HandSelection: String] = [.right: "Right", .left: "Left", .both: "Both"]
        return PracticeUISegmentedControl(
            title: "Hands",
            segments: [HandSelection.right, .left, .both].map {
                PracticeUISegment(value: $0, label: labels[$0] ?? $0.displayName, isEnabled: available.contains($0) && session.mode != .listen)
            },
            selection: session.hands,
            onSelect: { controller.setHands($0) }
        )
    }

    private var speedMenu: some View {
        Menu {
            ForEach(PracticeSpeed.allCases, id: \.self) { speed in
                Button {
                    controller.setSpeed(speed.rawValue)
                } label: {
                    if abs(session.speed - speed.rawValue) < 0.001 {
                        Label(PracticeUISpeedText.label(speed.rawValue), systemImage: "checkmark")
                    } else {
                        Text(PracticeUISpeedText.label(speed.rawValue))
                    }
                }
            }
        } label: {
            PracticeUIChipLabel(systemImage: "gauge.with.dots.needle.50percent", text: PracticeUISpeedText.label(session.speed), isOn: session.speed < 0.999)
        }
        .accessibilityLabel("Speed")
        .accessibilityValue(PracticeUISpeedText.label(session.speed))
    }

    private var metronomeButton: some View {
        Button {
            controller.toggleMetronome()
        } label: {
            PracticeUIChipLabel(systemImage: "metronome", isOn: session.metronomeEnabled)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Metronome")
        .accessibilityValue(session.metronomeEnabled ? "On" : "Off")
        .accessibilityAddTraits(session.metronomeEnabled ? .isSelected : [])
    }

    private var loopButton: some View {
        let loop = session.loop
        return Button {
            controller.toggleLoop()
        } label: {
            PracticeUIChipLabel(systemImage: "repeat", text: PracticeUILoopSelection.label(loop, score: session.score), isOn: loop != nil)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Loop")
        .accessibilityValue(loop == nil ? "Off" : PracticeUILoopSelection.label(loop, score: session.score))
        .accessibilityHint("Tap measures in the score to choose the loop region")
    }

    private var settingsButton: some View {
        Button {
            showsSettings = true
        } label: {
            PracticeUIChipLabel(systemImage: "slider.horizontal.3")
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Practice settings")
        .popover(isPresented: $showsSettings, arrowEdge: .top) {
            PracticeUISettingsPanel(controller: controller)
                .frame(minWidth: 320, idealWidth: 360, minHeight: 320, idealHeight: 620)
                .presentationCompactAdaptation(.popover)
        }
    }
}

// MARK: - Settings popover

/// Count-in, octave tolerance, other-hand playback, falling notes, note names and the input source.
struct PracticeUISettingsPanel: View {
    let controller: PracticeUISessionController
    @Environment(ProfileStore.self) private var profileStore
    @State private var showsBluetoothPairing = false

    var body: some View {
        let session = controller.session
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("Practice settings")
                    .font(.system(.headline, design: .rounded))
                    .foregroundStyle(Theme.textPrimary)

                VStack(alignment: .leading, spacing: 8) {
                    Text("Count-in")
                        .font(.subheadline.weight(.semibold))
                    Picker("Count-in", selection: Binding(get: { session.countInMeasures }, set: { controller.setCountIn($0) })) {
                        Text("Off").tag(0)
                        Text("1 bar").tag(1)
                        Text("2 bars").tag(2)
                    }
                    .pickerStyle(.segmented)
                    Text("Used before Just Play and Listen.")
                        .font(.caption)
                        .foregroundStyle(Theme.textSecondary)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Toggle(isOn: Binding(get: { session.settings.octaveTolerance }, set: { controller.setOctaveTolerance($0) })) {
                        labeled("Octave tolerance", "Accept the right note in any octave.")
                    }
                    Toggle(isOn: Binding(get: { session.settings.playOtherHands }, set: { controller.setPlayOtherHands($0) })) {
                        labeled("Play the other hand", "The app plays the hand you are not practicing.")
                    }
                    Toggle(isOn: Binding(get: { controller.showsFallingNotes }, set: { value in
                        controller.showsFallingNotes = value
                        profileStore.update { $0.settings.showFallingNotes = value }
                    })) {
                        labeled("Falling notes", "Show the notes falling onto the keyboard.")
                    }
                    Toggle(isOn: Binding(get: { controller.showsNoteNames }, set: { value in
                        controller.showsNoteNames = value
                        profileStore.update { $0.settings.showNoteNames = value }
                    })) {
                        labeled("Note names", "Label the keys and falling notes.")
                    }
                }
                .tint(Theme.accent)

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("Listen to")
                        .font(.subheadline.weight(.semibold))
                    Picker("Input", selection: Binding(get: { controller.inputSelection }, set: { controller.selectInput($0) })) {
                        Text("MIDI keyboard").tag(InputHubSelection.midi)
                        Text("Microphone").tag(InputHubSelection.microphone)
                        Text("MIDI and microphone").tag(InputHubSelection.both)
                        Text("On-screen keyboard only").tag(InputHubSelection.onScreenOnly)
                    }
                    .pickerStyle(.menu)
                    .accessibilityLabel("Input source")
                    if controller.inputSelection == .midi || controller.inputSelection == .both {
                        Button {
                            showsBluetoothPairing = true
                        } label: {
                            Label("Connect a Bluetooth MIDI keyboard", systemImage: "dot.radiowaves.left.and.right")
                                .font(.subheadline)
                        }
                    }
                    if controller.inputSelection == .microphone || controller.inputSelection == .both,
                       let mic = controller.hub?.microphoneSource {
                        InputMicrophoneStatusView(source: mic)
                    }
                }
            }
            .padding(20)
        }
        .sheet(isPresented: $showsBluetoothPairing) {
            InputBluetoothMIDIPairingView { showsBluetoothPairing = false }
        }
    }

    private func labeled(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.subheadline)
            Text(detail).font(.caption).foregroundStyle(Theme.textSecondary)
        }
    }
}
