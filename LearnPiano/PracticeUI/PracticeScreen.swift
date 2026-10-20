import SwiftUI

/// The full-screen practice screen presented by `RootView` for an `AppModel.activePractice` request.
///
/// Layout (landscape-first): slim header · optional exercise/audio banners · dark DEMO region (falling-note
/// lanes + keyboard) · white NOTATION region (scrolling score in landscape, wrapped pages in portrait) ·
/// transport bar. Everything is driven by a `PracticeUISessionController` created on first appearance.
struct PracticeScreen: View {
    let request: PracticeRequest

    @Environment(AppModel.self) private var appModel
    @Environment(ProfileStore.self) private var profileStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var controller: PracticeUISessionController?

    init(request: PracticeRequest) {
        self.request = request
    }

    var body: some View {
        ZStack {
            Theme.background.ignoresSafeArea()
            if let controller {
                PracticeUIScreenContent(controller: controller, onClose: close)
            } else {
                ProgressView("Preparing practice…")
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .persistentSystemOverlays(.hidden)
        .onAppear {
            let c = controller ?? PracticeUISessionController(request: request)
            if controller == nil { controller = c }
            c.prepare(userSettings: profileStore.settings)
        }
        .onDisappear {
            controller?.teardown()
        }
        .onChange(of: scenePhase) { _, phase in
            controller?.scenePhaseChanged(phase)
        }
    }

    private func close() {
        controller?.close()
        appModel.dismissPractice()
    }
}

/// The practice screen once its controller exists.
struct PracticeUIScreenContent: View {
    @Bindable var controller: PracticeUISessionController
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            PracticeUIHeaderView(controller: controller, onClose: onClose)
            if let instructions = controller.request.exerciseInstructions, !instructions.isEmpty {
                PracticeUIExerciseBanner(instructions: instructions)
            }
            if let problem = controller.audioProblem {
                PracticeUIAudioBanner(message: problem)
            }
            GeometryReader { proxy in
                let metrics = PracticeUILayoutMetrics.make(size: proxy.size, showsFallingNotes: controller.showsFallingNotes)
                VStack(spacing: 0) {
                    PracticeUIDemoRegion(controller: controller, metrics: metrics, width: proxy.size.width)
                        .frame(height: metrics.laneHeight + metrics.keyboardHeight)
                    PracticeUINotationRegion(controller: controller, metrics: metrics)
                        .frame(maxHeight: .infinity)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay {
                    PracticeUICountInOverlay(controller: controller)
                }
            }
            PracticeUITransportBar(controller: controller)
        }
        .sheet(item: $controller.summary) { presentation in
            PracticeUISummarySheet(
                presentation: presentation,
                onPracticeAgain: { controller.practiceAgain() },
                onLoopTroubleSpot: { controller.loopTroubleSpot() },
                onDone: onClose
            )
            .presentationDetents([.large])
            .presentationSizing(.form)
        }
    }
}

// MARK: - Demo region

/// Dark media region: falling-note lanes over the 88-key keyboard, synchronized with playback, plus the
/// input status chip and the wrong-note pill.
struct PracticeUIDemoRegion: View {
    let controller: PracticeUISessionController
    let metrics: PracticeUILayoutMetrics
    let width: CGFloat

    var body: some View {
        let session = controller.session
        let keyboard = PracticeUIFeedbackMapper.keyboardState(from: session.feedback, timeline: session.timeline, expectedPitches: session.expectedPitches)
        let range = controller.keyboardRange(width: width)
        let loopTicks = session.loop.flatMap { session.timeline.tickRange(of: $0) }
        let player = controller.player
        KeyboardStageView(
            visibleRange: range,
            keyStates: keyboard.keyStates,
            timeline: session.timeline,
            currentTick: 0,
            tickProvider: { [weak session, weak player] in
                if let player, player.isPlaying, session?.mode != .wait { return player.positionTick }
                return session?.cursorTick ?? 0
            },
            isPlaying: session.transportState == .playing,
            laneHeight: metrics.laneHeight,
            laneHands: .both,
            loopTicks: loopTicks,
            labels: controller.showsNoteNames ? .all : .cOnly,
            showsMiddleCMarker: true,
            showsLaneNoteNames: controller.showsNoteNames,
            isTouchEnabled: true,
            onNoteEvent: { [weak controller] event in controller?.keyboardEvent(event) }
        )
        .frame(maxWidth: .infinity)
        .background(Theme.mediaBackground)
        .overlay(alignment: .topLeading) {
            PracticeUIInputStatusView(controller: controller)
                .padding(12)
        }
        .overlay(alignment: .top) {
            if let pill = controller.wrongNotePill {
                PracticeUIWrongNotePillView(pill: pill)
                    .padding(.top, 12)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .id(pill.id)
            }
        }
        .animation(.spring(duration: 0.25), value: controller.wrongNotePill)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Keyboard demonstration")
        .accessibilityValue(keyboard.expectedPitches.isEmpty ? "" : "Play " + PracticeUINoteNames.spoken(keyboard.expectedPitches))
    }
}

// MARK: - Notation region

/// White sheet-music region bound to the session cursor and feedback; tap/long-press-drag selects the loop.
struct PracticeUINotationRegion: View {
    let controller: PracticeUISessionController
    let metrics: PracticeUILayoutMetrics

    var body: some View {
        let score = controller.session.score
        let view = NotationScoreView(
            score: score,
            highlight: controller.highlight,
            mode: metrics.notationMode,
            staffSpace: metrics.staffSpace,
            showsFingering: true,
            palette: .standard,
            onSelectMeasure: { [weak controller] index in controller?.tapMeasure(index) },
            onSelectRange: { [weak controller] range in controller?.dragMeasures(range) }
        )
        Group {
            switch metrics.notationMode {
            case .scroll:
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    view
                    Spacer(minLength: 0)
                }
            case .page:
                view
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.sheetBackground)
        .clipped()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Sheet music")
        .accessibilityHint("Tap a measure to loop it. Tap another measure to extend the loop. Touch and hold, then drag, to select several measures.")
    }
}
