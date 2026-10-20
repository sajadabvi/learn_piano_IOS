import XCTest
@testable import LearnPiano

@MainActor
final class LibraryTests: XCTestCase {
    // MARK: Fixtures

    private func arrangement(_ id: String, _ difficulty: Difficulty, measures: Int = 16) -> ArrangementEntry {
        ArrangementEntry(id: id, label: difficulty.displayName, difficulty: difficulty, storage: .bundled(fileName: "\(id).musicxml"),
                         tempoBPM: 90, keySignature: "C major", timeSignature: "4/4", measures: measures)
    }

    private lazy var furElise = SongEntry(
        id: "fur-elise", title: "Für Elise", composer: "Ludwig van Beethoven", genre: "Classical",
        categories: ["Classical", "Famous Melodies"],
        arrangements: [arrangement("fur-elise-advanced", .advanced, measures: 23), arrangement("fur-elise-beginner", .beginner, measures: 9)]
    )
    private lazy var odeToJoy = SongEntry(
        id: "ode-to-joy", title: "Ode to Joy", composer: "Ludwig van Beethoven", genre: "Classical",
        categories: ["Classical", "Easy Classics"],
        arrangements: [arrangement("ode-beginner", .beginner), arrangement("ode-intermediate", .intermediate)]
    )
    private lazy var entertainer = SongEntry(
        id: "the-entertainer", title: "The Entertainer", composer: "Scott Joplin", genre: "Ragtime",
        categories: ["Ragtime & Jazz", "Film & TV"],
        arrangements: [arrangement("ent-intermediate", .intermediate), arrangement("ent-advanced", .advanced)]
    )
    private lazy var clair = SongEntry(
        id: "clair-de-lune", title: "Clair de Lune", composer: "Claude Debussy", genre: "Classical",
        categories: ["Classical"],
        arrangements: [arrangement("clair-pro", .pro)]
    )
    private lazy var scale = SongEntry(
        id: "ex-c-major-scale", title: "C Major Scale", composer: "", genre: "Exercise",
        categories: ["Exercises"], isExercise: true,
        arrangements: [arrangement("ex-c-major-scale-beginner", .beginner)]
    )

    private var allSongs: [SongEntry] { [furElise, odeToJoy, entertainer, clair, scale] }

    private func lookup(_ songs: [SongEntry]) -> (String) -> (song: SongEntry, arrangement: ArrangementEntry)? {
        { id in
            for s in songs { if let a = s.arrangement(id: id) { return (s, a) } }
            return nil
        }
    }

    private func summary(_ arrangementID: String, startedAt: Date, duration: Double = 60, mode: PracticeMode = .wait,
                         steps: Int = 10, correct: Int = 10, wrong: Int = 0, measures: Set<Int> = [], reachedEnd: Bool = false,
                         mistakes: [Int: Int] = [:], speed: Double = 1) -> PracticeSummary {
        PracticeSummary(arrangementID: arrangementID, startedAt: startedAt, durationSeconds: duration, mode: mode, hands: .both, speed: speed,
                        stepsExpected: steps, stepsCorrect: correct, wrongNotes: wrong, mistakesByMeasure: mistakes,
                        measuresCompleted: measures, reachedEnd: reachedEnd)
    }

