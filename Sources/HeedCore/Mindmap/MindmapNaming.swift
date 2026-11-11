import Foundation

/// New campaigns, named by a cheap model from the work that fits none yet: a title as a person would say it, what it
/// is for, and the broad area it belongs to. Asked when enough work waits in Unsorted, never more than
/// `MindmapNaming.dailyCalls` times a day per Mindmap.
public enum MindmapNaming {
    /// Pieces of unsorted work that make a call worth it, and the most one call reads.
    public static let minimum = 3
    public static let batch = 30
    public static let dailyCalls = 6

    public struct Proposal: Hashable, Sendable {
        public var title: String
        public var intent: String?
        public var area: String?
        public var work: [String]
    }

    /// What the model reads: each piece of unsorted work by its ledger id, newest first.
    public static func inputs(_ entries: [LedgerEntry]) -> SummaryInputs {
        SummaryInputs(
            title: "Group this work into campaigns",
            known: entries.prefix(batch).map { entry in
                "\(entry.id): \(entry.title)" + (entry.summary.map { ". \($0)" } ?? "")
            }
        )
    }

    /// The campaigns in a reply; ids it did not read, and campaigns left with none, are dropped.
    public static func parse(_ text: String, known: Set<String>) -> [Proposal] {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let campaigns = object["campaigns"] as? [[String: Any]]
        else { return [] }
        var taken: Set<String> = []
        return campaigns.compactMap { campaign in
            guard let title = (campaign["title"] as? String)?.trimmingCharacters(in: .whitespaces), !title.isEmpty
            else { return nil }
            let work = ((campaign["work"] as? [Any]) ?? []).compactMap { $0 as? String }
                .filter { known.contains($0) && taken.insert($0).inserted }
            guard !work.isEmpty else { return nil }
            return Proposal(
                title: String(title.prefix(80)), intent: (campaign["intent"] as? String).map { String($0.prefix(200)) },
                area: (campaign["area"] as? String).map { String($0.prefix(40)) }, work: work
            )
        }
    }

    /// Makes the campaigns (inside their area: an existing one of the same name, or a new one) and moves their
    /// work in. Work you placed yourself is never moved.
    public static func apply(_ proposals: [Proposal], to tree: inout MindmapTree, now: Date) {
        for proposal in proposals {
            let area = proposal.area.flatMap { name -> String? in
                if let existing = tree.roots.first(where: {
                    $0.kind == .area && $0.title.caseInsensitiveCompare(name) == .orderedSame
                }) {
                    return existing.id
                }
                let node = MindNode(id: id("area", name), kind: .area, title: name, synopsisStale: true, createdAt: now)
                tree.upsert(node)
                return node.id
            }
            let campaign = tree.campaigns.first {
                $0.title.caseInsensitiveCompare(proposal.title) == .orderedSame
            } ?? MindNode(
                id: id("campaign", proposal.title), parent: area, kind: .campaign, title: proposal.title,
                intent: proposal.intent, synopsisStale: true, createdAt: now
            )
            tree.upsert(campaign)
            for entry in proposal.work {
                guard var work = tree.work(for: entry), work.madeBy != .you, work.parent == nil else { continue }
                work.parent = campaign.id
                work.suggested = false
                work.placement = .init(confidence: 1, route: "named")
                work.updatedAt = now
                tree.upsert(work)
            }
            tree.markStale(above: "work:\(proposal.work[0])", now: now)
        }
    }

    /// A stable id from a title: `campaign:make-the-docs-nav-trustworthy`.
    static func id(_ kind: String, _ title: String) -> String {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        let collapsed = String(slug).split(separator: "-").joined(separator: "-")
        return "\(kind):\(collapsed.prefix(60))"
    }
}
