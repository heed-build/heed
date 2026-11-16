import Foundation
@testable import HeedCore
import Testing

/// The live checks: heed's protocol code against the real agents, not fakes. They call a model, so they run only with
/// `HEED_LIVE=1` (`mise run live`); `mise run test` and CI skip them. Each works in a throwaway git repo under the
/// temporary directory, uses the cheapest model, and keeps what the agent sent in `HEED_LIVE_CAPTURE` (default
/// `$TMPDIR/heed-live/capture`) so a surprise can be turned into a fixture.
enum Live {
    static var enabled: Bool { ProcessInfo.processInfo.environment["HEED_LIVE"] == "1" }

    /// The model every live check runs on.
    static let model = "haiku"

    static var capture: URL {
        let path = ProcessInfo.processInfo.environment["HEED_LIVE_CAPTURE"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSTemporaryDirectory() as NSString).appendingPathComponent("heed-live/capture")
        let url = URL(fileURLWithPath: path, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func keep(_ name: String, _ text: String) {
        try? text.write(to: capture.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    /// The environment an agent starts with: this process's, without anything that would tie it to the session or app
    /// running the tests (another Claude Code's inbox and session, a heed pane's sockets, telemetry already set up).
    static func cleanEnvironment() -> [String: String] {
        ProcessInfo.processInfo.environment.filter { key, _ in
            !(key.hasPrefix("CLAUDE") || key.hasPrefix("HEED_") || key.hasPrefix("OTEL_") || key.hasPrefix("ANTHROPIC_")
                || key.hasPrefix("ENABLE_ENHANCED"))
        }
    }

    /// A short-pathed scratch folder (unix sockets want short paths), removed by `cleanUp`.
    static func scratch(_ name: String) throws -> URL {
        let url = URL(fileURLWithPath: "/tmp/heed-live-\(name)-\(UUID().uuidString.prefix(6))", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A git repo with one tiny file, committed: no remote, nothing to push to.
    static func repo(in folder: URL, files: [String: String]) async throws -> String {
        let path = folder.appendingPathComponent("repo").path
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for (name, text) in files {
            try text.write(toFile: (path as NSString).appendingPathComponent(name), atomically: true, encoding: .utf8)
        }
        for args in [
            ["init", "-q", "-b", "main"], ["add", "."],
            [
                "-c",
                "user.name=heed",
                "-c",
                "user.email=heed@example.invalid",
                "-c",
                "commit.gpgsign=false",
                "commit",
                "-q",
                "-m",
                "start",
            ],
        ] {
            _ = try await ProcessRunner.output("/usr/bin/git", ["-C", path] + args, caller: "live.repo")
        }
        // Resolved, as the agents report it (/tmp is /private/tmp).
        return URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    }

    /// The built `heed` helper next to the test bundle (`.build/debug/heed`).
    static func heedBinary() throws -> String {
        var url = Bundle.module.bundleURL
        for _ in 0 ..< 4 {
            url = url.deletingLastPathComponent()
            let candidate = url.appendingPathComponent("heed").path
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw LiveError.missing("the heed helper (swift build --product heed)")
    }

    /// `name` on the PATH.
    static func which(_ name: String) throws -> String {
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        for folder in path.split(separator: ":") {
            let candidate = "\(folder)/\(name)"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        throw LiveError.missing(name)
    }

    /// A free TCP port on 127.0.0.1.
    static func freePort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(
                fd,
                $0,
                socklen_t(MemoryLayout<sockaddr_in>.size)
            ) }
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: address.sin_port))
    }

    /// heed's own Claude Code launch, as a pane gets it: the hook settings and session id (`AgentIntegration`), the
    /// telemetry environment when `telemetry` is set, then a one-shot prompt on the cheap model.
    static func claude(
        prompt: String, repo: String, session: String, files: IntegrationFiles, environment: [String: String],
        timeout: Duration = .seconds(180)
    ) async throws -> ProcessResult {
        guard let profile = AgentProfile.builtIn.first(where: { $0.name == "claude" }) else {
            throw LiveError.missing("the claude profile")
        }
        let args = AgentIntegration.launchArguments(agent: profile, sessionID: session, files: files)
            + ["-p", "--model", model, "--permission-mode", "default", prompt]
        var env = environment
        env.merge(AgentIntegration.launchEnvironment(agent: profile, files: files)) { _, launch in launch }
        let result = try await ProcessRunner.run(
            which("claude"), args, in: repo, environment: env, timeout: timeout, caller: "live.claude"
        )
        keep("claude-\(session.prefix(8)).out", result.stdout + "\n--- stderr\n" + result.stderr)
        return result
    }

    /// Waits until `condition` holds or `seconds` pass.
    static func eventually(_ seconds: Double, _ condition: @Sendable () async -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await condition() { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return await condition()
    }
}

enum LiveError: Error, CustomStringConvertible {
    case missing(String)

    var description: String {
        switch self {
        case let .missing(what): "not found: \(what)"
        }
    }
}

/// A thread-safe list, for what servers and streams hand the tests from their own queues.
final class LiveLog<Element: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [Element] = []

    func append(_ item: Element) { lock.withLock { items.append(item) } }
    var all: [Element] { lock.withLock { items } }
}

/// ACP over a real process, with every line each way kept for the capture file.
final class RecordingTransport: ACPTransport, @unchecked Sendable {
    let inner: ACPProcessTransport
    let lines: AsyncStream<String>
    let log = LiveLog<String>()

    init(_ inner: ACPProcessTransport) {
        self.inner = inner
        let (stream, sink) = AsyncStream<String>.makeStream()
        lines = stream
        let log = log
        Task {
            for await line in inner.lines {
                log.append("<- " + line)
                sink.yield(line)
            }
            sink.finish()
        }
    }

    func send(_ line: String) async throws {
        log.append("-> " + line)
        try await inner.send(line)
    }

    func closedReason() async -> String? { await inner.closedReason() }
    func close() async { await inner.close() }
}
