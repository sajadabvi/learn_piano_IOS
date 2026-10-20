import SwiftUI

/// Bottom transport: progress, position, big play/pause, restart, loop start, previous/next measure, stop,
/// and live statistics. Keyboard shortcuts: space (play/pause), ←/→ (measure), ⌘R (restart),
/// ⌘L (loop start), ⌘. (stop).
struct PracticeUITransportBar: View {
    let controller: PracticeUISessionController

    var body: some View {
        VStack(spacing: 0) {
            PracticeUIProgressLine(controller: controller)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    PracticeUIPositionLabel(controller: controller)
                        .frame(minWidth: 120, alignment: .leading)
                    Spacer(minLength: 0)
                    buttons
                    Spacer(minLength: 0)
                    PracticeUILiveStats(controller: controller)
                        .frame(minWidth: 120, alignment: .trailing)
                }
                VStack(spacing: 6) {
                    buttons
                    HStack {
                        PracticeUIPositionLabel(controller: controller)
                        Spacer(minLength: 8)
                        PracticeUILiveStats(controller: controller)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .background(Theme.card)
        .overlay(alignment: .top) { Theme.separator.frame(height: 1) }
    }

    private var session: PracticeSession { controller.session }

    private var buttons: some View {
        HStack(spacing: 10) {
            transportButton("backward.end.fill", label: "Previous measure") { controller.previousMeasure() }
                .keyboardShortcut(.leftArrow, modifiers: [])
            transportButton("arrow.uturn.backward", label: session.loop == nil ? "Jump to start" : "Jump to loop start") { controller.jumpToLoopStart() }
                .keyboardShortcut("l", modifiers: .command)
            transportButton("arrow.counterclockwise", label: "Restart") { controller.restart() }
                .keyboardShortcut("r", modifiers: .command)
            playPauseButton
            transportButton("stop.fill", label: "Stop and show summary") { controller.stopAndSummarize() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(session.transportState == .stopped)
            transportButton("forward.end.fill", label: "Next measure") { controller.nextMeasure() }
                .keyboardShortcut(.rightArrow, modifiers: [])
        }
    }

    private var playPauseButton: some View {
        let active = session.isActive
        return Button {
            controller.togglePlayPause()
        } label: {
            Image(systemName: active ? "pause.fill" : "play.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 60, height: 60)
                .background(Theme.accent, in: Circle())
                .shadow(color: Theme.accent.opacity(0.3), radius: 6, y: 2)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(.space, modifiers: [])
        .accessibilityLabel(active ? "Pause" : "Play")
        .accessibilityHint("Space bar")
    }

    private func transportButton(_ systemImage: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.textPrimary)
                .frame(width: 44, height: 44)
                .background(Theme.background, in: Circle())
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

/// Thin bar of steps completed in the piece (or loop).
struct PracticeUIProgressLine: View {
    let controller: PracticeUISessionController

    var body: some View {
        let session = controller.session
        let total = controller.progressStepTicks.count
        let done = PracticeUIProgress.completedSteps(stepTicks: controller.progressStepTicks, cursorTick: session.cursorTick, finished: session.transportState == .finished)
        let fraction = PracticeUIProgress.fraction(completed: done, total: total)
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Theme.separator
                Theme.accent.frame(width: proxy.size.width * fraction)
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue("\(done) of \(total) steps")
    }
}

/// "Bar 5 / 32" with a VoiceOver description of the cursor's measure.
struct PracticeUIPositionLabel: View {
    let controller: PracticeUISessionController

    var body: some View {
        let session = controller.session
        let position = session.cursorMeasure
        VStack(alignment: .leading, spacing: 2) {
            Text(PracticeUIMeasureText.position(measureIndex: position.measureIndex, in: session.score))
                .font(.subheadline.weight(.semibold).monospacedDigit())
                .foregroundStyle(Theme.textPrimary)
            Text(stateText(session.transportState, mode: session.mode))
                .font(.caption)
                .foregroundStyle(Theme.textSecondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Current position")
        .accessibilityValue(PracticeUIMeasureText.spokenPosition(measureIndex: position.measureIndex, pass: position.pass, in: session.score)
                            + ", " + stateText(session.transportState, mode: session.mode))
    }

    private func stateText(_ state: TransportState, mode: PracticeMode) -> String {
        switch state {
        case .stopped: return "Ready"
        case .countingIn: return "Counting in"
        case .playing: return mode == .wait ? "Waiting for you" : (mode == .listen ? "Listening" : "Playing")
        case .paused: return "Paused"
        case .finished: return "Finished"
        }
    }
}

/// Live accuracy and wrong-note count of the running session.
struct PracticeUILiveStats: View {
    let controller: PracticeUISessionController

    var body: some View {
        let session = controller.session
        if session.mode == .listen {
            Text(MusicHelpers.clock(session.practicedSeconds))
                .font(.subheadline.monospacedDigit())
                .foregroundStyle(Theme.textSecondary)
                .accessibilityLabel("Time listened")
                .accessibilityValue(MusicHelpers.clock(session.practicedSeconds))
        } else {
            HStack(spacing: 14) {
                stat(PracticeUISummaryFormatter.percent(session.accuracy), "accuracy", color: Theme.correct)
                stat("\(session.statistics.wrongNotes)", session.statistics.wrongNotes == 1 ? "wrong note" : "wrong notes", color: Theme.wrong)
            }
            .accessibilityElement(children: .combine)
        }
    }

    private func stat(_ value: String, _ label: String, color: Color) -> some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(value)
                .font(.system(.headline, design: .rounded).monospacedDigit())
                .foregroundStyle(color)
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
