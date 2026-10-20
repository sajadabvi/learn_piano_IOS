import SwiftUI

/// Pages of the first-run onboarding.
enum SettingsOnboardingPage: Int, CaseIterable, Identifiable, Hashable {
    case welcome, instrument, permissions, tryIt

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Learn piano with the music in front of you"
        case .instrument: return "What will you play on?"
        case .permissions: return "Let LearnPiano hear you"
        case .tryIt: return "Try it"
        }
    }

    var next: SettingsOnboardingPage? { SettingsOnboardingPage(rawValue: rawValue + 1) }
    var previous: SettingsOnboardingPage? { SettingsOnboardingPage(rawValue: rawValue - 1) }
    var isLast: Bool { next == nil }
}

/// First-run onboarding (4 pages): what the app does, choosing the input with a live status row, microphone and
/// Bluetooth permission prompts, and "try it" (play any key and see it detected).
///
/// The integrator presents it while `ProfileStore.settings.hasCompletedOnboarding` is false, e.g.
/// `.fullScreenCover(isPresented: needsOnboardingBinding) { SettingsOnboardingView() }`. "Done" and "Skip" set the
/// flag to true themselves (which dismisses a cover bound to it) and then call `onFinish`.
struct SettingsOnboardingView: View {
    var onFinish: (() -> Void)?

    @Environment(ProfileStore.self) private var profileStore
    @State private var page: SettingsOnboardingPage = .welcome
    @State private var monitor = SettingsInputMonitor.shared
    @State private var isPairing = false
    /// When onboarding appeared: page 2's "Last note detected" ignores notes played before it.
    @State private var onboardingStart: TimeInterval = InputClock.now
    /// When the "Try it" page last became current: only notes played after it count as success. Nil until then,
    /// so a note played on an earlier page (or before "Replay onboarding") never shows the success line.
    @State private var tryItStart: TimeInterval?

    init(onFinish: (() -> Void)? = nil) {
        self.onFinish = onFinish
    }

    var body: some View {
        let viewModel = SettingsViewModel(store: profileStore)
        VStack(spacing: 0) {
            header
            TabView(selection: $page) {
                ForEach(SettingsOnboardingPage.allCases) { item in
                    ScrollView {
                        pageContent(item, viewModel: viewModel)
                            .frame(maxWidth: 760)
                            .padding(.horizontal, 32)
                            .padding(.vertical, 24)
                            .frame(maxWidth: .infinity)
                    }
                    .tag(item)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .animation(.easeInOut(duration: 0.25), value: page)
            footer(viewModel: viewModel)
        }
        .background(Theme.background.ignoresSafeArea())
        .sheet(isPresented: $isPairing, onDismiss: { monitor.refreshMIDIDevices() }) {
            InputBluetoothMIDIPairingView { isPairing = false }
        }
        .onAppear { onboardingStart = InputClock.now }
        .onChange(of: page, initial: true) { _, newPage in
            tryItStart = newPage == .tryIt ? InputClock.now : nil
        }
        .settingsInputMonitoring()
    }

    // MARK: Chrome

    private var header: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(SettingsOnboardingPage.allCases) { item in
                    Capsule()
                        .fill(item.rawValue <= page.rawValue ? Theme.accent : Theme.separator)
                        .frame(width: item == page ? 28 : 10, height: 6)
                }
            }
            .accessibilityElement()
            .accessibilityLabel("Page \(page.rawValue + 1) of \(SettingsOnboardingPage.allCases.count)")
            Spacer()
            if !page.isLast {
                Button("Skip") { finish() }
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 24)
        .padding(.bottom, 8)
    }

