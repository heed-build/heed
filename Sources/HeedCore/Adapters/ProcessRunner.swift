import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    public var succeeded: Bool { status == 0 }
}

public struct ProcessError: Error, Sendable, CustomStringConvertible {
    public let command: String
    public let result: ProcessResult?
    public let reason: String

    public var description: String {
        let detail = result.map { $0.stderr.trimmingCharacters(in: .whitespacesAndNewlines) } ?? ""
        return "\(command): \(reason)\(detail.isEmpty ? "" : " — \(detail)")"
    }
}

/// Runs a command and returns its output, entirely off the calling actor: output is read concurrently (so a full
/// pipe never deadlocks), termination is awaited, never waited on, and a timeout or task cancellation terminates it.
public enum ProcessRunner {
    public static func run(
        _ executable: String, _ arguments: [String], in directory: String? = nil,
        environment: [String: String]? = nil, timeout: Duration = .seconds(30)
    ) async throws -> ProcessResult {
        let command = ([executable] + arguments).joined(separator: " ")
        // A bare name is resolved through tool detection (an app opened from Finder has a minimal PATH) and runs with
        // the detected PATH, so gh finds git and git its helpers. A path runs as given.
        var path = executable
        var variables = environment ?? [:]
        if !executable.contains("/") {
            let found = await ToolLocator.shared.executable(executable)
            guard let resolved = found.path else {
                throw ProcessError(
                    command: command, result: nil,
                    reason: "\(executable) not found (set [tools] \(executable) in config.toml)"
                )
            }
            path = resolved
            if variables["PATH"] == nil { variables["PATH"] = found.pathVariable }
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        if let directory { process.currentDirectoryURL = URL(fileURLWithPath: directory) }
        if !variables.isEmpty {
            process.environment = ProcessInfo.processInfo.environment.merging(variables) { _, new in new }
        }
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let exited = AsyncStream<Int32> { continuation in
            process.terminationHandler = { finished in
                continuation.yield(finished.terminationStatus)
                continuation.finish()
            }
        }
        do {
            try process.run()
        } catch {
            throw ProcessError(command: command, result: nil, reason: "could not start (\(error.localizedDescription))")
        }

        let timedOut = Flag()
        let watchdog = Task.detached {
            try await Task.sleep(for: timeout)
            timedOut.set()
            process.terminate()
        }
        defer { watchdog.cancel() }

        return try await withTaskCancellationHandler {
            async let out = Task.detached { stdout.fileHandleForReading.readDataToEndOfFile() }.value
            async let err = Task.detached { stderr.fileHandleForReading.readDataToEndOfFile() }.value
            var status: Int32 = -1
            for await code in exited {
                status = code
            }
            let result = await ProcessResult(
                status: status,
                stdout: String(decoding: out, as: UTF8.self),
                stderr: String(decoding: err, as: UTF8.self)
            )
            if timedOut.isSet {
                throw ProcessError(command: command, result: result, reason: "timed out after \(timeout)")
            }
            return result
        } onCancel: {
            process.terminate()
        }
    }

    /// Runs and throws unless the command succeeded.
    public static func output(
        _ executable: String, _ arguments: [String], in directory: String? = nil, timeout: Duration = .seconds(30)
    ) async throws -> String {
        let result = try await run(executable, arguments, in: directory, timeout: timeout)
        guard result.succeeded else {
            throw ProcessError(
                command: ([executable] + arguments).joined(separator: " "), result: result,
                reason: "exit \(result.status)"
            )
        }
        return result.stdout
    }
}

/// A one-way flag shared with the watchdog task.
private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}
