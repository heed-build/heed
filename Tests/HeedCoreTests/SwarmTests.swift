import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func task(
    _ slug: String, _ title: String? = nil, phase: String = "Build", owner: String? = nil, estimate: Int? = nil,
    after: [String] = [], done: [String] = []
) -> SwarmTask {
    SwarmTask(
        id: "g/\(slug)", title: title ?? slug.capitalized, phase: phase,
        owner: owner.map { GoalItem.Owner(agent: $0) }, estimate: estimate, after: after.map { "g/\($0)" },
        doneWhen: done
    )
}

struct SwarmPlanTests {
    @Test func phasesKeepTheirFirstAppearanceAndNumberTheirTasks() {
        let tasks = [
            task("a", phase: "Spike"), task("b", phase: "Build"), task("c", phase: "Spike"), task("d", phase: "Build"),
        ]
        #expect(SwarmPlan.phases(tasks).map(\.name) == ["Spike", "Build"])
        #expect(SwarmPlan.grouped(tasks).map(\.slug) == ["a", "c", "b", "d"])
        let numbers = SwarmPlan.numbers(tasks)
        #expect(numbers["g/a"] == "1.1")
        #expect(numbers["g/c"] == "1.2")
        #expect(numbers["g/b"] == "2.1")
        #expect(numbers["g/d"] == "2.2")
    }

    @Test func orderPutsATaskAfterWhatItWaitsForAndOtherwiseKeepsPlanOrder() throws {
        let tasks = [
            task("tests", after: ["cache", "check"]),
            task("cache"),
            task("check", after: ["cache"]),
            task("docs"),
        ]
        let order = try #require(SwarmPlan.order(tasks)).map(\.slug)
        #expect(order == ["cache", "check", "tests", "docs"])
        // Waiting for an item that is not in the plan does not hold a task back.
        #expect(SwarmPlan.order([task("x", after: ["elsewhere"])])?.map(\.slug) == ["x"])
    }

    @Test func aCircleIsFoundAndNamedFromItsFirstTask() {
        let tasks = [task("a"), task("b", after: ["c"]), task("c", after: ["d"]), task("d", after: ["b"])]
        #expect(SwarmPlan.order(tasks) == nil)
        #expect(SwarmPlan.cycle(tasks) == ["g/b", "g/c", "g/d"])
        #expect(SwarmPlan.cycle([task("a"), task("b", after: ["a"])]) == nil)
        #expect(SwarmPlan.problems(tasks).contains(.cycle(["g/b", "g/c", "g/d"])))
        #expect(SwarmPlan.Problem.cycle(["g/b", "g/c"]).description.contains("g/b → g/c → g/b"))
    }

    @Test func problemsNameWhatIsWrong() {
        let tasks = [
            task("a", after: ["a"]), task("b", after: ["ghost"]), task("a"),
            SwarmTask(id: "g/c", title: "  ", phase: "Build"), task("d", after: ["known"]),
        ]
        let problems = SwarmPlan.problems(tasks, known: ["g/known"])
        #expect(problems.contains(.waitsForItself("g/a")))
        #expect(problems.contains(.unknownAfter(task: "g/b", after: "g/ghost")))
        #expect(problems.contains(.duplicate("g/a")))
        #expect(problems.contains(.noTitle(index: 3)))
        #expect(!problems.contains(.unknownAfter(task: "g/d", after: "g/known")))
        #expect(SwarmPlan.problems([]) == [.empty])
        #expect(SwarmPlan.problems([task("a"), task("b", after: ["a"])]).isEmpty)
    }

    @Test func theDiffSaysWhatWasAddedDroppedChangedAndMoved() {
        let old = [
            task("cache", owner: "claude", estimate: 55), task("check", done: ["a cold build passes"]), task("cli"),
            task("cold", phase: "Tests"),
        ]
        let new = [
            task("check", done: ["a warm build passes"]), task("cache", owner: "codex", estimate: 55), task("cli"),
            task("warm", phase: "Tests"),
        ]
        let changes = SwarmPlan.diff(old: old, new: new)
        #expect(changes.contains(.removed(old[3])))
        #expect(changes.contains(.added(new[3])))
        #expect(changes.contains(.changed(old: old[1], new: new[0], fields: [.doneWhen])))
        #expect(changes.contains(.changed(old: old[0], new: new[1], fields: [.owner])))
        // One of cache and check moved past the other; cli stayed where it was.
        #expect(changes.count { if case .moved = $0 { true } else { false } } == 1)
        #expect(!changes.contains(.moved(new[2])))
        #expect(SwarmPlan.diff(old: old, new: old).isEmpty)

        let lines = SwarmPlan.lines(old: old, new: new)
        #expect(lines.contains(SwarmPlan.DiffLine(mark: .removed, text: "2.1 Cold")))
        #expect(lines.contains(SwarmPlan.DiffLine(mark: .added, text: "2.1 Warm")))
        #expect(lines.contains(SwarmPlan.DiffLine(mark: .removed, text: "done when: a cold build passes")))
        #expect(lines.contains(SwarmPlan.DiffLine(mark: .added, text: "done when: a warm build passes")))
        #expect(lines.contains(SwarmPlan.DiffLine(mark: .added, text: "owner: codex")))
    }

