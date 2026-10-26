import Foundation
@testable import HeedCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func friction(_ text: String, _ severity: Severity, _ state: Objection.State = .open) -> Objection {
    Objection(id: ObjectionMatch.id(text), severity: severity, text: text, state: state, firstSeen: t0)
}

private func walk(
    _ lens: EvaluationLens = .dxFirstRun, version: Int = 2, seconds: [Double] = [60, 120],
    friction: [Friction] = [], source: String = "acme/search#3"
) -> EvaluationWalk {
    EvaluationWalk(
        lens: lens, draftVersion: version,
        steps: seconds.enumerated().map { WalkStep(title: "Step \($0.offset + 1)", outcome: .ok, seconds: $0.element) },
        friction: friction, summary: "", source: source
    )
}

struct EvaluationScoreTests {
    @Test func tenMinusOpenFrictionBySeverityAndAQuarterForAccepted() {
        let score = GoalScore.walk(
            [
                friction("Build says nothing for 40 s", .high),
                friction("Flags overlap", .med),
                friction("Times in ms and s", .low, .acceptedRisk),
                friction("Old fixed one", .high, .fixed),
            ],
            seconds: 551, previous: nil, steps: 6
        )
        // 10 − 3 − 1.5 − 0.5 × 0.25 = 5.375 → 5.4; fixed friction gives nothing back (a faster re-walk does).
        #expect(score.value == 5.4)
        #expect(score.basis.contains("minus 4.5 for 2 open friction entries"))
        #expect(score.basis.contains("minus 0.1 for 1 accepted"))
        #expect(score.basis.contains("6 steps in 9 min 11 s"))
        #expect(GoalScore.walk([], seconds: 30, previous: nil, steps: 1).basis.hasPrefix("10: no friction"))
        #expect(GoalScore.walk((0 ..< 5).map { friction("f\($0)", .high) }, seconds: nil, previous: nil, steps: 5)
            .value == 0)
    }

    @Test func aFasterReWalkEarnsCreditUpToItsCap() {
        let open = [friction("Flags overlap", .med)]
        // 20% faster: 0.6 back.
        let faster = GoalScore.walk(open, seconds: 480, previous: 600, steps: 4)
        #expect(faster.value == 9.1)
        #expect(faster.basis.contains("plus 0.6 for a re-walk 20% faster"))
        // Twice as fast: capped at 1.5, and never over 10.
        #expect(GoalScore.walk(open, seconds: 100, previous: 600, steps: 4).value == 10)
        #expect(GoalScore.walk([friction("a", .high), friction("b", .high)], seconds: 100, previous: 600, steps: 4)
            .value == 5.5)
        // Slower, or no time to compare: nothing.
        #expect(GoalScore.walk(open, seconds: 700, previous: 600, steps: 4).value == 8.5)
        #expect(GoalScore.walk(open, seconds: nil, previous: 600, steps: 4).value == 8.5)
        #expect(GoalScore.walk(open, seconds: 300, previous: 0, steps: 4).value == 8.5)
    }

    @Test func theFoldScoresAnEvaluatorByItsWalksAndOnlyComparesTheSameDraft() {
        let config = ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator)
        func review(_ run: String, _ walk: EvaluationWalk, at: Double) -> QualityRecord {
            QualityRecord(goal: "g", at: t0.addingTimeInterval(at), entry: .review(ReviewResult(
                run: run, reviewer: "dx-evaluator", basis: ReviewBasis(goalVersion: walk.draftVersion, heads: []),
                report: ReviewReport(walk: walk)
            )))
        }
        let slow = walk(seconds: [300, 300], friction: [Friction(severity: .med, step: 1, finding: "Flags overlap")])
        let fast = walk(seconds: [200, 200], friction: [Friction(severity: .med, step: 1, finding: "Flags overlap")])
        let records = [
            QualityRecord(goal: "g", at: t0, entry: .profile(ProfileDecision(
                profile: GoalProfile(stakes: .publicAPI), bars: [:], changes: [], note: "", goalVersion: 2
            ))),
            QualityRecord(goal: "g", at: t0, entry: .reviewer(config)),
            review("w1", slow, at: 10),
            review("w2", fast, at: 20),
        ]
        let quality = GoalQuality.fold(records, doc: nil)
        let evaluator = quality.reviewer("dx-evaluator")
        #expect(evaluator?.walks.count == 2)
        // 10 − 1.5 + (1 − 400/600) × 3 = 9.5.
        #expect(evaluator?.score?.value == 9.5)
        #expect(evaluator?.history == [8.5, 9.5])
        // A new draft (a new GOAL.md version) is not compared with the old one.
        let redrafted = GoalQuality.fold(records + [review("w3", walk(version: 3, seconds: [100, 100], friction: [
            Friction(severity: .med, step: 1, finding: "Flags overlap"),
        ]), at: 30)], doc: nil)
        #expect(redrafted.reviewer("dx-evaluator")?.score?.value == 8.5)
        // Accepting a friction entry rescores it as a walk.
        let accepted = GoalQuality.fold(records + [QualityRecord(
            goal: "g", at: t0.addingTimeInterval(40),
            entry: .action(ObjectionAction(
                reviewer: "dx-evaluator", objection: ObjectionMatch.id("Flags overlap"), state: .acceptedRisk
            ))
        )], doc: nil)
        // 10 − 0.375 + 1 = 10.6 → 10.
        #expect(accepted.reviewer("dx-evaluator")?.score?.value == 10)
        #expect(accepted.reviewer("dx-evaluator")?.score?.basis.contains("re-walk") == true)
    }

    @Test func aLensIsAsGoodAsItsWorstRequiredWalk() {
        func state(_ id: String, _ kind: ReviewerKind, walk lens: EvaluationLens?, score: Double) -> ReviewerState {
            var state = ReviewerState(
                config: ReviewerConfig(id: id, kind: kind, evaluation: lens), objections: [],
                score: GoalScore(value: score, basis: ""), history: [score], summary: ""
            )
            if let lens = lens ?? EvaluationLens.defaultWalk(of: kind) { state.walks = [walk(lens)] }
            return state
        }
        let firstRun = state("dx-evaluator", .dxEvaluator, walk: nil, score: 9)
        let api = state("dx-evaluator-api", .dxEvaluator, walk: .dxApiConfig, score: 4)
        #expect(GoalQuality.lensScore(.dx, reviewers: [firstRun, api], walks: [.dxFirstRun, .dxApiConfig]) == 4)
        // A walk the goal does not require does not count.
        #expect(GoalQuality.lensScore(.dx, reviewers: [firstRun, api], walks: [.dxFirstRun]) == 9)
        // Reviewers count as their best, against the walks.
        let reader = state("docs-reader", .docsReader, walk: nil, score: 9)
        let reader2 = state("docs-reader-2", .docsReader, walk: nil, score: 7)
        let docsWalk = state("docs-walk", .docsReader, walk: .docsWalk, score: 8)
        #expect(GoalQuality.lensScore(.docs, reviewers: [reader, reader2], walks: [.docsWalk]) == 9)
        #expect(GoalQuality.lensScore(.docs, reviewers: [reader, reader2, docsWalk], walks: [.docsWalk]) == 8)
        // An evaluator that has not walked (an old stub's review) does not count.
        var stub = state("ux-evaluator", .uxEvaluator, walk: nil, score: 3)
        stub.walks = []
        #expect(GoalQuality.lensScore(.ux, reviewers: [stub], walks: [.uxScreens]) == nil)
    }
}

