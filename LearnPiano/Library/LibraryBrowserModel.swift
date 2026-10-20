import Foundation
import Observation

/// Pure filtering rules of the songs browser: category, difficulty and a text query.
enum LibraryBrowserFilter {
    /// Category names that only exercises use; never offered as chips in the songs browser.
    static let exerciseCategoryNames: Set<String> = ["exercises", "exercise"]

    /// Chip titles for the browser: "All" first (represented by nil), then the catalog categories in their given order,
    /// without exercise categories and duplicates.
    static func categoryChips(from categories: [String]) -> [String?] {
        var seen = Set<String>()
        var chips: [String?] = [nil]
        for c in categories {
            let trimmed = c.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !exerciseCategoryNames.contains(trimmed.lowercased()), seen.insert(trimmed).inserted else { continue }
            chips.append(trimmed)
        }
        return chips
    }

    /// Whether the song's title or composer contains the query (case- and diacritic-insensitive). Empty query matches.
    /// ContentStore.search is the source of truth in the app; this mirrors its title/composer part for local lists.
    static func matches(_ song: SongEntry, query: String) -> Bool {
        let q = normalized(query)
        guard !q.isEmpty else { return true }
        return normalized(song.title).contains(q) || normalized(song.composer).contains(q)
    }

    /// Keeps songs (never exercises) in `category` (nil = all) that have an arrangement at `difficulty` (nil = any).
    static func apply(to songs: [SongEntry], category: String?, difficulty: Difficulty?) -> [SongEntry] {
        songs.filter { song in
            guard !song.isExercise else { return false }
            if let category, !song.categories.contains(category) { return false }
            if let difficulty, !song.arrangements.contains(where: { $0.difficulty == difficulty }) { return false }
            return true
        }
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}

/// UI state of the songs browser (selected category, difficulty filter, search text).
@MainActor
@Observable
final class LibraryBrowserModel {
    /// nil = "All".
    var selectedCategory: String?
    /// nil = "All".
    var selectedDifficulty: Difficulty?
    var query: String = ""

    init(selectedCategory: String? = nil, selectedDifficulty: Difficulty? = nil, query: String = "") {
        self.selectedCategory = selectedCategory
        self.selectedDifficulty = selectedDifficulty
        self.query = query
    }

    /// Difficulty filter options, "All" (nil) first.
    static let difficultyOptions: [Difficulty?] = [nil] + Difficulty.allCases.map { Optional($0) }

    var hasQuery: Bool { !LibraryBrowserFilter.normalized(query).isEmpty }
    var hasActiveFilters: Bool { selectedCategory != nil || selectedDifficulty != nil || hasQuery }

    /// Songs to show: `search(query)` (ContentStore.search in the app) narrowed by category and difficulty.
    func results(search: (String) -> [SongEntry]) -> [SongEntry] {
        LibraryBrowserFilter.apply(to: search(query), category: selectedCategory, difficulty: selectedDifficulty)
    }

    /// Drops a selected category that no longer exists (after a reload or deleting an imported song).
    func validateCategory(against chips: [String?]) {
        if let selectedCategory, !chips.contains(selectedCategory) { self.selectedCategory = nil }
    }

    func clearFilters() {
        selectedCategory = nil
        selectedDifficulty = nil
        query = ""
    }

    /// Short explanation for the empty state.
    var emptyResultsMessage: String {
        var parts: [String] = []
        if hasQuery { parts.append("matching \u{201C}\(query.trimmingCharacters(in: .whitespacesAndNewlines))\u{201D}") }
        if let selectedCategory { parts.append("in \(selectedCategory)") }
        if let selectedDifficulty { parts.append("at \(selectedDifficulty.displayName) level") }
        if parts.isEmpty { return "No songs are available." }
        return "No songs " + parts.joined(separator: " ") + "."
    }
}

/// One "Continue practicing" item: an arrangement practiced recently.
struct LibraryRecentItem: Identifiable, Hashable {
    var song: SongEntry
    var arrangement: ArrangementEntry
    var progress: SongProgress?
    var id: String { arrangement.id }

    var mastery: Double? { LibraryMastery.arrangementMastery(progress, arrangement: arrangement) }
}

/// Builds the recent lists from `UserProfile.recentArrangementIDs` (already most recent first).
enum LibraryRecents {
    /// Recent arrangements in the given order, skipping ids that no longer resolve (deleted songs) and exercises.
    static func items(recentArrangementIDs ids: [String],
                      lookup: (String) -> (song: SongEntry, arrangement: ArrangementEntry)?,
                      progress: (String) -> SongProgress?,
                      limit: Int = 10) -> [LibraryRecentItem] {
        var result: [LibraryRecentItem] = []
        var seen = Set<String>()
        for id in ids where seen.insert(id).inserted {
            guard let found = lookup(id), !found.song.isExercise else { continue }
            result.append(LibraryRecentItem(song: found.song, arrangement: found.arrangement, progress: progress(id)))
            if result.count >= limit { break }
        }
        return result
    }

    /// Songs practiced recently, most recent first, each song once (its most recent arrangement decides the order).
    static func songs(recentArrangementIDs ids: [String],
                      lookup: (String) -> (song: SongEntry, arrangement: ArrangementEntry)?,
                      limit: Int = 12) -> [SongEntry] {
        var result: [SongEntry] = []
        var seen = Set<String>()
        for id in ids {
            guard let found = lookup(id), !found.song.isExercise, seen.insert(found.song.id).inserted else { continue }
            result.append(found.song)
            if result.count >= limit { break }
        }
        return result
    }

    /// Favorite songs in the profile's order (newest favorite first), skipping ids that no longer exist.
    static func favorites(ids: [String], lookup: (String) -> SongEntry?) -> [SongEntry] {
        var seen = Set<String>()
        return ids.compactMap { id in
            guard seen.insert(id).inserted else { return nil }
            return lookup(id)
        }
    }
}

/// Mastery values shown on cards and rings.
enum LibraryMastery {
    /// Mastery of one arrangement, nil when it was never practiced. Uses the catalog's measure count, falling back to the
    /// highest completed measure when the catalog does not know it.
    static func arrangementMastery(_ progress: SongProgress?, arrangement: ArrangementEntry) -> Double? {
        guard let progress, progress.sessions > 0 || progress.lastPracticed != nil else { return nil }
        let count = arrangement.measures > 0 ? arrangement.measures : ((progress.measuresCompleted.max() ?? -1) + 1)
        return progress.mastery(measureCount: count)
    }

    /// Best mastery across a song's arrangements, nil when none was practiced.
    static func songMastery(_ song: SongEntry, progress: (String) -> SongProgress?) -> Double? {
        song.arrangements.compactMap { arrangementMastery(progress($0.id), arrangement: $0) }.max()
    }

    /// The arrangement to preselect in the detail view: the most recently practiced one, else the easiest.
    static func preferredArrangement(of song: SongEntry, progress: (String) -> SongProgress?) -> ArrangementEntry? {
        let practiced = song.arrangements.compactMap { a -> (ArrangementEntry, Date)? in
            guard let date = progress(a.id)?.lastPracticed else { return nil }
            return (a, date)
        }
        if let latest = practiced.max(by: { $0.1 < $1.1 }) { return latest.0 }
        return song.arrangements.first
    }
}
