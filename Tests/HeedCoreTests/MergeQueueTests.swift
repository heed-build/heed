import Foundation
@testable import HeedCore
import Testing

struct MergeQueueTests {
    private let repo = Repo(org: "nullean", name: "heed")

    private func detail(
        _ number: Int = 7, mergeable: String? = "MERGEABLE", state: String? = "CLEAN", failing: [String] = [],
        pending: [String] = [], threads: Int = 0, autoMerge: Bool = false, allowsAuto: Bool? = true,
        methods: [String]? = ["squash", "merge", "rebase"], prState: String = "OPEN"
    ) -> PullDetail {
        var detail = PullDetail(
            ref: PullRef(repo: repo, number: number), title: "t", body: "", author: nil, baseBranch: "main",
            headBranch: "b", additions: 0, deletions: 0, commitCount: 1, headSHA: "a1", reviews: [],
            threads: (0 ..< threads).map {
                ReviewThread(
                    id: "T\($0)", isResolved: false, path: "f", line: 1, author: "r", body: "x", diff: [], replies: 0,
                    url: nil
                )
            },
            failingChecks: failing.map { PullDetail.FailingCheck(name: $0, summary: "\($0) broke", url: nil) },
            checks: CheckSummary(
                passed: 2, failed: failing.count, pending: pending.count, failedNames: failing, pendingNames: pending
            ),
            closes: [], fetchedAt: Date()
        )
        detail.state = prState
        detail.isDraft = false
        detail.mergeable = mergeable
        detail.mergeState = state
        detail.requiredChecks = []
        detail.autoMergeEnabled = autoMerge
        detail.repoAllowsAutoMerge = allowsAuto
        detail.repoMergeMethods = methods
        return detail
    }

    private func action(
        _ detail: PullDetail, settings: PilotSettings = PilotSettings(merge: .auto), paused: Bool = false
    ) -> MergeQueue.Action {
        MergeQueue.action(for: MergeQueue.Entry(ref: detail.ref, detail: detail, settings: settings, paused: paused))
    }