struct WalkParsingTests {
    @Test func readsAWalkLeniently() throws {
        let json = """
        {"summary": "Got there, slowly.",
         "walk": [
           {"step": "Read the quick start", "result": "passed", "duration": "1m10"},
           {"name": "Pick flags", "status": "unclear", "time": "2:40"},
           {"title": "Run the first build", "outcome": "stuck", "seconds": 40},
           {"title": "Rebuild", "outcome": "ok", "seconds": "6s"},
           {"title": "Recover", "outcome": "error", "seconds": "1 min 30 s", "note": "stack trace"}
         ],
         "findings": [
           {"severity": "critical", "step": "step 3", "tag": "first build", "text": "Says hashing for 40 s.",
            "fix": "add progress"},
           {"severity": "medium", "step": 2, "problem": "Two flags overlap."},
           {"severity": "low", "step": 99, "finding": "Times in ms and s."},
           {"severity": "high", "finding": "  "}
         ]}
        """
        let walk = try #require(EvaluationWalk.parse(
            Data(json.utf8), lens: .dxFirstRun, draftVersion: 3, source: "acme/search#3"
        ))
        #expect(walk.steps.map(\.outcome) == [.ok, .confusing, .stalled, .ok, .failed])
        #expect(walk.steps.map(\.seconds) == [70, 160, 40, 6, 90])
        #expect(walk.seconds == 366)
        #expect(walk.summary == "Got there, slowly.")
        #expect(walk.friction[0] == Friction(
            severity: .high, step: 3, area: "first build", finding: "Says hashing for 40 s.", suggestion: "add progress"
        ))
        #expect(walk.friction[1].severity == .med)
        #expect(walk.friction[1].step == 2)
        // A step out of range is dropped from the entry, not the entry; one without text is dropped.
        #expect(walk.friction[2].step == nil)
        // The failed step 5 had no entry: it gets a high one, with its note.
        #expect(walk.friction.count == 4)
        #expect(walk.friction[3] == Friction(severity: .high, step: 5, finding: "Recover: failed. stack trace"))
        #expect(walk.raised.map(\.text) == walk.friction.map(\.finding))
        #expect(walk.raised.first?.evidence == "add progress")
        #expect(walk.friction[0].place == "step 3 · first build")
    }

    @Test func stepsThatDidNotGoWellAndHaveNoEntryGetOneAsBadAsTheyWent() throws {
        let json = """
        {"steps": [{"title": "A", "outcome": "confusing"}, {"title": "B", "outcome": "stalled"},
                   {"title": "C", "outcome": "fine"}]}
        """
        let walk = try #require(EvaluationWalk.parse(Data(json.utf8), lens: .docsWalk, draftVersion: 1, measured: 75))
        #expect(walk.friction.map(\.severity) == [.low, .med])
        #expect(walk.friction.map(\.step) == [1, 2])
        // Steps without times: what heed measured.
        #expect(walk.seconds == 75)
    }

    @Test func noStepsIsNoWalk() {
        #expect(EvaluationWalk.parse(Data("[]".utf8), lens: .dxFirstRun, draftVersion: 1) == nil)
        #expect(EvaluationWalk.parse(Data("{\"steps\": []}".utf8), lens: .dxFirstRun, draftVersion: 1) == nil)
        #expect(EvaluationWalk.parse(Data("not json".utf8), lens: .dxFirstRun, draftVersion: 1) == nil)
    }

    @Test func timesInTheShapesAgentsWriteThem() {
        #expect(EvaluationWalk.seconds(70) == 70)
        #expect(EvaluationWalk.seconds(1.5) == 1.5)
        #expect(EvaluationWalk.seconds("70") == 70)
        #expect(EvaluationWalk.seconds("70s") == 70)
        #expect(EvaluationWalk.seconds("1m10") == 70)
        #expect(EvaluationWalk.seconds("1m 10s") == 70)
        #expect(EvaluationWalk.seconds("2 min") == 120)
        #expect(EvaluationWalk.seconds("1:05") == 65)
        #expect(EvaluationWalk.seconds("1h") == 3600)
        #expect(EvaluationWalk.seconds("soon") == nil)
        #expect(EvaluationWalk.seconds(-3) == nil)
        #expect(EvaluationWalk.seconds(nil) == nil)
        #expect(EvaluationWalk.clock(70) == "1m10")
        #expect(EvaluationWalk.clock(6) == "0m06")
        #expect(EvaluationWalk.span(551) == "9 min 11 s")
        #expect(EvaluationWalk.span(120) == "2 min")
        #expect(EvaluationWalk.span(40) == "40 s")
    }

    @Test func theRunReadsItsFileElseItsLastMessage() {
        let json = "{\"steps\": [{\"title\": \"A\", \"outcome\": \"ok\", \"seconds\": 5}]}"
        let fromFile = EvaluationRun.read(
            file: Data(json.utf8), lastMessage: nil, lens: .dxFirstRun, draftVersion: 2, measured: 9, source: "s"
        )
        #expect(fromFile.walk?.seconds == 5)
        #expect(fromFile.walk?.source == "s")
        let fromMessage = EvaluationRun.read(
            file: Data("oops".utf8), lastMessage: "Done.\n```json\n\(json)\n```", lens: .dxFirstRun, draftVersion: 2,
            measured: nil, source: "s"
        )
        #expect(fromMessage.walk?.steps.count == 1)
        #expect(EvaluationRun.read(
            file: nil, lastMessage: nil, lens: .dxFirstRun, draftVersion: 2, measured: nil, source: ""
        ).failure == "it wrote no walk")
        #expect(EvaluationRun.read(
            file: Data("{}".utf8), lastMessage: "no json", lens: .dxFirstRun, draftVersion: 2, measured: nil,
            source: ""
        ).failure == "its evaluation.json is not a walk")
    }

    @Test func draftsAreTheAnswersLinesThreeToEight() {
        #expect(WalkDrafter.steps("- Read the README\n- Install it\n1. Run it\n* Break it\n- Recover:") == [
            "Read the README", "Install it", "Run it", "Break it",
        ])
        #expect(WalkDrafter.steps("- Only one\n- Two") == nil)
        #expect(WalkDrafter.steps((1 ... 12).map { "- Step \($0)" }.joined(separator: "\n"))?.count == 8)
        let draft = WalkDraft(reviewer: "dx-evaluator", lens: .dxFirstRun, goalVersion: 3, steps: ["a"])
        #expect(WalkDrafter.current(draft, version: 3) == draft)
        #expect(WalkDrafter.current(draft, version: 4) == nil)
        #expect(WalkDrafter.current(nil, version: 4) == nil)
    }
}

