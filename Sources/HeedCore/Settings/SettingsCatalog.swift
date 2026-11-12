import Foundation

/// Every setting Settings shows or config.toml takes, as data: where it lives (tree group › page › section, and a tab
/// on pages that have them), what it is called and says, its key in config.toml (or the key under a scope's table:
/// `[agents.<name>]`, `[orgs.<org>]`, `[repos."o/r"]`, `[hosts.<name>]`), whether it is basic or advanced, how much it
/// matters to someone setting heed up, the version it shipped in and its default. Modified, problems, counts, search
/// and the setup wizard all read this one list, so a new setting cannot skip any of them.
public enum SettingsCatalog {
    /// Every entry, in page order.
    public static let entries: [SettingsEntry] = globalEntries + agentEntries + overrideEntries + hostEntries

    public static func entry(_ id: String) -> SettingsEntry? { byID[id] }

    private static let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })

    /// The entries on a page, in order.
    public static func entries(on page: SettingsPage) -> [SettingsEntry] { entries.filter { $0.page == page } }

    /// The sections of a page, in the order its entries first name them.
    public static func sections(of page: SettingsPage) -> [String] {
        entries(on: page).map(\.section).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    // MARK: Values

    /// The value that applies at `target`; nil when the setting is unset there (an optional key, or an org or repo
    /// that does not override it).
    public static func value(_ entry: SettingsEntry, at target: SettingTarget = .global, in config: HeedConfig)
        -> SettingValue?
    {
        entry.read(config, target)
    }

    /// heed's own default at `target`: what the value is with nothing in config.toml for it. An org or repo
    /// override's default is nil (it inherits); a custom agent's is a fresh agent with the same command.
    public static func defaultValue(
        _ entry: SettingsEntry, at target: SettingTarget = .global, in config: HeedConfig = .default
    ) -> SettingValue? {
        entry.read(baseline(for: target, in: config), target)
    }

    /// Whether the value at `target` differs from heed's default. A key written out with its default (the shipped
    /// config.toml lists most of them) is not modified.
    public static func isModified(
        _ entry: SettingsEntry, at target: SettingTarget = .global, in config: HeedConfig
    ) -> Bool {
        value(entry, at: target, in: config) != defaultValue(entry, at: target, in: config)
    }

    /// The config with nothing set at `target`, but the target itself there: a custom agent keeps its command (it
    /// cannot be without one), a host its name.
    static func baseline(for target: SettingTarget, in config: HeedConfig) -> HeedConfig {
        var base = HeedConfig.default
        switch target {
        case let .agent(name):
            if base.work.agent(name) == nil {
                let command = config.work.agent(name)?.command ?? name
                base.work.agents.append(AgentProfile(name: name, command: command))
            }
        case let .host(name):
            base.hosts[name] = HostConfig(name: name)
        case .global, .org, .repo:
            break
        }
        return base
    }

    // MARK: Targets

    /// Where an entry applies in this config: `.global` for a global setting; each agent, org, repo or host for a
    /// scoped one (those configured, and any a problem names, so a refused value has a row to show on).
    public static func targets(
        for entry: SettingsEntry, in config: HeedConfig, problems: [ConfigProblem] = []
    ) -> [SettingTarget] {
        var found: [SettingTarget] = []
        switch entry.scope {
        case .global: return [.global]
        case .agent: found = config.work.agents.map { .agent($0.name) }
        case .host: found = config.hosts.keys.sorted().map(SettingTarget.host)
        case .org, .repo, .orgAndRepo:
            for scope in Overrides.configuredScopes(in: config) {
                switch scope {
                case let .org(name): found.append(.org(name))
                case let .repo(repo): found.append(.repo(repo.slug))
                }
            }
            for org in config.orgColors.keys.sorted() where !found.contains(.org(org)) {
                found.append(.org(org))
            }
            for slug in config.repos.keys.sorted() where !found.contains(.repo(slug)) {
                found.append(.repo(slug))
            }
        }
        for problem in problems {
            if let target = entry.target(of: problem.path), !found.contains(target) { found.append(target) }
        }
        return found.filter { entry.scope.applies(to: $0) }
    }

    // MARK: Problems

    /// The problems config.toml has, each on the entry (and target) it is about; the rest (a syntax error, a key
    /// heed no longer reads, a table that should be one) have no row and stay for the banner.
    public static func problems(_ problems: [ConfigProblem])
        -> (matched: [SettingProblem], unmatched: [ConfigProblem])
    {
        var matched: [SettingProblem] = []
        var unmatched: [ConfigProblem] = []
        for problem in problems {
            if let (entry, target) = owner(of: problem.path) {
                matched.append(SettingProblem(
                    entryID: entry.id, target: target, path: problem.path, reason: problem.message,
                    example: entry.example
                ))
            } else {
                unmatched.append(problem)
            }
        }
        return (matched, unmatched)
    }

    /// The problems that belong to one entry (at any target, or at `target`).
    public static func problems(
        for entry: SettingsEntry, at target: SettingTarget? = nil, in problems: [ConfigProblem]
    ) -> [SettingProblem] {
        Self.problems(problems).matched.filter { $0.entryID == entry.id && (target == nil || $0.target == target) }
    }

    /// The entry a problem's path is about: an exact key before a table that holds it.
    static func owner(of path: String) -> (SettingsEntry, SettingTarget)? {
        var table: (SettingsEntry, SettingTarget)?
        for entry in entries {
            guard let target = entry.target(of: path) else { continue }
            if !entry.isTable || entry.matchesExactly(path) { return (entry, target) }
            if table == nil { table = (entry, target) }
        }
        return table
    }

    /// Checks a value before it is written: `value` set at the entry's key in `source` (the current config.toml,
    /// so a value that depends on another key is judged against it), read as heed reads config.toml. nil: heed
    /// takes it. A custom agent gets a command first, which it cannot be read without.
    public static func validate(
        _ entry: SettingsEntry, _ value: TOMLValue, at target: SettingTarget = .global, in source: String = ""
    ) -> SettingProblem? {
        guard entry.scope.applies(to: target), let path = entry.path(at: target) else { return nil }
        var text = source
        func set(_ path: [String], _ value: TOMLValue) {
            guard let document = try? TOMLDocument(text) else { return }
            text = document.setting(path, to: value)
        }
        if case let .agent(name) = target, entry.key != ["command"],
           !AgentProfile.builtIn.contains(where: { $0.name == name }),
           (try? TOMLDocument(text))?.root.value(at: ["agents", name, "command"]) == nil
        {
            set(["agents", name, "command"], .string(name))
        }
        set(path, value)
        let (config, found) = ConfigLoader.decode(text)
        if config == nil, let syntax = found.first {
            return SettingProblem(
                entryID: entry.id, target: target, path: syntax.path, reason: syntax.message, example: entry.example
            )
        }
        return problems(found).matched.first { $0.entryID == entry.id && $0.target == target }
    }

    // MARK: States and counts

    /// Every entry at every target it applies to, modified or not, with its problems.
    public static func states(in config: HeedConfig, problems: [ConfigProblem] = []) -> [SettingState] {
        let matched = Self.problems(problems).matched
        var byRow: [String: [SettingProblem]] = [:]
        for problem in matched {
            byRow[problem.entryID + "\u{0}" + problem.target.description, default: []].append(problem)
        }
        return entries.flatMap { entry in
            targets(for: entry, in: config, problems: problems).map { target in
                SettingState(
                    entry: entry, target: target, isModified: isModified(entry, at: target, in: config),
                    problems: byRow[entry.id + "\u{0}" + target.description] ?? []
                )
            }
        }
    }

    /// Modified and problem counts by tree group, page, section, scope target and tab.
    public static func counts(in config: HeedConfig, problems: [ConfigProblem] = []) -> SettingsCounts {
        SettingsCounts(states(in: config, problems: problems))
    }

    // MARK: Search

    /// Entries matching `query`: every word of it in the entry's own text (label, detail, config key:
    /// `grace_seconds`, `llm.timeout_seconds`, `[orgs.<org>] watch`), ignoring case. Where they live (page, tree
    /// group, section, tab) counts only when no entry's own text matches, or when the query names that place
    /// outright: "model" finds what says model, not every entry on Model calls; "pilot" and "model calls" list
    /// their page. Label matches first, then key matches, then the rest, each in page order. An empty query matches
    /// nothing.
    public static func search(_ query: String, in entries: [SettingsEntry] = entries) -> [SettingsEntry] {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return [] }
        let own = entries.filter { entry in
            let text = entry.ownText
            return words.allSatisfy { text.contains($0) }
        }
        let found: [SettingsEntry]
        if own.isEmpty {
            found = entries.filter { entry in
                let text = entry.searchText
                return words.allSatisfy { text.contains($0) }
            }
        } else {
            let name = words.joined(separator: " ")
            found = entries.filter { entry in
                own.contains { $0.id == entry.id } || entry.placeNames.contains(name)
            }
        }
        func rank(_ entry: SettingsEntry) -> Int {
            let label = entry.label.lowercased()
            if words.allSatisfy(label.contains) { return 0 }
            let keys = entry.keyTexts.joined(separator: " ").lowercased()
            if words.allSatisfy(keys.contains) { return 1 }
            return 2
        }
        return found.enumerated().sorted { lhs, rhs in
            let (left, right) = (rank(lhs.element), rank(rhs.element))
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
    }

    // MARK: Gaps

    /// What the setup wizard offers: entries that matter (an impact), still at their default and not decided on,
    /// the most important first.
    public static func gaps(in config: HeedConfig, chosen: ChosenSettings) -> [SettingsEntry] {
        entries.filter { entry in
            entry.impact != .none && entry.scope == .global && !chosen.contains(entry.id)
                && !isModified(entry, in: config)
        }
        .enumerated()
        .sorted {
            $0.element.impact == $1.element.impact ? $0.offset < $1.offset : $0.element.impact > $1.element.impact
        }
        .map(\.element)
    }
}

