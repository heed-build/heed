import Foundation

/// `[decisions]`: who answers heed's typed questions (`Decider`).
public struct DecisionSettings: Equatable, Sendable {
    public enum Choice: String, CaseIterable, Sendable {
        /// Apple's on-device model: free, private, on this Mac only.
        case local
        /// A model call through `[llm]`.
        case model
        /// No decisions: what asks one goes without.
        case off
    }

    /// `decider`; nil: not chosen yet, which asks a model call as before and reminds you to choose.
    public var decider: Choice?

    public init(decider: Choice? = nil) {
        self.decider = decider
    }

    /// What answers now.
    public var effective: Choice { decider ?? .model }
}

/// Whether Apple's on-device model can run on this Mac (FoundationModels' availability, read by the app).
public enum LocalModel: String, Equatable, Sendable {
    case available
    case notEnabled
    case notReady
    case notEligible
    /// Before macOS 26, or a build without FoundationModels.
    case unsupported

    public var ready: Bool { self == .available }

    public var description: String {
        switch self {
        case .available: "Apple's on-device model is ready."
        case .notEnabled: "Turn on Apple Intelligence to use it."
        case .notReady: "Apple's on-device model is still downloading."
        case .notEligible: "This Mac cannot run Apple's on-device model."
        case .unsupported: "Needs macOS 26 with Apple Intelligence."
        }
    }
}

/// `[decisions] decider = "off"`: every question goes unanswered, and what asked goes on without.
public struct OffDecider: Decider {
    public init() {}

    public func decide(subject _: String, state _: String, questions _: [String: Question]) async throws
        -> [String: Answer]
    {
        throw DeciderError.off
    }
}

/// The Decider over a small local model that picks rather than weighs: for each question one option (or true/false)
/// and how sure it is (low, medium, high), turned into probabilities here. The model itself is asked by `ask`
/// (Apple's on-device model in the app, a fake in tests). Every decision writes a `decide` row, like `LLMDecider`.
public struct LocalDecider: Decider {
    /// One field the model fills: one of `options`.
    public struct Field: Equatable, Sendable {
        public var name: String
        public var description: String
        public var options: [String]
    }

    /// What the model is asked: its instructions, the prompt, and the fields of its answer in order.
    public struct Prompt: Equatable, Sendable {
        public var instructions: String
        public var prompt: String
        public var fields: [Field]
    }

    /// Fills the fields: field name → the option picked.
    public typealias Ask = @Sendable (Prompt) async throws -> [String: String]

    private let ask: Ask
    private let caller: String

    public init(caller: String, ask: @escaping Ask) {
        self.ask = ask
        self.caller = caller
    }

    /// How sure, as the model says it, and what that counts as.
    public static let confidences: [(String, Double)] = [("low", 0.5), ("medium", 0.7), ("high", 0.9)]
    /// The agent and model a local decision is logged with.
    public static let agent = "local"
    public static let model = "apple-on-device"

    static let instructions = """
    You judge the state of a piece of software work and answer questions about it. For each question pick one option, \
    and say how sure you are. Judge only from the state given.
    """

    public static func prompt(state: String, questions: [String: Question]) -> Prompt {
        var fields: [Field] = []
        for id in questions.keys.sorted() {
            let question = questions[id]!
            switch question {
            case let .choice(instructions, options):
                fields.append(Field(name: id, description: instructions, options: options))
            case let .score(instructions, levels):
                fields.append(Field(name: id, description: instructions + " (lowest to highest)", options: levels))
            case let .noul(instructions):
                fields.append(Field(name: id, description: "Is this true? " + instructions, options: ["true", "false"]))
            }
            fields.append(Field(
                name: id + "_confidence", description: "How sure you are of \(id)",
                options: confidences.map(\.0)
            ))
        }
        // The state is the prompt; the questions travel in the fields' descriptions.
        return Prompt(instructions: instructions, prompt: "State:\n" + state, fields: fields)
    }

    /// The model's pick and how sure it was, as an `Answer`: the pick gets the confidence (never below 0.5, so never
    /// below an even share), the other options share the rest; a score's level is the expected one.
    public static func answer(_ question: Question, pick: String?, confidence: String?) throws -> Answer {
        let sure = confidences.first { $0.0 == confidence }?.1 ?? confidences[0].1
        switch question {
        case let .choice(_, options), let .score(_, options):
            guard let pick, let picked = options.firstIndex(of: pick) else {
                throw DeciderError.badAnswer("\(pick ?? "nothing") is not one of the options")
            }
            let top = options.count == 1 ? 1 : sure
            let rest = options.count == 1 ? 0 : (1 - top) / Double(options.count - 1)
            let shares = options.indices.map { $0 == picked ? top : rest }
            var answer = Answer(
                choice: pick, probabilities: Dictionary(uniqueKeysWithValues: zip(options, shares)), confidence: sure
            )
            if case .score = question {
                answer.score = shares.enumerated().reduce(0) { $0 + Double($1.offset) * $1.element }
            }
            return answer
        case .noul:
            guard pick == "true" || pick == "false" else {
                throw DeciderError.badAnswer("\(pick ?? "nothing") is not true or false")
            }
            let probability = pick == "true" ? sure : 1 - sure
            return Answer(
                probability: probability, probabilities: ["true": probability, "false": 1 - probability],
                confidence: sure
            )
        }
    }

    public func decide(subject: String, state: String, questions: [String: Question]) async throws -> [String: Answer] {
        guard !questions.isEmpty else { throw DeciderError.noQuestions }
        let ids = questions.keys.sorted()
        let started = Date()
        var detail = ["subject": subject, "state": LoggedCall.truncated(state) ?? ""]
        func log(_ error: Error?) {
            CallLog.record(LoggedCall(
                at: started, kind: .decide, caller: caller, command: "decide",
                duration: Date().timeIntervalSince(started), failed: error != nil, stderr: error.map { "\($0)" },
                operation: "decide " + ids.joined(separator: ", "), agent: Self.agent, model: Self.model,
                detail: detail
            ))
        }
        do {
            let picks = try await ask(Self.prompt(state: state, questions: questions))
            var answers: [String: Answer] = [:]
            for id in ids {
                answers[id] = try Self.answer(questions[id]!, pick: picks[id], confidence: picks[id + "_confidence"])
            }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            detail["answers"] = (try? encoder.encode(answers)).map { String(decoding: $0, as: UTF8.self) }
            log(nil)
            return answers
        } catch {
            log(error)
            throw error
        }
    }
}
