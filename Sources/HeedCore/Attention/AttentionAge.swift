import Foundation

/// `[attention] max_age_days`: how old a GitHub item may be, by its last update, and still show in Attention. The
/// same cut-off goes to GitHub (the `updated:>=` qualifier of the searches, `since=` of the notifications) so fewer
/// calls are spent, and to the feed, so items cached from before it drop out too. 0 is no cap.
public enum AttentionAge {
    public static let defaultDays = 60
    /// The most `max_age_days` takes (ten years).
    public static let maxDays = 3650

    /// The moment before which an item is too old, or nil when `days` is 0 (no cap).
    public static func cutoff(days: Int, now: Date) -> Date? {
        days > 0 ? now.addingTimeInterval(-TimeInterval(days) * 86400) : nil
    }

    /// `updated:>=2026-09-17` for a GitHub search (the cut-off's day, UTC), or nil when there is no cap.
    public static func qualifier(days: Int, now: Date) -> String? {
        cutoff(days: days, now: now).map { "updated:>=\(day($0))" }
    }

    /// `2026-09-17T10:00:00Z`, for the notifications' `since=`, or nil when there is no cap.
    public static func since(days: Int, now: Date) -> String? {
        cutoff(days: days, now: now)?.formatted(.iso8601)
    }

    static func day(_ date: Date) -> String {
        let parts = Calendar(identifier: .gregorian).dateComponents(in: TimeZone(identifier: "UTC")!, from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    /// The thread ids (`org/repo#n`, lowercased) the cap leaves alone: what you are actively in. A session's PRs and
    /// issues, the PRs and issues attached to a goal (a PR link, an item sourced from one), and the PRs the pilot
    /// watches.
    public static func exempt(
        sessions: [Session], goalPulls: [String] = [], goalIssues: [String] = [], watched: [PullRef] = []
    ) -> Set<String> {
        var ids = Set<String>()
        for session in sessions {
            ids.formUnion(session.trackedPRs.map { AttentionItem.threadID($0.repo, $0.number) })
            ids.formUnion(session.issues.map { AttentionItem.threadID($0.repo, $0.number) })
        }
        ids.formUnion(goalPulls.map { $0.lowercased() })
        ids.formUnion(goalIssues.map { $0.lowercased() })
        ids.formUnion(watched.map { AttentionItem.threadID($0.repo, $0.number) })
        return ids
    }

    /// `items` without the GitHub ones last updated before the cut-off. Agents and goals are not GitHub's, and an
    /// item in `exempt` or with a session of its own stays however old.
    public static func apply(
        to items: [AttentionItem], days: Int, now: Date, exempt: Set<String> = []
    ) -> [AttentionItem] {
        guard let cutoff = cutoff(days: days, now: now) else { return items }
        return items.filter { item in
            switch item.kind {
            case .agent, .goal: true
            default: item.updatedAt >= cutoff || item.session != nil || exempt.contains(item.id)
            }
        }
    }
}
