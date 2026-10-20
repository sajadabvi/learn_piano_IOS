import XCTest
@testable import LearnPiano

// Deterministic tests of the Settings module's logic: the Keychain helper (test-only service), A4 clamping, the
// settings mapping view model, the API key check's request/response handling, and formatting helpers.

// MARK: - Keychain

final class SettingsKeychainTests: XCTestCase {
    private var keychain: SettingsKeychain!

    override func setUp() {
        super.setUp()
        keychain = SettingsKeychain(service: "com.sajadabvi.LearnPiano.tests.\(UUID().uuidString)", account: "test-account")
    }

    override func tearDown() {
        XCTAssertNoThrow(try keychain.delete())
        keychain = nil
        super.tearDown()
    }

    func testReadMissingItemReturnsNil() throws {
        XCTAssertNil(try keychain.read())
    }

    func testWriteReadRoundTrip() throws {
        try keychain.write("sk-ant-test-12345")
        XCTAssertEqual(try keychain.read(), "sk-ant-test-12345")
    }

    func testWriteReplacesExistingValue() throws {
        try keychain.write("first")
        try keychain.write("second")
        XCTAssertEqual(try keychain.read(), "second")
    }

    func testDeleteRemovesItemAndIsIdempotent() throws {
        try keychain.write("value")
        try keychain.delete()
        XCTAssertNil(try keychain.read())
        XCTAssertNoThrow(try keychain.delete())
    }

    func testUnicodeRoundTrip() throws {
        try keychain.write("clé-🎹")
        XCTAssertEqual(try keychain.read(), "clé-🎹")
    }

    func testItemsAreScopedByService() throws {
        let other = SettingsKeychain(service: keychain.service + ".other", account: keychain.account)
        defer { XCTAssertNoThrow(try other.delete()) }
        try keychain.write("mine")
        XCTAssertNil(try other.read())
    }

    func testAppItemIdentifiersMatchImportContract() {
        XCTAssertEqual(SettingsKeychain.anthropicAPIKey.service, "com.sajadabvi.LearnPiano")
        XCTAssertEqual(SettingsKeychain.anthropicAPIKey.account, "anthropic-api-key")
    }
}

// MARK: - A4 and other clamps

final class SettingsClampTests: XCTestCase {
    func testA4ClampsToRange() {
        XCTAssertEqual(SettingsViewModel.clampA4(400), 415)
        XCTAssertEqual(SettingsViewModel.clampA4(415), 415)
        XCTAssertEqual(SettingsViewModel.clampA4(440), 440)
        XCTAssertEqual(SettingsViewModel.clampA4(466), 466)
        XCTAssertEqual(SettingsViewModel.clampA4(500), 466)
    }

    func testA4RoundsToWholeHertz() {
        XCTAssertEqual(SettingsViewModel.clampA4(441.4), 441)
        XCTAssertEqual(SettingsViewModel.clampA4(441.6), 442)
    }

    func testA4NonFiniteResetsToDefault() {
        XCTAssertEqual(SettingsViewModel.clampA4(.nan), 440)
        XCTAssertEqual(SettingsViewModel.clampA4(.infinity), 440)
    }

    func testA4Label() {
        XCTAssertEqual(SettingsViewModel.a4Label(442), "442 Hz")
        XCTAssertEqual(SettingsViewModel.a4Label(1000), "466 Hz")
    }

    func testSensitivityAndCountInClamps() {
        XCTAssertEqual(SettingsViewModel.clampSensitivity(-1), 0)
        XCTAssertEqual(SettingsViewModel.clampSensitivity(2), 1)
        XCTAssertEqual(SettingsViewModel.clampSensitivity(.nan), 0.5)
        XCTAssertEqual(SettingsViewModel.clampCountIn(-3), 0)
        XCTAssertEqual(SettingsViewModel.clampCountIn(5), 2)
        XCTAssertEqual(SettingsViewModel.countInLabel(0), "None")
        XCTAssertEqual(SettingsViewModel.countInLabel(1), "1 measure")
        XCTAssertEqual(SettingsViewModel.countInLabel(2), "2 measures")
    }

    func testNearestSpeed() {
        XCTAssertEqual(SettingsViewModel.nearestSpeed(1.0), .full)
        XCTAssertEqual(SettingsViewModel.nearestSpeed(0.6), .half)
        XCTAssertEqual(SettingsViewModel.nearestSpeed(0.7), .threeQuarters)
        XCTAssertEqual(SettingsViewModel.nearestSpeed(0.1), .quarter)
        XCTAssertEqual(SettingsViewModel.nearestSpeed(1.5), .full)
    }

