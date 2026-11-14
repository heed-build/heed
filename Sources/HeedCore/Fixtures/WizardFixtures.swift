import Foundation

/// The new-goal wizard in the fake world: a goal part-way through it (for shots, at any step), and scripted answers for
/// its model calls, so shots and the tutor run the real code paths with no model. Invented, as every fixture is.
public enum WizardFixtures {
    public static let goalID = "fix-anchors-redirects"
    static let ask = "anchors break when pages move. fix it everywhere"

    // MARK: The goal and its wizard

    /// The goal the wizard shots show, just made.
    public static func goal(now: Date = Clock.now) -> GoalFixture {
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 1800)
        let doc = plan(3).apply(to: GoalDoc.new(title: "Anchors survive page moves", statement: ask))
        let goal = HeedGoal(id: goalID, title: doc.title, createdAt: at, version: 1)
        return GoalFixture(
            goal: goal, versions: [GoalVersion(goal: goalID, number: 1, at: at, text: doc.render(), note: "plan v3")],
            links: []
        )
    }

    /// The plan at version `number` (1…5).
    static func plan(_ number: Int) -> WizardPlan {
        var plan = WizardPlan(
            title: "Anchors survive page moves",
            summary: "A page that moves keeps every inbound anchor working, and the build stops a broken one before "
                + "it ships.",
            steps: [
                "one slug function",
                "warn, then fail on broken anchors",
                "301s for moved pages",
                "a sample site proves it",
            ],
            constraints: ["no change to how URLs are shaped"],
            risks: ["~12 pages break the build today"],
            audience: number >= 4 ? "docs authors and readers following old links" : "",
            outOfScope: ["search index", "renaming headings"],
            decisions: ["redirects in the toolkit and old links on the website", "warn first, fail after cleanup"]
        )
        if number < 3 { plan.steps = Array(plan.steps.prefix(number + 1)) }
        if number >= 5 { plan.decisions.append("delete the website's slug copy") }
        return plan
    }

    /// The goal's wizard at `step`, with everything before it done as in the designs.
    public static func wizard(at step: WizardStep, now: Date = Clock.now) -> GoalWizard {
        var wizard = GoalWizard(goal: goalID, at: now.addingTimeInterval(-1800))
        wizard.plan.turns = [
            PlanTurn(role: .you, text: ask),
            PlanTurn(
                role: .heed, text: "\"Everywhere\" could mean three things. Which?",
                options: ["redirects in the toolkit", "old links on the website", "links from other sites"],
                picked: [0, 1], model: "opus"
            ),
            PlanTurn(role: .you, text: "the first two"),
            PlanTurn(
                role: .heed, text: "A broken anchor: fail the build, or warn? Failing breaks ~12 pages today.",
                options: ["fail", "warn, then fail after cleanup", "only warn"], picked: [1], model: "opus"
            ),
            PlanTurn(role: .you, text: "warn, then fail after cleanup"),
            PlanTurn(
                role: .heed, text: "The website vendors an old slug copy. Delete it?",
                options: ["yes, delete", "keep, sync", "ask its owners"], model: "opus"
            ),
        ]
        for number in 1 ... 3 {
            wizard.plan.add(plan(number), goalVersion: number == 3 ? 1 : nil)
        }
        wizard.plan.completeness = Completeness([
            .scope: 90, .constraints: 75, .risks: 50, .audience: 40, .outOfScope: 85,
        ])
        wizard.spent(WizardCost(step: .plan, agent: "claude", model: "opus", dollars: 0.07))
        guard step > .plan else { return wizard }

        wizard.plan.turns[5].picked = [0]
        wizard.plan.turns.append(PlanTurn(role: .you, text: "yes, delete"))
        wizard.plan.add(plan(4), goalVersion: nil)
        wizard.plan.completeness = Completeness([
            .scope: 92, .constraints: 80, .risks: 70, .audience: 72, .outOfScope: 88,
        ])
        wizard.advance(at: now)
        wizard.panel.seats = PanelInvites.invite(signals: [.publicPackage, .behaviourChange])
        wizard.panel.rounds = [verdicts(round: 1)]
        wizard.spent(WizardCost(step: .panel, agent: "claude", model: "haiku", dollars: 0.01))
        guard step > .panel else { return wizard }

        wizard.plan.add(plan(5), goalVersion: nil)
        wizard.panel.decision = .worthIt
        wizard.panel.overruled = verdicts(round: 1).first?.quote
        wizard.advance(at: now)
        wizard.criteria = done()
        wizard.spent(WizardCost(step: .done, agent: "claude", model: "opus", dollars: 0.02))
        guard step > .done else { return wizard }
        wizard.advance(at: now)
        return wizard
    }

    static func verdicts(round: Int) -> [PanelVerdict] {
        [
            PanelVerdict(
                seat: "skeptic", kind: .not,
                quote: "Should we do this at all? A link checker in CI gets 90% for a tenth of the work.",
                fix: round == 1 ? "go smaller: link checker only" : nil
            ),
            PanelVerdict(
                seat: "purist",
                kind: round == 1 ? .not : .happy,
                quote: "Two slug functions is the bug. Delete the copy.",
                fix: round == 1 ? "answer: delete" : nil
            ),
            PanelVerdict(seat: "scope-keeper", kind: .happy, quote: "Skip the search index, as agreed."),
            PanelVerdict(seat: "ux", kind: .happy, quote: "Errors name the file and line. Fine."),
            PanelVerdict(
                seat: "dx",
                kind: round == 1 ? .concern : .happy,
                quote: "How do I turn on failing per repo? Needs a setting.",
                fix: round == 1 ? "+ setting" : nil
            ),
            PanelVerdict(seat: "newcomer", kind: .happy, quote: "The warning says what to do."),
            PanelVerdict(
                seat: "adversary",
                kind: round == 1 ? .concern : .happy,
                quote: "Unicode and duplicate headings collide.",
                fix: round == 1 ? "+ case to step 1" : nil
            ),
        ]
    }

    static func done() -> DoneDraft {
        var draft = DoneDraft(
            statement: "A page that moves keeps every inbound anchor working, and the build stops a broken one "
                + "before it ships.",
            criteria: [
                DoneCriterion(
                    "every redirect lands on a real heading",
                    check: CriterionCheck(.test, "RedirectTargetsTests")
                ),
                DoneCriterion(
                    "a moved heading fails CI with file and line", check: CriterionCheck(
                        .ci,
                        "docs build · step anchors"
                    )
                ),
                DoneCriterion(
                    "a moved page in the sample site keeps its anchors",
                    check: CriterionCheck(.command, "sample-site · make check")
                ),
                DoneCriterion(
                    "the backfill resumes where it stopped",
                    check: CriterionCheck(.test, "BackfillResumeTests", proposed: true)
                ),
                DoneCriterion("old links feel fast"),
            ],
            notTheGoal: ["search index", "renaming headings"], fromPlan: 5
        )
        draft.set(replacements: replacements, for: 4)
        return draft
    }

    static let replacements = [
        "a moved link answers in < 50 ms, p95", "a moved link is one redirect, never a chain",
        "drop it: speed isn't the goal",
    ]

    // MARK: Scripted answers

    /// heed's model calls in the fake world: each wizard call answered from the script by its operation.
    public static let calls: WizardCalls.Run = { request in
        let operation = request.operation ?? ""
        let text: String
        var model = "haiku"
        switch operation {
        case "wizard completeness":
            let answers = request.call.prompt.components(separatedBy: "\nA: ").count - 1
            let base = min(40 + answers * 15, 92)
            text = """
            {"scope": \(min(base + 10, 95)), "constraints": \(base), "risks": \(max(base - 20, 30)), \
            "audience": \(max(base - 25, 30)), "outOfScope": \(min(base + 5, 90))}
            """
        case "wizard panel":
            let prompt = request.call.prompt
            let round = prompt.contains("delete the website's slug copy") || prompt.contains("the panel's fixes taken")
                ? 2 : 1
            let seats = PanelInvites.invite(signals: PanelInvites.signals(in: request.call.prompt))
            let verdicts = verdicts(round: round).filter { verdict in seats.contains { $0.id == verdict.seat } }
            let known = Set(verdicts.map(\.seat))
            let rows = verdicts.map(json) + seats.filter { !known.contains($0.id) }.map { seat in
                json(PanelVerdict(seat: seat.id, kind: .happy, quote: "Fine by me as planned."))
            }
            text = "{\"verdicts\": [\(rows.joined(separator: ", "))]}"
        case "wizard fixes", "wizard smaller":
            let title = request.call.prompt.components(separatedBy: "\n").first { $0.hasPrefix("Title: ") }?
                .dropFirst(7) ?? "The plan"
            var next = title.contains("Anchors") ? plan(5) : generic(String(title), answers: 3)
            if operation == "wizard smaller" {
                next.steps = Array(next.steps.prefix(2))
                next.outOfScope.append("everything past the first two steps")
            } else {
                next.decisions.append("the panel's fixes taken")
            }
            text = planJSON(next)
        case "wizard persona chat":
            text = "Show me the cheaper way failing first, then I'll say worth it."
        case "wizard done looks like":
            model = "opus"
            text = """
            {"statement": "\(done().statement)", "criteria": [\
            {"text": "every redirect lands on a real heading", "check": "test", "target": "RedirectTargetsTests"}, \
            {"text": "a moved heading fails CI with file and line", "check": "ci", "target": "docs build · step anchors"}, \
            {"text": "a moved page in the sample site keeps its anchors", "check": "command", \
            "target": "sample-site · make check"}, \
            {"text": "the backfill resumes where it stopped", "check": "test", "target": "BackfillResumeTests", \
            "proposed": true}, \
            {"text": "old links feel fast", "check": "none"}], "notTheGoal": ["search index", "renaming headings"]}
            """
        case "wizard replacements":
            text = "{\"replacements\": [\(replacements.map { "\"\($0)\"" }.joined(separator: ", "))]}"
        default:
            text = "{}"
        }
        return LLMResponse(text: text, agent: "claude", model: model, cost: model == "opus" ? 0.02 : 0.003)
    }

    /// The planner in the fake world: the next scripted question for the conversation it is given, as claude's JSON.
    public static let planner: PlanTalker.Exec = { _, stdin, _ in
        let answers = stdin.components(separatedBy: "They answered: ").count - 1
        let title = stdin.components(separatedBy: "\n").first { $0.hasPrefix("Title: ") }
            .map { String($0.dropFirst(7)) }
            ?? "The goal"
        let reply: (question: String, options: [String], plan: WizardPlan)
        if title.lowercased().contains("anchor") {
            let script: [(String, [String])] = [
                (
                    "\"Everywhere\" could mean three things. Which?",
                    ["redirects in the toolkit", "old links on the website", "links from other sites"]
                ),
                (
                    "A broken anchor: fail the build, or warn? Failing breaks ~12 pages today.",
                    ["fail", "warn, then fail after cleanup", "only warn"]
                ),
                ("The website vendors an old slug copy. Delete it?", ["yes, delete", "keep, sync", "ask its owners"]),
                ("Who follows old links most: readers, or other sites' crawlers?", ["readers", "crawlers", "both"]),
            ]
            let step = script[min(answers, script.count - 1)]
            reply = (step.0, step.1, plan(min(answers + 1, 5)))
        } else {
            let script: [(String, [String])] = [
                ("Who is this for first?", ["you", "your team", "everyone using it"]),
                ("When it goes wrong, should it fail or warn?", ["fail", "warn first", "only log"]),
                (
                    "What must not change while you do it?",
                    ["the public API", "the config file", "nothing in particular"]
                ),
                ("Is anything here out of scope already?", ["the docs", "the UI", "no"]),
            ]
            let step = script[min(answers, script.count - 1)]
            reply = (step.0, step.1, generic(title, answers: answers))
        }
        let inner = """
        {"question": "\(escape(reply.question))", "options": [\(reply.options.map { "\"\(escape($0))\"" }
            .joined(separator: ", "))], "complete": \(answers >= 4), "plan": \(planJSON(reply.plan))}
        """
        let result: [String: Any] = [
            "type": "result", "result": inner, "total_cost_usd": 0.024, "modelUsage": ["opus": [:]],
        ]
        let data = try JSONSerialization.data(withJSONObject: result)
        return String(decoding: data, as: UTF8.self)
    }

    /// A plan for any goal, growing with the answers.
    static func generic(_ title: String, answers: Int) -> WizardPlan {
        let steps = [
            "find where it lives today",
            "change it in one place",
            "cover it with a test",
            "say what changed in the docs",
        ]
        return WizardPlan(
            title: title, summary: "\(title), checked by a test, with nothing else changing.",
            steps: Array(steps.prefix(min(answers + 2, steps.count))),
            constraints: answers >= 2 ? ["the public API stays as it is"] : [],
            risks: answers >= 1 ? ["callers that relied on the old behaviour"] : [],
            audience: answers >= 1 ? "the team that owns it" : "", outOfScope: answers >= 3 ? ["the UI"] : []
        )
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func json(_ verdict: PanelVerdict) -> String {
        let fix = verdict.fix.map { "\"\(escape($0))\"" } ?? "null"
        return "{\"persona\": \"\(verdict.seat)\", \"verdict\": \"\(verdict.kind.rawValue)\", "
            + "\"quote\": \"\(escape(verdict.quote))\", \"fix\": \(fix)}"
    }

    static func planJSON(_ plan: WizardPlan) -> String {
        func list(_ items: [String]) -> String { "[" + items.map { "\"\(escape($0))\"" }.joined(separator: ", ") + "]" }
        return """
        {"title": "\(escape(plan.title))", "summary": "\(escape(plan.summary))", "steps": \(list(plan.steps)), \
        "constraints": \(list(plan.constraints)), "risks": \(list(plan.risks)), "audience": "\(escape(plan
                .audience))", \
        "outOfScope": \(list(plan.outOfScope)), "decisions": \(list(plan.decisions))}
        """
    }
}
