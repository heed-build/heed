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
        .init("session.filter", "filter by repo, branch, PR, agent", .move),
        .init("session.attention", "next session needing you", .move),
        .init("session.park", "park session", .move),
        .init("session.close", "close session, keep worktree", .move),
        .init("session.pin", "pin / unpin session", .move),
        .init("session.back", "back to previous session", .move),
        .init("pin.jump", "jump to pinned session", .move, arguments: "<1-9>"),
        .init("work.start", "start work", .move),
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
        // Views & overlays
        .init("view", "switch view", .views, arguments: "<sessions|inbox|issues|prs|repos|history>"),
        .init("view.repos", "repos & worktrees", .views),
        .init("overlay.pr", "PR overlay for this session (toggle)", .views),
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
        .init("cleanup.sweep", "run cleanup sweep", .views),
        .init("cleanup.rules", "cleanup rules", .views),
        .init("inspector.toggle", "toggle inspector", .views),
        .init("config.edit", "open config.toml in $EDITOR", .views),
        .init("app.quit", "quit Heed", .views),
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
        .init("items.filter", "cycle the filter", .selection),
        .init("feedback.queue", "queue / unqueue the item", .selection),
        .init("feedback.send", "send queued feedback to the session", .selection),
        .init("feedback.mode", "cycle auto-feed: off, ask, auto when idle", .selection),
        .init("feedback.watch", "pause / resume watching", .selection),
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
        .init("repo.add", "add repo", .selection),
        .init("repo.scan", "rescan repo roots", .selection),
        .init("worktree.new", "new worktree", .selection),
        .init("select.remove", "remove selected", .selection),
        .init("select.pin", "pin selected", .selection),
        .init("select.copy", "copy paths", .selection),
        .init("select.open", "open selected", .selection),
    ]

    public static let byName: [String: CommandSpec] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    public static func spec(_ name: String) -> CommandSpec? { byName[name] }

    /// Names that start with `prefix`, for `:` completion.
    public static func complete(_ prefix: String) -> [CommandSpec] {
        all.filter { $0.name.hasPrefix(prefix) }
    }
}
