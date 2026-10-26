import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A Decider that answers from a fixed table, and keeps what it was asked.
private final class FakeDecider: Decider, Sendable {
    let answers: [String: Answer]
    let asked = Mutex<[[String: Question]]>([])

    init(_ answers: [String: Answer]) { self.answers = answers }

    func decide(subject _: String, state _: String, questions: [String: Question]) async throws -> [String: Answer] {
        asked.withLock { $0.append(questions) }
        return answers.filter { questions[$0.key] != nil }
    }
}

private func choice(_ option: String, _ probability: Double = 0.9) -> Answer {
    Answer(choice: option, probabilities: [option: probability], confidence: 0.8)
}

private func noul(_ probability: Double) -> Answer {
    Answer(probability: probability, probabilities: ["true": probability, "false": 1 - probability], confidence: 0.8)
}

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func objection(
    _ text: String, _ severity: Severity, _ state: Objection.State = .open
) -> Objection {
    Objection(id: ObjectionMatch.id(text), severity: severity, text: text, state: state, firstSeen: t0)
}

struct GoalProfileTests {
    @Test func barsTakeTheHighestOfEveryRowThatApplies() {
        let profile = GoalProfile(stakes: .internal, perfSensitive: true, securitySensitive: true)
        let bars = profile.bars()
        #expect(bars == [.plan: 6, .code: 7, .tests: 6, .perf: 7, .security: 8])
        // public-api has security 7, security-sensitive 8: the higher one.
        #expect(GoalProfile(stakes: .publicAPI, securitySensitive: true).bars()[.security] == 8)
        #expect(GoalProfile(stakes: .publicAPI).bars()[.security] == 7)
        #expect(GoalProfile(stakes: .spike).bars() == [.plan: 5, .code: 6])
    }

    @Test func aLowerRowNeverLowersAHigherOne() {
        var table = GoalBarTable.defaults
        table.rows["security-sensitive"] = [.code: 5, .security: 6]
        let bars = GoalProfile(stakes: .publicAPI, securitySensitive: true).bars(table)
        #expect(bars[.code] == 8)
        #expect(bars[.security] == 7)
    }

    @Test func pinsReplaceABarAndZeroTakesTheLensOff() {
        let profile = GoalProfile(stakes: .product, userFacing: true)
        let bars = profile.bars(pins: [.code: 9, .docs: 0, .perf: 5, .ux: 12])
        #expect(bars[.code] == 9)
        #expect(bars[.docs] == nil)
        #expect(bars[.perf] == 5)
        #expect(bars[.ux] == 10)
    }

    @Test func aTableRowReplacesTheDefault() {
        var table = GoalBarTable.defaults
        table.rows["spike"] = [.code: 4]
        #expect(GoalProfile(stakes: .spike).bars(table) == [.code: 4])
    }

    @Test func barRowsParseAndRender() {
        #expect(GoalBarTable.parse("plan 7, code 8, dx 7.5") == [.plan: 7, .code: 8, .dx: 7.5])
        #expect(GoalBarTable.parse("Code 8") == [.code: 8])
        #expect(GoalBarTable.parse("code eight") == nil)
        #expect(GoalBarTable.parse("code 11") == nil)
        #expect(GoalBarTable.parse("vibes 3") == nil)
        #expect(GoalBarTable.render([.dx: 8, .plan: 7, .code: 7.5]) == "plan 7, code 7.5, dx 8")
        for (_, row) in GoalBarTable.defaults.rows {
            #expect(GoalBarTable.parse(GoalBarTable.render(row)) == row)
        }
    }

    @Test func theProfileIsReadFromTheAnswers() {
        let profile = GoalProfile.from([
            "stakes": choice("public-api"), "user_facing": noul(0.5), "perf_sensitive": noul(0.49),
            "security_sensitive": noul(0.9),
        ])
        #expect(profile == GoalProfile(stakes: .publicAPI, userFacing: true, securitySensitive: true))
        #expect(GoalProfile.from(["stakes": choice("galactic")]) == nil)
        #expect(GoalProfile.from([:]) == nil)
    }