struct EvaluationLensTests {
    @Test func theProfileDecidesWhichWalksAGoalNeeds() {
        func lenses(_ profile: GoalProfile, pins: [GoalLens: Double] = [:]) -> [EvaluationLens] {
            EvaluationLens.required(profile: profile, bars: profile.bars(pins: pins))
        }
        #expect(lenses(GoalProfile(stakes: .spike)).isEmpty)
        #expect(lenses(GoalProfile(stakes: .internal)).isEmpty)
        #expect(lenses(GoalProfile(stakes: .product)) == [.docsWalk])
        #expect(lenses(GoalProfile(stakes: .product, userFacing: true)) == [.uxScreens, .accessibility, .docsWalk])
        #expect(lenses(GoalProfile(stakes: .publicAPI)) == [.dxFirstRun, .dxApiConfig, .docsWalk])
        // Accessibility needs a user-facing product: an internal one with UX pinned walks its screens only.
        #expect(lenses(GoalProfile(stakes: .internal, userFacing: true)) == [.uxScreens])
        #expect(lenses(GoalProfile(stakes: .internal), pins: [.ux: 6, .dx: 7]) == [.dxFirstRun, .uxScreens])
        // Docs required of an internal goal (a pin) are read, not walked.
        #expect(lenses(GoalProfile(stakes: .internal), pins: [.docs: 6]).isEmpty)
        // No profile yet: internal, nothing to walk.
        #expect(EvaluationLens.required(profile: nil, bars: GoalProfile.unknown.bars()).isEmpty)
    }

