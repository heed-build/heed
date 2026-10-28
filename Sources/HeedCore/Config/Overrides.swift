/// What an org (`[orgs.<name>]`) or a repo (`[repos."org/name"]`) can override, read from the parsed config: which
/// keys each sets, and for any key the value that applies and where it comes from. Settings' Orgs & repos page is
/// built on this.
public enum OverrideScope: Hashable, Sendable {
    case org(String)
    case repo(Repo)

    /// The table in config.toml.
    public var path: [String] {
        switch self {
        case let .org(name): ["orgs", name]
        case let .repo(repo): ["repos", repo.slug]
        }
    }

    public var title: String {
        switch self {
        case let .org(name): name
        case let .repo(repo): repo.slug
        }
    }

    public var isOrg: Bool { if case .org = self { true } else { false } }

    /// The key `GoalMirrorSettings` keeps its per-org and per-repo values under: the org, or `org/name`.
    var goalKey: String {
        switch self {
        case let .org(name): name
        case let .repo(repo): repo.slug
        }
    }
}

/// The tabs Settings › Orgs & repos splits an org's or repo's settings into, so no one tab is a long scroll: the
/// org-wide basics, then the Pilot's settings by what they drive, then the text heed adds to its prompts.
public enum OverrideTab: String, CaseIterable, Sendable, Identifiable {
    /// Color, issues, new worktrees' setup, goal trackers, watching (and a repo's tasks).
    case general
    /// Get it green and the agents and models its runs and merge-conflict runs use.
    case green
    /// Get it merged, what heed waits for before it merges, and merging by hand.
    case merged
    /// Who reviews, whose review counts, self-review, and what Copilot is asked.
    case reviews
    /// Extra instructions for heed's prompts, and signing off with a summary.
    case instructions

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .general: "General"
        case .green: "Get it green"
        case .merged: "Get it merged"
        case .reviews: "Reviews"
        case .instructions: "Instructions"
        }
    }

    /// The title in a narrow window.
    public var shortTitle: String {
        switch self {
        case .general: "General"
        case .green: "Green"
        case .merged: "Merged"
        case .reviews: "Reviews"
        case .instructions: "Prompts"
        }
    }

    /// `:settings.open orgs <tab>`: its name, or a short one.
    public static func named(_ name: String) -> OverrideTab? {
        let short: [String: OverrideTab] = [
            "general": .general, "green": .green, "merged": .merged, "merge": .merged, "reviews": .reviews,
            "reviewers": .reviews, "review": .reviews, "instructions": .instructions, "prompts": .instructions,
        ]
        return short[name.lowercased()]
    }
}

/// Where a value comes from: heed's default (or `[pilot]`), the org, the repo.
public enum OverrideSource: String, Sendable {
    case `default`, org, repo
}

/// A value of an override, as config.toml holds it.
public enum OverrideValue: Hashable, Sendable {
    case bool(Bool)
    case text(String)
    case integer(Int)
    case list([String])

    public var toml: TOMLValue {
        switch self {
        case let .bool(value): .bool(value)
        case let .text(value): .string(value)
        case let .integer(value): .integer(value)
        case let .list(values): .array(values.map { .string($0) })
        }
    }

    public var display: String {
        switch self {
        case let .bool(value): value ? "on" : "off"
        case let .text(value): value.isEmpty ? "none" : value
        case let .integer(value): "\(value)"
        case let .list(values): values.isEmpty ? "none" : values.joined(separator: ", ")
        }
    }
}

/// One key an org or repo can set.
public struct OverrideKey: Identifiable, Sendable {
    public enum Kind: Sendable, Equatable {
        case bool
        case choice([String])
        case integer(ClosedRange<Int>)
        case list
        case text
        /// One of the org palette's names (the app draws the swatches).
        case color
        /// One of the configured agents (the app lists them); empty: the session's.
        case agent
        /// Free text over several lines: instructions added to a prompt.
        case instructions
        /// A GitHub repo as `org/name`; emptied, the override is removed and the value inherits.
        case repoSlug
    }

