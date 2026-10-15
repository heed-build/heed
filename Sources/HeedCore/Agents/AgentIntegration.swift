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
        "SubagentStart",
        "SubagentStop",
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
        if let subagent = subagentHook(event: event, input: input) { return subagent }
        return inSubagent(codexTurnHook(event: event, input: input), input: input)
    }

    private static func codexTurnHook(event: String, input: [String: Any]) -> [HookMessage.Kind] {
        let tool = input["tool_name"] as? String
        switch event {
        case "SessionStart":
            var kinds: [HookMessage.Kind] = modelOnly(input) + [.state(.idle, reason: input["source"] as? String)]
            if let id = input["session_id"] as? String { kinds.insert(.agentSession(id: id, agent: "codex"), at: 0) }
            return kinds
        case "UserPromptSubmit": return modelOnly(input) + [.state(.working, reason: "prompt")]
        case "PreToolUse": return [.state(.working, reason: tool.map { describe(tool: $0, input: input) })]
        case "PostToolUse":
            return [.state(.working, reason: tool.map { describe(tool: $0, input: input) })] + created(input)
        case "PermissionRequest": return [.state(.blocked, reason: tool.map { describe(tool: $0, input: input) })]
        case "Stop": return codexUsage(input) + [TurnEnd.kind(lastWords: input["last_assistant_message"] as? String)]
        case "SessionEnd": return codexUsage(input) + [.state(.exited, reason: input["reason"] as? String)]
        default: return []
        }
    }

    /// The model every Codex hook carries, with the totals, context and rate limits of its rollout's tail.
    static func codexUsage(_ input: [String: Any]) -> [HookMessage.Kind] {
        var report = (input["transcript_path"] as? String).flatMap { UsageTranscripts.tail(path: $0) }
            .flatMap { UsageTranscripts.codex($0) } ?? UsageReport()
        if let model = input["model"] as? String, !model.isEmpty { report.model = model }
        return report.isEmpty ? [] : [.usage(report)]
    }

    /// The hook's `model` (codex, cursor), when it has one.
    static func modelOnly(_ input: [String: Any]) -> [HookMessage.Kind] {
        guard let model = input["model"] as? String, !model.isEmpty else { return [] }
        return [.usage(UsageReport(model: model))]
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
        for event in [
            "sessionStart", "beforeShellExecution", "afterShellExecution", "afterMCPExecution", "afterFileEdit",
            "postToolUse", "afterAgentResponse", "stop",
        ] {
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
            return (id.map { [.agentSession(id: $0, agent: "cursor")] } ?? []) + modelOnly(input)
                + [.state(.idle, reason: nil)]
        case "beforeShellExecution", "afterFileEdit":
            return [.state(.working, reason: (input["command"] as? String) ?? (input["file_path"] as? String))]
        case "afterShellExecution":
            return PullCreation.urls(
                tool: "shell", command: input["command"] as? String, output: PullCreation.text(input["output"])
            ).map { .prAdd(url: $0) }
        case "afterMCPExecution":
            return PullCreation.urls(
                tool: input["tool_name"] as? String, command: nil, output: PullCreation.text(input["result_json"])
            ).map { .prAdd(url: $0) }
        case "postToolUse":
            let tool = input["tool_name"] as? String
            return [.state(.working, reason: tool)] + PullCreation.urls(
                tool: tool, command: PullCreation.command(input["tool_input"]),
                output: PullCreation.text(input["tool_output"])
            ).map { .prAdd(url: $0) }
        // The agent's reply, before `stop`: a reply that asks you leaves the session asking (`stop` keeps it).
        case "afterAgentResponse":
            guard let text = input["text"] as? String, TurnEnd.asksYou(text) else { return [] }
            return [.guess(.asking, reason: TurnEnd.question)]
        case "stop":
            switch input["status"] as? String {
            case "aborted": return modelOnly(input) + [.state(.idle, reason: "aborted")]
            case "error": return modelOnly(input) + [.state(.done, reason: "error")]
            default: return modelOnly(input) + [.state(.done, reason: nil)]
            }
        default: return []
        }
    }

    // MARK: pi and opencode (they call `heed hook <agent> <event> <session id> [detail] [last text]`)

    /// `text` is the turn's last assistant text, sent with the turn's end.
    static func piHook(event: String, sessionID: String?, detail: String?, text: String? = nil) -> [HookMessage.Kind] {
        switch event {
        case "start":
            (sessionID.flatMap { $0.isEmpty ? nil : [.agentSession(id: $0, agent: "pi")] } ?? [])
                + [.state(.idle, reason: detail)]
        case "busy": [.state(.working, reason: "prompt")]
        case "tool": [.state(.working, reason: detail)]
        // The extension sends a PR it saw the agent create; the URL is checked here.
        case "pr": PullRef(url: detail ?? "") == nil ? [] : [.prAdd(url: detail!)]
        case "waiting": [.state(.asking, reason: detail)]
        case "idle": [TurnEnd.kind(lastWords: text)]
        case "aborted": [.state(.idle, reason: "aborted")]
        case "error": [.state(.done, reason: "error")]
        case "exit": [.state(.exited, reason: nil)]
        default: []
        }
    }

    static func opencodeHook(
        event: String, sessionID: String?, detail: String?, text: String? = nil
    ) -> [HookMessage.Kind] {
        switch event {
        case "session.created":
            sessionID.flatMap { $0.isEmpty ? nil : [.agentSession(id: $0, agent: "opencode")] } ?? []
        case "session.status":
            switch detail {
            case "busy": [.state(.working, reason: nil)]
            case "idle": [TurnEnd.kind(lastWords: text)]
            case "retry": [.state(.limited, reason: "retrying")]
            default: []
            }
        case "permission.asked": [.state(.blocked, reason: detail)]
        case "pr": PullRef(url: detail ?? "") == nil ? [] : [.prAdd(url: detail!)]
        case "question.asked": [.state(.asking, reason: nil)]
        case "session.error": [.state(.done, reason: "error")]
        case "usage": opencodeUsage(detail)
        default: []
        }
    }

    /// One finished assistant message, as the plugin sends it: `{"id", "model", "cost", "input", "output",
    /// "reasoning", "cacheRead", "cacheWrite"}`.
    static func opencodeUsage(_ detail: String?) -> [HookMessage.Kind] {
        guard let data = detail?.data(using: .utf8),
              let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = message["id"] as? String
        else { return [] }
        let int = UsageTranscripts.int
        let tokens = TokenCounts(
            input: int(message["input"]), output: int(message["output"]) + int(message["reasoning"]),
            cacheRead: int(message["cacheRead"]), cacheWrite: int(message["cacheWrite"])
        )
        let model = (message["model"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let cost = (message["cost"] as? NSNumber)?.doubleValue
        return [.usage(UsageReport(model: model, requests: [RequestUsage(id: id, tokens: tokens, costUSD: cost)]))]
    }

    public static let piExtensionSource = #"""
    // Heed: reports pi's state to the Heed app. Loaded per run with `pi -e`; does nothing outside a Heed pane.
    export default function (pi) {
      const bin = process.env.HEED_BIN;
      const send = (state, ctx, detail, text) => {
        if (!bin) return;
        let sid = "";
        try { sid = ctx.sessionManager.getSessionId() ?? ""; } catch {}
        const args = ["hook", "pi", state, sid, String(detail ?? "")];
        if (text) args.push(text);
        Promise.resolve(pi.exec(bin, args)).catch(() => {});
      };
      // The turn's last assistant text goes with its end, so Heed can tell a question to you from a finished turn.
      let last = "";
      pi.on("session_start", (e, ctx) => send("start", ctx, e?.reason));
      pi.on("agent_start", (_e, ctx) => { last = ""; send("busy", ctx); });
      pi.on("message_end", (e) => {
        const m = e?.message;
        if (m?.role !== "assistant" || !Array.isArray(m.content)) return;
        const text = m.content.filter((c) => c?.type === "text").map((c) => c.text ?? "").join("\n").trim();
        if (text) last = text.slice(-600);
      });
      pi.on("tool_execution_start", (e, ctx) => send("tool", ctx, e?.toolName));
      // A PR the agent opened (gh pr create, a create_pull_request tool) belongs to this session.
      pi.on("tool_result", (e, ctx) => {
        let text = "";
        try { text = JSON.stringify(e ?? {}); } catch { return; }
        if (!/gh\s+pr\s+create|create_pull_request|hub\s+pull-request/.test(text)) return;
        for (const url of new Set(text.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/g) ?? [])) send("pr", ctx, url);
      });
      pi.on("ui_prompt_start", (e, ctx) => send("waiting", ctx, e?.kind));
      pi.on("agent_before_settle", (e, ctx) => { if (e?.outcome === "error") send("error", ctx); });
      pi.on("agent_settled", (e, ctx) => send(e?.aborted ? "aborted" : "idle", ctx, "", e?.aborted ? "" : last));
      pi.on("session_shutdown", (_e, ctx) => send("exit", ctx));
    }
    """#

    public static let opencodePluginSource = #"""
    // Heed: reports opencode's state to the Heed app (plugin API of opencode 1.x). Loaded per run through
    // OPENCODE_CONFIG_CONTENT; does nothing outside a Heed pane.
    export const HeedPlugin = async ({ $ }) => {
      const args = new Map();
      const roles = new Map();
      const last = new Map();
      const reported = new Set(["session.created", "session.status", "permission.asked", "question.asked", "session.error"]);
      const sent = new Set();
      return {
      // A PR the agent opened (gh pr create, a create_pull_request tool) belongs to this session.
      "tool.execute.before": async (input, output) => { args.set(input.callID, output?.args); },
      "tool.execute.after": async (input, output) => {
        const bin = process.env.HEED_BIN;
        const ran = args.get(input.callID);
        args.delete(input.callID);
        if (!bin) return;
        let text = "";
        try { text = JSON.stringify({ tool: input.tool, args: ran, output: output?.output }); } catch { return; }
        if (!/gh\s+pr\s+create|create_pull_request|hub\s+pull-request/.test(text)) return;
        for (const url of new Set(text.match(/https:\/\/github\.com\/[\w.-]+\/[\w.-]+\/pull\/\d+/g) ?? [])) {
          await $`${bin} hook opencode pr ${input.sessionID ?? ""} ${url}`.quiet().nothrow();
        }
      },
      event: async ({ event }) => {
        const bin = process.env.HEED_BIN;
        if (!bin) return;
        const p = event.properties ?? {};
        // The last assistant text per session goes with its idle, so Heed can tell a question to you from a finished
        // turn. Parts of user messages are skipped by their message's role.
        if (event.type === "message.updated" && p.info?.id) {
          const m = p.info;
          roles.set(m.id, m.role);
          // A finished assistant message: its model, tokens and cost, once.
          if (m.role === "assistant" && m.time?.completed && !sent.has(m.id)) {
            sent.add(m.id);
            const t = m.tokens ?? {};
            const usage = JSON.stringify({ id: m.id, model: m.modelID ?? "", cost: m.cost ?? 0, input: t.input ?? 0,
              output: t.output ?? 0, reasoning: t.reasoning ?? 0, cacheRead: t.cache?.read ?? 0, cacheWrite: t.cache?.write ?? 0 });
            await $`${bin} hook opencode usage ${m.sessionID ?? ""} ${usage}`.quiet().nothrow();
          }
          return;
        }
        if (event.type === "message.part.updated") {
          const part = p.part ?? {};
          if (part.type === "text" && !part.synthetic && roles.get(part.messageID) === "assistant" && part.text) {
            last.set(part.sessionID, part.text.trim().slice(-600));
          }
          return;
        }
        if (!reported.has(event.type)) return;
        const detail = event.type === "session.status" ? (p.status?.type ?? "") : (p.permission ?? "");
        const sid = p.sessionID ?? p.info?.id ?? "";
        if (event.type === "session.status" && detail === "idle") {
          const text = last.get(sid) ?? "";
          last.delete(sid);
          await $`${bin} hook opencode ${event.type} ${sid} ${detail} ${text}`.quiet().nothrow();
          return;
        }
        await $`${bin} hook opencode ${event.type} ${sid} ${detail}`.quiet().nothrow();
      },
      };
    };
    """#

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
            FileManager.default.fileExists(
                atPath: "\(home)/.claude/projects/\(claudeProjectFolder(directory))/\(id).jsonl"
            )
        default:
            nil
        }
    }

    // MARK: Claude Code

    /// The folder Claude Code keeps a directory's sessions in: every character that is not an ASCII letter or digit
    /// becomes `-` (`/Users/me/wt/docs_x` → `-Users-me-wt-docs-x`).
    public static func claudeProjectFolder(_ directory: String) -> String {
        String(directory.map { $0.isASCII && ($0.isLetter || $0.isNumber) ? $0 : "-" })
    }

    /// Hook events Heed listens to, and the matcher for each.
    static let claudeEvents: [(event: String, matcher: String?)] = [
        ("SessionStart", nil), ("UserPromptSubmit", nil), ("PreToolUse", "*"), ("PostToolUse", "*"),
        ("PermissionRequest", "*"), ("Notification", nil), ("Stop", nil), ("StopFailure", nil), ("SessionEnd", nil),
        ("SubagentStart", nil), ("SubagentStop", nil),
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
        if let subagent = subagentHook(event: event, input: input) { return subagent }
        return inSubagent(claudeTurnHook(event: event, input: input), input: input)
    }

    private static func claudeTurnHook(event: String, input: [String: Any]) -> [HookMessage.Kind] {
        let tool = input["tool_name"] as? String
        switch event {
        case "SessionStart":
            var kinds: [HookMessage.Kind] = modelOnly(input) + [.state(.idle, reason: input["source"] as? String)]
            if let id = input["session_id"] as? String { kinds.insert(.agentSession(id: id, agent: "claude"), at: 0) }
            return kinds
        case "UserPromptSubmit":
            return [.state(.working, reason: "prompt")]
        case "PreToolUse":
            if tool == "AskUserQuestion" {
                let count = ((input["tool_input"] as? [String: Any])?["questions"] as? [Any])?.count
                return [.state(.asking, reason: count.map { "\($0) question\($0 == 1 ? "" : "s")" })]
            }
            // Plan mode's plan, waiting for you to approve it (or not); the next prompt or tool call moves on.
            if tool == "ExitPlanMode" { return [.state(.asking, reason: "plan to approve")] }
            return [.state(.working, reason: tool.map { describe(tool: $0, input: input) })]
        case "PostToolUse":
            return [.state(.working, reason: tool)] + created(input)
        case "PermissionRequest":
            return [.state(.blocked, reason: tool.map { describe(tool: $0, input: input) })]
        case "Notification":
            switch input["notification_type"] as? String {
            case "permission_prompt": return [.state(.blocked, reason: input["message"] as? String)]
            case "idle_prompt": return [.atPrompt]
            case "elicitation_dialog": return [.state(.asking, reason: input["message"] as? String)]
            default: return [.notify(input["message"] as? String ?? "")]
            }
        case "Stop":
            // A turn that left background work running, or a scheduled prompt, is not finished with: background tasks
            // keep it working (their results start the next turn), a schedule leaves it idle until it fires. A
            // question in the turn's last words outranks both.
            let usage = claudeUsage(input)
            let lastWords = input["last_assistant_message"] as? String
            if let lastWords, TurnEnd.asksYou(lastWords) { return usage + [TurnEnd.kind(lastWords: lastWords)] }
            if let tasks = input["background_tasks"] as? [Any], !tasks.isEmpty {
                return usage + [.state(
                    .working,
                    reason: "\(tasks.count) background task\(tasks.count == 1 ? "" : "s")"
                )]
            }
            // Nothing in the background (when Claude says so): no subagent the session lost track of still runs.
            let ended: [HookMessage.Kind] = (input["background_tasks"] as? [Any])?.isEmpty == true
                ? [.subagentsEnded] : []
            if let crons = input["session_crons"] as? [Any], !crons.isEmpty {
                return usage + ended + [.state(.idle, reason: "\(crons.count) scheduled")]
            }
            return usage + ended + [.state(.done, reason: nil)]
        case "StopFailure":
            // Usage first: a rate limit's reset time is known by the time the limited state arrives.
            let error = input["error"] as? String
            return claudeUsage(input)
                + [error == "rate_limit" ? .state(.limited, reason: "rate limited") : .state(.done, reason: error)]
        case "SessionEnd":
            return claudeUsage(input) + [.state(.exited, reason: input["reason"] as? String)]
        default:
            return []
        }
    }

    /// What the tail of the session's transcript says about its requests and model. Read at the end of a turn; the
    /// turn's last lines may still be on their way, and are counted at the next one.
    static func claudeUsage(_ input: [String: Any]) -> [HookMessage.Kind] {
        guard let path = input["transcript_path"] as? String, let data = UsageTranscripts.tail(path: path),
              let report = UsageTranscripts.claude(data)
        else { return [] }
        return [.usage(report)]
    }

    // MARK: Subagents (Claude Code and Codex)

    /// `SubagentStart` and `SubagentStop`, the same for both agents; nil for any other event. A subagent's last
    /// message (`last_assistant_message` on its stop) is its answer to its parent, so it is never read as the turn's.
    static func subagentHook(event: String, input: [String: Any]) -> [HookMessage.Kind]? {
        guard event == "SubagentStart" || event == "SubagentStop" else { return nil }
        guard let id = input["agent_id"] as? String, !id.isEmpty else { return [] }
        return [.subagent(id: id, type: input["agent_type"] as? String, started: event == "SubagentStart")]
    }

    /// What a hook that fired inside a subagent (its input carries `agent_id`) reports: its states as the subagent's,
    /// not the session's; a guess about its turn's end, or its prompt, is nobody's news. A main-thread hook (no
    /// `agent_id`; `agent_type` alone is the session's `--agent`) is left as it is.
    static func inSubagent(_ kinds: [HookMessage.Kind], input: [String: Any]) -> [HookMessage.Kind] {
        guard let id = input["agent_id"] as? String, !id.isEmpty else { return kinds }
        let type = input["agent_type"] as? String
        return kinds.compactMap { kind in
            switch kind {
            case let .state(state, reason): .subagentState(state, reason: reason, id: id, type: type)
            case .guess, .atPrompt, .subagentsEnded, .agentSession: nil
            default: kind
            }
        }
    }

    /// The PRs a Claude Code or Codex tool call created (`PostToolUse`: `tool_input`, `tool_response`).
    static func created(_ input: [String: Any]) -> [HookMessage.Kind] {
        PullCreation.urls(
            tool: input["tool_name"] as? String, command: PullCreation.command(input["tool_input"]),
            output: PullCreation.text(input["tool_response"])
        ).map { .prAdd(url: $0) }
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
