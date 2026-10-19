import Foundation
import Observation

/// The song catalog: bundled arrangements (Content/Songs/*.catalog.json + MusicXML in the app bundle) plus the user's
/// imported songs under Documents/Library/<song-id>/. Parses scores lazily through the injected importers and caches them.
///
/// Layout of a user song folder:
///   Documents/Library/<song-id>/song.json      – `SongEntry` (storage = .user)
///   Documents/Library/<song-id>/score.json     – `Score` (Codable, lossless)
///   Documents/Library/<song-id>/score.musicxml – optional export for sharing (written when an exporter is configured)
@MainActor
@Observable
final class ContentStore {
    private(set) var songs: [SongEntry] = []
    /// Problems met while loading the catalog (shown in Settings → Library).
    private(set) var loadErrors: [String] = []
    private(set) var isLoading = false

    private let bundle: Bundle
    private let libraryDirectory: URL
    private let importers: [ScoreImporter]
    private let exporter: ((Score) throws -> Data)?
    private var scoreCache: [String: Score] = [:]

    /// - Parameters:
    ///   - importers: parsers for the bundled MusicXML files (and any other format found in the bundle).
    ///   - exporter: optional Score → MusicXML bytes, used to write `score.musicxml` next to imported songs.
    ///   - libraryDirectory: defaults to Documents/Library.
    init(importers: [ScoreImporter], exporter: ((Score) throws -> Data)? = nil, bundle: Bundle = .main, libraryDirectory: URL? = nil) {
        self.importers = importers
        self.exporter = exporter
        self.bundle = bundle
        self.libraryDirectory = libraryDirectory ?? ContentStore.defaultLibraryDirectory
        reload()
    }

