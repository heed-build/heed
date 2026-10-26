import Foundation

/// What an agent working on a goal is told at launch and resume (`[goals] tell_agents`): which goal the work belongs
/// to and where its `GOAL.md` is. Only the words live here; `GoalLaunch` decides how they travel.
public enum GoalPointer {
    /// One or two plain sentences. No quotes, backticks, dollars or backslashes, so it reads the same in every shell
    /// and in TOML.
    public static func text(title: String, path: String) -> String {
        let title = plain(GoalDoc.oneLine(title))
        return "This work belongs to the goal \(title). Read \(plain(path)) first: it says what the goal is, what is "
            + "not the goal and when it is done. Keep to its Not the goal list."
    }

    static func plain(_ text: String) -> String { text.filter { !"\"'`$\\".contains($0) } }

    /// The pointers for the sessions and chats on a goal that is not archived, by session id.
    public static func bySession(_ snapshot: GoalSnapshot, files: GoalFiles) -> [String: String] {
        var pointers: [String: String] = [:]
        for link in snapshot.links where link.kind == .session || link.kind == .chat {
            guard let goal = snapshot.goal(link.goal), goal.status != .archived else { continue }
            pointers[link.target] = text(title: goal.title, path: files.doc(goal.id).path)
        }
        return pointers
    }
}

/// Words appended to an agent's instructions at launch, as the arguments that carry them: claude's
/// `--append-system-prompt`, codex's `developer_instructions`; none for agents that take neither. Several are joined
/// into one, since each agent takes one.
public enum AgentInstructions {
    public static func arguments(agent: String, _ texts: [String]) -> [String] {
        let texts = texts.filter { !$0.isEmpty }
        guard !texts.isEmpty else { return [] }
        let text = texts.joined(separator: " ")
        return switch agent {
        case "claude": ["--append-system-prompt", text]
        case "codex": ["-c", "developer_instructions=" + TOMLValue.quote(text)]
        default: []
        }
    }
}

/// How an agent on a goal is told so at launch and resume. Claude loads heed's plugin (`--plugin-dir`), whose
/// `heed-goal` skill says how to keep the goal and finds it with `heed goal show`, so it needs no pointer text. Codex
/// takes no per-session plugin (plugins are installed), so it gets the pointer and the same guidance as instructions
/// (`GoalGuidance.instructions`). Without the plugin (a host, which does not have it) claude gets the pointer.
public enum GoalLaunch {
    public static func arguments(agent: String, signOff: String?, pointer: String?, plugin: String?) -> [String] {
        guard let pointer else { return AgentInstructions.arguments(agent: agent, [signOff].compactMap(\.self)) }
        switch agent {
        case "claude" where plugin != nil:
            return ["--plugin-dir", plugin ?? ""]
                + AgentInstructions.arguments(agent: agent, [signOff].compactMap(\.self))
        case "codex":
            return AgentInstructions.arguments(
                agent: agent, [signOff, pointer, GoalGuidance.instructions].compactMap(\.self)
            )
        default:
            return AgentInstructions.arguments(agent: agent, [signOff, pointer].compactMap(\.self))
        }
    }
}
