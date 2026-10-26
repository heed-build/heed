import Foundation
import HeedCore

/// Personas: who a goal needs, worked out by a cheap model from its board (`PersonaDerivation`, within the goal's
/// model calls) whenever the board changes materially, debounced; each persona's coverage; and spawning one as a
/// reviewer (read-only, through the reviewer machinery), a chat or a session. A strong gap is spawned as a reviewer on
/// its own while the goal's reviewer budget lasts; every other gap is suggested in Attention. The pure parts are in
/// HeedCore (`Persona`, `PersonaDerivation`, `PersonaCoverage`, `PersonaBoard`, `PersonaAutoSpawn`).
extension AppModel {
    // MARK: The pane

    /// `goal.personas`: the Personas pane, or back to the overview.
    func toggleGoalPersonas() {
        endGoalEditing()
        endPersonaEditing()
        if view != .goals {
            view = .goals
            if goals.pane != .personas { goals.togglePersonas() }
            return
        }
        goals.togglePersonas()
    }

    func clickPersona(_ index: Int) {
        guard clicksReachLists, view == .goals else { return }
        clickedOutsideTerminal()
        goals.setFocus(.personas)
        goals.setCursor(index)
    }

    func personaMenu(_ index: Int) -> [MenuEntry] {
        let rows = goals.personaRows
        guard let goal = goals.selected, rows.indices.contains(index) else { return [] }
        let row = rows[index]
        return ContextMenus.persona(
            goal: goal.id, id: row.id, name: row.persona.name, editing: goals.personas.drafting == row.id
        )
    }

    /// What the open sessions and chats are, and which reviewers run: a persona with one of them is active.
    var personaLiveTargets: Set<String> {
        var live = Set(sessions.map(\.id))
        for quality in goals.qualities.values {
            for reviewer in quality.reviewers where reviewer.running {
                live.insert(reviewer.id)
            }
        }
        return live
    }

    /// The persona a command acts on: a right-click's row (`goal/persona:id`), else the cursor's in Personas.
    private var personaSubject: (goal: HeedGoal, row: PersonaRow)? {
        if case let .row(view: "goals", id: id) = commandTarget, let range = id.range(of: "/persona:") {
            let goalID = String(id[..<range.lowerBound])
            let personaID = String(id[range.upperBound...])
            if let goal = goals.snapshot.goal(goalID) {
                if goals.selected?.id != goalID { goals.point(to: goalID) }
                if let row = goals.personaRows.first(where: { $0.id == personaID }) { return (goal, row) }
            }
        }
        guard view == .goals, goals.pane == .personas, let goal = goals.selected, let row = goals.selectedPersona
        else { return nil }
        return (goal, row)
    }

    // MARK: Spawning

    /// What a persona is told about the goal: the persona, the goal and its GOAL.md, and the evidence that asked for
    /// it.
    private func personaSeed(goal: HeedGoal, row: PersonaRow) -> String {
        var lines = [
            row.persona.brief,
            "",
            "You are here for the goal \"\(goal.title)\" (its GOAL.md: \(Paths.tilde(goals.files.doc(goal.id).path))). "
                + "Read it first.",
        ]
        if !row.need.why.isEmpty { lines += ["", "Why you, now: \(row.need.why)"] }
        if !row.need.evidence.isEmpty {
            lines += ["", "What asked for you:"] + row.need.evidence.map { "- \($0.text): \($0.label)" }
        }
        return lines.joined(separator: "\n")
    }

    /// `persona.session`, `persona.chat`, `persona.reviewer`: the persona under the cursor put to work.
    func spawnPersona(_ mode: PersonaSpawn.Mode) {
        guard let subject = personaSubject else { return say("no persona here: P shows who the goal needs") }
        endPersonaEditing()
        switch mode {
        case .reviewer:
            spawnPersonaReviewer(goal: subject.goal, row: subject.row, auto: false)
        case .chat, .session:
            let seed = personaSeed(goal: subject.goal, row: subject.row)
            let prompt = mode == .chat ? seed + "\n\nLet's talk about the goal from where you stand." : seed
                + "\n\nWork on the goal from where you stand: start with what you ask first."
            goals.personas.starting = PersonaBrowser.Starting(
                goal: subject.goal.id, persona: subject.row.id, mode: mode, marker: subject.row.persona.brief
            )
            openStartWork(prompt: prompt, fromCursor: false, chat: mode == .chat)
            if let agent = goals.personas.spawn.agent, startWork?.choose(agent: agent) == false {
                say("no agent \(agent): Start work keeps its own")
            }
        }
    }

