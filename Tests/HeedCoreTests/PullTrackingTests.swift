import Foundation
@testable import HeedCore
import Testing

struct PullTrackingTests {
    private let repo = Repo(org: "o", name: "r")
    private let other = Repo(org: "o", name: "companion")

    private func session(created: Date = Date(timeIntervalSince1970: 1000)) -> Session {
        Session(
            id: "s", title: "t", repos: [repo], branch: "feature", agent: "claude", state: .init(.working),
            lastActivity: created, createdAt: created
        )
    }

    private func pull(_ number: Int, branch: String, in repo: Repo? = nil) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo ?? self.repo, number: number), title: "", url: "", state: .open, isDraft: false,
            headBranch: branch, review: nil, checks: CheckSummary(), unresolvedThreads: 0, updatedAt: Date()
        )
    }

    private func added(_ kinds: [HookMessage.Kind]) -> [String] {
        kinds.compactMap { if case let .prAdd(url) = $0 { url } else { nil } }
    }

    // MARK: PRs the agent created

    @Test func onlyACreationCounts() {
        let output = "Creating pull request for feature into main\nhttps://github.com/o/r/pull/12\n"
        #expect(PullCreation.urls(tool: "Bash", command: "gh pr create --fill", output: output)
            == ["https://github.com/o/r/pull/12"])
        #expect(PullCreation.urls(tool: "Bash", command: "gh pr view 12", output: output).isEmpty)
        #expect(PullCreation.urls(tool: "Bash", command: "echo see https://github.com/o/r/pull/9", output: output)
            .isEmpty)
        #expect(PullCreation.urls(tool: "Bash", command: "hub pull-request -m x", output: output).count == 1)
        let api = #"{"url":"https://api.github.com/repos/o/r/pulls/3","html_url":"https://github.com/o/r/pull/3"}"#
        #expect(PullCreation.urls(tool: "Bash", command: "gh api repos/o/r/pulls -X POST -f title=x", output: api)
            == ["https://github.com/o/r/pull/3"])
        #expect(PullCreation.urls(tool: "Bash", command: "gh api repos/o/r/pulls", output: api).isEmpty)
        #expect(PullCreation.urls(tool: "mcp__github__create_pull_request", command: nil, output: api)
            == ["https://github.com/o/r/pull/3"])
    }

    @Test func eachAgentsHookReportsIt() {
        let made = "https://github.com/o/companion/pull/4"
        let claude = AgentIntegration.claudeHook(event: "PostToolUse", input: [
            "tool_name": "Bash", "tool_input": ["command": "gh pr create -R o/companion --fill"],
            "tool_response": ["stdout": made + "\n", "stderr": ""],
        ])
        #expect(added(claude) == [made])
        let codex = AgentIntegration.codexHook(event: "PostToolUse", input: [
            "tool_name": "Bash", "tool_input": ["command": "gh pr create"], "tool_response": made,
        ])
        #expect(added(codex) == [made])
        let mcp = AgentIntegration.claudeHook(event: "PostToolUse", input: [
            "tool_name": "mcp__github__create_pull_request", "tool_input": ["title": "x"],
            "tool_response": [["type": "text", "text": #"{"html_url":"\#(made)"}"#]],
        ])
        #expect(added(mcp) == [made])
        #expect(added(AgentIntegration.cursorHook(
            event: "afterShellExecution", input: ["command": "gh pr create", "output": made]
        )) == [made])
        #expect(added(AgentIntegration.cursorHook(
            event: "afterMCPExecution", input: ["tool_name": "create_pull_request", "result_json": made]
        )) == [made])
        #expect(added(AgentIntegration.cursorHook(
            event: "postToolUse", input: [
                "tool_name": "Shell",
                "tool_input": #"{"command":"gh pr create"}"#,
                "tool_output": made,
            ]
        )) == [made])
        #expect(added(AgentIntegration.piHook(event: "pr", sessionID: "x", detail: made)) == [made])
        #expect(added(AgentIntegration.opencodeHook(event: "pr", sessionID: "x", detail: made)) == [made])
        #expect(AgentIntegration.piHook(event: "pr", sessionID: "x", detail: "not a url").isEmpty)
        // Reading a PR is not opening one.
        #expect(added(AgentIntegration.claudeHook(event: "PostToolUse", input: [
            "tool_name": "Bash", "tool_input": ["command": "gh pr view 4"], "tool_response": ["stdout": made],
        ])).isEmpty)
    }

    // MARK: The session follows its worktree's branch

    @Test func aNewBranchInTheSameWorktreeIsFollowed() {
        var domain = Domain(sessions: [session()])
        let path = "/wt/r/feature"
        domain.apply(.worktreesListed(repo: repo, [
            Worktree(repo: repo, path: path, branch: "feature", head: "a", isMain: false),
        ]))
        #expect(domain.sessions[0].worktreePaths == [path])
        // Merged, then `git switch -c follow-up` in the same worktree.
        domain.apply(.worktreesListed(repo: repo, [
            Worktree(repo: repo, path: path, branch: "follow-up", head: "b", isMain: false),
        ]))
        #expect(domain.sessions[0].branches == ["feature", "follow-up"])
        #expect(domain.sessions[0].owns(domain.worktrees[0]))
        let changes = PullTracking.changes(sessions: domain.sessions, pulls: [pull(8, branch: "follow-up")])
        guard case let .sessionUpserted(updated)? = changes.first else {
            Testing.Issue.record("not tracked")
            return
        }
        #expect(updated.trackedPRs.map(\.number) == [8])
        #expect(updated.timeline.last?.text == "tracking PR r#8 (branch follow-up)")
    }

    @Test func untrackedStaysOut() {
        var session = session()
        session.untrackedPRs = [PullRef(repo: repo, number: 7)]
        #expect(PullTracking.changes(sessions: [session], pulls: [pull(7, branch: "feature")]).isEmpty)
        let tracked = session.track(PullRef(repo: repo, number: 7), because: "x")
        #expect(!tracked)
    }

    // MARK: PRs that link back

    @Test func linkedPRsThatAreYoursAndNewerAreTracked() {
        var tracked = session()
        tracked.trackedPRs = [PullRef(repo: repo, number: 1)]
        func reference(_ number: Int, author: String, at seconds: Double, state: String = "OPEN") -> PullDetail
            .Reference
        {
            PullDetail.Reference(
                ref: PullRef(repo: other, number: number), title: "t", author: author, state: state,
                createdAt: Date(timeIntervalSince1970: seconds)
            )
        }
        let references = [
            reference(2, author: "Me", at: 2000), reference(3, author: "someone", at: 2000),
            reference(4, author: "me", at: 10), reference(5, author: "me", at: 2000, state: "MERGED"),
        ]
        let (track, suggest) = PullTracking.linked(references, session: tracked, viewer: "me")
        #expect(track.map(\.ref.number) == [2])
        #expect(suggest.map(\.ref.number) == [3, 4])
        // Without knowing who you are, nothing is tracked on its own.
        #expect(PullTracking.linked(references, session: tracked, viewer: nil).track.isEmpty)
    }

    @Test func theQueryReadsCrossReferences() throws {
        let json = """
        {"data":{"repository":{"pullRequest":{"number":1,"title":"t","body":"","baseRefName":"main","headRefName":"b",
          "additions":1,"deletions":1,"state":"OPEN",
          "commits":{"totalCount":1,"nodes":[{"commit":{"oid":"a","statusCheckRollup":null}}]},
          "reviews":{"nodes":[]},"closingIssuesReferences":{"nodes":[]},"reviewThreads":{"nodes":[]},
          "timelineItems":{"nodes":[
            {"source":{"number":4,"title":"Companion","state":"OPEN","createdAt":"2026-10-14T09:00:00Z",
              "author":{"login":"me"},"repository":{"nameWithOwner":"o/companion"}}},
            {"source":{"number":9}},
            {}]}}}}}
        """
        let detail = try #require(GitHub.parsePullDetail(
            Data(json.utf8),
            ref: PullRef(repo: repo, number: 1),
            now: Date()
        ))
        #expect(detail.references?.map(\.ref.description) == ["o/companion#4"])
        #expect(detail.references?.first?.author == "me")
    }

    @Test func sessionsCachedBeforeStillLoad() throws {
        var encoded = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session())) as? [String: Any] ?? [:]
        encoded.removeValue(forKey: "branches")
        encoded.removeValue(forKey: "worktreePaths")
        encoded.removeValue(forKey: "untrackedPRs")
        let decoded = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: encoded))
        #expect(decoded.branches == ["feature"])
        #expect(decoded.worktreePaths.isEmpty)
    }
}
