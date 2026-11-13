import HeedCore

extension AppModel {
    /// A click on a tab of Insights' pane bar: opens that view, as its key does (a click on the one shown does
    /// nothing, where its key would go back to History).
    func showHistoryPane(_ pane: String, command: String) {
        guard clicksReachLists, pane != view.rawValue else { return }
        clickedOutsideTerminal()
        perform(CommandInvocation(name: command))
    }
}
