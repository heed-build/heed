import Foundation

/// A goal's item sources (`ItemSource`): adding, editing and taking one off, heed's proposal, and a sync's results
/// written as items and evidence. Adding a source writes its line into GOAL.md's Done when (you chose the source, so
/// it applies as yours, a version you can restore away); when every item of it is done, heed checks the line off
/// with the count as evidence.
public extension GoalOps {
    func sourceState(of goal: String) throws -> GoalSourceState {
        try store.sources()[goal] ?? .empty
    }

    private func updateSources(goal: String, _ change: (inout GoalSourceState) throws -> Void) throws
        -> GoalSourceState
    {
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        var state = try sourceState(of: goal)
        try change(&state)
        try store.save(sources: state, goal: goal)
        return state
    }

    /// A new source on the goal (its id given here), and its line in Done when. The same query twice is refused.
    @discardableResult
    func addSource(goal: String, _ source: ItemSource, now: Date) throws -> ItemSource {
        var added = source
        try updateSources(goal: goal) { state in
            if let same = state.sources.first(where: { $0.query == source.query }) {
                throw GoalOpError.source("\(goal) has that source already (\(same.id): \(same.label))")
            }
            guard source.rule.fits(source.what) else {
                throw GoalOpError.source("issues are done when closed: \(source.rule.rawValue) is a rule for PRs")
            }
            added.id = "s\(state.next)"
            state.next += 1
            state.sources.append(added)
            if state.proposal?.source.query == source.query { state.proposal = nil }
        }
        try criterion(goal: goal, add: added.criterion, from: "source \(added.id)", now: now)
        return added
    }

    /// Takes a source off: its items stay on the goal, the ones not done marked as having left it; its Done when
    /// line goes unless it was met.
    @discardableResult
    func removeSource(goal: String, id: String, now: Date) throws -> ItemSource {
        var removed: ItemSource?
        try updateSources(goal: goal) { state in
            guard let index = state.sources.firstIndex(where: { $0.id == id }) else {
                throw GoalOpError.source("\(goal) has no source \(id)")
            }
            removed = state.sources.remove(at: index)
        }
        guard let removed else { throw GoalOpError.source("\(goal) has no source \(id)") }
        let evidence = try store.evidence()
        for var item in try store.items() where item.goal == goal && item.sourced?.source == id {
            guard item.sourced?.left == nil, Board.column(item, evidence: evidence) != .done else { continue }
            item.sourced?.left = now
            try store.save(item)
        }
        let doc = try GoalDoc.parse(text(of: goal))
        if doc.doneWhen.contains(where: { GoalEdits.same($0.text, removed.criterion) && !$0.met }) {
            try criterion(goal: goal, remove: removed.criterion, from: "source \(id) taken off", now: now)
        }
        return removed
    }

    /// A source's done rule changed: its items follow on the next sync, its Done when line now.
    @discardableResult
    func setSourceRule(goal: String, id: String, _ rule: ItemSource.Rule, now: Date) throws -> ItemSource {
        var before: ItemSource?
        var after: ItemSource?
        try updateSources(goal: goal) { state in
            guard let index = state.sources.firstIndex(where: { $0.id == id }) else {
                throw GoalOpError.source("\(goal) has no source \(id)")
            }
            guard rule.fits(state.sources[index].what) else {
                throw GoalOpError.source("issues are done when closed: \(rule.rawValue) is a rule for PRs")
            }
            before = state.sources[index]
            state.sources[index].rule = rule
            after = state.sources[index]
        }
        guard let before, let after else { throw GoalOpError.source("\(goal) has no source \(id)") }
        for var item in try store.items() where item.goal == goal && item.sourced?.source == id {
            item.sourced?.rule = rule
            try store.save(item)
        }
        try criterion(goal: goal, replace: before.criterion, with: after.criterion, from: "source \(id)", now: now)
        return after
    }

    /// A source's query changed (`goal.source.edit`): the items it found stay, and the next sync follows the new one.
    @discardableResult
    func editSource(goal: String, id: String, query: String, label: String, now: Date) throws -> ItemSource {
        var before: ItemSource?
        var after: ItemSource?
        try updateSources(goal: goal) { state in
            guard let index = state.sources.firstIndex(where: { $0.id == id }) else {
                throw GoalOpError.source("\(goal) has no source \(id)")
            }
            before = state.sources[index]
            state.sources[index].query = query
            state.sources[index].label = label
            if !state.sources[index].rule.fits(state.sources[index].what) { state.sources[index].rule = .closed }
            after = state.sources[index]
        }
        guard let before, let after else { throw GoalOpError.source("\(goal) has no source \(id)") }
        try criterion(goal: goal, replace: before.criterion, with: after.criterion, from: "source \(id)", now: now)
        return after
    }

    /// heed proposes a source for the goal (nil: takes the proposal back), and notes which GOAL.md version it read.
    func propose(source proposal: SourceProposal?, goal: String, version: Int) throws {
        try updateSources(goal: goal) { state in
            state.checked = version
            guard let proposal else { return }
            guard !state.dismissed.contains(proposal.source.query),
                  !state.sources.contains(where: { $0.query == proposal.source.query })
            else { return }
            state.proposal = proposal
        }
    }

