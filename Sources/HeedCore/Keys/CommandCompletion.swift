/// One thing `:` offers for the line typed so far: a command, a short form, or an argument once a space is typed.
public struct CommandCompletion: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case command, alias, argument }

    public let kind: Kind
    /// The line once this is taken: `view.watch`, `view watch`, `session.open Fix the docs`.
    public let line: String
    /// What the list shows: the command or short form, or the argument.
    public let label: String
    /// The argument placeholder (`<n>`), shown after a command or short form.
    public let arguments: String?
    /// What it does; for a short form, what it runs.
    public let summary: String
}

/// What arguments can be offered right now: the parts of the world `:` completes over.
public struct CompletionContext: Sendable {
    /// Session titles, in sidebar order.
    public var sessions: [String] = []
    /// Pinned sessions' titles, in pin order: `'1` is the first.
    public var pins: [String] = []
    /// The current session's tab titles.
    public var tabs: [String] = []
    public var hosts: [String] = []
    public var agents: [String] = []
    /// The current session's agent, which `agent.switch` does not offer.
    public var currentAgent: String?
    /// Repos with a merge queue (`owner/name`).
    public var mergeRepos: [String] = []
    /// Repos with issues, by name.
    public var issueRepos: [String] = []
    /// The current session's tracked PRs and linked issues, as URLs.
    public var pulls: [String] = []
    public var issues: [String] = []

    public init() {}
}

public enum CommandCompletions {
    /// `:settings.open <section>`.
    public static let settingsSections = ["general", "agents", "colors", "cleanup", "pilot", "keys"]

    /// `:pilot.pause <duration>`, the durations offered (any `<n>m|h|d` works).
    public static let pauseDurations: [(String, String)] = [
        ("30m", "half an hour"), ("1h", "an hour"), ("4h", "four hours"), ("1d", "a day"),
        ("forever", "until resumed"), ("off", "resume now"),
    ]

    /// Everything `:` offers for `line`. Before a space: every command and short form starting with it (commands that
    /// only work as COMMAND's own keys left out). After one: the arguments the command takes that start with (or, for
    /// words such as session titles, contain) what follows.
    public static func candidates(
        _ line: String,
        _ context: CompletionContext = CompletionContext()
    ) -> [CommandCompletion] {
        guard let space = line.firstIndex(of: " ") else {
            let commands = Commands.complete(line).map { spec in
                CommandCompletion(
                    kind: .command, line: spec.name + (spec.arguments == nil ? "" : " "), label: spec.name,
                    arguments: spec.arguments, summary: spec.summary
                )
            }
            let aliases = CommandAliases.listed.filter { $0.name.hasPrefix(line) }.map { alias in
                CommandCompletion(
                    kind: .alias, line: alias.name + (alias.arguments == nil ? "" : " "), label: alias.name,
                    arguments: alias.arguments, summary: "→ :\(alias.runs)"
                )
            }
            return commands + aliases
        }
        let name = String(line[..<space])
        let typed = String(line[line.index(after: space)...])
        let words = arguments(for: name, context)
        let key = typed.lowercased()
        let starting = words.filter { $0.value.lowercased().hasPrefix(key) }
        let containing = words.filter { !$0.value.lowercased().hasPrefix(key) && $0.value.lowercased().contains(key) }
        return (starting + containing).map { value, summary in
            CommandCompletion(kind: .argument, line: "\(name) \(value)", label: value, arguments: nil, summary: summary)
        }
    }

    /// The arguments a command (or short form) takes, with a word on each. Free text (paths, URLs, prompts) has none.
    public static func arguments(for name: String, _ context: CompletionContext) -> [(value: String, summary: String)] {
        switch name {
        case "view": CommandAliases.views.map { ($0, Commands.spec("view.\($0)")?.summary ?? "") }
        case "session.open": context.sessions.map { ($0, "") }
        case "pin.jump": context.pins.enumerated().map { ("\($0.offset + 1)", $0.element) }
        case "tab.go": context.tabs.enumerated().map { ("\($0.offset + 1)", $0.element) }
        case "host.filter", "host.roots": context.hosts.map { ($0, "") }
        case "agent": context.agents.map { ($0, "start work with \($0)") }
        case "agent.switch": Handoff.candidates(agents: context.agents, current: context.currentAgent)
            .map { ($0, "hand the session to \($0)") }
        case "settings.open": settingsSections.map { ($0, "") }
        case "pilot.pause": pauseDurations.map { ($0.0, $0.1) }
        case "merge.run": context.mergeRepos.map { ($0, "") } + [("all", "every queue")]
        case "merge.queue": context.mergeRepos.map { ($0, "") }
        case "issues.repo": context.issueRepos.map { ($0, "") }
        case "pr.untrack": context.pulls.map { ($0, "") }
        case "issue.remove": context.issues.map { ($0, "") }
        case "tutor": ([Tutor.tour] + Tutor.viewLessons).map { ($0.id, $0.title) }
        case "tutor.hide": [("all", "every lesson's reminder")]
        case "log.kind": CallKind.all.map { ($0.rawValue, "") }
        case "wt": [("sweep", "→ :cleanup.sweep")]
        default: []
        }
    }
}
