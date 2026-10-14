import Foundation

/// Get it merged, for one repo: what a run of its merge queue does with each PR that has merging on. Pure, so the
/// rules are tested; `AppModel` carries the steps out with `gh` and records them as a `MergeRun`.
public enum MergeQueue {
    public struct Entry: Sendable {
        public let ref: PullRef
        public let detail: PullDetail
        public let settings: PilotSettings
        public let paused: Bool

        public init(ref: PullRef, detail: PullDetail, settings: PilotSettings, paused: Bool) {
            self.ref = ref
            self.detail = detail
            self.settings = settings
            self.paused = paused
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

    /// Oldest first, as they were opened; merged and closed PRs have left the queue.
    public static func plan(_ entries: [Entry]) -> [Step] {
        entries.filter { $0.detail.state != "MERGED" && $0.detail.state != "CLOSED" }
            .sorted { $0.ref.number < $1.ref.number }.map { Step(
                ref: $0.ref,
                action: action(for: $0)
            ) }
    }

    public static func action(for entry: Entry) -> Action {
        let detail = entry.detail
        let enabled = detail.autoMergeEnabled == true
        if entry.paused { return .hold("paused") }
        if detail.state == "MERGED" || detail
            .state == "CLOSED" { return .hold(detail.state == "MERGED" ? "merged" : "closed") }
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
