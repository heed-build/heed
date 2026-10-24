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
        // Panes & tabs
        .init("pane.left", "focus pane left", .panes),
        .init("pane.right", "focus pane right", .panes),
        .init("pane.up", "focus pane above", .panes),
        .init("pane.down", "focus pane below", .panes),
        .init("pane.split.right", "split right", .panes),
        .init("pane.split.below", "split below", .panes),
        .init("pane.zoom", "zoom pane", .panes),
        .init("pane.close", "close pane", .panes),
        .init("tab.close", "close the tab, every pane in it", .panes),
        .init("tab.next", "next tab", .panes),
        .init("tab.prev", "previous tab", .panes),
        .init("tab.new", "new tab with shell", .panes),
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
            arguments: "<sessions|attention|inbox|issues|prs|watch|repos|history|timeline|ledger|dashboard|log>"
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
            "open Settings, on a section (general, agents, colors, cleanup, pilot, attention, keys, hosts)",
            .views,
            arguments: "[section]"
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
        .init("diff.commit", "show one commit (cycles)", .selection),
        .init("diff.split", "unified / split", .selection),
        .init("diff.ask", "queue feedback on this hunk", .selection),
        .init("diff.ask.now", "ask the agent about this hunk now", .selection),
        .init("diff.copy", "copy path:line", .selection),
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
