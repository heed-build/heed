import Foundation
import HeedCore

/// The key heed signs its panes' tokens with (`SessionKeys`): heed's own, kept so a pane started before a restart (a
/// zmx session heed reattaches) is still known after. A Developer ID build keeps it in the login Keychain, a
/// development build in a 0600 file (`SessionKeyStorage`). Fixtures, snapshots and the tutor check touch neither: they
/// get a key of their own. Read once, off the main actor at launch (`preload`).
enum PaneTokens {
    static let keys: SessionKeys = {
        let environment = ProcessInfo.processInfo.environment
        let fake = ["HEED_FIXTURE", "HEED_SNAPSHOT", "HEED_SHOTS", "HEED_TUTOR_CHECK"]
            .contains { environment[$0] != nil }
        if fake { return .ephemeral() }
        let stored = try? SessionKeyStorage.load(
            signing: SigningKind.current(), keychain: KeychainKeyStore(), file: FileKeyStore()
        )
        return stored ?? .ephemeral()
    }()

    /// Reads the key off the main actor at launch, so the first pane does not wait on the file.
    static func preload() {
        Task.detached(priority: .userInitiated) { _ = keys }
    }

    static func token(session: String, pane: String) -> String {
        keys.token(session: session, pane: pane)
    }
}
