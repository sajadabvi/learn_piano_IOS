import SwiftUI

/// Sidebar-adaptable tab shell. On iPad this renders as a sidebar (or a floating
/// tab bar in compact layouts); on iPhone it is a regular tab bar.
struct RootView: View {
    @Environment(AppModel.self) private var appModel

    var body: some View {
        @Bindable var appModel = appModel
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
    }
}
