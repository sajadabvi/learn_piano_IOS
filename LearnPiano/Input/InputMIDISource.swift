import CoreMIDI
import Foundation
import Observation
import os

/// A MIDI source endpoint (USB, Bluetooth LE, network or another app) as shown in the device list.
struct InputMIDIDevice: Identifiable, Hashable, Sendable {
    /// CoreMIDI's persistent unique ID of the endpoint.
    var id: Int32
    /// Display name, e.g. "Digital Piano Bluetooth".
    var name: String
    /// Manufacturer when the driver reports one.
    var manufacturer: String?
    /// True while the device is known but not reachable (e.g. a paired Bluetooth keyboard switched off).
    var isOffline: Bool
}

/// Note input from MIDI keyboards through CoreMIDI.
///
/// One client and one input port (MIDI 1.0 protocol) connected to every source endpoint; the source list is
/// re-scanned whenever CoreMIDI reports a setup change, so USB and Bluetooth keyboards can be hot-plugged.
/// Incoming Universal MIDI Packets are converted to a MIDI 1.0 byte stream and parsed per endpoint (running
/// status, velocity-0 note-offs, All Notes Off), channel-agnostically. Each event is stamped with the
/// packet's host time converted to seconds (`InputClock`), i.e. the same epoch as `SystemPracticeClock`.
///
/// Note events are delivered through `onEvent` on CoreMIDI's receive thread, without a main-actor hop, for
/// the lowest latency; UI state (`devices`, `sourceState`, `lastEvent`) is main-actor observable.
@MainActor
@Observable
final class InputMIDISource: NoteInputSource {
    // MARK: NoteInputSource (nonisolated, thread-safe)

    nonisolated let kind: InputSourceKind = .midi

    nonisolated var state: InputSourceState { status.value.state }

    nonisolated var displayName: String { status.value.name }

    nonisolated var onEvent: ((NoteInputEvent) -> Void)? {
        get { relay.onEvent }
        set { relay.onEvent = newValue }
    }

    // MARK: Observable state

    /// Every MIDI source endpoint currently known to CoreMIDI, sorted by name.
    private(set) var devices: [InputMIDIDevice] = []
    /// Lifecycle state for the UI (mirrors `state`).
    private(set) var sourceState: InputSourceState = .idle
    /// The most recent note event received (for a "last key" indicator).
    private(set) var lastEvent: NoteInputEvent?
    /// Human-readable description of the last setup failure, nil when healthy.
    private(set) var errorMessage: String?

    /// Names of the reachable devices, for compact status lines.
    var connectedDeviceNames: [String] { devices.filter { !$0.isOffline }.map(\.name) }

    // MARK: Private

    /// Values the nonisolated protocol requirements read.
    private struct Status: Sendable {
        var state: InputSourceState
        var name: String
    }

    private let relay = InputEventRelay()
    private let status = InputLockedValue(Status(state: .idle, name: InputSourceKind.midi.displayName))
    private let receiver = InputMIDIReceiver()
    /// CoreMIDI handles, kept in a lock box so the nonisolated deinit can dispose of them.
    private let handles = InputLockedValue<(client: MIDIClientRef, port: MIDIPortRef)>((0, 0))
    @ObservationIgnored private var connections: [MIDIUniqueID: (endpoint: MIDIEndpointRef, token: Int)] = [:]
    @ObservationIgnored private var nextToken = 1
    @ObservationIgnored private var isStarted = false
    @ObservationIgnored private var rescanScheduled = false
    private static let log = Logger(subsystem: "LearnPiano", category: "InputMIDI")

    init() {}

    deinit {
        let h = handles.value
        if h.port != 0 { MIDIPortDispose(h.port) }
        if h.client != 0 { MIDIClientDispose(h.client) }
    }

    // MARK: Lifecycle

    nonisolated func start() {
        InputMainActor.run { [weak self] in self?.startOnMain() }
    }

    nonisolated func stop() {
        InputMainActor.run { [weak self] in self?.stopOnMain() }
    }

    /// Re-reads the endpoint list (also happens automatically on setup changes).
    func refreshDevices() {
        rescan()
    }

    private func startOnMain() {
        guard !isStarted else { return }
        setState(.starting)
        guard ensurePort() else {
            setState(.failed)
            return
        }
        isStarted = true
        errorMessage = nil
        rescan()
        setState(.running)
    }

    private func stopOnMain() {
        guard isStarted else { return }
        isStarted = false
        let port = handles.value.port
        for (_, connection) in connections {
            let result = MIDIPortDisconnectSource(port, connection.endpoint)
            if result != noErr { Self.log.debug("MIDIPortDisconnectSource failed: \(result)") }
        }
        connections.removeAll()
        relay.send(receiver.unregisterAll(at: InputClock.now))
        setState(.idle)
    }

    // MARK: CoreMIDI setup

    /// Creates the client and input port once. Returns false (with `errorMessage` set) on failure.
    private func ensurePort() -> Bool {
        if handles.value.port != 0 { return true }
        var client = MIDIClientRef()
        let clientStatus = MIDIClientCreateWithBlock("LearnPiano" as CFString, &client, Self.makeNotifyBlock(owner: self))
        guard clientStatus == noErr else {
            errorMessage = "MIDI is unavailable (error \(clientStatus))."
            Self.log.error("MIDIClientCreateWithBlock failed: \(clientStatus)")
            return false
        }
        var port = MIDIPortRef()
        let portStatus = MIDIInputPortCreateWithProtocol(client, "LearnPiano Input" as CFString, ._1_0, &port,
                                                         Self.makeReceiveBlock(owner: self, receiver: receiver, relay: relay))
        guard portStatus == noErr else {
            MIDIClientDispose(client)
            errorMessage = "Could not open a MIDI input (error \(portStatus))."
            Self.log.error("MIDIInputPortCreateWithProtocol failed: \(portStatus)")
            return false
        }
        handles.value = (client, port)
        return true
    }

