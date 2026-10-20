import Foundation
import Observation
import os
import SwiftUI

/// The summary sheet's content: one ended session.
struct PracticeUISummaryPresentation: Identifiable {
    let id = UUID()
    var summary: PracticeSummary
    var text: PracticeUISummaryText
}

/// The transient "Expected: C4 E4" pill after a wrong note in Wait Mode.
struct PracticeUIWrongNotePill: Identifiable, Equatable {
    let id = UUID()
    var text: String
    var spoken: String
}

/// Owns and wires everything behind the practice screen: the audio synth/player/metronome, the input hub,
/// the `PracticeSession`, and the notation highlight model.
///
/// Lifecycle: created with the request (the session exists immediately, silent); `prepare(userSettings:)` on
/// appear brings up audio and input and attaches them; `teardown()` on disappear stops everything. Input
/// events reach the session through a main-actor hub subscription; follower events feed echo suppression and
/// the wrong-note pill; ended sessions are reported through `request.onFinish`.
@MainActor
@Observable
final class PracticeUISessionController {
    // MARK: Public state

    let request: PracticeRequest
    let session: PracticeSession
    /// Cursor, feedback, dimming and loop tint for the notation view (synced from the session).
    let highlight: NotationHighlightModel

    private(set) var synth: AudioPianoSynth?
    private(set) var player: AudioScorePlayer?
    private(set) var metronome: AudioMetronome?
    private(set) var hub: InputHub?

    /// Problem bringing up sound, shown as a banner (practice still works silently).
    private(set) var audioProblem: String?
    /// Current wrong-note pill, nil when hidden.
    private(set) var wrongNotePill: PracticeUIWrongNotePill?
    /// Summary sheet content, nil when hidden.
    var summary: PracticeUISummaryPresentation?
    /// Loop selection state (mirrors `session.settings.loop`).
    private(set) var loopSelection: PracticeUILoopSelection
    /// Ticks of the learner's steps in the loop/piece, for the progress bar.
    private(set) var progressStepTicks: [Ticks] = []
    /// Falling-note lanes visible.
    var showsFallingNotes = true
    /// Note names on the keyboard keys.
    var showsNoteNames = true
    /// Whether `prepare` has run (and `teardown` has not).
    private(set) var isPrepared = false
    /// Whether the screen was closed (no further summaries).
    private(set) var isClosed = false

    /// Input selection currently listened to.
    var inputSelection: InputHubSelection { hub?.selection ?? .onScreenOnly }

    // MARK: Private

    @ObservationIgnored private var inputSubscription: InputHubSubscription?
    @ObservationIgnored private var pillTask: Task<Void, Never>?
    @ObservationIgnored private var observing = false
    @ObservationIgnored private var showSummaryForNextEnd = false
    @ObservationIgnored private var lastProgressKey: (HandSelection, MeasureRange?)?
    @ObservationIgnored private var wasPlayingBeforeBackground = false
    @ObservationIgnored private var activatedAudioSession = false
    @ObservationIgnored private var keyboardRangeCache: [String: ClosedRange<Int>] = [:]
    private static let log = Logger(subsystem: "LearnPiano", category: "PracticeUI")

    init(request: PracticeRequest) {
        self.request = request
        let session = PracticeSession(score: request.score, arrangementID: request.arrangementID, settings: request.settings)
        self.session = session
        self.loopSelection = PracticeUILoopSelection(loop: session.settings.loop)
        let notation = PracticeUIFeedbackMapper.notationState(from: session.feedback, settings: session.settings)
        self.highlight = NotationHighlightModel(timeline: session.timeline, positionTick: session.cursorTick, feedback: notation.feedback,
                                                practicedHands: notation.practicedHands, dimsUnpracticedHands: notation.dimsOtherHands,
                                                loopRange: notation.loop, showsCursor: true, highlightsSoundingNotes: true)
        session.onSessionEnded = { [weak self] record in self?.sessionEnded(record) }
        session.onFollowerEvent = { [weak self] event in self?.followerEvent(event) }
        refreshProgressTicks()
    }

    // MARK: Lifecycle

    /// Brings up audio and input and connects them to the session. Idempotent.
    func prepare(userSettings: UserSettings) {
        guard !isPrepared, !isClosed else { return }
        isPrepared = true
        showsFallingNotes = userSettings.showFallingNotes
        showsNoteNames = userSettings.showNoteNames
        startObservingSession()
        prepareAudio(a4Hertz: userSettings.a4Hertz)
        prepareInput(userSettings: userSettings)
    }