    @Test func eachWalkScoresItsLensAsAKindWithAnId() {
        #expect(EvaluationLens.allCases.map(\.lens) == [.dx, .dx, .ux, .ux, .docs])
        #expect(Set(EvaluationLens.allCases.map(\.reviewerID)).count == EvaluationLens.allCases.count)
        #expect(ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator).walk == .dxFirstRun)
        #expect(ReviewerConfig(id: "ux-evaluator", kind: .uxEvaluator).walk == .uxScreens)
        #expect(ReviewerConfig(id: "docs-reader", kind: .docsReader).walk == nil)
        #expect(ReviewerConfig(id: "docs-walk", kind: .docsReader, evaluation: .docsWalk).walk == .docsWalk)
        #expect(ReviewerConfig(id: "docs-walk", kind: .docsReader, evaluation: .docsWalk).title == "Docs walker")
        #expect(ReviewerConfig(id: "implementation", kind: .implementation).title == "Implementation reviewer")
    }

    @Test func missingEvaluatorsAreSpawnedOncePerRequiredWalk() {
        let profile = GoalProfile(stakes: .publicAPI)
        let bars = profile.bars()
        let first = EvaluationPlanner.missing(profile: profile, bars: bars, configs: [
            ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator),
        ])
        #expect(first.map(\.id) == ["dx-evaluator-api", "docs-walk"])
        #expect(first.map(\.walk) == [.dxApiConfig, .docsWalk])
        #expect(first.map(\.kind) == [.dxEvaluator, .docsReader])
        // The default walk's evaluator is its kind's, with no lens of its own.
        let fresh = EvaluationPlanner.missing(profile: profile, bars: bars, configs: [])
        #expect(fresh.first == ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator))
        // A removed one keeps its id taken: the new one gets a number.
        let removed = EvaluationPlanner.missing(profile: profile, bars: bars, configs: [
            ReviewerConfig(id: "dx-evaluator", kind: .dxEvaluator, removed: true),
        ])
        #expect(removed.first?.id == "dx-evaluator-2")
        #expect(removed.first?.walk == .dxFirstRun)
    }

    @Test func eachLensHasItsArea() {
        #expect(EvaluationLens.dxFirstRun.touches("README.md"))
        #expect(EvaluationLens.dxFirstRun.touches("docs/getting-started.md"))
        #expect(EvaluationLens.dxFirstRun.touches("src/cli/build.ts"))
        #expect(EvaluationLens.dxFirstRun.touches("Sources/tool/main.swift"))
        #expect(EvaluationLens.dxFirstRun.touches("install.sh"))
        #expect(!EvaluationLens.dxFirstRun.touches("src/core/AnchorIndex.cs"))
        #expect(!EvaluationLens.dxFirstRun.touches("config/defaults.toml"))
        #expect(EvaluationLens.dxApiConfig.touches("config/defaults.toml"))
        #expect(EvaluationLens.dxApiConfig.touches("src/BuildConfiguration.cs"))
        #expect(EvaluationLens.uxScreens.touches("src/components/Nav.tsx"))
        #expect(EvaluationLens.uxScreens.touches("Sources/App/Views/SettingsView.swift"))
        #expect(EvaluationLens.accessibility.touches("styles/site.css"))
        #expect(!EvaluationLens.uxScreens.touches("src/core/Resolver.cs"))
        #expect(EvaluationLens.docsWalk.touches("docs/redirects.md"))
        #expect(EvaluationLens.docsWalk.touches("guide.mdx"))
        #expect(EvaluationLens.docsWalk.touches("examples/site/toc.yml"))
        #expect(!EvaluationLens.docsWalk.touches("src/cli/build.ts"))
    }
}