    @Test func smallChangesApplyAndStructuralOnesWait() {
        let base = [task("a", owner: "claude", estimate: 10), task("b", after: ["a"], done: ["it builds"])]
        #expect(SwarmPlan.classify(old: base, new: base) == .none)
        var owner = base
        owner[0].owner = GoalItem.Owner(agent: "codex")
        #expect(SwarmPlan.classify(old: base, new: owner) == .small)
        var estimate = base
        estimate[0].estimate = 30
        #expect(SwarmPlan.classify(old: base, new: estimate) == .small)
        var phase = base
        phase[1].phase = "Later"
        #expect(SwarmPlan.classify(old: base, new: phase) == .small)
        #expect(SwarmPlan.classify(old: base, new: base.reversed()) == .small)
        #expect(SwarmPlan.classify(old: base, new: base + [task("c")]) == .structural)
        #expect(SwarmPlan.classify(old: base, new: [base[0]]) == .structural)
        var title = base
        title[0].title = "Something else"
        #expect(SwarmPlan.classify(old: base, new: title) == .structural)
        var after = base
        after[1].after = []
        #expect(SwarmPlan.classify(old: base, new: after) == .structural)
        var done = base
        done[1].doneWhen = ["it ships"]
        #expect(SwarmPlan.classify(old: base, new: done) == .structural)
    }

    @Test func movingCrossesIntoTheNextPhaseAtItsEdge() throws {
        let tasks = [task("a", phase: "One"), task("b", phase: "One"), task("c", phase: "Two")]
        #expect(try #require(SwarmPlan.move(tasks, at: 0, by: 1)).map(\.slug) == ["b", "a", "c"])
        let down = try #require(SwarmPlan.move(tasks, at: 1, by: 1))
        #expect(down.map(\.slug) == ["a", "b", "c"])
        #expect(down[1].phase == "Two")
        let up = try #require(SwarmPlan.move(tasks, at: 2, by: -1))
        #expect(up.map(\.slug) == ["a", "b", "c"])
        #expect(up[2].phase == "One")
        #expect(SwarmPlan.move(tasks, at: 0, by: -1) == nil)
        #expect(SwarmPlan.move(tasks, at: 2, by: 1) == nil)
        #expect(SwarmPlan.move(tasks, at: 0, by: 2) == nil)
    }

    @Test func droppingATaskFreesWhatWaitedForIt() {
        let tasks = SwarmPlan.drop([task("a"), task("b", after: ["a", "x"])], id: "g/a")
        #expect(tasks.map(\.slug) == ["b"])
        #expect(tasks[0].after == ["g/x"])
    }

    @Test func estimatesReadAsALeadWritesThem() {
        #expect(SwarmEstimate.minutes("15m") == 15)
        #expect(SwarmEstimate.minutes("1h") == 60)
        #expect(SwarmEstimate.minutes("1h 30m") == 90)
        #expect(SwarmEstimate.minutes("1.5h") == 90)
        #expect(SwarmEstimate.minutes("90") == 90)
        #expect(SwarmEstimate.minutes("2 hours") == 120)
        #expect(SwarmEstimate.minutes("soon") == nil)
        #expect(SwarmEstimate.minutes("") == nil)
        #expect(SwarmEstimate.minutes("3x") == nil)
        #expect(SwarmEstimate.text(12) == "12m")
        #expect(SwarmEstimate.text(60) == "1h")
        #expect(SwarmEstimate.text(220) == "3h 40m")
        #expect(SwarmPlan.estimate([task("a", estimate: 10), task("b"), task("c", estimate: 5)]) == 15)
    }

    @Test func planMDHasThePhasesTasksAndTheirFields() {
        let swarm = GoalSwarm(id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(), plan: 2, startedAt: now)
        let version = SwarmPlanVersion(
            swarm: swarm.id, goal: "g", number: 2, at: now, author: .lead, note: "",
            tasks: [
                task("cache", "Cache layer", phase: "Build", owner: "claude", estimate: 55, done: ["the cache hits"]),
                task("tests", "Unit tests", phase: "Tests", after: ["cache"]),
            ]
        )
        let text = SwarmPlan.render(version, swarm: swarm, goalTitle: "Faster builds")
        #expect(text.hasPrefix("# Plan: Faster builds\n"))
        #expect(text.contains("plan v2 · draft · 2 tasks · est 55m"))
        #expect(text.contains("## 1. Build"))
        #expect(text.contains("- **1.1 Cache layer** (`cache`) · claude · 55m"))
        #expect(text.contains("  - done when: the cache hits"))
        #expect(text.contains("- **2.1 Unit tests** (`tests`) · after 1.1"))
    }
}

