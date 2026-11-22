import Foundation
import os

/// Heed's own record of what it was doing, for when it goes away without a crash report.
///
/// One line per event in `~/Library/Application Support/Heed/heed.log` (and the unified log, subsystem
/// `build.heed.app`, so `log stream --predicate 'subsystem == "build.heed.app"'` sees the same lines). The file rolls
/// over to `heed.log.1` at `maxBytes`, so it never grows past about twice that. Writes happen on a private queue, never
/// on the caller's.
public final class RunLog: @unchecked Sendable {
    public enum Level: String, Sendable { case info = "INFO", warn = "WARN", error = "ERROR" }

    public static let subsystem = "build.heed.app"
    /// The app's log. Nil (a no-op) until `open(directory:)`, so tests and fixtures never write one.
    public nonisolated(unsafe) static var shared: RunLog?

    public let file: URL
    private let maxBytes: Int
    private let now: @Sendable () -> Date
    private let queue = DispatchQueue(label: "build.heed.runlog", qos: .utility)
    private let logger = Logger(subsystem: RunLog.subsystem, category: "run")
    private let pid = ProcessInfo.processInfo.processIdentifier

    public init(directory: URL, maxBytes: Int = 512 * 1024, now: @escaping @Sendable () -> Date = { Date() }) {
        file = directory.appendingPathComponent("heed.log")
        self.maxBytes = maxBytes
        self.now = now
    }

    public static func defaultDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed", isDirectory: true)
    }

    @discardableResult
    public static func open(directory: URL = defaultDirectory()) -> RunLog {
        let log = RunLog(directory: directory)
        shared = log
        return log
    }

    public static func info(_ message: @autoclosure () -> String) { shared?.write(.info, message()) }
    public static func warn(_ message: @autoclosure () -> String) { shared?.write(.warn, message()) }
    public static func error(_ message: @autoclosure () -> String) { shared?.write(.error, message()) }

    public func write(_ level: Level, _ message: String) {
        let stamp = now()
        switch level {
        case .info: logger.info("\(message, privacy: .public)")
        case .warn: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }
        let line = "\(Self.format(stamp)) \(pid) \(level.rawValue) \(message)\n"
        queue.async { self.append(line) }
    }

    /// Blocks until what was written so far is on disk: before a quit, and in tests.
    public func drain() { queue.sync {} }

    public static func format(_ date: Date) -> String {
        date.formatted(.iso8601.year().month().day().dateSeparator(.dash).time(includingFractionalSeconds: true)
            .timeSeparator(.colon).timeZone(separator: .omitted))
    }

    private func append(_ line: String) {
        let fileManager = FileManager.default
        do {
            try fileManager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fileManager.attributesOfItem(atPath: file.path)[.size]) as? Int, size >= maxBytes {
                let older = file.appendingPathExtension("1")
                try? fileManager.removeItem(at: older)
                try fileManager.moveItem(at: file, to: older)
            }
            if !fileManager.fileExists(atPath: file.path) { fileManager.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
        } catch {
            let path = file.path
            let reason = error.localizedDescription
            logger.error("could not write \(path, privacy: .public): \(reason, privacy: .public)")
        }
    }
}