struct EvaluationTriggerTests {
    private func state(
        _ id: String, _ kind: ReviewerKind, walk lens: EvaluationLens? = nil, score: Double? = nil,
        walked: Bool = true, running: Bool = false, policy: ReviewPolicy = .onChange
    ) -> ReviewerState {
        var state = ReviewerState(
            config: ReviewerConfig(id: id, kind: kind, policy: policy, evaluation: lens), objections: [],
            score: score.map { GoalScore(value: $0, basis: "") }, history: [], summary: ""
        )
        if walked, let walk = state.config.walk { state.walks = [EvaluationWalk(
            lens: walk, draftVersion: 1, steps: [WalkStep(title: "a", outcome: .ok)], friction: []
        )] }
        if running {
            state.lastRun = ReviewRunStart(
                id: "r", reviewer: id, trigger: .manual, basis: ReviewBasis(goalVersion: 1, heads: []), agent: "claude"
            )
        }
        return state
    }

    @Test func walksAreQuietAtTheirBarAndOnPROpenedOrNightly() {
        let low = state("dx-evaluator", .dxEvaluator, score: 5)
        let high = state("ux-evaluator", .uxEvaluator, score: 8)
        let never = state("docs-walk", .docsReader, walk: .docsWalk, walked: false)
        let bars: [GoalLens: Double] = [.dx: 7, .ux: 7, .docs: 6]
        let required: Set<EvaluationLens> = [.dxFirstRun, .uxScreens, .docsWalk]
        func plan(_ trigger: ReviewTrigger, used: Int = 0, limit: Int = 6) -> ReviewPlan {
            EvaluationPlanner.plan(
                trigger: trigger, evaluators: [low, high, never], bars: bars, required: required, used: used,
                limit: limit
            )
        }
        let version = plan(.goalVersion(3))
        #expect(version.run == ["dx-evaluator", "docs-walk"])
        #expect(version.quiet["ux-evaluator"] == "at its bar")
        #expect(plan(.prMerged("acme/search#3")).run == ["dx-evaluator", "docs-walk"])
        #expect(plan(.areaChanged("README.md")).run == ["dx-evaluator", "docs-walk"])
        for trigger in [ReviewTrigger.prOpened("acme/search#3"), .prUpdated("acme/search#3"), .nightly] {
            #expect(plan(trigger).run.isEmpty)
            #expect(plan(trigger).quiet.count == 3)
        }
        // You asking walks even one at its bar, and the budget never holds it back.
        #expect(plan(.manual, used: 6).run == ["dx-evaluator", "ux-evaluator", "docs-walk"])
        // Over budget: waiting.
        let tight = plan(.goalVersion(3), used: 5)
        #expect(tight.run == ["dx-evaluator"])
        #expect(tight.overBudget == ["docs-walk"])
    }

    @Test func walksNotRequiredRunningOrManualOnlyStayQuiet() {
        let accessibility = state("ux-evaluator-a11y", .uxEvaluator, walk: .accessibility, score: 2)
        let running = state("dx-evaluator", .dxEvaluator, score: 2, running: true)
        let mine = state("docs-walk", .docsReader, walk: .docsWalk, score: 2, policy: .manual)
        let reviewer = state("implementation", .implementation, score: 2)
        let plan = EvaluationPlanner.plan(
            trigger: .goalVersion(2), evaluators: [accessibility, running, mine, reviewer],
            bars: [.dx: 7, .ux: 7, .docs: 6], required: [.dxFirstRun, .docsWalk, .uxScreens], used: 0, limit: 6
        )
        #expect(plan.run.isEmpty)
        #expect(plan.quiet["ux-evaluator-a11y"] == "the goal's profile does not need Accessibility")
        #expect(plan.quiet["dx-evaluator"] == "walking now")
        #expect(plan.quiet["docs-walk"] == "walks only when you ask")
        // Reviewers are not the evaluation planner's.
        #expect(plan.quiet["implementation"] == nil)
        // `only` narrows it.
        let only = EvaluationPlanner.plan(
            trigger: .manual, only: ["docs-walk"], evaluators: [accessibility, running, mine],
            bars: [.docs: 6], required: [.docsWalk], used: 0, limit: 6
        )
        #expect(only.run == ["docs-walk"])
    }

    @Test func areaChangesPickTheEvaluatorsWhoseAreaATouchedPathIsIn() {
        let evaluators = [
            state("dx-evaluator", .dxEvaluator),
            state("ux-evaluator", .uxEvaluator),
            state("docs-walk", .docsReader, walk: .docsWalk),
            state("implementation", .implementation),
        ]
        let hits = EvaluationTriggers.areaChanged(
            evaluators: evaluators, paths: ["src/core/Resolver.cs", "docs/redirects.md", "src/cli/build.ts"]
        )
        #expect(hits.map(\.id) == ["dx-evaluator", "docs-walk"])
        #expect(hits.map(\.path) == ["docs/redirects.md", "docs/redirects.md"])
        #expect(EvaluationTriggers.areaChanged(evaluators: evaluators, paths: ["src/core/Resolver.cs"]).isEmpty)
        #expect(EvaluationTriggers.newPaths(before: ["a", "b"], after: ["b", "c", "a"]) == ["c"])
        // The first look only remembers.
        #expect(EvaluationTriggers.newPaths(before: nil, after: ["a"]).isEmpty)
    }

