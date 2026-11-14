import Foundation
@testable import HeedCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func part(
    _ slug: String, _ agent: String?, minutes: Int, after: [String] = [], repo: String? = "engine"
) -> SplitPart {
    SplitPart(
        task: SwarmTask(
            id: "g/\(slug)", title: slug, phase: "Build", owner: agent.map { GoalItem.Owner(agent: $0) },
            estimate: minutes, after: after.map { "g/\($0)" }
        ),
        repo: repo
    )
}

struct GoalSplitTests {
    // MARK: Reading the split

    @Test func theSplitCallsJSONBecomesPartsWithRepoSizeAndContext() throws {
        let text = """
        Here is the split:
        {"lead": "claude:opus", "parts": [
          {"id": "schema", "title": "Schema v2", "repo": "acme/engine", "size": "M", "estimate": "2h",
           "doneWhen": ["the schema is reviewed"], "context": ["store/", "decision: online"]},
          {"id": "migrate", "title": "Migrate the store", "repo": "acme/engine", "size": "L", "estimate": "3h 10m",
           "after": ["schema", "nowhere"], "owner": "codex"},
          {"title": "Docs", "size": "XS"}
        ]}
        """
        let draft = try SplitDraft.parse(text, goal: "g", fromPlan: 3)
        #expect(draft.parts.count == 3)
        #expect(draft.fromPlan == 3)
        #expect(draft.lead == GoalItem.Owner(agent: "claude", model: "opus"))
        let first = draft.parts[0]
        #expect(first.id == "g/schema")
        #expect(first.repo == "acme/engine")
        #expect(first.repoName == "engine")
        #expect(first.size == .m)
        #expect(first.minutes == 120)
        #expect(first.context == ["store/", "decision: online"])
        #expect(first.task.doneWhen == ["the schema is reviewed"])
        // Unknown waits are dropped; owners come from assignment, never from the model.
        #expect(draft.parts[1].task.after == ["g/schema"])
        #expect(draft.parts[1].agent == nil)
        // A part with no estimate takes its size's typical one.
        #expect(draft.parts[2].minutes == PartSize.xs.typicalMinutes)
        #expect(draft.number(of: "g/migrate") == 2)
    }

    @Test func aSplitThatIsNotJSONOrHasNoPartsSaysSo() {
        #expect(throws: SplitDraft.ParseError.self) { try SplitDraft.parse("no idea", goal: "g") }
        #expect(throws: SplitDraft.ParseError.self) { try SplitDraft.parse("{\"parts\": []}", goal: "g") }
    }

    @Test func partsWaitingInACircleLoseTheirWaitsRatherThanTheSplit() throws {
        let text = """
        {"parts": [{"id": "a", "title": "A", "after": ["b"]}, {"id": "b", "title": "B", "after": ["a"]}]}
        """
        let draft = try SplitDraft.parse(text, goal: "g")
        #expect(draft.parts.allSatisfy { $0.task.after.isEmpty })
    }

    @Test func sizesReadFromEstimatesAndWords() {
        #expect(PartSize(minutes: 35) == .xs)
        #expect(PartSize(minutes: 90) == .s)
        #expect(PartSize(minutes: 180) == .m)
        #expect(PartSize(minutes: 181) == .l)
        #expect(PartSize(word: "large") == .l)
        #expect(PartSize(word: "?") == nil)
        #expect(PartSize.l.next == .xs)
        #expect([PartSize.xs, .s, .m, .l].map(\.pips) == [1, 1, 2, 3])
    }

