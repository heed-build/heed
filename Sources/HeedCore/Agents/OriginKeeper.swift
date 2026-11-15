import Foundation

/// Keeps `OriginBook`'s file up to date for the hooks: projected from what heed holds whenever that changes, plus what
/// it asked GitHub after a hook found it did not know enough (`warm`). Off the main actor; writes only when the book
/// changed.
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

    /// What heed holds changed: the book is projected again, and written when it differs.
    public func update(_ snapshot: Snapshot) {
        self.snapshot = snapshot
        flush()
    }

    /// The book as it stands.
    public func book() -> OriginBook {
        guard let snapshot else { return OriginBook() }
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
