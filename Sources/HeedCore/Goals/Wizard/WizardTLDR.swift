import Foundation

/// Something the TL;DR's Open list can do about a point: the command it runs with `d` or a click.
public enum WizardAction: Hashable, Sendable, Codable {
    /// Make a vague criterion measurable (step 3, that criterion).
    case define(criterion: Int)
    /// Back to the panel.
    case panel
    /// Back to the plan conversation.
    case plan

    /// The command and its arguments.
    public var command: (name: String, arguments: [String]) {
        switch self {
        case let .define(criterion): ("wizard.define", [String(criterion + 1)])
        case .panel: ("wizard.step", ["panel"])
        case .plan: ("wizard.step", ["plan"])
        }
    }

    /// The button's words.
    public var label: String {
        switch self {
        case let .define(criterion): "define \(criterion + 1)"
        case .panel: "back to the panel"
        case .plan: "back to the plan"
        }
    }
}

/// A point still open, numbered in the TL;DR, with what to do about it.
public struct WizardOpenPoint: Hashable, Sendable, Codable {
    public var text: String
    public var action: WizardAction?

    public init(_ text: String, action: WizardAction? = nil) {
        self.text = text
        self.action = action
    }
}

/// Where the work is going, once Split knows: time, money, agents, when it ends, and the longest chain by agent. Nil
/// until a later part fills it in; the TL;DR leaves the section out then.
public struct WizardGoing: Hashable, Sendable, Codable {
    public var hours: Double?
    public var dollars: Double?
    public var agents: Int?
    public var endsAt: Date?
    /// The longest chain of parts, each by the agent that does it, in order.
    public var chain: [String]

    public init(
        hours: Double? = nil, dollars: Double? = nil, agents: Int? = nil, endsAt: Date? = nil, chain: [String] = []
    ) {
        self.hours = hours
        self.dollars = dollars
        self.agents = agents
        self.endsAt = endsAt
        self.chain = chain
    }
}

/// One step's line in the TL;DR's stepper.
public struct WizardStepSummary: Hashable, Sendable, Codable {
    public var step: WizardStep
    /// `4 phases · 6 answers`.
    public var headline: String
    /// `v5 · opus · 4 turns`.
    public var detail: String

    public init(step: WizardStep, headline: String, detail: String) {
        self.step = step
        self.headline = headline
        self.detail = detail
    }
}

/// What the TL;DR is written from: the goal's title, each step's summary, the facts that are settled and the points
/// still open (each with its action). The cheap model rewrites the settled facts and open points shorter; the numbers
/// and actions are heed's.
public struct TLDRInputs: Hashable, Sendable {
    public var title: String
    public var steps: [WizardStepSummary]
    public var settled: [String]
    public var open: [WizardOpenPoint]
    public var going: WizardGoing?
    /// Changes when anything here could: the wizard's fingerprint and the GOAL.md version.
    public var fingerprint: String
    /// Steps finished, for news since the TL;DR was last opened.
    public var completed = 0

    /// What you have seen, to keep when the TL;DR opens.
    public var seen: TLDRSeen { TLDRSeen(completed: completed, open: open.map(\.text)) }

    /// What the TL;DR's entry shows: news since `seen` (a step finished, an open point you have not seen), how many
    /// points are open, and whether one needs you (it has something to do).
    public func badge(since seen: TLDRSeen?) -> TLDRBadge {
        let known = Set(seen?.open ?? [])
        let news = seen == nil || completed > (seen?.completed ?? 0) || open.contains { !known.contains($0.text) }
        return TLDRBadge(news: news, open: open.count, needsYou: open.contains { $0.action != nil })
    }

    /// There is something to summarise: the wizard's first plan, or a goal that says what it is or when it is done.
    /// Before that the TL;DR's entry does not show.
    public static func available(_ wizard: GoalWizard?, doc: GoalDoc?) -> Bool {
        if let wizard { return !wizard.plan.versions.isEmpty }
        guard let doc else { return false }
        return !doc.goal.isEmpty || !doc.doneWhen.isEmpty
    }

