import Foundation

/// Sizing splits: the ratio each divider keeps, set by dragging it or with `⌃w +`, `⌃w -`, `⌃w <`, `⌃w >` and `⌃w =`.
/// The tree keeps what you asked for; `PaneSizing` turns it into points, so no pane is drawn too small to use however
/// small the window gets.
public extension PaneTree {
    /// Which side of a split a path goes down.
    enum Side: Sendable, Hashable { case first, second }

    /// A split by the sides taken from the root to reach it; `[]` is the root.
    typealias SplitPath = [Side]

    /// A new split, and one that was cached before ratios were kept.
    static let equalRatio = 0.5

    /// Ratios a split may keep. The view keeps every pane at its minimum size on top of this.
    static let ratioBounds: ClosedRange<Double> = 0.05 ... 0.95

    /// How far one `⌃w +` (and the like) moves a divider, as a share of its split.
    static let resizeStep = 0.05

    /// The ratio of the split at `path`; nil when there is no split there.
    func ratio(at path: SplitPath) -> Double? {
        guard case let .split(_, first, second, ratio) = self else { return nil }
        guard let side = path.first else { return ratio }
        return (side == .first ? first : second).ratio(at: Array(path.dropFirst()))
    }

    /// The same tree with the split at `path` keeping `ratio`, inside `ratioBounds` (anything not finite is an equal
    /// split). Nothing changes when there is no split at `path`.
    func settingRatio(_ ratio: Double, at path: SplitPath) -> PaneTree {
        guard case let .split(axis, first, second, current) = self else { return self }
        guard let side = path.first else { return .split(axis, first, second, ratio: Self.bounded(ratio)) }
        let rest = Array(path.dropFirst())
        return side == .first
            ? .split(axis, first.settingRatio(ratio, at: rest), second, ratio: current)
            : .split(axis, first, second.settingRatio(ratio, at: rest), ratio: current)
    }

    /// The split at `path` back to equal: each pane along its axis gets the same share (a double-click on its divider).
    func resettingRatio(at path: SplitPath) -> PaneTree {
        guard let equal = equalRatio(at: path) else { return self }
        return settingRatio(equal, at: path)
    }

    /// Every split equal, as `⌃w =`.
    func equalized() -> PaneTree {
        guard case let .split(axis, first, second, _) = self else { return self }
        return .split(axis, first.equalized(), second.equalized(), ratio: equalShare)
    }

    /// The pane `id` grown by `delta` (shrunk when negative) along `axis`: the innermost split of that axis around it
    /// moves its divider. Nil when no split of that axis holds it.
    func resizing(_ id: String, along axis: Axis, by delta: Double) -> PaneTree? {
        guard case let .split(splitAxis, first, second, ratio) = self, contains(id) else { return nil }
        let inFirst = first.contains(id)
        if inFirst, let inner = first.resizing(id, along: axis, by: delta) {
            return .split(splitAxis, inner, second, ratio: ratio)
        }
        if !inFirst, let inner = second.resizing(id, along: axis, by: delta) {
            return .split(splitAxis, first, inner, ratio: ratio)
        }
        guard splitAxis == axis else { return nil }
        return .split(splitAxis, first, second, ratio: Self.bounded(ratio + (inFirst ? delta : -delta)))
    }

    /// The smallest this tree can be along `axis` with every pane at its minimum.
    func minimumExtent(along axis: Axis, _ sizing: PaneSizing) -> Double {
        switch self {
        case .leaf:
            return axis == .horizontal ? sizing.minimumWidth : sizing.minimumHeight
        case let .split(splitAxis, first, second, _):
            let lhs = first.minimumExtent(along: axis, sizing)
            let rhs = second.minimumExtent(along: axis, sizing)
            return splitAxis == axis ? lhs + sizing.divider + rhs : max(lhs, rhs)
        }
    }

    /// How many panes sit side by side along `axis`: what an equal split shares the space by.
    private func span(along axis: Axis) -> Int {
        switch self {
        case .leaf: 1
        case let .split(splitAxis, first, second, _):
            splitAxis == axis
                ? first.span(along: axis) + second.span(along: axis)
                : max(first.span(along: axis), second.span(along: axis))
        }
    }

