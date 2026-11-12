import Foundation

/// How a node ties to nodes elsewhere in its Mindmap, beyond what holds what: work that led to other work (its
/// decision replaced one taken there), and campaigns that keep touching the same files. Drawn only for the node under
/// the cursor, so the map never turns into a hairball; `]l` `[l` go to them.
public struct MindmapLink: Hashable, Sendable {
    public enum Kind: Hashable, Sendable {
        /// This work's decision replaced one taken in `target` (or the other way round: `ledFrom`).
        case ledTo, ledFrom
        /// Both touched these files.
        case sameFiles([String])
    }

    public var kind: Kind
    public var target: String

    /// In words, for the detail pane: `led to`, `same files · Toc.cs, Nav.cs`.
    public var label: String {
        switch kind {
        case .ledTo: "led to"
        case .ledFrom: "came from"
        case let .sameFiles(files): "same files · " + files.prefix(2).map { ($0 as NSString).lastPathComponent }
            .joined(separator: ", ")
        }
    }
}

public enum MindmapLinks {
    /// Files two campaigns must share to be linked.
    public static let sharedFiles = 2
    public static let maxLinks = 6

    public static func of(_ id: String, in tree: MindmapTree, ledger: [String: LedgerEntry]) -> [MindmapLink] {
        guard let node = tree[id] else { return [] }
        var links: [MindmapLink] = []
        let related = Set(tree.path(to: id).map(\.id) + tree.descendants(of: id).map(\.id) + [id])
        // Led to: a decision here replaced by one taken in other work, or the reverse.
        let mine = ([node] + tree.descendants(of: id)).filter { $0.kind == .work }
        for work in tree.nodes.values where work.kind == .work && !related.contains(work.id) {
            let theirs = Set(work.decisions.map(\.text))
            if mine.contains(where: { $0.decisions.contains { $0.supersededBy.map(theirs.contains) == true } }) {
                links.append(.init(kind: .ledTo, target: work.id))
            } else if work.decisions.contains(where: { decision in
                decision.supersededBy
                    .map { text in mine.contains { $0.decisions.contains { $0.text == text } } } == true
            }) {
                links.append(.init(kind: .ledFrom, target: work.id))
            }
        }
        // Same files: other campaigns whose work touched the files this node's work did.
        do {
            let files = Set(tree.entries(under: id).compactMap { ledger[$0] }.flatMap(\.files))
            if !files.isEmpty {
                for campaign in tree.campaigns where !related.contains(campaign.id) {
                    let theirs = Set(tree.entries(under: campaign.id).compactMap { ledger[$0] }.flatMap(\.files))
                    let shared = files.intersection(theirs).sorted()
                    if shared
                        .count >= sharedFiles { links.append(.init(kind: .sameFiles(shared), target: campaign.id)) }
                }
            }
        }
        return Array(links.prefix(maxLinks))
    }
}
