import HeedCore

/// The menu bar's facts, read from the model: the selected session and the PR in front as their right-click menus see
/// them (`sessionFacts`, `pullFacts`), and where you are. `MenuBar` builds the menus from them.
extension AppModel {
    func menuBarFacts() -> MenuBar.Facts {
        var facts = MenuBar.Facts()
        facts.session = currentSession.flatMap { sessionFacts($0.id) }
        facts.pull = pullInFront.map { pullFacts($0.ref, place: $0.place) }
        facts.view = view.rawValue
        facts.scope = engine.scope ?? view.rawValue
        facts.pinned = list.pins.map(\.title)
        facts.tabs = currentTabs.count
        facts.panes = currentTab?.tree.panes.count ?? 0
        facts.zoomed = currentTab?.zoomed ?? false
        facts.filtered = !(filters[view] ?? "").isEmpty
        facts.sidebarShown = !sidebarCollapsed
        facts.inspectorShown = inspectorVisible
        facts.tutor = tutor != nil
        facts.hunchDownloading = !hunch.downloading.isEmpty
        facts.hunchReady = hunch.status.modelReady
        return facts
    }

    /// The PR the pilot's keys act on alone: the one open in the PR overlay or reader, else the PRs or Watch row under
    /// the cursor. Nil elsewhere, where they act on the selected session's PRs.
    private var pullInFront: (ref: PullRef, place: ContextMenus.Place)? {
        if let ref = feedbackPull { return (ref, .inspector) }
        let index = itemCursor[view] ?? 0
        switch view {
        case .prs:
            let rows = pullRows
            return rows.indices.contains(index) ? (rows[index].ref, .prs) : nil
        case .watch:
            let rows = pilotRows
            return rows.indices.contains(index) ? (rows[index].ref, .watch) : nil
        default:
            return nil
        }
    }
}
