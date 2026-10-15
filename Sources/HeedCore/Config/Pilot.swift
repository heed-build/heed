import Foundation

/// What get it merged does once a PR is green enough. `auto` makes sure GitHub's auto-merge is on (GitHub merges once
/// its own requirements are met); `heed` merges it itself, once heed's merge rules hold (`HeedMerge`).
public enum MergeMode: String, CaseIterable, Hashable, Sendable, Codable {
    case off, auto, heed

    public var configName: String { rawValue }
    public static func named(_ name: String) -> MergeMode? { MergeMode(rawValue: name.lowercased()) }

    public var next: MergeMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}

/// Where get it green sends a PR's feedback: a background run (an agent in its own tab, worktree and branch), or the
/// session's own agent, typed in once it is idle and you have left it alone for a while.
public enum RunIn: String, CaseIterable, Hashable, Sendable {
    case background, session

    public var configName: String { rawValue }
    public static func named(_ name: String) -> RunIn? { RunIn(rawValue: name.lowercased()) }
}

/// The pilot's settings for a PR: whether heed follows it, what get it green does with what it finds, and how long a
/// pause lasts by default. From `[pilot]`, then `[orgs.<org>]`, then `[repos."org/name"]`; a hand-set choice on the PR
/// itself wins over all of them (see `PullFeedback.effective`).
public struct PilotSettings: Hashable, Sendable {
    /// Follow the PR: fetch its detail as it moves, collect review threads and failing checks, show its state.
    /// Read-only, so on by default.
    public var watch: Bool
    /// What happens to what is collected: shown only, queued by you, or sent to an idle agent.
    public var green: AutoFeed
    /// Prompts sent without a new approval before get it green stops.
    public var maxRounds: Int
    /// How long `zp` pauses a PR; nil pauses until resumed.
    public var pause: TimeInterval?
    public var merge: MergeMode
    /// `squash`, `merge` or `rebase`; nil takes the first the repo allows, in that order.
    public var mergeMethod: String?
    /// How often a repo's merge queue runs; nil only when asked (`:merge.run`).
    public var mergeSchedule: TimeInterval?
    /// After a merge, bring the queue's other PRs that fell behind up to date (`gh pr update-branch`).
    public var updateBranches: Bool
    /// Hand a watched PR's merge conflicts, and separately its review comments, to GitHub's Copilot coding agent (one
    /// comment on the PR) instead of your session's agent.
    public var copilotConflicts: Bool
    public var copilotComments: Bool
    /// Who heed asks to review a PR once it is open and ready: logins, `org/team`, or `copilot`.
    public var reviewers: [String]
    // The merge rules for `merge = "heed"`.
    /// No new commit or review for this long before heed merges.
    public var quietMinutes = 5
    /// AI reviewers (logins) whose review counts as one after the last push (see `HeedMerge`).
    public var trustedReviewers: [String] = []
    /// Checks that must have passed on the head commit, required by GitHub or not (an AI review's check, say).
    public var gateChecks: [String] = []
    /// Labels that hold a PR back.
    public var holdLabels = ["hold", "do-not-merge", "wip"]
    /// A command that reviews the PR's diff (on stdin) and answers APPROVE or REQUEST_CHANGES; nil skips it.
    public var selfReview: String?
    /// Retry a refused merge with `--admin` (bypassing branch protection). Per repo only.
    public var adminMerge = false
    /// The agent get it green and get it merged runs use; nil: the session's.
    public var agent: String?
    /// Its model (`--model`); nil: the agent's own default.
    public var model: String?
    /// A run still working after this long is stopped.
    public var runTimeout: TimeInterval = 1800
    /// Background runs, or the session's agent.
    public var runIn: RunIn = .background
    /// Extra instructions heed adds to its prompts: after get it green's feedback items, to heed merge's self-review
    /// criteria, and after Start work's issue text. Additions only: what heed needs from a prompt stays as it is.
    public var greenInstructions = ""
    public var reviewInstructions = ""
    public var startInstructions = ""

