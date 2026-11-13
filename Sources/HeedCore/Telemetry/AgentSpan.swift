import Foundation

/// What a span is, as heed draws it: a turn (your prompt and everything it set off), a model request, a tool call, a
/// wait for your OK, a hook, or something else the agent traced.
public enum SpanKind: String, Hashable, Sendable, Codable, CaseIterable {
    case turn, model, tool, permission, hook, other

    /// The filter's word for it, and the kind column's.
    public var label: String {
        switch self {
        case .turn: "turn"
        case .model: "model"
        case .tool: "tool"
        case .permission: "permission"
        case .hook: "hook"
        case .other: "other"
        }
    }

    /// What the kind filter shows by default: what a person reads a session by.
    public static let shown: [SpanKind] = [.turn, .tool, .permission, .model]
}

public enum SpanStatus: String, Hashable, Sendable, Codable {
    case ok, error
    /// Still open: a wait for your OK that has not been answered (a span that has not ended).
    case waiting
}

/// One span of an agent's work, from its own OpenTelemetry: a trace span as it sent it, or one heed made from an
/// event that carries a duration (`claude_code.tool_result`, `codex.tool_result`) when the agent sent no traces.
public struct AgentSpan: Hashable, Sendable, Identifiable, Codable {
    /// The span id, or `event:<key>` for one made from an event.
    public var id: String
    /// The trace it is in; for one made from an event, the prompt it answered (`prompt.id`) when the event says.
    public var traceID: String?
    public var parentID: String?
    /// `claude`, `codex`, `opencode`: from the resource's `service.name`.
    public var agent: String
    /// The agent's own session id (`session.id`, `conversation.id`), as heed knows it from the agent's hooks.
    public var agentSession: String?
    /// The heed session, when the resource names it (`heed.session`), else nil until the view maps `agentSession`.
    public var heedSession: String?
    public var kind: SpanKind
    /// `bash`, `edit`, `read/grep`, `mcp heed`, `model`, `permission`: the tool group a latency is counted under.
    public var name: String
    /// The command, the file, the prompt or the model: what this one was.
    public var detail: String
    public var model: String?
    public var start: Date
    public var end: Date
    public var status: SpanStatus
    public var error: String?
    public var tokens: TokenCounts?
    /// What the agent reported the request cost, in USD.
    public var cost: Double?
    /// The request or tool call it is about (`request_id`, `tool_use_id`, `call_id`): a span and an event about the
    /// same one are the same, and count once.
    public var key: String?
    /// Made from an event, not sent as a span.
    public var fromEvent: Bool

    public init(
        id: String, traceID: String? = nil, parentID: String? = nil, agent: String, agentSession: String? = nil,
        heedSession: String? = nil, kind: SpanKind, name: String, detail: String = "", model: String? = nil,
        start: Date, end: Date, status: SpanStatus = .ok, error: String? = nil, tokens: TokenCounts? = nil,
        cost: Double? = nil, key: String? = nil, fromEvent: Bool = false
    ) {
        self.id = id
        self.traceID = traceID
        self.parentID = parentID
        self.agent = agent
        self.agentSession = agentSession
        self.heedSession = heedSession
        self.kind = kind
        self.name = name
        self.detail = detail
        self.model = model
        self.start = start
        self.end = end
        self.status = status
        self.error = error
        self.tokens = tokens
        self.cost = cost
        self.key = key
        self.fromEvent = fromEvent
    }

    public var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// A marker with no duration: you sent a prompt (`claude_code.user_prompt`, `codex.user_prompt`). Spans made from
/// events that name no prompt are counted in the turn of the prompt before them.
public struct AgentPrompt: Hashable, Sendable, Codable {
    public var agent: String
    public var agentSession: String?
    public var heedSession: String?
    public var at: Date
    /// `prompt.id`, when the agent sends one.
    public var id: String?
    /// The prompt's text, only when the agent was told to include it.
    public var text: String?

