import Foundation

/// How each agent reports to Heed, and what Heed adds to its command line so it does. Hooks are always passed per
/// run (`--settings`, `-c`, `-e`, env), never written into the user's own agent config.
public enum AgentIntegration {
    /// Extra arguments for launching `agent` in `session`, placed right after the agent's command: its hook wiring,
    /// and the session id when Heed assigns it. When `resuming`, only the hook wiring.
    public static func launchArguments(
        agent: AgentProfile, sessionID: String, files: IntegrationFiles, resuming: Bool = false
    ) -> [String] {
        var args: [String] = switch agent.name {
        case "claude": ["--settings", files.claudeSettings]
        case "codex": codexArguments(heed: files.heedBinary)
        case "pi": ["-e", files.piExtension]
        default: []
        }
        if !resuming, let flag = agent.sessionIDFlag { args += [flag, sessionID] }
        return args
    }

    /// Environment set on the agent's command line itself (opencode's plugin travels in its config env var).
    public static func launchEnvironment(agent: AgentProfile, files: IntegrationFiles) -> [String: String] {
        switch agent.name {
        case "opencode": ["OPENCODE_CONFIG_CONTENT": #"{"plugin":["file://\#(files.opencodePlugin)"]}"#]
        default: [:]
        }
    }

    /// The agent's own session id when Heed assigns it at launch, else nil until its start hook reports one.
    public static func preassignedSessionID(agent: AgentProfile, sessionID: String) -> String? {
        agent.sessionIDFlag == nil ? nil : sessionID
    }

    // MARK: Codex

    static let codexEvents = [
        "SessionStart",
        "UserPromptSubmit",
        "PreToolUse",
        "PermissionRequest",
        "PostToolUse",
        "Stop",
        "SessionEnd",
    ]

    /// Hooks for one run, as `-c` config layers (the user's own hooks still run alongside). Non-managed hooks need
    /// trust; the bypass flag trusts exactly these, for this run.
    static func codexArguments(heed: String) -> [String] {
        ["--dangerously-bypass-hook-trust"] + codexEvents.flatMap { event in
            let command = TOMLValue.quote("\(ShellQuote.quote(heed)) hook codex \(event)")
            return ["-c", "hooks.\(event)=[{hooks=[{type=\"command\",command=\(command),timeout=15}]}]"]
        }
    }

    static func codexHook(event: String, input: [String: Any]) -> [HookMessage.Kind] {
        let tool = input["tool_name"] as? String
        switch event {
        case "SessionStart":
            var kinds: [HookMessage.Kind] = [.state(.idle, reason: input["source"] as? String)]
            if let id = input["session_id"] as? String { kinds.insert(.agentSession(id: id, agent: "codex"), at: 0) }
            return kinds
        case "UserPromptSubmit": return [.state(.working, reason: "prompt")]
        case "PreToolUse", "PostToolUse": return [.state(
                .working,
                reason: tool.map { describe(tool: $0, input: input) }
            )]
        case "PermissionRequest": return [.state(.blocked, reason: tool.map { describe(tool: $0, input: input) })]
        case "Stop": return [.state(.done, reason: nil)]
        case "SessionEnd": return [.state(.exited, reason: input["reason"] as? String)]
        default: return []
        }
    }

    // MARK: Cursor

    /// Cursor reads hooks only from files, so Heed writes `.cursor/hooks.json` into the worktree it created and keeps
    /// it out of git (`.git/info/exclude`). A repo that tracks its own hooks file is left alone.
    public static func installCursorHooks(worktree: String, heed: String) throws {
        let folder = URL(fileURLWithPath: worktree).appendingPathComponent(".cursor")
        let file = folder.appendingPathComponent("hooks.json")
        if FileManager.default.fileExists(atPath: file.path),
           (try? String(contentsOf: file, encoding: .utf8))?.contains("hook cursor") != true
        {
            return
        }
        var hooks: [String: Any] = [:]
        for event in ["sessionStart", "beforeShellExecution", "afterFileEdit", "postToolUse", "stop"] {
            hooks[event] = [["command": "\(ShellQuote.quote(heed)) hook cursor \(event)", "timeout": 15]]
        }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["version": 1, "hooks": hooks], options: [
                .prettyPrinted,
                .sortedKeys,
                .withoutEscapingSlashes,
            ]
        )
        try data.write(to: file)
        try excludeFromGit(".cursor/hooks.json", worktree: worktree)
    }

