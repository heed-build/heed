import Foundation
import HeedCore
import Observation

/// Goals (`view.goals`): the goals and what belongs to each, from `goals.sqlite` through `GoalOps`, the cursor on the
/// list and on the goal's sessions and chats, and which pane shows. Every change is a `GoalOps` operation run off the
/// main actor; the snapshot is read again after it. Fixtures (shots, the tutor) start from `GoalFixtures` and run the
/// same operations on an in-memory store that writes no files.
@MainActor
@Observable
final class GoalsBrowser {
    /// What the right of the view shows. Later parts add theirs (board, reviewers, personas, evaluations, unassigned)
    /// as cases here, each a pane of its own.
    enum Pane: String {
        case overview, doc, board
    }

    /// Where j and k move: the goals list, or what belongs to the goal under the cursor.
    enum Focus {
        case goals, links
    }

    /// The new goal dialog: a title and what the goal is; a session it is made from goes on it.
    struct Form: Equatable {
        var title = ""
        var statement = ""
        var session: String?
    }

    private(set) var snapshot = GoalSnapshot.empty
    /// The goals the list shows, in order, narrowed by `/`.
    private(set) var rows: [HeedGoal] = []
    private(set) var cursor = 0
    private(set) var pane = Pane.overview {
        didSet { if pane != oldValue { paneChanged() } }
    }

    private(set) var focus = Focus.goals
    private(set) var linkCursor = 0
    /// The selected goal's versions, newest first.
    private(set) var versions: [GoalVersion] = []
    /// Each session's or chat's goal, by session id.
    private(set) var bySession: [String: HeedGoal] = [:]
    /// GOAL.md as it is being edited, while it is.
    var draft: String?
    var form: Form?
    /// The board's cursor: a column, and a card in it.
    private(set) var boardColumn = Board.Column.toExplore
    private(set) var boardRow = 0
    /// Cards moved by hand since launch (the tutor watches it).
    private(set) var moves = 0
    /// Start work opened from an item: the session it starts goes on the goal, on that item.
    @ObservationIgnored var startingItem: GoalItem?
    /// Each goal's model calls today (planner, proposer, sharpener), for `GoalBudget`.
    @ObservationIgnored var modelRuns: [String: [Date]] = [:]
    /// The store did not open: Goals keeps nothing.
    private(set) var unavailable = false
    @ObservationIgnored private(set) var ops: GoalOps?
    @ObservationIgnored private var search = ""
    @ObservationIgnored private var fixtureVersions: [String: [GoalVersion]] = [:]
    /// Called after the goals changed (the agents' goal pointers follow).
    @ObservationIgnored var changed: () -> Void = {}
    /// Called when another pane shows (the key scope follows).
    @ObservationIgnored var paneChanged: () -> Void = {}

    init(fixture: Bool) {
        guard fixture else { return }
        let fixtures = GoalFixtures.all()
        apply(GoalFixtures.snapshot(fixtures))
        fixtureVersions = GoalFixtures.versions(fixtures)
        loadVersions()
        if let ops = try? GoalOps.inMemory() {
            self.ops = ops
            Task { try? await ops.adopt(fixtures) }
        }
    }

    /// The app's store, once open; nil leaves Goals empty and says so.
    func attach(_ ops: GoalOps?) async {
        self.ops = ops
        unavailable = ops == nil
        guard let ops, let snapshot = try? await ops.snapshot() else { return }
        apply(snapshot)
        loadVersions()
    }

    var files: GoalFiles { ops?.files ?? .fixture }

    var selected: HeedGoal? { rows.indices.contains(cursor) ? rows[cursor] : nil }
    var selectedDoc: GoalDoc? { selected.flatMap { snapshot.docs[$0.id] } }

    /// The sessions and chats on the selected goal, newest link first.
    var links: [GoalLink] {
        guard let goal = selected else { return [] }
        return snapshot.links(of: goal.id).filter { $0.kind == .session || $0.kind == .chat }
            .sorted { $0.at != $1.at ? $0.at > $1.at : $0.target < $1.target }
    }

    var selectedLink: GoalLink? {
        let links = links
        return focus == .links && links.indices.contains(linkCursor) ? links[linkCursor] : nil
    }

    // MARK: Moving

    func setCursor(_ index: Int) {
        if pane == .board {
            boardRow = min(max(index, 0), max(cards.count - 1, 0))
            return
        }
        if focus == .links {
            let count = links.count
            guard count > 0 else { return }
            linkCursor = min(max(index, 0), count - 1)
            return
        }
        guard !rows.isEmpty else { return }
        let clamped = min(max(index, 0), rows.count - 1)
        guard clamped != cursor else { return }
        cursor = clamped
        linkCursor = 0
        boardRow = 0
        draft = nil
        loadVersions()
    }

    var rowCount: Int { pane == .board ? cards.count : focus == .links ? links.count : rows.count }
    var rowCursor: Int { pane == .board ? boardRow : focus == .links ? linkCursor : cursor }

    // MARK: Items

    /// The selected goal's items, oldest first.
    var items: [GoalItem] { selected.map { snapshot.items(of: $0.id) } ?? [] }
    var evidence: [GoalEvidence] { selected.map { snapshot.evidence(of: $0.id) } ?? [] }
    /// The selected goal's changes to GOAL.md waiting for you, oldest first.
    var proposals: [GoalEdit] { selected.map { snapshot.proposals(of: $0.id) } ?? [] }

