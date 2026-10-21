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
    /// `ssh` was given, rather than defaulting to the name: over the tailnet it stays the destination (an alias whose
    /// User and IdentityFile apply), pointed at the machine.
    public var explicitSSH: Bool
    /// The tailnet machine it is (`tailscale = "devbox"`); nil matches one by its ssh alias or name.
    public var tailscale: String?
    /// How heed gets there; nil prefers the tailnet whenever the machine is on it.
    public var transport: HostTransport?
    /// Who to log in as over the tailnet when there is no ssh alias saying so.
    public var user: String?

    public init(
        name: String, ssh: String? = nil, repoRoots: [String] = ["~/code"], worktreeRoot: String = "~/code/wt",
        color: String? = nil, tailscale: String? = nil, transport: HostTransport? = nil, user: String? = nil
    ) {
        self.name = name
        self.ssh = ssh ?? name
        explicitSSH = ssh != nil
        self.repoRoots = repoRoots
        self.worktreeRoot = worktreeRoot
        self.color = color
        self.tailscale = tailscale
        self.transport = transport
        self.user = user
    }
}

/// `[hosts.x] transport`: over the tailnet, or plain ssh even when the machine is on it.
public enum HostTransport: String, Hashable, Sendable, CaseIterable {
    case ssh
    case tailscale
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
    /// The host goes over the tailnet, and Tailscale stands in the way.
    case tailscale(TailscaleIssue)

    public var isConnected: Bool { if case .connected = self { true } else { false } }
}

/// What Tailscale needs before heed can reach a host over the tailnet.
public enum TailscaleIssue: Hashable, Sendable {
    /// No Tailscale on this Mac.
    case notInstalled
    /// Tailscale is off (stopped, or the app is not running).
    case off
    /// Signed out: the URL that signs in, when Tailscale has one.
    case needsLogin(String?)
    /// Tailscale SSH in check mode wants you to confirm who you are, at this URL, before it lets ssh in.
    case checkAuth(String)

    /// The page that resolves it, if there is one.
    public var url: String? {
        switch self {
        case let .needsLogin(url): url
        case let .checkAuth(url): url
        case .notInstalled, .off: nil
        }
    }
}

/// A host's answers to the checks: how fast, and what it has.
public struct HostInfo: Hashable, Sendable {
    public var latency: Duration
    public var platform: String
    public var git: String?
    public var zmx: String?
    public var agents: [String]
    public var checkedAt: Date
    /// The login's home on the host: where `~/.heed` is, for paths an agent is given.
    public var home: String?
    /// Where zmx is on the host (a non-login ssh may not have ~/.local/bin on its PATH, so heed looks there too).
    public var zmxPath: String?
    /// `/etc/os-release` ID (`ubuntu`, `alpine`, `nixos`), for install instructions.
    public var os: String?
    /// Over the tailnet: how traffic goes (direct, through a relay). Nil over plain ssh.
    public var link: TailnetLink?

    public init(
        latency: Duration, platform: String, git: String?, zmx: String?, agents: [String], checkedAt: Date = Date(),
        home: String? = nil, zmxPath: String? = nil, os: String? = nil, link: TailnetLink? = nil
    ) {
        self.link = link
        self.home = home
        self.zmxPath = zmxPath
        self.os = os
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

    /// `24 ms`, or over the tailnet `direct · 12 ms`, `via relay fra · 48 ms`.
    public var linkSummary: String {
        (link.map { "\($0.label) · " } ?? "") + "\(latencyMilliseconds) ms"
    }
}

/// The checks heed runs on a host, in one round trip.
public enum HostProbe {
    public static let agents = ["claude", "codex", "cursor-agent", "pi", "opencode", "gemini"]

    /// A POSIX sh script that prints `key=value` lines heed reads back.
    public static let script = """
    echo "platform=$(uname -sm)"
    echo "home=$HOME"
    echo "git=$(git --version 2>/dev/null | awk '{print $3}')"
    # Only where it exists: `.` on a missing file ends a POSIX sh, and macOS has none.
    [ -r /etc/os-release ] && . /etc/os-release; echo "os=${ID:-}"
    z="$(command -v zmx 2>/dev/null)"
    for c in "$HOME/.local/bin/zmx" "$HOME/bin/zmx" "$HOME/.nix-profile/bin/zmx" /usr/local/bin/zmx /opt/homebrew/bin/zmx; do
      [ -n "$z" ] || { [ -x "$c" ] && z="$c"; }
    done
    [ -n "$z" ] && echo "zmxpath=$z" && echo "zmx=$("$z" version 2>/dev/null | awk '/^zmx/{print $2}')"
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
            checkedAt: now, home: nonEmpty("home"), zmxPath: nonEmpty("zmxpath"), os: nonEmpty("os")
        )
    }

    /// The URL Tailscale SSH's check mode prints ("To authenticate, visit: https://login.tailscale.com/…") and waits
    /// on; nil when it did not.
    public static func checkAuthURL(in text: String) -> String? {
        guard let marker = text.range(of: "To authenticate, visit:") else { return nil }
        let rest = text[marker.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        let url = rest.prefix { !$0.isWhitespace }
        return url.hasPrefix("https://") ? String(url) : nil
    }

    /// What a failed ssh call means, from its exit and what it said.
    public static func failure(status: Int32, stderr: String, lastSeen: Date?) -> HostStatus {
        if let url = checkAuthURL(in: stderr) { return .tailscale(.checkAuth(url)) }
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
        let result: ProcessResult
        do {
            result = try await ProcessRunner.run(on: .host(host), "sh", ["-c", script], timeout: .seconds(15))
        } catch {
            // Tailscale SSH's check mode prints where to confirm and waits, so the call times out.
            if let url = (error as? ProcessError)?.result.flatMap({ checkAuthURL(in: $0.stderr) }) {
                return .tailscale(.checkAuth(url))
            }
            return .offline(reason: "ssh did not answer", lastSeen: lastSeen)
        }
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
