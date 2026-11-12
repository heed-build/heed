import Foundation

// Settings' search (⌘F, `:settings.find`): every word of the query in a setting's label, detail, page, tree group,
// section, tab or config key, across every page and every agent, org, repo and host. The pane lists what matched as
// the real rows, page by page (the page with the best match first), each at the target it is shown at; the tree keeps
// the pages and groups with matches. Advanced settings are found whatever Show advanced says; Only modified keeps the
// matches that differ from heed's default or that heed refused.

/// One row search found: a setting at the target the pane shows it at. A scoped setting with nowhere to be shown yet (a
/// host setting with no host) has no target.
public struct SettingMatch: Hashable, Sendable {
    public let entry: SettingsEntry
    public let target: SettingTarget?

    public static func == (lhs: SettingMatch, rhs: SettingMatch) -> Bool {
        lhs.entry.id == rhs.entry.id && lhs.target == rhs.target
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(entry.id)
        hasher.combine(target)
    }
}

/// What a query found, in the order the pane lists it.
public struct SettingsSearch: Sendable {
    public let query: String
    /// The query's words, lowercased.
    public let words: [String]
    /// Page by page (`pages`), each page's in catalog order, a scoped setting once per target.
    public let matches: [SettingMatch]

    public var isEmpty: Bool { matches.isEmpty }

    /// The pages with matches, the one with the best match (a label match before a key match before the rest) first,
    /// ties in tree order.
    public var pages: [SettingsPage] {
        matches.map(\.entry.page).reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
    }

    public func matches(on page: SettingsPage) -> [SettingMatch] { matches.filter { $0.entry.page == page } }

    /// Matches on a page, or in a tree group.
    public func count(_ page: SettingsPage) -> Int { matches.count { $0.entry.page == page } }

    public func count(_ group: SettingsGroup) -> Int { matches.count { $0.entry.page.group == group } }

    /// The tree's lines while searching: the groups and pages holding a match (no sections).
    public var nodes: Set<SettingsNode> {
        Set(matches.flatMap { [SettingsNode.group($0.entry.page.group), .page($0.entry.page)] })
    }

    /// Whether a row (one setting, or a few shown as one) at `target` is one of the matches.
    public func contains(_ ids: [String], at target: SettingTarget) -> Bool {
        matches.contains { $0.target == target && ids.contains($0.entry.id) }
    }

    /// Whether a section of a page holds a match: what a section that draws no rows of its own (a list, an editor)
    /// shows by.
    public func contains(page: SettingsPage, section: String) -> Bool {
        matches.contains { $0.entry.page == page && $0.entry.section == section }
    }

    /// Whether a word of the query is in the setting's key, so the row says the key it matched on.
    public func matchesKey(_ entry: SettingsEntry) -> Bool {
        let keys = entry.keyTexts.joined(separator: " ").lowercased()
        return words.contains { keys.contains($0) }
    }

    /// Where the query's words are in `text`, ignoring case, for highlighting: in order, overlaps merged.
    public func ranges(in text: String) -> [Range<String.Index>] {
        var found: [Range<String.Index>] = []
        for word in words where !word.isEmpty {
            var start = text.startIndex
            while let range = text.range(of: word, options: .caseInsensitive, range: start ..< text.endIndex) {
                found.append(range)
                start = range.upperBound
            }
        }
        return found.sorted { $0.lowerBound < $1.lowerBound }.reduce(into: []) { merged, range in
            if let last = merged.last, range.lowerBound <= last.upperBound {
                merged[merged.count - 1] = last.lowerBound ..< max(last.upperBound, range.upperBound)
            } else {
                merged.append(range)
            }
        }
    }
}

public extension SettingsSearch {
    /// These global settings' rows alone, as search draws them, with nothing highlighted: a few real rows shown
    /// outside Settings (what's new, the gap nudge). Scoped settings have no one target to show at and are left out.
    static func only(_ entries: [SettingsEntry]) -> SettingsSearch {
        let matches = entries.filter { $0.scope == .global }.map { SettingMatch(entry: $0, target: .global) }
        return SettingsSearch(query: "", words: [], matches: matches)
    }
}

public extension SettingsCatalog {
    /// Searches every setting (advanced ones too) for `query`. A global setting is listed once; a scoped one at each
    /// agent, org, repo or host where it differs from heed's default or was refused, else once at the one its page
    /// opens on: the default agent, the first org or repo (config.toml's, then `known`: the ones the repo list has),
    /// the first host. Under Only modified only the changed ones are listed.
    static func search(
        _ query: String, in config: HeedConfig, problems: [ConfigProblem] = [], onlyModified: Bool = false,
        known: [SettingTarget] = []
    ) -> SettingsSearch {
        let words = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let ranked = search(query)
        let pages = ranked.map(\.page).reduce(into: [SettingsPage]()) { if !$0.contains($1) { $0.append($1) } }
        let found = Set(ranked.map(\.id))
        var matches: [SettingMatch] = []
        for page in pages {
            for entry in entries(on: page) where found.contains(entry.id) {
                let changed = { (target: SettingTarget) in
                    isChanged(entry, at: target, in: config, problems: problems)
                }
                if entry.scope == .global {
                    if !onlyModified || changed(.global) { matches.append(SettingMatch(entry: entry, target: .global)) }
                    continue
                }
                let all = targets(for: entry, in: config, problems: problems)
                let set = all.filter(changed)
                if onlyModified || !set.isEmpty {
                    matches += set.map { SettingMatch(entry: entry, target: $0) }
                } else {
                    let home = home(of: entry, among: all + known, in: config)
                    matches.append(SettingMatch(entry: entry, target: home))
                }
            }
        }
        return SettingsSearch(query: query, words: words, matches: matches)
    }

    /// Where a scoped setting is shown when it is set nowhere: the default agent, else the first that applies.
    private static func home(of entry: SettingsEntry, among targets: [SettingTarget], in config: HeedConfig)
        -> SettingTarget?
    {
        if entry.scope == .agent, config.work.agent(config.work.defaultAgent) != nil {
            return .agent(config.work.defaultAgent)
        }
        return targets.first { entry.scope.applies(to: $0) }
    }
}

public extension SettingsTree {
    /// The tree while a search is shown: only the groups and pages with matches, every such group open. The fold
    /// state itself is not changed, so clearing the search brings the tree back as it was.
    func searching(_ search: SettingsSearch) -> SettingsTree {
        let nodes = search.nodes
        return SettingsTree(page: page, folded: folded.subtracting(nodes), kept: nodes)
    }
}

/// A key in Settings' search field, as AppKit's field editor names it (`moveDown:`): the ones the search takes instead
/// of the text. Anything else stays the field's (typing, ← →, ⌘A).
public enum SettingsSearchKey: Equatable, Sendable {
    /// ↑ ↓: the cursor through the matches.
    case up, down
    /// ↩: the match the cursor is on, on its page.
    case open
    /// ⎋: the field emptied, the keyboard to the tree.
    case clear

    public init?(command: String) {
        switch command {
        case "moveUp:": self = .up
        case "moveDown:": self = .down
        case "insertNewline:": self = .open
        case "cancelOperation:": self = .clear
        default: return nil
        }
    }
}
