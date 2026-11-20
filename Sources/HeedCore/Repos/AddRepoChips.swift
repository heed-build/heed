import Foundation

/// Where the Add or clone dialog's tab chips go: as many as fit in `maxRows` rows, the rest behind a "+N more" chip.
/// Pure arithmetic over chip widths, so it is tested without SwiftUI. A chip is never split across rows, the order is
/// the order given, and the chip you are on is always shown.
public enum AddRepoChips {
    /// The chips shown, and the ones behind "+N more", as indices into the widths, each in the order given.
    public struct Result: Equatable, Sendable {
        public var visible: [Int]
        public var overflow: [Int]
    }

    public static let spacing = 8.0
    /// The widest a chip gets; a longer name is cut with an ellipsis (its tooltip has all of it).
    public static let maxChipWidth = 210.0

    /// The rows the chips make when flowed left to right: a chip that does not fit the rest of a row starts the next,
    /// and one wider than a whole row sits alone on it.
    public static func pack(_ widths: [Double], available: Double, spacing: Double = spacing) -> [[Int]] {
        var rows: [[Int]] = []
        var used = 0.0
        for (index, raw) in widths.enumerated() {
            let width = min(raw, available)
            if rows.isEmpty || used + spacing + width > available {
                rows.append([index])
                used = width
            } else {
                rows[rows.count - 1].append(index)
                used += spacing + width
            }
        }
        return rows
    }

    /// Which chips stay visible. All of them when they fit in `maxRows`. Otherwise `pinned` and `selected` stay, then
    /// the `recent` ones (most recent first), then the rest in order for as long as they fit beside a "+N more" chip
    /// `moreWidth` wide. The first of the rest that does not fit ends the list, so what shows is a prefix.
    public static func layout(
        widths: [Double], available: Double, maxRows: Int, selected: Int?, pinned: Set<Int> = [],
        recent: [Int] = [], spacing: Double = spacing, moreWidth: Double
    ) -> Result {
        let all = Array(widths.indices)
        guard !all.isEmpty else { return Result(visible: [], overflow: []) }
        if pack(widths, available: available, spacing: spacing).count <= max(maxRows, 1) {
            return Result(visible: all, overflow: [])
        }
        func fits(_ chosen: Set<Int>) -> Bool {
            let shown = all.filter(chosen.contains).map { widths[$0] } + [moreWidth]
            return pack(shown, available: available, spacing: spacing).count <= max(maxRows, 1)
        }
        var chosen = pinned.filter { widths.indices.contains($0) }
        if let selected, widths.indices.contains(selected) { chosen.insert(selected) }
        var seen = chosen
        let kept = recent.filter { widths.indices.contains($0) && seen.insert($0).inserted }
        for index in kept where fits(chosen.union([index])) {
            chosen.insert(index)
        }
        for index in all where !chosen.contains(index) && !kept.contains(index) {
            guard fits(chosen.union([index])) else { break }
            chosen.insert(index)
        }
        return Result(visible: all.filter(chosen.contains), overflow: all.filter { !chosen.contains($0) })
    }

    /// A chip's width, estimated from its text (the dialog has no way to measure before it lays out): the name, the
    /// compact count after it, and the padding.
    public static func width(title: String, count: Int?) -> Double {
        let name = Double(title.count) * 7
        let number = count.map { Double(BrowseNumber.compact($0).count) * 6.6 + 7 } ?? 0
        return min(name + number + 26, maxChipWidth)
    }

    /// The "+N more" chip's width at its widest (every chip in it).
    public static func moreWidth(total: Int) -> Double {
        Double("+\(total) more".count) * 7 + 26
    }
}
