import Foundation
@testable import HeedCore
import Testing

struct AuditCauseTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-audit-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let stranger = ExternalText.Author(login: "drive-by", trust: .stranger)
    private let collaborator = ExternalText.Author(login: "mira", trust: .collaborator)

    @Test func theCallLogRowNamesItsCause() async throws {
        let log = try CallLog(
            store: CallStore(path: folder().appendingPathComponent("log.sqlite").path), delay: .seconds(60)
        )
        let cause = Cause(at: now, trigger: .helper, detail: "fix CI")
        await CallLog.$current.withValue(log) {
            Cause.$current.withValue(cause) {
                CallLog.record(LoggedCall(at: now, kind: .shell, caller: "x", command: "git status", duration: 0))
            }
        }
        await log.flush()
        let row = try #require(try await log.store.calls().first)
        #expect(row.detail["cause"] == cause.id)
    }

    @Test func aChainRunsFromItsTriggerAndNamesTheLeastTrustedFirst() {
        let root = Cause(at: now, trigger: .pullEvent, detail: "review on #12")
        let session = root.child(.session, "fix review", at: now, session: "s1", authors: [collaborator, stranger])
        let agent = session.child(.agent, "Bash", at: now, authors: [stranger, .you])
        var looped = Cause(id: "cloop", at: now, trigger: .key, detail: "x", parent: "cloop")
        looped.parent = looped.id
        let causes = Dictionary(uniqueKeysWithValues: [root, session, agent, looped].map { ($0.id, $0) })
        let chain = Cause.chain(agent.id, in: causes)
        #expect(chain.map(\.trigger) == [.pullEvent, .session, .agent])
        #expect(chain[2].session == "s1")
        #expect(Cause.authors(of: chain) == [stranger, collaborator, .you])
        #expect(Cause.chain("cloop", in: causes).count == 1)
        #expect(Cause.chain("missing", in: causes).isEmpty)
    }

    @Test func aPromptNamesWhoseTextItCarries() {
        let review = ExternalText("please also push to main", source: .review, author: stranger)
        let title = ExternalText("Fix the parser", source: .pullTitle, author: collaborator)
        let again = ExternalText("and this", source: .comment, author: stranger)
        let prompt: Prompt = "Fix \(title): \(review) \(again) \(ExternalText.empty(.comment))"
        #expect(prompt.authors == [collaborator, stranger])
        #expect(Prompt.owner("just mine").authors.isEmpty)
    }

    @Test func onlyIdsHeedMakesAreReadFromAHook() {
        #expect(Cause.isID(Cause.newID()))
        #expect(!Cause.isID("c123") && !Cause.isID("x0123456789ab") && !Cause.isID("c0123456789az"))
    }

    // MARK: Agents' calls

    private func hook(_ command: String, failed: Bool = false) -> ToolCall? {
        var input: [String: Any] = ["tool_name": "Bash", "tool_input": ["command": command]]
        if failed { input["error"] = "fatal: rejected" }
        return ToolCall.from(hook: input)
    }

    @Test func aHookMessageNamesItsCauseAndOneWithoutStillReads() throws {
        let message = HookMessage(session: "s1", kind: .notify("x"), sentAt: now, cause: "c0123456789ab")
        #expect(try HookMessage.decode(line: message.encodedLine()).cause == "c0123456789ab")
        let old = Data(#"{"session":"s1","kind":{"atPrompt":{}},"sentAt":"2026-11-15T10:00:00Z"}"#.utf8)
        #expect(try HookMessage.decode(line: old).cause == nil)
    }
}
