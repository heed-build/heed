import Foundation

/// Turning a chat into work (`chat.promote`): Start work makes a worktree and a session as usual, and the new agent is
/// handed the conversation. Claude resumes the chat's own session there (`--resume` finds a session from any folder);
/// any other agent, or a claude chat whose transcript is gone, starts on a handoff prompt (`Handoff.promotion`).
public struct Promotion: Hashable, Sendable {
    /// The chat being promoted.
    public var chatID: String
    public var chatTitle: String
    /// The chat's agent, and its own session id when it can be resumed (claude, transcript still there).
    public var chatAgent: String
    public var resumeID: String?
    /// The chat's folder, its transcript (when heed knows where the agent keeps it), and what was asked in it.
    public var folder: ChatFolder
    public var transcript: String?
    public var prompts: [String]
    /// The files at the top of the chat's folder, for the handoff.
    public var files: [String]
    /// Copy those files into the new worktree (scratch chats only; off by default).
    public var copyFiles = false

    public init(
        chatID: String, chatTitle: String, chatAgent: String, resumeID: String? = nil, folder: ChatFolder,
        transcript: String? = nil, prompts: [String] = [], files: [String] = []
    ) {
        self.chatID = chatID
        self.chatTitle = chatTitle
        self.chatAgent = chatAgent
        self.resumeID = resumeID
        self.folder = folder
        self.transcript = transcript
        self.prompts = prompts
        self.files = files
    }

    /// Whether the files can be copied: a scratch folder heed made, with anything in it.
    public var canCopy: Bool { folder.kind == .scratch && !files.isEmpty }

    /// The session id the new agent continues, when it does: only claude, and only into claude.
    public func resuming(with agent: AgentProfile?) -> String? {
        agent?.name == "claude" && chatAgent == "claude" ? resumeID : nil
    }
}

public extension Handoff {
    /// The new agent's prompt when a chat becomes work: the task, where the conversation was (its transcript and what
    /// was asked), the chat's files and whether they came along, and the repo's `start_instructions`. The agent may
    /// differ from the chat's.
    static func promotion(
        _ promotion: Promotion, task: String, branch: String, instructions: String = ""
    ) -> String {
        var lines = [
            "This work started as a chat with \(promotion.chatAgent) (\"\(promotion.chatTitle)\"). You take it over "
                + "in this worktree, on the branch \(branch).",
        ]
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty { lines.append("The task:\n\n\(task)\n") }
        if let transcript = promotion.transcript {
            lines.append("The chat's transcript is \(transcript): read it for what was said and decided.")
        }
        let asked = promotion.prompts.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if !asked.isEmpty {
            lines.append("What was asked in the chat, in order:\n" + asked.map { "- \(Self.oneLine($0))" }
                .joined(separator: "\n"))
        }
        lines += filesLines(promotion)
        lines.append("Check git status, then carry on.")
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    /// What a resumed claude is told: it already has the conversation, so only where it is now and what to do.
    static func promotionResumed(_ promotion: Promotion, task: String, branch: String, instructions: String = "")
        -> String
    {
        var lines = [
            "This chat is now work in a git worktree, on the branch \(branch). You are in that worktree now; "
                + "the chat's folder was \(promotion.folder.path).",
        ]
        lines += filesLines(promotion)
        let task = task.trimmingCharacters(in: .whitespacesAndNewlines)
        lines.append(task.isEmpty ? "Carry on with the work here." : "Carry on with the work here:\n\n\(task)")
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    private static func filesLines(_ promotion: Promotion) -> [String] {
        guard !promotion.files.isEmpty else { return [] }
        let shown = promotion.files.prefix(20).joined(separator: ", ")
            + (promotion.files.count > 20 ? " and \(promotion.files.count - 20) more" : "")
        return [promotion.copyFiles
            ? "The chat's files were copied here: \(shown)."
            : "The chat's files are in \(promotion.folder.path), not copied here: \(shown)."]
    }

    /// A prompt on one line, cut at 300 characters.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > 300 ? String(flat.prefix(299)) + "…" : flat
    }
}

/// The chat folder's files, for the handoff, and copying them into the new worktree.
public enum Promote {
    /// The names at the top of `folder`, hidden ones (`.cursor`) left out, sorted.
    public static func files(in folder: String) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: folder)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
    }

    /// Copies each of `files` from `folder` into `worktree`; one already there is left as it is. Returns what was
    /// copied.
    @discardableResult
    public static func copy(_ files: [String], from folder: String, to worktree: String) -> [String] {
        // `copyItem` refuses to overwrite: a file the worktree already has stays.
        files.filter { name in
            (try? FileManager.default.copyItem(atPath: "\(folder)/\(name)", toPath: "\(worktree)/\(name)")) != nil
        }
    }
}

/// What a claude transcript says the user asked: its user turns with text, in order. Tool results and heed's own
/// injected lines are not prompts.
public enum ClaudeTranscript {
    /// `~/.claude/projects/<folder>/<id>.jsonl`.
    public static func path(id: String, directory: String, home: String = NSHomeDirectory()) -> String {
        "\(home)/.claude/projects/\(AgentIntegration.claudeProjectFolder(directory))/\(id).jsonl"
    }

    public static func prompts(in text: String, limit: Int = 12) -> [String] {
        var result: [String] = []
        for line in text.split(whereSeparator: \.isNewline) {
            guard let data = line.data(using: .utf8),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "user", object["isMeta"] as? Bool != true,
                  let message = object["message"] as? [String: Any]
            else { continue }
            let text: String? = if let content = message["content"] as? String {
                content
            } else if let parts = message["content"] as? [[String: Any]] {
                parts.compactMap { $0["type"] as? String == "text" ? $0["text"] as? String : nil }
                    .joined(separator: "\n").nilIfBlank
            } else {
                nil
            }
            guard let text, !text.hasPrefix("<") else { continue }
            result.append(text)
        }
        // The first prompt says what the chat was about; then the latest ones.
        guard result.count > limit else { return result }
        return [result[0]] + result.suffix(limit - 1)
    }
}

extension String {
    var nilIfBlank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