    private func prepareAudio(a4Hertz: Double) {
        do {
            if !AudioSessionConfigurator.isConfigured() { try AudioSessionConfigurator.configure() }
            try AudioSessionConfigurator.activate(true)
            activatedAudioSession = true
        } catch {
            Self.log.error("Audio session setup failed: \(error.localizedDescription, privacy: .public)")
            audioProblem = "Sound could not be started (\(error.localizedDescription)). You can still practice silently."
        }
        let synth = AudioPianoSynth(a4Hertz: a4Hertz)
        synth.masterVolume = Float(SettingsAudioPreferences.masterVolume)
        do {
            try synth.start()
        } catch {
            Self.log.error("Synth start failed: \(error.localizedDescription, privacy: .public)")
            audioProblem = "The piano sound is unavailable (\(error.localizedDescription)). You can still practice silently."
            return
        }
        let player = AudioScorePlayer(synth: synth)
        let metronome = AudioMetronome(synth: synth, player: player)
        self.synth = synth
        self.player = player
        self.metronome = metronome
        session.attach(player: player, metronome: metronome)
        // The session installed its own callbacks; chain echo suppression after them.
        let sessionEventHandler = player.onEventStarted
        player.onEventStarted = { [weak self] event in
            sessionEventHandler?(event)
            self?.noteAppSounding(event)
        }
        player.onInterrupted = { [weak self] in
            self?.session.pause()
        }
    }

    private func prepareInput(userSettings: UserSettings) {
        let hub = InputHub.makeDefault(settings: userSettings)
        self.hub = hub
        inputSubscription = hub.addMainActorHandler { [weak self] event in
            self?.session.handle(event)
            self?.syncExpectedPitches()
        }
        hub.start()
        syncExpectedPitches()
    }

    /// Stops the session (reporting it), the engines and the input; safe to call repeatedly.
    func teardown() {
        guard isPrepared else {
            // Never prepared: still report a session the learner may have run silently.
            session.stop()
            return
        }
        isPrepared = false
        showSummaryForNextEnd = false
        session.stop()
        observing = false
        pillTask?.cancel()
        pillTask = nil
        inputSubscription?.cancel()
        inputSubscription = nil
        hub?.clearAppSounding()
        hub?.stop()
        metronome?.cancelCountIn()
        metronome?.stop()
        player?.stop()
        player?.onEventStarted = nil
        player?.onReachedEnd = nil
        player?.onInterrupted = nil
        synth?.allNotesOff()
        synth?.stop()
        session.attach(player: nil, metronome: nil)
        if activatedAudioSession {
            do {
                try AudioSessionConfigurator.activate(false)
            } catch {
                Self.log.error("Audio session deactivation failed: \(error.localizedDescription, privacy: .public)")
            }
            activatedAudioSession = false
        }
    }

    /// Ends the session (reported through `onFinish`) without showing the summary; the caller dismisses.
    func close() {
        isClosed = true
        summary = nil
        teardown()
    }

    /// Pauses when the app leaves the foreground and releases the microphone in the background.
    func scenePhaseChanged(_ phase: ScenePhase) {
        guard isPrepared else { return }
        switch phase {
        case .active:
            hub?.start()
            if synth?.isRunning == false {
                do { try synth?.start() } catch {
                    Self.log.error("Synth restart failed: \(error.localizedDescription, privacy: .public)")
                    audioProblem = "The piano sound could not be restarted (\(error.localizedDescription))."
                }
            }
        case .inactive:
            if session.isActive { session.pause() }
        case .background:
            if session.isActive { session.pause() }
            hub?.clearAppSounding()
            hub?.stop()
        @unknown default:
            if session.isActive { session.pause() }
        }
    }

    // MARK: Session observation → notation highlight and progress

    private func startObservingSession() {
        guard !observing else { return }
        observing = true
        syncFromSession()
        observeNextChange()
    }