    @Test func aMergedFixForAFindingReWalksItsEvaluator() {
        let finding = "Build says nothing for 40 s"
        var dx = state("dx-evaluator", .dxEvaluator, score: 5)
        dx.objections = [friction(finding, .high)]
        var reviewer = state("implementation", .implementation, score: 5)
        reviewer.objections = [friction("Matched by title", .high)]
        let quality = GoalQuality(
            profile: nil, profiles: [], pins: [:], reviewers: [dx, reviewer], lenses: [], confidence: nil,
            done: (false, []), doneMark: nil, doneAt: nil, runs: []
        )
        func item(_ reviewer: String, _ text: String, pr: String) -> GoalItem {
            GoalItem(
                id: "g/\(reviewer)", goal: "g", title: text, source: .reviewer,
                links: [GoalItem.Link(.review, reviewer), GoalItem.Link(.pr, pr)],
                reason: "HIGH " + ReviewEvidence.marker(reviewer: reviewer, objection: ObjectionMatch.id(text)),
                createdAt: t0
            )
        }
        let items = [
            item("dx-evaluator", finding, pr: "acme/search#7"),
            item("implementation", "Matched by title", pr: "acme/search#8"),
        ]
        let hits = EvaluationTriggers.fixesMerged(quality, items: items, merged: ["acme/search#7", "acme/search#8"])
        #expect(hits.map(\.id) == ["dx-evaluator"])
        #expect(hits.map(\.ref) == ["acme/search#7"])
        #expect(EvaluationTriggers.fixesMerged(quality, items: items, merged: ["acme/search#9"]).isEmpty)
        #expect(EvaluationTriggers.fixesMerged(quality, items: items, merged: []).isEmpty)
    }
}

struct EvaluationRunTests {
    private let repo = Repo(org: "acme", name: "search")

    @Test func aWalkClonesTheOpenPRElseTheDefaultBranch() {
        let open = ReviewRun.Pull(ref: PullRef(repo: repo, number: 3), headBranch: "fix", open: true)
        let merged = ReviewRun.Pull(ref: PullRef(repo: repo, number: 2), headBranch: "old", open: false)
        #expect(EvaluationRun.source(pulls: [merged, open], repos: [repo]) == .pull(open.ref))
        #expect(EvaluationRun.source(pulls: [merged], repos: [repo]) == .defaultBranch(repo))
        #expect(EvaluationRun.source(pulls: [], repos: []) == nil)
        #expect(WalkSource.pull(open.ref).text == "acme/search#3")
        #expect(WalkSource.defaultBranch(repo).text == "acme/search")
    }

