import SwiftUI

/// Review of an imported score before it is saved: metadata, notation preview with "Listen", per-measure transcription
/// confidence, diagnostics, page re-transcription, Save and Discard.
struct ImportReviewView: View {
    @Bindable var pipeline: ImportPipeline
    /// Called after a successful save with the new library entry.
    var onSaved: (SongEntry) -> Void

    @Environment(AppModel.self) private var appModel
    @Environment(ContentStore.self) private var contentStore

    @State private var highlight = NotationHighlightModel(showsCursor: false, highlightsSoundingNotes: false)
    @State private var selectedMeasure: Int?
    @State private var showsFixes = false
    @State private var confirmsDiscard = false
    @State private var retranscribeTarget: Int?

    private static let previewID = "import-preview"

    var body: some View {
        if let draft = pipeline.draft {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        summary(draft)
                        detailsCard
                        previewCard(draft)
                            .id(Self.previewID)
                        if draft.isTranscription { pagesCard(draft) }
                        diagnosticsCard(draft) { index in
                            select(index, in: draft)
                            withAnimation(.easeInOut(duration: 0.3)) { proxy.scrollTo(Self.previewID, anchor: .top) }
                        }
                    }
                    .padding(24)
                    .frame(maxWidth: 1100, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.interactively)
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Discard", role: .destructive) { confirmsDiscard = true }
                        .disabled(pipeline.isBusy)
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let entry = pipeline.save(to: contentStore) { onSaved(entry) }
                    } label: {
                        Label("Save to My Songs", systemImage: "square.and.arrow.down")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(pipeline.isBusy || pipeline.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .confirmationDialog("Discard this import?", isPresented: $confirmsDiscard, titleVisibility: .visible) {
                Button("Discard", role: .destructive) { pipeline.discard() }
                Button("Keep Reviewing", role: .cancel) {}
            } message: {
                Text("The score has not been saved yet.")
            }
            .confirmationDialog(retranscribeTitle, isPresented: Binding(get: { retranscribeTarget != nil }, set: { if !$0 { retranscribeTarget = nil } }), titleVisibility: .visible) {
                Button("Re-transcribe") {
                    if let page = retranscribeTarget { pipeline.retranscribe(page: page) }
                    retranscribeTarget = nil
                }
                Button("Cancel", role: .cancel) { retranscribeTarget = nil }
            } message: {
                Text("The page is sent to Claude again and its measures are replaced. Your title, genre and description are kept.")
            }
            .alert("Import", isPresented: Binding(get: { pipeline.reviewError != nil }, set: { if !$0 { pipeline.reviewError = nil } })) {
                Button("OK", role: .cancel) { pipeline.reviewError = nil }
            } message: {
                Text(pipeline.reviewError ?? "")
            }
            .onChange(of: draft.id) { _, _ in clearSelection() }
        }
    }

    private var retranscribeTitle: String {
        "Re-transcribe page \((retranscribeTarget ?? 0) + 1)?"
    }

    // MARK: Summary

