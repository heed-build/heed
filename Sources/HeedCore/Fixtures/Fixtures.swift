import Foundation

/// Domains to start the UI in without any IO: one per design board. `HEED_FIXTURE=<name>` opens the app on one with
/// every adapter switched off.
public enum Fixtures {
    /// `resume` is `main` opening on the resume dialog (the app handles that name).
    public static let names = ["main", "empty", "resume", "pr-storm", "fresh-repos"]

    /// What the fixtures' config would say about issues: docs-builder and the nullean org show all of them.
    public static let issueRules = IssueRules(orgs: ["nullean": .all], repos: ["elastic/docs-builder": .all])

    public static func named(_ name: String) -> Domain? {
        switch name {
        case "main": main
        case "empty": .empty
        case "pr-storm": prStorm
        case "fresh-repos": freshRepos
        default: nil
        }
    }

    static let docsBuilder = Repo(org: "elastic", name: "docs-builder")
    static let docsContent = Repo(org: "elastic", name: "docs-content")
    static let mermaider = Repo(org: "nullean", name: "mermaider")
    static let editorconfig = Repo(org: "editorconfig", name: "editorconfig")
    static let ingest = Repo(org: "mpdreamz", name: "ingest")

    /// design/screens/Main.png.
    public static let main: Domain = {
        let root = "/Users/you/code"
        let repos = [docsBuilder, docsContent, mermaider, editorconfig, ingest].map {
            RepoRecord(repo: $0, path: "\(root)/\($0.name)", defaultBranch: "main")
        }
        let sessions = [
            Session(
                id: "s1", title: "Fix broken anchors in redirects",
                prompt: "Fix broken anchors in redirects.yml. Every redirect target must resolve to a real heading.",
                repos: [docsBuilder, docsContent], branch: "fix-anchors-redirects", agent: "claude",
                agentSessionID: "7f3a9c1e-52b4-4e0d-9a61-0c8d3e1f2b77",
                state: ObservedState(.working), activity: "running tests · 14m", trackedPRs: [
                    PullRef(repo: docsBuilder, number: 2841),
                    PullRef(repo: docsContent, number: 1920),
                ], pinned: true
            ),
            Session(
                id: "s2", title: "Cross-link validator for assemblies", repos: [docsBuilder],
                branch: "cross-link-validator", agent: "claude", agentSessionID: "2c81d6aa-9e17-4b3f-8d05-6a4e7b9c0d12",
                state: ObservedState(.blocked, reason: "Bash(dotnet publish)"),
                activity: "wants to run dotnet publish", trackedPRs: [PullRef(repo: docsBuilder, number: 2838)],
                pinned: true
            ),
            Session(
                id: "s3", title: "Backpressure in ingest stage", repos: [ingest], branch: "ingest-backpressure",
                agent: "codex", agentSessionID: "91be40d2-7a35-4c68-b2f9-13e5a8d07c46", state: ObservedState(
                    .asking,
                    source: .guessed
                ), activity: "3 questions waiting", trackedPRs: [PullRef(repo: ingest, number: 31)]
            ),
            Session(
                id: "s4", title: "Sequence diagram arrowheads", repos: [mermaider], branch: "sequence-arrowheads",
                agent: "claude", agentSessionID: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04", state: ObservedState(.working),
                activity: "editing · 3m", trackedPRs: [PullRef(repo: mermaider, number: 418)]
            ),
            Session(
                id: "s5", title: "Bump spec tests to 0.17", repos: [editorconfig], branch: "bump-spec-tests",
                agent: "claude", state: ObservedState(.done), activity: "done · PR approved", trackedPRs: [PullRef(
                    repo: editorconfig,
                    number: 412
                )]
            ),
            Session(
                id: "s6", title: "Docs nav spike", repos: [docsBuilder], branch: "docs-nav-spike", agent: "opencode",
                agentSessionID: "b36c9d71-04fa-42e8-8a3d-7e1c5b2f9d60",
                state: ObservedState(.idle), activity: "idle 2h", trackedPRs: [PullRef(repo: docsBuilder, number: 2852)]
            ),
        ]
        var worktrees: [Worktree] = []
        var layouts: [String: SessionLayout] = [:]
        for session in sessions {
            for repo in session.repos {
                worktrees.append(Worktree(
                    repo: repo, path: "\(root)/wt/\(repo.name)/\(session.branch)", branch: session.branch,
                    head: "0000000", isMain: false, status: WorktreeStatus(upstream: "origin/\(session.branch)")
                ))
            }
            layouts[session.id] = SessionLayout(tabs: tabs(for: session, root: root))
        }
        // Worktrees made outside Heed, with no session yet: what `I` in Sessions imports.
        worktrees += [
            Worktree(
                repo: docsBuilder, path: "\(root)/wt/docs-builder/toc-ordering", branch: "toc-ordering",
                head: "0000000", isMain: false, status: WorktreeStatus(upstream: "origin/toc-ordering")
            ),
            Worktree(
                repo: mermaider, path: "\(root)/wt/mermaider/gantt-labels", branch: "gantt-labels", head: "0000000",
                isMain: false, status: WorktreeStatus(upstream: nil)
            ),
            Worktree(repo: ingest, path: "\(root)/ingest", branch: "main", head: "0000000", isMain: true),
        ]
        let detail = pullDetail
        var pipeline = PullFeedback(ref: detail.ref)
        pipeline.merge(detail)
        if let index = pipeline.items.firstIndex(where: { $0.id == "T1" }) { pipeline.items[index].status = .queued }
        if let index = pipeline.items
            .firstIndex(where: { $0.id == "check:lint" }) { pipeline.items[index].status = .queued }
        var resolved = FeedbackItem(
            id: "T0",
            kind: .review(location: "RedirectFile.cs:41", author: "reviewer"),
            text: "Use the shared slug helper.",
            status: .resolved
        )
        resolved.resolvedAt = Clock.now
        pipeline.items.append(resolved)
        var (pilots, log) = pilotStates
        // editorconfig#412 conflicts, and Copilot was asked to resolve it.
        if let conflicting = otherDetails.first(where: { $0.mergeable == "CONFLICTING" }) {
            var copilot = PullFeedback(ref: conflicting.ref)
            copilot.merge(conflicting)
            CopilotAsk.asked(&copilot, items: ["conflict"], at: Clock.now.addingTimeInterval(-12 * 60))
            copilot.reviewersRequested = ["@copilot"]
            pilots[conflicting.ref.description] = copilot
            log.insert(PilotEvent(
                at: Clock.now.addingTimeInterval(-12 * 60), ref: conflicting.ref, kind: .copilot,
                text: "asked Copilot to merge in main and resolve the conflicts"
            ), at: 0)
            log.append(PilotEvent(
                at: Clock.now.addingTimeInterval(-3 * 3600), ref: conflicting.ref, kind: .review,
                text: "asked @copilot to review"
            ))
            log.sort { $0.at > $1.at }
        }
        // heed merges #2841 (held: lint failed), docs-content#1920 has auto-merge on.
        pipeline.merge = .heed
        pipeline.mergeSet = true
        return Domain(
            repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts, history: history, github: github,
            pullDetails: Dictionary(([detail] + otherDetails).map { ($0.ref.description, $0) }) { first, _ in first },
            feedback: pilots.merging([detail.ref.description: pipeline]) { _, main in main }, pilotLog: log,
            mergeRuns: mergeRuns
        )
    }()