    /// The lenses the goal needs. Until goals have quality profiles, every one.
    var requiredLenses: Set<Stage> { Stage.lenses }

    var columns: [Board.Column: [GoalItem]] { Board.columns(items, evidence: evidence) }

    /// The cards in the column under the cursor.
    var cards: [GoalItem] { columns[boardColumn] ?? [] }

    /// The card under the board's cursor.
    var selectedCard: GoalItem? {
        let cards = cards
        return cards.indices.contains(boardRow) ? cards[boardRow] : nil
    }

    /// The board's cursor on another column (`h`/`l`), on its nearest card.
    func moveColumn(_ delta: Int) {
        guard let next = boardColumn.step(delta) else { return }
        boardColumn = next
        boardRow = min(boardRow, max(cards.count - 1, 0))
    }

    /// The board's cursor on a card (a click).
    func pointBoard(column: Board.Column, row: Int) {
        boardColumn = column
        boardRow = min(max(row, 0), max(cards.count - 1, 0))
    }

    /// After a card moved: the cursor follows it.
    func follow(_ item: String, to column: Board.Column) {
        boardColumn = column
        boardRow = cards.firstIndex { $0.id == item } ?? 0
        moves += 1
    }

    /// The key scope: the board and GOAL.md have keys of their own.
    var scope: String {
        switch pane {
        case .board: "goalboard"
        case .doc: "goaldoc"
        case .overview: "goals"
        }
    }

    /// `goal.focus`: between the list and what is on the goal.
    func toggleFocus() {
        focus = focus == .goals && !links.isEmpty ? .links : .goals
    }

    func setFocus(_ next: Focus) {
        focus = next == .links && links.isEmpty ? .goals : next
    }

    /// Puts the cursor on a goal (`id`) or on a session or chat on it (`kind:target`).
    func point(to id: String) {
        if let item = snapshot.item(id) {
            point(to: item.goal)
            if pane == .board {
                let column = Board.column(item, evidence: snapshot.evidence)
                boardColumn = column
                boardRow = cards.firstIndex { $0.id == id } ?? 0
            }
            return
        }
        if id.hasPrefix("edit:") {
            if let edit = snapshot.edits.first(where: { id == "edit:\($0.id ?? -1)" }) { point(to: edit.goal) }
            return
        }
        if let index = rows.firstIndex(where: { $0.id == id }) {
            focus = .goals
            setCursor(index)
            return
        }
        guard let link = snapshot.links.first(where: { $0.key == id }) else { return }
        point(to: link.goal)
        if let index = links.firstIndex(where: { $0.key == id }) {
            focus = .links
            linkCursor = index
        }
    }

    func togglePane() {
        pane = pane == .doc ? .overview : .doc
        if pane == .overview { draft = nil }
    }

    /// `B`: the board, or back to the overview.
    func toggleBoard() {
        pane = pane == .board ? .overview : .board
        draft = nil
        if pane == .board { boardRow = min(boardRow, max(cards.count - 1, 0)) }
    }

    func show(_ next: Pane) { pane = next }

    func setSearch(_ text: String) {
        guard text != search else { return }
        search = text
        refilter()
    }

    // MARK: Operations

    /// Runs one `GoalOps` operation off the main actor, then reads the goals again. `done` gets what it returned, or
    /// the error in words.
    func run<T: Sendable>(
        _ operation: @escaping @Sendable (GoalOps) async throws -> T,
        done: @escaping @MainActor (Result<T, Error>) -> Void = { _ in }
    ) {
        guard let ops else { return done(.failure(GoalOpError.unknownGoal("goals.sqlite did not open"))) }
        Task {
            let result: Result<T, Error>
            do { result = try await .success(operation(ops)) } catch { result = .failure(error) }
            if let snapshot = try? await ops.snapshot() { apply(snapshot) }
            if let goal = selected?.id, let versions = try? await ops.versions(of: goal) {
                fixtureVersions[goal] = versions
                if selected?.id == goal { self.versions = versions }
            }
            done(result)
        }
    }

    private func loadVersions() {
        guard let goal = selected?.id else {
            versions = []
            return
        }
        versions = fixtureVersions[goal] ?? []
        guard let ops else { return }
        Task {
            guard let fresh = try? await ops.versions(of: goal), !fresh.isEmpty else { return }
            fixtureVersions[goal] = fresh
            if selected?.id == goal, fresh != versions { versions = fresh }
        }
    }

    private func apply(_ fresh: GoalSnapshot) {
        guard fresh != snapshot else { return }
        snapshot = fresh
        var map: [String: HeedGoal] = [:]
        for link in fresh.links where link.kind == .session || link.kind == .chat {
            map[link.target] = fresh.goal(link.goal)
        }
        if map != bySession { bySession = map }
        refilter()
        changed()
    }

    /// Only what changed is written; the cursor stays on its goal.
    private func refilter() {
        let current = selected?.id
        let fresh = snapshot.ordered.filter { goal in
            FilterQuery.matches(search, [goal.title, goal.id, snapshot.docs[goal.id]?.goal ?? "", goal.status.rawValue])
        }
        if fresh != rows { rows = fresh }
        if let current, let index = rows.firstIndex(where: { $0.id == current }) {
            cursor = index
        } else {
            cursor = min(cursor, max(rows.count - 1, 0))
            loadVersions()
        }
        linkCursor = min(linkCursor, max(links.count - 1, 0))
        boardRow = min(boardRow, max(cards.count - 1, 0))
        if focus == .links, links.isEmpty { focus = .goals }
    }
}
