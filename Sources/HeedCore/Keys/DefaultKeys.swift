/// The default bindings, per mode, in the same notation as `[keys.<mode>]` in config.toml. Config entries are laid over
/// these; `"gC" = ""` unbinds a default.
public enum DefaultKeys {
    /// INSERT's way out. Configurable as `insert_escape` because `<C-\>` is also SIGQUIT in a terminal.
    public static let insertEscape = "<C-\\>"

    public static let normal: [(String, String)] = [
        ("j", "row.next"), ("k", "row.prev"), ("<Down>", "row.next"), ("<Up>", "row.prev"),
        ("gg", "row.first"), ("G", "row.last"), ("/", "session.filter"),
        ("<C-d>", "row.halfpage.down"), ("<C-u>", "row.halfpage.up"), ("}", "group.next"), ("{", "group.prev"),
        ("h", "pane.left"), ("l", "pane.right"),
        ("o", "work.start"), ("O", "work.again"), ("gc", "chat.new"), ("gA", "agent.switch"), (
            "ga",
            "session.attention"
        ),
        ("gZ", "summary"),
        (
            "zz",
            "session.park"
        ),
        ("x", "session.close"), ("m", "session.pin"), ("''", "session.back"),
        ("'1", "pin.jump 1"), ("'2", "pin.jump 2"), ("'3", "pin.jump 3"), ("'4", "pin.jump 4"), ("'5", "pin.jump 5"),
        ("'6", "pin.jump 6"), ("'7", "pin.jump 7"), ("'8", "pin.jump 8"), ("'9", "pin.jump 9"),
        ("gG", "view.goals"), ("'g", "goal.jump"),
        ("gh", "view.history"), ("gr", "view.repos"), ("gw", "view.watch"), ("gM", "merge.queue"), ("gH", "host.open"),
        (
            "@",
            "host.filter"
        ),
        ("<C-w>v", "pane.split.right"), ("<C-w>s", "pane.split.below"), ("<C-w>z", "pane.zoom"),
        ("<C-w>q", "pane.close"), ("<C-w>h", "pane.left"), ("<C-w>l", "pane.right"), ("<C-w>j", "pane.down"),
        ("<C-w>k", "pane.up"), ("<C-w>c", "tab.close"),
        // Sizes as in vim: the focused pane grows or shrinks; = makes them all equal again.
        ("<C-w>>", "pane.wider"), ("<C-w><lt>", "pane.narrower"), ("<C-w>+", "pane.taller"),
        ("<C-w>-", "pane.shorter"), ("<C-w>=", "pane.equalize"),
        ("gt", "tab.next"), ("gT", "tab.prev"), ("gn", "tab.new"), ("!", "task.run"),
        ("g>", "tab.move.right"), ("g<lt>", "tab.move.left"),
        ("gs", "view.sessions"), ("gm", "view.attention"), ("gi", "view.attention issues"),
        ("gp", "view.attention mine"),
        ("gl", "links.pick"), ("gI", "issue.add"), ("go", "overlay.item"), ("]p", "pr.next"), ("[p", "pr.prev"), (
            "gd",
            "overlay.diff"
        ), ("gS", "pr.session"),
        ("<C-o>", "jump.back"), ("gB", "open.browser"), ("gR", "open.repo"), ("gU", "pr.track"), (
            "gC",
            "cleanup.sweep"
        ),
        ("zi", "inspector.toggle"), ("zs", "sidebar.toggle"),
        // The pilot, the same keys everywhere: the PR under the cursor, the open PR, or the session's PRs.
        ("z?", "pilot.why"), ("zv", "pilot.reviewers"), ("gb", "pilot.run"), ("zx", "pilot.run.stop"),
        ("zw", "pilot.watch"), ("zg", "pilot.green"), ("zm", "pilot.merge"), ("zM", "pilot.merge.now"), (
            "zp",
            "pilot.pause"
        ), (
            "zr",
            "pilot.retry"
        ), (
            "<CR>",
            "open.reader"
        ),
        ("i", "mode.insert"), ("v", "mode.visual"), ("V", "mode.visual"), (":", "mode.command"),
        ("f", "mode.hint"), ("F", "hint.insert"),
        ("?", "overlay.help"), ("<D-/>", "overlay.help"), ("<Esc>", "overlay.close"),
        ("<D-,>", "settings.open"), ("<D-T>", "tutor"), ("<D-.>", "tutor.exit"),
    ]

