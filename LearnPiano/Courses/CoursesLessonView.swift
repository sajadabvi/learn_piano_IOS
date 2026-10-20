import SwiftUI

/// A lesson: its blocks rendered top to bottom, then "Mark lesson complete" and "Next lesson".
struct CoursesLessonView: View {
    let course: Course
    let lesson: Lesson

    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore
    @Environment(CoursesNavigator.self) private var navigator
    @State private var launcher = CoursesExerciseLauncher()

    private var lessonNumber: Int { (course.lessons.firstIndex { $0.id == lesson.id } ?? 0) + 1 }

    var body: some View {
        let progress = profileStore.lessonProgress(lesson.id)
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header(progress: progress)
                ForEach(Array(lesson.blocks.enumerated()), id: \.offset) { _, block in
                    blockView(block, progress: progress)
                }
                footer(progress: progress)
            }
            .padding(.horizontal, 24)
            .padding(.top, 12)
            .padding(.bottom, 40)
            .frame(maxWidth: 780, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(lesson.title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { profileStore.markLessonOpened(lesson.id) }
    }

    // MARK: Sections

    private func header(progress: LessonProgress) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(course.title.uppercased()) · LESSON \(lessonNumber) OF \(course.lessons.count)")
                .font(Theme.caption(12))
                .foregroundStyle(Theme.textSecondary)
                .tracking(0.6)
            Text(lesson.title)
                .font(Theme.title(32))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Label("\(lesson.minutes) min", systemImage: "clock")
                if let exercises = CoursesProgressCalculator.exerciseLabel(for: lesson, progress: progress) {
                    Label(exercises, systemImage: "pianokeys")
                }
                if progress.completed {
                    Label("Completed", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Theme.correct)
                }
            }
            .font(Theme.caption())
            .foregroundStyle(Theme.textSecondary)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func blockView(_ block: LessonBlock, progress: LessonProgress) -> some View {
        switch block {
        case .text(let text):
            CoursesRichText(text: text)
        case .tip(let text):
            CoursesTipCallout(text: text)
        case .keyboardIllustration(let pitches, let caption):
            CoursesKeyboardIllustration(pitches: pitches, caption: caption)
        case .notationIllustration(let score, let caption):
            CoursesNotationIllustration(score: score, caption: caption)
        case .glossary(let rows):
            CoursesGlossaryTable(rows: rows)
        case .exercise(let exercise):
            CoursesExerciseCard(
                exercise: exercise,
                isPassed: progress.completedExerciseIDs.contains(exercise.id),
                attempts: profileStore.progress(forArrangement: CoursesCurriculum.arrangementID(forExercise: exercise.id))?.sessions ?? 0,
                isLoading: launcher.isLoading(exercise),
                isDisabled: launcher.loadingExerciseID != nil,
                errorMessage: launcher.error(for: exercise)
            ) {
                Task {
                    await launcher.start(exercise, lesson: lesson, course: course, contentStore: contentStore, profileStore: profileStore, appModel: appModel)
                }
            }
        }
    }

    private func footer(progress: LessonProgress) -> some View {
        let next = CoursesCurriculum.nextLesson(after: lesson.id)
        return VStack(alignment: .leading, spacing: 14) {
            Divider().overlay(Theme.separator)
            if progress.completed {
                Label("You've completed this lesson", systemImage: "checkmark.seal.fill")
                    .font(Theme.heading(17))
                    .foregroundStyle(Theme.correct)
            } else {
                Button {
                    profileStore.markLessonCompleted(lesson.id)
                } label: {
                    Label("Mark lesson complete", systemImage: "checkmark.circle")
                        .font(Theme.heading(16))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(Theme.correct)
            }
            if let next {
                Button {
                    navigator.replaceLesson(with: next.lesson, in: next.course)
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(next.course.id == course.id ? "Next lesson" : "Next course: \(next.course.title)")
                                .font(Theme.caption())
                                .foregroundStyle(.white.opacity(0.85))
                            Text(next.lesson.title)
                                .font(Theme.heading(17))
                                .foregroundStyle(.white)
                        }
                        Spacer()
                        Image(systemName: "arrow.right")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(.white)
                    }
                    .padding(.horizontal, 18)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Next lesson: \(next.lesson.title)")
            } else {
                Button {
                    navigator.popToRoot()
                } label: {
                    Label("Back to all courses", systemImage: "square.grid.2x2")
                        .font(Theme.heading(16))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            }
        }
        .padding(.top, 8)
    }
}
