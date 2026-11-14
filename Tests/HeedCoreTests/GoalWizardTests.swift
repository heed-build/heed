import Foundation
@testable import HeedCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

struct GoalWizardTests {
    // MARK: The state machine

    @Test func aNewWizardStartsAtPlanWithTheRestAhead() {
        let wizard = GoalWizard(goal: "g", at: t0)
        #expect(wizard.step == .plan)
        #expect(wizard.state(of: .plan) == .now)
        #expect(WizardStep.allCases.dropFirst().allSatisfy { wizard.state(of: $0) == .next })
        #expect(!wizard.finished)
        #expect(wizard.reach == .plan)
    }

    @Test func advancingMarksTheStepDoneAndShowsTheNext() {
        var wizard = GoalWizard(goal: "g", at: t0)
        let r1 = wizard.advance(at: t0)
        #expect(r1 == .panel)
        #expect(wizard.state(of: .plan) == .done)
        #expect(wizard.state(of: .panel) == .now)
        #expect(wizard.reach == .panel)
        // Back to a finished step is fine; past the reach is not.
        let r2 = wizard.show(.plan, at: t0)
        #expect(r2)
        #expect(wizard.state(of: .panel) == .next)
        #expect(wizard.reach == .panel)
        let r3 = wizard.show(.done, at: t0)
        #expect(!r3)
        let r4 = wizard.show(.panel, at: t0)
        #expect(r4)
        for _ in 0 ..< 5 {
            wizard.advance(at: t0)
        }
        #expect(wizard.finished)
        let r5 = wizard.advance(at: t0)
        #expect(r5 == nil)
    }

    @Test func onlyTheFirstThreeStepsAreBuiltAndTheRestFallBack() {
        #expect(WizardStep.allCases.filter(\.built) == [.plan, .panel, .done])
        #expect(WizardStep.split.fallback == .swarm)
        #expect(WizardStep.careful.fallback == .reviewers)
        #expect(WizardStep.go.fallback == .overview)
        #expect(WizardStep(word: "3") == .done)
        #expect(WizardStep(word: "How careful") == .careful)
        #expect(WizardStep(word: "nope") == nil)
    }

    @Test func theFingerprintChangesWithTheContentNotTheClockOrTheTLDR() {
        var wizard = GoalWizard(goal: "g", at: t0)
        let before = wizard.fingerprint
        wizard.updatedAt = t0.addingTimeInterval(60)
        wizard.tldr = WizardTLDR(steps: [], settled: [], open: [], writtenBy: "heed", at: t0, fingerprint: "x")
        wizard.spent(WizardCost(step: .plan, agent: "claude", model: "opus", dollars: 0.1))
        #expect(wizard.fingerprint == before)
        wizard.plan.answer("the first two")
        #expect(wizard.fingerprint != before)
        // Stable across encodes: the same content, the same print.
        #expect(wizard.fingerprint == wizard.fingerprint)
    }

    @Test func costsSumPerStepAndSayWhenPartial() {
        var wizard = GoalWizard(goal: "g", at: t0)
        #expect(wizard.dollars(for: .plan) == nil)
        wizard.spent(WizardCost(step: .plan, agent: "claude", model: "opus", dollars: 0.05))
        wizard.spent(WizardCost(step: .plan, agent: "claude", model: "opus", dollars: 0.02))
        #expect(abs((wizard.dollars(for: .plan) ?? 0) - 0.07) < 1e-9)
        #expect(!wizard.costIsPartial(for: .plan))
        wizard.spent(WizardCost(step: .plan, agent: "codex", model: nil, dollars: nil))
        #expect(wizard.costIsPartial(for: .plan))
        #expect(wizard.model(for: .plan) == "codex")
    }

    @Test func theStoreKeepsAWizardAcrossReopening() async throws {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Faster search", statement: "", now: t0)
        var wizard = try await ops.startWizard(goal: goal.id, now: t0)
        wizard.plan.answer("make it fast")
        wizard.advance(at: t0)
        try await ops.save(wizard: wizard)
        // Starting again resumes it.
        let again = try await ops.startWizard(goal: goal.id, now: t0.addingTimeInterval(9))
        #expect(again == wizard)
        #expect(try await ops.wizards()[goal.id]?.step == .panel)
        await #expect(throws: GoalOpError.unknownGoal("nope")) { try await ops.startWizard(goal: "nope", now: t0) }
    }

    // MARK: Plan

