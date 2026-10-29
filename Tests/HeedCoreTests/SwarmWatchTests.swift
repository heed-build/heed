import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func minutes(_ value: Double) -> Date { now.addingTimeInterval(value * 60) }

private func task(_ slug: String, phase: String = "Build", after: [String] = [], estimate: Int? = nil) -> SwarmTask {
    SwarmTask(
        id: "g/\(slug)", title: slug.capitalized, phase: phase, owner: GoalItem.Owner(agent: "claude"),
        estimate: estimate, after: after.map { "g/\($0)" }
    )
}

private func row(
    _ kind: SwarmSteer.Kind, _ text: String = "", id: Int64, actor: SwarmSteer.Actor = .heed, at: Date = now,
    about: Int64? = nil, ref: String? = nil, step: String? = nil, from: String? = nil, reason: String? = nil,
    options: [String] = [], ladder: [String]? = nil
) -> SwarmSteer {
    SwarmSteer(
        id: id, swarm: "g/swarm-1", goal: "g", at: at, actor: actor, kind: kind, text: text, reason: reason,
        state: kind == .question ? .pending : .applied, about: about, ref: ref, options: options, from: from,
        ladder: ladder, step: step ?? ladder?.first
    )
}

// MARK: Activity

struct ToolCallTests {
    @Test func aCallKeepsItsToolAndAShortInputNeverTheWholeOutput() throws {
        let long = String(repeating: "x", count: 200)
        let call = try #require(ToolCall.from(hook: [
            "tool_name": "Bash", "tool_input": ["command": "dotnet test --filter Anchor\nsecond line \(long)"],
            "tool_response": ["stdout": "41 passed", "stderr": "", "interrupted": false],
        ]))
        #expect(call.tool == "Bash")
        #expect(call.input == "dotnet test --filter Anchor")
        #expect(!call.error)
        #expect(call.digest == nil)
        let edit = try #require(ToolCall.from(hook: [
            "tool_name": "Edit", "tool_input": ["file_path": "/src/" + long],
        ]))
        #expect(edit.input?.count == ToolCall.inputLimit)
        #expect(edit.input?.hasSuffix("…") == true)
        #expect(ToolCall.from(hook: ["tool_input": ["command": "ls"]]) == nil)
    }

    @Test func failuresAreFoundHoweverTheAgentSaysThem() {
        func failed(_ input: [String: Any]) -> ToolCall? {
            ToolCall.from(hook: ["tool_name": "Bash", "tool_input": ["command": "make"]].merging(input) { $1 })
        }
        #expect(failed(["error": "Command failed with exit code 2"])?.error == true)
        #expect(failed(["tool_response": ["is_error": true, "stderr": "boom"]])?.digest == "boom")
        #expect(failed(["tool_response": ["exit_code": 1, "stderr": "error CS0246: type not found"]])?.error == true)
        #expect(failed(["tool_response": ["success": false]])?.error == true)
        #expect(failed(["tool_response": "Error: no such file"])?.error == true)
        #expect(failed(["tool_response": "all good"])?.error == false)
        #expect(failed(["tool_response": ["exit_code": 0, "stdout": "ok"]])?.error == false)
    }

    @Test func theSameErrorTwiceHasOneDigestWhateverItsNumbersAndPaths() {
        let first = ErrorDigest.of("Building…\nsrc/A.cs(12,5): error CS0246: 'SiteIndex' not found [a1b2c3d4e5f6]")
        let second = ErrorDigest
            .of("Building…\nsrc/A.cs(48,9): error CS0246: \"SiteIndex\" not found [ffee00112233]")
        #expect(first != nil)
        #expect(first == second)
        #expect(first?.hasPrefix("src/a.cs(#,#): error cs#") == true)
        #expect(ErrorDigest.of("other: error CS0103") != first)
        #expect(ErrorDigest.of("   \n  ") == nil)
        #expect((ErrorDigest.of(String(repeating: "error ", count: 40))?.count ?? 0) <= ErrorDigest.limit)
    }

    @Test func aRowHoldsTheCallBack() throws {
        let call = ToolCall(tool: "Bash", input: "make", error: true, digest: "make: *** error #")
        let event = call.event(at: now, session: "s", subject: "task:g/a", payload: ["swarm": "g/swarm-1"])
        #expect(event.kind == .toolCall)
        #expect(event.subject == "task:g/a")
        #expect(ToolCall(event: event) == call)
        let line = try #require(SwarmActivityLine(event: event))
        #expect(line.isError)
        #expect(line.text == "Bash(make) · make: *** error #")
    }

    @Test func aClaudePostToolUseReportsItsCallAlongsideItsState() {
        let kinds = AgentIntegration.claudeHook(event: "PostToolUse", input: [
            "tool_name": "Read", "tool_input": ["file_path": "src/a.cs"], "tool_response": ["file": [:]],
        ])
        #expect(kinds.contains(.toolCall(ToolCall(tool: "Read", input: "src/a.cs"))))
        #expect(kinds.contains(.state(.working, reason: "Read")))
        let failure = AgentIntegration.claudeHook(event: "PostToolUseFailure", input: [
            "tool_name": "Bash", "tool_input": ["command": "make"], "error": "make: *** [all] Error 2",
        ])
        #expect(failure == [.toolCall(ToolCall(
            tool: "Bash",
            input: "make",
            error: true,
            digest: "make: *** [all] error #"
        ))])
        let codex = AgentIntegration.codexHook(event: "PostToolUse", input: [
            "tool_name": "shell", "tool_input": ["command": "cargo test"],
        ])
        #expect(codex.contains(.toolCall(ToolCall(tool: "shell", input: "cargo test"))))
    }
}

struct ActivityThrottleTests {
    @Test func callsCloserThanTheGapAreCountedOnTheNextOneKeptButAFailureIsAlwaysKept() {
        var throttle = ActivityThrottle(gap: 2)
        #expect(throttle.keep("w", at: now, error: false) == (true, 0))
        #expect(throttle.keep("w", at: now.addingTimeInterval(0.5), error: false).keep == false)
        #expect(throttle.keep("w", at: now.addingTimeInterval(1), error: false).keep == false)
        #expect(throttle.keep("w", at: now.addingTimeInterval(1.5), error: true) == (true, 2))
        #expect(throttle.keep("other", at: now.addingTimeInterval(1.6), error: false) == (true, 0))
        #expect(throttle.keep("w", at: now.addingTimeInterval(3.6), error: false) == (true, 0))
        throttle.forget("w")
        #expect(throttle.keep("w", at: now.addingTimeInterval(3.7), error: false) == (true, 0))
    }
}

