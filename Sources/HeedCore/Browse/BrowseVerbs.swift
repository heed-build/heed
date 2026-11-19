import Foundation

/// What an agent can be asked to do with an item.
public enum BrowseVerb: String, CaseIterable, Hashable, Sendable, Codable {
    case fix, implement, chat, review

    public var title: String {
        switch self {
        case .fix: "Fix"
        case .implement: "Implement"
        case .chat: "Chat"
        case .review: "Review"
        }
    }

    /// The key inside Browse.
    public var key: String {
        switch self {
        case .fix: "F"
        case .implement: "I"
        case .chat: "C"
        case .review: "R"
        }
    }

    public var command: String { "browse.\(rawValue)" }

    /// What the verb does, as its button says when it is on offer.
    public var summary: String {
        switch self {
        case .fix: "Reproduce, fix, test and open a PR. Comments on the issue."
        case .implement: "Build it with tests and open a PR that closes the issue."
        case .chat: "Ask questions, find the cause, draft a reply. No edits."
        case .review: "Reads the diff, runs the tests, drafts a review you approve or edit before it is posted."
        }
    }
}

public enum BrowseAvailability: String, Hashable, Sendable {
    /// What heed suggests: at most one.
    case recommended
    case available
    /// Does not fit this item; the reason says why.
    case unavailable
}

public struct BrowseVerbAdvice: Hashable, Sendable {
    /// Advice for the pull request's own tracking action (Get it merged), which is no agent run.
    public struct Pull: Hashable, Sendable {
        public var availability: BrowseAvailability
        public var reason: String

        public init(_ availability: BrowseAvailability, _ reason: String) {
            self.availability = availability
            self.reason = reason
        }
    }

    public var verb: BrowseVerb
    public var availability: BrowseAvailability
    /// One line: why it is suggested, or why it is on offer or not.
    public var reason: String

    public init(_ verb: BrowseVerb, _ availability: BrowseAvailability, _ reason: String) {
        self.verb = verb
        self.availability = availability
        self.reason = reason
    }
}

/// What heed says about the four verbs for one item: all four, always. Pure: from the item, heed's read of it and
/// who you are.
///
/// The table:
/// - closed or merged: Chat only.
/// - a pull request: yours with failing checks or changes requested, Fix (address the feedback); your review
///   requested, Review; otherwise nothing is suggested. Implement never fits a pull request, Fix on another's pull
///   request only when something is failing, Review not on your own.
/// - an issue with no read yet: nothing is suggested (Fix and Implement are on offer once heed reads it).
/// - an issue, read: a question, or under 50% agent-ready, or with a pull request already linked, Chat; a bug at
///   50% or more with no pull request, Fix; a feature, docs or chore at 50% or more with no pull request, Implement.
public struct BrowseVerbs: Hashable, Sendable {
    /// Below this agent-readiness heed would be guessing, so Chat leads.
    public static let clearLine = 50

    /// Get it merged on an open pull request (`pilot.merge`, the PR tracking's own mode): the advice beside the four
    /// verbs. Nil for an issue and for a pull request that is closed or merged. On a pull request Fix is shown as Get
    /// it green (`pilot.green`) and Implement is left out.
    public var merge: BrowseVerbAdvice.Pull?

    /// All four, in the order Fix, Implement, Chat, Review.
    public var advice: [BrowseVerbAdvice]

    public subscript(_ verb: BrowseVerb) -> BrowseVerbAdvice { advice.first { $0.verb == verb }! }

    public var recommended: BrowseVerbAdvice? { advice.first { $0.availability == .recommended } }

    /// Whether get it merged is the suggestion (no verb is then).
    public var recommendsMerge: Bool { merge?.availability == .recommended }

    /// The buttons' order: the suggestion first, the rest as they are.
    public var ordered: [BrowseVerbAdvice] {
        advice.filter { $0.availability == .recommended } + advice.filter { $0.availability != .recommended }
    }

    /// The line over the buttons: why the suggestion, or that there is none.
    public var headline: String {
        recommended?.reason ?? (recommendsMerge ? merge?.reason : nil) ?? "No suggestion yet"
    }

