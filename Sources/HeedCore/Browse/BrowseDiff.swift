import Foundation

/// What a fresh answer changes in the list Browse shows, as a pure value: the rows whose fields changed (applied in
/// place, silently), and the rows that came, went or changed rank (the structural part, which waits behind a banner
/// while you hold an item).
public struct BrowseDiff: Equatable, Sendable {
    /// Rows on screen whose fetched version differs in any field they show, as fetched.
    public var updated: [BrowseItem]
    /// Rows the fetch has and the list does not, in the new order.
    public var added: [BrowseItem]
    /// Rows the list has and the fetch does not, as they are shown now.
    public var removed: [BrowseItem]
    /// Ids of rows the sort puts in another place: the fewest rows that, moved, give the new order.
    public var moved: [String]
    /// The whole new list, in order: what applying the diff shows.
    public var target: [BrowseItem]

    public init(
        updated: [BrowseItem] = [], added: [BrowseItem] = [], removed: [BrowseItem] = [], moved: [String] = [],
        target: [BrowseItem] = []
    ) {
        self.updated = updated
        self.added = added
        self.removed = removed
        self.moved = moved
        self.target = target
    }

    /// Rows came, went or changed place: a change the list must not make under a held item.
    public var isStructural: Bool { !added.isEmpty || !removed.isEmpty || !moved.isEmpty }

    public var isEmpty: Bool { updated.isEmpty && !isStructural }

    /// `3 new, 5 updated, 1 gone, 2 reordered`: every part that is not empty, in that order.
    public var summary: String {
        Self.join(
            [(added.count, "new"), (updated.count, "updated"), (removed.count, "gone"), (moved.count, "reordered")],
            by: ", "
        )
    }

    /// `3 new · 1 gone · 5 reordered`: what the banner says, the structural parts only.
    public var bannerText: String {
        Self.join([(added.count, "new"), (removed.count, "gone"), (moved.count, "reordered")], by: " \u{B7} ")
    }

    private static func join(_ parts: [(Int, String)], by separator: String) -> String {
        parts.filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }.joined(separator: separator)
    }

    /// The change from `current` (what is shown, in its order) to `fetched` (what the view would show), ordered by
    /// `order`. An id twice in `fetched` counts once, the last wins as when items are merged; twice in `current`, the
    /// first.
    public static func between(current: [BrowseItem], fetched: [BrowseItem], order: BrowseSort) -> BrowseDiff {
        var shown: [String: BrowseItem] = [:]
        var shownOrder: [String] = []
        for item in current where shown[item.id] == nil {
            shown[item.id] = item
            shownOrder.append(item.id)
        }
        var latest: [String: BrowseItem] = [:]
        for item in fetched {
            latest[item.id] = item
        }
        let target = order.sorted(Array(latest.values))
        var diff = BrowseDiff(target: target)
        for item in target {
            if let was = shown[item.id] {
                if was != item { diff.updated.append(item) }
            } else {
                diff.added.append(item)
            }
        }
        diff.removed = shownOrder.compactMap { latest[$0] == nil ? shown[$0] : nil }
        // Rank of each id in the new order; the rows that keep their relative order (the longest increasing run, as
        // seen in the shown order) stay, the others moved.
        let rank = Dictionary(uniqueKeysWithValues: target.enumerated().map { ($1.id, $0) })
        let common = shownOrder.filter { rank[$0] != nil }
        let stays = Self.longestIncreasing(common.map { rank[$0]! })
        diff.moved = common.enumerated().filter { !stays.contains($0.offset) }.map(\.element)
        return diff
    }

    /// The positions of one longest strictly increasing run in `values` (distinct numbers).
    static func longestIncreasing(_ values: [Int]) -> Set<Int> {
        var tails: [Int] = [] // index in values of the smallest tail of a run of each length
        var previous = [Int?](repeating: nil, count: values.count)
        for index in values.indices {
            var low = 0
            var high = tails.count
            while low < high {
                let mid = (low + high) / 2
                if values[tails[mid]] < values[index] { low = mid + 1 } else { high = mid }
            }
            previous[index] = low > 0 ? tails[low - 1] : nil
            if low == tails.count { tails.append(index) } else { tails[low] = index }
        }
        var keep: Set<Int> = []
        var at = tails.last
        while let position = at {
            keep.insert(position)
            at = previous[position]
        }
        return keep
    }
}
