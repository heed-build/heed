import Foundation

/// Handing a session to another agent (`agent.switch`): the new agent starts in the session's worktree with a prompt
/// that tells it what it takes over, and works out from git what is already done.
public enum Handoff {
    /// The new agent's prompt: whose work it takes over and on which branch, the original task, how to see what is
    /// done, the session's PRs, and the repo's `start_instructions`. Short: the worktree holds the rest.
    public static func prompt(
        session: Session, from agent: String, prs: [PullRef] = [], base: String? = nil, instructions: String = ""
    ) -> String {
        if session.isChat { return chatPrompt(session: session, from: agent) }
        var lines = ["You are taking over work on the branch \(session.branch) from \(agent), in this worktree."]
        let task = session.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !task.isEmpty { lines.append("The task was:\n\n\(task)\n") }
        let log = base.map { "git log \($0)..HEAD" } ?? "git log against the base branch"
        lines.append(
            "Check git status, \(log) and the diff to see what is already done, then continue the work."
        )
        if !prs.isEmpty {
            lines.append(
                "Pull request\(prs.count == 1 ? "" : "s") already open for it: "
                    + prs.map(\.url).joined(separator: ", ")
            )
        }
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        if !extra.isEmpty { lines.append(extra) }
        return lines.joined(separator: "\n")
    }

    /// A chat has no branch or git history to read: the new agent is told whose conversation it takes over, where, and
    /// how it began.
    static func chatPrompt(session: Session, from agent: String) -> String {
        var lines = ["You are taking over a conversation from \(agent), in this folder."]
        let first = session.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !first.isEmpty { lines.append("It began with:\n\n\(first)\n") }
        lines.append("Look at the files here for what is already done, then carry on.")
        return lines.joined(separator: "\n")
    }

    /// The agents a session can be handed to: every configured one but its own.
    public static func candidates(agents: [String], current: String?) -> [String] {
        agents.filter { $0 != current }
    }

    /// The model and effort `agent.switch <agent> [model] [effort]` names; `-` (or nothing) is the agent's default.
    public struct Choice: Equatable, Sendable {
        public var model: String?
        public var effort: String?

        public init(model: String? = nil, effort: String? = nil) {
            self.model = Self.word(model)
            self.effort = Self.word(effort)?.lowercased()
        }

        private static func word(_ text: String?) -> String? {
            guard let text = text?.trimmingCharacters(in: .whitespaces), !text.isEmpty, text != "-" else { return nil }
            return text
        }
    }

    /// What `:agent.switch ` offers as you type: the other agents; after an agent and a space, its models (`-` for its
    /// default); after a model and a space, its efforts. Each value is the whole argument typed so far.
    public static func completions(
        _ typed: String, agents: [String], current: String?, catalogs: [String: AgentModelCatalog]
    ) -> [(value: String, summary: String)] {
        let words = typed.split(separator: " ", omittingEmptySubsequences: false).map(String.init)
        guard words.count > 1, let catalog = catalogs[words[0]] else {
            return candidates(agents: agents, current: current).map { ($0, "hand the session to \($0)") }
        }
        let agent = words[0]
        if words.count == 2 {
            guard catalog.takesModel else { return [] }
            return [("\(agent) -", "its default model")]
                + catalog.models.map { ("\(agent) \($0.id)", $0.label == $0.id ? "" : $0.label) }
        }
        guard words.count == 3 else { return [] }
        let model = words[1] == "-" ? nil : words[1]
        return catalog.efforts(for: model).map { ("\(agent) \(words[1]) \($0)", "effort") }
    }
}
