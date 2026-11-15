import Foundation
@testable import HeedCore
import Testing

/// Shell commands an agent asks to run (`Fixtures/inputs/commands.json`): what `r` allows as a safe read, and what is
/// a release, a publish or a deploy.
struct CommandCorpus: Decodable, Sendable {
    struct Case: Decodable, Sendable, CustomTestStringConvertible {
        let command: String
        let checks: String
        var testDescription: String { command }
    }

    let root: String
    let notSafeRead: [Case]
    let safeRead: [Case]
    let publishes: [Case]
    let notPublishes: [Case]

    static let loaded: CommandCorpus? = UnusualInputs.cases("commands")

    /// The ask's row as the approvals list builds it, for an agent working in `root`.
    static func group(_ command: String) -> ApprovalGroup {
        let root = loaded?.root ?? "/w/repo"
        let ask = PermissionAsk(
            id: "a", session: "s", agent: "claude", tool: "Bash", command: command, cwd: root, askedAt: Date()
        )
        return ApprovalGroup(asks: [ask], tags: PermissionRisk.tags(for: ask, roots: [root], home: "/Users/me"))
    }
}

struct UnusualCommandTests {
    @Test(arguments: CommandCorpus.loaded?.notSafeRead ?? [])
    func isNotASafeRead(_ input: CommandCorpus.Case) {
        #expect(!CommandCorpus.group(input.command).safeRead, "\(input.checks)")
    }

    @Test(arguments: CommandCorpus.loaded?.safeRead ?? [])
    func isASafeRead(_ input: CommandCorpus.Case) {
        #expect(CommandCorpus.group(input.command).safeRead, "\(input.checks)")
    }

    /// A release is always asked, and never allowed for good.
    @Test(arguments: CommandCorpus.loaded?.publishes ?? [])
    func publishes(_ input: CommandCorpus.Case) {
        #expect(PermissionRisk.publishes(input.command), "\(input.checks)")
        let group = CommandCorpus.group(input.command)
        #expect(group.tags.first == .publishes)
        #expect(!group.safeRead)
        var always = group
        always.asks[0].rules = [PermissionRule(toolName: "Bash", ruleContent: input.command)]
        #expect(!always.canAlways)
    }

    @Test(arguments: CommandCorpus.loaded?.notPublishes ?? [])
    func doesNotPublish(_ input: CommandCorpus.Case) {
        #expect(!PermissionRisk.publishes(input.command), "\(input.checks)")
    }
}
