import Foundation

/// The control socket: what other apps on this Mac (an editor, a script, `heed sessions`) use to start sessions, type
/// into them and follow them. One JSON object per line each way. A request carries an `id` its reply echoes; `watch`
/// answers once, then keeps the connection open and sends a `sessions` event each time the list changes.
public enum HeedControl {
    /// Overrides where clients look for the socket.
    public static let socketVariable = "HEED_CONTROL"

    /// `~/Library/Application Support/Heed/control.sock`, beside the hooks socket.
    public static func defaultSocketPath() -> String {
        (HeedEnvironment.defaultSocketPath() as NSString).deletingLastPathComponent + "/control.sock"
    }

    public static func socketPath(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        environment[socketVariable].flatMap { $0.isEmpty ? nil : $0 } ?? defaultSocketPath()
    }
}

/// One request. Which fields count depends on the method:
/// - `sessions`: none.
/// - `watch`: none; the connection then receives events.
/// - `start`: `directory` (an existing folder), `prompt`, `agent` (the default agent when nil), `arguments` (more
///   words for the agent's command line, such as an editor's MCP config), `focus`.
/// - `send`: `session`, `text`. Typed into the agent's pane with Return, only while it is idle or done.
/// - `show`: `session`, `focus`. Heed shows the session; it comes to the front only with `focus`.
public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case sessions, watch, start, send, show
    }

    public var id: Int?
    public var method: Method
    public var session: String?
    public var directory: String?
    public var agent: String?
    public var prompt: String?
    public var arguments: [String]?
    public var text: String?
    public var focus: Bool?

    public init(
        id: Int? = nil, method: Method, session: String? = nil, directory: String? = nil, agent: String? = nil,
        prompt: String? = nil, arguments: [String]? = nil, text: String? = nil, focus: Bool? = nil
    ) {
        self.id = id
        self.method = method
        self.session = session
        self.directory = directory
        self.agent = agent
        self.prompt = prompt
        self.arguments = arguments
        self.text = text
        self.focus = focus
    }
}

/// A session as the control socket describes it.
public struct ControlSession: Codable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var agent: String
    /// `AgentState`'s raw value: working, idle, blocked, asking, done, limited, exited.
    public var state: String
    public var reason: String?
    /// It waits on you: asking, blocked, or a PR heed watches does.
    public var needsYou: Bool
    /// The sidebar group it is in ("Needs you", "Working", ...).
    public var group: String
    /// Where the agent runs: the chat's folder or the first worktree.
    public var directory: String?
    public var repo: String?
    public var branch: String?
    public var host: String?
    public var activity: String
    public var lastActivity: Date

    public init(
        id: String, title: String, agent: String, state: String, reason: String? = nil, needsYou: Bool,
        group: String, directory: String? = nil, repo: String? = nil, branch: String? = nil, host: String? = nil,
        activity: String = "", lastActivity: Date
    ) {
        self.id = id
        self.title = title
        self.agent = agent
        self.state = state
        self.reason = reason
        self.needsYou = needsYou
        self.group = group
        self.directory = directory
        self.repo = repo
        self.branch = branch
        self.host = host
        self.activity = activity
        self.lastActivity = lastActivity
    }

    /// The fields a session gives by itself; `needsYou` and `group` are the app's to decide (PRs count).
    public init(_ session: Session, needsYou: Bool, group: SessionGroup) {
        self.init(
            id: session.id, title: session.title, agent: session.agent, state: session.state.state.rawValue,
            reason: session.state.reason, needsYou: needsYou, group: group.rawValue, directory: session.directory,
            repo: session.repos.first?.slug, branch: session.branch.isEmpty ? nil : session.branch,
            host: session.host, activity: session.activity, lastActivity: session.lastActivity
        )
    }
}

/// A reply to a request (`id` echoed), or an event on a watch (`event` set, no `id`).
public struct ControlReply: Codable, Equatable, Sendable {
    public var id: Int?
    public var ok: Bool
    public var error: String?
    /// `start`: the new session's id.
    public var session: String?
    /// `sessions` and `watch`, and every `sessions` event.
    public var sessions: [ControlSession]?
    public var event: String?

    public init(
        id: Int? = nil, ok: Bool = true, error: String? = nil, session: String? = nil,
        sessions: [ControlSession]? = nil, event: String? = nil
    ) {
        self.id = id
        self.ok = ok
        self.error = error
        self.session = session
        self.sessions = sessions
        self.event = event
    }

