import Foundation

/// What closing a run does with its worktree: removes it, or keeps it because it holds work nothing else has. The one
/// rule that stands between esc and `git worktree remove --force`.
public enum BrowseCloseDecision: Equatable, Sendable {
    case remove
    /// Something would be lost: commits no remote has, or changes not committed.
    case keep(unpushed: Int, dirty: Int)

    /// `dirty` is nil when git could not say: unknown is treated as "may hold work", never as clean.
    public static func decide(unpushed: Int, dirty: Int?) -> BrowseCloseDecision {
        if unpushed <= 0, dirty == 0 { return .remove }
        return .keep(unpushed: max(unpushed, 0), dirty: max(dirty ?? 1, 0))
    }
}

/// A run that was closed but whose worktree was kept, with why: the reader shows it until you push the work, keep it as
/// a session, discard it or dismiss the card.
public struct BrowseKept: Equatable, Sendable {
    public var unpushed: Int
    public var dirty: Int
    public var path: String
    /// When X was pressed once: the next X, soon after, deletes.
    public private(set) var armedAt: Date?

    public init(unpushed: Int, dirty: Int, path: String) {
        self.unpushed = unpushed
        self.dirty = dirty
        self.path = path
    }

    /// `3 commits are not pushed`, `2 files have changes that are not committed`, or both.
    public var what: String {
        var parts: [String] = []
        if unpushed > 0 { parts.append("\(unpushed) commit\(unpushed == 1 ? " is" : "s are") not pushed") }
        if dirty > 0 { parts.append("\(dirty) file\(dirty == 1 ? " has" : "s have") changes that are not committed") }
        if parts.isEmpty { parts.append("git could not say whether the work is safe") }
        return parts.joined(separator: " and ")
    }

    /// The card's sentence.
    public var message: String {
        "\(what.prefix(1).uppercased() + what.dropFirst()). Kept at \(path). Push it, keep it as a session (s), "
            + "or discard (X twice)."
    }

    /// How long the first X waits for the second.
    public static let discardWindow: TimeInterval = 8

    /// X: the first press arms, a second within `discardWindow` says to delete. Returns true when the worktree should
    /// go.
    public mutating func pressDiscard(at time: Date) -> Bool {
        if let armedAt, time.timeIntervalSince(armedAt) <= Self.discardWindow { return true }
        armedAt = time
        return false
    }
}