struct FileActivityTests {
    @Test func statusAndDiffStatGiveTheFilesAndTheLines() {
        let change = FileActivity.parse(
            status: " M src/A.cs\n?? src/New.cs\nR  old.cs -> src/Moved.cs\n M src/A.cs\n",
            diffStat: " src/A.cs | 70 ++++--\n 2 files changed, 64 insertions(+), 12 deletions(-)\n"
        )
        #expect(change.files == ["src/A.cs", "src/New.cs", "src/Moved.cs"])
        #expect(change.insertions == 64)
        #expect(change.deletions == 12)
        #expect(change.line == "3 files · +64 −12")
        #expect(FileActivity.parse(status: "", diffStat: "").isEmpty)
        #expect(FileActivity.parse(status: " M a", diffStat: " 1 file changed, 1 insertion(+)")
            .line == "1 file · +1 −0")
    }

    @Test func aRowIsKeptOnlyWhenTheWorktreeChanged() {
        let one = FileActivity(files: ["a"], insertions: 1)
        #expect(FileActivity.change(from: nil, to: FileActivity()) == nil)
        #expect(FileActivity.change(from: nil, to: one) == one)
        #expect(FileActivity.change(from: one, to: one) == nil)
        #expect(FileActivity.change(from: one, to: FileActivity()) == FileActivity())
        #expect(FileActivityPolling.due(last: nil, now: now))
        #expect(!FileActivityPolling.due(last: now, now: now.addingTimeInterval(59)))
        #expect(FileActivityPolling.due(last: now, now: now.addingTimeInterval(60)))
    }

    @Test func theActivityFactsAreTheNewestTimeAndTheErrorsInOrder() {
        let lines = [
            SwarmActivityLine(at: minutes(2), kind: .tool(ToolCall(tool: "Bash", error: true, digest: "x"))),
            SwarmActivityLine(at: minutes(1), kind: .tool(ToolCall(tool: "Read"))),
            SwarmActivityLine(at: minutes(3), kind: .files(FileActivity(files: ["a"]))),
            SwarmActivityLine(at: minutes(4), kind: .tool(ToolCall(tool: "Bash", error: true))),
        ]
        let facts = SwarmActivityFacts.of(lines)
        #expect(facts.last == minutes(4))
        #expect(facts.errors == [nil, "x", "Bash"])
    }
}

// MARK: Stuck

struct SwarmStuckTests {
    private func observe(
        at: Double, last: Double? = nil, errors: [String?] = [], estimate: Int? = nil,
        screen: SwarmStuck.ScreenRead? = nil,
        others: Double? = nil, you: Double? = nil
    ) -> SwarmStuck.Observation {
        SwarmStuck.Observation(
            now: minutes(at), startedAt: now, estimate: estimate, lastActivity: last.map(minutes), recentErrors: errors,
            screen: screen, waitingOnOthers: others.map(minutes), waitingOnYou: you.map(minutes)
        )
    }

    @Test func tenQuietMinutesIsStuckNineAreNot() {
        #expect(SwarmStuck.signal(observe(at: 19, last: 10)) == nil)
        let signal = SwarmStuck.signal(observe(at: 20, last: 10))
        #expect(signal?.main == .noProgress(minutes: 10))
        #expect(signal?.strong == true)
        // No activity yet: from its start.
        #expect(SwarmStuck.signal(observe(at: 10))?.main == .noProgress(minutes: 10))
    }

    @Test func theSameErrorThreeTimesInARowIsStuckASuccessBetweenResetsIt() {
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["e", "e", "e"]))?.main == .sameError("e", count: 3))
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["e", "e", nil, "e"])) == nil)
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["e", "f", "e"])) == nil)
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["e", "e", "e", nil])) == nil)
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["f", "e", "e", "e", "e"]))?.main
            == .sameError("e", count: 4))
    }

    @Test func overTheEstimateIsAWeakSignalThatNeverStartsTheLadder() throws {
        #expect(SwarmStuck.signal(observe(at: 44, last: 44, estimate: 30)) == nil)
        let signal = try #require(SwarmStuck.signal(observe(at: 45, last: 45, estimate: 30)))
        #expect(signal.main == .overEstimate(ratio: 1.5))
        #expect(!signal.strong)
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: [], now: minutes(45)) == .none)
        #expect(signal.main.text == "150% of its estimate")
    }

    @Test func waitingOnAnAnswerIsNotBeingStuckItsQuietDoesNotCount() throws {
        let waiting = try #require(SwarmStuck.signal(observe(at: 30, last: 5, others: 20)))
        #expect(waiting.reasons == [.waitingOnOthers(minutes: 10)])
        #expect(!waiting.strong)
        let you = try #require(SwarmStuck.signal(observe(at: 30, last: 5, screen: .init(.stuck, by: .hunch), you: 10)))
        #expect(you.reasons == [.waitingOnYou(minutes: 20)])
        // The same error still counts while it waits.
        #expect(SwarmStuck.signal(observe(at: 30, last: 5, errors: ["e", "e", "e"], others: 20))?.strong == true)
    }

    @Test func theScreenReadingWaitingOrStuckIsAStrongSignalNamingWhoReadIt() throws {
        let waiting = try #require(SwarmStuck.signal(observe(at: 1, last: 1, screen: .init(.waiting, by: .guess))))
        #expect(waiting.main == .screen(.waiting, by: .guess))
        #expect(waiting.strong)
        #expect(waiting.main.text == "its screen reads waiting (heed's guess)")
        let stuck = try #require(SwarmStuck.signal(observe(at: 1, last: 1, screen: .init(.stuck, by: .hunch))))
        #expect(stuck.main.word == "stuck")
        #expect(stuck.main.text == "its screen reads stuck (Hunch)")
    }

    @Test func settingsChangeTheThresholdsAndZeroTurnsOneOff() {
        let strict = SwarmStuck.Settings(overEstimate: 1.2, sameError: 2, noProgress: 5)
        #expect(SwarmStuck.signal(observe(at: 5, last: 0), settings: strict)?.main == .noProgress(minutes: 5))
        #expect(SwarmStuck.signal(observe(at: 1, last: 1, errors: ["e", "e"]), settings: strict)?.strong == true)
        let off = SwarmStuck.Settings(overEstimate: 0, sameError: 0, noProgress: 0)
        #expect(SwarmStuck.signal(observe(at: 99, errors: ["e", "e", "e"], estimate: 10), settings: off) == nil)
        #expect(SwarmStuck.Settings().line == "1.5× estimate · 3× same error · 10 min no progress · 8 min on a peer"
            + " · 15 min on you")
    }

    @Test func theLadderNudgesFirstAsksTenMinutesLaterAndEndsWhenItMoves() throws {
        let signal = try #require(SwarmStuck.signal(observe(at: 10)))
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: [], now: minutes(10)) == .nudge(signal))
        #expect(SwarmStuck.next(task: "g/a", signal: nil, rows: [], now: minutes(10)) == .none)
        let nudged = [row(.stuck, id: 1, at: minutes(10), ref: "task:g/a", step: "nudge")]
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: nudged, now: minutes(19)) == .none)
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: nudged, now: minutes(20)) == .ask(signal))
        // Another task's episode is not this one's.
        #expect(SwarmStuck.next(task: "g/b", signal: signal, rows: nudged, now: minutes(20)) == .nudge(signal))
        let asked = nudged + [row(.stuck, id: 2, at: minutes(20), ref: "task:g/a", step: "ask")]
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: asked, now: minutes(60)) == .none)
        #expect(SwarmStuck.next(task: "g/a", signal: nil, rows: asked, now: minutes(61)) == .clear)
        let weak = try #require(SwarmStuck.signal(observe(at: 61, last: 61, estimate: 10)))
        #expect(SwarmStuck.next(task: "g/a", signal: weak, rows: asked, now: minutes(61)) == .clear)
        let cleared = asked + [row(.stuck, id: 3, at: minutes(61), ref: "task:g/a", step: "clear")]
        #expect(SwarmStuck.episode(of: "g/a", cleared) == nil)
        #expect(SwarmStuck.next(task: "g/a", signal: nil, rows: cleared, now: minutes(62)) == .none)
        #expect(SwarmStuck.next(task: "g/a", signal: signal, rows: cleared, now: minutes(80)) == .nudge(signal))
    }

    @Test func aQuestionWaitingOnYouIsRemindedOnceAfterFifteenMinutes() {
        let asked = row(.question, "Fail or warn?", id: 1, actor: .agent, at: now, from: "task:g/a", ladder: ["you"])
        #expect(SwarmStuck.reminders([asked], now: minutes(14)).isEmpty)
        #expect(SwarmStuck.reminders([asked], now: minutes(15)).map(\.id) == [1])
        let reminded = [asked, row(.remind, id: 2, at: minutes(15), about: 1)]
        #expect(SwarmStuck.reminders(reminded, now: minutes(40)).isEmpty)
        let answered = [asked, row(.answer, "warn", id: 2, actor: .you, at: minutes(5), about: 1)]
        #expect(SwarmStuck.reminders(answered, now: minutes(40)).isEmpty)
        // At the controller's step it does not wait on you yet.
        let atController = row(
            .question,
            "Name?",
            id: 1,
            actor: .agent,
            from: "task:g/a",
            ladder: ["controller", "you"]
        )
        #expect(SwarmStuck.reminders([atController], now: minutes(40)).isEmpty)
        #expect(SwarmStuck.reminders([asked], now: minutes(40), settings: .init(waitingOnYou: 0)).isEmpty)
    }

    @Test func settingsStoredBeforeStuckDetectionReadWithTheDefaults() throws {
        let old = #"{"repos":["acme/site"],"lead":{"agent":"claude"},"workers":[],"limits":{"agents":3,"hours":4,"dollars":40},"autonomy":"planChanges"}"#
        let settings = try JSONDecoder().decode(SwarmSettings.self, from: Data(old.utf8))
        #expect(settings.stuck == .defaults)
        let partial = #"{"noProgress": 20}"#
        let stuck = try JSONDecoder().decode(SwarmStuck.Settings.self, from: Data(partial.utf8))
        #expect(stuck.noProgress == 20)
        #expect(stuck.sameError == 3)
        var changed = SwarmSettings()
        changed.stuck.noProgress = 7
        let back = try JSONDecoder().decode(SwarmSettings.self, from: JSONEncoder().encode(changed))
        #expect(back.stuck.noProgress == 7)
    }
}

