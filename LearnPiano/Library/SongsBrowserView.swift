import SwiftUI

/// The Songs tab: "Continue practicing", category chips, difficulty filter, search and the song grid.
struct SongsBrowserView: View {
    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore

    @State private var model = LibraryBrowserModel()
    @State private var launcher = LibraryPracticeLauncher()
    @State private var path: [LibrarySongRoute] = []

    var body: some View {
        @Bindable var model = model
        NavigationStack(path: $path) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    if !model.hasQuery { continuePracticing }
                    filters
                    results
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
            .background(Theme.background)
            .navigationTitle("Songs")
            .searchable(text: $model.query, prompt: "Search title or composer")
            .refreshable { contentStore.reload() }
            .modifier(LibraryNavigationDestinations())
            .onChange(of: contentStore.categories) { _, categories in
                model.validateCategory(against: LibraryBrowserFilter.categoryChips(from: categories))
            }
            .alert("Could Not Open Song", isPresented: errorBinding) {
                Button("OK", role: .cancel) { launcher.errorMessage = nil }
            } message: {
                Text(launcher.errorMessage ?? "")
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { launcher.errorMessage != nil }, set: { if !$0 { launcher.errorMessage = nil } })
    }

    // MARK: Continue practicing

    private var recentItems: [LibraryRecentItem] {
        LibraryRecents.items(
            recentArrangementIDs: profileStore.profile.recentArrangementIDs,
            lookup: { contentStore.arrangement(id: $0) },
            progress: { profileStore.progress(forArrangement: $0) }
        )
    }

    @ViewBuilder
    private var continuePracticing: some View {
        let items = recentItems
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                LibrarySectionHeader(title: "Continue practicing")
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(spacing: 16) {
                        ForEach(items) { item in
                            LibraryRecentCard(
                                item: item,
                                isLoading: launcher.loadingArrangementID == item.arrangement.id,
                                onPractice: { practice(item) },
                                onShowDetails: { path.append(LibrarySongRoute(songID: item.song.id, arrangementID: item.arrangement.id)) }
                            )
                        }
                    }
                    .padding(.vertical, 10)
                    .padding(.horizontal, 2)
                }
                .scrollClipDisabled()
            }
        }
    }

    private func practice(_ item: LibraryRecentItem) {
        Task {
            await launcher.launch(song: item.song, arrangement: item.arrangement, content: contentStore, profile: profileStore, app: appModel)
        }
    }

    // MARK: Filters

    private var filters: some View {
        @Bindable var model = model
        let chips = LibraryBrowserFilter.categoryChips(from: contentStore.categories)
        return VStack(alignment: .leading, spacing: 14) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(chips, id: \.self) { chip in
                        LibraryChip(
                            title: chip ?? "All",
                            count: chip.map { contentStore.count(category: $0) } ?? contentStore.browsableSongs.count,
                            isSelected: model.selectedCategory == chip
                        ) {
                            withAnimation(.snappy) { model.selectedCategory = chip }
                        }
                    }
                }
                .padding(.horizontal, 2)
                .padding(.vertical, 2)
            }
            .scrollClipDisabled()

            Picker("Difficulty", selection: $model.selectedDifficulty) {
                ForEach(LibraryBrowserModel.difficultyOptions, id: \.self) { level in
                    Text(LibraryFormatting.difficultyFilterLabel(level)).tag(level)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 560)
        }
    }

    // MARK: Results

    @ViewBuilder
    private var results: some View {
        let songs = model.results(search: { contentStore.search($0) })
        if contentStore.isLoading && contentStore.songs.isEmpty {
            ProgressView("Loading songs…")
                .frame(maxWidth: .infinity, minHeight: 240)
        } else if contentStore.browsableSongs.isEmpty {
            LibraryCatalogEmptyView(errorCount: contentStore.loadErrors.count) { contentStore.reload() }
        } else if songs.isEmpty {
            LibraryNoResultsView(message: model.emptyResultsMessage) {
                withAnimation(.snappy) { model.clearFilters() }
            }
        } else {
            VStack(alignment: .leading, spacing: 12) {
                LibrarySectionHeader(
                    title: model.selectedCategory ?? (model.hasQuery ? "Results" : "All songs"),
                    subtitle: songs.count == 1 ? "1 song" : "\(songs.count) songs"
                )
                LibrarySongGrid(songs: songs)
            }
        }
    }
}

/// Empty state when filters or the search match nothing.
struct LibraryNoResultsView: View {
    var message: String
    var onClear: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Matching Songs", systemImage: "magnifyingglass")
        } description: {
            Text(message)
        } actions: {
            Button("Clear Filters", action: onClear)
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}

/// Empty state when the catalog itself has no songs (e.g. the bundle failed to load).
struct LibraryCatalogEmptyView: View {
    var errorCount: Int
    var onReload: () -> Void

    var body: some View {
        ContentUnavailableView {
            Label("No Songs Yet", systemImage: "music.note.list")
        } description: {
            if errorCount > 0 {
                Text(errorCount == 1 ? "1 catalog file could not be read. Details are listed in Settings." : "\(errorCount) catalog files could not be read. Details are listed in Settings.")
            } else {
                Text("The song catalog is empty. Import sheet music from the Import tab to start your library.")
            }
        } actions: {
            Button("Reload", action: onReload)
                .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, minHeight: 280)
    }
}
