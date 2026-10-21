import Foundation
@testable import HeedCore
import Testing

struct HostsTests {
    @Test func sshCommandsShareAConnectionAndNeverPrompt() {
        let args = Remote.sshArguments(
            host: "devbox", command: ["git", "-C", "~/code/docs-builder", "status"], controlDirectory: "/c",
            target: "martijn@devbox.lan"
        )
        #expect(args.contains("BatchMode=yes"))
        #expect(args.contains("ControlMaster=auto"))
        #expect(args.contains("ControlPath=/c/%C"))
        #expect(args.suffix(3) == ["martijn@devbox.lan", "--", #"git -C "$HOME"/code/docs-builder status"#])
        #expect(Remote.shellLine(["echo", "it's", "~"]) == #"echo 'it'\''s' "$HOME""#)
    }

    @Test func hostsFromSSHConfig() {
        let text = """
        Host *
          ServerAliveInterval 30
        Host devbox
          HostName devbox.lan
          User martijn
        Host gpu gpu-alt
          ProxyJump bastion
        Host *.internal
          User ops
        Match host ci
          User nobody
        Host ci # build runner
          HostName 10.0.4.9
          User ci
        """
        let entries = SSHConfig.entries(text)
        #expect(entries.map(\.alias) == ["devbox", "gpu", "gpu-alt", "ci"])
        #expect(entries[0].summary == "martijn@devbox.lan")
        #expect(entries[1].summary == "via bastion")
        #expect(entries[3].summary == "ci@10.0.4.9")
    }

    @Test func theChecksReadBackAndFailuresAreNamed() {
        let output = "platform=Linux x86_64\nos=ubuntu\nhome=/home/m\nshell=fish\ngit=2.46.0\nzmxpath=/home/m/.local/bin/zmx\nzmx=0.8.1\nagent=claude\nagent=codex\n"
        let info = HostProbe.info(fromOutput: output, latency: .milliseconds(24))
        #expect(info?.platform == "Linux x86_64")
        #expect(info?.git == "2.46.0")
        #expect(info?.zmx == "0.8.1")
        #expect(info?.zmxPath == "/home/m/.local/bin/zmx")
        #expect(info?.os == "ubuntu")
        #expect(info?.home == "/home/m")
        #expect(info?.shell == "fish")
        #expect(info?.agents == ["claude", "codex"])
        #expect(info?.latencyMilliseconds == 24)
        #expect(HostProbe.info(fromOutput: "welcome banner", latency: .zero) == nil)

        let changed = "@@@@@@\n@    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @\n"
        #expect(HostProbe.failure(status: 255, stderr: changed, lastSeen: nil) == .hostKeyChanged)
        #expect(HostProbe
            .failure(status: 255, stderr: "Host key verification failed.", lastSeen: nil) == .unknownHostKey)
        if case .needsAuth = HostProbe.failure(
            status: 255,
            stderr: "martijn@devbox: Permission denied (publickey).",
            lastSeen: nil
        ) {} else {
            Testing.Issue.record("expected needsAuth")
        }
        let seen = Date(timeIntervalSince1970: 1000)
        #expect(HostProbe.failure(
            status: 255,
            stderr: "ssh: connect to host ci port 22: Operation timed out",
            lastSeen: seen
        )
            == .offline(reason: "ssh: connect to host ci port 22: Operation timed out", lastSeen: seen))
    }

    @Test func theScanFindsMainCheckouts() {
        #expect(RemoteScan.findArguments(roots: ["~/code"]).prefix(3) == ["~/code", "-maxdepth", "3"])
        let output = "/home/m/code/docs-builder/.git\n/home/m/code/docs/.git\nfind: '/home/m/src': No such file\n"
        #expect(RemoteScan.checkouts(fromFind: output) == ["/home/m/code/docs-builder", "/home/m/code/docs"])
    }

    @Test func theSameRepoOnTwoMachinesIsTwoRecordsAndListingsStayApart() {
        let repo = Repo(org: "elastic", name: "docs-builder")
        let local = RepoRecord(repo: repo, path: "/Users/m/code/docs-builder")
        let remote = RepoRecord(repo: repo, path: "/home/m/code/docs-builder", location: .host("devbox"))
        #expect(local.id == "elastic/docs-builder")
        #expect(remote.id == "elastic/docs-builder@devbox")
        var domain = Domain()
        domain.apply(.worktreesListed(
            repo: repo,
            [Worktree(repo: repo, path: "/Users/m/code/docs-builder", branch: "main", head: "a", isMain: true)]
        ))
        let there = Worktree(
            repo: repo,
            path: "/home/m/code/wt/flake",
            branch: "flake",
            head: "b",
            isMain: false,
            location: .host("devbox")
        )
        domain.apply(.worktreesListed(repo: repo, [there]))
        #expect(domain.worktrees.count == 2)
        #expect(there.id == "devbox:/home/m/code/wt/flake")
        #expect(domain.registration(of: there) == .discovered)
        #expect(domain.registration(of: there, reachable: false) == .stale)
        domain.apply(.worktreeRegistered(there.id))
        #expect(domain.registration(of: there) == .registered)
        #expect(domain.registration(of: domain.worktrees[0]) == .registered)
    }

    @Test func recordsAndWorktreesCachedBeforeHostsAreLocal() throws {
        let old = #"{"repo":{"org":"o","name":"r"},"path":"/p","branch":"b","head":"h","isMain":false}"#
        #expect(try JSONDecoder().decode(Worktree.self, from: Data(old.utf8)).location == .local)
        let record = #"{"repo":{"org":"o","name":"r"},"path":"/p"}"#
        #expect(try JSONDecoder().decode(RepoRecord.self, from: Data(record.utf8)).location == .local)
    }

    @Test func hostsAreReadFromConfig() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [hosts.devbox]
        repo_roots = ["~/code", "~/src"]
        [hosts.gpu]
        ssh = "me@10.0.0.7"
        worktree_root = "~/runs"
        color = "periwinkle"
        [hosts.ci]
        color = "orange"
        """)
        let config = try #require(decoded)
        #expect(config.hosts["devbox"]?.ssh == "devbox")
        #expect(config.hosts["devbox"]?.repoRoots == ["~/code", "~/src"])
        #expect(config.hosts["gpu"]?.ssh == "me@10.0.0.7")
        #expect(config.hosts["gpu"]?.worktreeRoot == "~/runs")
        #expect(config.hosts["gpu"]?.color == "periwinkle")
        #expect(problems.map(\.path) == ["hosts.ci.color"])
    }
}
