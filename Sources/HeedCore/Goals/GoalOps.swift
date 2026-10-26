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
    case unknownItem(String)
    case unknownEdit(Int64)
    /// The edit is not in the state the operation needs (accepting one already applied).
    case editNot(GoalEdit.State, Int64)

    public var description: String {
        switch self {
        case .noTitle: "a goal needs a title"
        case let .unknownGoal(id): "no goal \(id)"
        case let .unknownVersion(id, number): "\(id) has no version \(number)"
        case let .unknownItem(id): "no item \(id)"
        case let .unknownEdit(id): "no edit \(id)"
        case let .editNot(state, id): "edit \(id) is not \(state.rawValue)"
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

    // MARK: Items

    /// A new item on a goal; its id is the goal's slug and one made from the title, unique in the goal.
    @discardableResult
    public func addItem(
        goal: String, title: String, kind: GoalItem.Kind = .work, source: GoalItem.Source, parent: String? = nil,
        links: [GoalItem.Link] = [], confidence: Double? = nil, reason: String? = nil, now: Date
    ) throws -> GoalItem {
        let title = GoalDoc.oneLine(title)
        guard !title.isEmpty else { throw GoalOpError.noTitle }
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        if let parent, try store.item(parent) == nil { throw GoalOpError.unknownItem(parent) }
        let taken = try Set(store.items().filter { $0.goal == goal }.map(\.slug))
        let item = GoalItem(
            id: "\(goal)/\(GoalSlug.make(title, taken: taken))", goal: goal, title: title, kind: kind, source: source,
            parent: parent, links: links, confidence: confidence, reason: reason, createdAt: now
        )
        try store.save(item)
        return item
    }

    private func item(_ id: String) throws -> GoalItem {
        guard let item = try store.item(id) else { throw GoalOpError.unknownItem(id) }
        return item
    }

    /// Puts an item's card in a column by hand; it stays there until newer evidence about it moves it.
    @discardableResult
    public func move(item id: String, to column: Board.Column, now: Date) throws -> GoalItem {
        var item = try item(id)
        item.placement = GoalItem.Placement(column, at: now)
        try store.save(item)
        return item
    }

    /// Done by hand: the card in Done.
    @discardableResult
    public func done(item id: String, now: Date) throws -> GoalItem {
        try move(item: id, to: .done, now: now)
    }

    /// Splits an item into smaller ones, each with it as their parent; the new items.
    @discardableResult
    public func split(
        item id: String, into titles: [String], source: GoalItem.Source = .you, now: Date
    ) throws -> [GoalItem] {
        let parent = try item(id)
        return try titles.map { title in
            try addItem(
                goal: parent.goal, title: title, kind: parent.kind, source: source, parent: parent.id,
                reason: "split from \(parent.title)", now: now
            )
        }
    }

    /// Adds a link to an item (a session working on it, its branch, its PR); a link it has already is kept once.
    @discardableResult
    public func link(item id: String, _ link: GoalItem.Link) throws -> GoalItem {
        var item = try item(id)
        guard !item.links.contains(link) else { return item }
        item.links.append(link)
        try store.save(item)
        return item
    }

    // MARK: Evidence

    /// Records evidence about a goal or one of its items; nil when it says what the newest of its kind already says.
    /// Reviewers, evaluations and the GitHub mirror add theirs here too.
    @discardableResult
    public func addEvidence(_ evidence: GoalEvidence) throws -> GoalEvidence? {
        guard try store.goal(evidence.goal) != nil else { throw GoalOpError.unknownGoal(evidence.goal) }
        if let id = evidence.item, try store.item(id) == nil { throw GoalOpError.unknownItem(id) }
        let latest = try store.evidence()
            .filter { $0.goal == evidence.goal && $0.item == evidence.item && $0.kind == evidence.kind }
            .max { Stages.newer($1, than: $0) }
        if let latest, latest.same(as: evidence) { return nil }
        var stored = evidence
        stored.id = try store.add(evidence)
        return stored
    }

    /// A PR on a goal's work: its item (found by the PR, or made for it, source `pr`) gets the PR linked and the
    /// evidence that is new. One step, so two scans at once cannot make the item twice. The item's id.
    @discardableResult
    public func recordPull(_ finding: GoalPulls.Finding, evidence: [GoalEvidence], now: Date) throws -> String? {
        guard let goal = evidence.first?.goal ?? finding.evidence.first?.goal else { return nil }
        let ref = finding.ref.description
        var id = finding.item
        if id == nil {
            id = try store.items().first { $0.goal == goal && $0.linked(.pr).contains(ref) }?.id
        }
        if id == nil {
            id = try addItem(
                goal: goal, title: finding.title, source: .pr,
                links: [GoalItem.Link(.pr, ref)] + (finding.session.map { [GoalItem.Link(.session, $0)] } ?? []),
                reason: "a PR on the goal's work", now: now
            ).id
        }
        guard let id else { return nil }
        try link(item: id, GoalItem.Link(.pr, ref))
        for var entry in evidence {
            entry.item = id
            try addEvidence(entry)
        }
        return id
    }

    // MARK: GOAL.md edits

    /// An edit the work suggests. Record edits apply at once, as a new version by heed (undo takes them back out);
    /// scope edits wait for you, and one waiting already with the same change is not asked twice. Kind is decided
    /// by `GoalEdits.classify`: an edit can be made to wait, never to skip waiting.
    @discardableResult
    public func propose(_ edit: GoalEdit, now: Date) throws -> GoalEdit {
        guard try store.goal(edit.goal) != nil else { throw GoalOpError.unknownGoal(edit.goal) }
        var edit = edit
        edit.id = nil
        edit.kind = edit.kind == .record && GoalEdits.classify(edit) == .record ? .record : .scope
        edit.state = .proposed
        edit.version = nil
        let doc = try GoalDoc.parse(text(of: edit.goal))
        guard GoalEdits.apply(edit, to: doc) != nil else {
            edit.state = .moot
            edit.id = try store.save(edit)
            return edit
        }
        if edit.kind == .scope {
            if let waiting = try store.edits().first(where: {
                $0.goal == edit.goal && $0.state == .proposed && $0.section == edit.section && $0.op == edit.op
                    && GoalEdits.same($0.text, edit.text) && $0.target.map(GoalEdits.key) == edit.target
                    .map(GoalEdits.key)
            }) { return waiting }
            edit.id = try store.save(edit)
            return edit
        }
        edit.id = try store.save(edit)
        return try applyEdit(edit, now: now)
    }

    /// Yes to a waiting edit, with its text changed first when `text` is given.
    @discardableResult
    public func accept(edit id: Int64, text: String? = nil, now: Date) throws -> GoalEdit {
        var edit = try waiting(id)
        if let text = text.map(GoalDoc.oneLine), !text.isEmpty { edit.text = text }
        return try applyEdit(edit, now: now)
    }

    /// No to a waiting edit.
    @discardableResult
    public func reject(edit id: Int64, now _: Date) throws -> GoalEdit {
        var edit = try waiting(id)
        edit.state = .rejected
        try store.save(edit)
        return edit
    }

    /// Takes an applied edit back out of GOAL.md, as a new version.
    @discardableResult
    public func undo(edit id: Int64, now: Date) throws -> GoalEdit {
        guard var edit = try store.edit(id) else { throw GoalOpError.unknownEdit(id) }
        guard edit.state == .applied else { throw GoalOpError.editNot(.applied, id) }
        let doc = try GoalDoc.parse(text(of: edit.goal))
        if let reverted = GoalEdits.revert(edit, in: doc) {
            try save(goal: edit.goal, doc: reverted, note: "undid " + GoalEdits.note(edit), author: .heed, now: now)
        }
        edit.state = .undone
        try store.save(edit)
        return edit
    }

    private func waiting(_ id: Int64) throws -> GoalEdit {
        guard let edit = try store.edit(id) else { throw GoalOpError.unknownEdit(id) }
        guard edit.state == .proposed else { throw GoalOpError.editNot(.proposed, id) }
        return edit
    }

    private func applyEdit(_ edit: GoalEdit, now: Date) throws -> GoalEdit {
        var edit = edit
        let doc = try GoalDoc.parse(text(of: edit.goal))
        if let changed = GoalEdits.apply(edit, to: doc),
           let version = try save(
               goal: edit.goal, doc: changed, note: GoalEdits.note(edit),
               author: edit.kind == .record ? .heed : .you, now: now
           )
        {
            edit.state = .applied
            edit.version = version.number
        } else {
            edit.state = .moot
        }
        try store.save(edit)
        return edit
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
            for item in fixture.items {
                try store.save(item)
            }
            for entry in fixture.evidence {
                _ = try store.add(entry)
            }
            for edit in fixture.edits {
                try store.save(edit)
            }
        }
    }
}

/// A goal as fixtures make it: the goal, its `GOAL.md` versions oldest first, and what belongs to it.
public struct GoalFixture: Sendable {
    public var goal: HeedGoal
    public var versions: [GoalVersion]
    public var links: [GoalLink]
    public var items: [GoalItem]
    public var evidence: [GoalEvidence]
    public var edits: [GoalEdit]

    public init(
        goal: HeedGoal, versions: [GoalVersion], links: [GoalLink], items: [GoalItem] = [],
        evidence: [GoalEvidence] = [], edits: [GoalEdit] = []
    ) {
        self.goal = goal
        self.versions = versions
        self.links = links
        self.items = items
        self.evidence = evidence
        self.edits = edits
    }
}
