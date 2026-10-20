import XCTest
import UIKit
import ImageIO
import UniformTypeIdentifiers
@testable import LearnPiano

/// Unit tests for the Import module: type sniffing, link normalising, page concatenation, the Claude request body,
/// response parsing, HTTP classification, backoff, the repair loop (with a canned transport) and small helpers.
final class ImportTests: XCTestCase {

    // MARK: - Fixtures

    private func bytes(_ values: [UInt8], padTo count: Int = 32) -> Data {
        var d = Data(values)
        if d.count < count { d.append(Data(repeating: 0, count: count - d.count)) }
        return d
    }

    /// One complete 4/4 measure: a whole C4 in the right hand, a whole rest in the left.
    private let validLPC = """
    {"format":"lpc-1","title":"Test Piece","composer":"Anon","divisions":4,"time":"4/4","key":0,"tempo":90,"pickup":false,
     "measures":[{"n":1,"time":"4/4","key":0,"tempo":90,"confidence":0.9,
       "rh":[{"p":["C4"],"d":16,"tie":"","t":[],"f":[],"s":""}],
       "lh":[{"p":[],"d":16,"tie":"","t":[],"f":[],"s":""}],"rh2":[],"lh2":[]}]}
    """

    /// The same measure with the right hand three beats short (a measure-numbered error).
    private let invalidLPC = """
    {"format":"lpc-1","title":"Test Piece","composer":"Anon","divisions":4,"time":"4/4","key":0,"tempo":90,"pickup":false,
     "measures":[{"n":1,"time":"4/4","key":0,"tempo":90,"confidence":0.8,
       "rh":[{"p":["C4"],"d":4,"tie":"","t":[],"f":[],"s":""}],
       "lh":[{"p":[],"d":16,"tie":"","t":[],"f":[],"s":""}],"rh2":[],"lh2":[]}]}
    """

    /// The reply for an image without music (a title page).
    private let blankLPC = """
    {"format":"lpc-1","title":"Sonatina in G","composer":"Anon","divisions":4,"time":"","key":0,"tempo":100,"pickup":false,"measures":[]}
    """

    /// A piece that opens with a one-beat pickup, then one complete 4/4 measure.
    private let pickupLPC = """
    {"format":"lpc-1","title":"","composer":"","divisions":4,"time":"4/4","key":1,"tempo":90,"pickup":true,
     "measures":[{"n":1,"time":"4/4","key":1,"tempo":90,"confidence":0.9,
       "rh":[{"p":["D5"],"d":4,"tie":"","t":[],"f":[],"s":""}],
       "lh":[{"p":[],"d":4,"tie":"","t":[],"f":[],"s":""}],"rh2":[],"lh2":[]},
      {"n":2,"time":"4/4","key":1,"tempo":90,"confidence":0.9,
       "rh":[{"p":["G5"],"d":16,"tie":"","t":[],"f":[],"s":""}],
       "lh":[{"p":["G3"],"d":16,"tie":"","t":[],"f":[],"s":""}],"rh2":[],"lh2":[]}]}
    """

    /// A Messages API response body with a thinking block before the text block.
    private func messageResponse(text: String?, stopReason: String) throws -> Data {
        var content: [[String: Any]] = [["type": "thinking", "thinking": "Reading the systems…", "signature": "sig"]]
        if let text { content.append(["type": "text", "text": text]) }
        let body: [String: Any] = [
            "id": "msg_test", "type": "message", "role": "assistant", "model": "claude-opus-5-5",
            "content": content, "stop_reason": stopReason,
            "usage": ["input_tokens": 1200, "output_tokens": 300],
        ]
        return try JSONSerialization.data(withJSONObject: body)
    }

    private func errorBody(_ message: String, type: String = "invalid_request_error") -> Data {
        Data("{\"type\":\"error\",\"error\":{\"type\":\"\(type)\",\"message\":\"\(message)\"}}".utf8)
    }

