import Foundation

/// An agent run on one Browse item: an item, a verb, an agent, a temporary worktree and an ACP session. Everything it
/// shows comes from what the agent reported and what heed did; its life is a state machine, so a late event (a turn's
/// end after you closed the run) cannot bring it back.
///
/// needsClone, then cloning (or straight to) preparing (the worktree and its setup, the agent started), then working;
/// a turn's end leaves it done (waiting for what you say next), failed, or closed.
public struct BrowseRun: Identifiable, Sendable {
    public enum Phase: Equatable, Sendable {
        /// The repo is not on this Mac: the clone card asks.
        case needsClone
        case cloning
        /// The worktree is being made, its setup run, its agent started.
        case preparing
        case working
        /// A turn ended: the run waits for what you say next (or for a review's Post).
        case done(ACPStopReason)
        case failed(String)
        /// You closed it, or declined its clone.
        case closed(String)

        /// Using a slot of `[browse] max_runs`: something is happening.
        public var holdsSlot: Bool {
            switch self {
            case .cloning, .preparing, .working: true
            case .needsClone, .done, .failed, .closed: false
            }
        }

        public var isOver: Bool {
            switch self {
            case .failed, .closed: true
            default: false
            }
        }

        /// What the header says after the verb: `working`.
        public var text: String {
            switch self {
            case .needsClone: "not on this Mac"
            case .cloning: "cloning"
            case .preparing: "preparing"
            case .working: "working"
            case let .done(reason): reason == .endTurn ? "done" : reason.text
            case let .failed(why): "failed: \(why)"
            case let .closed(how): how
            }
        }
    }

    /// Why a turn was cancelled, so its end is read right.
    public enum Cancel: Equatable, Sendable {
        /// You said something: its words start the next turn.
        case steer(String)
        /// heed stopped it: its spend cap, closing.
        case stop(String)
    }

    public enum Event: Equatable, Sendable {
        case cloneStarted
        case cloned
        case cloneFailed(String)
        /// "Not now" on the clone card.
        case declined
        /// Its agent started in the worktree.
        case ready(note: String?)
        case turnStarted
        case turnEnded(ACPStopReason, cancel: Cancel?, connected: Bool)
        case turnFailed(String)
        case agentExited(String)
        case couldNotStart(String)
        case closed(String)
    }

    public enum Effect: Equatable, Sendable {
        /// Read what the turn left: a review's draft.
        case finishTurn
        /// Start the next turn on your words.
        case steer(String)
    }

    /// Whether the run goes ahead with its verb, or reads only: from someone heed does not trust it reads (Chat), and
    /// says why.
    public enum Mode: Equatable, Sendable {
        case full
        case chatOnly(reason: String)
    }

    public let id: String
    public let itemID: String
    public let repo: Repo
    public let number: Int
    public let kind: BrowseItem.Kind
    /// The item's title as shown.
    public var title: String
    public let url: String
    /// What you asked for.
    public let verb: BrowseVerb
    public var mode: Mode
    public var agent: String
    public var adapter: String
    /// `issue-2830-4f9c2e`.
    public var name: String
    public var branch: String
    public var worktree: String
    /// A pull request's head branch, when the run may push to it.
    public var prBranch: String?
    /// False on a pull request from a fork.
    public var canPush: Bool
    public var phase: Phase
    public var startedAt: Date
    public var endedAt: Date?
    /// The feed, the plan, the usage and the files: the helper story engine, never listed among helpers.
    public var story: HelperRun
    public var draft: BrowseReviewDraft?
    /// The folder the clone card clones into (the repo's own folder goes under it).
    public var cloneRoot: String?
    /// What you said when you started it in your own words (`t`), in place of the verb's prompt.
    public var words: String?
    /// Closed, but its worktree holds work nothing else has, so it stays: the reader says so until you deal with it.
    public var kept: BrowseKept?

    public init(
        id: String = UUID().uuidString.lowercased(), item: BrowseItem, verb: BrowseVerb, mode: Mode = .full,
        agent: String, adapter: String, name: String, branch: String, worktree: String, prBranch: String? = nil,
        canPush: Bool = true, phase: Phase, startedAt: Date, cap: Double
    ) {
        self.id = id
        itemID = item.id
        repo = item.repo
        number = item.number
        kind = item.kind
        title = item.title.display
        url = item.url
        self.verb = verb
        self.mode = mode
        self.agent = agent
        self.adapter = adapter
        self.name = name
        self.branch = branch
        self.worktree = worktree
        self.prBranch = prBranch
        self.canPush = canPush
        self.phase = phase
        self.startedAt = startedAt
        story = HelperRun(
            id: id, kind: .review, ref: PullRef(repo: item.repo, number: item.number), title: item.title.display,
            agent: agent, adapter: adapter, sessionID: nil, prBranch: prBranch ?? branch, branch: branch,
            worktree: worktree, startedAt: startedAt, cap: cap
        )
    }