    public static let visual: [(String, String)] = [
        ("j", "row.next"), ("k", "row.prev"), ("gg", "row.first"), ("G", "row.last"),
        ("<Space>", "select.toggle"), ("d", "select.remove"), ("m", "select.pin"), ("y", "select.copy"),
        ("o", "select.open"), ("zp", "pilot.pause"), ("<Esc>", "mode.normal"), ("?", "overlay.help"),
        ("<D-/>", "overlay.help"),
    ]

    public static let insert: [(String, String)] = [
        (insertEscape, "mode.normal"), ("<S-Esc>", "mode.normal"), ("<D-/>", "overlay.help"),
        ("<D-T>", "tutor"), ("<D-.>", "tutor.exit"),
    ]

    public static let command: [(String, String)] = [
        ("<Esc>", "mode.normal"), ("<CR>", "command.submit"), ("<Tab>", "command.complete"),
        ("<S-Tab>", "command.complete.prev"), ("<Down>", "command.complete"), ("<Up>", "command.complete.prev"),
        ("<D-/>", "overlay.help"),
    ]

    public static let hint: [(String, String)] = [
        ("<Esc>", "mode.normal"), ("<D-/>", "overlay.help"),
    ]

    /// Bindings that only apply in one view, keyed by view name.
    public static let scoped: [String: [(String, String)]] = [
        // ↩ on a session types into its agent; go, gB and gl still read or open its PRs and issues.
        "sessions": [
            ("dd", "session.delete"), ("Iw", "session.import"), ("Ip", "session.import.path"),
            ("<CR>", "session.agent"),
        ],
        "repos": [
            ("o", "worktree.new"), ("r", "repo.scan"), ("w", "issues.visibility"), ("dd", "select.remove"),
            ("<CR>", "select.open"), ("S", "setup.review"), ("M", "repo.setup"),
        ],
        // ↩ and a double-click reopen, as R does: there is nothing else in History to open.
        "history": [
            ("R", "history.reopen"), ("<CR>", "history.reopen"),
            ("O", "history.again"),
            ("t", "history.outcome"),
            ("T", "history.timeline"),
            ("L", "history.ledger"),
            ("D", "history.dashboard"),
        ],
        // History's timeline (T, :timeline); T again goes back to the list.
        "timeline": [
            ("T", "history.timeline"), ("L", "history.ledger"), ("R", "history.reopen"), ("<CR>", "history.reopen"),
            ("t", "timeline.kind"),
            ("r", "timeline.repo"), ("w", "timeline.where"), ("D", "timeline.gone"),
        ],
        // History's ledger (L, :ledger); L again goes back to the list.
        "ledger": [
            ("L", "history.ledger"), ("T", "history.timeline"), ("D", "history.dashboard"), ("R", "history.reopen"),
            ("<CR>", "history.reopen"), ("S", "ledger.summarize"), ("E", "ledger.edit"),
        ],
        // History's dashboard (D, :dashboard); D again goes back to the list.
        "dashboard": [
            ("D", "history.dashboard"), ("T", "history.timeline"), ("L", "history.ledger"), ("R", "history.reopen"),
            ("<CR>", "history.reopen"), ("r", "dashboard.range"),
        ],
        // Goals (gG): j k move through the goals, ⇥ to what belongs to the one under the cursor, ↩ opens.
        "goals": goals,
        // A goal's board (B): h l columns, j k cards, H L move the card, a adds one (n as well: it is new there),
        // s or o starts work on it, D is done, - splits it.
        "goalboard": paneWith([
            ("a", "goal.item.add"), ("n", "goal.item.add"), ("H", "goal.item.move left"),
            ("L", "goal.item.move right"), ("h", "goal.item.column -1"), ("l", "goal.item.column 1"),
            ("s", "goal.item.work"), ("o", "goal.item.work"), ("<CR>", "goal.item.open"), ("D", "goal.item.done"),
            ("-", "goal.item.split"), ("<Tab>", ""), ("<S-Tab>", ""),
        ]),
        // A goal's GOAL.md (E): y n on the first change waiting, c rewords it, u takes back heed's last, w sharpens.
        "goaldoc": goalsWith([
            ("y", "goal.proposal.accept"), ("n", "goal.proposal.reject"), ("c", "goal.proposal.edit"),
            ("u", "goal.undo"), ("w", "goal.sharpen"),
        ]),
        // A goal's Reviewers (R): A accepts a risk, s starts a session to fix, c asks why, N spawns a reviewer, r has
        // them all look again.
        "goalreviewers": paneWith([
            ("A", "review.accept"), ("s", "review.fix"), ("c", "review.why"), ("N", "reviewer.spawn"),
            ("r", "review.recheck"),
        ]),
        // A goal's Personas (P): s spawns the persona as a session, c as a chat, N as a reviewer; e edits its file,
        // r works the list out again, p shares (publishes) the persona to the library.
        "goalpersonas": paneWith([
            ("s", "persona.session"), ("c", "persona.chat"), ("N", "persona.reviewer"), ("e", "persona.edit"),
            ("r", "persona.derive"), ("p", "persona.share"),
        ]),
        // A goal's Evaluations (X): s starts a session to fix the friction, A accepts it (as a risk in Reviewers), r
        // walks again, h l pick the lens.
        "goalevals": paneWith([
            ("s", "eval.fix"), ("A", "eval.accept"), ("r", "eval.rewalk"), ("h", "eval.lens -1"), ("l", "eval.lens 1"),
        ]),
        // A goal's swarm (S): e edits the task, a adds one, J K move it, x drops it, r asks the lead to re-plan, A
        // approves the plan, y n answer a change waiting (as in GOAL.md), 1…9 pick that option of the question under
        // the cursor (else the first open one) and i types an answer, d the version's whole diff, u restores it.
        "goalplan": paneWith([
            ("e", "swarm.task.edit"), ("a", "swarm.task.add"), ("J", "swarm.task.move 1"), ("K", "swarm.task.move -1"),
            ("x", "swarm.task.drop"), ("r", "swarm.replan"), ("A", "swarm.approve"), ("y", "swarm.accept"),
            ("n", "swarm.reject"), ("i", "swarm.answer"), ("d", "swarm.diff"), ("u", "swarm.restore"),
            // Once it runs: p pauses or resumes the task, t hands it to another agent, s goes to its worker's tab.
            ("p", "swarm.task.pause"), ("t", "swarm.task.swap"), ("s", "swarm.task.open"),
            // Landing: m shows the plan in merge order (again: by phase), b moves the task's stacked PR to its new
            // base once the PR it stacks on merged (heed does it on its own; b is for after gh refused).
            ("m", "swarm.order"), ("b", "swarm.land"),
            // Steering: c hands the question under the cursor to the controller, w shows the log by who decided, q
            // jumps between a question and its answer. 1…9 and i on an answered question answer it again: an
            // overrule.
            ("c", "swarm.controller"), ("w", "swarm.log.who"), ("q", "swarm.log.jump"),
            // Once it is done: F starts a follow-up swarm on the goal.
            ("F", "swarm.followup"),
        ] + (1 ... 9).map { ("\($0)", "swarm.answer.option \($0)") }),
        // A swarm's agents (W): j k move between workers, s or ↩ goes to its tab, p pauses its task, t swaps its agent;
        // on the right Needs you: 1…9 pick an option of the question under the cursor (its worker's, else the first
        // waiting), i types an answer, c asks the controller. Once the swarm is done, its summary: F starts a
        // follow-up.
        "goalagents": paneWith([
            ("s", "swarm.task.open"), ("<CR>", "swarm.task.open"), ("p", "swarm.task.pause"),
            ("t", "swarm.task.swap"), ("i", "swarm.answer"), ("c", "swarm.controller"), ("F", "swarm.followup"),
        ] + (1 ... 9).map { ("\($0)", "swarm.answer.option \($0)") }),
        // The swarm's map (T): h l between columns (the goal, then each phase), j k between the cards of one; s or ↩
        // goes to the card's worker, p pauses its task, t swaps its agent, e edits it in the plan.
        "goalmap": paneWith([
            ("h", "swarm.map.move h"), ("l", "swarm.map.move l"), ("j", "swarm.map.move j"),
            ("k", "swarm.map.move k"), ("<Left>", "swarm.map.move h"), ("<Right>", "swarm.map.move l"),
            ("<Down>", "swarm.map.move j"), ("<Up>", "swarm.map.move k"), ("s", "swarm.task.open"),
            ("<CR>", "swarm.task.open"), ("p", "swarm.task.pause"), ("t", "swarm.task.swap"),
            ("e", "swarm.task.edit"), ("F", "swarm.followup"), ("<Tab>", ""), ("<S-Tab>", ""),
        ]),
        // Goals › Unassigned (U): y n m i answer heed's asks (y on a suggested goal makes it), u undoes.
        "unassigned": paneWith([
            ("y", "goal.ask.yes"), ("n", "goal.ask.no"), ("m", "goal.ask.move"), ("i", "goal.ask.ignore"),
            ("u", "goal.attach.undo"), ("<Tab>", ""), ("<S-Tab>", ""),
        ]),
        // The call log has no key of its own (:log); inside it, its filters.
        "log": [
            ("t", "log.kind"), ("x", "log.failed"), ("s", "log.slow"), ("w", "log.writes"), ("c", "log.caller"),
            ("a", "log.agent"), ("y", "log.copy"),
        ],
        "attention": attention,
        // Attention with a swarm's question under the cursor: 1…9 pick an option, i types an answer, c asks the
        // controller, A makes your next answer the answer to similar questions too; y takes the controller's
        // suggestion (n types another). Everything else is Attention's.
        "swarmask": laid([
            ("i", "swarm.answer"), ("c", "swarm.controller"), ("A", "swarm.similar"),
        ] + (1 ... 9).map { ("\($0)", "swarm.answer.option \($0)") }, over: attention),
        "inbox": [
            ("<Space>", "select.toggle"), ("s", "items.start"), ("a", "items.add"), ("x", "items.read"),
            ("t", "items.filter"), ("r", "github.sync"),
        ],
        "issues": [
            ("<Space>", "select.toggle"), ("s", "items.start"), ("a", "items.add"), ("r", "github.sync"),
            ("t", "items.filter"), ("<Tab>", "issues.repo.next"),
            ("<S-Tab>", "issues.repo.prev"), ("w", "issues.visibility"),
        ],
        "prs": [
            ("r", "github.sync"), ("<Space>", "select.toggle"),
        ],
        "watch": [
            ("r", "github.sync"), ("<Space>", "select.toggle"), ("R", "merge.run"), ("C", "pilot.copilot"),
        ],
        /// The diff overlay. ↩ writes a note on the line, as a double-click does.
        "diff": [
            ("n", "diff.hunk.next"), ("N", "diff.hunk.prev"), ("]f", "diff.file.next"), ("[f", "diff.file.prev"),
            ("<Tab>", "diff.scope.next"), ("<S-Tab>", "diff.scope.prev"), ("c", "diff.commit"), ("t", "diff.split"),
            ("a", "diff.ask"), ("A", "diff.ask.now"), ("y", "diff.copy"), ("e", "diff.edit"), ("<CR>", "diff.ask"),
            ("<Esc>", "overlay.close"),
        ],
        /// The issue reader.
        "issue": [("s", "items.start"), ("a", "items.add"), ("<Esc>", "overlay.close")],
        /// The PR overlay and the reader.
        "pr": [
            // Sideways through the session's PRs, as ]p and [p.
            ("h", "pr.prev"), ("l", "pr.next"), ("<Left>", "pr.prev"), ("<Right>", "pr.next"),
            ("<Space>", "feedback.queue"), ("s", "feedback.send"), ("C", "pilot.copilot"),
            ("x", "feedback.dismiss"), ("S", "feedback.session"), ("<Esc>", "overlay.close"), ("r", "github.sync"),
        ],
    ]

