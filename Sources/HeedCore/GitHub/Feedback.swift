import Foundation

/// A PR as the reader shows it: description, review threads with the diff they refer to, checks, linked issues.
/// Fetched on demand and for PRs sessions track.
public struct PullDetail: Hashable, Sendable, Codable {
    public var ref: PullRef
    public var title: String
    public var body: String
    public var author: String?
    public var baseBranch: String
    public var headBranch: String
    public var additions: Int
    public var deletions: Int
    public var commitCount: Int
    public var headSHA: String
    public var reviews: [Review]
    public var threads: [ReviewThread]
    public var failingChecks: [FailingCheck]
    public var checks: CheckSummary
    public var closes: [PullRef]
    public var fetchedAt: Date

    public struct Review: Hashable, Sendable, Codable {
        public var author: String
        public var state: String
    }

    public struct FailingCheck: Hashable, Sendable, Codable {
        public var name: String
        /// The check's title or summary, first line: `docs/redirects.md:41 line too long`.
        public var summary: String
        public var url: String?
    }

    public init(
        ref: PullRef, title: String, body: String, author: String?, baseBranch: String, headBranch: String,
        additions: Int, deletions: Int, commitCount: Int, headSHA: String, reviews: [Review], threads: [ReviewThread],
        failingChecks: [FailingCheck], checks: CheckSummary, closes: [PullRef], fetchedAt: Date
    ) {
        self.ref = ref
        self.title = title
        self.body = body
        self.author = author
        self.baseBranch = baseBranch
        self.headBranch = headBranch
        self.additions = additions
        self.deletions = deletions
        self.commitCount = commitCount
        self.headSHA = headSHA
        self.reviews = reviews
        self.threads = threads
        self.failingChecks = failingChecks
        self.checks = checks
        self.closes = closes
        self.fetchedAt = fetchedAt
    }

    public var approvals: Int { latestReviews.count { $0.state == "APPROVED" } }

    /// The last review per reviewer.
    public var latestReviews: [Review] {
        var seen: [String: Review] = [:]
        for review in reviews {
            seen[review.author] = review
        }
        return seen.values.sorted { $0.author < $1.author }
    }
}

public struct ReviewThread: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var isResolved: Bool
    public var path: String
    public var line: Int?
    public var author: String
    public var body: String
    /// The last lines of the diff hunk the thread is on.
    public var diff: [String]
    public var replies: Int
    public var url: String?

    public init(
        id: String, isResolved: Bool, path: String, line: Int?, author: String, body: String, diff: [String],
        replies: Int, url: String?
    ) {
        self.id = id
        self.isResolved = isResolved
        self.path = path
        self.line = line
        self.author = author
        self.body = body
        self.diff = diff
        self.replies = replies
        self.url = url
    }

    /// `RedirectFile.cs:88`.
    public var location: String {
        let file = (path as NSString).lastPathComponent
        return line.map { "\(file):\($0)" } ?? file
    }
}

/// One thing to feed back to the agent: a review thread or a failing check.
public struct FeedbackItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case review(location: String, author: String)
        case check(name: String)
    }

    /// The pipeline: New → Queued → Sent → Addressed (the agent pushed) → Resolved (thread resolved, check passing).
    public enum Status: String, Hashable, Sendable, Codable, CaseIterable {
        case new = "New", queued = "Queued", sent = "Sent", addressed = "Addressed", resolved = "Resolved"
    }

    /// The thread id, or `check:<name>`.
    public var id: String
    public var kind: Kind
    public var text: String
    public var status: Status
    public var sentAt: Date?
    public var resolvedAt: Date?
    /// The head commit when it was sent, so a later push marks it addressed.
    public var sentAtSHA: String?

    public init(id: String, kind: Kind, text: String, status: Status = .new) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
    }

    /// One line of the prompt: `RedirectFile.cs:88 Anchor lookup is case sensitive…` or `lint: docs/redirects.md:41
    /// line too long`.
    public var promptLine: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let short = first.count > 160 ? String(first.prefix(159)) + "…" : first
        switch kind {
        case let .review(location, author): return "\(location) (@\(author)): \(short)"
        case let .check(name): return "check \(name) failed: \(short)"
        }
    }
}

