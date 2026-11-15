import Foundation
@testable import HeedCore
import Testing

struct AuditGrantTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func aRevokedGrantShowsAsRevokedUntilItIsGivenAgain() {
        let rule = AuditGrant(
            id: "g1", at: now, kind: .alwaysRule, subject: "Bash(npm test:*)", scope: "/r/.claude/settings.local.json",
            why: "always in approvals"
        )
        let before = AuditGrant(
            id: "before:1", at: .distantPast, kind: .alwaysRule, subject: "Bash(ls:*)", scope: rule.scope, why: "",
            beforeAudit: true
        )
        let duplicate = AuditGrant(
            id: "before:2", at: .distantPast, kind: .alwaysRule, subject: rule.subject, scope: rule.scope, why: "",
            beforeAudit: true
        )
        var book = AuditBook([.grant(rule)])
        #expect(book.grantRows(before: [before, duplicate]).map(\.id) == ["g1", "before:1"])
        book.apply([.revoke(AuditRevocation(grant: rule, at: now.addingTimeInterval(5), result: "removed"))])
        #expect(book.grantRows().first?.revoked?.result == "removed")
        var again = rule
        again.id = "g2"
        again.at = now.addingTimeInterval(10)
        book.apply([.grant(again)])
        #expect(book.grantRows().map(\.id) == ["g2"])
        #expect(book.grantRows().first?.revoked == nil)
    }

    @Test func revokingAnAlwaysRuleTakesOnlyThatRuleOut() throws {
        let root = try folder().path
        let file = AlwaysRules.file(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("""
        {"permissions": {"allow": ["Bash(npm test:*)", "Bash(git push:*)"], "deny": ["Read(.env)"]},
         "model": "haiku"}
        """.utf8).write(to: file)
        #expect(AlwaysRules.rules(in: file) == ["Bash(npm test:*)", "Bash(git push:*)"])
        #expect(try AlwaysRules.remove("Bash(git push:*)", from: file))
        #expect(AlwaysRules.rules(in: file) == ["Bash(npm test:*)"])
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any]
        )
        #expect(json["model"] as? String == "haiku")
        #expect((json["permissions"] as? [String: Any])?["deny"] as? [String] == ["Read(.env)"])
        #expect(try !AlwaysRules.remove("Bash(git push:*)", from: file))
        #expect(try !AlwaysRules.remove("x", from: URL(fileURLWithPath: root + "/missing.json")))
        try Data("not json".utf8).write(to: file)
        #expect(throws: AlwaysRules.Failure.self) { try AlwaysRules.remove("x", from: file) }
    }

    @Test func rulesAlreadyInAFileAreListedOnceAsBeforeAudit() throws {
        let root = try folder().path
        let file = AlwaysRules.file(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(#"{"permissions": {"allow": ["Bash(ls:*)", "WebFetch"]}}"#.utf8).write(to: file)
        let recorded = AuditGrant(
            at: now, kind: .alwaysRule, subject: "WebFetch", scope: file.path, why: "always in approvals"
        )
        let found = AlwaysRules.beforeAudit(roots: [root, root], known: [recorded.identity])
        #expect(found.map(\.subject) == ["Bash(ls:*)"])
        #expect(found[0].beforeAudit && found[0].id == "before:\(file.path):Bash(ls:*)")
    }

    @Test func revokingTrustTakesBackClaudesAndLeavesTheRest() throws {
        let file = try folder().appendingPathComponent("claude.json")
        try Data(#"{"projects": {"/r": {"hasTrustDialogAccepted": true, "x": 1}}}"#.utf8).write(to: file)
        #expect(ClaudeTrust.isTrusted("/r", file: file))
        #expect(try ClaudeTrust.untrust("/r", file: file))
        #expect(!ClaudeTrust.isTrusted("/r", file: file))
        #expect(try String(contentsOf: file, encoding: .utf8).contains("\"x\": 1"))
    }

    @Test func revokingATrustedLoginTakesOutOnlyThatOne() {
        let list = ["coderabbitai[bot]", "@Mira", "copilot"]
        #expect(TrustedLogins.removing("coderabbitai", from: list) == ["@Mira", "copilot"])
        #expect(TrustedLogins.removing("mira", from: list) == ["coderabbitai[bot]", "copilot"])
        #expect(TrustedLogins.removing("nobody", from: list) == list)
    }

    @Test func revokingAMemoryDropsTheKeptDecision() {
        var node = MindNode(id: "n", kind: .campaign, title: "Docs", createdAt: now)
        node.decisions = [.init(text: "keep it short", source: "s"), .init(text: "other", source: "s")]
        var tree = MindmapTree([node])
        let dropped = tree.dropDecision("keep it short", in: "n", now: now)
        #expect(dropped)
        #expect(tree.nodes["n"]?.decisions.map(\.text) == ["other"])
        let again = tree.dropDecision("keep it short", in: "n", now: now)
        #expect(!again)
    }
}