    public init(
        agent: String, agentSession: String? = nil, heedSession: String? = nil, at: Date, id: String? = nil,
        text: String? = nil
    ) {
        self.agent = agent
        self.agentSession = agentSession
        self.heedSession = heedSession
        self.at = at
        self.id = id
        self.text = text
    }
}

/// Tokens and cost a metric reported (`claude_code.token.usage`, `claude_code.cost.usage`, codex's turn usage), for
/// agents whose requests heed has no events for.
public struct AgentUsageSample: Hashable, Sendable, Codable {
    public var agent: String
    public var agentSession: String?
    public var heedSession: String?
    public var at: Date
    public var model: String?
    public var tokens: TokenCounts
    public var cost: Double?
    /// A running total since the agent started (a cumulative sum), not what was used since the last export.
    public var cumulative = false

    public init(
        agent: String, agentSession: String? = nil, heedSession: String? = nil, at: Date, model: String? = nil,
        tokens: TokenCounts = TokenCounts(), cost: Double? = nil, cumulative: Bool = false
    ) {
        self.agent = agent
        self.agentSession = agentSession
        self.heedSession = heedSession
        self.at = at
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.cumulative = cumulative
    }

    /// Samples that add up: deltas as they are, and of each cumulative series (session, model, what it counts) only
    /// its latest total.
    public static func summable(_ samples: [AgentUsageSample]) -> [AgentUsageSample] {
        var latest: [String: AgentUsageSample] = [:]
        var out: [AgentUsageSample] = []
        for sample in samples {
            guard sample.cumulative else {
                out.append(sample)
                continue
            }
            let what = sample.cost != nil ? "cost" : "\(sample.tokens.input > 0)\(sample.tokens.output > 0)"
                + "\(sample.tokens.cacheRead > 0)\(sample.tokens.cacheWrite > 0)"
            let key = "\(sample.agentSession ?? sample.agent)|\(sample.model ?? "")|\(what)"
            if latest[key].map({ $0.at <= sample.at }) ?? true { latest[key] = sample }
        }
        return out + latest.values.sorted { $0.at < $1.at }
    }
}

/// What one export became, in heed's terms.
public struct TelemetryRecords: Hashable, Sendable {
    public var spans: [AgentSpan] = []
    public var prompts: [AgentPrompt] = []
    public var usage: [AgentUsageSample] = []

    public init(spans: [AgentSpan] = [], prompts: [AgentPrompt] = [], usage: [AgentUsageSample] = []) {
        self.spans = spans
        self.prompts = prompts
        self.usage = usage
    }

    public var isEmpty: Bool { spans.isEmpty && prompts.isEmpty && usage.isEmpty }
    public var count: Int { spans.count + prompts.count + usage.count }

    public static func + (lhs: TelemetryRecords, rhs: TelemetryRecords) -> TelemetryRecords {
        TelemetryRecords(spans: lhs.spans + rhs.spans, prompts: lhs.prompts + rhs.prompts, usage: lhs.usage + rhs.usage)
    }
}

/// OTLP as the agents send it, read into heed's values. Claude Code and Codex are read by name; another agent's spans
/// are kept as `other`, its events with a tool name and a duration as tool calls.
public enum TelemetryReader {
    /// The resource attribute heed sets to tie an export to its session, when it can.
    public static let sessionAttribute = "heed.session"

    public static func records(_ batch: OTLPBatch) -> TelemetryRecords {
        var out = TelemetryRecords()
        out.spans = batch.spans.compactMap(span)
        for log in batch.logs {
            if let prompt = prompt(log) {
                out.prompts.append(prompt)
            } else if let span = span(log) {
                out.spans.append(span)
            }
        }
        out.usage = usage(batch.points)
        return out
    }

    // MARK: Who

    /// `claude`, `codex`, `opencode`, or the service's own name.
    public static func agent(_ resource: [String: String]) -> String {
        let service = (resource["service.name"] ?? "").lowercased()
        if service.contains("claude") { return "claude" }
        if service.contains("codex") { return "codex" }
        if service.contains("opencode") { return "opencode" }
        if service.contains("gemini") { return "gemini" }
        return service.isEmpty ? "agent" : service
    }

