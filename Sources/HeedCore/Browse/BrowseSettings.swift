import Foundation

/// `[browse]`: how far back a Browse search reaches, when an org has too many repos to browse at once, and how
/// heed reads items.
public struct BrowseSettings: Equatable, Sendable {
    /// `runs`: what an agent run in Browse may do. Chat: it reads and answers, nothing that writes or posts is on
    /// offer.
    /// Full: Fix, Implement, Review and Get it green too (`BrowsePolicy` is a best-effort filter, not a sandbox).
    public enum Runs: String, CaseIterable, Equatable, Sendable {
        case chat, full
    }

    public static let defaultMaxAgeDays = 90
    public static let defaultReadAhead = 20
    public static let defaultMaxRuns = 3
    public static let defaultRefreshAfter = 60
    public var maxAgeDays: Int
    /// An org with more repos than this is offered a view of its own before everything (0 never asks).
    public var manyRepos: Int
    /// `reads`: when heed reads items (class, size, how agent-ready, a TL;DR) with a cheap model call. Ahead: the top
    /// `readAhead` rows of the view, and an item when the cursor rests on it; On open: only the item under the
    /// cursor; Off: only when asked (`U`).
    public var reads: AttentionSummaryMode
    /// How many rows from the top of the view are read ahead of time; 0 reads none ahead.
    public var readAhead: Int
    /// How many agent runs (Fix, Implement, Chat, Review) may work at once; 0: no limit.
    public var maxRuns: Int
    /// `runs`: Chat only (the default) or Full.
    public var runs: Runs
    /// `agent`: the agent Browse's runs use instead of `[helpers] agent`; nil: the helpers' choice.
    public var agent: String?
    /// `auto_refresh`: coming back to Browse (the view, the app, the window) asks GitHub for the view you are on again.
    public var autoRefresh: Bool
    /// `refresh_after`: seconds since the last answer before coming back asks again.
    public var refreshAfter: Int

    public init(
        maxAgeDays: Int = BrowseSettings.defaultMaxAgeDays, manyRepos: Int = BrowseGuidance.defaultThreshold,
        reads: AttentionSummaryMode = .ahead, readAhead: Int = BrowseSettings.defaultReadAhead,
        maxRuns: Int = BrowseSettings.defaultMaxRuns, runs: Runs = .chat, agent: String? = nil,
        autoRefresh: Bool = true,
        refreshAfter: Int = BrowseSettings.defaultRefreshAfter
    ) {
        self.autoRefresh = autoRefresh
        self.refreshAfter = refreshAfter
        self.maxRuns = maxRuns
        self.runs = runs
        self.agent = agent
        self.maxAgeDays = maxAgeDays
        self.manyRepos = manyRepos
        self.reads = reads
        self.readAhead = readAhead
    }
}
