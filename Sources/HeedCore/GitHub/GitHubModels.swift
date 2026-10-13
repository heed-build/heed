import Foundation

/// Everything Heed knows from GitHub, as domain values. Cached with the rest of the domain, so the Inbox, Issues and
/// PRs views draw instantly on launch and keep working offline.
public struct GitHubState: Hashable, Sendable, Codable {
    public var viewer: String?
    public var inbox: [InboxItem]
    public var issues: [Issue]
    public var pulls: [PullRequest]
    public var syncedAt: Date?
    public var status: SyncStatus

    public init(
        viewer: String? = nil, inbox: [InboxItem] = [], issues: [Issue] = [], pulls: [PullRequest] = [],
        syncedAt: Date? = nil, status: SyncStatus = .never
    ) {
        self.viewer = viewer
        self.inbox = inbox
        self.issues = issues
        self.pulls = pulls
        self.syncedAt = syncedAt
        self.status = status
    }

    public func pull(_ ref: PullRef) -> PullRequest? { pulls.first { $0.ref == ref } }

    /// PRs that need you: failing checks, changes requested or unresolved review threads.
    public var pullsNeedingAttention: Int {
        pulls.count { $0.checks.failed > 0 || $0.review == .changesRequested || $0.unresolvedThreads > 0 }
    }
}

public enum SyncStatus: Hashable, Sendable, Codable {
    case never
    case ok
    /// Synced, but GitHub hid some items (SAML-protected orgs the gh token is not authorized for).
    case partial(hidden: Int, note: String)
    /// gh failed (network, not installed, not signed in): showing the cache.
    case offline(String)

    public var isOffline: Bool { if case .offline = self { true } else { false } }
}

public struct InboxItem: Identifiable, Hashable, Sendable, Codable {
    public enum Kind: String, Hashable, Sendable, Codable {
        case pr = "PR", issue = "ISSUE", ci = "CI", release = "RELEASE", discussion = "DISCUSSION", other = "OTHER"
    }

    /// The notification thread id (for marking read).
    public var id: String
    public var kind: Kind
    public var repo: Repo
    public var number: Int?
    public var title: String
    /// GitHub's reason: `review_requested`, `assign`, `mention`, `author`, `ci_activity`, `subscribed`, ...
    public var reason: String
    public var unread: Bool
    public var updatedAt: Date
    /// The web page for the subject, when it has one.
    public var url: String?

    public init(
        id: String, kind: Kind, repo: Repo, number: Int?, title: String, reason: String, unread: Bool,
        updatedAt: Date, url: String?
    ) {
        self.id = id
        self.kind = kind
        self.repo = repo
        self.number = number
        self.title = title
        self.reason = reason
        self.unread = unread
        self.updatedAt = updatedAt
        self.url = url
    }

    /// `review requested`, `assigned to you`, `mentioned`, ...
    public var reasonText: String {
        switch reason {
        case "review_requested": "review requested"
        case "assign": "assigned to you"
        case "mention", "team_mention": "mentioned"
        case "author": "your thread"
        case "ci_activity": "check failed"
        case "comment": "comments"
        case "state_change": "state changed"
        case "subscribed": "subscribed"
        default: reason.replacingOccurrences(of: "_", with: " ")
        }
    }
}

public struct Issue: Identifiable, Hashable, Sendable, Codable {
    public var id: String { "\(repo.slug)#\(number)" }
    public var repo: Repo
    public var number: Int
    public var title: String
    public var url: String
    /// The first part of the body, for building a prompt.
    public var body: String
    public var labels: [String]
    public var author: String?
    public var updatedAt: Date
    /// Assigned to you / mentions you. Neither: it is shown because its repo shows all issues.
    public var assigned = false
    public var mentioned = false

    public var involvesYou: Bool { assigned || mentioned }

    public init(
        repo: Repo, number: Int, title: String, url: String, body: String, labels: [String], author: String?,
        updatedAt: Date, assigned: Bool = false, mentioned: Bool = false
    ) {
        self.assigned = assigned
        self.mentioned = mentioned
        self.repo = repo
        self.number = number
        self.title = title
        self.url = url
        self.body = body
        self.labels = labels
        self.author = author
        self.updatedAt = updatedAt
    }
}

public enum ReviewDecision: String, Hashable, Sendable, Codable {
    case approved = "APPROVED"
    case changesRequested = "CHANGES_REQUESTED"
    case reviewRequired = "REVIEW_REQUIRED"

    public var text: String {
        switch self {
        case .approved: "approved"
        case .changesRequested: "changes requested"
        case .reviewRequired: "review required"
        }
    }
}

public struct CheckSummary: Hashable, Sendable, Codable {
    public var passed: Int
    public var failed: Int
    public var pending: Int
    public var skipped: Int
    public var failedNames: [String]
    /// The checks still running, so a failure that has since passed resolves without waiting on unrelated ones.
    public var pendingNames: [String]

    public init(
        passed: Int = 0, failed: Int = 0, pending: Int = 0, skipped: Int = 0, failedNames: [String] = [],
        pendingNames: [String] = []
    ) {
        self.passed = passed
        self.failed = failed
        self.pending = pending
        self.skipped = skipped
        self.failedNames = failedNames
        self.pendingNames = pendingNames
    }

