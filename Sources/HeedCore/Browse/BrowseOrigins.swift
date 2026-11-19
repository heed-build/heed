import Foundation

/// Which items in Browse have work started from them: the sessions that close or track them, and the goals that hold
/// them as an item. Derived from what heed already keeps (a session's issues and PRs, a goal item's links), so nothing
/// is stored and nothing is lost when the session or goal outlives its Browse run.
public struct BrowseOrigins: Equatable, Sendable {
    public struct Entry: Equatable, Sendable {
        public var sessions: [String] = []
        public var goals: [String] = []
        public var isEmpty: Bool { sessions.isEmpty && goals.isEmpty }
    }

    /// What a session links to, as far as Browse cares.
    public struct SessionRefs: Equatable, Sendable {
        public var id: String
        public var issues: [IssueRef]
        public var pulls: [PullRef]

        public init(id: String, issues: [IssueRef], pulls: [PullRef]) {
            self.id = id
            self.issues = issues
            self.pulls = pulls
        }
    }

    public static let empty = BrowseOrigins(byPlace: [:])

    private var byPlace: [String: Entry]

    private init(byPlace: [String: Entry]) { self.byPlace = byPlace }

    /// `acme/docs#12`, the way an item names itself (`BrowseItem.place`).
    public static func place(_ repo: Repo, _ number: Int) -> String { "\(repo.slug)#\(number)" }

    public static func build(sessions: [SessionRefs], goalItems: [GoalItem]) -> BrowseOrigins {
        var map: [String: Entry] = [:]
        for session in sessions {
            let places = session.issues.map { place($0.repo, $0.number) } + session.pulls
                .map { place($0.repo, $0.number) }
            for place in places where !(map[place]?.sessions.contains(session.id) ?? false) {
                map[place, default: Entry()].sessions.append(session.id)
            }
        }
        for item in goalItems {
            for link in item.links where link.kind == .issue || link.kind == .pr {
                if !(map[link.target]?.goals.contains(item.goal) ?? false) {
                    map[link.target, default: Entry()].goals.append(item.goal)
                }
            }
        }
        return BrowseOrigins(byPlace: map)
    }

    public subscript(_ item: BrowseItem) -> Entry { byPlace[item.place] ?? Entry() }
}

/// The quick filter at the right of Browse's count: only the items with an agent run on them, with a session started
/// from them, or with a goal holding them. One at a time; each is on offer only while some item qualifies.
public enum BrowseWorkFilter: String, CaseIterable, Hashable, Sendable {
    case agent, session, goal

    public func keeps(_ item: BrowseItem, hasRun: Bool, origins: BrowseOrigins) -> Bool {
        switch self {
        case .agent: hasRun
        case .session: !origins[item].sessions.isEmpty
        case .goal: !origins[item].goals.isEmpty
        }
    }

    public var title: String {
        switch self {
        case .agent: "with an agent"
        case .session: "from sessions"
        case .goal: "in goals"
        }
    }
}