    public static func recommend(item: BrowseItem, read: BrowseRead?, viewer: String?) -> BrowseVerbs {
        func suggest(
            fix: (BrowseAvailability, String), implement: (BrowseAvailability, String),
            chat: (BrowseAvailability, String), review: (BrowseAvailability, String)
        ) -> BrowseVerbs {
            BrowseVerbs(advice: [
                .init(.fix, fix.0, fix.1), .init(.implement, implement.0, implement.1),
                .init(.chat, chat.0, chat.1), .init(.review, review.0, review.1),
            ])
        }
        let ask = "Ask questions, find the cause, draft a reply. No edits."
        if item.state != .open {
            let why = item.state == .merged ? "Already merged" : "Already closed"
            return suggest(
                fix: (.unavailable, "\(why): nothing left to push."),
                implement: (.unavailable, "\(why): nothing left to build."),
                chat: (.recommended, "\(why): ask about it or draft a reply"),
                review: (.unavailable, item.kind == .pull ? "\(why): nothing left to review." : noPull())
            )
        }
        let mine = viewer.map { item.author?.caseInsensitiveCompare($0) == .orderedSame } ?? false
        if item.kind == .pull { return pull(item, mine: mine, viewer: viewer, ask: ask) }

        let review: (BrowseAvailability, String) = item.hasLinkedPull
            ? (.available, "A pull request closes this issue: heed finds it and reviews it.")
            : (.unavailable, noPull())
        guard let read else {
            return suggest(
                fix: (.available, "Not read yet: read it first to see whether it is a bug."),
                implement: (.available, "Not read yet: read it first to see whether it is a feature."),
                chat: (.available, ask), review: review
            )
        }
        let ready = read.agentReady
        let guessing = "Possible, but heed would be guessing the design."
        switch read.kind {
        case .question:
            return suggest(
                fix: (.unavailable, "A question, not a change to make."),
                implement: (.unavailable, "A question, not a feature request."),
                chat: (.recommended, "A question: talk it through, no edits"), review: review
            )
        case .bug:
            let notFeature = (BrowseAvailability.unavailable, "Not a feature, so Fix fits better here.")
            if item.hasLinkedPull {
                return suggest(
                    fix: (.available, "A pull request is already linked to this bug."), implement: notFeature,
                    chat: (.recommended, "A pull request already addresses this: talk it over"), review: review
                )
            }
            if ready >= clearLine {
                let how = ready >= BrowseRead.readyLine ? "Clear bug" : "Likely a bug, \(ready)% agent-ready"
                let size = ready >= BrowseRead.readyLine ? ", \(read.size.title.lowercased())" : ""
                return suggest(
                    fix: (.recommended, "\(how)\(size), no PR yet"), implement: notFeature,
                    chat: (.available, ask), review: review
                )
            }
            return suggest(
                fix: (.available, guessing), implement: notFeature,
                chat: (.recommended, "Needs a decision first, only \(ready)% agent-ready"), review: review
            )
        case .feature, .docs, .chore:
            let notBug = (BrowseAvailability.unavailable, "Not a bug, so Implement fits better here.")
            let what = read.kind == .feature ? "feature request" : read.kind.rawValue
            if item.hasLinkedPull {
                return suggest(
                    fix: notBug, implement: (.available, "A pull request is already linked to this."),
                    chat: (.recommended, "A pull request already addresses this: talk it over"), review: review
                )
            }
            if ready >= clearLine {
                return suggest(
                    fix: notBug,
                    implement: (.recommended, "Clear \(what), \(read.size.title.lowercased()), no PR yet"),
                    chat: (.available, ask), review: review
                )
            }
            return suggest(
                fix: notBug, implement: (.available, guessing),
                chat: (.recommended, "Needs a decision first, only \(ready)% agent-ready"), review: review
            )
        }
    }

    /// Get it merged: suggested on your own pull request once its checks are green and nobody asks for changes; on
    /// offer on any other open one (it waits for green first); not on a draft.
    private static func mergeAdvice(_ item: BrowseItem, mine: Bool, failing: Bool, changes: Bool) -> BrowseVerbAdvice.Pull {
        if item.isDraft { return .init(.unavailable, "Still a draft: mark it ready first.") }
        if mine, item.checks == .passing, !changes { return .init(.recommended, "Your PR is green: get it merged") }
        if failing || changes { return .init(.available, "Gets it green first, then merges it.") }
        return .init(.available, "Watches the PR and merges it by your rules once it is green.")
    }

    private static func noPull() -> String { "No pull request linked to this issue yet." }

    private static func pull(_ item: BrowseItem, mine: Bool, viewer: String?, ask: String) -> BrowseVerbs {
        let implement = BrowseVerbAdvice(
            .implement,
            .unavailable,
            "Pull requests are reviewed or fixed, not implemented."
        )
        let failing = item.checks == .failing
        let changes = item.review == .changesRequested
        let requested = viewer.map { who in
            item.requestedReviewers?.contains { $0.caseInsensitiveCompare(who) == .orderedSame } ?? false
        } ?? false
        let checks = item.checks
            .map { ", CI \($0 == .passing ? "green" : $0 == .failing ? "failing" : "running")" } ?? ""

        let fix: BrowseVerbAdvice
        if mine, failing || changes {
            let why = failing && changes
                ? "Your PR has failing checks and requested changes"
                : failing ? "Your PR has failing checks" : "Changes were requested on your PR"
            fix = .init(.fix, .recommended, "\(why): address the feedback")
        } else if failing || changes {
            fix = .init(.fix, .available, failing ? "CI is failing on this PR." : "Changes were requested on this PR.")
        } else if item.checks == .passing {
            fix = .init(.fix, .unavailable, "Nothing to fix: CI is green.")
        } else {
            fix = .init(.fix, .available, "Watches the PR and fixes what fails.")
        }

        var review: BrowseVerbAdvice = if mine {
            .init(.review, .unavailable, "This is your own pull request.")
        } else if requested {
            .init(
                .review,
                fix.availability == .recommended ? .available : .recommended,
                "Review requested\(checks)"
            )
        } else {
            .init(.review, .available, "Not requested of you, but you can read the diff.")
        }
        if item.isDraft, review.availability == .recommended {
            review = .init(.review, .available, "Review requested, but it is still a draft")
        }
        var answer = BrowseVerbs(advice: [fix, implement, .init(.chat, .available, ask), review])
        answer.merge = mergeAdvice(item, mine: mine, failing: failing, changes: changes)
        return answer
    }
}
