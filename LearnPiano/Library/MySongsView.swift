import SwiftUI

/// The My Songs tab: favorites, recently practiced songs and imported songs.
struct MySongsView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore

    var body: some View {
        NavigationStack {
            ScrollView {
                let favorites = LibraryRecents.favorites(ids: profileStore.profile.favoriteSongIDs) { contentStore.song(id: $0) }
                let recent = LibraryRecents.songs(recentArrangementIDs: profileStore.profile.recentArrangementIDs) { contentStore.arrangement(id: $0) }
                let imported = contentStore.userSongs

                VStack(alignment: .leading, spacing: 32) {
                    if favorites.isEmpty && recent.isEmpty && imported.isEmpty {
                        LibraryMySongsEmptyView(
                            onBrowse: { appModel.selectedTab = .songs },
                            onImport: { appModel.selectedTab = .importSheet }
                        )
                    } else {
                        section(title: "Favorites", subtitle: count(favorites.count), songs: favorites) {
                            LibraryInlineHint(text: "Tap the heart on any song to keep it here.", systemImage: "heart", actionTitle: "Browse Songs") {
                                appModel.selectedTab = .songs
                            }
                        }
                        section(title: "Recently practiced", subtitle: count(recent.count), songs: recent) {
                            LibraryInlineHint(text: "Songs you practice appear here.", systemImage: "clock", actionTitle: "Browse Songs") {
                                appModel.selectedTab = .songs
                            }
                        }
                        section(title: "Imported", subtitle: count(imported.count), songs: imported) {
                            LibraryInlineHint(text: "Bring in MusicXML, MIDI, PDF or a photo of sheet music.", systemImage: "square.and.arrow.down.on.square", actionTitle: "Import Sheet Music") {
                                appModel.selectedTab = .importSheet
                            }
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Theme.background)
            .navigationTitle("My Songs")
            .refreshable { contentStore.reload() }
            .modifier(LibraryNavigationDestinations())
        }
    }

    private func count(_ n: Int) -> String? {
        n == 0 ? nil : (n == 1 ? "1 song" : "\(n) songs")
    }

    @ViewBuilder
    private func section<Hint: View>(title: String, subtitle: String?, songs: [SongEntry], @ViewBuilder emptyHint: () -> Hint) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            LibrarySectionHeader(title: title, subtitle: subtitle)
            if songs.isEmpty {
                emptyHint()
            } else {
                LibrarySongGrid(songs: songs)
            }
        }
    }
}

/// Compact guidance shown in place of an empty section.
struct LibraryInlineHint: View {
    var text: String
    var systemImage: String
    var actionTitle: String
    var action: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 20))
                .foregroundStyle(Theme.accent)
                .frame(width: 28)
            Text(text)
                .font(Theme.body(15))
                .foregroundStyle(Theme.textSecondary)
            Spacer(minLength: 8)
            Button(actionTitle, action: action)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }
}

/// Full empty state for a brand-new learner: points to the Songs and Import tabs.
struct LibraryMySongsEmptyView: View {
    var onBrowse: () -> Void
    var onImport: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("Your Collection Is Empty", systemImage: "heart")
        } description: {
            Text("Tap the heart on a song in the Songs tab to keep it here, or import your own sheet music. Songs you practice show up automatically.")
        } actions: {
            HStack(spacing: 12) {
                Button(action: onBrowse) {
                    Label("Browse Songs", systemImage: "music.note.list")
                }
                .buttonStyle(.borderedProminent)
                Button(action: onImport) {
                    Label("Import Sheet Music", systemImage: "square.and.arrow.down.on.square")
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
    }
}
