import Foundation

/// The parts of the Agent Client Protocol (ACP, agentclientprotocol.com) heed speaks, as of protocol version 1
/// (`schema/v1/schema.json` in agentclientprotocol/agent-client-protocol). heed is the client: it starts an agent
/// (or an adapter in front of one), opens a session in a worktree, prompts it, and draws what the agent streams back
/// in `session/update` notifications. Only the stable v1 methods are used; the v2 draft is not.
public enum ACP {
    /// The protocol version heed asks for in `initialize`.
    public static let protocolVersion = 1

    public enum Method {
        public static let initialize = "initialize"
        public static let sessionNew = "session/new"
        public static let sessionPrompt = "session/prompt"
        public static let sessionCancel = "session/cancel"
        public static let sessionUpdate = "session/update"
        public static let requestPermission = "session/request_permission"
    }

    /// The `initialize` request: v1, and no client capabilities. heed does not offer the agent its file system or
    /// terminals (`fs/*`, `terminal/*`): the agent reads, writes and runs in its own worktree itself, and asks
    /// permission through `session/request_permission`.
    public static func initializeParams(clientVersion: String) -> JSONValue {
        [
            "protocolVersion": .number(Double(protocolVersion)),
            "clientCapabilities": [
                "fs": ["readTextFile": false, "writeTextFile": false],
                "terminal": false,
            ],
            "clientInfo": ["name": "heed", "title": "heed", "version": .string(clientVersion)],
        ]
    }

    public static func newSessionParams(cwd: String) -> JSONValue {
        ["cwd": .string(cwd), "mcpServers": []]
    }

    public static func promptParams(sessionID: String, text: String) -> JSONValue {
        ["sessionId": .string(sessionID), "prompt": [["type": "text", "text": .string(text)]]]
    }

    public static func cancelParams(sessionID: String) -> JSONValue { ["sessionId": .string(sessionID)] }

    /// The answer to `session/request_permission`: the option picked, or `cancelled` (the turn was cancelled, or
    /// the helper stopped).
    public static func permissionResult(optionID: String?) -> JSONValue {
        guard let optionID else { return ["outcome": ["outcome": "cancelled"]] }
        return ["outcome": ["outcome": "selected", "optionId": .string(optionID)]]
    }
}

/// What `initialize` answered: the version the agent speaks and who it is.
public struct ACPAgentInfo: Hashable, Sendable {
    public var protocolVersion: Int
    public var name: String?
    public var version: String?
    /// The agent's ways to sign in, when it needs one heed cannot do (heed never runs `authenticate`).
    public var authMethods: [String]

    public init(protocolVersion: Int, name: String? = nil, version: String? = nil, authMethods: [String] = []) {
        self.protocolVersion = protocolVersion
        self.name = name
        self.version = version
        self.authMethods = authMethods
    }

    public init(_ result: JSONValue) {
        protocolVersion = result["protocolVersion"]?.int ?? 0
        name = result["agentInfo"]?["title"]?.string ?? result["agentInfo"]?["name"]?.string
        version = result["agentInfo"]?["version"]?.string
        authMethods = result["authMethods"]?.array?.compactMap { $0["name"]?.string ?? $0["id"]?.string } ?? []
    }
}

/// Why a prompt turn ended (`PromptResponse.stopReason`).
public enum ACPStopReason: String, Hashable, Sendable, Codable {
    case endTurn = "end_turn"
    case maxTokens = "max_tokens"
    case maxTurnRequests = "max_turn_requests"
    case refusal
    case cancelled

    public var text: String {
        switch self {
        case .endTurn: "finished its turn"
        case .maxTokens: "ran out of tokens"
        case .maxTurnRequests: "reached its turn limit"
        case .refusal: "refused"
        case .cancelled: "was cancelled"
        }
    }
}

/// A plan entry (`PlanEntry`): the agent's own list of steps, replaced whole on every `plan` update.
public struct ACPPlanEntry: Hashable, Sendable, Codable {
    public enum Status: String, Hashable, Sendable, Codable {
        case pending, inProgress = "in_progress", completed
    }

    public var content: String
    public var status: Status

    public init(content: String, status: Status) {
        self.content = content
        self.status = status
    }
}

/// What a tool call carries (`ToolCallContent`): text, a diff of one file, or a terminal the client would own (heed
/// offers none, so it only shows that there was one).
public enum ACPToolContent: Hashable, Sendable, Codable {
    case text(String)
    case diff(path: String, oldText: String?, newText: String)
    case terminal(String)

    init?(_ value: JSONValue) {
        switch value["type"]?.string {
        case "content":
            guard let text = value["content"]?["text"]?.string else { return nil }
            self = .text(text)
        case "diff":
            guard let path = value["path"]?.string, let new = value["newText"]?.string else { return nil }
            self = .diff(path: path, oldText: value["oldText"]?.string, newText: new)
        case "terminal":
            self = .terminal(value["terminalId"]?.string ?? "")
        default:
            return nil
        }
    }
}