// MARK: Usage

struct SwarmUsageTests {
    private func worker(_ slug: String, start: Double, end: Double?, cost: Double?, tokens: Int?) -> SwarmWorker {
        SwarmWorker(
            id: "w-\(slug)", task: "g/\(slug)", owner: GoalItem.Owner(agent: slug == "c" ? "codex" : "claude"),
            host: "lead", repo: "acme/site", branch: "b", base: "main", worktree: "/wt", startedAt: minutes(start),
            endedAt: end.map(minutes), costUSD: cost, tokens: tokens
        )
    }

    @Test func endedWorkersCountAsRecordedLiveOnesAsTheirHooksSayNow() {
        let run = GoalSwarm(
            id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(), startedAt: now,
            workers: [
                worker("a", start: 0, end: 30, cost: 1.5, tokens: 100_000),
                worker("b", start: 10, end: nil, cost: 0.4, tokens: 20000),
                worker("c", start: 20, end: nil, cost: nil, tokens: nil),
            ]
        )
        let rollup = SwarmUsageRollup.of(run, live: ["w-b": .init(dollars: 0.9, tokens: 50000)], now: minutes(40))
        // b's persisted 0.4 is replaced by its live 0.9, not added to it.
        #expect(abs(rollup.dollars - 2.4) < 0.0001)
        #expect(rollup.tokens == 150_000)
        #expect(rollup.byTask["g/b"]?.dollars == 0.9)
        #expect(rollup.byAgent["claude"]?.tokens == 150_000)
        #expect(rollup.byAgent["codex"]?.dollars == 0)
        #expect(rollup.agentTime == (30 + 30 + 20) * 60)
        // Without live numbers a live worker counts what was persisted last.
        #expect(abs(SwarmUsageRollup.of(run, now: minutes(40)).dollars - 1.9) < 0.0001)
    }

    @Test func liveUseIsWrittenAgainOnlyWhenItMovedEnough() {
        let stored = SwarmUsageRollup.Use(dollars: 1, tokens: 1000)
        #expect(!SwarmUsageRollup.worthPersisting(.init(dollars: 1.005, tokens: 5000), over: stored))
        #expect(SwarmUsageRollup.worthPersisting(.init(dollars: 1.01, tokens: 1000), over: stored))
        #expect(SwarmUsageRollup.worthPersisting(.init(dollars: 1, tokens: 11000), over: stored))
        #expect(SwarmUsageRollup.tokens(1_250_000) == "1.2M tokens")
        #expect(SwarmUsageRollup.tokens(840_000) == "840k tokens")
        #expect(SwarmUsageRollup.tokens(12) == "12 tokens")
    }
}

// MARK: The map

struct SwarmMapTests {
    private let tasks = [
        task("survey", phase: "Survey"), task("consumers", phase: "Survey"),
        task("generator", phase: "Core", after: ["survey"]), task(
            "validator",
            phase: "Core",
            after: ["survey", "consumers"]
        ),
        task("tests", phase: "Tests", after: ["generator"]),
    ]

