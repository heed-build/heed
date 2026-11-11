import HeedCore

/// History's timeline (`history.timeline`): the glue its browser and view need from the model.
extension AppModel {
    /// The History entry of a timeline line's session: what `R` reopens from there.
    func timelineEntry(_ item: TimelineItem) -> HistoryEntry? {
        guard let id = item.session else { return nil }
        return history.first { $0.id == id }
    }
}

extension AppModel {
    /// A click on a tab of History's pane bar: opens that view, as its key does (a click on the one shown does
    /// nothing, where its key would go back to the list).
    func showHistoryPane(_ pane: String, command: String) {
        guard clicksReachLists, pane != view.rawValue else { return }
        clickedOutsideTerminal()
        perform(CommandInvocation(name: command))
    }
}
