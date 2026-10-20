import Foundation

// Pure request/response logic for the Claude Messages API, exactly as specified in docs/claude-api-notes.md.
// No networking here, so everything is unit-testable with canned JSON.

/// `output_config.effort` values.
enum ImportClaudeEffort: String, Sendable, CaseIterable {
    case low, medium, high, xhigh, max
}

/// Builds the HTTP requests sent to `POST /v1/messages`.
enum ImportClaudeRequestBuilder {
    static let endpoint: URL = URL(string: "https://api.anthropic.com/v1/messages") ?? URL(fileURLWithPath: "/v1/messages")
    static let anthropicVersion = "2023-06-01"
    static let defaultModel = "claude-opus-5-5"
    /// Output budget for one page (non-streaming).
    static let maxTokens = 16000
    /// Dense pages can take minutes.
    static let requestTimeout: TimeInterval = 600

    /// The model id to send: the user's choice, or the default when it is empty. Date suffixes are never appended.
    static func modelID(_ configured: String?) -> String {
        let trimmed = configured?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? defaultModel : trimmed
    }

    /// The JSON body for one page image plus instructions. `schema` goes verbatim into `output_config.format.schema`.
    static func body(model: String, effort: ImportClaudeEffort, system: String, schema: [String: Any], png: Data, text: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": [
                "effort": effort.rawValue,
                "format": ["type": "json_schema", "schema": schema] as [String: Any],
            ] as [String: Any],
            "system": system,
            "messages": [
                [
                    "role": "user",
                    "content": [
                        [
                            "type": "image",
                            "source": ["type": "base64", "media_type": "image/png", "data": png.base64EncodedString()],
                        ] as [String: Any],
                        ["type": "text", "text": text],
                    ],
                ] as [String: Any],
            ],
        ]
    }

    /// Serialized body (sorted keys so identical requests are byte-identical).
    static func bodyData(_ body: [String: Any]) throws -> Data {
        do {
            return try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys, .withoutEscapingSlashes])
        } catch {
            throw ImportError.provider("Could not encode the request: \(error.localizedDescription)")
        }
    }

    /// The POST request with the required headers.
    static func urlRequest(body: Data, apiKey: String) -> URLRequest {
        var request = URLRequest(url: endpoint, timeoutInterval: requestTimeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(anthropicVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = body
        return request
    }
}

/// How a successful (HTTP 200) Messages response ended.
enum ImportClaudeOutcome: Equatable, Sendable {
    /// `end_turn`: the first text block (the JSON reply).
    case text(String)
    /// `max_tokens`: the reply was cut off.
    case maxTokens
    /// `refusal`: the model declined; carries any text it gave.
    case refusal(String?)
    /// Any other stop reason (treated as a failure).
    case other(String)
}

/// What to do with an HTTP response.
enum ImportClaudeHTTPDecision: Equatable, Sendable {
    case success
    /// Retry after the server's `retry-after` (seconds) when given, else the backoff policy's delay; `failure` is thrown
    /// when the retries are used up.
    case retry(after: TimeInterval?, failure: ImportError)
    case fail(ImportError)
}

/// Reads Messages API responses.
enum ImportClaudeResponseParser {
    private struct Body: Decodable {
        struct Block: Decodable {
            var type: String
            var text: String?
        }
        var content: [Block]?
        var stop_reason: String?
    }

    private struct ErrorBody: Decodable {
        struct Detail: Decodable {
            var type: String?
            var message: String?
        }
        var error: Detail?
    }

    /// Checks `stop_reason` first, then takes the first `text` block (thinking blocks are ignored).
    static func outcome(from data: Data) throws -> ImportClaudeOutcome {
        let body: Body
        do { body = try JSONDecoder().decode(Body.self, from: data) } catch {
            throw ImportError.provider("The Claude API sent a reply that could not be read.")
        }
        let firstText = body.content?.first { $0.type == "text" }?.text
        switch body.stop_reason {
        case "end_turn":
            guard let text = firstText, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ImportError.provider("The model finished without returning a transcription.")
            }
            return .text(text)
        case "max_tokens":
            return .maxTokens
        case "refusal":
            return .refusal(firstText)
        case let other?:
            return .other(other)
        case nil:
            return .other("missing stop_reason")
        }
    }

    /// The `error.message` of an API error body.
    static func errorMessage(from data: Data) -> String? {
        guard let body = try? JSONDecoder().decode(ErrorBody.self, from: data), let message = body.error?.message,
              !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return message
    }

    /// Maps an HTTP status to success, retry (429, 529, other 5xx) or a readable failure.
    static func classify(status: Int, retryAfter: String?, body: Data, now: Date = Date()) -> ImportClaudeHTTPDecision {
        let apiMessage = errorMessage(from: body)
        let detail = apiMessage.map { ": \($0)" } ?? "."
        let after = parseRetryAfter(retryAfter, now: now)
        switch status {
        case 200..<300:
            return .success
        case 401:
            return .fail(.provider("The Claude API key was rejected (HTTP 401). Check the key in Settings."))
        case 403:
            return .fail(.provider("This API key is not allowed to make this request (HTTP 403)\(detail)"))
        case 404:
            return .fail(.provider("The Claude API could not find the model or endpoint (HTTP 404)\(detail) Check the model in Settings."))
        case 400:
            return .fail(.provider(apiMessage ?? "The Claude API rejected the request (HTTP 400)."))
        case 413:
            return .fail(.provider("The page image is too large for the Claude API (HTTP 413)."))
        case 429:
            return .retry(after: after, failure: .network("Claude is rate-limiting requests (HTTP 429). Wait a minute, then try again."))
        case 529:
            return .retry(after: after, failure: .provider("Claude is overloaded right now (HTTP 529). Try again in a few minutes."))
        case 500..<600:
            return .retry(after: after, failure: .provider("The Claude API had a server error (HTTP \(status))\(detail)"))
        default:
            return .fail(.provider("Unexpected response from the Claude API (HTTP \(status))\(detail)"))
        }
    }

    /// `retry-after` is either delta-seconds or an HTTP date.
    static func parseRetryAfter(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let seconds = Double(raw), seconds.isFinite { return max(0, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

/// Exponential backoff for retryable responses (429, 529, 5xx, transient network errors). Deterministic (no jitter).
struct ImportBackoffPolicy: Equatable, Sendable {
    /// Retries after the first attempt: 2, so a rate-limited or overloaded request is tried at most 3 times in all
    /// (docs/claude-api-notes.md: "max 3 tries").
    var maxRetries: Int = 2
    var baseDelay: TimeInterval = 2
    var maxDelay: TimeInterval = 60

    /// Delay before retry number `retry` (1-based), or nil when the retries are used up. A server `retry-after`
    /// wins over the exponential delay (both capped at `maxDelay`).
    func delay(forRetry retry: Int, retryAfter: TimeInterval? = nil) -> TimeInterval? {
        guard retry >= 1, retry <= maxRetries else { return nil }
        if let retryAfter, retryAfter.isFinite { return min(max(0, retryAfter), maxDelay) }
        return min(baseDelay * pow(2, Double(retry - 1)), maxDelay)
    }
}
