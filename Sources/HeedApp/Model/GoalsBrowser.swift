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
        case overview, doc, board, reviewers
        /// Goals › Unassigned: heed's attach decisions, asks and suggested goals (`AttachBrowser`).
        case unassigned
        /// Who the goal needs (`PersonaBrowser`).
        case personas
        /// Stranger walks: an evaluator's walk, its friction log, and the lens picker.
        case evaluations
    }

    /// Where j and k move: the goals list, what belongs to the goal under the cursor, or (in Reviewers) its reviewers
    /// and the objections of the one under the cursor.
    enum Focus: String {
        case goals, links, reviewers, objections, personas
        /// The friction log of the evaluation under the lens picker.
        case friction
    }

    /// The spawn-a-reviewer panel: what the next reviewer is.
    struct Spawn: Equatable {
        var kind = ReviewerKind.implementation
        var instructions = ""
        var policy = ReviewPolicy.onChange
        /// nil: `[goals] reviewer_agent`, else the goal's sessions' agent.
        var agent: String?
        /// nil: `[goals.reviewers]` for the kind.
        var tier: ModelTier?
    }

    /// The new goal dialog: a title and what the goal is; a session it is made from goes on it.
    struct Form: Equatable {
        var title = ""
        var statement = ""
        var session: String?
        /// The tracker repo it mirrors to on GitHub (`org/name`), from `[goals] tracker` and the org's or repo's.
        var tracker = ""
        /// It mirrors from the start (the org's or repo's `goals_mirror`, else `[goals] mirror`).
        var mirror = false
    }

    private(set) var snapshot = GoalSnapshot.empty
    /// The goals the list shows, in order, narrowed by `/`.
    private(set) var rows: [HeedGoal] = []
    private(set) var cursor = 0
    private(set) var pane = Pane.overview {
        didSet { if pane != oldValue { paneChanged() } }
    }

    /// Attachment: decisions, asks, suggestions and rules (Unassigned).
    let attach = AttachBrowser()
    /// Personas: who the goal needs, their files and spawns.
    let personas = PersonaBrowser()
    /// The open sessions' and chats' ids and the running reviewers', for personas' coverage (set by the app).
    @ObservationIgnored var liveTargets: () -> Set<String> = { [] }
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
    /// Each goal's quality (profile, bars, reviewers, confidence), by goal id.
    private(set) var qualities: [String: GoalQuality] = [:]
    private(set) var reviewerCursor = 0
    private(set) var objectionCursor = 0
    var spawn = Spawn()
    /// Evaluations: the lens picked, and the cursor on its friction log.
    private(set) var evalLens = EvaluationLens.dxFirstRun
    private(set) var frictionCursor = 0
    /// What the goals' work touched at the last look, to tell when an evaluator's area changed.
    @ObservationIgnored var seenPaths: [String: Set<String>] = [:]
    /// The custom reviewer's instructions are being typed.
    var spawnTyping = false
    /// Reviewers due but held back by the day's budget, by goal: an Attention ask.
    private(set) var waiting: [String: [String]] = [:]
    /// Spawns asked for past a goal's cap (`heed goal item spawn`), by goal: an Attention ask until y or n.
    private(set) var heldSpawns: [String: [GoalHeldSpawn]] = [:]
    /// Spawned background runs still working (`run:<id>`), for the cap.
    @ObservationIgnored var spawnRuns: Set<String> = []
    /// What the goals' PRs and versions were at the last look, to tell what changed (`ReviewTrigger.from`).
    @ObservationIgnored var seenPulls: [String: [String: (head: String?, state: String)]] = [:]
    @ObservationIgnored var seenVersions: [String: Int] = [:]
    @ObservationIgnored var lastNightly: Date?
    /// Goals whose profile a model is deciding now.
    @ObservationIgnored var deciding: Set<String> = []
    /// `[goals.bars]`, from config.
    @ObservationIgnored var table = GoalBarTable.defaults
    /// The store did not open: Goals keeps nothing.
    private(set) var unavailable = false
    @ObservationIgnored private(set) var ops: GoalOps?
    @ObservationIgnored private var search = ""
    @ObservationIgnored private var fixtureVersions: [String: [GoalVersion]] = [:]
    /// Called after the goals changed (the agents' goal pointers follow).
    @ObservationIgnored var changed: () -> Void = {}
    /// Called when another pane shows (the key scope follows).
    @ObservationIgnored var paneChanged: () -> Void = {}
    /// Each goal's GitHub mirror, by goal id (`goal_mirrors`).
    private(set) var mirrors: [String: GoalMirrorState] = [:]
    /// The last read-only check of each tracker repo, by repo.
    private(set) var checks: [String: TrackerCheck] = [:]
    /// The mirror's sync, made on first use (never in fixtures).
    @ObservationIgnored var mirrorSync: GoalMirrorSync?
    /// When each mirrored goal was last read back.
    @ObservationIgnored var lastMirrorPoll: [String: Date] = [:]

    init(fixture: Bool) {
        guard fixture else { return }
        let fixtures = GoalMirrorFixtures.apply(to: GoalFixtures.all())
        let mirrors = GoalMirrorFixtures.states(fixtures)
        self.mirrors = mirrors
        let records = GoalQualityFixtures.all()
        let qualities = GoalQualityFixtures.qualities(records, goals: fixtures)
        self.qualities = qualities
        var snapshot = GoalFixtures.snapshot(fixtures)
        for index in snapshot.goals.indices {
            snapshot.goals[index].score = qualities[snapshot.goals[index].id]?.confidence?.value
        }
        GoalQualityFixtures.share(qualities, into: &snapshot)
        apply(snapshot)
        fixtureVersions = GoalFixtures.versions(fixtures)
        loadVersions()
        let decisions = GoalFixtures.attachDecisions()
        loadFixtureAttach(decisions)
        let personaRecords = PersonaFixtures.records()
        let personaFiles = PersonaFixtures.files()
        personas.loadFixture(records: personaRecords, files: personaFiles)
        if let ops = try? GoalOps.inMemory() {
            self.ops = ops
            Task {
                try? await ops.adopt(fixtures)
                try? await ops.adopt(decisions: decisions)
                try? await ops.setRules(GoalFixtures.attachRules)
                try? await ops.adopt(quality: records)
                try? await ops.adopt(personas: personaFiles, records: personaRecords)
                for (goal, state) in mirrors {
                    try? await ops.save(mirror: state, goal: goal)
                }
            }
        }
    }

    /// The app's store, once open; nil leaves Goals empty and says so.
    func attach(_ ops: GoalOps?) async {
        self.ops = ops
        unavailable = ops == nil
        guard let ops, let snapshot = try? await ops.snapshot() else { return }
        if let fresh = try? await ops.qualities(table: table) { qualities = fresh }
        apply(snapshot)
        loadVersions()
        if let fresh = try? await ops.mirrors() { mirrors = fresh }
        await reloadAttach()
        await personas.reload(ops)
    }

    // MARK: Mirror

    func mirror(of goal: String) -> GoalMirrorState { mirrors[goal] ?? .off }

    /// The selected goal's colleague changes on GitHub waiting for an answer.
    var asks: [MirrorAsk] { selected.map { mirror(of: $0.id).asks } ?? [] }

    func setCheck(_ check: TrackerCheck) {
        if checks[check.repo] != check { checks[check.repo] = check }
    }

    /// Reads the mirrors (and the goals, whose issue numbers a sync fills in) again.
    func reloadMirrors() {
        guard let ops else { return }
        Task {
            if let fresh = try? await ops.mirrors(), fresh != mirrors {
                mirrors = fresh
                changed()
            }
            if let snapshot = try? await ops.snapshot() { apply(snapshot) }
        }
    }

    // MARK: Quality

    var selectedQuality: GoalQuality? { selected.flatMap { qualities[$0.id] } }

    /// The selected goal's live reviewers, in the order they were spawned.
    var reviewers: [ReviewerState] { selectedQuality?.live ?? [] }

    var selectedReviewer: ReviewerState? {
        let reviewers = reviewers
        return reviewers.indices.contains(reviewerCursor) ? reviewers[reviewerCursor] : reviewers.first
    }

    /// The objections of the reviewer under the cursor, open first.
    var objections: [Objection] { selectedReviewer?.ordered ?? [] }

    var selectedObjection: Objection? {
        let objections = objections
        guard !objections.isEmpty else { return nil }
        return objections[min(objectionCursor, objections.count - 1)]
    }

    // MARK: Evaluations

    /// The selected goal's evaluations, one per lens.
    var evaluations: [Evaluation] { selectedQuality.map(Evaluation.all) ?? [] }

    var selectedEvaluation: Evaluation? { evaluations.first { $0.lens == evalLens } }

    /// The friction log of the picked lens: open first, then accepted, then fixed.
    var friction: [Evaluation.Row] { selectedEvaluation?.rows ?? [] }

    var selectedFriction: Evaluation.Row? {
        let rows = friction
        guard !rows.isEmpty else { return nil }
        return rows[min(frictionCursor, rows.count - 1)]
    }

    /// Picks a lens: `delta` steps through them, or a lens by name.
    func pickLens(_ lens: EvaluationLens) {
        guard lens != evalLens else { return }
        evalLens = lens
        frictionCursor = 0
        if focus == .friction, friction.isEmpty { focus = .goals }
    }

    func stepLens(_ delta: Int) {
        let all = EvaluationLens.allCases
        let index = all.firstIndex(of: evalLens) ?? 0
        pickLens(all[(index + delta + all.count) % all.count])
    }

    /// The lens a goal's evaluations open on: its first required one with a walk, else its first required one.
    private func defaultLens() {
        let evaluations = evaluations
        let lens = evaluations.first { $0.required && $0.walk != nil }?.lens
            ?? evaluations.first(where: \.required)?.lens ?? evalLens
        if lens != evalLens {
            evalLens = lens
            frictionCursor = 0
        }
    }

    /// `goal.evaluations`: the Evaluations pane, or back to the overview.
    func toggleEvaluations() {
        pane = pane == .evaluations ? .overview : .evaluations
        draft = nil
        if pane == .evaluations { defaultLens() }
        leftPane()
    }

    /// Goals whose reviewers have nowhere to run, and why: an Attention note.
    private(set) var blocked: [String: String] = [:]

    func setBlocked(_ goal: String, _ why: String?) {
        if blocked[goal] != why { blocked[goal] = why }
    }

    /// A spawn waits for you; the same item asked twice waits once.
    func hold(_ spawn: GoalHeldSpawn) {
        var held = heldSpawns[spawn.spawn.goal] ?? []
        held.removeAll { $0.spawn.item == spawn.spawn.item }
        held.append(spawn)
        heldSpawns[spawn.spawn.goal] = held
    }

    /// The spawns waiting on a goal, no longer waiting.
    func release(_ goal: String) -> [GoalHeldSpawn] {
        heldSpawns.removeValue(forKey: goal) ?? []
    }

    func setWaiting(_ goal: String, _ reviewers: [String]) {
        let fresh = reviewers.isEmpty ? nil : reviewers
        if waiting[goal] != fresh { waiting[goal] = fresh }
    }

    /// Puts the cursor on a reviewer of the selected goal.
    func point(reviewer id: String) {
        guard let index = reviewers.firstIndex(where: { $0.id == id }) else { return }
        reviewerCursor = index
        objectionCursor = 0
    }

    func setObjectionCursor(_ index: Int) {
        let count = objections.count
        guard count > 0 else { return }
        objectionCursor = min(max(index, 0), count - 1)
    }

    /// Reads every goal's quality again (after an operation, or a reviewer run ended).
    func reloadQualities() {
        guard let ops else { return }
        let table = table
        Task {
            guard let fresh = try? await ops.qualities(table: table), fresh != qualities else { return }
            qualities = fresh
            clampQualityCursors()
        }
    }

    private func clampQualityCursors() {
        reviewerCursor = min(reviewerCursor, max(reviewers.count - 1, 0))
        objectionCursor = min(objectionCursor, max(objections.count - 1, 0))
        frictionCursor = min(frictionCursor, max(friction.count - 1, 0))
        if focus == .friction, friction.isEmpty { focus = .goals }
        if focus == .objections, objections.isEmpty { focus = reviewers.isEmpty ? .goals : .reviewers }
        if focus == .reviewers, reviewers.isEmpty { focus = .goals }
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
        if pane == .unassigned { return attach.setCursor(index) }
        if focus == .personas { return personas.setCursor(index, count: personaRows.count) }
        if pane == .board {
            boardRow = min(max(index, 0), max(cards.count - 1, 0))
            return
        }
        if focus == .reviewers {
            let count = reviewers.count
            guard count > 0 else { return }
            let clamped = min(max(index, 0), count - 1)
            if clamped != reviewerCursor { objectionCursor = 0 }
            reviewerCursor = clamped
            return
        }
        if focus == .objections { return setObjectionCursor(index) }
        if focus == .friction {
            let count = friction.count
            guard count > 0 else { return }
            frictionCursor = min(max(index, 0), count - 1)
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
        reviewerCursor = 0
        objectionCursor = 0
        personas.setCursor(0, count: 1)
        personas.draft = nil
        frictionCursor = 0
        draft = nil
        loadVersions()
        if pane == .evaluations { defaultLens() }
    }

    // MARK: Items

    /// The selected goal's items, oldest first.
    var items: [GoalItem] { selected.map { snapshot.items(of: $0.id) } ?? [] }
    var evidence: [GoalEvidence] { selected.map { snapshot.evidence(of: $0.id) } ?? [] }
    /// The selected goal's changes to GOAL.md waiting for you, oldest first.
    var proposals: [GoalEdit] { selected.map { snapshot.proposals(of: $0.id) } ?? [] }

    /// The matrix's lens columns the goal needs, from its quality profile (every one until a profile is decided).
    var requiredLenses: Set<Stage> { ReviewEvidence.requiredStages(selectedQuality) }

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
        case .unassigned: "unassigned"
        case .reviewers: "goalreviewers"
        case .personas: "goalpersonas"
        case .evaluations: "goalevals"
        }
    }

    var rowCount: Int {
        if pane == .unassigned { return attach.rows.count }
        guard pane != .board else { return cards.count }
        return switch focus {
        case .goals: rows.count
        case .links: links.count
        case .reviewers: reviewers.count
        case .objections: objections.count
        case .personas: personaRows.count
        case .friction: friction.count
        }
    }

    var rowCursor: Int {
        if pane == .unassigned { return attach.cursor }
        guard pane != .board else { return boardRow }
        return switch focus {
        case .goals: cursor
        case .links: linkCursor
        case .reviewers: min(reviewerCursor, max(reviewers.count - 1, 0))
        case .objections: min(objectionCursor, max(objections.count - 1, 0))
        case .personas: min(personas.cursor, max(personaRows.count - 1, 0))
        case .friction: min(frictionCursor, max(friction.count - 1, 0))
        }
    }

    /// `goal.focus`: between the list and what is on the goal; in Reviewers, the list, the reviewers and the
    /// objections of the one under the cursor, in turn.
    func toggleFocus() {
        if pane == .reviewers {
            switch focus {
            case .goals, .links: focus = reviewers.isEmpty ? .goals : .reviewers
            case .reviewers: focus = objections.isEmpty ? .goals : .objections
            case .objections, .personas, .friction: focus = .goals
            }
            return
        }
        if pane == .personas {
            focus = focus == .personas || personaRows.isEmpty ? .goals : .personas
            return
        }
        if pane == .evaluations {
            focus = focus == .goals && !friction.isEmpty ? .friction : .goals
            return
        }
        focus = focus == .goals && !links.isEmpty ? .links : .goals
    }

    func setFocus(_ next: Focus) {
        switch next {
        case .links: focus = links.isEmpty ? .goals : .links
        case .reviewers: focus = reviewers.isEmpty ? .goals : .reviewers
        case .objections: focus = objections.isEmpty ? .goals : .objections
        case .personas: focus = personaRows.isEmpty ? .goals : .personas
        case .friction: focus = friction.isEmpty ? .goals : .friction
        case .goals: focus = .goals
        }
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
        pane = pane == .overview ? .doc : .overview
        if pane == .overview { draft = nil }
        leftPane()
    }

    /// `B`: the board, or back to the overview.
    func toggleBoard() {
        pane = pane == .board ? .overview : .board
        draft = nil
        if pane == .board { boardRow = min(boardRow, max(cards.count - 1, 0)) }
    }

    func show(_ next: Pane) {
        pane = next
        leftPane()
    }

    /// `goal.reviewers`: the Reviewers pane, or back to the overview.
    func toggleReviewers() {
        pane = pane == .reviewers ? .overview : .reviewers
        draft = nil
        if pane == .reviewers, !reviewers.isEmpty, focus != .goals { focus = .reviewers }
        leftPane()
    }

    /// `goal.personas`: the Personas pane, or back to the overview.
    func togglePersonas() {
        pane = pane == .personas ? .overview : .personas
        draft = nil
        personas.draft = nil
        if pane == .personas, !personaRows.isEmpty, focus != .goals { focus = .personas }
        leftPane()
    }

    /// Focus on reviewers or objections only holds while Reviewers shows, on personas while Personas does.
    private func leftPane() {
        if pane != .reviewers, focus == .reviewers || focus == .objections { focus = .goals }
        if pane != .personas, focus == .personas { focus = .goals }
        if pane != .evaluations, focus == .friction { focus = .goals }
        if pane == .reviewers || pane == .personas || pane == .evaluations, focus == .links { focus = .goals }
        if pane != .personas { personas.draft = nil }
    }

    // MARK: Personas

    /// The selected goal's personas, gaps first, with their coverage.
    var personaRows: [PersonaRow] {
        guard let goal = selected, let board = personas.boards[goal.id] else { return [] }
        return board.rows(
            files: personas.files[goal.id] ?? [:], items: items, evidence: evidence, links: snapshot.links(of: goal.id),
            reviewers: selectedQuality?.reviewers ?? [], live: liveTargets()
        )
    }

    var selectedPersona: PersonaRow? {
        let rows = personaRows
        return rows.isEmpty ? nil : rows[min(personas.cursor, rows.count - 1)]
    }

    /// Puts the cursor on a persona of the selected goal.
    func point(persona id: String) {
        guard let index = personaRows.firstIndex(where: { $0.id == id }) else { return }
        personas.setCursor(index, count: personaRows.count)
    }

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
            await reloadAttach()
            await personas.reload(ops)
            if let fresh = try? await ops.qualities(table: table), fresh != qualities {
                qualities = fresh
                clampQualityCursors()
                // The tutor and Attention follow the scores too.
                changed()
            }
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
