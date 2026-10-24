import Foundation
@testable import HeedCore
import Testing

/// Ready to merge, merge now and force merge for one PR, and whether a repo's merge settings can work, ahead of a run.
struct MergeReadinessTests {
    private let ref = PullRef(repo: Repo(org: "globex", name: "site"), number: 7)
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private let head = "abc1234def"

    /// Open, mergeable, clean, approved, checks passed, quiet for an hour, auto-merge off; the viewer can write.
    private func detail(_ edit: (inout PullDetail) -> Void = { _ in }) -> PullDetail {
        var detail = PullDetail(
            ref: ref, title: "Fix the footer", body: "", author: "me", baseBranch: "main", headBranch: "b",
            additions: 1, deletions: 1, commitCount: 1, headSHA: head,
            reviews: [.init(author: "alice", state: "APPROVED", submittedAt: now - 3600, commit: head)], threads: [],
            failingChecks: [], checks: CheckSummary(passed: 2), closes: [], fetchedAt: now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "CLEAN"
        detail.reviewDecision = "APPROVED"
        detail.requiredChecks = ["build"]
        detail.labels = []
        detail.headCommittedAt = now - 3600
        detail.autoMergeEnabled = false
        detail.repoAllowsAutoMerge = true
        detail.repoMergeMethods = ["squash", "merge"]
        detail.viewerPermission = "WRITE"
        edit(&detail)
        return detail
    }

    private func candidate(_ detail: PullDetail, _ settings: PilotSettings = PilotSettings()) -> MergeCandidate {
        MergeCandidate.of(detail, settings: settings, now: now)
    }

    private func unmet(_ detail: PullDetail, _ settings: PilotSettings = PilotSettings()) -> [String] {
        candidate(detail, settings).unmet.map(\.rule.name)
    }

    // MARK: The candidate predicate

    @Test func aGreenApprovedQuietPRIsACandidate() {
        #expect(candidate(detail()).isCandidate)
        #expect(unmet(detail()).isEmpty)
    }

    @Test func eachRequirementOnItsOwnHoldsAPRBack() {
        #expect(unmet(detail { $0.state = "CLOSED" }) == ["Open"])
        #expect(unmet(detail { $0.isDraft = true }) == ["Ready for review"])
        #expect(unmet(detail {
            $0.mergeable = "CONFLICTING"
            $0.mergeState = "DIRTY"
        }) == ["No conflicts"])
        #expect(unmet(detail { $0.mergeable = "UNKNOWN" }) == ["No conflicts"])
        #expect(unmet(detail { $0.mergeState = "BEHIND" }) == ["Up to date"])
        #expect(unmet(detail {
            $0.failingChecks = [.init(name: "build", summary: "", url: nil)]
            $0.checks = CheckSummary(passed: 1, failed: 1)
        }) == ["Checks pass"])
        #expect(unmet(detail { $0.reviewDecision = "CHANGES_REQUESTED" }) == ["Approved"])
        #expect(unmet(detail { $0.threads = [ReviewThread(
            id: "T1", isResolved: false, path: "a", line: 1, author: "bob", body: "?", diff: [], replies: 0, url: nil
        )] }) == ["Threads resolved"])
        #expect(unmet(detail { $0.labels = ["WIP"] }) == ["No hold label"])
        #expect(unmet(detail { $0.headCommittedAt = now - 60 }) == ["Quiet"])
        #expect(unmet(detail { $0.autoMergeEnabled = true }) == ["Auto-merge off"])
    }

    @Test func blockedOnlyOnReviewsIsTheReviewRequirement() {
        let waiting = detail {
            $0.mergeState = "BLOCKED"
            $0.reviewDecision = "REVIEW_REQUIRED"
        }
        #expect(unmet(waiting) == ["Approved"])
        #expect(candidate(waiting).unmet.map(\.bar) == [.github])
        // Blocked with everything heed can see in order: a rule it cannot see (a ruleset, code owners).
        let unseen = detail { $0.mergeState = "BLOCKED" }
        #expect(unmet(unseen) == ["Not blocked"])
    }

    @Test func noRequiredReviewsCountsAsApproved() {
        let unreviewed = detail {
            $0.reviewDecision = nil
            $0.reviews = []
        }
        #expect(candidate(unreviewed).isCandidate)
    }

    @Test func onlyRequiredChecksCountWhenTheRepoRequiresSome() {
        let flaky = detail {
            $0.failingChecks = [.init(name: "docs-preview", summary: "", url: nil)]
            $0.checks = CheckSummary(passed: 2, failed: 1)
            $0.mergeState = "UNSTABLE"
        }
        #expect(candidate(flaky).isCandidate)
        let running = detail {
            $0.checks = CheckSummary(passed: 1, pending: 1, pendingNames: ["build"])
        }
        #expect(unmet(running) == ["Checks pass"])
    }

    @Test func theQuietWindowAndHoldLabelsComeFromTheSettings() {
        var settings = PilotSettings()
        settings.quietMinutes = 0
        #expect(candidate(detail { $0.headCommittedAt = now - 1 }, settings).isCandidate)
        settings.holdLabels = ["parked"]
        #expect(unmet(detail { $0.labels = ["Parked"] }, settings) == ["No hold label"])
        // A review is activity too.
        #expect(unmet(detail {
            $0.reviews = [.init(author: "alice", state: "APPROVED", submittedAt: now - 30, commit: head)]
        }) == ["Quiet"])
    }

    // MARK: Merge now and force merge

    @Test func mergeNowWhenGitHubWouldTakeIt() {
        let ready = detail()
        #expect(MergeNow.offer(candidate(ready), detail: ready, settings: PilotSettings()) ==
            .merge(method: "squash", skipping: []))
        // heed's own waits (quiet, auto-merge on) are skipped by merging now, and named.
        let fresh = detail { $0.headCommittedAt = now - 60 }
        guard case let .merge(method, skipping) = MergeNow.offer(
            candidate(fresh), detail: fresh, settings: PilotSettings()
        ) else { Issue.record("expected merge"); return }
        #expect(method == "squash" && skipping.map(\.name) == ["Quiet"])
    }

    @Test func forceMergeOnlyForAnAdminAndOnlyPastWhatGitHubEnforces() {
        let unapproved = detail {
            $0.mergeState = "BLOCKED"
            $0.reviewDecision = "REVIEW_REQUIRED"
        }
        // Not an admin: nothing merges it now.
        guard case let .unavailable(why) = MergeNow.offer(
            candidate(unapproved), detail: unapproved, settings: PilotSettings()
        ) else { Issue.record("expected unavailable"); return }
        #expect(why.contains("Approved") && why.contains("admin"))
        var admin = unapproved
        admin.viewerPermission = "ADMIN"
        guard case let .force(method, bypassing, _) = MergeNow.offer(
            candidate(admin), detail: admin, settings: PilotSettings()
        ) else { Issue.record("expected force"); return }
        #expect(method == "squash" && bypassing.map(\.name) == ["Approved"])
        // force_merge = "off": never offered.
        var off = PilotSettings()
        off.forceMerge = .off
        guard case let .unavailable(offWhy) = MergeNow.offer(candidate(admin), detail: admin, settings: off)
        else { Issue.record("expected unavailable"); return }
        #expect(offWhy.contains("force_merge"))
        // What nobody bypasses: a draft, conflicts, a hold label.
        var draft = admin
        draft.isDraft = true
        #expect(MergeNow.offer(candidate(draft), detail: draft, settings: PilotSettings()) ==
            .unavailable("Ready for review: draft"))
        var held = admin
        held.labels = ["hold"]
        #expect(MergeNow.offer(candidate(held), detail: held, settings: PilotSettings()) ==
            .unavailable("No hold label: labelled hold"))
    }

    @Test func mergeNowTakesTheConfiguredMethodOnlyWhenTheRepoAllowsIt() {
        var settings = PilotSettings()
        settings.mergeMethod = "rebase"
        let ready = detail()
        #expect(MergeNow.offer(candidate(ready), detail: ready, settings: settings) ==
            .unavailable("the repo does not allow rebase merges"))
        settings.mergeMethod = "merge"
        #expect(MergeNow.offer(candidate(ready), detail: ready, settings: settings) ==
            .merge(method: "merge", skipping: []))
    }

    @Test func confirmationsFollowMergeNowAndForceMerge() {
        var settings = PilotSettings()
        #expect(settings.mergeNow == .ask && settings.forceMerge == .ask)
        let merge = MergeNow.Offer.merge(method: "squash", skipping: [])
        let force = MergeNow.Offer.force(method: "squash", bypassing: [], skipping: [])
        #expect(MergeNow.asks(merge, settings: settings) && MergeNow.asks(force, settings: settings))
        settings.mergeNow = .auto
        #expect(!MergeNow.asks(merge, settings: settings) && MergeNow.asks(force, settings: settings))
        settings.forceMerge = .auto
        #expect(!MergeNow.asks(force, settings: settings))
    }

    @Test func theMergeConfirmationNamesThePRTheMethodAndWhatIsUnmet() throws {
        let fresh = detail { $0.headCommittedAt = now - 60 }
        let offer = MergeNow.offer(candidate(fresh), detail: fresh, settings: PilotSettings())
        let prompt = try #require(MergeNow.prompt(offer, detail: fresh))
        #expect(prompt.title == "Merge globex/site#7 now?")
        #expect(prompt.lines == [
            "Fix the footer",
            "squash into main, on the commit heed checked (abc1234)",
            "Not met, merged anyway · Quiet: quiet for 4m more",
        ])
        #expect(prompt.accept == "Merge (squash)" && !prompt.destructive)
        let ready = detail()
        let clean = try #require(MergeNow.prompt(
            MergeNow.offer(candidate(ready), detail: ready, settings: PilotSettings()), detail: ready
        ))
        #expect(clean.lines.last == "Every requirement is met")
    }

    @Test func theForceConfirmationListsExactlyWhatIsBypassed() throws {
        let blocked = detail {
            $0.mergeState = "BLOCKED"
            $0.reviewDecision = "REVIEW_REQUIRED"
            $0.checks = CheckSummary(passed: 1, pending: 1, pendingNames: ["build"])
            $0.viewerPermission = "ADMIN"
        }
        let offer = MergeNow.offer(candidate(blocked), detail: blocked, settings: PilotSettings())
        let prompt = try #require(MergeNow.prompt(offer, detail: blocked))
        #expect(prompt.title == "Force-merge globex/site#7 with --admin?")
        #expect(prompt.lines == [
            "Fix the footer",
            "squash into main with --admin, on the commit heed checked (abc1234)",
            "Bypassed · Checks pass: build still running",
            "Bypassed · Approved: needs an approving review",
        ])
        #expect(prompt.accept == "Force merge" && prompt.destructive)
        #expect(MergeNow.prompt(.unavailable("x"), detail: blocked) == nil)
    }

    // MARK: A repo's merge settings

    private let facts = RepoMergeFacts(
        allowsAutoMerge: true, methods: ["squash", "merge"], linearHistory: false, viewerPermission: "WRITE"
    )

    private func readiness(
        _ edit: (inout PilotSettings) -> Void, facts: RepoMergeFacts?
    ) -> RepoMergeReadiness {
        var settings = PilotSettings()
        edit(&settings)
        return RepoMergeReadiness.of(settings, facts: facts)
    }

    @Test func mergingOffIsNotSetUp() {
        #expect(readiness({ _ in }, facts: facts) == .notSetUp)
        #expect(RepoMergeReadiness.notSetUp.badge == "merging: not set up")
    }

    @Test func mergingOnWithSettingsTheRepoTakesIsOK() {
        #expect(readiness({ $0.merge = .auto }, facts: facts) == .ok)
        #expect(readiness({ $0.merge = .heed }, facts: facts) == .ok)
        #expect(readiness({ $0.merge = .auto }, facts: nil) == .unknown)
        #expect(RepoMergeReadiness.ok.badge == "merging: ok")
    }

    @Test func misconfigurationsAreFoundAheadOfARun() {
        var noAuto = facts
        noAuto.allowsAutoMerge = false
        #expect(readiness({ $0.merge = .auto }, facts: noAuto) == .misconfigured([
            "merge = \"auto\" needs GitHub's auto-merge, which the repo does not allow (Settings › General)",
        ]))
        // heed merges itself: GitHub's auto-merge does not matter.
        #expect(readiness({ $0.merge = .heed }, facts: noAuto) == .ok)
        #expect(readiness({
            $0.merge = .heed
            $0.mergeMethod = "rebase"
        }, facts: facts) == .misconfigured(["the repo does not allow rebase merges (it allows squash, merge)"]))
        var linear = facts
        linear.linearHistory = true
        #expect(readiness({
            $0.merge = .heed
            $0.mergeMethod = "merge"
        }, facts: linear) == .misconfigured([
            "the base branch requires linear history, which a merge commit breaks: use squash or rebase",
        ]))
        // squash keeps history linear.
        #expect(readiness({ $0.merge = .heed }, facts: linear) == .ok)
        #expect(readiness({
            $0.merge = .heed
            $0.adminMerge = true
        }, facts: facts) == .misconfigured(["admin_merge is on, but you are not an admin of the repo"]))
        var admin = facts
        admin.viewerPermission = "ADMIN"
        #expect(readiness({
            $0.merge = .heed
            $0.adminMerge = true
        }, facts: admin) == .ok)
        let several = readiness({
            $0.merge = .auto
            $0.mergeMethod = "rebase"
        }, facts: noAuto)
        #expect(several.problems.count == 2)
        #expect(several.badge == "merging: ⚠")
        #expect(several.line?.hasPrefix("Merging misconfigured: ") == true)
    }

    @Test func aPRsOwnMergeChoiceIsCheckedToo() {
        var noAuto = facts
        noAuto.allowsAutoMerge = false
        // The repo leaves merging off, but zm turned auto on for this PR.
        #expect(RepoMergeReadiness.of(PilotSettings(), mode: .auto, facts: noAuto).problems.count == 1)
    }

    @Test func theFactsComeFromTheNewestDetailOfTheRepo() {
        var old = detail()
        old.fetchedAt = now - 600
        old.repoAllowsAutoMerge = false
        var new = detail()
        new.repoRequiresLinearHistory = true
        var other = detail()
        other.ref = PullRef(repo: Repo(org: "globex", name: "else"), number: 1)
        other.fetchedAt = now + 600
        let found = RepoMergeFacts.of(ref.repo, details: [old, new, other])
        #expect(found == RepoMergeFacts(
            allowsAutoMerge: true, methods: ["squash", "merge"], linearHistory: true, viewerPermission: "WRITE"
        ))
        #expect(RepoMergeFacts.of(Repo(org: "x", name: "y"), details: [old]) == nil)
    }

    // MARK: The fake world

    @Test func theFakeWorldHasAPRReadyToMergeAndAMisconfiguredRepo() throws {
        let details = Fixtures.main.pullDetails
        let ingest = try #require(details["umbrella/ingest#31"])
        let settings = Fixtures.pilotRules.resolve(ingest.ref.repo)
        #expect(settings.merge == .off)
        #expect(MergeCandidate.of(ingest, settings: settings, now: Date()).isCandidate)
        let markgraph = Repo(org: "globex", name: "markgraph")
        let readiness = RepoMergeReadiness.of(
            Fixtures.pilotRules.resolve(markgraph), facts: RepoMergeFacts.of(markgraph, details: details.values)
        )
        #expect(readiness.problems.count == 1)
    }

    // MARK: Settings

    @Test func mergeNowAndForceMergeResolvePerRepo() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [pilot]
        merge_now = "auto"
        [orgs.globex]
        force_merge = "off"
        [repos."globex/site"]
        force_merge = "auto"
        merge_now = "ask"
        [repos."globex/bad"]
        merge_now = "always"
        force_merge = "yes"
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.mergeNow == .auto)
        #expect(config.pilot.defaults.forceMerge == .ask)
        let other = config.pilot.resolve(Repo(org: "globex", name: "other"))
        #expect(other.mergeNow == .auto && other.forceMerge == .off)
        let site = config.pilot.resolve(Repo(org: "globex", name: "site"))
        #expect(site.mergeNow == .ask && site.forceMerge == .auto)
        #expect(Set(problems.map(\.path)) == ["repos.globex/bad.merge_now", "repos.globex/bad.force_merge"])
        #expect(config.pilot.resolve(Repo(org: "initech", name: "x")).forceMerge == .ask)
    }

    @Test func theNewKeysAreOnOrgsAndRepos() {
        let ids = Overrides.keys(for: .org("globex")).map(\.id)
        #expect(ids.contains("merge_now") && ids.contains("force_merge"))
    }

    @Test func theDetailQueryReadsLinearHistoryAndTheViewersPermission() throws {
        #expect(GitHub.pullDetailQuery.contains("viewerPermission"))
        #expect(GitHub.pullDetailQuery.contains("requiresLinearHistory"))
        let json = """
        {"data":{"repository":{"viewerPermission":"ADMIN","autoMergeAllowed":false,"squashMergeAllowed":true,
          "pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main","headRefName":"b","state":"OPEN",
          "baseRef":{"refUpdateRule":{"requiresLinearHistory":true}},
          "commits":{"totalCount":1,"nodes":[]},"reviews":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let parsed = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: now))
        #expect(parsed.viewerPermission == "ADMIN")
        #expect(parsed.repoRequiresLinearHistory == true)
        #expect(RepoMergeFacts(parsed) == RepoMergeFacts(
            allowsAutoMerge: false, methods: ["squash"], linearHistory: true, viewerPermission: "ADMIN"
        ))
    }
}