    /// Yes to heed's proposal: the source it proposed, added.
    @discardableResult
    func acceptSourceProposal(goal: String, now: Date) throws -> ItemSource {
        guard let proposal = try sourceState(of: goal).proposal else {
            throw GoalOpError.source("heed proposes no source for \(goal)")
        }
        var source = proposal.source
        source.origin = .proposal
        source.addedAt = now
        return try addSource(goal: goal, source, now: now)
    }

    /// No to heed's proposal: not proposed again.
    @discardableResult
    func dismissSourceProposal(goal: String) throws -> SourceProposal {
        var dismissed: SourceProposal?
        try updateSources(goal: goal) { state in
            dismissed = state.proposal
            if let query = state.proposal?.source.query, !state.dismissed.contains(query) {
                state.dismissed.append(query)
            }
            state.proposal = nil
        }
        guard let dismissed else { throw GoalOpError.source("heed proposes no source for \(goal)") }
        return dismissed
    }

    /// What one sync of a goal's sources did.
    struct SourceSyncSummary: Hashable, Sendable {
        public var added = 0
        public var updated = 0
        public var evidence = 0
        /// Done when lines checked off because every item of their source is done.
        public var met: [String] = []
    }

    /// Writes a sync of the goal's sources: new items, updated ones, fresh evidence, the sync's time and error, and
    /// any Done when line whose items are all done now. One step, so two syncs at once cannot make an item twice.
    @discardableResult
    func applySources(goal: String, results: [String: SourceResult], error: String?, now: Date) throws
        -> SourceSyncSummary
    {
        var state = try sourceState(of: goal)
        let snapshot = try store.snapshot()
        let plan = ItemSourceSync.plan(
            goal: goal, sources: state.sources, results: results, items: snapshot.items(of: goal),
            evidence: snapshot.evidence(of: goal), now: now
        )
        var summary = SourceSyncSummary()
        for item in plan.updates {
            try store.save(item)
            summary.updated += 1
        }
        for new in plan.adds {
            let item = try addItem(
                goal: goal, title: new.title, source: .github,
                links: [GoalItem.Link(new.sourced.kind == .pr ? .pr : .issue, new.sourced.ref)], reason: new.reason,
                now: now
            )
            var stored = item
            stored.sourced = new.sourced
            try store.save(stored)
            for var entry in new.evidence {
                entry.item = item.id
                if try addEvidence(entry) != nil { summary.evidence += 1 }
            }
            summary.added += 1
        }
        for entry in plan.evidence where try addEvidence(entry) != nil {
            summary.evidence += 1
        }
        state.syncedAt = now
        state.error = error
        try store.save(sources: state, goal: goal)
        // Every item of a source done: its Done when line met, with the count as evidence.
        let fresh = try store.snapshot()
        let doc = try GoalDoc.parse(text(of: goal))
        for source in state.sources where results[source.id] != nil {
            let progress = SourceProgress.of(source, items: fresh.items(of: goal), evidence: fresh.evidence(of: goal))
            guard progress.complete,
                  doc.doneWhen.contains(where: { GoalEdits.same($0.text, source.criterion) && !$0.met })
            else { continue }
            let edit = try propose(GoalEdit(
                goal: goal, section: .doneWhen, op: .check, text: source.criterion, target: source.criterion,
                evidence: progress.text(source.rule, what: source.what), from: "source \(source.id)", at: now
            ), now: now)
            if edit.state == .applied { summary.met.append(source.criterion) }
        }
        return summary
    }

    // MARK: Done when

    /// Adds, takes out or rewords a source's Done when line, as you: you chose the source.
    private func criterion(
        goal: String, add: String? = nil, remove: String? = nil, replace: String? = nil, with: String? = nil,
        from: String, now: Date
    ) throws {
        let edit: GoalEdit
        if let add {
            edit = GoalEdit(
                goal: goal,
                section: .doneWhen,
                op: .add,
                text: add,
                from: from,
                reason: "a source",
                at: now
            )
        } else if let remove {
            edit = GoalEdit(
                goal: goal, section: .doneWhen, op: .remove, text: remove, target: remove, from: from, at: now
            )
        } else if let replace, let with, replace != with {
            edit = GoalEdit(
                goal: goal, section: .doneWhen, op: .replace, text: with, target: replace, from: from, at: now
            )
        } else {
            return
        }
        let doc = try GoalDoc.parse(text(of: goal))
        var stored = edit
        guard let changed = GoalEdits.apply(edit, to: doc),
              let version = try save(goal: goal, doc: changed, note: GoalEdits.note(edit), author: .you, now: now)
        else {
            stored.state = .moot
            try store.save(stored)
            return
        }
        stored.state = .applied
        stored.version = version.number
        try store.save(stored)
    }
}

public extension GoalOps {
    /// Lays down fixture goals' sources and proposals (`ItemSourceFixtures`).
    func adopt(sources states: [String: GoalSourceState]) throws {
        for (goal, state) in states {
            try store.save(sources: state, goal: goal)
        }
    }
}
