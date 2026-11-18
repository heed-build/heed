import Foundation

/// `[browse]`: how far back a Browse search reaches, when an org has too many repos to browse at once, and how
/// heed reads items.
public struct BrowseSettings: Equatable, Sendable {
    public static let defaultMaxAgeDays = 90
    public static let defaultReadAhead = 20
    public var maxAgeDays: Int
    /// An org with more repos than this is offered a view of its own before everything (0 never asks).
    public var manyRepos: Int
    /// `reads`: when heed reads items (class, size, how agent-ready, a TL;DR) with a cheap model call. Ahead: the top
    /// `readAhead` rows of the view, and an item when the cursor rests on it; On open: only the item under the
    /// cursor; Off: only when asked (`U`).
    public var reads: AttentionSummaryMode
    /// How many rows from the top of the view are read ahead of time; 0 reads none ahead.
    public var readAhead: Int

    public init(
        maxAgeDays: Int = BrowseSettings.defaultMaxAgeDays, manyRepos: Int = BrowseGuidance.defaultThreshold,
        reads: AttentionSummaryMode = .ahead, readAhead: Int = BrowseSettings.defaultReadAhead
    ) {
        self.maxAgeDays = maxAgeDays
        self.manyRepos = manyRepos
        self.reads = reads
        self.readAhead = readAhead
    }
}
