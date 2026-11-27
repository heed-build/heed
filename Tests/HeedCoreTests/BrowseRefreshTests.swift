import Foundation
@testable import HeedCore
import Testing

struct BrowseRefreshPolicyTests {
    private func state(_ edit: (inout BrowseRefreshPolicy.State) -> Void = { _ in }) -> BrowseRefreshPolicy.State {
        var state = BrowseRefreshPolicy.State()
        state.age = 120
        edit(&state)
        return state
    }

    @Test func `a stale answer is asked again, a fresh one is not`() {
        #expect(BrowseRefreshPolicy.decide(state: state()).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state { $0.age = 30 }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state { $0.age = 59.9 }).fetch)
        #expect(BrowseRefreshPolicy.decide(state: state { $0.age = 60 }).fetch)
        // Nothing answered for this scope and query yet.
        #expect(BrowseRefreshPolicy.decide(state: state { $0.age = nil }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state {
            $0.age = 100
            $0.refreshAfter = 300
        }).fetch)
    }

    @Test func `every trigger asks while Browse is in front`() {
        for trigger in [BrowseRefreshPolicy.Trigger.viewSwitch, .appActive, .windowKey] {
            #expect(BrowseRefreshPolicy.decide(state: state { $0.trigger = trigger }).fetch)
        }
    }

    @Test func `no fetch in the fake world, with another view in front, without a query, or while one runs`() {
        #expect(!BrowseRefreshPolicy.decide(state: state { $0.fixture = true }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state {
            $0.frontIsBrowse = false
            $0.trigger = .appActive
        }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state { $0.hasQuery = false }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state { $0.inFlight = true }).fetch)
    }

    @Test func `with the setting off only entering Browse asks, as before`() {
        #expect(BrowseRefreshPolicy.decide(state: state { $0.autoRefresh = false }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state {
            $0.autoRefresh = false
            $0.trigger = .appActive
        }).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: state {
            $0.autoRefresh = false
            $0.trigger = .windowKey
        }).fetch)
    }

    @Test func `a failure backs off, longer for each in a row`() {
        #expect(BrowseRefreshPolicy.backoff(failures: 0, refreshAfter: 60) == 0)
        #expect(BrowseRefreshPolicy.backoff(failures: 1, refreshAfter: 60) == 60)
        #expect(BrowseRefreshPolicy.backoff(failures: 2, refreshAfter: 60) == 120)
        #expect(BrowseRefreshPolicy.backoff(failures: 9, refreshAfter: 60) == 600)
        let failed = { (seconds: Double, count: Int) in
            state {
                $0.age = 1000
                $0.failures = count
                $0.sinceFailure = seconds
            }
        }
        #expect(!BrowseRefreshPolicy.decide(state: failed(30, 1)).fetch)
        #expect(BrowseRefreshPolicy.decide(state: failed(61, 1)).fetch)
        #expect(!BrowseRefreshPolicy.decide(state: failed(100, 2)).fetch)
        #expect(BrowseRefreshPolicy.decide(state: failed(121, 2)).fetch)
    }

    @Test func `what is selected holds the structural part`() {
        let none = BrowseRefreshPolicy.decide(state: state())
        #expect(none.fetch && !none.holdStructural)
        let selections: [(String, (inout BrowseRefreshPolicy.State) -> Void)] = [
            ("cursor in the reader", { $0.cursorInReader = true }),
            ("picks", { $0.picks = 2 }),
            ("pushed reader", { $0.readerPushed = true }),
            ("a run", { $0.runLive = true }),
            ("a builder or sheet", { $0.overlayOpen = true }),
            ("a bulk form", { $0.bulkOpen = true }),
        ]
        for (name, edit) in selections {
            let decision = BrowseRefreshPolicy.decide(state: state(edit))
            #expect(decision.fetch, "\(name)")
            #expect(decision.holdStructural, "\(name)")
        }
        // A hold does not stop the ask: in-place changes still land.
        #expect(BrowseRefreshPolicy.decide(state: state { $0.cursorInReader = true }).fetch)
        // Nor does a fresh answer stop the hold.
        #expect(BrowseRefreshPolicy.decide(state: state {
            $0.age = 1
            $0.picks = 1
        }).holdStructural)
    }
}

