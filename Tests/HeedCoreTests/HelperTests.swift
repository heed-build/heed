import Foundation
@testable import HeedCore
import Testing

/// Helpers: what a helper run makes of the agent's updates, how its last message is read back, which adapter it
/// runs, and heed's next step for each kind of Attention item.
struct HelperRunTests {
    private let ref = PullRef(repo: Repo(org: "acme", name: "docs-toolkit"), number: 2841)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func helper() -> HelperRun {
        HelperRun(
            id: "h1", kind: .green, ref: ref, title: "Fix broken anchors", agent: "claude", adapter: "claude via ACP",
            sessionID: "s1", prBranch: "fix-anchors", branch: "heed/get-it-green/fix-anchors", worktree: "/wt/h",
            startedAt: t0, cap: 0.5
        )
    }

    @Test func messageChunksJoinAndToolCallsChangeInPlace() {
        var run = helper()
        run.apply(.agentMessage("Changed the lookup "), at: t0)
        run.apply(.agentMessage("to ignore case."), at: t0)
        run.apply(.agentThought("hmm"), at: t0)
        #expect(run.feed.count == 1)
        #expect(run.feed[0].body == .message("Changed the lookup to ignore case."))

        run.apply(.toolCall(ACPToolCall(
            id: "t1", title: "Edit Redirects.cs", kind: .edit, status: .inProgress,
            content: [.diff(
                path: "src/Redirects.cs", oldText: "var hit = anchors.Contains(target);",
                newText: "var hit = anchors.Contains(target,\n    StringComparer.OrdinalIgnoreCase);"
            )]
        )), at: t0)
        run.apply(.agentMessage("Next."), at: t0)
        #expect(run.feed.count == 3, "a message after a tool call starts a new line")
        #expect(run.files == [HelperFile(path: "src/Redirects.cs", added: 2, removed: 1)])

        run.apply(.toolCallUpdate(ACPToolCall(id: "t1", status: .completed)), at: t0)
        guard case let .tool(tool) = run.feed[1].body else {
            Issue.record("not a tool")
            return
        }
        #expect(tool.status == .completed && tool.title == "Edit Redirects.cs" && tool.diffs.count == 1)

        // An update for a call never announced becomes the call.
        run.apply(.toolCallUpdate(ACPToolCall(id: "t9", status: .completed)), at: t0)
        #expect(run.recentTools(5).map(\.id) == ["t1", "t9"])
        #expect(run.recentTools(5).last?.title == "a tool call")

        // A second edit of the same file adds to its count; content on an update replaces the call's.
        run.apply(.toolCall(ACPToolCall(
            id: "t2", title: "Write test", kind: .edit,
            content: [.diff(path: "tests/RedirectChainTests.cs", oldText: nil, newText: "a\nb\nc")]
        )), at: t0)
        run.apply(.toolCallUpdate(ACPToolCall(
            id: "t2", content: [.diff(path: "tests/RedirectChainTests.cs", oldText: nil, newText: "a\nb")]
        )), at: t0)
        #expect(run.files.map(\.path) == ["src/Redirects.cs", "tests/RedirectChainTests.cs"])
        #expect(run.addedLines == 4 && run.removedLines == 1)
    }

    @Test func thePlanTheUsageAndWhatItIsDoingNow() {
        var run = helper()
        #expect(run.planProgress == nil && run.now == nil)
        run.apply(.plan([
            ACPPlanEntry(content: "Read the failing lint log", status: .completed),
            ACPPlanEntry(content: "Case-insensitive lookup", status: .completed),
            ACPPlanEntry(content: "Test for the 301 chain", status: .inProgress),
            ACPPlanEntry(content: "Lint and tests", status: .pending),
            ACPPlanEntry(content: "Push and reply", status: .pending),
        ]), at: t0)
        #expect(run.planProgress! == (3, 5))
        #expect(run.now == "Test for the 301 chain")
        run.apply(.usage(used: 12400, size: 200_000, cost: nil, currency: nil), at: t0)
        #expect(run.usage == HelperUsage(tokens: 12400, window: 200_000, cost: nil))
        #expect(!run.overCap, "no cost reported: the cap cannot be judged")
        run.apply(.usage(used: 13000, size: 200_000, cost: 0.51, currency: "USD"), at: t0)
        #expect(run.overCap)
        run.apply(.usage(used: 14000, size: 200_000, cost: nil, currency: nil), at: t0)
        #expect(run.usage.cost == 0.51, "a later update without a cost keeps the last one")
        run.plan = [ACPPlanEntry(content: "a", status: .completed), ACPPlanEntry(content: "b", status: .pending)]
        #expect(run.planProgress! == (2, 2))
        run.plan = []
        run.apply(.agentMessage("line one\nline two"), at: t0)
        #expect(run.now == "line two")
    }

