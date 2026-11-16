import Foundation
@testable import HeedCore
import Testing

/// What two paths that run often cost: an outward call recorded into a year of Audit, and a hook call that is not
/// about GitHub. (`CoreBench` times `ExternalText.display`, fenced prompts and a whole book.) `mise run bench` runs
/// them.
@Suite(.enabled(if: Bench.enabled), .serialized)
struct AuditBench {
    /// A year of Audit: `count` actions, each under a cause chain three deep, and a few grants.
    static func records(_ count: Int) -> [AuditRecord] {
        let start = Date(timeIntervalSince1970: 1_700_000_000)
        var records: [AuditRecord] = []
        for index in 0 ..< count {
            let at = start.addingTimeInterval(Double(index) * 600)
            let root = Cause(id: "k\(index)", at: at, trigger: .key, detail: "gm")
            let session = Cause(id: "s\(index)", at: at, trigger: .session, detail: "s", parent: root.id)
            let agent = Cause(
                id: "a\(index)", at: at, trigger: .agent, detail: "a", parent: session.id,
                authors: [.init(login: "eve", trust: .stranger)]
            )
            records += [.cause(root), .cause(session), .cause(agent)]
            records.append(.action(AuditAction(
                id: "x\(index)", at: at, actor: .agent, tag: .push, what: "pushed b\(index)",
                command: "git push origin b\(index)", repo: "acme/app", cause: agent.id
            )))
        }
        for index in 0 ..< 20 {
            records.append(.grant(AuditGrant(
                id: "g\(index)", at: start, kind: .alwaysRule, subject: "Bash(npm test:\(index))", scope: "acme/app",
                why: "you"
            )))
        }
        return records
    }

    /// One outward call recorded into a book of 5,000, and the rows and grants read back, as Audit shows them.
    @Test func anOutwardCallIntoAYearOfAudit() {
        var book = AuditBook(Self.records(5000))
        var index = 0
        let (median, slowest) = Bench.time(runs: 50) {
            index += 1
            let at = Date(timeIntervalSince1970: 1_800_000_000 + Double(index))
            book.apply([
                .cause(Cause(id: "n\(index)", at: at, trigger: .key, detail: "gp")),
                .action(AuditAction(
                    id: "n\(index)", at: at, actor: .heed, tag: .push, what: "pushed", command: "git push",
                    cause: "n\(index)"
                )),
            ])
            _ = book.rows.count
            _ = book.grantRows().count
        }
        print("audit record: median \(Self.ms(median)) ms, slowest \(Self.ms(slowest)) ms")
    }

    /// A Bash call in auto mode that has nothing to do with GitHub, with the book at its limit on disk.
    @Test func aHookCallNotAboutGitHub() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("origin-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = OriginBook.path(forSocket: folder.appendingPathComponent("heed.sock").path)
        try OriginNoteTests.fullBook.write(to: path)
        let input: [String: Any] = [
            "permission_mode": "auto", "tool_name": "Bash", "cwd": OriginNoteTests.repo,
            "tool_input": ["command": "ls -la && swift build"],
        ]
        let (median, slowest) = Bench.time { _ = OriginNote.report(input: input) { OriginBook.read(path) } }
        print("origin note, not GitHub: median \(Self.ms(median)) ms, slowest \(Self.ms(slowest)) ms")
    }

    static func ms(_ seconds: Double) -> String { String(format: "%.3f", seconds * 1000) }
}
