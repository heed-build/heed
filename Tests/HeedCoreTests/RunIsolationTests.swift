import Foundation
@testable import HeedCore
import Synchronization
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let ref = PullRef(repo: Repo(org: "acme", name: "widgets"), number: 12)

private func settings(_ arguments: [String]) throws -> [String: Any] {
    let index = try #require(arguments.firstIndex(of: "--settings"))
    return try #require(JSONSerialization.jsonObject(with: Data(arguments[index + 1].utf8)) as? [String: Any])
}

/// Reports come from the run's own folder, written after it started.
struct RunFolderTests {
    @Test func aRunsFolderIsHeedsOwnAndOutsideTheWorktree() {
        #expect(RunFolder.path(run: "r1", root: "/support/Heed/runs/") == "/support/Heed/runs/r1")
        #expect(RunFolder.localRoot().hasSuffix("/Heed/runs"))
        #expect(RunFolder.hostPath(run: "r1") == "~/.heed/runs/r1")
        #expect(RunFolder.ghConfig("/support/runs/r1") == "/support/runs/r1/gh")
        #expect(RunFolder.leftovers(in: "/wt/r") == [
            "/wt/r/.heed/review.json", "/wt/r/.heed/evaluation.json", "/wt/r/.heed/last-message.txt",
        ])
        #expect(RunFolder.hostPrepare("~/.heed/runs/r1") == [
            ["rm", "-rf", "~/.heed/runs/r1"], ["mkdir", "-p", "~/.heed/runs/r1/gh"],
        ])
    }

    @Test func aReportFromBeforeTheRunIsNotRead() throws {
        let folder = NSTemporaryDirectory() + "heed-runfolder-\(UUID().uuidString)"
        defer { RunFolder.remove(folder) }
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: URL(fileURLWithPath: folder + "/stale.json"))
        // Prepared again under the same id: what was there goes.
        try RunFolder.prepare(folder)
        #expect(!FileManager.default.fileExists(atPath: folder + "/stale.json"))
        #expect(FileManager.default.fileExists(atPath: RunFolder.ghConfig(folder)))
        let path = folder + "/review.json"
        try Data(#"{"summary": "x"}"#.utf8).write(to: URL(fileURLWithPath: path))
        let started = Date()
        try FileManager.default.setAttributes(
            [.modificationDate: started.addingTimeInterval(-3600)], ofItemAtPath: path
        )
        #expect(RunFolder.read(path, started: started) == nil)
        try FileManager.default.setAttributes([.modificationDate: started.addingTimeInterval(5)], ofItemAtPath: path)
        #expect(RunFolder.readText(path, started: started) == #"{"summary": "x"}"#)
        #expect(RunFolder.read(folder + "/none.json", started: started) == nil)
        #expect(!RunFolder.isFresh(modified: nil, started: started))
        #expect(RunFolder.isFresh(modified: started.addingTimeInterval(-0.5), started: started))
    }
}

struct RunSandboxTests {
    /// What `words` followed by `/usr/bin/env` print when started with exactly `environment`: the run's environment.
    private func runEnvironment(_ words: [String], _ environment: [String: String]) throws -> [String: String] {
        try printed(words[0], Array(words.dropFirst()) + ["/usr/bin/env"], environment)
    }

