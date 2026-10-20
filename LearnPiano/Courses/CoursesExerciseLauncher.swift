import Foundation
import Observation

/// Loads an exercise's score and opens the practice screen for it. One instance per lesson screen.
@MainActor
@Observable
final class CoursesExerciseLauncher {
    /// The exercise whose score is being loaded, if any.
    private(set) var loadingExerciseID: String?
    /// Load failures by exercise id, shown on the exercise card.
    private(set) var errors: [String: String] = [:]

    func isLoading(_ exercise: Exercise) -> Bool { loadingExerciseID == exercise.id }

    func error(for exercise: Exercise) -> String? { errors[exercise.id] }

    /// Loads the score (inline or bundled) and presents the practice screen. Each finished session is recorded in the
    /// profile under "exercise:<id>"; a passing one marks the exercise passed, which completes the lesson once every
    /// exercise in it has passed. A lesson that was already completed stays completed.
    func start(_ exercise: Exercise, lesson: Lesson, course: Course, contentStore: ContentStore, profileStore: ProfileStore, appModel: AppModel) async {
        guard loadingExerciseID == nil else { return }
        loadingExerciseID = exercise.id
        errors[exercise.id] = nil
        defer { loadingExerciseID = nil }

        let score: Score
        do {
            score = try await loadScore(for: exercise, contentStore: contentStore)
        } catch {
            errors[exercise.id] = "Couldn't open the exercise: \(error.localizedDescription)"
            NSLog("CoursesExerciseLauncher: loading \(exercise.id) failed: \(error)")
            return
        }

        let lessonID = lesson.id
        let exerciseID = exercise.id
        let allExerciseIDs = lesson.exercises.map(\.id)
        let request = CoursesExerciseRequestFactory.makeRequest(
            exercise: exercise, lesson: lesson, course: course, score: score,
            baseSettings: profileStore.settings.defaultPractice
        ) { [weak profileStore] summary, passed in
            MainActor.assumeIsolated {
                guard let profileStore else { return }
                profileStore.record(summary)
                guard passed else { return }
                // ProfileStore.markExercisePassed recomputes `completed` from the exercises alone, which would undo a
                // lesson the learner marked complete by hand; restore it in that case.
                let wasCompleted = profileStore.lessonProgress(lessonID).completed
                profileStore.markExercisePassed(lessonID: lessonID, exerciseID: exerciseID, allExerciseIDs: allExerciseIDs)
                let after = profileStore.lessonProgress(lessonID)
                let shouldBeCompleted = CoursesProgressCalculator.lessonCompletedAfterPassing(
                    wasCompleted: wasCompleted, passedExerciseIDs: after.completedExerciseIDs, allExerciseIDs: allExerciseIDs)
                if shouldBeCompleted && !after.completed {
                    profileStore.markLessonCompleted(lessonID)
                }
            }
        }
        appModel.presentPractice(request)
    }

    private func loadScore(for exercise: Exercise, contentStore: ContentStore) async throws -> Score {
        if let inline = exercise.inlineScore { return inline }
        guard let fileName = exercise.scoreFileName else {
            throw CoursesExerciseLaunchError.noScore(exercise.title)
        }
        return try await contentStore.loadScore(bundledFileName: fileName)
    }
}

enum CoursesExerciseLaunchError: LocalizedError {
    case noScore(String)

    var errorDescription: String? {
        switch self {
        case .noScore(let title): return "\"\(title)\" has no score attached."
        }
    }
}
