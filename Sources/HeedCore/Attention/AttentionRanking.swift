import Foundation

/// An item with what the rules and your marks make of it.
public struct AttentionEntry: Identifiable, Hashable, Sendable {
    public var item: AttentionItem
    public var outcome: AttentionOutcome
    public var mark: AttentionMark
    /// Still reported by GitHub or the sessions; an item only the store remembers is listed under Muted at most.
    public var live: Bool

    public var id: String { item.id }

    /// Out of the feed for good: a rule ignores it, or you muted it.
    public var muted: Bool { outcome.action.ignore || mark.mutedAt != nil }
    public var pinned: Bool { outcome.action.pin }
    public var lowered: Bool { outcome.action.lower }
    public var weight: Int { outcome.action.weight }
}

public enum AttentionSort: String, CaseIterable, Hashable, Sendable {
    /// Newest first (pinned on top).
    case recent
    /// Highest weight first, newest first within a weight (pinned on top).
    case weight

    public var title: String {
        switch self {
        case .recent: "Recent first"
        case .weight: "Weight, then recent"
        }
    }
}

public enum AttentionRanking {
    /// Every item with its outcome and mark. `live` are the items now; `stored` adds the ones the store remembers that
    /// are no longer live (for Muted).
    public static func entries(
        live: [AttentionItem], stored: [AttentionItem] = [], rules: AttentionRules,
        marks: [String: AttentionMark], viewer: String?, now: Date
    ) -> [AttentionEntry] {
        let liveIDs = Set(live.map(\.id))
        let all = live.map { ($0, true) } + stored.filter { !liveIDs.contains($0.id) }.map { ($0, false) }
        return all.map { item, isLive in
            AttentionEntry(
                item: item, outcome: rules.outcome(for: item, viewer: viewer, now: now),
                mark: marks[item.id] ?? AttentionMark(), live: isLive
            )
        }
    }

    /// What a filter lists, in order. Muted lists what rules ignore and what you muted (live or remembered); every
    /// other filter lists live items that are not muted, snoozed or done.
    public static func list(
        _ entries: [AttentionEntry], filter: AttentionFilter, sort: AttentionSort = .recent, now: Date
    ) -> [AttentionEntry] {
        let listed = entries.filter { entry in
            if filter == .muted { return entry.muted }
            return entry.live && !entry.muted && !entry.mark.hides(entry.item, now: now) && filter.matches(entry.item)
        }
        return listed.sorted { left, right in
            if left.pinned != right.pinned { return left.pinned }
            if sort == .weight, left.weight != right.weight { return left.weight > right.weight }
            if left.item.updatedAt != right.item.updatedAt { return left.item.updatedAt > right.item.updatedAt }
            return left.id < right.id
        }
    }

    /// How many each filter lists.
    public static func counts(_ entries: [AttentionEntry], now: Date) -> [AttentionFilter: Int] {
        Dictionary(uniqueKeysWithValues: AttentionFilter.allCases
            .map { ($0, list(entries, filter: $0, now: now).count) })
    }
}