    private func printed(_ executable: String, _ arguments: [String], _ environment: [String: String]) throws
        -> [String: String]
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        let out = Pipe()
        process.standardOutput = out
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        var printed: [String: String] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let equals = line.firstIndex(of: "=") else { continue }
            printed[String(line[..<equals])] = String(line[line.index(after: equals)...])
        }
        return printed
    }

    /// What a shell config could export besides the basics: logins of all kinds and other agents' keys. `USER` is the
    /// account's, as fish sets it however it started.
    private let shell: [String: String] = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/me", "USER": NSUserName(), "LOGNAME": "me", "SHELL": "/bin/zsh",
        "TMPDIR": "/tmp/me", "TERM": "xterm-ghostty", "LANG": "en_US.UTF-8", "LC_ALL": "C",
        "HEED_SESSION_ID": "s1", "HEED_PANE_ID": "p1", "HEED_SESSION_TOKEN": "t1",
        "ANTHROPIC_API_KEY": "sk-ant", "CLAUDE_CODE_OAUTH_TOKEN": "oauth", "OPENAI_API_KEY": "sk-openai",
        "CODEX_HOME": "/Users/me/.codex", "GEMINI_API_KEY": "g", "FOO_KEY": "f", "DATABASE_URL": "postgres://x",
        "KUBECONFIG": "/k", "GIT_ASKPASS": "/a", "SSH_ASKPASS": "/a", "SSH_AUTH_SOCK": "/s", "GH_TOKEN": "gh",
        "AWS_PROFILE": "prod", "NPM_TOKEN": "n", "MY_SERVICE_TOKEN": "m", "HEED_PROMPT": "p",
    ]

    private let base: [String: String] = [
        "PATH": "/usr/bin:/bin", "HOME": "/Users/me", "USER": NSUserName(), "LOGNAME": "me", "SHELL": "/bin/zsh",
        "TMPDIR": "/tmp/me", "TERM": "xterm-ghostty", "LANG": "en_US.UTF-8", "LC_ALL": "C",
        "HEED_SESSION_ID": "s1", "HEED_PANE_ID": "p1", "HEED_SESSION_TOKEN": "t1",
        "GH_CONFIG_DIR": "/runs/1/gh", "GIT_TERMINAL_PROMPT": "0",
    ]

    @Test func aClaudeRunStartsEmptyAndGetsBackOnlyWhatItNeeds() throws {
        let got = try runEnvironment(RunSandbox.environment(agent: "claude", folder: "/runs/1"), shell)
        #expect(got == base.merging(["ANTHROPIC_API_KEY": "sk-ant", "CLAUDE_CODE_OAUTH_TOKEN": "oauth"]) { $1 })
        #expect(got["FOO_KEY"] == nil && got["DATABASE_URL"] == nil && got["OPENAI_API_KEY"] == nil)
    }

    @Test func aCodexRunGetsCodexsOwnKeyAndNotClaudes() throws {
        let got = try runEnvironment(RunSandbox.environment(agent: "codex", folder: "/runs/1"), shell)
        #expect(got == base.merging(["OPENAI_API_KEY": "sk-openai", "CODEX_HOME": "/Users/me/.codex"]) { $1 })
    }

    @Test func theCloudClaudeRunsOnStaysOnlyWhenItIsOn() throws {
        let words = RunSandbox.environment(agent: "claude", folder: "/runs/1")
        #expect(try runEnvironment(words, shell)["AWS_PROFILE"] == nil)
        let bedrock = try runEnvironment(words, shell.merging(["CLAUDE_CODE_USE_BEDROCK": "1"]) { $1 })
        #expect(bedrock["AWS_PROFILE"] == "prod" && bedrock["CLAUDE_CODE_USE_BEDROCK"] == "1")
        #expect(bedrock["GH_TOKEN"] == nil)
        #expect(try runEnvironment(RunSandbox.environment(agent: "codex", folder: "/r"), shell.merging([
            "CLAUDE_CODE_USE_BEDROCK": "1",
        ]) { $1 })["AWS_PROFILE"] == nil)
    }

    @Test func valuesArriveAsTheyAreAndOnlyShellNamesAreKept() throws {
        let odd = #"a b 'c' "d" $HOME `x` \e"#
        let got = try runEnvironment(
            RunSandbox.environment(agent: "claude", folder: "/runs/it's here", keeping: ["OTEL_X", "BAD NAME", "A;B"]),
            ["PATH": odd, "SHELL": "/bin/zsh", "TERM": "dumb", "OTEL_X": "1", "BAD NAME": "x"]
        )
        #expect(got == [
            "PATH": odd, "SHELL": "/bin/zsh", "TERM": "dumb", "OTEL_X": "1", "GH_CONFIG_DIR": "/runs/it's here/gh",
            "GIT_TERMINAL_PROMPT": "0",
        ])
        #expect(!RunSandbox.keptNames(agent: "claude", extra: ["BAD NAME", "A;B", "1X"]).contains { $0.contains(" ") })
        #expect(!RunSandbox.keptNames(agent: "claude", extra: ["A;B", "1X"]).contains("A;B"))
        #expect(!RunSandbox.keptNames(agent: "claude", extra: ["1X"]).contains("1X"))
    }

    /// (sh fills in `PATH`, `SHELL` and `TERM` when they are not set, so each check sets them.)
    @Test func aHostsRunFolderIsUnderTheHostsHome() throws {
        let script = RunSandbox.environmentScript(agent: "claude", folder: RunFolder.hostPath(run: "r1"))
        #expect(script.contains(#"GH_CONFIG_DIR="$HOME"/.heed/runs/r1/gh"#))
        let got = try runEnvironment(
            RunSandbox.environment(agent: "claude", folder: RunFolder.hostPath(run: "r1")),
            ["HOME": "/home/me", "PATH": "/bin", "SHELL": "/bin/sh", "TERM": "dumb"]
        )
        #expect(got == [
            "HOME": "/home/me", "PATH": "/bin", "SHELL": "/bin/sh", "TERM": "dumb",
            "GH_CONFIG_DIR": "/home/me/.heed/runs/r1/gh", "GIT_TERMINAL_PROMPT": "0",
        ])
    }

    /// A run in a tab: the line runs in the pane's shell, which has what your shell config exported.
    @Test func aRunInATabDropsWhatYourShellExported() throws {
        let agent = AgentProfile(name: "claude", command: "/usr/bin/env")
        let command = agent.launchCommand(
            prompt: "", environment: ["OTEL_LOGS_EXPORTER": "otlp"],
            prefix: RunSandbox.environment(agent: "claude", folder: "/runs/1", keeping: ["OTEL_LOGS_EXPORTER"])
        )
        let posix = try printed("/bin/sh", ["-c", command.rendered(for: .posix)], shell)
        #expect(posix == base.merging([
            "ANTHROPIC_API_KEY": "sk-ant", "CLAUDE_CODE_OAUTH_TOKEN": "oauth", "OTEL_LOGS_EXPORTER": "otlp",
        ]) { $1 })
        let fish = "/opt/homebrew/bin/fish"
        if FileManager.default.isExecutableFile(atPath: fish) {
            #expect(try printed(fish, ["--no-config", "-c", command.rendered(for: .fish)], shell) == posix)
        }
    }

    @Test func codexsProfileWritesOnlyWhereTheRunMayAndReadsNoLogins() throws {
        let words = RunSandbox.codex(folder: "/runs/1")
        #expect(!words.contains("--sandbox") && !words.contains("--add-dir"))
        #expect(words.contains(#"default_permissions="heed-run""#))
        #expect(words.contains(#"permissions.heed-run.extends=":workspace""#))
        #expect(words.contains("permissions.heed-run.network.enabled=false"))
        let filesystem = try #require(words.first { $0.hasPrefix("permissions.heed-run.filesystem=") })
        #expect(filesystem.contains(#""~/.ssh"="none""#) && filesystem.contains(#""~/.config/gh"="none""#))
        #expect(filesystem.contains(#""/runs/1"="write""#))
        #expect(stride(from: 0, to: words.count, by: 2).allSatisfy { words[$0] == "-c" })
    }

    @Test func claudesSandboxKeepsItInItsWorktreeAndOffTheNetwork() throws {
        let words = RunSandbox.claude(
            allowed: ["Bash", "Read"], denied: ["Edit"], worktree: "/wt/r", folder: "/runs/1", network: .none
        )
        let object = try settings(words)
        let sandbox = try #require(object["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        #expect(sandbox["failIfUnavailable"] as? Bool == true)
        #expect(sandbox["allowUnsandboxedCommands"] as? Bool == false)
        let filesystem = try #require(sandbox["filesystem"] as? [String: Any])
        #expect(filesystem["allowWrite"] as? [String] == ["//wt/r", "//runs/1"])
        #expect((filesystem["denyRead"] as? [String])?.contains("~/.ssh") == true)
        #expect((filesystem["denyRead"] as? [String])?.contains("~/.config/gh") == true)
        #expect((sandbox["network"] as? [String: Any])?["allowedDomains"] as? [String] == [])
        let deny = try #require((object["permissions"] as? [String: Any])?["deny"] as? [String])
        #expect(Set(deny).isSuperset(of: ["Edit", "Bash(gh:*)", "Bash(git push:*)", "WebFetch", "Read(~/.ssh/**)"]))
        #expect(object["hooks"] == nil)
        // gh is denied twice over: in the settings and on the command line.
        let disallowed = try #require(words.firstIndex(of: "--disallowedTools"))
        #expect(words[disallowed...].contains("Bash(gh:*)"))
        #expect(words.suffix(2) == ["--permission-mode", "dontAsk"])
        let walk = try settings(RunSandbox.claude(
            allowed: [], denied: [], worktree: "/c", folder: "/r", network: .packages
        ))
        #expect(((walk["sandbox"] as? [String: Any])?["network"] as? [String: Any])?["allowedDomains"] as? [String]
            == RunSandbox.packageHosts)
        #expect(RunSandbox.packageHosts.contains("registry.npmjs.org") && !RunSandbox.packageHosts
            .contains("github.com"))
    }

    @Test func aRunInATabCarriesHeedsHooksInItsOneSettings() throws {
        let words = RunSandbox.claude(
            allowed: [], denied: [], worktree: "/w", folder: "/r", network: .none, hooks: true
        )
        let hooks = try #require(try settings(words)["hooks"] as? [String: Any])
        #expect(hooks["Stop"] != nil)
        #expect(words.count { $0 == "--settings" } == 1)
        #expect(RunSandbox.withoutSettings(["--settings", "/heed/hooks.json", "--session-id", "x"])
            == ["--session-id", "x"])
    }

    @Test func agentsWithoutASandboxAreSaidSo() {
        #expect(RunSandbox.isSandboxed(agent: "claude") && RunSandbox.isSandboxed(agent: "codex"))
        #expect(!RunSandbox.isSandboxed(agent: "cursor") && !RunSandbox.isSandboxed(agent: "gemini"))
        #expect(RunSandbox.unsandboxedNote(agent: "cursor") == "cursor has no sandbox heed can start it in")
        #expect(RunSandbox.note(folder: "/r", network: .none).contains("has no network"))
        #expect(RunSandbox.note(folder: "/r", network: .packages).contains("only package registries"))
    }

    @Test func aSandboxedRunIsPrefixedWithItsEnvironment() {
        let agent = AgentProfile(name: "claude", command: "claude")
        let line = agent.launchCommand(prompt: "", prefix: ["/usr/bin/env", "-u", "GH_TOKEN"]).rendered(for: .posix)
        #expect(line.hasPrefix("/usr/bin/env -u GH_TOKEN claude"))
        #expect(agent.launchCommand(prompt: "").rendered(for: .posix).hasPrefix("claude"))
    }
}

