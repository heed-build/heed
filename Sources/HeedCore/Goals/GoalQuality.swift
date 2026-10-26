import Foundation

/// A reviewer on a goal, as spawned: what kind, what it is told, when it looks again and what it runs as.
public struct ReviewerConfig: Hashable, Sendable, Codable, Identifiable {
    /// `<kind>` for the one of each kind heed spawns for a required lens; `<kind>-<n>` for more.
    public var id: String
    public var kind: ReviewerKind
    /// A custom reviewer's own instructions (a persona, later).
    public var instructions: String?
    public var policy: ReviewPolicy
    /// The agent it runs as; nil: `[goals] reviewer_agent`, else the goal's sessions' agent.
    public var agent: String?
    /// nil: `[goals.reviewers]` for its kind, else the kind's default.
    public var tier: ModelTier?
    /// Taken off the goal: kept for its history, never run again.
    public var removed: Bool

    public init(
        id: String, kind: ReviewerKind, instructions: String? = nil, policy: ReviewPolicy = .onChange,
        agent: String? = nil, tier: ModelTier? = nil, removed: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.instructions = instructions
        self.policy = policy
        self.agent = agent
        self.tier = tier
        self.removed = removed
    }

    public var title: String {
        kind == .custom ? (instructions.map { "Custom: " + String($0.prefix(30)) } ?? kind.title) : kind.title
    }
}

/// What a review looked at: the GOAL.md version and each PR's head. A reviewer at its bar runs again only when this
/// moved (new evidence).
public struct ReviewBasis: Hashable, Sendable, Codable {
    public var goalVersion: Int
    /// `org/repo#n@sha`, sorted.
    public var heads: [String]

    public init(goalVersion: Int, heads: [String]) {
        self.goalVersion = goalVersion
        self.heads = heads.sorted()
    }

    /// `v3 · acme/docs#12@1a2b3c4`.
    public var text: String {
        (["v\(goalVersion)"] + heads.map { head in
            guard let at = head.firstIndex(of: "@") else { return head }
            return head[..<at] + "@" + head[head.index(after: at)...].prefix(7)
        }).joined(separator: " · ")
    }
}

/// One row of a goal's quality record (`goal_reviews`, JSON in `data`). Everything about profiles, reviewers and
/// their objections is a fold over these, oldest first, so nothing is overwritten and every change can be undone.
public enum QualityEntry: Hashable, Sendable, Codable {
    /// A profile decided (by a model, or by you), for a GOAL.md version, and the bars it set.
    case profile(ProfileDecision)
    /// Your bars for this goal, laid over the table: lens → bar, 0 to take a lens off.
    case pins([GoalLens: Double])
    /// A reviewer spawned, changed or taken off.
    case reviewer(ReviewerConfig)
    /// A reviewer run started (it counts on the day's budget).
    case run(ReviewRunStart)
    /// A reviewer run ended: what it wrote, or why it wrote nothing.
    case review(ReviewResult)
    /// You set an objection's state: accepted the risk, or opened it again.
    case action(ObjectionAction)
    /// heed marked the goal done (or you undid that).
    case done(DoneMark)

    /// The `kind` column.
    public var kind: String {
        switch self {
        case .profile: "profile"
        case .pins: "pins"
        case .reviewer: "reviewer"
        case .run: "run"
        case .review: "review"
        case .action: "action"
        case .done: "done"
        }
    }
}

public struct ProfileDecision: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        case model, you
    }

    public var profile: GoalProfile
    public var bars: [GoalLens: Double]
    public var changes: [BarChange]
    /// `public-api · user-facing → DX first run now 8 (was –)`.
    public var note: String
    public var goalVersion: Int
    public var source: Source

    public init(
        profile: GoalProfile, bars: [GoalLens: Double], changes: [BarChange], note: String, goalVersion: Int,
        source: Source = .model
    ) {
        self.profile = profile
        self.bars = bars
        self.changes = changes
        self.note = note
        self.goalVersion = goalVersion
        self.source = source
    }
}

public struct ReviewRunStart: Hashable, Sendable, Codable {
    public var id: String
    public var reviewer: String
    public var trigger: ReviewTrigger
    public var basis: ReviewBasis
    /// `claude`, `codex` …, and the model it was asked for.
    public var agent: String
    public var model: String?

    public init(
        id: String, reviewer: String, trigger: ReviewTrigger, basis: ReviewBasis, agent: String, model: String? = nil
    ) {
        self.id = id
        self.reviewer = reviewer
        self.trigger = trigger
        self.basis = basis
        self.agent = agent
        self.model = model
    }
}

