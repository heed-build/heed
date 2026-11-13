import Foundation

/// Claude Code's cross-session inbox, as heed uses it (Claude Code 2.1.224 and later; checked against 2.1.319).
///
/// Each running session binds a Unix socket (`/tmp/cc-socks/<pid>.sock` unless `$XDG_RUNTIME_DIR` says otherwise) and
/// exports its path to hooks as `CLAUDE_CODE_MESSAGING_SOCKET`; heed's hook passes it on. A message is one JSON line:
///
///     {"type":"user","from":"uds:<reply socket>","message":{"role":"user","content":"…"}}
///
/// Claude Code wraps it as a message from another session, which can never approve a prompt or change settings, and
/// queues it: read between tool calls, or a new turn when idle. Nothing comes back on the connection. When `from` is a
/// socket beside the session's own, Claude Code reports there what it did with a message it did not deliver:
///
///     {"type":"control","action":"peer_message_status","status":"held","reason":"…","from":"uds:<its socket>",…}
///
/// `held` (waiting for your approval in the session, which its `crossSessionInbound` setting or permission mode asks
/// for), or `expired` with `status_detail` `refused` (the setting refuses messages). Silence means it took it.
public enum ClaudeInbox {
    /// What heed's messages start with, so the agent (and you, reading its transcript) know who sent them.
    public static let prefix = "From heed, the app your user runs this session in: "

    /// The hook environment's inbox socket, when it names one.
    public static func socket(from environment: [String: String]) -> String? {
        guard let path = environment["CLAUDE_CODE_MESSAGING_SOCKET"]?.trimmingCharacters(in: .whitespaces),
              path.hasPrefix("/")
        else { return nil }
        return path
    }

    /// The line that delivers `text`, replies (receipts) going to `replyTo`.
    public static func line(_ text: String, replyTo: String?) -> Data {
        var object: [String: Any] = ["type": "user", "message": ["role": "user", "content": prefix + text]]
        if let replyTo { object["from"] = "uds:" + replyTo }
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        data.append(0x0A)
        return data
    }

    /// heed's reply socket for sessions whose inbox is `socket`: in the same directory (Claude Code only answers an
    /// address there), named for heed's process. Nil when the path would be too long for a Unix socket.
    public static func replySocket(beside socket: String, pid: Int32 = getpid()) -> String? {
        let directory = (socket as NSString).deletingLastPathComponent
        let path = (directory as NSString).appendingPathComponent("heed-\(pid).sock")
        return path.utf8.count <= 103 ? path : nil
    }

    /// A receipt line: the inbox it is about and what it says. Nil for anything else (a reply from the session's
    /// Claude, say).
    public static func receipt(_ line: Data) -> (socket: String, result: ChannelResult)? {
        guard let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "control", object["action"] as? String == "peer_message_status",
              let from = object["from"] as? String, let status = object["status"] as? String
        else { return nil }
        let socket = from.hasPrefix("uds:") ? String(from.dropFirst(4)) : from
        switch status {
        case "held":
            return (socket, .queued("held for your approval in the session"))
        case "expired":
            if object["status_detail"] as? String == "refused" {
                return (socket, .refused("the session refuses messages from other sessions"))
            }
            return (socket, .refused("the session dropped it unread"))
        default:
            return (socket, .accepted)
        }
    }
}

/// How heed reaches agents' channels: real sockets and `codex`, or fakes in tests.
public protocol ChannelTransport: Sendable {
    /// Writes one line to a Unix socket and closes it; false when nothing accepts the connection.
    func write(_ line: Data, to socket: String) async -> Bool
    /// Starts listening for receipts at `path` (idempotent); lines arrive through `receipts`.
    func listen(at path: String) async -> Bool
    var receipts: AsyncStream<Data> { get }
    /// `codex queue --thread <thread> --message <text>`: nil when codex could not be run.
    func codexQueue(thread: String, text: String) async -> ProcessResult?
}

