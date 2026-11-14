import Foundation
@testable import HeedCore
import Testing

/// Steps 5 and 6: How careful's levels on the quality machinery, Go's choices and what they come to, and Go starting
/// the goal's swarm on the split.
struct GoalGoTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: How careful

    @Test func eachLevelSetsTheMachineryItNamesAndNothingNew() {
        let profile = GoalProfile(stakes: .publicAPI, userFacing: true)
        let quick = CarePlan.of(.quick, profile: profile)
        #expect(quick.lenses.isEmpty)
        #expect(quick.pilotReviewers == ["copilot"])
        #expect(quick.trustedReviewers == ["copilot-pull-request-reviewer"])
        #expect(quick.you == .none)
        #expect(!quick.reviewParts)

        let standard = CarePlan.of(.standard, profile: profile)
        #expect(standard.lenses == [.code, .tests])
        #expect(standard.cheap == [.implementation, .testArchitect])
        #expect(standard.walks.isEmpty)
        #expect(standard.pilotReviewers.isEmpty)
        #expect(standard.you == .lastPart)
        // Every lens is pinned, the ones it does not keep at 0: nothing the table would add sneaks back.
        #expect(standard.pins.count == GoalLens.allCases.count)
        #expect(standard.pins[.docs] == 0)

        let thorough = CarePlan.of(.thorough, profile: profile)
        #expect(thorough.lenses == [.code, .tests, .docs, .ux, .dx])
        #expect(thorough.walks == [.docsWalk, .uxScreens, .dxFirstRun])
        #expect(thorough.you == .everyPart)
        #expect(thorough.reviewParts)
        // Bars come from the profile's table, at least 7.
        #expect((thorough.pins[.code] ?? 0) >= 7)
    }

    @Test func sensitiveGoalsKeepTheirSecurityAndPerformanceReviewersPastQuick() {
        let profile = GoalProfile(stakes: .internal, perfSensitive: true, securitySensitive: true)
        #expect(CarePlan.of(.standard, profile: profile).lenses == [.code, .tests, .perf, .security])
        #expect(CarePlan.of(.quick, profile: profile).lenses.isEmpty)
    }

    @Test func reviewsCostWhatTheCardsSay() {
        let profile = GoalProfile(stakes: .publicAPI, userFacing: true)
        #expect(abs(CarePlan.of(.quick, profile: profile).dollars(parts: 4) - 0.20) < 0.001)
        #expect(abs(CarePlan.of(.standard, profile: profile).dollars(parts: 4) - 1.40) < 0.001)
        #expect(CarePlan.dollarsText(CarePlan.of(.thorough, profile: profile).dollars(parts: 4)) == "$6")
        #expect(CarePlan.dollarsText(0.2) == "$0.20")
    }

    @Test func standardWaitsForYouOnTheLastPartAndThoroughOnEvery() {
        let draft = SplitFixtures.complex()
        let last = CarePlan.lastPart(draft)
        #expect(last == "\(SplitFixtures.complexID)/drill")
        let standard = CarePlan.of(.standard, profile: nil)
        #expect(draft.active.count { standard.waitsForYou($0.id, in: draft) } == 1)
        #expect(standard.waitsForYou(last ?? "", in: draft))
        let thorough = CarePlan.of(.thorough, profile: nil)
        #expect(draft.active.allSatisfy { thorough.waitsForYou($0.id, in: draft) })
        #expect(!draft.active.contains { CarePlan.of(.quick, profile: nil).waitsForYou($0.id, in: draft) })
    }

    @Test func theSuggestionFollowsTheProfileWithItsReason() {
        let api = CareSuggestion.of(profile: GoalProfile(stakes: .publicAPI), parts: 4, repos: ["docs-toolkit"])
        #expect(api.level == .thorough)
        #expect(api.reason.contains("docs-toolkit"))
        #expect(CareSuggestion.of(profile: GoalProfile(stakes: .spike), parts: 9).level == .quick)
        #expect(CareSuggestion.of(profile: GoalProfile(stakes: .internal), parts: 2).level == .quick)
        #expect(CareSuggestion.of(profile: GoalProfile(stakes: .internal), parts: 6).level == .standard)
        #expect(CareSuggestion.of(profile: GoalProfile(stakes: .product, userFacing: true), parts: 3)
            .level == .standard)
        #expect(CareSuggestion.of(profile: GoalProfile(stakes: .product, userFacing: true), parts: 8)
            .level == .thorough)
        let unknown = CareSuggestion.of(profile: nil, parts: 3)
        #expect(unknown.level == .standard)
        #expect(unknown.reason.contains("not worked out"))
    }

    @Test func levelsReadFromNumbersAndNames() {
        #expect(CareLevel(word: "1") == .quick)
        #expect(CareLevel(word: "Thorough") == .thorough)
        #expect(CareLevel(word: "4") == nil)
        #expect(CareLevel.allCases.map(\.number) == [1, 2, 3])
    }

    @Test func aThoroughGoalsOpenPullsShowAsUnderReview() {
        #expect(PartState.running(progress: 0.5).reviewing(prOpen: true, care: .thorough) == .review)
        #expect(PartState.running(progress: 0.5).reviewing(prOpen: true, care: .standard) == .running(progress: 0.5))
        #expect(PartState.done.reviewing(prOpen: true, care: .thorough) == .done)
        #expect(PartState.asking.reviewing(prOpen: true, care: .thorough) == .asking)
        #expect(PartState.planned.reviewing(prOpen: false, care: .thorough) == .planned)
        #expect(PartState.planned.reviewing(prOpen: true, care: nil) == .planned)
    }

    // MARK: Go

    @Test func choicesStepWithinTheirOptionsAndKeepTheirDefaults() {
        var choices = GoChoices()
        #expect(choices.who == .helpers && choices.atOnce == 5 && choices.ask == .planChanges)
        #expect(choices.budget == 25 && choices.merge == .heed)
        choices.step(.atOnce, by: 1)
        #expect(choices.atOnce == 5)
        choices.step(.atOnce, by: -1)
        #expect(choices.atOnce == 3)
        choices.pick(.who, 2)
        #expect(choices.who == .mix)
        choices.pick(.who, 7)
        #expect(choices.who == .mix)
        choices.pick(.merge, 0)
        #expect(choices.merge.swarm == .off)
        #expect(choices.options(.budget) == ["$10", "$25", "$50"])
        #expect(choices.picked(.budget) == 1)
    }

    @Test func theDefaultsFitThePlanAndItsCost() {
        let small = SplitFixtures.small()
        #expect(GoChoices.defaults(for: small, extra: 0).atOnce == 2)
        #expect(GoChoices.defaults(for: SplitFixtures.complex(), extra: 3).atOnce == 5)
        #expect(GoChoices.defaults(for: small, extra: 3).budget == 25)
        #expect(GoChoices.defaults(for: small, extra: 20).budget == 50)
    }

    @Test func mixRunsTheLongestChainInSessionsAndTheRestAsHelpers() {
        let chain = ["a", "b"]
        let mix = GoChoices(who: .mix)
        #expect(!mix.runsAsHelper("a", chain: chain))
        #expect(mix.runsAsHelper("c", chain: chain))
        #expect(GoChoices(who: .helpers).runsAsHelper("a", chain: chain))
        #expect(!GoChoices(who: .sessions).runsAsHelper("c", chain: chain))
    }

    @Test func theForecastCountsPartsStartingNowTimeCostPullsAndRealRingsOnly() {
        let draft = SplitFixtures.complex()
        let fleet = SplitFixtures.fleet(now: t0)
        let care = CarePlan.of(.standard, profile: nil)
        let forecast = GoForecast.of(draft: draft, choices: GoChoices(), care: care, fleet: fleet, now: t0)
        // Schema and the load-test harness wait for nothing.
        #expect(forecast.startNow == 2)
        #expect(forecast.agentsNow == 2)
        #expect(forecast.pulls == 15)
        #expect(forecast.repos == 4)
        #expect(forecast.extra >= care.dollars(parts: 15))
        #expect(forecast.endsAt == t0.addingTimeInterval(forecast.hours * 3600))
        #expect(forecast.agents.map(\.id) == ["claude", "codex", AgentFleet.copilot, "gemini", "cursor"])
        #expect(forecast.agents.count { $0.quota != nil } == 1)
        // One at a time is slower than the plan's own pace.
        let narrow = GoForecast.of(draft: draft, choices: GoChoices(atOnce: 1), care: care, fleet: fleet, now: t0)
        #expect(narrow.hours > forecast.hours)
        #expect(GoForecast.endText(t0, timeZone: TimeZone(identifier: "UTC")!) == "Fri 08:00")
    }

    @Test func goMapsOntoTheSwarmsFormFields() {
        let draft = SplitFixtures.complex()
        let care = CarePlan.of(.standard, profile: nil)
        let choices = GoChoices(who: .mix, atOnce: 3, ask: .everyQuestion, budget: 50, merge: .askMe)
        let launch = GoLaunch.of(
            draft: draft, choices: choices, care: care, repos: ["acme/engine", "acme/console"], defaultAgent: "claude"
        )
        let settings = launch.settings
        #expect(settings.repos.prefix(2) == ["acme/engine", "acme/console"])
        #expect(settings.repos.contains("docs"))
        #expect(settings.lead == GoalItem.Owner(agent: "claude", model: "opus"))
        #expect(settings.workers.map(\.agent) == ["claude", "codex", "gemini", AgentFleet.copilot, "cursor"])
        #expect(settings.workers.allSatisfy { $0.count <= 3 })
        #expect(settings.limits.agents == 3)
        #expect(settings.limits.dollars == 50)
        #expect(settings.limits.hours >= 1)
        #expect(settings.askEverything)
        #expect(settings.merge == .off)
        #expect(settings.care == .standard)
        let chain = SplitSchedule.make(draft.parts).chain
        // Mix: the chain in sessions; Copilot's parts work on GitHub, never as helpers.
        #expect(!chain.contains { settings.runsAsHelper($0) })
        #expect(!draft.active.contains { $0.agent == AgentFleet.copilot && settings.runsAsHelper($0.id) })
        #expect(draft.active.contains { settings.runsAsHelper($0.id) })
        #expect(settings.waitForYou == ["\(SplitFixtures.complexID)/drill"])
        #expect(launch.tasks == draft.swarmTasks)
    }

    @Test func settingsFromBeforeGoDecodeWithItsFieldsOff() throws {
        let old = #"{"repos":["a/b"],"lead":{"agent":"claude"},"workers":[],"limits":{"agents":4,"hours":4,"dollars":40},"autonomy":"planChanges"}"#
        let settings = try JSONDecoder().decode(SwarmSettings.self, from: Data(old.utf8))
        #expect(!settings.askEverything)
        #expect(settings.care == nil)
        #expect(!settings.runsAsHelper("x"))
        #expect(!settings.waitsForYou("x"))
        var go = settings
        go.helpers = ["x"]
        go.care = .thorough
        let again = try JSONDecoder().decode(SwarmSettings.self, from: JSONEncoder().encode(go))
        #expect(again == go)
    }

    @Test func goStartsTheSwarmOnTheSplitApprovedAndRunningAndAppliesTheLevel() async throws {
        let ops = try GoalOps.inMemory()
        let id = SplitFixtures.complexID
        try await ops.adopt([SplitFixtures.goal(id, now: t0)])
        var wizard = SplitFixtures.wizard(id, now: t0)
        wizard.advance(at: t0)
        try await ops.adopt(wizards: [wizard])
        let draft = try #require(wizard.split)
        let care = CarePlan.of(.standard, profile: nil)
        let launch = GoLaunch.of(draft: draft, choices: GoChoices(), care: care, repos: [], defaultAgent: "claude")
        let swarm = try await ops.go(goal: id, launch: launch, care: care, now: t0)
        #expect(swarm.status == .running)
        #expect(swarm.runningAt == t0)
        #expect(swarm.isApproved)
        let board = try await ops.board(of: swarm.id)
        #expect(board.versions.count == 1)
        #expect(board.versions.first?.tasks.map(\.id) == draft.swarmTasks.map(\.id))
        // The approved plan's tasks are the goal's items.
        let items = try await ops.snapshot().items(of: id)
        #expect(items.count == draft.active.count)
        // The wizard is finished, with the swarm it started.
        let saved = try #require(try await ops.wizard(of: id))
        #expect(saved.finished)
        #expect(saved.swarm == swarm.id)
        // The level is on the goal's quality record: code and test reviewers, cheap; nothing else.
        let quality = try await ops.quality(of: id)
        let live = quality.reviewers.filter { !$0.config.removed }
        #expect(Set(live.map(\.config.kind)) == [.implementation, .testArchitect])
        #expect(live.allSatisfy { $0.config.tier == .cheap })
        // One swarm at a time.
        await #expect(throws: GoalOpError.swarmActive(id)) {
            try await ops.go(goal: id, launch: launch, care: care, now: t0)
        }
    }

    @Test func goTakesOverASwarmStillPlanningWithNothingApproved() async throws {
        let ops = try GoalOps.inMemory()
        let id = SplitFixtures.complexID
        try await ops.adopt([SplitFixtures.goal(id, now: t0)])
        var wizard = SplitFixtures.wizard(id, now: t0)
        wizard.advance(at: t0)
        try await ops.adopt(wizards: [wizard])
        let old = try await ops.startSwarm(goal: id, settings: SwarmSettings(repos: ["acme/engine"]), now: t0)
        let draft = try #require(wizard.split)
        let care = CarePlan.of(.quick, profile: nil)
        let launch = GoLaunch.of(draft: draft, choices: GoChoices(), care: care, repos: [], defaultAgent: "claude")
        let swarm = try await ops.go(goal: id, launch: launch, care: care, now: t0 + 60)
        #expect(swarm.id == old.id)
        #expect(swarm.settings.care == .quick)
        #expect(swarm.status == .running)
    }

    @Test func aLaterLevelTakesOffTheReviewersItDoesNotNeed() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Faster search", statement: "", now: t0)
        try await ops.applyCare(goal: goal.id, CarePlan.of(.standard, profile: nil), now: t0)
        let quality = try await ops.applyCare(goal: goal.id, CarePlan.of(.quick, profile: nil), now: t0 + 5)
        let live = quality.reviewers.filter { !$0.config.removed }
        #expect(live.isEmpty)
    }

    // MARK: The TL;DR

    @Test func theTLDRSaysWhereItIsGoingAndWhatStepsFiveAndSixSettled() {
        var wizard = SplitFixtures.wizard(SplitFixtures.complexID, now: t0)
        wizard.advance(at: t0)
        wizard.advance(at: t0)
        wizard.careful = .thorough
        let inputs = TLDRInputs.build(
            wizard, doc: nil, goalVersion: 1, care: CarePlan.of(.thorough, profile: nil),
            fleet: SplitFixtures.fleet(now: t0), now: t0
        )
        let careful = inputs.steps.first { $0.step == .careful }
        #expect(careful?.headline == "Thorough")
        #expect(careful?.detail.contains("stranger walk") == true)
        let go = inputs.steps.first { $0.step == .go }
        #expect(go?.headline == "ready")
        #expect(go?.detail == "helpers · 5 at once · $25 · heed merges")
        let going = inputs.going
        #expect(going?.hours ?? 0 > 10)
        #expect(going?.agents == 5)
        #expect(going?.endsAt != nil)
        #expect(going?.dollars ?? 0 > 0)
        #expect(going?.chain.isEmpty == false)

        var unpicked = wizard
        unpicked.careful = nil
        let suggested = TLDRInputs.build(unpicked, doc: nil, goalVersion: 1, care: CarePlan.of(.standard, profile: nil))
        #expect(suggested.steps.first { $0.step == .careful }?.headline == "Standard, suggested")
    }
}
