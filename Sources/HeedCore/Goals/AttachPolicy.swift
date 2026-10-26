import Foundation

/// `[goals]`' attachment keys: whether heed finds goals for new work, and how sure it must be to act.
public struct AttachSettings: Equatable, Sendable {
    /// `attach`: look for a goal when a session or chat starts, gets its first prompt, tracks a PR or gets a ledger
    /// entry.
    public var enabled = true
    /// `attach_auto`: at or above this, attach without asking (with undo).
    public var auto = 0.85
    /// `attach_ask`: at or above this (and below `auto`), ask with one key in Attention; below, leave it Unassigned.
    public var ask = 0.5
    /// `attach_model`: ask the cheap model when the signals are unsure or two goals are close.
    public var model = true

    public init(enabled: Bool = true, auto: Double = 0.85, ask: Double = 0.5, model: Bool = true) {
        self.enabled = enabled
        self.auto = auto
        self.ask = ask
        self.model = model
    }

    /// Two goals within this of each other are "close": heed asks the model, and never attaches on its own.
    public static let closeMargin = 0.1
}

/// What heed does with a thing: put it on a goal, ask you, or leave it.
public enum AttachAction: String, Hashable, Sendable, Codable {
    case attach, ask, leave, ignore
}

/// The model's say on a thing: a probability per goal and for "none", and how sure it is.
public struct AttachOpinion: Hashable, Sendable, Codable {
    public var probabilities: [String: Double]
    public var confidence: Double
    public var choice: String

    public init(probabilities: [String: Double], confidence: Double, choice: String) {
        self.probabilities = probabilities
        self.confidence = confidence
        self.choice = choice
    }

    public static let none = "none"
}

/// What heed decided and why: the action, the goal, how sure, in words, and the runner-up.
public struct AttachVerdict: Hashable, Sendable, Codable {
    public enum Basis: String, Hashable, Sendable, Codable {
        /// A line of `attach.rules`.
        case rule
        case signals
        /// Signals and the model's opinion, combined.
        case model
    }

    public var action: AttachAction
    public var goal: String?
    public var confidence: Double
    public var reason: String
    public var basis: Basis
    /// The next most likely goal, when there was one.
    public var alternative: String?

    public init(
        action: AttachAction, goal: String? = nil, confidence: Double = 0, reason: String, basis: Basis = .signals,
        alternative: String? = nil
    ) {
        self.action = action
        self.goal = goal
        self.confidence = confidence
        self.reason = reason
        self.basis = basis
        self.alternative = alternative
    }
}

/// How signals, the model and the thresholds make one decision. Deterministic, so the same inputs always act the
/// same way:
///
/// 1. Rules first (`AttachRules`): `ignore` leaves it alone, `always` attaches, `never` drops a goal.
/// 2. Signals score each remaining goal (`AttachSignals`).
/// 3. The model is asked (`needsModel`) only when the best goal is between `ask` and `auto`, or the two best are
///    within `closeMargin` with the best at `ask` or more.
/// 4. With its answer, each goal's confidence becomes `(1 − w)·signals + w·p(goal)`, `w = 0.6 × the model's
///    confidence`: the model moves a number, it never replaces one, and a goal no signal found is never picked.
/// 5. Act on the best: at `auto` or more, attach, unless another goal is within `closeMargin` (then ask); at `ask` or
///    more, ask; below, leave it.
public enum AttachPolicy {
    /// How much the model's opinion can weigh, at its full confidence.
    public static let modelWeight = 0.6

    /// Whether the signals leave enough doubt to spend a model call on.
    public static func needsModel(_ candidates: [AttachCandidate], settings: AttachSettings) -> Bool {
        guard let best = candidates.first, best.confidence >= settings.ask else { return false }
        if best.confidence < settings.auto { return true }
        return close(candidates)
    }

    static func close(_ candidates: [AttachCandidate]) -> Bool {
        guard candidates.count > 1 else { return false }
        // A hair under the margin, so 0.9 and 0.8 are not close for want of a bit of floating point.
        return candidates[0].confidence - candidates[1].confidence < AttachSettings.closeMargin - 1e-9
    }

    /// Signals with the model's opinion folded in, most likely first.
    public static func blend(_ candidates: [AttachCandidate], with opinion: AttachOpinion) -> [AttachCandidate] {
        let weight = modelWeight * min(1, max(0, opinion.confidence))
        return candidates.map { candidate in
            var candidate = candidate
            let probability = opinion.probabilities[candidate.goal] ?? 0
            candidate.confidence = (1 - weight) * candidate.confidence + weight * probability
            return candidate
        }.sorted { $0.confidence != $1.confidence ? $0.confidence > $1.confidence : $0.goal < $1.goal }
    }

    /// The decision for `subject`, from the rules' ruling, the signals' candidates and the model's opinion if it gave
    /// one. `titles` names goals in the reason.
    public static func decide(
        ruling: AttachRuling, candidates: [AttachCandidate], opinion: AttachOpinion? = nil, settings: AttachSettings,
        titles: [String: String] = [:]
    ) -> AttachVerdict {
        if ruling.ignored {
            return AttachVerdict(
                action: .ignore, reason: "rule line \(ruling.rule?.line ?? 0): \(ruling.rule?.text ?? "ignore")",
                basis: .rule
            )
        }
        if let goal = ruling.goal {
            return AttachVerdict(
                action: .attach, goal: goal, confidence: 1,
                reason: "rule line \(ruling.rule?.line ?? 0): \(ruling.rule?.text ?? "always")", basis: .rule
            )
        }
        let allowed = candidates.filter { !ruling.excluded.contains($0.goal) }
        let ranked = opinion.map { blend(allowed, with: $0) } ?? allowed
        guard let best = ranked.first else {
            return AttachVerdict(action: .leave, reason: "no goal matches")
        }
        let alternative = ranked.dropFirst().first
        var reason = best.reason
        if let opinion {
            let said = opinion.choice == AttachOpinion.none ? "none fits"
                : titles[opinion.choice].map { "fits \($0)" } ?? "fits \(opinion.choice)"
            reason += (reason.isEmpty ? "" : " · ") + "model: \(said) (\(percent(opinion.confidence)) sure)"
        }
        let isClose = close(ranked)
        let action: AttachAction
        if best.confidence >= settings.auto, !isClose {
            action = .attach
        } else if best.confidence >= settings.ask {
            action = .ask
            if isClose, let alternative {
                reason += " · close to \(titles[alternative.goal] ?? alternative.goal)"
            }
        } else {
            action = .leave
        }
        return AttachVerdict(
            action: action, goal: action == .leave ? nil : best.goal, confidence: best.confidence,
            reason: action == .leave ? "best \(titles[best.goal] ?? best.goal) at \(percent(best.confidence)): "
                + reason : reason,
            basis: opinion == nil ? .signals : .model, alternative: alternative?.goal
        )
    }

    static func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
}
