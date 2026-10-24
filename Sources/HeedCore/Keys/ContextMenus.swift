/// What a command acts on when a right-click names it, instead of what the cursor is on. Keys never set one, so the
/// keyboard keeps its cursor-based behaviour; a menu on a PR card acts on that PR, not on every PR of its session.
public enum CommandTarget: Hashable, Sendable {
    case session(String)
    case pull(PullRef)
    case issue(IssueRef)
    /// A get it green / get it merged run, by id.
    case run(String)
    /// A row of a list view (`inbox`, `issues`, `repos`, `history`…), by its id: the cursor moves there first, and the
    /// commands that act on the picked rows act on it alone unless it is one of them.
    case row(view: String, id: String)
    /// A repo, as the Issues repo column lists them.
    case repo(Repo)
    /// One of the session's tabs, by id: it is selected first.
    case tab(String)
    /// A line of the diff overlay (row 0 is the file's top): the overlay's cursor moves there first.
    case diffLine(file: Int, row: Int)
    /// A feedback item in the PR overlay or reader, by id: the cursor moves onto it first.
    case feedback(String)

    /// The PRs the pilot commands act on; nil when the target names no PR (the cursor decides).
    public var pulls: [PullRef]? {
        if case let .pull(ref) = self { [ref] } else { nil }
    }

    /// The row named in `view`, if this is one.
    public func row(in view: String) -> String? {
        if case let .row(named, id) = self, named == view { id } else { nil }
    }

    public var runID: String? {
        if case let .run(id) = self { id } else { nil }
    }

    /// What `gB` opens; nil when the target names nothing with a page of its own.
    public var url: String? {
        switch self {
        case let .pull(ref): ref.url
        case let .issue(ref): ref.url
        case .session, .run, .row, .repo, .tab, .diffLine, .feedback: nil
        }
    }

