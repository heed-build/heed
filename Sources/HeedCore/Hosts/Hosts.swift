import Foundation

/// A machine heed drives over ssh, as `[hosts.<name>]` describes it.
public struct HostConfig: Hashable, Sendable {
    public var name: String
    /// What ssh connects to: an alias from ~/.ssh/config or `user@address`; the name by default.
    public var ssh: String
    /// Where repos are looked for on the host, two levels deep.
    public var repoRoots: [String]
    /// Where heed puts the worktrees it makes there.
    public var worktreeRoot: String
    /// One of the host colours (teal, periwinkle, pink, sky); nil picks one from the name.
    public var color: String?

    public init(
        name: String, ssh: String? = nil, repoRoots: [String] = ["~/code"], worktreeRoot: String = "~/code/wt",
        color: String? = nil
    ) {
        self.name = name
        self.ssh = ssh ?? name
        self.repoRoots = repoRoots
        self.worktreeRoot = worktreeRoot
        self.color = color
    }
}

/// The hosts named in ~/.ssh/config, for adding one without typing it.
public enum SSHConfig {
    public struct Entry: Hashable, Sendable {
        public let alias: String
        public var hostName: String?
        public var user: String?
        public var proxyJump: String?

        /// `martijn@devbox.lan`, `via bastion`, or the alias.
        public var summary: String {
            if let proxyJump { return "via \(proxyJump)" }
            let address = hostName ?? alias
            return user.map { "\($0)@\(address)" } ?? address
        }
    }

    /// Named `Host` entries (patterns like `*` or `*.internal` are not hosts), in file order, with what they set.
    public static func entries(_ text: String) -> [Entry] {
        var entries: [Entry] = []
        var current: [Int] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            guard !line.isEmpty else { continue }
            let parts = line.split(maxSplits: 1, whereSeparator: { $0 == " " || $0 == "\t" || $0 == "=" })
            guard let key = parts.first?.lowercased() else { continue }
            let value = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "host":
                current = []
                for alias in value.split(separator: " ").map(String.init)
                    where !alias.contains(where: { "*?!".contains($0) }) && !entries
                    .contains(where: { $0.alias == alias })
                {
                    entries.append(Entry(alias: alias))
                    current.append(entries.count - 1)
                }
            case "match":
                current = []
            case "hostname": for index in current {
                    entries[index].hostName = value
                }
            case "user": for index in current {
                    entries[index].user = value
                }
            case "proxyjump": for index in current {
                    entries[index].proxyJump = value
                }
            default: break
            }
        }
        return entries
    }

    public static func defaultFile() -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".ssh/config")
    }
}

/// What heed knows about a host's link: the Add host checks, and the state behind the pane strip and sidebar rail.
public enum HostStatus: Hashable, Sendable {
    case unknown
    case connected(HostInfo)
    /// ssh could not log in without a prompt: your key is locked, or not loaded.
    case needsAuth(String)
    /// The host's key is not the one in known_hosts: blocked until you check it.
    case hostKeyChanged
    /// No known_hosts entry yet: connect once by hand (`ssh <host>`) to accept its key.
    case unknownHostKey
    case offline(reason: String, lastSeen: Date?)

    public var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// A host's answers to the checks: how fast, and what it has.
public struct HostInfo: Hashable, Sendable {
    public var latency: Duration
    public var platform: String
    public var git: String?
    public var zmx: String?
    public var agents: [String]
    public var checkedAt: Date

    public init(
        latency: Duration, platform: String, git: String?, zmx: String?, agents: [String], checkedAt: Date = Date()
    ) {
        self.latency = latency
        self.platform = platform
        self.git = git
        self.zmx = zmx
        self.agents = agents
        self.checkedAt = checkedAt
    }

    public var latencyMilliseconds: Int {
        Int(latency.components.seconds * 1000) + Int(latency.components.attoseconds / 1_000_000_000_000_000)
    }
}

/// The checks heed runs on a host, in one round trip.
public enum HostProbe {
    public static let agents = ["claude", "codex", "cursor-agent", "pi", "opencode", "gemini"]