    private func summary(_ draft: ImportDraft) -> some View {
        let score = draft.score
        let hands = score.hasNotes(for: .right) && score.hasNotes(for: .left) ? "Both hands" : (score.hasNotes(for: .left) ? "Left hand" : "Right hand")
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: draft.kind.systemImage)
                    .foregroundStyle(Theme.accent)
                Text(draft.sourceName)
                    .font(Theme.caption(14))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Text(draft.isTranscription ? "Check the transcription, then save it to your library." : "Check the details, then save the piece to your library.")
                .font(Theme.title(24))
                .foregroundStyle(Theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ImportFactChip(text: "\(score.measures.count) measures")
                    ImportFactChip(text: score.initialKey.displayName)
                    ImportFactChip(text: score.initialTime.description)
                    ImportFactChip(text: "♩ = \(Int(score.initialTempoBPM.rounded()))")
                    ImportFactChip(text: hands)
                    if draft.isTranscription { ImportFactChip(text: "\(draft.pageCount) page\(draft.pageCount == 1 ? "" : "s")") }
                    if draft.errorCount > 0 { ImportFactChip(text: "\(draft.errorCount) error\(draft.errorCount == 1 ? "" : "s")", tint: Theme.wrong) }
                    if !draft.lowConfidenceMeasures.isEmpty {
                        ImportFactChip(text: "\(draft.lowConfidenceMeasures.count) measure\(draft.lowConfidenceMeasures.count == 1 ? "" : "s") to check", tint: Theme.waiting)
                    }
                }
            }
        }
    }

    // MARK: Details

    private var genreOptions: [String] {
        var options = contentStore.genres.filter { !$0.isEmpty && $0 != ImportPipeline.otherGenre }
        if !pipeline.genre.isEmpty, pipeline.genre != ImportPipeline.otherGenre, !options.contains(pipeline.genre) { options.append(pipeline.genre) }
        options.sort { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        options.append(ImportPipeline.otherGenre)
        return options
    }

    private var detailsCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Details")
                .font(Theme.heading())
                .foregroundStyle(Theme.textPrimary)
            Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 16, verticalSpacing: 12) {
                GridRow {
                    fieldLabel("Title")
                    TextField("Title", text: $pipeline.title)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                }
                GridRow {
                    fieldLabel("Composer")
                    TextField("Composer", text: $pipeline.composer)
                        .textFieldStyle(.roundedBorder)
                        .textInputAutocapitalization(.words)
                }
                GridRow {
                    fieldLabel("Genre")
                    Picker("Genre", selection: $pipeline.genre) {
                        ForEach(genreOptions, id: \.self) { Text($0).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .gridCellAnchor(.leading)
                }
                GridRow {
                    fieldLabel("Difficulty")
                    Picker("Difficulty", selection: $pipeline.difficulty) {
                        ForEach(Difficulty.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 480)
                    .gridCellAnchor(.leading)
                }
                GridRow {
                    fieldLabel("Description")
                    TextField("What should a learner know about this piece?", text: $pipeline.descriptionText, axis: .vertical)
                        .lineLimit(2...5)
                        .textFieldStyle(.roundedBorder)
                }
            }
        }
        .card()
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .font(Theme.caption(14))
            .foregroundStyle(Theme.textSecondary)
            .frame(minWidth: 90, alignment: .leading)
    }

    // MARK: Preview

    private func previewCard(_ draft: ImportDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("Preview")
                    .font(Theme.heading())
                    .foregroundStyle(Theme.textPrimary)
                Text("Tap a measure to inspect it.")
                    .font(Theme.caption())
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button {
                    listen(draft)
                } label: {
                    Label("Listen", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(pipeline.isBusy)
            }
            if draft.isTranscription {
                ImportConfidenceStrip(confidence: draft.confidence, measureNumbers: draft.score.measures.map { $0.number },
                                      pageStarts: Set(draft.pageRanges.map { $0.lowerBound }), selected: selectedMeasure) { index in
                    select(index, in: draft)
                }
            }
            if let m = selectedMeasure, draft.score.measures.indices.contains(m) {
                selectedMeasureDetail(m, in: draft)
            }
            NotationScoreView(score: draft.score, highlight: highlight, mode: .page, staffSpace: 7, showsFingering: true,
                              onSelectMeasure: { select($0, in: draft) })
                .frame(height: 540)
                .background(Theme.sheetBackground)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Theme.separator, lineWidth: 1))
        }
        .card()
    }

    private func selectedMeasureDetail(_ m: Int, in draft: ImportDraft) -> some View {
        let number = draft.score.measures[m].number
        let issues = draft.diagnostics.filter { $0.measureIndex == m && $0.severity != .info }
        let confidence = draft.confidence.indices.contains(m) ? draft.confidence[m] : nil
        var facts: [String] = ["Measure \(number)"]
        if let c = confidence { facts.append("confidence \(Int((c * 100).rounded())) %") }
        if let page = draft.page(ofMeasure: m) { facts.append("page \(page + 1)") }
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: "scope")
                .foregroundStyle(Theme.accent)
            VStack(alignment: .leading, spacing: 4) {
                Text(facts.joined(separator: " · "))
                    .font(Theme.heading(15))
                    .foregroundStyle(Theme.textPrimary)
                if issues.isEmpty {
                    Text("No problems were found in this measure.")
                        .font(Theme.caption())
                        .foregroundStyle(Theme.textSecondary)
                } else {
                    ForEach(Array(issues.enumerated()), id: \.offset) { _, issue in
                        Text(issue.message)
                            .font(Theme.caption())
                            .foregroundStyle(issue.severity == .error ? Theme.wrong : Theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Spacer()
            if let page = draft.page(ofMeasure: m) {
                Button("Re-transcribe page \(page + 1)") { retranscribeTarget = page }
                    .buttonStyle(.bordered)
                    .disabled(pipeline.isBusy)
            }
            Button {
                clearSelection()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear selection")
        }
        .padding(12)
        .background(Theme.accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    // MARK: Pages

    private func pagesCard(_ draft: ImportDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Pages")
                .font(Theme.heading())
                .foregroundStyle(Theme.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    ForEach(0..<draft.pageCount, id: \.self) { page in
                        pageTile(page, in: draft)
                    }
                }
                .padding(.bottom, 4)
            }
        }
        .card()
    }

    private func pageTile(_ page: Int, in draft: ImportDraft) -> some View {
        let range = draft.pageRanges.indices.contains(page) ? draft.pageRanges[page] : 0..<0
        let numbers = draft.score.measures.map { $0.number }
        let measuresText: String
        if range.isEmpty {
            measuresText = "No measures"
        } else if let first = numbers[importSafe: range.lowerBound], let last = numbers[importSafe: range.upperBound - 1] {
            measuresText = first == last ? "Measure \(first)" : "Measures \(first)–\(last)"
        } else {
            measuresText = "\(range.count) measures"
        }
        let average = draft.averageConfidence(ofPage: page)
        let lowCount = range.filter { ImportPageMerger.level(draft.confidence[importSafe: $0] ?? nil) == .low }.count
        return VStack(alignment: .leading, spacing: 8) {
            Group {
                if let image = draft.thumbnails[importSafe: page] {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "doc")
                        .font(.largeTitle)
                        .foregroundStyle(Theme.textSecondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 170, height: 220)
            .background(Theme.sheetBackground)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(Theme.separator, lineWidth: 1))
            .onTapGesture {
                if !range.isEmpty { select(range.lowerBound, in: draft) }
            }
            Text("Page \(page + 1)")
                .font(Theme.heading(15))
                .foregroundStyle(Theme.textPrimary)
            Text(measuresText)
                .font(Theme.caption())
                .foregroundStyle(Theme.textSecondary)
            if let average {
                Text("Confidence \(Int((average * 100).rounded())) %" + (lowCount > 0 ? " · \(lowCount) low" : ""))
                    .font(Theme.caption())
                    .foregroundStyle(lowCount > 0 ? Theme.wrong : Theme.textSecondary)
            }
            Button("Re-transcribe page \(page + 1)") { retranscribeTarget = page }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(pipeline.isBusy)
        }
        .frame(width: 170, alignment: .leading)
    }

    // MARK: Diagnostics

    private func diagnosticsCard(_ draft: ImportDraft, onSelect: @escaping (Int) -> Void) -> some View {
        let problems = draft.diagnostics.filter { $0.severity != .info }
        let fixes = draft.diagnostics.filter { $0.severity == .info }
        return VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Checks")
                    .font(Theme.heading())
                    .foregroundStyle(Theme.textPrimary)
                Spacer()
                if draft.errorCount > 0 { ImportFactChip(text: "\(draft.errorCount) error\(draft.errorCount == 1 ? "" : "s")", tint: Theme.wrong) }
                if draft.warningCount > 0 { ImportFactChip(text: "\(draft.warningCount) warning\(draft.warningCount == 1 ? "" : "s")", tint: Theme.waiting) }
            }
            if problems.isEmpty {
                Label("No problems found. Every measure adds up and every note is playable.", systemImage: "checkmark.circle.fill")
                    .font(Theme.body(15))
                    .foregroundStyle(Theme.correct)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(problems.enumerated()), id: \.offset) { i, d in
                        if i > 0 { Divider() }
                        ImportDiagnosticRow(diagnostic: d, location: ImportDiagnostics.location(of: d, in: draft.score)) {
                            if let m = d.measureIndex { onSelect(m) }
                        }
                    }
                }
            }
            if !fixes.isEmpty {
                DisclosureGroup(isExpanded: $showsFixes) {
                    VStack(spacing: 0) {
                        ForEach(Array(fixes.enumerated()), id: \.offset) { i, d in
                            if i > 0 { Divider() }
                            ImportDiagnosticRow(diagnostic: d, location: ImportDiagnostics.location(of: d, in: draft.score)) {
                                if let m = d.measureIndex { onSelect(m) }
                            }
                        }
                    }
                } label: {
                    Text("\(fixes.count) note\(fixes.count == 1 ? "" : "s") and automatic fix\(fixes.count == 1 ? "" : "es")")
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textSecondary)
                }
            }
        }
        .card()
    }

    // MARK: Actions

    private func select(_ index: Int, in draft: ImportDraft) {
        guard draft.score.measures.indices.contains(index) else { return }
        if selectedMeasure == index {
            clearSelection()
            return
        }
        selectedMeasure = index
        highlight.loopRange = MeasureRange(single: index)
        let starts = draft.score.notatedMeasureStarts
        if starts.indices.contains(index) { highlight.positionTick = Double(starts[index]) + 1 }
    }

    private func clearSelection() {
        selectedMeasure = nil
        highlight.loopRange = nil
    }

    private func listen(_ draft: ImportDraft) {
        let name = pipeline.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let request = PracticeRequest(score: draft.score, arrangementID: "import-preview:\(draft.id.uuidString)",
                                      title: name.isEmpty ? "Imported score" : name, subtitle: "Preview · not saved yet",
                                      settings: PracticeSettings(mode: .listen, hands: .both, countInMeasures: 0))
        appModel.presentPractice(request)
    }
}

