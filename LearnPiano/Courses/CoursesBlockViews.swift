import SwiftUI

// MARK: - Text

/// A lesson text block: paragraphs with **bold** spans.
struct CoursesRichText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(CoursesMarkdown.paragraphs(in: text).enumerated()), id: \.offset) { _, paragraph in
                Text(CoursesMarkdown.attributed(paragraph))
                    .font(Theme.body(17))
                    .foregroundStyle(Theme.textPrimary)
                    .lineSpacing(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Tip

/// A tip callout with the accent color.
struct CoursesTipCallout: View {
    let text: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "lightbulb.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accent)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Tip")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.accent)
                Text(CoursesMarkdown.attributed(CoursesMarkdown.paragraphs(in: text).joined(separator: "\n")))
                    .font(Theme.body(16))
                    .foregroundStyle(Theme.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(Theme.cardPadding)
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(alignment: .leading) {
            UnevenRoundedRectangle(topLeadingRadius: Theme.cornerRadius, bottomLeadingRadius: Theme.cornerRadius, style: .continuous)
                .fill(Theme.accent)
                .frame(width: 4)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Glossary

/// A table of terms and meanings. Rows with more than two cells show the extra cells as further columns.
struct CoursesGlossaryTable: View {
    let rows: [[String]]

    private var columnCount: Int { max(1, rows.map(\.count).max() ?? 1) }

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: 20, verticalSpacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                GridRow {
                    ForEach(0..<columnCount, id: \.self) { column in
                        let cell = row.indices.contains(column) ? row[column] : ""
                        Text(CoursesMarkdown.attributed(cell))
                            .font(column == 0 ? Theme.heading(16) : Theme.body(16))
                            .foregroundStyle(column == 0 ? Theme.textPrimary : Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: column == 0 ? nil : .infinity, alignment: .leading)
                            .padding(.vertical, 10)
                    }
                }
                if index < rows.count - 1 {
                    Divider().overlay(Theme.separator).gridCellUnsizedAxes(.horizontal)
                }
            }
        }
        .card()
        .accessibilityElement(children: .contain)
    }
}

// MARK: - Keyboard illustration

/// A non-interactive keyboard with the given keys highlighted, on the dark media background.
struct CoursesKeyboardIllustration: View {
    let pitches: [Int]
    let caption: String

    var body: some View {
        let range = CoursesKeyboardIllustrationLayout.visibleRange(for: pitches)
        VStack(alignment: .leading, spacing: 10) {
            KeyboardView(
                visibleRange: range,
                keyStates: CoursesKeyboardIllustrationLayout.keyStates(for: pitches),
                labels: CoursesKeyboardIllustrationLayout.labels(for: range),
                showsMiddleCMarker: true,
                isTouchEnabled: false,
                highlightsTouches: false
            )
            .frame(height: 150)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .allowsHitTesting(false)
            .accessibilityLabel(CoursesKeyboardIllustrationLayout.accessibilityLabel(for: pitches))

            Text(caption)
                .font(Theme.caption(14))
                .foregroundStyle(.white.opacity(0.8))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .background(Theme.mediaBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
    }
}

// MARK: - Notation illustration

/// A small score engraved in page mode on white, sized to its content.
struct CoursesNotationIllustration: View {
    let score: Score
    let caption: String

    @State private var highlight = NotationHighlightModel(showsCursor: false, highlightsSoundingNotes: false)
    @State private var width: CGFloat = 0
    @State private var contentHeight: CGFloat?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotationScoreView(score: score, highlight: highlight, mode: .page, staffSpace: CoursesNotationIllustrationLayout.staffSpace, showsFingering: true)
                .frame(height: contentHeight ?? CoursesNotationIllustrationLayout.staffSpace * 22)
                .frame(maxWidth: CoursesNotationIllustrationLayout.maximumWidth(for: score))
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
                .allowsHitTesting(false)
                .accessibilityLabel(caption)
                .task(id: CoursesNotationIllustrationLayout.layoutRequest(score: score, width: width)) {
                    guard let request = CoursesNotationIllustrationLayout.layoutRequest(score: score, width: width) else { return }
                    let plan = await NotationLayoutCache.shared.plan(for: request)
                    if !Task.isCancelled { contentHeight = plan.contentSize.height }
                }
            Text(caption)
                .font(Theme.caption(14))
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.sheetBackground, in: RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous).stroke(Theme.separator, lineWidth: 1))
    }
}

// MARK: - Exercise card

/// An interactive exercise: instructions, mode and pass criteria, and the "Start exercise" button.
struct CoursesExerciseCard: View {
    let exercise: Exercise
    let isPassed: Bool
    let attempts: Int
    let isLoading: Bool
    let isDisabled: Bool
    let errorMessage: String?
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 14) {
                CoursesSymbolBadge(symbol: CoursesExerciseRequestFactory.symbol(for: exercise.mode), size: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text("EXERCISE")
                        .font(Theme.caption(11))
                        .tracking(0.8)
                        .foregroundStyle(Theme.accent)
                    Text(exercise.title)
                        .font(Theme.heading(19))
                        .foregroundStyle(Theme.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                if isPassed {
                    Label("Passed", systemImage: "checkmark.circle.fill")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.correct)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Theme.correct.opacity(0.12), in: Capsule())
                }
            }

            Text(CoursesMarkdown.attributed(exercise.instructions))
                .font(Theme.body(16))
                .foregroundStyle(Theme.textPrimary)
                .fixedSize(horizontal: false, vertical: true)

            CoursesChipRow(chips: [
                (exercise.mode.displayName + " mode", CoursesExerciseRequestFactory.symbol(for: exercise.mode)),
                (exercise.hands.displayName, "hand.raised.fingers.spread"),
                (CoursesExerciseRequestFactory.passDescription(for: exercise), "flag.checkered"),
            ])

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(Theme.caption(13))
                    .foregroundStyle(Theme.wrong)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 14) {
                Button(action: onStart) {
                    HStack(spacing: 8) {
                        if isLoading {
                            ProgressView().tint(.white)
                        } else {
                            Image(systemName: isPassed ? "arrow.clockwise" : "play.fill")
                        }
                        Text(isPassed ? "Practise again" : "Start exercise")
                    }
                    .font(Theme.heading(16))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(isDisabled)

                if attempts > 0 {
                    Text(attempts == 1 ? "1 attempt" : "\(attempts) attempts")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .overlay(
            RoundedRectangle(cornerRadius: Theme.cornerRadius, style: .continuous)
                .stroke(isPassed ? Theme.correct.opacity(0.5) : Theme.accent.opacity(0.25), lineWidth: 1)
        )
    }
}

/// A wrapping row of small labelled chips.
struct CoursesChipRow: View {
    let chips: [(String, String)]

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) { chipViews }
            VStack(alignment: .leading, spacing: 6) { chipViews }
        }
    }

    @ViewBuilder
    private var chipViews: some View {
        ForEach(Array(chips.enumerated()), id: \.offset) { _, chip in
            Label(chip.0, systemImage: chip.1)
                .font(Theme.caption(12))
                .foregroundStyle(Theme.textSecondary)
                .lineLimit(1)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Theme.background, in: Capsule())
        }
    }
}
