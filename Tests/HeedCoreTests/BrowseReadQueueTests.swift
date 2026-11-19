import Foundation
@testable import HeedCore
import Testing

struct BrowseReadQueueTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func item(_ number: Int, updated: Double = 0) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            updatedAt: now.addingTimeInterval(-updated)
        )
    }

    private func read(_ item: BrowseItem) -> BrowseRead {
        BrowseRead(
            itemID: item.id,
            kind: .bug,
            size: .s,
            agentReady: 80,
            tldr: "t",
            readAt: now,
            itemUpdatedAt: item.updatedAt
        )
    }

    private func due(
        _ item: BrowseItem, _ read: BrowseRead? = nil, _ trigger: BrowseReadQueue.Trigger = .ahead,
        mode: AttentionSummaryMode = .ahead, ahead: Int = 20, calls: Bool = true, failure: SummaryFailure? = nil,
        running: Bool = false
    ) -> Bool {
        BrowseReadQueue.due(
            item, read: read, trigger: trigger, mode: mode, readAhead: ahead, modelCalls: calls, failure: failure,
            running: running, now: now, backoff: 600
        )
    }

    @Test func anUnreadItemIsDueAheadAndOnOpen() {
        #expect(due(item(1)) && due(item(1), nil, .open) && due(item(1), nil, .asked))
    }

    @Test func aFreshReadIsNeverReadAgainButByAsking() {
        let one = item(1)
        #expect(!due(one, read(one)) && !due(one, read(one), .open))
        #expect(due(one, read(one), .asked))
    }

    @Test func aStaleReadIsDueAgain() {
        var one = item(1, updated: 100)
        let old = read(one)
        one.updatedAt = now
        #expect(due(one, old) && due(one, old, .open))
    }

    @Test func theModeDecidesWhatRunsOnItsOwn() {
        #expect(!due(item(1), mode: .off) && !due(item(1), nil, .open, mode: .off))
        #expect(!due(item(1), mode: .open))
        #expect(due(item(1), nil, .open, mode: .open))
        #expect(!due(item(1), ahead: 0) && due(item(1), nil, .open, ahead: 0))
        // Asking works with the mode off: it is you who asked.
        #expect(due(item(1), nil, .asked, mode: .off))
    }

    @Test func modelCallsOffOrARunningReadStopsEverything() {
        #expect(!due(item(1), calls: false) && !due(item(1), nil, .asked, calls: false))
        #expect(!due(item(1), running: true) && !due(item(1), nil, .asked, running: true))
    }

    @Test func aFailureWaitsForItsTimeUnlessTheItemMovedOrYouAsk() {
        let one = item(1, updated: 100)
        let failure = SummaryFailure(
            kind: .failed,
            text: "x",
            at: now.addingTimeInterval(-60),
            forUpdate: one.updatedAt
        )
        #expect(!due(one, failure: failure))
        #expect(due(one, nil, .asked, failure: failure))
        var moved = one
        moved.updatedAt = now
        #expect(due(moved, failure: failure))
        let old = SummaryFailure(kind: .failed, text: "x", at: now.addingTimeInterval(-700), forUpdate: one.updatedAt)
        #expect(due(one, failure: old))
    }

    @Test func theAheadQueueTakesTheTopRowsThatAreDueInListOrderWithinTheBudget() {
        let rows = (1 ... 30).map { item($0) }
        let done = Set([2, 4])
        let plan = BrowseReadQueue.ahead(rows, top: 20, budget: 100) { !done.contains($0.number) }
        #expect(plan.ids == (1 ... 20).filter { !done.contains($0) }.map { "acme/docs#\($0)" })
        #expect(plan.cut == 0)
        let small = BrowseReadQueue.ahead(rows, top: 20, budget: 5) { !done.contains($0.number) }
        #expect(small.ids == ["acme/docs#1", "acme/docs#3", "acme/docs#5", "acme/docs#6", "acme/docs#7"])
        #expect(small.cut == 13)
        #expect(BrowseReadQueue.ahead(rows, top: 20, budget: 0) { _ in true }.ids.isEmpty)
        #expect(BrowseReadQueue.ahead(rows, top: 0, budget: 9) { _ in true }.ids.isEmpty)
        #expect(BrowseReadQueue.ahead(rows, top: -3, budget: 9) { _ in true }.ids.isEmpty)
    }

    @Test func theBudgetIsTheDaysCallsLeftLessTheReserve() {
        var settings = LLMSettings()
        settings.dailyCalls = 100
        let spent = ["claude": (calls: 90, dollars: 0.1)]
        #expect(SummaryQueue.budget(settings: settings, spent: spent, agents: ["claude"]) == 0)
        #expect(SummaryQueue.budget(settings: settings, spent: [:], agents: ["claude"]) == 25)
        settings.enabled = false
        #expect(SummaryQueue.budget(settings: settings, spent: [:], agents: ["claude"]) == 0)
    }
}
