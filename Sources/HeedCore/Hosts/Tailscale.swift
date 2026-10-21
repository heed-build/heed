import Foundation
import Synchronization

/// Your tailnet as `tailscale status --json` describes it: whether Tailscale is up, and the machines on it.
public struct Tailnet: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// No tailscale CLI on this Mac (neither on the search path nor in the app).
        case notInstalled
        /// Stopped, or the app is not running: "Tailscale is off".
        case off
        /// Signed out; the URL that signs in, when Tailscale has one.
        case needsLogin(authURL: String?)
        case starting
        case running
    }

    public var state: State
    /// `example-tailnet.ts.net`, without the trailing dot.
    public var name: String?
    /// Whether MagicDNS names resolve (`devbox.example-tailnet.ts.net`); without it heed connects to the address.
    public var magicDNS: Bool
    /// The other machines on the tailnet, by name.
    public var machines: [TailnetMachine]
    /// Tailscale's own warnings (`Health`).
    public var health: [String]

    public init(
        state: State, name: String? = nil, magicDNS: Bool = true, machines: [TailnetMachine] = [],
        health: [String] = []
    ) {
        self.state = state
        self.name = name
        self.magicDNS = magicDNS
        self.machines = machines
        self.health = health
    }

    public var isRunning: Bool { state == .running }

    /// The machine called `name`: its machine name (the first label of its DNS name), its hostname, its full DNS name
    /// or one of its addresses, ignoring case.
    public func machine(named name: String) -> TailnetMachine? {
        let wanted = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !wanted.isEmpty else { return nil }
        return machines.first { $0.name.lowercased() == wanted }
            ?? machines.first { $0.hostName.lowercased() == wanted || $0.dnsName.lowercased() == wanted }
            ?? machines.first { $0.addresses.contains(wanted) }
    }
}

/// A machine on the tailnet.
public struct TailnetMachine: Hashable, Sendable, Identifiable {
    /// The machine name: the first label of its DNS name (`devbox`).
    public var name: String
    /// What the machine calls itself (`HostName`), which may differ from its machine name.
    public var hostName: String
    /// `devbox.example-tailnet.ts.net`, without the trailing dot.
    public var dnsName: String
    /// Its tailnet addresses (`100.64.0.7`, `fd7a:115c:a1e0::7`).
    public var addresses: [String]
    /// `linux`, `macOS`, `windows`.
    public var os: String
    public var online: Bool
    public var lastSeen: Date?
    /// How traffic to it goes now; nil when there has been none lately.
    public var link: TailnetLink?
    /// The host keys Tailscale SSH serves there; empty when the machine does not run Tailscale SSH.
    public var hostKeys: [String]

    public init(
        name: String, hostName: String? = nil, dnsName: String, addresses: [String] = [], os: String = "linux",
        online: Bool = true, lastSeen: Date? = nil, link: TailnetLink? = nil, hostKeys: [String] = []
    ) {
        self.name = name
        self.hostName = hostName ?? name
        self.dnsName = dnsName
        self.addresses = addresses
        self.os = os
        self.online = online
        self.lastSeen = lastSeen
        self.link = link
        self.hostKeys = hostKeys
    }

    public var id: String { dnsName }

    /// Runs Tailscale SSH: it logs you in with your tailnet identity, no key of yours needed.
    public var hasTailscaleSSH: Bool { !hostKeys.isEmpty }

    /// What ssh connects to: the DNS name with its trailing dot, the name Tailscale's known_hosts lines carry, or the
    /// first address when MagicDNS is off.
    public func address(magicDNS: Bool) -> String {
        magicDNS || addresses.isEmpty ? dnsName + "." : addresses[0]
    }
}

/// How traffic to a tailnet machine travels.
public enum TailnetLink: Hashable, Sendable {
    /// Straight to it, no relay.
    case direct
    /// Through Tailscale's DERP relay in `region` (`fra`, `nyc`).
    case relay(String)
    /// Through another machine of yours acting as a peer relay.
    case peerRelay

