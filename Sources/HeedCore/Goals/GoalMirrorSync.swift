import Foundation

/// `goal_mirrors`: each goal's `GoalMirrorState`, one JSON row per goal.
public extension GoalStore {
    func mirror(of goal: String) throws -> GoalMirrorState? {
        try database.query("SELECT data FROM goal_mirrors WHERE goal = ?", [.text(goal)]) { row in
            row[0].text.flatMap { try? Self.mirrorDecoder.decode(GoalMirrorState.self, from: Data($0.utf8)) }
        }.first ?? nil
    }

    func mirrors() throws -> [String: GoalMirrorState] {
        let rows = try database.query("SELECT goal, data FROM goal_mirrors") { row in
            (row[0].text ?? "", row[1].text.flatMap {
                try? Self.mirrorDecoder.decode(GoalMirrorState.self, from: Data($0.utf8))
            })
        }
        return Dictionary(rows.compactMap { goal, state in state.map { (goal, $0) } }) { _, last in last }
    }

    func save(mirror state: GoalMirrorState, goal: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try database.run(
            "INSERT OR REPLACE INTO goal_mirrors (goal, data) VALUES (?, ?)",
            [.text(goal), .text(String(decoding: encoder.encode(state), as: UTF8.self))]
        )
    }

    private static var mirrorDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }
}

/// Why the mirror did nothing.
public enum GoalMirrorError: Error, Equatable, CustomStringConvertible {
    case noTracker(String)

    public var description: String {
        switch self {
        case let .noTracker(goal): "\(goal) has no tracker repo yet: goal.tracker org/name sets one"
        }
    }
}

/// The mirror's operations on goals: its state, the tracker, turning it on and off, and answering an ask. Like every
/// goal change, through `GoalOps`.
public extension GoalOps {
    func mirror(of goal: String) throws -> GoalMirrorState { try store.mirror(of: goal) ?? .off }

    func mirrors() throws -> [String: GoalMirrorState] { try store.mirrors() }

    func save(mirror state: GoalMirrorState, goal: String) throws {
        try store.save(mirror: state, goal: goal)
    }

    /// Changes a goal's mirror state in one step (no other operation in between), then puts the issue numbers it
    /// holds where the views read them.
    func updateMirror(goal id: String, _ change: (inout GoalMirrorState) -> Void) throws {
        var state = try mirror(of: id)
        change(&state)
        try store.save(mirror: state, goal: id)
        try recordNumbers(goal: id, state: state)
    }

    /// Where the goal mirrors to. A different repo starts over there: the issues made in the old one stay as they are.
    @discardableResult
    func setTracker(goal id: String, repo: String?, now: Date) throws -> HeedGoal {
        guard var goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        let repo = repo.flatMap(TrackerCheck.slug)
        guard goal.tracker?.repo != repo else { return goal }
        goal.tracker = repo.map { GoalTracker(repo: $0) }
        goal.updatedAt = now
        try store.update(goal)
        for var item in try store.items() where item.goal == id && item.issueNumber != nil {
            item.issueNumber = nil
            try store.save(item)
        }
        var state = try mirror(of: id)
        state = GoalMirrorState(on: state.on && repo != nil, repo: repo)
        try store.save(mirror: state, goal: id)
        return goal
    }

    /// Mirroring on or off. On is the one confirmation: from then on heed writes on its own. Off leaves the issues as
    /// they are and writes nothing more.
    @discardableResult
    func setMirror(goal id: String, on: Bool) throws -> GoalMirrorState {
        guard let goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        var state = try mirror(of: id)
        guard state.on != on else { return state }
        guard !on || goal.tracker != nil else { throw GoalMirrorError.noTracker(id) }
        state.on = on
        state.repo = goal.tracker?.repo
        state.error = nil
        try store.save(mirror: state, goal: id)
        return state
    }

    /// The issue numbers a sync made or found, where the views read them: the goal's meta issue, the items' sub-issues.
    func recordNumbers(goal id: String, state: GoalMirrorState) throws {
        if var goal = try store.goal(id), let repo = goal.tracker?.repo, repo == state.repo,
           goal.tracker?.metaIssue != state.meta?.number
        {
            goal.tracker = GoalTracker(repo: repo, metaIssue: state.meta?.number)
            try store.update(goal)
        }
        for (itemID, issue) in state.items {
            guard var item = try store.item(itemID), item.issueNumber != issue.number else { continue }
            item.issueNumber = issue.number
            try store.save(item)
        }
    }

