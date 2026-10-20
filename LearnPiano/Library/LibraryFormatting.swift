import Foundation

/// Pure text formatting for the Library screens (difficulty labels, mastery, relative dates, durations).
/// Everything takes its inputs explicitly (dates, calendars) so it is deterministic in tests.
enum LibraryFormatting {
    // MARK: Difficulty

    /// "Beginner", "Intermediate", … for a level.
    static func difficultyLabel(_ difficulty: Difficulty) -> String { difficulty.displayName }

    /// Label of a difficulty filter option; nil means "All".
    static func difficultyFilterLabel(_ difficulty: Difficulty?) -> String {
        guard let difficulty else { return "All" }
        return difficultyLabel(difficulty)
    }

    /// The distinct difficulties offered by a song, easiest first.
    static func difficulties(of song: SongEntry) -> [Difficulty] {
        Array(Set(song.arrangements.map(\.difficulty))).sorted()
    }

    /// "Beginner", or "Beginner – Advanced" when the song spans several levels; empty for a song without arrangements.
    static func difficultyRange(of song: SongEntry) -> String {
        guard let low = song.easiestDifficulty, let high = song.hardestDifficulty else { return "" }
        if low == high { return difficultyLabel(low) }
        return "\(difficultyLabel(low)) – \(difficultyLabel(high))"
    }

    // MARK: Mastery and percentages

    /// Clamps a 0…1 fraction and rounds it to a whole percentage (NaN counts as 0).
    static func percentValue(_ fraction: Double) -> Int {
        guard fraction.isFinite else { return 0 }
        return Int((max(0, min(1, fraction)) * 100).rounded())
    }

    /// "0%" … "100%".
    static func percent(_ fraction: Double) -> String { "\(percentValue(fraction))%" }

    /// Mastery text for a card: "New" when never practiced, otherwise "42%".
    static func mastery(_ fraction: Double?) -> String {
        guard let fraction else { return "New" }
        return percent(fraction)
    }

    /// Accessibility description of a mastery value.
    static func masteryAccessibility(_ fraction: Double?) -> String {
        guard let fraction else { return "Not practiced yet" }
        return "\(percent(fraction)) mastered"
    }

    /// Best Just Play accuracy, or a dash when the piece was never finished in Just Play at full speed.
    static func bestAccuracy(_ value: Double?) -> String {
        guard let value else { return "–" }
        return percent(value)
    }

    /// Best clean Wait Mode speed as a share of the written tempo ("75% speed"), or a dash.
    static func bestCleanSpeed(_ value: Double?) -> String {
        guard let value else { return "–" }
        return "\(percent(value)) speed"
    }

    // MARK: Dates

    /// "Practiced today", "Last practiced yesterday", "Last practiced 2 days ago", … "Not practiced yet" for nil.
    static func lastPracticed(_ date: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let date else { return "Not practiced yet" }
        let relative = relativeDay(date, now: now, calendar: calendar)
        if relative == "today" { return "Practiced today" }
        return "Last practiced \(relative)"
    }

    /// "today", "yesterday", "2 days ago", "1 week ago", "3 weeks ago", "1 month ago", "2 years ago".
    /// Dates in the future (clock changes) count as today.
    static func relativeDay(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        let startDate = calendar.startOfDay(for: date)
        let startNow = calendar.startOfDay(for: now)
        let days = calendar.dateComponents([.day], from: startDate, to: startNow).day ?? 0
        if days <= 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days < 7 { return "\(days) days ago" }
        if days < 30 {
            let weeks = days / 7
            return weeks == 1 ? "1 week ago" : "\(weeks) weeks ago"
        }
        if days < 365 {
            let months = max(1, days / 30)
            return months == 1 ? "1 month ago" : "\(months) months ago"
        }
        let years = days / 365
        return years == 1 ? "1 year ago" : "\(years) years ago"
    }

    // MARK: Durations

    /// Practice time: "0 min", "45 s", "12 min", "1 h", "2 h 05 min".
    static func duration(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total) s" }
        let minutes = total / 60
        if minutes < 60 { return "\(minutes) min" }
        let hours = minutes / 60
        let rest = minutes % 60
        if rest == 0 { return "\(hours) h" }
        return String(format: "%d h %02d min", hours, rest)
    }

    /// Estimated playing time of an arrangement at its written tempo, e.g. "≈ 0:36"; nil when unknown.
    static func estimatedLength(measures: Int, timeSignature: String, tempoBPM: Int) -> String? {
        guard measures > 0, tempoBPM > 0, let quarters = quartersPerMeasure(timeSignature) else { return nil }
        let seconds = Double(measures) * quarters * 60 / Double(tempoBPM)
        return "≈ " + MusicHelpers.clock(seconds)
    }

    /// Quarter notes per measure for "3/4", "6/8", "12/8"; nil when the text is not a time signature.
    static func quartersPerMeasure(_ timeSignature: String) -> Double? {
        let parts = timeSignature.split(separator: "/").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2, let beats = Double(parts[0]), let unit = Double(parts[1]), beats > 0, unit > 0 else { return nil }
        return beats * 4 / unit
    }

    // MARK: Arrangement facts

    /// "Both hands", "Right hand", "Left hand" for the catalog's `hands` field.
    static func hands(_ value: String) -> String {
        switch value.lowercased() {
        case "right", "rh": return "Right hand"
        case "left", "lh": return "Left hand"
        default: return "Both hands"
        }
    }

    /// "♩ = 92".
    static func tempo(_ bpm: Int) -> String { "♩ = \(bpm)" }

    /// "1 measure", "23 measures".
    static func measures(_ count: Int) -> String { count == 1 ? "1 measure" : "\(count) measures" }

    /// "1 session", "4 sessions".
    static func sessions(_ count: Int) -> String { count == 1 ? "1 session" : "\(count) sessions" }

    /// Trouble spots (0-based notated measure indices) as "m. 3, 7, 12"; nil when there are none.
    /// `measureNumbers` are the score's printed numbers (`score.measures.map(\.number)`), so a pickup bar
    /// reads "m. 0" just as on the sheet and in the practice screen. An index outside that list, or a
    /// missing list (score not loaded yet), falls back to index + 1.
    static func troubleSpots(_ measureIndices: [Int], measureNumbers: [Int]? = nil) -> String? {
        guard !measureIndices.isEmpty else { return nil }
        let labels = measureIndices.map { index -> String in
            if let measureNumbers, measureNumbers.indices.contains(index) { return String(measureNumbers[index]) }
            return String(index + 1)
        }
        return "m. " + labels.joined(separator: ", ")
    }

    /// Subtitle line of a song card: "Ludwig van Beethoven · 1810" (composer, year when known).
    static func composerLine(_ song: SongEntry) -> String {
        var parts: [String] = []
        if !song.composer.isEmpty { parts.append(song.composer) }
        if let year = song.year { parts.append(String(year)) }
        return parts.joined(separator: " · ")
    }
}
