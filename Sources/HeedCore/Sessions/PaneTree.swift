import Foundation

/// What runs in a pane. The terminal itself lives in the app; this is the record that survives a relaunch.
public struct PaneSpec: Hashable, Sendable, Codable, Identifiable {
    public enum Role: String, Sendable, Codable {
        /// The shell the agent runs in; the session survives the agent exiting.
        case agent
        case shell
        /// A repo's pinned task (test, build, docs preview); its exit code sets the tab's glyph.
        case task
    }

    public var id: String
    public var role: Role
    public var title: String
    public var directory: String
    /// Typed into the shell once it starts (the agent command, a task's command). Nil for a plain shell.
    public var command: String?

    public init(id: String = UUID().uuidString, role: Role, title: String, directory: String, command: String? = nil) {
        self.id = id
        self.role = role
        self.title = title
        self.directory = directory
        self.command = command
    }
}

/// A tab's panes as a binary split tree, vim-style: `<C-w>v` splits the focused pane to the right, `<C-w>s` below.
public indirect enum PaneTree: Hashable, Sendable, Codable {
    public enum Axis: String, Sendable, Codable {
        /// Side by side.
        case horizontal
        /// Stacked.
        case vertical
    }

    case leaf(PaneSpec)
    case split(Axis, PaneTree, PaneTree, ratio: Double)

    /// Panes in reading order (left to right, top to bottom); their 1-based position is the pane number in the UI.
    public var panes: [PaneSpec] {
        switch self {
        case let .leaf(pane): [pane]
        case let .split(_, first, second, _): first.panes + second.panes
        }
    }

    public func contains(_ id: String) -> Bool { panes.contains { $0.id == id } }

    /// The same tree with pane `id` edited.
    public func updating(_ id: String, _ edit: (inout PaneSpec) -> Void) -> PaneTree {
        switch self {
        case var .leaf(pane):
            guard pane.id == id else { return self }
            edit(&pane)
            return .leaf(pane)
        case let .split(axis, first, second, ratio):
            return .split(axis, first.updating(id, edit), second.updating(id, edit), ratio: ratio)
        }
    }

    /// Splits the pane `id`, putting `new` to its right (horizontal) or below it (vertical).
    public func splitting(_ id: String, axis: Axis, with new: PaneSpec) -> PaneTree {
        switch self {
        case let .leaf(pane) where pane.id == id:
            .split(axis, self, .leaf(new), ratio: 0.5)
        case .leaf:
            self
        case let .split(splitAxis, first, second, ratio):
            .split(
                splitAxis, first.splitting(id, axis: axis, with: new), second.splitting(id, axis: axis, with: new),
                ratio: ratio
            )
        }
    }

    /// Removes pane `id`; its sibling takes the space. Nil when it was the last pane.
    public func removing(_ id: String) -> PaneTree? {
        switch self {
        case let .leaf(pane):
            return pane.id == id ? nil : self
        case let .split(axis, first, second, ratio):
            guard contains(id) else { return self }
            let newFirst = first.removing(id)
            let newSecond = second.removing(id)
            switch (newFirst, newSecond) {
            case let (lhs?, rhs?): return .split(axis, lhs, rhs, ratio: ratio)
            case let (lhs?, nil): return lhs
            case let (nil, rhs?): return rhs
            case (nil, nil): return nil
            }
        }
    }

    public enum Direction: Sendable { case left, right, up, down }

    /// The pane focus moves to from `id` in `direction`: the nearest pane on that side of the enclosing split.
    public func neighbor(of id: String, _ direction: Direction) -> String? {
        let axis: Axis = (direction == .left || direction == .right) ? .horizontal : .vertical
        let forward = direction == .right || direction == .down
        return neighbor(of: id, axis: axis, forward: forward)
    }

    private func neighbor(of id: String, axis: Axis, forward: Bool) -> String? {
        guard case let .split(splitAxis, first, second, _) = self else { return nil }
        let inFirst = first.contains(id)
        let inner = inFirst ? first : second
        if let found = inner.neighbor(of: id, axis: axis, forward: forward) { return found }
        guard splitAxis == axis else { return nil }
        if inFirst, forward { return second.panes.first?.id }
        if !inFirst, !forward { return first.panes.last?.id }
        return nil
    }
}

/// A tab in a session: a name and its pane tree.
public struct PaneTab: Hashable, Sendable, Codable, Identifiable {
    public var id: String
    public var title: String
    public var tree: PaneTree
    public var focused: String
    public var zoomed: Bool

    public init(id: String = UUID().uuidString, title: String, tree: PaneTree, focused: String? = nil) {
        self.id = id
        self.title = title
        self.tree = tree
        self.focused = focused ?? tree.panes[0].id
        zoomed = false
    }

    public mutating func split(_ axis: PaneTree.Axis, with pane: PaneSpec) {
        tree = tree.splitting(focused, axis: axis, with: pane)
        focused = pane.id
        zoomed = false
    }

    /// Closes the focused pane. Returns false when it was the tab's last pane (the caller closes the tab).
    public mutating func closeFocused() -> Bool {
        let order = tree.panes.map(\.id)
        guard let remaining = tree.removing(focused) else { return false }
        let index = order.firstIndex(of: focused) ?? 0
        tree = remaining
        let left = remaining.panes
        focused = left[min(max(index - 1, 0), left.count - 1)].id
        zoomed = false
        return true
    }

    public mutating func focus(_ direction: PaneTree.Direction) {
        if let next = tree.neighbor(of: focused, direction) { focused = next }
    }
}
