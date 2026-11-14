import Foundation

/// The fake world's helpers: one getting the anchors PR green (its plan, its story with a diff, and a permission it
/// waits on), one reviewing a PR for you, and one resolving a conflict. Plain values, for shots and the tutor: no
/// agent runs.
public extension Fixtures {
    static func helpers(now: Date) -> [HelperRun] {
        [anchorsHelper(now: now), reviewHelper(now: now), conflictHelper(now: now)]
    }

    /// Getting docs-toolkit#2841 green: three steps in, asking to run the tests.
    static func anchorsHelper(now: Date) -> HelperRun {
        let started = now.addingTimeInterval(-192)
        var run = HelperRun(
            id: "helper-2841", kind: .green, ref: PullRef(repo: docsToolkit, number: 2841),
            title: "Fix broken anchors in redirects", agent: "claude", adapter: "claude via ACP", sessionID: "s1",
            prBranch: "fix-anchors-redirects", branch: "heed/get-it-green/fix-anchors-redirects",
            worktree: Paths.home + "/code/wt/heed/docs-toolkit/get-it-green-fix-anchors-redirects", startedAt: started,
            cap: 0.5
        )
        run.phase = .working
        let at = { (seconds: Double) in started.addingTimeInterval(seconds) }
        run.apply(.plan([
            ACPPlanEntry(content: "Read the failing lint log", status: .completed),
            ACPPlanEntry(content: "Make the anchor lookup case-insensitive", status: .completed),
            ACPPlanEntry(content: "Add a test for the 301 chain", status: .inProgress),
            ACPPlanEntry(content: "Run lint and the tests", status: .pending),
            ACPPlanEntry(content: "Commit, for heed to push and reply", status: .pending),
        ]), at: at(5))
        run.apply(.toolCall(ACPToolCall(
            id: "t1", title: "Read the failing step's log: Redirects.cs(88): IDE0058", kind: .read, status: .completed,
            paths: ["src/Redirects.cs"]
        )), at: at(8))
        run.apply(.toolCall(ACPToolCall(
            id: "t2", title: "grep \"anchor\" src", kind: .search, status: .completed
        )), at: at(12))
        run.apply(.agentMessage(
            "Changed the lookup to compare lower-cased anchors, so #Install and #install match."
        ), at: at(60))
        run.apply(.toolCall(ACPToolCall(
            id: "t3", title: "Edit src/Redirects.cs", kind: .edit, status: .completed,
            content: [.diff(
                path: "src/Redirects.cs", oldText: "var hit = anchors.Contains(target);",
                newText: "var hit = anchors.Contains(target,\n    StringComparer.OrdinalIgnoreCase);"
            )], paths: ["src/Redirects.cs"]
        )), at: at(62))
        run.apply(.toolCall(ACPToolCall(
            id: "t4", title: "Write tests/RedirectChainTests.cs", kind: .edit, status: .completed,
            content: [.diff(
                path: "tests/RedirectChainTests.cs", oldText: nil,
                newText: (1 ... 24).map { "line \($0)" }.joined(separator: "\n")
            )], paths: ["tests/RedirectChainTests.cs"]
        )), at: at(120))
        run.apply(.toolCall(ACPToolCall(
            id: "t5", title: "Edit src/AnchorIndex.cs", kind: .edit, status: .completed,
            content: [.diff(
                path: "src/AnchorIndex.cs", oldText: (1 ... 6).map { "unused \($0)" }.joined(separator: "\n"),
                newText: ""
            )], paths: ["src/AnchorIndex.cs"]
        )), at: at(150))
        run.apply(.agentMessage("Writing RedirectChainTests.cs: a 3-hop chain, a loop, a missing target."), at: at(160))
        run.apply(.usage(used: 12400, size: 200_000, cost: 0.04, currency: "USD"), at: at(170))
        run.ask(ACPPermissionRequest(
            toolCall: ACPToolCall(
                id: "t6", title: "not on this repo's allowed list yet", kind: .execute,
                command: "dotnet test tests/Redirects"
            ),
            options: [
                .init(id: "allow", name: "Allow", kind: .allowOnce),
                .init(id: "always", name: "Always allow", kind: .allowAlways),
                .init(id: "reject", name: "Deny", kind: .rejectOnce),
            ]
        ), id: "p1", at: at(185))
        return run
    }

