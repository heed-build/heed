import Foundation

/// Whether a PR is ready to merge, requirement by requirement: open, not a draft, no conflicts, up to date when the
/// repo
/// requires it, its required checks passed, approved (or no review required), nothing else blocking it on GitHub, no
/// open threads, no hold label, quiet for `quiet_minutes`, and GitHub's auto-merge not already on it. A candidate meets
/// them all. Each requirement says who holds a PR to it, which decides what merging now can skip.
public struct MergeCandidate: Hashable, Sendable {
    /// Who holds a PR to a requirement.
    public enum Bar: Hashable, Sendable {
        /// Nothing merges it past this: closed, a draft, conflicts, a hold label.
        case hard
        /// GitHub's branch protection: a merge is refused, unless an admin forces it (`--admin`).
        case github
        /// heed's own patience: merging now skips it.
        case heed
    }

    public struct Requirement: Hashable, Sendable, Identifiable {
        public var id: String { rule.name }
        public let rule: GreenVerdict.Rule
        public let bar: Bar
    }

    public let requirements: [Requirement]

    public var isCandidate: Bool { requirements.allSatisfy { $0.rule.state == .pass } }

    /// What is not met yet, failures and waits alike, in the order above.
    public var unmet: [Requirement] { requirements.filter { $0.rule.state != .pass } }

    public static func of(_ detail: PullDetail, settings: PilotSettings, now: Date) -> MergeCandidate {
        var requirements: [Requirement] = []
        func add(_ name: String, _ bar: Bar, _ state: GreenVerdict.Rule.State, _ text: String) {
            requirements.append(Requirement(rule: GreenVerdict.Rule(name: name, state: state, detail: text), bar: bar))
        }
        let green = Dictionary(GreenVerdict.of(detail).rules.map { ($0.name, $0) }) { first, _ in first }
        func copy(_ name: String, _ bar: Bar) {
            if let rule = green[name] { requirements.append(Requirement(rule: rule, bar: bar)) }
        }
        copy("Open", .hard)
        copy("Ready for review", .hard)
        copy("No conflicts", .hard)
        copy("Up to date", .github)
        copy("Checks pass", .github)
        let approved: (GreenVerdict.Rule.State, String) = switch detail.reviewDecision {
        case "APPROVED": (.pass, "approved")
        case "REVIEW_REQUIRED": (.fail, "needs an approving review")
        case "CHANGES_REQUESTED": (.fail, "a reviewer requested changes")
        default: (.pass, "no review required")
        }
        add("Approved", .github, approved.0, approved.1)
        // BLOCKED with the reviews and checks in order: something heed does not see holds it (a ruleset, code owners,
        // signed commits).
        let explained = approved.0 != .pass || green["Checks pass"]?.state != .pass
        if detail.mergeState == "BLOCKED", !explained {
            add("Not blocked", .github, .fail, "GitHub blocks it for a rule heed cannot see")
        } else {
            add("Not blocked", .github, .pass, "nothing else blocks it")
        }
        copy("Threads resolved", .heed)
        let holds = Set(settings.holdLabels.map { $0.lowercased() })
        if let label = (detail.labels ?? []).first(where: { holds.contains($0.lowercased()) }) {
            add("No hold label", .hard, .fail, "labelled \(label)")
        } else {
            add("No hold label", .hard, .pass, "none")
        }
        let last = ([detail.headCommittedAt] + detail.reviews.map(\.submittedAt)).compactMap(\.self).max()
        let quiet = TimeInterval(settings.quietMinutes * 60)
        if let last, now.timeIntervalSince(last) < quiet {
            add("Quiet", .heed, .wait, "quiet for \(PilotDuration.text(quiet - now.timeIntervalSince(last))) more")
        } else {
            add("Quiet", .heed, .pass, settings.quietMinutes == 0 ? "no quiet window" : "nothing new for a while")
        }
        if detail.autoMergeEnabled == true {
            add("Auto-merge off", .heed, .fail, "GitHub's auto-merge is on: GitHub merges it")
        } else {
            add("Auto-merge off", .heed, .pass, "off")
        }
        return MergeCandidate(requirements: requirements)
    }
}

