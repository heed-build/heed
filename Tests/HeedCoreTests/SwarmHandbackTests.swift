import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func worker(
    _ slug: String, agent: String = "codex", model: String? = "o4", live: Bool = false, worktree: String = "/wt/a"
) -> SwarmWorker {
    SwarmWorker(
        id: "w-\(slug)", task: "g/\(slug)", owner: GoalItem.Owner(agent: agent, model: model), host: "lead",
        repo: "acme/site", branch: "swarm/g/\(slug)", base: "main", worktree: worktree, startedAt: now,
        endedAt: live ? nil : now, outcome: live ? nil : .turnOver
    )
}

private func swarm(_ workers: [SwarmWorker], status: GoalSwarm.Status = .landing) -> GoalSwarm {
    GoalSwarm(
        id: "g/swarm-1", goal: "g", number: 1, status: status, settings: SwarmSettings(repos: ["acme/site"]),
        plan: 1, approved: 1, startedAt: now, runningAt: now, workers: workers
    )
}

private let rebase = FeedbackItem(
    id: "rebase:412", kind: .rebase(onto: "main", parent: 412, past: "abc123"), text: "Rebase", status: .queued
)
private let conflict = FeedbackItem(
    id: "conflict", kind: .conflict(base: "main", behind: false), text: "Merge conflict with main.", status: .queued
)
private let review = FeedbackItem(
    id: "t1", kind: .review(location: "a.swift:3", author: "rev"), text: "Rename this", status: .queued
)

struct SwarmHandbackTests {
    @Test func onlyAQueuedConflictOrRebaseGoesBack() {
        #expect(SwarmHandback.needs([review]).isEmpty)
        #expect(SwarmHandback.needs([review, rebase]) == [rebase])
        #expect(SwarmHandback.needs([conflict]) == [conflict])
        var sent = conflict
        sent.status = .sent
        #expect(SwarmHandback.needs([sent]).isEmpty)
        var new = rebase
        new.status = .new
        #expect(SwarmHandback.needs([new]).isEmpty)
    }

    @Test func itGoesToTheTasksLastWorkerWhenThatWorkerCanTakeIt() {
        let first = worker("a", agent: "claude", model: nil)
        let last = worker("a")
        let run = swarm([first, last])
        #expect(SwarmHandback.route(
            task: "g/a", swarm: run, agents: ["claude", "codex"], limited: [:], worktreeExists: true, now: now
        ) == .worker(last))
    }

    @Test func otherwiseAGetItMergedRunTakesItAndSaysWhy() {
        func route(
            _ run: GoalSwarm? = nil, task: String = "g/a", agents: Set<String> = ["codex"],
            limited: [String: Date?] = [:], exists: Bool = true
        ) -> SwarmHandback.Route {
            SwarmHandback.route(
                task: task, swarm: run ?? swarm([worker("a")]), agents: agents, limited: limited,
                worktreeExists: exists, now: now
            )
        }
        #expect(route(swarm([worker("a")], status: .stopped)) == .pilot("the swarm is stopped"))
        #expect(route(swarm([worker("a")], status: .paused)) == .pilot("the swarm is paused"))
        #expect(route(swarm([worker("a")], status: .done)) == .pilot("the swarm is done"))
        #expect(route(task: "g/b") == .pilot("no worker ran the task"))
        #expect(route(agents: ["claude"]) == .pilot("its agent codex is not set up here"))
        #expect(route(limited: ["codex": nil]) == .pilot("codex is rate limited"))
        if case let .pilot(why) = route(limited: ["codex": now.addingTimeInterval(600)]) {
            #expect(why.hasPrefix("codex is rate limited until "))
        } else {
            Issue.record("rate limited until later")
        }
        // A limit that lifted no longer holds it back.
        #expect(route(limited: ["codex": now.addingTimeInterval(-60)]) == .worker(worker("a")))
        #expect(route(exists: false) == .pilot("its worktree is gone"))
        #expect(route(swarm([worker("a", worktree: "")])) == .pilot("its worktree is gone"))
        // At work on it now: it waits for its turn to end.
        #expect(route(swarm([worker("a", live: true)])) == .wait("its worker is at work on it"))
    }

    @Test func whatWentBackInAFewWords() {
        #expect(SwarmHandback.what([conflict, rebase], pr: 415) == "#415 rebases onto main (#412 merged)")
        #expect(SwarmHandback.what([conflict], pr: 415) == "#415 conflicts with main")
        let behind = FeedbackItem(id: "conflict", kind: .conflict(base: "main", behind: true), text: "Behind main.")
        #expect(SwarmHandback.what([behind], pr: 415) == "#415 is behind main")
        #expect(SwarmHandback.what([review], pr: 415) == "#415 needs its branch reworked")
    }

    @Test func theWorkersPromptSaysWhatThePRNeedsAndWhereItMayPush() {
        let task = SwarmTask(id: "g/cache", title: "Cache tiles", phase: "Build")
        let ref = PullRef(repo: Repo(org: "acme", name: "site"), number: 415)
        let prompt = Handoff.swarmReturn(
            task: task, number: "1.2", swarm: swarm([]), pr: ref, branch: "swarm/g/cache", base: "main",
            items: [rebase, review], instructions: "Keep commits small."
        )
        #expect(prompt.contains("swarm 1's task 1.2 Cache tiles (item g/cache)"))
        #expect(prompt.contains(ref.url))
        #expect(prompt.contains("- " + rebase.promptLine))
        #expect(prompt.contains("- " + review.promptLine))
        #expect(prompt.contains("Push to swarm/g/cache only"))
        #expect(prompt.contains("never to main, and never merge"))
        #expect(prompt.hasSuffix("Keep commits small."))
    }
}

