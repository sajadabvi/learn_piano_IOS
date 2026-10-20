import SwiftUI

/// The Settings tab: instrument and input, practice defaults, sheet import (Claude API), sound, library and about.
/// Everything persists through `ProfileStore.settings` except the API key (Keychain) and master volume
/// (`SettingsAudioPreferences`).
struct SettingsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore

    var body: some View {
        NavigationStack {
            SettingsForm(viewModel: SettingsViewModel(store: profileStore))
                .navigationTitle("Settings")
        }
        .settingsInputMonitoring(active: appModel.activePractice == nil)
    }
}

/// The form itself. `SettingsViewModel` is stateless (it reads and writes the store), so recreating it per body is cheap.
private struct SettingsForm: View {
    @Bindable var viewModel: SettingsViewModel
    @Environment(ContentStore.self) private var contentStore
    @State private var monitor = SettingsInputMonitor.shared
    @State private var apiKey = SettingsAPIKeyModel()
    @State private var isPairing = false
    @State private var isTestingSetup = false
    @State private var isConfirmingReset = false
    @State private var resetDone = false
    @State private var libraryBytes: Int64?
    @State private var masterVolume = SettingsAudioPreferences.masterVolume

    var body: some View {
        Form {
            inputSection
            practiceSection
            importSection
            soundSection
            librarySection
            aboutSection
        }
        .scrollContentBackground(.hidden)
        .background(Theme.background)
        .sheet(isPresented: $isPairing, onDismiss: { monitor.refreshMIDIDevices() }) {
            InputBluetoothMIDIPairingView { isPairing = false }
        }
        .sheet(isPresented: $isTestingSetup) {
            SettingsSetupTestSheet(monitor: monitor)
        }
        .task {
            apiKey.load()
            await refreshLibrarySize()
        }
        .onChange(of: contentStore.userSongs.count) { _, _ in
            Task { await refreshLibrarySize() }
        }
    }

    // MARK: Instrument & input

