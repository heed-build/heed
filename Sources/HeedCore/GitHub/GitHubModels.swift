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
    /// The teams you are on, refreshed daily: what `team_mention`s are attributed against.
    public var teams: ViewerTeams
    /// Which team each `team_mention` and `review_requested` thread came through, by thread id.
    public var teamMentions: TeamMentionCache

    public init(
        viewer: String? = nil, inbox: [InboxItem] = [], issues: [Issue] = [], pulls: [PullRequest] = [],
        syncedAt: Date? = nil, status: SyncStatus = .never, teams: ViewerTeams = ViewerTeams(),
        teamMentions: TeamMentionCache = TeamMentionCache()
    ) {
        self.viewer = viewer
        self.inbox = inbox
        self.issues = issues
        self.pulls = pulls
        self.syncedAt = syncedAt
        self.status = status
        self.teams = teams
        self.teamMentions = teamMentions
    }

    private enum CodingKeys: String, CodingKey {
        case viewer, inbox, issues, pulls, syncedAt, status, teams, teamMentions
    }

    /// Caches from before team attribution still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        viewer = try container.decodeIfPresent(String.self, forKey: .viewer)
        inbox = try container.decode([InboxItem].self, forKey: .inbox)
        issues = try container.decode([Issue].self, forKey: .issues)
        pulls = try container.decode([PullRequest].self, forKey: .pulls)
        syncedAt = try container.decodeIfPresent(Date.self, forKey: .syncedAt)
        status = try container.decode(SyncStatus.self, forKey: .status)
        teams = try container.decodeIfPresent(ViewerTeams.self, forKey: .teams) ?? ViewerTeams()
        teamMentions = try container.decodeIfPresent(TeamMentionCache.self, forKey: .teamMentions)
            ?? TeamMentionCache()
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
    /// The subject's API URL (`https://api.github.com/repos/o/r/pulls/12`), as the notification gave it.
    public var subjectAPI: String?
    /// The viewer's teams (`org/slug`, lowercased) this thread reached you through: the team mentioned, for a
    /// `team_mention`; the team asked to review, for a `review_requested`. Empty when none or not (yet) known.
    public var teams: Set<String>

    public init(
        id: String, kind: Kind, repo: Repo, number: Int?, title: String, reason: String, unread: Bool,
        updatedAt: Date, url: String?, subjectAPI: String? = nil, teams: Set<String> = []
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
        self.subjectAPI = subjectAPI
        self.teams = teams
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, repo, number, title, reason, unread, updatedAt, url, subjectAPI, teams
    }

    /// Caches from before team attribution still load.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(Kind.self, forKey: .kind)
        repo = try container.decode(Repo.self, forKey: .repo)
        number = try container.decodeIfPresent(Int.self, forKey: .number)
        title = try container.decode(String.self, forKey: .title)
        reason = try container.decode(String.self, forKey: .reason)
        unread = try container.decode(Bool.self, forKey: .unread)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        url = try container.decodeIfPresent(String.self, forKey: .url)
        subjectAPI = try container.decodeIfPresent(String.self, forKey: .subjectAPI)
        teams = try container.decodeIfPresent(Set<String>.self, forKey: .teams) ?? []
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

    /// What a check summary says, part by part, so each can take its state's colour.
    public enum Part: Hashable, Sendable {
        case passed(String), failed(String), running(String), skipped(String), none(String)

        public var text: String {
            switch self {
            case let .passed(text), let .failed(text), let .running(text), let .skipped(text), let .none(text): text
            }
        }
    }

    /// `10/12 passed`, then `lint failed` (or `2 failed`), `1 running` and `3 skipped` when there are any.
    /// Skipped checks are not counted in the total.
    public var parts: [Part] {
        if total == 0 { return [.none(skipped > 0 ? "\(skipped) skipped" : "no checks")] }
        var parts: [Part] = [.passed("\(passed)/\(total) passed")]
        if failed >
            0
        {
            parts
                .append(.failed(failedNames
                        .count == 1 && failed == 1 ? "\(failedNames[0]) failed" : "\(failed) failed"))
        }
        if pending > 0 { parts.append(.running("\(pending) running")) }
        if skipped > 0 { parts.append(.skipped("\(skipped) skipped")) }
        return parts
    }

    /// `10/12 passed · lint failed · 1 running`, `4/4 passed`, `no checks`.
    public var text: String { parts.map(\.text).joined(separator: " · ") }
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

