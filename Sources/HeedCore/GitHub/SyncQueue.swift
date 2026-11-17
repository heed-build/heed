import Foundation

/// One ask to sync GitHub: what is due on the schedule (`scheduled`), parts asked for by name, and whether it is
/// forced (gr, :github.sync, signing in: every part, and the teams).
public struct SyncRequest: Hashable, Sendable {
    public var force: Bool
    public var parts: Set<GitHubPart>
    public var scheduled: Bool

    /// What `syncGitHub(force:parts:)` asks: named parts, or (none named) what the schedule says is due.
    public init(force: Bool, parts: Set<GitHubPart>) {
        self.force = force
        self.parts = parts
        scheduled = parts.isEmpty
    }

    /// Both asks in one: every part either named, the schedule's if either asked for it, forced if either was.
    public func merged(with other: SyncRequest) -> SyncRequest {
        var merged = self
        merged.force = force || other.force
        merged.parts = parts.union(other.parts)
        merged.scheduled = scheduled || other.scheduled
        return merged
    }

    /// The parts to fetch, given the schedule's `due(force)`.
    public func parts(due: (Bool) -> Set<GitHubPart>) -> Set<GitHubPart> {
        (scheduled ? due(force) : []).union(parts)
    }

    /// Teams are refreshed only by a forced sync of what is due, not by one that named its parts.
    public var refreshesTeams: Bool {
        force && scheduled
    }
}

/// One sync at a time, without dropping an ask: one made while a sync runs is kept (merged with any other kept) and
/// runs when that sync ends, so a forced refresh during a poll is not lost.
public struct SyncQueue: Hashable, Sendable {
    public private(set) var running = false
    public private(set) var pending: SyncRequest?

    public init() {}

    /// The request to run now, or nil when one is running and this one waits behind it.
    public mutating func ask(_ request: SyncRequest) -> SyncRequest? {
        guard running else {
            running = true
            return request
        }
        pending = pending.map { $0.merged(with: request) } ?? request
        return nil
    }

    /// The running sync ended: the request kept meanwhile runs next (still running), or nothing does.
    public mutating func finished() -> SyncRequest? {
        guard running else { return nil }
        guard let next = pending else {
            running = false
            return nil
        }
        pending = nil
        return next
    }
}