struct SwarmLabelTests {
    private func row(_ task: String, pr: Int?) -> SwarmLanding.Row {
        SwarmLanding.Row(
            slot: SwarmLanding.Slot(task: task, position: 1, total: 2, after: [], before: []), title: task,
            number: "1.1", pr: pr, state: .open, label: "1/2", hold: nil, base: "main", stackedOn: nil
        )
    }

    @Test func aDoneRunKeepsItsLabelsUntilItsPRsMergedOrClosed() {
        let rows = [row("g/a", pr: 1), row("g/b", pr: 2), row("g/c", pr: nil)]
        #expect(SwarmLanding.labelled(rows, status: .landing) { _ in false } == rows)
        #expect(SwarmLanding.labelled(rows, status: .done) { $0.pr == 2 }.map(\.id) == ["g/b"])
        #expect(SwarmLanding.labelled(rows, status: .done) { _ in false }.isEmpty)
        #expect(SwarmLanding.labelled(rows, status: .stopped) { _ in true }.isEmpty)
    }
}

struct SwarmMergeSettingTests {
    @Test func theSwarmsModeOrTheReposForItsPRs() {
        #expect(SwarmSettings.Merge.repo.mode(repo: .heed) == .heed)
        #expect(SwarmSettings.Merge.repo.mode(repo: .off) == .off)
        #expect(SwarmSettings.Merge.auto.mode(repo: .off) == .auto)
        #expect(SwarmSettings.Merge.heed.mode(repo: .auto) == .heed)
        #expect(SwarmSettings.Merge.off.mode(repo: .heed) == .off)
        #expect(SwarmSettings().merge == .repo)
    }

    @Test func theWordsItTakesAndHowItReads() {
        #expect(SwarmSettings.Merge.named("AUTO") == .auto)
        #expect(SwarmSettings.Merge.named("follow") == .repo)
        #expect(SwarmSettings.Merge.named("default") == .repo)
        #expect(SwarmSettings.Merge.named("repo") == .repo)
        #expect(SwarmSettings.Merge.named("now") == nil)
        #expect(SwarmSettings.Merge.repo.line(repo: .off) == "merge as the repo says (off)")
        #expect(SwarmSettings.Merge.heed.line(repo: .off) == "merge heed")
    }

    @Test func settingsStoredBeforeItFollowTheRepo() throws {
        var json = try #require(JSONSerialization.jsonObject(
            with: JSONEncoder().encode(SwarmSettings(merge: .auto))
        ) as? [String: Any])
        #expect(json["merge"] as? String == "auto")
        json["merge"] = nil
        let old = try JSONDecoder().decode(SwarmSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.merge == .repo)
    }

    @Test func changingItAndHandingBackAreSteeringRows() async throws {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "G", statement: "x", now: now)
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        let changed = try await ops.setMerge(swarm: swarm.id, .auto, now: now)
        #expect(changed.settings.merge == .auto)
        var rows = try await ops.board(of: swarm.id).steering
        #expect(rows.last?.kind == .limit && rows.last?.actor == .you)
        #expect(rows.last?.text == "Get it merged: repo → auto")
        let count = rows.count
        try await ops.setMerge(swarm: swarm.id, .auto, now: now)
        #expect(try await ops.board(of: swarm.id).steering.count == count)

        try await ops.handback(
            swarm: swarm.id,
            task: "g/a",
            what: "#415 conflicts with main",
            to: "codex · o4",
            reason: nil,
            now: now
        )
        try await ops.handback(
            swarm: swarm.id,
            task: "g/a",
            what: "#415 conflicts with main",
            to: nil,
            reason: "the swarm is stopped",
            now: now
        )
        rows = try await ops.board(of: swarm.id).steering
        let back = rows.filter { $0.kind == .handback }
        #expect(back.map(\.text) == [
            "#415 conflicts with main: back to its worker, codex · o4",
            "#415 conflicts with main: to a get it merged run",
        ])
        #expect(back.map(\.actor) == [.heed, .heed])
        #expect(back.last?.reason == "the swarm is stopped")
        #expect(back.allSatisfy { $0.ref == "task:g/a" })
    }
}

struct ClaudeToolFailureHookTests {
    @Test func itIsRegisteredAndAStoppedCallIsNoFailure() throws {
        #expect(AgentIntegration.claudeEvents.contains { $0.event == "PostToolUseFailure" && $0.matcher == "*" })
        let json = try #require(JSONSerialization
            .jsonObject(with: Data(AgentIntegration.claudeSettingsJSON().utf8)) as? [String: Any])
        #expect((json["hooks"] as? [String: Any])?["PostToolUseFailure"] != nil)
        let stopped = AgentIntegration.claudeHook(event: "PostToolUseFailure", input: [
            "tool_name": "Bash", "tool_input": ["command": "make"], "error": "Interrupted by user",
            "is_interrupt": true,
        ])
        #expect(stopped == [.toolCall(ToolCall(tool: "Bash", input: "make"))])
        let failed = AgentIntegration.claudeHook(event: "PostToolUseFailure", input: [
            "tool_name": "Bash", "tool_input": ["command": "make"], "error": "make: *** [all] Error 2",
            "is_interrupt": false,
        ])
        #expect(failed.first.map { if case let .toolCall(call) = $0 { call.error } else { false } } == true)
    }
}
