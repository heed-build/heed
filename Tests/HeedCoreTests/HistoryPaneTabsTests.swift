@testable import HeedCore
import Testing

@Suite struct HistoryPaneTabsTests {
    @Test func tabsNameEveryInsightsViewOnceWithItsCount() {
        let tabs = HistoryPaneTabs.tabs(counts: .init(sessions: 12, ledger: 5, open: 3))
        #expect(tabs.map(\.pane) == ["history", "ledger", "dashboard", "mindmap", "standup"])
        #expect(tabs.map(\.title) == ["History", "Ledger", "Dashboard", "Mindmap", "Standup"])
        #expect(tabs.map(\.count) == [12, 5, 0, 3, 0])
        #expect(HistoryPaneTabs.area == "Insights" && HistoryPaneTabs.home == "dashboard")
    }

    /// The strip shows the same keys in every Insights view, so each view binds every other view's capital to it.
    @Test func everyInsightsViewBindsTheSameKeysToTheOthers() {
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
            // The timeline is gone: no view binds T to it.
            #expect(!bindings.contains { $0.1 == "history.timeline" }, "\(scope)")
        }
        #expect(keys == [
            "history.ledger": "L", "history.dashboard": "D", "history.mindmap": "M", "history.standup": "U",
        ])
    }

    /// The timeline's filters live on in History, on the keys they had there; e unfolds every event.
    @Test func historyTakesTheTimelinesFiltersAndUnfoldsOnE() {
        let history = DefaultKeys.scoped["history"] ?? []
        for (key, command) in [
            ("c", "timeline.gone"), ("r", "timeline.repo"), ("w", "timeline.where"), ("K", "timeline.kind"),
            ("e", "history.events"), ("t", "history.outcome"),
        ] {
            #expect(history.contains { $0 == (key, command) }, "\(key) \(command)")
        }
        #expect(DefaultKeys.scoped["timeline"] == nil)
        // The old names keep working: gh opens Insights, view.history and history.timeline still exist.
        #expect(DefaultKeys.normal.contains { $0 == ("gh", "view.insights") })
        for name in ["history.list", "history.timeline", "view.history", "view.timeline", "view.insights"] {
            #expect(Commands.spec(name) != nil, "\(name)")
        }
    }
}
