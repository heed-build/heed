/// Every command the app can run. A key binding names one of these, `:` completes over them, and the `?` overlay is
/// drawn from them: one list, so a command never exists in one of those places and not the others.
public struct CommandSpec: Sendable, Equatable {
    public enum Group: String, Sendable, CaseIterable {
        case move = "Move & sessions"
        case panes = "Panes & tabs"
        case views = "Views & overlays"
        case modes = "Modes"
        case selection = "Selection"
    }

    public let name: String
    public let summary: String
    public let group: Group
    /// Argument placeholder shown in completion, e.g. `<n>` for `pin.jump`.
    public let arguments: String?

    public init(_ name: String, _ summary: String, _ group: Group, arguments: String? = nil) {
        self.name = name
        self.summary = summary
        self.group = group
        self.arguments = arguments
    }
}

public enum Commands {
    public static let all: [CommandSpec] = [
        // Move & sessions
        .init("row.next", "next session / row", .move),
        .init("row.prev", "previous session / row", .move),
        .init("row.first", "first session / row", .move),
        .init("row.last", "last session / row", .move),
        .init("row.halfpage.down", "half a page down (ten rows)", .move),
        .init("row.halfpage.up", "half a page up (ten rows)", .move),
        .init("group.next", "first row of the next group (sidebar group, repo)", .move),
        .init("group.prev", "first row of this group, or of the one before", .move),
        .init("session.filter", "filter the current view (typed in the status bar)", .move),
        .init("filter.clear", "clear the current view's filter", .move),
        .init("session.attention", "next session needing you", .move),
        .init("session.park", "park session", .move),
        .init("session.close", "close session, keep worktree", .move),
        .init("session.delete", "delete session and its worktrees (asks first)", .move),
        .init(
            "session.import", "import a worktree Heed does not manage yet as a session", .move,
            arguments: "[path]"
        ),
        .init("session.import.path", "import the worktree at a path (any repo, anywhere)", .move),
        .init("session.pin", "pin / unpin session", .move),
        .init(
            "session.rename",
            "give the session your title, which heed keeps (no title: the command line opens with it)",
            .move, arguments: "[title]"
        ),
        .init("session.autoname", "let heed name the session again, from what it is doing", .move),
        .init(
            "session.kind", "what the work is: feat, fix, refactor, docs, chore or plan (no argument: the next)", .move,
            arguments: "[kind]"
        ),
        .init("session.back", "back to previous session", .move),
        .init("session.agent", "INSERT into the session's agent pane (the focused pane when it has none)", .move),
        .init("session.open", "go to the session matching these words", .move, arguments: "<words>"),
        .init("pin.jump", "jump to pinned session", .move, arguments: "<1-9>"),
        .init("work.start", "start work", .move),
        .init("work.start.panel", "start work in the floating panel, as the global shortcut does", .move),
        .init("resume", "pick up where you left off: the sessions to resume, as on launch", .move),
        .init(
            "summary", "while you were away: what still waits on you, and what merged, ran, finished and closed",
            .move
        ),
        .init("work.again", "start work from this session's prompt", .move),
        .init(
            "chat.new", "start a chat: an agent in a scratch folder or one you pick, no repo or worktree", .move,
            arguments: "[prompt]"
        ),
        .init(
            "chat.promote", "turn this chat into work: pick a repo, heed makes a worktree and hands the agent the chat",
            .move
        ),
        .init(
            "agent.switch", "hand the session to another agent: stop its agent, start that one on a handoff prompt",
            .move,
            arguments: "[agent] [model] [effort]"
        ),
        .init(
            "view.insights",
            "Insights: the dashboard first, then History, the ledger, the Mindmap and standups",
            .move
        ),
        .init("view.history", "Insights, as view.insights does (the name it had before)", .move),
        .init(
            "view.autopilot",
            "Autopilot: what heed can do on its own (Can do first), where it is on, what it does now, what it did",
            .move
        ),
        .init("goal.jump", "go to the session's goal; in Goals, to the goal of the session under the cursor", .move),
        // Panes & tabs
        .init("pane.left", "focus pane left", .panes),
        .init("pane.right", "focus pane right", .panes),
        .init("pane.up", "focus pane above", .panes),
        .init("pane.down", "focus pane below", .panes),
        .init("pane.split.right", "split right", .panes),
        .init("pane.split.below", "split below", .panes),
        .init("pane.zoom", "zoom pane", .panes),
        .init("pane.close", "close pane", .panes),
        .init("pane.wider", "widen the focused pane", .panes),
        .init("pane.narrower", "narrow the focused pane", .panes),
        .init("pane.taller", "make the focused pane taller", .panes),
        .init("pane.shorter", "make the focused pane shorter", .panes),
        .init("pane.equalize", "make every pane in the tab the same size", .panes),
        .init("tab.close", "close the tab, every pane in it", .panes),
        .init("tab.next", "next tab", .panes),
        .init("tab.prev", "previous tab", .panes),
        .init("tab.new", "new tab with shell", .panes),
        .init("tab.move.left", "move the tab left", .panes),
        .init("tab.move.right", "move the tab right", .panes),
        .init("tab.go", "go to tab n", .panes, arguments: "<n>"),
        .init(
            "task.run", "run a task in a tab of its own: pinned, mise, make, package.json (no name: pick one)", .panes,
            arguments: "[name]"
        ),
        .init("task.refresh", "read the session's tasks again (mise, make, package.json)", .panes),
        // Views & overlays
        .init(
            "view",
            "switch view",
            .views,
            arguments: "<sessions|attention|inbox|issues|prs|watch|repos|insights|history|timeline|ledger|dashboard|mindmap|standup|goals|log>"
        ),
        .init("view.sessions", "sessions", .views),
        .init(
            "view.attention",
            "attention: what wants you, with why, the thread beside it (a tab: foryou, reviews, mentions, mine, ...)",
            .views, arguments: "[filter]"
        ),
        .init("view.inbox", "Attention's Everything tab, where the inbox went", .views),
        .init(
            "view.issues",
            "Attention's issues: assigned to you or mentioning you, where the Issues view went",
            .views
        ),
        .init("view.prs", "pull requests", .views),
        .init("view.watch", "Autopilot, as view.autopilot does (the view was Watch before)", .views),
        .init("autopilot.cando", "Autopilot's Can do: a card per thing heed can do on its own", .views),
        .init("autopilot.where", "Autopilot's Where: each repo, and which capabilities are on there", .views),
        .init(
            "autopilot.now", "Autopilot's Now: stalled PRs first, then what each capability is working on", .views
        ),
        .init("autopilot.done", "Autopilot's Done: what heed did on its own, by day", .views),
        .init(
            "autopilot.move", "Autopilot: move between cards (Can do) or cells (Where)", .selection,
            arguments: "<h|j|k|l>"
        ),
        .init(
            "autopilot.on", "Autopilot: turn the capability on here (the repo in Where; its default on Can do)",
            .selection, arguments: "[capability] [repo]"
        ),
        .init("autopilot.ask", "Autopilot: have the capability ask you first here", .selection),
        .init("autopilot.off", "Autopilot: turn the capability off here", .selection),
        .init("autopilot.everywhere", "Autopilot: turn the capability on in every repo", .selection),
        .init(
            "autopilot.open",
            "Autopilot: what the card did (Can do), the repo in Repos (Where), read the PR (Now and Done)",
            .selection
        ),
        .init("autopilot.settings", "Autopilot: open the Settings page of the capability", .selection),
        .init(
            "autopilot.what", "Done: every capability, or the next one (or one by name)", .selection,
            arguments: "[capability]"
        ),
        .init("autopilot.repo", "Done: every repo, or the next one (or one by name)", .selection, arguments: "[repo]"),
        .init("view.repos", "repos & worktrees", .views),
        .init(
            "view.log",
            "the call log: every command and GitHub call heed made, how long it took, how it ended",
            .views
        ),
        .init("view.timeline", "Insights' History with every event as its own line (what the timeline was)", .views),
        .init("view.dashboard", "Insights' dashboard: what the work amounted to over a range", .views),
        .init("view.ledger", "Insights' ledger: a summary of each piece of work, kept after its worktree", .views),
        .init("view.standup", "Insights' standup reports: your questions answered, one report per org", .views),
        .init("view.mindmap", "Insights' Mindmap: the work grouped into campaigns, one Mindmap per org", .views),
        .init("view.goals", "goals: long-running work, what belongs to each goal, and its GOAL.md", .views),
        .init("goal.overview", "Goals: back to the goal's overview from any of its panes", .views),
        .init("goal.doc", "Goals: the goal's GOAL.md and its versions (again: the overview)", .views),
        .init("goal.board", "Goals: the goal as a board, its items by column (again: the overview)", .views),
        .init(
            "goal.unassigned",
            "Goals › Unassigned: how heed put new work on goals, its asks, and goals it suggests (again: the overview)",
            .views
        ),
        .init(
            "goal.reviewers",
            "Goals: the goal's reviewers, their scores and objections, and its quality bars (again: the overview)",
            .views
        ),
        .init(
            "goal.personas",
            "Goals: who the goal needs, why now, how much of their work they have looked at (again: the overview)",
            .views
        ),
        .init(
            "goal.evaluations",
            "Goals: stranger walks of the goal, their friction logs and scores, by lens (again: the overview)",
            .views
        ),
        .init(
            "goal.swarm",
            "Goals: the goal's swarm: its plan by phase, the lead's questions, versions and steering (again: the "
                + "overview)",
            .views
        ),
        .init(
            "goal.agents",
            "Goals: the swarm's agents: what each does and for how long, stuck or not, its notes and activity, and "
                + "what needs you; once done, its summary (again: the overview)",
            .views
        ),
        .init(
            "goal.map",
            "Goals: the swarm as a map: phases as columns, tasks as cards by state, dependencies as edges (again: the "
                + "overview)",
            .views
        ),
        .init("overlay.pr", "PR overlay for this session (toggle)", .views),
        .init("overlay.item", "open the PR or issue under the cursor; in Sessions, the session's PR (toggle)", .views),
        .init("overlay.diff", "diff overlay: commits, staged, unstaged", .views),
        .init("overlay.help", "keys & states", .views),
        .init("overlay.close", "close overlay", .views),
        .init("approvals.open", "what agents ask permission for, from every session, oldest first (toggle)", .views),
        .init("approvals.next", "approvals: the next request", .selection),
        .init("approvals.prev", "approvals: the request before", .selection),
        .init("approvals.allow", "approvals: allow the selected request; the next one is selected", .selection),
        .init(
            "approvals.deny", "approvals: deny the selected request, telling the agent why when given", .selection,
            arguments: "[reason]"
        ),
        .init("approvals.deny.reason", "approvals: deny the selected request with a reason you type", .selection),
        .init(
            "approvals.always", "approvals: allow, and save the agent's own allow rule in this repo (Claude Code)",
            .selection
        ),
        .init("approvals.allow.all", "approvals: allow every request heed can answer", .selection),
        .init("approvals.deny.all", "approvals: deny every request heed can answer", .selection),
        .init("approvals.allow.read", "approvals: allow every read-only request inside its worktree", .selection),
        .init("approvals.session", "approvals: go to the selected request's session", .selection),
        .init("pr.next", "next PR of this session", .views),
        .init("pr.prev", "previous PR of this session", .views),
        .init("pr.session", "jump from a PR to its session", .views),
        .init("pr.track", "track a PR by URL", .views, arguments: "<url>"),
        .init("pr.untrack", "stop tracking a PR in this session (no rule adds it back)", .views, arguments: "[url]"),
        .init("jump.back", "back", .views),
        .init(
            "open.browser",
            "open in the browser: the item under the cursor; in Sessions its PR or issue (a picker when there are several, its repo when there are none)",
            .views
        ),
        .init("open.repo", "open the repo under the cursor on GitHub", .views),
        .init("links.pick", "pick one of the session's PRs and issues to open in the browser", .views),
        .init("issue.add", "link an issue to the session (its URL, or the copied one)", .views, arguments: "[url]"),
        .init("issue.remove", "take an issue off the session", .views, arguments: "[url]"),
        .init("open.reader", "read the item, issue or PR", .views),
        .init("cleanup.rules", "the cleanup settings (Settings › Worktrees › Cleanup)", .views),
        .init(
            "cleanup.run",
            "clean up worktrees now: remove the ones idle past your cleanup settings (lists them and asks first)",
            .views
        ),
        .init("inspector.toggle", "collapse / expand the inspector", .views),
        .init(
            "inspector.tackle", "hand the session's loose end with this text to its agent (none: all of them)", .views,
            arguments: "[text]"
        ),
        .init(
            "inspector.resolve",
            "mark a loose end done, on the Mindmap node it lives on",
            .views,
            arguments: "<node> <text>"
        ),
        .init("inspector.copy", "copy a path to the pasteboard", .views, arguments: "<path>"),
        .init("sidebar.toggle", "collapse / expand the sessions sidebar", .views),
        .init("sidebar.titles", "show session titles / worktree names in the sidebar rows", .views),
        .init(
            "sessions.group", "group the sessions by status, campaign, repo or not at all (no argument: the next)",
            .views, arguments: "[status|campaign|repo|none]"
        ),
        .init(
            "sessions.sort",
            "sort the sessions: attention, you recent first, idle longest, started, size (no argument: next)",
            .views, arguments: "[attention|touched|idle|started|size]"
        ),
        .init("sessions.rows", "one line or two per session in the sidebar", .views, arguments: "[one|two]"),
        .init(
            "sessions.close.ready",
            "close every session in Can close (its PRs merged or closed, nothing left open), after asking", .views
        ),
        .init("config.edit", "open config.toml in $EDITOR", .views),
        .init(
            "tutor", "the tutor: pick a lesson, or start one by name (tour, sessions, prs…)", .views,
            arguments: "[lesson]"
        ),
        .init(
            "tutor.hide", "hide the title bar's tutor reminder for this lesson (all: every reminder)", .views,
            arguments: "[all]"
        ),
        .init("host.open", "hosts: the ones heed drives over ssh, and ones from ~/.ssh/config to add", .views),
        .init("host.filter", "narrow the view to one host (@devbox)", .views, arguments: "[host]"),
        .init("host.roots", "choose where heed looks for repos on a host", .views, arguments: "[host]"),
        .init("agents.stop", "stop every agent and shell in every pane (with [sessions] persist = \"zmx\")", .views),
        .init("tutor.back", "the tutor's previous step, the world as it was then", .views),
        .init("tutor.skip", "skip the tutor's step", .views),
        .init("tutor.exit", "leave the tutor; your sessions come back as they were", .views),
        .init("update.check", "look for a new version of heed now (also :update)", .views),
        .init("tools.detect", "find git and gh again (login shell PATH, usual places, [tools])", .views),
        .init("app.quit", "quit Heed", .views),
        .init(
            "settings.open",
            "open Settings, on a page (general, notifications, updates, agents, model-calls, decisions, worktrees, "
                + "goals, history, github, pilot, orgs, attention, hosts, tools, keys; the old colors, cleanup, "
                + "inference still work); orgs and pilot take a tab (green, merged, reviews, instructions), agents an "
                + "agent and a tab (sessions, model-calls)",
            .views,
            arguments: "[page] [tab]"
        ),
        .init(
            "settings.advanced",
            "Settings: show or hide the advanced settings (a set or refused one always shows)", .views
        ),
        .init(
            "settings.modified",
            "Settings: show only what differs from heed's defaults, or every setting again", .views
        ),
        .init(
            "settings.find",
            "Settings: search every setting by name, description, page or config key (grace_seconds), every word "
                + "matching",
            .views, arguments: "<words>"
        ),
        .init(
            "whatsnew.show",
            "what's new in heed: the features and new settings since the version you last opened",
            .views
        ),
        .init(
            "nudges.hide", "hide the title bar's settings-worth-a-look pill until the next launch (always: for good)",
            .views, arguments: "[always]"
        ),
        .init(
            "settings.configure",
            "Settings: Configure…, a profile, then the settings still worth deciding, then the changes to apply",
            .views
        ),
        .init(
            "inference.setup", "set up heed's model calls and decisions (Settings › Model calls)", .views
        ),
        .init(
            "inference.hide", "hide the title bar's model call setup reminder until the next launch (always: for good)",
            .views, arguments: "[always]"
        ),
        .init(
            "hunch.download", "download (or resume) Hunch's model, english by default; says its size and license first",
            .views, arguments: "[checkpoint]"
        ),
        .init(
            "hunch.cancel",
            "stop Hunch's model download; hunch.download resumes it",
            .views,
            arguments: "[checkpoint]"
        ),
        .init(
            "hunch.delete",
            "delete Hunch's downloaded model and the head trained on it",
            .views,
            arguments: "[checkpoint]"
        ),
        .init("hunch.retrain", "train Hunch on your corrections now, in the background", .views),
        .init("hunch.reset", "put Hunch back on its checkpoint's own head (the training set stays)", .views),
        .init(
            "hunch.screen",
            "have Hunch read the agent pane under the cursor now: working, waiting for input, stuck or done",
            .views
        ),
        .init("app.activate", "bring Heed's window to the front, as the global shortcut does", .views),
        .init("welcome", "show the getting-started checks again", .views),
        // Modes
        .init("mode.normal", "back to NORMAL", .modes),
        .init("mode.insert", "INSERT into the focused pane", .modes),
        .init("mode.visual", "VISUAL: select, then act", .modes),
        .init("mode.command", "COMMAND line", .modes),
        .init("mode.hint", "HINT: jump to anything", .modes),
        .init("hint.insert", "jump and enter INSERT", .modes),
        .init("command.submit", "run the command line", .modes),
        .init("command.complete", "complete, or the next match", .modes),
        .init("command.complete.prev", "the previous match", .modes),
        // Selection
        .init("select.toggle", "toggle row", .selection),
        .init("history.reopen", "reopen: resume, recreating the worktree if needed", .selection),
        .init("history.again", "start a new session from this prompt", .selection),
        .init(
            "history.outcome", "History: the next outcome filter, or one by name (all, merged, …)", .selection,
            arguments: "[outcome]"
        ),
        .init(
            "history.list",
            "Insights' History: the work that ended, by day, each with its story (again: the dashboard)",
            .views
        ),
        .init(
            "history.events", "History: every event as its own line, or folded into its piece of work again",
            .selection
        ),
        .init(
            "history.timeline", "History with every event as its own line (again: folded), as history.events",
            .views
        ),
        .init(
            "timeline.kind", "History: every kind, or one (sessions, worktrees, prs, questions, chats)", .selection,
            arguments: "[kind]"
        ),
        .init("timeline.repo", "History: every repo, or the next one", .selection, arguments: "[name]"),
        .init("timeline.where", "History: everywhere, this Mac, or a host", .selection, arguments: "[local|host]"),
        .init("timeline.gone", "History: show or hide removed worktrees", .selection),
        .init(
            "history.ledger",
            "Insights' ledger: a summary of each piece of work (again: back to the dashboard)",
            .views
        ),
        .init(
            "history.dashboard",
            "Insights' dashboard: what shipped, agent time, your bests, goals; where Insights opens",
            .views
        ),
        .init(
            "history.standup", "Insights' standup: your questions answered per org (again: back to the dashboard)",
            .views
        ),
        .init(
            "history.telemetry",
            "Insights' OpenTelemetry: the agents' own spans, latency, waits and cost (again: back to the dashboard)",
            .views
        ),
        .init(
            "telemetry.range",
            "OpenTelemetry: the next range (15 m, 1 h, 6 h, 24 h, 7 d), or one named (30m)",
            .selection,
            arguments: "[range]"
        ),
        .init(
            "telemetry.agent",
            "OpenTelemetry: only the next agent, then all again (or the one named)",
            .selection,
            arguments: "[agent]"
        ),
        .init(
            "telemetry.repo",
            "OpenTelemetry: only the next repo, then all again (or the one named)",
            .selection,
            arguments: "[repo]"
        ),
        .init(
            "telemetry.model",
            "OpenTelemetry: only the next model, then all again (or the one named)",
            .selection,
            arguments: "[model]"
        ),
        .init(
            "telemetry.kind",
            "OpenTelemetry: which spans the table lists: turns, tools, waits and model; all; one kind",
            .selection, arguments: "[kind]"
        ),
        .init("telemetry.live", "OpenTelemetry: stop or start redrawing as spans arrive", .selection),
        .init("telemetry.open", "OpenTelemetry: the span's session's trace, on its turn", .selection),
        .init(
            "session.trace",
            "a session's trace from its agent's OpenTelemetry: its last turns, span by span (again: back)",
            .views, arguments: "[session]"
        ),
        .init("trace.turn.next", "trace: the next turn", .move),
        .init("trace.turn.prev", "trace: the previous turn", .move),
        .init("trace.span.next", "trace: the next span in the turn", .move),
        .init("trace.span.prev", "trace: the previous span in the turn", .move),
        .init("standup.run", "standup: write a report for this org now", .selection),
        .init(
            "standup.copy",
            "standup: copy the answer to the question shown (all with none), as markdown",
            .selection,
            arguments: "[plain]"
        ),
        .init("standup.copy.all", "standup: copy the whole report, as markdown", .selection, arguments: "[plain]"),
        .init("standup.question", "standup: show one question's answers, the next, or all again", .selection),
        .init("standup.org.next", "standup: the next org's reports (personal last)", .selection),
        .init("standup.org.prev", "standup: the previous org's reports", .selection),
        .init(
            "history.mindmap",
            "Insights' Mindmap: the work grouped into campaigns, per org (again: back to the dashboard)",
            .views
        ),
        .init(
            "dashboard.range", "dashboard: the next range (7 days, 4 weeks, 12 weeks), or one in days or weeks (2w)",
            .selection, arguments: "[days]"
        ),
        .init(
            "goal.new", "new goal: a title and what it is (on a session: from its prompt, and the session on it)",
            .selection, arguments: "[title]"
        ),
        .init(
            "goal.attach", "put the session or chat on a goal (no goal: the command line opens to pick one)",
            .selection, arguments: "<goal>"
        ),
        .init("goal.detach", "take the session or chat off its goal", .selection),
        .init("goal.archive", "archive the goal (again: bring it back)", .selection),
        .init("goal.open", "Goals: what belongs to the goal; on a session or chat, go to it", .selection),
        .init("goal.focus", "Goals: between the goals and what belongs to the goal", .selection),
        .init("goal.edit", "edit the goal's GOAL.md in place; each save is a new version", .selection),
        .init(
            "goal.restore", "make one of the goal's GOAL.md versions current again (as a new version)", .selection,
            arguments: "<version>"
        ),
        .init(
            "goal.item.add", "Goals: add an item to the goal (on the board: in the column under the cursor)",
            .selection, arguments: "[title]"
        ),
        .init("goal.item.done", "Goals: the item under the cursor is done (its card to Done)", .selection),
        .init(
            "goal.item.move", "Goals: move the card under the cursor a column left or right, or to a column by name",
            .selection, arguments: "<left|right|explore|planned|working|verify|done>"
        ),
        .init("goal.item.column", "Goals board: the cursor a column left or right", .selection, arguments: "<-1|1>"),
        .init(
            "goal.item.split", "Goals: split the item into smaller ones (titles separated by ;)", .selection,
            arguments: "<titles>"
        ),
        .init("goal.item.work", "Goals: start work on the item, Start work filled in from it", .selection),
        .init(
            "goal.item.open",
            "Goals: open what the card is (its session, chat or PR); a question: GOAL.md",
            .selection
        ),
        .init("goal.plan", "Goals: ask the planner for the goal's items now", .selection),
        .init("goal.proposal.accept", "GOAL.md: yes to the first change waiting (or the one clicked)", .selection),
        .init("goal.proposal.reject", "GOAL.md: no to the first change waiting (or the one clicked)", .selection),
        .init(
            "goal.proposal.edit",
            "GOAL.md: reword the first change waiting, then accept it (no text: the command line)",
            .selection, arguments: "[text]"
        ),
        .init("goal.undo", "GOAL.md: take back the last change heed made on its own", .selection),
        .init("goal.sharpen", "GOAL.md: ask a model to sharpen the goal; what it suggests waits for you", .selection),
        .init(
            "goal.guide",
            "Goals: hide the goal's next-steps card (it comes back if a step it ticked off goes back), or show it again",
            .selection
        ),
        .init("goal.ask.yes", "yes: on the goal heed proposed (on a suggested goal: make it)", .selection),
        .init("goal.ask.no", "no: not on that goal, and heed learns it (on a suggested goal: drop it)", .selection),
        .init(
            "goal.ask.move", "on another goal instead, and heed learns it was not the one it proposed", .selection,
            arguments: "<goal>"
        ),
        .init("goal.ask.ignore", "leave things like this on no goal, and heed learns to (an ignore rule)", .selection),
        .init(
            "goal.unassigned.how",
            "Unassigned: show or hide how heed puts work on goals (shown on its own only while nothing waits for you)",
            .selection
        ),
        .init(
            "goal.attach.undo",
            "take heed's last attachment off again, and heed learns it (a never rule)",
            .selection
        ),
        .init("goal.attach.find", "look for the session's goal now: rules, signals, the model when unsure", .selection),
        .init(
            "goal.bar", "pin a quality bar for the goal: a lens and 0–10, off to drop the lens, auto for the profile's",
            .selection, arguments: "<lens> <bar|off|auto>"
        ),
        .init(
            "goal.bars.accept",
            "Reviewers: these quality bars are right for the goal (recorded as yours; the first steps tick off on it)",
            .selection
        ),
        .init(
            "goal.mirror",
            "mirror the goal to GitHub (its tracker checked first; heed keeps it up to date); again: stop",
            .selection
        ),
        .init(
            "goal.tracker", "the repo the goal mirrors to on GitHub, checked read-only first (none: no tracker)",
            .selection, arguments: "[org/name|none]"
        ),
        .init("goal.mirror.sync", "sync the goal's GitHub issues now and read them back", .selection),
        .init("goal.mirror.open", "open the goal's meta issue on GitHub (on a card: its sub-issue)", .selection),
        .init("goal.mirror.yes", "a colleague's change on GitHub: yes, the item follows it", .selection),
        .init("goal.mirror.no", "a colleague's change on GitHub: no, heed puts the sub-issue back", .selection),
        .init(
            "goal.source.add",
            "a GitHub query the goal's items come from, one item per PR or issue (prs org/repo, issues org/repo, "
                + "label <name>, reviews, milestone <title> org/repo, or a search); none: the source dialog",
            .selection, arguments: "[query]"
        ),
        .init(
            "goal.source.remove",
            "take a source off the goal (its items stay, marked)",
            .selection,
            arguments: "[id]"
        ),
        .init(
            "goal.source.edit", "change a source's query and rule (its items stay; none: the source dialog)",
            .selection, arguments: "<id> [query]"
        ),
        .init(
            "goal.source.rule", "what done means for a source's items: merged, closed, reviewed (by you) or green",
            .selection, arguments: "<id> <rule>"
        ),
        .init("goal.source.accept", "yes to the source heed proposes for the goal", .selection),
        .init("goal.source.dismiss", "no to the source heed proposes (not proposed again)", .selection),
        .init("goal.source.sync", "sync the goal's sources with GitHub now", .selection),
        .init("goal.reopen", "not done yet: undo heed marking the goal done (held until something new)", .selection),
        .init(
            "swarm.new",
            "new swarm: a goal, where it works, its lead and team, its limits; the lead drafts a plan for you to approve",
            .selection, arguments: "[title]"
        ),
        .init("swarm.start", "swarm this goal: a lead drafts a plan for its work (the form first)", .selection),
        .init(
            "swarm.stop", "stop the goal's swarm: nothing more starts, its plan and steering stay readable", .selection
        ),
        .init(
            "swarm.pause",
            "pause the goal's swarm (again: resume): nothing more starts, workers at work finish their turn",
            .selection
        ),
        .init(
            "swarm.approve", "approve the swarm's plan (or the change waiting for you): its tasks become items",
            .selection
        ),
        .init("swarm.accept", "yes to the plan change waiting for you: it becomes the approved plan", .selection),
        .init(
            "swarm.task.pause",
            "pause the swarm task under the cursor (again: resume): its worker stops, its worktree stays",
            .selection
        ),
        .init(
            "swarm.task.swap",
            "hand the swarm task under the cursor to another agent; a working worker hands over its worktree",
            .selection, arguments: "<agent[:model]>"
        ),
        .init(
            "swarm.task.host",
            "where the swarm task under the cursor runs: a host, local for this Mac, or - for where the swarm runs",
            .selection, arguments: "<host|local|->"
        ),
        .init(
            "swarm.host", "where the new swarm runs, in its form: a host, or local for this Mac", .selection,
            arguments: "<host|local>"
        ),
        .init("swarm.task.open", "the swarm task under the cursor's worker: its tab", .selection),
        .init(
            "swarm.land",
            "move the task under the cursor's stacked PR to where the PR it stacks on merged (again after gh refused)",
            .selection
        ),
        .init(
            "swarm.order", "the swarm's plan in merge order (what each task waits for merges first), or by phase again",
            .selection
        ),
        .init(
            "swarm.reject",
            "no to the plan change waiting for you; the lead hears why",
            .selection,
            arguments: "[why]"
        ),
        .init("swarm.task.edit", "edit the plan's task under the cursor: a new plan version", .selection),
        .init(
            "swarm.task.add", "add a task after the one under the cursor, in its phase: a new plan version", .selection,
            arguments: "[title]"
        ),
        .init(
            "swarm.task.move", "move the plan's task down (1) or up (-1); past its phase, into the next", .selection,
            arguments: "<1|-1>"
        ),
        .init("swarm.task.drop", "drop the plan's task under the cursor; nothing waits for it any more", .selection),
        .init(
            "swarm.replan", "ask the swarm's lead to re-plan, with your feedback", .selection, arguments: "[feedback]"
        ),
        .init(
            "swarm.answer",
            "answer the swarm question under the cursor (Needs you, the plan's log), else the first open one; on one "
                + "someone else answered, an overrule", .selection, arguments: "[answer]"
        ),
        .init(
            "swarm.answer.option",
            "answer the swarm question under the cursor (else the first open one) with its option n (1 is the first)",
            .selection, arguments: "<n>"
        ),
        .init(
            "swarm.controller",
            "hand the swarm question under the cursor to heed's controller: it answers what is within its authority "
                + "and suggests an answer for what is yours", .selection
        ),
        .init(
            "swarm.similar",
            "make your next answer to the swarm question under the cursor the answer to similar questions too",
            .selection
        ),
        .init(
            "swarm.overrule", "answer again the swarm question under the cursor that someone else answered",
            .selection, arguments: "[answer]"
        ),
        .init(
            "swarm.log.who", "the steering log by who decided: everyone, you, the controller, the lead, agents, heed",
            .selection, arguments: "[actor]"
        ),
        .init(
            "swarm.log.jump",
            "from a steering row to the question it is about, from a question to its answer; elsewhere to the log",
            .selection
        ),
        .init(
            "swarm.send", "a message to a swarm agent (a task's number, lead, or @all), typed in once it is idle",
            .selection, arguments: "<to> <text>"
        ),
        .init(
            "swarm.diff",
            "the plan version under the cursor's whole diff against the one before (again: short)",
            .selection
        ),
        .init(
            "swarm.restore", "make a plan version current again, as a new version", .selection, arguments: "[version]"
        ),
        .init(
            "swarm.map.move", "the swarm map's cursor: h l between columns, j k between the cards of one", .selection,
            arguments: "<h|j|k|l>"
        ),
        .init(
            "swarm.followup",
            "start a follow-up swarm on the goal: the last one's team and limits, its follow-ups for the lead (the form "
                + "first)",
            .selection
        ),
        .init(
            "swarm.summary",
            "the swarm's end-of-build summary: written again from its record, and the lead asked to write its part",
            .selection
        ),
        .init(
            "swarm.stuck",
            "when the goal's swarm counts a worker as stuck: estimate (×), errors, quiet, peer and you (minutes)",
            .selection, arguments: "<estimate|errors|quiet|peer|you> <value>"
        ),
        .init(
            "swarm.merge",
            "get it merged for the goal's swarm's PRs: off, auto, heed, or repo (each PR's repo says; the default). "
                + "In merge order either way",
            .selection, arguments: "<off|auto|heed|repo>"
        ),
        .init(
            "swarm.rule.delete", "delete one of the goal's repeat rules: the controller stops answering with it",
            .selection, arguments: "[rule number]"
        ),
        .init(
            "review.recheck",
            "re-check: the reviewer under the cursor looks again now (elsewhere in Goals: every reviewer the goal needs)",
            .selection, arguments: "[reviewer]"
        ),
        .init("review.accept", "accept the risk of the objection under the cursor (again: open it)", .selection),
        .init("review.fix", "start a session to fix the objection under the cursor: Start work, filled in", .selection),
        .init("review.why", "ask the reviewer why: a chat seeded with its review", .selection),
        .init(
            "reviewer.spawn", "spawn a reviewer on the goal, as the spawn panel says (or of the kind given)",
            .selection, arguments: "[kind]"
        ),
        .init("reviewer.remove", "take the reviewer under the cursor off the goal (its history stays)", .selection),
        .init("persona.session", "start a session as the persona under the cursor: Start work, filled in", .selection),
        .init(
            "persona.chat",
            "start a chat with the persona under the cursor, seeded with it, the goal and why",
            .selection
        ),
        .init(
            "persona.reviewer", "spawn the persona under the cursor as a reviewer: read-only, it looks now", .selection
        ),
        .init("persona.edit", "edit the persona's file in place (again, ⎋ or ⌘S: save it)", .selection),
        .init("persona.derive", "work out again who the goal needs, now (one of the goal's model calls)", .selection),
        .init("persona.share", "copy the persona's file to the shared library, for other goals", .selection),
        .init(
            "persona.use", "put a persona from the shared library on the goal (a copy)", .selection,
            arguments: "<persona>"
        ),
        .init(
            "eval.fix", "start a session to fix the friction under the cursor: Start work, filled in", .selection
        ),
        .init("eval.accept", "accept the friction under the cursor (again: open it)", .selection),
        .init(
            "eval.rewalk",
            "walk again now, in a fresh clone: the lens picked (after a fix, to see whether it helped)",
            .selection, arguments: "[lens]"
        ),
        .init(
            "eval.lens", "Evaluations: pick a lens, the next (1), the one before (-1) or one by name", .selection,
            arguments: "<1|-1|lens>"
        ),
        .init("ledger.summarize", "write the ledger summary of this work now", .selection),
        .init("mindmap.in", "Mindmap: into what the node under the cursor holds", .selection),
        .init("mindmap.out", "Mindmap: out to the node that holds this one", .selection),
        .init("mindmap.less", "Mindmap: draw one level less to the right", .selection),
        .init("mindmap.more", "Mindmap: draw one level more to the right", .selection),
        .init("mindmap.org.next", "Mindmap: the next org's Mindmap (personal last)", .selection),
        .init("mindmap.org.prev", "Mindmap: the previous org's Mindmap", .selection),
        .init("mindmap.accept", "Mindmap: keep the suggested placement as it is", .selection),
        .init("mindmap.done", "Mindmap: mark the node's first open follow-up done", .selection),
        .init("mindmap.pin", "Mindmap: pin the node's first decision so it shows above it (again: unpin)", .selection),
        .init("mindmap.nest", "Mindmap: put the node in a new group with its next sibling", .selection),
        .init("mindmap.lift", "Mindmap: lift the node out of what holds it", .selection),
        .init(
            "mindmap.rename", "Mindmap: rename the node (no title: the command line opens with it)", .selection,
            arguments: "[title]"
        ),
        .init(
            "mindmap.move", "Mindmap: move the node into a campaign or group by its title (top: to the top)",
            .selection, arguments: "[title|top]"
        ),
        .init(
            "mindmap.join", "Mindmap: move everything in the node into another by its title, and drop it",
            .selection, arguments: "[title]"
        ),
        .init("mindmap.name", "Mindmap: name campaigns for the work waiting in Unsorted now", .selection),
        .init("mindmap.open", "Mindmap: a piece of work's ledger entry", .selection),
        .init(
            "mindmap.goal",
            "Mindmap: make a goal of this campaign, its work on it and its GOAL.md drafted",
            .selection
        ),
        .init("mindmap.link.next", "Mindmap: to the next node this one links to (led to, same files)", .selection),
        .init("mindmap.link.prev", "Mindmap: to the previous node this one links to", .selection),
        .init(
            "mindmap.session", "Mindmap: start a session on this node, told what was decided and what is open here",
            .selection, arguments: "[prompt]"
        ),
        .init(
            "ledger.edit", "edit the ledger entry's summary (no text: the command line opens with it)", .selection,
            arguments: "[text]"
        ),
        .init(
            "log.kind", "call log: all, or one kind (shell, github, llm, decide)", .selection,
            arguments: "[all|kind]"
        ),
        .init("log.failed", "call log: only calls that failed, or all", .selection),
        .init("log.slow", "call log: only slow calls (5 s or more), or all", .selection),
        .init("log.writes", "call log: only GitHub writes, or all", .selection),
        .init("log.caller", "call log: only the caller of the call under the cursor, or every caller", .selection),
        .init("log.agent", "call log: only the agent of the call under the cursor, or every agent", .selection),
        .init("log.copy", "copy the command of the call under the cursor", .selection),
        .init("github.sync", "sync GitHub now", .selection),
        .init("items.start", "start one session from the picked items", .selection),
        .init("items.add", "add the picked items to the current session", .selection),
        .init(
            "attention.done", "done: mark the thread read on GitHub; it comes back when something new happens",
            .selection
        ),
        .init(
            "attention.snooze", "snooze: out of the feed until later (3h, or 30m, 2d, tomorrow)", .selection,
            arguments: "[duration]"
        ),
        .init(
            "attention.mute", "mute the thread on GitHub (no more notifications about it); listed under Muted",
            .selection
        ),
        .init(
            "attention.reply", "draft a reply with the model; you read it before anything is posted", .selection
        ),
        .init("attention.session", "go to the item's session", .selection),
        .init(
            "attention.filter", "next Attention tab (Muted after Everything), or the one named", .selection,
            arguments: "[filter]"
        ),
        .init("attention.done.new", "done with everything in For you's New since", .selection),
        .init("attention.fold", "For you's Mentioned before: list it, or fold it again", .selection),
        .init("attention.reader.down", "scroll Attention's reader down half its height", .selection),
        .init("attention.reader.up", "scroll Attention's reader up half its height", .selection),
        .init("attention.sort", "Attention: recent first, or weight then recent", .selection),
        .init(
            "attention.summarize",
            "write the thread's catch-up summary again (↻): what is new since you last looked", .selection
        ),
        .init(
            "attention.coverage", "Coverage: what Attention has of each source against GitHub, and where it went",
            .selection
        ),
        .init(
            "helper.do", "do heed's next step for the item (review it, draft a reply, get it green, merge, set up "
                + "Autopilot, start work)", .selection
        ),
        .init(
            "helper.always", "do heed's next step, and from now on always in this repo (turns its Autopilot "
                + "capability on)", .selection
        ),
        .init("helper.other", "propose the item's next other step instead (and back to heed's own)", .selection),
        .init("helper.watch", "Watch it: the helper on the session's PR, in a split under its panes", .selection),
        .init(
            "helper.takeover", "Take it over: stop the helper and hand its branch to your session as a note",
            .selection
        ),
        .init("helper.steer", "tell the helper something (it stops its turn and reads it)", .selection),
        .init("helper.pause", "pause the helper (its turn is cancelled), or let it carry on", .selection),
        .init("helper.stop", "stop the helper; its close-out keeps what it did", .selection),
        .init("helper.zoom", "the helper's split takes the whole column, or not", .selection),
        .init("helper.close", "close the helper's split (it keeps working)", .selection),
        .init("helper.allow", "allow what the helper asks to run, once", .selection),
        .init(
            "helper.allow.always",
            "allow what the helper asks to run, from now on (the agent remembers)",
            .selection
        ),
        .init("helper.deny", "deny what the helper asks to run", .selection),
        .init(
            "helper.push",
            "push the helper's work to the PR's branch and post its replies (a review: post it)",
            .selection
        ),
        .init("helper.push.only", "push the helper's work to the PR's branch, without its replies", .selection),
        .init(
            "helper.throwaway",
            "throw away what the helper did: its worktree and branch go (twice, to be sure)",
            .selection
        ),
        .init("helper.diff", "the helper's whole diff, in its close-out", .selection),
        .init("helper.tile.next", "Now: the next helper's tile", .selection),
        .init("helper.tile.prev", "Now: the previous helper's tile", .selection),
        .init("feedback.queue", "queue / unqueue the item", .selection),
        .init("feedback.send", "send queued feedback to the session", .selection),
        .init("feedback.mode", "pilot.green, by its former name", .selection),
        .init("feedback.watch", "pilot.watch, by its former name", .selection),
        .init("pilot.why", "what heed will do for the PR, and what holds it back", .selection),
        .init("pilot.watch", "watch or stop watching the PR (or the picked PRs)", .selection),
        .init(
            "pilot.green", "cycle get it green for the PR: off, ask, auto (or set the one named)", .selection,
            arguments: "[off|ask|auto]"
        ),
        .init("pilot.run", "show the session's running get it green / get it merged run", .selection),
        .init("pilot.run.stop", "stop the session's running get it green / get it merged run", .selection),
        .init("pilot.retry", "one more round of get it green for a stalled PR (or the picked PRs)", .selection),
        .init(
            "pilot.copilot", "ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments",
            .selection
        ),
        .init("pilot.reviewers", "ask the PR's configured reviewers ([pilot] reviewers) to review it", .selection),
        .init("pilot.merge", "get it merged for the PR (or the picked PRs): off or auto", .selection),
        .init(
            "pilot.merge.now",
            "merge the PR now; past unmet required reviews or checks with --admin when you are an admin (merge_now, force_merge)",
            .selection
        ),
        .init("pilot.merge.setup", "set up get it merged for the PR's repo", .selection),
        .init(
            "merge.run",
            "run a repo's merge queue now (no name: the PR's repo; all: every queue)",
            .selection,
            arguments: "[repo|all]"
        ),
        .init(
            "merge.queue",
            "show a repo's merge queue and its runs (no name: the PR's repo)",
            .selection,
            arguments: "[repo]"
        ),
        .init(
            "pilot.pause", "pause the PR (or the picked PRs), or resume: 30m, 1h, 4h, 1d, forever, off", .selection,
            arguments: "[duration]"
        ),
        .init("feedback.dismiss", "dismiss the item", .selection),
        .init("feedback.session", "start a new session from this PR", .selection),
        .init("diff.hunk.next", "next hunk", .selection),
        .init("diff.hunk.prev", "previous hunk", .selection),
        .init("diff.file.next", "next file", .selection),
        .init("diff.file.prev", "previous file", .selection),
        .init("diff.scope.next", "next scope: all, committed, staged, unstaged", .selection),
        .init("diff.scope.prev", "previous scope", .selection),
        .init(
            "diff.commit",
            "show one commit (cycles; a sha shows that one, all the whole branch)",
            .selection,
            arguments: "[sha|all]"
        ),
        .init("diff.split", "unified / split", .selection),
        .init("diff.ask", "queue feedback on this hunk (or the selected lines)", .selection),
        .init("diff.ask.now", "ask the agent about this hunk (or the selected lines) now", .selection),
        .init("diff.copy", "copy path:line (path:first-last for selected lines)", .selection),
        .init("diff.edit", "open the file in the editor", .selection),
        .init(
            "repo.add",
            "add or clone a repo: the dialog, or the repo at a path added (kept in repo_paths outside the roots)",
            .selection,
            arguments: "[path]"
        ),
        .init("repo.reveal", "show the repo's folder in Finder", .selection),
        .init(
            "repos.focus",
            "Repos: between the repo column and the worktree table (repos, worktrees, or the other one)",
            .selection,
            arguments: "[repos|worktrees]"
        ),
        .init("repo.scan", "refresh: rescan the repo roots", .selection),
        .init("worktree.new", "start work in the repo under the cursor", .selection),
        .init(
            "setup.review",
            "the setup heed detected for the repo's new worktrees: approve, edit or never",
            .selection
        ),
        .init("setup.approve", "approve the detected setup for the repo's new worktrees", .selection),
        .init("setup.never", "no setup for the repo's new worktrees, and no more proposals", .selection),
        .init("setup.edit", "edit the repo's setup commands (Settings, Orgs & repos)", .selection),
        .init(
            "repo.setup",
            "set up get it merged and get it green for the repo: sample its history, propose, validate, write config",
            .selection,
            arguments: "[repo]"
        ),
        .init("select.remove", "remove the selected worktrees, or the one under the cursor (asks first)", .selection),
        .init("select.pin", "pin selected", .selection),
        .init("select.copy", "copy paths", .selection),
        .init("select.open", "open the worktree's session, importing it when it has none", .selection),
    ]

    public static let byName: [String: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> CommandSpec? { byName[name] }

    /// Commands that were renamed, old name to new: config.toml bindings and `:` still take the old name.
    public static let renamed: [String: String] = ["cleanup.sweep": "cleanup.run"]

    /// A binding's command line with a renamed command's new name (`cleanup.sweep` runs `cleanup.run`).
    public static func current(_ line: String) -> String {
        let invocation = CommandInvocation(parsing: line)
        guard let name = renamed[invocation.name] else { return line }
        return ([name] + invocation.arguments).joined(separator: " ")
    }

    /// Commands that only make sense as keys on the command line itself: `:` runs them but does not offer them.
    public static let keyOnly: Set<String> = ["command.submit", "command.complete", "command.complete.prev"]

    /// Names that start with `prefix`, for `:` completion.
    public static func complete(_ prefix: String) -> [CommandSpec] {
        all.filter { $0.name.hasPrefix(prefix) && !keyOnly.contains($0.name) }
    }
}