    @Test func theGoalIsOnTheLeftPhasesAreColumnsAndEveryAfterIsAnEdge() throws {
        let layout = SwarmMap.layout(
            goal: "Goal", lead: "claude", tasks: tasks, states: ["g/survey": .done, "g/validator": .asking]
        )
        #expect(layout.columns == ["Survey", "Core", "Tests"])
        #expect(layout.columnCount == 4)
        #expect(layout.nodes(in: 0).map(\.id) == ["lead"])
        #expect(layout.nodes(in: 2).map(\.id) == ["g/generator", "g/validator"])
        let validator = try #require(layout.node("g/validator"))
        #expect(validator.number == "2.2")
        #expect(validator.state == .asking)
        #expect(layout.node("g/tests")?.state == .waiting)
        let edges = layout.edges.map { "\($0.from)>\($0.to)" }
        #expect(edges == [
            "lead>g/survey", "lead>g/consumers", "g/survey>g/generator", "g/survey>g/validator",
            "g/consumers>g/validator", "g/generator>g/tests",
        ])
        #expect(layout.edges.first { $0.from == "g/survey" }?.settled == true)
        #expect(layout.edges.first { $0.from == "g/consumers" }?.settled == false)
        // Columns left to right, edges from a card's right to the next one's left.
        let survey = try #require(layout.node("g/survey"))
        #expect(survey.frame.x > 0)
        #expect(validator.frame.x > survey.frame.maxX)
        let edge = try #require(layout.edges.first { $0.to == "g/validator" })
        #expect(edge.start.x == survey.frame.maxX)
        #expect(edge.end.x == validator.frame.x)
        #expect(layout.width == validator.frame.maxX + SwarmMap.Metrics().cardWidth + SwarmMap.Metrics().columnGap)
    }

    @Test func theSamePlanLaysOutTheSame() {
        let one = SwarmMap.layout(goal: "G", lead: "claude", tasks: tasks, states: [:])
        let two = SwarmMap.layout(goal: "G", lead: "claude", tasks: tasks, states: [:])
        #expect(one == two)
        // The tallest column fills the height; a shorter one is centred in it.
        let core = one.nodes(in: 3)
        #expect(core.count == 1)
        #expect(abs((core[0].frame.midY) - (one.node("lead")?.frame.midY ?? 0)) < 0.001)
    }

    @Test func hlMoveBetweenColumnsAndJkBetweenCardsKeepingTheRow() {
        let layout = SwarmMap.layout(goal: "G", lead: "claude", tasks: tasks, states: [:])
        #expect(SwarmMap.move(from: nil, columns: 0, rows: 0, in: layout) == "lead")
        #expect(SwarmMap.move(from: "lead", columns: 1, rows: 0, in: layout) == "g/survey")
        #expect(SwarmMap.move(from: "g/survey", columns: 0, rows: 1, in: layout) == "g/consumers")
        #expect(SwarmMap.move(from: "g/consumers", columns: 0, rows: 1, in: layout) == "g/consumers")
        #expect(SwarmMap.move(from: "g/consumers", columns: 1, rows: 0, in: layout) == "g/validator")
        #expect(SwarmMap.move(from: "g/validator", columns: 1, rows: 0, in: layout) == "g/tests")
        #expect(SwarmMap.move(from: "g/tests", columns: 1, rows: 0, in: layout) == "g/tests")
        #expect(SwarmMap.move(from: "g/survey", columns: -1, rows: 0, in: layout) == "lead")
        #expect(SwarmMap.move(from: "lead", columns: -1, rows: 0, in: layout) == "lead")
    }

    @Test func aCardsColourFollowsItsTaskAndItsWorker() {
        func state(_ value: SwarmTaskStatus.State, _ worker: AgentState? = nil, stuck: Bool = false) -> SwarmMap.State {
            SwarmMap.state(SwarmTaskStatus(value), worker: worker, stuck: stuck)
        }
        #expect(state(.done) == .done)
        #expect(state(.merged) == .done)
        #expect(state(.green) == .done)
        #expect(state(.pr) == .working)
        #expect(state(.working) == .working)
        #expect(state(.working, .asking) == .asking)
        #expect(state(.working, .blocked) == .blocked)
        #expect(state(.working, .asking, stuck: true) == .stuck)
        #expect(state(.paused) == .blocked)
        #expect(state(.ready) == .waiting)
        #expect(SwarmMap.state(nil, worker: nil, stuck: false) == .waiting)
    }
}

// MARK: Since you last looked

struct SwarmDigestTests {
    private let tasks = [task("a"), task("b", after: ["a"])]

    private func board(_ rows: [SwarmSteer], versions: [SwarmPlanVersion] = []) -> SwarmBoard {
        SwarmBoard(
            swarm: GoalSwarm(id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(), startedAt: now),
            versions: versions, steering: rows
        )
    }

    @Test func onlyWhatHappenedSinceYouLookedAndWhatWaitsOnYou() {
        let rows = [
            row(.work, "1.1 A: claude from main", id: 1, at: minutes(1), ref: "task:g/a"),
            row(.question, "Fail or warn?", id: 2, actor: .agent, at: minutes(2), from: "task:g/a", ladder: ["you"]),
            row(.answer, "warn", id: 3, actor: .you, at: minutes(12), about: 2),
            row(.work, "1.2 B: claude stacked", id: 4, at: minutes(20), ref: "task:g/b"),
            row(
                .stuck,
                "B looks stuck",
                id: 5,
                at: minutes(30),
                ref: "task:g/b",
                step: "nudge",
                reason: "the same error 3×: x"
            ),
            row(.question, "Name it?", id: 6, actor: .agent, at: minutes(31), from: "task:g/b", ladder: ["you"]),
        ]
        let versions = [
            SwarmPlanVersion(
                swarm: "g/swarm-1",
                goal: "g",
                number: 2,
                at: minutes(15),
                author: .you,
                note: "moved B",
                tasks: tasks
            ),
            SwarmPlanVersion(
                swarm: "g/swarm-1",
                goal: "g",
                number: 1,
                at: minutes(0),
                author: .lead,
                note: "draft",
                tasks: tasks
            ),
        ]
        let digest = SwarmDigest.of(
            board(rows, versions: versions), since: minutes(10), tasks: tasks,
            states: ["g/a": SwarmTaskStatus(.done)], now: minutes(40)
        )
        #expect(digest.facts == [
            "Started: 1.2 B.", "1 of 2 tasks merged or done.", "1.2 B got stuck: the same error 3×: x.",
            "1 question asked.",
        ])
        #expect(digest.decisions == ["warn: Fail or warn? (you)"])
        #expect(digest.versions == ["v2 · you · moved B"])
        #expect(digest.waitingOnYou == 1)
        #expect(digest.lastRow == 6)
        #expect(digest.key("g/swarm-1") == "g/swarm-1@\(Int(minutes(10).timeIntervalSince1970))#6")
        #expect(digest.plain.hasSuffix("1 question waits on you."))
        #expect(digest.inputs(title: "G").timeline.contains("Decided: warn: Fail or warn? (you)"))
    }

    @Test func nothingSinceIsSaid() {
        let digest = SwarmDigest.of(
            board([row(.work, "1.1 A: x", id: 1, at: minutes(1), ref: "task:g/a")]), since: minutes(5), tasks: tasks,
            states: [:], now: minutes(6)
        )
        #expect(digest.facts == ["Nothing changed."])
        #expect(!digest.isEmpty)
        #expect(digest.plain == "Nothing changed.")
    }
}

// MARK: The summary

struct SwarmSummaryTests {
    private let tasks = [task("a", phase: "One"), task("b", phase: "Two", after: ["a"]), task("c", phase: "Two")]

