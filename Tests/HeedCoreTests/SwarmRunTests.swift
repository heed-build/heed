import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func task(
    _ slug: String, phase: String = "Build", owner: String? = "claude", after: [String] = [], done: [String] = []
) -> SwarmTask {
    SwarmTask(
        id: "g/\(slug)", title: slug.capitalized, phase: phase, owner: owner.map { GoalItem.Owner(agent: $0) },
        after: after.map { "g/\($0)" }, doneWhen: done
    )
}

private func swarm(
    status: GoalSwarm.Status = .running, agents: Int = 3, hours: Double = 4, dollars: Double = 40,
    workers: [SwarmWorker] = []
) -> GoalSwarm {
    GoalSwarm(
        id: "g/swarm-1", goal: "g", number: 1, status: status,
        settings: SwarmSettings(
            repos: ["acme/site"], workers: [SwarmSettings.Worker(agent: "claude", count: 2)],
            limits: SwarmSettings.Limits(agents: agents, hours: hours, dollars: dollars)
        ),
        plan: 1, approved: 1, startedAt: now, runningAt: status == .planning ? nil : now, workers: workers
    )
}

private func worker(
    _ slug: String, id: String? = nil, agent: String = "claude", ended: Date? = nil,
    outcome: SwarmWorker.Outcome? = nil, cost: Double? = nil, startedAt: Date = now
) -> SwarmWorker {
    SwarmWorker(
        id: id ?? "w-\(slug)", task: "g/\(slug)", owner: GoalItem.Owner(agent: agent), host: "lead",
        repo: "acme/site", branch: "swarm/g/\(slug)", base: "main", worktree: "/wt/\(slug)", startedAt: startedAt,
        endedAt: ended, outcome: outcome, costUSD: cost
    )
}

private func pull(
    _ number: Int, branch: String, state: PullRequest.State = .open, draft: Bool = false, passed: Int = 3,
    failed: Int = 0, pending: Int = 0, repo: String = "acme/site"
) -> PullRequest {
    PullRequest(
        ref: PullRef(
            repo: Repo(org: String(repo.split(separator: "/")[0]), name: String(repo.split(separator: "/")[1])),
            number: number
        ), title: "PR \(number)", url: "", state: state,
        isDraft: draft, headBranch: branch, review: nil,
        checks: CheckSummary(passed: passed, failed: failed, pending: pending), unresolvedThreads: 0, updatedAt: now
    )
}

private func open(_ number: Int, _ branch: String, _ checks: SwarmTaskFacts.PR.Checks = .passing)
    -> SwarmTaskFacts
{
    SwarmTaskFacts(pr: .open(number: number, branch: branch, checks: checks))
}

struct SwarmBaseTests {
    private let numbers = ["g/a": "1.1", "g/b": "1.2", "g/c": "2.1"]

    @Test func aTaskWithNothingOpenBeforeItStartsFromTheDefaultBranch() {
        #expect(SwarmScheduler.base(task("a"), facts: [:], numbers: numbers, defaultBranch: "main")
            == .start(base: "main", stackedOn: nil))
        let merged = ["g/a": SwarmTaskFacts(pr: .merged(number: 4))]
        #expect(SwarmScheduler.base(task("c", after: ["a"]), facts: merged, numbers: numbers, defaultBranch: "trunk")
            == .start(base: "trunk", stackedOn: nil))
        // Done with no PR (a survey): nothing to stack on, nothing to wait for.
        let done = ["g/a": SwarmTaskFacts(criteriaMet: 1, criteriaTotal: 1)]
        #expect(SwarmScheduler.base(task("c", after: ["a"]), facts: done, numbers: numbers, defaultBranch: "main")
            == .start(base: "main", stackedOn: nil))
    }

    @Test func aTaskStacksOnItsBlockersBranchAsSoonAsItsPROpens() {
        let facts = ["g/a": open(7, "swarm/g/a", .running), "g/b": SwarmTaskFacts(pr: .merged(number: 5))]
        #expect(SwarmScheduler.base(task("c", after: ["a", "b"]), facts: facts, numbers: numbers, defaultBranch: "main")
            == .start(base: "swarm/g/a", stackedOn: "g/a"))
        // Failing checks do not hold the stack back: the PR is open.
        let failing = ["g/a": open(7, "swarm/g/a", .failing)]
        #expect(SwarmScheduler.base(task("c", after: ["a"]), facts: failing, numbers: numbers, defaultBranch: "main")
            == .start(base: "swarm/g/a", stackedOn: "g/a"))
    }

    @Test func aTaskWaitsForBlockersWithNoPRTwoOpenPRsOrOneClosed() {
        let none = SwarmScheduler.base(task("c", after: ["a"]), facts: [:], numbers: numbers, defaultBranch: "main")
        #expect(none == .wait("after 1.1 (no PR yet)"))
        let two = ["g/a": open(7, "swarm/g/a"), "g/b": open(8, "swarm/g/b")]
        #expect(SwarmScheduler.base(task("c", after: ["a", "b"]), facts: two, numbers: numbers, defaultBranch: "main")
            == .wait("after 1.1 and 1.2: two open PRs, it starts when one merges"))
        let closed = ["g/a": SwarmTaskFacts(pr: .closed(number: 7))]
        #expect(SwarmScheduler.base(task("c", after: ["a"]), facts: closed, numbers: numbers, defaultBranch: "main")
            == .wait("after 1.1 (its PR closed unmerged)"))
        // A blocker with an open PR and another with none: it waits for the one with none.
        let mixed = ["g/a": open(7, "swarm/g/a")]
        #expect(SwarmScheduler.base(task("c", after: ["a", "b"]), facts: mixed, numbers: numbers, defaultBranch: "main")
            == .wait("after 1.2 (no PR yet)"))
    }
}

