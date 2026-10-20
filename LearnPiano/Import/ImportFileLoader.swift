import Foundation
import UIKit

/// Bytes of one source file with the kind sniffed from its content.
struct ImportLoadedFile: Sendable {
    var data: Data
    var fileName: String
    var kind: ImportFileKind
}

/// File access, link downloads, symbolic parsing and page rendering. Every function is `async` and nonisolated, so
/// calls from the main actor run on the cooperative pool and still inherit cancellation.
enum ImportFileLoader {
    /// Larger files are refused (sheet music is rarely over a few MB).
    static let maxBytes = 100 * 1024 * 1024

    // MARK: Local files

    /// Reads a file from the Files picker or "Open in LearnPiano" (security-scoped, possibly in iCloud).
    static func load(url: URL) async throws -> ImportLoadedFile {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var coordinationError: NSError?
        var outcome: Result<Data, Error> = .failure(ImportError.malformed("\(url.lastPathComponent) could not be read."))
        NSFileCoordinator().coordinate(readingItemAt: url, options: [.withoutChanges], error: &coordinationError) { readURL in
            outcome = Result {
                if let size = try readURL.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                    throw ImportError.unsupportedFormat("\(readURL.lastPathComponent) is larger than 100 MB")
                }
                return try Data(contentsOf: readURL, options: .mappedIfSafe)
            }
        }
        if let coordinationError { throw ImportError.malformed("\(url.lastPathComponent): \(coordinationError.localizedDescription)") }
        let data: Data
        switch outcome {
        case .success(let d): data = d
        case .failure(let error as ImportError): throw error
        case .failure(let error): throw ImportError.malformed("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        removeInboxCopy(url)
        return try identify(data: data, fileName: url.lastPathComponent, mimeType: nil)
    }

    /// Files handed over with "Open in" are copied into Documents/Inbox; they are ours to delete once read.
    private static func removeInboxCopy(_ url: URL) {
        guard url.isFileURL, url.standardizedFileURL.path.contains("/Documents/Inbox/") else { return }
        do { try FileManager.default.removeItem(at: url) } catch {
            NSLog("ImportFileLoader: could not remove the inbox copy \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// Sniffs the kind; web pages and unknown formats become readable errors.
    static func identify(data: Data, fileName: String, mimeType: String?) throws -> ImportLoadedFile {
        guard !data.isEmpty else { throw ImportError.malformed("\(fileName) is empty.") }
        guard let kind = ImportFileSniffer.kind(data: data, fileName: fileName, mimeType: mimeType) else {
            let ext = (fileName as NSString).pathExtension
            throw ImportError.unsupportedFormat(ext.isEmpty ? fileName : ".\(ext) — LearnPiano reads MusicXML, MXL, MIDI, PDF and pictures")
        }
        if kind == .webPage {
            throw ImportError.unsupportedFormat("the link opens a web page, not a file. On the site, copy the address of the download link of the PDF, MusicXML or MIDI file instead")
        }
        return ImportLoadedFile(data: data, fileName: fileName, kind: kind)
    }

    // MARK: Links

    /// Downloads a link to a temporary file with URLSession, then sniffs it.
    static func download(_ url: URL, session: URLSession = .shared) async throws -> ImportLoadedFile {
        var request = URLRequest(url: url, timeoutInterval: 90)
        request.setValue("LearnPiano/1.0 (iPad; sheet music import)", forHTTPHeaderField: "User-Agent")
        let tempURL: URL
        let response: URLResponse
        do {
            (tempURL, response) = try await session.download(for: request)
        } catch let error as URLError {
            if error.code == .cancelled { throw ImportError.cancelled }
            throw ImportError.network(readable(error))
        }
        guard let http = response as? HTTPURLResponse else { throw ImportError.network("The server did not send an HTTP response.") }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LearnPianoImport", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let local = folder.appendingPathComponent("download")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: tempURL, to: local)
        } catch {
            throw ImportError.network("The download could not be stored: \(error.localizedDescription)")
        }
        defer {
            do { try FileManager.default.removeItem(at: folder) } catch {
                NSLog("ImportFileLoader: could not remove the temporary download: \(error.localizedDescription)")
            }
        }
        guard (200..<300).contains(http.statusCode) else {
            throw ImportError.network(http.statusCode == 404 ? "Nothing was found at that link (HTTP 404)." : "The server answered with HTTP \(http.statusCode).")
        }
        let data: Data
        do {
            if let size = try local.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
                throw ImportError.unsupportedFormat("the download is larger than 100 MB")
            }
            data = try Data(contentsOf: local)
        } catch let error as ImportError {
            throw error
        } catch {
            throw ImportError.network("The download could not be read: \(error.localizedDescription)")
        }
        let sniffed = ImportFileSniffer.kind(data: data, fileName: response.suggestedFilename ?? url.lastPathComponent, mimeType: http.mimeType)
        let name = ImportFileSniffer.fileName(suggested: response.suggestedFilename, url: http.url ?? url, kind: sniffed)
        return try identify(data: data, fileName: name, mimeType: http.mimeType)
    }

    static func readable(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "The iPad is offline. Connect to the internet and try again."
        case .timedOut: return "The server did not answer in time."
        case .cannotFindHost, .dnsLookupFailed: return "That web address could not be found."
        case .cannotConnectToHost: return "Could not connect to the server."
        case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate: return "A secure connection to the server could not be made."
        case .badURL, .unsupportedURL: return "That link is not a valid web address."
        default: return error.localizedDescription
        }
    }

    // MARK: Parsing and rendering

    /// MusicXML / MXL / MIDI / LPC through the Parsers importers.
    static func parseSymbolic(_ file: ImportLoadedFile) async throws -> ImportResult {
        var result: ImportResult
        switch file.kind {
        case .musicXML, .compressedMusicXML:
            result = try ParsersMusicXMLImporter().importScore(data: file.data, fileName: file.fileName)
            result.score.metadata.source = .musicXML
        case .midi:
            result = try ParsersMIDIImporter().importScore(data: file.data, fileName: file.fileName)
            result.score.metadata.source = .midi
        case .compactScore:
            result = try ParsersCompactScoreImporter().importScore(data: file.data, fileName: file.fileName)
            result.score.metadata.source = .compactJSON
        case .pdf, .image, .webPage:
            throw ImportError.unsupportedFormat(file.kind.displayName)
        }
        result.score.metadata.sourceFileName = file.fileName
        return result
    }

    /// PDF pages and pictures, in order, as PNG pages.
    static func renderPages(_ files: [ImportLoadedFile]) async throws -> [SheetPage] {
        var pages: [SheetPage] = []
        for file in files {
            try Task.checkCancellation()
            switch file.kind {
            case .pdf:
                pages += try ImportPageRenderer.renderPDF(data: file.data, firstIndex: pages.count, isCancelled: { Task.isCancelled })
            case .image:
                pages.append(try ImportPageRenderer.renderImage(data: file.data, index: pages.count))
            default:
                throw ImportError.unsupportedFormat(file.kind.displayName)
            }
        }
        guard pages.count <= ImportPageRenderer.maxPages else {
            throw ImportError.unsupportedFormat("\(pages.count) pages; LearnPiano transcribes up to \(ImportPageRenderer.maxPages) pages at a time")
        }
        return pages
    }

    static func thumbnails(_ pages: [SheetPage]) async -> [UIImage] {
        pages.compactMap { ImportPageRenderer.thumbnail($0) }
    }

    /// Repairs what can be fixed mechanically and collects every diagnostic for the review screen.
    static func finalize(_ result: ImportResult) async throws -> ImportValidatedScore {
        let repaired = ScoreValidator.repair(result.score)
        let remaining = ScoreValidator.validate(repaired.score)
        guard repaired.score.hasNotes(for: .right) || repaired.score.hasNotes(for: .left) else { throw ImportError.empty }
        return ImportValidatedScore(score: repaired.score, diagnostics: ImportDiagnostics.combine(imported: result.diagnostics, validation: remaining, repairs: repaired.changes),
                                    remainingErrors: remaining.filter { $0.severity == .error })
    }
}

/// A score after `ScoreValidator.repair` with all diagnostics.
struct ImportValidatedScore: Sendable {
    var score: Score
    var diagnostics: [ScoreDiagnostic]
    var remainingErrors: [ScoreDiagnostic]
}

/// Diagnostic bookkeeping for the review list.
enum ImportDiagnostics {
    /// Importer/transcription messages, then structural validation, then repairs; duplicates removed; sorted by measure
    /// (whole-score messages first), then severity (errors first).
    static func combine(imported: [ScoreDiagnostic], validation: [ScoreDiagnostic], repairs: [ScoreDiagnostic]) -> [ScoreDiagnostic] {
        var seen = Set<ScoreDiagnostic>()
        var out: [ScoreDiagnostic] = []
        for d in imported + validation + repairs where !seen.contains(d) {
            seen.insert(d)
            out.append(d)
        }
        return out.enumerated().sorted { a, b in
            let ma = a.element.measureIndex ?? -1
            let mb = b.element.measureIndex ?? -1
            if ma != mb { return ma < mb }
            if a.element.severity != b.element.severity { return a.element.severity > b.element.severity }
            return a.offset < b.offset
        }.map { $0.element }
    }

