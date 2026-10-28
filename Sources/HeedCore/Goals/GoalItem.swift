import Foundation

/// A piece of a goal's work: a row of the overview's matrix and a card on its board. Items are discovered more than
/// typed in: the planner breaks GOAL.md into them, sessions and chats on the goal add what they find, PRs and reviewers
/// add theirs, and you add one by hand. Where an item stands is never ticked off: it follows from its evidence
/// (`Stages.of`, `Board.column`), and moving a card by hand holds only until new evidence moves it.
public struct GoalItem: Hashable, Sendable, Codable, Identifiable {
    /// Who put it on the goal.
    public enum Source: String, Hashable, Sendable, Codable, CaseIterable {
        case you, planner, session, pr, reviewer, chat, swarm, subagent
    }

    /// Work to do, or a question to answer (a question sits in To explore until a decision answers it).
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case work, question
    }

    /// Something the item is about: a session or chat working on it, its branch, its PR, a review, a run.
    public struct Link: Hashable, Sendable, Codable {
        public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
            case session, chat, branch, pr, review, run
        }

        public var kind: Kind
        /// A session or chat id, a branch name, `org/repo#n` for a PR, a review's or a run's id.
        public var target: String

        public init(_ kind: Kind, _ target: String) {
            self.kind = kind
            self.target = target
        }
    }

    /// A card moved by hand: the column it was put in, and when (later evidence moves it on).
    public struct Placement: Hashable, Sendable, Codable {
        public var column: Board.Column
        public var at: Date

        public init(_ column: Board.Column, at: Date) {
            self.column = column
            self.at = at
        }
    }

    /// Who works on a swarm task: an agent, and the model it runs on (nil: the agent's own default).
    public struct Owner: Hashable, Sendable, Codable {
        public var agent: String
        public var model: String?

        public init(agent: String, model: String? = nil) {
            self.agent = agent
            self.model = model?.isEmpty == true ? nil : model
        }

        /// `claude`, `claude · opus`.
        public var label: String { model.map { "\(agent) · \($0)" } ?? agent }
    }

    /// `<goal>/<slug>`: unique across goals, stable, never reused within its goal.
    public var id: String
    public var goal: String
    public var title: String
    public var kind: Kind
    public var source: Source
    /// The item it was split from, or that an agent split it from.
    public var parent: String?
    public var links: [Link]
    /// Moved by hand, if it was.
    public var placement: Placement?
    /// How sure heed was that this is new work on the goal, 0–1, for items it found itself; nil for yours.
    public var confidence: Double?
    /// Why it is here, in words ("follow-up in Fix anchors", "from GOAL.md v3").
    public var reason: String?
    public var createdAt: Date
    /// The sub-issue it mirrors to on GitHub, once it does.
    public var issueNumber: Int?
    /// A swarm task's owner: the agent (and model) that works on it.
    public var owner: Owner?
    /// The items it waits for (ids): a swarm task starts once these are done, and stacks on their PRs.
    public var after: [String]
    /// How long it should take, in minutes, as the swarm's lead estimated it.
    public var estimate: Int?
    /// How we will know it is done: checks its evidence must show.
    public var doneWhen: [String]
    /// The plan's phase it is in (`Survey`, `Core change`), for the outline.
    public var phase: String?

    public init(
        id: String, goal: String, title: String, kind: Kind = .work, source: Source, parent: String? = nil,
        links: [Link] = [], placement: Placement? = nil, confidence: Double? = nil, reason: String? = nil,
        createdAt: Date, issueNumber: Int? = nil, owner: Owner? = nil, after: [String] = [], estimate: Int? = nil,
        doneWhen: [String] = [], phase: String? = nil
    ) {
        self.id = id
        self.goal = goal
        self.title = title
        self.kind = kind
        self.source = source
        self.parent = parent
        self.links = links
        self.placement = placement
        self.confidence = confidence
        self.reason = reason
        self.createdAt = createdAt
        self.issueNumber = issueNumber
        self.owner = owner
        self.after = after
        self.estimate = estimate
        self.doneWhen = doneWhen
        self.phase = phase
    }

    private enum CodingKeys: String, CodingKey {
        case id, goal, title, kind, source, parent, links, placement, confidence, reason, createdAt, issueNumber
        case owner, after, estimate, doneWhen, phase
    }

    /// Rows written before swarms decode unchanged: the swarm fields are absent there, and empty here.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        goal = try values.decode(String.self, forKey: .goal)
        title = try values.decode(String.self, forKey: .title)
        kind = try values.decode(Kind.self, forKey: .kind)
        source = try values.decode(Source.self, forKey: .source)
        parent = try values.decodeIfPresent(String.self, forKey: .parent)
        links = try values.decode([Link].self, forKey: .links)
        placement = try values.decodeIfPresent(Placement.self, forKey: .placement)
        confidence = try values.decodeIfPresent(Double.self, forKey: .confidence)
        reason = try values.decodeIfPresent(String.self, forKey: .reason)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        issueNumber = try values.decodeIfPresent(Int.self, forKey: .issueNumber)
        owner = try values.decodeIfPresent(Owner.self, forKey: .owner)
        after = try values.decodeIfPresent([String].self, forKey: .after) ?? []
        estimate = try values.decodeIfPresent(Int.self, forKey: .estimate)
        doneWhen = try values.decodeIfPresent([String].self, forKey: .doneWhen) ?? []
        phase = try values.decodeIfPresent(String.self, forKey: .phase)
    }

    public func linked(_ kind: Link.Kind) -> [String] { links.filter { $0.kind == kind }.map(\.target) }

    /// The item's slug, without its goal.
    public var slug: String { id.split(separator: "/", maxSplits: 1).last.map(String.init) ?? id }
}

