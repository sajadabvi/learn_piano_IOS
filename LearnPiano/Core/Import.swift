import Foundation

// MARK: - Importing scores from external formats

/// Severity of an import/validation message.
public enum DiagnosticSeverity: String, Codable, Hashable, Comparable, Sendable {
    case info, warning, error
    private var rank: Int { ["info": 0, "warning": 1, "error": 2][rawValue] ?? 0 }
    public static func < (lhs: DiagnosticSeverity, rhs: DiagnosticSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// A message about a score, optionally located at a measure and hand/voice. Errors are measure-numbered so they can be shown
/// in the review screen and sent back to the transcription model for repair.
public struct ScoreDiagnostic: Hashable, Codable, Sendable, CustomStringConvertible {
    public var severity: DiagnosticSeverity
    /// 0-based notated measure index, nil for whole-score issues.
    public var measureIndex: Int?
    public var hand: Hand?
    public var voice: Int?
    public var message: String

    public init(_ severity: DiagnosticSeverity, measureIndex: Int? = nil, hand: Hand? = nil, voice: Int? = nil, message: String) {
        self.severity = severity
        self.measureIndex = measureIndex
        self.hand = hand
        self.voice = voice
        self.message = message
    }

    public var description: String {
        var loc = ""
        if let m = measureIndex { loc += "m\(m + 1)" }
        if let h = hand { loc += loc.isEmpty ? h.rawValue : " \(h.rawValue)" }
        if let v = voice { loc += " v\(v)" }
        return "[\(severity.rawValue)] \(loc.isEmpty ? "" : loc + ": ")\(message)"
    }
}

/// What an importer produced.
public struct ImportResult: Hashable, Codable, Sendable {
    public var score: Score
    public var diagnostics: [ScoreDiagnostic]
    public init(score: Score, diagnostics: [ScoreDiagnostic] = []) {
        self.score = score
        self.diagnostics = diagnostics
    }
    public var hasErrors: Bool { diagnostics.contains { $0.severity == .error } }
    public var errors: [ScoreDiagnostic] { diagnostics.filter { $0.severity == .error } }
}

/// Errors thrown when an importer cannot produce a score at all.
public enum ImportError: Error, LocalizedError, Hashable, Sendable {
    case unsupportedFormat(String)
    case malformed(String)
    case empty
    case cancelled
    case network(String)
    case provider(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedFormat(let s): return "Unsupported file type: \(s)"
        case .malformed(let s): return "The file could not be read: \(s)"
        case .empty: return "The file contains no notes."
        case .cancelled: return "Import cancelled."
        case .network(let s): return "Network problem: \(s)"
        case .provider(let s): return "Transcription failed: \(s)"
        }
    }
}

/// Converts bytes of one format into a `Score`. Implementations live in Parsers/ (MusicXML, MXL, MIDI, LPC JSON).
public protocol ScoreImporter {
    /// Lower-case file extensions this importer accepts.
    var supportedExtensions: [String] { get }
    var displayName: String { get }
    /// Parses the data. Throws `ImportError` for unrecoverable problems; recoverable ones become diagnostics.
    func importScore(data: Data, fileName: String) throws -> ImportResult
}

public extension ScoreImporter {
    func canImport(fileExtension: String) -> Bool { supportedExtensions.contains(fileExtension.lowercased()) }
}

/// A page of sheet music handed to a transcription provider.
public struct SheetPage: Hashable, Sendable {
    public var index: Int
    /// PNG bytes of the rendered page.
    public var png: Data
    public var pixelWidth: Int
    public var pixelHeight: Int
    public init(index: Int, png: Data, pixelWidth: Int, pixelHeight: Int) {
        self.index = index
        self.png = png
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }
}

/// Progress reported by a multi-page transcription.
public struct TranscriptionProgress: Hashable, Sendable {
    public var pagesDone: Int
    public var pagesTotal: Int
    public var message: String
    public init(pagesDone: Int, pagesTotal: Int, message: String) {
        self.pagesDone = pagesDone
        self.pagesTotal = pagesTotal
        self.message = message
    }
}

/// Optical-music-recognition provider: images of sheet music → score. The Import module implements it with the Claude API
/// (docs/claude-api-notes.md) and converts the LPC JSON reply with the Parsers module.
public protocol SheetTranscriptionProvider {
    var displayName: String { get }
    /// Whether the provider is configured (e.g. API key present).
    var isConfigured: Bool { get }
    func transcribe(pages: [SheetPage], hint: String?, progress: @escaping (TranscriptionProgress) -> Void) async throws -> ImportResult
}
