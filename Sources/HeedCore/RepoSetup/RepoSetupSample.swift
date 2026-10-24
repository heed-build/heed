import Foundation

/// What GitHub says about how a repo merges: the merge buttons it allows, auto-merge, its branch protection and
/// rulesets on the default branch, and what the viewer may do there. Read by the setup wizard (`repo.setup`) and the
/// Repos view's readiness line; heed never changes any of it.
public struct RepoMergeSettings: Hashable, Sendable, Codable {
    public var defaultBranch: String
    /// The merge buttons the repo allows, in heed's order (`squash`, `merge`, `rebase`).
    public var repoMethods: [String]
    /// What a ruleset's pull request rule narrows them to; nil when no rule does.
    public var rulesetMethods: [String]?
    /// nil when not known (a partial view built from a PR's detail, say).
    public var autoMergeAllowed: Bool?
    public var deleteBranchOnMerge: Bool?
    /// `ADMIN`, `MAINTAIN`, `WRITE`, `TRIAGE`, `READ`; nil when not known.
    public var viewerPermission: String?
    public var requiredChecks: [String]
    public var requiredApprovals: Int
    public var linearHistory: Bool
    /// Branches must be up to date before merging.
    public var strictChecks: Bool
    public var mergeQueue: Bool
    /// An approval must come after the last push (`require_last_push_approval`).
    public var lastPushApproval: Bool
    public var codeOwnerReview: Bool
    /// A ruleset asks Copilot to review each PR.
    public var copilotReview: Bool
    public var hasCodeowners: Bool

    public init(
        defaultBranch: String = "main", repoMethods: [String] = ["squash", "merge", "rebase"],
        rulesetMethods: [String]? = nil, autoMergeAllowed: Bool? = nil, deleteBranchOnMerge: Bool? = nil,
        viewerPermission: String? = nil, requiredChecks: [String] = [], requiredApprovals: Int = 0,
        linearHistory: Bool = false, strictChecks: Bool = false, mergeQueue: Bool = false,
        lastPushApproval: Bool = false, codeOwnerReview: Bool = false, copilotReview: Bool = false,
        hasCodeowners: Bool = false
    ) {
        self.defaultBranch = defaultBranch
        self.repoMethods = repoMethods
        self.rulesetMethods = rulesetMethods
        self.autoMergeAllowed = autoMergeAllowed
        self.deleteBranchOnMerge = deleteBranchOnMerge
        self.viewerPermission = viewerPermission
        self.requiredChecks = requiredChecks
        self.requiredApprovals = requiredApprovals
        self.linearHistory = linearHistory
        self.strictChecks = strictChecks
        self.mergeQueue = mergeQueue
        self.lastPushApproval = lastPushApproval
        self.codeOwnerReview = codeOwnerReview
        self.copilotReview = copilotReview
        self.hasCodeowners = hasCodeowners
    }

    /// The methods a merge can use: the repo's buttons, narrowed by its rulesets, without `merge` under linear
    /// history.
    public var methods: [String] {
        var allowed = repoMethods
        if let rulesetMethods { allowed = allowed.filter(rulesetMethods.contains) }
        if linearHistory { allowed.removeAll { $0 == "merge" } }
        return allowed
    }

    /// What the pilot's readiness check reads (`RepoMergeReadiness`).
    public var facts: RepoMergeFacts {
        RepoMergeFacts(
            allowsAutoMerge: autoMergeAllowed, methods: methods, linearHistory: linearHistory,
            viewerPermission: viewerPermission
        )
    }

    /// nil when the viewer's permission is not known.
    public var isAdmin: Bool? { viewerPermission.map { $0 == "ADMIN" } }

    /// The repo's settings pages, where each fix is made.
    public static func settingsURL(_ repo: Repo, page: SettingsPage = .general) -> String {
        "https://github.com/\(repo.slug)/settings" + page.path
    }

    public enum SettingsPage: Sendable {
        case general, branches, rules

        var path: String {
            switch self {
            case .general: ""
            case .branches: "/branches"
            case .rules: "/rules"
            }
        }
    }
}

