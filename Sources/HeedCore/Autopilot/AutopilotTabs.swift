/// Autopilot's views, as the strip above them shows them: each with the command (and so the key) that opens it and a
/// count of what is in it. Every Autopilot view binds the same capitals to them, so the strip reads the same wherever
/// you are.
public enum AutopilotTabs {
    public struct Tab: Hashable, Sendable, Identifiable {
        /// The view's name (its key scope): `autopilot`, `where`, `watch`, `done`.
        public var pane: String
        public var title: String
        public var command: String
        public var count: Int
        public var id: String { pane }
    }

    public struct Counts: Hashable, Sendable {
        /// Capabilities off somewhere.
        public var off = 0
        /// PRs heed is working on or stopped on.
        public var now = 0
        /// What heed did this week.
        public var done = 0

        public init(off: Int = 0, now: Int = 0, done: Int = 0) {
            self.off = off
            self.now = now
            self.done = done
        }
    }

    /// The area's name, in the title bar and the menus.
    public static let area = "Autopilot"

    /// The view `gw` (`view.autopilot`) opens.
    public static let home = "autopilot"

    public static let panes: [(pane: String, title: String, command: String)] = [
        ("autopilot", "Can do", "autopilot.cando"),
        ("where", "Where", "autopilot.where"),
        ("watch", "Now", "autopilot.now"),
        ("done", "Done", "autopilot.done"),
    ]

    /// The keys every Autopilot view binds to its tabs.
    public static let keys: [(String, String)] = [
        ("C", "autopilot.cando"), ("W", "autopilot.where"), ("N", "autopilot.now"), ("D", "autopilot.done"),
    ]

    public static func tabs(counts: Counts = Counts()) -> [Tab] {
        panes.map { pane in
            let count = switch pane.pane {
            case "where": counts.off
            case "watch": counts.now
            case "done": counts.done
            default: 0
            }
            return Tab(pane: pane.pane, title: pane.title, command: pane.command, count: count)
        }
    }

    /// `this week heed took 41 things off your hands`, as lead, figure and tail.
    public static func strip(done: Int) -> (lead: String, figure: String, tail: String) {
        if done == 0 { return ("heed has done nothing on its own this week", "", "") }
        return ("this week heed took ", "\(done) thing\(done == 1 ? "" : "s")", " off your hands")
    }
}