    public init(
        watch: Bool = true, green: AutoFeed = .ask, maxRounds: Int = 3, pause: TimeInterval? = 3600,
        merge: MergeMode = .off, mergeMethod: String? = nil, mergeSchedule: TimeInterval? = 3600,
        updateBranches: Bool = true, copilotConflicts: Bool = false, copilotComments: Bool = false,
        reviewers: [String] = []
    ) {
        self.copilotConflicts = copilotConflicts
        self.copilotComments = copilotComments
        self.reviewers = reviewers
        self.watch = watch
        self.green = green
        self.maxRounds = maxRounds
        self.pause = pause
        self.merge = merge
        self.mergeMethod = mergeMethod
        self.mergeSchedule = mergeSchedule
        self.updateBranches = updateBranches
    }
}

/// What an org or a repo changes; nil leaves the level above in charge.
public struct PilotOverrides: Hashable, Sendable {
    public var watch: Bool?
    public var green: AutoFeed?
    public var maxRounds: Int?
    public var merge: MergeMode?
    public var mergeMethod: String?
    public var updateBranches: Bool?
    public var copilotConflicts: Bool?
    public var copilotComments: Bool?
    public var reviewers: [String]?
    public var quietMinutes: Int?
    public var trustedReviewers: [String]?
    public var gateChecks: [String]?
    public var holdLabels: [String]?
    public var selfReview: String?
    /// Read only under `[repos."org/name"]`.
    public var adminMerge: Bool?
    public var agent: String?
    public var model: String?
    public var runIn: RunIn?
    /// Empty is a value too: a repo can clear what its org adds.
    public var greenInstructions: String?
    public var reviewInstructions: String?
    public var startInstructions: String?

    public init(
        watch: Bool? = nil, green: AutoFeed? = nil, maxRounds: Int? = nil, merge: MergeMode? = nil,
        mergeMethod: String? = nil, updateBranches: Bool? = nil, copilotConflicts: Bool? = nil,
        copilotComments: Bool? = nil, reviewers: [String]? = nil
    ) {
        self.copilotConflicts = copilotConflicts
        self.copilotComments = copilotComments
        self.reviewers = reviewers
        self.watch = watch
        self.green = green
        self.maxRounds = maxRounds
        self.merge = merge
        self.mergeMethod = mergeMethod
        self.updateBranches = updateBranches
    }

    public var isEmpty: Bool {
        watch == nil && green == nil && maxRounds == nil && merge == nil && mergeMethod == nil && updateBranches == nil
            && copilotConflicts == nil && copilotComments == nil && reviewers == nil && quietMinutes == nil
            && trustedReviewers == nil && gateChecks == nil && holdLabels == nil && selfReview == nil && adminMerge ==
            nil && agent == nil && model == nil
            && greenInstructions == nil && reviewInstructions == nil && startInstructions == nil && runIn == nil
    }
}

/// The levels, resolved per repo the way `IssueRules.visibility` is: the repo, then its org, then the defaults.
public struct PilotRules: Hashable, Sendable {
    public var defaults: PilotSettings
    public var orgs: [String: PilotOverrides]
    public var repos: [String: PilotOverrides]

    public init(
        defaults: PilotSettings = PilotSettings(), orgs: [String: PilotOverrides] = [:],
        repos: [String: PilotOverrides] = [:]
    ) {
        self.defaults = defaults
        self.orgs = orgs
        self.repos = repos
    }