/// What showed something about a goal or one of its items: a plan, a review, a build, a benchmark, a PR, a merge, a
/// decision, a question, a criterion met. Evidence is only ever added; the newest of a kind is what counts.
///
/// The kinds are generic on purpose: reviewers, evaluations and the GitHub mirror add theirs through
/// `GoalOps.addEvidence` with the same shape.
public struct GoalEvidence: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        /// The item is in a plan (the planner's, a swarm's, yours).
        case plan
        /// A reviewer read the plan.
        case planReview
        /// Code exists for it: a session worked on it, a commit, a build.
        case built
        /// A code review (a reviewer agent, or a person on the PR).
        case codeReview
        /// A benchmark or perf probe.
        case perf
        /// A developer-experience walk (first run, API, docs).
        case dx
        /// A user-experience walk (the screens, accessibility): no matrix column of its own.
        case ux
        /// A PR for it: opened, updated, its checks.
        case pr
        /// Its PR merged.
        case merged
        /// A decision taken (goal-level, or answering a question item).
        case decision
        /// A question raised.
        case question
        /// A done-when criterion met.
        case criterion
    }

    /// How it came out: done (passed, met, merged), still going, or a problem (failing checks, a high objection).
    public enum State: String, Hashable, Sendable, Codable, CaseIterable {
        case done, inProgress, issue
    }

    /// Its row in `goals.sqlite`; nil until stored.
    public var id: Int64?
    public var goal: String
    /// The item it is about; nil for the goal as a whole.
    public var item: String?
    public var kind: Kind
    public var state: State
    public var at: Date
    /// Who or what produced it: `session s1`, `acme/docs#12`, `perf prober`, `you`.
    public var source: String
    /// What it says, in a line.
    public var text: String
    /// What it points at, for ↩: a PR (`org/repo#n`), a session id, a URL.
    public var ref: String?
    /// A score it carries, 0–10, when it has one (a review, an evaluation).
    public var score: Double?

    public init(
        id: Int64? = nil, goal: String, item: String? = nil, kind: Kind, state: State = .done, at: Date,
        source: String, text: String = "", ref: String? = nil, score: Double? = nil
    ) {
        self.id = id
        self.goal = goal
        self.item = item
        self.kind = kind
        self.state = state
        self.at = at
        self.source = source
        self.text = text
        self.ref = ref
        self.score = score
    }

    /// Two pieces of evidence that say the same thing: adding the second is a no-op.
    public func same(as other: GoalEvidence) -> Bool {
        goal == other.goal && item == other.item && kind == other.kind && state == other.state && ref == other.ref
            && source == other.source && text == other.text
    }
}