struct SwarmScheduleTests {
    @Test func readyTasksStartInPlanOrderUpToTheFreeSlots() {
        let tasks = [task("a"), task("b"), task("c"), task("d", after: ["a"])]
        let schedule = SwarmScheduler.schedule(
            swarm(agents: 3), tasks: tasks, facts: [:], usage: .init(live: 1), defaultBranch: "main", now: now
        )
        #expect(schedule.starts.map(\.task) == ["g/a", "g/b"])
        #expect(schedule.starts.allSatisfy { $0.base == "main" && $0.stackedOn == nil })
        #expect(schedule.states["g/c"] == SwarmTaskStatus(.ready, "3 of 3 agents at work", base: "main"))
        #expect(schedule.states["g/d"]?.state == .waiting)
        #expect(schedule.limit == nil)
    }

    @Test func nothingStartsBeforeApprovalWhilePausedOrOnceStopped() {
        let tasks = [task("a")]
        var planning = swarm(status: .planning)
        planning.approved = nil
        for run in [planning, swarm(status: .paused), swarm(status: .stopped)] {
            let schedule = SwarmScheduler.schedule(
                run, tasks: tasks, facts: [:], usage: .init(), defaultBranch: "main", now: now
            )
            #expect(schedule.starts.isEmpty)
            #expect(schedule.states["g/a"]?.state == .ready)
        }
        let approved = SwarmScheduler.schedule(
            swarm(status: .planning), tasks: tasks, facts: [:], usage: .init(), defaultBranch: "main", now: now
        )
        #expect(approved.starts.map(\.task) == ["g/a"])
        #expect(SwarmScheduler.schedule(
            swarm(status: .paused), tasks: tasks, facts: [:], usage: .init(), defaultBranch: "main", now: now
        ).states["g/a"]?.reason == "the swarm is paused")
    }

    @Test func reachingHoursOrDollarsStopsStartsAndSaysWhich() {
        let tasks = [task("a")]
        let hours = SwarmScheduler.schedule(
            swarm(hours: 2), tasks: tasks, facts: [:], usage: .init(elapsed: 2 * 3600), defaultBranch: "main",
            now: now
        )
        #expect(hours.limit == .hours)
        #expect(hours.starts.isEmpty)
        #expect(hours.states["g/a"]?.reason == "the swarm reached its 2 h limit")
        let dollars = SwarmScheduler.schedule(
            swarm(dollars: 10), tasks: tasks, facts: [:], usage: .init(dollars: 10.5), defaultBranch: "main", now: now
        )
        #expect(dollars.limit == .dollars)
        let under = SwarmScheduler.schedule(
            swarm(hours: 2, dollars: 10), tasks: tasks, facts: [:], usage: .init(dollars: 9.99, elapsed: 7199),
            defaultBranch: "main", now: now
        )
        #expect(under.limit == nil)
        #expect(under.starts.count == 1)
    }

    @Test func aRateLimitedAgentsTasksWaitUntilTheReset() {
        let tasks = [task("a", owner: "claude"), task("b", owner: "codex")]
        let later = SwarmScheduler.schedule(
            swarm(), tasks: tasks, facts: [:], usage: .init(limited: ["claude": now + 600]), defaultBranch: "main",
            now: now
        )
        #expect(later.starts.map(\.task) == ["g/b"])
        #expect(later.states["g/a"]?.reason?.hasPrefix("claude is rate limited until ") == true)
        let unknown = SwarmScheduler.schedule(
            swarm(), tasks: tasks, facts: [:], usage: .init(limited: ["claude": nil]), defaultBranch: "main", now: now
        )
        #expect(unknown.states["g/a"]?.reason == "claude is rate limited")
        let past = SwarmScheduler.schedule(
            swarm(), tasks: tasks, facts: [:], usage: .init(limited: ["claude": now - 1]), defaultBranch: "main",
            now: now
        )
        #expect(past.starts.map(\.task) == ["g/a", "g/b"])
        // No owner: the team's first agent.
        let unowned = SwarmScheduler.schedule(
            swarm(), tasks: [task("c", owner: nil)], facts: [:], usage: .init(limited: ["claude": nil]),
            defaultBranch: "main", now: now
        )
        #expect(unowned.starts.isEmpty)
    }

    @Test func everyTaskSaysWhereItStands() {
        let tasks = [
            task("working"), task("paused"), task("stalled"), task("draft"), task("failing"), task("green"),
            task("merged", done: ["x"]), task("done", done: ["x"]), task("closed"), task("waits", after: ["paused"]),
        ]
        var asking = worker("working")
        asking.stackedOn = "g/green"
        let facts: [String: SwarmTaskFacts] = [
            "g/working": SwarmTaskFacts(worker: asking, workerState: .asking),
            "g/paused": SwarmTaskFacts(paused: true),
            "g/stalled": SwarmTaskFacts(stalled: .turnOver),
            "g/draft": open(1, "b1", .draft),
            "g/failing": open(2, "b2", .failing),
            "g/green": open(3, "b3"),
            "g/merged": SwarmTaskFacts(pr: .merged(number: 4), criteriaMet: 0, criteriaTotal: 1),
            "g/done": SwarmTaskFacts(pr: .merged(number: 5), criteriaMet: 1, criteriaTotal: 1),
            "g/closed": SwarmTaskFacts(pr: .closed(number: 6)),
        ]
        let states = SwarmScheduler.schedule(
            swarm(agents: 10), tasks: tasks, facts: facts, usage: .init(), defaultBranch: "main", now: now
        ).states
        #expect(states["g/working"] == SwarmTaskStatus(.working, "asking", base: "main", stackedOn: "g/green"))
        #expect(states["g/paused"] == SwarmTaskStatus(.paused, "paused by you"))
        #expect(states["g/stalled"] == SwarmTaskStatus(.stalled, "its worker ended without a PR (its turn is over)"))
        #expect(states["g/draft"] == SwarmTaskStatus(.pr, "#1 draft"))
        #expect(states["g/failing"] == SwarmTaskStatus(.pr, "#2 CI failing"))
        #expect(states["g/green"] == SwarmTaskStatus(.green, "#3 green"))
        #expect(states["g/merged"] == SwarmTaskStatus(.merged, "#4 merged · done when 0 of 1"))
        #expect(states["g/done"] == SwarmTaskStatus(.done, "#5 merged"))
        #expect(states["g/closed"] == SwarmTaskStatus(.stalled, "#6 closed without merging"))
        #expect(states["g/waits"] == SwarmTaskStatus(.waiting, "after 1.2 (no PR yet)"))
    }

    @Test func aTaskIsDoneWhenItsDoneWhenHasEvidenceAndNothingOfItIsStillOpen() {
        #expect(SwarmTaskFacts(criteriaMet: 2, criteriaTotal: 2).done)
        #expect(!SwarmTaskFacts(criteriaMet: 1, criteriaTotal: 2).done)
        #expect(!SwarmTaskFacts(pr: .open(number: 1, branch: "b", checks: .passing), criteriaMet: 1, criteriaTotal: 1)
            .done)
        #expect(SwarmTaskFacts(pr: .merged(number: 1)).done)
        #expect(!SwarmTaskFacts(pr: .merged(number: 1), criteriaTotal: 1).done)
        #expect(!SwarmTaskFacts().done)
    }
}

