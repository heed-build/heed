import Foundation
@testable import HeedCore
import Testing

struct TailscaleTests {
    /// `tailscale status --json`'s shape, with a made-up tailnet.
    static let status = #"""
    {
      "Version": "1.104.2",
      "BackendState": "Running",
      "AuthURL": "",
      "MagicDNSSuffix": "example-tailnet.ts.net",
      "CurrentTailnet": {"Name": "you@example.com", "MagicDNSSuffix": "example-tailnet.ts.net", "MagicDNSEnabled": true},
      "Self": {"HostName": "laptop", "DNSName": "laptop.example-tailnet.ts.net.", "Online": true},
      "Health": [],
      "Peer": {
        "nodekey:aa": {
          "HostName": "devbox", "DNSName": "devbox.example-tailnet.ts.net.",
          "TailscaleIPs": ["100.64.0.7", "fd7a:115c:a1e0::7"], "OS": "linux", "Online": true, "Active": true,
          "CurAddr": "192.0.2.10:41641", "Relay": "fra", "PeerRelay": "",
          "LastSeen": "0001-01-01T00:00:00Z",
          "sshHostKeys": ["ssh-ed25519 AAAAexampleone", " ecdsa-sha2-nistp256 AAAAexampletwo "]
        },
        "nodekey:bb": {
          "HostName": "GPU Box", "DNSName": "gpu-box.example-tailnet.ts.net.", "TailscaleIPs": ["100.64.0.9"],
          "OS": "linux", "Online": true, "Active": true, "CurAddr": "", "Relay": "nyc", "PeerRelay": ""
        },
        "nodekey:cc": {
          "HostName": "build-mini", "DNSName": "build-mini.example-tailnet.ts.net.", "TailscaleIPs": ["100.64.0.12"],
          "OS": "macOS", "Online": false, "Active": false, "CurAddr": "", "Relay": "fra",
          "LastSeen": "2026-10-19T08:00:00Z", "Tags": ["tag:ci"]
        },
        "nodekey:dd": {
          "HostName": "lab", "DNSName": "lab.example-tailnet.ts.net.", "TailscaleIPs": ["100.64.0.4"],
          "OS": "linux", "Online": true, "Active": true, "CurAddr": "", "Relay": "fra", "PeerRelay": "100.64.0.9:40000"
        }
      }
    }
    """#

    static let tailnet = TailscaleStatus.parse(Data(status.utf8))!

    @Test func statusIsReadIntoATailnet() throws {
        let tailnet = Self.tailnet
        #expect(tailnet.state == .running)
        #expect(tailnet.name == "example-tailnet.ts.net")
        #expect(tailnet.machines.map(\.name) == ["build-mini", "devbox", "gpu-box", "lab"])
        let devbox = try #require(tailnet.machine(named: "devbox"))
        #expect(devbox.dnsName == "devbox.example-tailnet.ts.net")
        #expect(devbox.addresses == ["100.64.0.7", "fd7a:115c:a1e0::7"])
        #expect(devbox.hasTailscaleSSH)
        #expect(devbox.hostKeys == ["ssh-ed25519 AAAAexampleone", "ecdsa-sha2-nistp256 AAAAexampletwo"])
        #expect(devbox.link == .direct)
        #expect(devbox.lastSeen == nil)
        #expect(tailnet.machine(named: "gpu-box")?.link == .relay("nyc"))
        #expect(tailnet.machine(named: "gpu-box")?.hasTailscaleSSH == false)
        #expect(tailnet.machine(named: "lab")?.link == .peerRelay)
        let mini = try #require(tailnet.machine(named: "build-mini"))
        #expect(!mini.online)
        #expect(mini.link == nil)
        #expect(mini.os == "macOS")
        #expect(mini.lastSeen != nil)
    }

    @Test func machinesAreFoundByAnyOfTheirNames() {
        let tailnet = Self.tailnet
        #expect(tailnet.machine(named: "DEVBOX")?.name == "devbox")
        #expect(tailnet.machine(named: "GPU Box")?.name == "gpu-box")
        #expect(tailnet.machine(named: "devbox.example-tailnet.ts.net.")?.name == "devbox")
        #expect(tailnet.machine(named: "100.64.0.9")?.name == "gpu-box")
        #expect(tailnet.machine(named: "elsewhere") == nil)
    }

    @Test func otherStatesAndNoPeers() {
        let signedOut = TailscaleStatus.parse(Data(#"""
        {"BackendState": "NeedsLogin", "AuthURL": "https://login.tailscale.com/a/example", "Peer": null}
        """#.utf8))
        #expect(signedOut?.state == .needsLogin(authURL: "https://login.tailscale.com/a/example"))
        #expect(signedOut?.machines.isEmpty == true)
        #expect(TailscaleStatus.parse(Data(#"{"BackendState": "Stopped"}"#.utf8))?.state == .off)
        #expect(TailscaleStatus.parse(Data(#"{"BackendState": "NeedsLogin", "AuthURL": ""}"#.utf8))?
            .state == .needsLogin(authURL: nil))
        #expect(TailscaleStatus.parse(Data("failed to connect to local Tailscale daemon".utf8)) == nil)
    }

    @Test func knownHostsAreWrittenAsTailscaleSSHWritesThem() {
        #expect(TailscaleStatus.knownHosts(Self.tailnet) == """
        devbox.example-tailnet.ts.net. ssh-ed25519 AAAAexampleone
        100.64.0.7 ssh-ed25519 AAAAexampleone
        fd7a:115c:a1e0::7 ssh-ed25519 AAAAexampleone
        devbox.example-tailnet.ts.net. ecdsa-sha2-nistp256 AAAAexampletwo
        100.64.0.7 ecdsa-sha2-nistp256 AAAAexampletwo
        fd7a:115c:a1e0::7 ecdsa-sha2-nistp256 AAAAexampletwo

