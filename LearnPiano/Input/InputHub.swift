import Foundation
import Observation

/// The single note stream the rest of the app listens to.
///
/// Merges any number of `NoteInputSource`s (CoreMIDI, microphone, on-screen keyboard), accepts only the
/// kinds the learner selected (the on-screen keyboard is always accepted), de-duplicates keys held by
/// several sources, and tracks which keys are held. It is itself a `NoteInputSource`, so anything written
/// against the Core protocol can consume it.
///
/// Delivery paths (pick one per consumer):
/// - `onEvent` (Core protocol) and `addHandler(_:)`: called synchronously on the source's thread — lowest
///   latency, the consumer hops to its own actor.
/// - `addMainActorHandler(_:)`: called on the main actor in order (e.g. `PracticeSession.handle(_:)`).
/// - `events()`: an `AsyncStream` per call.
///
/// Event times are onset times on the host clock (`ProcessInfo.systemUptime` epoch), so delivery latency
/// does not distort timing judgements. Observable state (`heldNotes`, `recentEvents`, …) is updated on the
/// main actor.
@MainActor
@Observable
final class InputHub: NoteInputSource {
    // MARK: NoteInputSource (nonisolated, thread-safe)

    /// The selection's primary kind; individual events keep their own `source`.
    nonisolated var kind: InputSourceKind { selectionMirror.value.primaryKind }

    nonisolated var state: InputSourceState { router.isRunning ? .running : .idle }

    nonisolated var displayName: String { selectionMirror.value.displayName }

    nonisolated var onEvent: ((NoteInputEvent) -> Void)? {
        get { router.onEvent }
        set { router.onEvent = newValue }
    }

    // MARK: Observable state

    /// Which hardware input is listened to.
    private(set) var selection: InputHubSelection
    /// Whether the hub (and its selected sources) are started.
    private(set) var isRunning = false
    /// Keys currently held across all accepted sources.
    private(set) var heldNotes: Set<Int> = []
    /// Attack time (Input clock seconds) of each held key.
    private(set) var heldNoteOnTimes: [Int: TimeInterval] = [:]
    /// The most recent delivered events, newest last (at most `recentEventLimit`).
    private(set) var recentEvents: [NoteInputEvent] = []
    /// The most recent note-on (for a "last detected note" label).
    private(set) var lastNoteOn: NoteInputEvent?

    /// How many events `recentEvents` keeps.
    let recentEventLimit = 32

    /// The registered CoreMIDI source, if any.
    var midiSource: InputMIDISource? { sources.lazy.compactMap { $0 as? InputMIDISource }.first }
    /// The registered microphone source, if any.
    var microphoneSource: InputMicrophoneSource? { sources.lazy.compactMap { $0 as? InputMicrophoneSource }.first }
    /// The on-screen keyboard source (always registered).
    let virtualKeyboard: InputVirtualKeyboardSource

    /// Lifecycle state of each registered hardware kind (the on-screen keyboard is omitted).
    var sourceStates: [InputSourceKind: InputSourceState] {
        var states: [InputSourceKind: InputSourceState] = [:]
        if let midiSource { states[.midi] = midiSource.sourceState }
        if let microphoneSource { states[.microphone] = microphoneSource.sourceState }
        return states
    }

    // MARK: Private

    private let router: InputHubRouter
    private let selectionMirror: InputLockedValue<InputHubSelection>
    @ObservationIgnored private var sources: [any NoteInputSource] = []
    @ObservationIgnored private var mainHandlers: [Int: (NoteInputEvent) -> Void] = [:]
    @ObservationIgnored private var nextMainHandlerID = 0
    @ObservationIgnored private var appliedSequence = 0

    /// Creates a hub with only the on-screen keyboard registered. Use `makeDefault(settings:)` for the app.
    init(selection: InputHubSelection = .microphone) {
        self.selection = selection
        selectionMirror = InputLockedValue(selection)
        router = InputHubRouter(selection: selection)
        virtualKeyboard = InputVirtualKeyboardSource()
        register(virtualKeyboard)
    }

    /// The app's hub: CoreMIDI, microphone and on-screen keyboard sources, configured from `settings`.
    static func makeDefault(settings: UserSettings) -> InputHub {
        let hub = InputHub(selection: InputHubSelection(preferred: settings.preferredInput))
        hub.register(InputMIDISource())
        let microphone = InputMicrophoneSource()
        microphone.apply(settings)
        hub.register(microphone)
        return hub
    }

    deinit {
        router.finishAllStreams()
    }

    // MARK: Sources

    /// Adds a source; the hub takes over its `onEvent`. Started immediately when the hub is running and the
    /// source's kind is selected.
    func register(_ source: any NoteInputSource) {
        guard !sources.contains(where: { $0 === source }) else { return }
        sources.append(source)
        let router = self.router
        source.onEvent = { [weak self] event in
            let routed = router.receive(event)
            guard !routed.events.isEmpty else { return }
            InputMainActor.run { self?.applyRouted(routed) }
        }
        if isRunning, selection.enabledKinds.contains(source.kind) { source.start() }
    }

