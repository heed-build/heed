import Foundation

/// What a Start work prompt is: a question (a chat), one session, or bigger than one session (a goal).
public enum TaskClass: String, CaseIterable, Sendable, Codable {
    case chat, session, goal
}

/// Rough size facts for a task that looks bigger than one session: the Start work card's stats. Rough on purpose:
/// they say "bigger than one session", not a plan.
public struct TaskSizeFacts: Hashable, Sendable {
    /// Parts it splits into.
    public var parts: Int
    /// Repos it touches.
    public var repos: Int
    /// Agents that could work on it at once.
    public var atOnce: Int
    /// Hours for one agent doing it all.
    public var hours: Double
    /// A short title for the goal, when the model gave one.
    public var title: String?

    public init(parts: Int, repos: Int, atOnce: Int, hours: Double, title: String? = nil) {
        self.parts = parts
        self.repos = repos
        self.atOnce = atOnce
        self.hours = hours
        self.title = title
    }

    /// One agent's time, as the card says it: `~30 min`, `3 h`, `1 day+`, `3 days+`. A working day is eight hours.
    public var time: (value: String, unit: String) {
        if hours < 1 { return ("~\(max(10, Int((hours * 60 / 10).rounded()) * 10))", "min") }
        if hours < 8 { return ("\(Int(hours.rounded()))", "h") }
        return ("\(Int(hours / 8))", Int(hours / 8) == 1 ? "day+" : "days+")
    }
}

/// What Start work made of a prompt, and what the call that made it cost (for the card's corner).
public struct TaskSizing: Hashable, Sendable {
    /// The prompt it sized, as `TaskSizer.key` keeps it.
    public var prompt: String
    public var kind: TaskClass
    /// How likely the decider found it bigger than one session.
    public var goal: Double
    /// Only asked for when a goal was likely.
    public var facts: TaskSizeFacts?
    /// The model that gave the facts, how long it took and what it cost.
    public var model: String?
    public var seconds: Double?
    public var cost: Double?

    public init(
        prompt: String, kind: TaskClass, goal: Double = 0, facts: TaskSizeFacts? = nil, model: String? = nil,
        seconds: Double? = nil, cost: Double? = nil
    ) {
        self.prompt = prompt
        self.kind = kind
        self.goal = goal
        self.facts = facts
        self.model = model
        self.seconds = seconds
        self.cost = cost
    }

    /// `haiku · 2 s · $0.001`: what sizing it took; nil when no model call gave the facts.
    public var callLabel: String? {
        guard let model else { return nil }
        var parts = [TaskSizer.shortModel(model)]
        if let seconds { parts.append(seconds < 1 ? "<1 s" : "\(Int(seconds.rounded())) s") }
        if let cost { parts.append(String(format: cost < 0.01 ? "$%.3f" : "$%.2f", cost)) }
        return parts.joined(separator: " · ")
    }
}

/// Sizes a Start work prompt: a `choice` question to the configured decider (on-device or Hunch first, a model call
/// behind them), and only when a goal looks likely, one cheap model call for the rough facts. Short prompts are never
/// sized: small tasks start exactly as they always did.
public enum TaskSizer {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse

    /// Fewer words than this is a small task: no question at all.
    public static let minimumWords = 12
    /// The facts are asked for from this likelihood of a goal up.
    static let likely = 0.35
    /// The card shows from this likelihood up, and only when the facts (if any) say more than one part.
    static let sure = 0.5