struct PullTrustTests {
    @Test func yoursAndThoseWhoCanWriteAreTrusted() {
        func pull(_ author: String?, _ association: String?, fork: Bool = false) -> PullAuthorship {
            PullAuthorship(author: author, association: association, crossRepository: fork)
        }
        func trusted(_ pull: PullAuthorship, viewer: String?, authors: [String] = []) -> Bool {
            pull.trusted(viewer: viewer, trustedAuthors: authors)
        }
        #expect(trusted(pull("me", "CONTRIBUTOR", fork: true), viewer: "Me"))
        #expect(trusted(pull("ann", "OWNER"), viewer: "me"))
        #expect(trusted(pull("ann", "COLLABORATOR"), viewer: nil))
        #expect(!trusted(pull("ann", "COLLABORATOR", fork: true), viewer: "me"))
        #expect(!trusted(pull("ann", "CONTRIBUTOR"), viewer: "me"))
        #expect(!trusted(pull("ann", "FIRST_TIME_CONTRIBUTOR"), viewer: "me"))
        #expect(!trusted(pull("ann", "NONE"), viewer: "me"))
        #expect(!trusted(pull(nil, nil), viewer: "me"))
        // An organisation member only with write access, and never from a fork.
        var member = pull("ann", "member")
        #expect(!trusted(member, viewer: "me") && member.needsPermission)
        member.canWrite = false
        #expect(!trusted(member, viewer: "me") && !member.needsPermission)
        member.canWrite = true
        #expect(trusted(member, viewer: "me"))
        member.crossRepository = true
        #expect(!trusted(member, viewer: "me"))
        // trusted_authors, as for a merge, and not from a fork.
        #expect(trusted(pull("dependabot[bot]", "NONE"), viewer: "me", authors: ["dependabot"]))
        #expect(!trusted(pull("dependabot[bot]", "NONE", fork: true), viewer: "me", authors: ["dependabot"]))
    }

