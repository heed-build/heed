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

    public static func setTargets(_ map: [String: String]) { setRoutes(map.mapValues { HostRoute(destination: $0) }) }

    public static func route(for host: String) -> HostRoute {
        routes.withLock { $0[host] } ?? HostRoute(destination: host)
    }

    public static func target(for host: String) -> String { route(for: host).destination }

    /// Extra ssh options for every call (tests point ssh at a throwaway key and known_hosts this way).
    private static let extra = Mutex<[String]>([])
    public static func setExtraOptions(_ options: [String]) { extra.withLock { $0 = options } }

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
        extra.withLock { $0 } + (host.map { route(for: $0).options } ?? []) + [
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

public extension ProcessRunner {
    /// `run`, on this Mac or on a host over ssh. `input` is fed to the command's stdin (an upload).
    static func run(
        on location: Location, _ executable: String, _ arguments: [String], timeout: Duration = .seconds(30),
        input: URL? = nil, caller: String
    ) async throws -> ProcessResult {
        guard let host = location.hostName else {
            return try await run(executable, arguments, timeout: timeout, input: input, caller: caller)
        }
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
