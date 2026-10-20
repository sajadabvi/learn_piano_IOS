import SwiftUI

/// One course: header with progress and the ordered lesson list with completion checkmarks and durations.
struct CoursesCourseView: View {
    let course: Course

    @Environment(ProfileStore.self) private var profileStore
    @Environment(CoursesNavigator.self) private var navigator

    var body: some View {
        let summary = CoursesProgressCalculator.summary(for: course, progress: profileStore.lessonProgress)
        let next = CoursesProgressCalculator.nextLessonToStudy(in: course, progress: profileStore.lessonProgress)
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header(summary: summary, next: next)
                VStack(spacing: 0) {
                    ForEach(Array(course.lessons.enumerated()), id: \.element.id) { index, lesson in
                        Button { navigator.openLesson(lesson, in: course) } label: {
                            CoursesLessonRow(number: index + 1, lesson: lesson, progress: profileStore.lessonProgress(lesson.id), isNext: lesson.id == next?.id)
                        }
                        .buttonStyle(.plain)
                        if index < course.lessons.count - 1 {
                            Divider().overlay(Theme.separator).padding(.leading, 72)
                        }
                    }
                }
                .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
                .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 20)
            .frame(maxWidth: 860)
            .frame(maxWidth: .infinity)
        }
        .background(Theme.background)
        .navigationTitle(course.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func header(summary: CoursesProgressSummary, next: Lesson?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .center, spacing: 16) {
                CoursesSymbolBadge(symbol: course.symbol, size: 64)
                VStack(alignment: .leading, spacing: 6) {
                    CoursesLevelBadge(level: course.level)
                    Text(course.title)
                        .font(Theme.title(28))
                        .foregroundStyle(Theme.textPrimary)
                }
            }
            Text(course.subtitle)
                .font(Theme.body(17))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: summary.fraction)
                    .tint(summary.isComplete ? Theme.correct : Theme.accent)
                HStack {
                    Text(summary.label)
                    Text("·")
                    Text("about \(CoursesProgressCalculator.totalMinutes(of: course)) min")
                }
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            }
            if let next {
                Button {
                    navigator.openLesson(next, in: course)
                } label: {
                    Label(summary.completedLessons == 0 ? "Start the course" : "Continue: \(next.title)", systemImage: "play.fill")
                        .font(Theme.heading(16))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
            } else {
                Label("Course completed", systemImage: "checkmark.seal.fill")
                    .font(Theme.heading(16))
                    .foregroundStyle(Theme.correct)
            }
        }
    }
}

/// One row of the lesson list.
struct CoursesLessonRow: View {
    let number: Int
    let lesson: Lesson
    let progress: LessonProgress
    let isNext: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            ZStack {
                Circle()
                    .fill(progress.completed ? Theme.correct : (isNext ? Theme.accent.opacity(0.12) : Theme.background))
                if progress.completed {
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Text("\(number)")
                        .font(Theme.heading(16))
                        .foregroundStyle(isNext ? Theme.accent : Theme.textSecondary)
                }
            }
            .frame(width: 40, height: 40)

            VStack(alignment: .leading, spacing: 4) {
                Text(lesson.title)
                    .font(Theme.heading(17))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(lesson.summary)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 12) {
                    Label("\(lesson.minutes) min", systemImage: "clock")
                    if let exercises = CoursesProgressCalculator.exerciseLabel(for: lesson, progress: progress) {
                        Label(exercises, systemImage: "pianokeys")
                    }
                }
                .font(Theme.caption(12))
                .foregroundStyle(Theme.textSecondary)
                .padding(.top, 2)
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.textSecondary.opacity(0.7))
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Lesson \(number), \(lesson.title), \(lesson.minutes) minutes\(progress.completed ? ", completed" : "")")
        .accessibilityAddTraits(.isButton)
    }
}
