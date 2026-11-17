import Foundation
import Synchronization

/// Keeps `OriginBook`'s file up to date for the hooks: projected from what heed holds whenever that changes, plus what
/// it asked GitHub after a hook found it did not know enough (`warm`). Off the main actor; writes only when the book
/// changed. Snapshots are `submit`ted in the order heed takes them and applied in that order, a burst of them as one:
/// an older one never overwrites a newer one.
public actor OriginKeeper {
    public struct Snapshot: Sendable {
        public var viewer: String?
        public var checkouts: [(path: String, repo: Repo)]
        public var details: [PullDetail]
        public var issues: [Issue]

        public init(viewer: String?, checkouts: [(path: String, repo: Repo)], details: [PullDetail], issues: [Issue]) {
            self.viewer = viewer
            self.checkouts = checkouts
            self.details = details
            self.issues = issues
        }
    }

    public typealias Fetch = @Sendable (Repo, Int) async throws -> OriginBook.Item

    let path: String
    let authorship: @Sendable (PullRef) -> PullAuthorship?
    let clock: @Sendable () -> Date
    private var snapshot: Snapshot?
    private var fetched: [String: OriginBook.Item] = [:]
    private var asked: [String: Date] = [:]
    private var written: OriginBook?
    /// The generation of the snapshot applied last: an older one that arrives later is dropped.
    private var generation: UInt64 = 0
    /// Snapshots submitted and not applied yet: only the newest is kept.
    private nonisolated let pending = Latest<Snapshot>()
    /// How many times the book was projected: what a test checks.
    private(set) var projections = 0

    /// How long what heed asked GitHub counts as fresh; a hook that finds it older asks again for the next call.
    public static let fresh: TimeInterval = 10 * 60
    /// The soonest heed asks GitHub about the same PR or issue again.
    public static let cooldown: TimeInterval = 60

    public init(
        path: String,
        authorship: @escaping @Sendable (PullRef) -> PullAuthorship? = { PullTrustBook.shared.authorship($0) },
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.path = path
        self.authorship = authorship
        self.clock = clock
    }

    /// What heed holds changed, from where it took `snapshot` (the main actor): kept as the newest, and applied off
    /// it. Snapshots submitted while one is being applied are applied once, the newest of them.
    public nonisolated func submit(_ snapshot: Snapshot) {
        guard pending.offer(snapshot) else { return }
        Task.detached(priority: .utility) { await self.drain() }
    }

    /// Applies what was submitted, the newest only, until nothing is left.
    func drain() {
        while let (snapshot, generation) = pending.take() {
            update(snapshot, generation: generation)
        }
    }

    /// What heed holds changed: the book is projected again, and written when it differs.
    public func update(_ snapshot: Snapshot) {
        update(snapshot, generation: pending.stamp())
    }

    /// `snapshot`, taken as `generation`: nothing when a newer one was applied already.
    func update(_ snapshot: Snapshot, generation: UInt64) {
        guard generation > self.generation else { return }
        self.generation = generation
        self.snapshot = snapshot
        flush()
    }

    /// The book as it stands.
    public func book() -> OriginBook {
        guard let snapshot else { return OriginBook() }
        projections += 1
        return OriginBook.project(
            viewer: snapshot.viewer, checkouts: snapshot.checkouts, details: snapshot.details, issues: snapshot.issues,
            authorship: authorship, fetched: fetched
        )
    }

    /// Asks GitHub who wrote on `subject` when the hook found heed did not know, or knew only from a while ago; at
    /// most once a minute per PR or issue. True when it asked and the book changed.
    @discardableResult
    public func warm(_ subject: OriginSubject, hadNote: Bool, fetch: Fetch) async -> Bool {
        guard let key = subject.key, let slug = subject.repo, let number = subject.number else { return false }
        let now = clock()
        if hadNote, let at = fetched[key]?.fetchedAt, now.timeIntervalSince(at) < Self.fresh { return false }
        if let last = asked[key], now.timeIntervalSince(last) < Self.cooldown { return false }
        asked[key] = now
        let parts = slug.split(separator: "/").map(String.init)
        guard parts.count == 2, let item = try? await fetch(Repo(org: parts[0], name: parts[1]), number) else {
            return false
        }
        fetched[key] = item
        return flush()
    }

    @discardableResult
    private func flush() -> Bool {
        let book = book()
        guard book != written else { return false }
        do {
            try book.write(to: path)
            written = book
            return true
        } catch {
            return false
        }
    }
}

/// The newest of a stream of values, for one consumer that drains it: `offer` keeps the newest, numbered in the order
/// offered, and says when nothing is draining yet; `take` hands over the newest and, once there is none, ends the
/// drain, so the next `offer` starts one.
public final class Latest<Value: Sendable>: Sendable {
    private struct State {
        var value: Value?
        var generation: UInt64 = 0
        var draining = false
    }

    private let state = Mutex(State())

    public init() {}

    /// Keeps `value` as the newest; true when the caller should start draining.
    public func offer(_ value: Value) -> Bool {
        state.withLock { state in
            state.generation += 1
            state.value = value
            guard !state.draining else { return false }
            state.draining = true
            return true
        }
    }

    /// The newest value since the last `take`, and its number; nil, and the drain over, when there is none.
    public func take() -> (Value, UInt64)? {
        state.withLock { state in
            guard let value = state.value else {
                state.draining = false
                return nil
            }
            state.value = nil
            return (value, state.generation)
        }
    }

    /// The next number, for a value applied without being offered: it is newer than any offered before.
    public func stamp() -> UInt64 {
        state.withLock { state in
            state.generation += 1
            return state.generation
        }
    }
}