    /// What you said to start it, as the feed's first line.
    public static func youSaid(_ verb: BrowseVerb, _ item: BrowseItem) -> String {
        switch verb {
        case .fix: item.kind == .pull ? "Address the feedback" : "Fix it and open a PR"
        case .implement: "Build it and open a PR"
        case .chat: "Talk it through"
        case .review: "Review it"
        }
    }

    /// What the agent is held to: Chat when heed does not trust the author.
    public var effectiveVerb: BrowseVerb {
        if case .chatOnly = mode { return .chat }
        return verb
    }

    /// `Fix · claude working`.
    public var headline: String { "\(effectiveVerb == verb ? verb.title : "\(verb.title) as Chat") · \(agent)" }

    public var canSteer: Bool {
        switch phase {
        case .working, .done: true
        default: false
        }
    }

    public var isLive: Bool { !phase.isOver }

    /// Dollars it has spent, as the agent reports; nil when it reports none.
    public var cost: Double? { story.usage.cost }
    public var overCap: Bool { story.overCap }

    // MARK: Life

    /// Takes one event in: what the app does next, or nil when the event no longer applies and nothing changed.
    public mutating func apply(_ event: Event, at time: Date) -> [Effect]? {
        switch event {
        case .cloneStarted:
            guard phase == .needsClone else { return nil }
            phase = .cloning
            note("cloning \(repo.slug)", at: time)
            return []
        case .cloned:
            guard phase == .cloning else { return nil }
            phase = .preparing
            return []
        case let .cloneFailed(why):
            guard phase == .cloning else { return nil }
            return fail(why, at: time)
        case .declined:
            guard phase == .needsClone else { return nil }
            phase = .closed("not now")
            endedAt = time
            return []
        case let .ready(text):
            guard phase == .preparing else { return nil }
            phase = .working
            if let text { note(text, at: time) }
            return []
        case .turnStarted:
            switch phase {
            case .working, .done: phase = .working
            default: return nil
            }
            // A new turn's draft is not the old one: the old one stays until a new one replaces it.
            return []
        case let .turnEnded(stop, cancel, connected):
            guard phase == .working else { return nil }
            switch cancel {
            case let .steer(text)?:
                guard connected else {
                    phase = .done(.cancelled)
                    return []
                }
                return [.steer(text)]
            case let .stop(why)?:
                phase = .done(.cancelled)
                note(why, at: time)
                return [.finishTurn]
            case nil:
                phase = .done(stop)
                return [.finishTurn]
            }
        case let .turnFailed(why), let .couldNotStart(why):
            guard phase.holdsSlot else { return nil }
            return fail(why, at: time)
        case let .agentExited(why):
            if case .done = phase {
                note(why, at: time)
                return []
            }
            guard phase.holdsSlot else { return nil }
            return fail(why, at: time)
        case let .closed(how):
            guard !phase.isOver else { return nil }
            phase = .closed(how)
            endedAt = time
            return []
        }
    }

    private mutating func fail(_ why: String, at time: Date) -> [Effect] {
        phase = .failed(why)
        endedAt = time
        note(why, at: time)
        return []
    }

    public mutating func note(_ text: String, at time: Date) { story.append(.note(text), at: time) }

    /// What you said.
    public mutating func said(_ text: String, at time: Date) { story.append(.steer(text), at: time) }

    /// Heed refused something the agent asked for: the feed says what and why.
    public mutating func refused(_ what: String, why: String, at time: Date) {
        story.append(.permission(title: what, answer: "refused: \(why)"), at: time)
    }

    public mutating func apply(_ update: ACPUpdate, at time: Date) { story.apply(update, at: time) }

    // MARK: A review's draft

    /// The agent's last message, read as a draft review (Review only): replaces a draft not yet posted.
    public mutating func drafted(from message: String) {
        guard effectiveVerb == .review || verb == .review else { return }
        switch draft?.state {
        case .posting?, .posted?: return
        default: break
        }
        draft = BrowseReviewDraft.parse(message)
    }

    /// You changed the draft's text before posting it: only a draft not posted or being posted.
    public mutating func editDraft(_ body: String) -> Bool {
        guard draft?.state == .drafted else { return false }
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        draft?.body = trimmed
        draft?.failure = nil
        return true
    }

    /// Post starts: only a drafted review (never twice, never one that is gone).
    public mutating func beginPost() -> BrowseReviewDraft? {
        guard var current = draft, current.state == .drafted || current.failure != nil else { return nil }
        current.state = .posting
        current.failure = nil
        draft = current
        return current
    }

    public mutating func posted() {
        guard draft?.state == .posting else { return }
        draft?.state = .posted
    }

    public mutating func postFailed(_ why: String) {
        guard draft?.state == .posting else { return }
        draft?.state = .drafted
        draft?.failure = why
    }

    /// Discard: a drafted review is dropped, nothing is posted.
    public mutating func discardDraft() -> Bool {
        guard draft?.state == .drafted else { return false }
        draft?.state = .discarded
        return true
    }
}

