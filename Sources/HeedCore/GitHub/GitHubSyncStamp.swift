import Foundation

/// What every GitHub sync changes, whether GitHub had news or not: when it synced, what each source's last fetch
/// brought (and when), and the team-attribution bookkeeping (when each thread was last seen). Kept apart from the
/// data, so a sync that brought nothing new changes nothing the window draws from the data (`GitHubState.sameData`).
public struct GitHubSyncStamp: Hashable, Sendable {
    public var syncedAt: Date?
    public var fetches: GitHubFetches
    public var teamMentions: TeamMentionCache

    public init(
        syncedAt: Date? = nil, fetches: GitHubFetches = GitHubFetches(),
        teamMentions: TeamMentionCache = TeamMentionCache()
    ) {
        self.syncedAt = syncedAt
        self.fetches = fetches
        self.teamMentions = teamMentions
    }

    /// The newer of two stamps (by when they synced); `a` when neither is newer.
    public static func newer(_ a: GitHubSyncStamp, _ b: GitHubSyncStamp?) -> GitHubSyncStamp {
        guard let b, let bAt = b.syncedAt else { return a }
        guard let aAt = a.syncedAt else { return b }
        return bAt > aAt ? b : a
    }
}

public extension GitHubState {
    /// This state's sync stamp.
    var stamp: GitHubSyncStamp {
        GitHubSyncStamp(syncedAt: syncedAt, fetches: fetches, teamMentions: teamMentions)
    }

    /// This state with `stamp` in place of its own.
    func stamped(_ stamp: GitHubSyncStamp) -> GitHubState {
        var state = self
        state.syncedAt = stamp.syncedAt
        state.fetches = stamp.fetches
        state.teamMentions = stamp.teamMentions
        return state
    }

    /// This state with `stamp` in place of its own when `stamp` synced later: the newest of the two.
    func freshened(by stamp: GitHubSyncStamp?) -> GitHubState {
        stamped(GitHubSyncStamp.newer(self.stamp, stamp))
    }

    /// Whether the two hold the same data, whatever their sync stamps say.
    func sameData(as other: GitHubState) -> Bool {
        stamped(other.stamp) == other
    }
}
