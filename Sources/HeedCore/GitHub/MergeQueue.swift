import Foundation

/// Get it merged, for one repo: what a run of its merge queue does with each PR that has merging on. Pure, so the
/// rules are tested; `AppModel` carries the steps out with `gh` and records them as a `MergeRun`.
public enum MergeQueue {
    public struct Entry: Sendable {
        public let ref: PullRef
        public let detail: PullDetail
        public let settings: PilotSettings
        public let paused: Bool
        /// `merge = "heed"`, else auto.
        public let mode: MergeMode
        public let selfReview: SelfReview?
        public let now: Date
        /// Why it may not merge yet whatever its rules say: a swarm PR whose blockers have not merged
        /// (`SwarmLanding.hold`).
        public let held: String?

        public init(
            ref: PullRef, detail: PullDetail, settings: PilotSettings, paused: Bool, mode: MergeMode = .auto,
            selfReview: SelfReview? = nil, now: Date = Date(), held: String? = nil
        ) {
            self.held = held
            self.ref = ref
            self.detail = detail
            self.settings = settings
            self.paused = paused
            self.mode = mode
            self.selfReview = selfReview
            self.now = now
        }
    }

    public enum Action: Hashable, Sendable {
        /// `gh pr merge --auto --<method>`: GitHub merges now when it can, else once its requirements are met.
        case enableAutoMerge(method: String)
        /// Auto-merge is on but heed's verdict found something GitHub might not enforce: turn it off again.
        case disableAutoMerge(reason: String)
        /// `gh pr update-branch`: the PR fell behind and the repo wants it current.
        case updateBranch
        /// Auto-merge is on and nothing is wrong: GitHub is waiting on its own requirements.
        case waiting(String)
        case hold(String)
        /// `merge = "heed"`: every merge rule holds, so heed merges (`--admin` on a refusal when `admin`).
        case merge(method: String, admin: Bool)
        /// Every merge rule but the self-review holds: run it.
        case selfReview
    }

    public struct Step: Hashable, Sendable {
        public let ref: PullRef
        public let action: Action
    }

    /// The methods heed tries, in order, when the settings name none.
    public static let methods = ["squash", "merge", "rebase"]

    /// The method to merge with: the configured one if the repo allows it, else the first it does.
    public static func method(_ settings: PilotSettings, allowed: [String]?) -> String? {
        let allowed = allowed ?? methods
        if let wanted = settings.mergeMethod { return allowed.contains(wanted) ? wanted : nil }
        return methods.first { allowed.contains($0) }
    }

    /// Oldest first, as they were opened; merged and closed PRs have left the queue. With `order` (a swarm's merge
    /// order), the PRs it names take the places those PRs have among the rest, in its order: unrelated PRs keep
    /// theirs.
    public static func plan(_ entries: [Entry], order: [PullRef]? = nil) -> [Step] {
        let open = entries.filter { $0.detail.state != "MERGED" && $0.detail.state != "CLOSED" }
        return sorted(open.map(\.ref), order: order).compactMap { ref in
            open.first { $0.ref == ref }.map { Step(ref: ref, action: action(for: $0)) }
        }
    }

    /// `refs` by PR number, then the ones in `order` rearranged among the places they hold, in its order.
    public static func sorted(_ refs: [PullRef], order: [PullRef]?) -> [PullRef] {
        var sorted = refs.sorted { $0.number < $1.number }
        guard let order, !order.isEmpty else { return sorted }
        let ordered = order.filter { sorted.contains($0) }
        let places = sorted.indices.filter { ordered.contains(sorted[$0]) }
        for (place, ref) in zip(places, ordered) {
            sorted[place] = ref
        }
        return sorted
    }

