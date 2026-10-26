import Foundation

/// Where a goal's files are: `<root>/<slug>/GOAL.md` (the current version, for agents and editors) and `links.json`
/// (what belongs to the goal, exported). `root` is `~/Library/Application Support/Heed/goals` for the app, a temporary
/// folder in tests, and `/Users/you/…` with `writes` off for fixtures and shots, which never touch the disk.
public struct GoalFiles: Hashable, Sendable {
    public var root: URL
    public var writes: Bool

    public init(root: URL, writes: Bool = true) {
        self.root = root
        self.writes = writes
    }

    /// `~/Library/Application Support/Heed/goals`.
    public static func `default`() -> GoalFiles {
        GoalFiles(
            root: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Heed/goals")
        )
    }

    /// What fixtures and shots show: the default place under a made-up home; nothing is written.
    public static let fixture = GoalFiles(
        root: URL(fileURLWithPath: "/Users/you/Library/Application Support/Heed/goals"), writes: false
    )

    public func folder(_ goal: String) -> URL { root.appendingPathComponent(goal, isDirectory: true) }
    public func doc(_ goal: String) -> URL { folder(goal).appendingPathComponent("GOAL.md") }
    public func links(_ goal: String) -> URL { folder(goal).appendingPathComponent("links.json") }

    func write(doc text: String, goal: String) throws {
        guard writes else { return }
        try FileManager.default.createDirectory(at: folder(goal), withIntermediateDirectories: true)
        try text.write(to: doc(goal), atomically: true, encoding: .utf8)
    }

    func write(links: [GoalLink], goal: String) throws {
        guard writes else { return }
        try FileManager.default.createDirectory(at: folder(goal), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(links.sorted { $0.key < $1.key }).write(to: self.links(goal), options: .atomic)
    }
}

/// Why a goal operation did nothing.
public enum GoalOpError: Error, Equatable, CustomStringConvertible {
    case noTitle
    case unknownGoal(String)
    case unknownVersion(String, Int)

    public var description: String {
        switch self {
        case .noTitle: "a goal needs a title"
        case let .unknownGoal(id): "no goal \(id)"
        case let .unknownVersion(id, number): "\(id) has no version \(number)"
        }
    }
}

/// Every change to goals goes through here, whoever asks: the Goals view and its keys now, the `heed goal` commands
/// over the control socket later. Each operation writes the store, then the goal's files, and returns what changed;
/// the caller reads `snapshot()` to redraw. Runs off the main actor, one operation at a time.
public actor GoalOps {
    private let store: GoalStore
    public nonisolated let files: GoalFiles

    /// `path` is `goals.sqlite`; `":memory:"` keeps nothing.
    public init(path: String, files: GoalFiles) throws {
        store = try GoalStore(path: path)
        self.files = files
    }

    /// Opens `goals.sqlite` beside the domain file and `goals/` beside it; nil (logged) when it cannot be opened.
    public static func open(at file: URL, files: GoalFiles) async -> GoalOps? {
        await Task.detached(priority: .userInitiated) {
            do {
                return try GoalOps(path: file.path, files: files)
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); Goals keeps nothing")
                return nil
            }
        }.value
    }

    /// An in-memory store with `files` not written: fixtures, shots and the tutor.
    public static func inMemory(files: GoalFiles = .fixture) throws -> GoalOps {
        try GoalOps(path: ":memory:", files: files)
    }

    // MARK: Reading

    public func snapshot() throws -> GoalSnapshot { try store.snapshot() }

    public func versions(of goal: String) throws -> [GoalVersion] { try store.versions(of: goal) }

    /// A goal's current `GOAL.md` text.
    public func text(of goal: String) throws -> String {
        guard let current = try store.goal(goal) else { throw GoalOpError.unknownGoal(goal) }
        return try store.version(of: goal, number: current.version)?.text ?? ""
    }

    // MARK: Goals

    /// A new goal from a title and a statement: its slug, its first `GOAL.md` (v1) and its folder.
    @discardableResult
    public func create(title: String, statement: String, now: Date) throws -> HeedGoal {
        let title = GoalDoc.oneLine(title)
        guard !title.isEmpty else { throw GoalOpError.noTitle }
        let taken = try Set(store.goals().map(\.id))
        let goal = HeedGoal(id: GoalSlug.make(title, taken: taken), title: title, createdAt: now)
        let text = GoalDoc.new(title: title, statement: statement).render()
        try store.insert(goal, first: GoalVersion(goal: goal.id, number: 1, at: now, text: text, note: "created"))
        try files.write(doc: text, goal: goal.id)
        try files.write(links: [], goal: goal.id)
        return goal
    }

