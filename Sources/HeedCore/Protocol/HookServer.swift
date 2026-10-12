import Foundation

/// Listens on the unix socket `heed` writes to and yields every decoded message. Accepting and reading happen on a
/// private queue; consumers get an `AsyncStream`, so nothing here touches the main actor.
public final class HookServer: @unchecked Sendable {
    public let path: String
    public let messages: AsyncStream<HookMessage>

    private let continuation: AsyncStream<HookMessage>.Continuation
    private let queue = DispatchQueue(label: "heed.hooks")
    private var listener: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var clients: [Int32: (DispatchSourceRead, Data)] = [:]

    public init(path: String = HeedEnvironment.defaultSocketPath()) {
        self.path = path
        (messages, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(1024))
    }

    deinit { stop() }

    /// Binds the socket, replacing a stale one left by a crash. Throws when another Heed is already listening.
    public func start() throws {
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: path) {
            if Self.isListening(path) { throw HookServerError.alreadyRunning(path) }
            unlink(path)
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HookServerError.system("socket", errno) }
        var address = Self.address(path)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_un>.size)
            ) }
        }
        guard bound == 0 else {
            close(fd)
            throw HookServerError.system("bind", errno)
        }
        chmod(path, 0o600)
        guard listen(fd, 64) == 0 else {
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
            for (fd, client) in clients {
                client.0.cancel()
                close(fd)
            }
            clients = [:]
            if listener >= 0 {
                close(listener)
                unlink(path)
                listener = -1
            }
        }
        continuation.finish()
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
            // EOF or error: deliver a final unterminated line, then drop the client.
            if let rest = clients[fd]?.1, !rest.isEmpty { deliver(rest) }
            clients[fd]?.0.cancel()
            clients[fd] = nil
            close(fd)
            return
        }
        pending.append(contentsOf: buffer[0 ..< count])
        while let newline = pending.firstIndex(of: 0x0A) {
            deliver(pending[pending.startIndex ..< newline])
            pending.removeSubrange(pending.startIndex ... newline)
        }
        clients[fd]?.1 = pending
    }

    private func deliver(_ line: Data) {
        guard !line.isEmpty, let message = try? HookMessage.decode(line: Data(line)) else { return }
        continuation.yield(message)
    }

    static func address(_ path: String) -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            let bytes = Array(path.utf8.prefix(buffer.count - 1))
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// True when something accepts connections at `path`.
    static func isListening(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var address = address(path)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}

public enum HookServerError: Error, CustomStringConvertible {
    case alreadyRunning(String)
    case system(String, Int32)

    public var description: String {
        switch self {
        case let .alreadyRunning(path): "another Heed is listening on \(path)"
        case let .system(call, code): "\(call) failed: \(String(cString: strerror(code)))"
        }
    }
}
