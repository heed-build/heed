import Foundation

/// The environment every pane gets, so hooks inside it can reach the app.
public enum HeedEnvironment {
    public static let sessionID = "HEED_SESSION_ID"
    public static let socket = "HEED_SOCKET"
    public static let pane = "HEED_PANE_ID"

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
        case notify(String)
        case prAdd(url: String)
        case title(String)
        /// The agent's own session id, captured from its start hook, so the session can be resumed later.
        case agentSession(id: String, agent: String)
    }

    public var session: String
    public var pane: String?
    public var kind: Kind
    public var sentAt: Date

    public init(session: String, pane: String? = nil, kind: Kind, sentAt: Date = Date()) {
        self.session = session
        self.pane = pane
        self.kind = kind
        self.sentAt = sentAt
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
           heed title "<title>"
           heed agent-session <agent> <id>
    Reads \(HeedEnvironment.sessionID) and \(HeedEnvironment.socket) from the environment (set in every Heed pane).
    """

    public struct UsageError: Error, Equatable, CustomStringConvertible {
        public let description: String
    }

    public static func parse(_ arguments: [String]) throws(UsageError) -> HookMessage.Kind {
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
        case "title":
            guard let title = args.popFirst() else { throw UsageError(description: "heed title: expected a title") }
            return .title(title)
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