    @Test func pickingAnOptionAnswersTheOpenQuestion() {
        var conversation = PlanConversation(turns: [
            PlanTurn(role: .you, text: "fix it everywhere"),
            PlanTurn(role: .heed, text: "Which?", options: ["a", "b", "c"]),
        ])
        #expect(conversation.open?.text == "Which?")
        let r6 = conversation.pick(5)
        #expect(r6 == nil)
        let r7 = conversation.pick(1)
        #expect(r7 == "b")
        #expect(conversation.turns[1].picked == [1])
        #expect(conversation.open == nil)
        #expect(conversation.answers == 2)
        let r8 = conversation.pick(0)
        #expect(r8 == nil)
    }

    @Test func aPlanVersionIsAddedOnlyWhenThePlanChanged() {
        var conversation = PlanConversation()
        let plan = WizardPlan(title: "T", steps: ["a"])
        let r9 = conversation.add(plan, goalVersion: 2)
        #expect(r9 == 1)
        let r10 = conversation.add(plan, goalVersion: 3)
        #expect(r10 == nil)
        var bigger = plan
        bigger.steps.append("b")
        let r11 = conversation.add(bigger, goalVersion: 3)
        #expect(r11 == 2)
        #expect(conversation.current == bigger)
    }

    @Test func thePlanGoesIntoGoalMdAndReadsBack() {
        let plan = WizardFixtures.plan(4)
        var mine = GoalDoc(title: "Old", goal: "old", extras: [GoalDoc.Extra(heading: "Notes", body: "keep me")])
        mine.decisions = [GoalDoc.Decision("mine", source: "you")]
        let doc = plan.apply(to: mine)
        #expect(doc.title == plan.title)
        #expect(doc.goal == plan.summary)
        #expect(doc.notTheGoal == plan.outOfScope)
        #expect(doc.extras.last == GoalDoc.Extra(heading: "Notes", body: "keep me"))
        #expect(doc.decisions.first?.text == "mine")
        // Through the file and back: the same plan.
        let read = WizardPlan.read(GoalDoc.parse(doc.render()))
        #expect(read == plan)
        // Applied twice, nothing doubles.
        #expect(plan.apply(to: doc) == doc)
    }

