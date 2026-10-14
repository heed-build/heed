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
        .init("session.open", "go to the session matching these words", .move, arguments: "<words>"),
        .init("pin.jump", "jump to pinned session", .move, arguments: "<1-9>"),
        .init("work.start", "start work", .move),
        .init("work.start.panel", "start work in the floating panel, as the global shortcut does", .move),
        .init("resume", "pick up where you left off: the sessions to resume, as on launch", .move),
        .init("work.again", "start work from this session's prompt", .move),
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
        .init("tab.next", "next tab", .panes),
        .init("tab.prev", "previous tab", .panes),
        .init("tab.new", "new tab with shell", .panes),
        .init("tab.go", "go to tab n", .panes, arguments: "<n>"),
        // Views & overlays
        .init("view", "switch view", .views, arguments: "<sessions|inbox|issues|prs|repos|history>"),
        .init("view.sessions", "sessions", .views),
        .init("view.inbox", "inbox", .views),
        .init("view.issues", "issues", .views),
        .init("view.prs", "pull requests", .views),
        .init("view.watch", "watch: the PRs your sessions track, what heed does for each and has done", .views),
        .init("view.repos", "repos & worktrees", .views),
        .init("overlay.pr", "PR overlay for this session (toggle)", .views),
        .init("overlay.item", "open the PR or issue under the cursor; in Sessions, the session's PR (toggle)", .views),
        .init("overlay.diff", "diff overlay: commits, staged, unstaged", .views),
        .init("overlay.help", "keys & states", .views),
        .init("overlay.close", "close overlay", .views),
        .init("pr.next", "next PR of this session", .views),
        .init("pr.prev", "previous PR of this session", .views),
        .init("pr.session", "jump from a PR to its session", .views),
        .init("pr.track", "track a PR by URL", .views, arguments: "<url>"),
        .init("jump.back", "back", .views),
        .init("open.browser", "open in browser", .views),
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
        .init("tutor.back", "the tutor's previous step, the world as it was then", .views),
        .init("tutor.skip", "skip the tutor's step", .views),
        .init("tutor.exit", "leave the tutor; your sessions come back as they were", .views),
        .init("tools.detect", "find git and gh again (login shell PATH, usual places, [tools])", .views),
        .init("app.quit", "quit Heed", .views),
        .init(
            "settings.open", "open Settings, on a section (general, agents, colors, cleanup, pilot, keys)", .views,
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
        .init("command.complete", "complete", .modes),
        // Selection
        .init("select.toggle", "toggle row", .selection),
        .init("history.reopen", "reopen: resume, recreating the worktree if needed", .selection),
        .init("history.again", "start a new session from this prompt", .selection),
        .init("history.outcome", "cycle the outcome filter", .selection),
        .init("github.sync", "sync GitHub now", .selection),
        .init("items.start", "start one session from the picked items", .selection),
        .init("items.add", "add the picked items to the current session", .selection),
        .init("items.read", "mark read", .selection),
        .init("items.filter", "cycle the filter chips", .selection),
        .init("issues.repo.next", "next repo in the Issues repo column", .selection),
        .init("issues.repo.prev", "previous repo in the Issues repo column", .selection),
        .init("issues.repo", "show one repo's issues (no name: every repo)", .selection, arguments: "[name]"),
        .init("issues.visibility", "flip the repo under the cursor between all issues and only yours", .selection),
        .init("feedback.queue", "queue / unqueue the item", .selection),
        .init("feedback.send", "send queued feedback to the session", .selection),
        .init("feedback.mode", "pilot.green, by its former name", .selection),
        .init("feedback.watch", "pilot.watch, by its former name", .selection),
        .init("pilot.why", "what holds the PR back from green, rule by rule (in the Watch view)", .selection),
        .init("pilot.watch", "watch or stop watching the PR (or the picked PRs)", .selection),
        .init("pilot.green", "cycle get it green for the PR: off, ask, auto", .selection),
        .init(
            "pilot.copilot", "ask GitHub's Copilot coding agent to resolve the PR's conflicts and address its comments",
            .selection
        ),
        .init("pilot.reviewers", "ask the PR's configured reviewers ([pilot] reviewers) to review it", .selection),
        .init("pilot.merge", "get it merged for the PR (or the picked PRs): off or auto", .selection),
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
        .init("diff.ask", "ask the agent about this hunk", .selection),
        .init("diff.copy", "copy path:line", .selection),
        .init("diff.edit", "open the file in the editor", .selection),
        .init("repo.add", "add a repo outside the scanned roots (kept in repo_paths)", .selection, arguments: "<path>"),
        .init("repo.scan", "refresh: rescan the repo roots", .selection),
        .init("worktree.new", "start work in the repo under the cursor", .selection),
        .init("select.remove", "remove the selected worktrees, or the one under the cursor (asks first)", .selection),
        .init("select.pin", "pin selected", .selection),
        .init("select.copy", "copy paths", .selection),
        .init("select.open", "open the worktree's session, importing it when it has none", .selection),
    ]

    public static let byName: [String: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> CommandSpec? { byName[name] }

    /// Names that start with `prefix`, for `:` completion.
    public static func complete(_ prefix: String) -> [CommandSpec] {
        all.filter { $0.name.hasPrefix(prefix) }
    }
}