    /// Attention's own keys. heed's goal asks have one key each; on other items m pins as before.
    static let attention: [(String, String)] = [
        ("<Space>", "select.toggle"), ("s", "items.start"), ("a", "items.add"), ("x", "attention.done"),
        ("Z", "attention.snooze"), ("M", "attention.mute"), ("R", "attention.reply"), ("gS", "attention.session"),
        ("t", "attention.filter"), ("T", "attention.sort"), ("r", "github.sync"),
        ("y", "goal.ask.yes"), ("n", "goal.ask.no"), ("m", "goal.ask.move"), ("i", "goal.ask.ignore"),
    ]

    /// Views whose own bindings work in VISUAL too, ahead of VISUAL's: in the diff, `a`, `A` and `y` act on the
    /// selected lines.
    /// The keys of Goals' list and overview: what acts on the goal, and what every view of Goals shares.
    static let goals: [(String, String)] = goalActions + goalShared + [("F", "swarm.followup")]

    /// Lowercase actions on the goal itself. They apply only where the goal is what you are on: the list, the overview
    /// and GOAL.md (where `y` is the first GOAL.md change's yes instead; on the list and overview it is the proposed
    /// source's). Every other pane binds the key to its own row's meaning or leaves it unbound, so a key never falls
    /// through to the goal (`a` in Reviewers does not archive it).
    public static let goalActions: [(String, String)] = [
        ("n", "goal.new"), ("e", "goal.edit"), ("a", "goal.archive"), ("x", "goal.detach"), ("w", "goal.sharpen"),
        ("u", "goal.attach.undo"), ("r", "review.recheck"), ("y", "goal.source.accept"),
    ]

