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
            arguments: "[agent]"
        ),
        .init("view.history", "history", .move),
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
            arguments: "<sessions|attention|inbox|issues|prs|watch|repos|history|timeline|ledger|dashboard|goals|log>"
        ),
        .init("view.sessions", "sessions", .views),
        .init(
            "view.attention",
            "attention: everything that wants you, one feed, with why (a filter: tagged, reviews, mine, ...)",
            .views, arguments: "[filter]"
        ),
        .init("view.inbox", "inbox", .views),
        .init("view.issues", "issues", .views),
        .init("view.prs", "pull requests", .views),
        .init("view.watch", "watch: the PRs your sessions track, what heed does for each and has done", .views),
        .init("view.repos", "repos & worktrees", .views),
        .init(
            "view.log",
            "the call log: every command and GitHub call heed made, how long it took, how it ended",
            .views
        ),
        .init("view.timeline", "History's timeline: sessions, worktrees, PRs and questions, by day", .views),
        .init("view.dashboard", "History's dashboard: what the work amounted to over a range", .views),
        .init("view.ledger", "History's ledger: a summary of each piece of work, kept after its worktree", .views),
        .init("view.goals", "goals: long-running work, what belongs to each goal, and its GOAL.md", .views),
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
        .init("open.reader", "read inbox item, issue or PR", .views),
        .init("cleanup.rules", "show the cleanup rules (Repos, with its rules panel)", .views),
        .init("cleanup.sweep", "run the cleanup sweep now", .views),
        .init("inspector.toggle", "collapse / expand the inspector", .views),
        .init("sidebar.toggle", "collapse / expand the sessions sidebar", .views),
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
            "open Settings, on a section (general, agents, inference, colors, cleanup, pilot, attention, keys, hosts); "
                + "orgs takes a tab (general, green, merged, reviews, instructions)",
            .views,
            arguments: "[section] [tab]"
        ),
        .init(
            "inference.setup", "set up heed's model calls and decisions (Settings › Inference & decisions)", .views
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
        .init("history.outcome", "cycle the outcome filter", .selection),
        .init("history.timeline", "History as a timeline: what happened, by day (again: back to the list)", .views),
        .init(
            "timeline.kind", "timeline: every kind, or one (sessions, worktrees, prs, questions, chats)", .selection,
            arguments: "[kind]"
        ),
        .init("timeline.repo", "timeline: every repo, or the next one", .selection, arguments: "[name]"),
        .init("timeline.where", "timeline: everywhere, this Mac, or a host", .selection, arguments: "[local|host]"),
        .init("timeline.gone", "timeline: show or hide removed worktrees", .selection),
        .init("history.ledger", "History's ledger: a summary of each piece of work (again: back to the list)", .views),
        .init("history.dashboard", "History's dashboard: sessions, agent time, PRs, by day, agent and repo", .views),
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
        .init("goal.ask.yes", "yes: on the goal heed proposed (on a suggested goal: make it)", .selection),
        .init("goal.ask.no", "no: not on that goal, and heed learns it (on a suggested goal: drop it)", .selection),
        .init(
            "goal.ask.move", "on another goal instead, and heed learns it was not the one it proposed", .selection,
            arguments: "<goal>"
        ),
        .init("goal.ask.ignore", "leave things like this on no goal, and heed learns to (an ignore rule)", .selection),
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
                + "label <name>, reviews, milestone <title> org/repo, or a search)",
            .selection, arguments: "<query>"
        ),
        .init(
            "goal.source.remove",
            "take a source off the goal (its items stay, marked)",
            .selection,
            arguments: "[id]"
        ),
        .init(
            "goal.source.edit", "change a source's query (its items stay; the next sync follows the new one)",
            .selection, arguments: "<id> <query>"
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
        .init("items.read", "mark read", .selection),
        .init("items.filter", "cycle the filter chips", .selection),
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
        .init("attention.filter", "next Attention filter, or the one named", .selection, arguments: "[filter]"),
        .init("attention.sort", "Attention: recent first, or weight then recent", .selection),
        .init("issues.repo.next", "next repo in the Issues repo column", .selection),
        .init("issues.repo.prev", "previous repo in the Issues repo column", .selection),
        .init("issues.repo", "show one repo's issues (no name: every repo)", .selection, arguments: "[name]"),
        .init("issues.visibility", "flip the repo under the cursor between all issues and only yours", .selection),
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
        .init("repo.add", "add a repo outside the scanned roots (kept in repo_paths)", .selection, arguments: "<path>"),
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

    /// Commands that only make sense as keys on the command line itself: `:` runs them but does not offer them.
    public static let keyOnly: Set<String> = ["command.submit", "command.complete", "command.complete.prev"]

    /// Names that start with `prefix`, for `:` completion.
    public static func complete(_ prefix: String) -> [CommandSpec] {
        all.filter { $0.name.hasPrefix(prefix) && !keyOnly.contains($0.name) }
    }
}