/// The stages an item goes through, left to right in the overview's matrix.
public enum Stage: String, Hashable, Sendable, Codable, CaseIterable {
    case plan, planReview, built, codeReview, perf, dx, pr, merged

    /// The matrix's column heading.
    public var title: String {
        switch self {
        case .plan: "plan"
        case .planReview: "plan rev"
        case .built: "built"
        case .codeReview: "code rev"
        case .perf: "perf"
        case .dx: "DX"
        case .pr: "PR"
        case .merged: "merged"
        }
    }

    /// The stages a quality lens decides: a goal that does not need one shows it as n/a.
    public static let lenses: Set<Stage> = [.planReview, .codeReview, .perf, .dx]

    /// The evidence that fills it.
    public var evidence: GoalEvidence.Kind {
        switch self {
        case .plan: .plan
        case .planReview: .planReview
        case .built: .built
        case .codeReview: .codeReview
        case .perf: .perf
        case .dx: .dx
        case .pr: .pr
        case .merged: .merged
        }
    }
}

/// Where an item is in one stage.
public enum StageMark: String, Hashable, Sendable, Codable, CaseIterable {
    case done, inProgress, issue, notYet, notApplicable

    /// ✓ done, ◐ in progress, ! issue, ○ not yet, · n/a.
    public var glyph: String {
        switch self {
        case .done: "✓"
        case .inProgress: "◐"
        case .issue: "!"
        case .notYet: "○"
        case .notApplicable: "·"
        }
    }

    public var word: String {
        switch self {
        case .done: "done"
        case .inProgress: "in progress"
        case .issue: "issue"
        case .notYet: "not yet"
        case .notApplicable: "n/a"
        }
    }
}

public enum Stages {
    /// Each stage of `item`, from the evidence about it. The newest evidence of a stage's kind decides it; a later
    /// stage done implies the ones it cannot happen without (a merge implies a PR, a PR implies something built; an
    /// item the planner made is planned). Lens stages not in `requiredLenses` are n/a, whatever their evidence.
    public static func of(
        _ item: GoalItem, evidence: [GoalEvidence], requiredLenses: Set<Stage> = Stage.lenses
    ) -> [Stage: StageMark] {
        let mine = evidence.filter { $0.item == item.id }
        var latest: [GoalEvidence.Kind: GoalEvidence] = [:]
        for entry in mine {
            if let current = latest[entry.kind], !newer(entry, than: current) { continue }
            latest[entry.kind] = entry
        }
        var marks: [Stage: StageMark] = [:]
        for stage in Stage.allCases {
            if Stage.lenses.contains(stage), !requiredLenses.contains(stage) {
                marks[stage] = .notApplicable
                continue
            }
            marks[stage] = latest[stage.evidence].map { mark($0.state) } ?? .notYet
        }
        if marks[.merged] == .done { marks[.pr] = .done }
        if marks[.pr] != .notYet, marks[.built] != .done, marks[.built] != .issue { marks[.built] = .done }
        if item.source == .planner || item.source == .swarm, marks[.plan] == .notYet { marks[.plan] = .done }
        return marks
    }

    static func mark(_ state: GoalEvidence.State) -> StageMark {
        switch state {
        case .done: .done
        case .inProgress: .inProgress
        case .issue: .issue
        }
    }

    /// Later evidence wins; at the same moment, the one stored later.
    public static func newer(_ entry: GoalEvidence, than other: GoalEvidence) -> Bool {
        entry.at != other.at ? entry.at > other.at : (entry.id ?? .max) >= (other.id ?? .max)
    }
}

/// A goal as a board: what we know, what is running, what is unknown.
public enum Board {
    public enum Column: String, Hashable, Sendable, Codable, CaseIterable {
        case toExplore, planned, working, verify, done

        public var title: String {
            switch self {
            case .toExplore: "To explore"
            case .planned: "Planned"
            case .working: "Working"
            case .verify: "Verify"
            case .done: "Done"
            }
        }

        /// The word `goal.item.move` takes for it.
        public var word: String { self == .toExplore ? "explore" : rawValue }

        /// A column from `goal.item.move`'s word: its name, or the start of its title.
        public init?(word: String) {
            let key = word.lowercased()
            guard !key.isEmpty,
                  let found = Column.allCases.first(where: {
                      $0.word == key || $0.title.lowercased().hasPrefix(key) || $0.rawValue.lowercased() == key
                  })
            else { return nil }
            self = found
        }

