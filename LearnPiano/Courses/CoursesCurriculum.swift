import Foundation

/// The built-in course curriculum: every course, lesson and exercise the Courses tab shows, in teaching order.
/// The lesson content lives in the `CoursesCurriculum+<Course>.swift` files; this file holds the lookups.
enum CoursesCurriculum {
    /// All courses in the order they are presented.
    static let courses: [Course] = [welcomeCourse, readingMusicCourse, chordsAndScalesCourse, expressionCourse]

    /// Prefix of the arrangement id under which exercise progress is recorded.
    static let exerciseArrangementPrefix = "exercise:"

    static func course(id: String) -> Course? { courses.first { $0.id == id } }

    /// The course containing a lesson.
    static func course(containingLesson lessonID: String) -> Course? {
        courses.first { c in c.lessons.contains { $0.id == lessonID } }
    }

    static func lesson(id: String) -> Lesson? {
        for c in courses { if let l = c.lessons.first(where: { $0.id == id }) { return l } }
        return nil
    }

    /// The lesson after `lessonID`: the next one in the same course, or the first lesson of the next course.
    static func nextLesson(after lessonID: String) -> (course: Course, lesson: Lesson)? {
        guard let ci = courses.firstIndex(where: { c in c.lessons.contains { $0.id == lessonID } }),
              let li = courses[ci].lessons.firstIndex(where: { $0.id == lessonID }) else { return nil }
        let course = courses[ci]
        if li + 1 < course.lessons.count { return (course, course.lessons[li + 1]) }
        var next = ci + 1
        while next < courses.count {
            if let first = courses[next].lessons.first { return (courses[next], first) }
            next += 1
        }
        return nil
    }

    /// Every exercise in the curriculum, in order.
    static var allExercises: [Exercise] { courses.flatMap { $0.lessons.flatMap { $0.exercises } } }

    /// Every bundled score file referenced by an exercise (deduplicated, in first-use order).
    static var bundledFileNames: [String] {
        var seen = Set<String>()
        return allExercises.compactMap { $0.scoreFileName }.filter { seen.insert($0).inserted }
    }

    /// Arrangement id used for an exercise's practice progress.
    static func arrangementID(forExercise exerciseID: String) -> String { exerciseArrangementPrefix + exerciseID }
}

// MARK: - Authoring helpers shared by the course files

extension CoursesCurriculum {
    typealias NoteEvent = (pitches: [String], ticks: Ticks)

    static let whole: Ticks = Ticks.perWhole
    static let half: Ticks = Ticks.perQuarter * 2
    static let quarter: Ticks = Ticks.perQuarter
    static let eighth: Ticks = Ticks.perQuarter / 2

    /// A note or chord event for `ScoreBuilder`.
    static func play(_ pitches: String..., for ticks: Ticks) -> NoteEvent { (pitches, ticks) }

    /// A rest event for `ScoreBuilder`.
    static func rest(_ ticks: Ticks) -> NoteEvent { ([], ticks) }

    /// A small illustration score (exercise source, so it is never confused with a bundled song).
    /// A hand with no material gets a full-measure rest in every bar so both staves are engraved cleanly.
    static func illustration(_ title: String, key: KeySignature = .cMajor, time: TimeSignature = .common,
                             right: [[NoteEvent]], left: [[NoteEvent]] = [], fingering: [[[Int]]] = []) -> Score {
        let count = max(right.count, left.count)
        func padded(_ hand: [[NoteEvent]]) -> [[NoteEvent]] {
            (0..<count).map { i in hand.indices.contains(i) && !hand[i].isEmpty ? hand[i] : [rest(time.measureTicks)] }
        }
        return ScoreBuilder.make(title: title, time: time, key: key, tempo: 80, right: padded(right), left: padded(left), fingering: fingering)
    }
}
