import Foundation

/// Where a new piece of work goes in its Mindmap, and what it changes there. The words settle the clear cases; the
/// rest is one Decider call sized for Hunch (at most four campaigns and "new", options of a few characters), so it
/// usually runs on this Mac for free.
public enum MindmapPlace {
    /// The outcome, and what was asked to reach it.
    public struct Placed: Hashable, Sendable {
        public var outcome: Outcome
        public var state: String?
        public var options: [String]
    }

    public enum Outcome: Hashable, Sendable {
        /// The work continues `campaign`. `sure`: heed places it on its own; otherwise it waits as a suggestion.
        case campaign(String, confidence: Double, route: String, sure: Bool)
        /// None of them: it waits in Unsorted until heed names a campaign for it (or you place it).
        case new(confidence: Double, route: String)
    }

    /// At or above: the same campaign without asking. Below `differentBelow`: new without asking.
    public static let sameAbove = 0.75
    public static let differentBelow = 0.1
    /// An answer at least this sure places the work on its own; below, it is a suggestion (`y` takes it).
    public static let sureAbove = 0.7
    /// Hunch takes at most five options: four campaigns and "new".
    public static let shortlist = 4
    /// Statements checked per new piece of work: "resolves this follow-up", "contradicts this decision".
    public static let maxChecks = 6
    /// A check holds at this probability or more.
    public static let checkHolds = 0.8

    /// How alike a piece of work is to a campaign, 0–1: the better of its words (title, branch) against the
    /// campaign's title and its work's titles, and the files they share.
    public static func affinity(
        _ entry: LedgerEntry,
        to campaign: MindNode,
        in tree: MindmapTree,
        ledger: [String: LedgerEntry]
    )
        -> Double
    {
        let members = tree.entries(under: campaign.id).compactMap { ledger[$0] }
        let words = "\(entry.title) \(entry.branch)"
        let titles = ([campaign.title] + members.map { "\($0.title) \($0.branch)" })
        let byWords = titles.map { GoalItemMatch.similarity(words, $0) }.max() ?? 0
        let theirs = Set(members.flatMap(\.files))
        let mine = Set(entry.files)
        let byFiles = mine.isEmpty || theirs.isEmpty ? 0
            : Double(mine.intersection(theirs).count) / Double(min(mine.count, theirs.count))
        return max(byWords, byFiles)
    }

