import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func task(_ slug: String, phase: String = "Build", after: [String] = []) -> SwarmTask {
    SwarmTask(
        id: "g/\(slug)", title: slug.capitalized, phase: phase, owner: GoalItem.Owner(agent: "claude"),
        after: after.map { "g/\($0)" }
    )
}

private func worker(_ slug: String, base: String = "main", stackedOn: String? = nil) -> SwarmWorker {
    SwarmWorker(
        id: "w-\(slug)", task: "g/\(slug)", owner: GoalItem.Owner(agent: "claude"), host: "lead", repo: "acme/site",
        branch: "swarm/g/\(slug)", base: base, stackedOn: stackedOn.map { "g/\($0)" }, worktree: "/wt/\(slug)",
        startedAt: now, endedAt: now, outcome: .turnOver
    )
}

private func swarm(_ workers: [SwarmWorker], status: GoalSwarm.Status = .landing) -> GoalSwarm {
    GoalSwarm(
        id: "g/swarm-1", goal: "g", number: 1, status: status, settings: SwarmSettings(repos: ["acme/site"]),
        plan: 1, approved: 1, startedAt: now, runningAt: now, workers: workers
    )
}

private func open(_ number: Int, _ slug: String) -> SwarmTaskFacts {
    SwarmTaskFacts(pr: .open(number: number, branch: "swarm/g/\(slug)", checks: .passing))
}

private func merged(_ number: Int) -> SwarmTaskFacts { SwarmTaskFacts(pr: .merged(number: number)) }

struct SwarmLandingOrderTests {
    @Test func dependenciesComeFirstThenPlanOrder() {
        // c waits for d, which the plan lists after it: d moves up, the rest keep the plan's order.
        let tasks = [task("a"), task("c", after: ["d"]), task("b"), task("d")]
        #expect(SwarmLanding.order(tasks) == ["g/a", "g/b", "g/d", "g/c"])
        // Already in order: unchanged.
        let plain = [task("a"), task("b", after: ["a"]), task("c", after: ["b"])]
        #expect(SwarmLanding.order(plain) == ["g/a", "g/b", "g/c"])
    }

    @Test func whatATaskWaitsForOutsideThePlanDoesNotOrderIt() {
        let tasks = [task("a", after: ["elsewhere"]), task("b")]
        #expect(SwarmLanding.order(tasks) == ["g/a", "g/b"])
    }

    @Test func aCycleLeavesTheRestInPlanOrder() {
        let tasks = [task("a"), task("b", after: ["c"]), task("c", after: ["b"])]
        #expect(SwarmLanding.order(tasks) == ["g/a", "g/b", "g/c"])
    }

    @Test func slotsSayWhichConstraintsAreReal() {
        let tasks = [task("a"), task("iso"), task("b", after: ["a"]), task("c", after: ["b", "a"])]
        let slots = Dictionary(uniqueKeysWithValues: SwarmLanding.slots(tasks).map { ($0.task, $0) })
        #expect(slots["g/iso"]?.isolated == true)
        #expect(slots["g/a"]?.isolated == false)
        #expect(slots["g/a"]?.before == ["g/b", "g/c"])
        // In merge order, not as the plan listed them.
        #expect(slots["g/c"]?.after == ["g/a", "g/b"])
        #expect(slots["g/c"]?.position == 4 && slots["g/c"]?.total == 4)
    }

    @Test func theLabelNamesPRsWhereThereAreSomeElsePlanNumbers() {
        let tasks = [task("a"), task("b", after: ["a"]), task("iso")]
        let slots = SwarmLanding.slots(tasks)
        let numbers = SwarmPlan.numbers(tasks)
        #expect(SwarmLanding.label(slots[1], prs: ["g/a": 412], numbers: numbers) == "2/3 · after #412")
        #expect(SwarmLanding.label(slots[1], prs: [:], numbers: numbers) == "2/3 · after 1.1")
        #expect(SwarmLanding.label(slots[2], prs: [:], numbers: numbers) == "3/3 · any order")
        // First, with something waiting for it: just its place.
        #expect(SwarmLanding.label(slots[0], prs: [:], numbers: numbers) == "1/3")
    }
}

struct SwarmLandingHoldTests {
    private let numbers = ["g/a": "1.1", "g/b": "1.2", "g/c": "2.1"]