    /// The anchors helper once its turn ended: what it did and the replies heed will post.
    static func anchorsHelperDone(now: Date) -> HelperRun {
        var run = anchorsHelper(now: now)
        run.answered("allowed")
        run.apply(.plan(run.plan.map { ACPPlanEntry(content: $0.content, status: .completed) }), at: now)
        run.apply(.agentMessage("\nAll five redirects resolve now; lint and 48 tests pass."), at: now)
        run.apply(.usage(used: 31000, size: 200_000, cost: 0.09, currency: "USD"), at: now)
        run.phase = .done(.endTurn)
        run.endedAt = now.addingTimeInterval(208)
        run.files = [
            HelperFile(path: "src/Redirects.cs", added: 2, removed: 1),
            HelperFile(path: "tests/RedirectChainTests.cs", added: 24, removed: 0),
            HelperFile(path: "src/AnchorIndex.cs", added: 0, removed: 6),
        ]
        run.closeOut = HelperCloseOut(
            did: [
                "lint passes: anchors compare case-insensitively",
                "a test covers the 301 chain, 3 cases",
                "dropped an unused overload",
                "lint and 48 tests pass locally",
            ],
            replies: [
                HelperReply(
                    threadID: "PRRT_fixture_1", place: "Redirects.cs:88",
                    text: "Lower-cased both sides with an ordinal ignore-case compare; #Install and #install now "
                        + "resolve the same."
                ),
                HelperReply(
                    threadID: "PRRT_fixture_2", place: "the 301 chain comment",
                    text: "Added RedirectChainTests with a 3-hop chain, a loop and a missing target."
                ),
            ],
            summary: "All five redirects resolve now; lint and 48 tests pass.", commits: 2
        )
        return run
    }

    /// Reviewing docs-toolkit#2845 for you: reading it against its issue.
    static func reviewHelper(now: Date) -> HelperRun {
        let started = now.addingTimeInterval(-130)
        var run = HelperRun(
            id: "helper-2845", kind: .review, ref: PullRef(repo: docsToolkit, number: 2845),
            title: "Add link validation to assembler", agent: "claude", adapter: "claude via ACP", sessionID: nil,
            prBranch: "link-validation", branch: "heed/review/link-validation",
            worktree: Paths.home + "/code/wt/heed/docs-toolkit/review-link-validation", startedAt: started, cap: 0.5
        )
        run.phase = .working
        run.apply(.plan([
            ACPPlanEntry(content: "Read the change against #2830", status: .completed),
            ACPPlanEntry(content: "Reading Assembler.cs against the issue", status: .inProgress),
            ACPPlanEntry(content: "Run the tests", status: .pending),
            ACPPlanEntry(content: "Draft review comments", status: .pending),
        ]), at: started)
        run.apply(
            .toolCall(ACPToolCall(id: "r1", title: "read src/Assembler.cs", kind: .read, status: .completed)),
            at: started.addingTimeInterval(40)
        )
        run.apply(
            .toolCall(ACPToolCall(id: "r2", title: "grep 'ValidateLinks' -n", kind: .search, status: .completed)),
            at: started.addingTimeInterval(70)
        )
        run.apply(.usage(used: 8200, size: 200_000, cost: 0.02, currency: "USD"), at: started.addingTimeInterval(80))
        return run
    }

