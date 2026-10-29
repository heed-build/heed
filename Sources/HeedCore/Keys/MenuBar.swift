/// The macOS menu bar, for the mouse: every command heed has, under File, Session, View, PR, Go, Window and Help, each
/// with its key drawn beside it as text (as the right-click menus do). It registers no key equivalents of its own:
/// heed's keys are sequences the mode engine reads, and a menu that claimed `o` or `gd` would take them from terminals.
///
/// Built from plain facts about where you are, like the right-click menus, and from those menus themselves: an item a
/// session's or a PR's right-click menu offers is enabled, checked and targeted here exactly as it is there, so the two
/// can not disagree on what can run now. Everything else is enabled by the view or overlay it acts in.
public enum MenuBar {
    /// Where you are when the menu bar opens.
    public struct Facts: Sendable {
        /// The selected session, as its right-click menu sees it; nil with none.
        public var session: ContextMenus.SessionFacts?
        /// The PR in front: the one open in the PR overlay or the reader, or the PRs or Watch row under the cursor.
        public var pull: ContextMenus.PullFacts?
        /// The view you are on (`sessions`, `attention`, `timeline`…).
        public var view = "sessions"
        /// What keys read now: the view's name, or `diff`, `pr` or `issue` while an overlay or the reader is open.
        public var scope = "sessions"
        /// The pinned sessions' titles, in `pin.jump` order.
        public var pinned: [String] = []
        /// The selected session's tabs, and the panes in its open tab.
        public var tabs = 0
        public var panes = 0
        public var zoomed = false
        /// The view has a filter typed.
        public var filtered = false
        public var sidebarShown = true
        public var inspectorShown = true
        /// The tutor is running (its steps can be gone back, skipped or left).
        public var tutor = false
        /// Hunch: a checkpoint is downloading; the configured one is downloaded.
        public var hunchDownloading = false
        public var hunchReady = false

        public init() {}
    }

    public struct Menu: Equatable, Sendable {
        public let title: String
        public let entries: [MenuEntry]

        public init(_ title: String, _ entries: [MenuEntry]) {
            self.title = title
            self.entries = entries
        }

        /// Its items, those in submenus too.
        public var items: [MenuItem] {
            entries.flatMap { entry -> [MenuItem] in
                switch entry {
                case let .item(item): [item]
                case let .submenu(_, items): items
                case .header, .separator: []
                }
            }
        }
    }

    /// The docs, for Help's last item (a link, not a command).
    public static let docsURL = "https://heed.build/getting-started/"

    /// Commands the menu bar leaves out, and why. Every other command is in some menu (a test holds it to that).
    public static let unlisted: [String: String] = [
        "row.next": "moving the cursor: the mouse clicks rows and scrolls",
        "row.prev": "moving the cursor: the mouse clicks rows and scrolls",
        "row.first": "moving the cursor: the mouse clicks rows and scrolls",
        "row.last": "moving the cursor: the mouse clicks rows and scrolls",
        "goal.item.column": "moving the board's cursor: the mouse clicks a card in any column",
        "row.halfpage.down": "moving the cursor: the mouse clicks rows and scrolls",
        "row.halfpage.up": "moving the cursor: the mouse clicks rows and scrolls",
        "group.next": "moving the cursor: the mouse clicks rows and scrolls",
        "group.prev": "moving the cursor: the mouse clicks rows and scrolls",
        "select.toggle": "picks the row under the cursor; the menu bar has no row of its own",
        "view": "each view has its own item (view.sessions, view.attention…)",
        "overlay.close": "⎋ closes what is open",
        "mode.normal": "⎋, or a click outside the terminal, leaves INSERT",
        "command.submit": "a key of the command line itself",
        "command.complete": "a key of the command line itself",
        "command.complete.prev": "a key of the command line itself",
        "feedback.mode": "pilot.green's former name; PR has Get it green",
        "feedback.watch": "pilot.watch's former name; PR has Watch",
        "app.quit": "the app menu's Quit Heed (⌘Q)",
        "settings.open": "the app menu's Settings… (⌘,)",
        "update.check": "the app menu's Check for Updates…",
        "app.activate": "brings the window forward, which clicking the menu bar has already done",
        "swarm.host": "the new swarm form's Where chips, which only that form shows",
    ]