    @Test func aChildIsHeldWhileItsParentIsUnmerged() {
        let child = task("c", after: ["a"])
        let facts = ["g/a": open(412, "a"), "g/c": open(415, "c")]
        let hold = SwarmLanding.hold(child, facts: facts, prs: SwarmLanding.prs(facts), numbers: numbers)
        #expect(hold == "after #412, which is not merged yet: dependencies merge first")
        // No PR yet: by its number.
        #expect(SwarmLanding.hold(child, facts: [:], prs: [:], numbers: numbers)?.hasPrefix("after 1.1,") == true)
    }

    @Test func aMergedOrDoneParentLetsItGo() {
        let child = task("c", after: ["a", "b"])
        let facts = ["g/a": merged(412), "g/b": SwarmTaskFacts(criteriaMet: 1, criteriaTotal: 1)]
        #expect(SwarmLanding.hold(child, facts: facts, prs: [:], numbers: numbers) == nil)
        #expect(SwarmLanding.hold(task("a"), facts: [:], prs: [:], numbers: numbers) == nil)
    }

    @Test func twoOpenParentsBothHoldIt() {
        let child = task("c", after: ["a", "b"])
        let facts = ["g/a": open(412, "a"), "g/b": open(413, "b")]
        let hold = SwarmLanding.hold(child, facts: facts, prs: SwarmLanding.prs(facts), numbers: numbers)
        #expect(hold == "after #412 and #413, which are not merged yet: dependencies merge first")
    }

    @Test func rowsSayHeldOpenMergedAndNoPR() {
        let tasks = [task("a"), task("b"), task("c", after: ["a"]), task("d", after: ["b"])]
        let run = swarm([worker("a"), worker("c", base: "swarm/g/a", stackedOn: "a")])
        let facts = [
            "g/a": open(412, "a"), "g/b": merged(409), "g/c": open(415, "c"), "g/d": SwarmTaskFacts(),
        ]
        let rows = Dictionary(uniqueKeysWithValues: SwarmLanding.rows(tasks, swarm: run, facts: facts).map {
            ($0.id, $0)
        })
        #expect(rows["g/a"]?.state == .open)
        #expect(rows["g/b"]?.state == .merged)
        #expect(rows["g/c"]?.state == .held)
        #expect(rows["g/c"]?.label == "3/4 · after #412")
        #expect(rows["g/c"]?.base == "swarm/g/a" && rows["g/c"]?.stackedOn == "g/a")
        #expect(rows["g/d"]?.state == .noPR)
        #expect(rows["g/d"]?.hold == nil)
    }

    @Test func theScheduleSaysAGreenChildMergesAfterItsParent() {
        let tasks = [task("a"), task("c", after: ["a"])]
        let run = swarm([worker("a"), worker("c", base: "swarm/g/a", stackedOn: "a")], status: .running)
        let facts = ["g/a": open(412, "a"), "g/c": open(415, "c")]
        let schedule = SwarmScheduler.schedule(
            run, tasks: tasks, facts: facts, usage: SwarmScheduler.Usage(), defaultBranch: "main", now: now
        )
        #expect(schedule.states["g/c"]?.state == .green)
        #expect(schedule.states["g/c"]?.reason == "#415 green · merges after #412")
        #expect(schedule.states["g/a"]?.reason == "#412 green")
    }
}

