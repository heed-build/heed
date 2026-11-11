/// History's views, as the tab strip above them shows them: each with the command (and so the key) that opens it, and
/// a count of what is in it. Every History view keeps the same capitals for the others, so the strip reads the same
/// wherever you are.
public enum HistoryPaneTabs {
    public struct Tab: Hashable, Sendable, Identifiable {
        /// The view's name (`AppView`'s raw value): `history`, `timeline`, `ledger`, `dashboard`.
        public var pane: String
        public var title: String
        public var command: String
        public var count: Int
        public var id: String { pane }
    }

    public struct Counts: Hashable, Sendable {
        /// Sessions that ended.
        public var sessions = 0
        /// Pieces of work in the ledger.
        public var ledger = 0
        /// Follow-ups still open in the Mindmap shown.
        public var open = 0

        public init(sessions: Int = 0, ledger: Int = 0, open: Int = 0) {
            self.sessions = sessions
            self.ledger = ledger
            self.open = open
        }
    }

    /// The panes, and the commands every History view binds to the same keys.
    public static let panes: [(pane: String, title: String, command: String)] = [
        ("history", "Sessions", "history.list"),
        ("timeline", "Timeline", "history.timeline"),
        ("ledger", "Ledger", "history.ledger"),
        ("dashboard", "Dashboard", "history.dashboard"),
        ("mindmap", "Mindmap", "history.mindmap"),
        ("standup", "Standup", "history.standup"),
    ]

    public static func tabs(counts: Counts = Counts()) -> [Tab] {
        panes.map { pane in
            let count = switch pane.pane {
            case "history": counts.sessions
            case "ledger": counts.ledger
            case "mindmap": counts.open
            default: 0
            }
            return Tab(pane: pane.pane, title: pane.title, command: pane.command, count: count)
        }
    }

    /// The breadcrumb: `History › Ledger`.
    public static func crumb(pane: String) -> [String] {
        ["History", panes.first { $0.pane == pane }?.title ?? pane]
    }
}