    /// The inputs for a goal from its wizard and its `GOAL.md`.
    public static func build(_ wizard: GoalWizard, doc: GoalDoc?, goalVersion: Int) -> TLDRInputs {
        let plan = wizard.plan.current ?? doc.map(WizardPlan.read)
        var steps: [WizardStepSummary] = []
        let heedTurns = wizard.plan.turns.count { $0.role == .heed }
        steps.append(WizardStepSummary(
            step: .plan,
            headline: plan.map { plan in
                "\(plural(plan.steps.count, "step")) · \(plural(wizard.plan.answers, "answer"))"
            } ?? "not started",
            detail: [
                wizard.plan.versions.last.map { "v\($0.number)" }, wizard.model(for: .plan),
                heedTurns > 0 ? plural(heedTurns, "turn") : nil,
            ].compactMap(\.self).joined(separator: " · ")
        ))
        let panel = wizard.panel
        let happy = panel.count(.happy)
        steps.append(WizardStepSummary(
            step: .panel,
            headline: panel.latest.isEmpty ? "not read yet" : "\(happy) of \(panel.latest.count) happy",
            detail: panel.overruled.map { _ in "Skeptic overruled: worth it" }
                ?? (panel.rounds.isEmpty ? "" : "round \(panel.rounds.count)/\(PanelState.maxRounds)")
        ))
        let criteria = wizard.criteria.criteria
        let unchecked = criteria.count { $0.check.kind == .none }
        steps.append(WizardStepSummary(
            step: .done,
            headline: criteria.isEmpty ? "not drafted"
                : "\(criteria.count) criteri\(criteria.count == 1 ? "on" : "a") · "
                + (unchecked == 0 ? "all checkable" : "\(unchecked) vague"),
            detail: Checkability.kinds(criteria)
        ))
        for step in [WizardStep.split, .careful, .go] {
            steps.append(WizardStepSummary(
                step: step, headline: wizard.state(of: step) == .done ? "done" : "not yet",
                detail: step.built ? "" : "on the goal's page for now"
            ))
        }

        var settled: [String] = []
        if let plan, !plan.summary.isEmpty { settled.append(plan.summary) }
        settled += (plan?.decisions ?? []) + (doc?.decisions.filter { $0.source != "plan" }.map(\.text) ?? [])
        if !criteria.isEmpty {
            settled.append("Done = \(criteria.count) checks" + (Checkability.kinds(criteria).isEmpty ? "" :
                    ": " + Checkability.kinds(criteria)) + ".")
        }
        let out = wizard.criteria.notTheGoal.isEmpty ? plan?.outOfScope ?? [] : wizard.criteria.notTheGoal
        if !out.isEmpty { settled.append("Out: " + out.joined(separator: ", ") + ".") }

        var open: [WizardOpenPoint] = []
        for (index, criterion) in criteria.enumerated() where criterion.check.kind == .none {
            let text = criterion.vague
                ? "Criterion \(index + 1) is vague: \"\(criterion.text)\" has no check yet."
                : "Nothing checks criterion \(index + 1) yet: \"\(criterion.text)\"."
            open.append(WizardOpenPoint(text, action: .define(criterion: index)))
        }
        // Before you decided, every doubt is open; once you said worth it, only the Skeptic you overruled is.
        let doubts = panel.latest.filter { verdict in
            verdict.kind != .happy && (panel.decision == nil || verdict.seat == PanelInvites.skeptic.id)
        }
        for verdict in doubts {
            let name = panel.seats.first { $0.id == verdict.seat }?.name ?? verdict.seat
            let quote = verdict.quote.trimmingCharacters(in: CharacterSet(charactersIn: ".!"))
            open.append(WizardOpenPoint(
                "The \(name) still says \"\(quote)\"" +
                    (panel.decision == .worthIt ? "; you said it's worth it." : "."),
                action: panel.decision == nil ? .panel : nil
            ))
        }
        for question in doc?.openQuestions ?? [] {
            open.append(WizardOpenPoint(question, action: .plan))
        }
        if wizard.plan.completeness?.enough == false, wizard.state(of: .plan) == .done,
           let weakest = wizard.plan.completeness?.weakest
        {
            open.append(WizardOpenPoint("The plan is thin on \(weakest.label).", action: .plan))
        }
        return TLDRInputs(
            title: plan?.title ?? doc?.title ?? wizard.goal, steps: steps, settled: Array(settled.prefix(6)),
            open: Array(open.prefix(5)), going: nil, fingerprint: wizard.fingerprint + "@\(goalVersion)",
            completed: wizard.completed.count
        )
    }

    static func plural(_ count: Int, _ word: String) -> String { "\(count) \(word)\(count == 1 ? "" : "s")" }

    /// The cheap model's input.
    public var prompt: String {
        var lines = ["Goal: \(title)", "", "Steps:"]
        lines += steps.map { "- \($0.step.title): \($0.headline)" + ($0.detail.isEmpty ? "" : " (\($0.detail))") }
        lines += ["", "Settled:"] + settled.map { "- \($0)" }
        lines += ["", "Open (keep this order and count):"] + open.enumerated()
            .map { "\($0.offset + 1). \($0.element.text)" }
        return lines.joined(separator: "\n")
    }