    /// An item whose command needs words the menu cannot know (`pr.track <url>`): it opens the command line with the
    /// command typed instead of running it.
    public static func asks(_ item: MenuItem) -> Bool {
        guard item.command.arguments.isEmpty, let arguments = Commands.spec(item.command.name)?.arguments else {
            return false
        }
        return arguments.hasPrefix("<")
    }

    public static func menus(_ facts: Facts) -> [Menu] {
        let builder = Builder(facts)
        return [
            builder.file(), builder.session(), builder.view(), builder.pr(), builder.go(), builder.window(),
            builder.help(),
        ]
    }

    private struct Builder {
        let facts: Facts
        /// What the right-click menus of the selected session and of the PR in front offer, their submenus too.
        let sessionOffers: [MenuItem]
        let pullOffers: [MenuItem]

        init(_ facts: Facts) {
            self.facts = facts
            sessionOffers = facts.session.map { Menu("", ContextMenus.session($0)).items } ?? []
            pullOffers = facts.pull.map { Menu("", ContextMenus.pull($0)).items } ?? []
        }

        var hasSession: Bool { facts.session != nil }
        var hasRepo: Bool { facts.session.map { !$0.chat } ?? false }
        var sessionTarget: CommandTarget? { facts.session.map { .session($0.id) } }
        var pullTarget: CommandTarget? { facts.pull.map { .pull($0.ref) } ?? sessionTarget }
        /// The PR in front is open, or the session has an open PR.
        var openPull: Bool { facts.pull.map(\.open) ?? (hasRepo && (facts.session?.openPulls ?? 0) > 0) }
        var anyPull: Bool { facts.pull != nil || hasRepo && (facts.session?.pulls ?? 0) > 0 }
        var historyViews: Set<String> { ["history", "timeline", "ledger", "dashboard"] }

        func item(
            _ title: String, _ name: String, _ arguments: [String] = [], enabled: Bool = true, checked: Bool = false,
            target: CommandTarget? = nil
        ) -> MenuEntry {
            .item(MenuItem(
                title, CommandInvocation(name: name, arguments: arguments, target: target), enabled: enabled,
                checked: checked
            ))
        }

        /// As the session's right-click menu has it; otherwise on the session, enabled when `otherwise` says so.
        func session(_ title: String, _ name: String, otherwise: Bool = false, checked: Bool? = nil) -> MenuEntry {
            offered(title, name, in: sessionOffers, target: sessionTarget, otherwise: otherwise, checked: checked)
        }

        /// As the right-click menu of the PR in front has it, or else the session's (which acts on all its PRs).
        func pull(_ title: String, _ name: String, otherwise: Bool = false) -> MenuEntry {
            offered(title, name, in: pullOffers + sessionOffers, target: pullTarget, otherwise: otherwise)
        }

        private func offered(
            _ title: String, _ name: String, in offers: [MenuItem], target: CommandTarget?, otherwise: Bool,
            checked: Bool? = nil
        ) -> MenuEntry {
            if let offer = offers.first(where: { $0.command.name == name && $0.command.arguments.isEmpty }) {
                return .item(MenuItem(title, offer.command, enabled: offer.enabled, checked: checked ?? offer.checked))
            }
            return item(title, name, enabled: otherwise, checked: checked ?? false, target: target)
        }

        /// Items for one view or overlay: enabled only there, acting on its cursor as the keys do.
        func scoped(_ title: String, _ items: [(String, String)], in scopes: Set<String>) -> MenuEntry {
            let here = scopes.contains(facts.scope) || scopes.contains(facts.view)
            return .submenu(title, items.map { MenuItem($0.0, CommandInvocation(name: $0.1), enabled: here) })
        }

        /// `scoped`, for commands with arguments (`goal.item.move left`).
        func scopedInvocations(_ title: String, _ items: [(String, String)], in scopes: Set<String>) -> MenuEntry {
            let here = scopes.contains(facts.scope)
            return .submenu(title, items.map { MenuItem($0.0, CommandInvocation(parsing: $0.1), enabled: here) })
        }

