import Foundation
import Observation
import UIKit

/// An imported score waiting in the review screen.
struct ImportDraft: Identifiable {
    let id = UUID()
    var score: Score
    /// Importer/transcription diagnostics, validation results and repairs (measure indices into `score`).
    var diagnostics: [ScoreDiagnostic]
    /// Per-measure transcription confidence (empty for MusicXML/MIDI imports).
    var confidence: [Double?]
    var kind: ImportFileKind
    var sourceName: String
    /// Set for PDF/picture imports; keeps the pages so a single page can be re-transcribed.
    var transcription: ImportTranscription?
    /// Small previews of the pages (sheet imports only).
    var thumbnails: [UIImage]

    var isTranscription: Bool { transcription != nil }
    var pageCount: Int { transcription?.pages.count ?? 0 }
    /// Merged measure indices per page.
    var pageRanges: [Range<Int>] { transcription?.merged.partRanges ?? [] }

    /// 0-based page holding a measure.
    func page(ofMeasure index: Int) -> Int? { pageRanges.firstIndex { $0.contains(index) } }

    var errorCount: Int { diagnostics.filter { $0.severity == .error }.count }
    var warningCount: Int { diagnostics.filter { $0.severity == .warning }.count }

    /// Measures below the low-confidence threshold.
    var lowConfidenceMeasures: [Int] {
        confidence.indices.filter { ImportPageMerger.level(confidence[$0]) == .low }
    }

    /// Mean stated confidence of a page's measures.
    func averageConfidence(ofPage page: Int) -> Double? {
        guard pageRanges.indices.contains(page) else { return nil }
        let values = pageRanges[page].compactMap { confidence.indices.contains($0) ? confidence[$0] : nil }
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }
}

/// Drives one import: idle → reading → transcribing(page i of n) → validating → review → saving → done / failed.
/// Owned by `ImportHomeView`; heavy work (file reading, parsing, rendering, network) runs off the main actor.
@MainActor
@Observable
final class ImportPipeline {
    enum Phase: Equatable {
        case idle
        case reading(String)
        case transcribing(page: Int, of: Int, message: String)
        case validating
        case review
        case saving
        case done(songID: String, title: String)
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var draft: ImportDraft?
    /// A problem met while a draft stays open (failed re-transcription or save); shown as an alert.
    var reviewError: String?

    // Editable metadata for the review screen.
    var title = ""
    var composer = ""
    var genre = ImportPipeline.otherGenre
    var difficulty: Difficulty = .beginner
    var descriptionText = ""

    /// Model id for PDF/picture transcription (`UserSettings.transcriptionModel`); set by the view before an import.
    var transcriptionModel = ImportClaudeRequestBuilder.defaultModel

    static let otherGenre = "Other"

    @ObservationIgnored var makeProvider: (String) -> ImportClaudeTranscriptionProvider
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var runID = 0

    init(makeProvider: @escaping (String) -> ImportClaudeTranscriptionProvider = { ImportClaudeTranscriptionProvider(model: $0) }) {
        self.makeProvider = makeProvider
    }

    var isBusy: Bool {
        switch phase {
        case .reading, .transcribing, .validating, .saving: return true
        case .idle, .review, .done, .failed: return false
        }
    }

    /// Progress 0…1 for page-wise transcription, nil when indeterminate.
    var progressFraction: Double? {
        if case .transcribing(let page, let total, _) = phase, total > 0 { return Double(max(0, page - 1)) / Double(total) }
        return nil
    }

    var statusText: String {
        switch phase {
        case .idle: return ""
        case .reading(let name): return "Opening \(name)…"
        case .transcribing(let page, let total, let message): return message.isEmpty ? "Transcribing page \(page) of \(total)…" : message
        case .validating: return "Checking the score…"
        case .review: return "Ready for review"
        case .saving: return "Saving…"
        case .done(_, let title): return "Saved “\(title)”"
        case .failed(let message): return message
        }
    }

    // MARK: Starting imports

    /// Files from the Files picker or the system (one MusicXML/MXL/MIDI file, or PDFs and pictures as pages).
    func importFiles(_ urls: [URL]) {
        guard !urls.isEmpty else { return }
        let label = urls.count == 1 ? urls[0].lastPathComponent : "\(urls.count) files"
        start(label: label) { pipeline in
            var files: [ImportLoadedFile] = []
            for url in urls {
                try Task.checkCancellation()
                files.append(try await ImportFileLoader.load(url: url))
            }
            try await pipeline.process(files)
        }
    }

