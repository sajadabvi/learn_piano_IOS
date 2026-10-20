import SwiftUI

/// Navigation value for the song detail screen; optionally preselects an arrangement.
struct LibrarySongRoute: Hashable {
    var songID: String
    var arrangementID: String?
}

/// Registers the Library's navigation destinations on a NavigationStack.
struct LibraryNavigationDestinations: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationDestination(for: LibrarySongRoute.self) { route in
            LibrarySongDetailView(songID: route.songID, initialArrangementID: route.arrangementID)
        }
    }
}

// MARK: - Mastery ring

/// Circular progress ring with the percentage in the middle; a dashed ring with "New" when never practiced.
struct LibraryMasteryRing: View {
    var mastery: Double?
    var size: CGFloat = 44
    var lineWidth: CGFloat = 5

    var body: some View {
        ZStack {
            Circle()
                .stroke(Theme.separator, style: StrokeStyle(lineWidth: lineWidth, dash: mastery == nil ? [3, 3] : []))
            if let mastery {
                Circle()
                    .trim(from: 0, to: max(0.001, min(1, mastery)))
                    .stroke(mastery >= 0.999 ? Theme.correct : Theme.accent, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            Text(LibraryFormatting.mastery(mastery))
                .font(.system(size: size * 0.24, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(mastery == nil ? Theme.textSecondary : Theme.textPrimary)
                .minimumScaleFactor(0.6)
                .lineLimit(1)
                .padding(lineWidth)
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(LibraryFormatting.masteryAccessibility(mastery))
    }
}

// MARK: - Badges and tags

/// Colored capsule naming a difficulty level.
struct LibraryDifficultyBadge: View {
    var difficulty: Difficulty
    var compact = false

    var body: some View {
        let color = DifficultyPalette.color(forLevel: difficulty.rawValue)
        Text(compact ? String(difficulty.displayName.prefix(3)) : difficulty.displayName)
            .font(Theme.caption(compact ? 11 : 12))
            .foregroundStyle(color)
            .padding(.horizontal, compact ? 6 : 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.12), in: Capsule())
            .accessibilityLabel("\(difficulty.displayName) level")
    }
}

/// Neutral capsule for a genre or category.
struct LibraryTag: View {
    var text: String

    var body: some View {
        Text(text)
            .font(Theme.caption(12))
            .foregroundStyle(Theme.textSecondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(Theme.background, in: Capsule())
            .overlay(Capsule().stroke(Theme.separator, lineWidth: 1))
    }
}

/// Heart button bound to the profile's favorites.
struct LibraryFavoriteButton: View {
    var songID: String
    var size: CGFloat = 18
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        let isFavorite = profileStore.isFavorite(songID: songID)
        Button {
            profileStore.toggleFavorite(songID: songID)
        } label: {
            Image(systemName: isFavorite ? "heart.fill" : "heart")
                .font(.system(size: size, weight: .semibold))
                .foregroundStyle(isFavorite ? Theme.wrong : Theme.textSecondary)
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 44, height: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
        .sensoryFeedback(.selection, trigger: isFavorite)
    }
}

/// A selectable chip (category filter).
struct LibraryChip: View {
    var title: String
    var count: Int?
    var isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .font(Theme.caption(14))
                if let count {
                    Text("\(count)")
                        .font(Theme.caption(12))
                        .monospacedDigit()
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Theme.textSecondary)
                }
            }
            .foregroundStyle(isSelected ? Color.white : Theme.textPrimary)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(isSelected ? Theme.accent : Theme.card, in: Capsule())
            .overlay(Capsule().stroke(isSelected ? Color.clear : Theme.separator, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }
}

// MARK: - Song card

/// Grid card for a song: title, composer, genre, difficulty badges, mastery ring and a favorite heart.
struct LibrarySongCard: View {
    var song: SongEntry
    @Environment(ProfileStore.self) private var profileStore

    var body: some View {
        ZStack(alignment: .topTrailing) {
            NavigationLink(value: LibrarySongRoute(songID: song.id)) {
                cardBody
            }
            .buttonStyle(LibraryCardButtonStyle())
            LibraryFavoriteButton(songID: song.id)
                .padding(4)
        }
    }

    private var cardBody: some View {
        let mastery = LibraryMastery.songMastery(song) { profileStore.progress(forArrangement: $0) }
        let lastPracticed = profileStore.progress(forSong: song)?.lastPracticed
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                LibrarySongArtwork(song: song)
                VStack(alignment: .leading, spacing: 3) {
                    Text(song.title)
                        .font(Theme.heading(18))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    Text(song.composer.isEmpty ? "Unknown composer" : song.composer)
                        .font(Theme.body(14))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                .padding(.trailing, 32)
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                if !song.genre.isEmpty { LibraryTag(text: song.genre) }
                if song.isUserImported { LibraryTag(text: "Imported") }
            }
            Spacer(minLength: 0)
            HStack(alignment: .bottom) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 4) {
                        ForEach(LibraryFormatting.difficulties(of: song), id: \.self) { level in
                            LibraryDifficultyBadge(difficulty: level, compact: song.arrangements.count > 2)
                        }
                    }
                    Text(LibraryFormatting.lastPracticed(lastPracticed))
                        .font(Theme.caption(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                LibraryMasteryRing(mastery: mastery, size: 46)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 170, alignment: .topLeading)
        .card()
        .accessibilityElement(children: .combine)
    }
}

/// Small colored square with a music glyph, tinted by the song's easiest level.
struct LibrarySongArtwork: View {
    var song: SongEntry
    var size: CGFloat = 48

    var body: some View {
        let color = DifficultyPalette.color(forLevel: song.easiestDifficulty?.rawValue ?? "")
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(LinearGradient(colors: [color.opacity(0.85), color.opacity(0.55)], startPoint: .topLeading, endPoint: .bottomTrailing))
            .frame(width: size, height: size)
            .overlay(
                Image(systemName: song.isUserImported ? "doc.richtext" : "music.note")
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            )
            .accessibilityHidden(true)
    }
}

/// Press feedback for card-shaped buttons and links.
struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .opacity(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

/// Responsive grid of song cards: 3–4 columns on iPad landscape, fewer when narrower.
struct LibrarySongGrid: View {
    var songs: [SongEntry]

    static let columns = [GridItem(.adaptive(minimum: 280, maximum: 420), spacing: 20, alignment: .top)]

    var body: some View {
        LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 20) {
            ForEach(songs) { song in
                LibrarySongCard(song: song)
            }
        }
    }
}

// MARK: - Continue practicing

/// Hero card for one recently practiced arrangement. Tapping it starts practice; the context menu opens details.
struct LibraryRecentCard: View {
    var item: LibraryRecentItem
    var isLoading: Bool
    var onPractice: () -> Void
    var onShowDetails: () -> Void

    var body: some View {
        Button(action: onPractice) {
            HStack(spacing: 14) {
                LibraryMasteryRing(mastery: item.mastery, size: 58, lineWidth: 6)
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.song.title)
                        .font(Theme.heading(17))
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        LibraryDifficultyBadge(difficulty: item.arrangement.difficulty)
                        if item.arrangement.label.lowercased() != item.arrangement.difficulty.rawValue {
                            Text(item.arrangement.label)
                                .font(Theme.caption(12))
                                .foregroundStyle(Theme.textSecondary)
                                .lineLimit(1)
                        }
                    }
                    Text(LibraryFormatting.lastPracticed(item.progress?.lastPracticed))
                        .font(Theme.caption(12))
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                ZStack {
                    Circle().fill(Theme.accent)
                    if isLoading {
                        ProgressView().tint(.white)
                    } else {
                        Image(systemName: "play.fill")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.white)
                            .offset(x: 1)
                    }
                }
                .frame(width: 40, height: 40)
            }
            .frame(width: 320, alignment: .leading)
            .card()
        }
        .buttonStyle(LibraryCardButtonStyle())
        .contextMenu {
            Button("Practice", systemImage: "play.fill", action: onPractice)
            Button("Song Details", systemImage: "info.circle", action: onShowDetails)
        }
        .accessibilityLabel("Continue \(item.song.title), \(item.arrangement.label)")
        .accessibilityHint("Opens the practice screen")
    }
}

// MARK: - Section header

struct LibrarySectionHeader: View {
    var title: String
    var subtitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(Theme.heading(22))
                .foregroundStyle(Theme.textPrimary)
            if let subtitle {
                Text(subtitle)
                    .font(Theme.body(14))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityAddTraits(.isHeader)
    }
}