    /// The prompt as sizing keys it: words joined by single spaces. Typing a trailing space asks nothing new.
    public static func key(_ prompt: String) -> String {
        prompt.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Long enough to be worth a question.
    public static func worthSizing(_ prompt: String) -> Bool {
        prompt.split(whereSeparator: \.isWhitespace).count >= minimumWords
    }

    static let instructions = """
    How big is this piece of software work? chat: a question to answer or something to look up, no code change. \
    session: one coding agent can do it in one sitting in one repo, even if it takes a while. goal: it needs several \
    pieces of work, several pull requests or several repos, or more than a day of one agent's time.
    """

    /// The one question: which of the three.
    public static func question() -> [String: Question] {
        ["size": .choice(instructions: instructions, options: TaskClass.allCases.map(\.rawValue))]
    }

    /// The state the decider reads: the prompt, and the repos it would start in.
    public static func state(prompt: String, repos: [String]) -> String {
        var lines = ["Task: \(prompt)"]
        if !repos.isEmpty { lines.append("Repos it starts in: \(repos.joined(separator: ", "))") }
        return lines.joined(separator: "\n")
    }

    /// The decider's answer read as a class and the likelihood of a goal. No answer: a session (as Start work was).
    public static func classify(_ answer: Answer?) -> (kind: TaskClass, goal: Double) {
        guard let answer else { return (.session, 0) }
        let goal = answer.probabilities[TaskClass.goal.rawValue] ?? 0
        if goal >= sure { return (.goal, goal) }
        return (answer.choice.flatMap(TaskClass.init(rawValue:)) == .chat ? .chat : .session, goal)
    }

    // MARK: The facts

    static let factsSystem = """
    You size a piece of software work for the developer about to start it, roughly: how many parts it splits into \
    (each one pull request), how many repositories it touches, how many coding agents could work on it at once, how \
    many hours one agent would take for all of it, and a goal title of at most eight words, sentence case, no period. \
    Judge only from the task. Reply with only the JSON the schema asks for.
    """

    static let factsSchema = """
    {"type":"object","properties":{"parts":{"type":"integer","minimum":1,"maximum":20},\
    "repos":{"type":"integer","minimum":1,"maximum":10},"at_once":{"type":"integer","minimum":1,"maximum":10},\
    "hours":{"type":"number","minimum":0,"maximum":400},"title":{"type":"string"}},\
    "required":["parts","repos","at_once","hours","title"],"additionalProperties":false}
    """

    /// The facts call: cheap, and in the background queue so the daily cap applies.
    public static func factsRequest(prompt: String, repos: [String]) -> LLMRequest {
        LLMRequest(
            call: LLMCall(system: factsSystem, prompt: state(prompt: prompt, repos: repos), schema: factsSchema),
            priority: .background, caller: "work.size", operation: "size the task"
        )
    }

    /// The facts from the call's JSON; nil when they are not there. Numbers are kept in range.
    public static func facts(from json: Data?) -> TaskSizeFacts? {
        guard let json, let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return nil }
        func int(_ key: String, _ range: ClosedRange<Int>) -> Int? {
            (object[key] as? NSNumber).map { min(range.upperBound, max(range.lowerBound, $0.intValue)) }
        }
        guard let parts = int("parts", 1 ... 20), let hours = (object["hours"] as? NSNumber)?.doubleValue,
              hours.isFinite
        else { return nil }
        let title = (object["title"] as? String).map { GoalDoc.oneLine($0) }.flatMap { $0.isEmpty ? nil : $0 }
        return TaskSizeFacts(
            parts: parts, repos: int("repos", 1 ... 10) ?? 1, atOnce: int("at_once", 1 ... 10) ?? 1,
            hours: min(400, max(0, hours)), title: title
        )
    }

    /// `claude-haiku-4-5` → `haiku`; other names as given.
    static func shortModel(_ model: String) -> String {
        for family in ["haiku", "sonnet", "opus"] where model.lowercased().contains(family) {
            return family
        }
        return model
    }

    /// Sizes `prompt`: the decider's class, then the facts when a goal is likely. Nil when the decider could not
    /// answer (off, unavailable, failed): Start work then starts as it always did. A facts call that fails keeps the
    /// decider's verdict; facts that say one part make it a session after all.
    public static func size(
        prompt: String, repos: [String], decider: any Decider, run: Run
    ) async -> TaskSizing? {
        let key = key(prompt)
        guard worthSizing(key) else { return nil }
        let answers = try? await decider.decide(
            subject: "start-work", state: state(prompt: key, repos: repos), questions: question()
        )
        guard let answers else { return nil }
        let classified = classify(answers["size"])
        var kind = classified.kind
        let goal = classified.goal
        var sizing = TaskSizing(prompt: key, kind: kind, goal: goal)
        guard goal >= likely, !Task.isCancelled else { return sizing }
        if let response = try? await run(factsRequest(prompt: key, repos: repos)),
           let facts = facts(from: response.json)
        {
            sizing.facts = facts
            sizing.model = response.model ?? response.agent
            sizing.seconds = response.duration
            sizing.cost = response.cost
            if kind == .goal, facts.parts < 2 { kind = .session }
            if kind != .goal, facts.parts >= 3, facts.hours >= 8 { kind = .goal }
        }
        sizing.kind = kind
        return sizing
    }
}

/// Sizes the prompt once typing pauses, or at once (⌘↩): each new prompt cancels the one before, and an answer is
/// delivered only for the prompt still current. Typing never waits on it.
@MainActor
public final class TaskSizeScheduler {
    public typealias Size = @Sendable (String) async -> TaskSizing?
    private let size: Size
    private let debounce: Duration
    private var task: Task<Void, Never>?
    /// The prompt asked last (`TaskSizer.key`): asking it again does nothing, unless `now` hurries it.
    public private(set) var current: String?
    private var hurried = false

    public init(debounce: Duration = .milliseconds(700), size: @escaping Size) {
        self.size = size
        self.debounce = debounce
    }

    /// Sizes `key` after the pause (`now`: at once, even if it is already waiting); nil cancels. `deliver` gets the
    /// sizing, or nil when there is none. Returns the task, for tests to await.
    @discardableResult
    public func ask(
        _ key: String?, now: Bool = false, deliver: @escaping @MainActor (String, TaskSizing?) -> Void
    ) -> Task<Void, Never>? {
        guard key != current || (now && !hurried) else { return nil }
        task?.cancel()
        current = key
        hurried = now
        guard let key else { return nil }
        let size = size, debounce = debounce
        task = Task { [weak self] in
            if !now {
                do { try await Task.sleep(for: debounce) } catch { return }
            }
            let sizing = await size(key)
            guard !Task.isCancelled, let self, current == key else { return }
            deliver(key, sizing)
        }
        return task
    }

    /// The dialog closed: nothing more is delivered.
    public func cancel() {
        task?.cancel()
        task = nil
        current = nil
        hurried = false
    }
}