struct SwarmSteeringTests {
    private func row(
        _ id: Int64, _ kind: SwarmSteer.Kind, actor: SwarmSteer.Actor = .you, state: SwarmSteer.State = .applied,
        about: Int64? = nil, version: Int? = nil, tasks: [SwarmTask]? = nil, text: String = ""
    ) -> SwarmSteer {
        SwarmSteer(
            id: id, swarm: "g/swarm-1", goal: "g", at: now, actor: actor, kind: kind, text: text, state: state,
            about: about, version: version, tasks: tasks
        )
    }

    @Test func aQuestionIsOpenUntilAnAnswerPointsAtIt() {
        let rows = [
            row(1, .question, actor: .lead, state: .pending, text: "local or remote cache?"),
            row(2, .question, actor: .lead, state: .pending, text: "in scope?"),
            row(3, .answer, about: 1, text: "local"), row(4, .answer, about: 1, text: "local, remote later"),
        ]
        let questions = SwarmSteering.questions(rows)
        #expect(questions.map(\.id) == [1, 2])
        #expect(questions[0].answer?.text == "local, remote later")
        #expect(questions[1].answer == nil)
    }

    @Test func aPendingChangeWaitsUntilApprovedRejectedOrReplaced() {
        let pending = row(2, .propose, actor: .lead, state: .pending, tasks: [task("a")])
        #expect(SwarmSteering.pendingChange([row(1, .start), pending])?.id == 2)
        #expect(SwarmSteering.pendingChange([pending, row(3, .approve, about: 2)]) == nil)
        #expect(SwarmSteering.pendingChange([pending, row(3, .reject, about: 2)]) == nil)
        #expect(SwarmSteering.pendingChange([pending, row(3, .propose, actor: .lead, version: 4)]) == nil)
        // A GOAL.md change the lead proposed is no plan change.
        let scope = row(3, .propose, actor: .lead, state: .pending, text: "GOAL.md: + Not the goal: x")
        #expect(SwarmSteering.pendingChange([pending, scope])?.id == 2)
        #expect(SwarmSteering.pendingChange([scope]) == nil)
        // Something about another row does not settle it.
        #expect(SwarmSteering.pendingChange([pending, row(3, .answer, about: 1)])?.id == 2)
    }

    @Test func feedbackIsWhatTheLeadHasNotAnsweredYet() {
        let rows = [
            row(1, .replan, text: "old"), row(2, .propose, actor: .lead, version: 1), row(3, .replan, text: "split it"),
            row(4, .replan, text: "smaller"),
        ]
        #expect(SwarmSteering.feedback(rows).map(\.text) == ["split it", "smaller"])
        #expect(SwarmSteering.feedback(rows + [row(5, .propose, actor: .lead, version: 2)]).isEmpty)
    }
}

struct SwarmInputTests {
    @Test func aPlanReadsFromAnObjectWithNoteScopeAndTasks() throws {
        let json = """
        {"note": "first draft",
         "tasks": [
           {"id": "profile", "title": "Profile the build", "phase": "Spike", "owner": "claude",
            "estimate": "15m", "doneWhen": "a profile of every build step"},
           {"title": "Cache layer", "phase": "Build", "owner": "codex:o4", "estimate": 55,
            "after": ["profile"], "done_when": ["the cache hits", ""]},
           {"title": "Docs", "owner": {"agent": "claude", "model": "haiku"}, "after": "cache-layer"}
         ],
         "scope": [{"section": "not-the-goal", "text": "rewriting the bundler"}]}
        """
        let input = try SwarmPlanInput.parse(json, goal: "g")
        #expect(input.note == "first draft")
        #expect(input.scope == [SwarmPlanInput.Scope(section: .notTheGoal, text: "rewriting the bundler")])
        #expect(input.tasks.map(\.id) == ["g/profile", "g/cache-layer", "g/docs"])
        #expect(input.tasks[0].estimate == 15)
        #expect(input.tasks[0].doneWhen == ["a profile of every build step"])
        #expect(input.tasks[1].owner == GoalItem.Owner(agent: "codex", model: "o4"))
        #expect(input.tasks[1].after == ["g/profile"])
        #expect(input.tasks[1].doneWhen == ["the cache hits"])
        // No phase: the one before it.
        #expect(input.tasks[2].phase == "Build")
        #expect(input.tasks[2].owner == GoalItem.Owner(agent: "claude", model: "haiku"))
        #expect(input.tasks[2].after == ["g/cache-layer"])
    }