struct SwarmLandingGreenTests {
    private func detail(mergeable: String = "MERGEABLE", state: String = "CLEAN", pending: [String] = [])
        -> PullDetail
    {
        var detail = PullDetail(
            ref: PullRef(repo: Repo(org: "acme", name: "site"), number: 7), title: "", body: "", author: nil,
            baseBranch: "main", headBranch: "swarm/g/a", additions: 0, deletions: 0, commitCount: 1, headSHA: "abc",
            reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(passed: 3, pending: pending.count, pendingNames: pending), closes: [],
            fetchedAt: now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = mergeable
        detail.mergeState = state
        return detail
    }

    @Test func greenIsThePilotsVerdictWhenItHasOne() {
        // Checks pass, but the PR conflicts with its base: not green, and the schedule says why.
        let conflicted = SwarmTaskFacts(
            pr: .open(number: 7, branch: "swarm/g/a", checks: .passing),
            verdict: GreenVerdict.of(detail(mergeable: "CONFLICTING", state: "DIRTY"))
        )
        #expect(!conflicted.green)
        let schedule = SwarmScheduler.schedule(
            swarm([], status: .running), tasks: [task("a")], facts: ["g/a": conflicted],
            usage: SwarmScheduler.Usage(), defaultBranch: "main", now: now
        )
        #expect(schedule.states["g/a"]?.state == .pr)
        #expect(schedule.states["g/a"]?.reason == "#7 conflicts with main")
        // A verdict that holds: green.
        let clean = SwarmTaskFacts(
            pr: .open(number: 7, branch: "swarm/g/a", checks: .running), verdict: GreenVerdict.of(detail())
        )
        #expect(clean.green)
        // No verdict yet: checks passing, as before.
        #expect(open(7, "a").green)
        #expect(!SwarmTaskFacts(pr: .open(number: 7, branch: "b", checks: .running)).green)
    }

    @Test func factsCarryThePRAndItsVerdictFromTheDetails() {
        let run = swarm([worker("a")], status: .running)
        let pull = PullRequest(
            ref: PullRef(repo: Repo(org: "acme", name: "site"), number: 7), title: "A", url: "", state: .open,
            isDraft: false, headBranch: "swarm/g/a", review: nil, checks: CheckSummary(passed: 3),
            unresolvedThreads: 0, updatedAt: now
        )
        let facts = SwarmFacts.build(
            swarm: run, tasks: [task("a")], items: [], evidence: [], steering: [], pulls: [pull],
            details: [pull.ref.description: detail(mergeable: "CONFLICTING", state: "DIRTY")]
        )
        #expect(facts["g/a"]?.ref == pull.ref)
        #expect(facts["g/a"]?.verdict?.isGreen == false)
        #expect(facts["g/a"]?.green == false)
    }
}

struct SwarmLandingRetargetTests {
    @Test func aChildGoesToWhereItsParentMerged() {
        let tasks = [task("a"), task("c", after: ["a"])]
        let run = swarm([worker("a"), worker("c", base: "swarm/g/a", stackedOn: "a")])
        let facts = ["g/a": merged(412), "g/c": open(415, "c")]
        let moves = SwarmLanding.retargets(tasks, swarm: run, facts: facts, defaultBranch: "main")
        #expect(moves == [SwarmLanding.Retarget(
            task: "g/c", pr: 415, parent: "g/a", parentPR: 412, from: "swarm/g/a", to: "main", stackedOn: nil,
            edit: true
        )])
        #expect(moves.first?.text == "#415 now goes against main: #412 merged")
    }

    @Test func nothingMovesWhileTheParentIsOpenOrForAPROfTheDefaultBranch() {
        let tasks = [task("a"), task("c", after: ["a"])]
        let stacked = swarm([worker("a"), worker("c", base: "swarm/g/a", stackedOn: "a")])
        #expect(SwarmLanding.retargets(
            tasks, swarm: stacked, facts: ["g/a": open(412, "a"), "g/c": open(415, "c")], defaultBranch: "main"
        ).isEmpty)
        let plain = swarm([worker("a"), worker("c")])
        #expect(SwarmLanding.retargets(
            tasks, swarm: plain, facts: ["g/a": merged(412), "g/c": open(415, "c")], defaultBranch: "main"
        ).isEmpty)
        // The child merged or has no PR: nothing to move.
        #expect(SwarmLanding.retargets(
            tasks, swarm: stacked, facts: ["g/a": merged(412), "g/c": merged(415)], defaultBranch: "main"
        ).isEmpty)
    }

    @Test func aGrandchildGoesToTheFirstAncestorStillOpenElseTheDefaultBranch() {
        let tasks = [task("a"), task("b", after: ["a"]), task("c", after: ["b"])]
        let run = swarm([
            worker("a"), worker("b", base: "swarm/g/a", stackedOn: "a"),
            worker("c", base: "swarm/g/b", stackedOn: "b"),
        ])
        // b merged into a's branch (by hand) while a is open: c goes to a's branch, stacked on a.
        var facts = ["g/a": open(410, "a"), "g/b": merged(411), "g/c": open(412, "c")]
        let up = SwarmLanding.retargets(tasks, swarm: run, facts: facts, defaultBranch: "main")
        #expect(up.map(\.to) == ["swarm/g/a"])
        #expect(up.first?.stackedOn == "g/a")
        // a merged too: c goes all the way to main.
        facts["g/a"] = merged(410)
        let all = SwarmLanding.retargets(tasks, swarm: run, facts: facts, defaultBranch: "main")
        #expect(all.map(\.task) == ["g/c"])
        #expect(all.first?.to == "main" && all.first?.stackedOn == nil)
    }

    @Test func aPRGitHubMovedAlreadyNeedsOnlyHeedsRecord() {
        let tasks = [task("a"), task("c", after: ["a"])]
        let run = swarm([worker("a"), worker("c", base: "swarm/g/a", stackedOn: "a")])
        let facts = ["g/a": merged(412), "g/c": open(415, "c")]
        let moves = SwarmLanding.retargets(
            tasks, swarm: run, facts: facts, bases: ["g/c": "main"], defaultBranch: "main"
        )
        #expect(moves.map(\.edit) == [false])
        // Once heed's record says main, nothing is left to do.
        let moved = swarm([worker("a"), worker("c", base: "main", stackedOn: nil)])
        #expect(SwarmLanding.retargets(tasks, swarm: moved, facts: facts, defaultBranch: "main").isEmpty)
    }

    @Test func theRebaseIsGetItGreenFeedbackThatNeverForcesTheBase() {
        let move = SwarmLanding.Retarget(
            task: "g/c", pr: 415, parent: "g/a", parentPR: 412, from: "swarm/g/a", to: "main", stackedOn: nil,
            edit: true
        )
        let item = SwarmLanding.rebaseItem(move, past: "c412", queued: true)
        #expect(item.id == "rebase:412" && item.status == .queued)
        #expect(SwarmLanding.rebaseItem(move, past: "c412", queued: false).status == .new)
        let line = item.promptLine
        #expect(line.contains("git rebase --onto origin/main c412"))
        #expect(line.contains("--force-with-lease to this PR's branch only, never to main"))
        #expect(!line.contains("push --force "))
    }

    @Test func theRebaseIsResolvedOnceANewHeadMergesCleanly() {
        let ref = PullRef(repo: Repo(org: "acme", name: "site"), number: 415)
        var pipeline = PullFeedback(ref: ref)
        let move = SwarmLanding.Retarget(
            task: "g/c", pr: 415, parent: "g/a", parentPR: 412, from: "swarm/g/a", to: "main", stackedOn: nil,
            edit: true
        )
        pipeline.items = [SwarmLanding.rebaseItem(move, past: "c412", queued: true)]
        var detail = PullDetail(
            ref: ref, title: "", body: "", author: nil, baseBranch: "main", headBranch: "swarm/g/c", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "old", reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(passed: 1), closes: [], fetchedAt: now
        )
        detail.mergeable = "MERGEABLE"
        // Not sent yet: stays, however clean the PR looks.
        pipeline.merge(detail, now: now)
        #expect(pipeline.items.first?.status == .queued)
        pipeline.markSent(at: "old", now: now)
        pipeline.merge(detail, now: now)
        #expect(pipeline.items.first?.status == .sent)
        detail.headSHA = "new"
        pipeline.merge(detail, now: now)
        #expect(pipeline.items.first?.status == .resolved)
    }
}

