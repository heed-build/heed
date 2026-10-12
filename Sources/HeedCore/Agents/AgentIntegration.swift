import Foundation

/// How each agent reports to Heed, and what Heed adds to its command line so it does. Hooks are always passed per
/// run (`--settings`, `-c`, `-e`, env), never written into the user's own agent config.
public enum AgentIntegration {
    /// Extra arguments for launching `agent` in `session`, placed right after the agent's command. When `resuming`,
    /// only the hook wiring: the session id comes from the resume arguments.
    public static func launchArguments(
        agent: AgentProfile, sessionID: String, files: IntegrationFiles, resuming: Bool = false
    ) -> [String] {
        switch agent.name {
        case "claude":
            // The session id is assigned up front, so resume works even if the start hook never fires.
            resuming ? ["--settings", files.claudeSettings] : [
                "--settings",
                files.claudeSettings,
                "--session-id",
                sessionID,
            ]
        default:
            []
        }
    }

    /// Whether the agent still has session `id` for `directory`: true or false when Heed can tell (claude keeps
    /// `~/.claude/projects/<cwd with / and . as ->/<id>.jsonl`), nil when it cannot (assume it does).
    public static func hasSession(
        agent: String,
        id: String,
        directory: String,
        home: String = NSHomeDirectory()
    ) -> Bool? {
        switch agent {
        case "claude":
            let folder = directory.map { $0 == "/" || $0 == "." ? "-" : $0 }
            return FileManager.default.fileExists(atPath: "\(home)/.claude/projects/\(String(folder))/\(id).jsonl")
        default:
            return nil
        }
    }

    /// The agent's own session id when Heed assigns it (claude), else nil until its start hook reports one.
    public static func preassignedSessionID(agent: AgentProfile, sessionID: String) -> String? {
        agent.name == "claude" ? sessionID : nil
    }

    // MARK: Claude Code

    /// Hook events Heed listens to, and the matcher for each.
    static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"),
        ("PermissionRequest", "*"), ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
    ]

    /// The `--settings` JSON: every event runs `heed hook claude <event>`, which reads the hook's JSON on stdin.
    /// `$HEED_BIN` is set in every Heed pane; outside one the hook is a no-op.
    public static func claudeSettingsJSON() -> String {
        var hooks: [String: Any] = [:]
        for (event, matcher) in claudeEvents {
            var entry: [String: Any] = [
                "hooks": [["type": "command", "command": "\"${HEED_BIN:-true}\" hook claude \(event)", "timeout": 5]],
            ]
            if let matcher { entry["matcher"] = matcher }
            hooks[event] = [entry]
        }
        let data = try? JSONSerialization.data(withJSONObject: ["hooks": hooks], options: [.prettyPrinted, .sortedKeys])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// Maps one Claude Code hook call to what Heed should record. `input` is the hook's stdin JSON.
    public static func claudeHook(event: String, input: [String: Any]) -> [HookMessage.Kind] {
        let tool = input["tool_name"] as? String
        switch event {
        case "SessionStart":
            var kinds: [HookMessage.Kind] = [.state(.idle, reason: input["source"] as? String)]
            if let id = input["session_id"] as? String { kinds.insert(.agentSession(id: id, agent: "claude"), at: 0) }
            return kinds
        case "UserPromptSubmit":
            return [.state(.working, reason: "prompt")]
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                let count = ((input["tool_input"] as? [String: Any])?["questions"] as? [Any])?.count
                return [.state(.asking, reason: count.map { "\($0) question\($0 == 1 ? "" : "s")" })]
            }
            return [.state(.working, reason: tool.map { describe(tool: $0, input: input) })]
        case "PostToolUse":
            return [.state(.working, reason: tool)]
        case "PermissionRequest":
            return [.state(.blocked, reason: tool.map { describe(tool: $0, input: input) })]
        case "Notification":
            switch input["notification_type"] as? String {
            case "permission_prompt": return [.state(.blocked, reason: input["message"] as? String)]
            case "idle_prompt": return [.state(.idle, reason: nil)]
            case "elicitation_dialog": return [.state(.asking, reason: input["message"] as? String)]
            default: return [.notify(input["message"] as? String ?? "")]
            }
        case "Stop":
            return [.state(.done, reason: nil)]
        case "StopFailure":
            let error = input["error"] as? String
            return [error == "rate_limit" ? .state(.limited, reason: "rate limited") : .state(.done, reason: error)]
        case "SessionEnd":
            return [.state(.exited, reason: input["reason"] as? String)]
        default:
            return []
        }
    }

    /// `Bash(dotnet publish)`, `Edit(src/a.cs)`: the tool with its most telling argument.
    static func describe(tool: String, input: [String: Any]) -> String {
        let args = input["tool_input"] as? [String: Any] ?? [:]
        let detail = (args["command"] ?? args["file_path"] ?? args["pattern"] ?? args["url"]) as? String
        guard let detail else { return tool }
        let short = detail.split(separator: "\n").first.map(String.init) ?? detail
        return "\(tool)(\(short.count > 60 ? String(short.prefix(59)) + "…" : short))"
    }
}

/// Files Heed writes once at launch and points agents at.
public struct IntegrationFiles: Hashable, Sendable {
    public var claudeSettings: String

    public init(directory: URL) {
        claudeSettings = directory.appendingPathComponent("claude-hooks.json").path
    }

    public static func `default`() -> IntegrationFiles {
        IntegrationFiles(directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed"))
    }

    /// Writes the files if their content changed. Called off the main actor at launch.
    public func write() throws {
        let url = URL(fileURLWithPath: claudeSettings)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let content = AgentIntegration.claudeSettingsJSON()
        if (try? String(contentsOf: url, encoding: .utf8)) != content {
            try content.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