    @Test func idsAreKeptByTitleAndItemsOnTheGoalAreTakenIn() throws {
        let current = [SwarmTask(id: "g/cache-2", title: "Cache layer", phase: "Build")]
        let items = [
            GoalItem(id: "g/old-work", goal: "g", title: "Old work", source: .you, createdAt: now),
            GoalItem(id: "g/cache-layer", goal: "g", title: "Something else", source: .you, createdAt: now),
        ]
        let input = try SwarmPlanInput.parse("""
        [{"title": "cache layer"}, {"id": "old-work", "title": "Old work, planned"},
         {"title": "Tests", "after": ["old-work", "g/cache-2"]}, {"title": "Cache layer"}]
        """, goal: "g", current: current, items: items)
        #expect(input.tasks[0].id == "g/cache-2")
        #expect(input.tasks[1].id == "g/old-work")
        #expect(input.tasks[2].after == ["g/old-work", "g/cache-2"])
        // A second task with the title gets an id of its own, past the item already called that.
        #expect(input.tasks[3].id == "g/cache-layer-2")
        #expect(input.tasks.first?.phase == "Plan")
    }

    @Test func badPlansSayWhy() {
        func problem(_ json: String) -> String {
            do {
                _ = try SwarmPlanInput.parse(json, goal: "g")
                return ""
            } catch { return "\(error)" }
        }
        #expect(problem("").contains("no plan given"))
        #expect(problem("{").contains("not JSON"))
        #expect(problem("{\"note\": \"x\"}").contains("needs \"tasks\""))
        #expect(problem("[1]").contains("task 1 is not an object"))
        #expect(problem("[{\"phase\": \"x\"}]").contains("task 1 has no title"))
        #expect(problem("[{\"title\": \"a\", \"estimate\": \"soon\"}]").contains("no estimate in \"soon\""))
        #expect(problem("[{\"title\": \"a\", \"owner\": 3}]").contains("owner is an agent name"))
        #expect(problem("{\"tasks\": [], \"scope\": [{\"section\": \"x\", \"text\": \"y\"}]}").contains("scope change"))
        #expect(problem("\"x\"").contains("a list of tasks"))
    }
}

struct SwarmStoreTests {
    @Test func migrationThreeAddsTheTablesAndOldItemsStillRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-swarm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        // A file as the last heed left it: two migrations, an item written before swarms.
        do {
            let old = try SQLiteDatabase(path: url.path)
            try old.migrate(Array(GoalStore.schema.prefix(2)))
            try old.run(
                "INSERT INTO goals (id, title, status, created_at, updated_at, version) VALUES ('g', 'G', 'active', 0, 0, 1)"
            )
            try old.run("""
            INSERT INTO goal_items (id, goal, created_at, data) VALUES ('g/a', 'g', 0,
            '{"createdAt":0,"goal":"g","id":"g/a","kind":"work","links":[],"source":"you","title":"A"}')
            """)
        }
        let store = try GoalStore(path: url.path)
        #expect(try store.schemaVersion == 3)
        let item = try #require(try store.item("g/a"))
        #expect(item.title == "A")
        #expect(item.after.isEmpty && item.doneWhen.isEmpty)
        #expect(item.owner == nil && item.estimate == nil && item.phase == nil)
        #expect(try store.swarms().isEmpty)
    }

    @Test func plansAndSteeringAreOnlyAdded() throws {
        let store = try GoalStore(path: ":memory:")
        try store.insert(HeedGoal(id: "g", title: "G", createdAt: now), first: GoalVersion(
            goal: "g", number: 1, at: now, text: "# G\n", note: "created"
        ))
        let swarm = GoalSwarm(id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(), startedAt: now)
        try store.save(swarm)
        try store.add(SwarmPlanVersion(
            swarm: swarm.id,
            goal: "g",
            number: 1,
            at: now,
            author: .lead,
            note: "",
            tasks: []
        ))
        let row = try store.add(SwarmSteer(swarm: swarm.id, goal: "g", at: now, actor: .you, kind: .start, text: "x"))
        #expect(row.id != nil)
        #expect(throws: (any Error).self) { try store.database.run("UPDATE goal_steering SET state = 'overruled'") }
        #expect(throws: (any Error).self) { try store.database.run("DELETE FROM goal_steering") }
        #expect(throws: (any Error).self) { try store.database.run("UPDATE goal_plans SET note = 'x'") }
        #expect(throws: (any Error).self) { try store.database.run("DELETE FROM goal_plans") }
        #expect(try store.steering(of: swarm.id).count == 1)
        #expect(try store.plans(of: swarm.id).count == 1)
    }

    @Test func anItemWithSwarmFieldsRoundTrips() throws {
        let item = GoalItem(
            id: "g/a", goal: "g", title: "A", source: .swarm, createdAt: now,
            owner: GoalItem.Owner(agent: "codex", model: "o4"), after: ["g/b"], estimate: 40, doneWhen: ["x"],
            phase: "Build"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        #expect(try decoder.decode(GoalItem.self, from: encoder.encode(item)) == item)
        #expect(GoalItem.Owner(agent: "claude", model: "").model == nil)
        #expect(GoalItem.Owner(agent: "codex", model: "o4").label == "codex · o4")
    }
}

