import Foundation

/// The dashboard's goals: those that moved in the range (evidence came in, or they were done), and what is next for
/// the one closest to done. Only what the goals' records hold: a goal's confidence is kept as it is now, not as it
/// was, so how far it moved is told by what came in, not by a change of score.
public enum DashboardGoals {
    public struct Moved: Equatable, Sendable, Identifiable {
        public var id: String
        public var title: String
        /// Its confidence now, 0–10; nil when nothing scored it.
        public var score: Double?
        /// It was done in the range.
        public var done: Bool
        /// Evidence that came in done in the range, and of it how many merges.
        public var steps: Int
        public var merged: Int
    }

    public struct Next: Equatable, Sendable {
        public var goal: String
        public var title: String
        /// What it still lacks, as its quality says it (`2 criteria without evidence`, `Docs 5.6 under 7`).
        public var missing: [String]
    }

    /// The goals with something done in `since ... now`, most moved first.
    public static func moved(
        goals: [HeedGoal], evidence: [GoalEvidence], qualities: [String: GoalQuality], since: Date, now: Date
    ) -> [Moved] {
        let recent = evidence.filter { $0.at >= since && $0.at <= now && $0.state == .done }
        let byGoal = Dictionary(grouping: recent, by: \.goal)
        return goals.compactMap { goal -> Moved? in
            guard goal.status != .archived else { return nil }
            let quality = qualities[goal.id]
            let done = quality?.doneAt.map { $0 >= since && $0 <= now } ?? false
            let list = byGoal[goal.id] ?? []
            guard done || !list.isEmpty else { return nil }
            return Moved(
                id: goal.id, title: goal.title, score: quality?.confidence?.value ?? goal.score, done: done,
                steps: list.count, merged: list.count { $0.kind == .merged }
            )
        }
        .sorted { lhs, rhs in
            if lhs.done != rhs.done { return lhs.done }
            if lhs.steps != rhs.steps { return lhs.steps > rhs.steps }
            return lhs.title < rhs.title
        }
    }

    /// The active goal closest to done (highest confidence) that still lacks something, and what.
    public static func next(goals: [HeedGoal], qualities: [String: GoalQuality]) -> Next? {
        let open = goals.filter { $0.status == .active }.compactMap { goal -> (HeedGoal, GoalQuality)? in
            guard let quality = qualities[goal.id], !quality.done.done,
                  !quality.done.missing.isEmpty else { return nil }
            return (goal, quality)
        }
        guard let (goal, quality) = open.max(by: { lhs, rhs in
            let left = lhs.1.confidence?.value ?? -1
            let right = rhs.1.confidence?.value ?? -1
            return left != right ? left < right : lhs.0.title > rhs.0.title
        }) else { return nil }
        return Next(goal: goal.id, title: goal.title, missing: quality.done.missing)
    }
}