struct SwarmStatusTests {
    private let tasks = [task("a"), task("b")]

    private func status(_ run: GoalSwarm, _ states: [SwarmTaskStatus.State], starts: Int = 0, limit: SwarmLimit? = nil)
        -> GoalSwarm.Status?
    {
        let schedule = SwarmScheduler.Schedule(
            states: Dictionary(uniqueKeysWithValues: zip(tasks.map(\.id), states.map { SwarmTaskStatus($0) })),
            starts: (0 ..< starts).map { SwarmScheduler.Start(task: tasks[$0].id, base: "main") }, limit: limit
        )
        return SwarmScheduler.status(run, schedule: schedule, tasks: tasks)
    }

    @Test func approvedItRunsOnceAWorkerStartsAndLandsOnceEveryTaskHasAPR() {
        #expect(status(swarm(status: .planning), [.ready, .waiting]) == nil)
        #expect(status(swarm(status: .planning), [.ready, .waiting], starts: 1) == .running)
        var unapproved = swarm(status: .planning)
        unapproved.approved = nil
        #expect(status(unapproved, [.ready, .ready], starts: 2) == nil)
        #expect(status(swarm(), [.pr, .working]) == nil)
        #expect(status(swarm(), [.pr, .green]) == .landing)
        // Every task merged: done (S3), from running or landing; the goal's own done rule is not touched.
        #expect(status(swarm(), [.merged, .done]) == .done)
        #expect(status(swarm(status: .landing), [.merged, .merged]) == .done)
        #expect(status(swarm(status: .landing), [.merged, .green]) == nil)
        #expect(status(swarm(status: .landing), [.pr, .green]) == nil)
        #expect(status(swarm(status: .landing), [.pr, .stalled]) == .running)
    }