    private func board(_ rows: [SwarmSteer]) -> SwarmBoard {
        let workers = [
            SwarmWorker(
                id: "w1",
                task: "g/a",
                owner: GoalItem.Owner(agent: "claude"),
                host: "l",
                repo: "acme/site",
                branch: "swarm/g/a",
                base: "main",
                worktree: "/a",
                startedAt: minutes(10),
                endedAt: minutes(50),
                costUSD: 2
            ),
            SwarmWorker(
                id: "w2",
                task: "g/b",
                owner: GoalItem.Owner(agent: "codex"),
                host: "l",
                repo: "acme/site",
                branch: "swarm/g/b",
                base: "swarm/g/a",
                stackedOn: "g/a",
                worktree: "/b",
                startedAt: minutes(30),
                endedAt: minutes(90),
                costUSD: 1
            ),
            SwarmWorker(
                id: "w3",
                task: "g/c",
                owner: GoalItem.Owner(agent: "claude"),
                host: "l",
                repo: "acme/site",
                branch: "swarm/g/c",
                base: "main",
                worktree: "/c",
                startedAt: minutes(12),
                endedAt: minutes(40)
            ),
        ]
        let swarm = GoalSwarm(
            id: "g/swarm-1", goal: "g", number: 1, status: .done, settings: SwarmSettings(), plan: 2, approved: 2,
            startedAt: now, endedAt: minutes(120), runningAt: minutes(10), workers: workers
        )
        let versions = [1, 2].map {
            SwarmPlanVersion(swarm: swarm.id, goal: "g", number: $0, at: now, author: .lead, note: "", tasks: tasks)
        }
        return SwarmBoard(swarm: swarm, versions: versions, steering: rows)
    }

    private let facts: [String: SwarmTaskFacts] = [
        "g/a": SwarmTaskFacts(pr: .merged(number: 12)), "g/b": SwarmTaskFacts(pr: .merged(number: 14)),
        "g/c": SwarmTaskFacts(pr: .open(number: 13, branch: "swarm/g/c", checks: .running)),
    ]

    private var rows: [SwarmSteer] {
        [
            row(.approve, "approved v2", id: 1, actor: .you, at: minutes(8)),
            row(.question, "Fail or warn?", id: 2, actor: .agent, at: minutes(20), from: "task:g/a", ladder: ["you"]),
            row(.answer, "warn", id: 3, actor: .you, at: minutes(34), about: 2),
            row(
                .question,
                "Name it X or Y?",
                id: 4,
                actor: .agent,
                at: minutes(40),
                from: "task:g/b",
                options: ["X", "Y"],
                ladder: ["controller", "you"]
            ),
            row(.answer, "X", id: 5, actor: .controller, at: minutes(41), about: 4, from: "controller"),
            row(
                .question,
                "Does it stream?",
                id: 6,
                actor: .agent,
                at: minutes(42),
                from: "task:g/c",
                ladder: ["peer", "you"]
            ),
            row(.answer, "yes", id: 7, actor: .agent, at: minutes(44), about: 6, from: "task:g/a"),
            row(
                .stuck,
                "B looks stuck",
                id: 8,
                at: minutes(60),
                ref: "task:g/b",
                step: "nudge",
                reason: "the same error 4×: x"
            ),
            row(.stuck, "B is still stuck", id: 9, at: minutes(70), ref: "task:g/b", step: "ask"),
            row(.stuck, "B moves again", id: 10, at: minutes(80), ref: "task:g/b", step: "clear"),
            row(.question, "Split C?", id: 11, actor: .agent, at: minutes(85), from: "task:g/c", ladder: ["you"]),
            row(.message, "stay stacked", id: 12, actor: .lead, at: minutes(30), from: "lead"),
        ]
    }

    @Test func heedAssemblesWhatTheRunRecordsAndTheLeadsWordsGoOverIt() {
        let use = SwarmUsageRollup.of(board(rows).swarm, now: minutes(120))
        let summary = SwarmSummary.assemble(
            board(rows), goal: "Redirects", tasks: tasks, facts: facts, use: use, now: minutes(200)
        )
        // From when it ran (its first worker), not from when it was planned.
        #expect(summary.elapsed == 110 * 60)
        #expect(summary.agentTime == (40 + 60 + 28) * 60)
        #expect(summary.agents == 2)
        #expect(summary.versions == 2)
        #expect(summary.dollars == 3)
        #expect(!summary.byLead)
        #expect(summary.outcome == "2 of 3 tasks merged, in merge order. The swarm opened 3 PRs, 1 stacked.")
        #expect(summary.prs.map(\.number) == ["1.1", "2.1", "2.2"])
        #expect(summary.prs.map(\.order) == [1, 2, 3])
        #expect(summary.prs.map(\.pr) == [12, 14, 13])
        #expect(summary.prs.map(\.state) == ["merged", "merged", "CI running"])
        #expect(summary.prs[1].stackedOn == "1.1")
        #expect(summary.lanes.map(\.name) == ["lead", "1.1", "2.1", "2.2"])
        #expect(summary.lanes[0].spans == [SwarmSummary.Span(kind: .working, start: 20 * 60, end: 20 * 60 + 120)])
        #expect(summary.lanes[2].spans.map(\.kind) == [.working, .waiting, .stuck])
        #expect(summary.lanes[2].spans.last == SwarmSummary.Span(kind: .stuck, start: 50 * 60, end: 70 * 60))
        #expect(summary.episodes.map(\.kind) == [.stuck, .waited])
        #expect(summary.episodes[0].title == "2.1: the same error 4×: x")
        #expect(summary.episodes[0].minutes == 20)
        #expect(summary.episodes[0].detail == "Nudged to try another way, then asked for help.")
        #expect(summary.episodes[1].minutes == 14)
        #expect(summary.questions.map(\.answeredBy) == ["you", "controller", "peer", nil])
        #expect(summary.questions.map(\.from) == ["1.1", "2.1", "2.2", "2.2"])
        #expect(summary.questions[0].seconds == TimeInterval(14 * 60))
        #expect(summary.answeredLine == "1 you · 1 controller · 1 peer")
        #expect(summary.decisions == ["Fail or warn? warn (you)", "Name it X or Y? X (controller)"])
        #expect(summary.followUps == ["Unanswered: Split C?"])
        #expect(summary.markdown.contains("### PRs, in merge order\n1. 1.1 A: #12 merged"))
        #expect(summary.markdown.contains("2. 2.1 B: #14 merged · stacked on 1.1"))
        #expect(summary.markdown.contains("- Split C? (2.2) → unanswered"))

        let written = rows + [SwarmSteer(
            id: 13, swarm: "g/swarm-1", goal: "g", at: minutes(121), actor: .lead, kind: .summary,
            text: "Redirects are built at build time.", decisions: [
                "Warn, do not fail (you)",
                "Fail or warn? warn (you)",
            ],
            followUps: ["Document the warn setting"]
        )]
        let byLead = SwarmSummary.assemble(
            board(written), goal: "Redirects", tasks: tasks, facts: facts, use: use, now: minutes(200)
        )
        #expect(byLead.byLead)
        #expect(byLead.outcome == "Redirects are built at build time.")
        #expect(byLead.decisions == [
            "Warn, do not fail (you)",
            "Fail or warn? warn (you)",
            "Name it X or Y? X (controller)",
        ])
        #expect(byLead.followUps == ["Document the warn setting", "Unanswered: Split C?"])
        let entry = byLead.ledger(repos: ["acme/site"], pulls: [], lead: "claude", usage: nil)
        #expect(entry.id == "swarm:g/swarm-1")
        #expect(entry.source == .signOff)
        #expect(entry.summary == "Redirects are built at build time.")
        #expect(SwarmSummary.duration(3 * 3600 + 22 * 60) == "3 h 22 m")
        #expect(SwarmSummary.duration(14 * 60) == "14 m")
    }

    @Test func itRoundTripsOnTheRun() throws {
        let summary = SwarmSummary.assemble(
            board(rows), goal: "G", tasks: tasks, facts: facts, use: SwarmUsageRollup.of(board(rows).swarm, now: now),
            now: minutes(200)
        )
        var run = board(rows).swarm
        run.summary = summary
        let back = try JSONDecoder().decode(GoalSwarm.self, from: JSONEncoder().encode(run))
        #expect(back.summary == summary)
    }
}