    /// What `gR` opens; nil when the target names no repo.
    public var repos: [Repo]? {
        switch self {
        case let .pull(ref): [ref.repo]
        case let .issue(ref): [ref.repo]
        case let .repo(repo): [repo]
        case .session, .run, .row, .tab, .diffLine, .feedback: nil
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
    /// A titled list of items that opens beside the menu ("Hand off to…").
    case submenu(String, [MenuItem])
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
        /// The agents it can be handed to (`agent.switch`): every configured one but its own.
        public var handoffAgents: [String] = []
        /// A chat: no repo, worktree or branch, so nothing that reads one (diff, PRs, the pilot, the repo) applies.
        public var chat = false
        /// A chat in a scratch folder heed made here: deleting it removes the folder.
        public var scratch = false

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
        let repo = !facts.chat
        var menu = Menu(header: facts.title)
        menu.section([
            item("Type into its agent", "session.agent"),
            repo && facts.pulls > 0 ? item("Open PR overlay", "overlay.item") : nil,
            repo ? item("Diff", "overlay.diff") : nil,
            facts.links > 0 || repo && facts.hasGitHubRepo
                ? item(facts.links > 1 ? "Open in browser…" : "Open in browser", "open.browser") : nil,
            repo && facts.hasGitHubRepo ? item("Open repo on GitHub", "open.repo") : nil,
        ])
        if repo, facts.pulls > 0 {
            menu.section(pilotItems(facts.pilot, open: facts.openPulls > 0, target: target))
        }
        menu.section([
            item(facts.pinned ? "Unpin" : "Pin", "session.pin"),
            item(facts.parked ? "Unpark" : "Park", "session.park"),
            facts
                .hasPrompt ? item(repo ? "Start again from its prompt" : "New chat from its prompt", "work.again") :
                nil,
        ])
        if facts.chat { menu.section([item("Promote to work…", "chat.promote")]) }
        menu.submenu("Hand off to…", handoffItems(facts.handoffAgents, target: target))
        menu.section(repo ? [
            item("Close, keep worktree", "session.close"),
            item("Delete with worktrees…", "session.delete"),
        ] : [
            item("Close", "session.close"),
            facts.scratch ? item("Delete with its scratch folder…", "session.delete") : nil,
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

    /// An Inbox or Issues row. `count` is how many rows the item commands act on: the picked ones when the row clicked
    /// is among them, else that row alone.
    public struct ItemFacts: Sendable {
        public enum Kind: Sendable { case inbox, issue }
        public var kind: Kind
        public var id: String
        public var title: String
        public var count = 1
        /// A session is selected that `a` can add to.
        public var hasSession = false
        public var unread = false
        /// Inbox items with a page on GitHub; CI notices have none of their own.
        public var hasURL = true
        /// The repo shows every open issue, not only yours (Issues).
        public var allIssues = false

        public init(kind: Kind, id: String, title: String) {
            self.kind = kind
            self.id = id
            self.title = title
        }
    }

    public static func item(_ facts: ItemFacts) -> [MenuEntry] {
        let view = facts.kind == .inbox ? "inbox" : "issues"
        let target = CommandTarget.row(view: view, id: facts.id)
        func item(_ title: String, _ name: String, enabled: Bool = true, checked: Bool = false) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), enabled: enabled, checked: checked)
        }
        let them = facts.count > 1 ? "the \(facts.count) picked" : "it"
        var menu = Menu(header: facts.title)
        menu.section([
            item("Open", "open.reader"),
            facts.hasURL ? item("Open in browser", "open.browser") : nil,
            item("Open repo on GitHub", "open.repo"),
        ])
        menu.section([
            item("Start a session from \(them)", "items.start"),
            item("Add \(them) to this session", "items.add", enabled: facts.hasSession),
        ])
        switch facts.kind {
        case .inbox:
            menu.section([item(
                facts.count > 1 ? "Mark \(them) read" : "Mark read",
                "items.read",
                enabled: facts.unread
            )])
        case .issue:
            menu.section([item("All issues from its repo", "issues.visibility", checked: facts.allIssues)])
        }
        return menu.entries
    }

    /// An Attention row. `count` is how many rows the actions act on (the picked ones when the row clicked is among
    /// them, else that row alone).
    public struct AttentionFacts: Sendable {
        public var id: String
        public var title: String
        public var count = 1
        public var hasSession = false
        /// The item's own session (an agent's, or one tracking the thread).
        public var itemSession = false
        public var hasURL = true
        /// A GitHub notification thread, which done marks read and mute ignores.
        public var hasThread = true
        public var isAgent = false

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static func attention(_ facts: AttentionFacts) -> [MenuEntry] {
        let target = CommandTarget.row(view: "attention", id: facts.id)
        func item(_ title: String, _ name: String, _ arguments: [String] = [], enabled: Bool = true) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, arguments: arguments, target: target), enabled: enabled)
        }
        let them = facts.count > 1 ? "the \(facts.count) picked" : "it"
        var menu = Menu(header: facts.title)
        menu.section([
            facts.isAgent ? nil : item("Open", "open.reader"),
            facts.hasURL ? item("Open in browser", "open.browser") : nil,
            item("Go to its session", "attention.session", enabled: facts.itemSession),
        ])
        if !facts.isAgent {
            menu.section([
                item("Draft a reply…", "attention.reply", enabled: facts.count == 1 && facts.hasURL),
                item("Start a session from \(them)", "items.start"),
                item("Add \(them) to this session", "items.add", enabled: facts.hasSession),
            ])
        }
        menu.section([
            item(facts.count > 1 ? "Done with \(them)" : "Done", "attention.done"),
            item("Snooze 1 hour", "attention.snooze", ["1h"]),
            item("Snooze until tomorrow", "attention.snooze", ["tomorrow"]),
            facts.isAgent ? nil : item("Mute thread", "attention.mute", enabled: facts.hasThread),
        ])
        return menu.entries
    }

    /// A repo in the Issues repo column; nil is its All row.
    /// A repo in the Repos view's column: its setup for get it merged and get it green first.
    public static func repo(_ repo: Repo, allIssues: Bool) -> [MenuEntry] {
        let target = CommandTarget.repo(repo)
        let onGitHub = repo.org != "local"
        var menu = Menu(header: repo.slug)
        menu.section([
            onGitHub ? MenuItem("Set up merging and green…", CommandInvocation(name: "repo.setup", target: target)) :
                nil,
        ])
        menu.section([
            MenuItem(
                "All issues, not only yours", CommandInvocation(name: "issues.visibility", target: target),
                checked: allIssues
            ),
            onGitHub ? MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target)) : nil,
        ])
        return menu.entries
    }

    public static func issueRepo(_ repo: Repo?, allIssues: Bool) -> [MenuEntry] {
        guard let repo else {
            var menu = Menu(header: "Every repo")
            menu.section([MenuItem("Show every repo's issues", CommandInvocation(name: "issues.repo"))])
            return menu.entries
        }
        let target = CommandTarget.repo(repo)
        var menu = Menu(header: repo.slug)
        menu.section([
            MenuItem("Show its issues", CommandInvocation(name: "issues.repo", target: target)),
            MenuItem(
                "All issues, not only yours", CommandInvocation(name: "issues.visibility", target: target),
                checked: allIssues
            ),
        ])
        if repo.org != "local" {
            menu.section([MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target))])
        }
        return menu.entries
    }

    /// A worktree in Repos. `count` is how many rows the selection commands act on.
    public struct WorktreeFacts: Sendable {
        public var id: String
        public var title: String
        public var count = 1
        public var hasSession = false
        public var pinned = false
        public var isMain = false
        public var onGitHub = true
        public var allIssues = false

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static func worktree(_ facts: WorktreeFacts) -> [MenuEntry] {
        let target = CommandTarget.row(view: "repos", id: facts.id)
        func item(_ title: String, _ name: String, checked: Bool = false) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), checked: checked)
        }
        let several = facts.count > 1
        var menu = Menu(header: facts.title)
        menu.section([
            item(
                several ? "Open or import the \(facts.count) selected" : facts.hasSession ? "Go to its session"
                    : "Import as a session",
                "select.open"
            ),
            item("Start work in this repo", "worktree.new"),
        ])
        menu.section([
            item(several ? "Copy \(facts.count) paths" : "Copy path", "select.copy"),
            facts.hasSession || several ? item(
                several ? "Pin their sessions" : "Pin its session",
                "select.pin",
                checked: facts.pinned
            ) : nil,
            facts.onGitHub ? item("Open repo on GitHub", "open.repo") : nil,
            item("All issues from this repo", "issues.visibility", checked: facts.allIssues),
        ])
        menu.section([
            item("Run the cleanup sweep…", "cleanup.sweep"),
            item("Setup for new worktrees…", "setup.review"),
            facts.onGitHub ? item("Set up merging and green…", "repo.setup") : nil,
        ])
        // The repo's own checkout is never removed.
        if !facts.isMain || several {
            menu.section([item(several ? "Remove \(facts.count) worktrees…" : "Remove worktree…", "select.remove")])
        }
        return menu.entries
    }

    /// A call in the call log: copy it, or narrow the log to its caller or agent (unnarrow when it already is).
    public static func call(
        id: Int64, title: String, caller: String, agent: String?, callerFiltered: Bool, agentFiltered: Bool
    ) -> [MenuEntry] {
        let target = CommandTarget.row(view: "log", id: String(id))
        var menu = Menu(header: title)
        menu.section([
            MenuItem("Copy command", CommandInvocation(name: "log.copy", target: target)),
            MenuItem(
                callerFiltered ? "Every caller" : "Only \(caller)", CommandInvocation(
                    name: "log.caller",
                    target: target
                )
            ),
            agent.map { agent in
                MenuItem(
                    agentFiltered ? "Every agent" : "Only \(agent)", CommandInvocation(
                        name: "log.agent",
                        target: target
                    )
                )
            },
        ])
        return menu.entries
    }

    /// A session in History.
    public static func history(
        id: String, title: String, hasPrompt: Bool, chat: Bool = false, onGitHub: Bool
    ) -> [MenuEntry] {
        let target = CommandTarget.row(view: "history", id: id)
        var menu = Menu(header: title)
        menu.section([
            MenuItem("Reopen", CommandInvocation(name: "history.reopen", target: target)),
            hasPrompt ? MenuItem(
                chat ? "New chat from its prompt" : "Start again from its prompt",
                CommandInvocation(name: "history.again", target: target)
            )
                : nil,
            onGitHub ? MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target)) : nil,
        ])
        return menu.entries
    }

    /// A line of History's timeline: its session can be reopened when it is in History, and the line's kind shown
    /// alone.
    public static func timeline(
        id: String, title: String, kind: String, reopenable: Bool, onGitHub: Bool
    ) -> [MenuEntry] {
        let target = CommandTarget.row(view: "timeline", id: id)
        var menu = Menu(header: title)
        menu.section([
            reopenable ? MenuItem("Reopen", CommandInvocation(name: "history.reopen", target: target)) : nil,
            MenuItem("Only \(kind)", CommandInvocation(name: "timeline.kind", arguments: [kind], target: target)),
            onGitHub ? MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target)) : nil,
        ])
        menu.section([MenuItem("Back to the list", CommandInvocation(name: "history.timeline"))])
        return menu.entries
    }

    /// A recent session on the dashboard.
    public static func dashboard(id: String, title: String, reopenable: Bool, onGitHub: Bool) -> [MenuEntry] {
        let target = CommandTarget.row(view: "dashboard", id: id)
        var menu = Menu(header: title)
        menu.section([
            reopenable ? MenuItem("Reopen", CommandInvocation(name: "history.reopen", target: target)) : nil,
            onGitHub ? MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target)) : nil,
            MenuItem("Next range", CommandInvocation(name: "dashboard.range")),
        ])
        menu.section([MenuItem("Back to the list", CommandInvocation(name: "history.dashboard"))])
        return menu.entries
    }

    /// A ledger entry: write its summary again, edit it, reopen its session when it is in History.
    public static func ledger(id: String, title: String, reopenable: Bool, onGitHub: Bool) -> [MenuEntry] {
        let target = CommandTarget.row(view: "ledger", id: id)
        var menu = Menu(header: title)
        menu.section([
            MenuItem("Write the summary again", CommandInvocation(name: "ledger.summarize", target: target)),
            MenuItem("Edit the summary", CommandInvocation(name: "ledger.edit", target: target)),
            reopenable ? MenuItem("Reopen", CommandInvocation(name: "history.reopen", target: target)) : nil,
            onGitHub ? MenuItem("Open repo on GitHub", CommandInvocation(name: "open.repo", target: target)) : nil,
        ])
        menu.section([MenuItem("Back to the list", CommandInvocation(name: "history.ledger"))])
        return menu.entries
    }

    /// A tab of the session. A run's tab can stop its run; the agent's tab can hand the session to another agent
    /// (`handoffAgents`, empty for every other tab).
    public static func tab(
        id: String, title: String, zoomed: Bool, runLive: Bool, handoffAgents: [String] = []
    ) -> [MenuEntry] {
        let target = CommandTarget.tab(id)
        func item(_ title: String, _ name: String, checked: Bool = false) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), checked: checked)
        }
        var menu = Menu(header: title)
        menu.section([
            item("New tab", "tab.new"),
            item("Split right", "pane.split.right"),
            item("Split below", "pane.split.below"),
            item("Zoom pane", "pane.zoom", checked: zoomed),
        ])
        if runLive { menu.section([item("Stop run", "pilot.run.stop")]) }
        menu.submenu("Hand off to…", handoffItems(handoffAgents, target: target))
        menu.section([item("Close tab", "tab.close")])
        return menu.entries
    }

    /// A file in the diff overlay's list, or a line of its diff (`line` false: the file, at its top). `selected`: the
    /// line is in the selection, and the items act on all its lines.
    public static func diff(
        file: Int, row: Int, path: String, line _: Bool, split: Bool, hasCommits: Bool, selected: Bool = false
    ) -> [MenuEntry] {
        let target = CommandTarget.diffLine(file: file, row: row)
        func item(_ title: String, _ name: String, checked: Bool = false, enabled: Bool = true) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), enabled: enabled, checked: checked)
        }
        var menu = Menu(header: path.split(separator: "/").last.map(String.init) ?? path)
        menu.section([
            item(selected ? "Copy path:lines" : "Copy path:line", "diff.copy"),
            item("Open in editor", "diff.edit"),
            item(selected ? "Note on these lines" : "Note on this hunk", "diff.ask"),
            item(selected ? "Ask the agent about these lines now" : "Ask the agent now", "diff.ask.now"),
        ])
        menu.section([
            item("Show one commit", "diff.commit", enabled: hasCommits),
            item("Split view", "diff.split", checked: split),
        ])
        return menu.entries
    }

    /// A feedback item in the PR overlay or reader.
    public struct FeedbackFacts: Sendable {
        public var id: String
        public var title: String
        /// New or queued: what `␣` flips between.
        public var queueable = false
        public var queued = false
        /// Anything queued to send, this one or others.
        public var anyQueued = false
        /// About a PR; false for the session's own notes.
        public var onPull = true

        public init(id: String, title: String) {
            self.id = id
            self.title = title
        }
    }

    public static func feedback(_ facts: FeedbackFacts) -> [MenuEntry] {
        let target = CommandTarget.feedback(facts.id)
        func item(_ title: String, _ name: String, enabled: Bool = true, checked: Bool = false) -> MenuItem {
            MenuItem(title, CommandInvocation(name: name, target: target), enabled: enabled, checked: checked)
        }
        var menu = Menu(header: facts.title)
        menu.section([
            item("Queued", "feedback.queue", enabled: facts.queueable, checked: facts.queued),
            item("Send queued feedback", "feedback.send", enabled: facts.anyQueued),
            item("Dismiss", "feedback.dismiss"),
        ])
        if facts.onPull {
            menu.section([
                item("Start a session from this PR", "feedback.session"),
                item("Open the PR in browser", "open.browser"),
            ])
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

    /// `agent.switch <name>` for each agent, acting on what the menu is about.
    static func handoffItems(_ agents: [String], target: CommandTarget) -> [MenuItem] {
        agents.map { MenuItem($0, CommandInvocation(name: "agent.switch", arguments: [$0], target: target)) }
    }

    /// Sections with a separator between them; a section with nothing in it leaves no trace.
    struct Menu {
        var entries: [MenuEntry]

        init(header: String) { entries = [.header(header)] }

        mutating func section(_ items: [MenuItem?]) {
            let kept = items.compactMap(\.self)
            guard !kept.isEmpty else { return }
            separate()
            entries += kept.map(MenuEntry.item)
        }

        /// A submenu as a section of its own; none when it would be empty.
        mutating func submenu(_ title: String, _ items: [MenuItem]) {
            guard !items.isEmpty else { return }
            separate()
            entries.append(.submenu(title, items))
        }

        /// A separator before the next section, unless nothing but the header is above it.
        private mutating func separate() {
            if entries.contains(where: { if case .header = $0 { false } else { true } }) { entries.append(.separator) }
        }
    }
}