    @Test func aLimitPausesItButYourPauseAndItsEndStay() {
        #expect(status(swarm(), [.working, .ready], limit: .hours) == .paused)
        #expect(status(swarm(status: .landing), [.pr, .pr], limit: .dollars) == .paused)
        #expect(status(swarm(status: .paused), [.ready, .ready], starts: 0) == nil)
        #expect(status(swarm(status: .stopped), [.pr, .pr]) == nil)
        #expect(status(swarm(status: .done), [.ready, .ready]) == nil)
    }

    @Test func progressCountsDoneTasksAndLiveAgents() {
        let run = swarm(agents: 4, workers: [worker("a"), worker("b", ended: now)])
        let progress = SwarmProgress(
            swarm: run, tasks: tasks, states: ["g/a": SwarmTaskStatus(.done), "g/b": SwarmTaskStatus(.working)]
        )
        #expect(progress.tasksLine == "1 of 2 done")
        #expect(progress.agentsLine == "1 live · max 4")
    }

    @Test func usageAddsWorkerCostsAndCountsHoursFromTheFirstWorker() {
        let run = swarm(workers: [worker("a", cost: 1.5), worker("b", ended: now, cost: 2)])
        let usage = SwarmScheduler.Usage.of(run, limited: [:], now: now + 1800)
        #expect(usage.live == 1)
        #expect(usage.dollars == 3.5)
        #expect(usage.elapsed == 1800)
        #expect(SwarmScheduler.Usage.of(swarm(status: .planning), limited: [:], now: now + 60).elapsed == 0)
    }

    @Test func raisingALimitAddsHalfAgainRoundedUp() {
        let limits = SwarmSettings.Limits(agents: 3, hours: 4, dollars: 40)
        #expect(limits.raised(.hours).hours == 6)
        #expect(limits.raised(.hours).dollars == 40)
        #expect(limits.raised(.dollars).dollars == 60)
        #expect(SwarmSettings.Limits(hours: 1, dollars: 3).raised(.hours).hours == 2)
        // A zero limit still gets something.
        #expect(SwarmSettings.Limits(hours: 0, dollars: 0).raised(.hours).hours == 1)
        #expect(SwarmSettings.Limits(hours: 0, dollars: 0).raised(.dollars).dollars == 5)
        #expect(SwarmSettings.Limits(hours: 1, dollars: 3).raised(.dollars).dollars == 8)
        #expect(SwarmSettings.Limits(hours: 3, dollars: 30).raised(.hours).hours == 5)
        #expect(SwarmSettings.Limits(hours: 3, dollars: 33).raised(.dollars).dollars == 53)
    }
}

struct SwarmFactsTests {
    private func items(_ tasks: [SwarmTask]) -> [GoalItem] {
        tasks.map { task in
            GoalItem(
                id: task.id, goal: "g", title: task.title, source: .swarm, createdAt: now, after: task.after,
                doneWhen: task.doneWhen, phase: task.phase
            )
        }
    }

    @Test func aTasksPRIsFoundByItsBranchInTheSwarmsReposOrByItsLink() {
        let tasks = [task("a"), task("b"), task("c")]
        var list = items(tasks)
        list[2].links = [GoalItem.Link(.pr, "acme/other#40")]
        let facts = SwarmFacts.build(
            swarm: swarm(), tasks: tasks, items: list, evidence: [], steering: [],
            pulls: [
                pull(10, branch: "swarm/g/a", pending: 1),
                pull(11, branch: "swarm/g/b", repo: "acme/elsewhere"),
                pull(40, branch: "whatever", repo: "acme/other"),
            ]
        )
        #expect(facts["g/a"]?.pr == .open(number: 10, branch: "swarm/g/a", checks: .running))
        #expect(facts["g/b"]?.pr == SwarmTaskFacts.PR.none)
        #expect(facts["g/c"]?.pr == .open(number: 40, branch: "whatever", checks: .passing))
    }