    private func observeNextChange() {
        guard observing else { return }
        withObservationTracking {
            _ = session.cursorTick
            _ = session.feedback
            _ = session.settings
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, self.observing else { return }
                self.syncFromSession()
                self.observeNextChange()
            }
        }
    }

    private func syncFromSession() {
        let notation = PracticeUIFeedbackMapper.notationState(from: session.feedback, settings: session.settings)
        if highlight.positionTick != session.cursorTick { highlight.positionTick = session.cursorTick }
        if highlight.feedback != notation.feedback { highlight.feedback = notation.feedback }
        if highlight.practicedHands != notation.practicedHands { highlight.practicedHands = notation.practicedHands }
        if highlight.dimsUnpracticedHands != notation.dimsOtherHands { highlight.dimsUnpracticedHands = notation.dimsOtherHands }
        if highlight.loopRange != notation.loop { highlight.loopRange = notation.loop }
        if loopSelection.loop != session.settings.loop {
            loopSelection = PracticeUILoopSelection(loop: session.settings.loop, anchor: nil, remembered: session.settings.loop ?? loopSelection.remembered)
        }
        refreshProgressTicks()
    }

    private func refreshProgressTicks() {
        let key = (session.settings.hands, session.settings.loop)
        if let last = lastProgressKey, last.0 == key.0, last.1 == key.1 { return }
        lastProgressKey = key
        progressStepTicks = PracticeUIProgress.stepTicks(timeline: session.timeline, hands: key.0, loop: key.1)
    }

    // MARK: Session callbacks

    private func sessionEnded(_ record: PracticeSessionRecord) {
        request.onFinish?(record.summary)
        let finished = session.transportState == .finished
        guard !isClosed, finished || showSummaryForNextEnd else { return }
        showSummaryForNextEnd = false
        hub?.clearAppSounding()
        summary = PracticeUISummaryPresentation(summary: record.summary,
                                                text: PracticeUISummaryFormatter.format(record.summary, score: session.score, request: request))
    }

    /// Keeps the input hub's echo suppression aware of the keys the learner should play next.
    private func syncExpectedPitches() {
        hub?.setExpectedPitches(session.expectedPitches, anyOctave: session.settings.octaveTolerance)
    }

    private func followerEvent(_ event: PracticeFollowerEvent) {
        defer { syncExpectedPitches() }
        switch event {
        case .soundChord(let chord, _):
            hub?.noteAppSounding(chord)
        case .played(let record):
            if record.outcome == .wrong, session.mode == .wait { showWrongNotePill(expected: record.expected) }
        case .resyncRequested:
            hub?.clearAppSounding()
        case .stepBecameCurrent:
            if wrongNotePill != nil, session.mode == .wait { hideWrongNotePill() }
        case .measureCompleted, .loopWrapped, .finished:
            break
        }
    }

    private func noteAppSounding(_ event: TimelineEvent) {
        guard let hub, !event.isRest else { return }
        let seconds = session.timeline.tempoMap.seconds(from: event.tick, length: event.duration, speed: session.speed)
        let now = InputClock.now
        hub.noteAppSounding(pitches: event.pitches, from: now, until: now + max(0.05, seconds))
    }

    private func showWrongNotePill(expected: [Int]) {
        let pitches = expected.isEmpty ? session.expectedPitches : expected
        let key = session.score.keySignature(atMeasure: session.cursorMeasure.measureIndex)
        guard let text = PracticeUINoteNames.expectedPill(pitches, key: key) else { return }
        wrongNotePill = PracticeUIWrongNotePill(text: text, spoken: "Wrong note. Expected " + PracticeUINoteNames.spoken(pitches, key: key))
        pillTask?.cancel()
        pillTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_800_000_000)
            guard !Task.isCancelled else { return }
            self?.hideWrongNotePill()
        }
    }

    private func hideWrongNotePill() {
        pillTask?.cancel()
        pillTask = nil
        wrongNotePill = nil
    }

    // MARK: Transport

    func togglePlayPause() {
        summary = nil
        if !session.isActive { hub?.clearAppSounding() }
        session.togglePlayPause()
    }

    /// Ends the running session and shows its summary.
    func stopAndSummarize() {
        guard session.transportState != .stopped else { return }
        showSummaryForNextEnd = true
        hub?.clearAppSounding()
        let record = session.stop()
        if record == nil { showSummaryForNextEnd = false }
    }

    func restart() {
        summary = nil
        hub?.clearAppSounding()
        hideWrongNotePill()
        session.restart()
    }

    func jumpToLoopStart() {
        hub?.clearAppSounding()
        session.seek(toMeasure: session.settings.loop?.start ?? 0)
    }

    func previousMeasure() {
        let position = session.cursorMeasure
        let beat = session.score.timeSignature(atMeasure: position.measureIndex).beatTicks
        hub?.clearAppSounding()
        session.seek(toMeasure: PracticeUINavigation.previousMeasure(current: position.measureIndex, tickInMeasure: position.tickInMeasure, beatTicks: beat))
    }

    func nextMeasure() {
        hub?.clearAppSounding()
        session.seek(toMeasure: PracticeUINavigation.nextMeasure(current: session.cursorMeasure.measureIndex, measureCount: session.score.measures.count))
    }

    // MARK: Settings

    func setMode(_ mode: PracticeMode) {
        guard mode != session.mode else { return }
        hub?.clearAppSounding()
        hideWrongNotePill()
        session.mode = mode
    }

    func setHands(_ hands: HandSelection) {
        guard hands != session.hands else { return }
        hideWrongNotePill()
        session.hands = hands
        refreshProgressTicks()
    }

    func setSpeed(_ speed: Double) { session.speed = speed }

    func toggleMetronome() { session.metronomeEnabled.toggle() }

    func setCountIn(_ measures: Int) { session.countInMeasures = measures }

    func setOctaveTolerance(_ on: Bool) {
        var s = session.settings
        s.octaveTolerance = on
        session.updateSettings(s)
    }

    func setPlayOtherHands(_ on: Bool) {
        var s = session.settings
        s.playOtherHands = on
        session.updateSettings(s)
    }

    /// Hands that have notes in this score (the others cannot be practiced).
    var availableHands: [HandSelection] {
        let right = session.score.hasNotes(for: .right)
        let left = session.score.hasNotes(for: .left)
        var out: [HandSelection] = []
        if right { out.append(.right) }
        if left { out.append(.left) }
        if right && left { out.append(.both) }
        return out.isEmpty ? [.both] : out
    }

    /// Visible keyboard keys for the practiced hands at a width (memoized per hands and 50 pt width bucket).
    func keyboardRange(width: CGFloat) -> ClosedRange<Int> {
        let hands = session.hands
        let bucket = max(1, Int((width / 50).rounded(.down)))
        let key = "\(hands.rawValue)-\(bucket)"
        if let cached = keyboardRangeCache[key] { return cached }
        let range = PracticeUIKeyboardRange.range(for: session.score, hands: hands, width: CGFloat(bucket * 50))
        keyboardRangeCache[key] = range
        return range
    }

    // MARK: Loop

    func toggleLoop() {
        var selection = loopSelection
        let fallback = PracticeUILoopSelection.defaultRange(cursorMeasure: session.cursorMeasure.measureIndex, measureCount: session.score.measures.count)
        selection.toggle(fallback: fallback, measureCount: session.score.measures.count)
        applyLoop(selection)
    }

    func tapMeasure(_ index: Int) {
        var selection = loopSelection
        selection.tap(measure: index, measureCount: session.score.measures.count)
        applyLoop(selection)
    }

    func dragMeasures(_ range: MeasureRange) {
        var selection = loopSelection
        selection.drag(range, measureCount: session.score.measures.count)
        applyLoop(selection)
    }

    func clearLoop() {
        var selection = loopSelection
        selection.clear()
        applyLoop(selection)
    }

    private func applyLoop(_ selection: PracticeUILoopSelection) {
        loopSelection = selection
        if session.loop != selection.loop {
            hub?.clearAppSounding()
            session.loop = selection.loop
            refreshProgressTicks()
        }
    }

    // MARK: Summary actions

    func practiceAgain() {
        summary = nil
        hub?.clearAppSounding()
        session.play()
    }

    func loopTroubleSpot() {
        guard let range = summary?.text.troubleLoop else { return }
        summary = nil
        var selection = loopSelection
        selection.set(range, measureCount: session.score.measures.count)
        applyLoop(selection)
        if session.mode == .listen { session.mode = .wait }
        session.play()
    }

    // MARK: Input

    func selectInput(_ selection: InputHubSelection) {
        hub?.select(selection)
    }

    /// Touch on the on-screen keyboard: route it to the hub (as the virtual-keyboard source) and sound it.
    func keyboardEvent(_ event: NoteInputEvent) {
        guard let hub else { return }
        switch event.kind {
        case .on:
            if let synth {
                synth.noteOn(event.midi, velocity: event.velocity)
                // The microphone must not report the speaker's sound of the touched key.
                let now = InputClock.now
                hub.noteAppSounding(pitches: [event.midi], from: now, until: now + 1.5)
            }
        case .off:
            synth?.noteOff(event.midi)
        }
        hub.inject(event)
    }

    /// Opens the system Settings app page (microphone permission).
    var microphoneSettingsURL: URL? { InputMicrophoneSource.systemSettingsURL }
}