public struct ReviewResult: Hashable, Sendable, Codable {
    public var run: String
    public var reviewer: String
    public var basis: ReviewBasis
    /// nil: it wrote no review (`failure` says why).
    public var report: ReviewReport?
    public var failure: String?
    /// Raised index → known objection id, as a model matched them (`ObjectionMatch.ask`).
    public var pairs: [Int: String]

    public init(
        run: String, reviewer: String, basis: ReviewBasis, report: ReviewReport?, failure: String? = nil,
        pairs: [Int: String] = [:]
    ) {
        self.run = run
        self.reviewer = reviewer
        self.basis = basis
        self.report = report
        self.failure = failure
        self.pairs = pairs
    }
}

public struct ObjectionAction: Hashable, Sendable, Codable {
    public var reviewer: String
    public var objection: String
    public var state: Objection.State

    public init(reviewer: String, objection: String, state: Objection.State) {
        self.reviewer = reviewer
        self.objection = objection
        self.state = state
    }
}

public struct DoneMark: Hashable, Sendable, Codable {
    /// false: you undid it.
    public var done: Bool
    /// What was true when it was marked: undoing holds until this changes.
    public var basis: String

    public init(done: Bool, basis: String) {
        self.done = done
        self.basis = basis
    }
}

/// A stored entry: when, and what.
public struct QualityRecord: Hashable, Sendable {
    public var goal: String
    public var at: Date
    public var entry: QualityEntry

    public init(goal: String, at: Date, entry: QualityEntry) {
        self.goal = goal
        self.at = at
        self.entry = entry
    }
}

/// A reviewer as it stands: its config, its objections, its score now and before, and its last run.
public struct ReviewerState: Hashable, Sendable, Identifiable {
    public var config: ReviewerConfig
    public var objections: [Objection]
    /// nil until a review came back.
    public var score: GoalScore?
    /// Its score after each review, oldest first.
    public var history: [Double]
    public var lastReview: ReviewResult?
    public var lastReviewAt: Date?
    public var lastRun: ReviewRunStart?
    public var lastRunAt: Date?
    public var summary: String

    public var id: String { config.id }
    public var open: [Objection] { objections.filter { $0.state == .open } }

    /// The change since the review before: + better, − worse, nil with fewer than two.
    public var trend: Double? {
        guard history.count >= 2 else { return nil }
        return GoalScore.rounded(history[history.count - 1] - history[history.count - 2])
    }

    /// A run started and nothing came back yet.
    public var running: Bool {
        guard let lastRun else { return false }
        return lastReview?.run != lastRun.id
    }

    /// Objections in the order the detail lists them: open first, then accepted, then fixed; worst first in each.
    public var ordered: [Objection] {
        let rank: [Objection.State: Int] = [.open: 0, .acceptedRisk: 1, .fixed: 2]
        return objections.sorted {
            rank[$0.state]! != rank[$1.state]! ? rank[$0.state]! < rank[$1.state]!
                : $0.severity != $1.severity ? $0.severity < $1.severity : $0.firstSeen < $1.firstSeen
        }
    }
}

/// A goal's quality, folded from its record: the profile and bars, the reviewers, each required lens against its bar,
/// the confidence and whether the goal is done.
public struct GoalQuality: Hashable, Sendable {
    public var profile: ProfileDecision?
    /// Every profile decision, oldest first: the bar changes and their notes.
    public var profiles: [ProfileDecision]
    public var pins: [GoalLens: Double]
    public var reviewers: [ReviewerState]
    public var lenses: [GoalScore.Lens]
    public var confidence: GoalScore?
    public var done: (done: Bool, missing: [String])
    public var doneMark: DoneMark?
    public var doneAt: Date?
    /// Runs started today (the budget), and when each started.
    public var runs: [Date]

    public static func == (lhs: GoalQuality, rhs: GoalQuality) -> Bool {
        lhs.profile == rhs.profile && lhs.profiles == rhs.profiles && lhs.pins == rhs.pins
            && lhs.reviewers == rhs.reviewers && lhs.lenses == rhs.lenses && lhs.confidence == rhs.confidence
            && lhs.done.done == rhs.done.done && lhs.done.missing == rhs.done.missing
            && lhs.doneMark == rhs.doneMark && lhs.doneAt == rhs.doneAt && lhs.runs == rhs.runs
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(reviewers)
        hasher.combine(confidence)
    }

