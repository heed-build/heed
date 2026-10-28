import Foundation

/// A typed question about a state (a session, a PR), in the shapes a small local model can answer too: pick one of
/// some options, place it on an ordered scale, or say how likely something is true.
public enum Question: Hashable, Sendable {
    /// One of `options`.
    case choice(instructions: String, options: [String])
    /// One of `levels`, ordered from lowest to highest.
    case score(instructions: String, levels: [String])
    /// Whether the statement in `instructions` is true.
    case noul(instructions: String)

    public var instructions: String {
        switch self {
        case let .choice(instructions, _), let .score(instructions, _), let .noul(instructions): instructions
        }
    }

    var kind: String {
        switch self {
        case .choice: "choice"
        case .score: "score"
        case .noul: "noul"
        }
    }
}

/// An answer to a `Question`. `confidence` is the model's own, uncalibrated: keep it, but never let it gate an
/// irreversible action.
public struct Answer: Hashable, Sendable, Codable {
    /// choice: the most likely option; score: the most likely level; noul: nil.
    public var choice: String?
    /// score: the expected level, 0 for the first … count − 1 for the last.
    public var score: Double?
    /// noul: P(true).
    public var probability: Double?
    /// choice and score: per option or level, summing to 1; noul: "true" and "false".
    public var probabilities: [String: Double]
    /// 0…1.
    public var confidence: Double

    public init(
        choice: String? = nil, score: Double? = nil, probability: Double? = nil, probabilities: [String: Double],
        confidence: Double
    ) {
        self.choice = choice
        self.score = score
        self.probability = probability
        self.probabilities = probabilities
        self.confidence = confidence
    }
}

/// Answers typed questions about a state. The first implementation asks a model through the runner; a local model can
/// stand in later (plan 7). `subject` names what the state is about (a session or PR id): each decision is logged
/// with it, so what you do with that subject later can be joined to it.
public protocol Decider: Sendable {
    func decide(subject: String, state: String, questions: [String: Question]) async throws -> [String: Answer]
}

public enum DeciderError: Error, Equatable, Sendable, CustomStringConvertible {
    case noQuestions
    /// The answer was JSON, but not answers to the questions asked.
    case badAnswer(String)
    /// `[decisions] decider = "off"`.
    case off
    /// The decider chosen cannot run here (Apple's on-device model on a Mac without it); why.
    case unavailable(String)

    public var description: String {
        switch self {
        case .noQuestions: "nothing to decide"
        case let .badAnswer(why): "not an answer to the questions: \(why)"
        case .off: "decisions are off ([decisions] decider = \"off\")"
        case let .unavailable(why): "the local decider cannot run: \(why)"
        }
    }
}

/// The Decider over heed's model calls: one call with a JSON Schema for all the questions, native where the CLI
/// enforces one (claude, codex), read from the reply elsewhere. Every decision writes a `decide` row.
public struct LLMDecider: Decider {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse

    private let run: Run
    private let caller: String
    private let priority: LLMRequest.Priority

    /// `run` is how a call is made (`AppModel.runLLM` in the app, a runner's `run` in tests).
    public init(caller: String, priority: LLMRequest.Priority = .background, run: @escaping Run) {
        self.run = run
        self.caller = caller
        self.priority = priority
    }

    static let system = """
    You judge the state of a piece of software work and answer typed questions about it. For each question give \
    probabilities, not just a pick: spread them when the state does not settle the question, and say how confident \
    you are overall from 0 to 1. Judge only from the state given. Reply with only the JSON the schema asks for.
    """

