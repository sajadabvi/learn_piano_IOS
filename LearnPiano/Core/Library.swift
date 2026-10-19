import Foundation

// MARK: - Catalog (bundled + user-imported songs)

/// Where an arrangement's score file lives.
public enum ScoreStorage: Hashable, Codable, Sendable {
    /// A resource in the app bundle (file name including extension, e.g. "fur-elise__beginner.musicxml").
    case bundled(fileName: String)
    /// A file in the user's library folder (relative path under Documents/Library/).
    case user(relativePath: String)

    public var fileName: String {
        switch self {
        case .bundled(let f): return f
        case .user(let p): return (p as NSString).lastPathComponent
        }
    }
}

/// One playable arrangement of a song at a given difficulty. Mirrors the `arrangements[]` entries of the catalog fragments
/// in Content/Songs/*.catalog.json plus the storage location.
public struct ArrangementEntry: Hashable, Codable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var difficulty: Difficulty
    public var storage: ScoreStorage
    public var tempoBPM: Int
    public var keySignature: String
    public var timeSignature: String
    public var measures: Int
    public var hands: String
    public var notes: String
    public var teachingPoints: [String]

    public init(id: String, label: String, difficulty: Difficulty, storage: ScoreStorage, tempoBPM: Int = 100, keySignature: String = "", timeSignature: String = "", measures: Int = 0, hands: String = "both", notes: String = "", teachingPoints: [String] = []) {
        self.id = id
        self.label = label
        self.difficulty = difficulty
        self.storage = storage
        self.tempoBPM = tempoBPM
        self.keySignature = keySignature
        self.timeSignature = timeSignature
        self.measures = measures
        self.hands = hands
        self.notes = notes
        self.teachingPoints = teachingPoints
    }
}

/// A song (or exercise) with one or more arrangements. Mirrors Content/Songs/<id>.catalog.json.
public struct SongEntry: Hashable, Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var composer: String
    public var genre: String
    public var categories: [String]
    public var year: Int?
    public var description: String
    public var isExercise: Bool
    /// True for songs the user imported (stored under Documents).
    public var isUserImported: Bool
    public var dateAdded: Date?
    public var arrangements: [ArrangementEntry]

    public init(id: String, title: String, composer: String, genre: String, categories: [String] = [], year: Int? = nil, description: String = "", isExercise: Bool = false, isUserImported: Bool = false, dateAdded: Date? = nil, arrangements: [ArrangementEntry]) {
        self.id = id
        self.title = title
        self.composer = composer
        self.genre = genre
        self.categories = categories
        self.year = year
        self.description = description
        self.isExercise = isExercise
        self.isUserImported = isUserImported
        self.dateAdded = dateAdded
        self.arrangements = arrangements.sorted { $0.difficulty < $1.difficulty }
    }

    public var easiestDifficulty: Difficulty? { arrangements.map { $0.difficulty }.min() }
    public var hardestDifficulty: Difficulty? { arrangements.map { $0.difficulty }.max() }
    public func arrangement(id: String) -> ArrangementEntry? { arrangements.first { $0.id == id } }
}

/// Raw shape of the JSON catalog fragments written by content authors (Content/Songs/*.catalog.json).
/// Decode this, then convert with `songEntry(bundled:)`.
public struct CatalogFragment: Codable, Sendable {
    public struct Arrangement: Codable, Sendable {
        public var id: String
        public var label: String
        public var difficulty: String
        public var file: String
        public var tempoBPM: Int?
        public var keySignature: String?
        public var timeSignature: String?
        public var measures: Int?
        public var hands: String?
        public var notes: String?
        public var teachingPoints: [String]?
    }
    public var id: String
    public var title: String
    public var composer: String
    public var genre: String
    public var categories: [String]?
    public var year: Int?
    public var description: String?
    public var isExercise: Bool?
    public var arrangements: [Arrangement]

    /// Converts to a catalog entry whose files live in the app bundle.
    public func songEntry() -> SongEntry {
        SongEntry(
            id: id, title: title, composer: composer, genre: genre,
            categories: categories ?? [genre], year: year, description: description ?? "",
            isExercise: isExercise ?? false, isUserImported: false, dateAdded: nil,
            arrangements: arrangements.map { a in
                ArrangementEntry(
                    id: a.id, label: a.label, difficulty: Difficulty(rawValue: a.difficulty.lowercased()) ?? .beginner,
                    storage: .bundled(fileName: a.file), tempoBPM: a.tempoBPM ?? 100,
                    keySignature: a.keySignature ?? "", timeSignature: a.timeSignature ?? "",
                    measures: a.measures ?? 0, hands: a.hands ?? "both", notes: a.notes ?? "",
                    teachingPoints: a.teachingPoints ?? []
                )
            }
        )
    }
}

// MARK: - Progress and profile

/// Accumulated progress for one arrangement.
public struct SongProgress: Hashable, Codable, Sendable {
    public var arrangementID: String
    public var sessions: Int
    public var totalSeconds: Double
    public var lastPracticed: Date?
    /// Best Just-Play accuracy (0…1) at full speed, nil if never completed in Just Play.
    public var bestAccuracy: Double?
    /// Best speed at which the whole piece was completed in Wait Mode with no wrong notes.
    public var bestCleanSpeed: Double?
    /// Notated measures completed at least once (any mode).
    public var measuresCompleted: Set<Int>
    /// Lifetime wrong notes per notated measure, to surface "trouble spots".
    public var mistakesByMeasure: [Int: Int]
    public var completedOnce: Bool