    /// "Measure 12 · Right hand" style location, using the score's display numbers.
    static func location(of d: ScoreDiagnostic, in score: Score) -> String? {
        var parts: [String] = []
        if let m = d.measureIndex {
            let number = score.measures.indices.contains(m) ? score.measures[m].number : m + 1
            parts.append("Measure \(number)")
        }
        if let h = d.hand { parts.append(h.displayName + ((d.voice ?? 1) >= 2 ? ", voice \(d.voice ?? 2)" : "")) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// A first guess at the difficulty of an imported piece (the learner can change it before saving).
enum ImportDifficultyEstimator {
    static func estimate(_ score: Score) -> Difficulty {
        let quarters = Double(max(1, score.notatedLength)) / Double(Ticks.perQuarter)
        let attacks = Double(score.noteCount(for: .both))
        let density = attacks / quarters
        let events = score.allEvents.filter { !$0.isRest }
        let maxChord = events.map { $0.notes.count }.max() ?? 0
        let shortest = events.map { $0.duration }.min() ?? Ticks.perQuarter
        let bothHands = score.hasNotes(for: .right) && score.hasNotes(for: .left)
        let span = score.pitchRange.map { $0.upperBound - $0.lowerBound } ?? 0
        let accidentals = abs(score.initialKey.fifths)

        var points = 0.0
        // Steady figuration (e.g. constant sixteenths) is dense but repetitive, so density is capped lower than before.
        points += min(3, density * 0.8)
        if bothHands { points += 1 }
        if maxChord >= 3 { points += 0.75 }
        if maxChord >= 5 { points += 0.75 }
        if shortest <= Ticks.perQuarter / 4 { points += 1 } else if shortest <= Ticks.perQuarter / 2 { points += 0.5 }
        if span > 36 { points += 0.75 }
        if accidentals >= 4 { points += 0.5 }

        switch points {
        case ..<2.5: return .beginner
        case ..<5.0: return .intermediate
        case ..<6.75: return .advanced
        default: return .pro
        }
    }
}