    func testSensitivityLabels() {
        XCTAssertEqual(SettingsViewModel.sensitivityLabel(0.1), "Low")
        XCTAssertEqual(SettingsViewModel.sensitivityLabel(0.5), "Medium")
        XCTAssertEqual(SettingsViewModel.sensitivityLabel(0.9), "High")
    }
}

// MARK: - Settings mapping view model

@MainActor
final class SettingsViewModelTests: XCTestCase {
    private var directory: URL!

    override func setUp() {
        super.setUp()
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsTests-\(UUID().uuidString)", isDirectory: true)
    }

    override func tearDown() {
        if let directory, FileManager.default.fileExists(atPath: directory.path) {
            XCTAssertNoThrow(try FileManager.default.removeItem(at: directory))
        }
        directory = nil
        super.tearDown()
    }

    private func makeModel() -> (SettingsViewModel, ProfileStore) {
        let store = ProfileStore(directory: directory)
        return (SettingsViewModel(store: store), store)
    }

    func testInputSettingsMapToProfile() {
        let (model, store) = makeModel()
        model.preferredInput = .midi
        model.microphoneSensitivity = 1.7
        model.a4Hertz = 470
        XCTAssertEqual(store.settings.preferredInput, .midi)
        XCTAssertEqual(store.settings.microphoneSensitivity, 1)
        XCTAssertEqual(store.settings.a4Hertz, 466)
        model.a4Hertz = 442.2
        XCTAssertEqual(store.settings.a4Hertz, 442)
        model.resetA4()
        XCTAssertEqual(store.settings.a4Hertz, 440)
    }

    func testPracticeDefaultsMapToDefaultPractice() {
        let (model, store) = makeModel()
        model.defaultMode = .justPlay
        model.defaultHands = .left
        model.defaultSpeed = .half
        model.countInMeasures = 9
        model.playOtherHands = false
        model.octaveTolerance = true
        model.metronome = true
        let practice = store.settings.defaultPractice
        XCTAssertEqual(practice.mode, .justPlay)
        XCTAssertEqual(practice.hands, .left)
        XCTAssertEqual(practice.speed, 0.5)
        XCTAssertEqual(practice.countInMeasures, 2)
        XCTAssertFalse(practice.playOtherHands)
        XCTAssertTrue(practice.octaveTolerance)
        XCTAssertTrue(practice.metronome)
        XCTAssertEqual(model.defaultSpeed, .half)
    }

    func testDisplayTogglesMapToSettings() {
        let (model, store) = makeModel()
        model.showNoteNames = false
        model.showFallingNotes = false
        XCTAssertFalse(store.settings.showNoteNames)
        XCTAssertFalse(store.settings.showFallingNotes)
    }

    func testTranscriptionModelMapping() {
        let (model, store) = makeModel()
        XCTAssertEqual(model.transcriptionModel, .opus)
        model.transcriptionModel = .sonnet
        XCTAssertEqual(store.settings.transcriptionModel, "claude-sonnet-5-5")
        store.settings.transcriptionModel = "some-retired-model"
        XCTAssertEqual(model.transcriptionModel, .opus)
    }

    func testOnboardingFlags() {
        let (model, store) = makeModel()
        XCTAssertFalse(store.settings.hasCompletedOnboarding)
        model.completeOnboarding()
        XCTAssertTrue(store.settings.hasCompletedOnboarding)
        model.replayOnboarding()
        XCTAssertFalse(store.settings.hasCompletedOnboarding)
    }

    func testResetProgressKeepsSettings() {
        let (model, store) = makeModel()
        model.a4Hertz = 443
        store.toggleFavorite(songID: "fur-elise")
        store.markLessonCompleted("lesson-1")
        XCTAssertEqual(model.progressSummary, "0 practiced arrangements, 1 lesson, 1 favorite")
        model.resetProgress()
        XCTAssertTrue(store.profile.favoriteSongIDs.isEmpty)
        XCTAssertTrue(store.profile.lessons.isEmpty)
        XCTAssertEqual(store.settings.a4Hertz, 443)
    }

    func testSettingsPersistAcrossStores() {
        let (model, store) = makeModel()
        model.preferredInput = .virtualKeyboard
        model.a4Hertz = 432
        store.saveNow()
        let reloaded = ProfileStore(directory: directory)
        XCTAssertEqual(reloaded.settings.preferredInput, .virtualKeyboard)
        XCTAssertEqual(reloaded.settings.a4Hertz, 432)
    }
}