    @Test func theCloneIsFreshShallowAndCannotPush() {
        let path = "/tmp/heed-walk-g-dx-evaluator-abcdef12/search"
        let pull = EvaluationRun.cloneCommands(.pull(PullRef(repo: repo, number: 3)), path: path)
        #expect(pull == [
            ["gh", "repo", "clone", "acme/search", path, "--", "--depth", "1", "--quiet"],
            ["git", "-C", path, "fetch", "--quiet", "--depth", "1", "origin", "pull/3/head"],
            ["git", "-C", path, "checkout", "--quiet", "--detach", "FETCH_HEAD"],
            ["git", "-C", path, "remote", "set-url", "--push", "origin", "no-push"],
        ])
        let branch = EvaluationRun.cloneCommands(.defaultBranch(repo), path: path)
        #expect(branch.count == 2)
        #expect(branch.first?.contains("--depth") == true)
        #expect(branch.last?.last == "no-push")
    }

    @Test func theCloneLivesInATempFolderOfItsOwnNeverInYourWork() {
        let temp = "/private/var/folders/xy/T/"
        let folder = EvaluationRun.folder(
            temp: temp,
            goal: "faster-search",
            reviewer: "dx-evaluator",
            run: "0123456789"
        )
        #expect(folder == "/private/var/folders/xy/T/heed-walk-faster-search-dx-evaluator-01234567")
        let clone = EvaluationRun.clonePath(folder: folder, repo: repo)
        #expect(clone == folder + "/search")
        let keep = ["/Users/you/code/search", "/Users/you/code/wt/search/fix"]
        #expect(EvaluationRun.isDisposable(clone, temp: temp, keep: keep))
        // Every run its own folder.
        #expect(folder != EvaluationRun.folder(temp: temp, goal: "faster-search", reviewer: "dx-evaluator", run: "9"))
        // Never your clone or worktree, nor anything holding one, nor outside the temp folder.
        #expect(!EvaluationRun.isDisposable("/Users/you/code/search", temp: temp, keep: keep))
        #expect(!EvaluationRun.isDisposable("/Users/you/code/wt/search/fix/sub", temp: temp, keep: keep))
        #expect(!EvaluationRun.isDisposable(temp + "heed-walk-x", temp: temp, keep: [temp + "heed-walk-x/inner"]))
        #expect(!EvaluationRun.isDisposable(temp + "elsewhere/search", temp: temp, keep: []))
        #expect(!EvaluationRun.isDisposable(temp + "heed-walk-x/../../etc", temp: temp, keep: []))
    }

    @Test func theStrangerGetsTheStepsNotTheGoal() {
        let prompt = EvaluationRun.prompt(
            lens: .dxFirstRun, steps: ["Read the README", "Install it"], clone: "/tmp/heed-walk-x/search",
            known: [friction("Flags overlap", .med), friction("Gone", .low, .fixed)]
        )
        #expect(prompt.contains("1. Read the README\n2. Install it"))
        #expect(prompt.contains("no prior context"))
        #expect(prompt.contains("README"))
        #expect(prompt.contains("/tmp/heed-walk-x/search/.heed/evaluation.json"))
        #expect(prompt.contains("- [med] Flags overlap"))
        #expect(!prompt.contains("Gone"))
        #expect(prompt.contains("Never push"))
        #expect(EvaluationRun.prompt(lens: .docsWalk, steps: ["a"], clone: "/c", known: []).contains("the docs in"))
    }

    @Test func walksRunHeadlessAndCannotPush() throws {
        let claude = try #require(EvaluationRun.headless(
            agent: "claude", command: "claude", prompt: "walk", model: "haiku", clone: "/c"
        ))
        #expect(claude.prefix(3) == ["claude", "-p", "walk"])
        #expect(claude.contains("Bash(git push:*)"))
        #expect(claude.suffix(2) == ["--model", "haiku"])
        // The prompt follows the variadic tool lists only after the mode ends them.
        let mode = try #require(claude.firstIndex(of: "--permission-mode"))
        #expect(claude[mode + 1] == "dontAsk")
        let codex = try #require(EvaluationRun.headless(
            agent: "codex", command: "codex", prompt: "walk", model: nil, clone: "/c"
        ))
        #expect(codex == [
            "codex",
            "exec",
            "--sandbox",
            "workspace-write",
            "-C",
            "/c",
            "-o",
            "/c/.heed/last-message.txt",
            "walk",
        ])
        #expect(EvaluationRun.headless(agent: "cursor", command: "cursor-agent", prompt: "w", model: nil, clone: "/c")
            == nil)
    }
}

struct EvaluationOpsTests {
    private func make(_ ops: GoalOps) async throws -> HeedGoal {
        let goal = try await ops.create(title: "Faster search", statement: "Search answers in 50 ms.", now: t0)
        var doc = GoalDoc.new(title: "Faster search", statement: "Search answers in 50 ms.")
        doc.doneWhen = [GoalDoc.Criterion("p95 under 50 ms", met: true, evidence: "acme/search#9")]
        try await ops.save(goal: goal.id, doc: doc, note: "done when", now: t0.addingTimeInterval(1))
        return goal
    }

