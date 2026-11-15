import Foundation

/// Audit's fake world: an Autopilot merge on a collaborator's review, a publish you allowed, a push held after a
/// stranger's comment reached the prompt, a release nothing explains, heed's own comment and push, and two grants.
public extension Fixtures {
    /// The records, oldest first, relative to `now`.
    static func audit(now: Date) -> [AuditRecord] {
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        let mira = ExternalText.Author(login: "mira", trust: .collaborator)
        let rabbit = ExternalText.Author(login: "coderabbitai[bot]", trust: .bot)
        let driveBy = ExternalText.Author(login: "quickfix-42", trust: .stranger)

        // You started work on the anchors fix with zR; the agent's review round read mira's and the bot's comments.
        let start = Cause(
            id: "c00000000a001", at: ago(300), trigger: .key, detail: "o · work.start"
        )
        let session = start.child(
            .session, "started claude on \"Fix broken anchors in redirects\"", at: ago(299), session: "s1",
            sessionTitle: "Fix broken anchors in redirects", agent: "claude"
        )
        let review = Cause(
            id: "c00000000a003", at: ago(140), trigger: .pullEvent, detail: "2 new review comments on #2841",
            parent: session.id, session: "s1", sessionTitle: "Fix broken anchors in redirects", agent: "claude",
            authors: [mira, rabbit]
        )
        let pushed = AuditAction(
            id: "a-push-2841", at: ago(120), actor: .agent, tag: .push, what: "pushed to fix-redirect-anchors",
            command: "git push origin fix-redirect-anchors", repo: "acme/docs-toolkit",
            url: "https://github.com/acme/docs-toolkit/pull/2841", cause: review.id, session: "s1",
            sessionTitle: "Fix broken anchors in redirects", agent: "claude",
            approval: .init(by: .rule, detail: "Bash(git push:*) in .claude/settings.local.json")
        )
        // Autopilot merged it: every rule held, mira approved the head commit.
        let pilot = Cause(
            id: "c00000000a004", at: ago(42), trigger: .autopilot,
            detail: "merge = \"heed\": every merge rule held · approved by @mira on 9f3c2e1", parent: session.id,
            session: "s1", sessionTitle: "Fix broken anchors in redirects", authors: [mira]
        )
        let merged = AuditAction(
            id: "a-merge-2841", at: ago(41), actor: .heed, tag: .merge, what: "merged #2841 docs-toolkit",
            command: "gh pr merge 2841 --squash --match-head-commit 9f3c2e1 -R acme/docs-toolkit",
            repo: "acme/docs-toolkit", url: "https://github.com/acme/docs-toolkit/pull/2841", cause: pilot.id,
            session: "s1", sessionTitle: "Fix broken anchors in redirects"
        )
        let comment = AuditAction(
            id: "a-comment-2841", at: ago(41), actor: .heed, tag: .comment, what: "commented on #2841 docs-toolkit",
            command: "gh pr comment 2841 --body … -R acme/docs-toolkit", repo: "acme/docs-toolkit",
            url: "https://github.com/acme/docs-toolkit/pull/2841", cause: pilot.id, session: "s1",
            sessionTitle: "Fix broken anchors in redirects"
        )

        // The spec bump: you allowed its npm publish in the approvals.
        let bump = Cause(
            id: "c00000000a005", at: ago(200), trigger: .key, detail: "o · work.start", session: "s5",
            sessionTitle: "Bump spec tests to 0.17", agent: "codex"
        )
        let publish = AuditAction(
            id: "a-publish-rules", at: ago(18), actor: .agent, tag: .publish, what: "npm publish editor-rules@2.1.0",
            command: "npm publish --access public", repo: "initech/editor-rules", cause: bump.id, session: "s5",
            sessionTitle: "Bump spec tests to 0.17", agent: "codex",
            approval: .init(by: .you, at: ago(19), detail: "allowed once")
        )

        // The ingest session picked up a review comment from someone outside the repo; its push waited, and you
        // said no.
        let ingest = Cause(
            id: "c00000000a006", at: ago(90), trigger: .pullEvent, detail: "a new comment on #388",
            session: "s3", sessionTitle: "Backpressure in ingest stage", agent: "claude", authors: [driveBy]
        )
        let held = AuditAction(
            id: "a-push-held", at: ago(9), actor: .agent, tag: .push, what: "force-pushed to main",
            command: "git push --force origin HEAD:main", repo: "umbrella/ingest", cause: ingest.id, session: "s3",
            sessionTitle: "Backpressure in ingest stage", agent: "claude",
            approval: .init(by: .you, at: ago(8), detail: "denied"), outcome: .held
        )

        // A release on a watched repo with nothing in heed behind it.
        let outside = GitHubRelease(
            kind: .release, repo: "globex/markgraph", id: "188201", name: "v0.9.1", at: ago(64),
            url: "https://github.com/globex/markgraph/releases/tag/v0.9.1", author: "ci-release"
        ).action()

        // The helper fixing CI on the spec bump pushed its fix.
        let helper = Cause(
            id: "c00000000a007", at: ago(30), trigger: .helper, detail: "get it green on #77 (red CI)", session: "s5",
            sessionTitle: "Bump spec tests to 0.17", agent: "claude"
        )
        let helperPush = AuditAction(
            id: "a-helper-push", at: ago(26), actor: .heed, tag: .push, what: "pushed to bump-spec-tests",
            command: "git -C ~/src/editor-rules.worktrees/bump-spec-tests push origin HEAD:bump-spec-tests",
            repo: "initech/editor-rules", cause: helper.id, session: "s5", sessionTitle: "Bump spec tests to 0.17"
        )

        // Grants: the Always rule the anchors push ran under, and the bot trusted from heed's suggestion.
        let always = Cause(
            id: "c00000000a008", at: ago(2 * 1440), trigger: .key, detail: "gy · approvals.always", session: "s1",
            sessionTitle: "Fix broken anchors in redirects", agent: "claude"
        )
        let rule = AuditGrant(
            id: "g-always-push", at: ago(2 * 1440), kind: .alwaysRule, subject: "Bash(git push:*)",
            scope: "~/src/docs-toolkit.worktrees/fix-redirect-anchors/.claude/settings.local.json",
            why: "Always in the approvals, on git push origin fix-redirect-anchors", cause: always.id, session: "s1"
        )
        let trust = Cause(id: "c00000000a009", at: ago(3 * 1440), trigger: .key, detail: "zT · pilot.reviewers.trust")
        let reviewer = AuditGrant(
            id: "g-trust-rabbit", at: ago(3 * 1440), kind: .trustedReviewer, subject: "coderabbitai[bot]",
            scope: "acme/docs-toolkit", why: "heed suggested it: it reviewed 6 PRs there", cause: trust.id
        )
        return [
            .cause(trust), .grant(reviewer), .cause(always), .grant(rule), .cause(start), .cause(session),
            .cause(bump), .cause(review), .action(pushed), .cause(ingest), .action(outside), .cause(pilot),
            .action(merged), .action(comment), .cause(helper), .action(helperPush), .action(publish), .action(held),
        ]
    }

    /// The Always rules found in files before Audit: listed under its grants.
    static let auditBefore: [AuditGrant] = [
        AuditGrant(
            id: "before:~/src/ingest/.claude/settings.local.json:Bash(npm test:*)", at: .distantPast,
            kind: .alwaysRule, subject: "Bash(npm test:*)", scope: "~/src/ingest/.claude/settings.local.json",
            why: "in settings.local.json before Audit", beforeAudit: true
        ),
    ]
}