/// One setting.
public struct SettingsEntry: Identifiable, Sendable {
    /// Stable: the global key (`notifications.grace_seconds`), or the scope and key (`agent.command`,
    /// `override.watch`, `host.ssh`).
    public let id: String
    public let page: SettingsPage
    /// The section (card) on the page.
    public let section: String
    /// The tab, on pages that split into tabs (Agents, Pilot, Orgs & repos).
    public let tab: SettingsTab?
    public let label: String
    public let detail: String
    public let scope: SettingScope
    /// The key: the whole path for a global setting, the path under the scope's table for a scoped one.
    public let key: [String]
    /// A table whose keys are yours to name (`[worktrees.prefixes]`, `[usage.prices]`): its whole content is the value.
    public let isTable: Bool
    public let level: SettingLevel
    public let impact: SettingImpact
    /// The heed version it shipped in ("0.0": older than heed's history says).
    public let since: String
    /// A line of config.toml it takes, shown with a refused value.
    public let example: String
    let read: @Sendable (HeedConfig, SettingTarget) -> SettingValue?

    /// The key as the docs and search write it: `notifications.grace_seconds`, `[orgs.<org>] watch` and
    /// `[repos."o/r"] watch`, `[usage.prices]`.
    public var keyTexts: [String] {
        let leaf = key.joined(separator: ".")
        switch scope {
        case .global: return [isTable ? "[\(leaf)]" : leaf]
        default: return scope.tables.map { "[\($0)] \(leaf)" }
        }
    }

