import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

/// The Import tab: three ways to bring sheet music in (files, a link, photos), guidance on where to find free scores,
/// the progress of a running import, and the review screen once a score is ready.
struct ImportHomeView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore

    @State private var pipeline = ImportPipeline()
    @State private var showsFileImporter = false
    @State private var linkText = ""
    @State private var photoItems: [PhotosPickerItem] = []
    @State private var isLoadingPhotos = false
    @State private var apiKeyConfigured = true
    @State private var toast: String?
    @State private var localError: String?
    @State private var showsIncomingPrompt = false
    @FocusState private var linkFieldFocused: Bool

    private var incoming: ImportIncomingFiles { ImportIncomingFiles.shared }

    var body: some View {
        NavigationStack {
            ZStack {
                Theme.background.ignoresSafeArea()
                if pipeline.draft != nil {
                    ImportReviewView(pipeline: pipeline, onSaved: handleSaved)
                } else {
                    home
                }
            }
            .navigationTitle(pipeline.draft == nil ? "Import Sheet Music" : "Review Import")
            .overlay {
                if pipeline.isBusy { progressOverlay }
            }
            .overlay(alignment: .bottom) { toastView }
            .animation(.easeInOut(duration: 0.2), value: pipeline.isBusy)
            .animation(.spring(duration: 0.35), value: toast)
        }
        .fileImporter(isPresented: $showsFileImporter, allowedContentTypes: ImportFileSniffer.allowedContentTypes, allowsMultipleSelection: true) { result in
            switch result {
            case .success(let urls):
                guard !urls.isEmpty else { return }
                prepare()
                pipeline.importFiles(urls)
            case .failure(let error):
                localError = "The files could not be opened: \(error.localizedDescription)"
            }
        }
        .onChange(of: photoItems) { _, items in loadPhotos(items) }
        .task(id: appModel.selectedTab) { refreshConfiguration() }
        .onAppear { consumeIncoming() }
        .onChange(of: incoming.pending) { _, _ in consumeIncoming() }
        .onChange(of: pipeline.phase) { _, _ in
            refreshConfiguration()
            if !pipeline.isBusy, pipeline.draft == nil { consumeIncoming() }
        }
        .confirmationDialog("Import the shared file?", isPresented: $showsIncomingPrompt, titleVisibility: .visible) {
            Button("Import and Discard This Review", role: .destructive) {
                pipeline.discard()
                startIncoming(incoming.takeAll())
            }
            Button("Keep Reviewing", role: .cancel) {}
        } message: {
            Text("A file was shared with LearnPiano while you are reviewing another import. It will wait until you save or discard this one.")
        }
        .alert("Import", isPresented: Binding(get: { localError != nil }, set: { if !$0 { localError = nil } })) {
            Button("OK", role: .cancel) { localError = nil }
        } message: {
            Text(localError ?? "")
        }
    }

    // MARK: Home

    private var home: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                if !apiKeyConfigured { apiKeyBanner }
                statusBanner
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
                    fileCard
                    linkCard
                    photosCard
                }
                sourcesCard
                formatsCard
            }
            .padding(24)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Bring your own music")
                .font(Theme.title())
                .foregroundStyle(Theme.textPrimary)
            Text("Import a score you found online and practice it like any song in the library: with the notation, the keyboard and Wait Mode.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var apiKeyBanner: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: "key.fill")
                .font(.title3)
                .foregroundStyle(Theme.waiting)
            VStack(alignment: .leading, spacing: 2) {
                Text("PDF and photo import needs a Claude API key")
                    .font(Theme.heading(16))
                    .foregroundStyle(Theme.textPrimary)
                Text("MusicXML and MIDI files work without one. Scans and photos are transcribed by Claude, which needs your own Anthropic API key.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Open Settings") { appModel.selectedTab = .settings }
                .buttonStyle(.borderedProminent)
        }
        .padding(Theme.cardPadding)
        .background(Theme.waiting.opacity(0.14), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.waiting.opacity(0.5), lineWidth: 1))
    }

    @ViewBuilder
    private var statusBanner: some View {
        switch pipeline.phase {
        case .failed(let message):
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.title3)
                    .foregroundStyle(Theme.wrong)
                VStack(alignment: .leading, spacing: 4) {
                    Text("The import did not work")
                        .font(Theme.heading(16))
                        .foregroundStyle(Theme.textPrimary)
                    Text(message)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 8)
                Button("Dismiss") { pipeline.reset() }
                    .buttonStyle(.bordered)
            }
            .card()
        case .done(_, let title):
            HStack(spacing: 14) {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title2)
                    .foregroundStyle(Theme.correct)
                VStack(alignment: .leading, spacing: 2) {
                    Text("“\(title)” is in My Songs")
                        .font(Theme.heading(16))
                        .foregroundStyle(Theme.textPrimary)
                    Text("Import another piece below, or open it to start practicing.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer(minLength: 8)
                Button("Open My Songs") { appModel.selectedTab = .mySongs }
                    .buttonStyle(.borderedProminent)
            }
            .card()
        default:
            EmptyView()
        }
    }

    private var fileCard: some View {
        ImportPathCard(systemImage: "folder", title: "Open a file",
                       text: "MusicXML (.musicxml, .mxl) and MIDI import exactly. PDFs and pictures are transcribed; select several images to import them as pages of one piece.") {
            Button {
                showsFileImporter = true
            } label: {
                Label("Choose Files", systemImage: "doc.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pipeline.isBusy)
        }
    }

    private var linkCard: some View {
        ImportPathCard(systemImage: "link", title: "Paste a link",
                       text: "Paste the address of a download link (PDF, MusicXML or MIDI). Dropbox and Google Drive share links work too.") {
            VStack(spacing: 10) {
                TextField("https://…", text: $linkText)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.URL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .submitLabel(.go)
                    .focused($linkFieldFocused)
                    .onSubmit(downloadLink)
                HStack(spacing: 10) {
                    PasteButton(payloadType: String.self) { strings in
                        if let first = strings.first { linkText = first.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.roundedRectangle)
                    Button(action: downloadLink) {
                        Label("Download", systemImage: "arrow.down.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(pipeline.isBusy || linkText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private var photosCard: some View {
        ImportPathCard(systemImage: "photo.on.rectangle", title: "Photos",
                       text: "Pictures of a printed score: photograph each page flat, in good light, with the whole page in view. Pick the pages in order.") {
            PhotosPicker(selection: $photoItems, maxSelectionCount: ImportPageRenderer.maxPages, selectionBehavior: .ordered, matching: .images) {
                Label(isLoadingPhotos ? "Loading Photos…" : "Choose Photos", systemImage: "photo.badge.plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(pipeline.isBusy || isLoadingPhotos)
        }
    }

    private var sourcesCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Where to find free sheet music")
                .font(Theme.heading())
                .foregroundStyle(Theme.textPrimary)
            ImportSourceRow(name: "IMSLP – Petrucci Music Library", address: "https://imslp.org",
                            detail: "The largest library of public-domain classical scores, mostly as scanned PDFs. Choose a clean, modern edition for the best transcription.")
            Divider()
            ImportSourceRow(name: "MuseScore", address: "https://musescore.com/sheetmusic/public-domain",
                            detail: "Community scores. Filter for public domain; where a download as MusicXML or MIDI is offered, use it instead of the PDF.")
            Divider()
            ImportSourceRow(name: "Mutopia Project", address: "https://www.mutopiaproject.org",
                            detail: "Free, cleanly engraved editions of public-domain music with PDF and MIDI downloads.")
            Text("Only import music that is in the public domain, freely licensed, or that you otherwise have the right to use.")
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 4)
        }
        .card()
    }

    private var formatsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("What works best")
                .font(Theme.heading())
                .foregroundStyle(Theme.textPrimary)
            ImportTipRow(systemImage: "checkmark.seal", text: "MusicXML and MIDI files import in seconds and exactly as written.")
            ImportTipRow(systemImage: "sparkles", text: "PDFs and photos are transcribed by Claude page by page, about a minute per page. Check the result: low-confidence measures are marked for review.")
            ImportTipRow(systemImage: "square.and.arrow.down", text: "From Safari, Files or Mail you can also use Share → Open in LearnPiano.")
        }
        .card()
    }

    // MARK: Progress and toast

    private var progressOverlay: some View {
        ZStack {
            Color.black.opacity(0.18).ignoresSafeArea()
            VStack(spacing: 16) {
                if let fraction = pipeline.progressFraction {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear)
                        .tint(Theme.accent)
                } else {
                    ProgressView()
                        .controlSize(.large)
                }
                Text(pipeline.statusText)
                    .font(Theme.heading(17))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                if case .transcribing(let page, let total, _) = pipeline.phase {
                    Text("Page \(page) of \(total) · a dense page can take a couple of minutes")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                        .multilineTextAlignment(.center)
                }
                Button("Cancel", role: .cancel) { pipeline.cancel() }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: 420)
            .card()
            .padding(24)
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Label(toast, systemImage: "checkmark.circle.fill")
                .font(Theme.heading(16))
                .foregroundStyle(.white)
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
                .background(Theme.correct, in: Capsule())
                .shadow(color: .black.opacity(0.15), radius: 10, y: 4)
                .padding(.bottom, 32)
                .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    // MARK: Actions

    /// Settings the pipeline reads at the start of an import.
    private func prepare() {
        pipeline.transcriptionModel = profileStore.settings.transcriptionModel
        refreshConfiguration()
    }

    private func refreshConfiguration() {
        apiKeyConfigured = ImportClaudeTranscriptionProvider.isConfigured
    }

    private func downloadLink() {
        let text = linkText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !pipeline.isBusy else { return }
        linkFieldFocused = false
        prepare()
        pipeline.importLink(text)
    }

    private func loadPhotos(_ items: [PhotosPickerItem]) {
        guard !items.isEmpty else { return }
        isLoadingPhotos = true
        Task {
            var images: [Data] = []
            var failed = 0
            for item in items {
                do {
                    if let data = try await item.loadTransferable(type: Data.self) { images.append(data) } else { failed += 1 }
                } catch {
                    failed += 1
                    NSLog("ImportHomeView: loading a photo failed: \(error.localizedDescription)")
                }
            }
            isLoadingPhotos = false
            photoItems = []
            guard !images.isEmpty else {
                localError = "The selected photos could not be loaded. If they are in iCloud, wait until they are downloaded and try again."
                return
            }
            if failed > 0 { localError = "\(failed) of the selected photos could not be loaded; the others are being imported." }
            prepare()
            pipeline.importImages(images)
        }
    }

    private func consumeIncoming() {
        guard !incoming.pending.isEmpty, !pipeline.isBusy else { return }
        if pipeline.draft != nil {
            showsIncomingPrompt = true
            return
        }
        startIncoming(incoming.takeAll())
    }

    private func startIncoming(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        prepare()
        let files = urls.filter { $0.isFileURL }
        if !files.isEmpty {
            pipeline.importFiles(files)
        } else if let link = urls.first {
            linkText = link.absoluteString
            pipeline.importLink(link.absoluteString)
        }
    }

    private func handleSaved(_ entry: SongEntry) {
        toast = "Saved “\(entry.title)” to My Songs"
        Task {
            try? await Task.sleep(nanoseconds: 1_300_000_000)
            appModel.selectedTab = .mySongs
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            toast = nil
        }
    }
}

// MARK: - Building blocks

/// One of the three import paths.
struct ImportPathCard<Content: View>: View {
    let systemImage: String
    let title: String
    let text: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: systemImage)
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .frame(width: 52, height: 52)
                .background(Theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            Text(title)
                .font(Theme.heading())
                .foregroundStyle(Theme.textPrimary)
            Text(text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            content
        }
        .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
        .card()
    }
}

/// A free sheet-music site with a link.
struct ImportSourceRow: View {
    let name: String
    let address: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "books.vertical")
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 3) {
                if let url = URL(string: address) {
                    Link(destination: url) {
                        HStack(spacing: 4) {
                            Text(name).font(Theme.heading(16))
                            Image(systemName: "arrow.up.right.square").font(.footnote)
                        }
                    }
                } else {
                    Text(name).font(Theme.heading(16)).foregroundStyle(Theme.textPrimary)
                }
                Text(detail)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct ImportTipRow: View {
    let systemImage: String
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: systemImage)
                .foregroundStyle(Theme.accent)
                .frame(width: 24)
            Text(text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
