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
/// - `goal`: `goal` (a `heed goal` command), `session` (the calling pane's session, when there is one) and `pane`.
///   Answered with `goal` in the reply.
/// - `permission`: `permission` (a permission hook's ask), `session` and `pane`. Answered once you answer it in heed,
///   or with a pass when heed will not (`PermissionHook`). Heed first sends a line with only `received` (the ask's id)
///   as soon as the ask is in its queue. With `fallback` set it is a notice that the hook gave up, answered at once.
public struct ControlRequest: Codable, Equatable, Sendable {
    public enum Method: String, Codable, Sendable {
        case sessions, watch, start, send, show, goal, memory, permission
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
    public var goal: GoalCommand?
    /// The calling pane (`HEED_PANE_ID`), for `goal`: a swarm worker's tab is a pane of the lead's session.
    public var pane: String?
    /// `permission`: what the agent's permission hook asks.
    public var permission: PermissionAsk?
    /// `permission`, sent after the hook gave up: why the agent asks in its pane instead (nothing is answered).
    public var fallback: PermissionFallback?

    public init(
        id: Int? = nil, method: Method, session: String? = nil, directory: String? = nil, agent: String? = nil,
        prompt: String? = nil, arguments: [String]? = nil, text: String? = nil, focus: Bool? = nil,
        goal: GoalCommand? = nil, pane: String? = nil, permission: PermissionAsk? = nil,
        fallback: PermissionFallback? = nil
    ) {
        self.fallback = fallback
        self.permission = permission
        self.pane = pane
        self.id = id
        self.method = method
        self.session = session
        self.directory = directory
        self.agent = agent
        self.prompt = prompt
        self.arguments = arguments
        self.text = text
        self.focus = focus
        self.goal = goal
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
    /// `goal`: what the command did (its exit code, its words, what changed).
    public var goal: GoalReply?
    /// `memory`: what to print.
    public var memory: String?
    /// `send`: how it reached the agent ("through Claude's inbox", "typed into its pane").
    public var delivery: String?
    /// `permission`: the answer, and the id of the ask it answers.
    public var permission: PermissionAnswer?
    public var permissionID: String?
    /// `permission`: a receipt, before the answer and without an `id`: heed has this ask (its id) in its queue.
    public var received: String?

    public init(
        id: Int? = nil, ok: Bool = true, error: String? = nil, session: String? = nil,
        sessions: [ControlSession]? = nil, event: String? = nil, goal: GoalReply? = nil, memory: String? = nil,
        permission: PermissionAnswer? = nil, permissionID: String? = nil, received: String? = nil
    ) {
        self.received = received
        self.permission = permission
        self.permissionID = permissionID
        self.memory = memory
        self.id = id
        self.ok = ok
        self.error = error
        self.session = session
        self.sessions = sessions
        self.event = event
        self.goal = goal
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
/// happen on a private queue that never waits on a handler: each request is its own task, so a slow one (a permission
/// ask waiting on you) holds up no other connection, and the accept loop never waits on any.
public final class ControlServer: @unchecked Sendable {
    public typealias Handler = @Sendable (ControlRequest) async -> ControlReply

    public let path: String
    private let handler: Handler
    /// User-initiated: a reply is someone waiting (a hook holding up its agent, a command in a terminal).
    private let queue = DispatchQueue(label: "heed.control", qos: .userInitiated)
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (source: DispatchSourceRead, pending: Data, serial: Int)] = [:]
    private var watchers: Set<Int32> = []
    private var published: [ControlSession]?
    /// Each connection's number: a reply goes only to the connection that asked, never to a later one that was given
    /// the same descriptor.
    private var serial = 0
    /// Permission asks still waiting, by connection: when the hook goes away (the agent stopped it), `permissionGone`
    /// hears of it.
    private var waitingAsks: [Int32: String] = [:]
    /// Called (on a private queue) with the id of a permission ask whose hook closed its connection before an answer.
    public var permissionGone: (@Sendable (String) -> Void)?

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
        // As deep as the system allows: on macOS a full backlog refuses a connection, which a hook reads as heed not
        // running, so a burst of asks must not fill it.
        guard listen(fd, SOMAXCONN) == 0 else {
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
            serial += 1
            clients[fd] = (source, Data(), serial)
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
        let serial = clients[fd]?.serial
        if request.method == .permission, request.fallback == nil, let id = request.permission?.id {
            waitingAsks[fd] = id
        }
        let interim = Interim { [weak self] reply in self?.interim(reply, to: fd, serial: serial) }
        // Its own high priority rather than whatever the queue's thread passes on: when the cooperative pool is busy
        // (a loaded machine, many tasks queued at the default priority) the reply still goes first, so an answer is
        // never held back past a hook's ceiling behind work nobody is waiting on.
        Task(priority: .high) { [weak self] in
            var reply = await ControlServer.$current.withValue(interim) { await handler(request) }
            reply.id = request.id
            self?.answer(request, with: reply, to: fd, serial: serial)
        }
    }

    /// Lets a handler send a line before its reply, on the connection whose request it handles.
    struct Interim: Sendable {
        let send: @Sendable (ControlReply) -> Void
    }

    @TaskLocal static var current: Interim?

    /// From inside a `permission` handler: tells the hook that asked that heed has its ask (`received`), before the
    /// answer. Does nothing outside a handler.
    public static func receipt(_ askID: String) {
        current?.send(ControlReply(received: askID))
    }

    private func interim(_ reply: ControlReply, to fd: Int32, serial: Int?) {
        queue.async { [self] in
            guard let client = clients[fd], client.serial == serial, let data = try? ControlCoding.line(reply)
            else { return }
            send(data, to: fd)
        }
    }

    private func answer(_ request: ControlRequest, with reply: ControlReply, to fd: Int32, serial: Int?) {
        queue.async { [self] in
            guard let client = clients[fd], client.serial == serial, let data = try? ControlCoding.line(reply)
            else { return }
            if request.method == .permission { waitingAsks[fd] = nil }
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
        if let ask = waitingAsks.removeValue(forKey: fd) { permissionGone?(ask) }
        watchers.remove(fd)
        client.source.cancel()
        close(fd)
    }
}

/// A blocking client for one-shot requests (`heed sessions`), watches (`heed watch`) and a permission hook's wait. With
/// a `deadline`, nothing it does (connecting, writing, each read, however the reply comes in pieces) goes past it: it
/// throws `timedOut` there.
public final class ControlClient {
    private let fd: Int32
    private var pending = Data()
    private var nextID = 1
    /// When every call gives up; nil waits as long as heed takes.
    public var deadline: ContinuousClock.Instant?

    public init(path: String = HeedControl.socketPath(), deadline: ContinuousClock.Instant? = nil) throws {
        self.deadline = deadline
        // A refusal while the socket is there is a full backlog (heed busy accepting a burst), not heed gone: with a
        // deadline, try again (on a fresh socket) for a moment.
        let retryUntil = deadline.map { min($0, ContinuousClock.now + .milliseconds(500)) }
        while true {
            let (fd, code) = try Self.connect(path, deadline: deadline)
            if let fd {
                self.fd = fd
                return
            }
            guard code == ECONNREFUSED, let retryUntil, ContinuousClock.now < retryUntil,
                  FileManager.default.fileExists(atPath: path)
            else { throw ControlClientError.notRunning(path, code) }
            Thread.sleep(forTimeInterval: 0.01)
        }
    }

    /// A connected, non-blocking socket, or the errno that refused it.
    private static func connect(
        _ path: String, deadline: ContinuousClock.Instant?
    ) throws -> (fd: Int32?, code: Int32) {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system("socket", errno) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        // Non-blocking throughout: every wait is a poll bounded by the deadline.
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        var address = HookServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected != 0 else { return (fd, 0) }
        var code = errno
        if code == EINPROGRESS || code == EAGAIN || code == EINTR {
            do {
                try wait(fd, for: Int16(POLLOUT), until: deadline)
            } catch {
                close(fd)
                throw error
            }
            var failure: Int32 = 0
            var size = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &size)
            if failure == 0 { return (fd, 0) }
            code = failure
        }
        close(fd)
        return (nil, code)
    }

    deinit { close(fd) }

    /// Sends `request` and waits for its reply (events and receipts that arrive first are skipped).
    public func call(_ request: ControlRequest) throws -> ControlReply {
        let id = try send(request)
        while true {
            let reply = try next()
            if reply.id == id { return reply }
        }
    }

    /// Writes `request` with the next id, returned: its reply is the line that echoes it.
    @discardableResult
    public func send(_ request: ControlRequest) throws -> Int {
        var request = request
        request.id = nextID
        nextID += 1
        let data = try ControlCoding.line(request)
        var offset = 0
        while offset < data.count {
            let written = data.withUnsafeBytes { write(fd, $0.baseAddress! + offset, $0.count - offset) }
            if written > 0 {
                offset += written
            } else if written < 0, errno == EAGAIN || errno == EINTR {
                try waitFor(Int16(POLLOUT))
            } else {
                throw ControlClientError.closed
            }
        }
        return request.id ?? 0
    }

    /// The next line from heed: a reply, a receipt or an event. Throws when heed closes the connection, or at the
    /// deadline.
    public func next() throws -> ControlReply {
        while true {
            if let newline = pending.firstIndex(of: 0x0A) {
                let line = Data(pending[pending.startIndex ..< newline])
                pending.removeSubrange(pending.startIndex ... newline)
                return try ControlCoding.decode(ControlReply.self, line: line)
            }
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EAGAIN || errno == EINTR {
                try waitFor(Int16(POLLIN))
                continue
            }
            guard count > 0 else { throw ControlClientError.closed }
            pending.append(contentsOf: buffer[0 ..< count])
        }
    }

    private func waitFor(_ events: Int16) throws {
        try Self.wait(fd, for: events, until: deadline)
    }

    /// Waits until `fd` is ready for `events`, or throws `timedOut` at `deadline`.
    private static func wait(_ fd: Int32, for events: Int16, until deadline: ContinuousClock.Instant?) throws {
        while true {
            var timeout: Int32 = -1
            if let deadline {
                let left = ContinuousClock.now.duration(to: deadline)
                guard left > .zero else { throw ControlClientError.timedOut }
                let (seconds, attoseconds) = left.components
                // Rounded up, so a poll never wakes just before the deadline and spins.
                let milliseconds = seconds * 1000 + (attoseconds + 999_999_999_999_999) / 1_000_000_000_000_000
                timeout = Int32(clamping: milliseconds)
            }
            var poller = pollfd(fd: fd, events: events, revents: 0)
            let ready = poll(&poller, 1, timeout)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw ControlClientError.closed }
        }
    }
}

public enum ControlClientError: Error, CustomStringConvertible {
    case notRunning(String, Int32)
    case closed
    case timedOut

    public var description: String {
        switch self {
        case let .notRunning(path, code): "Heed is not running (\(path): \(String(cString: strerror(code))))"
        case .closed: "Heed closed the connection"
        case .timedOut: "Heed did not answer in time"
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
           heed send <session> "<text>"                   (its inbox, else typed while its agent is idle)
           heed show [--focus] <session>
           heed goal <command>                            (the goal this session is on: heed goal --help)
    Talks to the app over \(HeedControl.defaultSocketPath()) (or $\(HeedControl.socketVariable)).
    """

    /// The request a command line makes; `directory` is where `start` runs when `--dir` is not given.
    public static func parse(_ arguments: [String], directory: String) throws -> ControlRequest {
        guard let verb = arguments.first, let method = ControlRequest.Method(rawValue: verb), method != .goal else {
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
        case .goal:
            throw HookCommandLine.UsageError(description: GoalCommandLine.usage)
        case .memory:
            throw HookCommandLine.UsageError(description: MemoryCommandLine.usage)
        case .permission:
            throw HookCommandLine.UsageError(description: usage)
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