    public func resolve(_ repo: Repo) -> PilotSettings {
        let repoLevel = repos[repo.slug] ?? PilotOverrides()
        let orgLevel = orgs[repo.org] ?? PilotOverrides()
        var settings = defaults
        settings.watch = repoLevel.watch ?? orgLevel.watch ?? defaults.watch
        settings.green = repoLevel.green ?? orgLevel.green ?? defaults.green
        settings.maxRounds = repoLevel.maxRounds ?? orgLevel.maxRounds ?? defaults.maxRounds
        settings.merge = repoLevel.merge ?? orgLevel.merge ?? defaults.merge
        settings.mergeMethod = repoLevel.mergeMethod ?? orgLevel.mergeMethod ?? defaults.mergeMethod
        settings.updateBranches = repoLevel.updateBranches ?? orgLevel.updateBranches ?? defaults.updateBranches
        settings.copilotConflicts = repoLevel.copilotConflicts ?? orgLevel.copilotConflicts ?? defaults.copilotConflicts
        settings.copilotComments = repoLevel.copilotComments ?? orgLevel.copilotComments ?? defaults.copilotComments
        settings.reviewers = repoLevel.reviewers ?? orgLevel.reviewers ?? defaults.reviewers
        settings.quietMinutes = repoLevel.quietMinutes ?? orgLevel.quietMinutes ?? defaults.quietMinutes
        settings.trustedReviewers = repoLevel.trustedReviewers ?? orgLevel.trustedReviewers ?? defaults.trustedReviewers
        settings.gateChecks = repoLevel.gateChecks ?? orgLevel.gateChecks ?? defaults.gateChecks
        settings.holdLabels = repoLevel.holdLabels ?? orgLevel.holdLabels ?? defaults.holdLabels
        settings.selfReview = repoLevel.selfReview ?? orgLevel.selfReview ?? defaults.selfReview
        settings.adminMerge = repoLevel.adminMerge ?? false
        settings.agent = repoLevel.agent ?? orgLevel.agent ?? defaults.agent
        settings.model = repoLevel.model ?? orgLevel.model ?? defaults.model
        settings.runIn = repoLevel.runIn ?? orgLevel.runIn ?? defaults.runIn
        settings.greenInstructions = repoLevel.greenInstructions ?? orgLevel.greenInstructions
            ?? defaults.greenInstructions
        settings.reviewInstructions = repoLevel.reviewInstructions ?? orgLevel.reviewInstructions
            ?? defaults.reviewInstructions
        settings.startInstructions = repoLevel.startInstructions ?? orgLevel.startInstructions
            ?? defaults.startInstructions
        return settings
    }

    /// Which level a repo's `watch` comes from, for the UI's "from repo settings".
    public func watchSource(_ repo: Repo) -> String {
        if repos[repo.slug]?.watch != nil { return "repo" }
        if orgs[repo.org]?.watch != nil { return "org" }
        return "default"
    }
}

/// `1h`, `30m`, `4h`, `1d`, `90s`; `forever` (until resumed) and `off`.
public enum PilotDuration {
    public enum Parsed: Equatable, Sendable {
        case seconds(TimeInterval)
        case forever
        case off
    }

    public static func parse(_ text: String) -> Parsed? {
        let word = text.trimmingCharacters(in: .whitespaces).lowercased()
        switch word {
        case "forever", "until-resumed", "always": return .forever
        case "off", "resume", "none", "0": return .off
        default: break
        }
        guard let unit = word.last, let amount = Double(word.dropLast()), amount > 0 else { return nil }
        let scale: Double? = switch unit {
        case "s": 1
        case "m": 60
        case "h": 3600
        case "d": 86400
        default: nil
        }
        return scale.map { .seconds(amount * $0) }
    }

    /// `42m`, `3h 5m`, `2d`: what a pause countdown shows.
    public static func text(_ interval: TimeInterval) -> String {
        if interval <= 0 { return "0" }
        if interval < 60 { return "\(Int(interval.rounded()))s" }
        let minutes = max(Int((interval / 60).rounded(.up)), 1)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return minutes % 60 == 0 ? "\(hours)h" : "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d"
    }
}

