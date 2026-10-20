import Foundation
import Observation

/// State of the Claude API key row: the saved key (in the Keychain), the draft being typed, and the test result.
@MainActor
@Observable
final class SettingsAPIKeyModel {
    /// Text in the secure field (not yet saved).
    var draft = ""
    /// Masked form of the saved key, nil when none is saved.
    private(set) var savedKeyMask: String?
    /// Result of the last "Test key".
    private(set) var testResult: SettingsAPIKeyCheckResult?
    private(set) var isTesting = false
    /// Last Keychain problem, shown under the field.
    private(set) var keychainError: String?

    @ObservationIgnored private let keychain: SettingsKeychain
    @ObservationIgnored private let runCheck: (String, String) async -> SettingsAPIKeyCheckResult
    @ObservationIgnored private var testTask: Task<Void, Never>?

    /// - Parameters:
    ///   - keychain: the item holding the key (tests pass a test-only service).
    ///   - runCheck: performs the network test; injectable for tests.
    init(keychain: SettingsKeychain = .anthropicAPIKey,
         runCheck: @escaping (String, String) async -> SettingsAPIKeyCheckResult = { key, model in
             await SettingsAPIKeyCheck.run(apiKey: key, model: model)
         }) {
        self.keychain = keychain
        self.runCheck = runCheck
    }

    var hasSavedKey: Bool { savedKeyMask != nil }

    /// Whether the draft can be saved.
    var canSave: Bool { !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// A hint when the draft does not look like an Anthropic key.
    var draftWarning: String? {
        guard canSave, !SettingsFormatting.looksLikeAnthropicKey(draft) else { return nil }
        return "This does not look like an Anthropic API key (they start with “sk-ant-”)."
    }

    /// Reads the saved key's presence from the Keychain.
    func load() {
        do {
            savedKeyMask = try keychain.read().flatMap { $0.isEmpty ? nil : SettingsFormatting.maskedKey($0) }
            keychainError = nil
        } catch {
            savedKeyMask = nil
            keychainError = error.localizedDescription
        }
    }

    /// Saves the draft to the Keychain and clears it.
    func save() {
        let key = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        do {
            try keychain.write(key)
            draft = ""
            savedKeyMask = SettingsFormatting.maskedKey(key)
            keychainError = nil
            testResult = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// Deletes the saved key.
    func remove() {
        do {
            try keychain.delete()
            savedKeyMask = nil
            testResult = nil
            keychainError = nil
        } catch {
            keychainError = error.localizedDescription
        }
    }

    /// Tests the draft if one is typed, otherwise the saved key.
    func test(model: String) {
        let key: String
        let typed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if !typed.isEmpty {
            key = typed
        } else {
            do {
                guard let saved = try keychain.read(), !saved.isEmpty else {
                    testResult = .failure("Enter or save an API key first.")
                    return
                }
                key = saved
            } catch {
                testResult = .failure(error.localizedDescription)
                return
            }
        }
        testTask?.cancel()
        isTesting = true
        testResult = nil
        let check = runCheck
        testTask = Task { [weak self] in
            let result = await check(key, model)
            guard let self, !Task.isCancelled else { return }
            self.testResult = result
            self.isTesting = false
        }
    }

    /// Waits for a running test (tests only).
    func waitForTest() async {
        await testTask?.value
    }
}
