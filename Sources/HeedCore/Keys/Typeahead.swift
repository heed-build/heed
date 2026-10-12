import Foundation

/// Type to narrow a list, move with ⌃n ⌃p (or the arrows), ↩ picks, ⎋ cancels. Used to pick any repo in Start work
/// and a worktree to import in Sessions. Matching is `FilterQuery`: every typed word must appear.
public struct Typeahead<Item: Sendable>: Sendable {
    public enum Outcome: Sendable {
        case handled
        case picked(Item)
        case cancel
    }

    public private(set) var query = ""
    public private(set) var cursor = 0
    public let items: [Item]
    private let fields: @Sendable (Item) -> [String]

    public init(items: [Item], fields: @escaping @Sendable (Item) -> [String]) {
        self.items = items
        self.fields = fields
    }

    public var matches: [Item] { items.filter { FilterQuery.matches(query, fields($0)) } }

    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case .escape:
            return .cancel
        case KeyStroke("CR"):
            let found = matches
            return found.indices.contains(cursor) ? .picked(found[cursor]) : .handled
        case KeyStroke("n", .control), KeyStroke("j", .control), KeyStroke("Down"):
            cursor = min(cursor + 1, max(matches.count - 1, 0))
        case KeyStroke("p", .control), KeyStroke("k", .control), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("BS"):
            if !query.isEmpty { query.removeLast() }
            cursor = 0
        case KeyStroke("w", .control), KeyStroke("BS", .option):
            query = FilterQuery.droppingLastWord(query)
            cursor = 0
        case KeyStroke("u", .control):
            query = ""
            cursor = 0
        case KeyStroke("Space"):
            query += " "
        default:
            guard !stroke.isNamed, stroke.modifiers.subtracting(.option).isEmpty else { return .handled }
            query += stroke.key
            cursor = 0
        }
        return .handled
    }
}