        """)
    }

    @Test func aHostWithAnSSHAliasKeepsItPointedAtTheMachine() {
        let host = HostConfig(name: "devbox", ssh: "devbox")
        let route = HostRoutes.route(for: host, tailnet: Self.tailnet, knownHostsFile: "/k")
        #expect(route.destination == "devbox")
        #expect(route.machine?.name == "devbox")
        #expect(route.options == [
            "-o", "HostName=devbox.example-tailnet.ts.net.", "-o", "ProxyJump=none", "-o", "ProxyCommand=none",
            "-o", "UserKnownHostsFile=/k", "-o", "UpdateHostKeys=no", "-o", "StrictHostKeyChecking=yes",
            "-o", "CanonicalizeHostname=no",
        ])
        let args = Remote.sshArguments(host: "devbox", command: ["true"], controlDirectory: "/c", target: "devbox")
        #expect(args.contains("ControlPath=/c/%C"))
    }

    @Test func aTailnetHostWithoutAnAliasGoesToItsName() {
        let host = HostConfig(name: "gpu", tailscale: "gpu-box", user: "you")
        let route = HostRoutes.route(for: host, tailnet: Self.tailnet, knownHostsFile: "/k")
        #expect(route.destination == "you@gpu-box.example-tailnet.ts.net.")
        // No Tailscale SSH there: your own keys and known_hosts, no tailnet host keys.
        #expect(route.options == ["-o", "ProxyJump=none", "-o", "ProxyCommand=none"])
    }

    @Test func plainSSHWhenOptedOutOrNotOnTheTailnet() {
        let out = HostConfig(name: "devbox", transport: .ssh)
        #expect(HostRoutes.route(for: out, tailnet: Self.tailnet) == HostRoute(destination: "devbox"))
        let elsewhere = HostConfig(name: "ci", ssh: "ci@10.0.4.9")
        #expect(HostRoutes.route(for: elsewhere, tailnet: Self.tailnet) == HostRoute(destination: "ci@10.0.4.9"))
        let off = Tailnet(state: .off)
        #expect(HostRoutes.route(for: HostConfig(name: "devbox"), tailnet: off) == HostRoute(destination: "devbox"))
        #expect(HostRoutes.route(for: HostConfig(name: "devbox"), tailnet: nil) == HostRoute(destination: "devbox"))
        // MagicDNS off: the address.
        var noDNS = Self.tailnet
        noDNS.magicDNS = false
        #expect(HostRoutes.route(for: HostConfig(name: "x", tailscale: "devbox"), tailnet: noDNS)
            .destination == "100.64.0.7")
    }

    @Test func tailscaleStandsInTheWayOnlyOfHostsThatNeedIt() {
        let named = HostConfig(name: "gpu", tailscale: "gpu-box")
        let matched = HostConfig(name: "devbox")
        #expect(HostRoutes.blocker(for: named, tailnet: Tailnet(state: .off), lastSeen: nil) == .tailscale(.off))
        #expect(HostRoutes.blocker(for: matched, tailnet: Tailnet(state: .off), lastSeen: nil) == nil)
        #expect(HostRoutes.blocker(for: named, tailnet: Tailnet(state: .notInstalled), lastSeen: nil)
            == .tailscale(.notInstalled))
        #expect(HostRoutes.blocker(
            for: named, tailnet: Tailnet(state: .needsLogin(authURL: "https://login.tailscale.com/a/x")), lastSeen: nil
        ) == .tailscale(.needsLogin("https://login.tailscale.com/a/x")))
        #expect(HostRoutes.blocker(for: named, tailnet: Self.tailnet, lastSeen: nil) == nil)
        let mini = HostConfig(name: "mini", tailscale: "build-mini")
        guard case let .offline(reason, seen) = HostRoutes.blocker(for: mini, tailnet: Self.tailnet, lastSeen: nil)
        else {
            Testing.Issue.record("expected offline")
            return
        }
        #expect(reason == "offline on your tailnet")
        #expect(seen != nil)
        #expect(HostRoutes.blocker(for: HostConfig(name: "x", tailscale: "gone"), tailnet: Self.tailnet, lastSeen: nil)
            == .offline(reason: "not on your tailnet", lastSeen: nil))
    }

    @Test func checkModeIsRecognised() {
        let stderr = "# Tailscale SSH requires an additional check.\n# To authenticate, visit: https://login.tailscale.com/a/abc123\n"
        #expect(HostProbe.checkAuthURL(in: stderr) == "https://login.tailscale.com/a/abc123")
        #expect(HostProbe.failure(status: 255, stderr: stderr, lastSeen: nil)
            == .tailscale(.checkAuth("https://login.tailscale.com/a/abc123")))
        #expect(HostProbe.checkAuthURL(in: "Permission denied (publickey).") == nil)
    }

    @Test func theLinkIsSummarised() {
        let info = HostInfo(latency: .milliseconds(48), platform: "Linux", git: nil, zmx: nil, agents: [])
        #expect(info.linkSummary == "48 ms")
        var relayed = info
        relayed.link = .relay("fra")
        #expect(relayed.linkSummary == "via relay fra · 48 ms")
        relayed.link = .direct
        #expect(relayed.linkSummary == "direct · 48 ms")
        relayed.link = .peerRelay
        #expect(relayed.linkSummary == "via peer relay · 48 ms")
    }

    @Test func tailnetSettingsAreReadFromConfig() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [tools]
        tailscale = "/Applications/Tailscale.app/Contents/MacOS/Tailscale"
        [hosts.gpu]
        tailscale = "gpu-box"
        user = "you"
        [hosts.devbox]
        transport = "ssh"
        [hosts.lab]
        transport = "wireguard"
        [hosts.odd]
        tailscale = "two words"
        """)
        let config = try #require(decoded)
        #expect(config.tools.tailscale == "/Applications/Tailscale.app/Contents/MacOS/Tailscale")
        #expect(config.hosts["gpu"]?.tailscale == "gpu-box")
        #expect(config.hosts["gpu"]?.user == "you")
        #expect(config.hosts["gpu"]?.explicitSSH == false)
        #expect(config.hosts["devbox"]?.transport == .ssh)
        #expect(config.hosts["lab"]?.transport == nil)
        #expect(problems.map(\.path).sorted() == ["hosts.lab.transport", "hosts.odd.tailscale"])
    }
}
