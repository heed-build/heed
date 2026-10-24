import Foundation

/// Builds Attention's items from what heed already has: GitHub notifications, the issue and PR searches, and the
/// agents that need you (the same sessions as Needs you: one queue). Pure, so the feed is a function of the domain.
public enum AttentionFeed {
    /// Every item, deduplicated per thread with all its reasons, newest first.
    ///
    /// - `details`: thread details by URL (lowercased), for author, labels, draft, size and whose turn it is.
    /// - `pilotDriving`: PRs the pilot is getting green; their failing CI is the pilot's, so it is no reason here
    ///   (the PR shows under Watching), unless it stalls and leaves the set.
    /// - `readyToMerge`: PRs that meet every merge requirement while get it merged is off for them (`MergeCandidate`).
    public static func items(
        github: GitHubState, sessions: [Session], details: [String: ThreadDetail] = [:],
        pilotDriving: Set<PullRef> = [], readyToMerge: Set<PullRef> = []
    ) -> [AttentionItem] {
        var byID: [String: AttentionItem] = [:]
        func add(_ item: AttentionItem) {
            byID[item.id] = byID[item.id].map { merged($0, item) } ?? item
        }

        for note in github.inbox {
            add(item(note))
        }
        for issue in github.issues {
            var reasons: Set<AttentionReason> = []
            if issue.assigned { reasons.insert(.assigned) }
            if issue.mentioned { reasons.insert(.mentioned) }
            if reasons.isEmpty { reasons.insert(.watching) }
            add(AttentionItem(
                id: AttentionItem.threadID(issue.repo, issue.number), kind: .issue, repo: issue.repo,
                number: issue.number, title: issue.title, url: issue.url.isEmpty ? nil : issue.url, reasons: reasons,
                updatedAt: issue.updatedAt,
                author: issue.author, labels: issue.labels
            ))
        }
        for pull in github.pulls where pull.state == .open {
            var reasons: Set<AttentionReason> = [.yourPR]
            if pull.checks.failed > 0, !pilotDriving.contains(pull.ref) { reasons.insert(.ciFailed) }
            if pull.review == .changesRequested { reasons.insert(.changesRequested) }
            if pull.unresolvedThreads > 0 { reasons.insert(.unresolvedThreads) }
            if readyToMerge.contains(pull.ref) { reasons.insert(.readyToMerge) }
            add(AttentionItem(
                id: AttentionItem.threadID(pull.ref.repo, pull.ref.number), kind: .pr, repo: pull.ref.repo,
                number: pull.ref.number, title: pull.title, url: pull.url, reasons: reasons, updatedAt: pull.updatedAt,
                isDraft: pull.isDraft, branch: pull.checks.failed > 0 ? pull.headBranch : nil
            ))
        }
        for session in sessions {
            guard let reason = agentReason(session.state.state) else { continue }
            add(AttentionItem(
                id: "agent:\(session.id)", kind: .agent, repo: session.repos.first, number: nil, title: session.title,
                url: nil, reasons: [reason], updatedAt: session.lastActivity, agentState: session.state.state,
                session: session.id
            ))
        }

        return byID.values.map { item in
            var item = item
            if item.url == nil, item.kind == .pr || item.kind == .issue, let repo = item.repo,
               let number = item.number
            {
                item.url = "https://github.com/\(repo.slug)/\(item.kind == .pr ? "pull" : "issues")/\(number)"
            }
            if let url = item.url?.lowercased(), let detail = details[url] { apply(detail, to: &item) }
            if item.session == nil { item.session = session(for: item, in: sessions) }
            return item
        }.sorted { $0.updatedAt == $1.updatedAt ? $0.id < $1.id : $0.updatedAt > $1.updatedAt }
    }

    /// The reason an agent in `state` is here, if it is: the Needs you states, and rate limited.
    public static func agentReason(_ state: AgentState) -> AttentionReason? {
        switch state {
        case .blocked: .agentBlocked
        case .asking: .agentAsking
        case .limited: .agentLimited
        default: nil
        }
    }