// MARK: Repeat rules

struct SwarmRuleListTests {
    @Test func aDeletedRuleNoLongerAnswersOrLists() {
        let rule = SwarmSteer(
            id: 1, swarm: "g/swarm-1", goal: "g", at: now, actor: .you, kind: .rule, text: "Fail or warn?",
            options: ["fail", "warn"], answer: "warn"
        )
        let other = SwarmSteer(
            id: 2, swarm: "g/swarm-1", goal: "g", at: minutes(1), actor: .you, kind: .rule, text: "Real or fixtures?",
            options: ["real", "fixtures"], answer: "fixtures"
        )
        #expect(SwarmRepeat.rules([rule, other]).map(\.id) == [2, 1])
        #expect(SwarmRepeat.answered([rule, other]).count == 2)
        let deleted = [rule, other, row(.unrule, id: 3, actor: .you, at: minutes(2), about: 1)]
        #expect(SwarmRepeat.rules(deleted).map(\.id) == [2])
        #expect(SwarmRepeat.answered(deleted).map(\.id) == [2])
        #expect(SwarmRepeat
            .exact("Fail or warn?", options: ["fail", "warn"], among: SwarmRepeat.answered(deleted)) == nil)
    }
}

// MARK: Through GoalOps and the CLI

struct SwarmWatchOpsTests {
    private func world() async throws -> (GoalOps, GoalSwarm) {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "lead-1", origin: .swarm, at: now))
        let started = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.setLead(swarm: started.id, session: "lead-1", now: now)
        try await ops.proposePlan(swarm: started.id, input: SwarmPlanInput.parse("""
        [{"id": "a", "title": "A", "phase": "Build"}, {"id": "b", "title": "B", "phase": "Build", "after": ["a"]}]
        """, goal: goal.id), now: now)
        try await ops.approvePlan(swarm: started.id, now: now)
        for task in ["a", "b"] {
            try await ops.startWorker(swarm: started.id, SwarmWorker(
                id: "w-\(task)", task: "faster-builds/\(task)", owner: GoalItem.Owner(agent: "claude"),
                host: "lead-1", repo: "acme/site", branch: "swarm/\(task)", base: "main", worktree: "/wt/\(task)",
                startedAt: now
            ), text: "started", now: now)
        }
        return try await (ops, ops.board(of: started.id).swarm)
    }

    @Test func aLiveWorkersUseIsKeptOnItsRecordUntilItEnds() async throws {
        let (ops, swarm) = try await world()
        #expect(try await ops.noteWorkerUse(swarm: swarm.id, worker: "w-a", use: .init(dollars: 0.7, tokens: 12000)))
        var run = try await ops.board(of: swarm.id).swarm
        #expect(run.workers.first { $0.id == "w-a" }?.costUSD == 0.7)
        #expect(run.workers.first { $0.id == "w-a" }?.tokens == 12000)
        try await ops.endWorker(swarm: swarm.id, worker: "w-a", outcome: .turnOver, cost: 1.1, now: minutes(5))
        #expect(try await !ops.noteWorkerUse(swarm: swarm.id, worker: "w-a", use: .init(dollars: 9)))
        run = try await ops.board(of: swarm.id).swarm
        #expect(run.workers.first { $0.id == "w-a" }?.costUSD == 1.1)
        #expect(try await !ops.noteWorkerUse(swarm: swarm.id, worker: "nobody", use: .init(dollars: 9)))
    }

    @Test func aStuckWorkerIsNudgedThenAskedForAndTheQuestionClimbsToTheController() async throws {
        let (ops, swarm) = try await world()
        let signal = SwarmStuck.Signal(reasons: [.sameError("error cs#", count: 3)])
        try await ops.nudgeStuck(swarm: swarm.id, task: "faster-builds/b", title: "1.2 B", signal: signal, now: now)
        var board = try await ops.board(of: swarm.id)
        let stuck = try #require(board.steering.last { $0.kind == .stuck })
        #expect(stuck.step == "nudge")
        #expect(stuck.reason == "the same error 3×: error cs#")
        let nudge = try #require(board.steering.last { $0.kind == .message })
        #expect(nudge.actor == .heed)
        #expect(nudge.to == "task:faster-builds/b")
        #expect(nudge.text.contains("try a different approach"))
        // The nudge waits for the worker like any message.
        let waiting = SwarmDelivery.pending(for: .task("faster-builds/b"), board.steering, now: now)
        #expect(waiting.map(\.row.id) == [nudge.id])

        let question = try await ops.askStuck(
            swarm: swarm.id, task: "faster-builds/b", number: "1.2", title: "B", signal: signal, now: minutes(10)
        )
        #expect(question.from == "task:faster-builds/b")
        #expect(question.category == "implementation")
        // Its peer (a is at work, and b waits for it) first, then the controller, then you.
        #expect(question.ladder == ["peer", "controller", "you"])
        #expect(question.to == "task:faster-builds/a")
        #expect(question.options == ["try a different approach", "stop and wait for the owner"])
        board = try await ops.board(of: swarm.id)
        #expect(SwarmStuck.episode(of: "faster-builds/b", board.steering)?.step == "ask")
        #expect(board.steering.last?.about == question.id)
        try await ops.clearStuck(swarm: swarm.id, task: "faster-builds/b", title: "B", now: minutes(20))
        board = try await ops.board(of: swarm.id)
        #expect(SwarmStuck.episode(of: "faster-builds/b", board.steering) == nil)
        let reminded = try await ops.remind(swarm: swarm.id, question: question.id ?? 0, minutes: 15, now: minutes(30))
        #expect(reminded.kind == .remind)
    }

    @Test func theLeadWritesTheSummaryEvenOnceTheSwarmIsDoneAndOnlyTheLead() async throws {
        let (ops, swarm) = try await world()
        try await ops.advanceSwarm(swarm.id, to: .done, now: minutes(60))
        let lead = GoalCaller(session: "lead-1", title: "lead")
        let worker = GoalCaller(session: "lead-1", title: "worker", worker: "faster-builds/a")
        let command = try SwarmCommandLine.parse([
            "swarm", "summary", "--outcome", "Builds are faster.", "--decision", "Cache by hash",
            "--follow-up", "Measure cold builds", "--decision", "Keep the old flag",
        ])
        #expect(command.verb == .swarmSummary)
        #expect(command.text == "Builds are faster.")
        #expect(command.decisions == ["Cache by hash", "Keep the old flag"])
        #expect(command.followUps == ["Measure cold builds"])
        let refused = await GoalControl.run(command, caller: worker, ops: ops, files: .fixture, now: minutes(61))
        if case let .reply(reply) = refused { #expect(reply.exit == .refused) } else { Issue.record("no reply") }
        let done = await GoalControl.run(command, caller: lead, ops: ops, files: .fixture, now: minutes(61))
        guard case let .reply(reply) = done else {
            Issue.record("no reply")
            return
        }
        #expect(reply.outcome == "applied")
        let written = try await SwarmSummary.Written.of(ops.board(of: swarm.id).steering)
        #expect(written?.outcome == "Builds are faster.")
        #expect(written?.decisions == ["Cache by hash", "Keep the old flag"])
        #expect(throws: (any Error).self) { try SwarmCommandLine.parse(["swarm", "summary"]) }
        #expect(throws: (any Error).self) { try SwarmCommandLine.parse(["swarm", "summary", "--outcome"]) }
        #expect(throws: (any Error).self) { try SwarmCommandLine.parse(["swarm", "summary", "--who", "x"]) }
    }

    @Test func aSummaryIsKeptOnTheRunAndARuleCanBeDeleted() async throws {
        let (ops, swarm) = try await world()
        let asked = try await ops.ask(
            swarm: swarm.id, question: "Name it A or B?", options: ["A", "B"], from: .task("faster-builds/b"),
            actor: .agent, now: now
        )
        try await ops.rule(swarm: swarm.id, question: asked.id ?? 0, answer: "A", now: now)
        let rules = try await ops.repeatRules(goal: swarm.goal)
        #expect(rules.count == 1)
        try await ops.deleteRule(rules[0].id ?? 0, goal: swarm.goal, now: minutes(1))
        #expect(try await ops.repeatRules(goal: swarm.goal).isEmpty)
        await #expect(throws: GoalOpError.self) { try await ops.deleteRule(999, goal: swarm.goal, now: now) }
        let board = try await ops.board(of: swarm.id)
        let summary = SwarmSummary.assemble(
            board, goal: "Faster builds", tasks: board.tasks, facts: [:],
            use: SwarmUsageRollup.of(board.swarm, now: now), now: now
        )
        try await ops.saveSummary(swarm: swarm.id, summary)
        #expect(try await ops.board(of: swarm.id).swarm.summary == summary)
    }
}