    @Test func aPermissionIsAskedAndItsAnswerKept() {
        var run = helper()
        run.phase = .working
        run.ask(ACPPermissionRequest(
            toolCall: ACPToolCall(id: "t3", title: "Run tests", kind: .execute, command: "dotnet test tests/Redirects"),
            options: [
                .init(id: "a", name: "Allow", kind: .allowOnce), .init(id: "n", name: "Deny", kind: .rejectOnce),
            ]
        ), id: 7, at: t0)
        #expect(run.phase == .asking)
        #expect(run.permission?.command == "dotnet test tests/Redirects")
        #expect(run.permission?.option(.allowOnce)?.id == "a" && run.permission?.option(.allowAlways) == nil)
        #expect(run.now == "wants to run dotnet test tests/Redirects")
        run.answered("allowed")
        #expect(run.phase == .working && run.permission == nil && run.approvals == 1)
        #expect(run.feed.last?.body == .permission(title: "dotnet test tests/Redirects", answer: "allowed"))
    }

    @Test func phasesSayWhetherTheyAreLiveOrWaitForYou() {
        #expect(HelperRun.Phase.working.isLive && HelperRun.Phase.paused.isLive && HelperRun.Phase.asking.isLive)
        #expect(!HelperRun.Phase.done(.endTurn).isLive && HelperRun.Phase.done(.endTurn).awaitsCloseOut)
        #expect(HelperRun.Phase.stopped("cap").awaitsCloseOut && !HelperRun.Phase.failed("x").awaitsCloseOut)
        #expect(HelperRun.Phase.done(.endTurn).text == "done" && HelperRun.Phase.done(.refusal).text == "refused")
        #expect(HelperKind.green.title(2841) == "Getting #2841 green")
        #expect(HelperKind.review.slug == "review" && HelperKind.conflict.goal == .merged)
    }

    @Test func lineDiffsKeepWhatIsCommon() {
        let lines = LineDiff.lines(old: "a\nb\nc", new: "a\nB\nc\nd")
        #expect(lines.map(\.kind) == [.context, .deleted, .added, .context, .added])
        #expect(lines.map(\.text) == ["a", "b", "B", "c", "d"])
        #expect(LineDiff.lines(old: "", new: "x").map(\.kind) == [.added])
        #expect(LineDiff.lines(old: "x", new: "").map(\.kind) == [.deleted])
        let big = (0 ..< 401).map(String.init).joined(separator: "\n")
        #expect(LineDiff.lines(old: big, new: "y").count == 402)
    }
}

