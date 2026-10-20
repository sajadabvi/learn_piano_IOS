import Foundation
import Security

/// Sends one HTTP request. Abstracted so tests can replay canned responses.
protocol ImportHTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

/// `URLSession` transport with the 600 s request timeout the API notes require.
struct ImportURLSessionTransport: ImportHTTPTransport {
    let session: URLSession

    init(timeout: TimeInterval = ImportClaudeRequestBuilder.requestTimeout) {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = timeout
        configuration.timeoutIntervalForResource = max(timeout, 900)
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ImportError.network("The server did not send an HTTP response.") }
        return (data, http)
    }
}

/// Reads the Anthropic API key that the Settings screen stores in the Keychain (generic password,
/// service "com.sajadabvi.LearnPiano", account "anthropic-api-key"). Read-only on purpose.
enum ImportKeychain {
    static let service = "com.sajadabvi.LearnPiano"
    static let account = "anthropic-api-key"

    static func readAPIKey() -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let text = String(data: data, encoding: .utf8) else { return nil }
            let key = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return key.isEmpty ? nil : key
        case errSecItemNotFound:
            return nil
        default:
            NSLog("ImportKeychain: reading the API key failed with OSStatus \(status)")
            return nil
        }
    }
}

/// A finished multi-page transcription, kept by the review screen so single pages can be re-transcribed.
struct ImportTranscription: Sendable {
    var pages: [SheetPage]
    var pageResults: [ImportPageTranscription]
    var merged: ImportMergedScore
    var model: String
    var hint: String?

    var importResult: ImportResult { ImportResult(score: merged.score, diagnostics: merged.diagnostics) }
}

/// Optical music recognition through the Claude Messages API (docs/claude-api-notes.md): one request per page image
/// with structured output in the LPC schema, parsed by `ParsersCompactScoreImporter`; up to two repair rounds for
/// measure-numbered errors; dense pages that hit `max_tokens` are split in halves; 429/529/5xx retried with backoff.
struct ImportClaudeTranscriptionProvider: SheetTranscriptionProvider, Sendable {
    var model: String
    var transport: ImportHTTPTransport
    var backoff: ImportBackoffPolicy
    var apiKeyProvider: @Sendable () -> String?
    var sleeper: @Sendable (TimeInterval) async throws -> Void
    var maxRepairRounds: Int
    /// How many times a page may be halved after `max_tokens`.
    var maxSplitDepth: Int
    var fileName: String

