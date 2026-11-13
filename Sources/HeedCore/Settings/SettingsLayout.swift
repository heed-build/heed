import Foundation

// How Settings lays the catalog out: each page's sections in order (the catalog's, plus the few that hold no setting
// of their own: Model calls' setup, Attention's try-before-you-save), the settings that only show while another is
// on, the names `:settings.open` takes, and the tree in the sidebar with its folding and arrow keys.

public extension SettingsPage {
    /// The sections the page shows, in order: what the tree lists under it and the page scrolls to. Pages split into
    /// tabs or scopes (Agents, Pilot, Orgs & repos, Hosts) list none: their sections change with the tab.
    var sections: [String] {
        switch self {
        case .general: ["Sessions", "Outside the window"]
        case .notifications: ["Sessions", "Attention", "Quiet hours", "Nudges"]
        case .updates: ["Updates"]
        case .agents, .pilot, .orgsAndRepos, .hosts: []
        case .modelCalls: ["Set up", "Model calls", "Limits", "Usage", "Reminder"]
        case .decisions: ["Decisions", "Finding new work's goal", "Hunch", "Local decisions"]
        case .worktrees: ["Worktrees", "Branch names", "Start work", "Cleanup", "Saved work"]
        case .goals: ["Agents", "Reviewers", "Items", "GitHub mirror"]
        case .history: ["Ledger", "While you were away", "Mindmap", "Memory", "Standup", "Call log"]
        case .github: ["GitHub"]
        case .attention: ["Rules", "Try before you save", "Summaries", "Weights"]
        case .tools: ["Found", "Tools"]
        case .keys: ["Modes", "Global shortcuts", "Bindings"]
        }
    }

    /// The tabs the page splits into, in order (Agents' per agent, Pilot's).
    var tabs: [SettingsTab] {
        switch self {
        case .agents: [.sessions, .modelCalls]
        case .pilot: [.green, .merged, .reviews, .instructions]
        default: []
        }
    }

    /// The line under the page's title.
    var subtitle: String {
        switch self {
        case .general: "How sessions start and come back, and what heed shows outside its window."
        case .notifications: "When heed taps you on the shoulder: notifications, quiet hours, and its own nudges."
        case .updates: "New versions of heed, signed by its key and notarized by Apple."
        case .agents: "Each agent heed starts: how it runs, what it starts on, and its part in heed's model calls."
        case .modelCalls: "heed's own short calls (summaries, drafted replies, goal plans) through an agent CLI you are "
            + "logged in to. No API keys: your logins are used as they are."
        case .decisions: "Who answers heed's typed questions: Apple's on-device model, Hunch, a model call, or no one."
        case .worktrees: "Where worktrees go, what their branches are called, and when idle ones are swept."
        case .goals: "What goals do on their own: telling agents, reviewers, spawned items and the GitHub mirror."
        case .history: "The ledger's summaries, the Mindmap, standups, and how long the call log keeps each call."
        case .github: "How often heed asks gh."
        case .pilot: "What heed does with the PRs your sessions track: the defaults every PR starts from. Orgs and "
            + "repos override them in Orgs & repos."
        case .orgsAndRepos: "Orgs and repos can override the defaults: color, setup, goal trackers, and every Pilot "
            + "setting. A repo takes its org's values unless it sets its own."
        case .attention: "What matters in Attention: rules that boost, lower, mute, pin or notify, and its summaries."
        case .hosts: "Machines heed drives over your own ssh, or over your tailnet."
        case .tools: "The commands heed runs, and where it found them."
        case .keys: "Modes, the global shortcuts, and every binding. Bindings are edited in config.toml."
        }
    }

    /// The name `:settings.open` takes for it, and that its completion offers.
    var commandName: String {
        switch self {
        case .modelCalls: "model-calls"
        case .orgsAndRepos: "orgs"
        default: rawValue
        }
    }

    /// `:settings.open <name>`: a page's name, or a name an earlier Settings used for the section it now lives on
    /// (`colors`, `cleanup`, `inference`, ...).
    static func named(_ name: String) -> SettingsPage? {
        let key = name.lowercased()
        if let page = allCases.first(where: { $0.commandName == key || $0.rawValue.lowercased() == key }) {
            return page
        }
        return aliases[key]
    }

    /// The names of the sections Settings had before its pages, and a few short ones.
    static let aliases: [String: SettingsPage] = [
        "colors": .orgsAndRepos, "repos": .orgsAndRepos, "orgs": .orgsAndRepos, "cleanup": .worktrees,
        "modes": .keys, "rules": .attention, "ssh": .hosts, "inference": .modelCalls, "llm": .modelCalls,
        "hunch": .decisions, "notify": .notifications, "ledger": .history, "zmx": .tools, "update": .updates,
        "nudges": .notifications, "whatsnew": .notifications,
    ]
}

