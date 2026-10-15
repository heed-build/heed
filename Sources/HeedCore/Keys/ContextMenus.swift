/// What a command acts on when a right-click names it, instead of what the cursor is on. Keys never set one, so the
/// keyboard keeps its cursor-based behaviour; a menu on a PR card acts on that PR, not on every PR of its session.
public enum CommandTarget: Hashable, Sendable {
    case session(String)
    case pull(PullRef)
    case issue(IssueRef)
    /// A get it green / get it merged run, by id.
    case run(String)

    /// The PRs the pilot commands act on; nil when the target names no PR (the cursor decides).
    public var pulls: [PullRef]? {
        if case let .pull(ref) = self { [ref] } else { nil }
    }

    public var runID: String? {
        if case let .run(id) = self { id } else { nil }
    }

    /// What `gB` opens; nil when the target names nothing with a page of its own.
    public var url: String? {
        switch self {
        case let .pull(ref): ref.url
        case let .issue(ref): ref.url
        case .session, .run: nil
        }
    }

    /// What `gR` opens; nil when the target names no repo.
    public var repos: [Repo]? {
        switch self {
        case let .pull(ref): [ref.repo]
        case let .issue(ref): [ref.repo]
        case .session, .run: nil
        }
    }
}

/// One line of a right-click menu: a command, with a short label. The menu shows the command's key beside it.
public struct MenuItem: Equatable, Sendable {
    public let title: String
    public let command: CommandInvocation
    public var enabled: Bool
    /// A check mark: the setting the command flips is on (watching, get it merged, paused, pinned).
    public var checked: Bool

    public init(_ title: String, _ command: CommandInvocation, enabled: Bool = true, checked: Bool = false) {
        self.title = title
        self.command = command
        self.enabled = enabled
        self.checked = checked
    }

    /// The command whose key is shown: by name, so `pr.untrack <url>` shows `:pr.untrack` when nothing binds it.
    public var keyCommand: String { command.name }
}

public enum MenuEntry: Equatable, Sendable {
    /// The thing the menu is about, greyed at the top.
    case header(String)
    case item(MenuItem)
    case separator
}

/// The right-click menus, from plain facts about what was clicked. Items that cannot apply are left out; items that
/// apply but cannot run now are disabled. Every item runs a command that has a key or a `:` name.
public enum ContextMenus {
    /// A session row in the sidebar or the rail.
    public struct SessionFacts: Sendable {
        public var id: String
        public var title: String
        /// Tracked PRs, and how many of them are still open.
        public var pulls = 0
        public var openPulls = 0
        /// PRs and issues together (`gB` opens the one, or offers a picker over several, or the repo with none).
        public var links = 0
        /// Has a repo on GitHub (`gR`); a local-only repo has none.
        public var hasGitHubRepo = false
        public var pilot = PilotFacts()
        public var pinned = false
        public var parked = false
        public var hasPrompt = false

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    /// Where the pilot stands for the PRs a menu acts on.
    public struct PilotFacts: Sendable {
        public var watching = false
        public var green = false
        public var merging = false
        public var paused = false
        public var stalled = false
        public var runLive = false
        public var reviewers = false

        public init() {}
    }

    /// Where a PR menu opens: on a session's card in the inspector, or on a PRs or Watch row.
    public enum Place: Sendable { case inspector, prs, watch }

    public struct PullFacts: Sendable {
        public var ref: PullRef
        public var place: Place
        /// Open, or not known yet: the pilot only acts on open PRs.
        public var open = true
        public var pilot = PilotFacts()
        /// A session tracks it (`gS` goes there).
        public var hasSession = false

        public init(ref: PullRef, place: Place) {
            self.ref = ref
            self.place = place
        }
    }

