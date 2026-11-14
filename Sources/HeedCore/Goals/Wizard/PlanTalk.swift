import Foundation

/// What the planner said back on one turn: its next question with options, the plan as it stands, and whether it
/// thinks the plan is complete enough.
public struct PlanReply: Hashable, Sendable {
    public var question: String
    public var options: [String]
    public var plan: WizardPlan
    public var complete: Bool

    public init(question: String, options: [String] = [], plan: WizardPlan, complete: Bool = false) {
        self.question = question
        self.options = options
        self.plan = plan
        self.complete = complete
    }
}

/// Step 1's conversation with a big model. Each turn is one headless run of your default agent on its strongest model,
/// read-only, in the goal's repos (it may read and search them, never change them), given the whole conversation so
/// far: a real multi-turn conversation that can look at the code, without an agent session kept open between turns or
/// saved in the agent's own history. It answers with JSON: one question at a time, up to three options, the plan as it
/// stands now.
///
/// Why a headless run and not heed's model calls (`LLMRunner`): those run tools off in an empty folder on the cheap
/// model, so they cannot read the repo. Why not the swarm's lead: that is a session in a tab with a worktree, made to
/// change code. A turn here costs one run; the cost is read from the agent's own report.
public enum PlanTalk {
    /// The strongest model to ask for, by agent; nil leaves the agent's own default (codex's is its strongest).
    public static func strongest(agent: String) -> String? {
        switch agent {
        case "claude": "opus"
        default: nil
        }
    }

    /// The folders a turn reads: the goal's sessions' worktrees first, then the main checkout of each repo the ask
    /// names (`docs-toolkit`, `acme/docs-toolkit`), at most four, none twice. Empty: the planner works from the words
    /// alone, and the step says so.
    public static func repos(text: String, linked: [String], records: [(slug: String, path: String)]) -> [String] {
        var result: [String] = []
        for path in linked where !result.contains(path) {
            result.append(path)
        }
        let words = Set(text.lowercased().split { !($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == "/") }
            .map(String.init))
        for record in records {
            let slug = record.slug.lowercased()
            let name = slug.split(separator: "/").last.map(String.init) ?? slug
            guard words.contains(slug) || words.contains(name), !result.contains(record.path) else { continue }
            result.append(record.path)
        }
        return Array(result.prefix(4))
    }

    /// How long one turn may take.
    public static let timeout: TimeInterval = 5 * 60

    /// Most questions heed asks before it says the plan is as complete as talking makes it.
    public static let maxQuestions = 12

    public static let system = """
    You help a developer turn a rough ask into a plan a team of coding agents can carry out without asking again. \
    You may read and search the repositories in your working directories to ground your questions; never change a \
    file. Ask ONE question at a time, the one whose answer changes the plan most, short and concrete, naming files or \
    numbers you found. Offer two or three short options a person would pick from (at most six words each) when the \
    answer is a choice; none when it is open. Keep the plan updated after every answer: a short title, a one or two \
    sentence summary of the outcome, three to six numbered steps (imperative, at most eight words each), constraints, \
    risks, who it is for, what is out of scope, and the decisions taken so far. Set complete to true when scope, \
    constraints, risks, audience and out of scope are clear enough for agents; then the question is a one-line \
    confirmation. Reply with only JSON, no prose and no code fence: {"question": "...", "options": ["..."], \
    "complete": false, "plan": {"title": "...", "summary": "...", "steps": ["..."], "constraints": ["..."], \
    "risks": ["..."], "audience": "...", "outOfScope": ["..."], "decisions": ["..."]}}
    """

    /// The turn's input: the goal, the plan as it stands, the conversation so far, and what to do next.
    public static func prompt(
        title: String, statement: String, turns: [PlanTurn], plan: WizardPlan?, repos: [String], weakest: String?
    ) -> String {
        var parts = ["# The ask", "Title: \(title)"]
        if !statement.isEmpty { parts.append(statement) }
        if !repos.isEmpty { parts += ["", "# Repositories (your working directories)", repos.joined(separator: "\n")] }
        if let plan {
            parts += ["", "# The plan so far", render(plan)]
        }
        if !turns.isEmpty {
            parts += ["", "# The conversation so far"]
            var asked = false
            for turn in turns {
                switch turn.role {
                case .heed:
                    let options = turn.options.isEmpty ? "" : " (options: \(turn.options.joined(separator: " | ")))"
                    parts.append("You asked: \(turn.text)\(options)")
                    asked = true
                case .you:
                    // What they said before any question is the ask itself, in their words.
                    parts.append((asked ? "They answered: " : "They said: ") + turn.text)
                }
            }
        }
        parts += ["", "# Now"]
        if turns.isEmpty {
            parts.append("Read what you need, write the first plan, and ask your first question.")
        } else {
            parts.append("Update the plan with their last answer and ask the next question.")
        }
        if let weakest { parts.append("The plan is weakest on \(weakest).") }
        return parts.joined(separator: "\n")
    }

    /// The plan as text, for a prompt.
    public static func render(_ plan: WizardPlan) -> String {
        var lines = ["Title: \(plan.title)"]
        if !plan.summary.isEmpty { lines.append("Summary: \(plan.summary)") }
        for (index, step) in plan.steps.enumerated() {
            lines.append("\(index + 1). \(step)")
        }
        func list(_ name: String, _ items: [String]) {
            if !items.isEmpty { lines.append("\(name): " + items.joined(separator: "; ")) }
        }
        list("Constraints", plan.constraints)
        list("Risks", plan.risks)
        if !plan.audience.isEmpty { lines.append("Who it is for: \(plan.audience)") }
        list("Out of scope", plan.outOfScope)
        list("Decisions", plan.decisions)
        return lines.joined(separator: "\n")
    }