    /// The default at its representative target (global, claude for an agent, a new host); nil: unset or inherited.
    public var defaultValue: SettingValue? {
        let target: SettingTarget = switch scope {
        case .global: .global
        case .agent: .agent("claude")
        case .host: .host("host")
        case .org, .orgAndRepo: .org("org")
        case .repo: .repo("org/repo")
        }
        return SettingsCatalog.defaultValue(self, at: target)
    }

    /// The path in config.toml at `target`; nil when the entry does not apply there.
    public func path(at target: SettingTarget) -> [String]? {
        guard scope.applies(to: target) else { return nil }
        return target.table + key
    }

    /// The target a problem's dotted path names, when the path is this entry's key (or inside its table).
    func target(of path: String) -> SettingTarget? {
        let leaf = key.joined(separator: ".")
        func inside(_ rest: Substring) -> Bool {
            rest == leaf || (isTable && rest.hasPrefix(leaf + "."))
        }
        switch scope {
        case .global:
            return inside(Substring(path)) ? .global : nil
        default:
            for table in scope.prefixes {
                guard path.hasPrefix(table + ".") else { continue }
                let rest = path.dropFirst(table.count + 1)
                // The name may hold dots (a repo "org/site.io"): the key is found from the end.
                for index in rest.indices where rest[index] == "." && index > rest.startIndex {
                    let name = String(rest[..<index])
                    if inside(rest[rest.index(after: index)...]) {
                        let target = SettingTarget.scoped(table, name)
                        if scope.applies(to: target) { return target }
                    }
                }
            }
            return nil
        }
    }

