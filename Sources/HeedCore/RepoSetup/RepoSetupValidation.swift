import Foundation

/// What a proposal would have done, and what the repo's settings say about it: `HeedMerge.verdict` replayed over the
/// sampled PRs' final states, and each setting checked against GitHub's (a method the repo allows, auto-merge, linear
/// history, a merge queue, admin rights). heed only reads GitHub: a check that fails says what to change there.
public struct RepoSetupValidation: Hashable, Sendable {
    public struct Held: Hashable, Sendable {
        public var number: Int
        public var title: String
        public var reasons: [String]
    }

    public struct Check: Hashable, Sendable, Identifiable {
        public enum Level: Hashable, Sendable {
            case ok, warn, fail
        }

        public var id: String { text }
        public var level: Level
        public var text: String
        /// Where in GitHub's settings the fix is.
        public var url: String?

        public init(_ level: Level, _ text: String, url: String? = nil) {
            self.level = level
            self.text = text
            self.url = url
        }
    }

    /// PRs the merge rules were replayed over; 0 when the mode is not `heed`.
    public var replayed: Int
    public var held: [Held]
    public var checks: [Check]
    /// `3 of 30 would be held: 2 no review of the last push, 1 a hold label`.
    public var summary: String

    /// The settings with what the wizard proposes applied; `forceMerge` when the wizard sets it.
    public static func validate(
        _ sample: RepoSetupSample, settings: PilotSettings, forceMerge: ForceMerge? = nil
    ) -> RepoSetupValidation {
        var held: [Held] = []
        var replayed = 0
        let summary: String
        switch settings.merge {
        case .off:
            summary = "Merging stays off: nothing to replay."
        case .auto:
            summary = "GitHub's auto-merge decides when each PR merges: heed's rules are not replayed."
        case .heed:
            var rules = settings
            // The self-review command cannot be run on PRs already merged.
            rules.selfReview = nil
            for pull in sample.pulls {
                replayed += 1
                let verdict = HeedMerge.verdict(
                    detail(pull, settings: sample.settings, repo: sample.repo), settings: rules, selfReview: nil,
                    now: replayTime(pull, quietMinutes: rules.quietMinutes)
                )
                let reasons = verdict.rules.filter { $0.state != .pass }.map(reason)
                if !reasons.isEmpty { held.append(Held(number: pull.number, title: pull.title, reasons: reasons)) }
            }
            summary = describe(held: held, of: replayed)
        }
        return RepoSetupValidation(
            replayed: replayed, held: held,
            checks: checks(
                sample.settings,
                repo: sample.repo,
                settings: settings,
                sample: sample,
                forceMerge: forceMerge
            ),
            summary: summary
        )
    }

    /// When heed would look: at the merge, or once the quiet window after the last push or review has passed.
    static func replayTime(_ pull: SampledPull, quietMinutes: Int) -> Date {
        guard let last = pull.lastActivity else { return pull.mergedAt }
        return max(pull.mergedAt, last.addingTimeInterval(TimeInterval(quietMinutes * 60) + 1))
    }