    /// The planner's answer, read leniently: the JSON anywhere in the text, `options` as strings or `{label}`s, at most
    /// three kept. Nil when there is no JSON with a question or a plan in it.
    public static func parse(_ text: String, fallbackTitle: String) -> PlanReply? {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return nil }
        let question = GoalDoc.oneLine(object["question"] as? String ?? "")
        let options: [String] = ((object["options"] as? [Any]) ?? []).compactMap { option in
            if let text = option as? String { return GoalDoc.oneLine(text) }
            if let dict = option as? [String: Any] { return (dict["label"] ?? dict["text"]) as? String }
            return nil
        }
        .filter { !$0.isEmpty }
        let planObject = object["plan"] as? [String: Any]
        guard !question.isEmpty || planObject != nil else { return nil }
        let plan = WizardPlan.from(planObject ?? [:], fallbackTitle: fallbackTitle)
        let complete = (object["complete"] as? Bool) ?? ((object["complete"] as? String) == "true")
        return PlanReply(question: question, options: Array(options.prefix(3)), plan: plan, complete: complete)
    }

    /// The command line for one turn: the agent headless and read-only in `repos[0]`, the other repos added, the prompt
    /// on stdin. Nil for an agent heed cannot run this way (the turn then says so).
    public static func invocation(agent: String, command: String, model: String?, repos: [String]) -> [String]? {
        let words = command.split(separator: " ").map(String.init)
        guard let executable = words.first else { return nil }
        let extra = repos.dropFirst()
        switch agent {
        case "claude":
            // Its own system prompt stays (it is what makes the tools work); ours is appended. Read-only tools only,
            // nothing asked, nothing kept in claude's history.
            var arguments = [
                executable, "-p", "--output-format", "json", "--append-system-prompt", system,
                "--tools", "Read", "Grep", "Glob", "--permission-mode", "dontAsk", "--no-session-persistence",
                "--strict-mcp-config",
            ]
            for repo in extra {
                arguments += ["--add-dir", repo]
            }
            if let model { arguments += ["--model", model] }
            return arguments
        case "codex":
            var arguments = [executable, "exec", "--json", "--ephemeral", "-s", "read-only", "--skip-git-repo-check"]
            if let first = repos.first { arguments += ["-C", first] }
            for repo in extra {
                arguments += ["--add-dir", repo]
            }
            if let model { arguments += ["-m", model] }
            return arguments + ["-"]
        default:
            return nil
        }
    }

    /// What goes on stdin: codex has no system prompt flag, so ours goes in front.
    public static func stdin(agent: String, prompt: String) -> String {
        agent == "claude" ? prompt : system + "\n\n---\n\n" + prompt
    }

    /// The agent's output read as text, model, tokens and cost.
    public static func output(agent: String, stdout: String) throws -> LLMOutput {
        guard let dialect = LLMDialect(rawValue: agent) else { throw LLMOutputError("\(agent) cannot plan") }
        return try dialect.parse(stdout, schema: false)
    }
}

/// One planning turn run: the reply, and what it cost.
public struct PlanTurnResult: Sendable {
    public var reply: PlanReply
    public var cost: WizardCost

    public init(reply: PlanReply, cost: WizardCost) {
        self.reply = reply
        self.cost = cost
    }
}

/// Runs planning turns. `exec` runs a command (arguments, stdin, working directory) and returns its stdout; the app
/// passes a process runner, tests a fake, fixtures a scripted planner.
public struct PlanTalker: Sendable {
    public typealias Exec = @Sendable (_ arguments: [String], _ stdin: String, _ directory: String) async throws
        -> String

    let agent: String
    let command: String
    let model: String?
    let prices: UsagePrices
    let exec: Exec

    public init(
        agent: String,
        command: String,
        model: String?,
        prices: UsagePrices = UsagePrices(),
        exec: @escaping Exec
    ) {
        self.agent = agent
        self.command = command
        self.model = model
        self.prices = prices
        self.exec = exec
    }

    public enum Failure: Error, Equatable, CustomStringConvertible {
        case unsupported(String)
        case unreadable(String)

        public var description: String {
            switch self {
            case let .unsupported(agent): "\(agent) cannot plan headless here: set your default agent to claude or codex"
            case let .unreadable(text): "the planner did not answer with a plan: \(text.prefix(120))"
            }
        }
    }

    public func turn(
        title: String, statement: String, conversation: PlanConversation, repos: [String]
    ) async throws -> PlanTurnResult {
        guard let arguments = PlanTalk.invocation(agent: agent, command: command, model: model, repos: repos) else {
            throw Failure.unsupported(agent)
        }
        let weakest = conversation.completeness.map { $0.weakest.gap }
        let prompt = PlanTalk.prompt(
            title: title, statement: statement, turns: conversation.turns, plan: conversation.current, repos: repos,
            weakest: weakest
        )
        let stdout = try await exec(
            arguments, PlanTalk.stdin(agent: agent, prompt: prompt), repos.first ?? NSTemporaryDirectory()
        )
        let output = try PlanTalk.output(agent: agent, stdout: stdout)
        guard let reply = PlanTalk.parse(output.text, fallbackTitle: conversation.current?.title ?? title) else {
            throw Failure.unreadable(output.text)
        }
        let usedModel = output.model ?? model
        var dollars = output.cost
        var estimated = false
        if dollars == nil, let tokens = output.tokens, let usedModel {
            dollars = prices.estimate(AgentUsage(model: usedModel, tokens: tokens))
            estimated = dollars != nil
        }
        return PlanTurnResult(
            reply: reply,
            cost: WizardCost(step: .plan, agent: agent, model: usedModel, dollars: dollars, estimated: estimated)
        )
    }
}