    @Test func theBookForgetsAfterItsLifetimeAndMembersAreAskedAbout() async {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let book = PullTrustBook(ttl: 600) { clock.withLock { $0 } }
        book.record(PullAuthorship(author: "ann", association: "OWNER", crossRepository: false), for: ref)
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == true)
        clock.withLock { $0 += 599 }
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == true)
        clock.withLock { $0 += 2 }
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == nil)
        // A member whose permission was not asked about is not known yet: resolve asks.
        book.record(PullAuthorship(author: "ann", association: "MEMBER", crossRepository: false), for: ref)
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == nil)
        let resolved = await book.resolve(ref, viewer: "me", trustedAuthors: []) { _ in
            PullAuthorship(author: "ann", association: "MEMBER", crossRepository: false, canWrite: true)
        }
        #expect(resolved && book.trusted(ref, viewer: "me", trustedAuthors: []) == true)
        // A sync's detail replaces what the book knew.
        var detail = PullDetail(
            ref: ref, title: "t", body: "", author: "ann", baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "abc", reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(), closes: [], fetchedAt: .now, authorTrust: .member
        )
        detail.writers = []
        book.record(PullAuthorship(detail), for: ref)
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == false)
        book.forget()
        #expect(book.authorship(ref) == nil)
    }

    @Test func writeAccessIsAskedOncePerLifetimeAndAFailureIsNotKept() async {
        let clock = Mutex(Date(timeIntervalSince1970: 0))
        let book = WriteAccessBook(ttl: 600) { clock.withLock { $0 } }
        let asked = Mutex<[String]>([])
        let repo = ref.repo
        @Sendable func fetch(_: Repo, _ login: String) async throws -> Bool {
            asked.withLock { $0.append(login) }
            if login == "offline" { throw GitHub.Failure(description: "offline") }
            return login == "mia"
        }
        #expect(await book.writers(among: ["Mia", "bo", "mia", "offline"], in: repo, fetch: fetch) == ["mia"])
        #expect(asked.withLock { $0 }.sorted() == ["bo", "mia", "offline"])
        #expect(book.canWrite(repo, "MIA") == true && book.canWrite(repo, "bo") == false)
        #expect(book.canWrite(repo, "offline") == nil)
        _ = await book.resolve(repo, "mia", fetch: fetch)
        #expect(asked.withLock { $0 }.count == 3)
        clock.withLock { $0 += 601 }
        #expect(book.canWrite(repo, "mia") == nil)
        _ = await book.resolve(repo, "mia", fetch: fetch)
        #expect(asked.withLock { $0 }.count == 4)
        // Another repo is another question.
        #expect(book.canWrite(Repo(org: "acme", name: "other"), "mia") == nil)
    }

    @Test func ghsPermissionAnswerIsRead() async throws {
        #expect(RepoPermission.canWrite(#"{"permission": "write", "role_name": "write"}"#) == true)
        #expect(RepoPermission.canWrite(#"{"permission": "admin", "role_name": "admin"}"#) == true)
        #expect(RepoPermission.canWrite(#"{"permission": "write", "role_name": "maintain"}"#) == true)
        #expect(RepoPermission.canWrite(#"{"permission": "read", "role_name": "triage"}"#) == false)
        #expect(RepoPermission.canWrite(#"{"permission": "none", "role_name": "read"}"#) == false)
        #expect(RepoPermission.canWrite(#"{"message": "Not Found"}"#) == nil)
        // Through a stand-in gh, which is asked about the login on the repo.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-perm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        echo '{"permission": "read", "role_name": "read"}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let answer = try await GitHub.$executable.withValue(script.path) {
            try await GitHub.canWrite(ref.repo, login: "mia", caller: "test")
        }
        #expect(!answer)
        #expect(try String(contentsOf: args, encoding: .utf8) ==
            "api\nrepos/acme/widgets/collaborators/mia/permission\n")
        // A login GitHub would not allow is not asked about.
        try FileManager.default.removeItem(at: args)
        let odd = try await GitHub.$executable.withValue(script.path) {
            try await GitHub.canWrite(ref.repo, login: "../../x", caller: "test")
        }
        #expect(!odd && !FileManager.default.fileExists(atPath: args.path))
    }

    @Test func aFetchedPRCarriesItsMembersWriteAccess() async {
        var detail = PullDetail(
            ref: ref, title: "t", body: "", author: "ann", baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "abc",
            reviews: [
                .init(author: "Mia", state: "APPROVED", commit: "abc", trust: .member),
                .init(author: "olek", state: "APPROVED", commit: "abc", trust: .collaborator),
            ],
            threads: [ReviewThread(
                id: "T", isResolved: false, path: "f", line: 1, author: "bo", body: "x", diff: [], replies: 0, url: nil,
                trust: .member
            )],
            failingChecks: [], checks: CheckSummary(), closes: [], fetchedAt: .now, authorTrust: .member
        )
        #expect(detail.memberLogins == ["ann", "Mia", "bo"])
        let asked = Mutex<[String]>([])
        detail = await GitHub.withWriters(detail, book: WriteAccessBook()) { _, login in
            asked.withLock { $0.append(login) }
            return login != "bo"
        }
        #expect(asked.withLock { $0 }.sorted() == ["ann", "bo", "mia"])
        #expect(detail.writers == ["ann", "mia"])
        #expect(detail.canWrite("MIA", trust: .member) && !detail.canWrite("bo", trust: .member))
        #expect(detail.canWrite("olek", trust: .collaborator) && !detail.canWrite("x", trust: .stranger))
    }

    @Test func ghsAnswerIsRead() throws {
        let read = try #require(PullAuthorship.parse(
            #"{"author": {"login": "ann"}, "authorAssociation": "CONTRIBUTOR", "isCrossRepository": true}"#
        ))
        #expect(read == PullAuthorship(author: "ann", association: "CONTRIBUTOR", crossRepository: true))
        #expect(PullAuthorship.parse(#"{"title": "x"}"#) == nil)
        #expect(PullAuthorship.parse("not json") == nil)
        #expect(PullAuthorship.fields == "author,authorAssociation,isCrossRepository")
    }

    @Test func theBookAsksOnceAndKeepsNoFailure() async {
        let book = PullTrustBook()
        let asked = Mutex(0)
        #expect(book.trusted(ref, viewer: "me", trustedAuthors: []) == nil)
        let failed = await book.resolve(ref, viewer: "me", trustedAuthors: []) { _ in
            asked.withLock { $0 += 1 }
            throw GitHub.Failure(description: "offline")
        }
        #expect(!failed && book.trusted(ref, viewer: "me", trustedAuthors: []) == nil)
        let first = await book.resolve(ref, viewer: "me", trustedAuthors: []) { _ in
            asked.withLock { $0 += 1 }
            return PullAuthorship(author: "ann", association: "NONE", crossRepository: true)
        }
        let again = await book.resolve(ref, viewer: "me", trustedAuthors: []) { _ in
            asked.withLock { $0 += 1 }
            return PullAuthorship(author: "ann", association: "OWNER", crossRepository: false)
        }
        #expect(!first && !again && asked.withLock { $0 } == 2)
        #expect(book.trusted(ref, viewer: "ann", trustedAuthors: []) == true)
    }

    @Test func runsStartOnTheirOwnOnlyOnTrustedPRs() {
        #expect(Runs.ownStart(explicit: true, trusted: false) == .go)
        #expect(Runs.ownStart(explicit: false, trusted: true) == .go)
        #expect(Runs.ownStart(explicit: false, trusted: false) == .hold)
        #expect(Runs.ownStart(explicit: false, trusted: nil) == .ask)
    }

    @Test func reviewersWithNoSandboxWaitForYouOnSomeoneElsesPR() throws {
        let clone = RepoRecord(repo: ref.repo, path: "/code/widgets")
        let onPull = ReviewTarget(record: clone, branch: "fix", repo: ref.repo, pull: ref)
        let onBranch = ReviewTarget(record: clone, branch: "fix", repo: ref.repo)
        let held = try #require(ReviewRun.held(
            agent: "cursor", trigger: .prUpdated("x"), target: onPull, trusted: false
        ))
        #expect(held.contains("cursor has no sandbox") && held.contains("acme/widgets#12"))
        #expect(ReviewRun.held(agent: "cursor", trigger: .prUpdated("x"), target: onPull, trusted: nil) != nil)
        #expect(ReviewRun.held(agent: "cursor", trigger: .prUpdated("x"), target: onPull, trusted: true) == nil)
        #expect(ReviewRun.held(agent: "cursor", trigger: .manual, target: onPull, trusted: false) == nil)
        #expect(ReviewRun.held(agent: "claude", trigger: .nightly, target: onPull, trusted: false) == nil)
        #expect(ReviewRun.held(agent: "cursor", trigger: .nightly, target: onBranch, trusted: nil) == nil)
    }
}

