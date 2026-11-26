import Foundation

/// Which rows a command acts on, as a list view decides it: the right-clicked row alone when it is not picked (as
/// Finder does), else the picks, else the row under the cursor. Pure, so Attention, Browse and the menus share it.
public enum ActionTargets {
    public static func resolve(ids: [String], picked: Set<String>, cursor: Int, clicked: String?) -> [String] {
        if let clicked, !picked.contains(clicked) { return ids.contains(clicked) ? [clicked] : [] }
        if !picked.isEmpty { return ids.filter(picked.contains) }
        return ids.indices.contains(cursor) ? [ids[cursor]] : []
    }
}

/// `gB`, "Open on GitHub" and the copy commands for Browse items: which items, their pages, and when opening many
/// asks first.
public enum BrowseOpen {
    /// Opening more than this many pages at once asks first.
    public static let confirmAbove = 5

    public static func needsConfirm(_ count: Int) -> Bool { count > confirmAbove }

    /// The items for `ids`, in the list's order; an id that is not in the list is dropped.
    public static func items(_ ids: [String], in rows: [BrowseItem]) -> [BrowseItem] {
        let wanted = Set(ids)
        return rows.filter { wanted.contains($0.id) }
    }

    public static func urls(_ items: [BrowseItem]) -> [String] { items.map(\.url) }

    /// `org/repo#12`, one per line.
    public static func references(_ items: [BrowseItem]) -> String { items.map(\.place).joined(separator: "\n") }

    public static func links(_ items: [BrowseItem]) -> String { urls(items).joined(separator: "\n") }

    /// What the status line says after a copy.
    public static func copied(_ what: String, _ count: Int) -> String {
        count == 1 ? "copied the \(what)" : "copied \(count) \(what)s"
    }
}