    /// The key in config.toml.
    public let id: String
    public let label: String
    public let detail: String
    public let kind: Kind
    /// Repo only (`admin_merge`).
    public let repoOnly: Bool
    /// The group the page lists it under.
    public var group: String { Overrides.groups.first { $0.keys.contains(id) }?.title ?? "Other" }
    let read: @Sendable (HeedConfig, OverrideScope) -> OverrideValue?
    let fallback: @Sendable (HeedConfig) -> OverrideValue
}

public enum Overrides {
    /// Every key, in the order the page lists them.
    public static let keys: [OverrideKey] = [
        OverrideKey(
            id: "color", label: "Color", detail: "The chip color; repos take their org's.",
            kind: .color, repoOnly: false,
            read: { config, scope in
                switch scope {
                case let .org(name): config.orgColors[name].map(OverrideValue.text)
                case let .repo(repo): config.repos[repo.slug]?.color.map(OverrideValue.text)
                }
            },
            fallback: { _ in .text("by name") }
        ),
        OverrideKey(
            id: "issues", label: "Issues", detail: "All open issues, or only those assigned to you or mentioning you.",
            kind: .choice(["all", "involved"]), repoOnly: false,
            read: { config, scope in
                switch scope {
                case let .org(name): config.issues.orgs[name].map { .text($0.rawValue) }
                case let .repo(repo): config.issues.repos[repo.slug].map { .text($0.rawValue) }
                }
            },
            fallback: { .text($0.issues.fallback.rawValue) }
        ),
        OverrideKey(
            id: "setup", label: "Setup",
            detail: "Run in each new worktree before the agent. Unset: heed proposes what it detects; empty: nothing.",
            kind: .list, repoOnly: false,
            read: { config, scope in
                switch scope {
                case let .org(name): config.work.setup.orgs[name].map(OverrideValue.list)
                case let .repo(repo): config.work.setup.repos[repo.slug].map(OverrideValue.list)
                }
            },
            fallback: { _ in .list([]) }
        ),
        OverrideKey(
            id: "goals_tracker", label: "Goal tracker",
            detail: "Where a new goal from work here mirrors on GitHub, as org/name (any repo you can triage). "
                + "The default is General › Goals' tracker.",
            kind: .repoSlug, repoOnly: false,
            read: { config, scope in config.goals.mirror.trackers[scope.goalKey].map(OverrideValue.text) },
            fallback: { .text($0.goals.mirror.tracker) }
        ),
        OverrideKey(
            id: "goals_mirror", label: "Mirror new goals",
            detail: "New goals from work here mirror from the start; off, M on a goal turns it on.",
            kind: .bool, repoOnly: false,
            read: { config, scope in config.goals.mirror.mirrors[scope.goalKey].map(OverrideValue.bool) },
            fallback: { .bool($0.goals.mirror.on) }
        ),
        pilot(
            "watch",
            "Watch PRs",
            "Follow review threads and failing checks.",
            .bool,
            { $0.watch.map(OverrideValue.bool) },
            {
                .bool($0.watch)
            }
        ),
        pilot(
            "green",
            "Get it green",
            "off, ask (you queue) or auto (sent once the agent is idle).",
            .choice(AutoFeed.allCases.map(\.configName)),
            { $0.green.map { .text($0.configName) } },
            {
                .text($0.green.configName)
            }
        ),
        pilot(
            "max_rounds",
            "Stop after",
            "Prompts without a new approval.",
            .integer(1 ... 20),
            { $0.maxRounds.map(OverrideValue.integer) },
            { .integer($0.maxRounds) }
        ),
        pilot(
            "run_in",
            "Runs in",
            "background (a run of its own) or session (the session's agent, once idle).",
            .choice(RunIn.allCases.map(\.configName)),
            { $0.runIn.map { .text($0.configName) } },
            { .text($0.runIn.configName) }
        ),
        pilot(
            "agent",
            "Run agent",
            "The agent get it green runs use; unset: the session's.",
            .agent,
            { $0.agent.map(OverrideValue.text) },
            { .text($0.agent ?? "") }
        ),
        pilot(
            "model",
            "Run model",
            "Its model (haiku, gpt-5-codex…); empty: the agent's default.",
            .text,
            { $0.model.map(OverrideValue.text) },
            { .text($0.model ?? "") }
        ),
        pilot(
            "merge_agent",
            "Conflict agent",
            "Background runs for merge conflicts; unset: the run agent.",
            .agent,
            { $0.mergeAgent.map(OverrideValue.text) },
            { .text($0.mergeAgent ?? "") }
        ),
        pilot(
            "merge_model",
            "Conflict model",
            "Its model; empty: the run model (with a conflict agent, its default).",
            .text,
            { $0.mergeModel.map(OverrideValue.text) },
            { .text($0.mergeModel ?? "") }
        ),
        pilot(
            "merge",
            "Get it merged",
            "off, auto (GitHub's auto-merge) or heed (heed merges).",
            .choice(MergeMode.allCases.map(\.configName)),
            { $0.merge.map { .text($0.configName) } },
            {
                .text($0.merge.configName)
            }
        ),
        pilot(
            "merge_method",
            "Merge method",
            "How heed merges; unset: the first the repo allows.",
            .choice(["", "squash", "merge", "rebase"]),
            { $0.mergeMethod.map(OverrideValue.text) },
            { .text($0.mergeMethod ?? "") }
        ),
        pilot(
            "update_branches",
            "Update branches",
            "Bring PRs that fell behind up to date.",
            .bool,
            { $0.updateBranches.map(OverrideValue.bool) },
            { .bool($0.updateBranches) }
        ),
        pilot(
            "copilot_conflicts",
            "Copilot: conflicts",
            "Ask Copilot to resolve merge conflicts.",
            .bool,
            { $0.copilotConflicts.map(OverrideValue.bool) },
            { .bool($0.copilotConflicts) }
        ),
        pilot(
            "copilot_comments",
            "Copilot: comments",
            "Ask Copilot to address review comments.",
            .bool,
            { $0.copilotComments.map(OverrideValue.bool) },
            { .bool($0.copilotComments) }
        ),
        pilot(
            "reviewers",
            "Reviewers",
            "Asked to review each PR: logins, org/team or copilot.",
            .list,
            { $0.reviewers.map(OverrideValue.list) },
            { .list($0.reviewers) }
        ),
        pilot(
            "quiet_minutes",
            "Quiet for",
            "heed merges: minutes without a new commit or review first.",
            .integer(0 ... 1440),
            { $0.quietMinutes.map(OverrideValue.integer) },
            { .integer($0.quietMinutes) }
        ),
        pilot(
            "trusted_reviewers",
            "Trusted AI reviewers",
            "heed merges: their review counts as an approval.",
            .list,
            { $0.trustedReviewers.map(OverrideValue.list) },
            { .list($0.trustedReviewers) }
        ),
        pilot(
            "gate_checks",
            "Gate checks",
            "heed merges: checks that must have passed.",
            .list,
            { $0.gateChecks.map(OverrideValue.list) },
            { .list($0.gateChecks) }
        ),
        pilot(
            "hold_labels",
            "Hold labels",
            "heed merges: a PR with one of these waits.",
            .list,
            { $0.holdLabels.map(OverrideValue.list) },
            { .list($0.holdLabels) }
        ),
        pilot(
            "self_review",
            "Self-review",
            "heed merges: a command that reads the diff and answers APPROVE.",
            .text,
            { $0.selfReview.map(OverrideValue.text) },
            { .text($0.selfReview ?? "") }
        ),
        pilot(
            "green_instructions",
            "Get it green",
            "Added after the feedback items each run gets.",
            .instructions,
            { $0.greenInstructions.map(OverrideValue.text) },
            { .text($0.greenInstructions) }
        ),
        pilot(
            "review_instructions",
            "Self-review",
            "Added to what heed merge's self-review looks for.",
            .instructions,
            { $0.reviewInstructions.map(OverrideValue.text) },
            { .text($0.reviewInstructions) }
        ),
        pilot(
            "start_instructions",
            "Start work",
            "Added after the issue text Start work begins from.",
            .instructions,
            { $0.startInstructions.map(OverrideValue.text) },
            { .text($0.startInstructions) }
        ),
        pilot(
            "summary_instructions",
            "Summaries",
            "Added to what heed asks its model calls for when it summarizes work.",
            .instructions,
            { $0.summaryInstructions.map(OverrideValue.text) },
            { .text($0.summaryInstructions) }
        ),
        pilot(
            "summary_sign_off",
            "Sign off with a summary",
            "Agents are asked to end their final message with a heed-summary: line, which becomes the ledger's summary.",
            .bool,
            { $0.summarySignOff.map(OverrideValue.bool) },
            { .bool($0.summarySignOff) }
        ),
        pilot(
            "admin_merge",
            "Admin merge",
            "heed merges past branch protection you are allowed to bypass.",
            .bool,
            { $0.adminMerge.map(OverrideValue.bool) },
            { _ in .bool(false) },
            repoOnly: true
        ),
        pilot(
            "merge_now",
            "Merge now",
            "Merging a PR now by hand: ask shows the PR, the method and what is not met first; auto does not ask.",
            .choice(MergeNowConfirm.allCases.map(\.rawValue)),
            { $0.mergeNow.map { .text($0.rawValue) } },
            { .text($0.mergeNow.rawValue) }
        ),
        pilot(
            "force_merge",
            "Force merge",
            "Merging now past required reviews or checks with --admin, when you are an admin: off, ask, auto.",
            .choice(ForceMerge.allCases.map(\.rawValue)),
            { $0.forceMerge.map { .text($0.rawValue) } },
            { .text($0.forceMerge.rawValue) }
        ),
    ]

