import Foundation

/// The wizard's cheap model calls, through heed's model calls (`LLMRunner`, the cheap model, tools off): the meters
/// after each plan turn, the panel's verdicts, fixes and "go smaller" applied to the plan, the done-when draft,
/// measurable
/// replacements for a vague criterion, a persona's chat reply and the TL;DR. Each returns what it read and what it
/// cost.
public struct WizardCalls: Sendable {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse
    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    public static let caller = "goals.wizard"

    private func ask(
        _ system: String, _ prompt: String, step: WizardStep, operation: String
    ) async throws -> (text: String, cost: WizardCost, seconds: Double) {
        let response = try await run(LLMRequest(
            call: LLMCall(system: system, prompt: prompt), priority: .interactive, caller: Self.caller,
            operation: operation
        ))
        let cost = WizardCost(
            step: step, agent: response.agent, model: response.model,
            dollars: response.fromCache ? 0 : response.cost, estimated: response.costEstimated
        )
        return (response.text, cost, response.duration)
    }

    // MARK: Plan

    static let scoreSystem = """
    You score how complete a software plan is for coding agents to carry out without asking again, from the plan and \
    the conversation that made it. Score each of scope (what exactly changes), constraints (what must keep working, \
    limits), risks (what could go wrong and how it is handled), audience (who it is for) and outOfScope (what it is \
    not) from 0 to 100. Be strict: 90 or more only when an agent would need no question. Reply with only JSON: \
    {"scope": 0, "constraints": 0, "risks": 0, "audience": 0, "outOfScope": 0}.
    """