    static func agentSession(_ attributes: [String: String], _ resource: [String: String]) -> String? {
        for key in ["session.id", "conversation.id", "thread.id", "session_id", "conversation_id"] {
            if let value = attributes[key] ?? resource[key], !value.isEmpty { return value }
        }
        return nil
    }

    // MARK: Spans

    static func span(_ span: OTLPSpan) -> AgentSpan? {
        let attributes = span.attributes
        let agent = agent(span.resource)
        var out = AgentSpan(
            id: span.spanID, traceID: span.traceID, parentID: span.parentID, agent: agent,
            agentSession: agentSession(attributes, span.resource), heedSession: span.resource[sessionAttribute],
            kind: .other, name: span.name, start: span.start, end: span.end,
            status: span.failed || attributes["success"] == "false" ? .error : .ok,
            error: span.statusMessage ?? attributes["error"]
        )
        let name = span.name.lowercased()
        switch name {
        case "claude_code.interaction":
            out.kind = .turn
            out.name = "turn"
            out.detail = readable(attributes["user_prompt"])
                ?? attributes["interaction.sequence"].map { "turn \($0)" } ?? "turn"
        case "claude_code.llm_request":
            out.kind = .model
            out.name = "model"
            out.model = attributes["model"] ?? attributes["gen_ai.request.model"]
            out.detail = out.model ?? ""
            out.tokens = tokens(attributes)
            out.key = attributes["request_id"]
            if attributes["success"] == "false" { out.status = .error }
        case "claude_code.tool", "claude_code.tool.execution":
            out.kind = .tool
            let tool = attributes["tool_name"] ?? attributes["tool_name_safe"] ?? ""
            out.name = toolGroup(tool)
            out.detail = toolDetail(tool, attributes)
            out.key = (attributes["tool_use_id"] ?? attributes["gen_ai.tool.call.id"]).map { name + ":" + $0 }
        case "claude_code.tool.blocked_on_user":
            out.kind = .permission
            out.name = "permission"
            out.detail = attributes["decision"].map { "you: \($0)" } ?? ""
            // A wait that was rejected is no failure of the agent's.
            out.status = .ok
        case "claude_code.hook":
            out.kind = .hook
            out.name = "hook"
            out.detail = attributes["hook_event"] ?? attributes["hook_name"] ?? ""
        default:
            if let tool = attributes["tool_name"] ?? attributes["tool.name"] ?? attributes["gen_ai.tool.name"] {
                out.kind = .tool
                out.name = toolGroup(tool)
                out.detail = toolDetail(tool, attributes)
                out.key = (attributes["call_id"] ?? attributes["tool_use_id"]).map { "tool:" + $0 }
            } else if let model = attributes["gen_ai.request.model"] ?? attributes["model"],
                      name.contains("request") || name.contains("llm") || name.contains("model")
            {
                out.kind = .model
                out.name = "model"
                out.model = model
                out.detail = model
                out.tokens = tokens(attributes)
            } else if name.contains("turn") || name.contains("interaction") {
                out.kind = .turn
                out.name = "turn"
                out.detail = "turn"
            } else {
                out.detail = span.name
            }
        }
        // The waits Claude Code splits a tool call into are its children; the wrapper is drawn as what ran.
        if name == "claude_code.tool.execution" { out.key = out.key.map { $0 + ":run" } }
        return out
    }

    // MARK: Events

    /// An event's name with its agent's namespace: `claude_code.api_request` for Claude Code's `api_request`.
    static func eventName(_ log: OTLPLog) -> String {
        let name = log.name.lowercased()
        guard !name.contains(".") else { return name }
        return switch agent(log.resource) {
        case "claude": "claude_code." + name
        case "codex": "codex." + name
        default: name
        }
    }