    private func page(_ index: Int = 0) -> SheetPage {
        SheetPage(index: index, png: Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4]), pixelWidth: 2000, pixelHeight: 2576)
    }

    private func jsonObject(_ data: Data?) throws -> [String: Any] {
        let d = try XCTUnwrap(data)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: d) as? [String: Any])
    }

    // MARK: - Sniffing

    func testContentSniffingRecognisesMagicNumbers() {
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])), .image)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes([0xFF, 0xD8, 0xFF, 0xE0])), .image)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes(Array("GIF89a".utf8))), .image)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes([0, 0, 0, 0x18] + Array("ftypheic".utf8))), .image)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes(Array("MThd".utf8) + [0, 0, 0, 6])), .midi)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: bytes([0x50, 0x4B, 0x03, 0x04])), .compressedMusicXML)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: Data("%PDF-1.7\n".utf8)), .pdf)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: Data("garbage before\n%PDF-1.4\n".utf8)), .pdf)
    }

    func testContentSniffingRecognisesTextFormats() {
        let xml = "\u{FEFF}<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE score-partwise PUBLIC \"-//Recordare//DTD MusicXML 4.0 Partwise//EN\" \"http://www.musicxml.org/dtds/partwise.dtd\">\n<score-partwise version=\"4.0\"></score-partwise>"
        XCTAssertEqual(ImportFileSniffer.kind(forContent: Data(xml.utf8)), .musicXML)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: Data("<!DOCTYPE html><html><body>IMSLP</body></html>".utf8)), .webPage)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: Data(validLPC.utf8)), .compactScore)
        XCTAssertNil(ImportFileSniffer.kind(forContent: Data("<?xml version=\"1.0\"?><svg></svg>".utf8)))
        XCTAssertNil(ImportFileSniffer.kind(forContent: Data()))
    }

    func testContentWinsOverMIMEAndExtension() {
        // A ".pdf" link that actually returns an HTML error page.
        let html = Data("<!doctype html><html><head><title>404</title></head></html>".utf8)
        XCTAssertEqual(ImportFileSniffer.kind(data: html, fileName: "score.pdf", mimeType: "application/pdf"), .webPage)
        // An ".mxl" file that is plain MusicXML.
        let xml = Data("<score-partwise version=\"3.1\"></score-partwise>".utf8)
        XCTAssertEqual(ImportFileSniffer.kind(data: xml, fileName: "score.mxl", mimeType: nil), .musicXML)
    }

    func testMIMEThenExtensionFallback() {
        let opaque = Data([0x00, 0x01, 0x02, 0x03])
        XCTAssertEqual(ImportFileSniffer.kind(data: opaque, fileName: "a.bin", mimeType: "image/jpeg"), .image)
        XCTAssertEqual(ImportFileSniffer.kind(data: opaque, fileName: "song.MID", mimeType: "application/octet-stream"), .midi)
        XCTAssertEqual(ImportFileSniffer.kind(data: opaque, fileName: "piece.musicxml", mimeType: nil), .musicXML)
        XCTAssertNil(ImportFileSniffer.kind(data: opaque, fileName: "notes.txt", mimeType: "text/plain"))
        XCTAssertEqual(ImportFileSniffer.kind(forMIMEType: "application/pdf; charset=binary"), .pdf)
        XCTAssertEqual(ImportFileSniffer.kind(forMIMEType: "audio/midi"), .midi)
        XCTAssertEqual(ImportFileSniffer.kind(forMIMEType: "application/vnd.recordare.musicxml"), .compressedMusicXML)
        XCTAssertEqual(ImportFileSniffer.kind(forMIMEType: "Text/HTML; charset=utf-8"), .webPage)
        XCTAssertNil(ImportFileSniffer.kind(forMIMEType: "application/xml"))
    }

    func testDownloadFileNames() throws {
        XCTAssertEqual(ImportFileSniffer.fileName(suggested: "Minuet.pdf", url: nil, kind: .pdf), "Minuet.pdf")
        let bare = try XCTUnwrap(URL(string: "https://example.org/files/score"))
        XCTAssertEqual(ImportFileSniffer.fileName(suggested: nil, url: bare, kind: .musicXML), "score.musicxml")
        XCTAssertEqual(ImportFileSniffer.fileName(suggested: "score.mxl", url: nil, kind: .musicXML), "score.musicxml")
        let root = try XCTUnwrap(URL(string: "https://example.org/"))
        XCTAssertEqual(ImportFileSniffer.fileName(suggested: "", url: root, kind: .pdf), "download.pdf")
        XCTAssertEqual(ImportFileSniffer.fileName(suggested: "page.jpg", url: nil, kind: .image), "page.jpg")
    }

    func testFileKindFlags() {
        XCTAssertTrue(ImportFileKind.pdf.isSheet)
        XCTAssertTrue(ImportFileKind.image.isSheet)
        XCTAssertTrue(ImportFileKind.midi.isSymbolic)
        XCTAssertTrue(ImportFileKind.compressedMusicXML.isSymbolic)
        XCTAssertFalse(ImportFileKind.webPage.isSymbolic || ImportFileKind.webPage.isSheet)
    }

    // MARK: - Links

    func testLinkNormalizer() {
        XCTAssertEqual(ImportLinkNormalizer.url(from: "  imslp.org/wiki/Minuet  ")?.absoluteString, "https://imslp.org/wiki/Minuet")
        XCTAssertEqual(ImportLinkNormalizer.url(from: "http://www.mutopiaproject.org/a.pdf")?.absoluteString, "http://www.mutopiaproject.org/a.pdf")
        XCTAssertNil(ImportLinkNormalizer.url(from: "ftp://example.org/a.pdf"))
        XCTAssertNil(ImportLinkNormalizer.url(from: "hello"))
        XCTAssertNil(ImportLinkNormalizer.url(from: "two words.com"))
        XCTAssertNil(ImportLinkNormalizer.url(from: ""))
        XCTAssertEqual(ImportLinkNormalizer.url(from: "https://www.dropbox.com/s/abc/score.pdf?dl=0")?.absoluteString,
                       "https://www.dropbox.com/s/abc/score.pdf?dl=1")
        XCTAssertEqual(ImportLinkNormalizer.url(from: "https://drive.google.com/file/d/ABC123/view?usp=sharing")?.absoluteString,
                       "https://drive.google.com/uc?export=download&id=ABC123")
    }

    // MARK: - Request body

    func testRequestBodyShape() throws {
        let png = Data(repeating: 0xAB, count: 300)
        let body = ImportClaudeRequestBuilder.body(model: "claude-opus-5-5", effort: .high, system: ImportClaudePrompt.system,
                                                   schema: ImportClaudePrompt.lpcSchema, png: png, text: "Transcribe page 1 of 1")
        let json = try jsonObject(try ImportClaudeRequestBuilder.bodyData(body))

        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 16000)
        XCTAssertNil(json["thinking"], "thinking must never be sent")
        XCTAssertEqual(json["system"] as? String, ImportClaudePrompt.system)

        let output = try XCTUnwrap(json["output_config"] as? [String: Any])
        XCTAssertEqual(output["effort"] as? String, "high")
        let format = try XCTUnwrap(output["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        let schema = try XCTUnwrap(format["schema"] as? [String: Any])
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        XCTAssertEqual(schema["required"] as? [String], ["format", "title", "composer", "divisions", "time", "key", "tempo", "pickup", "measures"])
        let defs = try XCTUnwrap(schema["$defs"] as? [String: Any])
        let voice = try XCTUnwrap(defs["voice"] as? [String: Any])
        let item = try XCTUnwrap(voice["items"] as? [String: Any])
        XCTAssertEqual(item["required"] as? [String], ["p", "d", "tie", "t", "f", "s"])

        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0]["role"] as? String, "user")
        let content = try XCTUnwrap(messages[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 2)
        XCTAssertEqual(content[0]["type"] as? String, "image")
        let source = try XCTUnwrap(content[0]["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "base64")
        XCTAssertEqual(source["media_type"] as? String, "image/png")
        let data = try XCTUnwrap(source["data"] as? String)
        XCTAssertFalse(data.contains("\n"))
        XCTAssertEqual(Data(base64Encoded: data), png)
        XCTAssertEqual(content[1]["type"] as? String, "text")
        XCTAssertEqual(content[1]["text"] as? String, "Transcribe page 1 of 1")
    }

    func testRepairBodyUsesMediumEffort() throws {
        let body = ImportClaudeRequestBuilder.body(model: "claude-sonnet-5-5", effort: .medium, system: "s", schema: [:], png: Data([1]), text: "fix")
        let json = try jsonObject(try ImportClaudeRequestBuilder.bodyData(body))
        XCTAssertEqual((json["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        XCTAssertEqual(json["model"] as? String, "claude-sonnet-5-5")
    }

    func testURLRequestHeaders() {
        let request = ImportClaudeRequestBuilder.urlRequest(body: Data("{}".utf8), apiKey: "sk-ant-test")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.timeoutInterval, 600)
    }

    func testModelIDDefaultsAndNeverAddsSuffix() {
        XCTAssertEqual(ImportClaudeRequestBuilder.modelID(nil), "claude-opus-5-5")
        XCTAssertEqual(ImportClaudeRequestBuilder.modelID("  "), "claude-opus-5-5")
        XCTAssertEqual(ImportClaudeRequestBuilder.modelID("claude-sonnet-5-5"), "claude-sonnet-5-5")
    }

    func testSchemaLiteralParses() {
        XCTAssertFalse(ImportClaudePrompt.lpcSchema.isEmpty)
    }

    func testPageTextForContinuationPage() {
        let context = ImportPageContext(pageNumber: 2, pageCount: 3, firstMeasureNumber: 9, isFinal: false, pieceHasPickup: true,
                                        carriedTime: TimeSignature(beats: 3, beatType: 4), carriedKey: KeySignature(fifths: -2), carriedTempo: 84,
                                        label: "page 2 of 3", hint: "Minuet in G")
        let text = ImportClaudePrompt.pageText(for: context)
        XCTAssertTrue(text.contains("page 2 of 3"))
        XCTAssertTrue(text.contains("n = 9"))
        XCTAssertTrue(text.contains("set \"pickup\" to false"))
        XCTAssertTrue(text.contains("3/4"))
        XCTAssertTrue(text.contains("-2 fifths"))
        XCTAssertTrue(text.contains("Minuet in G"))
        XCTAssertFalse(context.startsPiece)
    }

    // MARK: - Response parsing

    func testEndTurnTakesFirstTextBlockAndIgnoresThinking() throws {
        let data = try messageResponse(text: "{\"format\":\"lpc-1\"}", stopReason: "end_turn")
        XCTAssertEqual(try ImportClaudeResponseParser.outcome(from: data), .text("{\"format\":\"lpc-1\"}"))
    }

    func testStopReasons() throws {
        XCTAssertEqual(try ImportClaudeResponseParser.outcome(from: try messageResponse(text: "{\"measures\":[", stopReason: "max_tokens")), .maxTokens)
        XCTAssertEqual(try ImportClaudeResponseParser.outcome(from: try messageResponse(text: "I can't help with that.", stopReason: "refusal")), .refusal("I can't help with that."))
        XCTAssertEqual(try ImportClaudeResponseParser.outcome(from: try messageResponse(text: nil, stopReason: "pause_turn")), .other("pause_turn"))
        XCTAssertThrowsError(try ImportClaudeResponseParser.outcome(from: try messageResponse(text: nil, stopReason: "end_turn")))
        XCTAssertThrowsError(try ImportClaudeResponseParser.outcome(from: Data("not json".utf8)))
    }

    func testHTTPClassification() {
        XCTAssertEqual(ImportClaudeResponseParser.classify(status: 200, retryAfter: nil, body: Data()), .success)
        if case .fail(.provider(let m)) = ImportClaudeResponseParser.classify(status: 401, retryAfter: nil, body: errorBody("invalid x-api-key", type: "authentication_error")) {
            XCTAssertTrue(m.contains("401"))
        } else { XCTFail("401 must fail") }
        XCTAssertEqual(ImportClaudeResponseParser.classify(status: 400, retryAfter: nil, body: errorBody("Image is too small")), .fail(.provider("Image is too small")))
        if case .retry(let after, .network) = ImportClaudeResponseParser.classify(status: 429, retryAfter: "30", body: errorBody("rate limited", type: "rate_limit_error")) {
            XCTAssertEqual(after, 30)
        } else { XCTFail("429 must retry") }
        if case .retry(let after, .provider) = ImportClaudeResponseParser.classify(status: 529, retryAfter: nil, body: errorBody("Overloaded", type: "overloaded_error")) {
            XCTAssertNil(after)
        } else { XCTFail("529 must retry") }
        if case .retry = ImportClaudeResponseParser.classify(status: 503, retryAfter: nil, body: Data()) {} else { XCTFail("5xx must retry") }
        if case .fail = ImportClaudeResponseParser.classify(status: 418, retryAfter: nil, body: Data()) {} else { XCTFail("418 must fail") }
        XCTAssertEqual(ImportClaudeResponseParser.errorMessage(from: errorBody("bad image")), "bad image")
        XCTAssertNil(ImportClaudeResponseParser.errorMessage(from: Data("{}".utf8)))
    }

    func testRetryAfterParsing() {
        XCTAssertEqual(ImportClaudeResponseParser.parseRetryAfter("12"), 12)
        XCTAssertNil(ImportClaudeResponseParser.parseRetryAfter(nil))
        XCTAssertNil(ImportClaudeResponseParser.parseRetryAfter("soon"))
        let now = Date(timeIntervalSince1970: 1_700_000_000) // Tue, 14 Nov 2023 22:13:20 GMT
        let later = ImportClaudeResponseParser.parseRetryAfter("Tue, 14 Nov 2023 22:13:50 GMT", now: now)
        XCTAssertEqual(later ?? -1, 30, accuracy: 0.5)
    }

    // MARK: - Backoff

    func testBackoffPolicy() {
        let policy = ImportBackoffPolicy()
        XCTAssertNil(policy.delay(forRetry: 0))
        XCTAssertEqual(policy.delay(forRetry: 1), 2)
        XCTAssertEqual(policy.delay(forRetry: 2), 4)
        XCTAssertNil(policy.delay(forRetry: 3), "at most 3 tries: the first attempt and 2 retries")
        XCTAssertEqual(policy.delay(forRetry: 1, retryAfter: 17), 17, "retry-after wins")
        XCTAssertEqual(policy.delay(forRetry: 2, retryAfter: 500), 60, "capped")
        let capped = ImportBackoffPolicy(maxRetries: 10, baseDelay: 5, maxDelay: 30)
        XCTAssertEqual(capped.delay(forRetry: 6), 30)
    }

    // MARK: - Page concatenation

    private func pageResult(_ index: Int, score: Score, confidence: [Double?] = [], diagnostics: [ScoreDiagnostic] = [],
                            head: String = "", tail: String = "", title: String = "") -> ImportPageTranscription {
        ImportPageTranscription(pageIndex: index, score: score, diagnostics: diagnostics, confidence: confidence,
                                headJSON: Data(head.utf8), tailJSON: Data(tail.utf8), printedTitle: title)
    }

    func testMergeRenumbersAndCarriesTimeKeyTempo() {
        let p1 = ScoreBuilder.make(title: "p1", time: .common, key: .cMajor, tempo: 90, right: [[(["C4"], 3840)], [(["D4"], 3840)]])
        let p2 = ScoreBuilder.make(title: "p2", time: TimeSignature(beats: 3, beatType: 4), key: .cMajor, tempo: 90, right: [[(["E4"], 2880)], [(["F4"], 2880)]])
        let p3 = ScoreBuilder.make(title: "p3", time: TimeSignature(beats: 3, beatType: 4), key: KeySignature(fifths: 1), tempo: 72, right: [[(["G4"], 2880)]])
        let merged = ImportPageMerger.merge([
            pageResult(0, score: p1, confidence: [0.9, 0.5], diagnostics: [ScoreDiagnostic(.warning, message: "whole score")]),
            pageResult(1, score: p2, confidence: [nil], diagnostics: [ScoreDiagnostic(.error, measureIndex: 1, message: "page-2 m2")], title: "Minuet"),
            pageResult(2, score: p3, confidence: [0.7]),
        ])
        let s = merged.score
        XCTAssertEqual(s.measures.count, 5)
        XCTAssertEqual(s.measures.map { $0.number }, [1, 2, 3, 4, 5])
        XCTAssertEqual(s.measures.map { $0.barline.isFinal }, [false, false, false, false, true])
        XCTAssertEqual(s.initialTime, .common)
        XCTAssertEqual(s.measures[2].timeSignature, TimeSignature(beats: 3, beatType: 4), "meter change written on page 2's first measure")
        XCTAssertNil(s.measures[2].keySignature)
        XCTAssertNil(s.measures[2].tempoBPM)
        XCTAssertNil(s.measures[4].timeSignature, "3/4 is already in force")
        XCTAssertEqual(s.measures[4].keySignature, KeySignature(fifths: 1))
        XCTAssertEqual(s.measures[4].tempoBPM, 72)
        XCTAssertEqual(s.timeSignature(atMeasure: 3), TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(merged.partRanges, [0..<2, 2..<4, 4..<5])
        XCTAssertEqual(merged.confidence, [0.9, 0.5, nil, nil, 0.7])
        XCTAssertEqual(merged.diagnostics.count, 2)
        XCTAssertNil(merged.diagnostics[0].measureIndex)
        XCTAssertEqual(merged.diagnostics[1].measureIndex, 3)
        XCTAssertEqual(s.metadata.title, "Minuet")
        XCTAssertEqual(s.metadata.source, .sheetTranscription)
    }

    func testMergeKeepsPickupOnlyOnFirstPage() {
        var p1 = ScoreBuilder.make(title: "p1", right: [[(["G4"], 960)], [(["C5"], 3840)]])
        p1.measures[0].isPickup = true
        var p2 = ScoreBuilder.make(title: "p2", right: [[(["D5"], 960)], [(["E5"], 3840)]])
        p2.measures[0].isPickup = true // a wrong pickup flag on a later page
        let merged = ImportPageMerger.merge([pageResult(0, score: p1), pageResult(1, score: p2)])
        XCTAssertEqual(merged.score.measures.map { $0.number }, [0, 1, 2, 3])
        XCTAssertEqual(merged.score.measures.map { $0.isPickup }, [true, false, false, false])
    }

    func testMergeFallsBackToGivenTitleAndHandlesEmptyInput() {
        let merged = ImportPageMerger.merge([pageResult(0, score: ScoreBuilder.make(title: "x", right: [[(["C4"], 3840)]]))], title: "From hint")
        XCTAssertEqual(merged.score.metadata.title, "From hint")
        let empty = ImportPageMerger.merge([])
        XCTAssertTrue(empty.score.measures.isEmpty)
        XCTAssertTrue(empty.partRanges.isEmpty)
    }

    func testTiesAcrossPageBreakAreJoined() throws {
        let p1 = ScoreBuilder.make(title: "p1", right: [[(["G4"], 1920), (["C5"], 1920)]])
        let p2 = ScoreBuilder.make(title: "p2", right: [[(["C5"], 3840)]])
        let tail = #"{"measures":[{"n":1,"rh":[{"p":["G4"],"d":8,"tie":""},{"p":["C5"],"d":8,"tie":"start"}],"lh":[]}]}"#
        let head = #"{"measures":[{"n":2,"rh":[{"p":["C5"],"d":16,"tie":"stop"}],"lh":[]}]}"#
        XCTAssertEqual(ImportPageMerger.crossPageTies(tailJSON: Data(tail.utf8), headJSON: Data(head.utf8)), ["rh": [72]])

        let dangling = ScoreDiagnostic(.error, measureIndex: 0, hand: .right, voice: 1, message: "Event 2 (C5) starts a tie but there is no following event in this voice.")
        let unpaired = ScoreDiagnostic(.warning, measureIndex: 0, hand: .right, voice: 1, message: "Event 1 ends a tie that no previous event starts; it is played as a new note.")
        let merged = ImportPageMerger.merge([
            pageResult(0, score: p1, diagnostics: [dangling], tail: tail),
            pageResult(1, score: p2, diagnostics: [unpaired], head: head),
        ])
        let last = try XCTUnwrap(merged.score.measures.first?.events.filter { $0.hand == .right }.max { $0.onset < $1.onset })
        XCTAssertEqual(last.notes.first?.tieStart, true)
        let first = try XCTUnwrap(merged.score.measures.last?.events.first { $0.hand == .right })
        XCTAssertEqual(first.notes.first?.tieStop, true)
        XCTAssertTrue(merged.diagnostics.isEmpty, "both unpaired-tie messages are resolved by the join")
        XCTAssertFalse(ScoreValidator.validate(merged.score).contains { $0.message.contains("Tie ends") })
    }

    func testNoTieJoinWithoutMatchingPitch() {
        let tail = #"{"measures":[{"n":1,"rh":[{"p":["C5"],"d":16,"tie":"start"}]}]}"#
        let head = #"{"measures":[{"n":2,"rh":[{"p":["D5"],"d":16,"tie":"stop"}]}]}"#
        XCTAssertTrue(ImportPageMerger.crossPageTies(tailJSON: Data(tail.utf8), headJSON: Data(head.utf8)).isEmpty)
        XCTAssertTrue(ImportPageMerger.crossPageTies(tailJSON: Data(), headJSON: Data(head.utf8)).isEmpty)
    }

    func testConfidenceMarkingAndLevels() {
        let errors = [ScoreDiagnostic(.error, measureIndex: 1, message: "bad"), ScoreDiagnostic(.warning, measureIndex: 0, message: "meh"),
                      ScoreDiagnostic(.error, measureIndex: 2, message: "bad too"), ScoreDiagnostic(.error, message: "whole")]
        XCTAssertEqual(ImportPageMerger.markingErrors([0.95, 0.9, nil], errors: errors, measureCount: 4), [0.95, 0.3, 0.3, nil])
        XCTAssertEqual(ImportPageMerger.level(0.9), .high)
        XCTAssertEqual(ImportPageMerger.level(0.7), .medium)
        XCTAssertEqual(ImportPageMerger.level(0.2), .low)
        XCTAssertEqual(ImportPageMerger.level(nil), .unknown)
    }

    func testRepairableErrorsSkipTiesIntoTheNextPage() {
        let tie = ParsersCompactScoreIssue(measure: 8, voice: "rh", message: "Event 3 (C5) starts a tie but there is no following event in this voice.")
        let sum = ParsersCompactScoreIssue(measure: 4, voice: "lh", message: "Voice \"lh\" lasts 12 divisions but a 4/4 measure needs 16.")
        XCTAssertEqual(ImportClaudeTranscriptionProvider.repairableErrors([tie, sum], isFinal: false), [sum])
        XCTAssertEqual(ImportClaudeTranscriptionProvider.repairableErrors([tie, sum], isFinal: true), [tie, sum])
    }

    func testPageContextContinuesNumberingAndCarriesAttributes() {
        let provider = ImportClaudeTranscriptionProvider(model: nil, transport: ImportCannedTransport([]), apiKeyProvider: { "k" }, sleeper: { _ in })
        let previous = ScoreBuilder.make(title: "p1", time: TimeSignature(beats: 3, beatType: 4), key: KeySignature(fifths: 2), tempo: 80,
                                         right: [[(["D5"], 2880)], [(["E5"], 2880)], [(["F#5"], 2880)], [(["G5"], 2880)]])
        var first = pageResult(0, score: previous)
        first.pickup = true
        let context = provider.context(forPage: 1, pageCount: 3, previous: [first], hint: nil)
        XCTAssertEqual(context.firstMeasureNumber, 5)
        XCTAssertFalse(context.isFinal)
        XCTAssertEqual(context.pieceHasPickup, true)
        XCTAssertEqual(context.carriedTime, TimeSignature(beats: 3, beatType: 4))
        XCTAssertEqual(context.carriedKey, KeySignature(fifths: 2))
        XCTAssertEqual(context.carriedTempo, 80)
        XCTAssertEqual(context.label, "page 2 of 3")
        let start = provider.context(forPage: 0, pageCount: 1, previous: [], hint: nil)
        XCTAssertTrue(start.startsPiece)
        XCTAssertTrue(start.isFinal)
        XCTAssertEqual(provider.model, "claude-opus-5-5")
    }

    func testMergeSkipsAnEmptyFirstPageAndKeepsThePickupOfTheFirstMusicPage() {
        let blank = Score(metadata: ScoreMetadata(title: "", source: .sheetTranscription), measures: [])
        var music = ScoreBuilder.make(title: "p2", time: TimeSignature(beats: 3, beatType: 4), key: KeySignature(fifths: 1), tempo: 80,
                                      right: [[(["D5"], 960)], [(["G5"], 2880)]])
        music.measures[0].isPickup = true
        let emptyMeasures = ScoreDiagnostic(.error, message: "\"measures\" is empty.")
        let merged = ImportPageMerger.merge([
            pageResult(0, score: blank, diagnostics: [emptyMeasures], title: "Sonatina in G"),
            pageResult(1, score: music, confidence: [0.9, 0.8]),
        ])
        let s = merged.score
        XCTAssertEqual(s.measures.map { $0.isPickup }, [true, false], "the pickup on the first music page survives")
        XCTAssertEqual(s.measures.map { $0.number }, [0, 1])
        XCTAssertEqual(s.initialTime, TimeSignature(beats: 3, beatType: 4), "attributes come from the first page with measures")
        XCTAssertEqual(s.initialKey, KeySignature(fifths: 1))
        XCTAssertEqual(s.initialTempoBPM, 80)
        XCTAssertNil(s.measures[0].timeSignature, "no change is written on the opening measure")
        XCTAssertEqual(s.metadata.title, "Sonatina in G", "the title page names the piece")
        XCTAssertTrue(merged.diagnostics.isEmpty, "the empty-measures error of a page without music is dropped")
        XCTAssertEqual(merged.partRanges, [0..<0, 0..<2])
        XCTAssertEqual(merged.confidence, [0.9, 0.8])
    }

    func testPageContextAfterAPageWithoutMusicStillStartsThePiece() {
        let provider = ImportClaudeTranscriptionProvider(model: nil, transport: ImportCannedTransport([]), apiKeyProvider: { "k" }, sleeper: { _ in })
        let blank = pageResult(0, score: Score(metadata: ScoreMetadata(title: "", source: .sheetTranscription), measures: []))
        let context = provider.context(forPage: 1, pageCount: 2, previous: [blank], hint: nil)
        XCTAssertEqual(context.firstMeasureNumber, 1)
        XCTAssertNil(context.pieceHasPickup)
        XCTAssertTrue(context.startsPiece)
        XCTAssertNil(context.carriedTime)
        XCTAssertTrue(ImportClaudePrompt.pageText(for: context).contains("This image starts the piece"))
        XCTAssertTrue(ImportClaudePrompt.system.contains("\"measures\": []"), "the prompt says how to answer for a page without music")
    }

    func testRepairableErrorsSkipTheEmptyMeasuresError() {
        let empty = ParsersCompactScoreIssue(measure: nil, message: "\"measures\" is empty.")
        XCTAssertTrue(ImportClaudeTranscriptionProvider.repairableErrors([empty], isFinal: true).isEmpty)
    }

    // MARK: - Provider with a canned transport

    func testProviderTranscribesOnePage() async throws {
        let transport = ImportCannedTransport([(200, [:], try messageResponse(text: validLPC, stopReason: "end_turn"))])
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "sk-test" }, sleeper: { _ in })
        let progress = ImportRecorder<TranscriptionProgress>()
        let result = try await provider.transcribeDocument(pages: [page()], hint: nil) { progress.append($0) }
        XCTAssertEqual(result.merged.score.measures.count, 1)
        XCTAssertEqual(result.merged.score.metadata.title, "Test Piece")
        XCTAssertEqual(result.merged.score.metadata.composer, "Anon")
        XCTAssertEqual(result.merged.score.initialTempoBPM, 90)
        XCTAssertEqual(result.merged.confidence, [0.9])
        XCTAssertEqual(result.pageResults.first?.repairRounds, 0)
        XCTAssertEqual(transport.requests.count, 1)
        XCTAssertEqual(transport.requests.first?.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(progress.values.first?.pagesTotal, 1)
        XCTAssertEqual(progress.values.last?.pagesDone, 1)
    }

    func testProviderSendsARepairRequestForMeasureErrors() async throws {
        let transport = ImportCannedTransport([
            (200, [:], try messageResponse(text: invalidLPC, stopReason: "end_turn")),
            (200, [:], try messageResponse(text: validLPC, stopReason: "end_turn")),
        ])
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "k" }, sleeper: { _ in })
        let result = try await provider.transcribeDocument(pages: [page()], hint: nil) { _ in }
        XCTAssertEqual(transport.requests.count, 2)
        let repair = try jsonObject(transport.requests[1].httpBody)
        XCTAssertEqual((repair["output_config"] as? [String: Any])?["effort"] as? String, "medium")
        let content = try XCTUnwrap(((repair["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        XCTAssertEqual(content.first?["type"] as? String, "image", "the repair resends the image")
        let text = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertTrue(text.contains("\"measure\":1"), "errors are measure-numbered")
        XCTAssertTrue(text.contains("\"d\":4"), "the previous JSON is included")
        XCTAssertEqual(result.pageResults.first?.repairRounds, 1)
        XCTAssertEqual(result.pageResults.first?.unresolvedErrorCount, 0)
        XCTAssertFalse(result.importResult.hasErrors)
    }

    func testProviderStopsAfterTwoRepairRoundsAndMarksMeasuresLow() async throws {
        let bad = try messageResponse(text: invalidLPC, stopReason: "end_turn")
        let transport = ImportCannedTransport([(200, [:], bad), (200, [:], bad), (200, [:], bad)])
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "k" }, sleeper: { _ in })
        let result = try await provider.transcribeDocument(pages: [page()], hint: nil) { _ in }
        XCTAssertEqual(transport.requests.count, 3, "one transcription + two repairs")
        XCTAssertEqual(result.pageResults.first?.repairRounds, 2)
        XCTAssertEqual(result.pageResults.first?.unresolvedErrorCount, 1)
        XCTAssertEqual(result.merged.confidence, [0.3])
        XCTAssertTrue(result.importResult.hasErrors)
    }

    func testProviderSkipsRepairsForAPageWithoutMusic() async throws {
        let transport = ImportCannedTransport([
            (200, [:], try messageResponse(text: blankLPC, stopReason: "end_turn")),
            (200, [:], try messageResponse(text: pickupLPC, stopReason: "end_turn")),
        ])
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "k" }, sleeper: { _ in })
        let result = try await provider.transcribeDocument(pages: [page(0), page(1)], hint: nil) { _ in }
        XCTAssertEqual(transport.requests.count, 2, "no repair requests for the title page")
        XCTAssertEqual(result.pageResults.first?.measureCount, 0)
        XCTAssertEqual(result.pageResults.first?.repairRounds, 0)
        XCTAssertEqual(result.pageResults.first?.unresolvedErrorCount, 0)
        let second = try jsonObject(transport.requests[1].httpBody)
        let content = try XCTUnwrap(((second["messages"] as? [[String: Any]])?.first)?["content"] as? [[String: Any]])
        let text = try XCTUnwrap(content.last?["text"] as? String)
        XCTAssertTrue(text.contains("n = 1"))
        XCTAssertTrue(text.contains("This image starts the piece"), "the first music page may hold a pickup")
        XCTAssertEqual(result.merged.score.measures.map { $0.isPickup }, [true, false])
        XCTAssertEqual(result.merged.score.measures.map { $0.number }, [0, 1])
        XCTAssertEqual(result.merged.score.metadata.title, "Sonatina in G")
        XCTAssertEqual(result.merged.score.initialKey, KeySignature(fifths: 1))
        XCTAssertFalse(result.importResult.hasErrors)
        XCTAssertEqual(result.merged.partRanges, [0..<0, 0..<2])
    }

    func testProviderRetriesRateLimitWithRetryAfter() async throws {
        let delays = ImportRecorder<TimeInterval>()
        let transport = ImportCannedTransport([
            (429, ["retry-after": "7"], errorBody("rate limited", type: "rate_limit_error")),
            (200, [:], try messageResponse(text: validLPC, stopReason: "end_turn")),
        ])
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "k" }, sleeper: { delays.append($0) })
        _ = try await provider.transcribeDocument(pages: [page()], hint: nil) { _ in }
        XCTAssertEqual(transport.requests.count, 2)
        XCTAssertEqual(delays.values, [7])
    }

    func testProviderGivesUpOnOverloadAfterThreeTries() async {
        let delays = ImportRecorder<TimeInterval>()
        let overloaded = errorBody("Overloaded", type: "overloaded_error")
        let transport = ImportCannedTransport(Array(repeating: (529, [:], overloaded), count: 5))
        let provider = ImportClaudeTranscriptionProvider(model: "claude-opus-5-5", transport: transport, apiKeyProvider: { "k" }, sleeper: { delays.append($0) })
        do {
            _ = try await provider.transcribeDocument(pages: [page()], hint: nil) { _ in }
            XCTFail("expected a failure")
        } catch let error as ImportError {
            guard case .provider(let message) = error else { return XCTFail("expected .provider, got \(error)") }
            XCTAssertTrue(message.contains("529"))
        } catch {
            XCTFail("unexpected \(error)")
        }
        XCTAssertEqual(transport.requests.count, 3, "max 3 tries")
        XCTAssertEqual(delays.values, [2, 4])
    }

    func testProviderMapsRefusalAndAuthErrors() async throws {
        let refusal = ImportCannedTransport([(200, [:], try messageResponse(text: nil, stopReason: "refusal"))])
        let p1 = ImportClaudeTranscriptionProvider(model: nil, transport: refusal, apiKeyProvider: { "k" }, sleeper: { _ in })
        do {
            _ = try await p1.transcribeDocument(pages: [page()], hint: nil) { _ in }
            XCTFail("expected a refusal error")
        } catch let error as ImportError {
            guard case .provider(let message) = error else { return XCTFail("expected .provider") }
            XCTAssertTrue(message.contains("declined"))
        }

        let unauthorized = ImportCannedTransport([(401, [:], errorBody("invalid x-api-key", type: "authentication_error"))])
        let p2 = ImportClaudeTranscriptionProvider(model: nil, transport: unauthorized, apiKeyProvider: { "k" }, sleeper: { _ in })
        do {
            _ = try await p2.transcribeDocument(pages: [page()], hint: nil) { _ in }
            XCTFail("expected an auth error")
        } catch let error as ImportError {
            guard case .provider(let message) = error else { return XCTFail("expected .provider") }
            XCTAssertTrue(message.contains("401"))
        }
        XCTAssertEqual(unauthorized.requests.count, 1, "401 is not retried")
    }

    func testProviderWithoutKeyIsNotConfigured() async {
        let provider = ImportClaudeTranscriptionProvider(model: nil, transport: ImportCannedTransport([]), apiKeyProvider: { nil }, sleeper: { _ in })
        XCTAssertFalse(provider.isConfigured)
        do {
            _ = try await provider.transcribe(pages: [page()], hint: nil) { _ in }
            XCTFail("expected an error")
        } catch let error as ImportError {
            guard case .provider = error else { return XCTFail("expected .provider") }
        } catch {
            XCTFail("unexpected \(error)")
        }
    }

    // MARK: - Rendering helpers

    func testTargetSize() {
        let letter = ImportPageRenderer.targetSize(for: CGSize(width: 612, height: 792), allowUpscale: true)
        XCTAssertEqual(letter.height, 2576)
        XCTAssertEqual(letter.width, 1991, accuracy: 1)
        XCTAssertEqual(ImportPageRenderer.targetSize(for: CGSize(width: 4000, height: 3000), allowUpscale: false), CGSize(width: 2576, height: 1932))
        XCTAssertEqual(ImportPageRenderer.targetSize(for: CGSize(width: 1000, height: 800), allowUpscale: false), CGSize(width: 1000, height: 800))
        XCTAssertEqual(ImportPageRenderer.targetSize(for: .zero, allowUpscale: true), .zero)
    }

    func testSplitRowPrefersWhitespaceNearTheMiddle() {
        var ink = Array(repeating: 1.0, count: 100)
        ink[62] = 0
        ink[10] = 0 // outside the middle 40 %
        XCTAssertEqual(ImportPageRenderer.splitRow(darkness: ink), 62)
        XCTAssertEqual(ImportPageRenderer.splitRow(darkness: Array(repeating: 0.2, count: 100)), 50)
        XCTAssertEqual(ImportPageRenderer.splitRow(darkness: []), 0)
    }

    func testRenderPDFPageToLongEdgePNG() throws {
        let bounds = CGRect(x: 0, y: 0, width: 612, height: 792)
        let pdf = UIGraphicsPDFRenderer(bounds: bounds).pdfData { ctx in
            for _ in 0..<2 {
                ctx.beginPage()
                UIColor.black.setFill()
                UIRectFill(CGRect(x: 50, y: 50, width: 500, height: 4))
            }
        }
        let pages = try ImportPageRenderer.renderPDF(data: pdf, firstIndex: 3)
        XCTAssertEqual(pages.count, 2)
        XCTAssertEqual(pages.map { $0.index }, [3, 4])
        XCTAssertEqual(pages[0].pixelHeight, 2576)
        XCTAssertEqual(Double(pages[0].pixelWidth), 1991, accuracy: 1)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: pages[0].png), .image)
        XCTAssertThrowsError(try ImportPageRenderer.renderPDF(data: Data("%PDF-broken".utf8)))
    }

    func testRenderImageDownscalesAndSplitFindsTheGap() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let size = CGSize(width: 1600, height: 3200)
        // Ink everywhere except a white band at 55–60 % of the height (the gap between two systems).
        let jpeg = UIGraphicsImageRenderer(size: size, format: format).jpegData(withCompressionQuality: 0.9) { ctx in
            UIColor.darkGray.setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: size.height * 0.55, width: size.width, height: size.height * 0.05))
        }
        let page = try ImportPageRenderer.renderImage(data: jpeg, index: 0)
        XCTAssertEqual(page.pixelHeight, 2576)
        XCTAssertEqual(page.pixelWidth, 1288)
        let halves = try XCTUnwrap(ImportPageRenderer.split(page))
        XCTAssertEqual(halves.top.pixelHeight + halves.bottom.pixelHeight, page.pixelHeight)
        let cutFraction = Double(halves.top.pixelHeight) / Double(page.pixelHeight)
        XCTAssertGreaterThan(cutFraction, 0.54)
        XCTAssertLessThan(cutFraction, 0.61)
        XCTAssertNotNil(ImportPageRenderer.thumbnail(page))
        XCTAssertThrowsError(try ImportPageRenderer.renderImage(data: Data([1, 2, 3]), index: 0))
    }

    func testNoisyPhotoStaysUnderTheImageByteBudget() throws {
        // A deterministic 4000x3000 RGB noise picture: the worst case for PNG compression (paper texture, sensor noise).
        let width = 4000, height = 3000
        var state: UInt32 = 0x1234_5678
        var pixels = [UInt32](repeating: 0, count: width * height)
        for i in pixels.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[i] = state | 0xFF00_0000
        }
        let image: CGImage = try pixels.withUnsafeMutableBytes { buffer in
            let ctx = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                              space: CGColorSpaceCreateDeviceRGB(),
                                              bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let out = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.92] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        let jpeg = out as Data

        let page = try ImportPageRenderer.renderImage(data: jpeg, index: 0)
        XCTAssertLessThan(page.png.count, ImportPageRenderer.maxPNGBytes)
        XCTAssertLessThan(page.png.count, 3_700_000)
        XCTAssertGreaterThanOrEqual(max(page.pixelWidth, page.pixelHeight), 1600, "never shrunk below 1600 px")
        XCTAssertLessThanOrEqual(max(page.pixelWidth, page.pixelHeight), 2576)
        // The reported size is the encoded size, and the PNG is single-channel gray.
        let source = try XCTUnwrap(CGImageSourceCreateWithData(page.png as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        XCTAssertEqual(decoded.width, page.pixelWidth)
        XCTAssertEqual(decoded.height, page.pixelHeight)
        XCTAssertEqual(decoded.colorSpace?.model, .monochrome)
        XCTAssertEqual(ImportFileSniffer.kind(forContent: page.png), .image)
    }

    func testByteBudgetShrinksStepwiseAndStopsAtTheFloor() throws {
        let sizes = ImportRecorder<CGSize>()
        let encoded = try XCTUnwrap(ImportPageRenderer.encodeWithinBudget(size: CGSize(width: 2576, height: 1932), maxBytes: 1, draw: { _, size in
            sizes.append(size)
        }))
        XCTAssertEqual(sizes.values.map { max($0.width, $0.height) }, [2576, 2189, 1860, 1600], "x0.85 per step, floor 1600")
        XCTAssertEqual(encoded.width, 1600)
        XCTAssertEqual(encoded.height, 1200)
        let small = try XCTUnwrap(ImportPageRenderer.encodeWithinBudget(size: CGSize(width: 1000, height: 800), maxBytes: 1, draw: { _, _ in }))
        XCTAssertEqual(small.width, 1000, "a page already under the floor is never shrunk")
    }

    // MARK: - Diagnostics and difficulty

    func testDiagnosticsCombineDedupesAndSorts() {
        let a = ScoreDiagnostic(.warning, measureIndex: 0, message: "under-filled")
        let b = ScoreDiagnostic(.error, measureIndex: 0, message: "over-full")
        let c = ScoreDiagnostic(.info, message: "fixed something")
        let d = ScoreDiagnostic(.error, measureIndex: 3, message: "out of range")
        let combined = ImportDiagnostics.combine(imported: [d, a], validation: [b, a], repairs: [c])
        XCTAssertEqual(combined, [c, b, a, d])
        let score = ScoreBuilder.make(title: "x", right: [[(["C4"], 3840)], [(["C4"], 3840)], [(["C4"], 3840)], [(["C4"], 3840)]])
        XCTAssertEqual(ImportDiagnostics.location(of: ScoreDiagnostic(.error, measureIndex: 3, hand: .left, voice: 2, message: "x"), in: score), "Measure 4 · Left hand, voice 2")
        XCTAssertNil(ImportDiagnostics.location(of: c, in: score))
    }

    func testDifficultyEstimate() {
        let simple = ScoreBuilder.make(title: "simple", right: Array(repeating: Array(repeating: (pitches: ["C4"], ticks: 960), count: 4), count: 8))
        XCTAssertEqual(ImportDifficultyEstimator.estimate(simple), .beginner)
        let dense = ScoreBuilder.make(title: "dense",
                                      right: Array(repeating: Array(repeating: (pitches: ["C5", "E5", "G5"], ticks: 240), count: 16), count: 8),
                                      left: Array(repeating: Array(repeating: (pitches: ["C2", "G2"], ticks: 480), count: 8), count: 8))
        XCTAssertGreaterThanOrEqual(ImportDifficultyEstimator.estimate(dense), .advanced)
    }

    // MARK: - Pipeline

    @MainActor
    private func waitUntilSettled(_ pipeline: ImportPipeline, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        try await Task.sleep(nanoseconds: 10_000_000)
        while pipeline.isBusy {
            if Date() > deadline { return XCTFail("the pipeline did not finish: \(pipeline.phase)") }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    @MainActor
    func testPipelineImportsMusicXMLAndSavesToLibrary() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        var source = ScoreBuilder.make(title: "Little Tune", right: [[(["C4"], 960), (["D4"], 960), (["E4"], 960), (["F4"], 960)], [(["G4"], 3840)]],
                                       left: [[(["C3"], 3840)], [(["G2"], 3840)]])
        source.metadata.composer = "Someone"
        let fileURL = folder.appendingPathComponent("tune.musicxml")
        try ParsersMusicXMLExporter().exportData(source).write(to: fileURL)

        let pipeline = ImportPipeline()
        pipeline.importFiles([fileURL])
        try await waitUntilSettled(pipeline)
        XCTAssertEqual(pipeline.phase, .review)
        let draft = try XCTUnwrap(pipeline.draft)
        XCTAssertEqual(draft.kind, .musicXML)
        XCTAssertEqual(draft.score.measures.count, 2)
        XCTAssertFalse(draft.isTranscription)
        XCTAssertEqual(pipeline.title, "Little Tune")
        XCTAssertEqual(pipeline.composer, "Someone")
        XCTAssertEqual(pipeline.genre, ImportPipeline.otherGenre)

        pipeline.genre = "Folk"
        pipeline.difficulty = .beginner
        let library = folder.appendingPathComponent("Library", isDirectory: true)
        let store = ContentStore(importers: [ParsersMusicXMLImporter()], libraryDirectory: library)
        let entry = try XCTUnwrap(pipeline.save(to: store))
        XCTAssertEqual(entry.title, "Little Tune")
        XCTAssertEqual(entry.genre, "Folk")
        XCTAssertTrue(entry.isUserImported)
        XCTAssertEqual(pipeline.phase, .done(songID: entry.id, title: "Little Tune"))
        XCTAssertNil(pipeline.draft)
        XCTAssertTrue(FileManager.default.fileExists(atPath: library.appendingPathComponent(entry.id).appendingPathComponent("song.json").path))
    }

    @MainActor
    func testPipelineRefusesSheetsWithoutAPIKey() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("ImportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 612, height: 792)).pdfData { $0.beginPage() }
        let url = folder.appendingPathComponent("scan.pdf")
        try pdf.write(to: url)

        let pipeline = ImportPipeline(makeProvider: { ImportClaudeTranscriptionProvider(model: $0, transport: ImportCannedTransport([]), apiKeyProvider: { nil }, sleeper: { _ in }) })
        pipeline.importFiles([url])
        try await waitUntilSettled(pipeline)
        guard case .failed(let message) = pipeline.phase else { return XCTFail("expected a failure, got \(pipeline.phase)") }
        XCTAssertTrue(message.contains("API key"))
    }

    @MainActor
    func testPipelineRejectsBadLink() {
        let pipeline = ImportPipeline()
        pipeline.importLink("not a link")
        guard case .failed = pipeline.phase else { return XCTFail("expected a failure") }
        pipeline.reset()
        XCTAssertEqual(pipeline.phase, .idle)
    }

    // MARK: - Incoming files

    @MainActor
    func testIncomingQueue() throws {
        let queue = ImportIncomingFiles()
        let file = URL(fileURLWithPath: "/tmp/score.musicxml")
        XCTAssertTrue(queue.enqueue(file))
        XCTAssertTrue(queue.enqueue(file))
        XCTAssertEqual(queue.pending.count, 1, "duplicates are not queued twice")
        XCTAssertFalse(queue.enqueue(try XCTUnwrap(URL(string: "mailto:someone@example.org"))))
        XCTAssertTrue(queue.enqueue(try XCTUnwrap(URL(string: "https://imslp.org/a.pdf"))))
        XCTAssertEqual(queue.takeAll().count, 2)
        XCTAssertTrue(queue.pending.isEmpty)
    }
}

// MARK: - Test doubles

/// Replays canned HTTP responses in order and records the requests.
final class ImportCannedTransport: ImportHTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var responses: [(Int, [String: String], Data)]
    private var recorded: [URLRequest] = []

    init(_ responses: [(Int, [String: String], Data)]) {
        self.responses = responses
    }

    var requests: [URLRequest] { lock.withLock { recorded } }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let next: (Int, [String: String], Data)? = lock.withLock {
            recorded.append(request)
            return responses.isEmpty ? nil : responses.removeFirst()
        }
        guard let (status, headers, body) = next,
              let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers) else {
            throw URLError(.badServerResponse)
        }
        return (body, response)
    }
}

/// Thread-safe collector for values reported from async code.
final class ImportRecorder<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [Value] = []

    func append(_ value: Value) { lock.withLock { stored.append(value) } }
    var values: [Value] { lock.withLock { stored } }
}