struct SwarmStuckSettingTests {
    @Test func theWordsSetTheirFieldAndBadValuesAreRefused() {
        let base = SwarmStuck.Settings()
        #expect(base.setting("estimate", to: "2")?.overEstimate == 2)
        #expect(base.setting("errors", to: "4")?.sameError == 4)
        #expect(base.setting("quiet", to: "15")?.noProgress == 15)
        #expect(base.setting("peer", to: "10")?.waitingOnPeer == 10)
        #expect(base.setting("you", to: "20")?.waitingOnYou == 20)
        #expect(base.setting("estimate", to: "0")?.overEstimate == 0)
        #expect(base.setting("estimate", to: "0.5") == nil)
        #expect(base.setting("quiet", to: "-1") == nil)
        #expect(base.setting("quiet", to: "soon") == nil)
        #expect(base.setting("mood", to: "3") == nil)
    }

    @Test func changingThemIsASteeringRow() async throws {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "G", statement: "x", now: now)
        let swarm = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        let changed = try await ops.setStuck(swarm: swarm.id, SwarmStuck.Settings(noProgress: 20), now: now)
        #expect(changed.settings.stuck.noProgress == 20)
        let rows = try await ops.board(of: swarm.id).steering
        #expect(rows.last?.kind == .limit)
        #expect(rows.last?.text.contains("10 min no progress") == true)
        let count = rows.count
        try await ops.setStuck(swarm: swarm.id, SwarmStuck.Settings(noProgress: 20), now: now)
        #expect(try await ops.board(of: swarm.id).steering.count == count)
    }
}

struct SwarmStuckScreenTests {
    private func reading(_ state: HunchScreen.State, _ confidence: Double = 0.9) -> HunchScreen.Reading {
        HunchScreen.Reading(state: state, confidence: confidence, at: now)
    }

    @Test func withoutHunchAPromptOnAWorkingPaneIsWaitingByTheGuess() {
        #expect(SwarmStuck.screen(guessed: .blocked, reported: .working) == .init(.waiting, by: .guess))
        #expect(SwarmStuck.screen(guessed: .asking, reported: .working) == .init(.waiting, by: .guess))
        #expect(SwarmStuck.screen(guessed: .asking, reported: .asking) == nil)
        #expect(SwarmStuck.screen(guessed: .working, reported: .working) == nil)
        #expect(SwarmStuck.screen(guessed: nil, reported: .working) == nil)
    }

    @Test func hunchsReadingDecidesOverTheGuess() {
        #expect(SwarmStuck.screen(hunch: reading(.stuck), guessed: nil, reported: .working)
            == .init(.stuck, by: .hunch))
        #expect(SwarmStuck.screen(hunch: reading(.waiting), guessed: nil, reported: .working)
            == .init(.waiting, by: .hunch))
        // Hunch reads working or done: no label, even where the guess saw a prompt.
        #expect(SwarmStuck.screen(hunch: reading(.working), guessed: .asking, reported: .working) == nil)
        #expect(SwarmStuck.screen(hunch: reading(.done), guessed: .blocked, reported: .working) == nil)
        // Only while the hooks say working.
        #expect(SwarmStuck.screen(hunch: reading(.stuck), guessed: nil, reported: .asking) == nil)
        #expect(SwarmStuck.screen(hunch: reading(.stuck), guessed: nil, reported: nil) == nil)
    }

    @Test func anUnsureReadingLeavesItToTheGuess() {
        #expect(SwarmStuck.screen(hunch: reading(.stuck, 0.49), guessed: .asking, reported: .working)
            == .init(.waiting, by: .guess))
        #expect(SwarmStuck.screen(hunch: reading(.working, 0.49), guessed: nil, reported: .working) == nil)
        #expect(SwarmStuck.screen(hunch: reading(.stuck, 0.5), guessed: .asking, reported: .working)
            == .init(.stuck, by: .hunch))
    }
}

// MARK: Volume

/// How much activity one busy worker-hour leaves in the event log, from a fixture of real-shaped hook payloads
/// (`Fixtures/worker-hour.jsonl`: every PostToolUse of an hour and a `git status` a minute). The numbers are in
/// docs/goals/swarms/watching.md; this keeps them true.
struct ActivityVolumeTests {
    private struct Hour {
        var calls: [(at: Date, input: [String: Any])] = []
        var polls: [(at: Date, status: String, stat: String, head: String)] = []
        var hookBytes = 0
    }