    @Test func splittingAPartPutsItsHalvesInItsPlaceAndRewiresWhatWaitedForIt() {
        var draft = SplitDraft(parts: [
            part("a", "claude", minutes: 60),
            part("b", "codex", minutes: 240, after: ["a"]),
            part("c", "claude", minutes: 30, after: ["b"]),
        ])
        draft.update("g/b") { $0.pinned = true }
        draft.replace("g/b", with: [part("x", nil, minutes: 120), part("y", nil, minutes: 120)])
        #expect(draft.parts.map(\.id) == ["g/a", "g/x", "g/y", "g/c"])
        #expect(draft.parts[1].task.after == ["g/a"])
        #expect(draft.parts[2].task.after == ["g/x"])
        #expect(draft.parts[3].task.after == ["g/y"])
        #expect(draft.parts[1].agent == "codex")
        #expect(draft.parts[2].pinned)
    }

    @Test func theSwarmTasksLeaveOutPartsPutOffAndTheirWaits() {
        var draft = SplitDraft(parts: [part("a", "claude", minutes: 60), part("b", "codex", minutes: 60, after: ["a"])])
        draft.update("g/a") { $0.later = true }
        #expect(draft.swarmTasks.map(\.id) == ["g/b"])
        #expect(draft.swarmTasks[0].after.isEmpty)
        #expect(draft.swarmTasks[0].owner?.agent == "codex")
    }

    // MARK: Quota and the fleet

    @Test func codexsWindowIsItsRingAndAResetWindowIsFull() {
        var usage = AgentUsage()
        usage.rateLimitUsedPercent = 19
        usage.rateLimitResetsAt = t0.addingTimeInterval(3600)
        let quota = FleetQuota.of(agent: "codex", usages: [(t0, usage)], now: t0)
        #expect(quota?.source == .window)
        #expect(abs((quota?.left ?? 0) - 0.81) < 1e-9)
        let later = FleetQuota.of(agent: "codex", usages: [(t0, usage)], now: t0.addingTimeInterval(7200))
        #expect(later?.source == .reset)
        #expect(later?.left == 1)
    }

    @Test func anAgentThatHitItsLimitHasAnEmptyRingAndOneWithNothingHasNone() {
        let limited = AgentUsage(rateLimitResetsAt: t0.addingTimeInterval(600))
        let quota = FleetQuota.of(agent: "claude", usages: [(t0, limited)], now: t0)
        #expect(quota?.source == .limited)
        #expect(quota?.left == 0)
        #expect(FleetQuota.of(agent: "claude", usages: [(t0, limited)], now: t0.addingTimeInterval(601)) == nil)
        #expect(FleetQuota.of(agent: "gemini", usages: [(t0, AgentUsage())], now: t0) == nil)
        #expect(FleetQuota.of(agent: "gemini", usages: [], now: t0) == nil)
    }