    /// What every view of Goals shares: ↩ and ⇥, the GitHub mirror (M turns it on or off; Y and K answer a colleague's
    /// change: yes / keep heed's), and the capitals that switch the goal's pane.
    static let goalShared: [(String, String)] = [
        ("<CR>", "goal.open"), ("<Tab>", "goal.focus"), ("<S-Tab>", "goal.focus"),
        ("M", "goal.mirror"), ("Y", "goal.mirror.yes"), ("K", "goal.mirror.no"),
    ] + goalPanes

    /// Every view of Goals, by key scope: the list and overview, and each pane of a goal.
    public static let goalScopes = [
        "goals", "goalboard", "goaldoc", "goalreviewers", "goalpersonas", "goalevals", "goalplan", "goalagents",
        "goalmap", "unassigned",
    ]

    /// The capitals that switch a goal's pane. They work the same in every view of Goals, and no pane may bind one of
    /// them to an action of its own: `S` opens the swarm from Personas as from anywhere else.
    public static let goalPanes: [(String, String)] = [
        ("E", "goal.doc"), ("B", "goal.board"), ("R", "goal.reviewers"), ("P", "goal.personas"),
        ("X", "goal.evaluations"), ("U", "goal.unassigned"), ("S", "goal.swarm"), ("W", "goal.agents"),
        ("T", "goal.map"),
    ]