/// One thing the pilot noticed or did, for the Watch view's timeline and activity. Kept in the domain, newest first.
public struct PilotEvent: Hashable, Sendable, Codable, Identifiable {
    public enum Kind: String, Hashable, Sendable, Codable {
        /// New review threads or failing checks arrived.
        case items
        case queued
        /// Sent to the agent.
        case sent
        /// Something to send, held back: the reason.
        case waiting
        /// The agent pushed after items were sent.
        case addressed
        case resolved
        /// Rounds exhausted without a new approval.
        case stuck
        /// `zr`: another round for a stalled PR.
        case retry
        /// A get it green / get it merged run ended: how, and its tab, worktree and branch gone.
        case helperDone
        case watch, green, pause
        /// Get it merged: auto-merge turned on or off, a merge, a PR held back, a branch brought up to date.
        case merge, autoMerge, merged, held, updated
        /// GitHub's Copilot coding agent was asked to resolve the PR's conflicts or address its comments.
        case copilot
        /// Reviews were requested.
        case review
    }

    public var id: String { "\(at.timeIntervalSince1970)-\(ref)-\(kind.rawValue)" }
    public let at: Date
    public let ref: PullRef
    public let kind: Kind
    public let text: String

    public init(at: Date, ref: PullRef, kind: Kind, text: String) {
        self.at = at
        self.ref = ref
        self.kind = kind
        self.text = text
    }

    public static let logLimit = 500

    /// What heed did, as opposed to what it noticed: a session you typed in stays yours until one of these happens on
    /// one of its PRs.
    public static let actions: Set<Kind> = [.sent, .merge, .autoMerge, .merged, .updated, .copilot, .review, .retry]

    /// What a fresh look at a PR changed in its pipeline: items that arrived, were addressed, were resolved.
    public static func changes(from before: PullFeedback?, to after: PullFeedback, at now: Date) -> [PilotEvent] {
        let old = Dictionary((before?.items ?? []).map { ($0.id, $0.status) }) { first, _ in first }
        let arrived = after.items.filter { old[$0.id] == nil || (old[$0.id] == .resolved && $0.status != .resolved) }
        let addressed = after.items.filter { $0.status == .addressed && old[$0.id] == .sent }
        let resolved = after.items.filter { $0.status == .resolved && old[$0.id] != nil && old[$0.id] != .resolved }
        var events: [PilotEvent] = []
        if !arrived.isEmpty { events.append(PilotEvent(
            at: now,
            ref: after.ref,
            kind: .items,
            text: describe(arrived, verb: "arrived")
        )) }
        if !addressed.isEmpty {
            events.append(PilotEvent(
                at: now,
                ref: after.ref,
                kind: .addressed,
                text: "the agent pushed: \(addressed.count) item\(addressed.count == 1 ? "" : "s") addressed"
            ))
        }
        if !resolved.isEmpty { events.append(PilotEvent(
            at: now,
            ref: after.ref,
            kind: .resolved,
            text: describe(resolved, verb: "resolved")
        )) }
        return events
    }

    /// `2 review threads and lint failed arrived`, `check lint resolved`.
    static func describe(_ items: [FeedbackItem], verb: String) -> String {
        let threads = items.count { if case .review = $0.kind { true } else { false } }
        let checks = items.compactMap { if case let .check(name) = $0.kind { name } else { nil } }
        var parts: [String] = []
        if threads > 0 { parts.append("\(threads) review thread\(threads == 1 ? "" : "s")") }
        if !checks.isEmpty { parts.append("check\(checks.count == 1 ? "" : "s") \(checks.joined(separator: ", "))") }
        return parts.joined(separator: " and ") + " " + verb
    }

    /// `log` with `events` added in front, capped.
    public static func log(_ log: [PilotEvent], adding events: [PilotEvent]) -> [PilotEvent] {
        Array((events.sorted { $0.at > $1.at } + log).prefix(logLimit))
    }
}