    @Test func decidingAsksTheFourQuestionsWithTheGoal() async {
        let decider = FakeDecider([
            "stakes": choice("spike"), "user_facing": noul(0.1), "perf_sensitive": noul(0.8),
            "security_sensitive": noul(0.2),
        ])
        let profile = await GoalProfile.decide(
            goal: "g", doc: "# Faster search", repos: ["acme/search"], paths: ["src/index.rs"], decider: decider
        )
        #expect(profile == GoalProfile(stakes: .spike, perfSensitive: true))
        let asked = decider.asked.withLock { $0.first.map { Set($0.keys) } }
        #expect(asked == [
            "stakes", "user_facing", "perf_sensitive", "security_sensitive",
        ])
        let state = GoalProfile.state(doc: "# Faster search", repos: ["acme/search"], paths: ["src/index.rs"])
        #expect(state.contains("# Faster search") && state.contains("acme/search") && state.contains("- src/index.rs"))
    }

    @Test func barChangesSayWhatMoved() {
        let old = GoalProfile(stakes: .internal).bars()
        let new = GoalProfile(stakes: .publicAPI).bars()
        let changes = BarChange.between(old, new)
        #expect(changes.map(\.lens) == [.plan, .code, .tests, .security, .docs, .dx])
        #expect(changes.allSatisfy { $0.raised })
        #expect(changes.last?.text == "DX first run now 8 (was –)")
        let down = BarChange.between(new, old)
        #expect(down.first { $0.lens == .dx }?.text == "DX first run no longer required (was 8)")
        #expect(down.first { $0.lens == .code }?.raised == false)
        #expect(BarChange.between(old, old).isEmpty)
        #expect(BarChange.note(profile: GoalProfile(stakes: .spike), changes: []) == "spike")
    }
}

struct GoalScoreTests {
    @Test func aReviewerStartsAtTenAndLosesBySeverity() {
        #expect(GoalScore.reviewer([]).value == 10)
        #expect(GoalScore.reviewer([]).basis == "10: nothing open.")
        let score = GoalScore.reviewer([
            objection("matched by title", .high), objection("index unbounded", .med), objection("format", .low),
        ])
        #expect(score.value == 5)
        #expect(score.basis == "10, minus 5 for 3 open.")
    }

    @Test func acceptedRisksCostAQuarterAndFixedOnesGiveCredit() {
        let score = GoalScore.reviewer(
            [
                objection("a", .high), objection("b", .med), objection("c", .low, .acceptedRisk),
                objection("d", .high, .fixed),
            ],
            ran: 2, files: 14
        )
        // 10 - 3 - 1.5 - 0.125 + 0.3 = 5.675 → 5.7
        #expect(score.value == 5.7)
        #expect(
            score.basis == "10, minus 4.5 for 2 open, minus 0.1 for 1 accepted risk, plus 0.3 for 1 fixed. Based on 14 files "
                + "and 2 commands run."
        )
    }

    @Test func creditIsCappedAndTheScoreClamped() {
        let fixed = (0 ..< 10).map { objection("fixed \($0)", .low, .fixed) }
        #expect(GoalScore.reviewer(fixed).value == 10)
        let high = (0 ..< 5).map { objection("bad \($0)", .high) }
        #expect(GoalScore.reviewer(high).value == 0)
        // Six fixed would give 1.8; the cap is 1.5.
        let mixed = [objection("x", .high), objection("y", .high)] + (0 ..< 6).map { objection("f\($0)", .low, .fixed) }
        #expect(GoalScore.reviewer(mixed).value == 5.5)
    }

    @Test func confidenceBlendsCriteriaAndLenses() {
        let lenses = [
            GoalScore.Lens(lens: .code, bar: 8, score: 8),
            GoalScore.Lens(lens: .tests, bar: 6, score: 3),
            GoalScore.Lens(lens: .docs, bar: 7, score: nil),
        ]
        // criteria 2/4 = 0.5; lenses (1 + 0.5 + 0) / 3 = 0.5 → 5.0
        let both = GoalScore.confidence(met: 2, total: 4, lenses: lenses)
        #expect(both?.value == 5)
        #expect(both?.basis == "2/4 criteria met, 1 of 3 lenses at their bar, weighed half and half.")
        #expect(GoalScore.confidence(met: 3, total: 4, lenses: [])?.value == 7.5)
        #expect(GoalScore.confidence(met: 0, total: 0, lenses: [lenses[0]])?.value == 10)
        #expect(GoalScore.confidence(met: 0, total: 0, lenses: []) == nil)
        // Over the bar counts as at it, not more.
        #expect(GoalScore.Lens(lens: .code, bar: 5, score: 9).progress == 1)
    }

    @Test func doneNeedsEveryCriterionWithEvidenceAndEveryLensAtItsBar() {
        var doc = GoalDoc.new(title: "T", statement: "S")
        #expect(GoalScore.done(doc: doc, lenses: []).missing == ["no done-when criteria"])
        doc.doneWhen = [
            GoalDoc.Criterion("a", met: true, evidence: "acme/x#1"), GoalDoc.Criterion("b", met: true),
        ]
        let lenses = [GoalScore.Lens(lens: .code, bar: 7, score: 6.5), GoalScore.Lens(lens: .plan, bar: 5, score: 5)]
        let verdict = GoalScore.done(doc: doc, lenses: lenses)
        #expect(!verdict.done)
        #expect(verdict.missing == ["1 criterion without evidence", "code review 6.5 under 7"])
        doc.doneWhen[1].evidence = "the sample site"
        #expect(GoalScore.done(doc: doc, lenses: [lenses[1]]).done)
        #expect(!GoalScore.done(doc: doc, lenses: [GoalScore.Lens(lens: .ux, bar: 7, score: nil)]).done)
    }
}