    static func prompt(_ log: OTLPLog) -> AgentPrompt? {
        guard eventName(log).hasSuffix("user_prompt") else { return nil }
        let attributes = log.attributes
        return AgentPrompt(
            agent: agent(log.resource), agentSession: agentSession(attributes, log.resource),
            heedSession: log.resource[sessionAttribute], at: log.time, id: attributes["prompt.id"],
            text: readable(attributes["prompt"] ?? attributes["prompt_text"])
        )
    }

    /// A tool call or a model request, from an event with a duration; nil for every other event.
    static func span(_ log: OTLPLog) -> AgentSpan? {
        let attributes = log.attributes
        let name = eventName(log)
        let agent = agent(log.resource)
        let milliseconds = (attributes["duration_ms"] ?? attributes["duration"]).flatMap(Double.init)
        let start = log.time.addingTimeInterval(-(milliseconds ?? 0) / 1000)
        let failed = attributes["success"] == "false" || attributes["success"] == "0"
        var out = AgentSpan(
            id: "", traceID: attributes["prompt.id"], agent: agent,
            agentSession: agentSession(attributes, log.resource), heedSession: log.resource[sessionAttribute],
            kind: .tool, name: "", start: start, end: log.time, status: failed ? .error : .ok,
            error: attributes["error"] ?? attributes["error_type"], fromEvent: true
        )
        if name.hasSuffix("tool_result") {
            let tool = attributes["tool_name"] ?? ""
            out.name = toolGroup(tool)
            out.detail = toolDetail(tool, attributes)
            let call = attributes["tool_use_id"] ?? attributes["call_id"]
            // Claude Code's own spans key a tool call as `claude_code.tool:<id>`.
            out.key = call.map { (agent == "claude" ? "claude_code.tool:" : "tool:") + $0 }
        } else if name == "claude_code.api_request" || name == "codex.api_request"
            || (name == "codex.sse_event" && (attributes["event.kind"] ?? attributes["kind"]) == "response.completed")
        {
            out.kind = .model
            out.name = "model"
            out.model = attributes["model"] ?? log.resource["model"]
            out.detail = out.model ?? ""
            out.tokens = tokens(attributes)
            out.cost = attributes["cost_usd"].flatMap(Double.init)
                ?? attributes["cost_usd_micros"].flatMap(Double.init).map { $0 / 1_000_000 }
            out.key = attributes["request_id"]
            // Codex's request event carries no tokens; its completed stream does, and no duration.
            if name == "codex.sse_event" { out.status = .ok }
        } else if name == "claude_code.api_error" {
            out.kind = .model
            out.name = "model"
            out.model = attributes["model"]
            out.detail = attributes["error"] ?? "error"
            out.status = .error
            out.key = attributes["request_id"].map { "error:" + $0 }
        } else {
            return nil
        }
        out.id = "event:" + (out.key ?? "\(agent):\(name):\(log.time.timeIntervalSince1970)")
        return out
    }

    // MARK: Metrics

    /// Tokens and cost by session and model, from the metrics: one sample per point.
    static func usage(_ points: [OTLPPoint]) -> [AgentUsageSample] {
        points.compactMap { point in
            let attributes = point.attributes
            var sample = AgentUsageSample(
                agent: agent(point.resource), agentSession: agentSession(attributes, point.resource),
                heedSession: point.resource[sessionAttribute], at: point.time, model: attributes["model"],
                cumulative: point.cumulative
            )
            switch point.name {
            case "claude_code.cost.usage":
                sample.cost = point.value
            case "codex.turn.cost_microusd":
                sample.cost = point.value / 1_000_000
            case "claude_code.token.usage", "codex.turn.token_usage":
                let count = Int(point.value)
                switch attributes["type"] ?? attributes["token_type"] ?? "" {
                case "input", "non_cached_input": sample.tokens.input = count
                case "output", "reasoning_output": sample.tokens.output = count
                case "cacheRead", "cache_read", "cached_input": sample.tokens.cacheRead = count
                case "cacheCreation", "cache_creation", "cache_write_input": sample.tokens.cacheWrite = count
                default: return nil
                }
            default:
                return nil
            }
            return sample
        }
    }

