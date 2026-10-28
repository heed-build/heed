import Foundation
import HeedCore

/// Goals' items, evidence and GOAL.md edits: the board's and the proposals' commands, and the pipelines that feed them
/// (the planner, what a session's or chat's ledger entry finds, PRs on the goal's branches, the proposer). Every change
/// goes through `GoalOps`; model calls go through `summarizer` and `decider`, within each goal's daily `GoalBudget`.
extension AppModel {
    // MARK: Moving

    /// `goal.board`: the goal as a board, or back to the overview.
    func toggleGoalBoard() {
        endGoalEditing()
        guard view == .goals else {
            view = .goals
            if goals.pane != .board { goals.toggleBoard() }
            return
        }
        goals.toggleBoard()
    }

    /// The item a command acts on: the one right-clicked, else the card under the board's cursor.
    var goalItemSubject: GoalItem? {
        if case let .row("goals", id)? = commandTarget, let item = goals.snapshot.item(id) { return item }
        return goals.pane == .board ? goals.selectedCard : nil
    }

    /// A matrix row clicked: the item's card on the board.
    func showGoalItem(_ id: String) {
        guard clicksReachLists else { return }
        view = .goals
        if goals.pane != .board { goals.toggleBoard() }
        goals.point(to: id)
    }

    func clickGoalCard(column: Board.Column, row: Int, open: Bool = false) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.pointBoard(column: column, row: row)
        if open { openGoalItem() }
    }

    func goalItemMenu(_ id: String) -> [MenuEntry] {
        guard let item = goals.snapshot.item(id) else { return [] }
        return ContextMenus.goalItem(
            id: item.id, title: item.title, column: Board.column(item, evidence: goals.snapshot.evidence),
            question: item.kind == .question, issue: item.issueNumber
        )
    }

    func goalProposalMenu(_ edit: GoalEdit) -> [MenuEntry] {
        edit.id.map { ContextMenus.goalProposal(id: $0, line: edit.line) } ?? []
    }

    // MARK: Items

    /// `goal.item.add <title>`: an item of yours on the goal; on the board, in the column under the cursor. A title
    /// ending in `?` is a question. No title: the command line.
    func addGoalItem(_ words: [String]) {
        guard let goal = goals.selected else { return say("no goal here: n makes one") }
        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !title.isEmpty else { return openCommandLine("goal.item.add ") }
        let column = goals.pane == .board ? goals.boardColumn : nil
        let now = Clock.now
        goals.run { ops in
            var item = try await ops.addItem(
                goal: goal.id, title: title, kind: title.hasSuffix("?") ? .question : .work, source: .you, now: now
            )
            let natural: Board.Column = item.kind == .question ? .toExplore : .planned
            if let column, column != natural { item = try await ops.move(item: item.id, to: column, now: now) }
            return item
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(item):
                if goals.pane == .board {
                    goals.follow(item.id, to: Board.column(item, evidence: goals.snapshot.evidence))
                }
                say("\(item.title) is on \(goal.title)")
            case let .failure(error): say("no item added: \(error)")
            }
        }
    }

    /// `goal.item.move <left|right|column>`: the card by hand; new evidence about it moves it on.
    func moveGoalItem(_ word: String?) {
        guard let item = goalItemSubject else { return say("no card here: B shows the board") }
        let current = Board.column(item, evidence: goals.snapshot.evidence)
        let target: Board.Column? = switch word?.lowercased() {
        case "left"?: current.step(-1)
        case "right"?: current.step(1)
        case let word?: Board.Column(word: word)
        case nil: nil
        }
        guard let target else {
            return word == nil ? openCommandLine("goal.item.move ") : say("\(item.title) is in \(current.title)")
        }
        guard target != current else { return say("\(item.title) is in \(current.title) already") }
        moveGoalItem(item, to: target)
    }

    /// A card dropped in another column, or moved by key.
    func moveGoalItem(_ item: GoalItem, to column: Board.Column) {
        let now = Clock.now
        goals.run { ops in
            try await ops.move(item: item.id, to: column, now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                goals.follow(item.id, to: column)
                say("\(item.title) → \(column.title), until new evidence moves it")
                observeTutorNow()
            case let .failure(error): say("not moved: \(error)")
            }
        }
    }

    func dropGoalCard(_ id: String, on column: Board.Column) {
        guard let item = goals.snapshot.item(id) else { return }
        guard Board.column(item, evidence: goals.snapshot.evidence) != column else { return }
        moveGoalItem(item, to: column)
    }

    /// `goal.item.done`.
    func goalItemDone() {
        guard let item = goalItemSubject else { return say("no card here: B shows the board") }
        moveGoalItem(item, to: .done)
    }

    /// `goal.item.split a; b; c`: smaller items, each with this one as its parent. No titles: the command line.
    func splitGoalItem(_ words: [String]) {
        guard let item = goalItemSubject else { return say("no card here: B shows the board") }
        let titles = words.joined(separator: " ").split(separator: ";")
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !titles.isEmpty else { return openCommandLine("goal.item.split ") }
        let now = Clock.now
        goals.run { ops in
            try await ops.split(item: item.id, into: titles, now: now)
        } done: { [weak self] result in
            switch result {
            case let .success(parts): self?.say("\(item.title) split into \(parts.count)")
            case let .failure(error): self?.say("not split: \(error)")
            }
        }
    }

    /// `goal.item.work` (`o` on the board): Start work, filled in from the item; the session it starts goes on the
    /// goal, on the item.
    func workOnGoalItem() {
        guard let item = goalItemSubject, let goal = goals.snapshot.goal(item.goal) else {
            return say("no card here: B shows the board")
        }
        goals.startingItem = item
        openStartWork(prompt: item.workPrompt(goal: goal.title, doc: Paths.tilde(goals.files.doc(goal.id).path)))
    }

    /// After Start work: the session started from an item goes on its goal and its item.
    func goalItemStarted(_ session: Session) {
        guard let item = goals.startingItem else { return }
        goals.startingItem = nil
        guard session.prompt.contains(item.title) else { return }
        let now = Clock.now
        let link = GoalLink(
            goal: item.goal,
            kind: GoalLink.kind(of: session),
            target: session.id,
            item: item.id,
            at: now
        )
        goals.run { ops in
            try await ops.attach(link)
            try await ops.link(item: item.id, GoalItem.Link(session.isChat ? .chat : .session, session.id))
            try await ops.addEvidence(GoalEvidence(
                goal: item.goal, item: item.id, kind: .built, state: .inProgress, at: now,
                source: "session \(session.id)", text: "started in \(session.title)", ref: session.id
            ))
        }
    }

    /// `goal.item.open` (↩ on a card): its PR, its session or chat; a question, GOAL.md.
    func openGoalItem() {
        guard let item = goalItemSubject else { return say("no card here: B shows the board") }
        if item.kind == .question {
            goals.show(.doc)
            return say("questions are answered in GOAL.md: a decision there moves the card to Done")
        }
        let live = item.links.reversed().first { link in
            (link.kind == .session || link.kind == .chat) && sessions.contains { $0.id == link.target }
        }
        if let pr = item.linked(.pr).last.flatMap(PullRef.init(slug:)) {
            return perform(CommandInvocation(name: "overlay.item", target: .pull(pr)))
        }
        if let live {
            view = .sessions
            return select(sessionID: live.target)
        }
        say(item.links.isEmpty ? "nothing works on \(item.title) yet: o starts work on it" : "its session is closed")
    }

    // MARK: Proposals

    enum ProposalAnswer { case accept, reject, edit }

    /// `goal.proposal.accept|reject|edit`: the change right-clicked or clicked, else the first one waiting. Edit
    /// takes the new words (`#<id>` first names one); without them, the command line opens with the change typed.
    func answerProposal(_ answer: ProposalAnswer, _ words: [String]) {
        var words = words
        var named: Int64?
        if let first = words.first, first.hasPrefix("#"), let id = Int64(first.dropFirst()) {
            named = id
            words.removeFirst()
        }
        if case let .row("goals", key)? = commandTarget, key.hasPrefix("edit:") { named = Int64(key.dropFirst(5)) }
        let waiting = goals.proposals
        guard let edit = named.flatMap({ id in goals.snapshot.edits.first { $0.id == id } }) ?? waiting.first,
              let id = edit.id
        else { return say("no changes waiting for GOAL.md") }
        let now = Clock.now
        let before = goals.snapshot.docs[edit.goal]
        switch answer {
        case .edit where words.isEmpty:
            openCommandLine("goal.proposal.edit #\(id) \(edit.text)")
        case .accept, .edit:
            let text = words.isEmpty ? nil : words.joined(separator: " ")
            goals.run { ops in
                try await ops.accept(edit: id, text: text, now: now)
            } done: { [weak self] result in
                guard let self else { return }
                switch result {
                case let .success(done):
                    say(done.state == .applied ? "GOAL.md v\(done.version ?? 0): \(done.line)" : "nothing to change")
                    replanIfScopeChanged(edit.goal, before: before)
                case let .failure(error): say("\(error)")
                }
            }
        case .reject:
            goals.run { ops in
                try await ops.reject(edit: id, now: now)
            } done: { [weak self] result in
                if case let .failure(error) = result { return self?.say("\(error)") ?? () }
                self?.say("left out: \(edit.line)")
            }
        }
    }

    /// `goal.undo`: the newest change heed made to GOAL.md on its own, taken back out.
    func undoGoalEdit() {
        guard let goal = goals.selected else { return say("no goal here") }
        guard let edit = goals.snapshot.edits.last(where: {
            $0.goal == goal.id && $0.state == .applied && $0.kind == .record
        }), let id = edit.id else { return say("heed changed nothing in \(goal.title)'s GOAL.md to undo") }
        let now = Clock.now
        goals.run { ops in
            try await ops.undo(edit: id, now: now)
        } done: { [weak self] result in
            if case let .failure(error) = result { return self?.say("\(error)") ?? () }
            self?.say("undone: \(edit.line)")
        }
    }

    /// Attention's goal item: its GOAL.md, with the changes waiting.
    func openGoalProposals(_ attentionID: String) {
        let goal = String(attentionID.dropFirst("goal:".count))
        view = .goals
        goals.point(to: goal)
        goals.show(.doc)
    }

    // MARK: Model calls

    /// Whether `goal` may make one more model call today; counts it when it may.
    func spendGoalCall(_ goal: String) -> Bool {
        guard !isFixture, tutor == nil, config.llm.enabled else { return false }
        let runs = goals.modelRuns[goal] ?? []
        guard GoalBudget.allows(runs: runs, now: Date()) else { return false }
        goals.modelRuns[goal] = runs.filter { Calendar.current.isDateInToday($0) } + [Date()]
        return true
    }

    private var goalDecider: (any Decider)? {
        decisionsOn && !isFixture ? decider(caller: "goals.items") : nil
    }

    /// `goal.plan` and new goals: the planner's items for the goal, those it does not have yet added as planned.
    func planGoal(asked: Bool = false, goal id: String? = nil) {
        guard let goal = id.flatMap(goals.snapshot.goal) ?? goals.selected else { return say("no goal here") }
        // While a swarm runs on the goal, its lead plans instead; the planner is back when the swarm ends.
        if let swarm = goals.snapshot.activeSwarm(of: goal.id) {
            if asked { say("swarm \(swarm.number)'s lead plans \(goal.title) now: S shows its plan") }
            return
        }
        guard spendGoalCall(goal.id) else {
            if asked { say(isFixture || tutor != nil ? "fixture: no model calls" : "no model call: [llm] is off, or "
                    + "\(goal.title) used today's \(GoalBudget.daily)") }
            return
        }
        if asked { say("planning \(goal.title)…") }
        let summarizer = summarizer
        let decider = goalDecider
        let version = goal.version
        goals.run { ops in
            let text = try await ops.text(of: goal.id)
            let existing = try await ops.snapshot().items(of: goal.id)
            let answer = try await summarizer.summarize(
                kind: .goalPlan, inputs: GoalPlanner.inputs(title: goal.title, doc: text, items: existing),
                caller: "goals.plan"
            )
            var added = 0
            var items = existing
            for title in GoalPlanner.titles(answer) {
                guard case .new = await GoalItemMatch.decide(title, items: items, goal: goal.id, decider: decider)
                else { continue }
                let item = try await ops.addItem(
                    goal: goal.id, title: title, source: .planner, reason: "from GOAL.md v\(version)", now: Date()
                )
                items.append(item)
                added += 1
            }
            return added
        } done: { [weak self] result in
            guard asked else { return }
            switch result {
            case let .success(added): self?
                .say(added == 0 ? "the plan has nothing new" : "\(added) planned items added")
            case let .failure(error): self?.say("planner: \(error)")
            }
        }
    }

    /// After a version that changed what the goal is, the planner looks again.
    func replanIfScopeChanged(_ goal: String, before: GoalDoc?) {
        guard let after = goals.snapshot.docs[goal], GoalPlanner.scopeChanged(from: before, to: after) else { return }
        planGoal(goal: goal)
    }

    /// `goal.sharpen` (`w`): a model suggests a sharper GOAL.md; every suggestion waits for you.
    func sharpenGoal() {
        guard let goal = goals.selected else { return say("no goal here") }
        guard spendGoalCall(goal.id) else {
            return say(isFixture || tutor != nil ? "fixture: no model calls" : "no model call: [llm] is off, or "
                + "\(goal.title) used today's \(GoalBudget.daily)")
        }
        say("asking for a sharper \(goal.title)…")
        let summarizer = summarizer
        goals.run { ops in
            let text = try await ops.text(of: goal.id)
            let answer = try await summarizer.summarize(
                kind: .goalSharpen, inputs: SummaryInputs(title: goal.title, goal: text), caller: "goals.sharpen",
                priority: .interactive
            )
            var waiting = 0
            for edit in GoalEditProposer.edits(answer, goal: goal.id, from: "sharpen", now: Date(), scopeOnly: true) {
                let proposed = try await ops.propose(edit, now: Date())
                waiting += proposed.state == .proposed ? 1 : 0
            }
            return waiting
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(count):
                goals.show(.doc)
                say(count == 0 ? "nothing to sharpen" : "\(count) suggestion\(count == 1 ? "" : "s") wait in GOAL.md")
            case let .failure(error): say("sharpen: \(error)")
            }
        }
    }

    // MARK: Pipelines

    /// A ledger entry written for a session or chat on a goal: its follow-ups become items (or questions), its
    /// decisions go into GOAL.md, its work is evidence for its item, and the proposer reads it for more.
    func learnFromLedger(_ entry: LedgerEntry) {
        guard !isFixture, let goal = goals.bySession[entry.id] else { return }
        let found = GoalDiscovery.from(entry)
        let source: GoalItem.Source = entry.chat ? .chat : .session
        let linkKind: GoalItem.Link.Kind = entry.chat ? .chat : .session
        let from = entry.chat ? "chat · \(entry.title)" : entry.title
        let decider = goalDecider
        let session = sessions.first { $0.id == entry.id } ?? history.first { $0.id == entry.id }?.session
        let propose = spendGoalCall(goal.id)
        let summarizer = summarizer
        let instructions = summaryInstructions(for: session?.repos.first)
        let lastMessage = session?.lastMessage
        let sessionItem = goals.snapshot.links.first { $0.target == entry.id }?.item
            ?? goals.snapshot.items(of: goal.id).first { $0.linked(linkKind).contains(entry.id) }?.id
        goals.run { ops in
            let now = Date()
            var items = try await ops.snapshot().items(of: goal.id)
            for (title, kind) in found.items.map({ ($0, GoalItem.Kind.work) })
                + found.questions.map({ ($0, GoalItem.Kind.question) })
            {
                switch await GoalItemMatch.decide(title, items: items, goal: goal.id, decider: decider) {
                case .existing:
                    continue
                case let .new(confidence):
                    let item = try await ops.addItem(
                        goal: goal.id, title: title, kind: kind, source: source,
                        links: [GoalItem.Link(linkKind, entry.id)], confidence: confidence,
                        reason: "\(kind == .question ? "asked" : "follow-up") in \(entry.title)", now: now
                    )
                    items.append(item)
                }
            }
            for decision in found.decisions {
                try await ops.propose(GoalEdit(
                    goal: goal.id, section: .decisions, op: .add, text: decision, evidence: from, from: from, at: now
                ), now: now)
            }
            if let item = sessionItem, let diff = entry.diff, diff.files > 0 {
                try await ops.addEvidence(GoalEvidence(
                    goal: goal.id, item: item, kind: .built, state: entry.endedAt == nil ? .inProgress : .done, at: now,
                    source: "session \(entry.id)", text: diff.text, ref: entry.id
                ))
            }
            guard propose else { return }
            let text = try await ops.text(of: goal.id)
            let answer = try await summarizer.summarize(
                kind: .goalEdits,
                inputs: GoalEditProposer.inputs(goal: goal.title, doc: text, entry: entry, lastMessage: lastMessage),
                instructions: instructions, caller: "goals.edits"
            )
            for edit in GoalEditProposer.edits(answer, goal: goal.id, from: from, now: now) {
                try await ops.propose(edit, now: now)
            }
        }
    }

    /// PRs on the goals' branches and items: evidence for their items (Verify, then Done once merged); a PR on a
    /// goal's session with no item gets one.
    func noticeGoalPulls() {
        guard !isFixture, goals.ops != nil, !goals.snapshot.goals.isEmpty else { return }
        let snapshot = goals.snapshot
        let pulls = github.pulls
        let sessions = sessions + history.map(\.session)
        let now = Clock.now
        var work: [(GoalPulls.Finding, [GoalEvidence])] = []
        for goal in snapshot.goals where goal.status == .active {
            for finding in GoalPulls.findings(
                goal: goal.id, links: snapshot.links, items: snapshot.items(of: goal.id), sessions: sessions,
                pulls: pulls, now: now
            ) {
                let fresh = finding.item == nil
                    ? finding.evidence : GoalPulls.fresh(finding.evidence, known: snapshot.evidence(of: goal.id))
                if !fresh.isEmpty { work.append((finding, fresh)) }
            }
        }
        guard !work.isEmpty else { return }
        let found = work
        goals.run { ops in
            for (finding, evidence) in found {
                try await ops.recordPull(finding, evidence: evidence, now: now)
            }
        }
    }
}