        func file() -> Menu {
            Menu("File", [
                item("Start work…", "work.start"),
                item("Start work in the floating panel…", "work.start.panel"),
                item("New chat…", "chat.new"),
                .separator,
                item("Import a worktree…", "session.import"),
                item("Import a worktree by path…", "session.import.path"),
                item("Add a repo…", "repo.add"),
                .separator,
                item("Resume where you left off…", "resume"),
                item("While you were away…", "summary"),
                .separator,
                item("Sync GitHub now", "github.sync"),
                item("Rescan the repo roots", "repo.scan"),
                item("Run the cleanup sweep", "cleanup.sweep"),
                item("Cleanup rules", "cleanup.rules"),
                .separator,
                item("Edit config.toml", "config.edit"),
                item("Find git and gh again", "tools.detect"),
            ])
        }

        func session() -> Menu {
            let agents = facts.session?.handoffAgents ?? []
            let handoff: MenuEntry = agents.isEmpty
                ? item("Hand off to…", "agent.switch", enabled: false, target: sessionTarget)
                : .submenu("Hand off to…", ContextMenus.handoffItems(agents, target: sessionTarget ?? .session("")))
            return Menu("Session", [
                session("Type into its agent", "session.agent"),
                item("Type into the focused pane", "mode.insert", enabled: facts.panes > 0),
                .separator,
                session("Pin", "session.pin", checked: facts.session?.pinned ?? false),
                session("Park", "session.park", checked: facts.session?.parked ?? false),
                session(
                    facts.session?.chat == true ? "New chat from its prompt" : "Start again from its prompt",
                    "work.again"
                ),
                handoff,
                session("Promote to work…", "chat.promote"),
                .separator,
                session("Go to its goal", "goal.jump"),
                session("Put on a goal…", "goal.attach"),
                session("Take off its goal", "goal.detach"),
                session("New goal from this session…", "goal.new"),
                session("Find its goal", "goal.attach.find"),
                .separator,
                item("Run a task…", "task.run", enabled: hasSession, target: sessionTarget),
                item("Read its tasks again", "task.refresh", enabled: hasSession, target: sessionTarget),
                .separator,
                item("Link an issue…", "issue.add", enabled: hasRepo, target: sessionTarget),
                item("Take an issue off…", "issue.remove", enabled: hasRepo, target: sessionTarget),
                .separator,
                session(hasRepo ? "Close, keep worktree" : "Close", "session.close"),
                session("Delete with worktrees…", "session.delete"),
                .separator,
                item("Stop every agent", "agents.stop"),
            ])
        }

