import Foundation
import HeedCore

/// The key heed signs its panes' tokens with (`SessionKeys`): heed's own, kept beside its sockets, so a pane started
/// before a restart (a zmx session heed reattaches) is still known after. Fixtures, snapshots and the tutor check never
/// touch the file: they get a key of their own.
enum PaneTokens {
    static let keys: SessionKeys = {
        let environment = ProcessInfo.processInfo.environment
        let fake = ["HEED_FIXTURE", "HEED_SNAPSHOT", "HEED_SHOTS", "HEED_TUTOR_CHECK"]
            .contains { environment[$0] != nil }
        if fake { return .ephemeral() }
        return (try? SessionKeys.load()) ?? .ephemeral()
    }()

    /// Reads the key off the main actor at launch, so the first pane does not wait on the file.
    static func preload() {
        Task.detached(priority: .userInitiated) { _ = keys }
    }

    static func token(session: String, pane: String) -> String {
        keys.token(session: session, pane: pane)
    }
}
