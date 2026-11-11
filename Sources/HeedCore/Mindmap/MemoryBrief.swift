import Foundation

/// What a session started from a Mindmap node (or on a goal whose work sits in one) is told at launch: what was
/// decided there and still stands, what was tried and dropped, what is still open, and its PRs. From that node's own
/// Mindmap only, so work in one org never reaches a session in another. Plain text in one paragraph, as the agents'
/// launch instructions take it.
public enum MemoryBrief {
    public static let maxDecisions = 8
    public static let maxDropped = 4
    public static let maxOpen = 8

    /// The campaign a node belongs to: itself when it is one (or an area, or a group), else the nearest campaign
    /// above it.
    public static func anchor(of id: String, in tree: MindmapTree) -> MindNode? {
        guard let node = tree[id] else { return nil }
        if node.kind != .work { return node }
        return tree.path(to: id).last { $0.kind == .campaign } ?? tree.path(to: id).last
    }

    /// The campaign most of these pieces of work sit in (a goal's sessions), nil when none is placed.
    public static func campaign(holding entries: [String], in tree: MindmapTree) -> MindNode? {
        let anchors = entries.compactMap { tree.work(for: $0) }.compactMap { anchor(of: $0.id, in: tree) }
        let counts = Dictionary(grouping: anchors, by: \.id)
        return counts.max { $0.value.count != $1.value.count ? $0.value.count < $1.value.count : $0.key > $1.key }?
            .value.first
    }

    public static func text(for id: String, in tree: MindmapTree, ledger: [String: LedgerEntry], instance: String)
        -> String?
    {
        guard let node = anchor(of: id, in: tree) else { return nil }
        let decided = tree.decisions(of: node.id).shown.filter { $0.supersededBy == nil }
            + tree.descendants(of: node.id).flatMap(\.standing)
        var seen: Set<String> = []
        let decisions = decided.filter { seen.insert($0.text.lowercased()).inserted }.prefix(maxDecisions)
        let work = tree.entries(under: node.id).compactMap { ledger[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        let dropped = work.filter { ["abandoned", "closed"].contains($0.outcome) }.prefix(maxDropped)
        let open = tree.stillOpen(under: node.id).prefix(maxOpen)
        let pulls = work.flatMap(\.pulls).prefix(8)
        guard !decisions.isEmpty || !dropped.isEmpty || !open.isEmpty else { return nil }
        var parts = [
            "Heed keeps a memory of earlier work: this session continues \(node.title)"
                + " (\(MindmapInstance.title(instance))).",
        ]
        if let intent = node.intent { parts.append("It is for: \(intent)") }
        if !decisions.isEmpty {
            parts.append("Decided earlier and still standing: " + decisions.map(\.text).joined(separator: "; ") + ".")
        }
        if !dropped.isEmpty {
            parts.append("Tried and dropped: " + dropped.map { entry in
                entry.title + (entry.summary.map { " (\(firstSentence($0)))" } ?? "")
            }.joined(separator: "; ") + ".")
        }
        if !open.isEmpty { parts.append("Still open: " + open.map(\.text).joined(separator: "; ") + ".") }
        if !pulls.isEmpty {
            parts.append("Its PRs: " + pulls.map { "\($0.repo.slug)#\($0.number)" }.joined(separator: ", ") + ".")
        }
        parts.append("Keep to these decisions unless the work shows one is wrong, and say so when it does.")
        return plain(parts.joined(separator: " "))
    }

    static func firstSentence(_ text: String) -> String {
        let end = text.firstIndex { ".;".contains($0) } ?? text.endIndex
        return String(text[..<end]).trimmingCharacters(in: .whitespaces)
    }

    /// Launch instructions are passed through a shell and TOML: no quotes, backticks, dollars or backslashes.
    static func plain(_ text: String) -> String { text.filter { !"\"'`$\\\n".contains($0) } }
}

/// `[memory]`: what sessions are told from the Mindmap at launch.
public struct MemorySettings: Equatable, Sendable {
    public enum Brief: String, Sendable, CaseIterable {
        /// Sessions started from a Mindmap node (`s`), and sessions on a goal whose work sits in a campaign.
        case nodeAndGoal = "node_and_goal"
        case off
    }

    public var brief: Brief = .nodeAndGoal

    public init(brief: Brief = .nodeAndGoal) { self.brief = brief }
}
