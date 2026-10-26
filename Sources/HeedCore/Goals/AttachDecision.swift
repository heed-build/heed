import Foundation

/// One look heed took for a thing's goal, kept in `goal_attach_decisions`: what it saw, what it decided and what
/// became of it. The Unassigned view is these, newest first; your answers and undos change their state.
public struct AttachDecision: Hashable, Sendable, Codable, Identifiable {
    public enum State: String, Hashable, Sendable, Codable {
        /// Acted on and nothing since: attached on its own, left unassigned, or ignored by a rule.
        case settled
        /// Asked about and waiting for you.
        case open
        /// You said yes.
        case accepted
        /// You said no.
        case declined
        /// You put it on another goal.
        case moved
        /// You undid heed's attachment.
        case undone
        /// You said to ignore things like it.
        case ignored
        /// A goal was made from a suggestion it was in.
        case clustered
        /// A newer look at the same thing replaced this one.
        case superseded
    }

    /// The row id; 0 until stored.
    public var id: Int64
    public var subject: AttachSubject
    public var trigger: AttachTrigger
    public var verdict: AttachVerdict
    /// The best goals the signals found (at most three), for the feed's reasons and `m`.
    public var candidates: [AttachCandidate]
    public var state: State
    /// Where you put it, after a move or a yes.
    public var goal: String?
    public var resolvedAt: Date?
    /// Model tokens spent on it (input and output), 0 when the model was not asked.
    public var tokens: Int
    /// Why the model was not heard when it was wanted.
    public var modelError: String?
    public var at: Date

    public init(
        id: Int64 = 0, subject: AttachSubject, trigger: AttachTrigger, verdict: AttachVerdict,
        candidates: [AttachCandidate] = [], state: State? = nil, goal: String? = nil, resolvedAt: Date? = nil,
        tokens: Int = 0, modelError: String? = nil, at: Date
    ) {
        self.id = id
        self.subject = subject
        self.trigger = trigger
        self.verdict = verdict
        self.candidates = Array(candidates.prefix(3))
        self.state = state ?? (verdict.action == .ask ? .open : .settled)
        self.goal = goal ?? (verdict.action == .attach ? verdict.goal : nil)
        self.resolvedAt = resolvedAt
        self.tokens = tokens
        self.modelError = modelError
        self.at = at
    }

    /// What the feed calls it: `auto`, `rule`, `proposed`, `unassigned`, `ignored`.
    public var label: String {
        switch verdict.action {
        case .attach: verdict.basis == .rule ? "rule" : "auto"
        case .ask: "proposed"
        case .leave: "unassigned"
        case .ignore: "ignored"
        }
    }

    /// Whether it is a correction of heed: an undo, a no, a move or an ignore.
    public var isCorrection: Bool { [.declined, .moved, .undone, .ignored].contains(state) }

    /// Whether the thing is still on no goal because of it: left, declined, undone, or still waiting.
    public var leftUnassigned: Bool {
        switch state {
        case .settled: verdict.action == .leave
        case .declined, .undone, .open: true
        default: false
        }
    }
}

/// Today's numbers in the Unassigned view: how many things heed looked at and what it did with them.
public struct AttachDay: Hashable, Sendable {
    public var looked = 0
    public var auto = 0
    public var proposed = 0
    /// Still on no goal.
    public var left = 0
    public var corrections = 0
    public var tokens = 0

    public init(
        looked: Int = 0,
        auto: Int = 0,
        proposed: Int = 0,
        left: Int = 0,
        corrections: Int = 0,
        tokens: Int = 0
    ) {
        self.looked = looked
        self.auto = auto
        self.proposed = proposed
        self.left = left
        self.corrections = corrections
        self.tokens = tokens
    }

    /// Counts the decisions made since `start` (the start of today), one per thing: its latest; and the corrections
    /// you made since then, of decisions from any day.
    public static func of(_ decisions: [AttachDecision], since start: Date) -> AttachDay {
        var latest: [String: AttachDecision] = [:]
        var day = AttachDay()
        day.corrections = decisions.count { $0.isCorrection && ($0.resolvedAt ?? $0.at) >= start }
        for decision in decisions where decision.at >= start {
            day.tokens += decision.tokens
            if let other = latest[decision.subject.key], other.at > decision.at { continue }
            latest[decision.subject.key] = decision
        }
        for decision in latest.values {
            day.looked += 1
            switch decision.verdict.action {
            case .attach: day.auto += 1
            case .ask: day.proposed += 1
            case .leave, .ignore: break
            }
            if decision.leftUnassigned { day.left += 1 }
        }
        return day
    }

    /// `14 looked · 9 auto · 3 proposed · 2 left · 4 corrections · 3.2k tokens`.
    public var text: String {
        var parts = [
            "\(looked) looked", "\(auto) auto", "\(proposed) proposed", "\(left) left",
            "\(corrections) correction\(corrections == 1 ? "" : "s")",
        ]
        parts.append(tokens >= 1000 ? String(format: "%.1fk tokens", Double(tokens) / 1000) : "\(tokens) tokens")
        return parts.joined(separator: " · ")
    }
}

/// heed's open asks as Attention items (reason `goalAttach`, kind `goal`): one per thing, answered there with y, n, m
/// or i. Asks about things on a goal by now (you put them there yourself) are gone.
public enum GoalAttachAsks {
    public static let prefix = "goal-attach:"

    /// The open asks, newest first, one per thing.
    public static func open(_ decisions: [AttachDecision], linked: Set<String>) -> [AttachDecision] {
        var seen: Set<String> = []
        return decisions.filter { $0.state == .open && !linked.contains($0.subject.key) }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.id > $1.id }
            .filter { seen.insert($0.subject.key).inserted }
    }

    public static func items(_ open: [AttachDecision], titles: [String: String]) -> [AttachItemSource] {
        open.map { AttachItemSource(decision: $0, goalTitle: $0.verdict.goal.flatMap { titles[$0] } ?? "a goal") }
    }

    /// The thing's key from an item's id, if the item is an ask.
    public static func key(of itemID: String) -> String? {
        itemID.hasPrefix(prefix) ? String(itemID.dropFirst(prefix.count)) : nil
    }
}

/// One ask, ready to be an Attention item.
public struct AttachItemSource: Hashable, Sendable {
    public var decision: AttachDecision
    public var goalTitle: String

    public var item: AttentionItem {
        let subject = decision.subject
        let repo = subject.repos.first.flatMap { slug -> Repo? in
            let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
            return parts.count == 2 ? Repo(org: parts[0], name: parts[1]) : nil
        }
        return AttentionItem(
            id: GoalAttachAsks.prefix + subject.key, kind: .goal, repo: repo, number: nil,
            title: "\(subject.title) → \(goalTitle)?", url: nil, reasons: [.goalAttach], updatedAt: decision.at,
            branch: subject.branch.isEmpty ? nil : subject.branch, session: subject.id
        )
    }
}