public enum AutoFeed: String, Hashable, Sendable, Codable, CaseIterable {
    case off = "Off", ask = "Ask", auto = "Auto when idle"

    /// The word in config.toml: `off`, `ask`, `auto`.
    public var configName: String {
        switch self {
        case .off: "off"
        case .ask: "ask"
        case .auto: "auto"
        }
    }

    public static func named(_ name: String) -> AutoFeed? { allCases.first { $0.configName == name.lowercased() } }

    public var next: AutoFeed {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// The feedback pipeline of one PR.
public struct PullFeedback: Hashable, Sendable, Codable {
    public var ref: PullRef
    public var items: [FeedbackItem]
    public var autoFeed: AutoFeed
    public var watching: Bool
    /// Prompts sent since the last new approval.
    public var rounds: Int
    public var approvalsSeen: Int
    /// Set by hand on this PR (`w`, `m`), so they win over the settings; otherwise `watching` and `autoFeed` follow
    /// the `[pilot]` settings, written back by the app (`PilotSettings`).
    public var watchSet: Bool
    public var greenSet: Bool
    /// Prompts without a new approval before get it green stops (from the settings).
    public var maxRounds: Int
    /// Paused (silenced) until then: still watched, nothing sent or merged. `pausedForever` until resumed.
    public var pausedUntil: Date?
    public var pausedForever: Bool

    public static let defaultMaxRounds = 3

    public init(ref: PullRef, items: [FeedbackItem] = [], autoFeed: AutoFeed = .ask, watching: Bool = true) {
        self.ref = ref
        self.items = items
        self.autoFeed = autoFeed
        self.watching = watching
        rounds = 0
        approvalsSeen = 0
        watchSet = false
        greenSet = false
        maxRounds = Self.defaultMaxRounds
        pausedUntil = nil
        pausedForever = false
    }

    private enum CodingKeys: String, CodingKey {
        case ref, items, autoFeed, watching, rounds, approvalsSeen, watchSet, greenSet, maxRounds, pausedUntil,
             pausedForever
    }

    /// Caches written before the pilot settings still load: the newer fields default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        ref = try container.decode(PullRef.self, forKey: .ref)
        items = try container.decode([FeedbackItem].self, forKey: .items)
        autoFeed = try container.decode(AutoFeed.self, forKey: .autoFeed)
        watching = try container.decode(Bool.self, forKey: .watching)
        rounds = try container.decode(Int.self, forKey: .rounds)
        approvalsSeen = try container.decode(Int.self, forKey: .approvalsSeen)
        watchSet = try container.decodeIfPresent(Bool.self, forKey: .watchSet) ?? false
        greenSet = try container.decodeIfPresent(Bool.self, forKey: .greenSet) ?? false
        maxRounds = try container.decodeIfPresent(Int.self, forKey: .maxRounds) ?? Self.defaultMaxRounds
        pausedUntil = try container.decodeIfPresent(Date.self, forKey: .pausedUntil)
        pausedForever = try container.decodeIfPresent(Bool.self, forKey: .pausedForever) ?? false
    }

    /// What applies to this PR: a hand-set choice, else the settings.
    public struct Effective: Hashable, Sendable {
        public let watching: Bool
        public let green: AutoFeed
        public let maxRounds: Int
    }

    public func effective(_ settings: PilotSettings) -> Effective {
        Effective(
            watching: watchSet ? watching : settings.watch, green: greenSet ? autoFeed : settings.green,
            maxRounds: settings.maxRounds
        )
    }

    /// For a PR heed has no pipeline for yet: the settings alone.
    public static func effective(_ pipeline: PullFeedback?, _ settings: PilotSettings) -> Effective {
        pipeline?.effective(settings) ?? Effective(
            watching: settings.watch, green: settings.green, maxRounds: settings.maxRounds
        )
    }

    /// Writes what applies into the stored fields, so code reading `watching` and `autoFeed` sees the settings for a
    /// PR nobody set by hand. Returns whether anything changed.
    @discardableResult
    public mutating func settle(_ settings: PilotSettings) -> Bool {
        let before = self
        let effective = effective(settings)
        watching = effective.watching
        autoFeed = effective.green
        maxRounds = effective.maxRounds
        return self != before
    }

    public func isPaused(_ now: Date = Date()) -> Bool {
        pausedForever || (pausedUntil.map { $0 > now } ?? false)
    }

    public func count(_ status: FeedbackItem.Status) -> Int { items.count { $0.status == status } }

    public var queued: [FeedbackItem] { items.filter { $0.status == .queued } }

    /// Stops after `maxRounds` prompts without a new approval, so a loop that is not converging ends.
    public var roundsExhausted: Bool { rounds >= maxRounds }

    /// Folds a fresh look at the PR into the pipeline: new threads and failing checks arrive as New (queued when
    /// auto-feed is on), resolved threads and passing checks become Resolved, and sent items whose PR got a new head
    /// commit become Addressed.
    public mutating func merge(_ detail: PullDetail, now: Date = Date()) {
        if detail.approvals > approvalsSeen {
            approvalsSeen = detail.approvals
            rounds = 0
        }
        let threads = Dictionary(detail.threads.map { ($0.id, $0) }) { first, _ in first }
        // Each check on its own: one that passed resolves even while other checks still run.
        let failing = Set(detail.failingChecks.map(\.name))
        for index in items.indices {
            var item = items[index]
            let gone: Bool = switch item.kind {
            case .review: threads[item.id]?.isResolved ?? true
            case let .check(name): !failing.contains(name) && !detail.checks.pendingNames.contains(name)
            }
            if gone, item.status != .resolved {
                item.status = .resolved
                item.resolvedAt = now
            } else if item.status == .sent, let sha = item.sentAtSHA, sha != detail.headSHA {
                item.status = .addressed
            }
            items[index] = item
        }
        let initial: FeedbackItem.Status = autoFeed == .auto ? .queued : .new
        for thread in detail.threads where !thread.isResolved && !items.contains(where: { $0.id == thread.id }) {
            items.append(FeedbackItem(
                id: thread.id, kind: .review(location: thread.location, author: thread.author), text: thread.body,
                status: initial
            ))
        }
        for check in detail.failingChecks
            where !items.contains(where: { $0.id == "check:\(check.name)" && $0.status != .resolved })
        {
            items.removeAll { $0.id == "check:\(check.name)" }
            items.append(FeedbackItem(
                id: "check:\(check.name)",
                kind: .check(name: check.name),
                text: check.summary,
                status: initial
            ))
        }
    }

    /// The one prompt the queued items become.
    public func prompt() -> String? {
        let queued = queued
        guard !queued.isEmpty else { return nil }
        let lines = queued.enumerated().map { "\($0.offset + 1)) \($0.element.promptLine)" }
        return "Review feedback on PR #\(ref.number): address each item, run the tests, then push. "
            + lines.joined(separator: " ")
    }

    /// Marks the queued items sent at `sha`, counting a round.
    public mutating func markSent(at sha: String?, now: Date = Date()) {
        for index in items.indices where items[index].status == .queued {
            items[index].status = .sent
            items[index].sentAt = now
            items[index].sentAtSHA = sha
        }
        rounds += 1
    }
}

/// When feedback may be typed into a session's agent.
public enum Delivery {
    public enum Verdict: Equatable, Sendable {
        case deliver
        case wait(String)
    }

    /// Only when the agent is idle or done; never while it works, is blocked or asks; and not while you were typing
    /// in its pane in the last `typingGrace`.
    public static func verdict(
        state: AgentState, lastTyped: Date?, now: Date = Date(), typingGrace: TimeInterval = 20
    ) -> Verdict {
        switch state {
        case .working: return .wait("the agent is working")
        case .blocked: return .wait("the agent is waiting on a permission prompt")
        case .asking: return .wait("the agent is asking you something")
        case .limited: return .wait("the agent is rate limited")
        case .exited: return .wait("the agent has exited")
        case .idle, .done: break
        }
        if let lastTyped, now.timeIntervalSince(lastTyped) < typingGrace {
            return .wait("you typed in its pane just now")
        }
        return .deliver
    }
}
