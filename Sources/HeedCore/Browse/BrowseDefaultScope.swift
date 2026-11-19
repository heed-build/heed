import Foundation

/// The default scope as GitHub searches: several `org:` qualifiers in one search are OR'd, but a search string holds
/// 256
/// characters at most, so the qualifiers are split into groups that each fit. The groups are disjoint: a count is the
/// sum of the groups' counts.
public enum BrowseDefaultScope {
    /// The longest search string asked (GitHub's limit is 256; the rest is margin).
    public static let limit = 240
    /// The most searches one fetch runs; qualifiers beyond them are left out and the header says so.
    public static let maxGroups = 6

    public struct Plan: Equatable, Sendable {
        /// The qualifiers of each search that runs.
        public var groups: [[String]]
        /// How many searches all the qualifiers need: more than `groups.count` when `maxGroups` cut it short.
        public var totalGroups: Int
        public var omitted: Bool { totalGroups > groups.count }
    }

    /// Splits `qualifiers` into searches of at most `limit` characters with `rest` (the filters) on each.
    public static func plan(
        _ qualifiers: [String],
        rest: String,
        limit: Int = limit,
        maxGroups: Int = maxGroups
    ) -> Plan {
        var groups: [[String]] = []
        var current: [String] = []
        var length = rest.count
        for qualifier in qualifiers {
            let added = qualifier.count + 1
            if !current.isEmpty, length + added > limit {
                groups.append(current)
                current = []
                length = rest.count
            }
            current.append(qualifier)
            length += added
        }
        if !current.isEmpty { groups.append(current) }
        return Plan(groups: Array(groups.prefix(maxGroups)), totalGroups: groups.count)
    }

    /// The search string of one group.
    public static func text(_ group: [String], rest: String) -> String {
        (group + (rest.isEmpty ? [] : [rest])).joined(separator: " ")
    }
}
