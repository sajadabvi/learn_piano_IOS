import SwiftUI
import Observation

/// Top-level app state shared across tabs: which tab is selected and which
/// song (if any) is open in the practice screen. Module-specific state lives in
/// the modules themselves; this object only coordinates navigation.
@Observable
final class AppModel {
    enum Tab: String, CaseIterable, Identifiable {
        case courses, songs, mySongs, importSheet, settings
        var id: String { rawValue }

        var title: String {
            switch self {
            case .courses: return "Courses"
            case .songs: return "Songs"
            case .mySongs: return "My Songs"
            case .importSheet: return "Import"
            case .settings: return "Settings"
            }
        }

        var systemImage: String {
            switch self {
            case .courses: return "graduationcap"
            case .songs: return "music.note.list"
            case .mySongs: return "heart"
            case .importSheet: return "square.and.arrow.down.on.square"
            case .settings: return "gearshape"
            }
        }
    }

    var selectedTab: Tab = .songs

    /// The practice screen currently presented full-screen, if any.
    var activePractice: PracticeRequest?

    /// Opens the practice screen for a request (replacing any open one).
    func presentPractice(_ request: PracticeRequest) { activePractice = request }

    func dismissPractice() { activePractice = nil }
}
