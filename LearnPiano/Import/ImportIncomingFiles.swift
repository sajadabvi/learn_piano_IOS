import Foundation
import Observation

/// Files (and links) the system hands to the app — "Open in LearnPiano" from Files, Safari or Mail — waiting for the
/// Import screen. The integrator feeds it from the App scene:
///
///     .onOpenURL { url in ImportIncomingFiles.shared.receive(url, appModel: appModel) }
///
/// `receive` queues the URL and switches to the Import tab; `ImportHomeView` observes `pending` and imports it as soon
/// as no other import is running (asking first when a review is open).
@MainActor
@Observable
final class ImportIncomingFiles {
    static let shared = ImportIncomingFiles()

    private(set) var pending: [URL] = []

    init() {}

    /// Queues a file URL or an http(s) link; other schemes are ignored. Returns whether it was queued.
    @discardableResult
    func enqueue(_ url: URL) -> Bool {
        guard ImportIncomingFiles.accepts(url) else { return false }
        if !pending.contains(url) { pending.append(url) }
        return true
    }

    /// Queues the URL and shows the Import tab.
    func receive(_ url: URL, appModel: AppModel) {
        if enqueue(url) { appModel.selectedTab = .importSheet }
    }

    /// Removes and returns everything queued.
    func takeAll() -> [URL] {
        let all = pending
        pending = []
        return all
    }

    func clear() { pending = [] }

    nonisolated static func accepts(_ url: URL) -> Bool {
        if url.isFileURL { return true }
        let scheme = url.scheme?.lowercased()
        return scheme == "http" || scheme == "https"
    }
}
