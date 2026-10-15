import Foundation
@testable import HeedCore
import Testing

/// `send_to = "tab"` and `send_after_idle`: a dedicated agent for get it green / merged, and not sending while you
/// work.
struct HelperTabTests {
    @Test func whichTabAPRNeedsAndWhenItIsDone() {
        #expect(HelperTabs.goal(for: .failing(2)) == .green)
        #expect(HelperTabs.goal(for: .changes(1)) == .green)
        #expect(HelperTabs.goal(for: .conflicted("conflicts")) == .merged)
        #expect(HelperTabs.goal(for: .green) == nil)
        #expect(HelperTabs.done(.green, status: .green))
        #expect(HelperTabs.done(.green, status: .passing))
        #expect(!HelperTabs.done(.green, status: .failing(1)))
        #expect(!HelperTabs.done(.merged, status: .green))
        #expect(HelperTabs.done(.merged, status: .closed(merged: true)))
        #expect(HelperTabs.canClose(.idle) && HelperTabs.canClose(nil) && !HelperTabs.canClose(.working))
        let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 12)
        #expect(HelperTabs.title(.green, ref: ref, pullCount: 1) == "get it green")
        #expect(HelperTabs.title(.merged, ref: ref, pullCount: 2) == "get it merged #12")
    }

    @Test func aBusyHelperPutsItsSessionInNeedsYou() {
        let session = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.idle))
        #expect(SessionGroup.of(session, pilot: SessionPilot(helperNeedsYou: true)) == .needsYou)
        #expect(SessionGroup.of(session, pilot: SessionPilot()) == .parked)
    }

    @Test func settingsParseWithOverrides() {
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        send_after_idle = "15m"
        send_to = "tab"
        [repos."o/r"]
        send_after_idle = "0"
        send_to = "session"
        [orgs.bad]
        send_to = "elsewhere"
        """)
        #expect(problems.map(\.path) == ["orgs.bad.send_to"])
        let pilot = config?.pilot ?? PilotRules()
        #expect(pilot.defaults.sendAfterIdle == 900 && pilot.defaults.sendTo == .tab)
        let repo = pilot.resolve(Repo(org: "o", name: "r"))
        #expect(repo.sendAfterIdle == 0 && repo.sendTo == .session)
        #expect(HeedConfig.default.pilot.defaults.sendAfterIdle == 300)
        #expect(PilotDuration.text(30) == "30s" && PilotDuration.text(0) == "0" && PilotDuration.text(300) == "5m")
    }

    @Test func notWhileYouWorkInIt() {
        let now = Date()
        let typed = now.addingTimeInterval(-120)
        #expect(Delivery.verdict(state: .idle, lastTyped: typed, now: now, typingGrace: 300)
            == .wait("you're working in it (sends 5m after your last keystroke)"))
        #expect(Delivery.verdict(state: .idle, lastTyped: typed, now: now, typingGrace: 60) == .deliver)
        // 0 still keeps the short grace.
        #expect(Delivery.verdict(state: .idle, lastTyped: now.addingTimeInterval(-5), now: now, typingGrace: 0)
            == .wait("you typed in its pane just now"))
    }
}

struct CompanionTests {
    @Test func whileYouAreThereAHelperGetsItsOwnWorktree() {
        #expect(HelperTabs.route(hasHelper: false, youAreThere: true) == .companionHelper)
        #expect(HelperTabs.route(hasHelper: false, youAreThere: false) == .sessionAgent)
        // A PR that has a helper keeps it, there or not.
        #expect(HelperTabs.route(hasHelper: true, youAreThere: false) == .existingHelper)
        #expect(HelperTabs.companionPath(worktree: "/wt/r/fix-a", goal: .green) == "/wt/r/fix-a-green")
        #expect(HelperTabs.companionPath(worktree: "/wt/r/fix-a", goal: .merged) == "/wt/r/fix-a-merged")
        #expect(HelperTabs.companionBranch("fix/a", goal: .green) == "fix/a-green")
        let prompt = HelperTabs.companionPrompt("Fix lint", branch: "fix/a", goal: .green)
        #expect(prompt.contains("fix/a-green") && prompt.contains("git push origin HEAD:fix/a")
            && prompt.hasSuffix("Fix lint"))
    }
}

/// A helper's companion checkout against real git: a remote, the session's worktree on the PR branch, the companion
/// beside it, a push from the companion, and the session's worktree catching up.
struct CompanionGitTests {
    private func git(_ path: String, _ args: [String]) async throws -> String {
        try await ProcessRunner.output("git", ["-C", path] + args)
    }

    @Test func aCompanionPushesToTheBranchAndTheWorktreeCatchesUp() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("heed-companion-\(UUID().uuidString)")
            .path
        defer { try? FileManager.default.removeItem(atPath: base) }
        let remote = base + "/remote.git", clone = base + "/clone", main = base + "/wt/r/fix-a"
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        _ = try await ProcessRunner.output("git", ["init", "-q", "--bare", "-b", "main", remote])
        _ = try await ProcessRunner.output("git", ["clone", "-q", remote, clone])
        for args in [
            ["config", "user.email", "t@t"], ["config", "user.name", "t"], ["commit", "-q", "--allow-empty", "-m", "a"],
            ["push", "-q", "origin", "main"], ["worktree", "add", "-q", "-b", "fix-a", main],
        ] {
            _ = try await git(clone, args)
        }
        _ = try await git(main, ["push", "-q", "-u", "origin", "fix-a"])
        let record = RepoRecord(repo: Repo(org: "o", name: "r"), path: clone)

        let companion = try await Git.addCompanion(
            record, path: HelperTabs.companionPath(worktree: main, goal: .green), branch: "fix-a",
            companionBranch: "fix-a-green"
        )
        #expect(companion.hasSuffix("fix-a-green"))
        // On its own branch, tracking the PR's.
        #expect(try await git(companion, ["rev-parse", "--abbrev-ref", "HEAD"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "fix-a-green")
        #expect(try await git(companion, ["rev-parse", "--abbrev-ref", "@{u}"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            == "origin/fix-a")
        // The helper commits and pushes the way its prompt says.
        _ = try await git(companion, ["commit", "-q", "--allow-empty", "-m", "helper fix"])
        _ = try await git(companion, ["push", "-q", "origin", "HEAD:fix-a"])

        await Git.removeWorktree(record, path: companion, branch: "fix-a-green")
        #expect(!FileManager.default.fileExists(atPath: companion))
        #expect(try await git(clone, ["branch", "--list", "fix-a-green"]).isEmpty)
        #expect(await Git.fastForwardIfClean(at: main))
        #expect(try await git(main, ["log", "-1", "--format=%s"]).trimmingCharacters(in: .whitespacesAndNewlines)
            == "helper fix")
        // With changes of its own, it is left alone.
        FileManager.default.createFile(atPath: main + "/mine.txt", contents: Data("x".utf8))
        #expect(await !Git.fastForwardIfClean(at: main))
    }
}
