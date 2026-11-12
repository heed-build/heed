import Foundation

// Settings' two switches at the foot of the tree. Show advanced off hides the catalog's advanced settings, except
// those set or refused: nothing set or broken is ever out of sight. Only modified keeps what differs from heed's
// default (or that config.toml has and heed refused): the tree its pages, each page those rows, each two-pane list
// the agents, orgs and repos that have one, each tab strip the tabs that hold one.

/// The two switches, as Settings keeps them.
public struct SettingsFilter: Equatable, Sendable {
    public var showAdvanced: Bool
    public var onlyModified: Bool

    public init(showAdvanced: Bool = false, onlyModified: Bool = false) {
        self.showAdvanced = showAdvanced
        self.onlyModified = onlyModified
    }

    /// The tabs a strip shows, and the one shown: all of them and `current`, or under Only modified those that hold a
    /// change, `current` if it is one, else the first (`current` when none does).
    public func tabs<Tab: Equatable>(
        _ tabs: [Tab],
        current: Tab,
        changed: (Tab) -> Bool
    ) -> (shown: [Tab], current: Tab) {
        guard onlyModified else { return (tabs, current) }
        let kept = tabs.filter(changed)
        return (kept, kept.contains(current) ? current : kept.first ?? current)
    }
}

/// Whether a row of Settings draws.
public enum SettingVisibility: Equatable, Sendable {
    case shown
    /// Advanced, at its default, with Show advanced off: its card counts it ("2 advanced hidden · Show").
    case hiddenAdvanced
    /// Not drawn and not counted: its parent is off, or Only modified is on and it is at its default.
    case hidden
}

public extension SettingsCatalog {
    /// Whether the value at `target` differs from heed's default, or config.toml has one there heed refused.
    static func isChanged(
        _ entry: SettingsEntry, at target: SettingTarget = .global, in config: HeedConfig,
        problems: [ConfigProblem] = []
    ) -> Bool {
        isModified(entry, at: target, in: config) || !Self.problems(for: entry, at: target, in: problems).isEmpty
    }

    /// Whether a row (one setting, or a few shown as one) draws. A changed row always does; under Only modified only
    /// those do. Else a dependent row hides while its parent is off, and with Show advanced off a row whose settings
    /// are all advanced hides, counted.
    static func visibility(
        _ ids: [String], at target: SettingTarget = .global, in config: HeedConfig, problems: [ConfigProblem] = [],
        filter: SettingsFilter
    ) -> SettingVisibility {
        let entries = ids.compactMap(entry)
        if entries.contains(where: { isChanged($0, at: target, in: config, problems: problems) }) { return .shown }
        if filter.onlyModified { return .hidden }
        if let first = ids.first, !isShown(first, at: target, in: config, problems: problems) { return .hidden }
        if !filter.showAdvanced, !entries.isEmpty, entries.allSatisfy({ $0.level == .advanced }) {
            return .hiddenAdvanced
        }
        return .shown
    }

    /// The rows of a page that differ from heed's default or that heed refused, at every target: what Only modified
    /// lists and Reset all removes.
    static func changes(
        on page: SettingsPage, in config: HeedConfig, problems: [ConfigProblem] = []
    ) -> [SettingState] {
        states(in: config, problems: problems)
            .filter { $0.entry.page == page && ($0.isModified || !$0.problems.isEmpty) }
    }

    /// The keys Reset all removes from config.toml for those rows, each once, in page order: what each row's ↺ removes.
    static func resetPaths(_ changes: [SettingState]) -> [[String]] {
        changes.compactMap { $0.entry.path(at: $0.target) }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    /// A key path as config.toml writes it: `notifications.grace_seconds`, `repos."acme/docs".watch`.
    static func keyText(_ path: [String]) -> String { path.map(TOMLValue.key).joined(separator: ".") }
}

public extension SettingsCounts {
    /// Whether anything under `key` differs from heed's default or was refused.
    func isChanged(_ key: SettingsCountKey) -> Bool { modified(key) > 0 || problems(key) > 0 }

    /// The lines of the tree Only modified keeps: the groups, pages and sections holding a change.
    var changedNodes: Set<SettingsNode> {
        var nodes: Set<SettingsNode> = []
        for group in SettingsGroup.allCases where isChanged(.group(group)) {
            nodes.insert(.group(group))
            for page in group.pages where isChanged(.page(page)) {
                nodes.insert(.page(page))
                for section in page.sections where isChanged(.section(page, section)) {
                    nodes.insert(.section(page, section))
                }
            }
        }
        return nodes
    }
}
