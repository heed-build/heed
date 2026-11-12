import Foundation

/// `G` on a campaign: the campaign as a goal suggestion, so it becomes a goal the way Unassigned's suggestions do
/// (its GOAL.md drafted from the work, the work put on it). Its intent and decisions go in as known.
public enum MindmapGoal {
    public static func suggestion(
        for id: String,
        in tree: MindmapTree,
        ledger: [String: LedgerEntry]
    ) -> GoalSuggestion? {
        guard let node = MemoryBrief.anchor(of: id, in: tree), node.kind != .work else { return nil }
        let entries = tree.entries(under: node.id).compactMap { ledger[$0] }.sorted { $0.startedAt < $1.startedAt }
        guard let first = entries.first, let last = entries.last else { return nil }
        let subjects = entries.map { entry in
            AttachSubject(
                kind: entry.chat ? .chat : .session, id: entry.id, title: entry.title, prompt: entry.summary ?? "",
                repos: entry.repos, branch: entry.branch, files: entry.files,
                pulls: entry.pulls.map(\.description), at: entry.startedAt
            )
        }
        let repos = Set(entries.compactMap(\.repos.first))
        let terms = (node.intent.map { [$0] } ?? []) + tree.decisions(of: node.id).shown.map(\.text)
        return GoalSuggestion(
            subjects: subjects, repo: repos.count == 1 ? repos.first : nil, terms: terms.isEmpty ? [node.title] : terms,
            title: node.title, first: first.startedAt, last: last.updatedAt
        )
    }
}
