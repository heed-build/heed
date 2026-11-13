import Foundation

/// One permission request an agent is waiting on: run a command, edit a file, fetch a page, use a tool. Never a
/// question to you (Claude's `AskUserQuestion`, a plan to approve, Codex's `request_user_input`): those stay the
/// session's asking state (`PermissionAsk.isQuestion`).
///
/// A hook ask (`channel == .hook`) came from the agent's own permission hook, which waits for heed's answer; a screen
/// ask is a blocked session heed knows only from its state, answered in its pane.
public struct PermissionAsk: Codable, Hashable, Sendable, Identifiable {
    public enum Channel: String, Codable, Sendable {
        /// The agent's permission hook is waiting on heed's answer (Claude Code, Codex).
        case hook
        /// Only the session's state says it waits: answered in its pane.
        case screen
    }

    /// Made by the hook that asked; the answer goes back on that hook's own connection.
    public var id: String
    /// The heed session (`HEED_SESSION_ID`) and pane (`HEED_PANE_ID`) the hook ran in.
    public var session: String
    public var pane: String?
    public var agent: String
    /// The subagent's type, when a subagent asked (its hook carries `agent_id`).
    public var subagent: String?
    /// `Bash`, `Edit`, `apply_patch`, `WebFetch`, `mcp__github__create_pull_request`.
    public var tool: String
    /// The shell command, for a shell tool.
    public var command: String?
    /// The files it would touch, as the agent names them.
    public var paths: [String]
    /// What would change, as `-` and `+` lines (an edit's old and new text, Codex's patch), capped.
    public var patch: String?
    public var url: String?
    /// Why it asks, when the agent says (Codex's approval reason, a Bash call's description).
    public var why: String?
    /// The agent's permission mode when it asked (`default`, `acceptEdits`, `plan`, `auto`, ...).
    public var mode: String?
    /// Where the agent ran.
    public var cwd: String?
    public var askedAt: Date
    /// Allow rules the agent offered to save with a yes (Claude's `permission_suggestions`): what "always" sends back.
    public var rules: [PermissionRule]
    public var channel: Channel

    public init(
        id: String, session: String, pane: String? = nil, agent: String, subagent: String? = nil, tool: String,
        command: String? = nil, paths: [String] = [], patch: String? = nil, url: String? = nil, why: String? = nil,
        mode: String? = nil, cwd: String? = nil, askedAt: Date, rules: [PermissionRule] = [],
        channel: Channel = .hook
    ) {
        self.id = id
        self.session = session
        self.pane = pane
        self.agent = agent
        self.subagent = subagent
        self.tool = tool
        self.command = command
        self.paths = paths
        self.patch = patch
        self.url = url
        self.why = why
        self.mode = mode
        self.cwd = cwd
        self.askedAt = askedAt
        self.rules = rules
        self.channel = channel
    }

    /// Tools that ask you something rather than for permission: never approvals.
    public static let questionTools: Set<String> = ["AskUserQuestion", "ExitPlanMode", "request_user_input"]

    public static func isQuestion(tool: String?) -> Bool { tool.map(questionTools.contains) ?? false }

    /// A Notification `permission_prompt` whose message names a question tool (`... to use AskUserQuestion`).
    public static func isQuestion(message: String?) -> Bool {
        guard let message else { return false }
        return questionTools.contains { message.contains($0) }
    }

    /// Longest patch kept, in lines.
    public static let patchLines = 40
    /// Longest command kept, in characters.
    public static let commandLimit = 4000