        func view() -> Menu {
            func view(_ title: String, _ name: String, _ view: String) -> MenuEntry {
                item(title, name, checked: facts.view == view)
            }
            return Menu("View", [
                view("Sessions", "view.sessions", "sessions"),
                view("Attention", "view.attention", "attention"),
                view("Inbox", "view.inbox", "inbox"),
                view("Issues", "view.issues", "issues"),
                view("Pull requests", "view.prs", "prs"),
                view("Watch", "view.watch", "watch"),
                view("Repos & worktrees", "view.repos", "repos"),
                view("History", "view.history", "history"),
                view("Timeline", "view.timeline", "timeline"),
                view("Ledger", "view.ledger", "ledger"),
                view("Dashboard", "view.dashboard", "dashboard"),
                view("Goals", "view.goals", "goals"),
                view("Call log", "view.log", "log"),
                item("Hosts", "host.open"),
                .separator,
                item("Filter…", "session.filter"),
                item("Clear the filter", "filter.clear", enabled: facts.filtered),
                item("Only one host…", "host.filter"),
                item("Where heed looks on a host…", "host.roots"),
                .separator,
                item("Sidebar", "sidebar.toggle", checked: facts.sidebarShown),
                item("Inspector", "inspector.toggle", checked: facts.inspectorShown),
                .separator,
                scoped("In Attention", [
                    ("Done", "attention.done"), ("Snooze…", "attention.snooze"), ("Mute thread", "attention.mute"),
                    ("Draft a reply…", "attention.reply"), ("Go to its session", "attention.session"),
                    ("Next filter", "attention.filter"), ("Sort", "attention.sort"),
                ], in: ["attention"]),
                scoped("In the Inbox and Issues", [
                    ("Start a session from it", "items.start"), ("Add it to this session", "items.add"),
                    ("Mark read", "items.read"), ("Next filter", "items.filter"),
                    ("Next repo", "issues.repo.next"), ("Previous repo", "issues.repo.prev"),
                    ("Every repo's issues", "issues.repo"), ("All issues, or only yours", "issues.visibility"),
                ], in: ["attention", "inbox", "issues", "issue"]),
                scoped("In Repos", [
                    ("Start work in this repo", "worktree.new"), ("Open or import", "select.open"),
                    ("Copy path", "select.copy"), ("Pin its session", "select.pin"), ("Remove…", "select.remove"),
                    ("Review the repo's setup…", "setup.review"), ("Approve the setup", "setup.approve"),
                    ("No setup, ever", "setup.never"), ("Edit the setup…", "setup.edit"),
                ], in: ["repos"]),
                scoped("In History", [
                    ("Reopen", "history.reopen"), ("Start again from its prompt", "history.again"),
                    ("Next outcome", "history.outcome"), ("Timeline", "history.timeline"),
                    ("Ledger", "history.ledger"), ("Dashboard", "history.dashboard"),
                    ("Timeline: next kind", "timeline.kind"), ("Timeline: next repo", "timeline.repo"),
                    ("Timeline: where", "timeline.where"), ("Timeline: removed worktrees", "timeline.gone"),
                    ("Dashboard: next range", "dashboard.range"), ("Ledger: summarize now", "ledger.summarize"),
                    ("Ledger: edit the summary", "ledger.edit"),
                ], in: historyViews),
                scoped("In Goals", [
                    ("New goal…", "goal.new"), ("GOAL.md and versions", "goal.doc"), ("Edit GOAL.md", "goal.edit"),
                    ("Restore a version…", "goal.restore"), ("Archive or bring back", "goal.archive"),
                    ("Open", "goal.open"), ("Goals or what is on one", "goal.focus"),
                    ("Take off the goal", "goal.detach"), ("Board", "goal.board"),
                    ("Sharpen the goal…", "goal.sharpen"), ("Plan its items now", "goal.plan"),
                    ("Unassigned", "goal.unassigned"), ("Undo heed's last attachment", "goal.attach.undo"),
                    ("Reviewers and quality bars", "goal.reviewers"),
                    ("Re-check", "review.recheck"), ("Accept the risk", "review.accept"),
                    ("Start a session to fix it", "review.fix"), ("Ask the reviewer why", "review.why"),
                    ("Spawn a reviewer", "reviewer.spawn"), ("Take the reviewer off", "reviewer.remove"),
                    ("Pin a quality bar…", "goal.bar"), ("Not done yet", "goal.reopen"),
                    ("Personas", "goal.personas"),
                    ("Evaluations", "goal.evaluations"),
                    ("Mirror to GitHub, or stop", "goal.mirror"), ("Tracker repo…", "goal.tracker"),
                    ("Sync its GitHub issues now", "goal.mirror.sync"), ("Open it on GitHub", "goal.mirror.open"),
                    ("Yes to a change on GitHub", "goal.mirror.yes"), ("No to a change on GitHub", "goal.mirror.no"),
                    ("Add an item source…", "goal.source.add"), ("Yes to the proposed source", "goal.source.accept"),
                    ("No to the proposed source", "goal.source.dismiss"), ("Sync its sources now", "goal.source.sync"),
                    ("Change a source's query…", "goal.source.edit"), ("A source's done rule…", "goal.source.rule"),
                    ("Take a source off…", "goal.source.remove"),
                    ("Swarm and its plan", "goal.swarm"), ("New swarm…", "swarm.new"), (
                        "Swarm this goal…",
                        "swarm.start"
                    ),
                    ("Pause or resume the swarm", "swarm.pause"), ("Stop the swarm", "swarm.stop"),
                    ("The swarm's agents", "goal.agents"), ("The swarm's map", "goal.map"),
                    ("Follow-up swarm…", "swarm.followup"), ("End-of-build summary again", "swarm.summary"),
                ], in: ["goals"]),
                scopedInvocations("In a swarm's plan", [
                    ("Approve the plan", "swarm.approve"), ("Yes to the change waiting", "swarm.accept"),
                    ("No to the change waiting", "swarm.reject"),
                    ("Edit the task…", "swarm.task.edit"), ("Add a task…", "swarm.task.add"),
                    ("Move the task down", "swarm.task.move 1"), ("Move the task up", "swarm.task.move -1"),
                    ("Drop the task", "swarm.task.drop"), ("Re-plan with feedback…", "swarm.replan"),
                    ("Message an agent…", "swarm.send"),
                    ("Steering log by who decided", "swarm.log.who"), ("Between question and answer", "swarm.log.jump"),
                    ("The version's whole diff", "swarm.diff"),
                    ("Restore the version", "swarm.restore"), ("Pause or resume the task", "swarm.task.pause"),
                    ("Hand the task to another agent…", "swarm.task.swap"), ("Run the task on…", "swarm.task.host"),
                    ("The task's worker", "swarm.task.open"),
                    ("The plan in merge order", "swarm.order"), ("Move the task's stacked PR on", "swarm.land"),
                    ("Follow-up swarm…", "swarm.followup"), ("Delete a repeat rule…", "swarm.rule.delete"),
                    ("When a worker is stuck…", "swarm.stuck"), ("Get it merged for its PRs…", "swarm.merge"),
                ], in: ["goalplan"]),
                scopedInvocations("A swarm's agents", [
                    ("The worker's tab", "swarm.task.open"), ("Pause or resume its task", "swarm.task.pause"),
                    ("Hand its task to another agent…", "swarm.task.swap"), ("Message an agent…", "swarm.send"),
                    ("Follow-up swarm…", "swarm.followup"), ("End-of-build summary again", "swarm.summary"),
                    ("When a worker is stuck…", "swarm.stuck"),
                ], in: ["goalagents"]),
                scopedInvocations("A swarm's map", [
                    ("Left", "swarm.map.move h"), ("Right", "swarm.map.move l"), ("Down", "swarm.map.move j"),
                    ("Up", "swarm.map.move k"), ("The card's worker", "swarm.task.open"),
                    ("Pause or resume its task", "swarm.task.pause"), ("Edit its task…", "swarm.task.edit"),
                    ("Follow-up swarm…", "swarm.followup"),
                ], in: ["goalmap"]),
                scopedInvocations("A swarm's question", [
                    ("Answer it…", "swarm.answer"), ("Answer with the first option", "swarm.answer.option 1"),
                    ("Ask the controller", "swarm.controller"), ("Same answer for similar questions", "swarm.similar"),
                    ("Overrule the answer…", "swarm.overrule"),
                ], in: ["goalplan", "goalagents", "swarmask"]),
                scoped("In Personas", [
                    ("Spawn as a session…", "persona.session"), ("Spawn as a chat…", "persona.chat"),
                    ("Spawn as a reviewer", "persona.reviewer"), ("Edit its file", "persona.edit"),
                    ("Share to the library", "persona.share"), ("Use one from the library…", "persona.use"),
                    ("Work out who is needed now", "persona.derive"),
                ], in: ["goalpersonas"]),
                scopedInvocations("In Evaluations", [
                    ("Start a session to fix it", "eval.fix"), ("Accept the friction", "eval.accept"),
                    ("Walk again", "eval.rewalk"), ("Next lens", "eval.lens 1"), ("Lens before", "eval.lens -1"),
                ], in: ["goalevals"]),
                scopedInvocations("On a goal's board", [
                    ("Add an item…", "goal.item.add"), ("Move the card left", "goal.item.move left"),
                    ("Move the card right", "goal.item.move right"), ("Start work on it…", "goal.item.work"),
                    ("Open what it is", "goal.item.open"), ("Done", "goal.item.done"), ("Split it…", "goal.item.split"),
                ], in: ["goalboard"]),
                scoped("In GOAL.md", [
                    ("Accept the first change", "goal.proposal.accept"),
                    ("Say no to the first change", "goal.proposal.reject"),
                    ("Reword the first change…", "goal.proposal.edit"), ("Undo heed's last change", "goal.undo"),
                ], in: ["goaldoc"]),
                scoped("In Unassigned", [
                    ("Yes, on that goal", "goal.ask.yes"), ("No, not that goal", "goal.ask.no"),
                    ("On another goal…", "goal.ask.move"), ("Ignore things like this", "goal.ask.ignore"),
                ], in: ["unassigned", "attention"]),
                scoped("In the call log", [
                    ("Next kind", "log.kind"), ("Only failed", "log.failed"), ("Only slow", "log.slow"),
                    ("Only GitHub writes", "log.writes"), ("Only this caller", "log.caller"),
                    ("Only this agent", "log.agent"), ("Copy the command", "log.copy"),
                ], in: ["log"]),
            ])
        }