/// Sends to agents' channels and reads what they answer. One per app.
public actor AgentChannels {
    private let transport: ChannelTransport
    private let receiptWindow: Duration
    private var waiters: [String: [(id: Int, continuation: CheckedContinuation<ChannelResult?, Never>)]] = [:]
    private var nextWaiter = 0
    private var inFlight: [String: Int] = [:]
    private var early: [String: [ChannelResult]] = [:]
    private var reading = false
    private let late: AsyncStream<(socket: String, result: ChannelResult)>.Continuation
    /// Receipts that came after their message was taken as delivered: a held message you denied, or that expired.
    public nonisolated let lateResults: AsyncStream<(socket: String, result: ChannelResult)>

    public init(transport: ChannelTransport = LiveChannelTransport(), receiptWindow: Duration = .milliseconds(800)) {
        self.transport = transport
        self.receiptWindow = receiptWindow
        (lateResults, late) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(64))
    }

    /// Hands `text` to the agent at `inbox` and says what came of it.
    public func send(_ text: String, to inbox: AgentInbox) async -> ChannelResult {
        switch inbox {
        case let .claude(socket): await sendClaude(text, to: socket)
        case let .codex(thread): await queueCodex(text, thread: thread)
        }
    }

    private func sendClaude(_ text: String, to socket: String) async -> ChannelResult {
        var reply = ClaudeInbox.replySocket(beside: socket)
        if let path = reply, await !transport.listen(at: path) { reply = nil }
        startReading()
        // Counted before the write: a receipt can come back before the write returns.
        inFlight[socket, default: 0] += 1
        defer {
            inFlight[socket, default: 1] -= 1
            if inFlight[socket] == 0 { inFlight[socket] = nil }
        }
        guard await transport.write(ClaudeInbox.line(text, replyTo: reply), to: socket) else {
            early[socket] = nil
            return .unreachable("nothing answers at its inbox")
        }
        // Without a reply socket there is no word back: taken as delivered, as Claude Code does on silence.
        guard reply != nil else { return .accepted }
        return await receipt(for: socket) ?? .accepted
    }

    private func queueCodex(_ text: String, thread: String) async -> ChannelResult {
        guard let result = await transport.codexQueue(thread: thread, text: text) else {
            return .unreachable("codex could not be run")
        }
        guard result.succeeded else {
            let words = result.stderr.split(separator: "\n").first.map(String.init) ?? "exit \(result.status)"
            return .unreachable(words)
        }
        // `codex queue` stores it in the thread's queue; codex runs it when the thread takes its next turn.
        return .queued("waiting in its thread's queue")
    }

    /// The receipt for the last message to `socket`, if one comes within the window.
    private func receipt(for socket: String) async -> ChannelResult? {
        if var arrived = early[socket], !arrived.isEmpty {
            let result = arrived.removeFirst()
            early[socket] = arrived.isEmpty ? nil : arrived
            return result
        }
        nextWaiter += 1
        let id = nextWaiter
        let window = receiptWindow
        Task {
            try? await Task.sleep(for: window)
            self.timeOut(socket, id: id)
        }
        return await withCheckedContinuation { continuation in
            waiters[socket, default: []].append((id, continuation))
        }
    }

    private func timeOut(_ socket: String, id: Int) {
        guard var list = waiters[socket], let index = list.firstIndex(where: { $0.id == id }) else { return }
        let waiter = list.remove(at: index)
        waiters[socket] = list.isEmpty ? nil : list
        waiter.continuation.resume(returning: nil)
    }

    /// A receipt: for the oldest message to `socket` still waiting on one, else one being sent, else a late word.
    private func arrived(_ socket: String, _ result: ChannelResult) {
        if var list = waiters[socket], !list.isEmpty {
            let waiter = list.removeFirst()
            waiters[socket] = list.isEmpty ? nil : list
            waiter.continuation.resume(returning: result)
        } else if inFlight[socket] != nil {
            early[socket, default: []].append(result)
        } else {
            late.yield((socket, result))
        }
    }

    private func startReading() {
        guard !reading else { return }
        reading = true
        let receipts = transport.receipts
        Task {
            for await line in receipts {
                guard let (socket, result) = ClaudeInbox.receipt(line) else { continue }
                self.arrived(socket, result)
            }
        }
    }
}

