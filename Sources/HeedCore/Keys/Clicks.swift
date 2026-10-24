/// What a click on something that shows a key does: the command that key runs, by the same path. Nothing here runs a
/// command; it only says which one a click means, so the app hands it to `perform` as it would a key.
public enum Clicks {
    /// The tooltip of a clickable key hint: the command as `:` takes it, then what it does. `:pilot.green ask: cycle
    /// get it green for the PR: off, ask, auto`.
    public static func help(_ invocation: CommandInvocation) -> String {
        let line = ([invocation.name] + invocation.arguments).joined(separator: " ")
        guard let summary = Commands.spec(invocation.name)?.summary else { return ":" + line }
        return ":\(line): \(summary)"
    }

    /// A command row of the `?` overlay, clicked.
    public enum HelpAction: Equatable, Sendable {
        /// Runs at once, as its key would.
        case run(CommandInvocation)
        /// Needs an argument (`pin.jump <1-9>`): `:` opens with this typed, its completions listed.
        case prompt(String)
    }

    /// A command whose argument is required (`<n>`) cannot run from a click alone: it opens `:` with its name typed.
    /// One whose argument is optional (`[path]`) runs without it, as its key does.
    public static func helpAction(for spec: CommandSpec) -> HelpAction {
        if let arguments = spec.arguments, arguments.hasPrefix("<") { return .prompt(spec.name + " ") }
        return .run(CommandInvocation(name: spec.name))
    }

    /// A tab of the PR overlay, clicked: `pr.next` or `pr.prev` with the count that lands on it, as `2]p` would.
    /// Nil when it is the tab already shown, or either index is not a tab.
    public static func tabStep(from current: Int, to index: Int, count: Int) -> CommandInvocation? {
        guard (0 ..< count).contains(current), (0 ..< count).contains(index), current != index else { return nil }
        return index > current ? CommandInvocation(name: "pr.next", count: index - current)
            : CommandInvocation(name: "pr.prev", count: current - index)
    }
}

public extension ModeEngine {
    /// What `keys` run in NORMAL, with nothing pending: the view's own binding first (`scope`), then NORMAL's. A
    /// double-click on a list row runs what ↩ runs there.
    func normalCommand(for keys: [KeyStroke], scope: String?) -> CommandInvocation? {
        if let scope, case let .command(line) = scopedKeymaps[scope]?.lookup(keys) {
            return CommandInvocation(parsing: line)
        }
        if case let .command(line) = keymaps[.normal]?.lookup(keys) { return CommandInvocation(parsing: line) }
        return nil
    }
}

/// The status bar's hint line, `j k move · / filter · R reopen`, when the bar is narrower than it: whole hints are
/// dropped from the end, so the first ones, the most important, always show.
public enum HintLine {
    public static let separator = " · "

    /// The line, then each shorter version of it, one hint fewer each time, down to the first hint alone.
    public static func shortenings(_ line: String) -> [String] {
        let hints = line.components(separatedBy: separator)
        guard hints.count > 1 else { return [line] }
        return (1 ... hints.count).reversed().map { hints.prefix($0).joined(separator: separator) }
    }
}

public extension AutoFeed {
    /// `pilot.green [off|ask|auto]`: the mode named, or without a name (or one that is no mode) the next after
    /// `current`, as the key cycles.
    static func chosen(_ name: String?, after current: AutoFeed) -> AutoFeed {
        name.flatMap(named) ?? current.next
    }
}

public extension CallLogQuery {
    /// `log.kind [all|kind]`: `all` shows every kind, a kind named shows it (again: every kind), none cycles.
    mutating func cycleKind(named name: String?) {
        if name?.lowercased() == "all" { return kind = nil }
        cycleKind(to: name.map(CallKind.init(rawValue:)))
    }
}
