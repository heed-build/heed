import Foundation
import Synchronization

/// Where a repo, a worktree or a command lives: this Mac, or a host heed reaches over ssh.
public enum Location: Hashable, Sendable, Codable {
    case local
    /// A host by its name in `[hosts.<name>]` (usually its alias in ~/.ssh/config).
    case host(String)

    public var hostName: String? { if case let .host(name) = self { name } else { nil } }
    public var isLocal: Bool { self == .local }
    /// `@devbox`, or "local".
    public var label: String { hostName.map { "@\($0)" } ?? "local" }
}

/// Running commands on hosts: the system's ssh, with your own config, keys and agent, over one shared connection per
/// host (ControlMaster), so a command costs milliseconds rather than a handshake.
public enum Remote {
    /// Host name to how ssh gets there: `[hosts.x] ssh` (the name itself by default), or the machine on the tailnet.
    /// Set from config and the tailnet's status.
    private static let routes = Mutex<[String: HostRoute]>([:])

    public static func setRoutes(_ map: [String: HostRoute]) { routes.withLock { $0 = map } }

    /// In place of the configured routes, for one task and the tasks it starts: how tests point ssh at a throwaway
    /// host, key and known_hosts without reaching the suites running beside them (`with(targets:extraOptions:)`).
    struct Override {
        var routes: [String: HostRoute]
        /// Extra ssh options for every call.
        var extraOptions: [String]
    }

    @TaskLocal static var override: Override?

    /// Runs `operation` with `targets` (host name to ssh destination) as the only routes and `extraOptions` ahead of
    /// every call's, for this task and the tasks it starts.
    static func with<T>(
        targets: [String: String], extraOptions: [String] = [], isolation: isolated (any Actor)? = #isolation,
        operation: () async throws -> T
    ) async rethrows -> T {
        let override = Override(routes: targets.mapValues { HostRoute(destination: $0) }, extraOptions: extraOptions)
        return try await $override.withValue(override, operation: operation, isolation: isolation)
    }

    public static func route(for host: String) -> HostRoute {
        let route = if let override { override.routes[host] } else { routes.withLock { $0[host] } }
        return route ?? HostRoute(destination: host)
    }

    public static func target(for host: String) -> String { route(for: host).destination }

    /// `~/Library/Caches/Heed/ssh`: the shared connections' sockets (`%C` keeps each path short enough for a socket).
    public static func controlDirectory() -> String {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Heed/ssh").path
    }

    /// ssh's options for heed's own calls: never prompt (a prompt in a background call would hang; needing your key is
    /// reported instead), share one connection, give up on a dead host quickly.
    /// The extra options come first: ssh keeps the first value it sees for an option, so they win; then the host's
    /// route (over the tailnet: its address and Tailscale SSH's known hosts), ahead of `~/.ssh/config`. The control
    /// path is keyed by where ssh actually goes (`%C`), so a tailnet route never reuses a connection made another way.
    public static func options(host: String? = nil, controlDirectory: String = controlDirectory()) -> [String] {
        (override?.extraOptions ?? []) + (host.map { route(for: $0).options } ?? []) + [
            "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=15",
            "-o", "ControlMaster=auto", "-o", "ControlPath=\(controlDirectory)/%C", "-o", "ControlPersist=10m",
        ]
    }

    /// The ssh arguments that run `command` on `host`.
    public static func sshArguments(
        host: String, command: [String], controlDirectory: String = controlDirectory(), target: String? = nil
    ) -> [String] {
        options(host: host, controlDirectory: controlDirectory)
            + [target ?? self.target(for: host), "--", shellLine(command)]
    }

    /// One line for the remote shell, each word quoted, except that a leading `~/` stays the remote home.
    public static func shellLine(_ words: [String]) -> String {
        words.map(word).joined(separator: " ")
    }

    static func word(_ text: String) -> String {
        if text == "~" { return "\"$HOME\"" }
        if text.hasPrefix("~/") { return "\"$HOME\"/" + ShellQuote.quote(String(text.dropFirst(2))) }
        return ShellQuote.quote(text)
    }
}

/// Runs one command on a host in place of ssh: what tests hand `ProcessRunner.$hostRunner` so nothing ever leaves this
/// Mac. `input` is the file a real call would feed to the command's stdin (an upload).
public typealias HostRunner = @Sendable (
    _ host: String, _ executable: String, _ arguments: [String], _ input: URL?
) async throws -> ProcessResult

public extension ProcessRunner {
    /// Set for a task (and the tasks it starts), every command `run(on:)` sends to a host goes here instead of ssh.
    @TaskLocal static var hostRunner: HostRunner?

    /// `run`, on this Mac or on a host over ssh. `input` is fed to the command's stdin (an upload).
    static func run(
        on location: Location, _ executable: String, _ arguments: [String], timeout: Duration = .seconds(30),
        input: URL? = nil, caller: String
    ) async throws -> ProcessResult {
        guard let host = location.hostName else {
            return try await run(executable, arguments, timeout: timeout, input: input, caller: caller)
        }
        if let fake = hostRunner { return try await fake(host, executable, arguments, input) }
        try? FileManager.default.createDirectory(atPath: Remote.controlDirectory(), withIntermediateDirectories: true)
        // Logged as the command on the host, not as the ssh line around it.
        return try await logged(caller: caller, host: host, executable: executable, arguments: arguments) {
            try await execute(
                "ssh", Remote.sshArguments(host: host, command: [executable] + arguments),
                timeout: timeout + .seconds(10), input: input
            )
        }
    }

    /// `output`, on this Mac or on a host over ssh.
    static func output(
        on location: Location, _ executable: String, _ arguments: [String], timeout: Duration = .seconds(30),
        caller: String
    ) async throws -> String {
        let result = try await run(on: location, executable, arguments, timeout: timeout, caller: caller)
        guard result.succeeded else {
            throw ProcessError(
                command: "\(location.label) \(executable) \(arguments.joined(separator: " "))", result: result,
                reason: "exit \(result.status)"
            )
        }
        return result.stdout
    }
}
