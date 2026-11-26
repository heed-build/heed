import AppKit
import HeedCore

/// Browse's way out to GitHub and the clipboard (`gB`, `y`, `Y`), its right-click menus, and what a rail row's menu
/// acts on. What is decided is `HeedCore`'s (`BrowseOpen`, `ActionTargets`, `ContextMenus`); this runs it.
extension AppModel {
    /// The items a command acts on: the picks, the row right-clicked when it is not picked, else the one under the
    /// cursor, in the list's order.
    var browseActionItems: [BrowseItem] { BrowseOpen.items(actionIDs(.browse), in: browse.rows) }

    // MARK: Open and copy

    /// `gB` in Browse: the item on GitHub, or every picked one (more than five asks first). With a run in the reader it
    /// still opens the item.
    func browseOpenOnGitHub() {
        let items = browseActionItems
        guard !items.isEmpty else { return say("nothing to open") }
        if BrowseOpen.needsConfirm(items.count) {
            browse.bulk = BrowseBulkForm(opening: items, viewer: browseViewer)
            return
        }
        openOnGitHub(items)
    }

    func openOnGitHub(_ items: [BrowseItem]) {
        let urls = BrowseOpen.urls(items).compactMap(URL.init(string:))
        // The fake world and the tutor open nothing: a snapshot must not raise a browser.
        guard !isFixture, tutor == nil else {
            return say("fixture: would open \(items.count == 1 ? items[0].place : "\(items.count) items") on GitHub")
        }
        for url in urls {
            NSWorkspace.shared.open(url)
        }
        say(items.count == 1 ? "opened \(items[0].place) on GitHub" : "opened \(items.count) items on GitHub")
    }

    /// `y` (the link) and `Y` (org/repo#number): of every picked item, a line each.
    func browseCopy(link: Bool) {
        let items = browseActionItems
        guard !items.isEmpty else { return say("nothing to copy") }
        let text = link ? BrowseOpen.links(items) : BrowseOpen.references(items)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        say(BrowseOpen.copied(link ? "link" : "reference", items.count))
        // Yanked from a VISUAL range: the range ends, as `y` does elsewhere.
        if mode == .visual { clearPicks() }
    }

    // MARK: The rail

    /// The saved query a rail command acts on: the row right-clicked, else the one you are on.
    var browseRailQuery: SavedQuery? {
        if let id = commandTarget?.row(in: "browse.rail"), let key = Self.railKey(id, "query:") {
            return browse.queries.first { $0.id == key }
        }
        return browse.activeSaved
    }

    /// The org a rail command acts on: the row right-clicked, else the scope you are in.
    var browseRailOrg: String? {
        if let id = commandTarget?.row(in: "browse.rail"), let key = Self.railKey(id, "org:") { return key }
        return browse.scope?.owner
    }

    private static func railKey(_ id: String, _ prefix: String) -> String? {
        id.hasPrefix(prefix) ? String(id.dropFirst(prefix.count)) : nil
    }

    func browseOpenOrgOnGitHub() {
        guard let org = browseRailOrg
        else { return say("pick an org first: \(keyText(for: "browse.scope", in: "browse"))") }
        guard !isFixture, tutor == nil, let url = URL(string: "https://github.com/\(org)") else {
            return say("fixture: would open \(org) on GitHub")
        }
        NSWorkspace.shared.open(url)
        say("opened \(org) on GitHub")
    }

    func browseGoToOwnRepos() {
        guard let org = browseRailOrg
        else { return say("pick an org first: \(keyText(for: "browse.scope", in: "browse"))") }
        guard browse.checkouts.org(org)?.repos.isEmpty == false
        else { return say("no repo of \(org) is checked out here") }
        browse.go(to: .ownRepos(org))
        browseOpenedQuery()
    }

    func browseRefreshCount() {
        guard let saved = browseRailQuery
        else { return say("run a saved query first: \(keyText(for: "browse.query.next", in: "browse"))") }
        browse.refreshCount(of: saved)
        say("asking GitHub how many “\(saved.name)” has")
    }

    // MARK: Menus

    /// A right-click on a rail row names it, and hands the keyboard back to heed.
    func rightClickBrowseRail() -> Bool { rightClickNamed() }

    func browseQueryMenu(_ saved: SavedQuery) -> [MenuEntry] {
        let queries = browse.queries
        let index = queries.firstIndex { $0.id == saved.id }
        return ContextMenus.browseQuery(
            id: saved.id, name: saved.name, first: index == 0, last: index == queries.count - 1
        )
    }

    func browseOrgMenu(_ org: String) -> [MenuEntry] {
        let row = browse.railScopes.rows.first { $0.scope == .org(org) }
        return ContextMenus.browseOrg(
            name: org, checkedOut: browse.checkouts.org(org)?.repos.count ?? 0, expanded: row?.expanded ?? false
        )
    }

    /// A row of the Browse list: what the menu builds from is the item, heed's advice on it and what the picks are.
    func browseMenu(_ index: Int) -> [MenuEntry] {
        let rows = browse.rows
        guard rows.indices.contains(index) else { return [] }
        let item = rows[index]
        let picks = pickedIDs(.browse)
        var facts = ContextMenus.BrowseRowFacts(id: item.id, title: item.place)
        facts.picked = picks.contains(item.id)
        facts.count = facts.picked ? picks.count : 1
        facts.choices = browseVerbs(item).menuChoices(for: item)
        facts.hasRead = browse.reads[item.id] != nil
        facts.readBlocked = config.llm.enabled ? nil : "Model calls are off ([llm] enabled)"
        let acting = facts.count > 1 ? BrowseOpen.items(Array(picks), in: rows) : [item]
        facts.assignBlocked = browseViewer == nil ? "heed does not know your GitHub login yet" : nil
        facts.closeBlocked = acting.allSatisfy { $0.state != .open } ? "Already closed" : nil
        return ContextMenus.browseRow(facts)
    }
}
