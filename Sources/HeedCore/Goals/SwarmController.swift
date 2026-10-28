import Foundation

/// The controller: heed's deciders (Settings › Inference & decisions: Hunch for small choices, the rest routed as
/// everywhere) answering a swarm's question within its authority. A repeat of a question you answered comes first (an
/// exact one needs no decider; a near one is a yes/no statement for it); then, if the question is the controller's,
/// it picks one of the asker's options. A question with no options, or one that is yours, it does not answer: on its
/// own it passes it to you, and when you ask it (`c`) about one of yours it only suggests.
///
/// Every decider call writes its own `decide` row (`LLMDecider`, `HunchDecider`); the caller writes the steering row.
public enum SwarmController {
    /// Who asked the controller.
    public enum Mode: Equatable, Sendable {
        /// The ladder reached it.
        case onItsOwn
        /// You handed it the question (`c` in Needs you or the plan).
        case askedByYou
    }

    public enum Outcome: Equatable, Sendable {
        /// It answers: the option it picked, and why in a few words.
        case answer(String, reason: String)
        /// A question you answered before asks the same: your answer again. `similar`: a near match a decider said
        /// is the same question, not the same words.
        case repeatOf(SwarmRepeat.Answered, answer: String, similar: Bool)
        /// The question is yours: what it would pick, for you to take or not.
        case suggest(String, reason: String)
        /// It does not answer: why (the question goes to you).
        case decline(String)
    }

    /// The decider's caller name, in the call log and its `decide` rows.
    public static let caller = "swarm.controller"

    /// The question as a decider is asked it: one of the asker's options, each with what it would change.
    public static func question(_ row: SwarmSteer) -> Question? {
        guard !row.options.isEmpty else { return nil }
        return .choice(
            instructions: "Pick the answer the project owner would most likely give to this question from an agent "
                + "working on their code: \(row.text)", options: row.options
        )
    }

    /// What the decider reads: who asks, the question, and what each choice would change. Only the row's own words,
    /// so a correction you make later (`HunchTrainingSet.swarm`) teaches on exactly what the controller read.
    public static func state(_ row: SwarmSteer) -> String {
        let asker = row.from.flatMap(SwarmAddress.init(raw:))?.label() ?? "an agent"
        var lines = ["An agent of a swarm working on the owner's code asks (\(asker)).", "Question: \(row.text)"]
        for (index, option) in row.options.enumerated() {
            let effect = row.effects.flatMap { $0.indices.contains(index) ? $0[index] : nil } ?? ""
            lines.append("Option \(option)" + (effect.isEmpty ? "" : ": \(effect)"))
        }
        return lines.joined(separator: "\n")
    }

    /// The controller's answer to `row`. `history`: your answers and rules (`SwarmRepeat.answered`). Never throws: a
    /// decider that fails or is off is a decline, and the question goes to you.
    public static func decide(
        _ row: SwarmSteer, category: SwarmAuthority.Category, history: [SwarmRepeat.Answered], decider: any Decider,
        mode: Mode = .onItsOwn
    ) async -> Outcome {
        let state = state(row)
        let subject = "swarm-question:\(row.swarm)#\(row.id ?? 0)"
        if SwarmAuthority.mayRepeat(category) {
            if let earlier = SwarmRepeat.exact(row.text, options: row.options, among: history),
               let answer = SwarmRepeat.answer(earlier, options: row.options)
            {
                return .repeatOf(earlier, answer: answer, similar: false)
            }
            let near = SwarmRepeat.near(row.text, options: row.options, among: history)
            if !near.isEmpty {
                var questions: [String: Question] = [:]
                for (index, earlier) in near.enumerated() {
                    questions["same\(index + 1)"] = SwarmRepeat.sameQuestion(row.text, earlier)
                }
                if let answers = try? await decider.decide(subject: subject, state: state, questions: questions) {
                    let best = near.enumerated().compactMap { index, earlier -> (SwarmRepeat.Answered, Double)? in
                        guard let probability = answers["same\(index + 1)"]?.probability,
                              probability >= SwarmRepeat.sameThreshold
                        else { return nil }
                        return (earlier, probability)
                    }.max { $0.1 < $1.1 }
                    if let best, let answer = SwarmRepeat.answer(best.0, options: row.options) {
                        return .repeatOf(best.0, answer: answer, similar: true)
                    }
                }
            }
        }
        let mayAnswer = switch mode {
        case .onItsOwn: category.controllerMay
        case .askedByYou: !category.alwaysYou
        }
        guard mayAnswer || mode == .askedByYou else {
            return .decline("\(category.title) is not the controller's to answer")
        }
        guard let question = question(row) else { return .decline("the question has no options to pick from") }
        let answers: [String: Answer]
        do {
            answers = try await decider.decide(subject: subject, state: state, questions: ["answer": question])
        } catch {
            return .decline("the controller could not decide: \(error)")
        }
        guard let choice = answers["answer"]?.choice, row.options.contains(choice) else {
            return .decline("the controller gave no answer")
        }
        let percent = Int(((answers["answer"]?.probabilities[choice] ?? 0) * 100).rounded())
        let reason = "\(percent)% for it"
        return mayAnswer ? .answer(choice, reason: reason) : .suggest(choice, reason: reason)
    }
}