    func matchesExactly(_ path: String) -> Bool {
        path == key.joined(separator: ".") || path.hasSuffix("." + key.joined(separator: "."))
    }

    var searchText: String {
        ([ownText] + placeNames).joined(separator: "\n")
    }

    /// What the entry itself says: its label, detail and key, lowercased.
    var ownText: String {
        ([label, detail, key.joined(separator: ".")] + keyTexts).joined(separator: "\n").lowercased()
    }

    /// Where it lives, lowercased: its page, tree group, section and tab.
    var placeNames: [String] {
        [page.title, page.group.title, section, tab?.title].compactMap(\.self).map { $0.lowercased() }
    }
}

/// The tree's groups (Heed, Agents, Work, GitHub, Machine), in order.
public enum SettingsGroup: String, CaseIterable, Sendable, Identifiable {
    case heed, agents, work, github, machine

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .heed: "Heed"
        case .agents: "Agents"
        case .work: "Work"
        case .github: "GitHub"
        case .machine: "Machine"
        }
    }

    public var pages: [SettingsPage] { SettingsPage.allCases.filter { $0.group == self } }
}

/// The pages, in tree order.
public enum SettingsPage: String, CaseIterable, Sendable, Identifiable {
    case general, notifications, updates
    case agents, modelCalls, decisions
    case worktrees, goals, history
    case github, pilot, orgsAndRepos, attention
    case hosts, tools, keys

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .notifications: "Notifications"
        case .updates: "Updates"
        case .agents: "Agents"
        case .modelCalls: "Model calls"
        case .decisions: "Decisions & Hunch"
        case .worktrees: "Worktrees"
        case .goals: "Goals"
        case .history: "History"
        case .github: "GitHub"
        case .pilot: "Pilot"
        case .orgsAndRepos: "Orgs & repos"
        case .attention: "Attention"
        case .hosts: "Hosts"
        case .tools: "Tools"
        case .keys: "Keys & modes"
        }
    }

    public var group: SettingsGroup {
        switch self {
        case .general, .notifications, .updates: .heed
        case .agents, .modelCalls, .decisions: .agents
        case .worktrees, .goals, .history: .work
        case .github, .pilot, .orgsAndRepos, .attention: .github
        case .hosts, .tools, .keys: .machine
        }
    }
}

/// The tabs pages split into: an agent's Sessions and Model calls; the Pilot's and Orgs & repos' (`OverrideTab`).
public enum SettingsTab: String, CaseIterable, Sendable {
    case sessions, modelCalls
    case general, green, merged, reviews, instructions