struct HelperIsolationTests {
    @Test func aHelperOnSomeoneElsesPRGetsNoneOfYourFilesOrSetup() {
        #expect(HelperSetup.steps(trusted: true, commands: ["npm ci"]) == (true, ["npm ci"]))
        #expect(HelperSetup.steps(trusted: false, commands: ["npm ci"]) == (false, []))
        let environment = HelperSetup.environment(
            [
                "PATH": "/bin", "GH_TOKEN": "t", "SSH_AUTH_SOCK": "/s", "ANTHROPIC_API_KEY": "k", "OPENAI_API_KEY": "o",
                "DATABASE_URL": "d", "FOO_KEY": "f",
            ],
            agent: "claude", folder: "/tmp/h"
        )
        #expect(environment == [
            "PATH": "/bin", "ANTHROPIC_API_KEY": "k", "GH_CONFIG_DIR": "/tmp/h/gh", "GIT_TERMINAL_PROMPT": "0",
        ])
    }

    @Test func itsPromptAsksToRunTestsOnlyOnYourWork() {
        func prompt(_ runTests: Bool) -> String {
            HelperPrompt.review(
                ref: ref, title: ExternalText("T", source: .pullTitle, author: .unknown), body: .empty(.pullBody),
                base: "main", branch: "heed/review/x", prBranch: "x", runTests: runTests
            ).display
        }
        #expect(prompt(true).contains("run its tests"))
        #expect(!prompt(false).contains("run its tests"))
        #expect(prompt(false).contains("run none of it"))
    }

    @Test func aPRIsCheckedOutFromGitHubsRefForIt() {
        #expect(Git.pullFetchArguments(clone: "/code/w", number: 12)
            == ["-C", "/code/w", "fetch", "--quiet", "origin", "+refs/pull/12/head"])
    }
}