    // MARK: Helpers

    /// The tool group a call is counted under: `bash`, `edit`, `read/grep`, `mcp <server>`, `web`, `agent`, or the
    /// tool's own name.
    public static func toolGroup(_ tool: String) -> String {
        let lower = tool.lowercased()
        if lower.hasPrefix("mcp__") {
            let server = lower.dropFirst(5).split(separator: "_", maxSplits: 1).first.map(String.init) ?? "mcp"
            return "mcp " + server
        }
        switch lower {
        case "bash", "shell", "exec_command", "local_shell", "unified_exec", "powershell", "container.exec": return "bash"
        case "edit", "write", "multiedit", "notebookedit", "apply_patch", "patch": return "edit"
        case "read", "grep", "glob", "ls", "view_image", "read_file", "list_dir", "grep_files": return "read/grep"
        case "webfetch", "websearch", "web_search", "web_fetch": return "web"
        case "task", "agent", "spawn_agent": return "agent"
        case "": return "tool"
        default: return lower
        }
    }

    /// The command or file, when the agent sent it (Claude Code: with `OTEL_LOG_TOOL_DETAILS`).
    static func toolDetail(_ tool: String, _ attributes: [String: String]) -> String {
        if let command = attributes["full_command"] ?? attributes["command"] { return firstLine(command) }
        if let parameters = attributes["tool_parameters"] ?? attributes["tool_input"] ?? attributes["arguments"],
           let data = parameters.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            for key in [
                "full_command",
                "command",
                "cmd",
                "bash_command",
                "file_path",
                "path",
                "pattern",
                "url",
                "description",
            ] {
                if let value = object[key] as? String, !value.isEmpty { return firstLine(value) }
                // Codex's shell takes argv; `bash -lc '<line>'` is the line.
                if let words = object[key] as? [String], !words.isEmpty {
                    if words.count == 3, ["bash", "sh", "zsh"].contains(words[0]), words[1].hasPrefix("-") {
                        return firstLine(words[2])
                    }
                    return firstLine(words.joined(separator: " "))
                }
            }
        }
        if let argv0 = attributes["bash_argv0"] ?? attributes["bash_command_class"] { return argv0 }
        if let path = attributes["file_path"] { return (path as NSString).lastPathComponent }
        if let skill = attributes["skill_name"] ?? attributes["subagent_type"] { return skill }
        if tool.lowercased().hasPrefix("mcp__") {
            return tool.split(separator: "_").last.map(String.init) ?? tool
        }
        return tool.lowercased() == toolGroup(tool) ? "" : tool
    }

    static func tokens(_ attributes: [String: String]) -> TokenCounts? {
        func count(_ keys: String...) -> Int {
            for key in keys {
                if let value = attributes[key].flatMap(Double.init) { return Int(value) }
            }
            return 0
        }
        let cacheRead = count("cache_read_tokens", "cached_token_count", "cached_input_tokens")
        let input = count("input_tokens", "input_token_count", "gen_ai.usage.input_tokens")
        // Codex counts the cached tokens inside its input count; heed's input is what was not read from the cache.
        let fresh = attributes["cached_token_count"] != nil ? max(0, input - cacheRead) : input
        let tokens = TokenCounts(
            input: fresh, output: count("output_tokens", "output_token_count", "gen_ai.usage.output_tokens"),
            cacheRead: cacheRead, cacheWrite: count("cache_creation_tokens")
        )
        return tokens.isEmpty ? nil : tokens
    }

    /// Prompt text an agent redacted is not worth showing.
    static func readable(_ text: String?) -> String? {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty,
              !text.hasPrefix("<REDACTED"), text != "<redacted>" else { return nil }
        return firstLine(text)
    }

    static func firstLine(_ text: String) -> String {
        let line = text.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        return trimmed.count > 120 ? String(trimmed.prefix(119)) + "…" : trimmed
    }
}
