import Foundation

/// One instance's Mindmap as a value: its nodes, what sits in what, and what you can do to it. Everything here is pure;
/// the store keeps the nodes and the app decides when to write.
public struct MindmapTree: Hashable, Sendable {
    public private(set) var nodes: [String: MindNode]

    public init(_ nodes: [MindNode] = []) {
        self.nodes = Dictionary(nodes.map { ($0.id, $0) }) { _, last in last }
    }

    public subscript(id: String) -> MindNode? { nodes[id] }

    /// The top-level nodes (areas, and anything not placed in one), most recently changed first.
    public var roots: [MindNode] { sorted(nodes.values.filter { $0.parent == nil || nodes[$0.parent!] == nil }) }

    public func children(of id: String) -> [MindNode] { sorted(nodes.values.filter { $0.parent == id }) }

    /// From the root down to `id`'s parent.
    public func path(to id: String) -> [MindNode] {
        var path: [MindNode] = []
        var seen: Set<String> = [id]
        var current = nodes[id]?.parent
        while let parent = current, let node = nodes[parent], seen.insert(parent).inserted {
            path.insert(node, at: 0)
            current = node.parent
        }
        return path
    }

    /// Every node under `id`, at any depth.
    public func descendants(of id: String) -> [MindNode] {
        var all: [MindNode] = []
        var queue = children(of: id)
        var seen: Set<String> = [id]
        while !queue.isEmpty {
            let node = queue.removeFirst()
            guard seen.insert(node.id).inserted else { continue }
            all.append(node)
            queue.append(contentsOf: children(of: node.id))
        }
        return all
    }

    /// The ledger entries under `id` (itself, when it is a piece of work).
    public func entries(under id: String) -> [String] {
        ([nodes[id]].compactMap(\.self) + descendants(of: id)).compactMap(\.entry)
    }

    /// The work node of a ledger entry.
    public func work(for entry: String) -> MindNode? { nodes["work:\(entry)"] }

    /// Campaigns: what new work is placed into.
    public var campaigns: [MindNode] { sorted(nodes.values.filter { $0.kind == .campaign }) }

    /// Work waiting for a campaign: placed nowhere, or placed but only suggested.
    public var unsorted: [MindNode] { sorted(nodes.values.filter { $0.kind == .work && $0.parent == nil }) }

    private func sorted(_ nodes: [MindNode]) -> [MindNode] {
        nodes.sorted { $0.updatedAt != $1.updatedAt ? $0.updatedAt > $1.updatedAt : $0.id < $1.id }
    }

    // MARK: What a node says

    /// The decisions a node shows: its own, plus those that rose from below. A decision rises when two of the
    /// node's children cite it (the same words, near enough) or it is pinned. Superseded ones stay, marked.
    public func decisions(of id: String) -> (shown: [MindNode.Decision], inside: Int) {
        guard let node = nodes[id] else { return ([], 0) }
        var shown = node.decisions
        var inside = 0
        let kids = children(of: id)
        // What each child shows, so a decision rises one level at a time.
        let perChild = kids.map { decisions(of: $0.id).shown }
        var candidates: [MindNode.Decision] = []
        for list in perChild {
            for decision in list where !candidates.contains(where: { Self.same($0.text, decision.text) }) {
                candidates.append(decision)
            }
        }
        for decision in candidates {
            let cited = perChild.count { list in list.contains { Self.same($0.text, decision.text) } }
            let rises = decision.pinned || cited >= 2
            if rises, !shown.contains(where: { Self.same($0.text, decision.text) }) {
                shown.append(decision)
            } else if !rises {
                inside += 1
            }
        }
        return (shown, inside)
    }

    /// Everything still open in a node and below it.
    public func stillOpen(under id: String) -> [MindNode.OpenItem] {
        ([nodes[id]].compactMap(\.self) + descendants(of: id)).flatMap(\.stillOpen)
    }

    static func same(_ one: String, _ other: String) -> Bool {
        one == other || GoalItemMatch.similarity(one, other) >= GoalItemMatch.sameAbove
    }

    // MARK: Changes

    public mutating func upsert(_ node: MindNode) {
        nodes[node.id] = node
    }

    /// Marks every node above `id` stale, so their synopses are written again from what changed.
    public mutating func markStale(above id: String, now: Date) {
        for node in path(to: id) {
            nodes[node.id]?.synopsisStale = true
            nodes[node.id]?.updatedAt = now
        }
    }

