import Foundation
import Observation

/// The single learner profile persisted at Documents/profile.json. Owns favorites, per-arrangement progress,
/// lesson progress and settings. Saves are debounced; call `saveNow()` before the app goes to the background.
@MainActor
@Observable
final class ProfileStore {
    private(set) var profile: UserProfile
    private let url: URL
    private var saveTask: Task<Void, Never>?

    /// Loads the profile from disk (or creates a fresh one). `directory` defaults to the app's Documents folder.
    init(directory: URL? = nil) {
        let dir = directory ?? ProfileStore.documentsDirectory
        url = dir.appendingPathComponent("profile.json")
        if let data = try? Data(contentsOf: url), let p = try? ProfileStore.decoder.decode(UserProfile.self, from: data) {
            profile = p
        } else {
            profile = UserProfile()
        }
    }

    static var documentsDirectory: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
    }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    // MARK: Mutations

    /// Applies a change and schedules a save.
    func update(_ change: (inout UserProfile) -> Void) {
        change(&profile)
        scheduleSave()
    }

    var settings: UserSettings {
        get { profile.settings }
        set { update { $0.settings = newValue } }
    }

    func toggleFavorite(songID: String) { update { $0.toggleFavorite(songID) } }
    func isFavorite(songID: String) -> Bool { profile.isFavorite(songID) }

    /// Folds a finished practice session into the arrangement's progress.
    func record(_ summary: PracticeSummary) { update { $0.record(summary) } }

    func progress(forArrangement id: String) -> SongProgress? { profile.progress[id] }

    /// Best progress across a song's arrangements (for the song card).
    func progress(forSong song: SongEntry) -> SongProgress? {
        song.arrangements.compactMap { profile.progress[$0.id] }.max { ($0.lastPracticed ?? .distantPast) < ($1.lastPracticed ?? .distantPast) }
    }

    func lessonProgress(_ lessonID: String) -> LessonProgress { profile.lessons[lessonID] ?? LessonProgress(lessonID: lessonID) }

    func markLessonOpened(_ lessonID: String) {
        update { p in
            var lp = p.lessons[lessonID] ?? LessonProgress(lessonID: lessonID)
            lp.lastOpened = Date()
            p.lessons[lessonID] = lp
        }
    }

    /// Records a passed exercise; the lesson is complete when all its exercises are passed.
    func markExercisePassed(lessonID: String, exerciseID: String, allExerciseIDs: [String]) {
        update { p in
            var lp = p.lessons[lessonID] ?? LessonProgress(lessonID: lessonID)
            lp.completedExerciseIDs.insert(exerciseID)
            lp.completed = Set(allExerciseIDs).isSubset(of: lp.completedExerciseIDs)
            p.lessons[lessonID] = lp
        }
    }

    func markLessonCompleted(_ lessonID: String) {
        update { p in
            var lp = p.lessons[lessonID] ?? LessonProgress(lessonID: lessonID)
            lp.completed = true
            p.lessons[lessonID] = lp
        }
    }

    /// Erases all progress and favorites but keeps settings.
    func resetProgress() {
        update { p in
            p.progress = [:]
            p.lessons = [:]
            p.favoriteSongIDs = []
        }
    }

    // MARK: Persistence

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        saveTask?.cancel()
        saveTask = nil
        do {
            let data = try ProfileStore.encoder.encode(profile)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            NSLog("ProfileStore: save failed: \(error)")
        }
    }
}