struct GoalRunIsolationTests {
    private func prItem(author: String?) -> GoalItem {
        GoalItem(
            id: "g/pr-12", goal: "g", title: "Cache templates", source: .github, createdAt: now,
            sourced: GoalItem.Sourced(
                source: "s1", ref: "acme/widgets#12", kind: .pr, url: "https://github.com/acme/widgets/pull/12",
                author: author, rule: .reviewed
            )
        )
    }

    @Test func aPRItemsReviewIsDraftedNotPosted() {
        let prompt = prItem(author: "tess").workPrompt(goal: "Review PRs", doc: "~/g/GOAL.md")
        #expect(!prompt.display.contains("leave your review on GitHub"))
        #expect(prompt.display.contains("do not post it, approve or comment on GitHub yourself"))
        #expect(prompt.display.contains("heed-verdict:") && prompt.display.contains("heed-comment"))
    }

    @Test func someoneElsesItemIsKnownAsSuch() {
        #expect(prItem(author: "tess").fromSomeoneElse(viewer: "me"))
        #expect(!prItem(author: "Me").fromSomeoneElse(viewer: "me"))
        #expect(prItem(author: nil).fromSomeoneElse(viewer: "me"))
        #expect(prItem(author: "me").fromSomeoneElse(viewer: nil))
        let yours = GoalItem(id: "g/a", goal: "g", title: "Cache", source: .you, createdAt: now)
        #expect(!yours.fromSomeoneElse(viewer: "me"))
    }