    static var defaultLibraryDirectory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return docs.appendingPathComponent("Library", isDirectory: true)
    }

    // MARK: Catalog

    var bundledSongs: [SongEntry] { songs.filter { !$0.isUserImported } }
    var userSongs: [SongEntry] { songs.filter { $0.isUserImported }.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) } }
    var exercises: [SongEntry] { songs.filter { $0.isExercise } }
    /// Songs shown in the browser (exercises excluded), sorted by title.
    var browsableSongs: [SongEntry] { songs.filter { !$0.isExercise }.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending } }

    /// All categories used by browsable songs, most common first.
    var categories: [String] {
        var counts: [String: Int] = [:]
        for s in browsableSongs { for c in s.categories { counts[c, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map { $0.key }
    }

    var genres: [String] { Array(Set(browsableSongs.map { $0.genre })).sorted() }

    func count(category: String) -> Int { browsableSongs.filter { $0.categories.contains(category) }.count }

    func song(id: String) -> SongEntry? { songs.first { $0.id == id } }

    /// Finds an arrangement and its song by arrangement id.
    func arrangement(id: String) -> (song: SongEntry, arrangement: ArrangementEntry)? {
        for s in songs { if let a = s.arrangement(id: id) { return (s, a) } }
        return nil
    }

    /// Case-insensitive search over title, composer, genre and categories (browsable songs only). Empty query = all.
    func search(_ query: String) -> [SongEntry] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return browsableSongs }
        return browsableSongs.filter { s in
            s.title.lowercased().contains(q) || s.composer.lowercased().contains(q) || s.genre.lowercased().contains(q) || s.categories.contains { $0.lowercased().contains(q) }
        }
    }

    /// Re-reads bundled fragments and the user library.
    func reload() {
        isLoading = true
        var errors: [String] = []
        var loaded: [SongEntry] = []
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        // Bundled fragments: every *.catalog.json resource.
        let fragmentURLs = (bundle.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []).filter { $0.lastPathComponent.hasSuffix(".catalog.json") }
        for url in fragmentURLs.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let fragment = try decoder.decode(CatalogFragment.self, from: Data(contentsOf: url))
                var entry = fragment.songEntry()
                // Keep only arrangements whose file actually exists in the bundle.
                entry.arrangements = entry.arrangements.filter { a in
                    if case .bundled(let f) = a.storage { return bundle.url(forResource: f, withExtension: nil) != nil }
                    return false
                }
                if entry.arrangements.isEmpty { errors.append("\(url.lastPathComponent): no playable arrangement files found") } else { loaded.append(entry) }
            } catch {
                errors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }

        // User library.
        if let folders = try? FileManager.default.contentsOfDirectory(at: libraryDirectory, includingPropertiesForKeys: nil) {
            for folder in folders where (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let songURL = folder.appendingPathComponent("song.json")
                guard FileManager.default.fileExists(atPath: songURL.path) else { continue }
                do {
                    var entry = try decoder.decode(SongEntry.self, from: Data(contentsOf: songURL))
                    entry.isUserImported = true
                    loaded.append(entry)
                } catch {
                    errors.append("\(folder.lastPathComponent)/song.json: \(error.localizedDescription)")
                }
            }
        }

        songs = loaded
        loadErrors = errors
        isLoading = false
    }

    // MARK: Scores

    /// Loads (and caches) the score for an arrangement. Parsing runs off the main actor.
    func loadScore(for arrangement: ArrangementEntry) async throws -> Score {
        let key: String
        switch arrangement.storage {
        case .bundled(let f): key = "bundled:\(f)"
        case .user(let p): key = "user:\(p)"
        }
        if let cached = scoreCache[key] { return cached }
        let score: Score
        switch arrangement.storage {
        case .bundled(let fileName):
            score = try await loadBundledScore(fileName: fileName)
        case .user(let relativePath):
            let url = libraryDirectory.appendingPathComponent(relativePath)
            let data = try Data(contentsOf: url)
            if url.pathExtension.lowercased() == "json" {
                score = try JSONDecoder().decode(Score.self, from: data)
            } else {
                score = try await parse(data: data, fileName: url.lastPathComponent).score
            }
        }
        scoreCache[key] = score
        return score
    }

    /// Loads a bundled file by name (used by course exercises).
    func loadScore(bundledFileName fileName: String) async throws -> Score {
        let key = "bundled:\(fileName)"
        if let cached = scoreCache[key] { return cached }
        let score = try await loadBundledScore(fileName: fileName)
        scoreCache[key] = score
        return score
    }

    private func loadBundledScore(fileName: String) async throws -> Score {
        guard let url = bundle.url(forResource: fileName, withExtension: nil) else { throw ImportError.malformed("\(fileName) is not in the app bundle") }
        let data = try Data(contentsOf: url)
        let result = try await parse(data: data, fileName: fileName)
        var score = result.score
        if score.metadata.source == .bundled || score.metadata.sourceFileName == nil {
            score.metadata.sourceFileName = fileName
        }
        return score
    }

    /// Runs the matching importer on a background task.
    func parse(data: Data, fileName: String) async throws -> ImportResult {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard let importer = importers.first(where: { $0.canImport(fileExtension: ext) }) else { throw ImportError.unsupportedFormat(ext) }
        return try await Task.detached(priority: .userInitiated) {
            try importer.importScore(data: data, fileName: fileName)
        }.value
    }

    // MARK: User library

    /// Saves an imported score as a new user song and returns its catalog entry.
    @discardableResult
    func addUserSong(score: Score, title: String, composer: String, genre: String, difficulty: Difficulty, description: String = "", categories: [String] = [], tempoBPM: Int? = nil) throws -> SongEntry {
        let base = ContentStore.slug(title.isEmpty ? "untitled" : title)
        var id = base
        var n = 2
        while songs.contains(where: { $0.id == id }) || FileManager.default.fileExists(atPath: libraryDirectory.appendingPathComponent(id).path) {
            id = "\(base)-\(n)"
            n += 1
        }
        let folder = libraryDirectory.appendingPathComponent(id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        var stored = score
        stored.metadata.title = title
        stored.metadata.composer = composer
        stored.metadata.difficulty = difficulty
        stored.metadata.genre = genre
        stored.metadata.arrangementLabel = difficulty.displayName

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(stored).write(to: folder.appendingPathComponent("score.json"), options: .atomic)
        if let exporter {
            do { try exporter(stored).write(to: folder.appendingPathComponent("score.musicxml"), options: .atomic) } catch {
                loadErrors.append("\(id): MusicXML export failed: \(error.localizedDescription)")
            }
        }

        let arrangement = ArrangementEntry(
            id: "\(id)-\(difficulty.rawValue)", label: difficulty.displayName, difficulty: difficulty,
            storage: .user(relativePath: "\(id)/score.json"),
            tempoBPM: tempoBPM ?? Int(stored.initialTempoBPM.rounded()),
            keySignature: stored.initialKey.displayName, timeSignature: stored.initialTime.description,
            measures: stored.measures.count, hands: stored.hasNotes(for: .left) && stored.hasNotes(for: .right) ? "both" : (stored.hasNotes(for: .left) ? "left" : "right"),
            notes: stored.metadata.notes, teachingPoints: []
        )
        let entry = SongEntry(id: id, title: title, composer: composer, genre: genre, categories: categories.isEmpty ? [genre, "Imported"] : categories, year: nil, description: description, isExercise: false, isUserImported: true, dateAdded: Date(), arrangements: [arrangement])
        let songEncoder = JSONEncoder()
        songEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        songEncoder.dateEncodingStrategy = .iso8601
        try songEncoder.encode(entry).write(to: folder.appendingPathComponent("song.json"), options: .atomic)

        scoreCache["user:\(id)/score.json"] = stored
        songs.append(entry)
        return entry
    }

    /// Deletes a user song and its folder. Bundled songs cannot be deleted.
    func deleteUserSong(id: String) throws {
        guard let s = song(id: id), s.isUserImported else { return }
        let folder = libraryDirectory.appendingPathComponent(id, isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
        songs.removeAll { $0.id == id }
        for a in s.arrangements { if case .user(let p) = a.storage { scoreCache["user:\(p)"] = nil } }
    }

    /// Bytes used by the user library.
    var userLibraryBytes: Int64 {
        guard let e = FileManager.default.enumerator(at: libraryDirectory, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in e { total += Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
        return total
    }

    static func slug(_ s: String) -> String {
        let lowered = s.lowercased().folding(options: .diacriticInsensitive, locale: nil)
        let allowed = lowered.map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
        let collapsed = allowed.replacingOccurrences(of: "-+", with: "-", options: .regularExpression).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String(collapsed.prefix(48)).isEmpty ? "song" : String(collapsed.prefix(48))
    }
}
