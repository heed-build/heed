import Foundation

/// What a piece of work left unfinished that nobody wrote down as a follow-up, from what heed already knows: work
/// saved when its worktree was removed that never landed, a branch with commits and no PR, a PR open and quiet,
/// review threads left open, CI left red, a last message that asked something nobody answered, work abandoned with
/// nothing written about what was left. Each is worked out again whenever the facts change, so one goes away by
/// itself when its fact does (the PR merges, the thread resolves, CI goes green); `x` dismisses one for good.
public enum LooseEnds {
    /// A PR with no activity this long is quiet.
    public static let quietAfter: TimeInterval = 7 * 24 * 3600

    /// What heed knows beyond the ledger entry: its PRs as GitHub last showed them, and whether its agent's last
    /// message asked something nobody answered (Hunch's reading, nil when not asked).
    public struct Facts: Hashable, Sendable {
        public var pulls: [PullRequest]
        public var unanswered: String?

        public init(pulls: [PullRequest] = [], unanswered: String? = nil) {
            self.pulls = pulls
            self.unanswered = unanswered
        }
    }

    public static func of(_ entry: LedgerEntry, facts: Facts, now: Date) -> [MindNode.OpenItem] {
        var items: [MindNode.OpenItem] = []
        func add(_ kind: MindNode.OpenItem.Kind, _ text: String) {
            items.append(.init(kind: kind, text: text, source: entry.id))
        }
        let landed = entry.outcome == "merged" || facts.pulls.contains { $0.state == .merged }
        let ended = entry.endedAt != nil
        if entry.outcome == "cleaned up", !landed {
            add(.saved, "Work saved from \(entry.branch.isEmpty ? entry.title : entry.branch) never landed")
        }
        if ended, !landed, entry.pulls.isEmpty, (entry.diff?.files ?? 0) > 0, entry.outcome != "abandoned" {
            add(.noPR, "\(entry.branch.isEmpty ? entry.title : entry.branch) has commits and no PR")
        }
        for pull in facts.pulls where pull.state == .open {
            let name = "\(pull.ref.repo.name)#\(pull.ref.number)"
            if now.timeIntervalSince(pull.updatedAt) >= quietAfter {
                add(.stalePR, "\(name) has been quiet for \(Int(now.timeIntervalSince(pull.updatedAt) / 86400)) days")
            }
            if pull.unresolvedThreads > 0 {
                add(
                    .threads,
                    "\(name): \(pull.unresolvedThreads) review thread\(pull.unresolvedThreads == 1 ? "" : "s") open"
                )
            }
            if pull.checks.failed > 0 {
                add(.redCI, "\(name): CI red (\(pull.checks.failedNames.prefix(2).joined(separator: ", ")))")
            }
        }
        if let question = facts.unanswered, !question.isEmpty { add(.question, "Left asking: \(question)") }
        if entry.outcome == "abandoned", entry.followUps.isEmpty {
            add(.abandoned, "\(entry.title) was abandoned with nothing written about what was left")
        }
        return items
    }

    /// The node's open items with its loose ends worked out again: follow-ups stay as they are, loose ends are
    /// replaced by `fresh`, except that one you dismissed stays dismissed while it is still there.
    public static func merge(_ fresh: [MindNode.OpenItem], into open: [MindNode.OpenItem]) -> [MindNode.OpenItem] {
        let followUps = open.filter { $0.kind == .followUp }
        let dismissed = Set(open.filter { $0.kind != .followUp && $0.resolvedBy != nil }
            .map { "\($0.kind)|\($0.text)" })
        return followUps + fresh.map { item in
            var item = item
            if dismissed.contains("\(item.kind)|\(item.text)") { item.resolvedBy = "you" }
            return item
        }
    }

    /// The statement Hunch checks the agent's last message against.
    public static let questionCheck = Question.noul(
        instructions: "The last message asks the user something, or says work is unfinished, and waits for an answer."
    )
}