    private var inputSection: some View {
        Section {
            Picker("Play with", selection: $viewModel.preferredInput) {
                ForEach(InputSourceKind.allCases, id: \.self) { kind in
                    Label(kind.displayName, systemImage: SettingsInputChoiceCards.icon(for: kind)).tag(kind)
                }
            }
            SettingsInputStatusView(monitor: monitor, preferredInput: viewModel.preferredInput)
            Button {
                isPairing = true
            } label: {
                Label("Pair a Bluetooth MIDI keyboard", systemImage: "dot.radiowaves.left.and.right")
            }
            if viewModel.preferredInput == .microphone {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Microphone sensitivity")
                        Spacer()
                        Text(SettingsViewModel.sensitivityLabel(viewModel.microphoneSensitivity))
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Slider(value: $viewModel.microphoneSensitivity, in: SettingsViewModel.sensitivityRange) {
                        Text("Microphone sensitivity")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.wave.1")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                    Text("Higher hears quieter notes but may pick up extra ones.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            HStack {
                Stepper(value: $viewModel.a4Hertz, in: SettingsViewModel.a4Range, step: 1) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Tuning (A4)")
                        Text(SettingsViewModel.a4Label(viewModel.a4Hertz) + (viewModel.a4Hertz == SettingsViewModel.a4Default ? " · standard" : ""))
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            HStack(spacing: 16) {
                Button {
                    monitor.playA4()
                } label: {
                    Label("Play A4", systemImage: "speaker.wave.2.fill")
                }
                .buttonStyle(.bordered)
                if viewModel.a4Hertz != SettingsViewModel.a4Default {
                    Button("Reset to 440 Hz") { viewModel.resetA4() }
                        .buttonStyle(.borderless)
                }
                Spacer()
            }
            Button {
                isTestingSetup = true
            } label: {
                HStack {
                    Label("Test your setup", systemImage: "waveform.and.magnifyingglass")
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        } header: {
            Text("Instrument & input")
        } footer: {
            Text("Match the tuning to your piano if it is not tuned to A = 440 Hz; detection then follows it.")
        }
    }

    // MARK: Practice defaults

    private var practiceSection: some View {
        Section {
            Picker("Mode", selection: $viewModel.defaultMode) {
                ForEach(PracticeMode.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Hands", selection: $viewModel.defaultHands) {
                ForEach(HandSelection.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Picker("Speed", selection: $viewModel.defaultSpeed) {
                ForEach(PracticeSpeed.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            Stepper(value: $viewModel.countInMeasures, in: SettingsViewModel.countInRange) {
                HStack {
                    Text("Count-in")
                    Spacer()
                    Text(SettingsViewModel.countInLabel(viewModel.countInMeasures))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            Toggle("Play the other hand for me", isOn: $viewModel.playOtherHands)
            Toggle("Accept any octave", isOn: $viewModel.octaveTolerance)
            Toggle("Metronome", isOn: $viewModel.metronome)
            Toggle("Show note names", isOn: $viewModel.showNoteNames)
            Toggle("Show falling notes", isOn: $viewModel.showFallingNotes)
        } header: {
            Text("Practice defaults")
        } footer: {
            Text("New practice sessions start with these settings; you can still change them on the practice screen. “Accept any octave” helps on small keyboards.")
        }
    }

    // MARK: Sheet import

    private var importSection: some View {
        Section {
            if let mask = apiKey.savedKeyMask {
                HStack {
                    Label("API key saved", systemImage: "key.fill")
                        .foregroundStyle(Theme.textPrimary)
                    Spacer()
                    Text(mask)
                        .font(Theme.body().monospaced())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            SecureField(apiKey.hasSavedKey ? "Paste a new key to replace it" : "Anthropic API key (sk-ant-…)", text: $apiKey.draft)
                .textContentType(.password)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .onSubmit { apiKey.save() }
            if let warning = apiKey.draftWarning {
                Text(warning)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.waiting)
            }
            HStack(spacing: 12) {
                Button("Save key") { apiKey.save() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!apiKey.canSave)
                Button {
                    apiKey.test(model: viewModel.transcriptionModel.rawValue)
                } label: {
                    if apiKey.isTesting {
                        ProgressView()
                    } else {
                        Text("Test key")
                    }
                }
                .buttonStyle(.bordered)
                .disabled(apiKey.isTesting || !(apiKey.hasSavedKey || apiKey.canSave))
                Spacer()
                if apiKey.hasSavedKey {
                    Button("Remove", role: .destructive) { apiKey.remove() }
                        .buttonStyle(.borderless)
                }
            }
            if let result = apiKey.testResult {
                Label(result.message, systemImage: result.isSuccess ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(Theme.caption(14))
                    .foregroundStyle(result.isSuccess ? Theme.correct : Theme.wrong)
            }
            if let error = apiKey.keychainError {
                Text(error)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.wrong)
            }
            Picker("Model", selection: $viewModel.transcriptionModel) {
                ForEach(SettingsTranscriptionModel.allCases) { model in
                    Text(model.displayName).tag(model)
                }
            }
            Text(viewModel.transcriptionModel.detail)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                Label("Privacy", systemImage: "lock.shield")
                    .font(Theme.heading(15))
                Text("Your key is stored in the iPad’s Keychain and never leaves the device except in requests to Anthropic. Page images are sent to Anthropic only when you import a PDF or image; MusicXML and MIDI files are read on the iPad and never uploaded.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                Label("Cost", systemImage: "creditcard")
                    .font(Theme.heading(15))
                    .padding(.top, 4)
                Text("Transcription is billed to your Anthropic account by tokens. A typical page costs a few cents with Opus 5.5 and up to roughly $0.30 for a dense page that needs repair passes; Sonnet 5.5 costs about half. Testing the key costs a fraction of a cent.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            .padding(.vertical, 4)
        } header: {
            Text("Sheet import (Claude API)")
        } footer: {
            Text("Needed only to import PDFs and photos of sheet music. Create a key at console.anthropic.com.")
        }
    }

    // MARK: Sound

    private var soundSection: some View {
        Section {
            HStack(alignment: .top) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(monitor.soundSourceDescription)
                        Text(monitor.soundSourceDetail)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                } icon: {
                    Image(systemName: "pianokeys.inverse")
                }
                Spacer()
                Button("Rescan") { monitor.refreshSoundFonts() }
                    .buttonStyle(.borderless)
            }
            if let error = monitor.soundError {
                Text(error)
                    .font(Theme.caption())
                    .foregroundStyle(Theme.wrong)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Use your own piano sound")
                    .font(Theme.body())
                Text("Open the Files app, go to On My iPad › LearnPiano › SoundFonts, and drop a piano .sf2 SoundFont there. The first file (alphabetically) is used the next time the piano starts; tap Rescan to check.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Master volume")
                    Spacer()
                    Text("\(Int((masterVolume * 100).rounded())) %")
                        .foregroundStyle(Theme.textSecondary)
                        .monospacedDigit()
                }
                Slider(value: $masterVolume, in: 0...1) {
                    Text("Master volume")
                } minimumValueLabel: {
                    Image(systemName: "speaker.fill")
                } maximumValueLabel: {
                    Image(systemName: "speaker.wave.3.fill")
                } onEditingChanged: { editing in
                    if !editing { monitor.playA4(seconds: 0.6) }
                }
                .onChange(of: masterVolume) { _, value in monitor.setMasterVolume(value) }
            }
        } header: {
            Text("Sound")
        }
    }

    // MARK: Library

    private var librarySection: some View {
        Section {
            HStack {
                Label("Imported songs", systemImage: "music.note.list")
                Spacer()
                Text("\(contentStore.userSongs.count)")
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack {
                Label("Storage used", systemImage: "internaldrive")
                Spacer()
                if let bytes = libraryBytes {
                    Text(SettingsFormatting.byteCount(bytes))
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ProgressView()
                }
            }
            if !contentStore.loadErrors.isEmpty {
                DisclosureGroup("\(contentStore.loadErrors.count) song file\(contentStore.loadErrors.count == 1 ? "" : "s") could not be loaded") {
                    ForEach(contentStore.loadErrors, id: \.self) { error in
                        Text(error)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .foregroundStyle(Theme.wrong)
            }
            Button {
                viewModel.replayOnboarding()
            } label: {
                Label("Replay onboarding", systemImage: "sparkles")
            }
            Button(role: .destructive) {
                isConfirmingReset = true
            } label: {
                Label(resetDone ? "Progress was reset" : "Reset progress", systemImage: "arrow.counterclockwise")
            }
            .confirmationDialog("Reset all progress?", isPresented: $isConfirmingReset, titleVisibility: .visible) {
                Button("Reset progress", role: .destructive) {
                    viewModel.resetProgress()
                    resetDone = true
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This erases \(viewModel.progressSummary). Your settings and imported songs are kept. This cannot be undone.")
            }
        } header: {
            Text("Library")
        }
    }

    // MARK: About

    private var aboutSection: some View {
        Section {
            HStack {
                Label("LearnPiano", systemImage: "info.circle")
                Spacer()
                Text(SettingsFormatting.versionString(info: Bundle.main.infoDictionary))
                    .foregroundStyle(Theme.textSecondary)
            }
            NavigationLink {
                SettingsLicensesView()
            } label: {
                Label("Licenses", systemImage: "doc.text")
            }
            if let url = SettingsAbout.repositoryURL {
                Link(destination: url) {
                    HStack {
                        Label("Source code on GitHub", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Image(systemName: "arrow.up.right.square")
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
        } header: {
            Text("About")
        }
    }

    // MARK: Helpers

    private func refreshLibrarySize() async {
        let directory = ContentStore.defaultLibraryDirectory
        let bytes = await Task.detached(priority: .utility) {
            SettingsFormatting.directorySize(at: directory)
        }.value
        libraryBytes = bytes
    }
}