/// Merging a PR now, by hand: whether GitHub would take it as it is, whether only an admin's `--admin` would, and what
/// the confirmation says. Pure; the app runs `gh pr merge`.
public enum MergeNow {
    public enum Offer: Hashable, Sendable {
        /// GitHub takes it: heed's own waits not met are `skipping`.
        case merge(method: String, skipping: [GreenVerdict.Rule])
        /// Only with `--admin`: `bypassing` is what GitHub enforces and is not met.
        case force(method: String, bypassing: [GreenVerdict.Rule], skipping: [GreenVerdict.Rule])
        /// Why not.
        case unavailable(String)
    }

    public static func offer(_ candidate: MergeCandidate, detail: PullDetail, settings: PilotSettings) -> Offer {
        guard let method = MergeQueue.method(settings, allowed: detail.repoMergeMethods) else {
            return .unavailable("the repo does not allow \(settings.mergeMethod ?? "any") merges")
        }
        let unmet = candidate.unmet
        if let hard = unmet.first(where: { $0.bar == .hard }) {
            return .unavailable("\(hard.rule.name): \(hard.rule.detail)")
        }
        let skipping = unmet.filter { $0.bar == .heed }.map(\.rule)
        let enforced = unmet.filter { $0.bar == .github }.map(\.rule)
        guard let first = enforced.first else { return .merge(method: method, skipping: skipping) }
        let why = "\(first.name): \(first.detail)"
        guard detail.viewerPermission == "ADMIN" else {
            return .unavailable("\(why) (only an admin of the repo can merge past it)")
        }
        guard settings.forceMerge != .off else { return .unavailable("\(why) (force_merge is off)") }
        return .force(method: method, bypassing: enforced, skipping: skipping)
    }

    /// Whether to ask before going ahead (`merge_now`, `force_merge`).
    public static func asks(_ offer: Offer, settings: PilotSettings) -> Bool {
        switch offer {
        case .merge: settings.mergeNow == .ask
        case .force: settings.forceMerge == .ask
        case .unavailable: false
        }
    }

    /// What the confirmation says.
    public struct Prompt: Hashable, Sendable {
        public let title: String
        public let lines: [String]
        public let accept: String
        public let destructive: Bool
    }

    /// The PR, the method, the commit, and every requirement not met: bypassed (force) or merged anyway (heed's).
    public static func prompt(_ offer: Offer, detail: PullDetail) -> Prompt? {
        let name = "\(detail.ref.repo.slug)#\(detail.ref.number)"
        let base = detail.baseBranch.isEmpty ? "the base branch" : detail.baseBranch
        let commit = "on the commit heed checked (\(detail.headSHA.prefix(7)))"
        func lines(_ rules: [GreenVerdict.Rule], _ prefix: String) -> [String] {
            rules.map { "\(prefix) · \($0.name): \($0.detail)" }
        }
        switch offer {
        case let .merge(method, skipping):
            return Prompt(
                title: "Merge \(name) now?",
                lines: [detail.title, "\(method) into \(base), \(commit)"]
                    + (skipping.isEmpty ? ["Every requirement is met"] : lines(skipping, "Not met, merged anyway")),
                accept: "Merge (\(method))", destructive: false
            )
        case let .force(method, bypassing, skipping):
            return Prompt(
                title: "Force-merge \(name) with --admin?",
                lines: [detail.title, "\(method) into \(base) with --admin, \(commit)"]
                    + lines(bypassing, "Bypassed") + lines(skipping, "Not met, merged anyway"),
                accept: "Force merge", destructive: true
            )
        case .unavailable:
            return nil
        }
    }
}