    /// Yes or no to a colleague's change on GitHub. Yes: the item follows (Done, or back to Working). No: heed puts
    /// the sub-issue back the way heed has it, on the next sync.
    @discardableResult
    func answer(ask item: String, yes: Bool, now: Date) throws -> MirrorAsk? {
        guard let found = try store.item(item) else { throw GoalOpError.unknownItem(item) }
        var state = try mirror(of: found.goal)
        guard let ask = state.ask(for: item) else { return nil }
        state.asks.removeAll { $0.item == item }
        try store.save(mirror: state, goal: found.goal)
        if yes { try move(item: item, to: ask.kind == .done ? .done : .working, now: now) }
        return ask
    }
}

/// The mirror's limits: how many writes one sync makes, and the pause between them (GitHub's secondary rate limits
/// punish bursts of content creation).
public struct MirrorLimits: Hashable, Sendable {
    public var writesPerSync: Int
    public var pause: Duration

    public init(writesPerSync: Int = 20, pause: Duration = .seconds(1)) {
        self.writesPerSync = writesPerSync
        self.pause = pause
    }

    public static let tests = MirrorLimits(writesPerSync: 100, pause: .zero)
}

/// What a poll found for you: comments on the meta issue for the proposer.
public struct MirrorPoll: Sendable {
    public var goal: String
    public var issue: String
    public var comments: [RemoteComment]
    /// The newest comment's id: store it with `GoalMirrorSync.read(comments:)` once they were proposed from.
    public var through: Int64?
}