struct HelperPromptTests {
    @Test func theLastMessageIsReadBackIntoACloseOut() {
        let message = """
        All five redirects resolve now.
        heed-did: lint passes: anchors compare case-insensitively
        - heed-did: a test covers the 301 chain, 3 cases
        heed-did:
        heed-reply 2: Lower-cased both sides with an ordinal ignore-case compare.
        heed-reply #3: Added RedirectChainTests with a 3-hop chain.
        heed-reply 1: this one is a check, not a thread
        heed-reply x: no number
        """
        let threads = [2: (id: "PRRT_a", location: "Redirects.cs:88"), 3: (id: "PRRT_b", location: "the 301 chain")]
        let out = HelperPrompt.closeOut(message, threads: threads)
        #expect(out.did == ["lint passes: anchors compare case-insensitively", "a test covers the 301 chain, 3 cases"])
        #expect(out.replies == [
            HelperReply(
                threadID: "PRRT_a",
                place: "Redirects.cs:88",
                text: "Lower-cased both sides with an ordinal ignore-case compare."
            ),
            HelperReply(
                threadID: "PRRT_b",
                place: "the 301 chain",
                text: "Added RedirectChainTests with a 3-hop chain."
            ),
        ])
        #expect(out.summary == "All five redirects resolve now.", "heed lines never reach the summary, read or not")
    }

    @Test func aReviewsCommentsAndVerdictAreRead() {
        let out = HelperPrompt.closeOut("""
        Looks mostly right.
        heed-did: ran cargo test (12 pass)
        heed-comment src/Arrow.rs:41: The arrowhead scales with zoom twice here.
        heed-comment src/Zoom.rs: no line
        heed-verdict: Request changes
        """)
        #expect(out.replies == [HelperReply(
            threadID: nil, place: "src/Arrow.rs:41", text: "The arrowhead scales with zoom twice here."
        )])
        #expect(out.verdict == "request changes")
        #expect(HelperPrompt.reviewBody(out) == """
        - ran cargo test (12 pass)

        **src/Arrow.rs:41**: The arrowhead scales with zoom twice here.
        """)
        #expect(HelperPrompt.reviewBody(HelperCloseOut(summary: "Fine.")) == "Fine.")
    }

    @Test func promptsSayWhereItIsAndThatItNeverPushes() {
        let green = HelperPrompt.green(feedback: "1) lint failed", branch: "heed/get-it-green/f", prBranch: "f")
        #expect(green.contains("heed/get-it-green/f") && green.contains("Do not push"))
        #expect(green.contains("1) lint failed") && green
            .hasSuffix("heed-reply <item number>: <your reply to that review comment, one or two sentences>"))
        let ref = PullRef(repo: Repo(org: "acme", name: "markgraph"), number: 418)
        let review = HelperPrompt.review(
            ref: ref, title: "Arrowheads", body: "Fixes #400", base: "main", branch: "heed/review/a", prBranch: "a"
        )
        #expect(review.contains("git diff origin/main...HEAD") && review.contains("Fixes #400"))
        #expect(review.contains("heed-verdict:") && review.contains("Change no files"))
        let items = [
            FeedbackItem(id: "check:lint", kind: .check(name: "lint"), text: "x"),
            FeedbackItem(id: "PRRT_a", kind: .review(location: "Redirects.cs:88", author: "r"), text: "y"),
        ]
        let threads = HelperPrompt.threads(items)
        #expect(threads.count == 1 && threads[2]?.id == "PRRT_a" && threads[2]?.location == "Redirects.cs:88")
    }

    @Test func theSessionIsToldInWords() {
        var run = HelperRun(
            kind: .green, ref: PullRef(repo: Repo(org: "o", name: "r"), number: 7), title: "t", agent: "claude",
            adapter: "claude via ACP", sessionID: "s", prBranch: "fix-a", branch: "heed/get-it-green/fix-a",
            worktree: "/wt/x", startedAt: Date(), cap: 0
        )
        #expect(HelperPrompt.pushedNote(run, sha: "a3f9c1d2", did: ["lint fix", "a 301-chain test", "more"])
            == "heed pushed a3f9c1d to fix-a: lint fix + a 301-chain test. Pull before your next change.")
        #expect(HelperPrompt.workingNote(run).hasPrefix("A helper is getting #7 green in its own worktree."))
        run.worktree = "/wt/y"
        #expect(HelperPrompt.takeOverNote(run).contains("git merge heed/get-it-green/fix-a"))
        #expect(HelperPrompt.takeOverNote(run).contains("/wt/y"))
    }
}

struct ACPAgentsTests {
    @Test func theAdapterIsTheConfiguredAgentsElseTheDefaultsElseClaudes() {
        #expect(ACPAgents.chosen(HelperSettings(), defaultAgent: "codex")?.executable == "codex-acp")
        #expect(ACPAgents.chosen(HelperSettings(), defaultAgent: "cursor")?.executable == "claude-agent-acp")
        #expect(ACPAgents.chosen(HelperSettings(agent: "opencode"), defaultAgent: "claude")?
            .commandLine == "opencode acp")
        let custom = ACPAgents.chosen(
            HelperSettings(command: "npx -y '@agentclientprotocol/claude-agent-acp'"), defaultAgent: "claude"
        )
        #expect(custom?.executable == "npx" && custom?.arguments == ["-y", "@agentclientprotocol/claude-agent-acp"])
        #expect(custom?.title == "claude via ACP")
        #expect(ACPAgents.chosen(HelperSettings(agent: "pi"), defaultAgent: "claude") == nil)
    }

    @Test func availabilitySaysWhatToInstall() {
        let found = ACPAgents.availability(HelperSettings(), defaultAgent: "claude") { name in
            name == "opencode" ? "/opt/homebrew/bin/opencode" : nil
        }
        #expect(!found.isReady)
        #expect(found.text.contains("npm install -g @agentclientprotocol/claude-agent-acp"))
        let ready = ACPAgents.availability(HelperSettings(agent: "opencode"), defaultAgent: "claude") { name in
            name == "opencode" ? "/opt/homebrew/bin/opencode" : nil
        }
        #expect(ready == .ready(ACPAgents.adapter(for: "opencode")!, path: "/opt/homebrew/bin/opencode"))
        #expect(ready.text == "helpers run opencode via ACP")
        let unknown = ACPAgents.availability(HelperSettings(agent: "pi"), defaultAgent: "claude") { _ in "/x" }
        #expect(unknown == .unknown(agent: "pi"))
    }

    @Test func commandLinesSplitIntoWords() {
        #expect(ACPAgents.words(#"  a "b c" 'd e'  f"#) == ["a", "b c", "d e", "f"])
        #expect(ACPAgents.words(#"x """#) == ["x", ""])
        #expect(ACPAgents.words("") == [])
    }

    @Test func helperSettingsParseAndAreRefusedWhenWrong() throws {
        let (config, problems) = ConfigLoader.decode("""
        [helpers]
        agent = "codex"
        command = " codex-acp --verbose "
        spend_cap = 2
        """)
        #expect(problems.isEmpty)
        #expect(config?.helpers == HelperSettings(agent: "codex", command: "codex-acp --verbose", spendCap: 2))
        let (_, bad) = ConfigLoader.decode("[helpers]\nspend_cap = -1\n")
        #expect(bad.map(\.path) == ["helpers.spend_cap"])
        let (shipped, none) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(none.isEmpty && shipped?.helpers == HelperSettings())
    }
}