    /// Goals' list keys with `overrides` laid over (an empty command drops the key): GOAL.md, where the goal is the
    /// thing under the cursor.
    static func goalsWith(_ overrides: [(String, String)]) -> [(String, String)] {
        laid(overrides, over: goals)
    }

    /// A goal's pane: what every view of Goals shares, with the pane's own keys laid over. No goal action comes along.
    static func paneWith(_ overrides: [(String, String)]) -> [(String, String)] {
        laid(overrides, over: goalShared)
    }

    private static func laid(_ overrides: [(String, String)], over base: [(String, String)]) -> [(String, String)] {
        let replaced = Set(overrides.map(\.0))
        return base.filter { !replaced.contains($0.0) } + overrides.filter { !$0.1.isEmpty }
    }

    public static let visualScopes: Set<String> = ["diff"]

    public static func table(for mode: Mode) -> [(String, String)] {
        switch mode {
        case .normal: normal
        case .visual: visual
        case .insert: insert
        case .command: command
        case .hint: hint
        }
    }
}

public enum Keymaps {
    public struct Problem: Equatable, Sendable, CustomStringConvertible {
        public let mode: Mode
        public let keys: String
        public let message: String
        public var description: String { "keys.\(mode.rawValue) \"\(keys)\": \(message)" }
    }

