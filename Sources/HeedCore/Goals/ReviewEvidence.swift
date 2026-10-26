import Foundation

/// Reviews in the goal's shared model: what a review says about each item goes in as `GoalEvidence` (so the matrix's
/// plan review, code review, perf and DX columns fill), and each open HIGH objection becomes an item of its own.
public enum ReviewEvidence {
    /// The matrix column a lens fills; nil for lenses the matrix has no column for (security, tests, docs, UX).
    public static func stage(_ lens: GoalLens) -> Stage? {
        switch lens {
        case .plan: .planReview
        case .code: .codeReview
        case .perf: .perf
        case .dx: .dx
        case .tests, .security, .docs, .ux: nil
        }
    }

    /// The matrix's lens columns a goal needs: its required lenses that have a column; every one until a profile
    /// decided.
    public static func requiredStages(_ quality: GoalQuality?) -> Set<Stage> {
        guard let quality, quality.profile != nil || !quality.pins.isEmpty else { return Stage.lenses }
        return Set(quality.lenses.compactMap { stage($0.lens) })
    }

    /// A review's evidence: one per item it looked at (the items linked to a PR whose head it reviewed, else the goal
    /// as a whole), done at or over the bar, an issue with a HIGH objection open, in progress otherwise; with the
    /// reviewer's score. Nothing for a run that wrote no review, or a lens without a column.
    public static func of(
        reviewer: ReviewerState, bar: Double?, goal: String, items: [GoalItem], at: Date
    ) -> [GoalEvidence] {
        guard let lens = reviewer.config.kind.lens, let stage = stage(lens), let score = reviewer.score,
              let review = reviewer.lastReview, review.report != nil
        else { return [] }
        let state: GoalEvidence.State = reviewer.open.contains { $0.severity == .high } ? .issue
            : score.value >= (bar ?? 0) ? .done : .inProgress
        let pulls = Set(review.basis.heads.map { head in head.split(separator: "@").first.map(String.init) ?? head })
        let reviewed = items.filter { item in !Set(item.linked(.pr)).isDisjoint(with: pulls) }
        let text = "\(reviewer.config.title) \(GoalBarTable.number(score.value))"
            + (bar.map { " (bar \(GoalBarTable.number($0)))" } ?? "")
        let targets: [String?] = reviewed.isEmpty ? [nil] : reviewed.map(\.id)
        return targets.map { item in
            GoalEvidence(
                goal: goal, item: item, kind: stage.evidence, state: state, at: at,
                source: reviewer.config.kind.title.lowercased(), text: text, ref: "review:\(reviewer.id)",
                score: score.value
            )
        }
    }

    /// The marker an objection's item carries in its reason, so it is made once.
    public static func marker(reviewer: String, objection: String) -> String { "objection \(reviewer)/\(objection)" }

    /// The open HIGH objections that have no item yet.
    public static func newItems(_ quality: GoalQuality, items: [GoalItem]) -> [(
        reviewer: ReviewerState,
        objection: Objection
    )] {
        let reasons = Set(items.compactMap(\.reason))
        return quality.live.flatMap { reviewer in
            reviewer.open.filter { objection in
                objection.severity == .high
                    && !reasons.contains { $0.hasSuffix(marker(reviewer: reviewer.id, objection: objection.id)) }
            }.map { (reviewer, $0) }
        }
    }

    /// Objections with an item that are no longer open (fixed, or the risk accepted): their items get done
    /// evidence.
    public static func settled(_ quality: GoalQuality, items: [GoalItem]) -> [(item: GoalItem, objection: Objection)] {
        quality.live.flatMap { reviewer in
            reviewer.objections.filter { $0.state != .open }.compactMap { objection in
                items.first { $0.reason?.hasSuffix(marker(reviewer: reviewer.id, objection: objection.id)) == true }
                    .map { ($0, objection) }
            }
        }
    }
}