    public static func failure(_ message: String, id: Int? = nil) -> ControlReply {
        ControlReply(id: id, ok: false, error: message)
    }
}

public enum ControlCoding {
    public static func line(_ value: some Encodable) throws -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decode<T: Decodable>(_: T.Type, line: Data) throws -> T {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode(T.self, from: line)
    }
}

/// Serves the control socket. Requests go to `handler` (the app's, on the main actor) and its reply is written back;
/// `publish` sends the session list to every watcher when it differs from the last one sent. Reading and writing
/// happen on a private queue.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

    public let path: String
    private let handler: Handler
    private let queue = DispatchQueue(label: "heed.control")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, pending: Data)] = [:]
    private var watchers: Set<Int32> = []
    private var published: [ControlSession]?

    public init(path: String = HeedControl.defaultSocketPath(), handler: @escaping Handler) {
        self.path = path
        self.handler = handler
    }

    deinit { stop() }

    /// Binds the socket (mode 0600), replacing a stale one. Throws when another Heed is listening there.
    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            if HookServer.isListening(path) { throw HookServerError.alreadyRunning(path) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system("socket", errno) }
        var address = HookServer.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0 else {
            close(fd)
            throw HookServerError.system("bind", errno)
        }
        chmod(path, 0o600)
        guard listen(fd, 16) == 0 else {
            close(fd)
            throw HookServerError.system("listen", errno)
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        acceptSource = source
    }

    public func stop() {
        queue.sync {
            acceptSource?.cancel()
            acceptSource = nil
            for fd in clients.keys {
                drop(fd)
            }
            if listener >= 0 {
                close(listener)
                unlink(path)
                listener = -1
            }
        }
    }

    /// The session list now: sent to every watcher, unless it is what they were last sent.
    public func publish(_ sessions: [ControlSession]) {
        queue.async { [self] in
            guard sessions != published else { return }
            published = sessions
            guard !watchers.isEmpty, let line = try? ControlCoding.line(ControlReply(
                sessions: sessions, event: "sessions"
            )) else { return }
            for fd in watchers {
                send(line, to: fd)
            }
        }
    }

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(fd) }
            clients[fd] = (source, Data())
            source.resume()
        }
    }

    private func read(_ fd: Int32) {
        var buffer = [UInt8](repeating: 0, count: 16384)
        let count = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0, var pending = clients[fd]?.pending else { return drop(fd) }
        pending.append(contentsOf: buffer[0 ..< count])
        while let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex ..< newline])
            pending.removeSubrange(pending.startIndex ... newline)
            if !line.isEmpty { handle(line, from: fd) }
        }
        // A runaway client (no newline in a megabyte) is not one.
        guard pending.count < 1 << 20 else { return drop(fd) }
        clients[fd]?.pending = pending
    }

    private func handle(_ line: Data, from fd: Int32) {
        guard let request = try? ControlCoding.decode(ControlRequest.self, line: line) else {
            if let reply = try? ControlCoding
                .line(ControlReply.failure("not a request: \(String(decoding: line, as: UTF8.self).prefix(80))"))
            {
                send(reply, to: fd)
            }
            return
        }
        let handler = handler
        Task { [weak self] in
            var reply = await handler(request)
            reply.id = request.id
            self?.answer(request, with: reply, to: fd)
        }
    }

    private func answer(_ request: ControlRequest, with reply: ControlReply, to fd: Int32) {
        queue.async { [self] in
            guard clients[fd] != nil, let data = try? ControlCoding.line(reply) else { return }
            send(data, to: fd)
            guard request.method == .watch, reply.ok, clients[fd] != nil else { return }
            watchers.insert(fd)
            if let sessions = reply.sessions { published = sessions }
        }
    }

    /// Writes all of `data`, waiting up to a second for a slow reader; one that cannot keep up is dropped.
    private func send(_ data: Data, to fd: Int32) {
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written > 0 {
                offset += written
                continue
            }
            if written < 0, errno == EAGAIN || errno == EINTR {
                var poller = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                if poll(&poller, 1, 1000) > 0 { continue }
            }
            return drop(fd)
        }
    }

    private func drop(_ fd: Int32) {
        guard let client = clients.removeValue(forKey: fd) else { return }
        watchers.remove(fd)
        client.source.cancel()
        close(fd)
    }
}

