import Foundation

/// What an open PR's card in the inspector shows, read from heed's facts: who reviewed and how, what the session's
/// agent is doing about it, heed's runs and switches, and the one thing that waits for you, if anything.
public struct PullCard: Hashable, Sendable {
    /// A reviewer's face on the card, ringed by their latest verdict.
    public struct Reviewer: Hashable, Sendable {
        public enum Verdict: String, Hashable, Sendable {
            case approved, changes, commented
        }

        public var login: String
        public var verdict: Verdict
    }

    /// What waits for you, at the bottom of the card.
    public enum Call: Hashable, Sendable {
        /// Review comments or failing checks heed would send to the agent once you say so.
        case send(count: Int)
        case merge
    }

    public var reviewers: [Reviewer]
    /// `approved`, `changes requested · 2 threads`, `3 new comments`, `no review`.
    public var review: String
    /// What the session's agent is doing about the PR, when anything was sent to it and is not settled yet.
    public var agent: String?
    public var agentWorking: Bool
    /// heed's rounds on it: how many used of how many it gets.
    public struct Rounds: Hashable, Sendable {
        public var used: Int
        public var of: Int
    }

    public var rounds: Rounds?
    /// heed's runs on it, oldest first, at most five (a running one has no outcome yet).
    public var runs: [PilotRun]
    public var green: AutoFeed
    public var merge: MergeMode
    /// Why heed is not acting, when it is holding back.
    public var holding: String?
    public var call: Call?

    public static func make(
        pull: PullRequest, detail: PullDetail?, pipeline: PullFeedback?, settings: PilotSettings, runs: [PilotRun],
        session: Session, readyToMerge: Bool
    ) -> PullCard {
        // Each reviewer's latest word; a comment after an approval does not take the approval back.
        var latest: [String: Reviewer.Verdict] = [:]
        var order: [String] = []
        for review in (detail?.reviews ?? [])
            .sorted(by: { ($0.submittedAt ?? .distantPast) < ($1.submittedAt ?? .distantPast) })
            where review.author != detail?.author
        {
            let verdict: Reviewer.Verdict? = switch review.state.uppercased() {
            case "APPROVED": .approved
            case "CHANGES_REQUESTED": .changes
            case "COMMENTED": latest[review.author] == nil ? .commented : nil
            default: nil
            }
            guard let verdict else { continue }
            if latest[review.author] == nil { order.append(review.author) }
            latest[review.author] = verdict
        }
        let reviewers = order.map { Reviewer(login: $0, verdict: latest[$0]!) }
        let items = pipeline?.items ?? []
        let waiting = items.count { $0.status == .new || $0.status == .queued }
        let sent = items.count { $0.status == .sent }
        let review: String = switch pull.review {
        case .approved?: "approved"
        case .changesRequested?: "changes requested" +
            (pull
                .unresolvedThreads > 0 ?
                " · \(pull.unresolvedThreads) thread\(pull.unresolvedThreads == 1 ? "" : "s")" :
                "")
        default:
            waiting > 0 ? "\(waiting) new comment\(waiting == 1 ? "" : "s")"
                : pull.unresolvedThreads > 0 ? "\(pull.unresolvedThreads) open thread\(pull.unresolvedThreads == 1 ? "" : "s")"
                : "no review"
        }
        let working = session.state.state == .working
        let agent: String? = sent == 0 ? nil
            : working ? "\(session.agent) working on \(sent) sent item\(sent == 1 ? "" : "s")"
            : "\(sent) item\(sent == 1 ? "" : "s") sent to \(session.agent)"
        let mine = runs.filter { $0.ref == pull.ref }.sorted { $0.startedAt < $1.startedAt }.suffix(5)
        let used = pipeline?.rounds ?? 0
        // The call line says why heed waits when it waits for you; this is for the rest.
        let holding: String? = if let until = pipeline?.pausedUntil, until > Clock.now {
            "paused"
        } else if !settings.watch {
            "not watching"
        } else {
            nil
        }
        let call: Call? = if waiting > 0, settings.green != .auto { .send(count: waiting) } else if readyToMerge {
            .merge
        } else {
            nil
        }
        return PullCard(
            reviewers: reviewers, review: review, agent: agent, agentWorking: working && sent > 0,
            rounds: settings.green == .off && used == 0 ? nil : Rounds(used: used, of: settings.maxRounds),
            runs: Array(mine), green: settings.green, merge: settings.merge, holding: holding, call: call
        )
    }
}