struct NextStepTests {
    private let repo = Repo(org: "acme", name: "docs-toolkit")

    private func item(
        _ kind: AttentionItem.Kind, _ reasons: Set<AttentionReason>, author: String? = nil, last: String? = nil
    ) -> AttentionItem {
        AttentionItem(
            id: "x", kind: kind, repo: repo, number: 1, title: "t", url: nil, reasons: reasons, updatedAt: Date(),
            author: author, lastCommenter: last
        )
    }

    @Test func eachKindOfItemHasItsOneStep() {
        let me = NextStep.Facts(viewer: "you")
        #expect(NextStep.of(item(.pr, [.reviewRequested], author: "ann"), facts: me) == .review)
        #expect(NextStep.of(item(.issue, [.mentioned], author: "ann", last: "ann"), facts: me) == .draftReply)
        #expect(NextStep.of(item(.issue, [.mentioned], author: "you", last: "you"), facts: me)
            == .nothing("waiting on others"))
        #expect(NextStep.of(item(.issue, [.mentioned], author: "ann", last: "you"), facts: me)
            == .nothing("you replied last"))
        #expect(NextStep.of(item(.issue, [.assigned], author: "ann"), facts: me) == .startWork)
        #expect(NextStep.of(item(.ci, [.ciFailed]), facts: me) == nil)
        #expect(NextStep.of(item(.pr, [.subscribed], author: "ann"), facts: me) == nil)

        var mine = me
        mine.autopilotSetUp = false
        #expect(NextStep.of(item(.pr, [.yourPR, .ciFailed]), facts: mine) == .setUpAutopilot(repo))

        var failing = me
        failing.failingChecks = ["lint"]
        failing.reviewComments = 2
        failing.approvalsNeeded = 1
        failing.mergeOn = true
        let green = NextStep.of(item(.pr, [.yourPR, .ciFailed]), facts: failing)
        #expect(green == .getGreen(
            steps: ["fix lint", "address 2 comments", "wait for approval", "merge with heed's rules"], merge: true
        ))
        #expect(green?.title == "get it green and merge it" && green?.capability == .green && green?.button == "Do it")

        var conflict = me
        conflict.conflictBase = "main"
        #expect(NextStep.of(item(.pr, [.yourPR]), facts: conflict) == .resolveConflict(base: "main"))

        var ready = me
        ready.status = .green
        #expect(NextStep.of(item(.pr, [.yourPR]), facts: ready) == .merge)
        #expect(NextStep.merge.capability == .merge)
        #expect(NextStep.of(item(.pr, [.author]), facts: me) == .nothing("waiting on reviewers"))

        var helping = failing
        helping.helper = .green
        #expect(NextStep.of(item(.pr, [.yourPR]), facts: helping) == .helping(.green))
        #expect(NextStep.helping(.green).rowLine == "heed is getting it green")
        #expect(NextStep.review.rowLine == "next: start a review")
        #expect(NextStep.nothing("waiting on others").rowLine == "waiting on others · nothing to do")
        #expect(!NextStep.nothing("x").actionable && NextStep.review.capability == nil)
    }

    @Test func otherStepsLeaveTheProposedOneOut() {
        let issue = item(.issue, [.mentioned])
        #expect(NextStep.others(issue, proposed: .draftReply) == [.startWork])
        #expect(NextStep.others(item(.pr, [.reviewRequested]), proposed: .review) == [.draftReply])
    }
}
