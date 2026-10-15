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
            "agent",
            "Run agent",
            "The agent get it green runs use (codex, claude…); empty: the session's.",
            .text,
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
            "squash, merge or rebase; empty: the repo's default.",
            .text,
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
            "admin_merge",
            "Admin merge",
            "heed merges past branch protection you are allowed to bypass.",
            .bool,
            { $0.adminMerge.map(OverrideValue.bool) },
            { _ in .bool(false) },
            repoOnly: true
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

    /// The groups the page lists keys under, in order.
    public static let groups: [(title: String, keys: [String])] = [
        ("General", ["color", "issues"]),
        ("Watching", ["watch"]),
        ("Get it green", ["green", "max_rounds", "agent", "model"]),
        ("Get it merged", [
            "merge", "merge_method", "update_branches", "quiet_minutes", "trusted_reviewers", "gate_checks",
            "hold_labels", "self_review", "admin_merge",
        ]),
        ("Copilot and reviewers", ["copilot_conflicts", "copilot_comments", "reviewers"]),
    ]

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
        let orgs = Set(config.orgColors.keys).union(config.issues.orgs.keys).union(config.pilot.orgs.keys)
        let repos = Set(config.repos.keys).union(config.issues.repos.keys).union(config.pilot.repos.keys)
        return orgs.sorted().map(OverrideScope.org) + repos.sorted().compactMap { slug in
            let parts = slug.split(separator: "/")
            return parts.count == 2 ? .repo(Repo(org: String(parts[0]), name: String(parts[1]))) : nil
        }
    }
}