// MARK: - Building blocks

/// One cell per measure, coloured by transcription confidence; tap to inspect the measure.
struct ImportConfidenceStrip: View {
    let confidence: [Double?]
    let measureNumbers: [Int]
    let pageStarts: Set<Int>
    let selected: Int?
    let onSelect: (Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ScrollViewReader { proxy in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 2) {
                        ForEach(confidence.indices, id: \.self) { i in
                            cell(i)
                                .padding(.leading, pageStarts.contains(i) && i > 0 ? 8 : 0)
                                .id(i)
                        }
                    }
                    .padding(.vertical, 3)
                }
                .onChange(of: selected) { _, new in
                    if let new { withAnimation { proxy.scrollTo(new, anchor: .center) } }
                }
            }
            HStack(spacing: 16) {
                legend(color: Theme.correct, text: "Confident")
                legend(color: Theme.waiting, text: "Check")
                legend(color: Theme.wrong, text: "Likely wrong")
                legend(color: Theme.separator, text: "Not rated")
            }
        }
    }

    private func cell(_ i: Int) -> some View {
        let c = confidence[i]
        let number = measureNumbers.indices.contains(i) ? measureNumbers[i] : i + 1
        return RoundedRectangle(cornerRadius: 3, style: .continuous)
            .fill(ImportConfidenceStrip.color(for: c))
            .frame(width: 16, height: 30)
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .stroke(Theme.accent, lineWidth: selected == i ? 2.5 : 0)
            )
            .contentShape(Rectangle())
            .onTapGesture { onSelect(i) }
            .accessibilityElement()
            .accessibilityLabel("Measure \(number)")
            .accessibilityValue(c.map { "confidence \(Int(($0 * 100).rounded())) percent" } ?? "not rated")
            .accessibilityAddTraits(.isButton)
    }

    private func legend(color: Color, text: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(text).font(Theme.caption(12)).foregroundStyle(Theme.textSecondary)
        }
    }

    static func color(for confidence: Double?) -> Color {
        switch ImportPageMerger.level(confidence) {
        case .high: return Theme.correct
        case .medium: return Theme.waiting
        case .low: return Theme.wrong
        case .unknown: return Theme.separator
        }
    }
}