    /// The pilot's other states: #2852 paused, ingest#31 not watched (set by hand), mermaider#418 stuck after three
    /// rounds, and a morning of activity.
    static let pilotStates: ([String: PullFeedback], [PilotEvent]) = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let nav = PullRef(repo: docsBuilder, number: 2852)
        let ingestPR = PullRef(repo: ingest, number: 31)
        let arrows = PullRef(repo: mermaider, number: 418)
        let anchors = PullRef(repo: docsBuilder, number: 2841)
        let redirects = PullRef(repo: docsContent, number: 1920)
        var paused = PullFeedback(ref: nav)
        paused.pausedUntil = now.addingTimeInterval(42 * 60)
        var unwatched = PullFeedback(ref: ingestPR, watching: false)
        unwatched.watchSet = true
        var merging = PullFeedback(ref: redirects)
        merging.merge = .auto
        merging.mergeSet = true
        var stuck = PullFeedback(ref: arrows, items: [FeedbackItem(
            id: "A1", kind: .review(location: "Arrow.cs:57", author: "reviewer"),
            text: "Arrowheads still detach below 50% zoom.", status: .new
        )])
        stuck.rounds = 3
        let log = [
            PilotEvent(at: ago(6), ref: anchors, kind: .waiting, text: "2 queued, held: the agent is working"),
            PilotEvent(at: ago(9), ref: anchors, kind: .items, text: "2 review threads and check lint arrived"),
            PilotEvent(at: ago(18), ref: nav, kind: .pause, text: "paused for 1h (by you)"),
            PilotEvent(
                at: ago(24),
                ref: arrows,
                kind: .stuck,
                text: "3 rounds without a new approval: stopped sending"
            ),
            PilotEvent(at: ago(31), ref: arrows, kind: .sent, text: "sent 1 item to claude (round 3)"),
            PilotEvent(
                at: ago(40), ref: redirects, kind: .autoMerge,
                text: "auto-merge on: squash; GitHub merges once its requirements are met"
            ),
            PilotEvent(at: ago(44), ref: redirects, kind: .resolved, text: "check link-check resolved"),
            PilotEvent(at: ago(52), ref: redirects, kind: .addressed, text: "the agent pushed: 1 item addressed"),
            PilotEvent(at: ago(70), ref: redirects, kind: .sent, text: "sent 1 item to claude (round 1)"),
            PilotEvent(at: ago(95), ref: ingestPR, kind: .watch, text: "stopped watching (by you)"),
            PilotEvent(at: ago(100), ref: redirects, kind: .merge, text: "merge: auto (by you)"),
        ]
        return (
            [
                nav.description: paused, ingestPR.description: unwatched, arrows.description: stuck,
                redirects.description: merging,
            ],
            log
        )
    }()

    /// The merge queues' runs: docs-content turned green and got auto-merge, docs-builder holds #2841 on lint.
    static let mergeRuns: [String: [MergeRun]] = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let anchors = PullRef(repo: docsBuilder, number: 2841)
        let redirects = PullRef(repo: docsContent, number: 1920)
        return [
            docsBuilder.slug: [
                MergeRun(repo: docsBuilder.slug, at: ago(20), why: "schedule", lines: [
                    .init(ref: anchors, action: "held", detail: "Green: checks pass: lint failed"),
                ]),
                MergeRun(repo: docsBuilder.slug, at: ago(80), why: "merge turned on", lines: [
                    .init(ref: anchors, action: "brought up to date", detail: "merged main in"),
                ]),
            ],
            docsContent.slug: [
                MergeRun(repo: docsContent.slug, at: ago(40), why: "#1920 turned green", lines: [
                    .init(
                        ref: redirects, action: "auto-merge on",
                        detail: "squash; GitHub merges once its requirements are met"
                    ),
                ]),
                MergeRun(repo: docsContent.slug, at: ago(100), why: "merge turned on", lines: [
                    .init(ref: redirects, action: "held", detail: "Checks pass: link-check failed"),
                ]),
            ],
        ]
    }()

    /// The tutor's PR storm: every review comment and failing check on #2841 is new, and it is the PR updated last,
    /// while the session that owns it is busy working.
    public static let prStorm: Domain = {
        var domain = main
        for key in domain.feedback.keys {
            for index in domain.feedback[key]!.items.indices
                where domain.feedback[key]!.items[index].status != .resolved
            {
                domain.feedback[key]!.items[index].status = .new
            }
        }
        if let index = domain.github.pulls.firstIndex(where: { $0.ref == pullDetail.ref }) {
            var pull = domain.github.pulls.remove(at: index)
            pull.updatedAt = Clock.now
            domain.github.pulls.insert(pull, at: 0)
        }
        return domain
    }()

    /// The tutor's fresh repos: every repo and worktree, no sessions or history yet.
    public static let freshRepos: Domain = {
        var domain = main
        domain.sessions = []
        domain.layouts = [:]
        domain.history = []
        domain.feedback = [:]
        return domain
    }()

    /// design/screens/Diff.png.
    public static let diffCommits = [
        CommitSummary(sha: "4f2a1c0", subject: "Validate anchors against headings"),
        CommitSummary(sha: "a91e3d0", subject: "Fix lint in redirects.md"),
        CommitSummary(sha: "0be7d20", subject: "Add moved-page redirect fixtures"),
    ]

    public static let diff: [FileDiff] = {
        let text = """
        diff --git a/src/Elastic.Markdown/Redirects/RedirectFile.cs b/src/Elastic.Markdown/Redirects/RedirectFile.cs
        --- a/src/Elastic.Markdown/Redirects/RedirectFile.cs
        +++ b/src/Elastic.Markdown/Redirects/RedirectFile.cs
        @@ -76,9 +76,11 @@ public sealed class RedirectFile
             public bool TryResolve(string page, string fragment)
             {
        -        var anchors = _anchors.GetValueOrDefault(page);
        +        var anchors = _anchors.GetValueOrDefault(page, EmptyAnchors);
        +        var slug = Slugify(fragment);
                 // headings are lowercased by the slugifier
        -        if (!anchors.Contains(fragment))
        +        if (!anchors.Contains(slug, StringComparer.Ordinal))
                     return false;
        +        _resolved[page] = new Resolved(page, slug);
                 return true;
             }
        @@ -131,6 +133,8 @@ public sealed class RedirectFile
             private static IReadOnlySet<string> EmptyAnchors
        +        = new HashSet<string>(StringComparer.Ordinal);
         }
        diff --git a/tests/Redirects/AnchorTests.cs b/tests/Redirects/AnchorTests.cs
        new file mode 100644
        --- /dev/null
        +++ b/tests/Redirects/AnchorTests.cs
        @@ -0,0 +1,3 @@
        +public class AnchorTests
        +{
        +}
        diff --git a/docs/redirects.md b/docs/redirects.md
        --- a/docs/redirects.md
        +++ b/docs/redirects.md
        @@ -40,2 +40,3 @@
         Redirects keep anchors.
        -A very long line that the linter rejects because it goes on and on.
        +A shorter line.
        +Another line.

        """
        return DiffParser.parse(text, repo: docsBuilder, staged: ["src/Elastic.Markdown/Redirects/RedirectFile.cs"])
    }()

    /// design/screens/Reader.png.
    static let pullDetail: PullDetail = {
        var detail = PullDetail(
            ref: PullRef(repo: docsBuilder, number: 2841), title: "Fix broken anchors in redirects",
            body: "Validates redirect targets against real headings, so moved pages no longer lose their anchors.\nCloses #2830. Companion change in docs-content #1920.",
            author: "you", baseBranch: "main", headBranch: "fix-anchors-redirects", additions: 82, deletions: 4,
            commitCount: 3, headSHA: "a91e3d0",
            reviews: [PullDetail.Review(author: "reviewer", state: "CHANGES_REQUESTED")],
            threads: [
                ReviewThread(
                    id: "T1", isResolved: false, path: "src/Redirects/RedirectFile.cs", line: 88, author: "reviewer",
                    body: "Anchor lookup is case sensitive. Heading slugs are lowercased, so this misses valid targets.",
                    diff: [
                        "     var slug = Slugify(heading);",
                        "-    var exists = anchors.Contains(target);",
                        "+    var exists = anchors.Contains(target, StringComparer.Ordinal);",
                    ],
                    replies: 0, url: nil
                ),
                ReviewThread(
                    id: "T2", isResolved: false, path: "tests/Redirects/AnchorTests.cs", line: 12, author: "reviewer",
                    body: "Please cover the moved-page case.", diff: [], replies: 0, url: nil
                ),
            ],
            failingChecks: [PullDetail.FailingCheck(
                name: "lint",
                summary: "docs/redirects.md:41 line too long",
                url: nil
            )],
            checks: CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]),
            closes: [PullRef(repo: docsBuilder, number: 2830)], fetchedAt: Clock.now
        )
        detail.state = "OPEN"
        detail.isDraft = false
        detail.mergeable = "MERGEABLE"
        detail.mergeState = "BLOCKED"
        detail.reviewDecision = "CHANGES_REQUESTED"
        detail.requiredChecks = ["build", "lint"]
        detail.repoAllowsAutoMerge = true
        detail.repoMergeMethods = ["squash"]
        detail.autoMergeEnabled = false
        return detail
    }()

    /// The other PRs' details, one per green verdict: docs-content#1920 green, editorconfig#412 conflicting.
    static let otherDetails: [PullDetail] = {
        func detail(
            _ repo: Repo, _ number: Int, _ title: String, _ branch: String, mergeable: String, state: String,
            checks: CheckSummary, review: String?
        ) -> PullDetail {
            var detail = PullDetail(
                ref: PullRef(repo: repo, number: number), title: title, body: "", author: "you", baseBranch: "main",
                headBranch: branch, additions: 20, deletions: 3, commitCount: 1, headSHA: "b\(number)",
                reviews: review.map { [PullDetail.Review(author: "reviewer", state: $0)] } ?? [], threads: [],
                failingChecks: [], checks: checks, closes: [], fetchedAt: Clock.now
            )
            detail.state = "OPEN"
            detail.isDraft = false
            detail.mergeable = mergeable
            detail.mergeState = state
            detail.reviewDecision = review
            detail.requiredChecks = ["build"]
            detail.repoAllowsAutoMerge = true
            detail.repoMergeMethods = ["squash", "merge"]
            // The green one is waiting on GitHub's auto-merge (the fixture never merges).
            detail.autoMergeEnabled = state == "CLEAN"
            detail.autoMergeMethod = state == "CLEAN" ? "squash" : nil
            return detail
        }
        return [
            detail(
                docsContent,
                1920,
                "Redirects for moved pages",
                "fix-anchors-redirects",
                mergeable: "MERGEABLE",
                state: "CLEAN",
                checks: CheckSummary(passed: 4),
                review: nil
            ),
            detail(
                editorconfig,
                412,
                "Bump spec tests to 0.17",
                "bump-spec-tests",
                mergeable: "CONFLICTING",
                state: "DIRTY",
                checks: CheckSummary(passed: 3),
                review: "APPROVED"
            ),
        ]
    }()

    /// design/screens/Inbox.png and PRs.png.
    static let github: GitHubState = {
        let now = Clock.now
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func pull(
            _ repo: Repo, _ number: Int, _ title: String, _ branch: String, _ checks: CheckSummary,
            _ review: ReviewDecision?, threads: Int = 0
        ) -> PullRequest {
            PullRequest(
                ref: PullRef(repo: repo, number: number), title: title, url: PullRef(repo: repo, number: number).url,
                state: .open, isDraft: false, headBranch: branch, review: review, checks: checks,
                unresolvedThreads: threads, updatedAt: ago(Double(number % 60))
            )
        }
        let inbox = [
            InboxItem(
                id: "n1",
                kind: .pr,
                repo: docsBuilder,
                number: 2845,
                title: "Add link validation to assembler",
                reason: "review_requested",
                unread: true,
                updatedAt: ago(4),
                url: nil
            ),
            InboxItem(
                id: "n2",
                kind: .ci,
                repo: docsBuilder,
                number: nil,
                title: "lint failed on #2841",
                reason: "ci_activity",
                unread: true,
                updatedAt: ago(9),
                url: nil
            ),
            InboxItem(
                id: "n3",
                kind: .pr,
                repo: docsContent,
                number: 1920,
                title: "2 new review comments",
                reason: "comment",
                unread: true,
                updatedAt: ago(12),
                url: nil
            ),
            InboxItem(
                id: "n4",
                kind: .issue,
                repo: docsBuilder,
                number: 2830,
                title: "Anchors lost when a page is moved",
                reason: "assign",
                unread: true,
                updatedAt: ago(60),
                url: nil
            ),
            InboxItem(
                id: "n5",
                kind: .issue,
                repo: docsBuilder,
                number: 2833,
                title: "Redirect loop on /reference",
                reason: "mention",
                unread: true,
                updatedAt: ago(120),
                url: nil
            ),
            InboxItem(
                id: "n6",
                kind: .pr,
                repo: mermaider,
                number: 187,
                title: "Arrowhead markers on sequence diagrams",
                reason: "review_requested",
                unread: true,
                updatedAt: ago(180),
                url: nil
            ),
            InboxItem(
                id: "n7",
                kind: .issue,
                repo: ingest,
                number: 94,
                title: "Backpressure drops events under burst",
                reason: "assign",
                unread: true,
                updatedAt: ago(300),
                url: nil
            ),
        ]
        let issues = [
            Issue(
                repo: docsBuilder,
                number: 2830,
                title: "Anchors lost when a page is moved",
                url: "",
                body: "Moving a page drops its heading anchors from redirects.",
                labels: ["bug"],
                author: "reviewer",
                updatedAt: ago(60),
                assigned: true
            ),
            Issue(
                repo: docsBuilder,
                number: 2833,
                title: "Redirect loop on /reference",
                url: "",
                body: "/reference redirects to itself after the nav change.",
                labels: ["bug", "redirects"],
                author: "reviewer",
                updatedAt: ago(120),
                mentioned: true
            ),
            Issue(
                repo: ingest,
                number: 94,
                title: "Backpressure drops events under burst",
                url: "",
                body: "Under burst load the stage drops events instead of slowing producers.",
                labels: [],
                author: nil,
                updatedAt: ago(300),
                assigned: true
            ),
            // Shown because docs-builder shows all issues, not because it involves you.
            Issue(
                repo: docsBuilder,
                number: 2851,
                title: "Support nested includes in snippets",
                url: "",
                body: "Snippets cannot include other snippets yet.",
                labels: ["enhancement"],
                author: "contributor",
                updatedAt: ago(400)
            ),
            Issue(
                repo: mermaider,
                number: 12,
                title: "Arrow heads render detached at small zoom",
                url: "",
                body: "",
                labels: ["bug"],
                author: "someone",
                updatedAt: ago(900)
            ),
        ]
        let pulls = [
            pull(
                docsBuilder,
                2841,
                "Fix broken anchors in redirects",
                "fix-anchors-redirects",
                CheckSummary(passed: 3, failed: 1, pending: 1, failedNames: ["lint"]),
                .changesRequested,
                threads: 2
            ),
            pull(docsContent, 1920, "Redirects for moved pages", "fix-anchors-redirects", CheckSummary(passed: 4), nil),
            pull(
                docsBuilder,
                2838,
                "Cross-link validator for assembler",
                "cross-link-validator",
                CheckSummary(passed: 2, pending: 3),
                nil
            ),
            pull(editorconfig, 412, "Bump spec tests to 0.17", "bump-spec-tests", CheckSummary(passed: 3), .approved),
            pull(ingest, 31, "Backpressure for the ingest stage", "ingest-backpressure", CheckSummary(passed: 2), nil),
            pull(
                mermaider, 418, "Arrowheads at small zoom", "sequence-arrowheads", CheckSummary(passed: 5), nil,
                threads: 1
            ),
            pull(docsBuilder, 2852, "Docs nav spike", "docs-nav-spike", CheckSummary(passed: 1, pending: 2), nil),
        ]
        return GitHubState(viewer: "you", inbox: inbox, issues: issues, pulls: pulls, syncedAt: ago(0.3), status: .ok)
    }()

    /// design/screens/History.png: closed sessions over the last week.
    static let history: [HistoryEntry] = {
        let now = Clock.now
        func entry(
            _ title: String, _ repo: Repo, _ agent: String, hoursAgo: Double, minutes: Double, _ outcome: Outcome,
            pr: Int? = nil
        ) -> HistoryEntry {
            let closed = now.addingTimeInterval(-hoursAgo * 3600)
            let started = closed.addingTimeInterval(-minutes * 60)
            var session = Session(
                id: "h-\(StartWork.name(for: title))", title: title,
                prompt: "\(title). Keep the change small and add a test.",
                repos: [repo], branch: StartWork.name(for: title), agent: agent,
                agentSessionID: "b36c9d71-04fa-42e8-8a3d-7e1c5b2f9d60", state: ObservedState(.done),
                trackedPRs: pr.map { [PullRef(repo: repo, number: $0)] } ?? [], lastActivity: closed, createdAt: started
            )
            session.record("started · \(agent) · 2 panes", at: started)
            if let pr { session.record("opened PR #\(pr)", at: started.addingTimeInterval(minutes * 30)) }
            session.record("ended after \(Int(minutes / 60))h \(Int(minutes) % 60)m", at: closed)
            return HistoryEntry(session: session, closedAt: closed, outcome: outcome)
        }
        return [
            entry("Fix toc ordering", docsBuilder, "claude", hoursAgo: 1, minutes: 130, .merged, pr: 2810),
            entry("Fix redirect typos", docsContent, "claude", hoursAgo: 3, minutes: 41, .merged, pr: 1912),
            entry("Bump spec tests to 0.17", editorconfig, "claude", hoursAgo: 26, minutes: 65, .merged, pr: 412),
            entry("Flowchart label wrapping", mermaider, "opencode", hoursAgo: 28, minutes: 26, .abandoned),
            entry("Docs nav spike v1", docsBuilder, "opencode", hoursAgo: 30, minutes: 220, .closed, pr: 2790),
            entry("Snippet include performance", docsBuilder, "claude", hoursAgo: 120, minutes: 175, .merged, pr: 2781),
            entry("Parser fuzzing harness", mermaider, "claude", hoursAgo: 130, minutes: 90, .cleanedUp),
        ]
    }()

    private static func tabs(for session: Session, root: String) -> [PaneTab] {
        let directory = "\(root)/wt/\(session.repos[0].name)/\(session.branch)"
        let agent = PaneSpec(
            id: "\(session.id)-agent", role: .agent, title: session.agent, directory: directory, command: session.agent
        )
        let shell = PaneSpec(
            id: "\(session.id)-shell", role: .shell, title: "zsh \(session.branch)", directory: directory
        )
        var main = PaneTab(id: "\(session.id)-t1", title: "agent", tree: .leaf(agent))
        main.split(.horizontal, with: shell)
        main.focused = agent.id
        let tests = PaneSpec(
            id: "\(session.id)-tests", role: .task, title: "tests", directory: directory, command: "dotnet watch test"
        )
        return [
            main,
            PaneTab(id: "\(session.id)-t2", title: "shell", tree: .leaf(PaneSpec(
                id: "\(session.id)-zsh", role: .shell, title: "zsh", directory: directory
            ))),
            PaneTab(id: "\(session.id)-t3", title: "tests", tree: .leaf(tests)),
        ]
    }
}
