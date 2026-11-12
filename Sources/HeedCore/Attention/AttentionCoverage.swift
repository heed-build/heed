import Foundation

/// Whether Attention has everything: per source, what heed fetched against what GitHub says it has, and where the
/// items went (listed, hidden by a rule, muted, folded, done, snoozed). The foot of Attention says it in a line,
/// amber when something is missing; `:attention.coverage` shows the table.
public struct AttentionCoverage: Hashable, Sendable {
    public enum Source: String, CaseIterable, Hashable, Sendable {
        case notifications, mentions, assigned, myPRs, agents, goals

        public var title: String {
            switch self {
            case .notifications: "Notifications"
            case .mentions: "Mentions"
            case .assigned: "Assigned"
            case .myPRs: "My PRs"
            case .agents: "Agents"
            case .goals: "Goals"
            }
        }
    }

    /// Where an item went.
    public enum Fate: Hashable, Sendable {
        case listed, hiddenByRule, muted, folded, done, snoozed, elsewhere
    }

    public struct Row: Hashable, Sendable {
        public var source: Source
        /// What the last fetch brought (for notifications: the unread ones).
        public var fetched: Int
        /// GitHub's own count, where it gives one.
        public var total: Int?
        /// The cap stopped the fetch before GitHub ran out.
        public var capped: Bool
        public var fetchedAt: Date?
        /// Items from the source by where they went; one item can come from several sources.
        public var fates: [Fate: Int]

        public func count(_ fate: Fate) -> Int { fates[fate] ?? 0 }
        /// What GitHub has that heed did not fetch.
        public var dropped: Int { max(0, (total ?? fetched) - fetched) }
        public var mismatch: Bool { capped || dropped > 0 }
    }

    public var rows: [Row]
    /// Items GitHub withheld (SAML).
    public var samlHidden: Int
    /// Each item counted once, by where it went.
    public var totals: [Fate: Int]
    /// How many of the folded ones are assignments (the rest are mentions).
    public var foldedAssignments: Int

    public var mismatch: Bool { samlHidden > 0 || rows.contains(where: \.mismatch) }

    public func row(_ source: Source) -> Row? { rows.first { $0.source == source } }

    /// Where `entry` went at `now`.
    public static func fate(of entry: AttentionEntry, now: Date) -> Fate {
        if entry.mark.mutedAt != nil { return .muted }
        if entry.outcome.action.ignore { return .hiddenByRule }
        if let until = entry.mark.snoozedUntil, until > now { return .snoozed }
        if entry.mark.hides(entry.item, now: now) { return .done }
        if entry.item.wantsYou { return .listed }
        if entry.item.reasons.contains(where: \.before) { return .folded }
        return .elsewhere
    }

    /// The coverage of `entries` (live ones count; what only the store remembers does not), from `github`'s last
    /// fetches.
    public static func of(github: GitHubState, entries: [AttentionEntry], now: Date) -> AttentionCoverage {
        let live = entries.filter(\.live)
        let fates = Dictionary(live.map { ($0.id, fate(of: $0, now: now)) }) { first, _ in first }
        func tally(_ ids: Set<String>) -> [Fate: Int] {
            var counts: [Fate: Int] = [:]
            for id in ids {
                if let fate = fates[id] { counts[fate, default: 0] += 1 }
            }
            return counts
        }
        func ids(_ match: (AttentionItem) -> Bool) -> Set<String> { Set(live.map(\.item).filter(match).map(\.id)) }
        let fetches = github.fetches
        let unread = github.inbox.count(where: \.unread)
        func row(_ source: Source, _ fetch: SourceFetch?, count: Int, _ members: Set<String>) -> Row {
            Row(
                source: source, fetched: fetch?.fetched ?? count, total: fetch?.total, capped: fetch?.capped ?? false,
                fetchedAt: fetch?.at, fates: tally(members)
            )
        }
        let notified = Set(github.inbox.map { AttentionFeed.item($0).id })
        let mentioned = Set(github.issues.filter(\.mentioned).map { AttentionItem.threadID($0.repo, $0.number) })
        let assigned = Set(github.issues.filter(\.assigned).map { AttentionItem.threadID($0.repo, $0.number) })
        let mine = Set(github.pulls.filter { $0.state == .open }
            .map { AttentionItem.threadID($0.ref.repo, $0.ref.number) })
        let agents = ids { $0.kind == .agent }
        let goals = ids { $0.kind == .goal }
        let rows = [
            row(.notifications, fetches.notifications, count: unread, notified),
            row(.mentions, fetches.mentions, count: mentioned.count, mentioned),
            row(.assigned, fetches.assigned, count: assigned.count, assigned),
            row(.myPRs, fetches.pulls, count: mine.count, mine),
            Row(
                source: .agents,
                fetched: agents.count,
                total: nil,
                capped: false,
                fetchedAt: nil,
                fates: tally(agents)
            ),
            Row(source: .goals, fetched: goals.count, total: nil, capped: false, fetchedAt: nil, fates: tally(goals)),
        ]
        var totals: [Fate: Int] = [:]
        for fate in fates.values {
            totals[fate, default: 0] += 1
        }
        let foldedAssignments = live.count { entry in
            fates[entry.id] == .folded && entry.item.reasons.contains(.assignedBefore)
                && !entry.item.reasons.contains(.mentionedBefore)
        }
        let saml = if case let .partial(hidden, _) = github.status { hidden } else { 0 }
        return AttentionCoverage(rows: rows, samlHidden: saml, totals: totals, foldedAssignments: foldedAssignments)
    }