/// A review the agent drafted for you to post, edit or discard: public speech on someone else's pull request, so it
/// goes out only from one explicit action.
public struct BrowseReviewDraft: Equatable, Sendable {
    public enum Verdict: String, Equatable, Sendable, CaseIterable {
        case approve, comment, requestChanges = "request changes"

        public var title: String {
            switch self {
            case .approve: "Approve"
            case .comment: "Comment"
            case .requestChanges: "Request changes"
            }
        }
    }

    public enum State: Equatable, Sendable {
        case drafted, posting, posted, discarded
    }

    public var verdict: Verdict
    public var body: String
    /// What it checked, one line each.
    public var did: [String]
    public var comments: [(place: String, text: String)]
    public var state: State = .drafted
    /// Why the last post failed.
    public var failure: String?

    public static func == (lhs: BrowseReviewDraft, rhs: BrowseReviewDraft) -> Bool {
        lhs.verdict == rhs.verdict && lhs.body == rhs.body && lhs.did == rhs.did && lhs.state == rhs.state
            && lhs.failure == rhs.failure && lhs.comments.map(\.place) == rhs.comments.map(\.place)
            && lhs.comments.map(\.text) == rhs.comments.map(\.text)
    }

    /// Reads a message with heed's sign-off lines (`HelperPrompt.signOffReview`); nil when it holds no review at all.
    public static func parse(_ message: String) -> BrowseReviewDraft? {
        let out = HelperPrompt.closeOut(message)
        let body = HelperPrompt.reviewBody(out)
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let verdict: Verdict = switch out.verdict {
        case "approve"?: .approve
        case "request changes"?, "request_changes"?, "request-changes"?: .requestChanges
        default: .comment
        }
        return BrowseReviewDraft(
            verdict: verdict, body: body, did: out.did, comments: out.replies.map { ($0.place, $0.text) }
        )
    }
}

/// Which runs may start: one live run per item, and as many at once as `[browse] max_runs` says.
public enum BrowseRuns {
    public enum Start: Equatable, Sendable {
        case ok
        /// This item already has a run you have not closed.
        case itemBusy
        /// This many are working already.
        case atCap(Int)

        public var reason: String? {
            switch self {
            case .ok: nil
            case .itemBusy: "this item already has a run: close it first (esc), or steer it"
            case let .atCap(max): "\(max) runs are working: wait for one to finish, or close one"
            }
        }
    }

    /// The run on an item that is not closed or failed.
    public static func current(for itemID: String, in runs: [BrowseRun]) -> BrowseRun? {
        runs.first { $0.itemID == itemID && !$0.phase.isOver }
    }

    /// How many are using a slot: cloning, preparing or working. One waiting for you (done, or asking to clone) is not.
    public static func working(_ runs: [BrowseRun]) -> Int { runs.count { $0.phase.holdsSlot } }

    /// The closed run on an item whose worktree was kept with work in it, for its card.
    public static func kept(for itemID: String, in runs: [BrowseRun]) -> BrowseRun? {
        runs.last { $0.itemID == itemID && $0.kept != nil }
    }

    public static func canStart(item itemID: String, runs: [BrowseRun], max: Int) -> Start {
        if current(for: itemID, in: runs) != nil { return .itemBusy }
        if max > 0, working(runs) >= max { return .atCap(max) }
        return .ok
    }
}

/// A run that could not start, as the reader says it: what went wrong and what to do about it. Pure: from the text the
/// start gave, so the card never shows a bare error.
public enum BrowseRunFailure {
    /// What to do about `why`: one sentence, naming the key or the setting where there is one.
    public static func advice(for why: String) -> String {
        let text = why.lowercased()
        if text.contains("could not read who opened") {
            return "heed asks GitHub who wrote a pull request before it lets an agent near it. Check that gh is signed in "
                + "(run gh auth status in a terminal) and that you are online, then try again."
        }
        if text.contains("is not installed") {
            return "Install it as the message says, then try again. [browse] agent (or [helpers] agent) picks another agent."
        }
        if text.contains("sign in first") {
            return "Run the agent once in a terminal, sign in there, then try again."
        }
        if text.contains("not cloned on this mac") {
            return "Clone the repo first (Add or clone, or the clone card), then try again."
        }
        if text.contains("worktree") {
            return "git could not make the run's worktree. Check the repo for a rebase or merge in progress and that "
                + "its default branch is fetched, then try again."
        }
        if text.contains("setup failed") {
            return "The repo's setup command failed in the new worktree. Run it by hand in the repo to see why."
        }
        if text.contains("no acp way") || text.contains("did not start") {
            return "heed could not reach an agent over ACP. Set [browse] agent to one that is installed, then try again."
        }
        return "Try again with the same key; esc dismisses this."
    }

    /// The run to show a failure for: the item's last run, when it failed and nothing newer is on the item.
    public static func failed(for itemID: String, in runs: [BrowseRun]) -> BrowseRun? {
        guard let last = runs.last(where: { $0.itemID == itemID }), case .failed = last.phase, last.kept == nil
        else { return nil }
        return last
    }
}
