import Foundation
@testable import HeedCore
import Testing

/// Audit's rows are kept, not built on every read (`AuditBook.apply`): an outward call recorded builds its own row
/// and no other, and what the rows say is what building them all from the records says.
struct AuditBookRowsTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)

    /// Action `index`, under a cause of its own, at `offset` seconds from `start`.
    private func recorded(_ index: Int, at offset: Double) -> [AuditRecord] {
        let cause = Cause(
            id: "c\(index)", at: start, trigger: .key, detail: "k\(index)",
            authors: index.isMultiple(of: 3) ? [.init(login: "eve", trust: .stranger)] : []
        )
        return [.cause(cause), .action(AuditAction(
            id: "a\(index)", at: start.addingTimeInterval(offset), actor: .heed, tag: .push, what: "pushed \(index)",
            command: "git push", cause: cause.id, key: index.isMultiple(of: 5) ? "release:acme/app:\(index)" : nil
        ))]
    }

    @Test func anActionRecordedBuildsOnlyItsOwnRow() {
        let records = (0 ..< 100).flatMap { recorded($0, at: Double($0)) }
        var book = AuditBook(records)
        #expect(book.rowsBuilt == 100)
        let change = book.apply(recorded(100, at: 50.5))
        #expect(book.rowsBuilt == 101)
        #expect(!change.rebuilt && !change.grants)
        #expect(change.inserted.map(\.id) == ["a100"])
        // In its place: after the 49 newer than it.
        #expect(book.rows.firstIndex { $0.id == "a100" } == 49)
        #expect(book.rows == AuditBook(records + recorded(100, at: 50.5)).rows)
    }

    /// Times out of order, the same time twice, the same id twice: one by one gives what all at once (a sort) gives.
    @Test func rowsRecordedOneByOneAreTheRowsOfTheWholeRecord() {
        let offsets: [Double] = [5, 1, 9, 5, 5, 0, 12, 3, 9, 7, 2, 12]
        var records = offsets.enumerated().flatMap { recorded($0.offset, at: $0.element) }
        // Action 3 recorded again at the same time, saying something else: it goes after the first, as a sort keeps it.
        records += [recorded(3, at: 5)[0], .action(AuditAction(
            id: "a3", at: start.addingTimeInterval(5), actor: .heed, tag: .push, what: "again", command: "", cause: "c3"
        ))]
        var book = AuditBook()
        for index in stride(from: 0, to: records.count, by: 2) {
            book.apply(Array(records[index ..< index + 2]))
        }
        let whole = AuditBook(records)
        #expect(book.rows.count == offsets.count + 1)
        #expect(book.rows == whole.rows)
        #expect(book.rows.filter { $0.id == "a3" }.map(\.action.what) == ["pushed 3", "again"])
        #expect(book.actions == whole.actions)
        // As the sort Audit used before rows were kept: a stable one.
        let actions = records.compactMap { record -> AuditAction? in
            if case let .action(action) = record { return action }
            return nil
        }
        #expect(book.actions == actions.sorted(by: AuditBook.newestFirst))
        #expect(book == whole && book.hashValue == whole.hashValue)
        #expect(book.outsideKeys == ["release:acme/app:0", "release:acme/app:5", "release:acme/app:10"])
        for offset in [-1.0, 0, 4.5, 5, 9, 12, 13] {
            let since = start.addingTimeInterval(offset)
            #expect(book.count(since: since) == book.actions.count(where: { $0.at >= since }))
        }
    }

    @Test func aCauseThatArrivesLaterRebuildsTheRowsThatNameIt() {
        let action = AuditAction(at: start, actor: .agent, tag: .comment, what: "commented", command: "", cause: "c1")
        var book = AuditBook([.action(action)])
        #expect(book.rows.first?.chain == [])
        let parent = Cause(id: "c0", at: start, trigger: .autopilot, detail: "rule")
        let cause = Cause(id: "c1", at: start, trigger: .agent, detail: "agent", parent: parent.id)
        #expect(book.apply([.cause(cause)]).rebuilt)
        #expect(book.rows.first?.chain.map(\.id) == ["c1"])
        #expect(book.apply([.cause(parent)]).rebuilt)
        #expect(book.rows.first?.chain.map(\.id) == ["c0", "c1"])
        #expect(book.rows.first?.trigger == "Autopilot")
        // A cause nothing shows, or one recorded again as it was, builds nothing.
        let built = book.rowsBuilt
        #expect(!book.apply([.cause(Cause(id: "other", at: start, trigger: .key, detail: "x"))]).rebuilt)
        #expect(!book.apply([.cause(cause)]).rebuilt)
        #expect(book.rowsBuilt == built)
    }

    @Test func aGrantOrARevocationSaysTheGrantsChanged() {
        let grant = AuditGrant(id: "g1", at: start, kind: .alwaysRule, subject: "Bash(ls:*)", scope: "/r", why: "")
        var book = AuditBook()
        #expect(book.apply([.grant(grant)]).grants)
        #expect(!book.apply(recorded(1, at: 0)).grants)
        #expect(book.apply([.revoke(AuditRevocation(grant: grant, at: start, result: "removed"))]).grants)
    }
}
