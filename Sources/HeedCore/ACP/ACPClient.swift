import Foundation

/// Where ACP's newline-delimited JSON-RPC messages go and come from: an agent process's stdin and stdout
/// (`ACPProcessTransport`), or a fake in tests.
public protocol ACPTransport: Sendable {
    /// One message, without its newline.
    func send(_ line: String) async throws
    /// What the agent writes, a line at a time; finishes when it exits or closes its output.
    var lines: AsyncStream<String> { get }
    /// Why it ended, when it did: the last lines of the agent's stderr, or its exit status.
    func closedReason() async -> String?
    func close() async
}

public enum ACPError: Error, Equatable, Sendable, CustomStringConvertible {
    /// The agent answered with a JSON-RPC error.
    case rpc(code: Int, message: String)
    /// The agent went away before answering: why, when known.
    case closed(String?)
    /// It speaks another protocol version than 1.
    case protocolVersion(Int)
    case timedOut(String)
    case badResponse(String)

    public var description: String {
        switch self {
        case let .rpc(code, message): "the agent said: \(message) (\(code))"
        case let .closed(reason): "the agent exited" + (reason.map { ": \($0)" } ?? "")
        case let .protocolVersion(version): "the agent speaks ACP version \(version), heed speaks 1"
        case let .timedOut(method): "the agent did not answer \(method) in time"
        case let .badResponse(method): "the agent's answer to \(method) did not read"
        }
    }
}

/// What the agent tells heed without being asked.
public enum ACPEvent: Sendable, Equatable {
    case update(sessionID: String, ACPUpdate)
    /// It asks before running a tool call; answer with `ACPClient.answerPermission(_:optionID:)`.
    case permission(requestID: JSONValue, sessionID: String, ACPPermissionRequest)
    /// It exited or closed its output.
    case closed(String?)
}

/// The client side of an ACP connection: JSON-RPC 2.0 requests with their answers matched by id, the agent's
/// notifications and requests turned into `events`, and the agent's requests heed does not serve (`fs/*`,
/// `terminal/*`, anything else) answered "method not found", as JSON-RPC asks, so the agent never waits on them.
public actor ACPClient {
    private let transport: any ACPTransport
    private var nextID = 0
    private var pending: [Int: CheckedContinuation<JSONValue, Error>] = [:]
    private var reader: Task<Void, Never>?
    private var isClosed = false
    public nonisolated let events: AsyncStream<ACPEvent>
    private let sink: AsyncStream<ACPEvent>.Continuation

    public init(transport: any ACPTransport) {
        self.transport = transport
        (events, sink) = AsyncStream<ACPEvent>.makeStream()
    }

    /// Starts reading what the agent writes. Call once, before the first request.
    public func start() {
        guard reader == nil else { return }
        let lines = transport.lines
        reader = Task { [weak self] in
            for await line in lines {
                await self?.receive(line)
            }
            await self?.transportEnded()
        }
    }

    // MARK: Requests

    /// `initialize`: version 1 or an error.
    public func initialize(clientVersion: String, timeout: Duration = .seconds(60)) async throws -> ACPAgentInfo {
        let result = try await request(
            ACP.Method.initialize, ACP.initializeParams(clientVersion: clientVersion), timeout: timeout
        )
        let info = ACPAgentInfo(result)
        guard info.protocolVersion == ACP.protocolVersion else { throw ACPError.protocolVersion(info.protocolVersion) }
        return info
    }

    /// `session/new` in `cwd`: the session's id.
    public func newSession(cwd: String, timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await request(ACP.Method.sessionNew, ACP.newSessionParams(cwd: cwd), timeout: timeout)
        guard let id = result["sessionId"]?.string else { throw ACPError.badResponse(ACP.Method.sessionNew) }
        return id
    }

    /// `session/prompt`: returns when the turn ends, however long it works (updates arrive as `events` meanwhile).
    public func prompt(sessionID: String, text: String) async throws -> ACPStopReason {
        let result = try await request(
            ACP.Method.sessionPrompt, ACP.promptParams(sessionID: sessionID, text: text), timeout: nil
        )
        guard let reason = result["stopReason"]?.string.flatMap(ACPStopReason.init(rawValue:)) else {
            throw ACPError.badResponse(ACP.Method.sessionPrompt)
        }
        return reason
    }

    /// `session/cancel`: the turn under way stops; its `prompt` answers `cancelled`.
    public func cancel(sessionID: String) async {
        try? await notify(ACP.Method.sessionCancel, ACP.cancelParams(sessionID: sessionID))
    }

    /// Answers a `session/request_permission`: an option's id, or nil for cancelled.
    public func answerPermission(_ requestID: JSONValue, optionID: String?) async {
        try? await send(["jsonrpc": "2.0", "id": requestID, "result": ACP.permissionResult(optionID: optionID)])
    }

    public func close() async {
        await transport.close()
    }

    func request(_ method: String, _ params: JSONValue, timeout: Duration?) async throws -> JSONValue {
        if isClosed { throw await ACPError.closed(transport.closedReason()) }
        let id = nextID
        nextID += 1
        let line = JSONValue.object([
            "jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": params,
        ]).text
        let transport = transport
        if let timeout {
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                await self?.fail(id, ACPError.timedOut(method))
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            pending[id] = continuation
            Task { [weak self] in
                do { try await transport.send(line) } catch { await self?.fail(id, error) }
            }
        }
    }

    private func notify(_ method: String, _ params: JSONValue) async throws {
        try await send(["jsonrpc": "2.0", "method": .string(method), "params": params])
    }

    private func send(_ message: JSONValue) async throws {
        guard !isClosed else { return }
        try await transport.send(message.text)
    }

    private func fail(_ id: Int, _ error: Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    // MARK: What the agent writes

    func receive(_ line: String) async {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let message = JSONValue.parse(trimmed), case .object = message else { return }
        let method = message["method"]?.string
        let id = message["id"]
        if method == nil, let id = id?.int {
            // An answer to one of heed's requests.
            guard let continuation = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] {
                continuation.resume(throwing: ACPError.rpc(
                    code: error["code"]?.int ?? 0, message: error["message"]?.string ?? "error"
                ))
            } else {
                continuation.resume(returning: message["result"] ?? .null)
            }
            return
        }
        guard let method else { return }
        let params = message["params"] ?? .null
        if let id, !id.isNull {
            // The agent's request: a permission to ask about, or something heed does not serve.
            if method == ACP.Method.requestPermission, let request = ACPPermissionRequest(params),
               let session = params["sessionId"]?.string
            {
                sink.yield(.permission(requestID: id, sessionID: session, request))
            } else {
                try? await send([
                    "jsonrpc": "2.0", "id": id,
                    "error": ["code": -32601, "message": .string("heed does not offer \(method)")],
                ])
            }
            return
        }
        if method == ACP.Method.sessionUpdate, let session = params["sessionId"]?.string,
           let update = params["update"].flatMap(ACPUpdate.init)
        {
            sink.yield(.update(sessionID: session, update))
        }
    }

    private func transportEnded() async {
        guard !isClosed else { return }
        isClosed = true
        let reason = await transport.closedReason()
        for continuation in pending.values {
            continuation.resume(throwing: ACPError.closed(reason))
        }
        pending.removeAll()
        sink.yield(.closed(reason))
        sink.finish()
    }
}