        func pr() -> Menu {
            let pulls = facts.session?.pulls ?? 0
            return Menu("PR", [
                item("PR overlay", "overlay.pr", enabled: hasRepo && pulls > 0, checked: facts.scope == "pr"),
                pull("Open the PR or issue", "overlay.item", otherwise: true),
                session("Diff", "overlay.diff", checked: facts.scope == "diff"),
                item("Previous PR", "pr.prev", enabled: hasRepo && pulls > 1),
                item("Next PR", "pr.next", enabled: hasRepo && pulls > 1),
                pull("Go to its session", "pr.session"),
                .separator,
                pull("Open in browser", "open.browser", otherwise: true),
                pull("Open repo on GitHub", "open.repo", otherwise: true),
                item("Open one of its links…", "links.pick", enabled: (facts.session?.links ?? 0) > 0),
                item("Read it", "open.reader"),
                .separator,
                item("Track a PR…", "pr.track", enabled: hasRepo),
                pull("Stop tracking", "pr.untrack", otherwise: hasRepo && pulls > 0),
                .separator,
                pull("What will heed do?", "pilot.why", otherwise: anyPull),
                pull("Watch", "pilot.watch", otherwise: openPull),
                pull("Get it green", "pilot.green", otherwise: openPull),
                pull("Get it merged", "pilot.merge", otherwise: openPull),
                item("Merge now…", "pilot.merge.now", enabled: openPull, target: pullTarget),
                pull("Pause", "pilot.pause", otherwise: openPull),
                pull("One more round", "pilot.retry"),
                pull("Ask Copilot", "pilot.copilot", otherwise: openPull),
                pull(
                    "Ask reviewers",
                    "pilot.reviewers",
                    otherwise: openPull && facts.pull == nil
                        && facts.session?.pilot.reviewers == true
                ),
                pull("Go to its run", "pilot.run"),
                pull("Stop run", "pilot.run.stop"),
                .separator,
                pull("Run its merge queue now", "merge.run", otherwise: anyPull),
                pull("Show its merge queue", "merge.queue", otherwise: anyPull),
                item("Set up get it merged…", "pilot.merge.setup", enabled: anyPull, target: pullTarget),
                item(
                    "Set up merging and green for a repo…",
                    "repo.setup",
                    target: facts.pull.map { .repo($0.ref.repo) }
                ),
                .separator,
                scoped("Feedback", [
                    ("Queue or unqueue", "feedback.queue"), ("Send the queue", "feedback.send"),
                    ("Dismiss", "feedback.dismiss"), ("Start a session from this PR", "feedback.session"),
                ], in: ["pr"]),
                scoped("In the diff", [
                    ("Next hunk", "diff.hunk.next"), ("Previous hunk", "diff.hunk.prev"),
                    ("Next file", "diff.file.next"), ("Previous file", "diff.file.prev"),
                    ("Next scope", "diff.scope.next"), ("Previous scope", "diff.scope.prev"),
                    ("One commit", "diff.commit"), ("Unified or split", "diff.split"),
                    ("Note on this hunk…", "diff.ask"), ("Ask the agent now…", "diff.ask.now"),
                    ("Copy path:line", "diff.copy"), ("Open in the editor", "diff.edit"),
                ], in: ["diff"]),
            ])
        }

