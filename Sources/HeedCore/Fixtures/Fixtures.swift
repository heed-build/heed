import Foundation

/// Domains to start the UI in without any IO: one per design board. `HEED_FIXTURE=<name>` opens the app on one with
/// every adapter switched off.
public enum Fixtures {
    /// `resume` is `main` opening on the resume dialog (the app handles that name).
    public static let names = ["main", "empty", "resume"]

    public static func named(_ name: String) -> Domain? {
        switch name {
        case "main": main
        case "empty": .empty
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
                ), activity: "3 questions waiting"
            ),
            Session(
                id: "s4", title: "Sequence diagram arrowheads", repos: [mermaider], branch: "sequence-arrowheads",
                agent: "claude", agentSessionID: "e0457f3b-18c2-4d9a-a6b1-5f2d9c8e3a04", state: ObservedState(.working),
                activity: "editing · 3m"
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
                state: ObservedState(.idle), activity: "idle 2h"
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
        return Domain(
            repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts, history: history, github: github
        )
    }()

    /// design/screens/Inbox.png and PRs.png.
    static let github: GitHubState = {
        let now = Date()
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
                updatedAt: ago(60)
            ),
            Issue(
                repo: docsBuilder,
                number: 2833,
                title: "Redirect loop on /reference",
                url: "",
                body: "/reference redirects to itself after the nav change.",
                labels: ["bug", "redirects"],
                author: "reviewer",
                updatedAt: ago(120)
            ),
            Issue(
                repo: ingest,
                number: 94,
                title: "Backpressure drops events under burst",
                url: "",
                body: "Under burst load the stage drops events instead of slowing producers.",
                labels: [],
                author: nil,
                updatedAt: ago(300)
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
        ]
        return GitHubState(viewer: "you", inbox: inbox, issues: issues, pulls: pulls, syncedAt: ago(0.3), status: .ok)
    }()

    /// design/screens/History.png: closed sessions over the last week.
    static let history: [HistoryEntry] = {
        let now = Date()
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
