@testable import HeedCore
import Testing

@Suite struct HistoryPaneTabsTests {
    @Test func tabsNameEveryHistoryViewOnceWithItsCount() {
        let tabs = HistoryPaneTabs.tabs(counts: .init(sessions: 12, ledger: 5, open: 3))
        #expect(tabs.map(\.pane) == ["history", "timeline", "ledger", "dashboard", "mindmap", "standup"])
        #expect(tabs.map(\.count) == [12, 0, 5, 0, 3, 0])
        #expect(HistoryPaneTabs.crumb(pane: "ledger") == ["History", "Ledger"])
        #expect(HistoryPaneTabs.crumb(pane: "history") == ["History", "Sessions"])
    }

    /// The strip shows the same keys in every History view, so each view binds every other view's capital to it.
    @Test func everyHistoryViewBindsTheSameKeysToTheOthers() {
        let switching = HistoryPaneTabs.panes.map(\.command).filter { $0 != "history.list" }
        var keys: [String: String] = [:]
        for scope in HistoryPaneTabs.panes.map(\.pane) {
            let bindings = DefaultKeys.scoped[scope] ?? []
            for command in switching {
                let bound = bindings.filter { $0.1 == command }.map(\.0)
                #expect(bound.count == 1, "\(scope) binds \(command) \(bound.count) times")
                guard let key = bound.first else { continue }
                if let earlier = keys[command] { #expect(earlier == key, "\(scope) binds \(command) to \(key)") }
                keys[command] = key
                // No other command in the view takes that key.
                #expect(bindings.count(where: { $0.0 == key }) == 1, "\(scope): \(key) is bound twice")
            }
        }
        #expect(keys == [
            "history.timeline": "T", "history.ledger": "L", "history.dashboard": "D", "history.mindmap": "M",
            "history.standup": "U",
        ])
    }

    @Test func theTimelinesRemovedWorktreesToggleKeepsItsCommandOnAnotherKey() {
        let timeline = DefaultKeys.scoped["timeline"] ?? []
        #expect(timeline.contains { $0 == ("c", "timeline.gone") })
        #expect(Commands.spec("history.list") != nil)
    }
}