    private static func pilot(
        _ id: String, _ label: String, _ detail: String, _ kind: OverrideKey.Kind,
        _ value: @escaping @Sendable (PilotOverrides) -> OverrideValue?,
        _ fallback: @escaping @Sendable (PilotSettings) -> OverrideValue, repoOnly: Bool = false
    ) -> OverrideKey {
        OverrideKey(
            id: id, label: label, detail: detail, kind: kind, repoOnly: repoOnly,
            read: { config, scope in
                switch scope {
                case let .org(name): config.pilot.orgs[name].flatMap(value)
                case let .repo(repo): config.pilot.repos[repo.slug].flatMap(value)
                }
            },
            fallback: { fallback($0.pilot.defaults) }
        )
    }

    /// The groups the page lists keys under, in order, and the tab each is on.
    public static let groups: [(title: String, tab: OverrideTab, keys: [String])] = [
        ("General", .general, ["color", "issues"]),
        ("New worktrees", .general, ["setup"]),
        ("Goals", .general, ["goals_tracker", "goals_mirror"]),
        ("Watching", .general, ["watch"]),
        ("Get it green", .green, ["green", "max_rounds", "run_in", "agent", "model"]),
        ("Merge conflicts", .green, ["merge_agent", "merge_model"]),
        ("Get it merged", .merged, ["merge", "merge_method", "update_branches", "admin_merge"]),
        ("Before heed merges", .merged, ["quiet_minutes", "gate_checks", "hold_labels"]),
        ("Merging by hand", .merged, ["merge_now", "force_merge"]),
        ("Reviewers", .reviews, ["reviewers", "trusted_reviewers", "self_review"]),
        ("Copilot", .reviews, ["copilot_comments", "copilot_conflicts"]),
        ("Extra instructions", .instructions, [
            "green_instructions", "review_instructions", "start_instructions", "summary_instructions",
            "summary_sign_off",
        ]),
    ]