struct SwarmLandingDoneTests {
    @Test func landedOnceEveryTaskMergedOrIsDone() {
        let tasks = [task("a"), task("b")]
        #expect(!SwarmLanding.landed([], facts: [:]))
        #expect(!SwarmLanding.landed(tasks, facts: ["g/a": merged(1), "g/b": open(2, "b")]))
        #expect(SwarmLanding.landed(tasks, facts: [
            "g/a": merged(1), "g/b": SwarmTaskFacts(criteriaMet: 1, criteriaTotal: 1),
        ]))
        #expect(SwarmLanding.mergedLine(tasks, facts: ["g/a": merged(1)]) == "1 of 2 merged")
    }

    @Test func aDoneRunEndsWithARowByHeedAndTheGoalStaysOpen() async throws {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        let started = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.proposePlan(swarm: started.id, input: SwarmPlanInput.parse("""
        [{"id": "a", "title": "A", "phase": "Build", "owner": "claude"},
         {"id": "b", "title": "B", "phase": "Build", "owner": "claude", "after": ["a"]}]
        """, goal: goal.id), now: now)
        try await ops.approvePlan(swarm: started.id, now: now)
        try await ops.advanceSwarm(started.id, to: .running, now: now)
        try await ops.startWorker(swarm: started.id, SwarmWorker(
            id: "w-b", task: "faster-builds/b", owner: GoalItem.Owner(agent: "claude"), host: "lead",
            repo: "acme/site", branch: "swarm/faster-builds/b", base: "swarm/faster-builds/a",
            stackedOn: "faster-builds/a", worktree: "/wt/b", startedAt: now
        ), text: "1.2 B: claude stacked on 1.1's PR", now: now)
        // a merged: b moves to main, recorded on its worker and as a row by heed.
        let move = SwarmLanding.Retarget(
            task: "faster-builds/b", pr: 8, parent: "faster-builds/a", parentPR: 7, from: "swarm/faster-builds/a",
            to: "main", stackedOn: nil, edit: true
        )
        var run = try await ops.retargeted(swarm: started.id, move, now: now + 10)
        #expect(run.lastWorker(on: "faster-builds/b")?.base == "main")
        #expect(run.lastWorker(on: "faster-builds/b")?.stackedOn == nil)
        var board = try await ops.board(of: started.id)
        let row = try #require(board.steering.last)
        #expect(row.kind == .retarget && row.actor == .heed)
        #expect(row.text == "#8 now goes against main: #7 merged (was swarm/faster-builds/a)")
        #expect(row.ref == "task:faster-builds/b")
        try await ops.retargetFailed(swarm: started.id, move, error: "gh: not found", now: now + 20)
        board = try await ops.board(of: started.id)
        #expect(board.steering.last?.text == "Could not move #8 to main")
        #expect(board.steering.last?.reason == "gh: not found")
        // Every task merged: done, its end recorded; the goal itself stays active.
        run = try await ops.advanceSwarm(started.id, to: .done, now: now + 60)
        #expect(run.status == .done && run.endedAt == now + 60)
        board = try await ops.board(of: started.id)
        #expect(board.steering.last?.kind == .land)
        #expect(board.steering.last?.text == "Done: every task merged, in merge order")
        #expect(try await ops.snapshot().goal(goal.id)?.status == .active)
    }

    @Test func theLandingFixtureHoldsBothChildrenAndTheDoneOneMovedThem() {
        let landing = SwarmFixtures.running(.landing, now: now)
        let tasks = SwarmPlan.grouped(SwarmFixtures.all(now: now).first { $0.swarm.id == landing.swarm.id }?
            .versions.first { $0.number == 3 }?.tasks ?? [])
        let facts = SwarmFacts.build(
            swarm: landing.swarm, tasks: tasks, items: [], evidence: landing.evidence, steering: [],
            pulls: landing.pulls
        )
        let rows = SwarmLanding.rows(tasks, swarm: landing.swarm, facts: facts)
        #expect(rows.map(\.pr) == [412, 409, 416, 415])
        #expect(rows.map(\.state) == [.open, .merged, .held, .held])
        let done = SwarmFixtures.running(.done, now: now)
        #expect(done.swarm.status == .done)
        #expect(done.swarm.workers.allSatisfy { $0.base == "main" && $0.stackedOn == nil })
    }
}

