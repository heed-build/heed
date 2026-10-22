import Foundation
import HeedCore

/// Chats: the glue that must live on the model.
extension AppModel {
    /// Claude Code asks to trust every new folder, and a scratch chat's folder is new every time. Claude also accepts a
    /// trusted parent folder outside a git repo, so heed trusts the chats root it owns, once, before the first claude
    /// chat there (`[worktrees] offer_trust` off leaves it alone). A picked folder is yours to trust. Says so when it
    /// did.
    func trustChatsRoot(for plan: StartWorkPlan) async -> String? {
        guard settings.offerTrust, let chat = plan.chat, chat.kind == .scratch, chat.location.isLocal,
              plan.agent?.name == "claude"
        else { return nil }
        let root = Chats.localRoot
        let trusted = await Task.detached { () -> Bool in
            if ClaudeTrust.isTrusted(root) { return false }
            try? FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
            return (try? ClaudeTrust.trust(root)) != nil
        }.value
        return trusted ? "trusted \(Paths.abbreviate(root)) for Claude Code" : nil
    }
}