// MARK: - Input selection

final class SettingsInputSelectionTests: XCTestCase {
    func testUndeterminedMicrophoneFallsBackToOnScreen() {
        XCTAssertEqual(SettingsInputMonitor.selection(for: .microphone, permission: .undetermined), .onScreenOnly)
        XCTAssertEqual(SettingsInputMonitor.selection(for: .microphone, permission: .granted), .microphone)
        XCTAssertEqual(SettingsInputMonitor.selection(for: .microphone, permission: .denied), .microphone)
        XCTAssertEqual(SettingsInputMonitor.selection(for: .midi, permission: .undetermined), .midi)
        XCTAssertEqual(SettingsInputMonitor.selection(for: .virtualKeyboard, permission: .granted), .onScreenOnly)
    }

    func testSetupTestRangeWidensForOutOfRangeNotes() {
        XCTAssertEqual(SettingsSetupTestLayout.visibleRange(for: [], recent: []), KeyboardRangeFitter.defaultRange)
        XCTAssertEqual(SettingsSetupTestLayout.visibleRange(for: [60], recent: [64]), KeyboardRangeFitter.defaultRange)
        XCTAssertEqual(SettingsSetupTestLayout.visibleRange(for: [24], recent: []), Pitch.pianoRange)
        XCTAssertEqual(SettingsSetupTestLayout.visibleRange(for: [], recent: [105]), Pitch.pianoRange)
    }

    func testSetupTestKeyStatesAndNames() {
        let states = SettingsSetupTestLayout.keyStates(for: [60, 64, 130])
        XCTAssertEqual(states, [60: .correct, 64: .correct])
        let events = [NoteInputEvent.on(60, time: 0, source: .midi), .on(64, time: 1, source: .midi)]
        XCTAssertEqual(SettingsSetupTestLayout.recentNames(events), "C4  E4")
        XCTAssertEqual(SettingsSetupTestLayout.recentNames([]), "–")
    }

    func testNoteOnsSinceBaselineDropStaleAndOffEvents() {
        let events: [NoteInputEvent] = [.on(60, time: 10, source: .midi), .off(60, time: 11, source: .midi),
                                        .on(62, time: 20, source: .midi), .off(62, time: 21, source: .midi),
                                        .on(64, time: 30, source: .microphone)]
        XCTAssertEqual(SettingsSetupTestLayout.noteOns(events, since: nil).map(\.midi), [60, 62, 64])
        XCTAssertEqual(SettingsSetupTestLayout.noteOns(events, since: 20).map(\.midi), [62, 64])
        XCTAssertEqual(SettingsSetupTestLayout.noteOns(events, since: 25).map(\.midi), [64])
        XCTAssertTrue(SettingsSetupTestLayout.noteOns(events, since: 31).isEmpty)
        // The onboarding "Try it" page uses +infinity before it has a baseline: nothing counts.
        XCTAssertTrue(SettingsSetupTestLayout.noteOns(events, since: .infinity).isEmpty)
        XCTAssertEqual(SettingsSetupTestLayout.recentNames(SettingsSetupTestLayout.noteOns(events, since: 31)), "–")
    }

    func testFreshNoteOnRequiresNoteAfterBaseline() {
        let stale = NoteInputEvent.on(60, time: 5, source: .midi)
        let fresh = NoteInputEvent.on(67, time: 15, source: .virtualKeyboard)
        XCTAssertNil(SettingsSetupTestLayout.freshNoteOn(nil, since: nil))
        XCTAssertEqual(SettingsSetupTestLayout.freshNoteOn(stale, since: nil), stale)
        XCTAssertNil(SettingsSetupTestLayout.freshNoteOn(stale, since: 10))
        XCTAssertEqual(SettingsSetupTestLayout.freshNoteOn(fresh, since: 10), fresh)
        XCTAssertEqual(SettingsSetupTestLayout.freshNoteOn(fresh, since: 15), fresh, "a note at the baseline counts")
        XCTAssertNil(SettingsSetupTestLayout.freshNoteOn(fresh, since: .infinity))
        XCTAssertNil(SettingsSetupTestLayout.freshNoteOn(.off(67, time: 20, source: .midi), since: 10))
    }
}

// MARK: - API key check