/// Builds the one prompt Start work gets when it starts from several inbox items or issues. `instructions` (the
/// repo's `start_instructions`) go after the issue text, before the `Closes` lines.
public enum WorkPrompt {
    public static func from(issues: [Issue], closesLines: Bool = true, instructions: String = "") -> String {
        guard !issues.isEmpty else { return "" }
        let extra = instructions.isEmpty ? [] : ["", instructions]
        if issues.count == 1, let issue = issues.first {
            var lines = ["\(issue.title) (\(issue.repo.name)#\(issue.number))", "", String(issue.body.prefix(1500))]
            lines += extra
            if closesLines { lines += ["", "Closes \(issue.repo.slug)#\(issue.number)"] }
            return lines.joined(separator: "\n")
        }
        var lines = ["Work on these together. They look related; open one PR that addresses all of them."]
        lines += issues.map { "- \($0.repo.name)#\($0.number) \($0.title)" }
        lines += extra
        if closesLines {
            lines.append("")
            lines += issues.map { "Closes \($0.repo.slug)#\($0.number)" }
        }
        return lines.joined(separator: "\n")
    }

    public static func from(inbox items: [InboxItem], instructions: String = "") -> String {
        guard !items.isEmpty else { return "" }
        let refs = items.map { item in
            "- \(item.repo.name)\(item.number.map { "#\($0)" } ?? "") \(item.title) (\(item.reasonText))"
        }
        return (["Look into these:"] + refs + (instructions.isEmpty ? [] : ["", instructions])).joined(separator: "\n")
    }
}

/// Links PRs to sessions: a PR whose head branch is one of a session's branches, in one of its repos, is tracked by
/// it.
public enum PullTracking {
    public static func changes(sessions: [Session], pulls: [PullRequest], now: Date = Date()) -> [DomainChange] {
        sessions.compactMap { session -> DomainChange? in
            var updated = session
            let added = pulls.filter { pull in
                session.branches.contains(pull.headBranch) && session.repos.contains(pull.ref.repo)
                    && updated.track(pull.ref, because: "branch \(pull.headBranch)", at: now)
            }
            return added.isEmpty ? nil : .sessionUpserted(updated)
        }
    }

    /// PRs that mention one of a session's PRs: yours, open, and opened after the session started are its own
    /// (follow-ups, companion changes); anyone else's are only suggested.
    public static func linked(
        _ references: [PullDetail.Reference], session: Session, viewer: String?
    ) -> (track: [PullDetail.Reference], suggest: [PullDetail.Reference]) {
        let fresh = references.filter { reference in
            !session.trackedPRs.contains(reference.ref) && !session.untrackedPRs.contains(reference.ref)
                && reference.state == "OPEN"
        }
        let mine = fresh.filter { reference in
            viewer.map { reference.author?.lowercased() == $0.lowercased() } == true
                && (reference.createdAt.map { $0 >= session.createdAt } ?? false)
        }
        return (mine, fresh.filter { !mine.contains($0) })
    }
}

/// A session follows its worktrees from branch to branch: merge, then `git switch -c next`, and the session is on
/// `next` too.
public enum BranchFollowing {
    public static func follow(_ session: Session, worktrees: [Worktree], now: Date = Date()) -> Session {
        var session = session
        for worktree in worktrees where session.owns(worktree) {
            if !session.worktreePaths.contains(worktree.path) { session.worktreePaths.append(worktree.path) }
            guard let branch = worktree.branch, !session.branches.contains(branch) else { continue }
            session.branches.append(branch)
            session.record("now on \(branch) in \(worktree.repo.name)", at: now)
        }
        return session
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