    private func footer(viewModel: SettingsViewModel) -> some View {
        HStack {
            if let previous = page.previous {
                Button {
                    page = previous
                } label: {
                    Label("Back", systemImage: "chevron.left")
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            Spacer()
            if let next = page.next {
                Button {
                    page = next
                } label: {
                    Text("Continue").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            } else {
                Button {
                    finish()
                } label: {
                    Text("Done").frame(minWidth: 140)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
            }
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        .background(Theme.card.shadow(.drop(color: .black.opacity(0.05), radius: 8, y: -2)))
    }

    private func finish() {
        profileStore.settings.hasCompletedOnboarding = true
        profileStore.saveNow()
        onFinish?()
    }

    // MARK: Pages

    @ViewBuilder
    private func pageContent(_ item: SettingsOnboardingPage, viewModel: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 24) {
            Text(item.title)
                .font(Theme.title(34))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            switch item {
            case .welcome: welcomePage
            case .instrument: instrumentPage(viewModel: viewModel)
            case .permissions: permissionsPage(viewModel: viewModel)
            case .tryIt: tryItPage(viewModel: viewModel)
            }
        }
    }

    private var welcomePage: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("LearnPiano shows real sheet music, plays it for you on a keyboard, and listens while you play it back.")
                .font(Theme.body(18))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            feature(icon: "music.note.list", title: "Songs and courses",
                    text: "From your first notes to classics, with lessons that build step by step.")
            feature(icon: "hourglass", title: "Wait Mode",
                    text: "The music waits until you find the right keys, so you can learn at your own pace.")
            feature(icon: "tortoise", title: "Slow down, loop, one hand at a time",
                    text: "Practice the hard bars slowly, then bring the hands together.")
            feature(icon: "doc.viewfinder", title: "Import your own sheets",
                    text: "Open MusicXML or MIDI files, or photograph a printed page.")
        }
    }

    private func instrumentPage(viewModel: SettingsViewModel) -> some View {
        @Bindable var viewModel = viewModel
        return VStack(alignment: .leading, spacing: 20) {
            Text("You can change this any time in Settings.")
                .font(Theme.body(18))
                .foregroundStyle(Theme.textSecondary)
            SettingsInputChoiceCards(selection: $viewModel.preferredInput)
            SettingsInputStatusView(monitor: monitor, preferredInput: viewModel.preferredInput,
                                    lastNoteSince: onboardingStart)
                .card()
        }
    }

    private func permissionsPage(viewModel: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("LearnPiano only listens while you practice. Nothing you play is recorded or uploaded.")
                .font(Theme.body(18))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            permissionCard(icon: "mic.fill",
                           title: "Microphone",
                           text: "Needed for an acoustic piano, or a digital piano without a cable.",
                           status: microphoneStatusText,
                           statusColor: monitor.microphonePermission == .granted ? Theme.correct : (monitor.microphonePermission == .denied ? Theme.wrong : Theme.textSecondary)) {
                switch monitor.microphonePermission {
                case .undetermined:
                    Button("Allow microphone") {
                        Task { await monitor.requestMicrophonePermission() }
                    }
                    .buttonStyle(.borderedProminent)
                case .denied:
                    if let url = InputMicrophoneSource.systemSettingsURL {
                        Link("Open Settings", destination: url)
                            .buttonStyle(.bordered)
                    }
                case .granted:
                    EmptyView()
                }
            }
            permissionCard(icon: "dot.radiowaves.left.and.right",
                           title: "Bluetooth MIDI",
                           text: "For wireless MIDI keyboards. USB keyboards work without pairing.",
                           status: monitor.connectedMIDIDeviceNames.isEmpty ? "No keyboard connected" : "Connected: \(monitor.connectedMIDIDeviceNames.joined(separator: ", "))",
                           statusColor: monitor.connectedMIDIDeviceNames.isEmpty ? Theme.textSecondary : Theme.correct) {
                Button("Pair a keyboard") { isPairing = true }
                    .buttonStyle(.bordered)
            }
            if viewModel.preferredInput == .virtualKeyboard {
                Text("You chose the on-screen keyboard, so neither permission is needed now.")
                    .font(Theme.caption(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    private func tryItPage(viewModel: SettingsViewModel) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Text(tryItInstructions(for: viewModel.preferredInput))
                .font(Theme.body(18))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            let cutoff = tryItStart ?? .infinity
            SettingsLiveKeyboardPanel(monitor: monitor, showsNoteNames: viewModel.showNoteNames, height: 190,
                                      since: cutoff)
            if let note = SettingsSetupTestLayout.freshNoteOn(monitor.lastNoteOn, since: cutoff) {
                Label("Detected \(MusicHelpers.noteName(midi: note.midi)). You are ready to play.",
                      systemImage: "checkmark.circle.fill")
                    .font(Theme.heading(18))
                    .foregroundStyle(Theme.correct)
            } else {
                Label("Waiting for a note…", systemImage: "ear")
                    .font(Theme.heading(18))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
    }

    // MARK: Pieces

    private var microphoneStatusText: String {
        switch monitor.microphonePermission {
        case .granted: return "Allowed"
        case .denied: return "Off. Turn it on in the Settings app."
        case .undetermined: return "Not asked yet"
        }
    }

    private func tryItInstructions(for input: InputSourceKind) -> String {
        switch input {
        case .midi: return "Press any key on your MIDI keyboard. It lights up below."
        case .microphone: return "Play any key on your piano at a normal volume. The note you play lights up below."
        case .virtualKeyboard: return "Tap any key below."
        }
    }

    private func feature(icon: String, title: String, text: String) -> some View {
        HStack(alignment: .top, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.heading(18))
                    .foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func permissionCard<Actions: View>(icon: String, title: String, text: String, status: String, statusColor: Color,
                                               @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 44, height: 44)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(Theme.heading(18))
                    .foregroundStyle(Theme.textPrimary)
                Text(text)
                    .font(Theme.body())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(status)
                    .font(Theme.caption())
                    .foregroundStyle(statusColor)
            }
            Spacer(minLength: 12)
            actions()
        }
        .card()
    }
}
