import Foundation

// MARK: - Curriculum

/// How an exercise is passed.
public struct ExercisePassCriteria: Hashable, Codable, Sendable {
    /// Minimum share of expected steps played correctly (Wait Mode: completion counts as 1.0 unless wrong notes exceed the allowance).
    public var minimumAccuracy: Double
    /// Wrong notes allowed before the attempt no longer counts as clean.
    public var maxWrongNotes: Int
    public init(minimumAccuracy: Double = 0.9, maxWrongNotes: Int = 3) {
        self.minimumAccuracy = max(0, min(1, minimumAccuracy))
        self.maxWrongNotes = max(0, maxWrongNotes)
    }
}

/// An interactive exercise inside a lesson: a short score practiced with the normal practice engine.
public struct Exercise: Hashable, Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    /// Short instructions shown above the score ("Play C D E F G with fingers 1–5").
    public var instructions: String
    /// Bundled MusicXML file name under Content/Songs (e.g. "ex-c-position-rh__beginner.musicxml"), or nil when `inlineScore` is used.
    public var scoreFileName: String?
    /// Small hand-authored score for exercises that need no file.
    public var inlineScore: Score?
    public var hands: HandSelection
    public var mode: PracticeMode
    public var pass: ExercisePassCriteria

    public init(id: String, title: String, instructions: String, scoreFileName: String? = nil, inlineScore: Score? = nil, hands: HandSelection = .both, mode: PracticeMode = .wait, pass: ExercisePassCriteria = ExercisePassCriteria()) {
        self.id = id
        self.title = title
        self.instructions = instructions
        self.scoreFileName = scoreFileName
        self.inlineScore = inlineScore
        self.hands = hands
        self.mode = mode
        self.pass = pass
    }
}

/// A content block inside a lesson, rendered top to bottom.
public enum LessonBlock: Hashable, Codable, Sendable {
    /// Markdown-ish paragraph(s): plain text with **bold** supported.
    case text(String)
    /// A short callout tip.
    case tip(String)
    /// Show these MIDI pitches highlighted on a keyboard illustration, with an optional caption.
    case keyboardIllustration(pitches: [Int], caption: String)
    /// Show a tiny score illustration (inline score) with a caption.
    case notationIllustration(score: Score, caption: String)
    /// An interactive exercise.
    case exercise(Exercise)
    /// A table of terms (e.g. finger numbers), rows of [term, meaning].
    case glossary([[String]])
}

/// One lesson: explanation blocks plus exercises.
public struct Lesson: Hashable, Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var summary: String
    /// Estimated minutes.
    public var minutes: Int
    public var blocks: [LessonBlock]

    public init(id: String, title: String, summary: String, minutes: Int = 10, blocks: [LessonBlock]) {
        self.id = id
        self.title = title
        self.summary = summary
        self.minutes = minutes
        self.blocks = blocks
    }

    public var exercises: [Exercise] {
        blocks.compactMap { if case .exercise(let e) = $0 { return e } else { return nil } }
    }
}

/// A course: an ordered group of lessons at a level.
public struct Course: Hashable, Codable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var subtitle: String
    public var level: Difficulty
    /// SF Symbol name for the card.
    public var symbol: String
    public var lessons: [Lesson]

    public init(id: String, title: String, subtitle: String, level: Difficulty, symbol: String = "music.note", lessons: [Lesson]) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.level = level
        self.symbol = symbol
        self.lessons = lessons
    }
}