    /// More on the anchors session's PRs, for its helper line: one getting docs-website#1920 green, two steps in, and
    /// one that pushed to #2836 a few minutes ago (not seen yet).
    static func sessionLineHelpers(now: Date) -> [HelperRun] {
        let started = now.addingTimeInterval(-95)
        var website = HelperRun(
            id: "helper-1920", kind: .green, ref: PullRef(repo: docsWebsite, number: 1920),
            title: "Redirects for moved pages", agent: "claude", adapter: "claude via ACP", sessionID: "s1",
            prBranch: "moved-page-redirects", branch: "heed/get-it-green/moved-page-redirects",
            worktree: Paths.home + "/code/wt/heed/docs-website/get-it-green-moved-page-redirects", startedAt: started,
            cap: 0.5
        )
        website.phase = .working
        website.apply(.plan([
            ACPPlanEntry(content: "Read the failing link check", status: .completed),
            ACPPlanEntry(content: "Point the moved pages at their new anchors", status: .inProgress),
            ACPPlanEntry(content: "Run the link check", status: .pending),
        ]), at: started)
        var pushed = HelperRun(
            id: "helper-2836", kind: .green, ref: PullRef(repo: docsToolkit, number: 2836),
            title: "Redirect checker: first pass", agent: "claude", adapter: "claude via ACP", sessionID: "s1",
            prBranch: "redirect-checker", branch: "heed/get-it-green/redirect-checker",
            worktree: Paths.home + "/code/wt/heed/docs-toolkit/get-it-green-redirect-checker",
            startedAt: now.addingTimeInterval(-900), cap: 0.5
        )
        pushed.closeOut = HelperCloseOut(did: ["lint fix"], summary: "lint passes", commits: 1, pushedSHA: "a3f9c1d")
        pushed.phase = .closed("pushed a3f9c1d")
        pushed.endedAt = now.addingTimeInterval(-240)
        return [website, pushed]
    }

    /// The fake world's own get it green, as a helper (`run_in = "helper"`, the default): bump-spec-tests' PR,
    /// editor-rules#412, its lint fixed and its spec tests running.
    static func specHelper(now: Date) -> HelperRun {
        let started = now.addingTimeInterval(-180)
        var run = HelperRun(
            id: "helper-412-green", kind: .green, ref: PullRef(repo: editorRules, number: 412),
            title: "Bump spec tests to 0.17", agent: "claude", adapter: "claude via ACP", sessionID: "s5",
            prBranch: "bump-spec-tests", branch: "heed/get-it-green/bump-spec-tests",
            worktree: Paths.home + "/code/wt/heed/editor-rules/get-it-green-bump-spec-tests", startedAt: started,
            cap: 0.5
        )
        run.phase = .working
        run.apply(.plan([
            ACPPlanEntry(content: "Fix the lint warning in rules.yaml", status: .completed),
            ACPPlanEntry(content: "Run the spec tests", status: .inProgress),
            ACPPlanEntry(content: "Commit, for heed to push", status: .pending),
        ]), at: started)
        run.apply(.toolCall(ACPToolCall(
            id: "g1", title: "npm run spec", kind: .execute, status: .inProgress
        )), at: started.addingTimeInterval(150))
        run.apply(.usage(used: 9100, size: 200_000, cost: 0.03, currency: "USD"), at: started.addingTimeInterval(160))
        return run
    }

    /// Resolving editor-rules#412's conflict with main.
    static func conflictHelper(now: Date) -> HelperRun {
        let started = now.addingTimeInterval(-70)
        var run = HelperRun(
            id: "helper-412", kind: .conflict, ref: PullRef(repo: editorRules, number: 412),
            title: "Label padding", agent: "claude", adapter: "claude via ACP", sessionID: nil,
            prBranch: "label-padding", branch: "heed/get-it-merged/label-padding",
            worktree: Paths.home + "/code/wt/heed/editor-rules/get-it-merged-label-padding", startedAt: started,
            cap: 0.5
        )
        run.phase = .working
        run.apply(.plan([
            ACPPlanEntry(content: "Merge main into the branch", status: .inProgress),
            ACPPlanEntry(content: "Resolve rules.yaml", status: .pending),
            ACPPlanEntry(content: "Run the spec tests", status: .pending),
        ]), at: started)
        run.apply(.toolCall(ACPToolCall(
            id: "c1", title: "git merge origin/main", kind: .execute, status: .completed,
            content: [.text("CONFLICT (content): Merge conflict in rules.yaml")], paths: ["rules.yaml"]
        )), at: started.addingTimeInterval(20))
        run.files = [HelperFile(path: "rules.yaml", added: 0, removed: 0)]
        return run
    }
}