    /// `direct`, `via relay fra`, `via peer relay`.
    public var label: String {
        switch self {
        case .direct: "direct"
        case let .relay(region): "via relay \(region)"
        case .peerRelay: "via peer relay"
        }
    }
}

/// `tailscale status --json`, projected into a `Tailnet`.
public enum TailscaleStatus {
    private struct Status: Decodable {
        var BackendState: String?
        var AuthURL: String?
        var MagicDNSSuffix: String?
        var CurrentTailnet: CurrentTailnet?
        var Peer: [String: Peer]?
        var Health: [String]?
    }

    private struct CurrentTailnet: Decodable {
        var Name: String?
        var MagicDNSSuffix: String?
        var MagicDNSEnabled: Bool?
    }

    private struct Peer: Decodable {
        var HostName: String?
        var DNSName: String?
        var TailscaleIPs: [String]?
        var OS: String?
        var Online: Bool?
        var LastSeen: String?
        var Active: Bool?
        var CurAddr: String?
        var Relay: String?
        var PeerRelay: String?
        var sshHostKeys: [String]?
    }

    /// The tailnet in `json`; nil when it is not status output.
    public static func parse(_ json: Data) -> Tailnet? {
        guard let status = try? JSONDecoder().decode(Status.self, from: json), let backend = status.BackendState
        else { return nil }
        let state: Tailnet.State = switch backend {
        case "Running": .running
        case "NeedsLogin", "NeedsMachineAuth": .needsLogin(authURL: status.AuthURL.flatMap { $0.isEmpty ? nil : $0 })
        case "Starting": .starting
        default: .off
        }
        let dates = ISO8601DateFormatter()
        let machines = (status.Peer ?? [:]).values.compactMap { peer -> TailnetMachine? in
            let dnsName = (peer.DNSName ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !dnsName.isEmpty else { return nil }
            let name = String(dnsName.split(separator: ".").first ?? Substring(dnsName))
            // Go's zero time (0001-01-01) means never.
            let seen = peer.LastSeen.flatMap { dates.date(from: $0) }
                .flatMap { $0.timeIntervalSince1970 > 0 ? $0 : nil }
            return TailnetMachine(
                name: name, hostName: peer.HostName, dnsName: dnsName, addresses: peer.TailscaleIPs ?? [],
                os: peer.OS ?? "", online: peer.Online ?? false, lastSeen: seen,
                link: link(curAddr: peer.CurAddr, relay: peer.Relay, peerRelay: peer.PeerRelay, active: peer.Active),
                hostKeys: (peer.sshHostKeys ?? []).map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty && !$0.contains(where: \.isNewline) }
            )
        }
        .sorted { $0.name.lowercased() < $1.name.lowercased() }
        let suffix = status.CurrentTailnet?.MagicDNSSuffix ?? status.MagicDNSSuffix
        return Tailnet(
            state: state, name: suffix.flatMap { $0.isEmpty ? nil : $0.trimmingCharacters(in: [".", " "]) },
            magicDNS: status.CurrentTailnet?.MagicDNSEnabled ?? true, machines: machines, health: status.Health ?? []
        )
    }

    /// A current address means a direct path; otherwise a peer relay, else the DERP region. None while idle.
    static func link(curAddr: String?, relay: String?, peerRelay: String?, active: Bool?) -> TailnetLink? {
        if let curAddr, !curAddr.isEmpty { return .direct }
        if let peerRelay, !peerRelay.isEmpty { return .peerRelay }
        if active == true, let relay, !relay.isEmpty { return .relay(relay) }
        return nil
    }

    /// The known_hosts text `tailscale ssh` writes: for each Tailscale SSH host key of each machine, a line for its DNS
    /// name (with the trailing dot) and one for each of its addresses.
    public static func knownHosts(_ tailnet: Tailnet) -> String {
        var text = ""
        for machine in tailnet.machines.sorted(by: { $0.dnsName < $1.dnsName }) {
            for key in machine.hostKeys {
                text += "\(machine.dnsName). \(key)\n"
                for address in machine.addresses {
                    text += "\(address) \(key)\n"
                }
            }
        }
        return text
    }
}