        func go() -> Menu {
            let pins = facts.pinned.enumerated().map { index, title in
                MenuItem("\(index + 1)  \(title)", CommandInvocation(name: "pin.jump", arguments: ["\(index + 1)"]))
            }
            return Menu("Go", [
                item("Next session needing you", "session.attention"),
                item("Previous session", "session.back"),
                item("Back", "jump.back"),
                item("Session named…", "session.open"),
                pins.isEmpty ? item("Pinned sessions", "pin.jump", enabled: false) : .submenu("Pinned sessions", pins),
                .separator,
                item("Jump to anything", "mode.hint"),
                item("Jump and type", "hint.insert"),
                item("Select rows", "mode.visual"),
                item("Command line", "mode.command"),
            ])
        }

        func window() -> Menu {
            let tabs = (0 ..< min(facts.tabs, 9)).map {
                MenuItem("Tab \($0 + 1)", CommandInvocation(name: "tab.go", arguments: ["\($0 + 1)"]))
            }
            let panes = facts.panes > 0
            let split = facts.panes > 1
            return Menu("Window", [
                item("Split right", "pane.split.right", enabled: panes),
                item("Split below", "pane.split.below", enabled: panes),
                item("Zoom pane", "pane.zoom", enabled: split, checked: facts.zoomed),
                item("Close pane", "pane.close", enabled: panes),
                item("Pane left", "pane.left", enabled: split),
                item("Pane right", "pane.right", enabled: split),
                item("Pane above", "pane.up", enabled: split),
                item("Pane below", "pane.down", enabled: split),
                .separator,
                item("Wider", "pane.wider", enabled: split),
                item("Narrower", "pane.narrower", enabled: split),
                item("Taller", "pane.taller", enabled: split),
                item("Shorter", "pane.shorter", enabled: split),
                item("Equal sizes", "pane.equalize", enabled: split),
                .separator,
                item("New tab", "tab.new", enabled: hasSession),
                item("Next tab", "tab.next", enabled: facts.tabs > 1),
                item("Previous tab", "tab.prev", enabled: facts.tabs > 1),
                item("Move tab left", "tab.move.left", enabled: facts.tabs > 1),
                item("Move tab right", "tab.move.right", enabled: facts.tabs > 1),
                tabs.isEmpty ? item("Go to tab", "tab.go", enabled: false) : .submenu("Go to tab", tabs),
                item("Close tab", "tab.close", enabled: facts.tabs > 0),
            ])
        }

        func help() -> Menu {
            Menu("Help", [
                item("Keys & states", "overlay.help"),
                item("Heed Tutor", "tutor"),
                item("Previous tutor step", "tutor.back", enabled: facts.tutor),
                item("Skip this step", "tutor.skip", enabled: facts.tutor),
                item("Leave the tutor", "tutor.exit", enabled: facts.tutor),
                item("Hide the tutor reminder", "tutor.hide"),
                .separator,
                item("Getting started checks", "welcome"),
                item("Set up model calls & decisions", "inference.setup"),
                item("Hide the setup reminder", "inference.hide"),
                .separator,
                item("Download Hunch's model", "hunch.download", enabled: !facts.hunchReady),
                item("Stop Hunch's download", "hunch.cancel", enabled: facts.hunchDownloading),
                item("Retrain Hunch from my corrections", "hunch.retrain", enabled: facts.hunchReady),
                item("Reset Hunch to its checkpoint's head", "hunch.reset", enabled: facts.hunchReady),
                item("Read this agent's screen with Hunch", "hunch.screen", enabled: facts.hunchReady),
                item("Delete Hunch's model", "hunch.delete", enabled: facts.hunchReady || facts.hunchDownloading),
            ])
        }
    }
}
