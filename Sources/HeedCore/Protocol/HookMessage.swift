import Foundation

/// The environment every pane gets, so hooks inside it can reach the app.
public enum HeedEnvironment {
    public static let sessionID = "HEED_SESSION_ID"
    public static let socket = "HEED_SOCKET"
    public static let pane = "HEED_PANE_ID"
    /// Absolute path of the bundled `heed`, for hooks that should not depend on PATH.
    public static let binary = "HEED_BIN"

    /// `~/Library/Application Support/Heed/heed.sock`, unless overridden.
    public static func defaultSocketPath() -> String {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return support.appendingPathComponent("Heed/heed.sock").path
    }
}

/// One message from `heed` (called by an agent hook) to the app. Sent as a single JSON line over the unix socket.
public struct HookMessage: Codable, Equatable, Sendable {
    public enum Kind: Codable, Equatable, Sendable {
        case state(AgentState, reason: String?)
        /// A state the hook read from what the agent wrote rather than was told (a question in the turn's last
        /// words): drawn as guessed, but the latest word on the turn, so it replaces what was reported.
        case guess(AgentState, reason: String?)
        /// The agent has sat at its prompt for a while (Claude's `idle_prompt`). Says idle only when nothing more
        /// telling is known: a done, asking or blocked session stays as it is.
        case atPrompt
        case notify(String)
        case prAdd(url: String)
        /// `heed issue add <url>`: an issue the session works on.
        case issueAdd(url: String)
        case title(String)
        /// The agent's own session id, captured from its start hook, so the session can be resumed later.
        case agentSession(id: String, agent: String)
        /// A pinned task finished in its pane with this exit code.
        case taskExit(code: Int)
        /// The agent's model and what it used, as far as its hooks (and the transcript they point at) tell.
        case usage(UsageReport)
        /// A subagent started or finished (Claude's and Codex's `SubagentStart` and `SubagentStop`). Never changes the
        /// session's state: a subagent's last words are for its parent.
        case subagent(id: String, type: String?, started: Bool)
        /// A state reported from inside a subagent (a hook carrying its `agent_id`): it is alive, and the session's
        /// state changes only as `Subagents.fromSubagent` allows.
        case subagentState(AgentState, reason: String?, id: String, type: String?)
        /// The main thread's turn ended with nothing left in the background: no subagent can still be running.
        case subagentsEnded
        /// What the agent said last, sent with its turn's end (capped, `LastMessage`): what summaries read. Never a
        /// subagent's.
        case lastMessage(String)
        /// A tool call the agent made, short (`PostToolUse`): what a swarm's agents pane lists and its stuck signal
        /// reads. Never changes the session's state.
        case toolCall(ToolCall)
    }

    public var session: String
    public var pane: String?
    public var kind: Kind
    public var sentAt: Date
    /// The agent whose hook sent it (`heed hook <agent> …`): the one actually running in the pane, which may not be
    /// the one the session started with (you quit it and started another there).
    public var agent: String?

    public init(session: String, pane: String? = nil, kind: Kind, sentAt: Date = Date(), agent: String? = nil) {
        self.session = session
        self.pane = pane
        self.kind = kind
        self.sentAt = sentAt
        self.agent = agent
    }

    public func encodedLine() throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try encoder.encode(self)
        data.append(0x0A)
        return data
    }

    public static func decode(line: Data) throws -> HookMessage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(HookMessage.self, from: line)
    }
}

/// Parses `heed` arguments into a message. Lives here, not in the CLI, so it is tested with everything else.
public enum HookCommandLine {
    public static let usage = """
    usage: heed state <working|idle|blocked|asking|done|limited|exited> [--reason "..."]
           heed notify "<message>"
           heed pr add <url>
           heed issue add <url>
           heed title "<title>"
           heed agent-session <agent> <id>
           heed task-exit <code>
           heed hook <agent> <event>        (reads the agent's hook JSON on stdin)
           heed tools                       (where git and gh are found, as the app finds them)
           heed cleanup runs [path]         (remove what get it green runs left behind, when safe)
           heed sessions|watch|start|send|show  (the running app's control socket: heed start -h)
    Reads \(HeedEnvironment.sessionID) and \(HeedEnvironment.socket) from the environment (set in every Heed pane).
    """

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    /// The agent a `heed hook <agent> <event>` line is from; nil for any other command.
    public static func agent(_ arguments: [String]) -> String? {
        arguments.first == "hook" && arguments.count >= 2 ? arguments[1] : nil
    }