    public init(arrangementID: String) {
        self.arrangementID = arrangementID
        sessions = 0
        totalSeconds = 0
        lastPracticed = nil
        bestAccuracy = nil
        bestCleanSpeed = nil
        measuresCompleted = []
        mistakesByMeasure = [:]
        completedOnce = false
    }

    /// Folds a finished session into the progress.
    public mutating func record(_ s: PracticeSummary) {
        sessions += 1
        totalSeconds += s.durationSeconds
        lastPracticed = s.startedAt.addingTimeInterval(s.durationSeconds)
        measuresCompleted.formUnion(s.measuresCompleted)
        for (m, n) in s.mistakesByMeasure { mistakesByMeasure[m, default: 0] += n }
        if s.reachedEnd {
            completedOnce = true
            if s.mode == .justPlay, s.speed >= 0.99 { bestAccuracy = max(bestAccuracy ?? 0, s.accuracy) }
            if s.mode == .wait, s.wrongNotes == 0, s.hands == .both { bestCleanSpeed = max(bestCleanSpeed ?? 0, s.speed) }
        }
    }

    /// 0…1 mastery estimate shown on cards: completion × accuracy/speed.
    public func mastery(measureCount: Int) -> Double {
        guard measureCount > 0 else { return 0 }
        let coverage = Double(measuresCompleted.count) / Double(measureCount)
        let quality = max(bestAccuracy ?? 0, bestCleanSpeed ?? 0)
        return min(1, 0.5 * coverage + 0.5 * quality * (completedOnce ? 1 : 0.5))
    }

    /// Measures with the most mistakes, worst first.
    public var troubleSpots: [Int] { mistakesByMeasure.sorted { $0.value > $1.value }.prefix(3).map { $0.key } }
}

/// Progress for one lesson.
public struct LessonProgress: Hashable, Codable, Sendable {
    public var lessonID: String
    public var completedExerciseIDs: Set<String>
    public var completed: Bool
    public var lastOpened: Date?
    public init(lessonID: String, completedExerciseIDs: Set<String> = [], completed: Bool = false, lastOpened: Date? = nil) {
        self.lessonID = lessonID
        self.completedExerciseIDs = completedExerciseIDs
        self.completed = completed
        self.lastOpened = lastOpened
    }
}

/// App-wide user settings persisted with the profile (device-local).
public struct UserSettings: Hashable, Codable, Sendable {
    public var preferredInput: InputSourceKind
    public var microphoneSensitivity: Double
    public var a4Hertz: Double
    public var showNoteNames: Bool
    public var showFallingNotes: Bool
    public var defaultPractice: PracticeSettings
    public var transcriptionModel: String
    public var hasCompletedOnboarding: Bool

    public init(preferredInput: InputSourceKind = .microphone, microphoneSensitivity: Double = 0.5, a4Hertz: Double = 440, showNoteNames: Bool = true, showFallingNotes: Bool = true, defaultPractice: PracticeSettings = PracticeSettings(), transcriptionModel: String = "claude-opus-5-5", hasCompletedOnboarding: Bool = false) {
        self.preferredInput = preferredInput
        self.microphoneSensitivity = max(0, min(1, microphoneSensitivity))
        self.a4Hertz = max(415, min(466, a4Hertz))
        self.showNoteNames = showNoteNames
        self.showFallingNotes = showFallingNotes
        self.defaultPractice = defaultPractice
        self.transcriptionModel = transcriptionModel
        self.hasCompletedOnboarding = hasCompletedOnboarding
    }
}

/// The single local learner profile.
public struct UserProfile: Hashable, Codable, Sendable {
    public var name: String
    public var createdAt: Date
    /// Song ids in "My Songs".
    public var favoriteSongIDs: [String]
    /// Progress keyed by arrangement id.
    public var progress: [String: SongProgress]
    /// Keyed by lesson id.
    public var lessons: [String: LessonProgress]
    public var settings: UserSettings

    public init(name: String = "Me", createdAt: Date = Date(), favoriteSongIDs: [String] = [], progress: [String: SongProgress] = [:], lessons: [String: LessonProgress] = [:], settings: UserSettings = UserSettings()) {
        self.name = name
        self.createdAt = createdAt
        self.favoriteSongIDs = favoriteSongIDs
        self.progress = progress
        self.lessons = lessons
        self.settings = settings
    }

    public func isFavorite(_ songID: String) -> Bool { favoriteSongIDs.contains(songID) }
    public mutating func toggleFavorite(_ songID: String) {
        if let i = favoriteSongIDs.firstIndex(of: songID) { favoriteSongIDs.remove(at: i) } else { favoriteSongIDs.insert(songID, at: 0) }
    }
    public mutating func record(_ summary: PracticeSummary) {
        var p = progress[summary.arrangementID] ?? SongProgress(arrangementID: summary.arrangementID)
        p.record(summary)
        progress[summary.arrangementID] = p
    }
    /// Arrangements practiced most recently first.
    public var recentArrangementIDs: [String] {
        progress.values.filter { $0.lastPracticed != nil }.sorted { ($0.lastPracticed ?? .distantPast) > ($1.lastPracticed ?? .distantPast) }.map { $0.arrangementID }
    }
}
