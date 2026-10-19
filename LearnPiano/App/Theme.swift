import SwiftUI

/// Design tokens: a light, minimal, educational look. Sheet music always sits on
/// pure white for contrast; media regions are dark; a single accent color marks
/// interactive and "current" elements.
enum Theme {
    // Colors
    static let accent = Color(red: 0.16, green: 0.47, blue: 0.96)          // interactive, selection, cursor
    static let background = Color(red: 0.97, green: 0.97, blue: 0.98)      // app background
    static let card = Color.white
    static let sheetBackground = Color.white
    static let mediaBackground = Color(red: 0.11, green: 0.11, blue: 0.13) // video / demo region
    static let textPrimary = Color(red: 0.12, green: 0.12, blue: 0.14)
    static let textSecondary = Color(red: 0.45, green: 0.46, blue: 0.50)
    static let separator = Color(red: 0.88, green: 0.88, blue: 0.90)

    // Hands (used by notation highlights and the keyboard view)
    static let rightHand = Color(red: 0.16, green: 0.47, blue: 0.96)
    static let leftHand = Color(red: 0.98, green: 0.55, blue: 0.16)

    // Feedback
    static let correct = Color(red: 0.20, green: 0.72, blue: 0.42)
    static let wrong = Color(red: 0.90, green: 0.26, blue: 0.26)
    static let waiting = Color(red: 0.96, green: 0.78, blue: 0.20)

    // Typography
    static func title(_ size: CGFloat = 28) -> Font { .system(size: size, weight: .bold, design: .rounded) }
    static func heading(_ size: CGFloat = 20) -> Font { .system(size: size, weight: .semibold, design: .rounded) }
    static func body(_ size: CGFloat = 16) -> Font { .system(size: size, weight: .regular) }
    static func caption(_ size: CGFloat = 13) -> Font { .system(size: size, weight: .medium) }

    // Layout
    static let cornerRadius: CGFloat = 14
    static let cardPadding: CGFloat = 16
}

/// Difficulty badge colors shared by library cards and the practice header.
enum DifficultyPalette {
    static func color(forLevel level: String) -> Color {
        switch level.lowercased() {
        case "beginner": return Color(red: 0.20, green: 0.72, blue: 0.42)
        case "intermediate": return Color(red: 0.16, green: 0.47, blue: 0.96)
        case "advanced": return Color(red: 0.98, green: 0.55, blue: 0.16)
        case "pro": return Color(red: 0.90, green: 0.26, blue: 0.26)
        default: return Theme.textSecondary
        }
    }
}

/// Card container used throughout browsing screens.
struct CardBackground: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(Theme.cardPadding)
            .background(Theme.card, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
            .shadow(color: .black.opacity(0.05), radius: 8, y: 2)
    }
}

extension View {
    func card() -> some View { modifier(CardBackground()) }
}