    init(model: String? = nil,
         transport: ImportHTTPTransport = ImportURLSessionTransport(),
         backoff: ImportBackoffPolicy = ImportBackoffPolicy(),
         apiKeyProvider: @escaping @Sendable () -> String? = { ImportKeychain.readAPIKey() },
         sleeper: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000)) },
         maxRepairRounds: Int = 2,
         maxSplitDepth: Int = 2,
         fileName: String = "transcription.lpc") {
        self.model = ImportClaudeRequestBuilder.modelID(model)
        self.transport = transport
        self.backoff = backoff
        self.apiKeyProvider = apiKeyProvider
        self.sleeper = sleeper
        self.maxRepairRounds = maxRepairRounds
        self.maxSplitDepth = maxSplitDepth
        self.fileName = fileName
    }

    /// Whether an API key is stored (read fresh from the Keychain).
    static var isConfigured: Bool { ImportKeychain.readAPIKey() != nil }

    var isConfigured: Bool { apiKeyProvider() != nil }
    var displayName: String { "Claude (\(model))" }

    // MARK: SheetTranscriptionProvider

    func transcribe(pages: [SheetPage], hint: String?, progress: @escaping (TranscriptionProgress) -> Void) async throws -> ImportResult {
        try await transcribeDocument(pages: pages, hint: hint, progress: progress).importResult
    }

    /// Transcribes all pages in order (each page's context depends on the previous ones) and concatenates them.
    func transcribeDocument(pages: [SheetPage], hint: String?, progress: @escaping (TranscriptionProgress) -> Void) async throws -> ImportTranscription {
        guard !pages.isEmpty else { throw ImportError.empty }
        let apiKey = try requireKey()
        var results: [ImportPageTranscription] = []
        do {
            for (i, page) in pages.enumerated() {
                try Task.checkCancellation()
                progress(TranscriptionProgress(pagesDone: i, pagesTotal: pages.count, message: "Reading page \(i + 1) of \(pages.count)…"))
                let context = self.context(forPage: i, pageCount: pages.count, previous: results, hint: hint)
                let result = try await transcribe(page: page, pageIndex: i, context: context, apiKey: apiKey, depth: 0) { message in
                    progress(TranscriptionProgress(pagesDone: i, pagesTotal: pages.count, message: message))
                }
                results.append(result)
            }
        } catch {
            throw Self.normalized(error)
        }
        progress(TranscriptionProgress(pagesDone: pages.count, pagesTotal: pages.count, message: "Putting the pages together…"))
        let merged = ImportPageMerger.merge(results, title: Self.fallbackTitle(hint), sourceFileName: fileName)
        return ImportTranscription(pages: pages, pageResults: results, merged: merged, model: model, hint: hint)
    }

    /// Re-runs one page of an earlier transcription and re-concatenates.
    func retranscribe(pageAt index: Int, in previous: ImportTranscription, progress: @escaping (TranscriptionProgress) -> Void) async throws -> ImportTranscription {
        guard previous.pages.indices.contains(index), previous.pageResults.indices.contains(index) else { throw ImportError.malformed("There is no page \(index + 1).") }
        let apiKey = try requireKey()
        let total = previous.pages.count
        progress(TranscriptionProgress(pagesDone: 0, pagesTotal: 1, message: "Reading page \(index + 1) of \(total) again…"))
        let context = self.context(forPage: index, pageCount: total, previous: Array(previous.pageResults.prefix(index)), hint: previous.hint)
        let result: ImportPageTranscription
        do {
            result = try await transcribe(page: previous.pages[index], pageIndex: index, context: context, apiKey: apiKey, depth: 0) { message in
                progress(TranscriptionProgress(pagesDone: 0, pagesTotal: 1, message: message))
            }
        } catch {
            throw Self.normalized(error)
        }
        var results = previous.pageResults
        results[index] = result
        progress(TranscriptionProgress(pagesDone: 1, pagesTotal: 1, message: "Putting the pages together…"))
        let merged = ImportPageMerger.merge(results, title: Self.fallbackTitle(previous.hint), sourceFileName: fileName)
        return ImportTranscription(pages: previous.pages, pageResults: results, merged: merged, model: model, hint: previous.hint)
    }

    // MARK: Page context

    func context(forPage index: Int, pageCount: Int, previous: [ImportPageTranscription], hint: String?) -> ImportPageContext {
        let firstNumber = 1 + previous.reduce(0) { $0 + $1.measureCount }
        var carriedTime: TimeSignature?
        var carriedKey: KeySignature?
        var carriedTempo: Double?
        // Pages without music (title page, preface, blank) carry nothing forward.
        if let last = previous.last(where: { $0.measureCount > 0 }) {
            let s = last.score
            let lastIndex = max(0, s.measures.count - 1)
            carriedTime = s.timeSignature(atMeasure: lastIndex)
            carriedKey = s.keySignature(atMeasure: lastIndex)
            carriedTempo = s.tempoBPM(atMeasure: lastIndex)
        }
        return ImportPageContext(pageNumber: index + 1, pageCount: pageCount, firstMeasureNumber: firstNumber,
                                 isFinal: index == pageCount - 1,
                                 // nil until a page with measures exists, so the first music page still starts the piece.
                                 pieceHasPickup: previous.first(where: { $0.measureCount > 0 })?.pickup,
                                 carriedTime: carriedTime, carriedKey: carriedKey, carriedTempo: carriedTempo,
                                 label: "page \(index + 1) of \(pageCount)", hint: hint)
    }

    // MARK: One image

    private struct Attempt {
        var json: Data
        var parse: ParsersCompactScoreParseResult?
        var repairable: [ParsersCompactScoreIssue]
        var readError: String?
        /// A valid reply with `"measures": []`: the image holds no music (title page, text, blank).
        var isBlank: Bool = false

        var errorCount: Int { readError == nil ? repairable.count : Int.max }
    }

    /// Transcribes one image with repair rounds; splits it in halves after `max_tokens`.
    private func transcribe(page: SheetPage, pageIndex: Int, context: ImportPageContext, apiKey: String, depth: Int,
                            report: @escaping (String) -> Void) async throws -> ImportPageTranscription {
        let body = ImportClaudeRequestBuilder.body(model: model, effort: .high, system: ImportClaudePrompt.system,
                                                   schema: ImportClaudePrompt.lpcSchema, png: page.png,
                                                   text: ImportClaudePrompt.pageText(for: context))
        let outcome = try await send(body: body, apiKey: apiKey, report: report)
        let firstText: String
        switch outcome {
        case .text(let text):
            firstText = text
        case .maxTokens:
            return try await transcribeSplit(page: page, pageIndex: pageIndex, context: context, apiKey: apiKey, depth: depth, report: report)
        case .refusal(let text):
            let reason = text.map { " (\($0.prefix(200)))" } ?? ""
            throw ImportError.provider("The model declined to transcribe \(context.label)\(reason).")
        case .other(let reason):
            throw ImportError.provider("The transcription of \(context.label) stopped unexpectedly (\(reason)).")
        }

        var best = evaluate(text: firstText, context: context)
        if best.isBlank {
            // No music on this image: nothing to repair, nothing to report.
            let header = Self.header(best.json)
            var score = Score(metadata: ScoreMetadata(title: header.title, composer: header.composer, source: .sheetTranscription, sourceFileName: fileName),
                              measures: [])
            if let parsed = best.parse?.importResult.score {
                score.initialTime = parsed.initialTime
                score.initialKey = parsed.initialKey
                score.initialTempoBPM = parsed.initialTempoBPM
            }
            return ImportPageTranscription(pageIndex: pageIndex, score: score, pickup: false, headJSON: best.json, tailJSON: best.json,
                                           printedTitle: header.title, printedComposer: header.composer)
        }
        var rounds = 0
        while best.errorCount > 0, rounds < maxRepairRounds {
            try Task.checkCancellation()
            rounds += 1
            let count = best.readError == nil ? best.repairable.count : 1
            report("Fixing \(count) problem\(count == 1 ? "" : "s") on \(context.label) (round \(rounds) of \(maxRepairRounds))…")
            let errorsJSON: String
            if let readError = best.readError {
                errorsJSON = ParsersCompactScoreIssue.json([ParsersCompactScoreIssue(measure: nil, message: readError)])
            } else {
                errorsJSON = ParsersCompactScoreIssue.json(best.repairable)
            }
            let previousJSON = String(decoding: best.json, as: UTF8.self)
            let repairBody = ImportClaudeRequestBuilder.body(model: model, effort: .medium, system: ImportClaudePrompt.system,
                                                             schema: ImportClaudePrompt.lpcSchema, png: page.png,
                                                             text: ImportClaudePrompt.repairText(for: context, previousJSON: previousJSON, errorsJSON: errorsJSON))
            let repairOutcome = try await send(body: repairBody, apiKey: apiKey, report: report)
            guard case .text(let repaired) = repairOutcome else { break } // keep the best attempt so far
            let attempt = evaluate(text: repaired, context: context)
            // A repair that drops every measure is not a fix of a page that had music.
            if !attempt.isBlank, attempt.errorCount <= best.errorCount { best = attempt }
        }

        guard let parse = best.parse else {
            throw ImportError.provider("The transcription of \(context.label) could not be read: \(best.readError ?? "invalid JSON").")
        }
        var score = parse.importResult.score
        score.metadata.source = .sheetTranscription
        let errors = parse.importResult.diagnostics.filter { $0.severity == .error }
        let confidence = ImportPageMerger.markingErrors(parse.confidence, errors: errors, measureCount: score.measures.count)
        let header = Self.header(best.json)
        return ImportPageTranscription(pageIndex: pageIndex, score: score, diagnostics: parse.importResult.diagnostics,
                                       confidence: confidence, pickup: header.pickup, headJSON: best.json, tailJSON: best.json,
                                       unresolvedErrorCount: best.repairable.count, repairRounds: rounds,
                                       printedTitle: header.title, printedComposer: header.composer)
    }

    /// Halves the image and transcribes both parts as consecutive segments of the same page.
    private func transcribeSplit(page: SheetPage, pageIndex: Int, context: ImportPageContext, apiKey: String, depth: Int,
                                 report: @escaping (String) -> Void) async throws -> ImportPageTranscription {
        guard depth < maxSplitDepth, let halves = ImportPageRenderer.split(page) else {
            throw ImportError.provider("\(context.label.prefix(1).uppercased() + context.label.dropFirst()) holds too much music for one reply. Try a sharper scan or crop the page into parts.")
        }
        report("\(context.label.prefix(1).uppercased() + context.label.dropFirst()) is dense; reading it in two halves…")
        var topContext = context
        topContext.isFinal = false
        topContext.label = "the top half of \(context.label)"
        let top = try await transcribe(page: halves.top, pageIndex: pageIndex, context: topContext, apiKey: apiKey, depth: depth + 1, report: report)

        var bottomContext = context
        bottomContext.firstMeasureNumber = context.firstMeasureNumber + top.measureCount
        if top.measureCount > 0 {
            // A top half without music (e.g. the title above the first system) leaves the context as it was.
            bottomContext.pieceHasPickup = context.pieceHasPickup ?? top.pickup
            let lastIndex = top.score.measures.count - 1
            bottomContext.carriedTime = top.score.timeSignature(atMeasure: lastIndex)
            bottomContext.carriedKey = top.score.keySignature(atMeasure: lastIndex)
            bottomContext.carriedTempo = top.score.tempoBPM(atMeasure: lastIndex)
        }
        bottomContext.label = "the bottom half of \(context.label)"
        let bottom = try await transcribe(page: halves.bottom, pageIndex: pageIndex, context: bottomContext, apiKey: apiKey, depth: depth + 1, report: report)

        let merged = ImportPageMerger.merge([top, bottom], title: "", sourceFileName: fileName)
        var score = merged.score
        score.measures.indices.forEach { score.measures[$0].barline.isFinal = false }
        if let last = score.measures.indices.last { score.measures[last].barline.isFinal = true }
        return ImportPageTranscription(pageIndex: pageIndex, score: score, diagnostics: merged.diagnostics, confidence: merged.confidence,
                                       pickup: top.measureCount > 0 ? top.pickup : bottom.pickup,
                                       headJSON: top.measureCount > 0 ? top.headJSON : bottom.headJSON,
                                       tailJSON: bottom.measureCount > 0 ? bottom.tailJSON : top.tailJSON,
                                       unresolvedErrorCount: top.unresolvedErrorCount + bottom.unresolvedErrorCount,
                                       repairRounds: top.repairRounds + bottom.repairRounds,
                                       printedTitle: top.printedTitle.isEmpty ? bottom.printedTitle : top.printedTitle,
                                       printedComposer: top.printedComposer.isEmpty ? bottom.printedComposer : top.printedComposer)
    }

    /// Parses a reply and lists the errors worth a repair request.
    private func evaluate(text: String, context: ImportPageContext) -> Attempt {
        let json = Data(text.utf8)
        let importer = ParsersCompactScoreImporter(firstMeasureNumber: context.firstMeasureNumber, isFinalPage: context.isFinal,
                                                   pieceHasPickup: context.pieceHasPickup)
        do {
            let parse = try importer.parse(data: json, fileName: fileName)
            if Self.isBlankPage(parse) {
                return Attempt(json: json, parse: parse, repairable: [], readError: nil, isBlank: true)
            }
            return Attempt(json: json, parse: parse, repairable: Self.repairableErrors(parse.errors, isFinal: context.isFinal), readError: nil)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return Attempt(json: json, parse: nil, repairable: [], readError: message)
        }
    }

    /// Errors sent back for repair. A tie that runs into the next page is legitimate on a page that does not end the
    /// piece; `"measures": []` is the agreed answer for a page without music.
    static func repairableErrors(_ errors: [ParsersCompactScoreIssue], isFinal: Bool) -> [ParsersCompactScoreIssue] {
        errors.filter { e in
            !ImportPageMerger.isEmptyMeasuresMessage(e.message) && (isFinal || !e.message.contains("there is no following event in this voice"))
        }
    }

    /// Whether a parsed reply is the answer for an image without music: an array of zero measures.
    static func isBlankPage(_ parse: ParsersCompactScoreParseResult) -> Bool {
        parse.importResult.score.measures.isEmpty && parse.errors.contains { $0.measure == nil && ImportPageMerger.isEmptyMeasuresMessage($0.message) }
    }

    /// Top-level header fields of an LPC reply.
    static func header(_ json: Data) -> (title: String, composer: String, pickup: Bool) {
        guard let root = try? ParsersCompactScoreImporter.jsonObject(json) else { return ("", "", false) }
        let title = (root["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let composer = (root["composer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return (title, composer, (root["pickup"] as? Bool) ?? false)
    }

    // MARK: HTTP

    private func requireKey() throws -> String {
        guard let key = apiKeyProvider() else {
            throw ImportError.provider("No Claude API key is set. Add one in Settings to transcribe PDFs and pictures.")
        }
        return key
    }

    /// Sends a request, retrying 429/529/5xx and transient network failures with backoff.
    private func send(body: [String: Any], apiKey: String, report: @escaping (String) -> Void) async throws -> ImportClaudeOutcome {
        let data = try ImportClaudeRequestBuilder.bodyData(body)
        var retry = 0
        while true {
            try Task.checkCancellation()
            let request = ImportClaudeRequestBuilder.urlRequest(body: data, apiKey: apiKey)
            let responseData: Data
            let http: HTTPURLResponse
            do {
                (responseData, http) = try await transport.send(request)
            } catch let error as URLError where error.code == .cancelled {
                throw ImportError.cancelled
            } catch let error as URLError {
                let failure = ImportError.network(Self.readable(error))
                guard Self.isTransient(error), let delay = backoff.delay(forRetry: retry + 1) else { throw failure }
                retry += 1
                report("Connection problem; retrying in \(Int(delay.rounded())) s…")
                try await sleeper(delay)
                continue
            }
            switch ImportClaudeResponseParser.classify(status: http.statusCode, retryAfter: http.value(forHTTPHeaderField: "retry-after"), body: responseData) {
            case .success:
                return try ImportClaudeResponseParser.outcome(from: responseData)
            case .fail(let error):
                throw error
            case .retry(let after, let failure):
                retry += 1
                guard let delay = backoff.delay(forRetry: retry, retryAfter: after) else { throw failure }
                report(http.statusCode == 429 ? "Rate limited; waiting \(Int(delay.rounded())) s…" : "Claude is busy; retrying in \(Int(delay.rounded())) s…")
                try await sleeper(delay)
            }
        }
    }

    static func isTransient(_ error: URLError) -> Bool {
        // Offline is not retried: waiting a few seconds rarely helps and the learner should see it at once.
        [.timedOut, .networkConnectionLost, .cannotConnectToHost, .dnsLookupFailed, .cannotFindHost].contains(error.code)
    }

    static func readable(_ error: URLError) -> String {
        switch error.code {
        case .notConnectedToInternet: return "The iPad is offline. Connect to the internet and try again."
        case .timedOut: return "The Claude API did not answer in time."
        case .cannotFindHost, .dnsLookupFailed, .cannotConnectToHost: return "Could not reach api.anthropic.com."
        case .networkConnectionLost: return "The connection was lost."
        default: return error.localizedDescription
        }
    }

    /// Cancellation of any kind becomes `ImportError.cancelled`; `ImportError`s pass through.
    static func normalized(_ error: Error) -> Error {
        if error is CancellationError { return ImportError.cancelled }
        if let e = error as? URLError, e.code == .cancelled { return ImportError.cancelled }
        return error
    }

    static func fallbackTitle(_ hint: String?) -> String {
        let h = hint?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return h.isEmpty ? "Imported score" : h
    }
}