    /// A pasted link: downloaded to a temporary file, then imported like a file.
    func importLink(_ text: String) {
        guard let url = ImportLinkNormalizer.url(from: text) else {
            cancelRunning()
            draft = nil
            phase = .failed("That does not look like a web address. Paste a link that starts with https://")
            return
        }
        start(label: url.host ?? url.absoluteString) { pipeline in
            let file = try await ImportFileLoader.download(url)
            try await pipeline.process([file])
        }
    }

    /// Pictures from the photo library (each one is a page, in selection order).
    func importImages(_ images: [Data]) {
        guard !images.isEmpty else { return }
        start(label: images.count == 1 ? "1 photo" : "\(images.count) photos") { pipeline in
            var files: [ImportLoadedFile] = []
            for (i, data) in images.enumerated() {
                files.append(try ImportFileLoader.identify(data: data, fileName: "Photo \(i + 1)", mimeType: "image/*"))
            }
            try await pipeline.process(files)
        }
    }

    /// Re-runs the transcription of one page of the current draft.
    func retranscribe(page index: Int) {
        guard let draft, let transcription = draft.transcription, transcription.pages.indices.contains(index), !isBusy else { return }
        let provider = makeProvider(transcriptionModel)
        guard provider.isConfigured else {
            reviewError = "Re-transcribing needs a Claude API key. Add one in Settings."
            return
        }
        let total = transcription.pages.count
        cancelRunning()
        runID += 1
        let id = runID
        phase = .transcribing(page: index + 1, of: total, message: "Reading page \(index + 1) of \(total) again…")
        task = Task { [weak self] in
            do {
                let updated = try await provider.retranscribe(pageAt: index, in: transcription) { progress in
                    Task { @MainActor [weak self] in self?.apply(progress, page: index + 1, total: total, runID: id) }
                }
                guard let self, id == self.runID else { return }
                try await self.finish(result: updated.importResult, kind: draft.kind, sourceName: draft.sourceName,
                                      transcription: updated, thumbnails: draft.thumbnails, keepsMetadata: true, runID: id)
            } catch {
                guard let self, id == self.runID else { return }
                self.handle(error, keepingDraft: true)
            }
            if let self, id == self.runID { self.task = nil }
        }
    }

    /// Stops the running step. A first import returns to idle; a re-transcription returns to the review.
    func cancel() {
        guard isBusy else { return }
        cancelRunning()
        phase = draft == nil ? .idle : .review
    }

    /// Drops the draft and returns to the start.
    func discard() {
        cancelRunning()
        draft = nil
        reviewError = nil
        phase = .idle
    }

    /// Clears a failure or the "done" state.
    func reset() {
        guard !isBusy else { return }
        if draft == nil { phase = .idle } else { phase = .review }
    }

    // MARK: Saving

    /// Saves the reviewed score as a user song. Returns the new entry, or nil (with `reviewError` set) on failure.
    @discardableResult
    func save(to store: ContentStore) -> SongEntry? {
        guard let draft, !isBusy else { return nil }
        phase = .saving
        var score = draft.score
        score.metadata.sourceFileName = draft.sourceName
        if score.metadata.notes.isEmpty, let model = draft.transcription?.model {
            score.metadata.notes = "Transcribed from \(draft.sourceName) with \(model)."
        }
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanGenre = genre.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let entry = try store.addUserSong(score: score, title: cleanTitle.isEmpty ? "Untitled" : cleanTitle,
                                              composer: composer.trimmingCharacters(in: .whitespacesAndNewlines),
                                              genre: cleanGenre.isEmpty ? ImportPipeline.otherGenre : cleanGenre,
                                              difficulty: difficulty,
                                              description: descriptionText.trimmingCharacters(in: .whitespacesAndNewlines))
            self.draft = nil
            phase = .done(songID: entry.id, title: entry.title)
            return entry
        } catch {
            phase = .review
            reviewError = "The song could not be saved: \(error.localizedDescription)"
            return nil
        }
    }

    // MARK: Running

    private func cancelRunning() {
        task?.cancel()
        task = nil
        runID += 1
    }