    private func hour() throws -> Hour {
        let url = try #require(Bundle.module.url(
            forResource: "worker-hour", withExtension: "jsonl", subdirectory: "Fixtures"
        ))
        var hour = Hour()
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            let object = try #require(JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
            let at = now.addingTimeInterval(object["t"] as? Double ?? 0)
            if let input = object["input"] as? [String: Any] {
                hour.calls.append((at, input))
                hour.hookBytes += try JSONSerialization.data(withJSONObject: input).count
            } else if let poll = object["poll"] as? [String: String] {
                hour.polls.append((at, poll["status"] ?? "", poll["stat"] ?? "", poll["head"] ?? ""))
            }
        }
        return hour
    }

    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-activity-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The rows heed writes for the hour: calls through the throttle, polls that changed something.
    private func rows(_ hour: Hour) -> [LoggedEvent] {
        var throttle = ActivityThrottle()
        var events: [LoggedEvent] = []
        for (at, input) in hour.calls {
            guard let call = ToolCall.from(hook: input) else { continue }
            let kept = throttle.keep("w", at: at, error: call.error)
            guard kept.keep else { continue }
            let payload = kept.skipped > 0 ? ["skipped": "\(kept.skipped)"] : [:]
            events.append(call.event(
                at: at,
                session: "lead-session-0001",
                subject: "task:anchors/validator-speed",
                payload: payload
            ))
        }
        var last: FileActivity?
        for poll in hour.polls {
            let current = FileActivity.parse(status: poll.status, diffStat: poll.stat, head: poll.head)
            if let change = FileActivity.change(from: last, to: current) {
                events.append(change.event(
                    at: poll.at, session: "lead-session-0001", worktree: "/w/docs-toolkit-swarm-validator-speed",
                    subject: "task:anchors/validator-speed"
                ))
            }
            last = current
        }
        return events
    }

    @Test func aBusyWorkerHourIsAboutFourHundredRowsAndUnderAHundredKilobytes() async throws {
        let hour = try hour()
        let events = rows(hour)
        let file = try folder().appendingPathComponent("heed.sqlite")
        let log = try EventLog(path: file.path)
        let empty = Self.bytes(file)
        await log.append(events)
        let size = try await log.activitySize()
        let disk = Self.bytes(file) - empty
        let calls = events.count { $0.kind == .toolCall }
        let changes = events.count { $0.kind == .fileChange }
        let errors = events.count { $0.payload["error"] == "1" }
        // The measured numbers (docs/goals/swarms/watching.md), within a margin.
        print("activity volume: \(hour.calls.count) calls in the hour (\(hour.hookBytes) bytes of hook input), "
            + "\(calls) kept, \(errors) failed, \(changes) file changes; \(size.rows) rows, \(size.bytes) bytes, "
            + "\(size.bytes / max(size.rows, 1)) bytes a row; the file grew \(disk) bytes")
        #expect(disk < 200_000)
        #expect(hour.calls.count > 300)
        #expect(calls < hour.calls.count)
        #expect(calls > hour.calls.count / 2)
        #expect(errors > 0)
        #expect(changes > 10 && changes <= 60)
        #expect(size.rows == events.count)
        // Never the tool's input or output: a few hundred bytes a row, against kilobytes a hook.
        #expect(size.bytes / size.rows < 160)
        #expect(size.bytes < 100_000)
        #expect(size.bytes * 2 < hour.hookBytes)
        // The size cap: about 80 worker-hours like this one.
        #expect(EventLog.activityMaxBytes / size.bytes > 50)
        // Read back by its task, newest first.
        let read = try await log.activity(about: ["task:anchors/validator-speed"], limit: 5)
        #expect(read["task:anchors/validator-speed"]?.count == 5)
        #expect(read["task:anchors/validator-speed"]?.first?.at == events.map(\.at).max())
    }

    /// The database's bytes on disk, its write-ahead log included.
    private static func bytes(_ file: URL) -> Int {
        [file.path, file.path + "-wal"].compactMap {
            (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? Int) ?? nil
        }.reduce(0, +)
    }

    @Test func pruningDropsOldActivityThenTheOldestPastTheCapAndNothingElse() async throws {
        let hour = try hour()
        let events = rows(hour)
        let log = try EventLog(path: folder().appendingPathComponent("heed.sqlite").path)
        let old = events.prefix(10).map { event -> LoggedEvent in
            var event = event
            event.at = event.at.addingTimeInterval(-20 * 86400)
            return event
        }
        let note = LoggedEvent(at: now.addingTimeInterval(-40 * 86400), kind: .note, session: "s", text: "kept")
        await log.append(old + events + [note])
        let before = try await log.activitySize()
        #expect(before.rows == events.count + 10)
        let aged = await log.pruneActivity(now: now.addingTimeInterval(3600))
        #expect(aged == 10)
        let full = try await log.activitySize()
        let capped = await log.pruneActivity(now: now.addingTimeInterval(3600), maxBytes: full.bytes / 2)
        let after = try await log.activitySize()
        #expect(capped > 0)
        #expect(after.bytes <= full.bytes / 2)
        #expect(after.rows == full.rows - capped)
        // The newest stay; other kinds are not touched.
        let newest = try await log.activity(about: ["task:anchors/validator-speed"], limit: 1)
        #expect(newest["task:anchors/validator-speed"]?.first?.at == events.map(\.at).max())
        #expect(try await log.events(kinds: [.note]).count == 1)
    }
}

struct SwarmWatchFixtureTests {
    @Test func theWatchedWorldIsInTimeOrderAndItsReferencesStillPointRight() throws {
        let world = SwarmFixtures.running(.watch, now: now)
        let rows = SwarmFixtures.number(world.steering, from: 1)
        #expect(rows.map(\.at) == rows.map(\.at).sorted())
        for row in rows {
            if let about = row.about { #expect(rows.contains { $0.id == about }, "\(row.text)") }
        }
        // The overrule still points at the controller's answer it overrules.
        let overrule = try #require(rows.first { $0.kind == .overrule })
        let ref = try #require(overrule.ref.flatMap { Int64($0.dropFirst(6)) })
        #expect(rows.first { $0.id == ref }?.actor == .controller)
        // 2.2's episode is open at the ask step, its question answered by the controller.
        let open = try #require(SwarmStuck.episode(of: "\(SwarmFixtures.anchors)/validator-speed", rows))
        #expect(open.step == "ask")
        let question = try #require(rows.first { $0.id == open.about })
        #expect(SwarmSteering.questions(rows).first { $0.id == question.id }?.answer?.actor == .controller)
        let summary = SwarmFixtures.number(SwarmFixtures.running(.summary, now: now).steering, from: 1)
        #expect(summary.map(\.at) == summary.map(\.at).sorted())
        #expect(SwarmSummary.Written.of(summary)?.followUps.count == 2)
    }

    @Test func theStuckWorkersActivityGivesAStrongSignal() throws {
        let lines = try #require(SwarmFixtures.activity(now: now)["\(SwarmFixtures.anchors)/validator-speed"])
        let facts = SwarmActivityFacts.of(lines)
        let signal = try #require(SwarmStuck.signal(SwarmStuck.Observation(
            now: now, startedAt: now.addingTimeInterval(-52 * 60), estimate: 45, lastActivity: facts.last,
            recentErrors: facts.errors
        )))
        #expect(signal.main == .sameError(SwarmFixtures.stuckDigest, count: 3))
        #expect(signal.strong)
    }
}