    /// Defaults with `overrides` (from config) laid over them. Bad entries are skipped and reported, never fatal: a
    /// typo
    /// in config must not leave you without keys.
    public static func build(
        overrides: [Mode: [(String, String)]] = [:],
        scopedOverrides: [String: [(String, String)]] = [:],
        insertEscape: String = DefaultKeys.insertEscape
    ) -> (keymaps: [Mode: Keymap], scoped: [String: Keymap], problems: [Problem]) {
        var keymaps: [Mode: Keymap] = [:]
        var problems: [Problem] = []
        for mode in Mode.allCases {
            var keymap = Keymap()
            var table = DefaultKeys.table(for: mode)
            if mode == .insert {
                table = table.map { $0.0 == DefaultKeys.insertEscape ? (insertEscape, "mode.normal") : $0 }
            }
            for (notation, command) in table + (overrides[mode] ?? []) {
                do {
                    let keys = try KeyNotation.parse(notation)
                    if command.isEmpty {
                        keymap.unbind(keys)
                        continue
                    }
                    let name = CommandInvocation(parsing: command).name
                    guard Commands.spec(name) != nil else {
                        problems.append(Problem(mode: mode, keys: notation, message: "unknown command '\(name)'"))
                        continue
                    }
                    if mode == .insert || mode == .command || mode == .hint, keys.count > 1 {
                        problems.append(Problem(
                            mode: mode, keys: notation,
                            message: "\(mode.rawValue) mode only binds single keys"
                        ))
                        continue
                    }
                    try keymap.bind(keys, to: command)
                } catch let error as KeyNotation.ParseError {
                    problems.append(Problem(mode: mode, keys: notation, message: error.reason))
                } catch {
                    problems.append(Problem(mode: mode, keys: notation, message: "\(error)"))
                }
            }
            keymaps[mode] = keymap
        }
        var scoped: [String: Keymap] = [:]
        for scope in Set(DefaultKeys.scoped.keys).union(scopedOverrides.keys) {
            var keymap = Keymap()
            for (notation, command) in (DefaultKeys.scoped[scope] ?? []) + (scopedOverrides[scope] ?? []) {
                do {
                    let keys = try KeyNotation.parse(notation)
                    if command.isEmpty {
                        keymap.unbind(keys)
                        continue
                    }
                    guard Commands.spec(CommandInvocation(parsing: command).name) != nil else {
                        problems.append(Problem(
                            mode: .normal,
                            keys: notation,
                            message: "unknown command in [keys.\(scope)]"
                        ))
                        continue
                    }
                    if let clash = clash(keys, with: keymaps[.normal] ?? Keymap()) {
                        problems.append(Problem(mode: .normal, keys: notation, message: "[keys.\(scope)]: \(clash)"))
                        continue
                    }
                    try keymap.bind(keys, to: command)
                } catch {
                    problems.append(Problem(mode: .normal, keys: notation, message: "[keys.\(scope)]: \(error)"))
                }
            }
            scoped[scope] = keymap
        }
        return (keymaps, scoped, problems)
    }

    /// Why a view binding cannot sit next to NORMAL's: part of it is a NORMAL command (`iw` would make `i` wait), or
    /// it is the start of a NORMAL binding (a view `g` would swallow `gg`). Replacing a NORMAL key outright in one view
    /// is fine; that is what view bindings are for.
    static func clash(_ keys: [KeyStroke], with normal: Keymap) -> String? {
        for length in 1 ..< max(keys.count, 1) {
            let start = Array(keys.prefix(length))
            if case let .command(command) = normal.lookup(start) {
                return "starts with \(KeyNotation.format(start)), which is \(command); pick keys that do not"
            }
        }
        if case .prefix = normal.lookup(keys),
           let longer = normal.bindings.first(where: { $0.keys.count > keys.count && $0.keys.starts(with: keys) })
        {
            return "would hide \(KeyNotation.format(longer.keys)) (\(longer.command)); pick keys that do not"
        }
        return nil
    }
}