public extension SettingsTab {
    /// `:settings.open pilot <tab>`, `:settings.open agents <agent> <tab>`.
    static func named(_ name: String, on page: SettingsPage) -> SettingsTab? {
        let key = name.lowercased()
        switch page {
        case .pilot:
            let short: [String: SettingsTab] = [
                "green": .green, "general": .green, "merged": .merged, "merge": .merged, "reviews": .reviews,
                "review": .reviews, "reviewers": .reviews, "instructions": .instructions, "prompts": .instructions,
            ]
            return short[key]
        case .agents:
            let short: [String: SettingsTab] = [
                "sessions": .sessions, "session": .sessions, "model-calls": .modelCalls, "llm": .modelCalls,
                "calls": .modelCalls,
            ]
            return short[key]
        default:
            return nil
        }
    }

    /// The name `:settings.open` takes for it.
    var commandName: String {
        switch self {
        case .modelCalls: "model-calls"
        default: rawValue
        }
    }
}

// MARK: Dependent settings

public extension SettingsCatalog {
    /// Settings that only mean something while another one is on: shown indented under it, and hidden while it is
    /// off (unless set, so nothing set is ever out of sight). Child → parent; both on the same page and section.
    static let parents: [String: String] = [
        "notifications.asking": "notifications.enabled",
        "notifications.blocked": "notifications.enabled",
        "notifications.grace_seconds": "notifications.enabled",
        "notifications.reminder_minutes": "notifications.enabled",
        "updates.install": "updates.check",
        "llm.agent": "llm.enabled",
        "goals.attach_auto": "goals.attach",
        "goals.attach_ask": "goals.attach",
        "goals.attach_model": "goals.attach",
        "local.keep_days": "local.record_screens",
        "cleanup.idle_days": "cleanup.enabled",
        "cleanup.delete_branch": "cleanup.enabled",
        "cleanup.ask_before_sweep": "cleanup.enabled",
        "mindmap.shadow": "mindmap.enabled",
        "standup.days": "standup.enabled",
        "standup.at": "standup.enabled",
        "standup.range_days": "standup.enabled",
        "standup.questions": "standup.enabled",
        "standup.personal_questions": "standup.enabled",
    ]

    /// Whether a row shows: always, unless its parent is off and it is at its default with nothing refused.
    static func isShown(
        _ id: String, at target: SettingTarget = .global, in config: HeedConfig, problems: [ConfigProblem] = []
    ) -> Bool {
        guard let parent = parents[id].flatMap(entry), let child = entry(id) else { return true }
        if value(parent, in: config) == .bool(true) { return true }
        return isModified(child, at: target, in: config)
            || !Self.problems(for: child, at: target, in: problems).isEmpty
    }
}

// MARK: The tree

/// A line of the Settings sidebar: a group, a page, or one of the shown page's sections.
public enum SettingsNode: Hashable, Sendable, CustomStringConvertible {
    case group(SettingsGroup)
    case page(SettingsPage)
    case section(SettingsPage, String)

    /// How the fold state is kept: `group:heed`, `page:modelCalls`.
    public var description: String {
        switch self {
        case let .group(group): "group:\(group.rawValue)"
        case let .page(page): "page:\(page.rawValue)"
        case let .section(page, title): "section:\(page.rawValue):\(title)"
        }
    }

    public init?(_ text: String) {
        let parts = text.split(separator: ":", maxSplits: 2).map(String.init)
        switch (parts.first, parts.count) {
        case ("group", 2): guard let group = SettingsGroup(rawValue: parts[1]) else { return nil }
            self = .group(group)
        case ("page", 2): guard let page = SettingsPage(rawValue: parts[1]) else { return nil }
            self = .page(page)
        case ("section", 3): guard let page = SettingsPage(rawValue: parts[1]) else { return nil }
            self = .section(page, parts[2])
        default: return nil
        }
    }

    /// The page it opens.
    public var page: SettingsPage? {
        switch self {
        case .group: nil
        case let .page(page), let .section(page, _): page
        }
    }
}

/// The sidebar: groups that fold, their pages, and under the page shown its sections (when it has two or more). The
/// arrow keys move a cursor over the lines shown; ← folds or goes up a level, → unfolds or goes down one.
public struct SettingsTree: Equatable, Sendable {
    /// The page shown.
    public var page: SettingsPage
    /// Groups folded, and pages whose sections are folded away.
    public var folded: Set<SettingsNode>
    /// Only modified's lines (`SettingsCounts.changedNodes`): the tree shows only these; nil shows every line.
    public var kept: Set<SettingsNode>?

    public init(page: SettingsPage = .general, folded: Set<SettingsNode> = [], kept: Set<SettingsNode>? = nil) {
        self.page = page
        self.folded = folded
        self.kept = kept
    }

    /// The lines under a node, folded or not.
    public func children(of node: SettingsNode) -> [SettingsNode] {
        let lines: [SettingsNode] = switch node {
        case let .group(group): group.pages.map(SettingsNode.page)
        case let .page(page):
            page == self.page && page.sections.count > 1 ? page.sections.map { .section(page, $0) } : []
        case .section: []
        }
        return lines.filter(isKept)
    }