struct ObjectionMatchTests {
    @Test func theIdIgnoresCasePunctuationAndFiller() {
        #expect(ObjectionMatch.id("Redirects are matched by title, not heading id.")
            == ObjectionMatch.id("redirects matched by title  heading id"))
        #expect(ObjectionMatch.id("index grows") != ObjectionMatch.id("grows index"))
        #expect(ObjectionMatch.id("x").count == 12)
    }

    @Test func aReCheckKeepsIdsFixesWhatIsGoneAndOpensWhatIsNew() {
        let later = t0.addingTimeInterval(3600)
        let known = [
            objection("Redirects are matched by title", .high),
            objection("The redirects file has no schema version", .low, .acceptedRisk),
            objection("Index grows without limit", .med),
            objection("A global logger is shared by two builds", .high, .fixed),
        ]
        let merged = ObjectionMatch.merge(known: known, raised: [
            .init(severity: .high, text: "redirects are matched by title."),
            .init(severity: .low, text: "The redirects file has no schema version"),
            .init(severity: .med, text: "A global logger is shared by two builds"),
            .init(severity: .low, text: "Docs miss the new flag"),
        ], at: later)
        func state(_ text: String) -> Objection? { merged.first { $0.id == ObjectionMatch.id(text) } }
        #expect(state("Redirects are matched by title")?.state == .open)
        #expect(state("Redirects are matched by title")?.firstSeen == t0)
        #expect(state("Redirects are matched by title")?.lastSeen == later)
        #expect(state("The redirects file has no schema version")?.state == .acceptedRisk)
        #expect(state("Index grows without limit")?.state == .fixed)
        #expect(state("Index grows without limit")?.fixedAt == later)
        // Fixed, then raised again: open again, at its new severity.
        #expect(state("A global logger is shared by two builds")?.state == .open)
        #expect(state("A global logger is shared by two builds")?.severity == .med)
        #expect(state("Docs miss the new flag")?.state == .open)
        // An accepted one no longer raised is gone too: fixed.
        let gone = ObjectionMatch.merge(known: [known[1]], raised: [], at: later)
        #expect(gone.first?.state == .fixed)
        #expect(state("Docs miss the new flag")?.firstSeen == later)
        #expect(merged.count == 5)
    }

    @Test func rewordedObjectionsMatchByTheirWords() {
        let known = [objection("The anchor index grows without any limit on big sites", .med, .acceptedRisk)]
        let merged = ObjectionMatch.merge(known: known, raised: [
            .init(severity: .med, text: "Anchor index grows without limit on big sites"),
        ], at: t0)
        #expect(merged.count == 1)
        #expect(merged[0].id == known[0].id)
        #expect(merged[0].state == .acceptedRisk)
        let unrelated = ObjectionMatch.merge(known: known, raised: [
            .init(severity: .med, text: "Login form loses focus"),
        ], at: t0)
        #expect(unrelated.count == 2)
    }

    @Test func aModelsPairMatchesWhatTheWordsDoNot() {
        let known = [objection("Redirects are matched by title", .high)]
        let raised = [ReviewReport.Raised(severity: .high, text: "Renaming a heading leaves old links dangling")]
        #expect(ObjectionMatch.unmatched(known: known, raised: raised).raised == [0])
        let merged = ObjectionMatch.merge(known: known, raised: raised, pairs: [0: known[0].id], at: t0)
        #expect(merged.count == 1)
        #expect(merged[0].id == known[0].id)
        #expect(merged[0].text == "Renaming a heading leaves old links dangling")
    }

    @Test func askingAModelOnlyAsksAboutWhatIsLeft() async {
        let known = [objection("Redirects are matched by title", .high), objection("Index grows", .med)]
        let raised: [ReviewReport.Raised] = [
            .init(severity: .high, text: "Redirects are matched by title"),
            .init(severity: .high, text: "Renaming a heading leaves old links dangling"),
        ]
        let decider = FakeDecider(["r1": choice(known[1].id, 0.7)])
        let pairs = await ObjectionMatch.ask(known: known, raised: raised, decider: decider, subject: "goal:g")
        #expect(pairs == [1: known[1].id])
        let asked = decider.asked.withLock { $0.first.map { Array($0.keys) } }
        #expect(asked == ["r1"])
        let unsure = FakeDecider(["r1": choice(known[1].id, 0.5)])
        #expect(await ObjectionMatch.ask(known: known, raised: raised, decider: unsure, subject: "g").isEmpty)
        let nothing = FakeDecider([:])
        #expect(await ObjectionMatch.ask(known: known, raised: [raised[0]], decider: nothing, subject: "g").isEmpty)
        let none = nothing.asked.withLock(\.isEmpty)
        #expect(none)
    }

    @Test func reviewJSONIsReadLeniently() throws {
        let report = try #require(ReviewReport.parse(Data("""
        {"summary": " Direction is right. ", "findings": [
          {"severity": "critical", "text": "Matched by title", "evidence": "src/a.rs:12", "file": "src/a.rs"},
          {"severity": "medium", "message": "Unbounded index"},
          {"severity": "strange", "text": "Odd"},
          {"severity": "low", "text": "  "}
        ], "ran": ["cargo test", {"command": "cargo bench"}, 3], "files": ["a", "b"]}
        """.utf8)))
        #expect(report.summary == "Direction is right.")
        #expect(report.objections.map(\.severity) == [.high, .med, .med])
        #expect(report.objections[0].file == "src/a.rs")
        #expect(report.objections[1].text == "Unbounded index")
        #expect(report.ran == ["cargo test", "cargo bench"])
        #expect(report.files == 2)
        #expect(ReviewReport.parse(Data("[1]".utf8)) == nil)
        #expect(ReviewRun.read(nil).failure == "it wrote no review")
        #expect(ReviewRun.read(Data("nope".utf8)).failure == "its review.json is not a review")
        #expect(ReviewRun.read(Data(#"{"summary": "fine"}"#.utf8)).report?.objections.isEmpty == true)
    }
}

struct ReviewPlannerTests {
    private let bars: [GoalLens: Double] = [.code: 7, .plan: 6]
    private let basis = ReviewBasis(goalVersion: 3, heads: ["acme/x#1@abc"])

    private func state(
        _ kind: ReviewerKind, policy: ReviewPolicy = .onChange, score: Double? = nil, reviewed: ReviewBasis? = nil,
        running: Bool = false
    ) -> ReviewerState {
        var state = ReviewerState(
            config: ReviewerConfig(id: kind.rawValue, kind: kind, policy: policy), objections: [],
            score: score.map { GoalScore(value: $0, basis: "") }, history: [], summary: ""
        )
        if let reviewed {
            state.lastReview = ReviewResult(run: "r1", reviewer: kind.rawValue, basis: reviewed, report: nil)
            state.lastRun = ReviewRunStart(
                id: "r1", reviewer: kind.rawValue, trigger: .nightly, basis: reviewed, agent: "claude"
            )
        }
        if running {
            state.lastRun = ReviewRunStart(
                id: "r2",
                reviewer: kind.rawValue,
                trigger: .manual,
                basis: basis,
                agent: "c"
            )
        }
        return state
    }

    @Test func onlyRequiredLensesRunAndCustomOnesAlways() {
        let plan = ReviewPlanner.plan(
            trigger: .prUpdated("acme/x#1"),
            reviewers: [state(.implementation), state(.perfProber), state(.custom)],
            bars: bars, basis: basis, used: 0, limit: 6
        )
        #expect(plan.run == ["implementation", "custom"])
        #expect(plan.quiet["perf-prober"] == "its lens is not required for this goal")
    }

    @Test func atItsBarItGoesQuietUntilSomethingNew() {
        let old = ReviewBasis(goalVersion: 2, heads: ["acme/x#1@abc"])
        let quiet = ReviewPlanner.plan(
            trigger: .nightly, reviewers: [state(.implementation, score: 7, reviewed: basis)], bars: bars,
            basis: basis, used: 0, limit: 6
        )
        #expect(quiet.run.isEmpty)
        #expect(quiet.quiet["implementation"] == "at its bar, nothing new since")
        let fresh = ReviewPlanner.plan(
            trigger: .goalVersion(3), reviewers: [state(.implementation, score: 9, reviewed: old)], bars: bars,
            basis: basis, used: 0, limit: 6
        )
        #expect(fresh.run == ["implementation"])
        // Under its bar and nothing new: running again would say the same.
        let same = ReviewPlanner.plan(
            trigger: .nightly, reviewers: [state(.implementation, score: 5, reviewed: basis)], bars: bars,
            basis: basis, used: 0, limit: 6
        )
        #expect(same.quiet["implementation"] == "nothing new since its last review")
        // You asking runs it regardless.
        let asked = ReviewPlanner.plan(
            trigger: .manual, reviewers: [state(.implementation, score: 9, reviewed: basis)], bars: bars,
            basis: basis, used: 0, limit: 6
        )
        #expect(asked.run == ["implementation"])
    }

    @Test func policiesPickTheirTriggers() {
        let reviewers = [state(.implementation, policy: .manual), state(.planCritic, policy: .nightly)]
        let change = ReviewPlanner.plan(
            trigger: .prMerged("acme/x#1"), reviewers: reviewers, bars: bars, basis: basis, used: 0, limit: 6
        )
        #expect(change.run.isEmpty)
        #expect(change.quiet == ["implementation": "re-checks only when you ask", "plan-critic": "re-checks nightly"])
        let night = ReviewPlanner.plan(
            trigger: .nightly,
            reviewers: reviewers,
            bars: bars,
            basis: basis,
            used: 0,
            limit: 6
        )
        #expect(night.run == ["plan-critic"])
    }

    @Test func theBudgetHoldsBackWhatIsOverAndManualIsNeverHeld() {
        let reviewers = [state(.implementation), state(.planCritic), state(.custom)]
        let plan = ReviewPlanner.plan(
            trigger: .goalVersion(3), reviewers: reviewers, bars: bars, basis: basis, used: 4, limit: 6
        )
        #expect(plan.run == ["implementation", "plan-critic"])
        #expect(plan.overBudget == ["custom"])
        let spent = ReviewPlanner.plan(
            trigger: .goalVersion(3), reviewers: reviewers, bars: bars, basis: basis, used: 9, limit: 6
        )
        #expect(spent.run.isEmpty)
        #expect(spent.overBudget.count == 3)
        let manual = ReviewPlanner.plan(
            trigger: .manual, only: ["custom"], reviewers: reviewers, bars: bars, basis: basis, used: 9, limit: 6
        )
        #expect(manual.run == ["custom"])
        #expect(manual.overBudget.isEmpty)
    }

    @Test func aRunningReviewerIsLeftAlone() {
        let plan = ReviewPlanner.plan(
            trigger: .manual, reviewers: [state(.implementation, running: true)], bars: bars, basis: basis, used: 0,
            limit: 6
        )
        #expect(plan.run.isEmpty)
        #expect(plan.quiet["implementation"] == "running now")
    }

    @Test func theBudgetCountsTodaysRuns() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_800_000_000) // 2027-01-15 08:00 UTC
        let runs = [now.addingTimeInterval(-3600), now.addingTimeInterval(-7 * 3600), now.addingTimeInterval(-9 * 3600)]
        #expect(ReviewPlanner.used(runs, now: now, calendar: calendar) == 2)
        #expect(ReviewPlanner.nightlyDue(last: nil, now: now, calendar: calendar))
        #expect(!ReviewPlanner.nightlyDue(last: now.addingTimeInterval(-3600), now: now, calendar: calendar))
        #expect(ReviewPlanner.nightlyDue(last: now.addingTimeInterval(-86400), now: now, calendar: calendar))
        #expect(!ReviewPlanner.nightlyDue(last: nil, now: now.addingTimeInterval(-6 * 3600), calendar: calendar))
    }

    @Test func missingReviewersAreOnePerRequiredLens() {
        #expect(ReviewPlanner.missing(bars: [.code: 7, .dx: 8, .plan: 6], reviewers: [state(.implementation)])
            == [.planCritic, .dxEvaluator])
    }

    @Test func prTriggersComeFromWhatMoved() {
        let before: [String: (head: String?, state: String)] = [
            "acme/x#1": ("aaa", "open"), "acme/x#2": ("bbb", "open"), "acme/x#3": ("ccc", "open"),
        ]
        let after: [String: (head: String?, state: String)] = [
            "acme/x#1": ("aaa", "open"), "acme/x#2": ("bbc", "open"), "acme/x#3": ("ccc", "merged"),
            "acme/x#4": ("ddd", "open"), "acme/x#5": ("eee", "closed"),
        ]
        #expect(ReviewTrigger.from(before: before, after: after) == [
            .prUpdated("acme/x#2"), .prMerged("acme/x#3"), .prOpened("acme/x#4"),
        ])
    }
}

struct ReviewRunTests {
    @Test func agentsAreKeptFromChangingTheWork() {
        let claude = ReviewRun.restrictions(agent: "claude")
        #expect(claude.first == "--disallowedTools")
        #expect(Set(claude).isSuperset(of: ["Edit", "Write", "NotebookEdit", "Bash(git push:*)"]))
        #expect(ReviewRun.restrictions(agent: "codex") == ["--sandbox", "workspace-write"])
        #expect(ReviewRun.restrictions(agent: "cursor").isEmpty)
    }

    @Test func runBranchesAreSweptLikeOtherRunBranches() {
        let branch = ReviewRun.branch(goal: "faster-search", reviewer: "implementation")
        #expect(branch == "heed/review/faster-search-implementation")
        #expect(ReviewRun.isReviewBranch(branch))
        #expect(Runs.isRunBranch(branch))
        #expect(ReviewRun.reportPath(worktree: "/wt/x") == "/wt/x/.heed/review.json")
    }

    @Test func thePromptCarriesTheGoalTheBarWhatChangedAndWhereToWrite() {
        let prompt = ReviewRun.prompt(
            config: ReviewerConfig(id: "implementation", kind: .implementation), goalTitle: "Faster search",
            doc: "# Faster search\n\n## Goal\nQuick.", bar: 7.5, changed: ["acme/x#1 changed"], worktree: "/wt/r",
            known: [
                objection("Index grows", .med), objection("Old thing", .low, .fixed),
                objection("Format", .low, .acceptedRisk),
            ]
        )
        #expect(prompt.contains("implementation reviewer for the goal \"Faster search\""))
        #expect(prompt.contains("The bar for this goal is 7.5 out of 10"))
        #expect(prompt.contains("- acme/x#1 changed"))
        #expect(prompt.contains("- [med] Index grows"))
        #expect(prompt.contains("- [low] Format (accepted)"))
        #expect(!prompt.contains("Old thing"))
        #expect(prompt.contains("/wt/r/.heed/review.json"))
        #expect(prompt.contains("never edit files, commit or push"))
    }
}

struct GoalQualityOpsTests {
    private func ops() throws -> (GoalOps, HeedGoal) {
        let ops = try GoalOps.inMemory()
        return (ops, HeedGoal(id: "", title: "", createdAt: t0))
    }

    private func make(_ ops: GoalOps) async throws -> HeedGoal {
        let goal = try await ops.create(title: "Faster search", statement: "Search answers in 50 ms.", now: t0)
        var doc = GoalDoc.new(title: "Faster search", statement: "Search answers in 50 ms.")
        doc.doneWhen = [GoalDoc.Criterion("p95 under 50 ms", met: true, evidence: "acme/search#9")]
        try await ops.save(goal: goal.id, doc: doc, note: "done when", now: t0.addingTimeInterval(1))
        return goal
    }

    @Test func aProfileSetsBarsAndSpawnsAReviewerPerLens() async throws {
        let (ops, _) = try ops()
        let goal = try await make(ops)
        let first = try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .spike), now: t0.addingTimeInterval(2))
        #expect(first?.bars == [.plan: 5, .code: 6])
        #expect(first?.changes.isEmpty == true)
        var quality = try await ops.quality(of: goal.id)
        #expect(quality.reviewers.map(\.id) == ["plan-critic", "implementation"])
        #expect(quality.lenses.map(\.lens) == [.plan, .code])
        // Criteria 1/1, lenses 0: confidence 5, and the ring follows it.
        #expect(quality.confidence?.value == 5)
        #expect(try await ops.snapshot().goal(goal.id)?.score == 5)

        // A new version, a riskier profile: the bars go up with a note, and its new lenses get reviewers.
        try await ops.save(
            goal: goal.id,
            text: "# Faster search\n\n## Goal\nA public search API.\n",
            now: t0.addingTimeInterval(3)
        )
        let second = try await ops.setProfile(
            goal: goal.id,
            GoalProfile(stakes: .publicAPI),
            now: t0.addingTimeInterval(4)
        )
        #expect(second?.goalVersion == 3)
        #expect(second?.note.contains("code review now 8 (was 6)") == true)
        quality = try await ops.quality(of: goal.id)
        #expect(quality.reviewers.map(\.id) == [
            "plan-critic", "implementation", "test-architect", "security", "docs-reader", "dx-evaluator",
        ])
        #expect(quality.profiles.count == 2)
        // The same profile for the same version again changes nothing.
        #expect(try await ops
            .setProfile(goal: goal.id, GoalProfile(stakes: .publicAPI), now: t0.addingTimeInterval(5)) == nil)
    }

    @Test func reviewsScoreAcceptingARiskMovesItAndDoneFollows() async throws {
        let (ops, _) = try ops()
        let goal = try await make(ops)
        try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .spike), now: t0.addingTimeInterval(2))
        let basis = ReviewBasis(goalVersion: 2, heads: [])
        let report = ReviewReport(summary: "Fine, mostly.", objections: [
            .init(severity: .med, text: "Unbounded index"),
        ])
        try await ops.runStarted(
            ReviewRunStart(id: "r1", reviewer: "implementation", trigger: .manual, basis: basis, agent: "claude"),
            goal: goal.id, now: t0.addingTimeInterval(10)
        )
        var quality = try await ops.quality(of: goal.id)
        #expect(quality.reviewer("implementation")?.running == true)
        #expect(quality.runs.count == 1)
        quality = try await ops.reviewEnded(
            ReviewResult(run: "r1", reviewer: "implementation", basis: basis, report: report),
            goal: goal.id, now: t0.addingTimeInterval(20)
        )
        let implementation = try #require(quality.reviewer("implementation"))
        #expect(!implementation.running)
        #expect(implementation.score?.value == 8.5)
        #expect(quality.lenses.first { $0.lens == .code }?.met == true)
        #expect(!quality.done.done)
        // The plan critic at its bar too: done.
        try await ops.reviewEnded(
            ReviewResult(
                run: "r2",
                reviewer: "plan-critic",
                basis: basis,
                report: ReviewReport(summary: "", objections: [])
            ),
            goal: goal.id, now: t0.addingTimeInterval(30)
        )
        quality = try await ops.setObjection(
            goal: goal.id, reviewer: "implementation", objection: ObjectionMatch.id("Unbounded index"), .acceptedRisk,
            now: t0.addingTimeInterval(40)
        )
        #expect(quality.reviewer("implementation")?.score?.value == 9.6)
        #expect(quality.done.done)
        #expect(quality.shouldMarkDone)
        #expect(quality.confidence?.value == 10)

        // Marked done, then undone: held until what made it done changes.
        try await ops.markDone(goal: goal.id, true, now: t0.addingTimeInterval(50))
        #expect(try await ops.snapshot().goal(goal.id)?.status == .done)
        #expect(try await !ops.quality(of: goal.id).shouldMarkDone)
        try await ops.markDone(goal: goal.id, false, now: t0.addingTimeInterval(60))
        #expect(try await ops.snapshot().goal(goal.id)?.status == .active)
        #expect(try await !ops.quality(of: goal.id).shouldMarkDone)
    }

    @Test func highObjectionsAreThereForTheItems() async throws {
        let (ops, _) = try ops()
        let goal = try await make(ops)
        try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .spike), now: t0.addingTimeInterval(2))
        try await ops.reviewEnded(
            ReviewResult(
                run: "r1",
                reviewer: "implementation",
                basis: ReviewBasis(goalVersion: 2, heads: []),
                report:
                ReviewReport(summary: "", objections: [
                    .init(severity: .high, text: "Matched by title"), .init(severity: .low, text: "Format"),
                ])
            ),
            goal: goal.id, now: t0.addingTimeInterval(20)
        )
        let high = try await ops.highObjections(goal: goal.id)
        #expect(high.map(\.objection.text) == ["Matched by title"])
        #expect(high.map(\.reviewer) == ["implementation"])
    }

    @Test func spawningTheSameKindTwiceGetsANumber() async throws {
        let (ops, _) = try ops()
        let goal = try await make(ops)
        let first = try await ops.spawn(
            ReviewerConfig(id: "custom", kind: .custom, instructions: "As a DBA"),
            goal: goal.id,
            now: t0
        )
        let second = try await ops.spawn(
            ReviewerConfig(id: "custom", kind: .custom),
            goal: goal.id,
            now: t0.addingTimeInterval(1)
        )
        #expect(first.id == "custom")
        #expect(second.id == "custom-2")
    }

    @Test func pinsOverrideTheProfileAndSpawnForANewLens() async throws {
        let (ops, _) = try ops()
        let goal = try await make(ops)
        try await ops.setProfile(goal: goal.id, GoalProfile(stakes: .spike), now: t0.addingTimeInterval(2))
        let quality = try await ops.pin(goal: goal.id, [.code: 9, .perf: 6, .plan: 0], now: t0.addingTimeInterval(3))
        #expect(quality.lenses.map(\.lens) == [.code, .perf])
        #expect(quality.lenses.first?.bar == 9)
        #expect(quality.reviewers.map(\.id).contains("perf-prober"))
    }

    @Test func theRecordSurvivesAReopen() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-quality-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appendingPathComponent("goals.sqlite").path
        let files = GoalFiles(root: folder.appendingPathComponent("goals"))
        do {
            let ops = try GoalOps(path: path, files: files)
            let goal = try await make(ops)
            try await ops.setProfile(
                goal: goal.id,
                GoalProfile(stakes: .product, userFacing: true),
                now: t0.addingTimeInterval(2)
            )
        }
        let again = try GoalOps(path: path, files: files)
        let quality = try await again.quality(of: "faster-search")
        #expect(quality.profile?.profile == GoalProfile(stakes: .product, userFacing: true))
        #expect(quality.lenses.map(\.lens) == [.plan, .code, .tests, .docs, .ux])
    }
}

struct GoalQualityConfigTests {
    @Test func barsReviewersAndTheBudgetAreRead() {
        let (decoded, problems) = ConfigLoader.decode("""
        [goals]
        reviewer_runs_per_day = 3
        auto_review = false
        reviewer_agent = "codex"

        [goals.bars]
        spike = "code 5"
        public-api = "code 9, dx 9"
        vibes = "code 1"
        product = "code lots"

        [goals.reviewers]
        implementation = "cheap"
        docs-reader = "BEST"
        wizard = "best"
        """)
        guard let config = decoded else { return #expect(Bool(false)) }
        #expect(config.goals.reviewerRunsPerDay == 3)
        #expect(!config.goals.autoReview)
        #expect(config.goals.reviewerAgent == "codex")
        #expect(config.goals.bars.rows["spike"] == [.code: 5])
        #expect(config.goals.bars.rows["public-api"] == [.code: 9, .dx: 9])
        #expect(config.goals.bars.rows["product"] == GoalBarTable.defaults.rows["product"])
        #expect(config.goals.tier(for: .implementation) == .cheap)
        #expect(config.goals.tier(for: .docsReader) == .best)
        #expect(config.goals.tier(for: .perfProber) == .cheap)
        #expect(config.goals.tier(for: .security) == .best)
        #expect(Set(problems.map(\.path)) == ["goals.bars.vibes", "goals.bars.product", "goals.reviewers.wizard"])
    }

    @Test func theDocumentedDefaultsAreTheBuiltInOnes() {
        let (decoded, problems) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(problems.isEmpty)
        guard let config = decoded else { return #expect(Bool(false)) }
        #expect(config.goals.bars == GoalBarTable.defaults)
        #expect(config.goals.reviewerRunsPerDay == 6)
        for kind in ReviewerKind.allCases {
            #expect(config.goals.tier(for: kind) == kind.defaultTier)
        }
    }
}

struct GoalAttentionTests {
    @Test func doneGoalsAndWaitingReviewersAreAsked() {
        let now = t0.addingTimeInterval(86400)
        let done = HeedGoal(id: "done-one", title: "Done one", status: .done, createdAt: t0)
        let busy = HeedGoal(id: "busy-one", title: "Busy one", createdAt: t0)
        let old = HeedGoal(id: "old-one", title: "Old one", status: .done, createdAt: t0)
        let records = [
            QualityRecord(goal: "done-one", at: t0, entry: .done(DoneMark(done: true, basis: ""))),
        ]
        var qualities = ["done-one": GoalQuality.fold(records, doc: nil)]
        qualities["old-one"] = GoalQuality.fold(
            [QualityRecord(
                goal: "old-one",
                at: t0.addingTimeInterval(-5 * 86400),
                entry: .done(DoneMark(done: true, basis: ""))
            )],
            doc: nil
        )
        let items = GoalAttention.items(
            goals: [done, busy, old], qualities: qualities, waiting: [
                "busy-one": ["implementation"],
                "done-one": ["x"],
            ],
            now: now
        )
        #expect(items.map(\.id) == ["goal:done-one:done", "goal:busy-one:budget"])
        #expect(items.map(\.reasons) == [[.goalDone], [.goalBudget]])
        #expect(items[1].title.contains("implementation"))
        #expect(GoalAttention.goal(of: items[1]) == "busy-one")
    }
}
