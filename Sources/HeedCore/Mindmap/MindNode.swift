import Foundation

/// One node of a Mindmap: an area, a campaign, a group you made, or one piece of work (a ledger entry). Every node,
/// at any depth, reads the same: a synopsis, the decisions taken in it, and what is still open; its facts (pieces of
/// work, PRs, agent time) are counted from the ledger, never kept here.
public struct MindNode: Codable, Hashable, Sendable, Identifiable {
    public enum Kind: String, Codable, Hashable, Sendable, CaseIterable {
        /// A broad part of the work (`Docs`), holding campaigns.
        case area
        /// What a run of work was for (`Make the docs nav trustworthy`).
        case campaign
        /// A group you made inside another node (`>`).
        case group
        /// One piece of work: `entry` is its ledger id.
        case work
    }

    /// Where a campaign is, from Hunch's reading of its latest work.
    public enum Stage: String, Codable, Hashable, Sendable, CaseIterable {
        case exploring, building, landing, done, stalled
    }

    /// Who put the node where it is. What you made, moved or renamed stays when heed groups again.
    public enum MadeBy: String, Codable, Hashable, Sendable {
        case heed, you
    }

    public var id: String
    /// The node it sits in; nil for the instance's top-level areas (and work not placed yet).
    public var parent: String?
    public var kind: Kind
    public var title: String
    /// What a campaign is for, in a sentence.
    public var intent: String?
    public var stage: Stage?
    public var synopsis: String?
    /// A child changed since the synopsis was written.
    public var synopsisStale: Bool
    /// The ledger id of a piece of work.
    public var entry: String?
    public var decisions: [Decision]
    public var open: [OpenItem]
    public var madeBy: MadeBy
    /// Placed by heed but not sure enough to stand on its own: waits for `y` (or a move).
    public var suggested: Bool
    /// How sure the placement was, and which route answered (`hunch`, `local`, `model`, `words`).
    public var placement: Placement?
    public var createdAt: Date
    public var updatedAt: Date

    public struct Decision: Codable, Hashable, Sendable {
        public var text: String
        /// The ledger entry it came from.
        public var source: String
        /// A later decision that replaced it (its text), when Hunch read the later work as contradicting it.
        public var supersededBy: String?
        public var pinned: Bool

        public init(text: String, source: String, supersededBy: String? = nil, pinned: Bool = false) {
            self.text = text
            self.source = source
            self.supersededBy = supersededBy
            self.pinned = pinned
        }
    }

    public struct OpenItem: Codable, Hashable, Sendable {
        public enum Kind: String, Codable, Hashable, Sendable {
            /// A follow-up the summary wrote down.
            case followUp = "follow-up"
        }

        public var kind: Kind
        public var text: String
        public var source: String
        /// The ledger entry whose work resolved it, or `you` when you marked it done.
        public var resolvedBy: String?

        public init(kind: Kind = .followUp, text: String, source: String, resolvedBy: String? = nil) {
            self.kind = kind
            self.text = text
            self.source = source
            self.resolvedBy = resolvedBy
        }
    }

    /// How heed placed a piece of work, and what you made of it: what Hunch learns from.
    public struct Placement: Codable, Hashable, Sendable {
        public var confidence: Double
        public var route: String
        /// What the Decider read, when it was asked (nil when the words settled it).
        public var state: String?
        /// The campaigns it was offered, in order: `c1` is the first.
        public var options: [String]
        /// The right answer, once you said: the option of the campaign you accepted or moved it to, or `new`.
        public var verdict: String?
        public var verdictAt: Date?

        public init(
            confidence: Double, route: String, state: String? = nil, options: [String] = [], verdict: String? = nil,
            verdictAt: Date? = nil
        ) {
            self.confidence = confidence
            self.route = route
            self.state = state
            self.options = options
            self.verdict = verdict
            self.verdictAt = verdictAt
        }

        /// The option a campaign was offered as (`c2`), nil when it was not offered.
        public func option(of campaign: String?) -> String? {
            guard let campaign,
                  let index = options.firstIndex(of: campaign) else { return campaign == nil ? "new" : nil }
            return "c\(index + 1)"
        }
    }

    public init(
        id: String, parent: String? = nil, kind: Kind, title: String, intent: String? = nil, stage: Stage? = nil,
        synopsis: String? = nil, synopsisStale: Bool = false, entry: String? = nil, decisions: [Decision] = [],
        open: [OpenItem] = [], madeBy: MadeBy = .heed, suggested: Bool = false, placement: Placement? = nil,
        createdAt: Date, updatedAt: Date? = nil
    ) {
        self.id = id
        self.parent = parent
        self.kind = kind
        self.title = title
        self.intent = intent
        self.stage = stage
        self.synopsis = synopsis
        self.synopsisStale = synopsisStale
        self.entry = entry
        self.decisions = decisions
        self.open = open
        self.madeBy = madeBy
        self.suggested = suggested
        self.placement = placement
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
    }

    /// A work node for a ledger entry: its decisions and follow-ups, as the entry wrote them.
    public static func work(_ entry: LedgerEntry, parent: String?, now: Date) -> MindNode {
        MindNode(
            id: "work:\(entry.id)", parent: parent, kind: .work, title: entry.title, synopsis: entry.summary,
            entry: entry.id,
            decisions: entry.decisions.map { Decision(text: $0, source: entry.id) },
            open: entry.followUps.map { OpenItem(text: $0, source: entry.id) },
            createdAt: now
        )
    }

    /// Open items nobody resolved yet.
    public var stillOpen: [OpenItem] { open.filter { $0.resolvedBy == nil } }

    /// Decisions nothing replaced.
    public var standing: [Decision] { decisions.filter { $0.supersededBy == nil } }
}