    /// The ask a Claude Code or Codex `PermissionRequest` hook describes; nil for a question tool or no tool.
    public static func from(
        hook input: [String: Any], agent: String, session: String, pane: String?, id: String = UUID().uuidString,
        now: Date = Date()
    ) -> PermissionAsk? {
        guard let tool = input["tool_name"] as? String, !tool.isEmpty, !isQuestion(tool: tool) else { return nil }
        let args = input["tool_input"] as? [String: Any] ?? [:]
        var ask = PermissionAsk(
            id: id, session: session, pane: pane, agent: agent, subagent: input["agent_type"] as? String,
            tool: tool, mode: input["permission_mode"] as? String, cwd: input["cwd"] as? String, askedAt: now
        )
        if input["agent_id"] == nil { ask.subagent = nil }
        ask.why = (args["description"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        switch tool {
        case "Bash", "PowerShell", "shell", "exec_command":
            ask.command = (args["command"] as? String).map { cap($0) }
        case "apply_patch":
            // Codex sends the patch itself as `command`.
            let patch = args["command"] as? String ?? args["patch"] as? String ?? ""
            ask.paths = patchPaths(patch)
            ask.patch = capLines(patch)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            if let path = (args["file_path"] ?? args["notebook_path"]) as? String { ask.paths = [path] }
            ask.patch = editPatch(tool: tool, args: args)
        case "WebFetch":
            ask.url = args["url"] as? String
        default:
            if let path = (args["file_path"] ?? args["path"]) as? String { ask.paths = [path] }
            ask.url = args["url"] as? String
            ask.command = (args["command"] as? String).map { cap($0) }
        }
        ask.rules = rules(input["permission_suggestions"])
        return ask
    }

    /// The ask a blocked session's state stands for, read from its reason (`Bash(git push)`, as heed's hooks describe
    /// a tool); the tool alone when the reason is not in that form.
    public static func screen(_ session: Session, now: Date) -> PermissionAsk {
        var ask = PermissionAsk(
            id: "screen-\(session.id)", session: session.id, agent: session.agent, tool: "a tool",
            askedAt: session.lastActivity > now ? now : session.lastActivity, channel: .screen
        )
        let reason = session.state.reason ?? ""
        if let open = reason.firstIndex(of: "("), reason.hasSuffix(")"), open > reason.startIndex {
            ask.tool = String(reason[..<open])
            let argument = String(reason[reason.index(after: open) ..< reason.index(before: reason.endIndex)])
            switch ask.tool.lowercased() {
            case "bash", "shell", "powershell": ask.command = argument
            case "webfetch": ask.url = argument
            default: ask.paths = [argument]
            }
        } else if !reason.isEmpty {
            ask.tool = reason
        }
        return ask
    }

    /// What it asks for, in a few words: "Run a command", "Edit 2 files", "Fetch a page".
    public var title: String {
        switch tool {
        case "Bash", "PowerShell", "shell", "exec_command", "bash": return "Run a command"
        case "apply_patch", "Edit", "MultiEdit", "Write", "NotebookEdit", "edit", "write":
            let count = max(paths.count, 1)
            return count == 1 ? (tool == "Write" ? "Write a file" : "Edit a file") : "Edit \(count) files"
        case "WebFetch", "webfetch": return "Fetch a page"
        case "WebSearch": return "Search the web"
        case "Read", "read": return "Read a file"
        default:
            if tool.hasPrefix("mcp__") {
                let parts = tool.split(separator: "_", omittingEmptySubsequences: true)
                return parts.count >= 3 ? "Use \(parts[1])'s \(parts[2...].joined(separator: "_"))" : "Use \(tool)"
            }
            return "Use \(tool)"
        }
    }

    /// The one line that says what exactly: the command, the files, the page.
    public var subject: String {
        if let command { return command.split(separator: "\n").first.map(String.init) ?? command }
        if !paths.isEmpty { return paths.map { Paths.tilde($0) }.joined(separator: ", ") }
        return url ?? tool
    }

    /// What two asks must share to be the same request: answered together, shown once with ×N.
    public var key: String {
        [channel.rawValue, tool, command ?? "", paths.joined(separator: "\n"), url ?? "", patch ?? ""]
            .joined(separator: "\u{1F}")
    }

    /// The `PostToolUse` call this ask turns into once it ran (`ToolCall.label`): when that arrives, it was answered.
    public var callLabel: String? {
        var args: [String: Any] = [:]
        if let command { args["command"] = command }
        if let path = paths.first { args["file_path"] = path }
        if let url { args["url"] = url }
        return ToolCall.from(hook: ["tool_name": tool, "tool_input": args])?.label
    }

    static func cap(_ text: String) -> String {
        text.count > commandLimit ? String(text.prefix(commandLimit - 1)) + "…" : text
    }

    static func capLines(_ text: String) -> String? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard !text.isEmpty else { return nil }
        guard lines.count > patchLines else { return text }
        return lines.prefix(patchLines).joined(separator: "\n") + "\n… \(lines.count - patchLines) more lines"
    }

    /// The files a Codex patch touches (`*** Update File: a`, `*** Add File:`, `*** Delete File:`).
    static func patchPaths(_ patch: String) -> [String] {
        let prefixes = ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "]
        var paths: [String] = []
        for line in patch.split(separator: "\n") {
            guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { continue }
            let path = line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
            if !path.isEmpty, !paths.contains(path) { paths.append(path) }
        }
        return paths
    }

    /// An edit as `-` and `+` lines: Edit's old and new string, MultiEdit's edits, Write's content.
    static func editPatch(tool: String, args: [String: Any]) -> String? {
        func lines(_ text: String?, _ mark: String) -> [String] {
            (text ?? "").split(separator: "\n", omittingEmptySubsequences: false).map { mark + $0 }
        }
        var out: [String] = []
        switch tool {
        case "Write":
            out = lines(args["content"] as? String, "+ ")
        case "MultiEdit":
            for edit in args["edits"] as? [[String: Any]] ?? [] {
                out += lines(edit["old_string"] as? String, "- ") + lines(edit["new_string"] as? String, "+ ")
            }
        default:
            out = lines(args["old_string"] as? String, "- ") + lines(args["new_string"] as? String, "+ ")
        }
        return out.isEmpty ? nil : capLines(out.joined(separator: "\n"))
    }

    /// The allow rules among Claude's suggestions (`addRules` with `behavior: allow`); the rest (mode switches,
    /// directories) are not heed's to offer.
    static func rules(_ suggestions: Any?) -> [PermissionRule] {
        guard let entries = suggestions as? [[String: Any]] else { return [] }
        return entries.flatMap { entry -> [PermissionRule] in
            guard entry["type"] as? String == "addRules", entry["behavior"] as? String == "allow" else { return [] }
            return (entry["rules"] as? [[String: Any]] ?? []).compactMap { rule in
                guard let tool = rule["toolName"] as? String, !tool.isEmpty else { return nil }
                return PermissionRule(toolName: tool, ruleContent: rule["ruleContent"] as? String)
            }
        }
    }
}

/// An allow rule as Claude Code writes it: `Bash(npm test)` is `toolName: Bash, ruleContent: npm test`.
public struct PermissionRule: Codable, Hashable, Sendable {
    public var toolName: String
    public var ruleContent: String?

    public init(toolName: String, ruleContent: String? = nil) {
        self.toolName = toolName
        self.ruleContent = ruleContent
    }

    /// `Bash(npm test)`, or `Bash` for the whole tool.
    public var text: String { ruleContent.map { "\(toolName)(\($0))" } ?? toolName }
}

/// What you said to one ask, as it goes back to the hook that waits.
public struct PermissionAnswer: Codable, Hashable, Sendable {
    public enum Decision: String, Codable, Sendable {
        case allow, deny
        /// heed does not decide (it timed out, or answering from heed is off): the agent asks in its own pane.
        case pass
    }

    public var decision: Decision
    /// For a deny: told to the agent, so it knows why.
    public var message: String?
    /// For an allow: also save the agent's offered rules in this repo (Claude only).
    public var always: Bool

    public init(_ decision: Decision, message: String? = nil, always: Bool = false) {
        self.decision = decision
        self.message = message
        self.always = always
    }

    public static let pass = PermissionAnswer(.pass)
}