    /// The tab a key is on; a repo's tasks (`tasks`, edited in the file) show on General.
    public static func tab(of id: String) -> OverrideTab {
        groups.first { $0.keys.contains(id) }?.tab ?? .general
    }

    /// The keys a tab shows at a scope, in page order; with `onlyOverridden`, only those set at exactly this scope.
    public static func keys(
        for scope: OverrideScope, on tab: OverrideTab, in config: HeedConfig, onlyOverridden: Bool = false
    ) -> [OverrideKey] {
        keys(for: scope).filter { key in
            Self.tab(of: key.id) == tab && (!onlyOverridden || key.read(config, scope) != nil)
        }
    }

    /// How many overrides each tab holds at a scope (its own, as the list's `● n` counts them); every tab is there,
    /// at 0 when it holds none. They add up to `setKeys(at:in:).count`.
    public static func overrideCounts(at scope: OverrideScope, in config: HeedConfig) -> [OverrideTab: Int] {
        var counts = Dictionary(uniqueKeysWithValues: OverrideTab.allCases.map { ($0, 0) })
        for id in setKeys(at: scope, in: config) {
            counts[tab(of: id), default: 0] += 1
        }
        return counts
    }

    /// The keys that apply at a scope (an org has no `admin_merge`), in group order.
    public static func keys(for scope: OverrideScope) -> [OverrideKey] {
        let order = groups.flatMap(\.keys)
        let applicable = scope.isOrg ? keys.filter { !$0.repoOnly } : keys
        return applicable.sorted { (order.firstIndex(of: $0.id) ?? .max) < (order.firstIndex(of: $1.id) ?? .max) }
    }