    @Test func completenessReadsLenientlyAndKnowsWhenItIsEnough() {
        let parsed = Completeness.parse("""
        Here: {"scope": 90, "Constraints": "75", "risks": 0.5, "who it's for": 40, "out_of_scope": 85}
        """)
        #expect(parsed?[.scope] == 90)
        #expect(parsed?[.constraints] == 75)
        #expect(parsed?[.risks] == 50)
        #expect(parsed?[.audience] == 40)
        #expect(parsed?[.outOfScope] == 85)
        #expect(parsed?.weakest == .audience)
        #expect(parsed?.overall == 68)
        #expect(parsed?.enough == true)
        #expect(Completeness([.scope: 95, .constraints: 95, .risks: 95, .audience: 30, .outOfScope: 95])
            .enough == false)
        #expect(Completeness([.scope: 60, .constraints: 90, .risks: 90, .audience: 90, .outOfScope: 90])
            .enough == false)
        #expect(Completeness.parse("{\"mood\": 3}") == nil)
        #expect(Completeness.parse("no json") == nil)
        #expect(Completeness([.scope: 140])[.scope] == 100)
    }

    @Test func thePlannersReplyIsReadLeniently() throws {
        let reply = try #require(PlanTalk.parse("""
        Sure. {"question": "Fail or warn?", "options": ["fail", {"label": "warn"}, "", "only log", "four"], \
        "complete": "true", "plan": {"title": "", "summary": "s", "steps": ["a", "b"], "who": "readers", \
        "out_of_scope": "search"}}
        """, fallbackTitle: "Fallback"))
        #expect(reply.question == "Fail or warn?")
        #expect(reply.options == ["fail", "warn", "only log"])
        #expect(reply.complete)
        #expect(reply.plan.title == "Fallback")
        #expect(reply.plan.steps == ["a", "b"])
        #expect(reply.plan.audience == "readers")
        #expect(reply.plan.outOfScope == ["search"])
        #expect(PlanTalk.parse("{\"other\": 1}", fallbackTitle: "x") == nil)
    }

    @Test func aTurnRunsTheAgentReadOnlyInTheReposWithTheConversation() throws {
        let claude = try #require(PlanTalk.invocation(
            agent: "claude", command: "claude --verbose", model: "opus", repos: ["/r/one", "/r/two"]
        ))
        #expect(claude.first == "claude")
        #expect(!claude.contains("--verbose"))
        #expect(claude.contains("--no-session-persistence"))
        let tools = try #require(claude.firstIndex(of: "--tools"))
        #expect(Array(claude[(tools + 1) ... (tools + 3)]) == ["Read", "Grep", "Glob"])
        #expect(!claude.contains("Edit") && !claude.contains("Bash"))
        #expect(claude.contains("/r/two") && !claude.contains("/r/one"))
        #expect(claude.suffix(2) == ["--model", "opus"])
        let codex = try #require(PlanTalk.invocation(agent: "codex", command: "codex", model: nil, repos: ["/r/one"]))
        #expect(codex.contains("read-only") && codex.contains("/r/one") && codex.last == "-")
        #expect(PlanTalk.invocation(agent: "gemini", command: "gemini", model: nil, repos: []) == nil)
        #expect(PlanTalk.strongest(agent: "claude") == "opus")
        #expect(PlanTalk.strongest(agent: "codex") == nil)

        let prompt = PlanTalk.prompt(
            title: "T", statement: "do it", turns: [
                PlanTurn(role: .heed, text: "Which?", options: ["a", "b"]), PlanTurn(role: .you, text: "a"),
            ], plan: WizardPlan(title: "T", steps: ["x"]), repos: ["/r/one"], weakest: "who it is for"
        )
        #expect(prompt.contains("You asked: Which? (options: a | b)"))
        #expect(prompt.contains("They answered: a"))
        #expect(prompt.contains("1. x"))
        #expect(prompt.contains("weakest on who it is for"))
    }

    @Test func aTurnReadsTheGoalsWorktreesAndTheReposTheAskNames() {
        let records = [(slug: "acme/docs-toolkit", path: "/src/docs-toolkit"), (slug: "acme/site", path: "/src/site")]
        #expect(PlanTalk
            .repos(text: "fix anchors in docs-toolkit", linked: [], records: records) == ["/src/docs-toolkit"])
        #expect(PlanTalk.repos(text: "acme/site and docs-toolkit", linked: ["/wt/a"], records: records)
            == ["/wt/a", "/src/docs-toolkit", "/src/site"])
        #expect(PlanTalk.repos(text: "the website", linked: [], records: records).isEmpty)
        #expect(PlanTalk.repos(text: "", linked: ["/a", "/a", "/b", "/c", "/d", "/e"], records: []).count == 4)
    }

    @Test func aTurnThroughAFakeAgentReadsTheReplyAndItsCost() async throws {
        let seen = Captured()
        let talker = PlanTalker(agent: "claude", command: "claude", model: "opus") { arguments, stdin, directory in
            await seen.set(arguments: arguments, stdin: stdin, directory: directory)
            return try await WizardFixtures.planner(arguments, stdin, directory)
        }
        var conversation = PlanConversation(turns: [PlanTurn(role: .you, text: "fix anchors")])
        let first = try await talker.turn(
            title: "Anchors survive page moves", statement: "", conversation: conversation, repos: ["/r/docs"]
        )
        #expect(first.reply.question.contains("Everywhere"))
        #expect(first.reply.options.count == 3)
        #expect(first.cost.dollars == 0.024)
        #expect(first.cost.model == "opus")
        #expect(await seen.directory == "/r/docs")
        conversation.turns.append(PlanTurn(role: .heed, text: first.reply.question, options: first.reply.options))
        _ = conversation.pick(0)
        let second = try await talker.turn(
            title: "Anchors survive page moves", statement: "", conversation: conversation, repos: ["/r/docs"]
        )
        #expect(second.reply.question.contains("fail the build"))
        #expect(await seen.stdin.contains("They answered: redirects in the toolkit"))

        let unsupported = PlanTalker(agent: "pi", command: "pi", model: nil) { _, _, _ in "" }
        await #expect(throws: PlanTalker.Failure.unsupported("pi")) {
            try await unsupported.turn(title: "x", statement: "", conversation: conversation, repos: [])
        }
        let rambling = PlanTalker(agent: "claude", command: "claude", model: nil) { _, _, _ in
            "{\"result\": \"I would rather not\"}"
        }
        await #expect(throws: PlanTalker.Failure.self) {
            try await rambling.turn(title: "x", statement: "", conversation: conversation, repos: [])
        }
    }

    // MARK: Panel

    @Test func fourAlwaysSitAndTheRestComeFromWhatTheGoalTouches() {
        let always = PanelInvites.invite(signals: [])
        #expect(always.map(\.id) == ["skeptic", "purist", "scope-keeper", "ux"])
        #expect(always.allSatisfy { $0.why == "always" })
        let anchors = PanelInvites.invite(
            plan: WizardFixtures.plan(3), statement: "anchors break when pages move. fix it in the toolkit", repos: []
        )
        #expect(anchors.map(\.id) == ["skeptic", "purist", "scope-keeper", "ux", "dx", "newcomer", "adversary"])
        #expect(anchors.first { $0.id == "dx" }?.why == "public package")
        #expect(anchors.first { $0.id == "adversary" }?.why == "changes behaviour")
    }

    @Test func eachSignalInvitesItsPersona() {
        let cases: [(String, PanelInvites.Signal, String)] = [
            ("publish the sdk to npm", .publicPackage, "newcomer"),
            ("the parser accepts tabs", .behaviourChange, "adversary"),
            ("deploy the queue worker", .service, "operator"),
            ("a new settings screen in SwiftUI", .ui, "accessibility"),
            ("refresh the OAuth token", .authNet, "security"),
            ("search p95 under 200 ms", .hotPath, "performance"),
        ]
        for (text, signal, persona) in cases {
            let found = PanelInvites.signals(in: text)
            #expect(found.contains(signal), "\(text)")
            #expect(PanelInvites.invite(signals: found).contains { $0.id == persona }, "\(text)")
        }
        // Whole words: "views" is a view, "reviews" is not; "fast" alone is a hot path, "breakfast" is not.
        #expect(!PanelInvites.signals(in: "reviews over breakfast").contains(.ui))
        #expect(!PanelInvites.signals(in: "reviews over breakfast").contains(.hotPath))
    }

    @Test func yourTeamsStyleSitsOnceLearned() {
        let style = Persona(name: "Our team style", knows: ["small PRs"])
        let library = [Persona(name: "Release engineer"), style]
        #expect(PanelInvites.teamStyle(in: library) == style)
        let panel = PanelInvites.invite(signals: [], teamStyle: style)
        #expect(panel.last?.why == "your team's style")
        #expect(PanelInvites.teamStyle(in: [Persona(name: "Release engineer")]) == nil)
        let offered = PanelInvites.candidates(library: library, seated: panel)
        #expect(!offered.contains { $0.id == "skeptic" || $0.id == style.id })
        #expect(offered.contains { $0.id == "release-engineer" })
        #expect(offered.contains { $0.id == "operator" && $0.why == "you invited" })
    }

    @Test func verdictsAreReadByIdOrNameInThePanelsOrder() {
        let seats = PanelInvites.invite(signals: [.publicPackage])
        let verdicts = PanelVerdict.parse("""
        {"verdicts": [
          {"persona": "DX", "verdict": "Concern", "quote": "\\"Needs a setting.\\"", "fix": "+ setting"},
          {"persona": "skeptic", "verdict": "no", "quote": "Don't.", "fix": "go smaller"},
          {"persona": "ux", "verdict": "lgtm", "quote": "Fine.", "fix": "null"},
          {"persona": "ghost", "verdict": "happy", "quote": "?"},
          {"persona": "purist", "verdict": "meh", "quote": "?"},
          {"persona": "skeptic", "verdict": "happy", "quote": "twice"}
        ]}
        """, seats: seats)
        #expect(verdicts.map(\.seat) == ["skeptic", "ux", "dx"])
        #expect(verdicts[0].kind == .not)
        #expect(verdicts[0].quote == "Don't.")
        #expect(verdicts[1].fix == nil)
        #expect(verdicts[2] == PanelVerdict(seat: "dx", kind: .concern, quote: "Needs a setting.", fix: "+ setting"))
        #expect(PanelVerdict.parse("nothing", seats: seats).isEmpty)
    }

    @Test func worthItRereadsWhileFixesAndRoundsAreLeft() {
        var panel = PanelState(seats: PanelInvites.invite(signals: []))
        #expect(!panel.settled)
        panel.rounds = [[
            PanelVerdict(seat: "skeptic", kind: .not, quote: "q", fix: "go smaller"),
            PanelVerdict(seat: "ux", kind: .happy, quote: "q"),
        ]]
        #expect(panel.next == .reread(["go smaller"]))
        #expect(panel.count(.not) == 1)
        panel.rounds.append(panel.rounds[0])
        panel.rounds.append(panel.rounds[0])
        // Three rounds: on, whatever is left.
        #expect(panel.next == .advance)
        #expect(panel.settled)
        panel.rounds = [[PanelVerdict(seat: "ux", kind: .happy, quote: "q")]]
        #expect(panel.next == .advance)
        #expect(panel.settled)
    }

    // MARK: Done looks like

    @Test func checkabilityScoresChecksAndWords() {
        #expect(DoneCriterion("x", check: CriterionCheck(.test, "XTests")).checkability == 1)
        #expect(DoneCriterion("x", check: CriterionCheck(.test, "XTests", proposed: true)).checkability == 0.5)
        #expect(DoneCriterion("old links feel fast").checkability == 0)
        #expect(DoneCriterion("old links feel fast").vague)
        #expect(!DoneCriterion("old links feel fast", check: CriterionCheck(.command, "bench")).vague)
        #expect(DoneCriterion("a moved link answers in < 50 ms").checkability == 0.25)
        #expect(!Checkability.vague("a moved link answers fast, under 50 ms"))
        #expect(DoneCriterion("redirects resolve").checkability == 0.1)
        let tally = Checkability.tally(WizardFixtures.done().criteria)
        #expect(tally.checked == 3 && tally.proposed == 1 && tally.unchecked == 1)
        #expect(Checkability.kinds(WizardFixtures.done().criteria) == "2 tests · 1 CI step · 1 command")
    }

    @Test func criteriaGoIntoDoneWhenAndReadBack() {
        let draft = WizardFixtures.done()
        let before = GoalDoc(title: "T", doneWhen: [
            GoalDoc.Criterion("every redirect lands on a real heading", met: true, evidence: "#12"),
        ])
        let doc = draft.apply(to: before)
        #expect(doc.goal == draft.statement)
        #expect(doc.doneWhen[0].text == "every redirect lands on a real heading (check: test RedirectTargetsTests)")
        #expect(doc.doneWhen[0].met && doc.doneWhen[0].evidence == "#12")
        #expect(doc.doneWhen[3].text.hasSuffix("(check: test proposed BackfillResumeTests)"))
        #expect(doc.doneWhen[4].text == "old links feel fast")
        let reread = GoalDoc.parse(doc.render()).doneWhen.map(DoneDraft.read)
        #expect(reread == draft.criteria)
    }

    @Test func draftsAndReplacementsAreParsed() throws {
        let draft = try #require(DoneDraft.parse("""
        {"statement": "S.", "criteria": [{"text": "a", "check": "ci", "target": "build"}, "b",
        {"text": "c", "check": {"kind": "test", "target": "CTests", "proposed": true}}], "notTheGoal": ["z"]}
        """, fromPlan: 4))
        #expect(draft.criteria == [
            DoneCriterion("a", check: CriterionCheck(.ci, "build")), DoneCriterion("b"),
            DoneCriterion("c", check: CriterionCheck(.test, "CTests", proposed: true)),
        ])
        #expect(draft.notTheGoal == ["z"])
        #expect(draft.fromPlan == 4)
        #expect(draft.firstVague == 1)
        #expect(!draft.allCheckable)
        #expect(DoneDraft.parse("{\"criteria\": []}", fromPlan: nil) == nil)
        let replacements = DoneDraft.parseReplacements("""
        {"replacements": ["answers in < 50 ms", "feels snappy", "one redirect, never a chain", "x", "y"]}
        """)
        #expect(replacements == ["answers in < 50 ms", "one redirect, never a chain", "x"])
    }

    @Test func replacingAndDroppingKeepTheReplacementsInLine() {
        var draft = WizardFixtures.done()
        #expect(draft.replacements(for: 4)?.count == 3)
        draft.drop(0)
        #expect(draft.replacements(for: 3)?.count == 3)
        #expect(draft.replacements(for: 4) == nil)
        draft.replace(3, with: "a moved link answers in < 50 ms, p95")
        #expect(draft.replacements(for: 3) == nil)
        #expect(draft.criteria[3].text == "a moved link answers in < 50 ms, p95")
    }

    // MARK: TL;DR

    @Test func theTLDRsInputsSummariseEachStepAndListWhatIsOpen() {
        let wizard = WizardFixtures.wizard(at: .split)
        let inputs = TLDRInputs.build(wizard, doc: nil, goalVersion: 3)
        #expect(inputs.title == "Anchors survive page moves")
        #expect(inputs.steps.map(\.step) == WizardStep.allCases)
        #expect(inputs.steps[0].headline == "4 steps · 4 answers")
        #expect(inputs.steps[0].detail == "v5 · opus · 3 turns")
        #expect(inputs.steps[1].headline == "3 of 7 happy")
        #expect(inputs.steps[1].detail == "Skeptic overruled: worth it")
        #expect(inputs.steps[2].headline == "5 criteria · 1 vague")
        #expect(inputs.steps[3].detail == "on the goal's page for now")
        #expect(inputs.open.first?.action == .define(criterion: 4))
        #expect(inputs.open.contains { $0.text.hasPrefix("The Skeptic still says") && $0.action == nil })
        // Worth it: the other doubts were answered by the fixes; only the overruled Skeptic stays open.
        #expect(!inputs.open.contains { $0.text.hasPrefix("The DX") })
        #expect(TLDRInputs.build(WizardFixtures.wizard(at: .panel), doc: nil, goalVersion: 1).open
            .count(where: { $0.action == .panel }) == 4)
        #expect(inputs.settled.contains { $0.hasPrefix("Done = 5 checks") })
        #expect(inputs.settled.contains("Out: search index, renaming headings."))
        #expect(inputs.going == nil)
        #expect(inputs.prompt.contains("1. Criterion 5 is vague"))
        // Something changes: a new fingerprint, so the cached TL;DR is stale.
        let tldr = WizardTLDR.plain(inputs, at: t0)
        #expect(tldr.fresh(for: inputs))
        var changed = wizard
        changed.criteria.replace(4, with: "a moved link is one redirect")
        #expect(!tldr.fresh(for: TLDRInputs.build(changed, doc: nil, goalVersion: 3)))
        #expect(!tldr.fresh(for: TLDRInputs.build(wizard, doc: nil, goalVersion: 4)))
    }

    @Test func theModelsTLDRKeepsHeedsActionsAndFallsBackToHeedsWords() {
        let inputs = TLDRInputs.build(WizardFixtures.wizard(at: .split), doc: nil, goalVersion: 1)
        let written = WizardTLDR.parse("""
        {"settled": ["Anchors move in **batches**."], "open": ["Define criterion 5.", ""]}
        """, inputs: inputs, writtenBy: "haiku", seconds: 2, at: t0)
        #expect(written.settled == ["Anchors move in **batches**."])
        #expect(written.open[0] == WizardOpenPoint("Define criterion 5.", action: .define(criterion: 4)))
        #expect(written.open[1].text == inputs.open[1].text)
        #expect(written.writtenBy == "haiku")
        let garbled = WizardTLDR.parse("sorry", inputs: inputs, writtenBy: "haiku", seconds: 1, at: t0)
        #expect(garbled.writtenBy == "heed")
        #expect(garbled.settled == Array(inputs.settled.prefix(4)))
        let markdown = written.markdown(title: inputs.title)
        #expect(markdown.hasPrefix("# TL;DR: Anchors survive page moves\n"))
        #expect(markdown.contains("3. **Done looks like**: 5 criteria · 1 vague (2 tests · 1 CI step · 1 command)"))
        #expect(markdown.contains("## Open\n\n1. Define criterion 5."))
        #expect(!markdown.contains("Where it's going"))
        #expect(WizardAction.define(criterion: 4).command.arguments == ["5"])
    }

    @Test func theScriptedCallsAnswerEveryWizardCall() async throws {
        let calls = WizardCalls(run: WizardFixtures.calls)
        let plan = WizardFixtures.plan(4)
        let (completeness, _) = try await calls.score(plan: plan, turns: WizardFixtures.wizard(at: .plan).plan.turns)
        #expect(completeness.overall > 0)
        let seats = PanelInvites.invite(plan: plan, statement: "fix it in the toolkit", repos: [])
        let (verdicts, cost) = try await calls.panel(plan: plan, seats: seats)
        #expect(verdicts.count == seats.count)
        #expect(cost.step == .panel)
        let (fixed, _) = try await calls.apply(fixes: ["+ setting"], to: plan)
        #expect(fixed.decisions.contains("delete the website's slug copy"))
        let (smaller, _) = try await calls.smaller(plan, hint: nil)
        #expect(smaller.steps.count == 2)
        let (draft, _) = try await calls.draftDone(plan: plan, version: 4)
        #expect(draft.criteria == WizardFixtures.done().criteria)
        let (replacements, _) = try await calls.replacements(for: "old links feel fast", plan: plan)
        #expect(replacements == WizardFixtures.replacements)
    }
}

private actor Captured {
    var arguments: [String] = []
    var stdin = ""
    var directory = ""

    func set(arguments: [String], stdin: String, directory: String) {
        self.arguments = arguments
        self.stdin = stdin
        self.directory = directory
    }
}