    public init(_ tab: OverrideTab) {
        self = switch tab {
        case .general: .general
        case .green: .green
        case .merged: .merged
        case .reviews: .reviews
        case .instructions: .instructions
        }
    }

    /// Orgs & repos' tab of the same name; nil for an agent's.
    public var overrideTab: OverrideTab? {
        switch self {
        case .general: .general
        case .green: .green
        case .merged: .merged
        case .reviews: .reviews
        case .instructions: .instructions
        case .sessions, .modelCalls: nil
        }
    }

    public var title: String {
        switch self {
        case .sessions: "Sessions"
        case .modelCalls: "Model calls"
        case .general: OverrideTab.general.title
        case .green: OverrideTab.green.title
        case .merged: OverrideTab.merged.title
        case .reviews: OverrideTab.reviews.title
        case .instructions: OverrideTab.instructions.title
        }
    }
}

/// Basic settings show by default; advanced ones (tuning: timeouts, limits, retention, tool paths, command lines)
/// only with Show advanced on, or when they are set.
public enum SettingLevel: String, Sendable {
    case basic, advanced
}

/// How much a setting matters to someone setting heed up: the wizard asks about those with one, high first.
public enum SettingImpact: Int, Comparable, Sendable {
    case none, low, medium, high

    public static func < (lhs: SettingImpact, rhs: SettingImpact) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Where a setting is set: once for heed, or per agent, org, repo or host.
public enum SettingScope: Hashable, Sendable {
    case global
    /// `[agents.<name>]`.
    case agent
    /// `[orgs.<org>]` only.
    case org
    /// `[repos."o/r"]` only.
    case repo
    /// `[orgs.<org>]` and `[repos."o/r"]`: the repo's wins, then the org's, then the default.
    case orgAndRepo
    /// `[hosts.<name>]`.
    case host

    /// The tables, as the docs write them.
    public var tables: [String] {
        switch self {
        case .global: []
        case .agent: ["agents.<name>"]
        case .org: ["orgs.<org>"]
        case .repo: ["repos.\"o/r\""]
        case .orgAndRepo: ["orgs.<org>", "repos.\"o/r\""]
        case .host: ["hosts.<name>"]
        }
    }

    /// The first key of its tables.
    var prefixes: [String] {
        switch self {
        case .global: []
        case .agent: ["agents"]
        case .org: ["orgs"]
        case .repo: ["repos"]
        case .orgAndRepo: ["orgs", "repos"]
        case .host: ["hosts"]
        }
    }

    public func applies(to target: SettingTarget) -> Bool {
        switch (self, target) {
        case (.global, .global), (.agent, .agent), (.host, .host), (.org, .org), (.repo, .repo),
             (.orgAndRepo, .org), (.orgAndRepo, .repo): true
        default: false
        }
    }
}

/// Where one value is: heed-wide, or one agent, org, repo (`org/name`) or host.
public enum SettingTarget: Hashable, Sendable, CustomStringConvertible {
    case global
    case agent(String)
    case org(String)
    case repo(String)
    case host(String)

    /// Its table in config.toml.
    public var table: [String] {
        switch self {
        case .global: []
        case let .agent(name): ["agents", name]
        case let .org(name): ["orgs", name]
        case let .repo(slug): ["repos", slug]
        case let .host(name): ["hosts", name]
        }
    }

    /// The org or repo as Orgs & repos has it.
    public var overrideScope: OverrideScope? {
        switch self {
        case let .org(name): return .org(name)
        case let .repo(slug):
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            return .repo(Repo(org: parts.first ?? slug, name: parts.count == 2 ? parts[1] : ""))
        default: return nil
        }
    }

    public var description: String {
        switch self {
        case .global: "global"
        case let .agent(name): "agent:\(name)"
        case let .org(name): "org:\(name)"
        case let .repo(slug): "repo:\(slug)"
        case let .host(name): "host:\(name)"
        }
    }

