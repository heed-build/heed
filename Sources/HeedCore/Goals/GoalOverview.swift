import Foundation

/// A goal's overview, from the goal, its `GOAL.md`, what is on it and what heed knows about those: the numbers at the
/// top, the sessions and chats on it, their PRs, and where the work was left (the newest ledger summary of one of its
/// sessions). Pure, so the view only draws it.
public struct GoalOverview: Hashable, Sendable {
    /// A session or chat on the goal, open or in History.
    public struct Row: Hashable, Sendable, Identifiable {
        public var link: GoalLink
        public var title: String
        /// Where it runs: its repos (or `chat`), and its host.
        public var place: String
        /// In the sidebar now; false once closed (it is in History) or gone.
        public var open: Bool
        public var state: AgentState?
        public var lastActivity: Date?

        public var id: String { link.key }
    }

    public struct Pull: Hashable, Sendable, Identifiable {
        public var ref: PullRef
        public var title: String?
        /// `merged`, `open`, `closed`, or `unknown` until GitHub says.
        public var state: String

        public var id: String { ref.description }
    }

    /// Where the work was left: the newest ledger summary of the goal's sessions.
    public struct LastTime: Hashable, Sendable {
        public var session: String
        public var title: String
        public var summary: String
        public var at: Date
    }

    public var criteriaMet: Int
    public var criteriaTotal: Int
    public var rows: [Row]
    public var pulls: [Pull]
    public var lastTime: LastTime?

    public var sessions: Int { rows.count }
    public var merged: Int { pulls.count { $0.state == "merged" } }

    public static func build(
        doc: GoalDoc?, links: [GoalLink], sessions: [Session], history: [HistoryEntry], github: GitHubState,
        ledger: [String: LedgerEntry]
    ) -> GoalOverview {
        let mine = links.filter { $0.kind == .session || $0.kind == .chat }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.target < $1.target }
        var rows: [Row] = []
        var refs: [PullRef] = []
        for link in mine {
            let live = sessions.first { $0.id == link.target }
            let closed = history.first { $0.id == link.target }?.session
            let session = live ?? closed
            let place = session.map { session in
                (session.isChat ? ["chat"] : session.repos.map(\.slug)).joined(separator: ", ")
                    + (session.host.map { " @\($0)" } ?? "")
            } ?? ""
            rows.append(Row(
                link: link, title: session?.title ?? ledger[link.target]?.title ?? link.target, place: place,
                open: live != nil, state: live?.state.state, lastActivity: session?.lastActivity
            ))
            for ref in (session?.trackedPRs ?? []) + (ledger[link.target]?.pulls ?? []) where !refs.contains(ref) {
                refs.append(ref)
            }
        }
        for link in links where link.kind == .pr {
            if let ref = PullRef(slug: link.target), !refs.contains(ref) { refs.append(ref) }
        }
        let pulls = refs.map { ref in
            let pull = github.pull(ref)
            let state = switch pull?.state {
            case .merged?: "merged"
            case .open?: "open"
            case .closed?: "closed"
            case nil: "unknown"
            }
            return Pull(ref: ref, title: pull?.title, state: state)
        }
        let last = mine.compactMap { link -> LastTime? in
            guard let entry = ledger[link.target], let summary = entry.summary, !summary.isEmpty else { return nil }
            return LastTime(
                session: link.target, title: entry.title, summary: summary, at: entry.summarizedAt ?? entry.updatedAt
            )
        }
        .max { $0.at != $1.at ? $0.at < $1.at : $0.session > $1.session }
        let met = doc?.criteriaMet ?? (met: 0, total: 0)
        return GoalOverview(criteriaMet: met.met, criteriaTotal: met.total, rows: rows, pulls: pulls, lastTime: last)
    }
}

public extension PullRef {
    /// `org/repo#n`, as a link names a PR.
    init?(slug: String) {
        let parts = slug.split(separator: "#")
        let repo = parts.first?.split(separator: "/") ?? []
        guard parts.count == 2, repo.count == 2, let number = Int(parts[1]) else { return nil }
        self.init(repo: Repo(org: String(repo[0]), name: String(repo[1])), number: number)
    }
}

public extension GoalSnapshot {
    /// The goal `query` names, for `goal.attach`: its slug, its title, or the one goal (not archived) whose slug or
    /// title starts with or contains it. Nil when none or several do.
    func find(_ query: String) -> HeedGoal? {
        let key = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !key.isEmpty else { return nil }
        if let exact = goals.first(where: { $0.id == key || $0.title.lowercased() == key }) { return exact }
        let live = goals.filter { $0.status != .archived }
        for test in [
            { (goal: HeedGoal) in goal.id.hasPrefix(key) || goal.title.lowercased().hasPrefix(key) },
            { (goal: HeedGoal) in goal.id.contains(key) || goal.title.lowercased().contains(key) },
        ] {
            let found = live.filter(test)
            if found.count == 1 { return found[0] }
            if found.count > 1 { return nil }
        }
        return nil
    }
}
