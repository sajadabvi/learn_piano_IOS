import SwiftUI

/// Sidebar-adaptable tab shell. On iPad this renders as a floating tab bar that can expand into a sidebar.
/// The practice screen is presented full-screen over everything when `AppModel.activePractice` is set; onboarding is
/// presented on first launch (and after "Replay onboarding" in Settings) until it sets `hasCompletedOnboarding`.
struct RootView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        @Bindable var appModel = appModel
        let needsOnboarding = Binding(
            get: { !profileStore.settings.hasCompletedOnboarding && appModel.activePractice == nil },
            set: { presented in if !presented { profileStore.update { $0.settings.hasCompletedOnboarding = true } } }
        )
        Group {
            TabView(selection: $appModel.selectedTab) {
                Tab(AppModel.Tab.courses.title, systemImage: AppModel.Tab.courses.systemImage, value: .courses) {
                    CoursesHomeView()
                }
                Tab(AppModel.Tab.songs.title, systemImage: AppModel.Tab.songs.systemImage, value: .songs) {
                    SongsBrowserView()
                }
                Tab(AppModel.Tab.mySongs.title, systemImage: AppModel.Tab.mySongs.systemImage, value: .mySongs) {
                    MySongsView()
                }
                Tab(AppModel.Tab.importSheet.title, systemImage: AppModel.Tab.importSheet.systemImage, value: .importSheet) {
                    ImportHomeView()
                }
                Tab(AppModel.Tab.settings.title, systemImage: AppModel.Tab.settings.systemImage, value: .settings) {
                    SettingsView()
                }
            }
            .tabViewStyle(.sidebarAdaptable)
            .fullScreenCover(item: $appModel.activePractice) { request in
                PracticeScreen(request: request)
            }
        }
        .fullScreenCover(isPresented: needsOnboarding) {
            SettingsOnboardingView()
        }
    }
}