    public static let empty = GoalQuality(
        profile: nil, profiles: [], pins: [:], reviewers: [], lenses: [], confidence: nil,
        done: (false, []), doneMark: nil, doneAt: nil, runs: []
    )

    /// The bars now: the latest profile's (the table's for an unknown profile), with the pins over them.
    public static func bars(profile: ProfileDecision?, pins: [GoalLens: Double], table: GoalBarTable)
        -> [GoalLens: Double]
    {
        (profile?.profile ?? .unknown).bars(table, pins: pins)
    }

    /// Folds `records` (oldest first) with the goal's current GOAL.md.
    public static func fold(_ records: [QualityRecord], doc: GoalDoc?, table: GoalBarTable = .defaults)
        -> GoalQuality
    {
        var profiles: [ProfileDecision] = []
        var pins: [GoalLens: Double] = [:]
        var configs: [String: ReviewerConfig] = [:]
        var order: [String] = []
        var states: [String: ReviewerState] = [:]
        var runs: [Date] = []
        var doneMark: DoneMark?
        var doneAt: Date?
        for record in records.sorted(by: { $0.at < $1.at }) {
            switch record.entry {
            case let .profile(decision): profiles.append(decision)
            case let .pins(new): pins = new
            case let .reviewer(config):
                if configs[config.id] == nil { order.append(config.id) }
                configs[config.id] = config
                var state = states[config.id] ?? ReviewerState(
                    config: config, objections: [], score: nil, history: [], summary: ""
                )
                state.config = config
                states[config.id] = state
            case let .run(start):
                runs.append(record.at)
                states[start.reviewer]?.lastRun = start
                states[start.reviewer]?.lastRunAt = record.at
            case let .review(result):
                guard var state = states[result.reviewer] else { continue }
                state.lastReview = result
                state.lastReviewAt = record.at
                if let report = result.report {
                    state.objections = ObjectionMatch.merge(
                        known: state.objections, raised: report.objections, pairs: result.pairs, at: record.at
                    )
                    state.summary = report.summary
                    let score = GoalScore.reviewer(state.objections, ran: report.ran.count, files: report.files)
                    state.score = score
                    state.history.append(score.value)
                }
                states[result.reviewer] = state
            case let .action(action):
                guard var state = states[action.reviewer],
                      let index = state.objections.firstIndex(where: { $0.id == action.objection })
                else { continue }
                state.objections[index].state = action.state
                if let report = state.lastReview?.report {
                    state.score = GoalScore.reviewer(state.objections, ran: report.ran.count, files: report.files)
                } else {
                    state.score = GoalScore.reviewer(state.objections)
                }
                states[action.reviewer] = state
            case let .done(mark):
                doneMark = mark
                doneAt = record.at
            }
        }
        let profile = profiles.last
        let bars = Self.bars(profile: profile, pins: pins, table: table)
        let reviewers = order.compactMap { states[$0] }
        let lenses = bars.keys.sorted().map { lens in
            // The lens's score: the best of its live reviewers that have scored.
            let score = reviewers.filter { !$0.config.removed && $0.config.kind.lens == lens }
                .compactMap { $0.score?.value }.max()
            return GoalScore.Lens(lens: lens, bar: bars[lens]!, score: score)
        }
        let met = doc?.criteriaMet ?? (met: 0, total: 0)
        return GoalQuality(
            profile: profile, profiles: profiles, pins: pins, reviewers: reviewers, lenses: lenses,
            confidence: GoalScore.confidence(met: met.met, total: met.total, lenses: lenses),
            done: doc.map { GoalScore.done(doc: $0, lenses: lenses) } ?? (false, ["no GOAL.md"]),
            doneMark: doneMark, doneAt: doneAt, runs: runs
        )
    }

    public func reviewer(_ id: String) -> ReviewerState? { reviewers.first { $0.id == id } }

    /// The live reviewers, in the order they were spawned.
    public var live: [ReviewerState] { reviewers.filter { !$0.config.removed } }

    /// What `done` looked at, to tell when it changed after an undo.
    public var doneBasis: String {
        lenses.map { "\($0.lens.rawValue)=\($0.score.map(GoalBarTable.number) ?? "-")" }.joined(separator: ",")
    }

    /// Whether heed should mark the goal done now: it is, and you did not undo that for what is true now.
    public var shouldMarkDone: Bool {
        guard done.done else { return false }
        if let mark = doneMark { return !mark.done && mark.basis != doneBasis }
        return true
    }
}
