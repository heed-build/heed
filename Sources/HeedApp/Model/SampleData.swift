import Foundation
import HeedCore

/// The design's sample sessions (design/screens/Main.png), shown until sessions are persisted (build step 5).
enum SampleData {
    static let docsBuilder = Repo(org: "elastic", name: "docs-builder")
    static let docsContent = Repo(org: "elastic", name: "docs-content")
    static let mermaider = Repo(org: "nullean", name: "mermaider")
    static let editorconfig = Repo(org: "editorconfig", name: "editorconfig")
    static let ingest = Repo(org: "mpdreamz", name: "ingest")

    static let sessions: [Session] = [
        Session(
            id: "s1", title: "Fix broken anchors in redirects",
            prompt: "Fix broken anchors in redirects.yml. Every redirect target must resolve to a real heading.",
            repos: [docsBuilder, docsContent], branch: "fix-anchors-redirects", agent: "claude",
            state: ObservedState(.working), activity: "running tests · 14m", trackedPRs: [2841, 1920], pinned: true
        ),
        Session(
            id: "s2", title: "Cross-link validator for assemblies", repos: [docsBuilder],
            branch: "cross-link-validator",
            agent: "claude", state: ObservedState(.blocked, reason: "Bash(dotnet publish)"),
            activity: "wants to run dotnet publish", trackedPRs: [2838], pinned: true
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
            agent: "claude", state: ObservedState(.done), activity: "done · PR approved", trackedPRs: [412]
        ),
        Session(
            id: "s6", title: "Docs nav spike", repos: [docsBuilder], branch: "docs-nav-spike", agent: "opencode",
            state: ObservedState(.idle), activity: "idle 2h"
        ),
    ]

    static func tabs(for session: Session) -> [PaneTab] {
        let directory = "\(NSHomeDirectory())/code/wt/\(session.repos[0].name)/\(session.branch)"
        let agent = PaneSpec(role: .agent, title: session.agent, directory: directory, command: session.agent)
        let shell = PaneSpec(role: .shell, title: "zsh \(session.branch)", directory: directory)
        var main = PaneTab(title: "agent", tree: .leaf(agent))
        main.split(.horizontal, with: shell)
        main.focused = agent.id
        let tests = PaneSpec(role: .task, title: "tests", directory: directory, command: "dotnet watch test")
        return [
            main,
            PaneTab(title: "shell", tree: .leaf(PaneSpec(role: .shell, title: "zsh", directory: directory))),
            PaneTab(title: "tests", tree: .leaf(tests)),
        ]
    }
}