    public static func session(_ facts: SessionFacts) -> [MenuEntry] {
        let target = CommandTarget.session(facts.id)
        func item(_ title: String, _ name: String, enabled: Bool = true, checked: Bool = false) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), enabled: enabled, checked: checked)
        }
        var menu = Menu(header: facts.title)
        menu.section([
            facts.pulls > 0 ? item("Open PR overlay", "overlay.item") : nil,
            item("Diff", "overlay.diff"),
            facts.links > 0 || facts.hasGitHubRepo
                ? item(facts.links > 1 ? "Open in browser…" : "Open in browser", "open.browser") : nil,
            facts.hasGitHubRepo ? item("Open repo on GitHub", "open.repo") : nil,
        ])
        if facts.pulls > 0 {
            menu.section(pilotItems(facts.pilot, open: facts.openPulls > 0, target: target))
        }
        menu.section([
            item(facts.pinned ? "Unpin" : "Pin", "session.pin"),
            item(facts.parked ? "Unpark" : "Park", "session.park"),
            facts.hasPrompt ? item("Start again from its prompt", "work.again") : nil,
        ])
        menu.section([
            item("Close, keep worktree", "session.close"),
            item("Delete with worktrees…", "session.delete"),
        ])
        return menu.entries
    }

    public static func pull(_ facts: PullFacts) -> [MenuEntry] {
        let ref = facts.ref
        let target = CommandTarget.pull(ref)
        func item(_ title: String, _ name: String, _ arguments: [String] = []) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, arguments: arguments, target: target))
        }
        var menu = Menu(header: "\(ref.repo.name) #\(ref.number)")
        menu.section([
            item(facts.place == .inspector ? "Open here" : "Open", "overlay.item"),
            item("Open in browser", "open.browser"),
            facts.place == .inspector ? nil : item("Open repo on GitHub", "open.repo"),
            facts.hasSession ? item("Go to its session", "pr.session") : nil,
        ])
        var pilot = [MenuItem(
            "Watch", CommandInvocation(name: "pilot.watch", target: target), enabled: facts.open,
            checked: facts.pilot.watching
        )]
        pilot += pilotItems(facts.pilot, open: facts.open, target: target, copilot: true)
        menu.section(pilot)
        if facts.place == .watch {
            menu.section([item("Run its merge queue now", "merge.run"), item("Show its merge queue", "merge.queue")])
        }
        if facts.place == .inspector {
            menu.section([item("Stop tracking", "pr.untrack", [ref.url])])
        }
        return menu.entries
    }

    /// An issue linked to a session, in the inspector.
    public static func issue(_ ref: IssueRef) -> [MenuEntry] {
        let target = CommandTarget.issue(ref)
        var menu = Menu(header: "\(ref.repo.name) #\(ref.number)")
        menu.section([
            MenuItem("Open here", CommandInvocation(name: "overlay.item", target: target)),
            MenuItem("Open in browser", CommandInvocation(name: "open.browser", target: target)),
        ])
        menu.section([
            MenuItem(
                "Remove from session",
                CommandInvocation(name: "issue.remove", arguments: [ref.url], target: target)
            ),
        ])
        return menu.entries
    }

    /// A run in the inspector: a running one goes to its tab or stops, an ended one opens in the reader.
    public static func run(id: String, title: String, running: Bool) -> [MenuEntry] {
        let target = CommandTarget.run(id)
        var menu = Menu(header: title)
        if running {
            menu.section([
                MenuItem("Go to its tab", CommandInvocation(name: "pilot.run", target: target)),
                MenuItem("Stop run", CommandInvocation(name: "pilot.run.stop", target: target)),
            ])
        } else {
            menu.section([MenuItem("Read what it did", CommandInvocation(name: "open.reader", target: target))])
        }
        return menu.entries
    }

    /// The pilot's commands for a session's PRs or one PR. Turning things on needs an open PR; asking why does not.
    static func pilotItems(
        _ pilot: PilotFacts, open: Bool, target: CommandTarget, copilot: Bool = false
    ) -> [MenuItem] {
        func item(_ title: String, _ name: String, checked: Bool = false, enabled: Bool? = nil) -> MenuItem {
            MenuItem(
                title, CommandInvocation(name: name, target: target), enabled: enabled ?? open, checked: checked
            )
        }
        var items = [
            item("Get it green: off / ask / auto", "pilot.green", checked: pilot.green),
            item("Get it merged", "pilot.merge", checked: pilot.merging),
            item("Pause", "pilot.pause", checked: pilot.paused),
        ]
        if pilot.stalled { items.append(item("One more round", "pilot.retry")) }
        if copilot {
            items.append(item("Ask Copilot", "pilot.copilot"))
            if pilot.reviewers { items.append(item("Ask reviewers", "pilot.reviewers")) }
        }
        items.append(item("What will heed do?", "pilot.why", enabled: true))
        if pilot.runLive {
            items.append(item("Go to its run", "pilot.run", enabled: true))
            items.append(item("Stop run", "pilot.run.stop", enabled: true))
        }
        return items
    }

    /// Sections with a separator between them; a section with nothing in it leaves no trace.
    struct Menu {
        var entries: [MenuEntry]

        init(header: String) { entries = [.header(header)] }

        mutating func section(_ items: [MenuItem?]) {
            let kept = items.compactMap(\.self)
            guard !kept.isEmpty else { return }
            if entries.contains(where: { if case .item = $0 { true } else { false } }) { entries.append(.separator) }
            entries += kept.map(MenuEntry.item)
        }
    }
}