    /// A merged PR as it stood just before its merge, in the shape the merge rules read.
    static func detail(_ pull: SampledPull, settings: RepoMergeSettings, repo: Repo) -> PullDetail {
        var detail = PullDetail(
            ref: PullRef(repo: repo, number: pull.number), title: pull.title, body: "", author: pull.author,
            baseBranch: settings.defaultBranch, headBranch: "", additions: 0, deletions: 0, commitCount: pull.commits,
            headSHA: pull.headSHA, reviews: pull.reviews, threads: pull.threads,
            failingChecks: pull.failedChecks.map { PullDetail.FailingCheck(name: $0, summary: "", url: nil) },
            checks: CheckSummary(
                passed: pull.passedChecks.count, failed: pull.failedChecks.count, pending: pull.pendingChecks.count,
                failedNames: pull.failedChecks, pendingNames: pull.pendingChecks
            ),
            closes: [], fetchedAt: pull.mergedAt
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "CLEAN"
        detail.reviewDecision = detail.latestReviews.contains { $0.state == "CHANGES_REQUESTED" }
            ? "CHANGES_REQUESTED" : nil
        detail.requiredChecks = settings.requiredChecks
        detail.labels = pull.labels.filter { label in !pull.removedBeforeMerge.contains(label) }
        detail.headCommittedAt = pull.headCommittedAt
        detail.passedChecks = pull.passedChecks
        detail.repoMergeMethods = settings.methods
        detail.repoAllowsAutoMerge = settings.autoMergeAllowed
        return detail
    }

    /// A rule that held a PR back, in a few words.
    static func reason(_ rule: GreenVerdict.Rule) -> String {
        switch rule.name {
        case "Green":
            let what = rule.detail.split(separator: ":").first.map(String.init) ?? rule.detail
            return switch what {
            case "checks pass": "checks failed"
            case "threads resolved": "review threads open"
            case "no changes requested": "changes requested"
            default: what
            }
        case "Reviewed after push": return "no review of the last push"
        case "No hold label": return "a hold label (\(rule.detail.replacingOccurrences(of: "labelled ", with: "")))"
        case "Gate checks": return "gate checks not passed"
        case "Quiet": return "not quiet yet"
        default: return rule.name.lowercased()
        }
    }

    static func describe(held: [Held], of total: Int) -> String {
        guard total > 0 else { return "No merged PRs to replay." }
        guard !held.isEmpty else { return "All \(total) merged PRs would have merged under these rules." }
        var counts: [String: Int] = [:]
        for pull in held {
            // A hold label counts once whichever label it was.
            let first = pull.reasons[0].hasPrefix("a hold label") ? "a hold label" : pull.reasons[0]
            counts[first, default: 0] += 1
        }
        let parts = counts.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.map { "\($0.value) \($0.key)" }
        return "\(held.count) of \(total) would be held: \(parts.joined(separator: ", "))."
    }

    /// The settings against GitHub's. `sample` (when there is one) adds what the merged PRs showed.
    public static func checks(
        _ github: RepoMergeSettings, repo: Repo, settings: PilotSettings, sample: RepoSetupSample? = nil,
        forceMerge: ForceMerge? = nil
    ) -> [Check] {
        var checks: [Check] = []
        let general = RepoMergeSettings.settingsURL(repo)
        let rules = RepoMergeSettings.settingsURL(repo, page: .rules)
        let admin = github.isAdmin
        if settings.merge != .off {
            let allowed = github.methods
            if let method = settings.mergeMethod {
                if github.linearHistory, method == "merge" {
                    checks.append(Check(
                        .fail,
                        "Linear history is required on \(github.defaultBranch): merge commits are refused; use squash or rebase.",
                        url: rules
                    ))
                } else if !allowed.contains(method) {
                    checks.append(Check(
                        .fail,
                        "The repo does not allow \(method) merges (allowed: \(allowed.isEmpty ? "none" : allowed.joined(separator: ", "))). Allow it in GitHub's settings, or pick another.",
                        url: general
                    ))
                } else {
                    checks.append(Check(.ok, "\(method.capitalized) merges are allowed."))
                }
            } else if let first = MergeQueue.method(settings, allowed: allowed) {
                checks.append(Check(.ok, "No method set: heed uses \(first), the first the repo allows."))
            } else {
                checks.append(Check(.fail, "The repo allows none of squash, merge or rebase.", url: general))
            }
        }
        switch settings.merge {
        case .auto:
            switch github.autoMergeAllowed {
            case true?: checks.append(Check(.ok, "Auto-merge is allowed."))
            case false?: checks.append(Check(
                    .fail, "Auto-merge is off for this repo: turn on “Allow auto-merge” in GitHub's settings.",
                    url: general
                ))
            case nil: checks.append(Check(.warn, "Whether the repo allows auto-merge is not known."))
            }
            if github.mergeQueue { checks.append(Check(.ok, "Auto-merge adds each PR to the merge queue.")) }
        case .heed:
            if github.mergeQueue {
                checks.append(Check(
                    .warn,
                    "\(github.defaultBranch) merges through a merge queue: a direct merge by heed needs admin rights; auto adds PRs to the queue.",
                    url: rules
                ))
            }
            if github.requiredApprovals > 0 {
                let unapproved = sample.map { $0.pulls.count { !$0.humanApproved } } ?? 0
                let bypass = admin == true ? "force_merge (admin) can bypass it" : "only an admin can bypass it"
                if !settings.trustedReviewers.isEmpty || unapproved > 0 {
                    checks.append(Check(
                        .warn,
                        "GitHub requires \(github.requiredApprovals) approval\(github.requiredApprovals == 1 ? "" : "s"); a trusted AI review does not count for GitHub, so heed's merge is refused without one: \(bypass).",
                        url: rules
                    ))
                } else {
                    checks.append(Check(
                        .ok,
                        "GitHub requires \(github.requiredApprovals) approval, which heed waits for too."
                    ))
                }
            }
        case .off:
            break
        }
        if settings.merge != .off, github.strictChecks {
            checks.append(settings.updateBranches
                ? Check(.ok, "Branches must be up to date: update_branches keeps them so.")
                : Check(.warn, "Branches must be up to date before merging: turn update_branches on.", url: rules))
        }
        if let forceMerge, forceMerge != .off {
            if admin == true {
                checks.append(Check(.ok, "You are an admin here: a forced merge bypasses branch protection."))
            } else {
                checks.append(Check(
                    .fail,
                    "force_merge needs admin rights on \(repo.slug); you have \(github.viewerPermission?.lowercased() ?? "unknown") rights."
                ))
            }
        }
        if settings.adminMerge, admin == false {
            checks.append(Check(.fail, "admin_merge is on but you are not an admin of \(repo.slug)."))
        }
        return checks
    }
}

/// Where a repo stands for get it merged and get it green, one line each: the Repos view's status beside Set up….
/// Merging is `RepoMergeReadiness` (the same answer the pilot's badges give), green is from the config's rules.
public struct RepoSetupStatus: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        /// Nothing in config.toml decides it for this repo.
        case notSetUp
        /// Off, or on and not checked against GitHub yet.
        case off
        case ok
        case warning
    }

    public struct Line: Hashable, Sendable {
        public var state: State
        public var text: String
    }

    public var merging: Line
    public var green: Line

    public static func of(_ repo: Repo, rules: PilotRules, readiness: RepoMergeReadiness) -> RepoSetupStatus {
        let settings = rules.resolve(repo)
        let mode = settings.merge.configName
        let decided = rules.repos[repo.slug]?.merge != nil || rules.orgs[repo.org]?.merge != nil
            || rules.defaults.merge != .off
        let off = Line(state: .off, text: "merging: off")
        let merging: Line = switch readiness {
        case .notSetUp where decided: off
        case .notSetUp: Line(state: .notSetUp, text: readiness.badge)
        case .unknown: Line(state: .off, text: "merging: \(mode) · not checked yet")
        case .ok: Line(
                state: .ok, text: "merging: ok · \(mode)" + (settings.mergeMethod.map { " · \($0)" } ?? "")
            )
        case let .misconfigured(problems): Line(state: .warning, text: "merging: ⚠ " + (problems.first ?? ""))
        }
        let greenDecided = rules.repos[repo.slug]?.green != nil || rules.orgs[repo.org]?.green != nil
            || rules.defaults.green != PilotSettings().green
        let green = switch settings.green {
        case .off: Line(state: .off, text: "green: off")
        case _ where !greenDecided: Line(state: .notSetUp, text: "green: not set up (\(settings.green.configName))")
        case _ where !settings.watch: Line(state: .warning, text: "green: ⚠ PRs here are not watched")
        default: Line(
                state: .ok,
                text: "green: \(settings.green.configName) · \(settings.maxRounds) round\(settings.maxRounds == 1 ? "" : "s")"
                    + (settings.agent.map { " · \($0)" + (settings.model.map { " \($0)" } ?? "") } ?? "")
            )
        }
        return RepoSetupStatus(merging: merging, green: green)
    }
}