/// Brings a goal's issues to what heed says, and reads colleagues' changes back. One sync at a time across goals;
/// every write goes through `MirrorGitHub` (gh, a `github` write row each) and is kept in the state as soon as it
/// went through, so a sync cut short repeats nothing.
public actor GoalMirrorSync {
    let ops: GoalOps
    let github: any MirrorGitHub
    let limits: MirrorLimits

    public init(ops: GoalOps, github: any MirrorGitHub, limits: MirrorLimits = MirrorLimits()) {
        self.ops = ops
        self.github = github
        self.limits = limits
    }

    /// Goals a sync or poll is running for: one at a time per goal, so two never make the same issue.
    private var busy: Set<String> = []

    /// Syncs one goal: nothing when mirroring is off, or while another sync or poll of it runs. Before making an
    /// issue, the tracker is searched for the goal's markers, so an issue heed made once (and lost track of) is taken
    /// back, never made twice. `labels`: put on what heed makes (dropped by GitHub without push access).
    ///
    /// The state is read again before each write and each write's result is folded into the stored one at once
    /// (`GoalOps.updateMirror`), so an answer, a tracker change or turning it off in between is never written over.
    /// The state after.
    @discardableResult
    public func sync(
        goal id: String, labels: [String] = [], table: GoalBarTable = .defaults, now: Date
    ) async -> GoalMirrorState {
        guard !busy.contains(id) else { return await (try? ops.mirror(of: id)) ?? .off }
        busy.insert(id)
        defer { busy.remove(id) }
        var searched = false
        var written = 0
        var repo = ""
        do {
            while true {
                let state = try await ops.mirror(of: id)
                guard state.on, let tracker = try await ops.snapshot().goal(id)?.tracker?.repo,
                      repo.isEmpty || repo == tracker
                else { break }
                if state.repo != tracker {
                    try await update(id) { $0 = GoalMirrorState(on: true, repo: tracker) }
                    continue
                }
                repo = tracker
                let writes = try await GoalMirrorPlan.writes(specs(goal: id, table: table, state: state), state: state)
                guard let write = writes.first else {
                    try await update(id) {
                        $0.pending = 0
                        $0.error = nil
                        $0.syncedAt = now
                    }
                    break
                }
                if case .create = write, !searched {
                    searched = true
                    let found = try await github.marked(repo: repo, goal: id)
                    if state.adopting(found, goal: id) != state {
                        try await update(id) { $0 = $0.adopting(found, goal: id) }
                        continue
                    }
                }
                guard written < limits.writesPerSync else {
                    try await update(id) {
                        $0.pending = writes.count
                        $0.error = nil
                    }
                    break
                }
                if written > 0, limits.pause > .zero { try await Task.sleep(for: limits.pause) }
                let made = try await perform(write, repo: repo, labels: labels)
                written += 1
                try await update(id) { $0 = $0.applied(write, made: made) }
            }
        } catch {
            try? await update(id) { $0.error = "\(error)" }
        }
        return await (try? ops.mirror(of: id)) ?? .off
    }

    private func specs(goal id: String, table: GoalBarTable, state: GoalMirrorState) async throws -> [MirrorSpec] {
        let snapshot = try await ops.snapshot()
        guard let goal = snapshot.goal(id) else { throw GoalOpError.unknownGoal(id) }
        let doc = snapshot.docs[id] ?? GoalDoc(title: goal.title)
        let quality = try await ops.quality(of: id, table: table)
        let required = ReviewEvidence.requiredStages(quality)
        // The swarm going (or the last one, once it landed): its approved plan is the merge order.
        let run = snapshot.activeSwarm(of: id)
            ?? snapshot.swarms(of: id).first.flatMap { $0.status == .done ? $0 : nil }
        var swarm: GoalMirrorRender.Swarm?
        if let run, let approved = run.approved, let board = try? await ops.board(of: run.id),
           let version = board.version(approved)
        {
            swarm = GoalMirrorRender.Swarm(run: run, tasks: SwarmPlan.grouped(version.tasks))
        }
        return GoalMirrorRender.specs(
            goal: goal, doc: doc, snapshot: snapshot, lenses: quality.lenses, requiredLenses: required,
            issues: state.items.mapValues(\.number), swarm: swarm
        )
    }

    /// Makes one write; the issue a create made.
    private func perform(_ write: MirrorWrite, repo: String, labels: [String]) async throws -> RemoteIssue? {
        switch write {
        case let .create(_, title, body):
            return try await github.create(repo: repo, title: title, body: body, labels: labels)
        case let .edit(_, number, title, body):
            try await github.edit(repo: repo, number: number, title: title, body: body)
        case let .close(_, number, comment):
            try await github.comment(repo: repo, number: number, body: comment)
            try await github.setState(repo: repo, number: number, open: false)
        case let .reopen(_, number, comment):
            try await github.setState(repo: repo, number: number, open: true)
            try await github.comment(repo: repo, number: number, body: comment)
        case let .attach(_, parent, child):
            try await github.addSubIssue(repo: repo, parent: parent, child: child)
        }
        return nil
    }

    private func update(_ goal: String, _ change: @escaping @Sendable (inout GoalMirrorState) -> Void) async throws {
        try await ops.updateMirror(goal: goal, change)
    }

    // MARK: Reading back

    /// Reads what changed on the tracker since the last poll: one call for the issues updated since, and one for the
    /// meta issue's comments when it is among them. Sub-issues colleagues closed or reopened become asks; the meta
    /// issue's new comments are returned for the proposer (their cursor moves when `read(comments:)` says so).
    public func poll(goal id: String, now: Date) async -> MirrorPoll? {
        guard !busy.contains(id), let state = try? await ops.mirror(of: id), state.on, let repo = state.repo,
              await (try? ops.snapshot().goal(id)) != nil
        else { return nil }
        busy.insert(id)
        defer { busy.remove(id) }
        let since = state.seen ?? state.syncedAt ?? now
        do {
            let updated = try await github.updated(repo: repo, since: since)
            let snapshot = try await ops.snapshot()
            let evidence = snapshot.evidence(of: id)
            let done = Set(snapshot.items(of: id).filter { Board.column($0, evidence: evidence) == .done }.map(\.id))
            try await update(id) { current in
                guard current.repo == repo else { return }
                current = GoalMirrorBack.read(current, updated: updated, done: done, now: now)
            }
            guard let meta = state.meta, updated.contains(where: { $0.number == meta.number }) else { return nil }
            let comments = try await github.comments(repo: repo, number: meta.number, since: since)
            let fresh = GoalMirrorBack.fresh(comments, after: state.lastComment)
            guard let last = fresh.last else { return nil }
            return MirrorPoll(goal: id, issue: "\(repo)#\(meta.number)", comments: fresh, through: last.id)
        } catch {
            try? await update(id) { $0.error = "\(error)" }
            return nil
        }
    }

    /// The meta issue's comments through `id` were read (proposed from, or let go): the next poll starts after them.
    public func read(comments id: Int64, goal: String) async {
        try? await update(goal) { $0.lastComment = max($0.lastComment ?? 0, id) }
    }

    /// Whether `repo` can be a tracker: read only.
    public func check(repo: String) async -> TrackerCheck {
        do { return try await github.check(repo: repo) } catch {
            return TrackerCheck(repo: repo, problem: "\(error)")
        }
    }
}