/// One merged PR as the sample saw it: who wrote, reviewed and merged it, what its head commit's checks said, which
/// labels it carried and shed, and how it was merged.
public struct SampledPull: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var author: String
    public var authorIsBot: Bool
    public var mergedBy: String?
    public var createdAt: Date
    public var mergedAt: Date
    /// Its labels as fetched (after the merge).
    public var labels: [String]
    /// Labels taken off before the merge and not put back.
    public var removedBeforeMerge: [String]
    /// Every label it carried at some point before the merge.
    public var labelsSeen: [String]
    /// The merge commit's parents: 2 is a merge commit, 1 a squash or a rebase; nil when GitHub has none.
    public var parents: Int?
    public var commits: Int
    public var autoMerge: Bool
    public var mergeQueue: Bool
    public var reviews: [PullDetail.Review]
    /// Reviewers that are bots (GitHub apps, `…[bot]`, Copilot's reviewer).
    public var botReviewers: Set<String>
    public var threads: [ReviewThread]
    public var headSHA: String
    public var headCommittedAt: Date?
    public var passedChecks: [String]
    public var failedChecks: [String]
    public var pendingChecks: [String]

    public init(
        number: Int, title: String = "", author: String, authorIsBot: Bool = false, mergedBy: String? = nil,
        createdAt: Date, mergedAt: Date, labels: [String] = [], removedBeforeMerge: [String] = [],
        labelsSeen: [String] = [], parents: Int? = 1, commits: Int = 1, autoMerge: Bool = false,
        mergeQueue: Bool = false, reviews: [PullDetail.Review] = [], botReviewers: Set<String> = [],
        threads: [ReviewThread] = [], headSHA: String = "", headCommittedAt: Date? = nil, passedChecks: [String] = [],
        failedChecks: [String] = [], pendingChecks: [String] = []
    ) {
        self.number = number
        self.title = title
        self.author = author
        self.authorIsBot = authorIsBot
        self.mergedBy = mergedBy
        self.createdAt = createdAt
        self.mergedAt = mergedAt
        self.labels = labels
        self.removedBeforeMerge = removedBeforeMerge
        self.labelsSeen = labelsSeen.isEmpty ? labels + removedBeforeMerge : labelsSeen
        self.parents = parents
        self.commits = commits
        self.autoMerge = autoMerge
        self.mergeQueue = mergeQueue
        self.reviews = reviews
        self.botReviewers = botReviewers
        self.threads = threads
        self.headSHA = headSHA
        self.headCommittedAt = headCommittedAt
        self.passedChecks = passedChecks
        self.failedChecks = failedChecks
        self.pendingChecks = pendingChecks
    }

    /// The last thing that happened to it before the merge: its head commit, or a review.
    public var lastActivity: Date? {
        ([headCommittedAt] + reviews.map(\.submittedAt)).compactMap(\.self).filter { $0 <= mergedAt }.max()
    }

    /// Approved by someone other than a bot, on any commit.
    public var humanApproved: Bool {
        reviews.contains { $0.state == "APPROVED" && !botReviewers.contains($0.author) && $0.author != author }
    }
}

/// What the repo's CI did on PRs lately: workflows that passed only on a re-run, and why runs failed.
public struct CIHistory: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case lint = "lint or format", test, build, infra = "setup or infrastructure", other
    }

    /// A workflow that passed on a second (or later) attempt.
    public struct Flaky: Hashable, Sendable {
        public var workflow: String
        public var retried: Int
        public var runs: Int

        public init(workflow: String, retried: Int, runs: Int) {
            self.workflow = workflow
            self.retried = retried
            self.runs = runs
        }
    }

    public struct Failure: Hashable, Sendable {
        public var workflow: String
        public var job: String
        public var step: String?
        public var kind: Kind

        public init(workflow: String, job: String, step: String? = nil, kind: Kind) {
            self.workflow = workflow
            self.job = job
            self.step = step
            self.kind = kind
        }
    }

    /// PR runs looked at.
    public var runs: Int
    public var flaky: [Flaky]
    public var failures: [Failure]

    public init(runs: Int = 0, flaky: [Flaky] = [], failures: [Failure] = []) {
        self.runs = runs
        self.flaky = flaky
        self.failures = failures
    }

    public func count(_ kind: Kind) -> Int { failures.count { $0.kind == kind } }
}

/// Everything the wizard sampled for one repo, and what it cost.
public struct RepoSetupSample: Hashable, Sendable {
    public var repo: Repo
    public var settings: RepoMergeSettings
    /// Newest first.
    public var pulls: [SampledPull]
    public var ci: CIHistory
    /// heed's own get it green / get it merged runs on this repo's PRs.
    public var runs: [PilotRun]
    /// Tasks found in the repo's checkout (lint and format ones become a hint for get it green).
    public var tasks: [TaskSpec]
    /// GitHub calls made, and the GraphQL points they cost.
    public var calls: Int
    public var cost: Int

    public init(
        repo: Repo, settings: RepoMergeSettings, pulls: [SampledPull], ci: CIHistory = CIHistory(),
        runs: [PilotRun] = [], tasks: [TaskSpec] = [], calls: Int = 0, cost: Int = 0
    ) {
        self.repo = repo
        self.settings = settings
        self.pulls = pulls
        self.ci = ci
        self.runs = runs
        self.tasks = tasks
        self.calls = calls
        self.cost = cost
    }
}