    public static func action(for entry: Entry) -> Action {
        let detail = entry.detail
        let enabled = detail.autoMergeEnabled == true
        if entry.paused { return .hold("paused") }
        if detail.state == "MERGED" || detail.state == "CLOSED" {
            return .hold(detail.state == "MERGED" ? "merged" : "closed")
        }
        // Before any rule: GitHub's auto-merge would merge it the moment its own requirements are met.
        if let held = entry.held {
            return detail.autoMergeEnabled == true ? .disableAutoMerge(reason: held) : .hold(held)
        }
        if entry.mode == .heed { return heedAction(entry) }
        if detail.repoAllowsAutoMerge == false {
            return .hold("the repo does not allow auto-merge (Settings → General → Allow auto-merge)")
        }
        guard let method = method(entry.settings, allowed: detail.repoMergeMethods) else {
            return .hold("the repo does not allow \(entry.settings.mergeMethod ?? "any") merges")
        }
        let verdict = GreenVerdict.of(detail)
        // Behind is the one failure a run fixes itself.
        if detail.mergeState == "BEHIND", entry.settings.updateBranches { return .updateBranch }
        if let failed = verdict.rules.first(where: { $0.state == .fail }) {
            let reason = "\(failed.name): \(failed.detail)"
            return enabled ? .disableAutoMerge(reason: reason) : .hold(reason)
        }
        if enabled {
            return .waiting(verdict.blocker.map { "auto-merge on, waiting: \($0.detail)" } ?? "auto-merge on")
        }
        if verdict.isGreen { return .enableAutoMerge(method: method) }
        // Waiting on something. Only hand it to GitHub when GitHub itself is holding the PR back (BLOCKED): there
        // auto-merge waits for the requirements. Anywhere else `--auto` merges at once, with checks still running.
        if detail.mergeState == "BLOCKED" { return .enableAutoMerge(method: method) }
        return .hold(verdict.blocker.map { "\($0.name): \($0.detail)" } ?? "not green yet")
    }
}

extension MergeQueue {
    static func heedAction(_ entry: Entry) -> Action {
        let detail = entry.detail
        guard let method = method(entry.settings, allowed: detail.repoMergeMethods) else {
            return .hold("the repo does not allow \(entry.settings.mergeMethod ?? "any") merges")
        }
        if detail.mergeState == "BEHIND", entry.settings.updateBranches { return .updateBranch }
        // heed decides when; GitHub's auto-merge would decide for it.
        if detail.autoMergeEnabled == true { return .disableAutoMerge(reason: "heed merges this PR itself") }
        let verdict = HeedMerge.verdict(detail, settings: entry.settings, selfReview: entry.selfReview, now: entry.now)
        if verdict.isGreen { return .merge(method: method, admin: entry.settings.adminMerge) }
        let others = verdict.rules.filter { $0.name != "Self-review" }
        if others.allSatisfy({ $0.state == .pass }), verdict.blocker?.state == .wait { return .selfReview }
        return .hold(verdict.blocker.map { "\($0.name): \($0.detail)" } ?? "not ready")
    }
}

/// One run of a repo's merge queue, for its merge session's run log.
public struct MergeRun: Hashable, Sendable, Codable, Identifiable {
    public struct Line: Hashable, Sendable, Codable {
        public let ref: PullRef
        /// `auto-merge on (squash)`, `brought up to date`, `held`, `failed`.
        public let action: String
        public let detail: String
        public let ok: Bool

        public init(ref: PullRef, action: String, detail: String, ok: Bool = true) {
            self.ref = ref
            self.action = action
            self.detail = detail
            self.ok = ok
        }
    }

    public var id: String { "\(repo)-\(at.timeIntervalSince1970)" }
    public let repo: String
    public let at: Date
    /// `schedule`, `asked`, `turned green`.
    public let why: String
    public let lines: [Line]

    public init(repo: String, at: Date, why: String, lines: [Line]) {
        self.repo = repo
        self.at = at
        self.why = why
        self.lines = lines
    }

    public static let keep = 50

    /// When a repo's queue runs next on its schedule: right away when it never ran (merging just came on), else
    /// one interval after the last run. Runs start when merging is turned on, so repos spread out by themselves.
    public static func nextRun(last: Date?, every: TimeInterval?, now: Date) -> Date? {
        guard let every else { return nil }
        return last.map { $0.addingTimeInterval(every) } ?? now
    }
}