    private func isKept(_ node: SettingsNode) -> Bool { kept?.contains(node) ?? true }

    /// The page shown when Only modified keeps lines: `page` while it holds a change, else the first page that does
    /// (nil when nothing is changed anywhere).
    public var keptPage: SettingsPage? {
        guard let kept else { return page }
        if kept.contains(.page(page)) { return page }
        return SettingsPage.allCases.first { kept.contains(.page($0)) }
    }

    public func isOpen(_ node: SettingsNode) -> Bool { !folded.contains(node) && !children(of: node).isEmpty }

    /// Every line shown, top to bottom.
    public var visible: [SettingsNode] {
        func lines(_ node: SettingsNode) -> [SettingsNode] {
            [node] + (folded.contains(node) ? [] : children(of: node).flatMap(lines))
        }
        return SettingsGroup.allCases.map(SettingsNode.group).filter(isKept).flatMap(lines)
    }

    /// The line `by` lines from `node` (↑ ↓), kept inside the tree. A page reached is shown.
    public mutating func move(_ node: SettingsNode, by offset: Int) -> SettingsNode {
        let lines = visible
        guard let index = lines.firstIndex(of: node) else { return lines.first ?? node }
        let next = lines[min(max(index + offset, 0), lines.count - 1)]
        show(next)
        return next
    }

    /// ←: folds an open group or page; else goes to the line above it in the tree.
    public mutating func left(_ node: SettingsNode) -> SettingsNode {
        if isOpen(node) {
            folded.insert(node)
            return node
        }
        switch node {
        case .group: return node
        case let .page(page): return .group(page.group)
        case let .section(page, _): return .page(page)
        }
    }

    /// →: unfolds a folded group or page; else goes to its first line.
    public mutating func right(_ node: SettingsNode) -> SettingsNode {
        if folded.contains(node) {
            folded.remove(node)
            return node
        }
        guard let first = children(of: node).first else { return node }
        show(first)
        return first
    }

    /// A click on a group's or page's fold mark.
    public mutating func toggle(_ node: SettingsNode) {
        if folded.contains(node) { folded.remove(node) } else { folded.insert(node) }
    }

    /// Shows the page a line is on, unfolding its group.
    public mutating func show(_ node: SettingsNode) {
        guard let page = node.page else { return }
        self.page = page
        folded.remove(.group(page.group))
    }
}

// MARK: Agents

/// What the Agents list says of an agent: ✓ ready (installed, logged in, its hooks), ○ not installed (a built-in
/// agent whose command is not there), ! broken and why (logged out, its own command not found, the last test failed),
/// or not checked (a custom agent heed has no check for, or detection still running).
public enum AgentReadiness: Equatable, Sendable {
    case ready
    case notInstalled
    case broken(String)
    case unchecked

    /// From what detection found and how the last test ended (`lastTestFailed`).
    public static func of(_ agent: AgentProfile, status: LLMAgentStatus?, lastTestFailed: Bool = false)
        -> AgentReadiness
    {
        guard let status else { return .unchecked }
        switch status.login {
        case .notInstalled:
            let builtIn = AgentProfile.builtIn.first { $0.name == agent.name }
            return builtIn?.command == agent.command ? .notInstalled : .broken("command not found")
        case .loggedOut: return .broken("logged out")
        case .loggedIn, .unknown: return lastTestFailed ? .broken("last test failed") : .ready
        }
    }

    public var glyph: String {
        switch self {
        case .ready: "✓"
        case .notInstalled: "○"
        case .broken: "!"
        case .unchecked: "·"
        }
    }

    /// What the list says beside the name; nil when ready.
    public var note: String? {
        switch self {
        case .ready: nil
        case .notInstalled: "not installed"
        case let .broken(reason): reason
        case .unchecked: "not checked"
        }
    }

    /// How an agent reports its state: hooks passed per run where it takes them, else what its screen shows.
    public static func hooks(_ name: String) -> String {
        switch name {
        case "claude": "full hooks"
        case "codex": "hooks"
        case "cursor": "project hooks"
        case "pi": "extension"
        case "opencode": "plugin"
        default: "reads the screen"
        }
    }

    /// The detail's status line: `installed · logged in · full hooks · 2 modified`.
    public static func statusLine(
        _ agent: AgentProfile, status: LLMAgentStatus?, readiness: AgentReadiness, modified: Int
    ) -> String {
        var parts: [String] = []
        switch status?.login {
        case .loggedIn: parts += ["installed", "logged in"]
        case .loggedOut: parts += ["installed", "logged out"]
        case .unknown: parts += ["installed", "no login check"]
        case .notInstalled: parts.append(readiness == .notInstalled ? "not installed" : "command not found")
        case nil: parts.append(LLMDialect.of(agent) == nil ? "custom agent" : "checking…")
        }
        if case .broken("last test failed") = readiness { parts.append("last test failed") }
        parts.append(hooks(agent.name))
        if modified > 0 { parts.append("\(modified) modified") }
        return parts.joined(separator: " · ")
    }
}
