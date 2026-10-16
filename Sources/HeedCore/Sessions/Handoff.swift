import Foundation

/// Handing a session to another agent (`agent.switch`): the new agent starts in the session's worktree with a prompt
/// that tells it what it takes over, and works out from git what is already done.
public enum Handoff {
    /// The new agent's prompt: whose work it takes over and on which branch, the original task, how to see what is
    /// done, the session's PRs, and the repo's `start_instructions`. Short: the worktree holds the rest.
    public static func prompt(
        session: Session, from agent: String, prs: [PullRef] = [], base: String? = nil, instructions: String = ""
    ) -> String {
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

    /// The agents a session can be handed to: every configured one but its own.
    public static func candidates(agents: [String], current: String?) -> [String] {
        agents.filter { $0 != current }
    }
}