    private var equalShare: Double {
        guard case let .split(axis, first, second, _) = self else { return Self.equalRatio }
        let lhs = Double(first.span(along: axis))
        return lhs / (lhs + Double(second.span(along: axis)))
    }

    private func equalRatio(at path: SplitPath) -> Double? {
        guard case let .split(_, first, second, _) = self else { return nil }
        guard let side = path.first else { return equalShare }
        return (side == .first ? first : second).equalRatio(at: Array(path.dropFirst()))
    }

    private static func bounded(_ ratio: Double) -> Double {
        ratio.isFinite ? min(max(ratio, ratioBounds.lowerBound), ratioBounds.upperBound) : equalRatio
    }
}

/// Splits in points: how much of a split the first side gets, with no pane smaller than a terminal can be used at.
public struct PaneSizing: Sendable, Equatable {
    public var minimumWidth: Double
    public var minimumHeight: Double
    /// The divider's own thickness between two sides.
    public var divider: Double

    public init(minimumWidth: Double, minimumHeight: Double, divider: Double) {
        self.minimumWidth = minimumWidth
        self.minimumHeight = minimumHeight
        self.divider = divider
    }

    /// About twenty columns and four rows of the default font under a pane's header.
    public static let standard = PaneSizing(minimumWidth: 160, minimumHeight: 110, divider: 1)

    /// The first side's extent along the split's axis when the split is `total` long. A pane below its minimum is
    /// given its minimum; when even that does not fit, the space is shared by what each side needs.
    public func firstExtent(of tree: PaneTree, total: Double) -> Double {
        guard case let .split(axis, first, second, ratio) = tree else { return total }
        let available = max(total - divider, 0)
        let (lhs, rhs) = (first.minimumExtent(along: axis, self), second.minimumExtent(along: axis, self))
        guard lhs + rhs <= available else { return available * lhs / (lhs + rhs) }
        return min(max(ratio * available, lhs), available - rhs)
    }

    /// The ratio for a divider dragged to leave the first side `extent` long, stopped where a pane would get too small.
    public func ratio(forFirstExtent extent: Double, of tree: PaneTree, total: Double) -> Double {
        let available = max(total - divider, 0)
        guard available > 0 else { return PaneTree.equalRatio }
        return firstExtent(of: tree.settingRatio(extent / available, at: []), total: total) / available
    }
}

/// Dragging a tab along the tab strip: where it lands, and how the others make room while it moves.
public enum TabDrag {
    /// The index tab `index` lands at, dragged `offset` points along a strip of tabs `widths` wide: past the middle of
    /// a neighbour, it takes that neighbour's place.
    public static func target(dragging index: Int, by offset: Double, widths: [Double]) -> Int {
        guard widths.indices.contains(index) else { return index }
        let centre = widths[..<index].reduce(0, +) + widths[index] / 2 + offset
        var x = 0.0
        var passed = 0
        for (other, width) in widths.enumerated() where other != index {
            if x + width / 2 < centre { passed += 1 }
            x += width
        }
        return passed
    }

    /// How far tab `other` slides while tab `index` is dragged to `target`: by the dragged tab's width, toward the gap
    /// it left, for the tabs between the two.
    public static func shift(of other: Int, dragging index: Int, to target: Int, widths: [Double]) -> Double {
        guard widths.indices.contains(index), other != index else { return 0 }
        if index < target, other > index, other <= target { return -widths[index] }
        if index > target, other >= target, other < index { return widths[index] }
        return 0
    }
}

/// At most one update a frame while something is dragged: a terminal resized faster than it can draw only flickers.
public struct FrameThrottle: Sendable {
    public let interval: Double
    private var last: Double?

    public init(interval: Double = 1.0 / 60) { self.interval = interval }

    /// Whether an update at `time` (seconds) may go now; if so, it counts as the last one.
    public mutating func admit(at time: Double) -> Bool {
        guard wait(at: time) == 0 else { return false }
        last = time
        return true
    }

    /// How long until an update may go.
    public func wait(at time: Double) -> Double {
        guard let last else { return 0 }
        return max(0, last + interval - time)
    }

    /// The drag ended: the next one starts at once.
    public mutating func reset() { last = nil }
}
