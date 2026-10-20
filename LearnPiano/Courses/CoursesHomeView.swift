import SwiftUI
import Observation

/// A destination inside the Courses tab's navigation stack.
enum CoursesRoute: Hashable {
    case course(id: String)
    case lesson(courseID: String, lessonID: String)
}

/// Navigation state of the Courses tab, shared with the course and lesson screens through the environment.
@MainActor
@Observable
final class CoursesNavigator {
    var path: [CoursesRoute] = []

    func openCourse(_ course: Course) { path.append(.course(id: course.id)) }

    func openLesson(_ lesson: Lesson, in course: Course) { path.append(.lesson(courseID: course.id, lessonID: lesson.id)) }

    /// Replaces the lesson on top of the stack with another one (used by "Next lesson"), so Back still leads to the course.
    func replaceLesson(with lesson: Lesson, in course: Course) {
        if case .lesson = path.last { path.removeLast() }
        if case .course(let id) = path.last, id != course.id { path.removeLast() }
        if path.last != .course(id: course.id) { path.append(.course(id: course.id)) }
        path.append(.lesson(courseID: course.id, lessonID: lesson.id))
    }

    func popToRoot() { path.removeAll() }
}

/// The Courses tab: course cards with progress, plus a "continue" card for the lesson the learner was last reading.
struct CoursesHomeView: View {
    @Environment(ProfileStore.self) private var profileStore
    @State private var navigator = CoursesNavigator()

    private let courses = CoursesCurriculum.courses

    var body: some View {
        @Bindable var navigator = navigator
        NavigationStack(path: $navigator.path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header
                    if let next = CoursesProgressCalculator.continueLesson(in: courses, progress: profileStore.lessonProgress) {
                        CoursesContinueCard(course: next.course, lesson: next.lesson) {
                            navigator.openLesson(next.lesson, in: next.course)
                        }
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 320, maximum: 560), spacing: 20, alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(courses) { course in
                            Button { navigator.openCourse(course) } label: {
                                CoursesCourseCard(course: course, summary: CoursesProgressCalculator.summary(for: course, progress: profileStore.lessonProgress))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: 1180)
                .frame(maxWidth: .infinity)
            }
            .background(Theme.background)
            .navigationTitle("Courses")
            .navigationDestination(for: CoursesRoute.self) { route in
                switch route {
                case .course(let id):
                    if let course = CoursesCurriculum.course(id: id) {
                        CoursesCourseView(course: course)
                    } else {
                        CoursesMissingContentView()
                    }
                case .lesson(let courseID, let lessonID):
                    if let course = CoursesCurriculum.course(id: courseID), let lesson = course.lessons.first(where: { $0.id == lessonID }) {
                        CoursesLessonView(course: course, lesson: lesson)
                            .id(lessonID)
                    } else {
                        CoursesMissingContentView()
                    }
                }
            }
        }
        .environment(navigator)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Learn step by step")
                .font(Theme.heading(22))
                .foregroundStyle(Theme.textPrimary)
            Text("Short lessons with interactive exercises. Start with the basics or jump to the course that fits your level.")
                .font(Theme.body())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Card for one course on the home screen.
struct CoursesCourseCard: View {
    let course: Course
    let summary: CoursesProgressSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                CoursesSymbolBadge(symbol: course.symbol, size: 52)
                Spacer()
                CoursesLevelBadge(level: course.level)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(course.title)
                    .font(Theme.heading(20))
                    .foregroundStyle(Theme.textPrimary)
                    .multilineTextAlignment(.leading)
                Text(course.subtitle)
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.textSecondary)
                    .multilineTextAlignment(.leading)
                    .lineLimit(3, reservesSpace: true)
            }
            Spacer(minLength: 0)
            VStack(alignment: .leading, spacing: 8) {
                ProgressView(value: summary.fraction)
                    .tint(summary.isComplete ? Theme.correct : Theme.accent)
                HStack {
                    if summary.isComplete {
                        Label("Completed", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.correct)
                    } else {
                        Text(summary.label)
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Spacer()
                    Text("\(CoursesProgressCalculator.totalMinutes(of: course)) min")
                        .foregroundStyle(Theme.textSecondary)
                }
                .font(Theme.caption())
            }
        }
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .card()
        .contentShape(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(course.title), \(course.level.displayName), \(summary.label)")
        .accessibilityAddTraits(.isButton)
    }
}

/// "Continue where you left off" card.
struct CoursesContinueCard: View {
    let course: Course
    let lesson: Lesson
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 16) {
                CoursesSymbolBadge(symbol: "play.fill", size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Continue")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.accent)
                    Text(lesson.title)
                        .font(Theme.heading(18))
                        .foregroundStyle(Theme.textPrimary)
                    Text(course.title)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .foregroundStyle(Theme.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .card()
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Continue \(lesson.title) in \(course.title)")
    }
}

/// Rounded tinted square with an SF Symbol.
struct CoursesSymbolBadge: View {
    let symbol: String
    var size: CGFloat = 48

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: size * 0.42, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .frame(width: size, height: size)
            .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: size * 0.28, style: .continuous))
            .accessibilityHidden(true)
    }
}

/// Capsule with the course level in the shared difficulty colors.
struct CoursesLevelBadge: View {
    let level: Difficulty

    var body: some View {
        let color = DifficultyPalette.color(forLevel: level.rawValue)
        Text(level.displayName)
            .font(Theme.caption(12))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(color.opacity(0.14), in: Capsule())
    }
}

/// Shown if a saved navigation route no longer matches the curriculum.
struct CoursesMissingContentView: View {
    @Environment(CoursesNavigator.self) private var navigator

    var body: some View {
        ContentUnavailableView {
            Label("Lesson not found", systemImage: "book.closed")
        } description: {
            Text("This lesson is no longer part of the course.")
        } actions: {
            Button("Back to Courses") { navigator.popToRoot() }
                .buttonStyle(.borderedProminent)
        }
    }
}