/// The real transport: Unix sockets, and `codex` found as heed finds every tool.
public final class LiveChannelTransport: ChannelTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var listeners: [String: LineListener] = [:]
    private let continuation: AsyncStream<Data>.Continuation
    public let receipts: AsyncStream<Data>

    public init() {
        (receipts, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(256))
    }

    deinit {
        for listener in listeners.values {
            listener.stop()
        }
    }

    public func write(_ line: Data, to socket: String) async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: UnixLine.write(line, to: socket))
            }
        }
    }

    public func listen(at path: String) async -> Bool {
        lock.withLock {
            if listeners[path] != nil { return true }
            Self.removeStale(beside: path)
            let listener = LineListener(path: path) { [continuation] line in continuation.yield(line) }
            guard (try? listener.start()) != nil else { return false }
            listeners[path] = listener
            return true
        }
    }

    /// Reply sockets an earlier heed left in that directory (it quit or crashed): `heed-<pid>.sock` of a process that
    /// is gone.
    static func removeStale(beside path: String) {
        let directory = (path as NSString).deletingLastPathComponent
        for name in (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? [] {
            guard name.hasPrefix("heed-"), name.hasSuffix(".sock"),
                  let pid = Int32(name.dropFirst(5).dropLast(5)), pid != getpid(), kill(pid, 0) != 0, errno == ESRCH
            else { continue }
            unlink((directory as NSString).appendingPathComponent(name))
        }
    }

    public func codexQueue(thread: String, text: String) async -> ProcessResult? {
        try? await ProcessRunner.run(
            "codex", ["queue", "--thread", thread, "--message", text], timeout: .seconds(20),
            caller: "delivery.codex-queue"
        )
    }
}

/// One line to a Unix socket, then closed. Blocking: call it off the main actor.
public enum UnixLine {
    public static func write(_ line: Data, to path: String, timeout: TimeInterval = 2) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var time = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &time, socklen_t(MemoryLayout<timeval>.size))
        guard path.utf8.count <= 103 else { return false }
        var address = HookServer.address(path)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return false }
        let written = line.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        shutdown(fd, SHUT_WR)
        return written == line.count
    }
}

/// A Unix socket that takes one line per connection and hands it on: where Claude Code sends heed its receipts.
/// Accepting and reading happen on a private queue.
public final class LineListener: @unchecked Sendable {
    public let path: String
    private let onLine: @Sendable (Data) -> Void
    private let queue = DispatchQueue(label: "heed.line-listener")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (DispatchSourceRead, Data)] = [:]

    public init(path: String, onLine: @escaping @Sendable (Data) -> Void) {
        self.path = path
        self.onLine = onLine
    }

    deinit { stop() }

    /// Binds the socket (mode 0600), replacing a stale one of the same name.
    public func start() throws {
        if FileManager.default.fileExists(atPath: path) { unlink(path) }
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
            unlink(path)
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

    private func acceptClients() {
        while true {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            _ = fcntl(fd, F_SETFL, O_NONBLOCK)
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
        guard count > 0, var pending = clients[fd]?.1 else {
            if let rest = clients[fd]?.1, !rest.isEmpty { onLine(rest) }
            drop(fd)
            return
        }
        pending.append(contentsOf: buffer[0 ..< count])
        // One line is all a sender has to say: hand it on and close, so the sender is not left waiting.
        if let newline = pending.firstIndex(of: 0x0A) {
            let line = Data(pending[pending.startIndex ..< newline])
            if !line.isEmpty { onLine(line) }
            drop(fd)
            return
        }
        clients[fd]?.1 = pending
    }

    private func drop(_ fd: Int32) {
        clients[fd]?.0.cancel()
        clients[fd] = nil
        close(fd)
    }
}