    /// The value set at exactly this scope, if any.
    public static func value(_ key: OverrideKey, at scope: OverrideScope, in config: HeedConfig) -> OverrideValue? {
        key.read(config, scope)
    }

    /// The value that applies at a scope, and where it comes from: the repo, then its org, then the default.
    public static func effective(
        _ key: OverrideKey, at scope: OverrideScope, in config: HeedConfig
    ) -> (value: OverrideValue, source: OverrideSource) {
        if let own = key.read(config, scope) {
            if case .org = scope { return (own, .org) }
            return (own, .repo)
        }
        if case let .repo(repo) = scope, let org = key.read(config, .org(repo.org)) { return (org, .org) }
        return (key.fallback(config), .default)
    }

    /// The keys set at a scope (its own overrides), plus the repo's tasks.
    public static func setKeys(at scope: OverrideScope, in config: HeedConfig) -> [String] {
        var result = keys(for: scope).filter { $0.read(config, scope) != nil }.map(\.id)
        if case let .repo(repo) = scope, !(config.repos[repo.slug]?.tasks.isEmpty ?? true) { result.append("tasks") }
        return result
    }

    /// Orgs and repos named in config.toml, whether or not they are cloned here.
    public static func configuredScopes(in config: HeedConfig) -> [OverrideScope] {
        // The goal mirror's tables hold orgs and repos in one: a repo is the key with a slash.
        let goals = Set(config.goals.mirror.trackers.keys).union(config.goals.mirror.mirrors.keys)
        let orgs = Set(config.orgColors.keys).union(config.issues.orgs.keys).union(config.pilot.orgs.keys)
            .union(config.work.setup.orgs.keys).union(goals.filter { !$0.contains("/") })
        let repos = Set(config.repos.keys).union(config.issues.repos.keys).union(config.pilot.repos.keys)
            .union(config.work.setup.repos.keys).union(goals.filter { $0.contains("/") })
        return orgs.sorted().map(OverrideScope.org) + repos.sorted().compactMap { slug in
            let parts = slug.split(separator: "/")
            return parts.count == 2 ? .repo(Repo(org: String(parts[0]), name: String(parts[1]))) : nil
        }
    }
}