struct SwarmLandingQueueTests {
    private let repo = Repo(org: "acme", name: "site")

    private func entry(_ number: Int, held: String? = nil, autoMerge: Bool = false) -> MergeQueue.Entry {
        var detail = PullDetail(
            ref: PullRef(repo: repo, number: number), title: "", body: "", author: nil, baseBranch: "main",
            headBranch: "b\(number)", additions: 0, deletions: 0, commitCount: 1, headSHA: "s\(number)",
            reviews: [], threads: [], failingChecks: [], checks: CheckSummary(passed: 2), closes: [],
            fetchedAt: now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "CLEAN"
        detail.repoAllowsAutoMerge = true
        detail.repoMergeMethods = ["squash"]
        detail.autoMergeEnabled = autoMerge
        return MergeQueue.Entry(
            ref: PullRef(repo: repo, number: number), detail: detail, settings: PilotSettings(), paused: false,
            now: now, held: held
        )
    }

    @Test func aHeldPRIsHeldAndLosesAutoMerge() {
        #expect(MergeQueue.action(for: entry(415, held: "after #412")) == .hold("after #412"))
        #expect(MergeQueue.action(for: entry(415, held: "after #412", autoMerge: true))
            == .disableAutoMerge(reason: "after #412"))
        // Not held: green gets auto-merge as before.
        #expect(MergeQueue.action(for: entry(412)) == .enableAutoMerge(method: "squash"))
    }