    @Test func aSpawnOnSomeoneElsesItemRunsSandboxed() throws {
        let claude = try #require(GoalSpawnRun.headless(
            agent: "claude", command: "claude", prompt: "do it", worktree: "/w", instructions: ["--plugin-dir", "/p"],
            sandbox: "/runs/3"
        ))
        let sandbox = try #require(try settings(claude)["sandbox"] as? [String: Any])
        #expect(sandbox["enabled"] as? Bool == true)
        // Its shell stays to what a spawn may run, sandbox or not.
        #expect(sandbox["autoAllowBashIfSandboxed"] as? Bool == false)
        #expect(claude.contains("Bash(heed goal *)") && claude.suffix(2) == ["--permission-mode", "acceptEdits"])
        #expect(claude.firstIndex(of: "--plugin-dir")! < claude.firstIndex(of: "--allowedTools")!)
        let codex = GoalSpawnRun.headless(
            agent: "codex", command: "codex", prompt: "do it", worktree: "/w", instructions: [], sandbox: "/runs/3"
        )
        #expect(codex == ["codex", "exec"] + RunSandbox.codex(folder: "/runs/3") + ["-C", "/w", "do it"])
        #expect(GoalSpawnRun.sandboxNote(folder: "/runs/3").contains("heed goal cannot reach heed"))
    }
}