    @Test func codexsRolloutCarriesItsUsedPercent() {
        let line = #"""
        {"timestamp":"2026-11-14T10:00:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":12.0,"resets_in_seconds":600},"secondary":{"used_percent":40.5,"resets_in_seconds":9000}}}}
        """#
        let report = UsageTranscripts.codex(Data(line.utf8))
        #expect(report?.rateLimitUsedPercent == 40.5)
        let usage = AgentUsage().applying(report ?? UsageReport())
        #expect(usage.rateLimitUsedPercent == 40.5)
    }

    @Test func thePlanIsReadFromEvidenceOnly() {
        #expect(AgentFleet.plan(AgentFleet.copilot, usages: []) == .included)
        #expect(AgentFleet.plan("codex", usages: [AgentUsage(rateLimitResetsAt: t0)]) == .subscription)
        #expect(AgentFleet.plan("opencode", usages: [AgentUsage(costUSD: 0.4)]) == .metered)
        #expect(AgentFleet.plan("gemini", usages: [AgentUsage()]) == .unknown)
    }

    @Test func theWeekBucketsTokensByDayTodayLast() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let week = AgentFleet.week(
            [
                ("claude", t0, 10),
                ("claude", t0.addingTimeInterval(-86400 * 2), 5),
                ("claude", t0.addingTimeInterval(-86400 * 9), 99),
            ],
            now: t0, calendar: calendar
        )
        #expect(week["claude"] == [0, 0, 0, 0, 5, 0, 10])
    }

    @Test func recordsCountPullsMergesAndStallsPerAgentAndRepo() {
        let ledger = [
            LedgerEntry(
                id: "1",
                title: "a",
                repos: ["acme/engine"],
                agent: "codex",
                startedAt: t0,
                outcome: "merged",
                pulls: [PullRef(repo: Repo(org: "acme", name: "engine"), number: 1)]
            ),
            LedgerEntry(
                id: "2",
                title: "b",
                repos: ["acme/engine"],
                agent: "codex",
                startedAt: t0,
                outcome: "abandoned"
            ),
            LedgerEntry(id: "3", title: "c", chat: true, agent: "codex", startedAt: t0, outcome: "merged"),
        ]
        let records = AgentFleet.records(ledger)
        #expect(records == [AgentRecord(agent: "codex", repo: "acme/engine", pulls: 1, merged: 1, stalls: 1)])
    }

    @Test func theFleetKeepsBoardOrderAndBuildsFromTheLedger() {
        var usage = AgentUsage(model: "gpt-5-codex", tokens: TokenCounts(input: 100, output: 50))
        usage.rateLimitUsedPercent = 50
        let ledger = [LedgerEntry(id: "1", title: "a", agent: "codex", startedAt: t0, usage: usage)]
        let fleet = AgentFleet.build(
            installed: ["gemini": nil, "codex": nil, "claude": "sonnet"], copilot: true, ledger: ledger, live: [],
            now: t0
        )
        #expect(fleet.map(\.id) == ["claude", "codex", "copilot", "gemini"])
        #expect(fleet[0].model == "sonnet")
        #expect(fleet[1].model == "gpt-5-codex")
        #expect(fleet[1].quota?.left == 0.5)
        #expect(fleet[1].plan == .subscription)
        #expect(fleet[1].week.last == 150)
        #expect(fleet[2].model == "on GitHub")
        #expect(fleet[3].quota == nil)
    }

    // MARK: Fit and assignment

    @Test func fitRisesWithMergedPullsInTheRepoAndFallsWithStalls() {
        let p = part("a", nil, minutes: 120)
        let agent = FleetAgent(id: "codex")
        let none = SplitAssign.fit(p, agent, records: [])
        let good = SplitAssign.fit(
            p,
            agent,
            records: [AgentRecord(agent: "codex", repo: "acme/engine", pulls: 11, merged: 11)]
        )
        let poor = SplitAssign.fit(
            p,
            agent,
            records: [AgentRecord(agent: "codex", repo: "engine", pulls: 4, merged: 1, stalls: 3)]
        )
        #expect(good > none)
        #expect(poor < good)
        #expect(poor < none + 0.1)
        // Copilot needs a repo to open its PR in.
        let loose = part("b", nil, minutes: 60, repo: nil)
        #expect(SplitAssign.fit(loose, FleetAgent(id: "copilot"), records: []) < SplitAssign.fit(
            loose,
            agent,
            records: []
        ))
    }

    @Test func candidatesAreRankedWithTheirReasons() {
        let draft = SplitFixtures.complex()
        let migrate = draft.part("schema-v2/migrate")!
        let ranked = SplitAssign.candidates(
            for: migrate, fleet: SplitFixtures.fleet(now: t0), records: SplitFixtures.records, draft: draft
        )
        #expect(ranked.first?.agent.id == "codex")
        #expect(ranked.first?.merged == 11)
        #expect(ranked.first { $0.agent.id == "copilot" }?.note == "PR only")
        #expect(ranked.first { $0.agent.id == "claude" }?.note?.hasPrefix("already on 1, 3") == true)
        #expect(ranked.first { $0.agent.id == "claude" }?.extra == 0)
        #expect(ranked.first { $0.agent.id == "gemini" }?.extra == nil)
    }

    @Test func fewestAgentsPutsEveryPartOnTheBestAgentUnlessItFitsPoorly() {
        var draft = SplitFixtures.complex()
        draft.balance = .fewest
        let assigned = SplitAssign.assign(draft, fleet: SplitFixtures.fleet(now: t0), records: SplitFixtures.records)
        let agents = Set(assigned.parts.compactMap(\.agent))
        #expect(agents.count <= 2)
        // Codex merged the most in engine, where most parts are.
        #expect(agents.contains("codex"))
    }

    @Test func speedSpreadsPartsSoTheGoalEndsSooner() {
        var draft = SplitFixtures.complex()
        draft.balance = .fewest
        let fleet = SplitFixtures.fleet(now: t0)
        let fewest = SplitSchedule.make(SplitAssign.assign(draft, fleet: fleet, records: SplitFixtures.records).parts)
        draft.balance = .speed
        let speed = SplitSchedule.make(SplitAssign.assign(draft, fleet: fleet, records: SplitFixtures.records).parts)
        #expect(speed.makespan < fewest.makespan)
        #expect(speed.agents.count > 2)
    }

    @Test func creditsSpreadsWorkOverAgentsWithRoomAndKeepsPinnedParts() {
        var draft = SplitFixtures.complex()
        draft.update("schema-v2/schema") {
            $0.task.owner = GoalItem.Owner(agent: "gemini")
            $0.pinned = true
        }
        let assigned = SplitAssign.assign(draft, fleet: SplitFixtures.fleet(now: t0), records: SplitFixtures.records)
        #expect(assigned.part("schema-v2/schema")?.agent == "gemini")
        #expect(Set(assigned.parts.compactMap(\.agent)).count >= 3)
        #expect(assigned.part("schema-v2/migrate")?.agent == "codex")
    }

    // MARK: The schedule

    @Test func partsStartAfterWhatTheyWaitForAndOneAtATimePerAgent() {
        let parts = [
            part("a", "claude", minutes: 60),
            part("b", "codex", minutes: 120, after: ["a"]),
            part("c", "claude", minutes: 30),
        ]
        let schedule = SplitSchedule.make(parts)
        let a = schedule.slots["g/a"]!
        let b = schedule.slots["g/b"]!
        let c = schedule.slots["g/c"]!
        #expect(a.start == SplitSchedule.brief)
        #expect(abs(b.start - (a.end + SplitSchedule.handoff)) < 1e-9)
        #expect(abs(c.start - (a.end + SplitSchedule.handoff)) < 1e-9)
        #expect(abs(schedule.makespan - b.end) < 1e-9)
        #expect(abs(schedule.alone - 3.5) < 1e-9)
    }

    @Test func theLongestChainFollowsTheHeaviestWaits() {
        let parts = [
            part("a", "claude", minutes: 60),
            part("b", "codex", minutes: 30, after: ["a"]),
            part("c", "codex", minutes: 240, after: ["a"]),
            part("d", "claude", minutes: 10, after: ["b", "c"]),
            part("e", "cursor", minutes: 200),
        ]
        #expect(SplitSchedule.longestChain(parts) == ["g/a", "g/c", "g/d"])
    }

    @Test func theLeadBriefsChecksTheChainAndReportsDone() {
        let parts = [part("a", "claude", minutes: 60), part("b", "codex", minutes: 60, after: ["a"])]
        let schedule = SplitSchedule.make(parts, numbers: ["g/a": 1, "g/b": 2])
        #expect(schedule.moves.map(\.kind) == [.start, .check, .done])
        #expect(schedule.moves[1].label == "checks part 1")
        #expect(schedule.leadIsLight)
        let big = SplitSchedule.make(SplitFixtures.complex().parts)
        #expect(big.moves.contains { $0.kind == .replan })
        #expect(big.chain.first == "schema-v2/schema")
        #expect(big.chain.last == "schema-v2/drill")
    }

    @Test func hoursReadShort() {
        #expect(SplitSchedule.text(0.58) == "35 m")
        #expect(SplitSchedule.text(2 + 1 / 3) == "2 h 20")
        #expect(SplitSchedule.text(3 + 5.0 / 60) == "3 h 05")
        #expect(SplitSchedule.text(19.2) == "19 h")
        #expect(SplitSchedule.text(2) == "2 h")
    }

    @Test func statsCountWhatIsFreeAndWhatCannotBePriced() {
        let draft = SplitFixtures.complex()
        let stats = SplitStats(
            draft: draft,
            schedule: SplitSchedule.make(draft.parts),
            fleet: SplitFixtures.fleet(now: t0)
        )
        #expect(stats.parts == 15)
        #expect(stats.agents == 5)
        #expect(stats.together < stats.alone)
        #expect(stats.unpriced > 0)
        #expect(stats.extraText == "≥$0")
    }

    // MARK: Layout

    @Test func ticksStayAtTenOrFewer() {
        #expect(SplitBoardLayout.tick(for: 2.5) == 0.25)
        #expect(SplitBoardLayout.tick(for: 2.6) == 0.5)
        #expect(SplitBoardLayout.tick(for: 19.3) == 2)
        #expect(SplitBoardLayout.tickText(0) == "0")
        #expect(SplitBoardLayout.tickText(0.5) == "0.5 h")
        #expect(SplitBoardLayout.tickText(20) == "20 h")
    }

    @Test func blocksAreAsWideAsTheirHoursInTheirAgentsRow() {
        let parts = [part("a", "claude", minutes: 120), part("b", "codex", minutes: 60, after: ["a"])]
        let schedule = SplitSchedule.make(parts)
        var layout = SplitBoardLayout.make(schedule: schedule, rows: ["claude", "codex"], width: 1262)
        layout.connect(parts, chain: schedule.chain)
        let a = layout.blocks["g/a"]!
        let b = layout.blocks["g/b"]!
        #expect(abs(a.width - (2 * layout.pointsPerHour - layout.metrics.blockGap)) < 1e-6)
        #expect(b.y > a.y)
        #expect(abs(layout.x(0) - layout.metrics.header) < 1e-9)
        #expect(layout.part(at: a.x + 2, a.midY) == "g/a")
        #expect(layout.row(at: b.midY) == 1)
        #expect(layout.connectors.count == 1)
        #expect(layout.connectors[0].onChain)
        #expect(layout.connectors[0].points.count == 4)
        #expect(layout.connectors[0].points[1].x <= b.x - 7 + 1e-9)
    }

    @Test func labelsShowWhatFitsTheBlock() {
        let narrow = SplitBoardLayout.Label(width: 36)
        #expect(!narrow.title && !narrow.pips && !narrow.repoName)
        let middle = SplitBoardLayout.Label(width: 80)
        #expect(middle.title && middle.pips && !middle.repoName)
        #expect(SplitBoardLayout.Label(width: 140).repoName)
    }

    @Test func theCursorMovesInTimeAndBetweenRows() {
        let parts = [
            part("a", "claude", minutes: 60),
            part("b", "claude", minutes: 60),
            part("c", "codex", minutes: 60),
        ]
        let schedule = SplitSchedule.make(parts)
        let rows = ["claude", "codex"]
        #expect(SplitCursor.move(from: nil, "l", schedule: schedule, rows: rows) == "g/a")
        #expect(SplitCursor.move(from: "g/a", "l", schedule: schedule, rows: rows) == "g/b")
        #expect(SplitCursor.move(from: "g/a", "j", schedule: schedule, rows: rows) == "g/c")
        #expect(SplitCursor.move(from: "g/c", "j", schedule: schedule, rows: rows) == "g/c")
        #expect(SplitCursor.move(from: "g/c", "k", schedule: schedule, rows: rows) == "g/a")
    }

    // MARK: The goal's page

    @Test func partStatesComeFromTheSwarmMap() {
        #expect(PartState.of(.done, startedAt: nil, minutes: 60, now: t0) == .done)
        #expect(PartState.of(.asking, startedAt: nil, minutes: 60, now: t0) == .asking)
        #expect(PartState.of(.waiting, startedAt: nil, minutes: 60, now: t0) == .planned)
        #expect(PartState.of(.working, startedAt: t0.addingTimeInterval(-1800), minutes: 60, now: t0)
            == .running(progress: 0.5))
        #expect(PartState.of(.working, startedAt: t0.addingTimeInterval(-9000), minutes: 60, now: t0)
            == .running(progress: 0.95))
    }

    @Test func theJourneyIsAtBuildingWithItsCount() {
        let journey = GoalJourney.of(wizard: nil, done: 5, total: 15, swarm: nil, goalDone: false)
        #expect(journey.steps.map(\.state) == [.done, .done, .done, .now, .next, .next, .next])
        #expect(journey.steps[3].title == "building · 5/15")
        let done = GoalJourney.of(wizard: nil, done: 15, total: 15, swarm: nil, goalDone: true)
        #expect(done.steps.allSatisfy { $0.state == .done })
    }

    @Test func theNextStepIsTheOldestQuestionOnYou() {
        let question = SwarmSteer(
            id: 7, swarm: "g/swarm-1", goal: "g", at: t0, actor: .lead, kind: .question,
            text: "Pick how editing works in the console", state: .pending, options: ["inline", "side panel"],
            from: "task:g/edit", to: "you"
        )
        let next = GoalNextStep.from([question], numbers: ["g/edit": 7])
        #expect(next?.title == "Your next step: pick how editing works in the console")
        #expect(next?.detail.hasPrefix("Part 7 asked the lead") == true)
        #expect(next?.options == ["inline", "side panel"])
        #expect(next?.question == 7)
        #expect(GoalNextStep.from([], numbers: [:]) == nil)
    }

    @Test func thePageFixtureIsBuildingWithANowLine() {
        let page = SplitFixtures.page(now: t0)
        #expect(page.now == 7.2)
        #expect(page.done > 0 && page.done < page.total)
        #expect(page.schedule.moves.contains { $0.kind == .ask } == false)
        #expect(page.states["schema-v2/edit-flows"] == .asking)
    }

    // MARK: Defining a part

    @Test func anAgentsReplyReadsAsTextOptionsAndADraft() {
        let reply = """
        anchors is too big for one transaction.

        ```json
        {"question": "Two ways to keep it online?", "options": ["batch", "dual-write"], "doneWhen": ["resumable backfill"], "estimate": "4h 30m", "context": ["anchors: 31 M rows"], "decision": "batch"}
        ```
        """
        let (text, options, draft) = PartDefinition.read(reply)
        #expect(text == "anchors is too big for one transaction.\n\nTwo ways to keep it online?")
        #expect(options == ["batch", "dual-write"])
        #expect(draft?.estimate == 270)
        #expect(draft?.context == ["anchors: 31 M rows", "decision: batch"])
        let plain = PartDefinition.read("just text")
        #expect(plain.text == "just text" && plain.options.isEmpty && plain.draft == nil)
    }

    @Test func pickingAnOptionAnswersWithIt() {
        var definition = PartDefinition(part: "g/a", agent: "codex", via: "codex via ACP", at: t0)
        definition.received("Which?\n{\"question\": null, \"options\": [\"one\", \"two\"]}")
        #expect(definition.openQuestion != nil)
        #expect(definition.pick(1) == "two")
        #expect(definition.turns.last?.text == "two")
        #expect(definition.openQuestion == nil)
        #expect(definition.pick(0) == nil)
    }

    @Test func aDefinitionAddsDoneWhenLinesEstimateAndContext() {
        let draft = SplitFixtures.complex()
        let migrate = draft.part("schema-v2/migrate")!
        let defined = SplitFixtures.definition(now: t0).draft!
        let diff = PartDefinition.diff(migrate, defined)
        #expect(diff.added.count == 2)
        #expect(diff.estimate?.old == 190 && diff.estimate?.new == 270)
        #expect(diff.size == nil)
        #expect(diff.addedContext == ["anchors: 31 M rows", "decision: batch, not dual-write"])
        let applied = PartDefinition.apply(defined, to: migrate)
        #expect(applied.task.doneWhen.count == 3)
        #expect(applied.minutes == 270)
    }

    @Test func theKnockOnSaysHowMuchLongerAndWhatMoves() {
        let draft = SplitFixtures.complex()
        let knock = PartDefinition.knockOn(
            SplitFixtures.definition(now: t0).draft!,
            part: "schema-v2/migrate",
            in: draft
        )!
        #expect(knock.delta > 1.2)
        #expect(knock.moved.contains(9))
        #expect(knock.text.hasPrefix("Longer by 1 h 20: parts"))
        #expect(knock.text.contains("move right; the goal ends at"))
        let none = PartDefinition.KnockOn(delta: 0, moved: [], makespan: 2)
        #expect(none.text == "Nothing else moves; the goal ends at 2 h.")
    }

    @Test func aDefiningAgentReadsAndIsRefusedAnythingElse() {
        let options = [
            ACPPermissionRequest.Option(id: "ok", name: "Allow", kind: .allowOnce),
            ACPPermissionRequest.Option(id: "no", name: "Reject", kind: .rejectOnce),
        ]
        func ask(_ kind: ACPToolKind) -> String? {
            DefinePolicy.answer(ACPPermissionRequest(toolCall: ACPToolCall(id: "1", kind: kind), options: options))
        }
        #expect(ask(.read) == "ok")
        #expect(ask(.search) == "ok")
        #expect(ask(.edit) == "no")
        #expect(ask(.execute) == "no")
        #expect(ask(.delete) == "no")
    }

    @Test func readsAreGroupedByFolder() {
        let reads = PartDefinition.reads(
            ["/r/store/a.go", "/r/store/b.go", "/r/README.md", "/r/store/a.go", "/r/migrations/1.sql"], root: "/r"
        )
        #expect(reads == ["store/ · 2 files", "README.md", "migrations/ · 1 file"])
    }

    @Test func thePromptCarriesThePartAndTheRules() {
        let draft = SplitFixtures.complex()
        let prompt = PartDefinition.prompt(
            part: draft.part("schema-v2/migrate")!, number: 4, goal: "Schema v2", plan: nil, criteria: ["c"],
            others: ["1 Schema"]
        )
        #expect(prompt.contains("# This part (4)"))
        #expect(prompt.contains("do not edit"))
        #expect(prompt.contains("context: decision: online, not downtime"))
    }
}

struct GoalSplitFixtureTests {
    @Test func theFakeWorldsSplitCallReadsBack() async throws {
        let calls = WizardCalls(run: WizardFixtures.calls)
        let (draft, _) = try await calls.split(
            plan: WizardFixtures.wizard(at: .split).plan.current!, criteria: ["c"], repos: [],
            goal: WizardFixtures.goalID, version: 1
        )
        #expect(draft.parts.count == 3)
        #expect(draft.parts[1].task.after == ["\(WizardFixtures.goalID)/wrap"])
        let assigned = SplitAssign.assign(draft, fleet: SplitFixtures.fleet(), records: SplitFixtures.records)
        #expect(assigned.parts.allSatisfy { $0.agent != nil })
    }
}

struct GoalSplitFitTests {
    @Test func mergedWorkInTheRepoBeatsABetterRecordElsewhere() {
        let docs = SplitFixtures.small().part("sequence-diagrams/docs")!
        let fleet = SplitFixtures.fleet()
        let gemini = SplitAssign.fit(docs, fleet.first { $0.id == "gemini" }!, records: SplitFixtures.records)
        let codex = SplitAssign.fit(docs, fleet.first { $0.id == "codex" }!, records: SplitFixtures.records)
        #expect(gemini > codex)
    }
}