    /// Adds a line to the worktree's `info/exclude` (shared by all worktrees of the repo), once.
    static func excludeFromGit(_ pattern: String, worktree: String) throws {
        let gitPath = URL(fileURLWithPath: worktree).appendingPathComponent(".git")
        var gitDir = gitPath
        if let pointer = try? String(contentsOf: gitPath, encoding: .utf8), pointer.hasPrefix("gitdir:") {
            // A worktree's .git file points at <repo>/.git/worktrees/<name>; info/exclude lives in the common dir.
            let dir = pointer.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: dir).deletingLastPathComponent().deletingLastPathComponent()
        }
        let exclude = gitDir.appendingPathComponent("info/exclude")
        let current = (try? String(contentsOf: exclude, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(Substring(pattern)) else { return }
        try FileManager.default.createDirectory(
            at: exclude.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try (current + (current.isEmpty || current.hasSuffix("\n") ? "" : "\n") + pattern + "\n")
            .write(to: exclude, atomically: true, encoding: .utf8)
    }

    static func cursorHook(event: String, input: [String: Any]) -> [HookMessage.Kind] {
        switch event {
        case "sessionStart":
            let id = (input["session_id"] as? String) ?? (input["conversation_id"] as? String)
            return (id.map { [.agentSession(id: $0, agent: "cursor")] } ?? []) + [.state(.idle, reason: nil)]
        case "beforeShellExecution", "afterFileEdit", "postToolUse":
            return [.state(.working, reason: (input["command"] as? String) ?? (input["file_path"] as? String))]
        case "stop":
            switch input["status"] as? String {
            case "aborted": return [.state(.idle, reason: "aborted")]
            case "error": return [.state(.done, reason: "error")]
            default: return [.state(.done, reason: nil)]
            }
        default: return []
        }
    }

    // MARK: pi and opencode (their extension and plugin call `heed hook <agent> <event> <session id> [detail]`)

    static func piHook(event: String, sessionID: String?, detail: String?) -> [HookMessage.Kind] {
        switch event {
        case "start":
            (sessionID.flatMap { $0.isEmpty ? nil : [.agentSession(id: $0, agent: "pi")] } ?? [])
                + [.state(.idle, reason: detail)]
        case "busy": [.state(.working, reason: "prompt")]
        case "tool": [.state(.working, reason: detail)]
        case "waiting": [.state(.asking, reason: detail)]
        case "idle": [.state(.done, reason: nil)]
        case "aborted": [.state(.idle, reason: "aborted")]
        case "error": [.state(.done, reason: "error")]
        case "exit": [.state(.exited, reason: nil)]
        default: []
        }
    }

    static func opencodeHook(event: String, sessionID: String?, detail: String?) -> [HookMessage.Kind] {
        switch event {
        case "session.created":
            sessionID.flatMap { $0.isEmpty ? nil : [.agentSession(id: $0, agent: "opencode")] } ?? []
        case "session.status":
            switch detail {
            case "busy": [.state(.working, reason: nil)]
            case "idle": [.state(.done, reason: nil)]
            case "retry": [.state(.limited, reason: "retrying")]
            default: []
            }
        case "permission.asked": [.state(.blocked, reason: detail)]
        case "question.asked": [.state(.asking, reason: nil)]
        case "session.error": [.state(.done, reason: "error")]
        default: []
        }
    }

    static let piExtensionSource = """
    // Heed: reports pi's state to the Heed app. Loaded per run with `pi -e`; does nothing outside a Heed pane.
    export default function (pi) {
      const bin = process.env.HEED_BIN;
      const send = (state, ctx, detail) => {
        if (!bin) return;
        let sid = "";
        try { sid = ctx.sessionManager.getSessionId() ?? ""; } catch {}
        Promise.resolve(pi.exec(bin, ["hook", "pi", state, sid, String(detail ?? "")])).catch(() => {});
      };
      pi.on("session_start", (e, ctx) => send("start", ctx, e?.reason));
      pi.on("agent_start", (_e, ctx) => send("busy", ctx));
      pi.on("tool_execution_start", (e, ctx) => send("tool", ctx, e?.toolName));
      pi.on("ui_prompt_start", (e, ctx) => send("waiting", ctx, e?.kind));
      pi.on("agent_before_settle", (e, ctx) => { if (e?.outcome === "error") send("error", ctx); });
      pi.on("agent_settled", (e, ctx) => send(e?.aborted ? "aborted" : "idle", ctx));
      pi.on("session_shutdown", (_e, ctx) => send("exit", ctx));
    }
    """

    static let opencodePluginSource = """
    // Heed: reports opencode's state to the Heed app (plugin API of opencode 1.x). Loaded per run through
    // OPENCODE_CONFIG_CONTENT; does nothing outside a Heed pane.
    export const HeedPlugin = async ({ $ }) => ({
      event: async ({ event }) => {
        const bin = process.env.HEED_BIN;
        if (!bin) return;
        const p = event.properties ?? {};
        const detail = event.type === "session.status" ? (p.status?.type ?? "") : (p.permission ?? "");
        const sid = p.sessionID ?? p.info?.id ?? "";
        await $`${bin} hook opencode ${event.type} ${sid} ${detail}`.quiet().nothrow();
      },
    });
    """

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
                "hooks": [["type": "command", "command": "\"${HEED_BIN:-true}\" hook claude \(event)", "timeout": 15]],
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
    public var piExtension: String
    public var opencodePlugin: String
    /// The bundled `heed`, for hooks that run without Heed's PATH (codex, cursor).
    public var heedBinary: String

    public init(directory: URL, heedBinary: String = "heed") {
        claudeSettings = directory.appendingPathComponent("claude-hooks.json").path
        piExtension = directory.appendingPathComponent("heed-pi.js").path
        opencodePlugin = directory.appendingPathComponent("heed-opencode.js").path
        self.heedBinary = heedBinary
    }

    public static func `default`(heedBinary: String = "heed") -> IntegrationFiles {
        IntegrationFiles(
            directory: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Heed"),
            heedBinary: heedBinary
        )
    }

    /// Writes the files if their content changed. Called off the main actor at launch.
    public func write() throws {
        let files = [
            (claudeSettings, AgentIntegration.claudeSettingsJSON()),
            (piExtension, AgentIntegration.piExtensionSource),
            (opencodePlugin, AgentIntegration.opencodePluginSource),
        ]
        for (path, content) in files {
            let url = URL(fileURLWithPath: path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if (try? String(contentsOf: url, encoding: .utf8)) != content {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}