    @Test func anOpenPRWinsOverAClosedOneAndChecksReadAsTheyAre() {
        let pr = SwarmFacts.pullFacts(
            branches: ["b"], refs: [], repos: [],
            pulls: [pull(3, branch: "b", state: .closed), pull(2, branch: "b", failed: 1)]
        )
        #expect(pr == .open(number: 2, branch: "b", checks: .failing))
        #expect(SwarmFacts.pullFacts(branches: ["b"], refs: [], repos: [], pulls: [pull(2, branch: "b", draft: true)])
            == .open(number: 2, branch: "b", checks: .draft))
        #expect(SwarmFacts.pullFacts(branches: ["b"], refs: [], repos: [], pulls: [pull(2, branch: "b", passed: 0)])
            == .open(number: 2, branch: "b", checks: .running))
        #expect(SwarmFacts.pullFacts(
            branches: ["b"], refs: [], repos: [], pulls: [pull(2, branch: "b", state: .merged), pull(
                5,
                branch: "b",
                state: .closed
            )]
        ) == .merged(number: 2))
    }

    @Test func doneWhenCountsCriterionEvidenceForItsOwnLines() {
        let tasks = [task("a", done: ["it builds", "docs say so"])]
        let evidence = [
            GoalEvidence(goal: "g", item: "g/a", kind: .criterion, at: now, source: "w", text: "It builds."),
            GoalEvidence(goal: "g", item: "g/a", kind: .criterion, at: now, source: "w", text: "something else"),
            GoalEvidence(goal: "g", item: "g/b", kind: .criterion, at: now, source: "w", text: "docs say so"),
        ]
        let facts = SwarmFacts.build(
            swarm: swarm(), tasks: tasks, items: items(tasks), evidence: evidence, steering: [], pulls: []
        )
        #expect(facts["g/a"]?.criteriaMet == 1)
        #expect(facts["g/a"]?.criteriaTotal == 2)
    }

    @Test func aWorkerThatEndedWithoutAPRStallsItsTaskUntilYouResumeIt() {
        let tasks = [task("a"), task("b")]
        let run = swarm(workers: [worker("a", ended: now + 60, outcome: .turnOver), worker("b")])
        func steer(_ kind: SwarmSteer.Kind, _ slug: String, at: Date) -> SwarmSteer {
            SwarmSteer(
                swarm: run.id, goal: "g", at: at, actor: .you, kind: kind, text: "", ref: "task:g/\(slug)"
            )
        }
        let stalled = SwarmFacts.build(
            swarm: run, tasks: tasks, items: items(tasks), evidence: [], steering: [], pulls: [],
            states: ["w-b": .asking]
        )
        #expect(stalled["g/a"]?.stalled == .turnOver)
        #expect(stalled["g/b"]?.worker?.id == "w-b")
        #expect(stalled["g/b"]?.workerState == .asking)
        let resumed = SwarmFacts.build(
            swarm: run, tasks: tasks, items: items(tasks), evidence: [],
            steering: [steer(.pause, "a", at: now + 100), steer(.resume, "a", at: now + 120)], pulls: []
        )
        #expect(resumed["g/a"]?.stalled == nil)
        #expect(resumed["g/a"]?.paused == false)
        let paused = SwarmFacts.build(
            swarm: run, tasks: tasks, items: items(tasks), evidence: [],
            steering: [steer(.resume, "a", at: now + 30), steer(.pause, "a", at: now + 100)], pulls: []
        )
        // Resumed before the worker ended: it still stalls. Paused after: paused.
        #expect(paused["g/a"]?.stalled == .turnOver)
        #expect(paused["g/a"]?.paused == true)
        // With a PR, a worker that ended is not stalling anything.
        let landed = SwarmFacts.build(
            swarm: run, tasks: tasks, items: items(tasks), evidence: [], steering: [],
            pulls: [pull(9, branch: "swarm/g/a")]
        )
        #expect(landed["g/a"]?.stalled == nil)
    }

    @Test func blockersOutsideThePlanAreKnownByTheirEvidence() {
        let tasks = [task("a", after: ["outside"])]
        let merged = GoalEvidence(goal: "g", item: "g/outside", kind: .merged, at: now, source: "#3")
        let facts = SwarmFacts.build(
            swarm: swarm(), tasks: tasks, items: items(tasks), evidence: [merged], steering: [], pulls: []
        )
        #expect(facts["g/outside"]?.merged == true)
        let schedule = SwarmScheduler.schedule(
            swarm(), tasks: tasks, facts: facts, usage: .init(), defaultBranch: "main", now: now
        )
        #expect(schedule.starts.map(\.task) == ["g/a"])
    }
}