    /// A POSIX sh script that prints `key=value` lines heed reads back.
    public static let script = """
    echo "platform=$(uname -sm)"
    echo "git=$(git --version 2>/dev/null | awk '{print $3}')"
    z="$HOME/.heed/bin/zmx"; [ -x "$z" ] || z="$(command -v zmx 2>/dev/null)"
    [ -n "$z" ] && echo "zmx=$("$z" version 2>/dev/null | awk '/^zmx/{print $2}')"
    for a in \(agents.joined(separator: " ")); do command -v "$a" >/dev/null 2>&1 && echo "agent=$a"; done
    true
    """

    /// The answers, or nil when the output is not the script's.
    public static func info(fromOutput output: String, latency: Duration, at now: Date = Date()) -> HostInfo? {
        var values: [String: String] = [:]
        var agents: [String] = []
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            if parts[0] == "agent" { agents.append(parts[1]) } else { values[parts[0]] = parts[1] }
        }
        guard let platform = values["platform"] else { return nil }
        func nonEmpty(_ key: String) -> String? { values[key].flatMap { $0.isEmpty ? nil : $0 } }
        return HostInfo(
            latency: latency, platform: platform, git: nonEmpty("git"), zmx: nonEmpty("zmx"), agents: agents,
            checkedAt: now
        )
    }

    /// What a failed ssh call means, from its exit and what it said.
    public static func failure(status: Int32, stderr: String, lastSeen: Date?) -> HostStatus {
        let text = stderr.lowercased()
        if text.contains("remote host identification has changed") { return .hostKeyChanged }
        if text.contains("host key verification failed") || text.contains("no matching host key")
            || text.contains("host key for") && text.contains("not known")
        {
            return .unknownHostKey
        }
        if text.contains("permission denied") || text.contains("too many authentication failures") {
            return .needsAuth(stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "permission denied")
        }
        let reason = stderr.split(whereSeparator: \.isNewline).last.map(String.init) ?? "exit \(status)"
        return .offline(reason: reason, lastSeen: lastSeen)
    }

    /// Runs the checks on `host` over ssh.
    public static func check(_ host: String, lastSeen: Date? = nil) async -> HostStatus {
        let clock = ContinuousClock()
        let start = clock.now
        guard let result = try? await ProcessRunner.run(
            on: .host(host), "sh", ["-c", script], timeout: .seconds(15)
        ) else { return .offline(reason: "ssh did not answer", lastSeen: lastSeen) }
        let latency = clock.now - start
        guard result.succeeded, let info = info(fromOutput: result.stdout, latency: latency) else {
            return failure(status: result.status, stderr: result.stderr, lastSeen: lastSeen)
        }
        return .connected(info)
    }
}

/// Finding repos on a host: `find` under its repo roots, then a record for each checkout.
public enum RemoteScan {
    /// The `find` that lists main checkouts (a `.git` directory, not a worktree's `.git` file) two levels down.
    public static func findArguments(roots: [String]) -> [String] {
        roots + ["-maxdepth", "3", "-name", ".git", "-type", "d", "-prune"]
    }

    /// The checkouts in `find`'s output (each `.git` directory's parent).
    public static func checkouts(fromFind output: String) -> [String] {
        output.split(whereSeparator: \.isNewline).map(String.init)
            .filter { $0.hasSuffix("/.git") }
            .map { String($0.dropLast(5)) }
    }

    public static func scan(_ host: HostConfig) async -> [RepoRecord] {
        let location = Location.host(host.name)
        let output = await (try? ProcessRunner.run(
            on: location, "find", findArguments(roots: host.repoRoots), timeout: .seconds(30)
        ))?.stdout ?? ""
        var records: [RepoRecord] = []
        for path in checkouts(fromFind: output) {
            if let record = await Git.record(at: path, on: location), !records.contains(record) {
                records.append(record)
            }
        }
        return records
    }
}

/// Whether heed manages a worktree. Worktrees on this Mac always are; on a host, one heed made or you registered is,
/// and one a scan found is left alone until you register it.
public enum WorktreeRegistration: String, Sendable {
    case registered
    /// Found on a host by a scan, never touched until registered.
    case discovered
    /// On a host that cannot be reached now: as last seen.
    case stale
    /// Registered, but no longer on its host.
    case missing
}
