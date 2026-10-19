import CoreAudioKit
import SwiftUI
import UIKit

/// The system Bluetooth LE MIDI pairing screen (`CABTMIDICentralViewController`) for SwiftUI.
///
/// It scans for nearby BLE-MIDI keyboards and connects the one the user taps; once connected the keyboard
/// appears as a CoreMIDI source, which `InputMIDISource` picks up through its setup-change rescan. The
/// controller needs a navigation bar, so it is wrapped in a `UINavigationController` with a Done button.
/// Present it in a sheet:
///
/// ```swift
/// .sheet(isPresented: $pairing) { InputBluetoothMIDIPairingView { pairing = false } }
/// ```
struct InputBluetoothMIDIPairingView: UIViewControllerRepresentable {
    /// Called when the user taps Done.
    var onDone: () -> Void

    init(onDone: @escaping () -> Void) {
        self.onDone = onDone
    }

    func makeCoordinator() -> Coordinator { Coordinator(onDone: onDone) }

    func makeUIViewController(context: Context) -> UINavigationController {
        let central = CABTMIDICentralViewController()
        central.title = "Bluetooth MIDI"
        let coordinator = context.coordinator
        central.navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { _ in coordinator.onDone() }
        )
        return UINavigationController(rootViewController: central)
    }

    func updateUIViewController(_ controller: UINavigationController, context: Context) {
        context.coordinator.onDone = onDone
    }

    /// Holds the latest Done callback so the bar button never calls a stale closure.
    @MainActor
    final class Coordinator {
        var onDone: () -> Void
        init(onDone: @escaping () -> Void) { self.onDone = onDone }
    }
}

/// Compact list of MIDI keyboards with a button that opens Bluetooth pairing; intended for Settings and
/// the practice screen's input popover. Uses system semantic styles so it inherits the app's tint.
struct InputMIDIDeviceListView: View {
    /// The MIDI source whose devices are shown.
    var source: InputMIDISource
    @State private var isPairing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if source.devices.isEmpty {
                Text("No MIDI keyboard connected. Plug one in over USB or pair a Bluetooth keyboard.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(source.devices) { device in
                    HStack(spacing: 10) {
                        Image(systemName: "pianokeys")
                            .foregroundStyle(device.isOffline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(device.name)
                                .font(.body)
                                .foregroundStyle(.primary)
                            if let manufacturer = device.manufacturer, !manufacturer.isEmpty {
                                Text(manufacturer)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Text(device.isOffline ? "Offline" : "Connected")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(device.isOffline ? Color.secondary : Color.green)
                    }
                    .accessibilityElement(children: .combine)
                }
            }
            if let error = source.errorMessage {
                Text(error)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.red)
            }
            Button {
                isPairing = true
            } label: {
                Label("Pair Bluetooth MIDI keyboard", systemImage: "dot.radiowaves.left.and.right")
            }
        }
        .sheet(isPresented: $isPairing) {
            InputBluetoothMIDIPairingView { isPairing = false }
        }
        .onAppear { source.refreshDevices() }
    }
}
