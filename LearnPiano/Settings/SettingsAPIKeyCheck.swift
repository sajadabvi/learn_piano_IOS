import Foundation

/// Transcription models offered in Settings (`UserSettings.transcriptionModel` stores the raw id).
enum SettingsTranscriptionModel: String, CaseIterable, Identifiable, Hashable, Sendable {
    case opus = "claude-opus-5-5"
    case sonnet = "claude-sonnet-5-5"

    var id: String { rawValue }

    /// The model used when the stored id is not one of the offered models.
    static let defaultModel: SettingsTranscriptionModel = .opus

    /// Maps a stored id to an offered model, falling back to the default.
    init(storedID: String) {
        self = SettingsTranscriptionModel(rawValue: storedID.trimmingCharacters(in: .whitespacesAndNewlines)) ?? .defaultModel
    }

    var displayName: String {
        switch self {
        case .opus: return "Claude Opus 5.5"
        case .sonnet: return "Claude Sonnet 5.5"
        }
    }

    var detail: String {
        switch self {
        case .opus: return "Most accurate. $4 input / $20 output per million tokens."
        case .sonnet: return "About half the cost. $2 input / $10 output per million tokens."
        }
    }
}

/// Outcome of the "Test key" request.
enum SettingsAPIKeyCheckResult: Equatable, Sendable {
    case success(String)
    case failure(String)

    var isSuccess: Bool {
        if case .success = self { return true }
        return false
    }

    var message: String {
        switch self {
        case .success(let text), .failure(let text): return text
        }
    }
}

/// Validates a Claude API key with one tiny Messages request (max_tokens 16, "Reply with OK"), using the exact
/// endpoint and headers from docs/claude-api-notes.md. Request building and response interpretation are pure so
/// they can be unit-tested; `run` performs the network call off the main actor.
enum SettingsAPIKeyCheck {
    static let endpoint = "https://api.anthropic.com/v1/messages"
    static let apiVersion = "2023-06-01"
    static let maxTokens = 16
    static let prompt = "Reply with OK"
    static let timeout: TimeInterval = 60

    enum BuildError: Error, LocalizedError, Equatable {
        case emptyKey
        case invalidEndpoint

        var errorDescription: String? {
            switch self {
            case .emptyKey: return "Enter an API key first."
            case .invalidEndpoint: return "The API address is invalid."
            }
        }
    }

    /// The JSON body: model, max_tokens 16, low effort (thinking is always on for these models, so no `thinking`
    /// object is sent), and one user message.
    static func body(model: String) -> [String: Any] {
        [
            "model": model,
            "max_tokens": maxTokens,
            "output_config": ["effort": "low"],
            "messages": [["role": "user", "content": prompt]],
        ]
    }

    /// Builds the POST request with the headers from docs/claude-api-notes.md.
    static func makeRequest(apiKey: String, model: String) throws -> URLRequest {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw BuildError.emptyKey }
        guard let url = URL(string: endpoint) else { throw BuildError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: timeout)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body(model: model), options: [.sortedKeys])
        return request
    }

    /// The `error.message` of an API error body (`{"type":"error","error":{"type":…,"message":…}}`).
    static func errorMessage(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = object["error"] as? [String: Any],
              let message = error["message"] as? String,
              !message.isEmpty else { return nil }
        return message
    }

    /// Concatenated `text` blocks of a successful response (thinking blocks are ignored).
    static func replyText(in data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = object["content"] as? [[String: Any]] else { return nil }
        let text = content.filter { ($0["type"] as? String) == "text" }.compactMap { $0["text"] as? String }.joined()
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Turns an HTTP status and body into a user-facing result. Any 200 proves the key works, even when the
    /// 16-token budget was spent on thinking and no text came back.
    static func interpret(statusCode: Int, data: Data, model: String) -> SettingsAPIKeyCheckResult {
        let apiMessage = errorMessage(in: data)
        let modelName = SettingsTranscriptionModel(rawValue: model)?.displayName ?? model
        switch statusCode {
        case 200..<300:
            if let reply = replyText(in: data) {
                return .success("Key works. \(modelName) replied “\(String(reply.prefix(40)))”.")
            }
            return .success("Key works. \(modelName) answered the test request.")
        case 401:
            return .failure("The key was rejected (401). Check that you pasted the whole key.")
        case 403:
            return .failure("This key is not allowed to use the API (403).\(apiMessage.map { " \($0)" } ?? "")")
        case 404:
            return .failure("\(modelName) is not available for this key (404).\(apiMessage.map { " \($0)" } ?? "")")
        case 429:
            return .failure("The key is valid but rate limited right now (429). Try again in a minute.")
        case 529:
            return .failure("The API is overloaded (529). The key could not be checked; try again shortly.")
        case 400:
            return .failure(apiMessage ?? "The API rejected the request (400).")
        case 500..<600:
            return .failure("The API had a server error (\(statusCode)). Try again shortly.")
        default:
            return .failure(apiMessage.map { "\($0) (\(statusCode))" } ?? "Unexpected response (\(statusCode)).")
        }
    }

    /// Sends the test request and interprets the response. Network failures become `.failure`.
    static func run(apiKey: String, model: String, session: URLSession = .shared) async -> SettingsAPIKeyCheckResult {
        let request: URLRequest
        do {
            request = try makeRequest(apiKey: apiKey, model: model)
        } catch {
            return .failure(error.localizedDescription)
        }
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("The API returned a response that is not HTTP.")
            }
            return interpret(statusCode: http.statusCode, data: data, model: model)
        } catch let error as URLError where error.code == .notConnectedToInternet {
            return .failure("You appear to be offline. Connect to the internet and try again.")
        } catch {
            return .failure("The request failed: \(error.localizedDescription)")
        }
    }
}
