import Foundation

/// How the sidebar lists sessions: what groups them, the order in a group, and one or two lines a row. The sidebar's
/// View menu and `sessions.group` `sessions.sort` `sessions.rows` change it; it is kept per Mac, not in config.
public struct SessionsView: Hashable, Sendable, Codable {
    public enum Grouping: String, CaseIterable, Hashable, Sendable, Codable {
        /// Pinned, Needs you, Stalled, Working, Watching, Chats, Parked: the sidebar as it always was.
        case status
        /// The Mindmap campaign each session's work is in; Unplaced for the rest.
        case campaign
        /// Each session's first repo.
        case repo
        /// One list.
        case none

        public var title: String {
            switch self {
            case .status: "status"
            case .campaign: "campaign"
            case .repo: "repo"
            case .none: "none"
            }
        }
    }

    public enum Sort: String, CaseIterable, Hashable, Sendable, Codable {
        /// As they came, Parked last touched first: the sidebar as it always was.
        case attention
        /// The ones you touched last first.
        case touched
        /// The ones you have been away from longest first.
        case idle
        /// The newest first.
        case started

        public var title: String {
            switch self {
            case .attention: "attention"
            case .touched: "you, recent first"
            case .idle: "idle longest"
            case .started: "started"
            }
        }

        /// One word, for the header.
        public var short: String {
            switch self {
            case .attention: "attention"
            case .touched: "recent"
            case .idle: "idle"
            case .started: "newest"
            }
        }
    }

    public enum Rows: String, CaseIterable, Hashable, Sendable, Codable {
        case two, one

        public var title: String { self == .two ? "two lines" : "one line" }
    }

    public var grouping: Grouping
    public var sort: Sort
    public var rows: Rows

    public init(grouping: Grouping = .status, sort: Sort = .attention, rows: Rows = .two) {
        self.grouping = grouping
        self.sort = sort
        self.rows = rows
    }

    public static let standard = SessionsView()

    /// `repo · idle`: the header's dropdown label, short enough to sit beside the header.
    public var label: String { sort == .attention ? grouping.title : "\(grouping.title) · \(sort.short)" }

    /// The next value of a choice, wrapping: what `sessions.group` `sessions.sort` `sessions.rows` step to.
    public static func next<Choice: CaseIterable & Equatable>(_ value: Choice) -> Choice {
        let all = Array(Choice.allCases)
        let index = all.firstIndex(of: value) ?? 0
        return all[(index + 1) % all.count]
    }

    /// How long ago you touched a session, for its row: nothing under 15 minutes, then `48m`, `3h`, `2d`, `5w`.
    public static func idleText(since date: Date, now: Date) -> String? {
        let seconds = now.timeIntervalSince(date)
        guard seconds >= 15 * 60 else { return nil }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h" }
        let days = hours / 24
        return days < 14 ? "\(days)d" : "\(days / 7)w"
    }

    /// How warm the idle age is drawn: 0 under an hour, 1 under a day, 2 after.
    public static func idleWarmth(since date: Date, now: Date) -> Int {
        let seconds = now.timeIntervalSince(date)
        return seconds < 3600 ? 0 : seconds < 86400 ? 1 : 2
    }
}

/// The Mindmap campaign a session's work sits in, for grouping by campaign.
public struct SessionCampaign: Hashable, Sendable {
    public var id: String
    /// `Docs nav › Redirects`: the area, when it has one, then the campaign.
    public var title: String
    public var stage: MindNode.Stage?

    public init(id: String, title: String, stage: MindNode.Stage? = nil) {
        self.id = id
        self.title = title
        self.stage = stage
    }

    /// The campaign holding `entry`'s work in `tree`, nil when it is not placed in one.
    public static func of(entry: String, in tree: MindmapTree) -> SessionCampaign? {
        guard let work = tree.work(for: entry) else { return nil }
        let path = tree.path(to: work.id)
        guard let campaign = path.last(where: { $0.kind == .campaign }) else { return nil }
        let area = path.last { $0.kind == .area }
        return SessionCampaign(
            id: campaign.id, title: [area?.title, campaign.title].compactMap(\.self).joined(separator: " › "),
            stage: campaign.stage
        )
    }
}