/// Where a watched PR stands: from its detail and the green verdict when heed has fetched it, else from the sync's
/// summary. The order is the Watch view's groups, most urgent first.
public enum PilotStatus: Hashable, Sendable {
    /// Needs you: there is feedback to send and no session to send it to.
    case stuck(String)
    /// Get it green used its rounds without a new approval: heed stopped sending (`zr` gives it another round).
    case stalled(rounds: Int)
    /// Items were sent; waiting for the agent's push.
    case feeding
    /// Conflicts with the base, or behind it when the repo requires up to date: what.
    case conflicted(String)
    case failing(Int)
    /// Unresolved review threads, or changes requested.
    case changes(Int)
    case pending
    case draft
    /// Every rule of the green verdict holds.
    case green
    /// Checks pass by the sync's summary; not yet confirmed by the detail.
    case passing
    case paused(until: Date?)
    case closed(merged: Bool)
    case unwatched

    public enum Group: String, CaseIterable, Sendable {
        case needsYou = "Needs you", stalled = "Stalled", failing = "Failing", changes = "Changes", feeding = "Feeding",
             pending = "Pending", green = "Green", passing = "Passing", paused = "Paused", done = "Done",
             unwatched = "Not watched"
    }

    public var group: Group {
        switch self {
        case .stuck: .needsYou
        case .stalled: .stalled
        case .failing, .conflicted: .failing
        case .changes: .changes
        case .feeding: .feeding
        case .pending, .draft: .pending
        case .green: .green
        case .passing: .passing
        case .paused: .paused
        case .closed: .done
        case .unwatched: .unwatched
        }
    }

    /// Counts toward what needs you (the title bar, the Dock, the menu bar).
    public var needsYou: Bool { if case .stuck = self { true } else { false } }

    /// Heed is doing something about the PR, so its session can be left be: feedback sent and not yet addressed, get
    /// it green on auto with something to fix, or merging on and the PR on its way.
    public func heedActing(_ effective: PullFeedback.Effective) -> Bool {
        switch self {
        case .feeding: true
        case .failing, .changes, .conflicted: effective.green == .auto
        case .pending, .passing, .green: effective.merge != .off
        case .stuck, .stalled, .draft, .paused, .closed, .unwatched: false
        }
    }

    /// `pull` is the PR's summary from the sync (nil until it arrives); `hasSession` says whether a session can be fed.
    public static func of(
        pull: PullRequest?, pipeline: PullFeedback?, settings: PilotSettings, hasSession: Bool,
        detail: PullDetail? = nil, now: Date = Date()
    ) -> PilotStatus {
        let effective = PullFeedback.effective(pipeline, settings)
        guard effective.watching else { return .unwatched }
        if pull?.state == .merged || detail?.state == "MERGED" { return .closed(merged: true) }
        if pull?.state == .closed || detail?.state == "CLOSED" { return .closed(merged: false) }
        if let pipeline,
           pipeline.isPaused(now) { return .paused(until: pipeline.pausedForever ? nil : pipeline.pausedUntil) }
        let open = pipeline?.items.filter { $0.status == .new || $0.status == .queued } ?? []
        if let pipeline, pipeline.rounds >= effective.maxRounds, !open.isEmpty {
            return .stalled(rounds: effective.maxRounds)
        }
        if !open.isEmpty, !hasSession, effective.green != .off { return .stuck("no session to send feedback to") }
        if pipeline?.items.contains(where: { $0.status == .sent }) == true { return .feeding }
        if let detail {
            guard let blocker = GreenVerdict.of(detail).blocker else { return .green }
            switch (blocker.name, blocker.state) {
            case ("Ready for review", _): return .draft
            case ("No conflicts", .fail), ("Up to date", .fail): return .conflicted(blocker.detail)
            case ("Checks pass", .fail):
                let required = detail.requiredChecks ?? []
                return .failing(max(detail.failingChecks.count { required.isEmpty || required.contains($0.name) }, 1))
            case ("Threads resolved", _), ("No changes requested", _):
                return .changes(max(detail.threads.count { !$0.isResolved }, 1))
            default: return .pending
            }
        }
        if let pull {
            if pull.checks.failed > 0 { return .failing(pull.checks.failed) }
            let threads = max(pull.unresolvedThreads, open.count { if case .review = $0.kind { true } else { false } })
            if threads > 0 || pull.review == .changesRequested { return .changes(max(threads, 1)) }
            if pull.checks.pending > 0 { return .pending }
        } else if !open.isEmpty {
            return .changes(open.count)
        }
        return pull == nil ? .pending : .passing
    }
}