final class SettingsAPIKeyCheckTests: XCTestCase {
    func testRequestUsesDocumentedHeadersAndTinyBody() throws {
        let request = try SettingsAPIKeyCheck.makeRequest(apiKey: "  sk-ant-abc  ", model: "claude-opus-5-5")
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-ant-abc")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2023-06-01")
        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["model"] as? String, "claude-opus-5-5")
        XCTAssertEqual(json["max_tokens"] as? Int, 16)
        XCTAssertNil(json["thinking"])
        let messages = try XCTUnwrap(json["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["role"] as? String, "user")
        XCTAssertEqual(messages.first?["content"] as? String, "Reply with OK")
    }

    func testEmptyKeyIsRejected() {
        XCTAssertThrowsError(try SettingsAPIKeyCheck.makeRequest(apiKey: "   ", model: "claude-opus-5-5")) { error in
            XCTAssertEqual(error as? SettingsAPIKeyCheck.BuildError, .emptyKey)
        }
    }

    func testSuccessWithText() {
        let data = Data(#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"OK"}],"stop_reason":"end_turn"}"#.utf8)
        let result = SettingsAPIKeyCheck.interpret(statusCode: 200, data: data, model: "claude-opus-5-5")
        XCTAssertTrue(result.isSuccess)
        XCTAssertTrue(result.message.contains("OK"))
        XCTAssertTrue(result.message.contains("Claude Opus 5.5"))
    }

    func testSuccessWithoutTextWhenBudgetSpentOnThinking() {
        let data = Data(#"{"content":[{"type":"thinking","thinking":""}],"stop_reason":"max_tokens"}"#.utf8)
        let result = SettingsAPIKeyCheck.interpret(statusCode: 200, data: data, model: "claude-sonnet-5-5")
        XCTAssertTrue(result.isSuccess)
    }

    func testErrorStatuses() {
        let body = Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"model: bad"}}"#.utf8)
        XCTAssertFalse(SettingsAPIKeyCheck.interpret(statusCode: 401, data: body, model: "m").isSuccess)
        XCTAssertTrue(SettingsAPIKeyCheck.interpret(statusCode: 401, data: body, model: "m").message.contains("401"))
        XCTAssertEqual(SettingsAPIKeyCheck.interpret(statusCode: 400, data: body, model: "m"), .failure("model: bad"))
        XCTAssertTrue(SettingsAPIKeyCheck.interpret(statusCode: 429, data: Data(), model: "m").message.contains("429"))
        XCTAssertTrue(SettingsAPIKeyCheck.interpret(statusCode: 529, data: Data(), model: "m").message.contains("overloaded"))
        XCTAssertTrue(SettingsAPIKeyCheck.interpret(statusCode: 503, data: Data(), model: "m").message.contains("503"))
        XCTAssertEqual(SettingsAPIKeyCheck.interpret(statusCode: 400, data: Data("not json".utf8), model: "m"),
                       .failure("The API rejected the request (400)."))
    }

    func testErrorMessageParsing() {
        XCTAssertEqual(SettingsAPIKeyCheck.errorMessage(in: Data(#"{"error":{"message":"x"}}"#.utf8)), "x")
        XCTAssertNil(SettingsAPIKeyCheck.errorMessage(in: Data(#"{"error":{}}"#.utf8)))
        XCTAssertNil(SettingsAPIKeyCheck.errorMessage(in: Data()))
    }

    func testTranscriptionModelStoredIDMapping() {
        XCTAssertEqual(SettingsTranscriptionModel(storedID: "claude-opus-5-5"), .opus)
        XCTAssertEqual(SettingsTranscriptionModel(storedID: " claude-sonnet-5-5 "), .sonnet)
        XCTAssertEqual(SettingsTranscriptionModel(storedID: ""), .opus)
    }
}

// MARK: - API key model

@MainActor
final class SettingsAPIKeyModelTests: XCTestCase {
    private var keychain: SettingsKeychain!

    override func setUp() {
        super.setUp()
        keychain = SettingsKeychain(service: "com.sajadabvi.LearnPiano.tests.\(UUID().uuidString)", account: "anthropic-api-key")
    }

    override func tearDown() {
        XCTAssertNoThrow(try keychain.delete())
        keychain = nil
        super.tearDown()
    }

    func testSaveLoadRemove() throws {
        let model = SettingsAPIKeyModel(keychain: keychain) { _, _ in .success("unused") }
        model.load()
        XCTAssertFalse(model.hasSavedKey)
        model.draft = "  sk-ant-api03-abcdefghijklmnopWXYZ "
        model.save()
        XCTAssertEqual(model.draft, "")
        XCTAssertEqual(model.savedKeyMask, "••••WXYZ")
        XCTAssertEqual(try keychain.read(), "sk-ant-api03-abcdefghijklmnopWXYZ")
        let reloaded = SettingsAPIKeyModel(keychain: keychain) { _, _ in .success("unused") }
        reloaded.load()
        XCTAssertTrue(reloaded.hasSavedKey)
        reloaded.remove()
        XCTAssertFalse(reloaded.hasSavedKey)
        XCTAssertNil(try keychain.read())
    }

    func testTestUsesDraftThenSavedKey() async throws {
        var seen: [(String, String)] = []
        let model = SettingsAPIKeyModel(keychain: keychain) { key, modelID in
            seen.append((key, modelID))
            return .success("ok")
        }
        model.test(model: "claude-opus-5-5")
        XCTAssertEqual(model.testResult, .failure("Enter or save an API key first."))
        try keychain.write("sk-ant-saved")
        model.test(model: "claude-sonnet-5-5")
        await model.waitForTest()
        XCTAssertEqual(seen.last?.0, "sk-ant-saved")
        XCTAssertEqual(seen.last?.1, "claude-sonnet-5-5")
        XCTAssertEqual(model.testResult, .success("ok"))
        XCTAssertFalse(model.isTesting)
        model.draft = "sk-ant-draft"
        model.test(model: "claude-opus-5-5")
        await model.waitForTest()
        XCTAssertEqual(seen.last?.0, "sk-ant-draft")
    }

    func testDraftWarning() {
        let model = SettingsAPIKeyModel(keychain: keychain) { _, _ in .success("") }
        XCTAssertNil(model.draftWarning)
        model.draft = "hello"
        XCTAssertNotNil(model.draftWarning)
        model.draft = "sk-ant-api03-abcdefghijklmnop"
        XCTAssertNil(model.draftWarning)
    }
}

// MARK: - Formatting and preferences

final class SettingsFormattingTests: XCTestCase {
    func testVersionString() {
        XCTAssertEqual(SettingsFormatting.versionString(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "7"]), "Version 0.1.0 (7)")
        XCTAssertEqual(SettingsFormatting.versionString(info: ["CFBundleShortVersionString": "1.0"]), "Version 1.0")
        XCTAssertEqual(SettingsFormatting.versionString(info: nil), "Version –")
    }

    func testMaskedKey() {
        XCTAssertEqual(SettingsFormatting.maskedKey("sk-ant-1234567890abcd"), "••••abcd")
        XCTAssertEqual(SettingsFormatting.maskedKey("short"), "•••••")
    }

    func testDirectorySize() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("SettingsSize-\(UUID().uuidString)", isDirectory: true)
        defer { XCTAssertNoThrow(try FileManager.default.removeItem(at: dir)) }
        let nested = dir.appendingPathComponent("song", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data(count: 100).write(to: dir.appendingPathComponent("a.json"))
        try Data(count: 250).write(to: nested.appendingPathComponent("b.json"))
        XCTAssertEqual(SettingsFormatting.directorySize(at: dir), 350)
        XCTAssertEqual(SettingsFormatting.directorySize(at: dir.appendingPathComponent("missing")), 0)
    }

    func testMasterVolumePreference() throws {
        let suite = "SettingsTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertEqual(SettingsAudioPreferences.masterVolume(in: defaults), 0.9)
        SettingsAudioPreferences.setMasterVolume(0.4, in: defaults)
        XCTAssertEqual(SettingsAudioPreferences.masterVolume(in: defaults), 0.4, accuracy: 1e-9)
        SettingsAudioPreferences.setMasterVolume(3, in: defaults)
        XCTAssertEqual(SettingsAudioPreferences.masterVolume(in: defaults), 1)
    }

    func testOnboardingPageOrder() {
        XCTAssertEqual(SettingsOnboardingPage.allCases.count, 4)
        XCTAssertEqual(SettingsOnboardingPage.welcome.next, .instrument)
        XCTAssertNil(SettingsOnboardingPage.welcome.previous)
        XCTAssertTrue(SettingsOnboardingPage.tryIt.isLast)
    }

    func testRepositoryURL() {
        XCTAssertEqual(SettingsAbout.repositoryURL?.absoluteString, "https://github.com/sajadabvi/learn_piano_IOS")
    }
}