    /// Saves `text` as the goal's next version (its `# ` line renames the goal); nil when nothing changed.
    @discardableResult
    public func save(
        goal id: String, text: String, note: String = "edited", author: GoalVersion.Author = .you, now: Date
    ) throws -> GoalVersion? {
        guard try store.goal(id) != nil else { throw GoalOpError.unknownGoal(id) }
        let normalized = text.hasSuffix("\n") ? text : text + "\n"
        guard try self.text(of: id) != normalized else { return nil }
        let title = GoalDoc.parse(normalized).title
        let current = try store.goal(id)?.title ?? id
        let version = try store.addVersion(
            goal: id, text: normalized, note: note, author: author, title: title.isEmpty ? current : title, at: now
        )
        try files.write(doc: normalized, goal: id)
        return version
    }

    /// Saves a parsed doc as the next version.
    @discardableResult
    public func save(goal id: String, doc: GoalDoc, note: String, author: GoalVersion.Author = .you, now: Date)
        throws -> GoalVersion?
    {
        try save(goal: id, text: doc.render(), note: note, author: author, now: now)
    }

    /// Makes an old version current again, as a new version: nothing is lost by restoring.
    @discardableResult
    public func restore(goal id: String, version number: Int, now: Date) throws -> GoalVersion? {
        guard let old = try store.version(of: id, number: number) else {
            throw GoalOpError.unknownVersion(id, number)
        }
        return try save(goal: id, text: old.text, note: "restored v\(number)", author: .restore, now: now)
    }

    public func setStatus(goal id: String, _ status: HeedGoal.Status, now: Date) throws {
        guard var goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        guard goal.status != status else { return }
        goal.status = status
        goal.updatedAt = now
        try store.update(goal)
    }

    /// Archives an active or done goal, and brings an archived one back.
    public func archive(goal id: String, now: Date) throws -> HeedGoal.Status {
        guard let goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        let status: HeedGoal.Status = goal.status == .archived ? .active : .archived
        try setStatus(goal: id, status, now: now)
        return status
    }

    // MARK: Links

    /// Puts a session, chat, PR or run on a goal; from another goal it moves. The goal it was on, if any.
    @discardableResult
    public func attach(_ link: GoalLink) throws -> String? {
        guard try store.goal(link.goal) != nil else { throw GoalOpError.unknownGoal(link.goal) }
        let previous = try store.unlink(kind: link.kind, target: link.target)
        try store.link(link)
        try exportLinks(of: [link.goal, previous?.goal].compactMap(\.self))
        return previous?.goal == link.goal ? nil : previous?.goal
    }

    /// Takes a thing off its goal; the goal it was on.
    @discardableResult
    public func detach(kind: GoalLink.Kind, target: String) throws -> String? {
        let removed = try store.unlink(kind: kind, target: target)
        if let goal = removed?.goal { try exportLinks(of: [goal]) }
        return removed?.goal
    }

    private func exportLinks(of goals: [String]) throws {
        guard files.writes else { return }
        let all = try store.links()
        for goal in Set(goals) {
            try files.write(links: all.filter { $0.goal == goal }, goal: goal)
        }
    }

    // MARK: Fixtures

    /// Lays down `GoalFixtures`: goals with every version, and their links.
    public func adopt(_ fixtures: [GoalFixture]) throws {
        for fixture in fixtures {
            guard let first = fixture.versions.first else { continue }
            var goal = fixture.goal
            goal.version = 1
            try store.insert(goal, first: first)
            for version in fixture.versions.dropFirst() {
                _ = try store.addVersion(
                    goal: goal.id, text: version.text, note: version.note, author: version.author,
                    title: GoalDoc.parse(version.text).title, at: version.at
                )
            }
            goal.version = fixture.versions.count
            goal.updatedAt = fixture.versions.last?.at ?? goal.createdAt
            try store.update(goal)
            for link in fixture.links {
                try store.link(link)
            }
        }
    }
}

/// A goal as fixtures make it: the goal, its `GOAL.md` versions oldest first, and what belongs to it.
public struct GoalFixture: Sendable {
    public var goal: HeedGoal
    public var versions: [GoalVersion]
    public var links: [GoalLink]

    public init(goal: HeedGoal, versions: [GoalVersion], links: [GoalLink]) {
        self.goal = goal
        self.versions = versions
        self.links = links
    }
}
