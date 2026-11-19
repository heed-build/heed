import Foundation
@testable import HeedCore
import Testing

struct BrowseBulkFormTests {
    private func item(_ number: Int, labels: [String] = []) -> BrowseItem {
        BrowseItem(
            repo: Repo(org: "acme", name: "docs"), number: number,
            title: ExternalText("T", source: .issueTitle, author: .unknown), labels: labels
        )
    }

    private func type(_ form: inout BrowseBulkForm, _ text: String) {
        for character in text {
            _ = form.handle(KeyStroke(character == " " ? "Space" : String(character)))
        }
    }

    @Test func aLabelIsTypedThenConfirmedThenRunOnlyOnEnter() {
        var form = BrowseBulkForm(typing: .label, items: [item(1), item(2, labels: ["bug"])], viewer: "me")
        type(&form, "bug, needs triage")
        #expect(form.labels == ["bug", "needs triage"])
        #expect(form.handle(KeyStroke("CR")) == .changed)
        guard case let .confirm(plan) = form.stage else { Issue.record("no confirm step"); return }
        #expect(plan.writes.map(\.itemID) == [item(1).id, item(2).id])
        // Typing nothing more reaches the run: only ↩ or y does.
        #expect(form.handle(KeyStroke("q")) == .none)
        #expect(form.handle(KeyStroke("CR")) == .run(plan))
        #expect(form.stage == .running)
    }

    @Test func anEmptyLabelStaysOnTheStepAndSaysWhy() {
        var form = BrowseBulkForm(typing: .label, items: [item(1)], viewer: nil)
        #expect(form.handle(KeyStroke("CR")) == .changed)
        #expect(form.problem == "type a label first")
        guard case .typing = form.stage else { Issue.record("left the step"); return }
    }

    @Test func escapeCancelsAtEveryStepBeforeTheRun() {
        var typing = BrowseBulkForm(typing: .comment, items: [item(1)], viewer: nil)
        #expect(typing.handle(.escape) == .close)
        var closing = BrowseBulkForm(closing: [item(1)], viewer: nil)
        #expect(closing.handle(.escape) == .close)
        var confirm = BrowseBulkForm(assigning: [item(1)], viewer: "me")
        #expect(confirm.handle(.escape) == .close)
        var each = BrowseBulkForm(each: [item(1), item(2)], viewer: nil)
        #expect(each.handle(.escape) == .close)
    }

    @Test func assignWithoutALoginCannotBeConfirmed() {
        var form = BrowseBulkForm(assigning: [item(1)], viewer: nil)
        guard case let .confirm(plan) = form.stage else { Issue.record("no confirm step"); return }
        #expect(plan.blocked != nil)
        // A blocked plan has no writes, so ↩ writes nothing.
        #expect(form.handle(KeyStroke("CR")) == .changed)
        #expect(form.problem == "nothing would change")
    }

    @Test func closingAsksHowThenConfirms() {
        var form = BrowseBulkForm(closing: [item(1), item(2)], viewer: nil)
        #expect(form.handle(KeyStroke("2")) == .changed)
        guard case let .confirm(plan) = form.stage else { Issue.record("no confirm step"); return }
        #expect(plan.action == .close(.notPlanned))
    }

    @Test func manySessionsStartOnlyAfterAYes() {
        var form = BrowseBulkForm(each: (1 ... 6).map { item($0) }, viewer: nil)
        #expect(form.handle(KeyStroke("x")) == .none)
        #expect(form.handle(KeyStroke("CR")) == .startEach)
    }

    @Test func theReportIsKeptAndClosedWithEnter() {
        var form = BrowseBulkForm(typing: .comment, items: [item(1)], viewer: nil)
        let report = BrowseReport(action: .comment("x"), entries: [.init(itemID: "a", place: "p", outcome: .done)])
        form.finished(report)
        #expect(form.stage == .report(report))
        #expect(form.handle(KeyStroke("CR")) == .close)
    }

    @Test func aWrittenActionUpdatesTheItem() {
        let a = item(1, labels: ["bug"])
        #expect(BrowseBulk.updated(a, by: .label(["Bug", "docs"])).labels == ["bug", "docs"])
        #expect(BrowseBulk.updated(a, by: .assignMe("me")).assignees == ["me"])
        #expect(BrowseBulk.updated(a, by: .close(.completed)).state == .closed)
    }
}
