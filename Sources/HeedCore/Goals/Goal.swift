import Foundation

/// A long-running goal (an epic) that sessions, chats, PRs and runs belong to. What it is lives in its `GOAL.md`
/// (`GoalDoc`, versioned); this is what heed keeps beside it. Named to stay clear of `RunGoal` (a PR run's aim).
public struct HeedGoal: Hashable, Sendable, Codable, Identifiable {
    public enum Status: String, Hashable, Sendable, Codable, CaseIterable {
        case active, done, archived
    }

    /// The slug: the goal's folder name, unique, never reused.
    public var id: String
    public var title: String
    public var status: Status
    public var createdAt: Date
    public var updatedAt: Date
    /// The `GOAL.md` version that is current (1 for a new goal).
    public var version: Int
    /// The goal's confidence, 0–10, once something scored it (reviewers, later); nil shows "–".
    public var score: Double?
    /// Where the goal mirrors to on GitHub, when it does (`GoalTracker`); nil until it is turned on.
    public var tracker: GoalTracker?

    public init(
        id: String, title: String, status: Status = .active, createdAt: Date, updatedAt: Date? = nil,
        version: Int = 1, score: Double? = nil, tracker: GoalTracker? = nil
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt
        self.version = version
        self.score = score
        self.tracker = tracker
    }
}

/// A goal's GitHub mirror: the tracker repo (any repo, not necessarily one the work happens in) and the meta issue
/// there, once made. Items keep their sub-issue numbers on their own rows (`goal_items.issue_number`).
public struct GoalTracker: Hashable, Sendable, Codable {
    /// `org/name`.
    public var repo: String
    public var metaIssue: Int?

    public init(repo: String, metaIssue: Int? = nil) {
        self.repo = repo
        self.metaIssue = metaIssue
    }
}

/// Something that belongs to a goal: a session, a chat, a PR, a run, a review. One goal each; attaching it to another
/// moves it.
public struct GoalLink: Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable, CaseIterable {
        case session, chat, pr, run, review
    }

    /// How the link was made: by you, by heed on its own (sure enough), or by heed after asking you.
    public enum Origin: String, Hashable, Sendable, Codable, CaseIterable {
        case manual, auto, asked
    }

    public var goal: String
    /// The goal's item it belongs to, when it is that precise (items come later).
    public var item: String?
    public var kind: Kind
    /// A session or chat id, `org/repo#n` for a PR, a run's id.
    public var target: String
    public var origin: Origin
    /// How sure heed was, 0–1, for links it made; nil for yours.
    public var confidence: Double?
    /// Why heed made it, in words.
    public var reason: String?
    public var at: Date

    public init(
        goal: String, kind: Kind, target: String, origin: Origin = .manual, item: String? = nil,
        confidence: Double? = nil, reason: String? = nil, at: Date
    ) {
        self.goal = goal
        self.kind = kind
        self.target = target
        self.origin = origin
        self.item = item
        self.confidence = confidence
        self.reason = reason
        self.at = at
    }

    /// The link's key: one goal per thing.
    public var key: String { "\(kind.rawValue):\(target)" }

    /// A session's link kind: a chat's or a session's.
    public static func kind(of session: Session) -> Kind { session.isChat ? .chat : .session }
}

/// One saved `GOAL.md`: every save is a new version, and restoring one saves it again as the newest.
public struct GoalVersion: Hashable, Sendable, Codable, Identifiable {
    /// Who wrote it.
    public enum Author: String, Hashable, Sendable, Codable {
        case you, heed, agent, restore
    }

    public var goal: String
    public var number: Int
    public var at: Date
    public var text: String
    /// What changed, in a few words ("created", "edited", "restored v2").
    public var note: String
    public var author: Author

    public init(goal: String, number: Int, at: Date, text: String, note: String, author: Author = .you) {
        self.goal = goal
        self.number = number
        self.at = at
        self.text = text
        self.note = note
        self.author = author
    }

    public var id: String { "\(goal)@\(number)" }
}

/// Everything the Goals view draws, read from the store at once.
public struct GoalSnapshot: Hashable, Sendable {
    public var goals: [HeedGoal]
    public var links: [GoalLink]
    /// Each goal's current `GOAL.md`, parsed, by goal id.
    public var docs: [String: GoalDoc]
    /// Every goal's items, oldest first.
    public var items: [GoalItem]
    /// Every goal's evidence, oldest first.
    public var evidence: [GoalEvidence]
    /// Every goal's GOAL.md edits (proposed, applied, said no to), oldest first.
    public var edits: [GoalEdit]

    public init(
        goals: [HeedGoal] = [], links: [GoalLink] = [], docs: [String: GoalDoc] = [:], items: [GoalItem] = [],
        evidence: [GoalEvidence] = [], edits: [GoalEdit] = []
    ) {
        self.goals = goals
        self.links = links
        self.docs = docs
        self.items = items
        self.evidence = evidence
        self.edits = edits
    }

    public func items(of goal: String) -> [GoalItem] { items.filter { $0.goal == goal } }
    public func evidence(of goal: String) -> [GoalEvidence] { evidence.filter { $0.goal == goal } }
    public func item(_ id: String) -> GoalItem? { items.first { $0.id == id } }

    /// A goal's scope edits waiting for you, oldest first.
    public func proposals(of goal: String) -> [GoalEdit] {
        edits.filter { $0.goal == goal && $0.state == .proposed }
    }

    public static let empty = GoalSnapshot()

    public func goal(_ id: String) -> HeedGoal? { goals.first { $0.id == id } }

    /// The goal a session or chat belongs to.
    public func goal(of session: Session) -> HeedGoal? {
        links.first { $0.kind == GoalLink.kind(of: session) && $0.target == session.id }.flatMap { goal($0.goal) }
    }

    public func links(of goal: String) -> [GoalLink] { links.filter { $0.goal == goal } }

    /// Goals in the order the list shows them: active first, then done, then archived; newest first in each.
    public var ordered: [HeedGoal] {
        let rank: [HeedGoal.Status: Int] = [.active: 0, .done: 1, .archived: 2]
        return goals.sorted {
            rank[$0.status] != rank[$1.status] ? rank[$0.status]! < rank[$1.status]!
                : $0.createdAt != $1.createdAt ? $0.createdAt > $1.createdAt : $0.id < $1.id
        }
    }
}

public enum GoalSlug {
    /// A folder name from a title: lowercase words joined by `-`, at most 48 characters, and `-2`, `-3`… when taken.
    public static func make(_ title: String, taken: Set<String>) -> String {
        let words = title.lowercased().folding(options: .diacriticInsensitive, locale: nil)
            .split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        var base = ""
        for word in words {
            let next = base.isEmpty ? String(word) : base + "-" + word
            if next.count > 48 { break }
            base = next
        }
        if base.isEmpty { base = "goal" }
        guard taken.contains(base) else { return base }
        var number = 2
        while taken.contains("\(base)-\(number)") {
            number += 1
        }
        return "\(base)-\(number)"
    }
}

/// `[goals]` in config.toml.
public struct GoalSettings: Equatable, Sendable {
    /// Sessions and chats on a goal are told at launch and resume which goal, and to read its `GOAL.md` first
    /// (`GoalPointer`).
    public var tellAgents = true

    public init(tellAgents: Bool = true) {
        self.tellAgents = tellAgents
    }
}