    /// The campaigns closest to `entry`, closest first, with how close.
    public static func candidates(for entry: LedgerEntry, in tree: MindmapTree, ledger: [String: LedgerEntry])
        -> [(MindNode, Double)]
    {
        tree.campaigns.map { ($0, affinity(entry, to: $0, in: tree, ledger: ledger)) }
            .sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.updatedAt > $1.0.updatedAt }
    }

    /// The decision without a model: sure matches and sure misses; nil when it is close enough to ask.
    public static func quick(_ scored: [(MindNode, Double)]) -> Outcome? {
        guard let best = scored.first else { return .new(confidence: 1, route: "words") }
        if best.1 >= sameAbove { return .campaign(best.0.id, confidence: best.1, route: "words", sure: true) }
        if best.1 < differentBelow { return .new(confidence: 1 - best.1, route: "words") }
        return nil
    }

    /// What the Decider reads: the work, then each candidate by its short id.
    public static func state(for entry: LedgerEntry, candidates: [MindNode]) -> String {
        var lines = ["New work: \(entry.title)"]
        if let summary = entry.summary { lines.append("What it did: \(summary)") }
        if !entry.files.isEmpty { lines.append("Files: \(entry.files.prefix(5).joined(separator: ", "))") }
        lines.append("Campaigns:")
        for (index, campaign) in candidates.enumerated() {
            let about = campaign.intent ?? campaign.synopsis ?? ""
            lines.append("- c\(index + 1): \(campaign.title)\(about.isEmpty ? "" : ". \(about)")")
        }
        return HunchTrainingSet.trimmed(lines.joined(separator: "\n"), keepEnd: false)
    }

    public static func question(candidates: Int) -> Question {
        .choice(
            instructions: "The new work continues one of the campaigns (pick its id), or it starts something new (new).",
            options: (1 ... max(1, candidates)).map { "c\($0)" } + ["new"]
        )
    }

    /// The placement, asking `decider` when the words alone do not settle it. With no decider, or a failed call,
    /// the closest campaign is suggested when it is at least half alike, so nothing is placed on a guess.
    public static func decide(
        _ entry: LedgerEntry, in tree: MindmapTree, ledger: [String: LedgerEntry], decider: (any Decider)?,
        route: String = "model"
    ) async -> Placed {
        let scored = candidates(for: entry, in: tree, ledger: ledger)
        if let quick = quick(scored) { return Placed(outcome: quick, state: nil, options: []) }
        let shortlist = Array(scored.prefix(shortlist))
        let fallback: Outcome = if let closest = shortlist.first, closest.1 >= 0.5 {
            .campaign(closest.0.id, confidence: closest.1, route: "words", sure: false)
        } else {
            .new(confidence: 0.5, route: "words")
        }
        let state = state(for: entry, candidates: shortlist.map(\.0))
        let options = shortlist.map(\.0.id)
        guard let decider else { return Placed(outcome: fallback, state: state, options: options) }
        let answers = try? await decider.decide(
            subject: "mindmap:\(entry.id)", state: state, questions: ["place": question(candidates: shortlist.count)]
        )
        let outcome: Outcome = {
            guard let answer = answers?["place"], let choice = answer.choice else { return fallback }
            let confidence = answer.probabilities[choice] ?? answer.confidence
            if choice == "new" { return .new(confidence: confidence, route: route) }
            guard let index = Int(choice.dropFirst()), (1 ... shortlist.count).contains(index) else { return fallback }
            return .campaign(
                shortlist[index - 1].0.id, confidence: confidence, route: route, sure: confidence >= sureAbove
            )
        }()
        return Placed(outcome: outcome, state: state, options: options)
    }

    /// Puts `entry` where `placed` says: its work node is made, or kept (where you put it stays where you put it),
    /// and its decisions and follow-ups follow what the entry says now.
    @discardableResult
    public static func record(
        _ entry: LedgerEntry,
        placed: Placed?,
        in tree: inout MindmapTree,
        now: Date
    ) -> MindNode {
        var node = tree.work(for: entry.id) ?? MindNode.work(entry, parent: nil, now: now)
        let fresh = MindNode.work(entry, parent: nil, now: now)
        node.title = entry.title
        if node.madeBy != .you { node.synopsis = entry.summary }
        // Keep what was marked on decisions and follow-ups that are still there.
        node.decisions = fresh.decisions.map { decision in
            node.decisions.first { $0.text == decision.text } ?? decision
        }
        node.open = fresh.open.map { item in node.open.first { $0.text == item.text } ?? item }
        node.updatedAt = now
        if let placed, node.madeBy != .you {
            switch placed.outcome {
            case let .campaign(campaign, confidence, route, sure):
                node.parent = campaign
                node.suggested = !sure
                node.placement = .init(
                    confidence: confidence, route: route, state: placed.state, options: placed.options
                )
            case let .new(confidence, route):
                node.parent = nil
                node.suggested = false
                node.placement = .init(
                    confidence: confidence, route: route, state: placed.state, options: placed.options
                )
            }
        }
        tree.upsert(node)
        tree.markStale(above: node.id, now: now)
        return node
    }

    // MARK: What the new work changes

    /// One statement to check against the new work.
    public struct Check: Hashable, Sendable {
        public enum Kind: String, Hashable, Sendable { case resolves, contradicts }
        public var kind: Kind
        /// The node the follow-up or decision sits on.
        public var node: String
        public var text: String
        public var statement: String
    }

    /// The statements worth checking: the campaign's open follow-ups and standing decisions, newest work first, at
    /// most `maxChecks`, never the new work's own.
    public static func checks(for entry: LedgerEntry, campaign: String, in tree: MindmapTree) -> [Check] {
        let nodes = ([tree[campaign]].compactMap(\.self) + tree.descendants(of: campaign))
            .filter { $0.entry != entry.id }
            .sorted { $0.updatedAt > $1.updatedAt }
        var checks: [Check] = []
        for node in nodes {
            for item in node.stillOpen {
                checks.append(Check(
                    kind: .resolves, node: node.id, text: item.text,
                    statement: "The new work does this earlier follow-up: \(item.text)"
                ))
            }
            for decision in node.standing {
                checks.append(Check(
                    kind: .contradicts, node: node.id, text: decision.text,
                    statement: "The new work goes against this earlier decision: \(decision.text)"
                ))
            }
        }
        return Array(checks.prefix(maxChecks))
    }

    /// The checks that hold, asked as yes/no statements (Hunch always takes those).
    public static func confirm(_ checks: [Check], entry: LedgerEntry, decider: (any Decider)?) async -> [Check] {
        guard let decider, !checks.isEmpty else { return [] }
        let state = HunchTrainingSet.trimmed([
            "New work: \(entry.title)", entry.summary.map { "What it did: \($0)" },
            entry.decisions.isEmpty ? nil : "Its decisions: " + entry.decisions.joined(separator: "; "),
        ].compactMap(\.self).joined(separator: "\n"), keepEnd: false)
        var questions: [String: Question] = [:]
        for (index, check) in checks.enumerated() {
            questions["check\(index + 1)"] = .noul(instructions: check.statement)
        }
        guard let answers = try? await decider.decide(
            subject: "mindmap:\(entry.id)",
            state: state,
            questions: questions
        )
        else { return [] }
        return checks.enumerated().compactMap { index, check in
            (answers["check\(index + 1)"]?.probability ?? 0) >= checkHolds ? check : nil
        }
    }

    /// Applies what holds: follow-ups the new work did are resolved by it; decisions it went against are superseded
    /// by its first decision (or its title).
    public static func apply(_ held: [Check], entry: LedgerEntry, to tree: inout MindmapTree, now: Date) {
        for check in held {
            switch check.kind {
            case .resolves:
                tree.resolve(check.text, in: check.node, by: entry.id, now: now)
            case .contradicts:
                guard var node = tree[check.node],
                      let index = node.decisions.firstIndex(where: { $0.text == check.text }) else { continue }
                node.decisions[index].supersededBy = entry.decisions.first ?? entry.title
                node.updatedAt = now
                tree.upsert(node)
            }
        }
    }

    // MARK: Stage

    public static let stageQuestion = Question.score(
        instructions: "How far along the campaign is, from its latest work.",
        levels: MindNode.Stage.allCases.map(\.rawValue)
    )

    /// What the stage is read from: the campaign and its newest work, newest first.
    public static func stageState(of campaign: String, in tree: MindmapTree, ledger: [String: LedgerEntry]) -> String {
        guard let node = tree[campaign] else { return "" }
        let work = tree.entries(under: campaign).compactMap { ledger[$0] }.sorted { $0.updatedAt > $1.updatedAt }
        let lines = ["Campaign: \(node.title)"] + work.prefix(6).map { entry in
            "- \(entry.title) (\(entry.outcome))\(entry.summary.map { ": \($0)" } ?? "")"
        }
        return HunchTrainingSet.trimmed(lines.joined(separator: "\n"), keepEnd: false)
    }

    public static func stage(
        of campaign: String,
        in tree: MindmapTree,
        ledger: [String: LedgerEntry],
        decider: (any Decider)?
    )
        async -> MindNode.Stage?
    {
        guard let decider else { return nil }
        let answers = try? await decider.decide(
            subject: "mindmap:\(campaign)", state: stageState(of: campaign, in: tree, ledger: ledger),
            questions: ["stage": stageQuestion]
        )
        return answers?["stage"]?.choice.flatMap(MindNode.Stage.init(rawValue:))
    }
}