struct ImportDiagnosticRow: View {
    let diagnostic: ScoreDiagnostic
    let location: String?
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: icon)
                    .foregroundStyle(tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    if let location {
                        Text(location)
                            .font(Theme.caption())
                            .foregroundStyle(Theme.textSecondary)
                    }
                    Text(diagnostic.message)
                        .font(Theme.body(15))
                        .foregroundStyle(Theme.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                if diagnostic.measureIndex != nil {
                    Image(systemName: "chevron.right")
                        .font(.footnote)
                        .foregroundStyle(Theme.textSecondary)
                }
            }
            .padding(.vertical, 10)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(diagnostic.measureIndex == nil)
    }

    private var icon: String {
        switch diagnostic.severity {
        case .error: return "xmark.octagon.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .info: return "wrench.and.screwdriver"
        }
    }

    private var tint: Color {
        switch diagnostic.severity {
        case .error: return Theme.wrong
        case .warning: return Theme.waiting
        case .info: return Theme.textSecondary
        }
    }
}

struct ImportFactChip: View {
    let text: String
    var tint: Color = Theme.textSecondary

    var body: some View {
        Text(text)
            .font(Theme.caption())
            .foregroundStyle(tint == Theme.textSecondary ? Theme.textPrimary : tint)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(tint.opacity(0.12), in: Capsule())
    }
}

extension Array {
    /// Element at an index, or nil when out of bounds (Import module helper).
    fileprivate subscript(importSafe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}
