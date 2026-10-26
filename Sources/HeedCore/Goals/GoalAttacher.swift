import Foundation

/// What set heed looking for a thing's goal.
public enum AttachTrigger: String, Hashable, Sendable, Codable, CaseIterable {
    /// A session or chat started.
    case started
    /// Its first prompt became known.
    case prompt
    /// It tracks a PR it did not before.
    case pull
    /// Its ledger entry was written (files touched, a summary).
    case ledger
    /// You asked (`goal.attach.find`).
    case asked

    /// Which triggers a change of the domain fires: new sessions and chats, a first prompt, a PR tracked.
    public static func of(before: Domain, after: Domain) -> [(String, AttachTrigger)] {
        let old = Dictionary(before.sessions.map { ($0.id, $0) }) { first, _ in first }
        var found: [(String, AttachTrigger)] = []
        for session in after.sessions {
            guard let was = old[session.id] else {
                found.append((session.id, session.prompt.isEmpty ? .started : .prompt))
                continue
            }
            if was.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !session.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                found.append((session.id, .prompt))
            } else if session.trackedPRs.contains(where: { !was.trackedPRs.contains($0) }) {
                found.append((session.id, .pull))
            }
        }
        return found
    }
}

/// Asks a model which goal a thing belongs to: a `choice` over the candidate goals and "none", with the goals' text and
/// the thing's as state. Logged as a `decide` row with subject `goal-attach:<kind>:<id>`.
public enum AttachQuestion {
    public static let id = "goal"

    public static func subject(_ subject: AttachSubject) -> String { "goal-attach:\(subject.key)" }

    /// The goals asked about: the candidates the signals found, best first, at most four.
    public static func goals(_ candidates: [AttachCandidate]) -> [String] {
        Array(candidates.prefix(4).map(\.goal))
    }

    public static func question(goals: [String]) -> Question {
        .choice(
            instructions: "Which goal does this work belong to? Pick none when it fits none of them well.",
            options: goals + [AttachOpinion.none]
        )
    }

    /// The state the model reads: the work, then each goal with its statement and what the signals saw.
    public static func state(
        _ subject: AttachSubject, candidates: [AttachCandidate], contexts: [GoalContext]
    ) -> String {
        var lines = ["Work (\(subject.kind.rawValue)): \(subject.title)"]
        if !subject.repos.isEmpty { lines.append("Repos: \(subject.repos.joined(separator: ", "))") }
        if !subject.branch.isEmpty { lines.append("Branch: \(subject.branch)") }
        let prompt = subject.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        if !prompt.isEmpty { lines.append("First prompt: \(String(prompt.prefix(1200)))") }
        if !subject.files.isEmpty { lines.append("Files touched: \(subject.files.prefix(20).joined(separator: ", "))") }
        lines.append("")
        for candidate in candidates.prefix(4) {
            guard let context = contexts.first(where: { $0.goal.id == candidate.goal }) else { continue }
            lines.append("Goal \(candidate.goal): \(context.doc.title)")
            if !context.doc.goal.isEmpty { lines.append("  Goal: \(String(context.doc.goal.prefix(600)))") }
            if !context.doc.notTheGoal.isEmpty {
                lines.append("  Not the goal: \(context.doc.notTheGoal.joined(separator: "; "))")
            }
            lines.append("  Signals: \(candidate.reason)")
        }
        return lines.joined(separator: "\n")
    }

    public static func opinion(_ answer: Answer) -> AttachOpinion {
        AttachOpinion(
            probabilities: answer.probabilities, confidence: answer.confidence,
            choice: answer.choice ?? AttachOpinion.none
        )
    }
}

/// One look for a thing's goal, end to end: rules, signals, the model when unsure, the decision. Pure but for the
/// model call, which goes through the `Decider` it is given (none: signals alone).
public enum GoalAttacher {
    public struct Outcome: Sendable {
        public var verdict: AttachVerdict
        public var candidates: [AttachCandidate]
        public var opinion: AttachOpinion?
        /// Why the model was not heard when it was wanted (off, failed, over budget).
        public var modelError: String?
    }

    public static func decide(
        _ subject: AttachSubject, contexts: [GoalContext], rules: AttachRules, settings: AttachSettings,
        decider: (any Decider)?, now: Date
    ) async -> Outcome {
        let titles = Dictionary(contexts.map { ($0.goal.id, $0.goal.title) }) { first, _ in first }
        let ruling = rules.ruling(subject, goals: Set(contexts.map(\.goal.id)))
        let candidates = AttachSignals.score(subject, goals: contexts, now: now)
            .filter { !ruling.excluded.contains($0.goal) }
        var opinion: AttachOpinion?
        var modelError: String?
        if !ruling.ignored, ruling.goal == nil, AttachPolicy.needsModel(candidates, settings: settings) {
            if settings.model, let decider {
                let goals = AttachQuestion.goals(candidates)
                do {
                    let answers = try await decider.decide(
                        subject: AttachQuestion.subject(subject),
                        state: AttachQuestion.state(subject, candidates: candidates, contexts: contexts),
                        questions: [AttachQuestion.id: AttachQuestion.question(goals: goals)]
                    )
                    opinion = answers[AttachQuestion.id].map(AttachQuestion.opinion)
                } catch {
                    modelError = "\(error)"
                }
            } else {
                modelError = settings.model ? "model calls are off" : "attach_model is off"
            }
        }
        let verdict = AttachPolicy.decide(
            ruling: ruling, candidates: candidates, opinion: opinion, settings: settings, titles: titles
        )
        return Outcome(verdict: verdict, candidates: candidates, opinion: opinion, modelError: modelError)
    }
}
