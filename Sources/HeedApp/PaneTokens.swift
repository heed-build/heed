import Foundation
import HeedCore

/// The key heed signs its panes' tokens with (`SessionKeys`): heed's own, kept so a pane started before a restart (a
/// zmx session heed reattaches) is still known after. A Developer ID build keeps it in the login Keychain, a
/// development build in a 0600 file (`SessionKeyStorage`). Fixtures, snapshots and the tutor check touch neither: they
/// get a key of their own. Read once, off the main actor at launch (`preload`). A key that cannot be read or kept gives
/// way to one for this run, and `read.problem` says why (Settings shows it, the call log has it).
enum PaneTokens {
    static let signing = SigningKind.current()

    static let read: SessionKeyRead = {
        let environment = ProcessInfo.processInfo.environment
        let fake = ["HEED_FIXTURE", "HEED_SNAPSHOT", "HEED_SHOTS", "HEED_TUTOR_CHECK"]
            .contains { environment[$0] != nil }
        if fake { return SessionKeyRead(keys: .ephemeral(), problem: nil) }
        return SessionKeyRead.load(signing: signing, keychain: KeychainKeyStore(), file: FileKeyStore())
    }()

    static var keys: SessionKeys { read.keys }

    /// Reads the key off the main actor at launch, so the first pane does not wait on the file.
    static func preload() {
        Task.detached(priority: .userInitiated) { _ = read }
    }

    static func token(session: String, pane: String) -> String {
        keys.token(session: session, pane: pane)
    }
}