    public func score(plan: WizardPlan, turns: [PlanTurn]) async throws -> (Completeness, WizardCost) {
        let conversation = turns.map { ($0.role == .heed ? "Q: " : "A: ") + $0.text }.joined(separator: "\n")
        let answer = try await ask(
            Self.scoreSystem, PlanTalk.render(plan) + "\n\nConversation:\n" + conversation, step: .plan,
            operation: "wizard completeness"
        )
        guard let completeness = Completeness.parse(answer.text) else {
            throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text)
        }
        return (completeness, answer.cost)
    }

    // MARK: Panel

    static let panelSystem = """
    You are a panel of reviewers reading a software plan before any work starts. Each persona below reads it in its \
    own voice and gives a verdict: happy (go ahead), concern (go ahead if one thing changes) or not (do not do it like \
    this). Each says one short quote (at most fifteen words, first person, concrete) and, unless happy, one fix in at \
    most six words ("go smaller: link checker only", "+ case to step 1", "answer: delete"). Reply with only JSON: \
    {"verdicts": [{"persona": "<id>", "verdict": "happy|concern|not", "quote": "...", "fix": "..." or null}]}.
    """

    public func panel(plan: WizardPlan, seats: [PanelSeat]) async throws -> ([PanelVerdict], WizardCost) {
        let personas = seats.map { "- \($0.id) (\($0.name), \($0.role)): \($0.brief)" }.joined(separator: "\n")
        let answer = try await ask(
            Self.panelSystem, "# The plan\n" + PlanTalk.render(plan) + "\n\n# The personas\n" + personas,
            step: .panel, operation: "wizard panel"
        )
        let verdicts = PanelVerdict.parse(answer.text, seats: seats)
        guard !verdicts.isEmpty else { throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text) }
        return (verdicts, answer.cost)
    }

    static let reviseSystem = """
    You revise a software plan. Apply exactly the changes asked for and nothing else, keeping the plan's shape. Reply \
    with only JSON: {"title": "...", "summary": "...", "steps": ["..."], "constraints": ["..."], "risks": ["..."], \
    "audience": "...", "outOfScope": ["..."], "decisions": ["..."]}.
    """

    /// The plan with the panel's fixes in it.
    public func apply(fixes: [String], to plan: WizardPlan) async throws -> (WizardPlan, WizardCost) {
        try await revise(
            plan,
            asking: "Apply these fixes from the panel:\n" + fixes.map { "- \($0)" }
                .joined(separator: "\n"),
            operation: "wizard fixes"
        )
    }

    /// The plan cut down: the smallest version that still gets most of the value.
    public func smaller(_ plan: WizardPlan, hint: String?) async throws -> (WizardPlan, WizardCost) {
        try await revise(
            plan, asking: "Make the plan smaller: keep only what gets most of the value, move the rest to out of scope."
                + (hint.map { " The panel suggested: \($0)." } ?? ""), operation: "wizard smaller"
        )
    }

    private func revise(
        _ plan: WizardPlan,
        asking: String,
        operation: String
    ) async throws -> (WizardPlan, WizardCost) {
        let answer = try await ask(
            Self.reviseSystem, "# The plan\n" + PlanTalk.render(plan) + "\n\n# Change\n" + asking, step: .panel,
            operation: operation
        )
        guard let data = LLMDialect.jsonObject(in: answer.text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text) }
        return (WizardPlan.from(object, fallbackTitle: plan.title), answer.cost)
    }

    static let chatSystem = """
    You are one persona on a review panel for a software plan, talking with the developer who owns it. Stay in \
    character, answer their last message in at most three short sentences, concrete, and say what would change your \
    verdict.
    """

    public func reply(_ chat: PersonaChat, plan: WizardPlan) async throws -> (String, WizardCost) {
        let answer = try await ask(
            Self.chatSystem + "\n\nYou are: \(chat.seat.name), \(chat.seat.role). \(chat.seat.brief)",
            "# The plan\n" + PlanTalk.render(plan) + "\n\n# The conversation\n" + chat.transcript, step: .panel,
            operation: "wizard persona chat"
        )
        return (answer.text.trimmingCharacters(in: .whitespacesAndNewlines), answer.cost)
    }

    // MARK: Done looks like

    static let doneSystem = """
    You write what done looks like for an agreed software plan: a one-sentence statement of the outcome, three to six \
    done-when criteria each checkable by a machine and at most twelve words, and at most four things that are not the \
    goal, a few words each. For each criterion say how it is checked: test (target: the test's name only), ci (the \
    CI step's name), command (the command line) or none when nothing can check it yet (target empty); proposed true \
    when the test or step does not exist yet, rather than saying so in the target. Reply with only JSON: \
    {"statement": "...", \
    "criteria": [{"text": "...", "check": "test|ci|command|none", "target": "...", "proposed": false}], \
    "notTheGoal": ["..."]}.
    """

    public func draftDone(plan: WizardPlan, version: Int?) async throws -> (DoneDraft, WizardCost) {
        let answer = try await ask(
            Self.doneSystem, PlanTalk.render(plan), step: .done, operation: "wizard done looks like"
        )
        guard let draft = DoneDraft.parse(answer.text, fromPlan: version) else {
            throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text)
        }
        return (draft, answer.cost)
    }

    static let replaceSystem = """
    A done-when criterion of a software plan cannot be checked as written. Suggest up to three replacements a machine \
    can check: each with a number or a named thing to look at, at most twelve words. One of them may be dropping it \
    ("drop it: speed isn't the goal"). Reply with only JSON: {"replacements": ["..."]}.
    """

    public func replacements(for criterion: String, plan: WizardPlan) async throws -> ([String], WizardCost) {
        let answer = try await ask(
            Self.replaceSystem, "# The plan\n" + PlanTalk.render(plan) + "\n\n# The criterion\n" + criterion,
            step: .done, operation: "wizard replacements"
        )
        return (DoneDraft.parseReplacements(answer.text), answer.cost)
    }

    // MARK: Split

    static let splitSystem = """
    You split an agreed software plan into parts that coding agents can each finish in one go, in parallel where the \
    work allows. Each part is one pull request in one repo: a short title (at most six words), the repo it is in \
    (one of the repos listed, or null), its size (XS under 45 minutes, S under 90, M under 3 hours, L longer), an \
    estimate ("2h 30m"), the ids of the parts it must wait for (after), one to three done-when lines a machine can \
    check (at most twelve words each, taken from the goal's criteria where they fit), and its context: folders, \
    files, PRs or decisions its agent starts from. Put reviews and walk-throughs last. Use as few parts as the plan \
    needs: two to four for a small plan, at most sixteen. Reply with only JSON: {"parts": [{"id": "short-id", \
    "title": "...", "repo": "...", "size": "M", "estimate": "2h", "after": ["short-id"], "doneWhen": ["..."], \
    "context": ["..."]}]}.
    """

    /// The agreed plan and its done-when, split into parts (`SplitDraft`); assignment puts them on agents after.
    public func split(
        plan: WizardPlan, criteria: [String], repos: [String], goal: String, version: Int?
    ) async throws -> (SplitDraft, WizardCost) {
        let prompt = "# The plan\n" + PlanTalk.render(plan) + "\n\n# Done when\n"
            + criteria.map { "- \($0)" }.joined(separator: "\n")
            + "\n\n# Repos\n" + (repos.isEmpty ? "(none named)" : repos.map { "- \($0)" }.joined(separator: "\n"))
        let answer = try await ask(Self.splitSystem, prompt, step: .split, operation: "wizard split")
        do {
            return try (SplitDraft.parse(answer.text, goal: goal, fromPlan: version), answer.cost)
        } catch {
            throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text)
        }
    }

    /// One part split in two (`s`): the halves, the second after the first.
    public func split(part: SplitPart, plan: WizardPlan?, goal: String) async throws -> ([SplitPart], WizardCost) {
        let prompt = (plan.map { "# The plan\n" + PlanTalk.render($0) + "\n\n" } ?? "")
            + "# Split this part in two smaller parts, the second after the first\n" + part.title
            + "\nrepo: \(part.repo ?? "null") · estimate \(SwarmEstimate.text(part.minutes))\n"
            + part.task.doneWhen.map { "done when: \($0)" }.joined(separator: "\n")
        let answer = try await ask(Self.splitSystem, prompt, step: .split, operation: "wizard split part")
        guard let draft = try? SplitDraft.parse(answer.text, goal: goal), !draft.parts.isEmpty else {
            throw LLMError.unparseable(agent: answer.cost.agent, text: answer.text)
        }
        return (Array(draft.parts.prefix(2)), answer.cost)
    }

    // MARK: TL;DR

    public func tldr(_ inputs: TLDRInputs, now: Date) async throws -> (WizardTLDR, WizardCost) {
        let answer = try await ask(TLDRInputs.system, inputs.prompt, step: .plan, operation: "wizard tldr")
        let tldr = WizardTLDR.parse(
            answer.text, inputs: inputs, writtenBy: answer.cost.model ?? answer.cost.agent, seconds: answer.seconds,
            at: now
        )
        return (tldr, answer.cost)
    }
}