struct BrowseRefreshApplyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func item(_ number: Int, days: Double) -> BrowseItem {
        BrowseItem(
            repo: docs, number: number, title: ExternalText("Item \(number)", source: .issueTitle, author: .unknown),
            updatedAt: now.addingTimeInterval(-days * 86400)
        )
    }

    private var current: [BrowseItem] { (1 ... 5).map { item($0, days: Double($0)) } }
    private func id(_ number: Int) -> String { "acme/docs#\(number)" }

    private func apply(_ fetched: [BrowseItem], cursor: Int?, picks: Set<String> = []) -> BrowseRefreshApply.Outcome {
        let diff = BrowseDiff.between(current: current, fetched: fetched, order: .updated)
        return BrowseRefreshApply.apply(
            diff, to: current, cursorID: cursor.map(id), cursorIndex: cursor.map { $0 - 1 } ?? 0, picks: picks
        )
    }

    @Test func `the cursor stays on its item when rows come above it`() {
        let outcome = apply([item(8, days: 0.1), item(9, days: 0.2)] + current, cursor: 3)
        #expect(outcome.rows.count == 7)
        #expect(outcome.cursorID == id(3))
        #expect(outcome.cursor == 4)
        #expect(!outcome.cursorGone)
        #expect(outcome.fresh == [id(8), id(9)])
        #expect(outcome.note == nil)
    }

    @Test func `the cursor moves to the row below when its item is gone`() {
        let outcome = apply(current.filter { $0.number != 3 }, cursor: 3)
        #expect(outcome.cursorGone)
        #expect(outcome.cursorID == id(4))
        #expect(outcome.cursor == 2)
        #expect(outcome.note?.contains("gone") == true)
    }

    @Test func `the cursor moves up when nothing below stayed`() {
        let outcome = apply(current.filter { $0.number < 4 }, cursor: 5)
        #expect(outcome.cursorID == id(3))
        #expect(outcome.cursor == 2)
        #expect(outcome.cursorGone)
    }

    @Test func `picks stay by id and the ones gone are dropped and counted`() {
        let outcome = apply(
            current.filter { $0.number != 2 && $0.number != 4 },
            cursor: 1,
            picks: [id(2), id(3), id(4)]
        )
        #expect(outcome.droppedPicks == [id(2), id(4)])
        #expect(outcome.note == "2 picked items are gone")
        let one = apply(current.filter { $0.number != 2 }, cursor: 1, picks: [id(2)])
        #expect(one.note == "1 picked item is gone")
    }

    @Test func `all picks gone`() {
        let outcome = apply([item(9, days: 0.1)], cursor: nil, picks: Set((1 ... 5).map(id)))
        #expect(outcome.droppedPicks.count == 5)
        #expect(outcome.rows.map(\.number) == [9])
    }

    @Test func `an empty answer leaves an empty list with the cursor at the top`() {
        let outcome = apply([], cursor: 2, picks: [id(1)])
        #expect(outcome.rows.isEmpty)
        #expect(outcome.cursor == 0)
        #expect(outcome.cursorID == nil)
        #expect(outcome.droppedPicks == [id(1)])
    }

    @Test func `an empty list fills with no cursor to keep`() {
        let diff = BrowseDiff.between(current: [], fetched: current, order: .updated)
        let outcome = BrowseRefreshApply.apply(diff, to: [], cursorID: nil, cursorIndex: 0, picks: [])
        #expect(outcome.rows.count == 5)
        #expect(outcome.cursor == 0)
        #expect(outcome.cursorID == id(1))
        #expect(outcome.fresh.count == 5)
    }

    @Test func `a moved row follows the cursor`() {
        var changed = current
        changed[4].updatedAt = now // 5 jumps to the top; the cursor is on it
        let outcome = apply(changed, cursor: 5)
        #expect(outcome.cursor == 0)
        #expect(outcome.cursorID == id(5))
    }

    @Test func `what GitHub no longer lists is gone, within what a capped answer vouches for`() {
        let shown = current // 1 day ... 5 days old
        let fetched = [shown[0], shown[2]]
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: fetched, capped: false) == [id(2), id(4), id(5)])
        // Capped: the answer reaches back to 3's update time, so older 4 and 5 may just be past the cap.
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: fetched, capped: true) == [id(2)])
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: [], capped: true).isEmpty)
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: [], capped: false).count == 5)
        // An answer that searched only some of the owners vouches for none of the rows.
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: fetched, capped: false, partial: true).isEmpty)
        #expect(BrowseRefreshApply.gone(shown: shown, fetched: [], capped: false, partial: true).isEmpty)
    }
}

struct BrowseRefreshSettingsTests {
    @Test func `the settings default on, a minute, and are read`() {
        #expect(BrowseSettings().autoRefresh)
        #expect(BrowseSettings().refreshAfter == 60)
        let (config, problems) = ConfigLoader.decode("[browse]\nauto_refresh = false\nrefresh_after = 300\n")
        #expect(problems.isEmpty)
        #expect(config?.browse.autoRefresh == false)
        #expect(config?.browse.refreshAfter == 300)
        let (_, bad) = ConfigLoader.decode("[browse]\nauto_refresh = \"yes\"\nrefresh_after = 1\n")
        #expect(bad.contains { $0.path == "browse.auto_refresh" })
        #expect(bad.contains { $0.path == "browse.refresh_after" })
    }
}
