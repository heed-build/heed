import Foundation

/// Who answers a question when `[decisions] decider = "hunch"`.
public enum DecisionRoute: String, Equatable, Hashable, Sendable, CaseIterable {
    /// Hunch, on this Mac.
    case hunch
    /// Apple's on-device model.
    case local
    /// A model call through `[llm]`.
    case model
    /// Nothing can: the question goes unanswered.
    case none
}

/// Hunch answers the questions a Laya checkpoint is good at; the rest go elsewhere, by a rule the pane states.
///
/// A choice's heading and options share the checkpoint's head budget (192 tokens on the English checkpoint), so many
/// options, or long ones, get cut to a few tokens each, and the English checkpoint's calibration for 11 or more
/// options is unusable. Picking one of many names (a goal's items, reviewers' objections) is a job for a generative
/// model; yes/no statements, scales and a handful of short options are Hunch's.
public enum HunchRouting {
    /// A choice with more options than this goes elsewhere.
    public static let maxChoiceOptions = 5
    /// A scale with more levels than this goes elsewhere.
    public static let maxScoreLevels = 6
    /// An option or level longer than this (in characters) goes elsewhere.
    public static let maxOptionLength = 40

    /// Whether Hunch takes `question`.
    public static func hunchTakes(_ question: Question) -> Bool {
        switch question {
        case .noul: true
        case let .score(_, levels):
            levels.count <= maxScoreLevels && levels.allSatisfy { $0.count <= maxOptionLength }
        case let .choice(_, options):
            options.count <= maxChoiceOptions && options.allSatisfy { $0.count <= maxOptionLength }
        }
    }

    /// Where a question Hunch does not take goes: Apple's on-device model when this Mac has it, else a model call
    /// when model calls are on, else nowhere.
    public static func overflow(localReady: Bool, modelCalls: Bool) -> DecisionRoute {
        if localReady { return .local }
        return modelCalls ? .model : .none
    }

    /// Each question's route. Without a model ready, Hunch takes nothing: its questions go where the rest go.
    public static func routes(
        _ questions: [String: Question], hunchReady: Bool, localReady: Bool, modelCalls: Bool
    ) -> [String: DecisionRoute] {
        let elsewhere = overflow(localReady: localReady, modelCalls: modelCalls)
        return questions.mapValues { hunchReady && hunchTakes($0) ? .hunch : elsewhere }
    }

    /// The pane's sentence for the rule as it applies on this Mac now.
    public static func summary(localReady: Bool, modelCalls: Bool) -> String {
        let rest = switch overflow(localReady: localReady, modelCalls: modelCalls) {
        case .local: "Apple's on-device model"
        case .model: "a model call"
        case .hunch, .none: "nothing: they go unanswered"
        }
        return "Hunch answers yes/no statements, scales of up to \(maxScoreLevels) levels and choices of up to "
            + "\(maxChoiceOptions) short options (Attention's suggested weights). Choices among more or longer "
            + "options (a goal's items, reviewers' objections) go to \(rest)."
    }
}

/// The Decider for `[decisions] decider = "hunch"`: splits the questions by `HunchRouting`, asks each part of its
/// decider, and puts the answers back together. Each part writes its own `decide` row. A part that fails fails the
/// whole, as one decider's failure would.
public struct RoutedDecider: Decider {
    private let deciders: [DecisionRoute: any Decider]
    private let route: @Sendable ([String: Question]) -> [String: DecisionRoute]

    /// `deciders`: one per route that can answer; questions routed to `.none`, or to a route without one, go
    /// unanswered (`DeciderError.unavailable`).
    public init(
        deciders: [DecisionRoute: any Decider],
        route: @escaping @Sendable ([String: Question]) -> [String: DecisionRoute]
    ) {
        self.deciders = deciders
        self.route = route
    }

    public func decide(subject: String, state: String, questions: [String: Question]) async throws -> [String: Answer] {
        guard !questions.isEmpty else { throw DeciderError.noQuestions }
        var parts: [DecisionRoute: [String: Question]] = [:]
        for (id, route) in route(questions) {
            parts[route, default: [:]][id] = questions[id]
        }
        var answers: [String: Answer] = [:]
        for route in DecisionRoute.allCases {
            guard let part = parts[route] else { continue }
            guard let decider = deciders[route], route != .none else {
                throw DeciderError.unavailable(
                    "no decider can answer \(part.keys.sorted().joined(separator: ", ")) on this Mac"
                )
            }
            try await answers.merge(decider.decide(subject: subject, state: state, questions: part)) { $1 }
        }
        return answers
    }
}

/// The Decider over Hunch: answers come from `ask` (Hunch's `DecisionModel` in the app, a fake in tests) and every
/// decision writes a `decide` row, agent `hunch`, with the checkpoint and head it used.
public struct HunchDecider: Decider {
    /// Answers every question about the state.
    public typealias Ask = @Sendable (_ state: String, _ questions: [String: Question]) async throws -> [String: Answer]

    public static let agent = "hunch"

    private let ask: Ask
    private let caller: String
    /// `laya-english`, or `laya-english+head-…` with a trained head: logged as the model.
    private let model: String

    public init(caller: String, model: String, ask: @escaping Ask) {
        self.ask = ask
        self.caller = caller
        self.model = model
    }

    public func decide(subject: String, state: String, questions: [String: Question]) async throws -> [String: Answer] {
        guard !questions.isEmpty else { throw DeciderError.noQuestions }
        let ids = questions.keys.sorted()
        let started = Date()
        var detail = [
            "subject": subject,
            "questions": Self.json(questions.mapValues(\.kind)) ?? "",
            "state": LoggedCall.truncated(state) ?? "",
        ]
        func log(_ error: Error?) {
            CallLog.record(LoggedCall(
                at: started, kind: .decide, caller: caller, command: "decide",
                duration: Date().timeIntervalSince(started), failed: error != nil, stderr: error.map { "\($0)" },
                operation: "decide " + ids.joined(separator: ", "), agent: Self.agent, model: model, detail: detail
            ))
        }
        do {
            let answers = try await ask(state, questions)
            for id in ids where answers[id] == nil {
                throw DeciderError.badAnswer("\(id) missing")
            }
            detail["answers"] = Self.json(answers)
            log(nil)
            return answers.filter { questions[$0.key] != nil }
        } catch {
            log(error)
            throw error
        }
    }

    private static func json(_ value: some Encodable) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }
}
