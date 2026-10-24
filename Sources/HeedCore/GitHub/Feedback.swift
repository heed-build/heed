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
    /// What the green verdict reads. Optional: details cached before them decode without them, and count as unknown.
    /// `OPEN`, `MERGED`, `CLOSED`.
    public var state: String?
    public var isDraft: Bool?
    /// `MERGEABLE`, `CONFLICTING`, or `UNKNOWN` while GitHub works it out.
    public var mergeable: String?
    /// GitHub's `mergeStateStatus`: `CLEAN`, `BEHIND` (out of date, and the repo requires up to date), `DIRTY`
    /// (conflicts), `BLOCKED`, `UNSTABLE`, `HAS_HOOKS`, `DRAFT`, `UNKNOWN`.
    public var mergeState: String?
    /// `APPROVED`, `CHANGES_REQUESTED`, `REVIEW_REQUIRED`, or nil.
    public var reviewDecision: String?
    /// The checks branch protection requires on this PR; empty when it requires none.
    public var requiredChecks: [String]?
    /// GitHub auto-merge is on for this PR, and with which method.
    public var autoMergeEnabled: Bool?
    public var autoMergeMethod: String?
    public var labels: [String]?
    /// What the repo allows: auto-merge, and the merge methods (`squash`, `merge`, `rebase`).
    public var repoAllowsAutoMerge: Bool?
    public var repoMergeMethods: [String]?
    /// The base branch's protection requires linear history (no merge commits); nil when unknown or unprotected.
    public var repoRequiresLinearHistory: Bool?
    /// Your permission on the repo: `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`. Only an admin can force a merge.
    public var viewerPermission: String?
    /// When the head commit was made, for the merge rules' quiet window.
    public var headCommittedAt: Date?
    /// The checks that passed on the head commit, by name.
    public var passedChecks: [String]?

    /// PRs that mention this one (GitHub's cross-references), for follow-ups and companion changes.
    public var references: [Reference]?

    public struct Reference: Hashable, Sendable, Codable {
        public var ref: PullRef
        public var title: String
        public var author: String?
        public var state: String
        public var createdAt: Date?

        public init(ref: PullRef, title: String, author: String?, state: String, createdAt: Date?) {
            self.ref = ref
            self.title = title
            self.author = author
            self.state = state
            self.createdAt = createdAt
        }
    }

    public struct Review: Hashable, Sendable, Codable {
        public var author: String
        public var state: String
        public var submittedAt: Date?
        /// The commit it reviewed, so a review from before the last push does not count.
        public var commit: String?

        public init(author: String, state: String, submittedAt: Date? = nil, commit: String? = nil) {
            self.author = author
            self.state = state
            self.submittedAt = submittedAt
            self.commit = commit
        }
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

/// One thing to feed back to the agent: a review thread, a failing check, or a note of your own on a hunk.
public struct FeedbackItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: Hashable, Sendable, Codable {
        case review(location: String, author: String)
        case check(name: String)
        /// The PR conflicts with its base (or is behind it, when the repo requires up to date).
        case conflict(base: String, behind: Bool)
        /// Your note on a hunk in the diff overlay (`a`), at a line of the new side.
        case note(path: String, line: Int, repo: Repo?)
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
    /// For a failed check: the failed step's log, saved where the agent can read it.
    public var logPath: String?
    /// For a conflict: when Copilot was asked to resolve it (so it is asked once, and not sent to the agent too).
    public var copilotAskedAt: Date?
    /// For a note: the hunk it is on, as diff lines (`+`, `-`, or a space first), at most `noteHunkLimit` of them.
    public var hunk: [String]?

    public init(id: String, kind: Kind, text: String, status: Status = .new) {
        self.id = id
        self.kind = kind
        self.text = text
        self.status = status
    }

    /// The most hunk lines a note keeps (and its prompt quotes): the ones around the line it is on.
    public static let noteHunkLimit = 20

    /// A note on a hunk, queued: the comment, where it is, and the hunk's lines around `focus` (an index into
    /// `lines`; nil is the hunk's start).
    public static func note(
        _ comment: String, path: String, line: Int, repo: Repo?, lines: [DiffLine], focus: Int? = nil,
        id: String = "note:" + UUID().uuidString.lowercased()
    ) -> FeedbackItem {
        var item = FeedbackItem(
            id: id, kind: .note(path: path, line: line, repo: repo),
            text: comment.trimmingCharacters(in: .whitespacesAndNewlines), status: .queued
        )
        let limit = noteHunkLimit
        var start = 0
        if lines.count > limit, let focus {
            start = min(max(focus - limit / 2, 0), lines.count - limit)
        }
        item.hunk = lines[start ..< min(start + limit, lines.count)].map { line in
            switch line.kind {
            case .added: "+" + line.text
            case .deleted: "-" + line.text
            case .context: " " + line.text
            }
        }
        return item
    }

    /// Where a note is: `src/RedirectFile.cs:88`.
    public var noteLocation: String? {
        guard case let .note(path, line, _) = kind else { return nil }
        return "\(path):\(line)"
    }

    /// One line of the prompt: `RedirectFile.cs:88 Anchor lookup is case sensitive…` or `lint: docs/redirects.md:41
    /// line too long`.
    public var promptLine: String {
        let first = text.split(separator: "\n").first.map(String.init) ?? text
        let short = first.count > 160 ? String(first.prefix(159)) + "…" : first
        switch kind {
        case let .review(location, author): return "\(location) (@\(author)): \(short)"
        case let .note(path, line, _):
            // Your words in full, then the hunk they are about.
            let quoted = (hunk ?? []).isEmpty ? "" : "\n```diff\n" + (hunk ?? []).joined(separator: "\n") + "\n```"
            return "\(path):\(line) (you): \(text)" + quoted
        case let .check(name):
            return "check \(name) failed: \(short)" + (logPath.map { " (the failed log is in \($0))" } ?? "")
        case let .conflict(base, behind):
            return behind
                ? "the branch is behind \(base), which the repo requires to be current: rebase on \(base) and push"
                : "the branch conflicts with \(base): rebase on \(base), resolve the conflicts, run the tests and push"
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
    /// Get it merged, as set by hand (`M`) when `mergeSet`, else from the settings.
    public var merge: MergeMode
    public var mergeSet: Bool
    /// The reviewers heed asked for (as gh spells them), so each is asked once.
    public var reviewersRequested: [String]
    /// The last self-review, for the head commit it read (`merge = "heed"` with `self_review`).
    public var selfReview: SelfReview?

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
        merge = .off
        mergeSet = false
        reviewersRequested = []
    }

    private enum CodingKeys: String, CodingKey {
        case ref, items, autoFeed, watching, rounds, approvalsSeen, watchSet, greenSet, maxRounds, pausedUntil,
             pausedForever, merge, mergeSet, reviewersRequested, selfReview
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
        merge = try container.decodeIfPresent(MergeMode.self, forKey: .merge) ?? .off
        mergeSet = try container.decodeIfPresent(Bool.self, forKey: .mergeSet) ?? false
        reviewersRequested = try container.decodeIfPresent([String].self, forKey: .reviewersRequested) ?? []
        selfReview = try container.decodeIfPresent(SelfReview.self, forKey: .selfReview)
    }

    /// What applies to this PR: a hand-set choice, else the settings.
    public struct Effective: Hashable, Sendable {
        public let watching: Bool
        public let green: AutoFeed
        public let maxRounds: Int
        public let merge: MergeMode

        public init(watching: Bool, green: AutoFeed, maxRounds: Int, merge: MergeMode = .off) {
            self.watching = watching
            self.green = green
            self.maxRounds = maxRounds
            self.merge = merge
        }
    }

    public func effective(_ settings: PilotSettings) -> Effective {
        Effective(
            watching: watchSet ? watching : settings.watch, green: greenSet ? autoFeed : settings.green,
            maxRounds: settings.maxRounds, merge: mergeSet ? merge : settings.merge
        )
    }

    /// For a PR heed has no pipeline for yet: the settings alone.
    public static func effective(_ pipeline: PullFeedback?, _ settings: PilotSettings) -> Effective {
        pipeline?.effective(settings) ?? Effective(
            watching: settings.watch, green: settings.green, maxRounds: settings.maxRounds, merge: settings.merge
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
        merge = effective.merge
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
            // Yours: GitHub knows nothing of it, so only you dismiss it.
            case .note: false
            // Gone once GitHub says it merges cleanly and is current; unknown keeps it.
            case .conflict: detail.mergeable == "MERGEABLE" && detail.mergeState != "BEHIND"
                && detail.mergeState != "DIRTY"
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
        let base = detail.baseBranch.isEmpty ? "the base branch" : detail.baseBranch
        let conflicted = detail.mergeable == "CONFLICTING" || detail.mergeState == "DIRTY"
        let behind = !conflicted && detail.mergeState == "BEHIND"
        if conflicted || behind, !items.contains(where: { $0.id == "conflict" && $0.status != .resolved }) {
            items.removeAll { $0.id == "conflict" }
            items.append(FeedbackItem(
                id: "conflict", kind: .conflict(base: base, behind: behind),
                text: conflicted ? "Merge conflict with \(base)." : "Behind \(base).", status: initial
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

    /// The one prompt the queued items become, then `instructions` (the repo's `green_instructions`).
    public func prompt(instructions: String = "") -> String? {
        let queued = queued
        guard !queued.isEmpty else { return nil }
        let prompt = "Review feedback on PR #\(ref.number): address each item, run the tests, then push. "
            + FeedbackItem.numbered(queued)
        return instructions.isEmpty ? prompt : prompt + "\n\n" + instructions
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

extension FeedbackItem {
    /// `1) … 2) …`: on one line, or a line each when one of them quotes a hunk.
    static func numbered(_ items: [FeedbackItem]) -> String {
        let lines = items.enumerated().map { "\($0.offset + 1)) \($0.element.promptLine)" }
        return lines.joined(separator: lines.contains { $0.contains("\n") } ? "\n" : " ")
    }
}

/// Notes on a session's diff before it has a PR to put them on: queued on the session, sent to its own agent (`s` in
/// the overlay, or `⌘↩` as you queue one), and moved into the PR's pipeline once the session tracks one.
public enum SessionNotes {
    /// The one prompt the queued notes become.
    public static func prompt(_ notes: [FeedbackItem]) -> String? {
        let queued = notes.filter { $0.status == .queued }
        guard !queued.isEmpty else { return nil }
        return "Feedback on your changes: address each item, then run the tests. " + FeedbackItem.numbered(queued)
    }

    /// Marks the queued notes sent.
    public static func markSent(_ notes: inout [FeedbackItem], now: Date = Date()) {
        for index in notes.indices where notes[index].status == .queued {
            notes[index].status = .sent
            notes[index].sentAt = now
        }
    }

    /// The tracked PR a note on `repo` belongs to: the newest open one in that repo (a note without a repo, in any).
    public static func pull(
        for repo: Repo?, in session: Session, isOpen: (PullRef) -> Bool = { _ in true }
    ) -> PullRef? {
        session.trackedPRs.last { (repo == nil || $0.repo == repo) && isOpen($0) }
    }

    /// Moves the session's notes into the pipelines of the PRs it now tracks, keeping their status. Notes in a repo
    /// without a PR stay. Returns the pipelines that changed.
    public static func adopt(
        _ session: inout Session, into feedback: [String: PullFeedback], isOpen: (PullRef) -> Bool = { _ in true }
    ) -> [PullFeedback] {
        guard !session.notes.isEmpty, !session.trackedPRs.isEmpty else { return [] }
        var changed: [String: PullFeedback] = [:]
        let tracking = session
        session.notes.removeAll { note in
            guard case let .note(_, _, repo) = note.kind, let ref = pull(for: repo, in: tracking, isOpen: isOpen)
            else { return false }
            var pipeline = changed[ref.description] ?? feedback[ref.description] ?? PullFeedback(ref: ref)
            if !pipeline.items.contains(where: { $0.id == note.id }) { pipeline.items.append(note) }
            changed[ref.description] = pipeline
            return true
        }
        return changed.values.sorted { $0.ref.description < $1.ref.description }
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
        let grace = max(typingGrace, 20)
        if let lastTyped, now.timeIntervalSince(lastTyped) < grace {
            return .wait(grace <= 20
                ? "you typed in its pane just now"
                : "you're working in it (sends \(PilotDuration.text(grace)) after your last keystroke)")
        }
        return .deliver
    }
}
