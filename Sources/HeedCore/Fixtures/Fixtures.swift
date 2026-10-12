import Foundation

/// Domains to start the UI in without any IO: one per design board. `HEED_FIXTURE=<name>` opens the app on one with
/// every adapter switched off.
public enum Fixtures {
    public static let names = ["main", "empty"]

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
                state: ObservedState(.working), activity: "running tests · 14m", trackedPRs: [
                    PullRef(repo: docsBuilder, number: 2841),
                    PullRef(repo: docsContent, number: 1920),
                ], pinned: true
            ),
            Session(
                id: "s2", title: "Cross-link validator for assemblies", repos: [docsBuilder],
                branch: "cross-link-validator", agent: "claude",
                state: ObservedState(.blocked, reason: "Bash(dotnet publish)"),
                activity: "wants to run dotnet publish", trackedPRs: [PullRef(repo: docsBuilder, number: 2838)],
                pinned: true
            ),
            Session(
                id: "s3", title: "Backpressure in ingest stage", repos: [ingest], branch: "ingest-backpressure",
                agent: "codex", state: ObservedState(.asking, source: .guessed), activity: "3 questions waiting"
            ),
            Session(
                id: "s4", title: "Sequence diagram arrowheads", repos: [mermaider], branch: "sequence-arrowheads",
                agent: "claude", state: ObservedState(.working), activity: "editing · 3m"
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
        return Domain(repos: repos, worktrees: worktrees, sessions: sessions, layouts: layouts)
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