/// `ToolKind`, as the agent labels a call; heed only uses it to pick a glyph and to say what is asked.
public enum ACPToolKind: String, Hashable, Sendable, Codable {
    case read, edit, delete, move, search, execute, think, fetch
    case switchMode = "switch_mode"
    case other
}

public enum ACPToolStatus: String, Hashable, Sendable, Codable {
    case pending, inProgress = "in_progress", completed, failed
}

/// A tool call, as first reported (`tool_call`) or updated (`tool_call_update`, every field but the id optional).
public struct ACPToolCall: Hashable, Sendable, Codable {
    public var id: String
    public var title: String?
    public var kind: ACPToolKind?
    public var status: ACPToolStatus?
    /// Nil on an update that leaves the content as it was; an update's content replaces it.
    public var content: [ACPToolContent]?
    public var paths: [String]?
    /// The tool's raw input, when it is a command to run: what a permission request shows.
    public var command: String?

    public init(
        id: String, title: String? = nil, kind: ACPToolKind? = nil, status: ACPToolStatus? = nil,
        content: [ACPToolContent]? = nil, paths: [String]? = nil, command: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.content = content
        self.paths = paths
        self.command = command
    }

    init?(_ value: JSONValue) {
        guard let id = value["toolCallId"]?.string else { return nil }
        self.id = id
        title = value["title"]?.string
        kind = value["kind"]?.string.flatMap(ACPToolKind.init(rawValue:))
        status = value["status"]?.string.flatMap(ACPToolStatus.init(rawValue:))
        content = value["content"]?.array.map { $0.compactMap(ACPToolContent.init) }
        paths = value["locations"]?.array.map { $0.compactMap { $0["path"]?.string } }
        let input = value["rawInput"]
        command = input?["command"]?.string ?? input?["command"]?.array?.compactMap(\.string).joined(separator: " ")
    }
}

/// One `session/update`, as heed reads it. Kinds heed does not draw (available commands, modes, config options,
/// session info, notices, compaction) are `other`, named.
public enum ACPUpdate: Hashable, Sendable {
    case agentMessage(String)
    case agentThought(String)
    case userMessage(String)
    case toolCall(ACPToolCall)
    case toolCallUpdate(ACPToolCall)
    case plan([ACPPlanEntry])
    /// `usage_update`: context tokens used, the window's size, and the session's cost so far when the agent knows it.
    case usage(used: Int, size: Int, cost: Double?, currency: String?)
    case other(String)

    public init?(_ update: JSONValue) {
        guard let kind = update["sessionUpdate"]?.string else { return nil }
        func text() -> String {
            let content = update["content"]
            if content?["type"]?.string == "text" { return content?["text"]?.string ?? "" }
            return ""
        }
        switch kind {
        case "agent_message_chunk": self = .agentMessage(text())
        case "agent_thought_chunk": self = .agentThought(text())
        case "user_message_chunk": self = .userMessage(text())
        case "tool_call":
            guard let call = ACPToolCall(update) else { return nil }
            self = .toolCall(call)
        case "tool_call_update":
            guard let call = ACPToolCall(update) else { return nil }
            self = .toolCallUpdate(call)
        case "plan":
            let entries = update["entries"]?.array?.compactMap { entry -> ACPPlanEntry? in
                guard let content = entry["content"]?.string else { return nil }
                let status = entry["status"]?.string.flatMap(ACPPlanEntry.Status.init(rawValue:)) ?? .pending
                return ACPPlanEntry(content: content, status: status)
            }
            self = .plan(entries ?? [])
        case "usage_update":
            self = .usage(
                used: update["used"]?.int ?? 0, size: update["size"]?.int ?? 0,
                cost: update["cost"]?["amount"]?.double, currency: update["cost"]?["currency"]?.string
            )
        default: self = .other(kind)
        }
    }
}

/// `session/request_permission`: the agent wants to run a tool call and offers options (allow once, allow always,
/// reject once, reject always).
public struct ACPPermissionRequest: Hashable, Sendable {
    public struct Option: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable {
            case allowOnce = "allow_once", allowAlways = "allow_always", rejectOnce = "reject_once"
            case rejectAlways = "reject_always"
        }

        public var id: String
        public var name: String
        public var kind: Kind

        public init(id: String, name: String, kind: Kind) {
            self.id = id
            self.name = name
            self.kind = kind
        }
    }

    public var toolCall: ACPToolCall
    public var options: [Option]

    public init(toolCall: ACPToolCall, options: [Option]) {
        self.toolCall = toolCall
        self.options = options
    }

    init?(_ params: JSONValue) {
        guard let call = params["toolCall"].flatMap(ACPToolCall.init) else { return nil }
        toolCall = call
        options = params["options"]?.array?.compactMap { option in
            guard let id = option["optionId"]?.string,
                  let kind = option["kind"]?.string.flatMap(Option.Kind.init(rawValue:))
            else { return nil }
            return Option(id: id, name: option["name"]?.string ?? id, kind: kind)
        } ?? []
    }

    /// The option of `kind`, when the agent offered one.
    public func option(_ kind: Option.Kind) -> Option? { options.first { $0.kind == kind } }
}