struct SwarmWorkTests {
    @Test func branchesAndWorktreesAreTheTasksOwn() {
        #expect(SwarmWork.branch(of: task("heading-ids"), goal: "anchors") == "swarm/anchors/heading-ids")
        #expect(!Runs.isRunBranch("swarm/anchors/heading-ids"))
        #expect(!SwarmWork.branch(goal: "g", slug: "a").hasPrefix(Runs.prefix))
        #expect(SwarmWork.worktreePath(root: "/wt", repo: Repo(org: "acme", name: "site"), goal: "anchors", slug: "ids")
            == "/wt/heed/site/swarm-anchors-ids")
        #expect(SwarmWork.title(number: "1.2") == "swarm 1.2")
    }

    @Test func thePromptNamesTheBaseItsPRGoesAgainstAndHowToReport() {
        let task = task("b", after: ["a"], done: ["it builds"])
        let stacked = SwarmWork.prompt(
            task: task, number: "1.2", swarm: swarm(), goal: "Faster builds", doc: "~/goals/g/GOAL.md",
            branch: "swarm/g/b", base: "swarm/g/a", stackedOn: ("1.1", "A"), numbers: ["g/a": "1.1"]
        )
        #expect(stacked.contains("Your task: 1.2 B (item g/b)."))
        #expect(stacked.contains("1. it builds"))
        #expect(stacked.contains("It comes after 1.1."))
        #expect(stacked.contains("made from swarm/g/a"))
        #expect(stacked.contains("goes against swarm/g/a, not the default branch"))
        #expect(stacked.contains("gh pr create --base swarm/g/a --head swarm/g/b"))
        #expect(stacked.contains("heed goal criterion check <n> --item g/b"))
        #expect(stacked.contains("heed goal link pr <its URL> --item g/b"))
        #expect(!stacked.contains("take over"))
        let plain = SwarmWork.prompt(
            task: SwarmTask(id: "g/c", title: "C", phase: "x"), number: "2.1", swarm: swarm(), goal: "G", doc: "d",
            branch: "swarm/g/c", base: "main", stackedOn: nil, numbers: [:], handoff: "codex"
        )
        #expect(plain.hasPrefix("You take over this task from codex"))
        #expect(plain.contains("gh pr create --base main --head swarm/g/c"))
        #expect(!plain.contains("not the default branch"))
        #expect(!plain.contains("criterion check"))
    }

    @Test func pausesAreTheNewestRowAboutEachTask() {
        func row(_ kind: SwarmSteer.Kind, _ ref: String?) -> SwarmSteer {
            SwarmSteer(swarm: "s", goal: "g", at: now, actor: .you, kind: kind, text: "", ref: ref)
        }
        let rows = [
            row(.pause, "task:g/a"), row(.pause, "task:g/b"), row(.resume, "task:g/a"), row(.pause, nil),
            row(.edit, "task:g/c"),
        ]
        #expect(SwarmSteering.pausedTasks(rows) == ["g/b"])
        #expect(SwarmSteering.resumedAt(rows).keys.sorted() == ["g/a"])
    }

    @Test func aDroppedSwarmItemWearsDroppedAndATakenInOneGoesBack() {
        var item = GoalItem(id: "g/a", goal: "g", title: "A", source: .swarm, createdAt: now, phase: "Build")
        #expect(Board.badge(item, evidence: []) == .swarm)
        item.phase = nil
        #expect(SwarmDropped.isDropped(item))
        #expect(Board.badge(item, evidence: []) == .dropped)
        let taken = GoalItem(id: "g/b", goal: "g", title: "B", source: .you, createdAt: now)
        #expect(!SwarmDropped.isDropped(taken))
        #expect(Board.badge(taken, evidence: []) == .item)
    }

    @Test func aRunStoredBeforeWorkersStillReads() throws {
        let old = """
        {"id": "g/swarm-1", "goal": "g", "number": 1, "status": "planning", "plan": 2, "approved": 2,
         "startedAt": 1800000000, "settings": {"repos": [], "lead": {"agent": "claude"}, "workers": [],
         "limits": {"agents": 4, "hours": 4, "dollars": 40}, "autonomy": "planChanges"}}
        """
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let run = try decoder.decode(GoalSwarm.self, from: Data(old.utf8))
        #expect(run.workers.isEmpty)
        #expect(run.runningAt == nil && run.held == nil)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let full = swarm(workers: [worker("a", outcome: .handedOff("codex"))])
        #expect(try decoder.decode(GoalSwarm.self, from: encoder.encode(full)) == full)
    }
}