/// A blocking client for one-shot requests (`heed sessions`) and watches (`heed watch`).
public final class ControlClient {
    private let fd: Int32
    private var pending = Data()
    private var nextID = 1

    public init(path: String = HeedControl.socketPath()) throws {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system("socket", errno) }
        var address = HookServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            let code = errno
            close(fd)
            throw ControlClientError.notRunning(path, code)
        }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        self.fd = fd
    }

    deinit { close(fd) }

    /// Sends `request` and waits for its reply (events that arrive first are skipped).
    public func call(_ request: ControlRequest) throws -> ControlReply {
        var request = request
        request.id = nextID
        nextID += 1
        let data = try ControlCoding.line(request)
        let written = data.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        guard written == data.count else { throw ControlClientError.closed }
        while true {
            let reply = try next()
            if reply.id == request.id { return reply }
        }
    }

    /// The next line from heed: a reply or an event. Throws when heed closes the connection.
    public func next() throws -> ControlReply {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex ..< newline])
                pending.removeSubrange(pending.startIndex ... newline)
                return try ControlCoding.decode(ControlReply.self, line: line)
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw ControlClientError.closed }
            pending.append(contentsOf: buffer[0 ..< count])
        }
    }
}

public enum ControlClientError: Error, CustomStringConvertible {
    case notRunning(String, Int32)
    case closed

    public var description: String {
        switch self {
        case let .notRunning(path, code): "Heed is not running (\(path): \(String(cString: strerror(code))))"
        case .closed: "Heed closed the connection"
        }
    }
}

/// `heed sessions|watch|start|send|show`: the control socket from a terminal.
public enum ControlCommandLine {
    public static let verbs: Set<String> = ["sessions", "watch", "start", "send", "show"]

    public static let usage = """
    usage: heed sessions                                  (every session: id, state, needs you, title)
           heed watch                                     (the session list as JSON lines, each time it changes)
           heed start [--agent <name>] [--dir <path>] [--arg <word>]... [--focus] "<prompt>"
           heed send <session> "<text>"                   (only while its agent is idle or done)
           heed show [--focus] <session>
    Talks to the app over \(HeedControl.defaultSocketPath()) (or $\(HeedControl.socketVariable)).
    """

    /// The request a command line makes; `directory` is where `start` runs when `--dir` is not given.
    public static func parse(_ arguments: [String], directory: String) throws -> ControlRequest {
        guard let verb = arguments.first, let method = ControlRequest.Method(rawValue: verb) else {
            throw HookCommandLine.UsageError(description: usage)
        }
        var request = ControlRequest(method: method)
        var words: [String] = []
        var rest = arguments.dropFirst()
        while let word = rest.popFirst() {
            switch word {
            case "--focus": request.focus = true
            case "--agent", "--dir", "--arg":
                guard let value = rest.popFirst() else {
                    throw HookCommandLine.UsageError(description: "\(word) needs a value\n\(usage)")
                }
                switch word {
                case "--agent": request.agent = value
                case "--dir": request.directory = value
                default: request.arguments = (request.arguments ?? []) + [value]
                }
            default: words.append(word)
            }
        }
        switch method {
        case .sessions, .watch:
            guard words.isEmpty else { throw HookCommandLine.UsageError(description: usage) }
        case .start:
            request.prompt = words.joined(separator: " ")
            request.directory = request.directory ?? directory
        case .send:
            guard words.count >= 2 else { throw HookCommandLine.UsageError(description: usage) }
            request.session = words[0]
            request.text = words.dropFirst().joined(separator: " ")
        case .show:
            guard words.count == 1 else { throw HookCommandLine.UsageError(description: usage) }
            request.session = words[0]
        }
        return request
    }

    /// One line per session, those that need you first.
    public static func table(_ sessions: [ControlSession]) -> String {
        let ordered = sessions
            .sorted { ($0.needsYou ? 0 : 1, $1.lastActivity) < ($1.needsYou ? 0 : 1, $0.lastActivity) }
        return ordered.map { session in
            [
                session.id, session.needsYou ? "needs you" : session.state, session.agent,
                session.title, session.directory.map { Paths.tilde($0) } ?? "",
            ].joined(separator: "\t")
        }.joined(separator: "\n")
    }
}
