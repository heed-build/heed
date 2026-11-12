import Foundation

/// Who acted in a thread lately, as its details tell (its last three comments and reviews): the newest by someone
/// other than you who is not a bot, and the newest by a bot. Your own are in neither.
public struct ThreadActivity: Hashable, Sendable, Codable {
    public var others: Date?
    public var bots: Date?

    public init(others: Date? = nil, bots: Date? = nil) {
        self.others = others
        self.bots = bots
    }

    /// From a thread's details; nil when they were fetched for an older update than `updatedAt` (they cannot say who
    /// made the last one).
    public static func of(_ detail: ThreadDetail, viewer: String?, updatedAt: Date) -> ThreadActivity? {
        guard detail.updatedAt >= updatedAt else { return nil }
        let me = viewer?.lowercased()
        var activity = ThreadActivity()
        for comment in detail.comments {
            if comment.byBot {
                activity.bots = max(activity.bots ?? .distantPast, comment.at)
            } else if comment.author.lowercased() != me {
                activity.others = max(activity.others ?? .distantPast, comment.at)
            }
        }
        return activity
    }
}

/// What undoes done: something new in the thread since, from someone other than you.
public enum AttentionActivity {
    /// The reasons whose news a bot can bring: a check that failed, a review asked for or given.
    public static let botNews: Set<AttentionReason> = [.ciFailed, .reviewRequested, .changesRequested]

    /// Whether `item` has something new since `doneAt`:
    ///
    /// - nothing updated it since: no;
    /// - one of heed's own items (an agent, a goal), or a thread with no details to read (a CI run, a release, a
    ///   discussion): any update;
    /// - a comment or review by someone else (not you, not a bot) since: yes; by a bot, only when the item is there
    ///   for a failed check or a review (`botNews`);
    /// - an unread notification: yes, as GitHub never notifies you of what you did yourself, unless the details show
    ///   only a bot spoke since and the reason is not one a bot's news counts for;
    /// - otherwise (your own comment or push, or details not fetched yet for the update): no.
    public static func isNew(_ item: AttentionItem, since doneAt: Date) -> Bool {
        guard item.updatedAt > doneAt else { return false }
        guard item.kind == .pr || item.kind == .issue else { return true }
        let botsCount = !item.reasons.isDisjoint(with: botNews)
        let activity = item.activity
        if let others = activity?.others, others > doneAt { return true }
        let botSpoke = activity?.bots.map { $0 > doneAt } ?? false
        if botsCount, botSpoke { return true }
        if item.unread, item.notificationID != nil { return !botSpoke }
        return false
    }
}