/// What heed knows about a repo that decides whether its merge settings can work: what the repo allows, whether its
/// base branch wants linear history, and your permission. Read from the PR details heed fetches anyway.
public struct RepoMergeFacts: Hashable, Sendable {
    public var allowsAutoMerge: Bool?
    public var methods: [String]?
    public var linearHistory: Bool?
    public var viewerPermission: String?

    public init(allowsAutoMerge: Bool?, methods: [String]?, linearHistory: Bool?, viewerPermission: String?) {
        self.allowsAutoMerge = allowsAutoMerge
        self.methods = methods
        self.linearHistory = linearHistory
        self.viewerPermission = viewerPermission
    }

    public init(_ detail: PullDetail) {
        self.init(
            allowsAutoMerge: detail.repoAllowsAutoMerge, methods: detail.repoMergeMethods,
            linearHistory: detail.repoRequiresLinearHistory, viewerPermission: detail.viewerPermission
        )
    }

    /// From the newest detail of one of the repo's PRs; nil when heed has none.
    public static func of(_ repo: Repo, details: some Sequence<PullDetail>) -> RepoMergeFacts? {
        details.filter { $0.ref.repo == repo }.max { $0.fetchedAt < $1.fetchedAt }.map(RepoMergeFacts.init)
    }
}

/// Whether get it merged is set up for a repo and can work there: computed once per repo from its settings and
/// `RepoMergeFacts`, so a misconfiguration shows before a run holds a PR for it. The Repos view's badge and the setup
/// flow read the same value.
public enum RepoMergeReadiness: Hashable, Sendable {
    /// `merge = "off"`.
    case notSetUp
    /// Merging is on, and nothing about the repo is known yet.
    case unknown
    case ok
    /// What cannot work, one sentence each.
    case misconfigured([String])

    /// `mode` is a PR's own choice (`zm`) when it has one; else the settings' `merge`.
    public static func of(_ settings: PilotSettings, mode: MergeMode? = nil, facts: RepoMergeFacts?) -> Self {
        let mode = mode ?? settings.merge
        guard mode != .off else { return .notSetUp }
        guard let facts else { return .unknown }
        let problems = problems(settings, mode: mode, facts: facts)
        return problems.isEmpty ? .ok : .misconfigured(problems)
    }

    public static func problems(_ settings: PilotSettings, mode: MergeMode, facts: RepoMergeFacts) -> [String] {
        var problems: [String] = []
        if mode == .auto, facts.allowsAutoMerge == false {
            problems.append(
                "merge = \"auto\" needs GitHub's auto-merge, which the repo does not allow (Settings › General)"
            )
        }
        let allowed = facts.methods ?? MergeQueue.methods
        if let wanted = settings.mergeMethod, !allowed.contains(wanted) {
            problems.append(
                "the repo does not allow \(wanted) merges (it allows \(allowed.isEmpty ? "none" : allowed.joined(separator: ", ")))"
            )
        } else if allowed.isEmpty {
            problems.append("the repo allows no merge method")
        }
        if facts.linearHistory == true, MergeQueue.method(settings, allowed: facts.methods) == "merge" {
            problems
                .append("the base branch requires linear history, which a merge commit breaks: use squash or rebase")
        }
        if settings.adminMerge, mode == .heed, let permission = facts.viewerPermission, permission != "ADMIN" {
            problems.append("admin_merge is on, but you are not an admin of the repo")
        }
        return problems
    }

    public var problems: [String] {
        if case let .misconfigured(problems) = self { problems } else { [] }
    }

    /// The Repos view's badge: `merging: not set up`, `merging: ok`, `merging: ⚠`.
    public var badge: String {
        switch self {
        case .notSetUp: "merging: not set up"
        case .unknown: "merging: not checked yet"
        case .ok: "merging: ok"
        case .misconfigured: "merging: ⚠"
        }
    }

    /// `Merging misconfigured: …`, for a PR in such a repo; nil when nothing is wrong.
    public var line: String? {
        problems.isEmpty ? nil : "Merging misconfigured: " + problems.joined(separator: "; ")
    }
}