        /// The next column left or right, if there is one.
        public func step(_ delta: Int) -> Column? {
            let all = Column.allCases
            guard let index = all.firstIndex(of: self), all.indices.contains(index + delta) else { return nil }
            return all[index + delta]
        }
    }

    /// Where `item` sits. From its evidence: merged (or a question answered by a decision) is Done; a PR, or something
    /// built that a reviewer is looking at, is Verify; something being built is Working; a question is To explore;
    /// planned work is Planned; the rest is To explore. Moved by hand, it stays where it was put until evidence about
    /// it
    /// newer than the move arrives.
    public static func column(_ item: GoalItem, evidence: [GoalEvidence]) -> Column {
        let mine = evidence.filter { $0.item == item.id }
        if let placement = item.placement, !mine.contains(where: { $0.at > placement.at }) { return placement.column }
        return derived(item, evidence: mine)
    }

    /// The column from evidence alone (no hand placement).
    static func derived(_ item: GoalItem, evidence mine: [GoalEvidence]) -> Column {
        let marks = Stages.of(item, evidence: mine)
        if marks[.merged] == .done { return .done }
        if item.kind == .question {
            return mine.contains { $0.kind == .decision && $0.state == .done } ? .done : .toExplore
        }
        if marks[.pr] != .notYet { return .verify }
        let reviewed = [Stage.codeReview, .perf, .dx].contains { marks[$0] != .notYet && marks[$0] != .notApplicable }
        if marks[.built] == .done, reviewed { return .verify }
        if marks[.built] != .notYet || !item.linked(.session).isEmpty { return .working }
        if marks[.plan] != .notYet || item.source == .you || item.source == .reviewer { return .planned }
        return .toExplore
    }

    /// The items in each column, in the order they were added.
    public static func columns(_ items: [GoalItem], evidence: [GoalEvidence]) -> [Column: [GoalItem]] {
        var result: [Column: [GoalItem]] = Dictionary(uniqueKeysWithValues: Column.allCases.map { ($0, []) })
        for item in items.sorted(by: { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }) {
            result[column(item, evidence: evidence), default: []].append(item)
        }
        return result
    }

    /// The badge a card wears: what the item mostly is right now.
    public enum Badge: String, Hashable, Sendable, CaseIterable {
        case question, session, chat, pr, review, bench, swarm, item

        public var title: String { self == .pr ? "PR" : rawValue.uppercased() }
    }

    public static func badge(_ item: GoalItem, evidence: [GoalEvidence]) -> Badge {
        if item.kind == .question { return .question }
        let mine = evidence.filter { $0.item == item.id }.sorted { Stages.newer($1, than: $0) }
        if let last = mine.last {
            switch last.kind {
            case .pr, .merged: return .pr
            case .codeReview, .planReview, .dx, .ux: return .review
            case .perf: return .bench
            default: break
            }
        }
        if !item.linked(.pr).isEmpty { return .pr }
        if item.source == .swarm { return .swarm }
        if !item.linked(.session).isEmpty { return .session }
        if !item.linked(.chat).isEmpty || item.source == .chat { return .chat }
        return .item
    }
}

/// Dragging a card between the board's columns: which column the pointer is over.
public enum BoardDrag {
    /// The column a card from column `from`, dragged `offset` points sideways on a board of columns `width` wide with
    /// `spacing` between them, lands in: past the middle of the gap to a neighbour, it is that neighbour's.
    public static func target(from: Int, by offset: Double, width: Double, spacing: Double, count: Int) -> Int {
        guard count > 0, width > 0 else { return from }
        let pitch = width + spacing
        let centre = Double(from) * pitch + width / 2 + offset
        let index = Int((centre + spacing / 2) / pitch)
        return min(max(centre < 0 ? 0 : index, 0), count - 1)
    }
}

public extension GoalItem {
    /// What Start work opens with for this item: the item, its goal, and where the goal is written down.
    func workPrompt(goal: String, doc path: String) -> String {
        let what = kind == .question ? "Find out: \(title)" : title
        return "\(what)\n\nThis is one item of the goal \(goal); its GOAL.md is \(path)."
    }
}