struct SwarmRunOpsTests {
    private func world() async throws -> (GoalOps, GoalSwarm) {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        let started = try await ops.startSwarm(
            goal: goal.id, settings: SwarmSettings(limits: SwarmSettings.Limits(agents: 2, hours: 4, dollars: 40)),
            now: now
        )
        try await ops.proposePlan(swarm: started.id, input: SwarmPlanInput.parse("""
        [{"id": "a", "title": "A", "phase": "Build", "owner": "claude", "doneWhen": ["it builds"]},
         {"id": "b", "title": "B", "phase": "Build", "owner": "claude", "after": ["a"]}]
        """, goal: goal.id), now: now)
        try await ops.approvePlan(swarm: started.id, now: now)
        return try await (ops, ops.board(of: started.id).swarm)
    }

    private func worker(_: GoalSwarm, task: String, id: String) -> SwarmWorker {
        SwarmWorker(
            id: id, task: "faster-builds/\(task)", owner: GoalItem.Owner(agent: "claude"), host: "lead",
            repo: "acme/site", branch: "swarm/faster-builds/\(task)", base: "main", worktree: "/wt/\(task)",
            startedAt: now
        )
    }

    @Test func workersAreRecordedOnTheRunTheirItemAndTheLog() async throws {
        let (ops, run) = try await world()
        try await ops.startWorker(
            swarm: run.id,
            worker(run, task: "a", id: "w1"),
            text: "1.1 A: claude from main",
            now: now
        )
        try await ops.advanceSwarm(run.id, to: .running, now: now)
        var board = try await ops.board(of: run.id)
        #expect(board.swarm.status == .running)
        #expect(board.swarm.runningAt == now)
        #expect(board.swarm.liveWorkers.map(\.id) == ["w1"])
        let item = try #require(try await ops.snapshot().item("faster-builds/a"))
        #expect(item.linked(.branch) == ["swarm/faster-builds/a"])
        #expect(try await Board.column(item, evidence: ops.snapshot().evidence) == .working)
        let ended = try await ops.endWorker(swarm: run.id, worker: "w1", outcome: .turnOver, cost: 1.25, now: now + 60)
        #expect(ended?.outcome == .turnOver)
        #expect(try await ops.endWorker(swarm: run.id, worker: "w1", outcome: .stopped, cost: nil, now: now) == nil)
        board = try await ops.board(of: run.id)
        #expect(board.swarm.workers.first?.costUSD == 1.25)
        #expect(board.steering.suffix(3).map(\.kind) == [.work, .start, .work])
        #expect(board.steering.last?.text == "claude on a ended: its turn is over")
    }

    @Test func aLimitPausesAndAskingForMoreRaisesItWhileNoKeepsItPaused() async throws {
        let (ops, run) = try await world()
        try await ops.advanceSwarm(run.id, to: .running, now: now)
        let paused = try await ops.advanceSwarm(run.id, to: .paused, limit: .hours, now: now + 60)
        #expect(paused.held == .hours)
        #expect(try await ops.snapshot().swarms.first?.held == .hours)
        let resumed = try await ops.resumeSwarm(run.id, now: now + 120)
        #expect(resumed.status == .running)
        #expect(resumed.held == nil)
        #expect(resumed.settings.limits.hours == 6)
        let rows = try await ops.board(of: run.id).steering.suffix(3)
        #expect(rows.map(\.kind) == [.limit, .limit, .resume])
        #expect(rows.map(\.actor) == [.heed, .you, .you])

        try await ops.advanceSwarm(run.id, to: .paused, limit: .dollars, now: now + 180)
        let kept = try await ops.keepPaused(run.id, now: now + 200)
        #expect(kept.status == .paused && kept.held == nil)
        // Resuming after a no gives nothing more: it is your plain resume.
        #expect(try await ops.resumeSwarm(run.id, now: now + 300).settings.limits.dollars == 40)
    }

    @Test func youPauseTheRunAndItsTasksAndSwapAnAgent() async throws {
        let (ops, run) = try await world()
        let paused = try await ops.pauseSwarm(run.id, now: now)
        #expect(paused.status == .paused && paused.held == nil)
        // Paused before anything ran, it goes back to planning.
        #expect(try await ops.resumeSwarm(run.id, now: now + 1).status == .planning)
        try await ops.pauseTask(swarm: run.id, task: "faster-builds/a", title: "A", paused: true, now: now)
        var board = try await ops.board(of: run.id)
        #expect(SwarmSteering.pausedTasks(board.steering) == ["faster-builds/a"])
        let version = try await ops.swapOwner(
            swarm: run.id, task: "faster-builds/a", owner: GoalItem.Owner(agent: "codex"), now: now
        )
        board = try await ops.board(of: run.id)
        #expect(version?.number == 2)
        #expect(board.swarm.isApproved)
        #expect(board.tasks.first?.owner?.agent == "codex")
        #expect(board.steering.last?.kind == .swap)
        #expect(board.steering.last?.text == "A: claude → codex")
        #expect(try await ops.snapshot().item("faster-builds/a")?.owner?.agent == "codex")
    }