struct SwarmOpsTests {
    private func world(files: GoalFiles = .fixture) async throws -> (GoalOps, HeedGoal) {
        let ops = try GoalOps(path: ":memory:", files: files)
        let goal = try await ops.create(title: "Faster builds", statement: "Build the map at build time.", now: now)
        return (ops, goal)
    }

    private func input(_ json: String, goal: String = "faster-builds") throws -> SwarmPlanInput {
        try SwarmPlanInput.parse(json, goal: goal)
    }

    private let draft = """
    {"tasks": [{"id": "profile", "title": "Profile", "phase": "Spike", "owner": "claude", "estimate": "15m"},
               {"id": "cache", "title": "Cache layer", "phase": "Build", "after": ["profile"], "doneWhen": ["it builds"]}]}
    """

    @Test func oneSwarmAtATimeAndAStoppedOneStaysReadable() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(repos: ["acme/docs"]), now: now)
        #expect(swarm.id == "faster-builds/swarm-1")
        #expect(swarm.status == .planning)
        await #expect(throws: GoalOpError.swarmActive(goal.id)) {
            try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        }
        try await ops.setLead(swarm: swarm.id, session: "lead-1", now: now)
        try await ops.stopSwarm(swarm.id, now: now + 60)
        await #expect(throws: GoalOpError.swarmEnded(swarm.id)) {
            try await ops.ask(swarm: swarm.id, question: "x", now: now)
        }
        let next = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now + 120)
        #expect(next.number == 2)
        let old = try await ops.board(of: swarm.id)
        #expect(old.swarm.status == .stopped)
        #expect(old.swarm.lead == "lead-1")
        #expect(old.steering.map(\.kind) == [.start, .start, .stop])
        #expect(try await ops.snapshot().swarms(of: goal.id).map(\.number) == [2, 1])
        #expect(try await ops.snapshot().activeSwarm(of: goal.id)?.number == 2)
    }

    @Test func draftsApplyUntilApprovalAndApprovalMakesTheItems() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        let first = try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now)
        #expect(first.outcome == .applied && first.version == 1)
        #expect(try await ops.snapshot().items(of: goal.id).isEmpty)
        // Before approval, even a structural change is just the next draft.
        let bigger = try await ops.proposePlan(swarm: swarm.id, input: input("""
        [{"id": "profile", "title": "Profile", "phase": "Spike"}, {"id": "cache", "title": "Cache layer",
          "phase": "Build", "after": ["profile"]}, {"id": "docs", "title": "Docs", "phase": "Docs"}]
        """), now: now)
        #expect(bigger.outcome == .applied && bigger.version == 2)
        #expect(try await ops.proposePlan(swarm: swarm.id, input: input("""
        [{"id": "profile", "title": "Profile", "phase": "Spike"}, {"id": "cache", "title": "Cache layer",
          "phase": "Build", "after": ["profile"]}, {"id": "docs", "title": "Docs", "phase": "Docs"}]
        """), now: now).outcome == .unchanged)
        let approved = try await ops.approvePlan(swarm: swarm.id, now: now + 60)
        #expect(approved.number == 2)
        let snapshot = try await ops.snapshot()
        let items = snapshot.items(of: goal.id)
        #expect(items.map(\.id).sorted() == ["faster-builds/cache", "faster-builds/docs", "faster-builds/profile"])
        let cache = try #require(snapshot.item("faster-builds/cache"))
        #expect(cache.source == .swarm)
        #expect(cache.after == ["faster-builds/profile"])
        #expect(cache.phase == "Build")
        #expect(Stages.of(cache, evidence: snapshot.evidence)[.plan] == .done)
        let board = try await ops.board(of: swarm.id)
        #expect(board.swarm.isApproved)
        #expect(board.steering.last?.kind == .approve)
    }

    @Test func afterApprovalSmallChangesApplyAndStructuralOnesWait() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now)
        try await ops.approvePlan(swarm: swarm.id, now: now)
        let small = try await ops.proposePlan(swarm: swarm.id, input: input(draft.replacingOccurrences(
            of: "\"owner\": \"claude\"", with: "\"owner\": \"codex\""
        )), now: now)
        #expect(small.outcome == .applied && small.size == .small)
        #expect(try await ops.board(of: swarm.id).swarm.approved == small.version)
        #expect(try await ops.snapshot().item("faster-builds/profile")?.owner?.agent == "codex")

        let structural = try await ops.proposePlan(swarm: swarm.id, input: input("""
        [{"id": "cache", "title": "Cache layer", "phase": "Build"}]
        """), now: now + 10)
        #expect(structural.outcome == .pending && structural.size == .structural)
        var board = try await ops.board(of: swarm.id)
        #expect(board.pending?.id == structural.steer?.id)
        #expect(board.tasks.count == 2)
        // Approve takes the waiting change as a new version; the dropped item stays, without its phase.
        let approved = try await ops.approvePlan(swarm: swarm.id, now: now + 20)
        board = try await ops.board(of: swarm.id)
        #expect(approved.tasks.map(\.slug) == ["cache"])
        #expect(board.pending == nil)
        #expect(board.steering.last?.about == structural.steer?.id)
        let dropped = try #require(try await ops.snapshot().item("faster-builds/profile"))
        #expect(dropped.phase == nil)

        // A waiting change said no to.
        let again = try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now + 30)
        #expect(again.outcome == .pending)
        let no = try await ops.rejectChange(swarm: swarm.id, reason: "keep it small", now: now + 40)
        #expect(no?.about == again.steer?.id)
        #expect(try await ops.board(of: swarm.id).pending == nil)
        #expect(try await ops.rejectChange(swarm: swarm.id, reason: nil, now: now + 50) == nil)
        _ = goal
    }

    @Test func runningToTheEndAppliesEveryChange() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(
            goal: goal.id, settings: SwarmSettings(autonomy: .toTheEnd), now: now
        )
        try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now)
        try await ops.approvePlan(swarm: swarm.id, now: now)
        let change = try await ops.proposePlan(swarm: swarm.id, input: input("""
        [{"id": "cache", "title": "Cache layer", "phase": "Build"}]
        """), now: now)
        #expect(change.outcome == .applied)
    }

    @Test func aPlanThatWouldChangeTheGoalProposesToGOALmdInstead() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        let done = try await ops.proposePlan(swarm: swarm.id, input: input("""
        {"tasks": [{"title": "Profile"}], "scope": [{"section": "not-the-goal", "text": "rewriting the bundler"},
         {"section": "decision", "text": "use the local disk"}]}
        """), now: now)
        #expect(done.scope.map(\.state) == [.proposed, .proposed])
        let snapshot = try await ops.snapshot()
        #expect(snapshot.proposals(of: goal.id).count == 2)
        #expect(snapshot.docs[goal.id]?.notTheGoal.isEmpty == true)
        let board = try await ops.board(of: swarm.id)
        #expect(board.steering.count(where: { $0.ref?.hasPrefix("edit:") == true }) == 2)
        // Those rows are no plan change waiting.
        #expect(board.pending == nil)
    }

    @Test func badPlansAreRefusedWithTheirProblems() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        await #expect(throws: GoalOpError.badPlan([
            "the tasks wait for each other in a circle: faster-builds/a → faster-builds/b → faster-builds/a",
        ])) {
            try await ops.proposePlan(swarm: swarm.id, input: input("""
            [{"id": "a", "title": "A", "after": ["b"]}, {"id": "b", "title": "B", "after": ["a"]}]
            """), now: now)
        }
        await #expect(throws: GoalOpError.noPlan(swarm.id)) { try await ops.approvePlan(swarm: swarm.id, now: now) }
    }

    @Test func questionsAnswersFeedbackAndYourOwnEdits() async throws {
        let (ops, goal) = try await world()
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now)
        let question = try await ops.ask(
            swarm: swarm.id, question: "Local or remote cache?", options: ["local", "remote", ""], now: now
        )
        #expect(question.options == ["local", "remote"])
        #expect(try await ops.ask(swarm: swarm.id, question: "local or remote cache", now: now).id == question.id)
        let id = try #require(question.id)
        try await ops.answer(swarm: swarm.id, question: id, text: "local", now: now)
        await #expect(throws: GoalOpError.unknownQuestion(999)) {
            try await ops.answer(swarm: swarm.id, question: 999, text: "x", now: now)
        }
        try await ops.replan(swarm: swarm.id, feedback: "split the cache layer", now: now)
        var board = try await ops.board(of: swarm.id)
        #expect(board.openQuestions.isEmpty)
        #expect(SwarmSteering.feedback(board.steering).map(\.text) == ["split the cache layer"])

        let moved = try #require(SwarmPlan.move(board.tasks, at: 0, by: 1))
        let version = try await ops.changePlan(swarm: swarm.id, tasks: moved, kind: .move, text: "moved", now: now)
        #expect(version?.author == .you)
        #expect(try await ops.changePlan(swarm: swarm.id, tasks: moved, kind: .move, text: "again", now: now) == nil)
        board = try await ops.board(of: swarm.id)
        #expect(board.swarm.plan == 2)
        let restored = try await ops.restorePlan(swarm: swarm.id, version: 1, now: now)
        #expect(restored?.number == 3)
        #expect(restored?.author == .restore)
        #expect(try await ops.restorePlan(swarm: swarm.id, version: 3, now: now) == nil)
        await #expect(throws: GoalOpError.unknownPlanVersion(swarm.id, 9)) {
            try await ops.restorePlan(swarm: swarm.id, version: 9, now: now)
        }
        board = try await ops.board(of: swarm.id)
        #expect(board.tasks == board.version(1)?.tasks)
        #expect(board.steering.map(\.kind) == [.start, .propose, .question, .answer, .replan, .move, .restore])
        _ = goal
    }

    @Test func everyVersionIsExportedAsPLANmdNextToGOALmd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("heed-swarm-files-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let files = GoalFiles(root: root)
        let (ops, goal) = try await world(files: files)
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        #expect(!FileManager.default.fileExists(atPath: files.plan(goal.id).path))
        try await ops.proposePlan(swarm: swarm.id, input: input(draft), now: now)
        var text = try String(contentsOf: files.plan(goal.id), encoding: .utf8)
        #expect(text.contains("plan v1 · draft"))
        try await ops.approvePlan(swarm: swarm.id, now: now)
        text = try String(contentsOf: files.plan(goal.id), encoding: .utf8)
        #expect(text.contains("plan v1 · approved"))
        #expect(files.plan(goal.id).deletingLastPathComponent() == files.doc(goal.id).deletingLastPathComponent())
    }
}

struct SwarmCommandTests {
    private func parse(_ line: String) throws -> GoalCommand {
        try GoalCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func planAndAskParse() throws {
        #expect(try parse("goal plan show").verb == .planShow)
        #expect(try parse("plan approve").verb == .planApprove)
        #expect(try parse("plan propose --file plan.json --note first") == GoalCommand(
            .planPropose, note: "first", file: "plan.json"
        ))
        #expect(try parse("ask Local or remote cache --option local --option=remote") == GoalCommand(
            .ask, text: "Local or remote cache", options: ["local", "remote"]
        ))
        #expect(throws: (any Error).self) { try parse("plan propose") }
        #expect(throws: (any Error).self) { try parse("plan propose words --file x") }
        #expect(throws: (any Error).self) { try parse("plan show now") }
        #expect(throws: (any Error).self) { try parse("plan forget") }
        #expect(throws: (any Error).self) { try parse("ask") }
        #expect(throws: (any Error).self) { try parse("ask x --note y") }
        #expect(throws: (any Error).self) { try parse("show --option x") }
        #expect(GoalCommandLine.usage.contains("plan propose --file"))
    }

    @Test func theRequestReadsThePlanAndMarksBackgroundRuns() throws {
        let request = try GoalCommandLine.request(
            ["goal", "plan", "propose", "--file", "-"], environment: [HeedEnvironment.sessionID: "s1"],
            read: { $0 == "-" ? "[{\"title\": \"a\"}]" : "" }
        )
        #expect(request.goal?.text == "[{\"title\": \"a\"}]")
        #expect(request.goal?.fromRun == nil)
        let run = try GoalCommandLine.request(
            ["goal", "plan", "approve"], environment: [GoalCommandLine.goalVariable: "g"]
        )
        #expect(run.goal?.fromRun == true)
        #expect(run.goal?.goal == "g")
        #expect(throws: (any Error).self) {
            try GoalCommandLine.request(
                ["goal", "plan", "propose", "--file", "missing.json"], environment: [:],
                read: { _ in throw CocoaError(.fileNoSuchFile) }
            )
        }
    }
}

struct SwarmControlTests {
    private let lead = GoalCaller(session: "lead-1", title: "Lead")
    private let other = GoalCaller(session: "s2", title: "Someone")

    private func world() async throws -> (GoalOps, GoalSwarm) {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "lead-1", origin: .swarm, at: now))
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "s2", at: now))
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.setLead(swarm: swarm.id, session: "lead-1", now: now)
        return (ops, swarm)
    }

    private func run(_ command: GoalCommand, _ ops: GoalOps, caller: GoalCaller?) async -> GoalReply? {
        let outcome = await GoalControl.run(command, caller: caller, ops: ops, files: .fixture, now: now)
        if case let .reply(reply) = outcome { return reply }
        return nil
    }

    @Test func theLeadProposesAndAsksButNeverApproves() async throws {
        let (ops, swarm) = try await world()
        let propose = await run(
            GoalCommand(.planPropose, text: "[{\"id\": \"a\", \"title\": \"A\", \"owner\": \"claude\"}]", note: "v1"),
            ops, caller: lead
        )
        #expect(propose?.outcome == "applied")
        #expect(propose?.version == 1)
        #expect(propose?.message.contains("a draft") == true)
        let asked = await run(
            GoalCommand(.ask, text: "Local or remote cache?", options: ["local", "remote"]),
            ops,
            caller: lead
        )
        #expect(asked?.outcome == "asked")
        let board = try await ops.board(of: swarm.id)
        #expect(board.steering.filter { $0.kind == .propose || $0.kind == .question }.map(\.actor) == [.lead, .lead])
        #expect(board.version(1)?.note == "v1")

        #expect(await run(GoalCommand(.planApprove), ops, caller: lead)?.exit == .refused)
        #expect(await run(GoalCommand(.planApprove, goal: "faster-builds"), ops, caller: other)?.exit == .refused)
        var fromRun = GoalCommand(.planApprove, goal: "faster-builds")
        fromRun.fromRun = true
        #expect(await run(fromRun, ops, caller: nil)?.exit == .refused)
        #expect(await run(GoalCommand(.planApprove, goal: "faster-builds"), ops, caller: nil)?.outcome == "applied")

        let show = await run(GoalCommand(.planShow), ops, caller: lead)
        let text = show.map { $0.rendered(json: false) } ?? ""
        #expect(text.contains("approved, plan v1, approved v1"))
        #expect(text.contains("1.1 A  [faster-builds/a]  claude"))
        #expect(text.contains("Local or remote cache? (local / remote)"))
        #expect(text.contains("not answered yet"))
        #expect(show?.plan?.tasks.first?.number == "1.1")
    }

    @Test func badJSONAndNoSwarmAreRefused() async throws {
        let (ops, swarm) = try await world()
        #expect(await run(GoalCommand(.planPropose, text: "{"), ops, caller: lead)?.message
            .contains("not JSON") == true)
        try await ops.stopSwarm(swarm.id, now: now)
        let none = await run(GoalCommand(.planShow), ops, caller: lead)
        #expect(none?.exit == .refused)
        #expect(none?.message.contains("no swarm going") == true)
    }

    @Test func theSkillTeachesTheLead() {
        let skill = HeedPlugin.skillText
        #expect(skill.contains("## Leading a swarm"))
        #expect(skill.contains("`heed goal plan propose --file plan.json --note TEXT`"))
        #expect(skill.contains("Never change the goal or the swarm's limits"))
        let swarm = GoalSwarm(
            id: "g/swarm-2", goal: "g", number: 2,
            settings: SwarmSettings(workers: [SwarmSettings.Worker(agent: "codex", count: 2)]), startedAt: now
        )
        let prompt = SwarmLead.prompt(goal: "Faster builds", doc: "~/goals/g/GOAL.md", swarm: swarm)
        #expect(prompt.hasPrefix("You lead swarm 2 on the goal Faster builds. Its GOAL.md is ~/goals/g/GOAL.md."))
        #expect(prompt.contains("a team of codex ×2"))
        #expect(prompt.contains("Run: heed goal ask QUESTION --option A --effect TEXT --option B --effect TEXT."))
        for rule in GoalGuidance.leadRules {
            for bad in ["\"", "`", "$", "\\"] {
                #expect(!rule.text.contains(bad) && !(rule.command ?? "").contains(bad))
            }
        }
    }
}

struct SwarmTaskFormTests {
    private let tasks = [
        SwarmTask(id: "g/a", title: "A", phase: "One"), SwarmTask(id: "g/b", title: "B", phase: "Two"),
    ]

    @Test func aTaskReadsBackFromItsFields() throws {
        let task = SwarmTask(
            id: "g/b", title: "B", phase: "Two", owner: GoalItem.Owner(agent: "codex", model: "o4", effort: "high"),
            estimate: 90, after: ["g/a"], doneWhen: ["x", "y"]
        )
        let form = SwarmTaskForm(task, in: tasks)
        #expect(form.agent == "codex" && form.model == "o4" && form.effort == "high")
        #expect(form.estimate == "1h 30m")
        #expect(form.after == "1.1")
        #expect(form.doneWhen == "x\ny")
        #expect(try form.task(id: "g/b", in: tasks).get() == task)
    }

    @Test func badFieldsSayWhy() {
        var form = SwarmTaskForm()
        #expect(form.task(id: "g/c", in: tasks) == .failure(.init("a task needs a title")))
        form.title = "C"
        form.estimate = "soon"
        #expect(form.task(id: "g/c", in: tasks) == .failure(.init("no estimate in soon: 15m, 1h 30m")))
        form.estimate = ""
        form.after = "9.9"
        #expect(form
            .task(id: "g/c", in: tasks) == .failure(.init("no task 9.9 to wait for (a number like 1.2, or an id)")))
        form.after = "1.1, b, 1.1"
        let task = try? form.task(id: "g/c", in: tasks).get()
        #expect(task?.after == ["g/a", "g/b"])
        #expect(task?.phase == "Plan")
        form.after = "1.1"
        #expect(form.task(id: "g/a", in: tasks) == .failure(.init("a task cannot wait for itself")))
    }

    @Test func theOwnerIsAnAgentWithAModelAndEffortOrNone() throws {
        var form = SwarmTaskForm()
        form.title = "C"
        form.model = "ignored without an agent"
        #expect(try form.task(id: "g/c", in: tasks).get().owner == nil)
        form.agent = "claude"
        form.model = "two words"
        #expect(form.task(id: "g/c", in: tasks) == .failure(.init("the owner's model: a model id has no spaces")))
        form.model = ""
        form.effort = "High"
        #expect(try form.task(id: "g/c", in: tasks).get().owner == GoalItem.Owner(agent: "claude", effort: "high"))
        form.model = "my-proxy-model"
        #expect(try form.task(id: "g/c", in: tasks).get().owner?.model == "my-proxy-model")
    }
}