    @Test func aPublicAPIProfileSpawnsItsEvaluators() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await make(ops)
        try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .publicAPI), now: t0.addingTimeInterval(2))
        let quality = try await ops.quality(of: goal.id)
        let walkers = quality.live.filter { $0.config.walk != nil }
        #expect(walkers.map(\.id) == ["dx-evaluator", "dx-evaluator-api", "docs-walk"])
        // The docs reader still reads.
        #expect(quality.reviewer("docs-reader")?.config.walk == nil)
        // Pinning UX on adds the screens' walk.
        let pinned = try await ops.pin(goal: goal.id, [.ux: 6], now: t0.addingTimeInterval(3))
        #expect(pinned.live.contains { $0.id == "ux-evaluator" && $0.config.walk == .uxScreens })
        #expect(Evaluation.all(pinned).filter(\.required).map(\.lens) == [
            .dxFirstRun, .dxApiConfig, .uxScreens, .docsWalk,
        ])
    }

    @Test func aWalkLeavesEvidenceItemsForHighFrictionAndDoneWhenFixed() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await make(ops)
        try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .publicAPI), now: t0.addingTimeInterval(2))
        try await ops.draftWalk(
            WalkDraft(reviewer: "dx-evaluator", lens: .dxFirstRun, goalVersion: 2, steps: ["Read", "Run"]),
            goal: goal.id, now: t0.addingTimeInterval(3)
        )
        let high = "The first build says nothing for 40 s."
        func walked(_ run: String, _ entries: [Friction], seconds: [Double], at: Double) async throws -> GoalQuality {
            try await ops.reviewEnded(
                ReviewResult(
                    run: run, reviewer: "dx-evaluator", basis: ReviewBasis(goalVersion: 2, heads: []),
                    report: ReviewReport(walk: walk(seconds: seconds, friction: entries))
                ),
                goal: goal.id, now: t0.addingTimeInterval(at)
            )
        }
        var quality = try await walked("w1", [
            Friction(severity: .high, step: 2, area: "first build", finding: high, suggestion: "add progress"),
            Friction(severity: .low, step: 1, finding: "Times in ms and s."),
        ], seconds: [60, 240], at: 10)
        #expect(quality.reviewer("dx-evaluator")?.draft?.steps == ["Read", "Run"])
        #expect(quality.reviewer("dx-evaluator")?.score?.value == 6.5)
        var snapshot = try await ops.snapshot()
        let items = snapshot.items(of: goal.id)
        #expect(items.map(\.title) == [high])
        #expect(items.first?.source == .reviewer)
        let item = try #require(items.first)
        #expect(snapshot.evidence(of: goal.id).contains { $0.item == item.id && $0.kind == .dx && $0.state == .issue })
        let level = try #require(snapshot.evidence(of: goal.id).first { $0.item == nil && $0.kind == .dx })
        #expect(level.score == 6.5)
        #expect(level.text == "DX evaluator 6.5 (bar 8): 2 steps, 5 min")
        #expect(level.source == "dx evaluator")
        // The lens takes the walk's score.
        #expect(quality.lenses.first { $0.lens == .dx }?.score == 6.5)

        // The re-walk after the fix: the high one is gone (fixed), and it went faster.
        quality = try await walked(
            "w2",
            [Friction(severity: .low, step: 1, finding: "Times in ms and s.")],
            seconds: [60, 90],
            at: 20
        )
        // 10 − 0.5 + min((1 − 150/300) × 3, 1.5) = 11 → 10.
        #expect(quality.reviewer("dx-evaluator")?.score?.value == 10)
        snapshot = try await ops.snapshot()
        #expect(snapshot.evidence(of: goal.id).contains { $0.item == item.id && $0.kind == .dx && $0.state == .done })
        let rows = try #require(Evaluation.all(quality).first { $0.lens == .dxFirstRun }).rows
        #expect(rows.map(\.state) == [.open, .fixed])
        #expect(rows.last?.friction.place == "step 2 · first build")
    }

    @Test func uxWalksLeaveUXEvidence() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await make(ops)
        try await ops.setProfile(
            goal: goal.id, GoalProfile(stakes: .product, userFacing: true), now: t0.addingTimeInterval(2)
        )
        try await ops.reviewEnded(
            ReviewResult(
                run: "u1", reviewer: "ux-evaluator", basis: ReviewBasis(goalVersion: 2, heads: []),
                report: ReviewReport(walk: walk(.uxScreens, friction: []))
            ),
            goal: goal.id, now: t0.addingTimeInterval(10)
        )
        let evidence = try await ops.snapshot().evidence(of: goal.id)
        #expect(evidence.contains { $0.kind == .ux && $0.state == .done && $0.score == 10 })
        #expect(!evidence.contains { $0.kind == .dx })
    }
}

struct EvaluationFixtureTests {
    @Test func theFakeWorldWalkedTheAnchorsGoalTwice() throws {
        let fixtures = GoalFixtures.all(now: t0)
        let qualities = GoalQualityFixtures.qualities(GoalQualityFixtures.all(now: t0), goals: fixtures)
        let anchors = try #require(qualities["anchors-survive-page-moves"])
        let dx = try #require(Evaluation.all(anchors).first { $0.lens == .dxFirstRun })
        #expect(dx.required)
        #expect(dx.walks.count == 2)
        // 10 − (3 + 1.5 + 0.5) − 0.125 + (1 − 660/840) × 3 → 5.5.
        #expect(dx.score?.value == 5.5)
        #expect(dx.rows.map(\.state) == [.open, .open, .open, .acceptedRisk, .fixed, .fixed])
        #expect(anchors.lenses.first { $0.lens == .dx }?.score == 5.5)
        // The docs lens is as good as its walk, under the reader's 10.
        #expect(anchors.lenses.first { $0.lens == .docs }?.score == 8.5)
        let ux = try #require(Evaluation.all(anchors).first { $0.lens == .uxScreens })
        #expect(ux.walk == nil)
        #expect(ux.evaluator?.draft?.steps.count == 4)
        let diagrams = try #require(qualities["sequence-diagrams-read-cleanly"])
        #expect(Evaluation.all(diagrams).filter { $0.evaluator != nil }.map(\.lens) == [
            .uxScreens, .accessibility, .docsWalk,
        ])
    }
}
