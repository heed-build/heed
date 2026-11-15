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
    @Test func aRunHasNoLogins() {
        let present = [
            "PATH", "HOME", "GH_TOKEN", "AWS_REGION", "AZURE_SUBSCRIPTION", "MY_SERVICE_TOKEN", "DB_PASSWORD",
            "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "HEED_SESSION_ID", "LANG",
        ]
        let unset = Set(RunSandbox.unset(present: present))
        #expect(unset.isSuperset(of: [
            "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "SSH_AUTH_SOCK", "AWS_REGION", "AZURE_SUBSCRIPTION",
            "MY_SERVICE_TOKEN", "DB_PASSWORD", "AWS_SECRET_ACCESS_KEY",
        ]))
        #expect(unset.isDisjoint(with: [
            "PATH", "HOME", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "OPENAI_API_KEY", "HEED_SESSION_ID", "LANG",
        ]))
        // The cloud the agent itself runs on stays.
        let bedrock = RunSandbox.unset(present: ["CLAUDE_CODE_USE_BEDROCK", "AWS_PROFILE", "GH_TOKEN"])
        #expect(!bedrock.contains("AWS_PROFILE") && bedrock.contains("GH_TOKEN"))
        let words = RunSandbox.environment(present: present, folder: "/runs/1")
        #expect(words.first == "/usr/bin/env")
        #expect(zip(words, words.dropFirst()).contains { $0 == "-u" && $1 == "GH_TOKEN" })
        #expect(zip(words, words.dropFirst()).contains { $0 == "-u" && $1 == "SSH_AUTH_SOCK" })
        #expect(words.contains("GH_CONFIG_DIR=/runs/1/gh") && words.contains("GIT_TERMINAL_PROMPT=0"))
        #expect(!words.contains { $0.contains("ANTHROPIC") })
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
        #expect(pull("me", "CONTRIBUTOR", fork: true).trusted(viewer: "Me"))
        #expect(pull("ann", "OWNER").trusted(viewer: "me"))
        #expect(pull("ann", "member").trusted(viewer: "me"))
        #expect(pull("ann", "COLLABORATOR").trusted(viewer: nil))
        #expect(!pull("ann", "COLLABORATOR", fork: true).trusted(viewer: "me"))
        #expect(!pull("ann", "CONTRIBUTOR").trusted(viewer: "me"))
        #expect(!pull("ann", "FIRST_TIME_CONTRIBUTOR").trusted(viewer: "me"))
        #expect(!pull("ann", "NONE").trusted(viewer: "me"))
        #expect(!pull(nil, nil).trusted(viewer: "me"))
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
        #expect(book.trusted(ref, viewer: "me") == nil)
        let failed = await book.resolve(ref, viewer: "me") { _ in
            asked.withLock { $0 += 1 }
            throw GitHub.Failure(description: "offline")
        }
        #expect(!failed && book.trusted(ref, viewer: "me") == nil)
        let first = await book.resolve(ref, viewer: "me") { _ in
            asked.withLock { $0 += 1 }
            return PullAuthorship(author: "ann", association: "NONE", crossRepository: true)
        }
        let again = await book.resolve(ref, viewer: "me") { _ in
            asked.withLock { $0 += 1 }
            return PullAuthorship(author: "ann", association: "OWNER", crossRepository: false)
        }
        #expect(!first && !again && asked.withLock { $0 } == 2)
        #expect(book.trusted(ref, viewer: "ann") == true)
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
            ["PATH": "/bin", "GH_TOKEN": "t", "SSH_AUTH_SOCK": "/s", "ANTHROPIC_API_KEY": "k"], folder: "/tmp/h"
        )
        #expect(environment["GH_TOKEN"] == nil && environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["PATH"] == "/bin" && environment["ANTHROPIC_API_KEY"] == "k")
        #expect(environment["GH_CONFIG_DIR"] == "/tmp/h/gh")
    }

    @Test func itsPromptAsksToRunTestsOnlyOnYourWork() {
        func prompt(_ runTests: Bool) -> String {
            HelperPrompt.review(
                ref: ref, title: "T", body: "", base: "main", branch: "heed/review/x", prBranch: "x",
                runTests: runTests
            )
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
        #expect(!prompt.contains("leave your review on GitHub"))
        #expect(prompt.contains("do not post it, approve or comment on GitHub yourself"))
        #expect(prompt.contains("heed-verdict:") && prompt.contains("heed-comment"))
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
        #expect(codex == [
            "codex", "exec", "--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=false",
            "--add-dir", "/runs/3", "-C", "/w", "do it",
        ])
        #expect(GoalSpawnRun.sandboxNote(folder: "/runs/3").contains("heed goal cannot reach heed"))
    }
}
