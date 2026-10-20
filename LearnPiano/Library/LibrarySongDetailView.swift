import SwiftUI

/// Song detail: header, arrangement picker with per-arrangement progress, Practice / Listen, favorite and delete.
struct LibrarySongDetailView: View {
    var songID: String
    var initialArrangementID: String?

    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(ContentStore.self) private var contentStore
    @Environment(\.dismiss) private var dismiss

    @State private var launcher = LibraryPracticeLauncher()
    @State private var selectedArrangementID: String?
    @State private var isConfirmingDelete = false
    @State private var deleteErrorMessage: String?
    @State private var contentWidth: CGFloat = 0
    /// Printed measure numbers per arrangement id, loaded from the score so trouble spots match the sheet.
    @State private var measureNumbers: [String: [Int]] = [:]

    var body: some View {
        Group {
            if let song = contentStore.song(id: songID) {
                content(for: song)
            } else {
                ContentUnavailableView("Song Not Found", systemImage: "music.note", description: Text("This song is no longer in your library."))
            }
        }
        .background(Theme.background)
        .alert("Could Not Open Song", isPresented: launchErrorBinding) {
            Button("OK", role: .cancel) { launcher.errorMessage = nil }
        } message: {
            Text(launcher.errorMessage ?? "")
        }
        .alert("Could Not Delete Song", isPresented: deleteErrorBinding) {
            Button("OK", role: .cancel) { deleteErrorMessage = nil }
        } message: {
            Text(deleteErrorMessage ?? "")
        }
    }

    private var launchErrorBinding: Binding<Bool> {
        Binding(get: { launcher.errorMessage != nil }, set: { if !$0 { launcher.errorMessage = nil } })
    }

    private var deleteErrorBinding: Binding<Bool> {
        Binding(get: { deleteErrorMessage != nil }, set: { if !$0 { deleteErrorMessage = nil } })
    }

    // MARK: Layout

    private func content(for song: SongEntry) -> some View {
        let selected = selectedArrangement(in: song)
        let wide = contentWidth >= 900
        return ScrollView {
            Group {
                if wide {
                    HStack(alignment: .top, spacing: 24) {
                        LibrarySongHeader(song: song)
                            .frame(width: min(420, contentWidth * 0.38))
                        arrangementList(song: song, selected: selected)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 24) {
                        LibrarySongHeader(song: song)
                        arrangementList(song: song, selected: selected)
                    }
                }
            }
            .padding(24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
        .safeAreaInset(edge: .bottom) {
            if let selected {
                actionBar(song: song, arrangement: selected)
            }
        }
        .navigationTitle(song.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                LibraryFavoriteButton(songID: song.id, size: 20)
            }
            if song.isUserImported {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Delete Song", systemImage: "trash", role: .destructive) { isConfirmingDelete = true }
                        .tint(Theme.wrong)
                }
            }
        }
        .confirmationDialog("Delete \u{201C}\(song.title)\u{201D}?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
            Button("Delete Song", role: .destructive) { delete(song) }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The imported score and its practice progress will be removed from this iPad. This cannot be undone.")
        }
        .task(id: selected?.id) {
            guard let arrangement = selected, measureNumbers[arrangement.id] == nil else { return }
            do {
                let score = try await contentStore.loadScore(for: arrangement)
                measureNumbers[arrangement.id] = score.measures.map(\.number)
            } catch {
                // Display falls back to index + 1; the practice screen reports load errors itself.
                NSLog("Library: could not load measure numbers for \(arrangement.id): \(error)")
            }
        }
        .onAppear {
            if selectedArrangementID == nil {
                selectedArrangementID = initialArrangementID.flatMap { song.arrangement(id: $0)?.id }
                    ?? LibraryMastery.preferredArrangement(of: song) { profileStore.progress(forArrangement: $0) }?.id
            }
        }
    }

    private func selectedArrangement(in song: SongEntry) -> ArrangementEntry? {
        if let id = selectedArrangementID, let a = song.arrangement(id: id) { return a }
        if let id = initialArrangementID, let a = song.arrangement(id: id) { return a }
        return LibraryMastery.preferredArrangement(of: song) { profileStore.progress(forArrangement: $0) }
    }

