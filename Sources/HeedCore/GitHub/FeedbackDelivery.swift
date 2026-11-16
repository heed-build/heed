import Foundation

/// Whether a PR's queued feedback goes out now, and where to: a helper, the session that tracks it, a run of its own,
/// or a swarm task's worker. Decided from what the app knows of the PR; the app does what it says.
public enum FeedbackDelivery {
    public enum Decision: Equatable, Sendable {
        /// Nothing queued to send.
        case nothingQueued
        /// Feedback heed sends on its own is caused by what arrived on the PR: decide again under that cause.
        case attributeCause
        /// A merged or closed PR has nothing left to fix: it stops waiting.
        case finished(PullRequest.State)
        /// Auto-feed does not send it: off, not watching, paused, or out of rounds (`stuck` when auto-feed is on and
        /// the rounds ran out).
        case held(stuck: Bool)
        /// From someone outside the repo: a run starts only when you send it.
        case heldForAuthor
        /// Whether the author can write to the repo is not known yet: find out, then decide again.
        case resolveTrust
        /// `run_in = "helper"`: an agent over ACP in its own worktree.
        case helper
        /// No session tracks the PR.
        case noSession
        /// A fixture does no IO; with the tutor on, the items count as sent.
        case fixture(tutor: Bool)
        /// `run_in = "session"`: typed to the session that tracks it.
        case inSession
        /// One run per PR at a time: the next round waits for it to end.
        case waitForRun
        /// A swarm PR's conflict or rebase goes back to its task's own worker.
        case returnToWorker(SwarmWorker)
        /// A swarm PR's handback waits: why.
        case waitForWorker(String)
        /// A run of its own starts on it; for a swarm PR the worker could not take, why (`handback`).
        case startRun(handback: String?)
    }

    /// What the decision reads. `trusted` and `handback` are asked only when the decision gets that far: one reads
    /// the trust book, the other looks for worktrees on disk.
    public struct Facts {
        /// You sent it, rather than heed on its own.
        public var explicit: Bool
        /// The PR has a pipeline with a prompt to send.
        public var queued: Bool
        /// The current cause (audit) is something that arrived on the PR.
        public var causedByPullEvent: Bool
        public var state: PullRequest.State?
        public var effective: PullFeedback.Effective
        public var roundsExhausted: Bool
        public var paused: Bool
        public var isFixture: Bool
        public var tutor: Bool
        public var runIn: RunIn
        /// The PR is a swarm's.
        public var swarm: Bool
        public var hasSession: Bool
        /// A run works on it, or is starting.
        public var runWorking: Bool
        /// Its items need its swarm task's worker (`SwarmHandback.needs`).
        public var needsHandback: Bool
        public var trusted: () -> Bool?
        public var handback: () -> SwarmHandback.Route

        public init(
            explicit: Bool, queued: Bool, causedByPullEvent: Bool, state: PullRequest.State?,
            effective: PullFeedback.Effective, roundsExhausted: Bool, paused: Bool, isFixture: Bool, tutor: Bool,
            runIn: RunIn, swarm: Bool, hasSession: Bool, runWorking: Bool, needsHandback: Bool,
            trusted: @escaping () -> Bool?, handback: @escaping () -> SwarmHandback.Route
        ) {
            self.explicit = explicit
            self.queued = queued
            self.causedByPullEvent = causedByPullEvent
            self.state = state
            self.effective = effective
            self.roundsExhausted = roundsExhausted
            self.paused = paused
            self.isFixture = isFixture
            self.tutor = tutor
            self.runIn = runIn
            self.swarm = swarm
            self.hasSession = hasSession
            self.runWorking = runWorking
            self.needsHandback = needsHandback
            self.trusted = trusted
            self.handback = handback
        }
    }

    public static func decide(_ facts: Facts) -> Decision {
        guard facts.queued else { return .nothingQueued }
        if !facts.explicit, !facts.causedByPullEvent { return .attributeCause }
        if let state = facts.state, state != .open { return .finished(state) }
        let auto = facts.effective.green == .auto
        guard facts.explicit || (auto && facts.effective.watching && !facts.roundsExhausted && !facts.paused) else {
            return .held(stuck: facts.roundsExhausted && auto)
        }
        if !facts.isFixture {
            switch Runs.ownStart(explicit: facts.explicit, trusted: facts.trusted()) {
            case .go: break
            case .hold: return .heldForAuthor
            case .ask: return .resolveTrust
            }
            if facts.runIn == .helper, !facts.swarm { return .helper }
        }
        guard facts.hasSession else { return .noSession }
        if facts.isFixture { return .fixture(tutor: facts.tutor) }
        if facts.runIn == .session, !facts.swarm { return .inSession }
        if facts.runWorking { return .waitForRun }
        if facts.swarm, facts.needsHandback {
            switch facts.handback() {
            case let .worker(worker): return .returnToWorker(worker)
            case let .wait(why): return .waitForWorker(why)
            case let .pilot(why): return .startRun(handback: why)
            }
        }
        return .startRun(handback: nil)
    }
}