    /// `m`: moves a node into another (nil: to the top). Refused into itself or below itself.
    @discardableResult
    public mutating func move(_ id: String, to parent: String?, now: Date) -> Bool {
        guard nodes[id] != nil else { return false }
        if let parent {
            guard nodes[parent] != nil, parent != id, !path(to: parent).contains(where: { $0.id == id }) else {
                return false
            }
        }
        markStale(above: id, now: now)
        nodes[id]?.parent = parent
        noteVerdict(id, campaign: parent, now: now)
        nodes[id]?.madeBy = .you
        nodes[id]?.suggested = false
        nodes[id]?.updatedAt = now
        markStale(above: id, now: now)
        return true
    }

    /// `>`: puts `ids` (siblings) into a new group, in their parent. The group's title starts as `title`.
    public mutating func group(_ ids: [String], title: String, id: String, now: Date) -> Bool {
        let parents = Set(ids.compactMap { nodes[$0] }.map(\.parent))
        guard !ids.isEmpty, ids.allSatisfy({ nodes[$0] != nil }), parents.count == 1 else { return false }
        let group = MindNode(
            id: id, parent: parents.first ?? nil, kind: .group, title: title, synopsisStale: true, madeBy: .you,
            createdAt: now
        )
        nodes[group.id] = group
        for child in ids {
            nodes[child]?.parent = group.id
            nodes[child]?.madeBy = .you
            nodes[child]?.suggested = false
        }
        markStale(above: group.id, now: now)
        return true
    }

    /// `<`: lifts a node out of its parent, into its grandparent. A group left empty goes.
    @discardableResult
    public mutating func lift(_ id: String, now: Date) -> Bool {
        guard let node = nodes[id], let parent = node.parent.flatMap({ nodes[$0] }) else { return false }
        _ = move(id, to: parent.parent, now: now)
        if parent.kind == .group, children(of: parent.id).isEmpty { nodes[parent.id] = nil }
        return true
    }

    /// `r`: a new title, yours from now on.
    public mutating func rename(_ id: String, to title: String, now: Date) {
        guard nodes[id] != nil, !title.isEmpty else { return }
        nodes[id]?.title = title
        nodes[id]?.madeBy = .you
        nodes[id]?.updatedAt = now
    }

    /// `J`: `other`'s children move into `id`, and `other` goes.
    @discardableResult
    public mutating func join(_ other: String, into id: String, now: Date) -> Bool {
        guard other != id, let source = nodes[other], let target = nodes[id] else { return false }
        guard !path(to: id).contains(where: { $0.id == other }) else { return false }
        for child in children(of: other) {
            nodes[child.id]?.parent = target.id
        }
        nodes[id]?.decisions += source.decisions
        nodes[id]?.open += source.open
        nodes[id]?.synopsisStale = true
        nodes[id]?.madeBy = .you
        nodes[id]?.updatedAt = now
        nodes[other] = nil
        markStale(above: id, now: now)
        return true
    }

    /// `x`: an open item done, by you.
    public mutating func resolve(_ text: String, in id: String, by resolver: String = "you", now: Date) {
        guard let index = nodes[id]?.open.firstIndex(where: { $0.text == text && $0.resolvedBy == nil }) else { return }
        nodes[id]?.open[index].resolvedBy = resolver
        nodes[id]?.updatedAt = now
        markStale(above: id, now: now)
    }

    /// `p`: pins a decision so it shows on every node above it; again unpins.
    public mutating func togglePin(_ text: String, in id: String, now: Date) {
        guard let index = nodes[id]?.decisions.firstIndex(where: { $0.text == text }) else { return }
        nodes[id]?.decisions[index].pinned.toggle()
        nodes[id]?.updatedAt = now
    }

    /// What you did with a placement heed asked about, as the answer it should have given: the option of the
    /// campaign the work ended in (or `new` at the top). A campaign it was not offered teaches nothing.
    private mutating func noteVerdict(_ id: String, campaign: String?, now: Date) {
        guard nodes[id]?.kind == .work, let placement = nodes[id]?.placement, placement.state != nil else { return }
        let target = campaign.flatMap { nodes[$0]?.kind == .campaign ? $0 : nil }
        guard campaign == nil || target != nil, let option = placement.option(of: target) else { return }
        nodes[id]?.placement?.verdict = option
        nodes[id]?.placement?.verdictAt = now
    }

    /// `y`, or ✓ on the card: heed placed it right. A suggestion stands; an unconfirmed placement is confirmed.
    public mutating func accept(_ id: String, now: Date) {
        guard let node = nodes[id], node.suggested || node.unconfirmed else { return }
        noteVerdict(id, campaign: node.parent, now: now)
        nodes[id]?.suggested = false
        nodes[id]?.updatedAt = now
    }
}
