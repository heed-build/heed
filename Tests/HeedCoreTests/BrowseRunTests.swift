import Foundation
@testable import HeedCore
import Testing

/// A Browse run's life, which runs may start, the review it drafts, and who it is allowed to work for.
struct BrowseRunTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs-toolkit")

    private func issue(_ number: Int = 2830, author: String? = "mara", bot: Bool = false) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number,
            title: ExternalText("Anchors lost when a page is moved", source: .issueTitle, author: .unknown),
            author: author, authorIsBot: bot
        )
    }

    private func pull(_ number: Int = 412) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, kind: .pull,
            title: ExternalText("Bump spec tests", source: .pullTitle, author: .unknown), author: "renovate"
        )
    }

    private func run(
        _ verb: BrowseVerb = .fix, item: BrowseItem? = nil, phase: BrowseRun.Phase = .preparing,
        mode: BrowseRun.Mode = .full
    ) -> BrowseRun {
        BrowseRun(
            item: item ?? issue(), verb: verb, mode: mode, agent: "claude", adapter: "claude via ACP",
            name: "issue-2830-4f9c2e", branch: "heed/browse/issue-2830-4f9c2e", worktree: "/wt/issue-2830-4f9c2e",
            phase: phase, startedAt: now, cap: 0.5
        )
    }

    private func apply(_ run: inout BrowseRun, _ event: BrowseRun.Event) -> [BrowseRun.Effect]? {
        run.apply(event, at: now)
    }

    // MARK: Lifecycle

    @Test func aRunWalksFromCloneToWorkToDone() {
        var run = run(phase: .needsClone)
        #expect(apply(&run, .cloneStarted) == [])
        #expect(run.phase == .cloning)
        #expect(apply(&run, .cloned) == [])
        #expect(run.phase == .preparing)
        #expect(apply(&run, .ready(note: "claude started")) == [])
        #expect(run.phase == .working)
        #expect(apply(&run, .turnEnded(.endTurn, cancel: nil, connected: true)) == [.finishTurn])
        #expect(run.phase == .done(.endTurn))
        #expect(run.canSteer)
        // A follow-up starts another turn.
        #expect(apply(&run, .turnStarted) == [])
        #expect(run.phase == .working)
        #expect(apply(&run, .closed("closed")) == [])
        #expect(run.phase == .closed("closed"))
        #expect(run.endedAt == now)
    }

    @Test func eventsThatDoNotFitTheStateChangeNothing() {
        // Each row: a state, an event that cannot apply to it.
        let rows: [(BrowseRun.Phase, BrowseRun.Event)] = [
            (.needsClone, .cloned), (.needsClone, .ready(note: nil)), (.needsClone, .turnStarted),
            (.needsClone, .turnEnded(.endTurn, cancel: nil, connected: true)), (.needsClone, .turnFailed("x")),
            (.cloning, .cloneStarted), (.cloning, .declined), (.cloning, .ready(note: nil)),
            (.preparing, .cloned), (.preparing, .turnStarted), (
                .preparing,
                .turnEnded(.endTurn, cancel: nil, connected: true)
            ),
            (.working, .ready(note: nil)), (.working, .cloneStarted), (.working, .declined),
            (.done(.endTurn), .turnEnded(.endTurn, cancel: nil, connected: true)), (.done(.endTurn), .turnFailed("x")),
            (.done(.endTurn), .couldNotStart("x")), (.done(.endTurn), .ready(note: nil)),
            (.failed("x"), .turnStarted), (.failed("x"), .ready(note: nil)), (.failed("x"), .turnFailed("y")),
            (.failed("x"), .closed("closed")), (.closed("closed"), .turnStarted), (.closed("closed"), .closed("again")),
            (.closed("closed"), .turnEnded(.endTurn, cancel: nil, connected: true)),
            (.closed("closed"), .agentExited("x")), (.failed("x"), .agentExited("y")),
        ]
        for (phase, event) in rows {
            var run = run(phase: phase)
            let before = run.phase
            let effects = apply(&run, event)
            #expect(effects == nil, "\(phase) took \(event)")
            #expect(run.phase == before, "\(phase) moved on \(event)")
        }
    }

    @Test func aFinishedRunIsNotBroughtBackByALateTurnEnd() {
        var run = run(phase: .working)
        _ = apply(&run, .closed("closed"))
        #expect(apply(&run, .turnEnded(.endTurn, cancel: nil, connected: true)) == nil)
        #expect(apply(&run, .turnFailed("late")) == nil)
        #expect(run.phase == .closed("closed"))
    }

    @Test func failuresEndTheRunAndKeepWhy() {
        for event in [
            BrowseRun.Event.couldNotStart("no worktree"),
            .turnFailed("no worktree"),
            .agentExited("no worktree"),
        ] {
            var run = run(phase: .working)
            #expect(apply(&run, event) == [])
            #expect(run.phase == .failed("no worktree"))
            #expect(run.endedAt == now)
            #expect(run.story.feed.contains { if case .note("no worktree") = $0.body { true } else { false } })
        }
        var cloning = run(phase: .cloning)
        _ = apply(&cloning, .cloneFailed("no space"))
        #expect(cloning.phase == .failed("no space"))
        // An agent that goes away while the run waits for you is no failure.
        var done = run(phase: .done(.endTurn))
        #expect(apply(&done, .agentExited("gone")) == [])
        #expect(done.phase == .done(.endTurn))
    }

    @Test func notNowClosesTheCloneCard() {
        var run = run(phase: .needsClone)
        #expect(apply(&run, .declined) == [])
        #expect(run.phase == .closed("not now"))
    }

    @Test func aSteerCancelsTheTurnAndStartsTheNextOnYourWords() {
        var run = run(phase: .working)
        #expect(apply(&run, .turnEnded(.cancelled, cancel: .steer("use the old overload"), connected: true)) ==
            [.steer("use the old overload")])
        #expect(run.phase == .working)
        // Its agent gone meanwhile: nothing to steer.
        var gone = self.run(phase: .working)
        #expect(apply(&gone, .turnEnded(.cancelled, cancel: .steer("x"), connected: false)) == [])
        #expect(gone.phase == .done(.cancelled))
        // heed stopping it (the spend cap) ends the turn and says why.
        var capped = self.run(phase: .working)
        #expect(apply(&capped, .turnEnded(.cancelled, cancel: .stop("reached its $0.5 spend cap"), connected: true)) ==
            [.finishTurn])
        #expect(capped.phase == .done(.cancelled))
        #expect(capped.story.feed
            .contains { if case .note("reached its $0.5 spend cap") = $0.body { true } else { false } })
    }

    @Test func theSpendCapComesFromWhatTheAgentReports() {
        var run = run(phase: .working)
        #expect(!run.overCap)
        run.apply(.usage(used: 10, size: 100, cost: 0.2, currency: "USD"), at: now)
        #expect(!run.overCap)
        run.apply(.usage(used: 10, size: 100, cost: 0.5, currency: "USD"), at: now)
        #expect(run.overCap)
        #expect(run.cost == 0.5)
    }

    // MARK: How many

    @Test func oneRunPerItemAndAtMostMaxRunsWorkingAtOnce() {
        let a = run(item: issue(1)), b = run(item: issue(2)), c = run(item: issue(3), phase: .working)
        let runs = [a, b, c]
        #expect(BrowseRuns.canStart(item: issue(4).id, runs: runs, max: 4) == .ok)
        #expect(BrowseRuns.canStart(item: issue(4).id, runs: runs, max: 3) == .atCap(3))
        #expect(BrowseRuns.canStart(item: issue(1).id, runs: runs, max: 10) == .itemBusy)
        #expect(BrowseRuns.canStart(item: issue(4).id, runs: runs, max: 0) == .ok)
        #expect(BrowseRuns.working(runs) == 3)
        // A run waiting for you (done, or asking to clone) holds no slot; a failed or closed one is gone.
        let waiting = [run(item: issue(1), phase: .done(.endTurn)), run(item: issue(2), phase: .needsClone)]
        #expect(BrowseRuns.working(waiting) == 0)
        #expect(BrowseRuns.canStart(item: issue(5).id, runs: waiting, max: 1) == .ok)
        #expect(BrowseRuns.canStart(item: issue(1).id, runs: waiting, max: 1) == .itemBusy)
        let over = [run(item: issue(1), phase: .failed("x")), run(item: issue(2), phase: .closed("closed"))]
        #expect(BrowseRuns.canStart(item: issue(1).id, runs: over, max: 1) == .ok)
        #expect(BrowseRuns.current(for: issue(1).id, in: over) == nil)
        #expect(BrowseRuns.Start.atCap(3).reason?.contains("3") == true)
    }

    // MARK: A drafted review

    private let message = """
    Fine overall.
    heed-did: read the diff
    heed-comment fixtures/a.json:18: This snapshot moved: worth a changelog line.
    heed-verdict: request changes
    """

    @Test func aReviewIsDraftedFromTheAgentsLastMessage() throws {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        run.drafted(from: message)
        let draft = try #require(run.draft)
        #expect(draft.verdict == .requestChanges)
        #expect(draft.did == ["read the diff"])
        #expect(draft.comments.first?.place == "fixtures/a.json:18")
        #expect(draft.body.contains("read the diff"))
        #expect(draft.state == .drafted)
        // Nothing in the message: no draft.
        var empty = self.run(.review, item: pull())
        empty.drafted(from: "  ")
        #expect(empty.draft == nil)
        // A Fix never drafts a review.
        var fix = self.run(.fix)
        fix.drafted(from: message)
        #expect(fix.draft == nil)
    }

    @Test func aReviewIsPostedOnceFromOneExplicitAction() throws {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        let t1 = run.beginPost()
        #expect(t1 == nil, "no draft, nothing to post")
        run.drafted(from: message)
        let t2 = run.beginPost()
        let sent = try #require(t2)
        #expect(sent.verdict == .requestChanges)
        #expect(run.draft?.state == .posting)
        let t3 = run.beginPost()
        #expect(t3 == nil, "never twice while it is going")
        run.posted()
        #expect(run.draft?.state == .posted)
        let t4 = run.beginPost()
        #expect(t4 == nil, "never again once posted")
        let t5 = run.discardDraft()
        #expect(!t5)
        // A newer draft does not replace one that is posted.
        run.drafted(from: "heed-did: something else\nheed-verdict: approve")
        #expect(run.draft?.verdict == .requestChanges)
    }

    @Test func aFailedPostLeavesTheDraftToTryAgain() throws {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        run.drafted(from: message)
        _ = run.beginPost()
        run.postFailed("rate limited")
        #expect(run.draft?.state == .drafted)
        #expect(run.draft?.failure == "rate limited")
        let t6 = run.beginPost()
        #expect(t6 != nil)
        // postFailed with nothing being posted changes nothing.
        var idle = self.run(.review, item: pull())
        idle.drafted(from: message)
        idle.postFailed("x")
        #expect(idle.draft?.failure == nil)
    }

    @Test func discardingDropsTheDraftAndPostsNothing() {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        run.drafted(from: message)
        let t7 = run.discardDraft()
        #expect(t7)
        #expect(run.draft?.state == .discarded)
        let t8 = run.beginPost()
        #expect(t8 == nil)
    }

    @Test func editingChangesTheTextBeforePostingOnly() throws {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        run.drafted(from: message)
        let t9 = run.editDraft("  Looks good, one nit.  ")
        #expect(t9)
        #expect(run.draft?.body == "Looks good, one nit.")
        let t10 = run.editDraft("   ")
        #expect(!t10, "an empty review is not a review")
        _ = run.beginPost()
        let t11 = run.editDraft("changed while posting")
        #expect(!t11)
        run.posted()
        let t12 = run.editDraft("changed after posting")
        #expect(!t12)
        #expect(run.draft?.body == "Looks good, one nit.")
    }

    @Test func aNewDraftReplacesOneNotYetPosted() {
        var run = run(.review, item: pull(), phase: .done(.endTurn))
        run.drafted(from: message)
        run.drafted(from: "heed-did: rechecked\nheed-verdict: approve")
        #expect(run.draft?.verdict == .approve)
        #expect(run.draft?.did == ["rechecked"])
    }

    // MARK: Whose work it runs on

    @Test func youAndThoseWhoCanWriteAreTrustedOnIssues() {
        let mine = BrowseTrust.issue(issue(author: "you"), viewer: "You", canWrite: nil, trustedAuthors: [])
        #expect(mine.trusted)
        #expect(BrowseTrust.issue(issue(author: "mara"), viewer: "you", canWrite: true, trustedAuthors: []).trusted)
        #expect(BrowseTrust.issue(issue(author: "mara"), viewer: "you", canWrite: nil, trustedAuthors: ["MARA"])
            .trusted)
        let stranger = BrowseTrust.issue(issue(author: "lsmith"), viewer: "you", canWrite: false, trustedAuthors: [])
        #expect(!stranger.trusted)
        #expect(stranger.text.contains("@lsmith"))
        #expect(!BrowseTrust.issue(issue(author: "lsmith"), viewer: "you", canWrite: nil, trustedAuthors: []).trusted)
        #expect(!BrowseTrust.issue(issue(author: nil), viewer: "you", canWrite: true, trustedAuthors: []).trusted)
        // A bot only when listed.
        #expect(!BrowseTrust.issue(
            issue(author: "renovate", bot: true),
            viewer: "you",
            canWrite: true,
            trustedAuthors: []
        ).trusted)
        #expect(BrowseTrust.issue(
            issue(author: "renovate", bot: true),
            viewer: "you",
            canWrite: false,
            trustedAuthors: ["renovate[bot]"]
        ).trusted)
        #expect(!BrowseTrust.issue(
            issue(author: "renovate", bot: false),
            viewer: "you",
            canWrite: false,
            trustedAuthors: ["renovate[bot]"]
        ).trusted)
    }

    @Test func aPullRequestFromAForkIsNeverTrustedAndCannotBePushedTo() {
        let fork = PullAuthorship(author: "mara", association: "COLLABORATOR", crossRepository: true)
        let verdict = BrowseTrust.pull(fork, viewer: "you", trustedAuthors: ["mara"])
        #expect(!verdict.trusted)
        #expect(!verdict.canPush)
        let own = PullAuthorship(author: "mara", association: "COLLABORATOR", crossRepository: false)
        let ok = BrowseTrust.pull(own, viewer: "you", trustedAuthors: [])
        #expect(ok.trusted)
        #expect(ok.canPush)
        // Yours from a fork is yours, and still cannot be pushed to.
        let mineFromFork = BrowseTrust.pull(
            PullAuthorship(author: "you", association: "OWNER", crossRepository: true), viewer: "you",
            trustedAuthors: []
        )
        #expect(mineFromFork.trusted)
        #expect(!mineFromFork.canPush)
        let outsider = BrowseTrust.pull(
            PullAuthorship(author: "x", association: "NONE", crossRepository: false), viewer: "you", trustedAuthors: []
        )
        #expect(!outsider.trusted)
    }

    @Test func untrustedAuthorsMakeTheRunAChatThatSaysWhy() {
        let stranger = BrowseTrust.issue(issue(author: "lsmith"), viewer: "you", canWrite: false, trustedAuthors: [])
        let mode = BrowseTrust.chatOnly(stranger)
        guard case let .chatOnly(reason) = mode else {
            Issue.record("expected chat only")
            return
        }
        #expect(reason.contains("@lsmith"))
        let fix = run(.fix, mode: mode)
        #expect(fix.verb == .fix)
        #expect(fix.effectiveVerb == .chat, "a Fix on an untrusted author's work is held to Chat")
        #expect(run(.review, mode: mode).effectiveVerb == .chat)
        #expect(run(.implement, mode: .full).effectiveVerb == .implement)
        #expect(BrowseTrust.chatOnly(BrowseTrust.Verdict(trusted: true, text: "", canPush: true)) == .full)
    }

    @Test func theSettingsAreRead() throws {
        #expect(BrowseSettings().maxRuns == 3)
        #expect(BrowseSettings().agent == nil)
        let (config, problems) = ConfigLoader.decode("[browse]\nmax_runs = 5\nagent = \"codex\"\n")
        #expect(problems.isEmpty)
        #expect(config?.browse.maxRuns == 5)
        #expect(config?.browse.agent == "codex")
        let (_, bad) = ConfigLoader.decode("[browse]\nmax_runs = -1\n")
        #expect(bad.contains { $0.path == "browse.max_runs" })
        let (zero, none) = ConfigLoader.decode("[browse]\nmax_runs = 0\nagent = \"\"\n")
        #expect(none.isEmpty)
        #expect(zero?.browse.maxRuns == 0)
        #expect(zero?.browse.agent == nil)
    }
}
