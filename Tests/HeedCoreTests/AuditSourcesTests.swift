import Foundation
@testable import HeedCore
import Synchronization
import Testing

struct AuditSourcesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let stranger = ExternalText.Author(login: "drive-by", trust: .stranger)
    private let collaborator = ExternalText.Author(login: "mira", trust: .collaborator)

    /// A sink that keeps what it is handed.
    private final class Caught: Sendable {
        let actions = Mutex<[(AuditAction, Cause?)]>([])
        var sink: AuditTap.Sink { { action, cause in self.actions.withLock { $0.append((action, cause)) } } }
        var all: [(AuditAction, Cause?)] { actions.withLock { $0 } }
    }

    private func hook(_ command: String, failed: Bool = false) -> ToolCall? {
        var input: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
        if failed { input["error"] = "fatal: rejected" }
        return ToolCall.from(hook: input)
    }

    @Test func aCauseReachesTheCallsMadeUnderItAndTheTasksTheyStart() async throws {
        let caught = Caught()
        let cause = Cause(at: now, trigger: .key, detail: "zM · pr.merge.now")
        let call = LoggedCall(
            at: now, kind: .github, caller: "pr.mergeNow",
            command: "gh pr merge 412 --squash --match-head-commit abc -R acme/webapp", duration: 1,
            operation: "pr merge", write: true
        )
        await AuditTap.$current.withValue(caught.sink) {
            await Cause.$current.withValue(cause) {
                CallLog.record(call)
                // A task started under it, as a key's work starts one, carries it on.
                await Task { CallLog.record(call) }.value
            }
            // Outside it, nothing names a cause.
            CallLog.record(call)
        }
        let rows = caught.all
        #expect(rows.count == 3)
        #expect(rows[0].0.cause == cause.id && rows[1].0.cause == cause.id && rows[2].0.cause == nil)
        #expect(rows[0].0.tag == .merge && rows[0].0.what == "merged #412 webapp" && rows[0].0.repo == "acme/webapp")
        #expect(rows[0].0.url == "https://github.com/acme/webapp/pull/412")
    }

    @Test func readsAndHeedsBookkeepingAreNotActions() {
        let reads = [
            LoggedCall(at: now, kind: .github, caller: "sync", command: "gh api graphql -f query=@pulls", duration: 0),
            LoggedCall(
                at: now, kind: .github, caller: "read", command: "gh api -X PATCH notifications/threads/9",
                duration: 0, write: true
            ),
            LoggedCall(at: now, kind: .shell, caller: "git", command: "git fetch origin", duration: 0),
        ]
        for call in reads {
            #expect(AuditClassifier.action(call, cause: nil) == nil, "\(call.command)")
        }
    }

    @Test func heedsOwnPushIsAPush() throws {
        let call = LoggedCall(
            at: now, kind: .shell, caller: "helper.push",
            command: "/usr/bin/git -C /tmp/wt push origin HEAD:feature/x", duration: 1, write: false
        )
        let action = try #require(AuditClassifier.action(call, cause: nil))
        #expect(action.tag == .push && action.what == "pushed to feature/x" && action.actor == .heed)
        let failed = LoggedCall(
            at: now, kind: .shell, caller: "helper.push", command: "git push", duration: 1, failed: true
        )
        #expect(AuditClassifier.action(failed, cause: nil)?.outcome == .failed)
    }

    @Test func anAgentsOutwardCommandsAreClassified() throws {
        let cases: [(String, AuditClass, String)] = [
            ("git push -u origin feature/x", .push, "pushed to feature/x"),
            ("git push --force-with-lease", .push, "force-pushed the current branch"),
            ("cd web && git push origin --tags", .publish, "pushed tags"),
            ("gh pr merge 412 --squash -R acme/webapp", .merge, "merged #412 webapp"),
            ("gh pr comment 12 --body 'done'", .comment, "commented on #12"),
            ("gh pr review 9 --approve", .review, "approved #9"),
            ("gh pr edit 9 --add-reviewer mira", .review, "asked mira to review #9"),
            ("npm publish --access public", .publish, "npm publish"),
            ("gh release create v0.9.1 --generate-notes", .publish, "release v0.9.1"),
            ("env CI=1 bash -c 'gh pr create --fill'", .write, "opened a PR"),
            ("gh api -X POST repos/acme/webapp/issues/12/comments -f body=x", .comment, "commented on #12 webapp"),
        ]
        for (command, tag, what) in cases {
            let call = try #require(hook(command), "\(command)")
            #expect(call.command == command, "\(command)")
            let action = try #require(
                AuditClassifier.action(
                    call, at: now, session: "s1", sessionTitle: "fix", agent: "claude", repo: "acme/webapp",
                    cause: nil
                ), "\(command)"
            )
            #expect(action.tag == tag, "\(command)")
            #expect(action.what == what, "\(command): \(action.what)")
            #expect(action.actor == .agent && action.repo == "acme/webapp" && action.session == "s1")
        }
    }

    @Test func anAgentsLocalCommandsAreNot() throws {
        for command in [
            "git status", "git commit -m 'push it'", "gh pr view 12", "npm test", "gh api repos/acme/webapp/pulls",
            "gh api graphql -f query='{ viewer { login } }'", "echo git push",
        ] {
            let call = try #require(hook(command))
            #expect(call.command == nil, "\(command)")
            #expect(
                AuditClassifier.action(
                    call, at: now, session: nil, sessionTitle: nil, agent: nil, repo: nil, cause: nil
                ) == nil,
                "\(command)"
            )
        }
    }

    @Test func aFailedPushIsKeptAsFailed() throws {
        let call = try #require(hook("git push origin main", failed: true))
        let action = AuditClassifier.action(
            call, at: now, session: nil, sessionTitle: nil, agent: nil, repo: nil, cause: nil
        )
        #expect(action?.outcome == .failed)
    }

    @Test func aGitHubToolThatWritesIsAnAction() {
        let merge = ToolCall(tool: "mcp__github__merge_pull_request")
        let read = ToolCall(tool: "mcp__github__get_pull_request")
        #expect(AuditClassifier.action(
            merge, at: now, session: nil, sessionTitle: nil, agent: nil, repo: "a/b", cause: nil
        )?.tag == .merge)
        #expect(AuditClassifier.action(
            read, at: now, session: nil, sessionTitle: nil, agent: nil, repo: "a/b", cause: nil
        ) == nil)
    }

    // MARK: The chain

    private func record(_ index: Int) -> AuditRecord {
        .action(AuditAction(
            id: "a\(index)", at: now.addingTimeInterval(Double(index)), actor: .heed, tag: .push,
            what: "pushed \(index)", command: "git push"
        ))
    }

    @Test func aReleaseNothingExplainsIsOutsideHeed() {
        let start = now.addingTimeInterval(-86400)
        let ours = AuditAction(
            at: now, actor: .agent, tag: .publish, what: "release v0.9.1", command: "gh release create v0.9.1",
            repo: "acme/webapp"
        )
        let tagPush = AuditAction(
            at: now, actor: .heed, tag: .publish, what: "pushed tag v2.0.0", command: "git push origin v2.0.0",
            repo: "acme/api"
        )
        let merge = AuditAction(
            at: now, actor: .heed, tag: .merge, what: "merged #4 site", command: "gh pr merge 4", repo: "acme/site"
        )
        let releases = [
            GitHubRelease(kind: .release, repo: "acme/webapp", id: "1", name: "v0.9.1", at: now.addingTimeInterval(60)),
            GitHubRelease(kind: .release, repo: "acme/webapp", id: "2", name: "v0.9.2", at: now.addingTimeInterval(90)),
            GitHubRelease(kind: .release, repo: "acme/api", id: "3", name: "v2.0.0", at: now.addingTimeInterval(600)),
            GitHubRelease(kind: .deployment, repo: "acme/site", id: "4", name: "prod", at: now.addingTimeInterval(900)),
            // Too long after anything heed did, and before Audit started.
            GitHubRelease(kind: .release, repo: "acme/api", id: "5", name: "v2.0.1", at: now.addingTimeInterval(9000)),
            GitHubRelease(kind: .release, repo: "acme/api", id: "6", name: "v1.0.0", at: start.addingTimeInterval(-1)),
        ]
        let found = AuditOutside.unexplained(
            releases, actions: [ours, tagPush, merge], since: start, known: ["release:acme/webapp:9"]
        )
        #expect(found.map(\.id) == ["2", "5"])
        #expect(AuditOutside.unexplained(
            releases, actions: [ours, tagPush, merge], since: start, known: ["release:acme/webapp:2"]
        ).map(\.id) == ["5"])
        let row = found[0].action()
        #expect(row.actor == .outside && row.tag == .publish && row.key == "release:acme/webapp:2")
    }

    @Test func releasesAndDeploymentsAreReadFromGitHub() {
        let releases = Data("""
        [{"id": 7, "tag_name": "v1.2.0", "published_at": "2026-11-01T10:00:00Z", "html_url": "https://x/r",
          "author": {"login": "mira"}}, {"id": 8}]
        """.utf8)
        let deployments = Data("""
        [{"id": 9, "environment": "production", "created_at": "2026-11-02T10:00:00Z", "creator": {"login": "bot"}}]
        """.utf8)
        let found = GitHubRelease.parse(releases, kind: .release, repo: "acme/webapp")
            + GitHubRelease.parse(deployments, kind: .deployment, repo: "acme/webapp")
        #expect(found.map(\.name) == ["v1.2.0", "production"])
        #expect(found[0].author == "mira" && found[0].url == "https://x/r" && found[1].id == "9")
        #expect(GitHubRelease.parse(Data("nope".utf8), kind: .release, repo: "a/b").isEmpty)
    }

    @Test func theBookCountsTheWeekAndLinksEachRowToItsChain() {
        let root = Cause(at: now, trigger: .autopilot, detail: "merge = heed", authors: [collaborator])
        let old = AuditAction(
            at: now.addingTimeInterval(-8 * 86400),
            actor: .heed,
            tag: .push,
            what: "old",
            command: ""
        )
        let merged = AuditAction(
            at: now, actor: .heed, tag: .merge, what: "merged #4", command: "gh pr merge 4", cause: root.id
        )
        let book = AuditBook([.cause(root), .action(old), .action(merged)])
        #expect(book.count(since: now.addingTimeInterval(-7 * 86400)) == 1)
        #expect(book.rows.map(\.action.what) == ["merged #4", "old"])
        #expect(book.rows[0].trigger == "Autopilot" && book.rows[0].authors == [collaborator])
        #expect(book.rows[1].trigger == "heed")
    }

    @Test func theFakeWorldHoldsOneOfEachKind() {
        let book = AuditBook(Fixtures.audit(now: now))
        let rows = book.rows
        #expect(book.broken == nil && rows.count == 7)
        #expect(rows.first?.action.outcome == .held && rows.first?.worstTrust == .stranger)
        #expect(rows.contains { $0.action.actor == .outside && $0.trigger == "outside heed" })
        #expect(rows
            .contains {
                $0.action.tag == .merge && $0.trigger == "Autopilot" && $0.authors.map(\.trust) == [.collaborator]
            })
        #expect(rows.contains { $0.action.tag == .publish && $0.action.approval?.by == .you })
        #expect(book.grantRows(before: Fixtures.auditBefore).count == 3)
    }
}