    // pendingNames came later: caches written before it still decode.
    private enum CodingKeys: String, CodingKey { case passed, failed, pending, skipped, failedNames, pendingNames }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        passed = try container.decode(Int.self, forKey: .passed)
        failed = try container.decode(Int.self, forKey: .failed)
        pending = try container.decode(Int.self, forKey: .pending)
        skipped = try container.decode(Int.self, forKey: .skipped)
        failedNames = try container.decode([String].self, forKey: .failedNames)
        pendingNames = try container.decodeIfPresent([String].self, forKey: .pendingNames) ?? []
    }

    public var total: Int { passed + failed + pending }

    /// `lint failed`, `2/5 running`, `4/4 passed`, `no checks`.
    public var text: String {
        if total == 0 { return "no checks" }
        if failed > 0 { return failedNames.count == 1 ? "\(failedNames[0]) failed" : "\(failed) failed" }
        if pending > 0 { return "\(passed)/\(total) running" }
        return "\(passed)/\(total) passed"
    }
}

public struct PullRequest: Identifiable, Hashable, Sendable, Codable {
    public enum State: String, Hashable, Sendable, Codable {
        case open = "OPEN", closed = "CLOSED", merged = "MERGED"
    }

    public var id: String { ref.description }
    public var ref: PullRef
    public var title: String
    public var url: String
    public var state: State
    public var isDraft: Bool
    public var headBranch: String
    public var review: ReviewDecision?
    public var checks: CheckSummary
    public var unresolvedThreads: Int
    public var updatedAt: Date

    public init(
        ref: PullRef, title: String, url: String, state: State, isDraft: Bool, headBranch: String,
        review: ReviewDecision?, checks: CheckSummary, unresolvedThreads: Int, updatedAt: Date
    ) {
        self.ref = ref
        self.title = title
        self.url = url
        self.state = state
        self.isDraft = isDraft
        self.headBranch = headBranch
        self.review = review
        self.checks = checks
        self.unresolvedThreads = unresolvedThreads
        self.updatedAt = updatedAt
    }
}

/// Builds the one prompt Start work gets when it starts from several inbox items or issues.
public enum WorkPrompt {
    public static func from(issues: [Issue], closesLines: Bool = true) -> String {
        guard !issues.isEmpty else { return "" }
        if issues.count == 1, let issue = issues.first {
            var text = "\(issue.title) (\(issue.repo.name)#\(issue.number))\n\n\(issue.body.prefix(1500))"
            if closesLines { text += "\n\nCloses \(issue.repo.slug)#\(issue.number)" }
            return text
        }
        var lines = ["Work on these together. They look related; open one PR that addresses all of them."]
        lines += issues.map { "- \($0.repo.name)#\($0.number) \($0.title)" }
        if closesLines {
            lines.append("")
            lines += issues.map { "Closes \($0.repo.slug)#\($0.number)" }
        }
        return lines.joined(separator: "\n")
    }

    public static func from(inbox items: [InboxItem]) -> String {
        guard !items.isEmpty else { return "" }
        let refs = items.map { item in
            "- \(item.repo.name)\(item.number.map { "#\($0)" } ?? "") \(item.title) (\(item.reasonText))"
        }
        return (["Look into these:"] + refs).joined(separator: "\n")
    }
}

/// Links PRs to sessions: a PR whose head branch is a session's branch, in one of its repos, is tracked by it.
public enum PullTracking {
    public static func changes(sessions: [Session], pulls: [PullRequest], now: Date = Date()) -> [DomainChange] {
        sessions.compactMap { session -> DomainChange? in
            let matches = pulls.filter { pull in
                pull.headBranch == session.branch && session.repos.contains(pull.ref.repo)
                    && !session.trackedPRs.contains(pull.ref)
            }
            guard !matches.isEmpty else { return nil }
            var updated = session
            for pull in matches {
                updated.trackedPRs.append(pull.ref)
                updated.record("tracking PR \(pull.ref.repo.name)#\(pull.ref.number) (branch match)", at: now)
            }
            return .sessionUpserted(updated)
        }
    }
}

/// Which issues the Issues view shows for a repo. Issues assigned to you or mentioning you always show.
public enum IssueVisibility: String, CaseIterable, Sendable, Codable {
    /// Every open issue.
    case all
    /// Only those assigned to you or mentioning you.
    case involved
}

/// `[issues] default`, `[orgs.<org>] issues` and `[repos."org/name"] issues`: the most specific one wins.
public struct IssueRules: Equatable, Sendable {
    public var fallback: IssueVisibility
    public var orgs: [String: IssueVisibility]
    public var repos: [String: IssueVisibility]

    public init(
        fallback: IssueVisibility = .involved, orgs: [String: IssueVisibility] = [:],
        repos: [String: IssueVisibility] = [:]
    ) {
        self.fallback = fallback
        self.orgs = orgs
        self.repos = repos
    }

    public func visibility(_ repo: Repo) -> IssueVisibility {
        repos[repo.slug] ?? orgs[repo.org] ?? fallback
    }

    /// Search qualifiers for the repos that show all issues: `org:` for orgs set to all (a repo there set to
    /// involved is dropped after fetching), `repo:` for the rest, including local repos when the fallback is all.
    public func watchQualifiers(local: [Repo]) -> [String] {
        let watchedOrgs = orgs.filter { $0.value == .all }.keys.sorted()
        var repoSlugs = Set(repos.filter { $0.value == .all }.keys)
        if fallback == .all {
            repoSlugs.formUnion(local.filter { orgs[$0.org] == nil && repos[$0.slug] == nil }.map(\.slug))
        }
        let outside = repoSlugs.filter { slug in !watchedOrgs.contains { slug.hasPrefix("\($0)/") } }.sorted()
        return watchedOrgs.map { "org:\($0)" } + outside.map { "repo:\($0)" }
    }
}