    @Test func greenTurnsAutoMergeOn() {
        #expect(action(detail()) == .enableAutoMerge(method: "squash"))
        #expect(action(detail(methods: ["rebase"])) == .enableAutoMerge(method: "rebase"))
        #expect(action(detail(), settings: PilotSettings(merge: .auto, mergeMethod: "merge"))
            == .enableAutoMerge(method: "merge"))
    }

    @Test func waitingIsHandedToGitHubOnlyWhenGitHubIsHoldingIt() {
        // BLOCKED: GitHub waits on its requirements, so auto-merge waits too.
        #expect(action(detail(state: "BLOCKED", pending: ["build"])) == .enableAutoMerge(method: "squash"))
        // UNSTABLE: --auto would merge right away with the check still running.
        #expect(action(detail(state: "UNSTABLE", pending: ["build"])) == .hold("Checks pass: build still running"))
        #expect(action(detail(mergeable: "UNKNOWN", state: "UNKNOWN"))
            == .hold("No conflicts: GitHub is still working it out"))
    }

    @Test func failuresHoldOrTurnAutoMergeOff() {
        #expect(action(detail(failing: ["lint"])) == .hold("Checks pass: lint failed"))
        #expect(action(detail(threads: 1, autoMerge: true)) ==
            .disableAutoMerge(reason: "Threads resolved: 1 thread open"))
        #expect(action(detail(state: "BLOCKED", pending: ["build"], autoMerge: true))
            == .waiting("auto-merge on, waiting: build still running"))
    }

    @Test func behindIsBroughtUpToDate() {
        #expect(action(detail(state: "BEHIND")) == .updateBranch)
        let noUpdates = PilotSettings(merge: .auto, updateBranches: false)
        #expect(action(detail(state: "BEHIND"), settings: noUpdates)
            == .hold("Up to date: behind main, which this repo requires to be current"))
    }

    @Test func whatTheRepoAndThePauseAllow() {
        #expect(action(detail(), paused: true) == .hold("paused"))
        #expect(action(detail(allowsAuto: false))
            == .hold("the repo does not allow auto-merge (Settings → General → Allow auto-merge)"))
        #expect(action(detail(methods: ["squash"]), settings: PilotSettings(merge: .auto, mergeMethod: "rebase"))
            == .hold("the repo does not allow rebase merges"))
    }

    @Test func aRunGoesOldestFirstAndSkipsWhatLeft() {
        let entries = [detail(9), detail(3), detail(5, prState: "MERGED")].map {
            MergeQueue.Entry(ref: $0.ref, detail: $0, settings: PilotSettings(merge: .auto), paused: false)
        }
        #expect(MergeQueue.plan(entries).map(\.ref.number) == [3, 9])
    }

    @Test func schedule() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(MergeRun.nextRun(last: nil, every: 3600, now: now) == now)
        #expect(MergeRun.nextRun(last: now, every: 3600, now: now) == now.addingTimeInterval(3600))
        #expect(MergeRun.nextRun(last: now, every: nil, now: now) == nil)
    }

    @Test func theRunLogIsKeptPerRepoAndCapped() {
        var domain = Domain()
        for index in 0 ..< MergeRun.keep + 5 {
            domain.apply(.mergeRan(MergeRun(
                repo: repo.slug, at: Date(timeIntervalSince1970: Double(index)), why: "schedule", lines: []
            )))
        }
        #expect(domain.mergeRuns[repo.slug]?.count == MergeRun.keep)
        #expect(domain.mergeRuns[repo.slug]?.first?.at == Date(timeIntervalSince1970: Double(MergeRun.keep + 4)))
    }

    @Test func aMergeIsLogged() {
        var domain = Domain()
        domain.apply(.pullDetailFetched(detail()))
        domain.apply(.pullDetailFetched(detail(prState: "MERGED")))
        #expect(domain.pilotLog.first?.kind == .merged)
    }

    @Test func mergeIsSetPerPRAndFollowsSettingsOtherwise() throws {
        var pipeline = PullFeedback(ref: PullRef(repo: repo, number: 7))
        #expect(pipeline.effective(PilotSettings(merge: .auto)).merge == .auto)
        pipeline.merge = .off
        pipeline.mergeSet = true
        #expect(pipeline.effective(PilotSettings(merge: .auto)).merge == .off)
        // A pipeline cached before merging existed still loads.
        let old = #"{"ref":{"repo":{"org":"nullean","name":"heed"},"number":7},"items":[],"autoFeed":"Ask","#
            + #""watching":true,"rounds":0,"approvalsSeen":0}"#
        let decoded = try JSONDecoder().decode(PullFeedback.self, from: Data(old.utf8))
        #expect(decoded.merge == .off)
        #expect(!decoded.mergeSet)
    }

    @Test func configReadsMergeAtEveryLevel() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [pilot]
        merge = "auto"
        merge_method = "rebase"
        merge_schedule = "15m"
        update_branches = false
        [orgs.employer]
        merge = "off"
        [repos."employer/main"]
        merge = "auto"
        merge_method = "squash"
        [repos."elastic/x"]
        merge = "yolo"
        merge_method = "fast-forward"
        """)
        let config = try #require(decoded)
        #expect(config.pilot.defaults.merge == .auto)
        #expect(config.pilot.defaults.mergeSchedule == 900)
        #expect(!config.pilot.defaults.updateBranches)
        #expect(config.pilot.resolve(Repo(org: "employer", name: "other")).merge == .off)
        let main = config.pilot.resolve(Repo(org: "employer", name: "main"))
        #expect(main.merge == .auto)
        #expect(main.mergeMethod == "squash")
        #expect(config.pilot.resolve(Repo(org: "nullean", name: "heed")).mergeMethod == "rebase")
        #expect(problems.count == 2)

        let manual = ConfigLoader.decode("[pilot]\nmerge_schedule = \"manual\"").0
        #expect(manual?.pilot.defaults.mergeSchedule == nil)
        #expect(manual != nil)
        #expect(ConfigLoader.decode("[pilot]\nmerge_schedule = \"1m\"").1.count == 1)
    }

    @Test func theDetailQueryReadsMergeFields() throws {
        let json = """
        {"data":{"repository":{"autoMergeAllowed":true,"squashMergeAllowed":true,"mergeCommitAllowed":false,
          "rebaseMergeAllowed":true,"pullRequest":{"number":7,"title":"t","body":"","baseRefName":"main",
          "headRefName":"b","additions":1,"deletions":1,"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE",
          "mergeStateStatus":"BLOCKED","reviewDecision":null,
          "autoMergeRequest":{"enabledAt":"2026-10-14T08:00:00Z","mergeMethod":"SQUASH"},
          "labels":{"nodes":[{"name":"hold"}]},
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"a1","statusCheckRollup":null}}]},
          "reviews":{"nodes":[]},"closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]}}}}}
        """
        let ref = PullRef(repo: repo, number: 7)
        let detail = try #require(GitHub.parsePullDetail(Data(json.utf8), ref: ref, now: Date()))
        #expect(detail.autoMergeEnabled == true)
        #expect(detail.autoMergeMethod == "squash")
        #expect(detail.labels == ["hold"])
        #expect(detail.repoAllowsAutoMerge == true)
        #expect(detail.repoMergeMethods == ["squash", "rebase"])
    }
}