/// Whether a PR is green, rule by rule: what `pilot.why` lists and what decides the Green group. Green means GitHub
/// has nothing left to object to on the code: no conflicts, up to date when required, the required checks (every
/// check when none are required) passed, no unresolved threads, no changes requested.
public struct GreenVerdict: Hashable, Sendable {
    public struct Rule: Hashable, Sendable, Identifiable {
        public enum State: Hashable, Sendable {
            case pass, fail, wait
        }

        public var id: String { name }
        public let name: String
        public let state: State
        /// What it found: `lint failed`, `behind main`, `2 threads open`.
        public let detail: String
    }

    public let rules: [Rule]

    public var isGreen: Bool { rules.allSatisfy { $0.state == .pass } }

    /// The first rule holding the PR back, failures before waits.
    public var blocker: Rule? { rules.first { $0.state == .fail } ?? rules.first { $0.state == .wait } }

    public static func of(_ detail: PullDetail) -> GreenVerdict {
        var rules: [Rule] = []
        func rule(_ name: String, _ state: Rule.State, _ detail: String) {
            rules.append(Rule(name: name, state: state, detail: detail))
        }
        let base = detail.baseBranch.isEmpty ? "the base branch" : detail.baseBranch
        switch detail.state {
        case "MERGED": rule("Open", .fail, "merged")
        case "CLOSED": rule("Open", .fail, "closed without merging")
        default: rule("Open", .pass, "open")
        }
        if detail.isDraft == true {
            rule("Ready for review", .fail, "draft")
        } else {
            rule("Ready for review", .pass, "not a draft")
        }
        if detail.mergeable == "CONFLICTING" || detail.mergeState == "DIRTY" {
            rule("No conflicts", .fail, "conflicts with \(base)")
        } else if detail.mergeable == "MERGEABLE" {
            rule("No conflicts", .pass, "merges cleanly")
        } else {
            rule("No conflicts", .wait, "GitHub is still working it out")
        }
        if detail.mergeState == "BEHIND" {
            rule("Up to date", .fail, "behind \(base), which this repo requires to be current")
        } else {
            rule("Up to date", .pass, "current enough")
        }
        let required = detail.requiredChecks ?? []
        let failing = detail.failingChecks.map(\.name).filter { required.isEmpty || required.contains($0) }
        let pending = detail.checks.pendingNames.filter { required.isEmpty || required.contains($0) }
        let which = required.isEmpty ? "checks" : "required checks"
        if !failing.isEmpty {
            rule("Checks pass", .fail, "\(failing.joined(separator: ", ")) failed")
        } else if !pending.isEmpty {
            rule("Checks pass", .wait, "\(pending.joined(separator: ", ")) still running")
        } else {
            rule("Checks pass", .pass, detail.checks.total == 0 ? "no checks" : "all \(which) passed")
        }
        let open = detail.threads.count { !$0.isResolved }
        if open > 0 {
            rule("Threads resolved", .fail, "\(open) thread\(open == 1 ? "" : "s") open")
        } else {
            rule("Threads resolved", .pass, "none open")
        }
        if detail.reviewDecision == "CHANGES_REQUESTED" {
            rule("No changes requested", .fail, "a reviewer requested changes")
        } else {
            rule("No changes requested", .pass, "none outstanding")
        }
        return GreenVerdict(rules: rules)
    }
}