    public static let system = """
    You write the TL;DR of a software goal being planned, for the developer who owns it, from heed's facts. Rewrite \
    the settled facts as at most four short sentences, the most important first, plain words, bold (**) on at most \
    one key word each. Rewrite each open point as one short actionable sentence, in the same order and count. Only \
    facts from the input. Reply with only JSON: {"settled": ["..."], "open": ["..."]}.
    """
}

/// What the TL;DR showed when you last opened it: how many steps were finished, and its open points.
public struct TLDRSeen: Hashable, Sendable, Codable {
    public var completed: Int
    public var open: [String]

    public init(completed: Int, open: [String]) {
        self.completed = completed
        self.open = open
    }
}

/// The TL;DR's entry in the rail: a dot or count when there is news, amber when an open point needs you.
public struct TLDRBadge: Hashable, Sendable {
    public var news: Bool
    public var open: Int
    public var needsYou: Bool
}

/// The TL;DR as written, cached until what it was written from changes.
public struct WizardTLDR: Hashable, Sendable, Codable {
    public var steps: [WizardStepSummary]
    public var settled: [String]
    public var open: [WizardOpenPoint]
    public var going: WizardGoing?
    /// Who wrote it (a model, or `heed` when no model could), and how long it took.
    public var writtenBy: String
    public var seconds: Double?
    public var at: Date
    public var fingerprint: String

    public init(
        steps: [WizardStepSummary], settled: [String], open: [WizardOpenPoint], going: WizardGoing? = nil,
        writtenBy: String, seconds: Double? = nil, at: Date, fingerprint: String
    ) {
        self.steps = steps
        self.settled = settled
        self.open = open
        self.going = going
        self.writtenBy = writtenBy
        self.seconds = seconds
        self.at = at
        self.fingerprint = fingerprint
    }

    /// heed's own TL;DR from the inputs as they are: what shows while the model writes, and when it cannot.
    public static func plain(_ inputs: TLDRInputs, at: Date) -> WizardTLDR {
        WizardTLDR(
            steps: inputs.steps, settled: Array(inputs.settled.prefix(4)), open: inputs.open, going: inputs.going,
            writtenBy: "heed", at: at, fingerprint: inputs.fingerprint
        )
    }

    /// The model's rewrite over heed's facts: its settled sentences, its open points on heed's actions by position.
    /// Points it left out keep heed's words; a reply heed cannot read gives heed's own TL;DR.
    public static func parse(
        _ text: String, inputs: TLDRInputs, writtenBy: String, seconds: Double?, at: Date
    ) -> WizardTLDR {
        var result = plain(inputs, at: at)
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return result }
        let settled = (object["settled"] as? [Any] ?? []).compactMap { ($0 as? String).map(GoalDoc.oneLine) }
            .filter { !$0.isEmpty }
        let open = (object["open"] as? [Any] ?? []).compactMap { ($0 as? String).map(GoalDoc.oneLine) }
        if !settled.isEmpty { result.settled = Array(settled.prefix(4)) }
        for (index, line) in open.enumerated() where result.open.indices.contains(index) && !line.isEmpty {
            result.open[index].text = line
        }
        result.writtenBy = writtenBy
        result.seconds = seconds
        return result
    }

    /// Still true to the goal.
    public func fresh(for inputs: TLDRInputs) -> Bool { fingerprint == inputs.fingerprint }

    /// `y`: the TL;DR as markdown.
    public func markdown(title: String) -> String {
        var lines = ["# TL;DR: \(title)", ""]
        for summary in steps {
            let detail = summary.detail.isEmpty ? "" : " (\(summary.detail))"
            lines.append("\(summary.step.number). **\(summary.step.title)**: \(summary.headline)\(detail)")
        }
        lines += ["", "## Settled", ""] + settled.map { "- \($0)" }
        if !open.isEmpty {
            lines += ["", "## Open", ""] + open.enumerated().map { "\($0.offset + 1). \($0.element.text)" }
        }
        if let going {
            lines += ["", "## Where it's going", ""]
            if let hours = going.hours { lines.append("- ~\(Int(hours.rounded())) h") }
            if let dollars = going.dollars { lines.append("- \(AgentUsage.dollars(dollars))") }
            if let agents = going.agents { lines.append("- \(agents) agents") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