    @Test func stoppingEndsItsWorkersAndALaunchInterruptsTheOnesLeft() async throws {
        let (ops, run) = try await world()
        try await ops.startWorker(swarm: run.id, worker(run, task: "a", id: "w1"), text: "", now: now)
        try await ops.stopSwarm(run.id, now: now + 60)
        let stopped = try await ops.board(of: run.id).swarm
        #expect(stopped.workers.map(\.outcome) == [.stopped])

        let ops2 = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops2.create(title: "Other", statement: "x", now: now)
        let other = try await ops2.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops2.startWorker(swarm: other.id, worker(other, task: "z", id: "w9"), text: "", now: now)
        try await ops2.interruptWorkers(now: now + 5)
        #expect(try await ops2.board(of: other.id).swarm.workers.map(\.outcome) == [.interrupted])
    }

    @Test func aWorkerChecksItsTasksDoneWhenAndAsksAsAnAgent() async throws {
        let (ops, swarm) = try await world()
        try await ops.attach(GoalLink(goal: swarm.goal, kind: .session, target: "lead", origin: .swarm, at: now))
        try await ops.setLead(swarm: swarm.id, session: "lead", now: now)
        let worker = GoalCaller(session: "lead", title: "Lead", worker: "faster-builds/a")
        func send(_ command: GoalCommand) async -> GoalReply? {
            if case let .reply(reply) = await GoalControl.run(
                command,
                caller: worker,
                ops: ops,
                files: .fixture,
                now: now
            ) { return reply }
            return nil
        }
        let checked = await send(GoalCommand(.criterionCheck, subject: "1", evidence: "swift build", item: "a"))
        #expect(checked?.outcome == "applied")
        #expect(checked?.message.contains("1 of 1 done-when met") == true)
        let evidence = try await ops.snapshot().evidence.filter { $0.kind == .criterion }
        #expect(evidence.map(\.text) == ["it builds"])
        #expect(evidence.first?.source == "swarm worker on a")
        let missing = await send(GoalCommand(.criterionCheck, subject: "9", evidence: "x", item: "a"))
        #expect(missing?.exit == .refused)
        _ = await send(GoalCommand(.ask, text: "Which cache?", options: ["a", "b"]))
        #expect(try await ops.board(of: swarm.id).steering.last?.actor == .agent)
    }

    @Test func aSwarmAtALimitAsksInAttention() async throws {
        let (ops, run) = try await world()
        try await ops.advanceSwarm(run.id, to: .paused, limit: .hours, now: now)
        let snapshot = try await ops.snapshot()
        let items = GoalAttention.items(
            goals: snapshot.goals, qualities: [:], waiting: [:], swarms: snapshot.swarms, now: now
        )
        let ask = try #require(items.first { $0.reasons == [.swarmAsk] })
        #expect(ask.id == "goal:faster-builds:swarm")
        #expect(ask.title.contains("paused at its 4 h limit (y: raise it to 6 h, n: keep it paused)"))
        #expect(GoalAttention.goal(of: ask) == "faster-builds")
        try await ops.keepPaused(run.id, now: now)
        let after = try await ops.snapshot()
        #expect(!GoalAttention.items(goals: after.goals, qualities: [:], waiting: [:], swarms: after.swarms, now: now)
            .contains { $0.reasons == [.swarmAsk] })
    }
}

struct SwarmWorkerCommandTests {
    @Test func criterionCheckTakesAnItemAndTheRequestCarriesThePane() throws {
        let command = try GoalCommandLine.parse(["goal", "criterion", "check", "1", "--item", "a", "--evidence", "ok"])
        #expect(command == GoalCommand(.criterionCheck, subject: "1", evidence: "ok", item: "a"))
        #expect(throws: (any Error).self) {
            try GoalCommandLine.parse(["goal", "criterion", "check", "1", "--item", "a"])
        }
        let request = try GoalCommandLine.request(
            ["goal", "show"], environment: [HeedEnvironment.sessionID: "s1", HeedEnvironment.pane: "p1"]
        )
        #expect(request.pane == "p1")
        let outside = try GoalCommandLine.request(["goal", "show"], environment: [HeedEnvironment.pane: "p1"])
        #expect(outside.pane == nil)
    }

    @Test func theSkillTeachesTheWorker() {
        let skill = HeedPlugin.skillText
        #expect(skill.contains("## Working on a swarm task"))
        #expect(skill.contains("gh pr create --base BASE --head BRANCH"))
        #expect(skill.contains("heed goal criterion check N --item ID --evidence TEXT"))
        for rule in GoalGuidance.workerRules {
            #expect(skill.contains(rule.text))
        }
    }
}