    /// `readInput` supplies stdin, read only by `hook` (agents pass their hook payload there).
    public static func parse(
        _ arguments: [String], readInput: () -> Data = { Data() }
    ) throws(UsageError) -> [HookMessage.Kind] {
        if arguments.first == "hook" {
            guard arguments.count >= 3 else { throw UsageError(description: "heed hook: expected <agent> <event>") }
            let event = arguments[2]
            let session = arguments.count > 3 ? arguments[3] : nil
            let detail = arguments.count > 4 ? arguments[4] : nil
            let text = arguments.count > 5 ? arguments[5] : nil
            switch arguments[1] {
            // These pass their payload as arguments (the turn's last text with its end); stdin is not read.
            case "pi": return AgentIntegration.piHook(event: event, sessionID: session, detail: detail, text: text)
            case "opencode":
                return AgentIntegration.opencodeHook(event: event, sessionID: session, detail: detail, text: text)
            default: break
            }
            let input = (try? JSONSerialization.jsonObject(with: readInput())) as? [String: Any] ?? [:]
            switch arguments[1] {
            case "claude": return AgentIntegration.claudeHook(event: event, input: input)
            case "codex": return AgentIntegration.codexHook(event: event, input: input)
            case "cursor": return AgentIntegration.cursorHook(event: event, input: input)
            default: throw UsageError(description: "heed hook: unknown agent '\(arguments[1])'")
            }
        }
        return try [parseVerb(arguments)]
    }

    private static func parseVerb(_ arguments: [String]) throws(UsageError) -> HookMessage.Kind {
        var args = arguments[...]
        guard let verb = args.popFirst() else { throw UsageError(description: usage) }
        switch verb {
        case "state":
            guard let raw = args.popFirst(), let state = AgentState(rawValue: raw) else {
                throw UsageError(description: "heed state: expected one of \(AgentState.allCases.map(\.rawValue))")
            }
            var reason: String?
            if args.first == "--reason" {
                args.removeFirst()
                reason = args.popFirst()
            }
            return .state(state, reason: reason)
        case "notify":
            guard let message = args.popFirst()
            else { throw UsageError(description: "heed notify: expected a message") }
            return .notify(message)
        case "pr":
            guard args.popFirst() == "add", let url = args.popFirst() else {
                throw UsageError(description: "heed pr add: expected a PR url")
            }
            return .prAdd(url: url)
        case "issue":
            guard args.popFirst() == "add", let url = args.popFirst(), IssueRef(url: url) != nil else {
                throw UsageError(description: "heed issue add: expected an issue url")
            }
            return .issueAdd(url: url)
        case "title":
            guard let title = args.popFirst() else { throw UsageError(description: "heed title: expected a title") }
            return .title(title)
        case "task-exit":
            guard let code = args.popFirst().flatMap({ Int($0) }) else {
                throw UsageError(description: "heed task-exit: expected an exit code")
            }
            return .taskExit(code: code)
        case "agent-session":
            guard let agent = args.popFirst(), let id = args.popFirst() else {
                throw UsageError(description: "heed agent-session: expected <agent> <id>")
            }
            return .agentSession(id: id, agent: agent)
        default:
            throw UsageError(description: usage)
        }
    }
}

/// The agent's last message as heed keeps it: trimmed, at most `limit` characters, its end kept (where a turn
/// concludes).
public enum LastMessage {
    public static let limit = 4000

    /// The message kind for `text`, or nothing when there is nothing to keep.
    public static func kinds(_ text: String?) -> [HookMessage.Kind] {
        guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return [] }
        return [.lastMessage(text.count > limit ? "…" + String(text.suffix(limit - 1)) : text)]
    }
}