    private func start(label: String, _ work: @escaping (ImportPipeline) async throws -> Void) {
        cancelRunning()
        let id = runID
        draft = nil
        reviewError = nil
        phase = .reading(label)
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try await work(self)
            } catch {
                if id == self.runID { self.handle(error, keepingDraft: false) }
            }
            if id == self.runID { self.task = nil }
        }
    }

    /// Imports loaded files: one symbolic file directly, sheets through the transcription provider.
    private func process(_ files: [ImportLoadedFile]) async throws {
        let id = runID
        if let other = files.first(where: { !$0.kind.isSymbolic && !$0.kind.isSheet }) {
            throw ImportError.unsupportedFormat(other.kind.displayName)
        }
        let symbolic = files.filter { $0.kind.isSymbolic }
        if let file = symbolic.first {
            guard files.count == 1 else {
                throw ImportError.unsupportedFormat("several files at once. Choose one MusicXML or MIDI file, or one or more PDF and picture pages")
            }
            phase = .reading(file.fileName)
            let result = try await ImportFileLoader.parseSymbolic(file)
            try Task.checkCancellation()
            try await finish(result: result, kind: file.kind, sourceName: file.fileName, transcription: nil, thumbnails: [], keepsMetadata: false, runID: id)
            return
        }

        let sourceName = files.count == 1 ? (files.first?.fileName ?? "pages") : "\(files.count) files"
        let kind: ImportFileKind = files.contains { $0.kind == .pdf } ? .pdf : .image
        let provider = makeProvider(transcriptionModel)
        guard provider.isConfigured else {
            throw ImportError.provider("PDF and picture import needs a Claude API key. Add one in Settings, then try again.")
        }
        phase = .reading(sourceName)
        let pages = try await ImportFileLoader.renderPages(files)
        try Task.checkCancellation()
        guard id == runID else { return }
        phase = .transcribing(page: 1, of: pages.count, message: "Reading page 1 of \(pages.count)…")
        let total = pages.count
        let transcription = try await provider.transcribeDocument(pages: pages, hint: nil) { progress in
            Task { @MainActor [weak self] in self?.apply(progress, page: min(progress.pagesDone + 1, total), total: total, runID: id) }
        }
        try Task.checkCancellation()
        let thumbnails = await ImportFileLoader.thumbnails(pages)
        try await finish(result: transcription.importResult, kind: kind, sourceName: sourceName, transcription: transcription,
                         thumbnails: thumbnails, keepsMetadata: false, runID: id)
    }

    private func apply(_ progress: TranscriptionProgress, page: Int, total: Int, runID id: Int) {
        guard id == runID, case .transcribing = phase else { return }
        phase = .transcribing(page: page, of: total, message: progress.message)
    }

    /// Validation + repair, then the review.
    private func finish(result: ImportResult, kind: ImportFileKind, sourceName: String, transcription: ImportTranscription?,
                        thumbnails: [UIImage], keepsMetadata: Bool, runID id: Int) async throws {
        guard id == runID else { return }
        phase = .validating
        let validated = try await ImportFileLoader.finalize(result)
        try Task.checkCancellation()
        guard id == runID else { return }
        let confidence = transcription.map {
            ImportPageMerger.markingErrors($0.merged.confidence, errors: validated.remainingErrors, measureCount: validated.score.measures.count)
        } ?? []
        draft = ImportDraft(score: validated.score, diagnostics: validated.diagnostics, confidence: confidence, kind: kind,
                            sourceName: sourceName, transcription: transcription, thumbnails: thumbnails)
        if !keepsMetadata { seedMetadata(from: validated.score, sourceName: sourceName) }
        phase = .review
    }

    private func seedMetadata(from score: Score, sourceName: String) {
        let t = score.metadata.title.trimmingCharacters(in: .whitespacesAndNewlines)
        title = t.isEmpty ? ((sourceName as NSString).deletingPathExtension) : t
        composer = score.metadata.composer
        let g = score.metadata.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        genre = g.isEmpty ? ImportPipeline.otherGenre : g
        difficulty = score.metadata.difficulty ?? ImportDifficultyEstimator.estimate(score)
        descriptionText = ""
    }

    private func handle(_ error: Error, keepingDraft: Bool) {
        let normalized = ImportClaudeTranscriptionProvider.normalized(error)
        if let importError = normalized as? ImportError, importError == .cancelled {
            phase = draft == nil ? .idle : .review
            return
        }
        let message = (normalized as? LocalizedError)?.errorDescription ?? normalized.localizedDescription
        if keepingDraft, draft != nil {
            reviewError = message
            phase = .review
        } else {
            draft = nil
            phase = .failed(message)
        }
    }
}
