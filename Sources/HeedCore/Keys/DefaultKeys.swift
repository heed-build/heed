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
        ("o", "work.start"), ("O", "work.again"), ("ga", "session.attention"), ("zz", "session.park"),
        ("x", "session.close"), ("m", "session.pin"), ("''", "session.back"),
        ("'1", "pin.jump 1"), ("'2", "pin.jump 2"), ("'3", "pin.jump 3"), ("'4", "pin.jump 4"), ("'5", "pin.jump 5"),
        ("'6", "pin.jump 6"), ("'7", "pin.jump 7"), ("'8", "pin.jump 8"), ("'9", "pin.jump 9"),
        ("gh", "view.history"), ("gr", "view.repos"), ("gw", "view.watch"), ("gM", "merge.queue"), ("gH", "host.open"),
        (
            "@",
            "host.filter"
        ),
        ("<C-w>v", "pane.split.right"), ("<C-w>s", "pane.split.below"), ("<C-w>z", "pane.zoom"),
        ("<C-w>q", "pane.close"), ("<C-w>h", "pane.left"), ("<C-w>l", "pane.right"), ("<C-w>j", "pane.down"),
        ("<C-w>k", "pane.up"),
        ("gt", "tab.next"), ("gT", "tab.prev"), ("gn", "tab.new"),
        ("gs", "view.sessions"), ("gm", "view.inbox"), ("gi", "view.issues"), ("gp", "view.prs"),
        ("go", "overlay.item"), ("]p", "pr.next"), ("[p", "pr.prev"), ("gd", "overlay.diff"), ("gS", "pr.session"),
        ("<C-o>", "jump.back"), ("gB", "open.browser"), ("gR", "open.repo"), ("gU", "pr.track"), (
            "gC",
            "cleanup.sweep"
        ),
        ("zi", "inspector.toggle"), ("zs", "sidebar.toggle"),
        // The pilot, the same keys everywhere: the PR under the cursor, the open PR, or the session's PRs.
        ("zw", "pilot.watch"), ("zg", "pilot.green"), ("zm", "pilot.merge"), ("zp", "pilot.pause"), (
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
        ("<D-/>", "overlay.help"),
    ]

    public static let hint: [(String, String)] = [
        ("<Esc>", "mode.normal"), ("<D-/>", "overlay.help"),
    ]

    /// Bindings that only apply in one view, keyed by view name.
    public static let scoped: [String: [(String, String)]] = [
        "sessions": [("dd", "session.delete"), ("Iw", "session.import"), ("Ip", "session.import.path")],
        "repos": [
            ("o", "worktree.new"), ("r", "repo.scan"), ("w", "issues.visibility"), ("dd", "select.remove"),
            ("<CR>", "select.open"),
        ],
        "history": [("R", "history.reopen"), ("O", "history.again"), ("t", "history.outcome")],
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
        /// The diff overlay.
        "diff": [
            ("n", "diff.hunk.next"), ("N", "diff.hunk.prev"), ("]f", "diff.file.next"), ("[f", "diff.file.prev"),
            ("<Tab>", "diff.scope.next"), ("<S-Tab>", "diff.scope.prev"), ("c", "diff.commit"), ("t", "diff.split"),
            ("a", "diff.ask"), ("y", "diff.copy"), ("e", "diff.edit"), ("<Esc>", "overlay.close"),
        ],
        /// The issue reader.
        "issue": [("s", "items.start"), ("a", "items.add"), ("<Esc>", "overlay.close")],
        /// The PR overlay and the reader.
        "pr": [
            ("<Space>", "feedback.queue"), ("s", "feedback.send"), ("C", "pilot.copilot"),
            ("x", "feedback.dismiss"), ("S", "feedback.session"), ("<Esc>", "overlay.close"), ("r", "github.sync"),
        ],
    ]

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