    private func arrangementList(song: SongEntry, selected: ArrangementEntry?) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            LibrarySectionHeader(
                title: song.arrangements.count == 1 ? "Arrangement" : "Arrangements",
                subtitle: song.arrangements.count > 1 ? "Choose the version that fits your level." : nil
            )
            if song.arrangements.isEmpty {
                ContentUnavailableView("No Playable Arrangement", systemImage: "exclamationmark.triangle", description: Text("This song has no score file that can be opened."))
            }
            ForEach(song.arrangements) { arrangement in
                LibraryArrangementCard(
                    arrangement: arrangement,
                    progress: profileStore.progress(forArrangement: arrangement.id),
                    measureNumbers: measureNumbers[arrangement.id],
                    isSelected: arrangement.id == selected?.id
                ) {
                    withAnimation(.snappy) { selectedArrangementID = arrangement.id }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func actionBar(song: SongEntry, arrangement: ArrangementEntry) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(arrangement.label)
                    .font(Theme.heading(16))
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(1)
                Text(LibraryFormatting.lastPracticed(profileStore.progress(forArrangement: arrangement.id)?.lastPracticed))
                    .font(Theme.caption(12))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button {
                start(song: song, arrangement: arrangement, mode: .listen)
            } label: {
                launchLabel(title: "Listen", systemImage: "headphones", spinning: launcher.isLoading && launcher.loadingMode == .listen)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(launcher.isLoading)

            Button {
                start(song: song, arrangement: arrangement, mode: nil)
            } label: {
                launchLabel(title: "Practice", systemImage: "play.fill", spinning: launcher.isLoading && launcher.loadingMode != .listen)
                    .frame(minWidth: 120)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(launcher.isLoading)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(.bar)
        .overlay(alignment: .top) { Divider() }
    }

    private func launchLabel(title: String, systemImage: String, spinning: Bool) -> some View {
        HStack(spacing: 8) {
            if spinning {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: systemImage)
            }
            Text(spinning ? "Loading…" : title)
        }
        .font(Theme.heading(16))
    }

    // MARK: Actions

    private func start(song: SongEntry, arrangement: ArrangementEntry, mode: PracticeMode?) {
        Task {
            await launcher.launch(song: song, arrangement: arrangement, mode: mode, content: contentStore, profile: profileStore, app: appModel)
        }
    }

    private func delete(_ song: SongEntry) {
        do {
            try contentStore.deleteUserSong(id: song.id)
        } catch {
            deleteErrorMessage = error.localizedDescription
            return
        }
        let arrangementIDs = song.arrangements.map(\.id)
        profileStore.update { profile in
            profile.favoriteSongIDs.removeAll { $0 == song.id }
            for id in arrangementIDs { profile.progress[id] = nil }
        }
        dismiss()
    }
}

// MARK: - Header

/// Title, composer, year, genre/categories and description of a song.
struct LibrarySongHeader: View {
    var song: SongEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 16) {
                LibrarySongArtwork(song: song, size: 72)
                VStack(alignment: .leading, spacing: 4) {
                    Text(song.title)
                        .font(Theme.title(30))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    let line = LibraryFormatting.composerLine(song)
                    if !line.isEmpty {
                        Text(line)
                            .font(Theme.body(17))
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
            }
            LibraryFlowTags(tags: tags)
            if !song.description.isEmpty {
                Text(song.description)
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if song.isUserImported, let added = song.dateAdded {
                Label("Imported \(LibraryFormatting.relativeDay(added))", systemImage: "square.and.arrow.down")
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private var tags: [String] {
        var result: [String] = []
        for t in [song.genre] + song.categories where !t.isEmpty && !result.contains(t) { result.append(t) }
        return result
    }
}

/// Tags laid out in rows that wrap to the available width.
struct LibraryFlowTags: View {
    var tags: [String]

    var body: some View {
        LibraryFlowLayout(spacing: 6) {
            ForEach(tags, id: \.self) { LibraryTag(text: $0) }
        }
    }
}

/// Minimal wrapping layout (left-aligned rows).
struct LibraryFlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(width: proposal.width ?? .infinity, subviews: subviews)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.reduce(0) { $0 + $1.height } + spacing * CGFloat(max(0, rows.count - 1))
        return CGSize(width: proposal.width.map { min($0, width) } ?? width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(width: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for index in row.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(width: CGFloat, subviews: Subviews) -> [Row] {
        var rows: [Row] = []
        var current = Row()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if needed > width, !current.indices.isEmpty {
                rows.append(current)
                current = Row()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { rows.append(current) }
        return rows
    }
}

// MARK: - Arrangement card

/// One selectable arrangement with its facts, teaching points and the learner's progress on it.
struct LibraryArrangementCard: View {
    var arrangement: ArrangementEntry
    var progress: SongProgress?
    /// The score's printed measure numbers, when loaded; trouble spots fall back to index + 1 without them.
    var measureNumbers: [Int]? = nil
    var isSelected: Bool
    var onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 12) {
                header
                facts
                if isSelected {
                    if !arrangement.notes.isEmpty {
                        Text(arrangement.notes)
                            .font(Theme.body(15))
                            .foregroundStyle(Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !arrangement.teachingPoints.isEmpty { teachingPoints }
                }
                progressSection
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .multilineTextAlignment(.leading)
            .card()
            .overlay(
                RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                    .stroke(isSelected ? Theme.accent : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(LibraryCardButtonStyle())
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .font(.system(size: 22))
                .foregroundStyle(isSelected ? Theme.accent : Theme.separator)
            Text(arrangement.label)
                .font(Theme.heading(19))
                .foregroundStyle(Theme.textPrimary)
            LibraryDifficultyBadge(difficulty: arrangement.difficulty)
            Spacer(minLength: 8)
            LibraryMasteryRing(mastery: LibraryMastery.arrangementMastery(progress, arrangement: arrangement), size: 44)
        }
    }

    private var facts: some View {
        LibraryFlowLayout(spacing: 14) {
            if !arrangement.keySignature.isEmpty { fact(arrangement.keySignature, systemImage: "music.note") }
            if !arrangement.timeSignature.isEmpty { fact(arrangement.timeSignature, systemImage: "metronome") }
            fact(LibraryFormatting.tempo(arrangement.tempoBPM), systemImage: "speedometer")
            if arrangement.measures > 0 { fact(LibraryFormatting.measures(arrangement.measures), systemImage: "rectangle.split.3x1") }
            fact(LibraryFormatting.hands(arrangement.hands), systemImage: "hand.raised")
            if let length = LibraryFormatting.estimatedLength(measures: arrangement.measures, timeSignature: arrangement.timeSignature, tempoBPM: arrangement.tempoBPM) {
                fact(length, systemImage: "clock")
            }
        }
    }

    private func fact(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(Theme.caption(13))
            .foregroundStyle(Theme.textSecondary)
            .labelStyle(.titleAndIcon)
    }

    private var teachingPoints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("What you will learn")
                .font(Theme.heading(15))
                .foregroundStyle(Theme.textPrimary)
            ForEach(Array(arrangement.teachingPoints.enumerated()), id: \.offset) { _, point in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Circle().fill(Theme.accent).frame(width: 6, height: 6)
                    Text(point)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private var progressSection: some View {
        if let progress, progress.sessions > 0 {
            VStack(alignment: .leading, spacing: 10) {
                Divider()
                HStack(alignment: .top, spacing: 0) {
                    stat(title: "Sessions", value: "\(progress.sessions)", detail: LibraryFormatting.duration(progress.totalSeconds))
                    stat(title: "Best accuracy", value: LibraryFormatting.bestAccuracy(progress.bestAccuracy), detail: "Just Play, full speed")
                    stat(title: "Best clean speed", value: LibraryFormatting.bestCleanSpeed(progress.bestCleanSpeed), detail: "Wait Mode, no mistakes")
                }
                HStack(spacing: 16) {
                    Label(LibraryFormatting.lastPracticed(progress.lastPracticed), systemImage: "calendar")
                    if progress.completedOnce {
                        Label("Completed", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(Theme.correct)
                    }
                    if let spots = LibraryFormatting.troubleSpots(progress.troubleSpots, measureNumbers: measureNumbers) {
                        Label("Trouble spots: \(spots)", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.leftHand)
                    }
                }
                .font(Theme.caption(13))
                .foregroundStyle(Theme.textSecondary)
            }
        } else {
            Text("Not practiced yet")
                .font(Theme.caption(13))
                .foregroundStyle(Theme.textSecondary)
        }
    }

    private func stat(title: String, value: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.caption(12))
                .foregroundStyle(Theme.textSecondary)
            Text(value)
                .font(Theme.heading(20))
                .foregroundStyle(Theme.textPrimary)
                .monospacedDigit()
            Text(detail)
                .font(Theme.caption(11))
                .foregroundStyle(Theme.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
