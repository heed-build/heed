import Foundation

/// ACP over an agent process's stdio: heed writes a message a line to its stdin and reads its stdout a line at a
/// time. Its stderr is the agent's log: the last lines are kept to say why it ended. Nothing here runs on the main
/// actor: the pipes are read on their own queues.
public final class ACPProcessTransport: ACPTransport, @unchecked Sendable {
    public let lines: AsyncStream<String>
    private let sink: AsyncStream<String>.Continuation
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private let errors = Pipe()
    private let lock = NSLock()
    private var buffer = Data()
    private var errorTail: [String] = []
    private var ended = false
    /// Left when the agent's stderr reaches its end: its output's end waits for that (briefly), so the reason it gives
    /// for ending has the last lines it wrote there. The two pipes are read on their own queues, in no set order.
    private let errorsDone = DispatchGroup()
    private var errorsEnded = false

    /// Starts `executable` with `arguments` in `directory`. Throws when it does not start.
    public init(
        executable: String, arguments: [String], directory: String, environment: [String: String]
    ) throws {
        (lines, sink) = AsyncStream<String>.makeStream()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.currentDirectoryURL = URL(fileURLWithPath: directory)
        process.environment = environment
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.read(data)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            self?.readErrors(data)
        }
        // Normally its output's end finishes the lines; this is for a child that keeps the pipe open after it exits.
        errorsDone.enter()
        process.terminationHandler = { [weak self] _ in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { self?.finish() }
        }
        try process.run()
    }

    public func send(_ line: String) async throws {
        let data = Data((line + "\n").utf8)
        let handle = input.fileHandleForWriting
        guard isRunning else { throw ACPError.closed(currentReason()) }
        try handle.write(contentsOf: data)
    }

    public func closedReason() async -> String? { currentReason() }

    public func close() async {
        try? input.fileHandleForWriting.close()
        if process.isRunning { process.terminate() }
    }

    private var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !ended && process.isRunning
    }

    private func read(_ data: Data) {
        guard !data.isEmpty else {
            // End of file: whatever is left is the last line.
            lock.lock()
            let rest = buffer
            buffer.removeAll()
            lock.unlock()
            if let line = String(data: rest, encoding: .utf8), !line.isEmpty { sink.yield(line) }
            output.fileHandleForReading.readabilityHandler = nil
            let errorsDone = errorsDone
            DispatchQueue.global().async { [weak self] in
                _ = errorsDone.wait(timeout: .now() + 1)
                self?.finish()
            }
            return
        }
        lock.lock()
        buffer.append(data)
        var found: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex ..< newline]
            buffer.removeSubrange(buffer.startIndex ... newline)
            if let text = String(data: line, encoding: .utf8) { found.append(text) }
        }
        lock.unlock()
        for line in found {
            sink.yield(line)
        }
    }

    private func readErrors(_ data: Data) {
        guard !data.isEmpty else {
            errors.fileHandleForReading.readabilityHandler = nil
            lock.lock()
            let first = !errorsEnded
            errorsEnded = true
            lock.unlock()
            if first { errorsDone.leave() }
            return
        }
        guard let text = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        errorTail += text.split(whereSeparator: \.isNewline).map(String.init).filter { !$0.isEmpty }
        if errorTail.count > 20 { errorTail.removeFirst(errorTail.count - 20) }
        lock.unlock()
    }

    private func finish() {
        lock.lock()
        let first = !ended
        ended = true
        lock.unlock()
        if first { sink.finish() }
    }

    private func currentReason() -> String? {
        lock.lock()
        let tail = errorTail.suffix(3).joined(separator: " · ")
        lock.unlock()
        if !tail.isEmpty { return tail }
        if !process.isRunning { return "exit status \(process.terminationStatus)" }
        return nil
    }
}