    /// The client notification block: any setup change (device plugged in or removed, Bluetooth keyboard
    /// connected, property changed) schedules a coalesced rescan on the main actor.
    ///
    /// Built in a nonisolated context because CoreMIDI calls it on its own thread; a closure formed inside a
    /// `@MainActor` method would be inferred main-actor isolated.
    nonisolated private static func makeNotifyBlock(owner: InputMIDISource) -> MIDINotifyBlock {
        { [weak owner] notification in
            let id = notification.pointee.messageID
            guard id == .msgSetupChanged || id == .msgObjectAdded || id == .msgObjectRemoved || id == .msgPropertyChanged else { return }
            InputMainActor.run { owner?.scheduleRescan() }
        }
    }

    /// The input port's receive block: decodes every packet of the event list with the endpoint's parser
    /// (identified by the connection token in `srcConnRefCon`), stamps it with the packet's host time and
    /// delivers the note events on CoreMIDI's receive thread. Only the "last event" UI mirror hops to the
    /// main actor. Nonisolated for the same reason as `makeNotifyBlock`.
    nonisolated private static func makeReceiveBlock(owner: InputMIDISource, receiver: InputMIDIReceiver,
                                                     relay: InputEventRelay) -> MIDIReceiveBlock {
        { [weak owner] eventList, refCon in
            let token = Int(bitPattern: refCon)
            var events: [NoteInputEvent] = []
            for packet in eventList.unsafeSequence() {
                let time = InputClock.seconds(hostTime: packet.pointee.timeStamp)
                events += receiver.handle(words: packet.words(), time: time, token: token)
            }
            guard let last = events.last else { return }
            relay.send(events)
            InputMainActor.run { owner?.lastEvent = last }
        }
    }

    /// Coalesces bursts of setup notifications into one rescan.
    private func scheduleRescan() {
        guard !rescanScheduled else { return }
        rescanScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rescanScheduled = false
                self.rescan()
            }
        }
    }

    /// Lists all source endpoints, connects new ones and disconnects vanished ones (releasing their keys).
    private func rescan() {
        var found: [MIDIUniqueID: (endpoint: MIDIEndpointRef, device: InputMIDIDevice)] = [:]
        for index in 0..<MIDIGetNumberOfSources() {
            let endpoint = MIDIGetSource(index)
            guard endpoint != 0, let uniqueID = Self.intProperty(endpoint, kMIDIPropertyUniqueID) else { continue }
            let name = Self.stringProperty(endpoint, kMIDIPropertyDisplayName)
                ?? Self.stringProperty(endpoint, kMIDIPropertyName)
                ?? "MIDI device"
            let device = InputMIDIDevice(id: uniqueID, name: name,
                                         manufacturer: Self.stringProperty(endpoint, kMIDIPropertyManufacturer),
                                         isOffline: (Self.intProperty(endpoint, kMIDIPropertyOffline) ?? 0) != 0)
            found[uniqueID] = (endpoint, device)
        }
        devices = found.values.map(\.device).sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        updateDisplayName()

        guard isStarted else { return }
        let port = handles.value.port
        let now = InputClock.now
        for (uniqueID, connection) in connections where found[uniqueID] == nil {
            // The endpoint is gone; disconnecting may legitimately fail because CoreMIDI already removed it.
            let result = MIDIPortDisconnectSource(port, connection.endpoint)
            if result != noErr { Self.log.debug("Disconnect of removed source returned \(result)") }
            connections[uniqueID] = nil
            relay.send(receiver.unregister(token: connection.token, at: now))
        }
        for (uniqueID, entry) in found where connections[uniqueID] == nil {
            let token = nextToken
            nextToken += 1
            receiver.register(token: token)
            let result = MIDIPortConnectSource(port, entry.endpoint, UnsafeMutableRawPointer(bitPattern: token))
            if result == noErr {
                connections[uniqueID] = (entry.endpoint, token)
            } else {
                _ = receiver.unregister(token: token, at: now)
                Self.log.error("MIDIPortConnectSource failed for \(entry.device.name, privacy: .public): \(result)")
            }
        }
    }

    // MARK: State helpers

    private func setState(_ newState: InputSourceState) {
        sourceState = newState
        status.withValue { $0.state = newState }
    }

    private func updateDisplayName() {
        let names = connectedDeviceNames
        let name = names.isEmpty ? InputSourceKind.midi.displayName : names.joined(separator: ", ")
        status.withValue { $0.name = name }
    }

    /// A string property of a MIDI object, or nil.
    private static func stringProperty(_ object: MIDIObjectRef, _ key: CFString) -> String? {
        var value: Unmanaged<CFString>?
        guard MIDIObjectGetStringProperty(object, key, &value) == noErr, let string = value?.takeRetainedValue() else { return nil }
        return string as String
    }

    /// An integer property of a MIDI object, or nil.
    private static func intProperty(_ object: MIDIObjectRef, _ key: CFString) -> Int32? {
        var value: Int32 = 0
        guard MIDIObjectGetIntegerProperty(object, key, &value) == noErr else { return nil }
        return value
    }
}