    /// The persona as a reviewer on the goal: a custom reviewer whose instructions are the persona and its evidence,
    /// read-only as every reviewer is, recorded as the persona's. `auto`: heed spawned it for a strong gap, and it runs
    /// within the goal's reviewer budget; yours runs now.
    private func spawnPersonaReviewer(goal: HeedGoal, row: PersonaRow, auto: Bool) {
        let table = config.goals.bars
        var instructions = row.persona.brief
        if !row.need.evidence.isEmpty {
            instructions += "\n\nWhat asked for you: " + row.need.evidence.map(\.text).joined(separator: ", ")
        }
        let existing = goals.qualities[goal.id]?.live.first { $0.config.persona.map(Persona.slug) == row.id }
        let config = existing?.config ?? ReviewerConfig(
            id: "persona-\(row.id)", kind: .custom, instructions: instructions, policy: .onChange,
            agent: goals.personas.spawn.agent, tier: goals.personas.spawn.tier, persona: row.persona.name
        )
        let now = Clock.now
        let persona = row.id
        goals.run { ops in
            let spawned = existing == nil ? try await ops.spawn(config, goal: goal.id, now: now, table: table) : config
            try await ops.personaSpawned(
                PersonaSpawn(persona: persona, mode: .reviewer, target: spawned.id, auto: auto), goal: goal.id,
                now: now
            )
            return spawned
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(spawned):
                if auto {
                    say("\(goal.title): nobody had looked as \(row.persona.name), so heed asked one to review")
                    runReviewers(goal: goal, trigger: .personaGap(row.persona.name), only: [spawned.id])
                } else {
                    say("\(row.persona.name) reviews \(goal.title)")
                    runReviewers(goal: goal, trigger: .manual, only: [spawned.id])
                }
            case let .failure(error): say("no reviewer: \(error)")
            }
        }
    }

    /// Before Start work launches a persona's session or chat: it goes on the goal first (as `heed goal item spawn`
    /// does), and the goal pointers and plugin are applied, so its agent launches told about the goal like any session
    /// on one. Any other plan is returned as it is.
    func preparePersonaLaunch(_ plan: StartWorkPlan) async -> StartWorkPlan {
        guard let starting = goals.personas.starting, let agent = plan.agent, plan.prompt.contains(starting.marker),
              (starting.mode == .chat) == (plan.chat != nil)
        else { return plan }
        let link = GoalLink(
            goal: starting.goal, kind: plan.chat == nil ? .session : .chat, target: plan.sessionID, origin: .manual,
            reason: "spawned as \(starting.persona)", at: Clock.now
        )
        let attached: Bool = await withCheckedContinuation { continuation in
            goals.run { ops in
                try await ops.attach(link)
                return true
            } done: {
                continuation.resume(returning: (try? $0.get()) == true)
            }
        }
        guard attached else { return plan }
        applyGoalPointers()
        var told = plan
        told.signOff = settings.signOffArguments(
            agent: agent, repo: plan.repos.first?.repo, session: plan.sessionID, host: plan.location.hostName
        )
        return told
    }

    /// After Start work: a session or chat started as a persona is recorded as the persona's (and is on the goal,
    /// from `preparePersonaLaunch`; attached again here in case that could not).
    func personaStarted(_ session: Session) {
        guard let starting = goals.personas.starting else { return }
        goals.personas.starting = nil
        guard session.prompt.contains(starting.marker), (starting.mode == .chat) == session.isChat else { return }
        let now = Clock.now
        let attached = goals.bySession[session.id]?.id == starting.goal
        let link = GoalLink(goal: starting.goal, kind: GoalLink.kind(of: session), target: session.id, at: now)
        let spawn = PersonaSpawn(persona: starting.persona, mode: starting.mode, target: session.id)
        goals.run { ops in
            if !attached { try await ops.attach(link) }
            try await ops.personaSpawned(spawn, goal: starting.goal, now: now)
        }
    }

    // MARK: The file

    /// `persona.edit`: the persona's file in an editor in place; again (or ⎋, ⌘S) saves it.
    func editPersona() {
        if goals.personas.draft != nil { return savePersonaDraft() }
        guard let subject = personaSubject else { return say("no persona here: P shows who the goal needs") }
        let goalID = subject.goal.id
        let id = subject.row.id
        let fallback = subject.row.persona.render()
        goals.run { ops in
            await (try? ops.personaText(id, goal: goalID)) ?? fallback
        } done: { [weak self] result in
            guard let self, case let .success(text) = result else { return }
            goals.personas.drafting = id
            goals.personas.draft = text
            textInputActive = true
        }
    }

    func savePersonaDraft() {
        guard let draft = goals.personas.draft, let id = goals.personas.drafting, let goal = goals.selected else {
            return endPersonaEditing()
        }
        endPersonaEditing()
        goals.run { ops in
            try await ops.savePersona(draft, id: id, goal: goal.id)
        } done: { [weak self] result in
            switch result {
            case let .success(persona): self?.say("\(persona.id).md saved")
            case let .failure(error): self?.say("not saved: \(error)")
            }
        }
    }

    func endPersonaEditing() {
        guard goals.personas.draft != nil else { return }
        goals.personas.draft = nil
        goals.personas.drafting = nil
        textInputActive = false
    }

    /// Keys while a persona's file is edited: ⎋ and ⌘S save it.
    func answerPersonaText(_ stroke: KeyStroke) -> Bool {
        switch stroke {
        case .escape, KeyStroke("s", .command): savePersonaDraft()
        default: return false
        }
        return true
    }

    /// `persona.share`: the persona's file into the library, for other goals.
    func sharePersona() {
        guard let subject = personaSubject else { return say("no persona here: P shows who the goal needs") }
        let goalID = subject.goal.id
        let id = subject.row.id
        goals.run { ops in
            if await (try? ops.personaText(id, goal: goalID)) == nil {
                // A draft not written yet (the fake world): its file first.
                try await ops.savePersona(subject.row.persona.render(), id: id, goal: goalID)
            }
            try await ops.share(persona: id, goal: goalID)
        } done: { [weak self] result in
            switch result {
            case .success: self?.say("\(subject.row.persona.name) is in the library: :persona.use on another goal")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `persona.use <persona>`: a library persona copied onto the goal; the next derivation can name it.
    func usePersona(_ words: [String]) {
        guard let goal = goals.selected else { return say("no goal here") }
        let library = goals.personas.library
        guard !words.isEmpty else {
            return library.isEmpty ? say("the library is empty: L shares a persona into it")
                : openCommandLine("persona.use ")
        }
        let name = words.joined(separator: " ")
        let id = library[name] != nil ? name : Persona.slug(name)
        guard library[id] != nil else {
            return say("no persona \(name) in the library: " + library.keys.sorted().joined(separator: ", "))
        }
        goals.run { ops in
            try await ops.use(library: id, goal: goal.id)
        } done: { [weak self] result in
            switch result {
            case let .success(persona): self?.say("\(persona.name) is on \(goal.title)")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    // MARK: Working it out

    /// `persona.derive`: who the goal needs, now.
    func derivePersonas(asked: Bool = false, goal id: String? = nil) {
        guard let goal = id.flatMap(goals.snapshot.goal) ?? goals.selected else { return say("no goal here") }
        guard !goals.personas.deriving.contains(goal.id) else { return asked ? say("working it out already") : () }
        guard spendGoalCall(goal.id) else {
            if asked {
                say(isFixture || tutor != nil ? "fixture: no model calls" : "no model call: [llm] is off, or "
                    + "\(goal.title) used today's \(GoalBudget.daily)")
            }
            return
        }
        if asked { say("working out who \(goal.title) needs…") }
        goals.personas.deriving.insert(goal.id)
        let doc = goals.snapshot.docs[goal.id]
        let items = goals.snapshot.items(of: goal.id)
        let evidence = goals.snapshot.evidence(of: goal.id)
        let quality = goals.qualities[goal.id]
        let refs = PersonaDerivation.refs(doc: doc, items: items, evidence: evidence, quality: quality)
        let signature = PersonaDerivation.signature(doc: doc, items: items, evidence: evidence, quality: quality)
        let known = Array(Set((goals.personas.files[goal.id] ?? [:]).values.map(\.name)
                + goals.personas.library.values.map(\.name))).sorted()
        let inputs = PersonaDerivation.inputs(
            title: goal.title, doc: doc?.render() ?? "", refs: refs, evidence: evidence, known: known
        )
        let summarizer = summarizer
        let version = goal.version
        goals.run { ops in
            let answer = try await summarizer.summarize(kind: .goalPersonas, inputs: inputs, caller: "goals.personas")
            let needs = PersonaDerivation.parse(answer, refs: refs)
            guard !needs.isEmpty else { return 0 }
            try await ops.derived(
                PersonaDerivation(needs: needs, signature: signature, goalVersion: version), goal: goal.id,
                now: Clock.now
            )
            return needs.count
        } done: { [weak self] result in
            guard let self else { return }
            goals.personas.deriving.remove(goal.id)
            goals.personas.seen[goal.id] = (signature, Clock.now)
            switch result {
            case let .success(count):
                if asked { say(count == 0 ? "the model named nobody" : "\(goal.title) needs \(count) personas") }
                spawnPersonaGaps(goal)
            case let .failure(error): if asked { say("personas: \(error)") }
            }
        }
    }

    /// Each sync: goals whose board changed materially, and has been still a while, work out their personas again;
    /// gaps are spawned or suggested.
    func checkGoalPersonas() {
        guard !isFixture, tutor == nil, goals.ops != nil else { return }
        let now = Clock.now
        for goal in goals.snapshot.goals where goal.status == .active {
            let doc = goals.snapshot.docs[goal.id]
            let items = goals.snapshot.items(of: goal.id)
            let evidence = goals.snapshot.evidence(of: goal.id)
            let signature = PersonaDerivation.signature(
                doc: doc, items: items, evidence: evidence, quality: goals.qualities[goal.id]
            )
            // When the board last moved: the debounce waits for it to be still.
            if goals.personas.seen[goal.id]?.signature != signature { goals.personas.seen[goal.id] = (signature, now) }
            let board = goals.personas.boards[goal.id]
            let last = board?.derivation.map { (signature: $0.signature, at: board?.derivedAt ?? .distantPast) }
            if PersonaDerivation.due(
                last: last, signature: signature, changedAt: goals.personas.seen[goal.id]?.at ?? now, now: now,
                empty: items.isEmpty && (doc?.openQuestions.isEmpty ?? true)
            ) {
                derivePersonas(goal: goal.id)
            } else {
                spawnPersonaGaps(goal)
            }
        }
    }

    /// Strong gaps become reviewers while the goal's reviewer budget lasts (once per persona); the rest are suggested.
    private func spawnPersonaGaps(_ goal: HeedGoal) {
        guard !isFixture, tutor == nil, let board = goals.personas.boards[goal.id] else { return }
        let rows = board.rows(
            files: goals.personas.files[goal.id] ?? [:], items: goals.snapshot.items(of: goal.id),
            evidence: goals.snapshot.evidence(of: goal.id), links: goals.snapshot.links(of: goal.id),
            reviewers: goals.qualities[goal.id]?.reviewers ?? [], live: personaLiveTargets
        )
        let quality = goals.qualities[goal.id]
        let picked = PersonaAutoSpawn.pick(
            rows: rows, spawns: board.spawns, used: ReviewPlanner.used(quality?.runs ?? [], now: Clock.now),
            limit: config.goals.autoReview ? config.goals.reviewerRunsPerDay : 0
        )
        goals.personas.setSuggested(goal.id, picked.suggest)
        for id in picked.spawn {
            guard let row = rows.first(where: { $0.id == id }) else { continue }
            spawnPersonaReviewer(goal: goal, row: row, auto: true)
        }
    }

    /// Gaps heed suggests, one Attention item per goal.
    var personaAttentionItems: [AttentionItem] {
        var names: [String: [String]] = [:]
        for (goal, ids) in goals.personas.suggested {
            let rows = goals.personas.boards[goal]?.derivation?.needs ?? []
            names[goal] = ids.compactMap { id in
                goals.personas.files[goal]?[id]?.name ?? rows.first { $0.id == id }?.name
            }
        }
        let at = goals.personas.boards.compactMapValues(\.derivedAt)
        return GoalAttention.personaGaps(goals: goals.snapshot.goals, gaps: names, at: at, now: Clock.now)
    }
}