    static func scoped(_ table: String, _ name: String) -> SettingTarget {
        switch table {
        case "agents": .agent(name)
        case "orgs": .org(name)
        case "repos": .repo(name)
        default: .host(name)
        }
    }
}

/// A setting's value as heed reads it, comparable with its default.
public enum SettingValue: Hashable, Sendable, CustomStringConvertible {
    case bool(Bool)
    case integer(Int)
    case number(Double)
    case text(String)
    case list([String])
    /// A table of your own keys (prefixes, prices, bars): key → its value as text.
    case table([String: String])

    public init(_ value: OverrideValue) {
        self = switch value {
        case let .bool(flag): .bool(flag)
        case let .text(text): .text(text)
        case let .integer(number): .integer(number)
        case let .list(items): .list(items)
        }
    }

    /// The value as config.toml writes it.
    public var toml: TOMLValue {
        switch self {
        case let .bool(flag): .bool(flag)
        case let .integer(number): .integer(number)
        case let .number(number): .float(number)
        case let .text(text): .string(text)
        case let .list(items): .array(items.map { .string($0) })
        case let .table(pairs):
            .table(pairs.keys.sorted().reduce(into: TOMLTable()) { $0[$1] = .string(pairs[$1] ?? "") })
        }
    }

    public var description: String {
        switch self {
        case let .bool(flag): flag ? "on" : "off"
        case let .integer(number): "\(number)"
        case let .number(number): number == number.rounded() ? String(Int(number)) : "\(number)"
        case let .text(text): text.isEmpty ? "none" : text
        case let .list(items): items.isEmpty ? "none" : items.joined(separator: ", ")
        case let .table(pairs): pairs.isEmpty ? "none" : pairs.keys.sorted().map { "\($0) = \(pairs[$0] ?? "")" }
            .joined(separator: "; ")
        }
    }
}

/// A value config.toml has that heed refused, on the setting it is for.
public struct SettingProblem: Hashable, Sendable {
    public let entryID: String
    public let target: SettingTarget
    /// The key, as the problem names it (`notifications.grace_seconds`, `orgs.acme.green`).
    public let path: String
    /// Why heed refused it ("expected a number from 0 to 3600").
    public let reason: String
    /// A line it would take.
    public let example: String
}

/// One entry at one target.
public struct SettingState: Sendable {
    public let entry: SettingsEntry
    public let target: SettingTarget
    public let isModified: Bool
    public let problems: [SettingProblem]
}

/// What the `● N` and `!` marks count.
public enum SettingsCountKey: Hashable, Sendable {
    case group(SettingsGroup)
    case page(SettingsPage)
    case section(SettingsPage, String)
    /// One agent, org, repo or host on its page; `.global` holds the page's own settings.
    case target(SettingsPage, SettingTarget)
    /// A tab of one target on its page.
    case tab(SettingsPage, SettingTarget, SettingsTab)
}

/// Modified and problem counts rolled up from rows: row → tab → target → page → tree group, and by section.
public struct SettingsCounts: Sendable {
    private var modifiedCounts: [SettingsCountKey: Int] = [:]
    private var problemCounts: [SettingsCountKey: Int] = [:]

    public init(_ states: [SettingState]) {
        for state in states {
            let page = state.entry.page
            var keys: [SettingsCountKey] = [
                .group(page.group), .page(page), .section(page, state.entry.section), .target(page, state.target),
            ]
            if let tab = state.entry.tab { keys.append(.tab(page, state.target, tab)) }
            for key in keys {
                if state.isModified { modifiedCounts[key, default: 0] += 1 }
                if !state.problems.isEmpty { problemCounts[key, default: 0] += 1 }
            }
        }
    }

    /// Rows that differ from heed's default.
    public func modified(_ key: SettingsCountKey) -> Int { modifiedCounts[key] ?? 0 }

    /// Rows with a value heed refused.
    public func problems(_ key: SettingsCountKey) -> Int { problemCounts[key] ?? 0 }
}