    private var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC") ?? TimeZone(secondsFromGMT: 0) ?? .current
        return c
    }

    /// 2026-10-19 15:00 UTC.
    private let now = Date(timeIntervalSince1970: 1_792_422_000)

    // MARK: Filtering

    func testCategoryChipsStartWithAllAndSkipExercises() {
        let chips = LibraryBrowserFilter.categoryChips(from: ["Classical", "Exercises", "Famous Melodies", "Classical", " "])
        XCTAssertEqual(chips, [nil, "Classical", "Famous Melodies"])
    }

    func testFilterByCategory() {
        let result = LibraryBrowserFilter.apply(to: allSongs, category: "Easy Classics", difficulty: nil)
        XCTAssertEqual(result.map(\.id), ["ode-to-joy"])
    }

    func testFilterByDifficultyKeepsSongsWithAnArrangementAtThatLevel() {
        XCTAssertEqual(LibraryBrowserFilter.apply(to: allSongs, category: nil, difficulty: .advanced).map(\.id), ["fur-elise", "the-entertainer"])
        XCTAssertEqual(LibraryBrowserFilter.apply(to: allSongs, category: nil, difficulty: .pro).map(\.id), ["clair-de-lune"])
        XCTAssertEqual(LibraryBrowserFilter.apply(to: allSongs, category: nil, difficulty: .beginner).map(\.id), ["fur-elise", "ode-to-joy"])
    }

    func testFilterNeverReturnsExercises() {
        let all = LibraryBrowserFilter.apply(to: allSongs, category: nil, difficulty: nil)
        XCTAssertFalse(all.contains { $0.isExercise })
        XCTAssertEqual(all.count, 4)
        XCTAssertTrue(LibraryBrowserFilter.apply(to: allSongs, category: "Exercises", difficulty: nil).isEmpty)
    }

    func testCombinedCategoryAndDifficulty() {
        XCTAssertEqual(LibraryBrowserFilter.apply(to: allSongs, category: "Classical", difficulty: .intermediate).map(\.id), ["ode-to-joy"])
        XCTAssertTrue(LibraryBrowserFilter.apply(to: allSongs, category: "Film & TV", difficulty: .beginner).isEmpty)
    }

    func testQueryMatchesTitleAndComposerIgnoringCaseAndDiacritics() {
        XCTAssertTrue(LibraryBrowserFilter.matches(furElise, query: "fur"))
        XCTAssertTrue(LibraryBrowserFilter.matches(furElise, query: "  ELISE "))
        XCTAssertTrue(LibraryBrowserFilter.matches(furElise, query: "beethoven"))
        XCTAssertFalse(LibraryBrowserFilter.matches(furElise, query: "joplin"))
        XCTAssertTrue(LibraryBrowserFilter.matches(furElise, query: ""))
    }

    func testModelCombinesSearchCategoryAndDifficulty() {
        let model = LibraryBrowserModel()
        let songs = allSongs
        let search: (String) -> [SongEntry] = { q in songs.filter { LibraryBrowserFilter.matches($0, query: q) } }

        XCTAssertEqual(model.results(search: search).count, 4)
        XCTAssertFalse(model.hasActiveFilters)

        model.query = "beethoven"
        XCTAssertEqual(model.results(search: search).map(\.id), ["fur-elise", "ode-to-joy"])

        model.selectedDifficulty = .advanced
        XCTAssertEqual(model.results(search: search).map(\.id), ["fur-elise"])

        model.selectedCategory = "Easy Classics"
        XCTAssertTrue(model.results(search: search).isEmpty)
        XCTAssertEqual(model.emptyResultsMessage, "No songs matching \u{201C}beethoven\u{201D} in Easy Classics at Advanced level.")

        model.clearFilters()
        XCTAssertFalse(model.hasActiveFilters)
        XCTAssertEqual(model.results(search: search).count, 4)
    }

    func testModelPassesQueryToSearch() {
        let model = LibraryBrowserModel(query: "joplin")
        var received: [String] = []
        _ = model.results { q in received.append(q); return [] }
        XCTAssertEqual(received, ["joplin"])
    }

    func testValidateCategoryDropsMissingCategory() {
        let model = LibraryBrowserModel(selectedCategory: "Imported")
        model.validateCategory(against: [nil, "Classical"])
        XCTAssertNil(model.selectedCategory)

        model.selectedCategory = "Classical"
        model.validateCategory(against: [nil, "Classical"])
        XCTAssertEqual(model.selectedCategory, "Classical")
    }

    func testDifficultyOptionsStartWithAll() {
        XCTAssertEqual(LibraryBrowserModel.difficultyOptions, [nil, .beginner, .intermediate, .advanced, .pro])
        XCTAssertEqual(LibraryBrowserModel.difficultyOptions.map(LibraryFormatting.difficultyFilterLabel),
                       ["All", "Beginner", "Intermediate", "Advanced", "Pro"])
    }

    // MARK: Recents

    func testRecentItemsFollowProfileOrderAndSkipMissingAndExercises() {
        var profile = UserProfile()
        let base = now.addingTimeInterval(-10 * 86_400)
        profile.record(summary("ode-beginner", startedAt: base))
        profile.record(summary("ex-c-major-scale-beginner", startedAt: base.addingTimeInterval(3_600)))
        profile.record(summary("fur-elise-advanced", startedAt: base.addingTimeInterval(7_200)))
        profile.record(summary("deleted-song-beginner", startedAt: base.addingTimeInterval(9_000)))
        profile.record(summary("clair-pro", startedAt: base.addingTimeInterval(5_000)))

        XCTAssertEqual(profile.recentArrangementIDs.first, "deleted-song-beginner")

        let items = LibraryRecents.items(recentArrangementIDs: profile.recentArrangementIDs, lookup: lookup(allSongs), progress: { profile.progress[$0] })
        XCTAssertEqual(items.map(\.id), ["fur-elise-advanced", "clair-pro", "ode-beginner"])
        XCTAssertEqual(items.first?.song.id, "fur-elise")
        XCTAssertEqual(items.first?.progress?.sessions, 1)
    }

    func testRecentItemsRespectLimitAndDuplicates() {
        let ids = ["ode-beginner", "ode-beginner", "fur-elise-beginner", "clair-pro"]
        let items = LibraryRecents.items(recentArrangementIDs: ids, lookup: lookup(allSongs), progress: { _ in nil }, limit: 2)
        XCTAssertEqual(items.map(\.id), ["ode-beginner", "fur-elise-beginner"])
    }

    func testRecentSongsDeduplicateBySongKeepingMostRecentPosition() {
        let ids = ["fur-elise-beginner", "ode-intermediate", "fur-elise-advanced", "ex-c-major-scale-beginner", "ode-beginner", "clair-pro"]
        let songs = LibraryRecents.songs(recentArrangementIDs: ids, lookup: lookup(allSongs))
        XCTAssertEqual(songs.map(\.id), ["fur-elise", "ode-to-joy", "clair-de-lune"])
    }

    func testFavoritesKeepProfileOrderAndSkipUnknownIDs() {
        let byID = Dictionary(uniqueKeysWithValues: allSongs.map { ($0.id, $0) })
        let favorites = LibraryRecents.favorites(ids: ["clair-de-lune", "gone", "fur-elise", "clair-de-lune"]) { byID[$0] }
        XCTAssertEqual(favorites.map(\.id), ["clair-de-lune", "fur-elise"])
    }

    // MARK: Mastery

    func testMasteryFormatting() {
        XCTAssertEqual(LibraryFormatting.percent(0), "0%")
        XCTAssertEqual(LibraryFormatting.percent(0.424), "42%")
        XCTAssertEqual(LibraryFormatting.percent(0.425), "43%")
        XCTAssertEqual(LibraryFormatting.percent(1.3), "100%")
        XCTAssertEqual(LibraryFormatting.percent(-0.2), "0%")
        XCTAssertEqual(LibraryFormatting.percent(.nan), "0%")
        XCTAssertEqual(LibraryFormatting.mastery(nil), "New")
        XCTAssertEqual(LibraryFormatting.mastery(0.5), "50%")
        XCTAssertEqual(LibraryFormatting.masteryAccessibility(0.5), "50% mastered")
        XCTAssertEqual(LibraryFormatting.bestAccuracy(nil), "–")
        XCTAssertEqual(LibraryFormatting.bestAccuracy(0.876), "88%")
        XCTAssertEqual(LibraryFormatting.bestCleanSpeed(0.75), "75% speed")
    }

    func testArrangementMasteryIsNilWhenNeverPracticed() {
        let a = arrangement("ode-beginner", .beginner, measures: 8)
        XCTAssertNil(LibraryMastery.arrangementMastery(nil, arrangement: a))
        XCTAssertNil(LibraryMastery.arrangementMastery(SongProgress(arrangementID: a.id), arrangement: a))
    }

    func testArrangementMasteryUsesCatalogMeasureCount() {
        let a = arrangement("ode-beginner", .beginner, measures: 8)
        var p = SongProgress(arrangementID: a.id)
        p.record(summary(a.id, startedAt: now, measures: [0, 1, 2, 3]))
        // Half the measures covered, no quality yet: 0.5 × 0.5.
        XCTAssertEqual(LibraryMastery.arrangementMastery(p, arrangement: a) ?? -1, 0.25, accuracy: 1e-9)

        p.record(summary(a.id, startedAt: now, mode: .wait, measures: Set(0..<8), reachedEnd: true))
        XCTAssertEqual(LibraryMastery.arrangementMastery(p, arrangement: a) ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertEqual(LibraryFormatting.mastery(LibraryMastery.arrangementMastery(p, arrangement: a)), "100%")
    }

    func testArrangementMasteryFallsBackToCompletedMeasuresWhenCountUnknown() {
        let a = arrangement("x", .beginner, measures: 0)
        var p = SongProgress(arrangementID: "x")
        p.record(summary("x", startedAt: now, measures: [0, 1, 2, 3]))
        XCTAssertEqual(LibraryMastery.arrangementMastery(p, arrangement: a) ?? -1, 0.5, accuracy: 1e-9)
    }

    func testSongMasteryIsBestArrangement() {
        var progress: [String: SongProgress] = [:]
        var beginner = SongProgress(arrangementID: "fur-elise-beginner")
        beginner.record(summary("fur-elise-beginner", startedAt: now, measures: Set(0..<9), reachedEnd: true))
        progress[beginner.arrangementID] = beginner
        var advanced = SongProgress(arrangementID: "fur-elise-advanced")
        advanced.record(summary("fur-elise-advanced", startedAt: now, measures: [0]))
        progress[advanced.arrangementID] = advanced

        let m = LibraryMastery.songMastery(furElise) { progress[$0] }
        XCTAssertEqual(m ?? -1, 1.0, accuracy: 1e-9)
        XCTAssertNil(LibraryMastery.songMastery(clair) { progress[$0] })
    }

    func testPreferredArrangementIsMostRecentlyPracticedElseEasiest() {
        XCTAssertEqual(LibraryMastery.preferredArrangement(of: furElise) { _ in nil }?.id, "fur-elise-beginner")
        var p = SongProgress(arrangementID: "fur-elise-advanced")
        p.record(summary("fur-elise-advanced", startedAt: now))
        XCTAssertEqual(LibraryMastery.preferredArrangement(of: furElise) { $0 == p.arrangementID ? p : nil }?.id, "fur-elise-advanced")
    }

    // MARK: Dates and durations

    func testRelativeDays() {
        let c = utc
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-3_600), now: now, calendar: c), "today")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(3_600), now: now, calendar: c), "today")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-86_400), now: now, calendar: c), "yesterday")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-2 * 86_400), now: now, calendar: c), "2 days ago")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-8 * 86_400), now: now, calendar: c), "1 week ago")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-21 * 86_400), now: now, calendar: c), "3 weeks ago")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-45 * 86_400), now: now, calendar: c), "1 month ago")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-100 * 86_400), now: now, calendar: c), "3 months ago")
        XCTAssertEqual(LibraryFormatting.relativeDay(now.addingTimeInterval(-800 * 86_400), now: now, calendar: c), "2 years ago")
    }

    func testRelativeDayCountsCalendarDaysNotHours() {
        // 23:30 the previous evening is "yesterday" at 15:00 even though it is less than 24 hours ago.
        let lateYesterday = now.addingTimeInterval(-(15.5 * 3_600))
        XCTAssertEqual(LibraryFormatting.relativeDay(lateYesterday, now: now, calendar: utc), "yesterday")
    }

    func testLastPracticedSentence() {
        XCTAssertEqual(LibraryFormatting.lastPracticed(nil, now: now, calendar: utc), "Not practiced yet")
        XCTAssertEqual(LibraryFormatting.lastPracticed(now, now: now, calendar: utc), "Practiced today")
        XCTAssertEqual(LibraryFormatting.lastPracticed(now.addingTimeInterval(-2 * 86_400), now: now, calendar: utc), "Last practiced 2 days ago")
    }

    func testDurations() {
        XCTAssertEqual(LibraryFormatting.duration(0), "0 min")
        XCTAssertEqual(LibraryFormatting.duration(-5), "0 min")
        XCTAssertEqual(LibraryFormatting.duration(45), "45 s")
        XCTAssertEqual(LibraryFormatting.duration(59.6), "1 min")
        XCTAssertEqual(LibraryFormatting.duration(12 * 60 + 20), "12 min")
        XCTAssertEqual(LibraryFormatting.duration(3_600), "1 h")
        XCTAssertEqual(LibraryFormatting.duration(2 * 3_600 + 5 * 60), "2 h 05 min")
    }

    func testEstimatedLength() {
        // 9 bars of 3/4 at 92 BPM = 27 quarters ≈ 17.6 s.
        XCTAssertEqual(LibraryFormatting.estimatedLength(measures: 9, timeSignature: "3/4", tempoBPM: 92), "≈ 0:18")
        // 23 bars of 3/8 at 66 BPM = 34.5 quarters ≈ 31.4 s.
        XCTAssertEqual(LibraryFormatting.estimatedLength(measures: 23, timeSignature: "3/8", tempoBPM: 66), "≈ 0:31")
        XCTAssertNil(LibraryFormatting.estimatedLength(measures: 0, timeSignature: "4/4", tempoBPM: 90))
        XCTAssertNil(LibraryFormatting.estimatedLength(measures: 8, timeSignature: "common", tempoBPM: 90))
    }

    // MARK: Labels

    func testDifficultyLabels() {
        XCTAssertEqual(LibraryFormatting.difficultyRange(of: furElise), "Beginner – Advanced")
        XCTAssertEqual(LibraryFormatting.difficultyRange(of: clair), "Pro")
        XCTAssertEqual(LibraryFormatting.difficulties(of: furElise), [.beginner, .advanced])
        XCTAssertEqual(LibraryFormatting.difficultyLabel(.intermediate), "Intermediate")
    }

    func testArrangementFacts() {
        XCTAssertEqual(LibraryFormatting.hands("both"), "Both hands")
        XCTAssertEqual(LibraryFormatting.hands("right"), "Right hand")
        XCTAssertEqual(LibraryFormatting.hands("LEFT"), "Left hand")
        XCTAssertEqual(LibraryFormatting.tempo(92), "♩ = 92")
        XCTAssertEqual(LibraryFormatting.measures(1), "1 measure")
        XCTAssertEqual(LibraryFormatting.measures(23), "23 measures")
        XCTAssertEqual(LibraryFormatting.troubleSpots([3, 7, 0]), "m. 4, 8, 1")
        XCTAssertNil(LibraryFormatting.troubleSpots([]))
        // Pickup scores: printed numbers start at 0, so index 3 is bar 3, not bar 4.
        XCTAssertEqual(LibraryFormatting.troubleSpots([0, 3], measureNumbers: [0, 1, 2, 3]), "m. 0, 3")
        XCTAssertEqual(LibraryFormatting.troubleSpots([0, 3]), "m. 1, 4")
        // An index the loaded score does not cover falls back to index + 1.
        XCTAssertEqual(LibraryFormatting.troubleSpots([1, 9], measureNumbers: [0, 1, 2]), "m. 1, 10")
        XCTAssertNil(LibraryFormatting.troubleSpots([], measureNumbers: [0, 1]))
        XCTAssertEqual(LibraryFormatting.composerLine(furElise), "Ludwig van Beethoven")
        var dated = furElise
        dated.year = 1810
        XCTAssertEqual(LibraryFormatting.composerLine(dated), "Ludwig van Beethoven · 1810")
    }

    // MARK: Practice launch

    func testLaunchSettings() {
        var base = PracticeSettings(mode: .listen, speed: 0.5, loop: MeasureRange(start: 0, end: 3))
        let practice = LibraryPracticeLauncher.settings(base: base, mode: nil)
        XCTAssertEqual(practice.mode, .wait)
        XCTAssertNil(practice.loop)
        XCTAssertEqual(practice.speed, 0.5, accuracy: 1e-9)

        base.mode = .justPlay
        XCTAssertEqual(LibraryPracticeLauncher.settings(base: base, mode: nil).mode, .justPlay)
        XCTAssertEqual(LibraryPracticeLauncher.settings(base: base, mode: .listen).mode, .listen)
    }

    func testLaunchSubtitleAndRecordingRule() {
        let a = furElise.arrangements[0]
        XCTAssertEqual(LibraryPracticeLauncher.subtitle(song: furElise, arrangement: a), "Beginner · Ludwig van Beethoven")
        XCTAssertFalse(LibraryPracticeLauncher.shouldRecord(summary(a.id, startedAt: now, duration: 1, steps: 0, correct: 0)))
        XCTAssertTrue(LibraryPracticeLauncher.shouldRecord(summary(a.id, startedAt: now, duration: 1, steps: 3, correct: 1)))
        XCTAssertTrue(LibraryPracticeLauncher.shouldRecord(summary(a.id, startedAt: now, duration: 30, mode: .listen, steps: 0, correct: 0)))
    }

    func testRequestOnFinishRecordsIntoProfile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("LibraryTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = ProfileStore(directory: dir)
        let a = furElise.arrangements[0]
        let score = ScoreBuilder.make(title: "Test", right: [[(pitches: ["C4"], ticks: 3_840)]])
        let request = LibraryPracticeLauncher.makeRequest(song: furElise, arrangement: a, score: score, settings: PracticeSettings(), profile: store)

        XCTAssertEqual(request.arrangementID, a.id)
        XCTAssertEqual(request.title, "Für Elise")
        let onFinish = try XCTUnwrap(request.onFinish)
        onFinish(summary(a.id, startedAt: now, measures: [0, 1]))
        onFinish(summary(a.id, startedAt: now, duration: 0.5, steps: 0, correct: 0))

        XCTAssertEqual(store.progress(forArrangement: a.id)?.sessions, 1)
        XCTAssertEqual(store.profile.recentArrangementIDs, [a.id])
    }
}