/// The tailscale CLI: found on the search path or in the Mac app (a GUI app's PATH has neither), asked for its status
/// with a short timeout, the answer kept for a few seconds so every host's check shares one call.
public actor TailscaleCLI {
    public static let shared = TailscaleCLI()

    /// Where the CLI usually is: the standalone install, Homebrew, and the Mac app's own binary, which works as one.
    public static let knownPaths = [
        "/usr/local/bin/tailscale", "/opt/homebrew/bin/tailscale",
        "/Applications/Tailscale.app/Contents/MacOS/Tailscale",
    ]

    /// How to get it, for "not installed".
    public static let install = ["brew install --cask tailscale", "or the Mac app from tailscale.com/download"]

    private var cached: (at: ContinuousClock.Instant, tailnet: Tailnet)?
    private var configured = ""

    /// `[tools] tailscale` (a path or a name on the search path), else the search path, else the usual places.
    public static func locate(_ configured: String, searchPath: [String]) -> String? {
        let wanted = configured.trimmingCharacters(in: .whitespaces)
        if !wanted.isEmpty { return ToolDetection.find(wanted, in: searchPath) }
        return ToolDetection.find("tailscale", in: searchPath)
            ?? knownPaths.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public func configure(_ tool: String) {
        if tool != configured { cached = nil }
        configured = tool
    }

    /// The tailnet, at most ten seconds old unless `fresh`.
    public func status(fresh: Bool = false) async -> Tailnet {
        let clock = ContinuousClock()
        if !fresh, let cached, clock.now - cached.at < .seconds(10) { return cached.tailnet }
        let searchPath = await ToolLocator.shared.report().searchPath
        let tailnet: Tailnet
        if let binary = Self.locate(configured, searchPath: searchPath) {
            let result = try? await ProcessRunner.run(binary, ["status", "--json"], timeout: .seconds(5))
            // A daemon that is not running (the app quit) answers with an error and no JSON: that is "off" too.
            tailnet = result.flatMap { TailscaleStatus.parse(Data($0.stdout.utf8)) } ?? Tailnet(state: .off)
        } else {
            tailnet = Tailnet(state: .notInstalled)
        }
        cached = (clock.now, tailnet)
        return tailnet
    }
}

/// How heed reaches a host: what ssh connects to, and the options that go with it.
public struct HostRoute: Hashable, Sendable {
    public var destination: String
    public var options: [String]
    /// The tailnet machine it goes to; nil over plain ssh.
    public var machine: TailnetMachine?

    public init(destination: String, options: [String] = [], machine: TailnetMachine? = nil) {
        self.destination = destination
        self.options = options
        self.machine = machine
    }
}

/// Which hosts go over the tailnet, and how: any host whose machine is on it, unless it says `transport = "ssh"`.
public enum HostRoutes {
    /// `~/Library/Application Support/Heed/tailscale_known_hosts`: Tailscale SSH's host keys, rewritten from the
    /// tailnet's status when they change.
    public static func knownHostsFile() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/tailscale_known_hosts").path
    }

    /// The tailnet machine `host` is: the one it names with `tailscale`, else the one its ssh alias or name matches.
    public static func machine(for host: HostConfig, in tailnet: Tailnet) -> TailnetMachine? {
        guard host.transport != .ssh, tailnet.isRunning else { return nil }
        if let named = host.tailscale { return tailnet.machine(named: named) }
        let address = host.ssh.split(separator: "@").last.map(String.init) ?? host.ssh
        return tailnet.machine(named: address) ?? tailnet.machine(named: host.name)
    }

    /// How heed reaches `host`. Over the tailnet: your ssh alias when you gave one (so `~/.ssh/config`'s User and
    /// IdentityFile still apply) pointed at the machine's MagicDNS name, else `user@` that name. A machine running
    /// Tailscale SSH is checked against its tailnet host keys the way `tailscale ssh` does it; one without uses your
    /// keys and known_hosts as before. No ProxyCommand: on macOS MagicDNS resolves for every process.
    public static func route(for host: HostConfig, tailnet: Tailnet?, knownHostsFile: String = knownHostsFile())
        -> HostRoute
    {
        guard let tailnet, let machine = machine(for: host, in: tailnet) else {
            // Named for the tailnet but it is not up: the machine name, which ssh cannot reach until it is.
            let fallback = host.explicitSSH || host.tailscale == nil ? host.ssh : host.tailscale ?? host.ssh
            return HostRoute(destination: host.user.map { "\($0)@\(fallback)" } ?? fallback)
        }
        let address = machine.address(magicDNS: tailnet.magicDNS)
        var options: [String] = []
        let destination: String
        if host.explicitSSH {
            destination = host.ssh
            options += ["-o", "HostName=\(address)"]
            if let user = host.user { options += ["-o", "User=\(user)"] }
        } else {
            destination = host.user.map { "\($0)@\(address)" } ?? address
        }
        // A jump host from ~/.ssh/config is for the way there without the tailnet.
        options += ["-o", "ProxyJump=none", "-o", "ProxyCommand=none"]
        if machine.hasTailscaleSSH {
            options += [
                "-o", "UserKnownHostsFile=\(knownHostsFile)", "-o", "UpdateHostKeys=no",
                "-o", "StrictHostKeyChecking=yes", "-o", "CanonicalizeHostname=no",
            ]
        } else {
            // Your own known_hosts: the key you accepted is filed under the name you connected with (the alias, or the
            // machine's name without MagicDNS's trailing dot), not the address the tailnet route goes to.
            let alias = host.explicitSSH ? Self.hostPart(host.ssh) : machine.dnsName
            options += ["-o", "HostKeyAlias=\(alias)"]
        }
        return HostRoute(destination: destination, options: options, machine: machine)
    }

    /// `user@host` or `host`: the host.
    static func hostPart(_ destination: String) -> String {
        destination.split(separator: "@").last.map(String.init) ?? destination
    }

    /// Every host's route.
    public static func plan(_ hosts: [String: HostConfig], tailnet: Tailnet?, knownHostsFile: String = knownHostsFile())
        -> [String: HostRoute]
    {
        hosts.mapValues { route(for: $0, tailnet: tailnet, knownHostsFile: knownHostsFile) }
    }

    /// Writes the known_hosts file when its text changed.
    public static func writeKnownHosts(_ tailnet: Tailnet, to path: String = knownHostsFile()) {
        let text = TailscaleStatus.knownHosts(tailnet)
        guard (try? String(contentsOfFile: path, encoding: .utf8)) != text else { return }
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? Data(text.utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
    }

    /// What stops heed from reaching a host that has to go over the tailnet, before any ssh: Tailscale is not
    /// installed, off or signed out, or the machine is offline. Nil when it can be tried (or is not a tailnet host).
    public static func blocker(for host: HostConfig, tailnet: Tailnet?, lastSeen: Date?) -> HostStatus? {
        guard host.transport != .ssh, let tailnet else { return nil }
        let required = host.tailscale != nil || host.transport == .tailscale
        switch tailnet.state {
        case .running:
            guard let machine = machine(for: host, in: tailnet) else {
                return required ? .offline(reason: "not on your tailnet", lastSeen: lastSeen) : nil
            }
            return machine.online ? nil : .offline(
                reason: "offline on your tailnet",
                lastSeen: [machine.lastSeen, lastSeen].compactMap(\.self).max()
            )
        case .notInstalled: return required ? .tailscale(.notInstalled) : nil
        case .off, .starting: return required ? .tailscale(.off) : nil
        case let .needsLogin(url): return required ? .tailscale(.needsLogin(url)) : nil
        }
    }
}
