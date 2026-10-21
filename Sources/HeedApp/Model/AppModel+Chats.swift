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

    /// What promoting `chat` hands over, read off the main actor: the claude transcript (and whether `--resume` can
    /// continue it), what was asked in it, and the files at the top of its folder. A chat on a host hands over its
    /// prompt only: its transcript and files are there.
    nonisolated static func promotion(for chat: Session) async -> Promotion? {
        guard let folder = chat.chat else { return nil }
        return await Task.detached(priority: .userInitiated) { () -> Promotion in
            var promotion = Promotion(
                chatID: chat.id, chatTitle: chat.title, chatAgent: chat.agent, folder: folder, prompts: [chat.prompt]
            )
            guard chat.location.isLocal else { return promotion }
            if chat.agent == "claude", let id = chat.agentSessionID {
                let path = ClaudeTranscript.path(id: id, directory: folder.path)
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    promotion.transcript = path
                    promotion.resumeID = id
                    let asked = ClaudeTranscript.prompts(in: text)
                    if !asked.isEmpty { promotion.prompts = asked }
                }
            }
            promotion.files = Promote.files(in: folder.path)
            return promotion
        }.value
    }

    /// The fake world's promotion: no files read.
    static func fixturePromotion(_ chat: Session) -> Promotion? {
        guard let folder = chat.chat else { return nil }
        return Promotion(
            chatID: chat.id, chatTitle: chat.title, chatAgent: chat.agent, resumeID: chat.agentSessionID,
            folder: folder,
            transcript: chat.agentSessionID.map { ClaudeTranscript.path(
                id: $0,
                directory: folder.path,
                home: "/Users/you"
            ) },
            prompts: [chat.prompt], files: folder.kind == .scratch ? ["crontab.txt", "notes.md"] : []
        )
    }
}