    @Test func theSwarmsOrderTakesThePlacesItsPRsHoldAmongTheRest() {
        let ref = { (number: Int) in PullRef(repo: repo, number: number) }
        // 300 and 500 are unrelated; the swarm's order is 416, 412, 415.
        let refs = [500, 415, 300, 412, 416].map(ref)
        #expect(MergeQueue.sorted(refs, order: [416, 412, 415].map(ref)).map(\.number) == [300, 416, 412, 415, 500])
        #expect(MergeQueue.sorted(refs, order: nil).map(\.number) == [300, 412, 415, 416, 500])
        let steps = MergeQueue.plan([entry(415), entry(412), entry(300)], order: [412, 415].map(ref))
        #expect(steps.map(\.ref.number) == [300, 412, 415])
        let reversed = MergeQueue.plan([entry(415), entry(412), entry(300)], order: [415, 412].map(ref))
        #expect(reversed.map(\.ref.number) == [300, 415, 412])
    }
}

struct SwarmLandingMirrorTests {
    private func item(_ slug: String, after: [String] = [], prs: [String] = []) -> GoalItem {
        GoalItem(
            id: "g/\(slug)", goal: "g", title: slug.capitalized, source: .swarm,
            links: prs.map { GoalItem.Link(.pr, $0) }, createdAt: now, after: after.map { "g/\($0)" }
        )
    }

    @Test func aSubIssueSaysWhatItComesAfter() {
        let items = [item("a"), item("b"), item("c", after: ["a", "b"])]
        #expect(SwarmLanding.mirrorAfter(items[2], items: items, issues: ["g/a": 12, "g/b": 14]) == "After #12, #14.")
        // No issue yet: its title.
        #expect(SwarmLanding.mirrorAfter(items[2], items: items, issues: ["g/a": 12]) == "After #12, B.")
        #expect(SwarmLanding.mirrorAfter(items[0], items: items, issues: [:]) == nil)
    }

    @Test func theMetaIssueShowsTheMergeOrderAndState() {
        let tasks = [task("a"), task("iso"), task("c", after: ["a"])]
        let items = [item("a", prs: ["acme/site#412"]), item("iso"), item("c", after: ["a"], prs: ["acme/site#415"])]
        let evidence = [GoalEvidence(
            goal: "g", item: "g/a", kind: .merged, state: .done, at: now, source: "#412", text: "merged",
            ref: "acme/site#412"
        )]
        let lines = SwarmLanding.mirrorSection(
            swarm([]), tasks: tasks, items: items, evidence: evidence, issues: ["g/a": 12, "g/c": 13]
        )
        #expect(lines == [
            "## Swarm 1",
            "",
            "State: **landing** · 1 of 3 merged · merge order:",
            "",
            "1. A (#12) · merged acme/site#412",
            "2. Iso · no PR yet · any order",
            "3. C (#13) · PR acme/site#415 · after #12",
            "",
        ])
    }
}

struct SwarmLandingGitHubTests {
    @Test func retargetingIsOneEditOfTheBaseAndNothingElse() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-retarget-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let args = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        exit 0
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try await GitHub.$executable.withValue(script.path) {
            try await GitHub.retarget(
                PullRef(repo: Repo(org: "acme", name: "site"), number: 415), base: "main", caller: "swarm.land"
            )
        }
        let sent = try String(contentsOf: args, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(sent == ["pr", "edit", "415", "--base", "main", "-R", "acme/site"])
    }
}

struct SwarmLandingMirrorSpecTests {
    @Test func theIssuesCarryTheSwarmSectionAndAfterLine() {
        let goal = HeedGoal(id: "g", title: "G", createdAt: now)
        let meta = GoalMirrorRender.meta(
            goal: goal, doc: GoalDoc(title: "G"), lenses: [], pulls: ["acme/site#7"], swarm: ["## Swarm 1", ""]
        )
        #expect(meta.body.contains("## Swarm 1\n\n## Pull requests"))
        let item = GoalItem(id: "g/b", goal: "g", title: "B", source: .swarm, createdAt: now, after: ["g/a"])
        let spec = GoalMirrorRender.item(
            item, goal: goal, column: .planned, marks: [:], evidence: [], after: "After #12."
        )
        #expect(spec.body.contains("\n\nAfter #12.\n"))
    }
}