    static func item(_ note: InboxItem) -> AttentionItem {
        let kind: AttentionItem.Kind = switch note.kind {
        case .pr: .pr
        case .issue: .issue
        case .ci: .ci
        case .release: .release
        case .discussion: .discussion
        case .other: .other
        }
        let thread = (kind == .pr || kind == .issue) ? note.number.map { AttentionItem.threadID(note.repo, $0) } : nil
        return AttentionItem(
            id: thread ?? "\(kind.rawValue):\(note.id)", kind: kind, repo: note.repo, number: note.number,
            title: note.title, url: note.url, reasons: [AttentionReason(notification: note.reason)], teams: note.teams,
            updatedAt: note.updatedAt, notificationID: note.id, unread: note.unread,
            branch: kind == .ci ? ciBranch(note.title) : nil
        )
    }

    /// The branch in a CI notification's title: `Build workflow run failed for main branch` → `main`.
    static func ciBranch(_ title: String) -> String? {
        title.firstMatch(of: /for (\S+) branch/).map { String($0.output.1) }
    }

    /// Two views of one thread as one: every reason and team, the newest time, and each field from whichever has it
    /// (the notification's title and unread state first, as the newer).
    static func merged(_ old: AttentionItem, _ new: AttentionItem) -> AttentionItem {
        var item = old
        item.reasons.formUnion(new.reasons)
        item.teams.formUnion(new.teams)
        if new.updatedAt > item.updatedAt {
            item.updatedAt = new.updatedAt
            item.title = new.title.isEmpty ? item.title : new.title
        }
        item.notificationID = item.notificationID ?? new.notificationID
        item.unread = item.unread || new.unread
        item.url = item.url ?? new.url
        item.author = item.author ?? new.author
        if item.labels.isEmpty { item.labels = new.labels }
        item.isDraft = item.isDraft ?? new.isDraft
        item.branch = item.branch ?? new.branch
        item.session = item.session ?? new.session
        return item
    }

    static func apply(_ detail: ThreadDetail, to item: inout AttentionItem) {
        item.author = item.author ?? detail.author
        item.authorIsBot = item.authorIsBot || detail.authorIsBot
        if item.labels.isEmpty { item.labels = detail.labels }
        item.isDraft = item.isDraft ?? detail.isDraft
        item.size = item.size ?? detail.size
        item.lastCommenter = detail.lastCommenter
    }

    /// A session that tracks the item's PR, or works on its issue.
    static func session(for item: AttentionItem, in sessions: [Session]) -> String? {
        guard let repo = item.repo, let number = item.number else { return nil }
        let pull = PullRef(repo: repo, number: number)
        let issue = IssueRef(repo: repo, number: number)
        return sessions.first { $0.trackedPRs.contains(pull) || $0.issues.contains(issue) }?.id
    }

    /// The URLs (as given) that need thread details: issues and PRs that want you, with none yet or older than their
    /// last update; at most `limit`, newest first.
    public static func detailsNeeded(
        _ items: [AttentionItem], details: [String: ThreadDetail], limit: Int = 40
    ) -> [(url: String, updatedAt: Date)] {
        Array(items.lazy.filter { $0.wantsYou && ($0.kind == .pr || $0.kind == .issue) }.compactMap { item in
            guard let url = item.url else { return nil }
            if let known = details[url.lowercased()], known.updatedAt >= item.updatedAt { return nil }
            return (url, item.updatedAt)
        }.prefix(limit))
    }
}

/// The sidebar's filters.
public enum AttentionFilter: String, CaseIterable, Hashable, Sendable {
    /// The raw values are what `view.attention` and `attention.filter` take: `gi` is `view.attention issues`.
    case needsMe = "needs", tagged, reviews, myPRs = "mine", agents, ci, issues, muted

    public var title: String {
        switch self {
        case .needsMe: "Needs me"
        case .tagged: "Tagged"
        case .reviews: "Review requests"
        case .myPRs: "My PRs"
        case .agents: "Agents"
        case .ci: "CI"
        case .issues: "Issues"
        case .muted: "Muted"
        }
    }

    /// Whether `item` belongs under this filter (muted aside: what is muted is decided by rules and marks).
    public func matches(_ item: AttentionItem) -> Bool {
        switch self {
        case .needsMe: item.wantsYou
        case .tagged: !item.reasons.isDisjoint(with: [.mentioned, .teamMention])
        case .reviews: item.reasons.contains(.reviewRequested)
        case .myPRs: item.reasons.contains(.yourPR)
        case .agents: item.kind == .agent
        case .ci: item.reasons.contains(.ciFailed)
        case .issues: item.kind == .issue
        case .muted: false
        }
    }
}