    public func decide(subject: String, state: String, questions: [String: Question]) async throws -> [String: Answer] {
        guard !questions.isEmpty else { throw DeciderError.noQuestions }
        let ids = questions.keys.sorted()
        let request = LLMRequest(
            call: LLMCall(
                system: Self.system,
                prompt: Self.prompt(state: state, questions: questions),
                schema: Self.schema(questions)
            ),
            priority: priority, caller: caller, operation: "decide " + ids.joined(separator: ", ")
        )
        let started = Date()
        var detail = [
            "subject": subject,
            "questions": Self.json(questions.mapValues { $0.kind }) ?? "",
            "state": LoggedCall.truncated(state) ?? "",
        ]
        func log(_ response: LLMResponse?, error: Error?) {
            CallLog.record(LoggedCall(
                at: started, kind: .decide, caller: caller, command: "decide",
                duration: Date().timeIntervalSince(started),
                failed: error != nil, stderr: error.map { "\($0)" }, operation: request.operation,
                agent: response?.agent, model: response?.model,
                tokens: response?.fromCache == true ? nil : response?.tokens,
                cost: response?.fromCache == true ? nil : response?.cost,
                costEstimated: response?.costEstimated ?? false,
                detail: detail
            ))
        }
        var response: LLMResponse?
        do {
            response = try await run(request)
            guard let json = response?.json else { throw DeciderError.badAnswer("no JSON") }
            let answers = try Self.answers(json, questions: questions)
            detail["answers"] = Self.json(answers)
            if response?.fromCache == true { detail["cache"] = "hit" }
            log(response, error: nil)
            return answers
        } catch {
            log(response, error: error)
            throw error
        }
    }

    // MARK: The call

    static func prompt(state: String, questions: [String: Question]) -> String {
        var lines = ["State:", state, "", "Questions:"]
        for id in questions.keys.sorted() {
            let question = questions[id]!
            switch question {
            case let .choice(instructions, options):
                lines.append("- \(id) (pick one): \(instructions) Options: \(options.joined(separator: ", ")).")
            case let .score(instructions, levels):
                lines
                    .append(
                        "- \(id) (a level, lowest to highest): \(instructions) Levels: \(levels.joined(separator: ", "))."
                    )
            case let .noul(instructions):
                lines.append("- \(id) (how likely is this true): \(instructions)")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// One object per question: probabilities per option or level (or one probability), and a confidence.
    static func schema(_ questions: [String: Question]) -> String {
        let number: [String: Any] = ["type": "number", "minimum": 0, "maximum": 1]
        var properties: [String: Any] = [:]
        for (id, question) in questions {
            switch question {
            case let .choice(_, options), let .score(_, options):
                properties[id] = [
                    "type": "object",
                    "properties": [
                        "probabilities": [
                            "type": "object",
                            "properties": Dictionary(uniqueKeysWithValues: options.map { ($0, number) }),
                            "required": options, "additionalProperties": false,
                        ] as [String: Any],
                        "confidence": number,
                    ],
                    "required": ["probabilities", "confidence"], "additionalProperties": false,
                ] as [String: Any]
            case .noul:
                properties[id] = [
                    "type": "object", "properties": ["probability": number, "confidence": number],
                    "required": ["probability", "confidence"], "additionalProperties": false,
                ] as [String: Any]
            }
        }
        let schema: [String: Any] = [
            "type": "object", "properties": properties, "required": questions.keys.sorted(),
            "additionalProperties": false,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Reading the answer

    static func answers(_ json: Data, questions: [String: Question]) throws -> [String: Answer] {
        guard let object = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw DeciderError.badAnswer("not a JSON object")
        }
        func number(_ value: Any?) -> Double? {
            guard let value = value as? NSNumber, value.doubleValue.isFinite else { return nil }
            return min(1, max(0, value.doubleValue))
        }
        var answers: [String: Answer] = [:]
        for (id, question) in questions {
            guard let entry = object[id] as? [String: Any] else { throw DeciderError.badAnswer("\(id) missing") }
            let confidence = number(entry["confidence"]) ?? 0
            switch question {
            case let .choice(_, options), let .score(_, options):
                let given = entry["probabilities"] as? [String: Any] ?? [:]
                let raw = options.map { number(given[$0]) ?? 0 }
                let total = raw.reduce(0, +)
                guard total > 0 else { throw DeciderError.badAnswer("\(id) has no probabilities") }
                let normalized = raw.map { $0 / total }
                let probabilities = Dictionary(uniqueKeysWithValues: zip(options, normalized))
                // max(by:) keeps the first of equal ones: the order the question gave.
                let best = normalized.indices.max { normalized[$0] < normalized[$1] }!
                var answer = Answer(choice: options[best], probabilities: probabilities, confidence: confidence)
                if case .score = question {
                    answer.score = normalized.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
                }
                answers[id] = answer
            case .noul:
                guard let probability = number(entry["probability"]) else {
                    throw DeciderError.badAnswer("\(id) has no probability")
                }
                answers[id] = Answer(
                    probability: probability, probabilities: ["true": probability, "false": 1 - probability],
                    confidence: confidence
                )
            }
        }
        return answers
    }

    private static func json(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