    /// Removes a source, stopping it and releasing keys it held.
    func unregister(_ source: any NoteInputSource) {
        guard let index = sources.firstIndex(where: { $0 === source }) else { return }
        sources.remove(at: index)
        source.onEvent = nil
        source.stop()
        if !sources.contains(where: { $0.kind == source.kind }) {
            applyRouted(router.releaseAll(from: source.kind, at: InputClock.now))
        }
    }

    // MARK: Lifecycle

    nonisolated func start() {
        InputMainActor.run { [weak self] in self?.startOnMain() }
    }

    nonisolated func stop() {
        InputMainActor.run { [weak self] in self?.stopOnMain() }
    }

    private func startOnMain() {
        guard !isRunning else { return }
        isRunning = true
        router.isRunning = true
        for source in sources where selection.enabledKinds.contains(source.kind) { source.start() }
    }

    private func stopOnMain() {
        guard isRunning else { return }
        for source in sources { source.stop() }
        applyRouted(router.releaseAll(at: InputClock.now))
        isRunning = false
        router.isRunning = false
    }

    /// Chooses which hardware input is listened to; deselected sources stop and their keys are released.
    func select(_ newSelection: InputHubSelection) {
        guard newSelection != selection else { return }
        selection = newSelection
        selectionMirror.value = newSelection
        let enabled = newSelection.enabledKinds
        applyRouted(router.setEnabledKinds(enabled, at: InputClock.now))
        guard isRunning else { return }
        // `start()` is idempotent for every Input source, and retries a source that failed or lacked
        // permission before.
        for source in sources {
            if enabled.contains(source.kind) { source.start() } else { source.stop() }
        }
    }

    /// Applies the persisted input preference and microphone calibration.
    func apply(_ settings: UserSettings) {
        microphoneSource?.apply(settings)
        // `.both` is not persisted by Core's single `preferredInput`; keep it when MIDI is its primary kind.
        let preferred = InputHubSelection(preferred: settings.preferredInput)
        if !(selection == .both && preferred == .midi) { select(preferred) }
    }

    // MARK: Injection (on-screen keyboard, tests, previews)

    /// Routes an event as if a source had produced it. Events labelled `.virtualKeyboard` go through the
    /// on-screen keyboard source (which must be started, i.e. the hub running); others are routed directly,
    /// which lets tests and previews simulate a MIDI keyboard or the microphone. Thread-safe.
    nonisolated func inject(_ event: NoteInputEvent) {
        if event.source == .virtualKeyboard {
            virtualKeyboard.send(event)
        } else {
            let routed = router.receive(event)
            guard !routed.events.isEmpty else { return }
            InputMainActor.run { [weak self] in self?.applyRouted(routed) }
        }
    }

    // MARK: Subscriptions

    /// Calls `handler` for every delivered event on the delivering (source) thread.
    nonisolated func addHandler(_ handler: @escaping (NoteInputEvent) -> Void) -> InputHubSubscription {
        let router = self.router
        let id = router.addHandler(handler)
        return InputHubSubscription { router.removeHandler(id) }
    }

    /// Calls `handler` on the main actor for every delivered event, in delivery order.
    func addMainActorHandler(_ handler: @escaping @MainActor (NoteInputEvent) -> Void) -> InputHubSubscription {
        nextMainHandlerID += 1
        let id = nextMainHandlerID
        mainHandlers[id] = handler
        return InputHubSubscription { [weak self] in
            InputMainActor.run { self?.mainHandlers[id] = nil }
        }
    }

    /// A new stream of every delivered event; it ends when the consuming task is cancelled or the hub goes
    /// away. If the consumer falls behind, the oldest buffered events beyond `limit` are dropped.
    nonisolated func events(bufferingNewest limit: Int = 256) -> AsyncStream<NoteInputEvent> {
        let (stream, continuation) = AsyncStream.makeStream(of: NoteInputEvent.self,
                                                            bufferingPolicy: .bufferingNewest(max(1, limit)))
        let router = self.router
        let id = router.addContinuation(continuation)
        continuation.onTermination = { _ in router.removeContinuation(id) }
        return stream
    }

    // MARK: Main-actor bookkeeping

    /// Updates observable state and calls main-actor handlers for routed events.
    private func applyRouted(_ routed: InputHubRouter.Routed) {
        guard !routed.events.isEmpty else { return }
        if routed.snapshot.sequence > appliedSequence {
            appliedSequence = routed.snapshot.sequence
            heldNoteOnTimes = routed.snapshot.heldOnTimes
            heldNotes = Set(routed.snapshot.heldOnTimes.keys)
        }
        recentEvents.append(contentsOf: routed.events)
        if recentEvents.count > recentEventLimit { recentEvents.removeFirst(recentEvents.count - recentEventLimit) }
        if let on = routed.events.last(where: { $0.kind == .on }) { lastNoteOn = on }
        let handlers = mainHandlers.sorted { $0.key < $1.key }.map(\.value)
        for event in routed.events {
            for handler in handlers { handler(event) }
        }
    }
}