    // MARK: Text

    /// The foot of Attention: `36 of 36 unread from GitHub · 54 old mentions folded · 3 muted`.
    public var line: String {
        var parts: [String] = []
        if let notes = row(.notifications) {
            if notes.capped {
                parts.append("\(notes.fetched) of \(notes.fetched)+ unread from GitHub, stopped at the cap")
            } else if notes.fetchedAt == nil, notes.total == nil, notes.fetched == 0 {
                parts.append("no notifications fetched yet")
            } else {
                parts.append("\(notes.fetched) of \(notes.total ?? notes.fetched) unread from GitHub")
            }
        }
        for source in [Source.mentions, .assigned, .myPRs] {
            guard let row = row(source), row.mismatch else { continue }
            parts.append("\(row.source.title.lowercased()) \(row.fetched) of \(row.total.map(String.init) ?? "?")")
        }
        if samlHidden > 0 { parts.append("\(samlHidden) hidden by SAML") }
        let folded = totals[.folded] ?? 0
        if folded > 0 {
            let plural = folded == 1 ? "" : "s"
            let what = switch foldedAssignments {
            case 0: "mention\(plural)"
            case folded: "assignment\(plural)"
            default: "mentions and assignments"
            }
            parts.append("\(folded) old \(what) folded")
        }
        let muted = (totals[.muted] ?? 0) + (totals[.hiddenByRule] ?? 0)
        if muted > 0 { parts.append("\(muted) muted") }
        return parts.joined(separator: " · ")
    }

    /// One line per source, for `:attention.coverage`.
    public func table(now: Date) -> [String] {
        rows.map { row in
            var parts: [String] = []
            switch row.source {
            case .notifications:
                parts.append(
                    row.capped ? "\(row.fetched) unread fetched, stopped at the cap of \(GitHub.notificationCap)"
                        : "\(row.fetched) of \(row.total ?? row.fetched) unread"
                )
            case .agents, .goals:
                parts.append("\(row.fetched) waiting on you")
            default:
                parts.append("\(row.fetched) of \(row.total.map(String.init) ?? "?") open")
                if row.capped { parts.append("\(row.dropped) past the cap of \(GitHub.issueSearchCap)") }
            }
            let fates: [(Fate, String)] = [
                (.listed, "in Needs me"), (.folded, "folded"), (.done, "done"), (.snoozed, "snoozed"),
                (.hiddenByRule, "hidden by a rule"), (.muted, "muted"),
            ]
            for (fate, word) in fates where row.count(fate) > 0 {
                parts.append("\(row.count(fate)) \(word)")
            }
            if let at = row.fetchedAt { parts.append("fetched \(AttentionCoverage.age(at, now: now))") }
            return "\(row.source.title): " + parts.joined(separator: " · ")
        } + (samlHidden > 0 ? ["\(samlHidden) withheld by SAML: authorize the GitHub CLI for that org"] : [])
    }

    /// `just now`, `4m ago`, `2h ago`, `3d ago`.
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}
