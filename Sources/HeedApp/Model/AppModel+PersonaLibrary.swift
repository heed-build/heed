import AppKit
import Foundation
import HeedCore

/// Settings › Personas: the library (heed's built-ins and your files, one list), turning one on or off, what it joins,
/// its file, trying it on a recent merged PR, sharing it; Add a persona (heed reads the repos you pick and a cheap
/// model
/// proposes the people they serve); and defining the picked with an agent over ACP (read-only), one at a time. The
/// domain is HeedCore's (`PersonaLibrary`, `PersonaDigest`, `PersonaProposals`, `PersonaDefinition`, `PersonaTrial`);
/// this gathers inputs and runs gh, the calls and the ACP session off the main actor. Files go through `GoalOps`.
extension AppModel {
    func performPersonas(_ command: CommandInvocation) -> Bool {
        let words = command.arguments
        let ui = personaUI
        switch command.name {
        case "personas.open":
            _ = openSettingsPage(.personas, rest: [])
            settingsPage = .personas
            openSettings?()
        case "personas.move":
            let step = Int(words.first ?? "") ?? 1
            if var adding = ui.adding, ui.defining.isEmpty {
                adding.cursor = min(max(adding.cursor + step, 0), max(adding.proposals.count - 1, 0))
                ui.adding = adding
            } else {
                ui.setCursor(ui.cursor + step, count: personaRows.count)
            }
        case "personas.toggle": togglePersona()
        case "personas.try": tryPersona()
        case "personas.edit": editLibraryPersona()
        case "personas.share": shareLibraryPersona()
        case "personas.join": toggleJoin(words.first ?? "")
        case "personas.add": openAddPersona()
        case "personas.pick": pickProposal()
        case "personas.read": readForPersonas()
        case "personas.repo": lookAt(words.joined(separator: " "))
        case "personas.describe": if ui.adding != nil { ui.adding?.describing = "" }
        case "personas.overlap": resolveOverlap(words.first == "sharpen" ? .sharpen : .keep)
        case "personas.drafted": addDrafted()
        case "personas.define": defineProposals()
        case "personas.answer": if !ui.defining.isEmpty { ui.answering = "" }
        case "personas.option": pickPersonaOption(Int(words.first ?? "") ?? 1)
        case "personas.next": nextDefinition()
        case "personas.save": saveDefinition()
        case "personas.close": closePersonaSheet()
        default: return false
        }
        return true
    }

    // MARK: The library

    /// The library: the built-ins and the files, one list.
    var personaLibrary: PersonaLibrary { PersonaLibrary(files: goals.personas.library) }

    /// The rows the page shows, under its filter.
    var personaRows: [PersonaLibrary.Entry] { personaLibrary.filtered(personaUI.filter) }

    var selectedLibraryEntry: PersonaLibrary.Entry? {
        let rows = personaRows
        return rows.indices.contains(personaUI.cursor) ? rows[personaUI.cursor] : rows.first
    }

    /// Each persona's last verdicts, from the panels that read a plan with it in a seat.
    var personaVerdicts: [String: [PanelVerdict.Kind]] {
        personaUI.fixtureVerdicts ?? PersonaVerdicts.history(Array(goals.wizard.wizards.values))
    }

    /// The fake world's library, for the Settings shots: its files into the in-memory store, and its verdicts.
    func loadPersonaLibraryFixture() {
        let files = PersonaLibraryFixtures.files
        personaUI.fixtureVerdicts = PersonaLibraryFixtures.verdicts
        goals.run { ops in
            for (id, text) in files {
                try await ops.saveLibrary(text: text, id: id)
            }
        }
    }

    func clickLibraryPersona(_ id: String) {
        guard let index = personaRows.firstIndex(where: { $0.id == id }) else { return }
        personaUI.setCursor(index, count: personaRows.count)
    }

    private func saveToLibrary(_ persona: Persona, said: String) {
        goals.run { ops in
            try await ops.saveLibrary(persona)
        } done: { [weak self] result in
            switch result {
            case .success: self?.say(said)
            case let .failure(error): self?.say("not saved: \(error)")
            }
        }
    }

    /// `personas.toggle`: on or off; a built-in turned off gets a file that says so.
    func togglePersona() {
        guard let entry = selectedLibraryEntry, let persona = personaLibrary.toggled(entry.id) else { return }
        saveToLibrary(persona, said: "\(persona.name) is \(persona.on ? "on" : "off")")
    }

    /// `personas.join <panels|pr|plans>`: what it joins on its own. The session ones are stored for sessions to read.
    func toggleJoin(_ word: String) {
        guard let join = PersonaJoin(text: word), var persona = selectedLibraryEntry?.persona else {
            return say("joins: panels, pr or plans")
        }
        if persona.joins.contains(join) { persona.joins.remove(join) } else { persona.joins.insert(join) }
        let on = persona.joins.contains(join)
        saveToLibrary(persona, said: "\(persona.name) \(on ? "joins" : "no longer joins") \(join.text)")
    }

    /// `personas.edit`: the file in an editor in place (a built-in from its text); again, ⎋ or ⌘S saves.
    func editLibraryPersona() {
        if personaUI.draft != nil { return saveLibraryDraft() }
        guard let entry = selectedLibraryEntry else { return }
        let id = entry.id
        let fallback = entry.persona.render()
        goals.run { ops in
            await (try? ops.libraryText(id)) ?? fallback
        } done: { [weak self] result in
            guard let self, case let .success(text) = result else { return }
            personaUI.drafting = id
            personaUI.draft = text
        }
    }

    func saveLibraryDraft() {
        guard let draft = personaUI.draft, let id = personaUI.drafting else { return }
        personaUI.draft = nil
        personaUI.drafting = nil
        goals.run { ops in
            try await ops.saveLibrary(text: draft, id: id)
        } done: { [weak self] result in
            switch result {
            case let .success(persona): self?.say("\(persona.id).md saved")
            case let .failure(error): self?.say("not saved: \(error)")
            }
        }
    }

    /// `personas.share`: the file on the pasteboard, to send to a teammate (their library takes it as it is).
    func shareLibraryPersona() {
        guard let entry = selectedLibraryEntry else { return }
        let id = entry.id
        let fallback = entry.persona.render()
        goals.run { ops in
            await (try? ops.libraryText(id)) ?? fallback
        } done: { [weak self] result in
            guard let self, case let .success(text) = result else { return }
            if !isFixture {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
            say("\(entry.persona.name)'s file is copied: it goes in personas/\(id).md of their library")
        }
    }

    // MARK: Trying it on a PR

    /// The local repo a persona's trial reads: its repo, else one in its org, else the first.
    private func trialRepo(_ persona: Persona) -> Repo? {
        let local = repos.filter(\.location.isLocal).map(\.repo)
        switch persona.scope {
        case let .repo(slug):
            let parts = slug.split(separator: "/").map(String.init)
            return parts.count == 2 ? Repo(org: parts[0], name: parts[1]) : nil
        case let .org(org): return local.first { $0.org.lowercased() == org.lowercased() }
        case .everywhere: return currentSession?.repos.first ?? local.first
        }
    }

    var personaCalls: PersonaCalls {
        if isFixture { return PersonaCalls(run: PersonaLibraryFixtures.calls) }
        return PersonaCalls { [weak self] request in
            guard let self else { throw LLMError.disabled }
            return try await runLLM(request)
        }
    }

    /// `personas.try`: the persona (or the one being defined, as drafted) as a cheap review of a recent merged PR in
    /// its scope; the next one each time.
    func tryPersona() {
        let ui = personaUI
        let defining = ui.current
        guard let persona = defining?.draft ?? selectedLibraryEntry?.persona else { return }
        let id = persona.id
        guard !ui.trying.contains(id) else { return say("trying it already") }
        let tried = defining?.tried ?? ui.tried[id] ?? []
        let calls = personaCalls
        let fixture = isFixture
        let repo = trialRepo(persona)
        guard fixture || repo != nil else { return say("no repo to try \(persona.name) on: clone one in its scope") }
        ui.trying.insert(id)
        ui.edit(id: id) { $0.trying = true }
        say("\(persona.name) reads a merged PR…")
        Task {
            do {
                let pull: PullSample
                if fixture {
                    pull = PersonaLibraryFixtures.pull
                } else if let repo {
                    let pulls = await GitHub.mergedPulls(repo, caller: PersonaCalls.caller)
                    guard let next = PersonaTrial.pick(pulls, tried: tried) else {
                        throw TrialProblem(description: "no merged PR in \(repo.slug) left to try")
                    }
                    pull = try await GitHub.pullSample(repo, pull: next, caller: PersonaCalls.caller)
                } else {
                    return
                }
                let (trial, _) = try await calls.trial(persona, pull: pull)
                ui.trials[id] = trial
                ui.tried[id, default: []].insert(pull.number)
                ui.edit(id: id) { definition in
                    definition.trial = trial
                    definition.tried.insert(pull.number)
                }
                say("\(persona.name) on #\(pull.number): \(trial.verdict.rawValue)")
            } catch {
                say("not tried: \(error)")
            }
            ui.trying.remove(id)
            ui.edit(id: id) { $0.trying = false }
        }
    }

    // MARK: Add a persona

    /// `personas.add`: the sheet, with the repos of the org you work in most picked, and heed reading them.
    func openAddPersona() {
        if isFixture {
            personaUI.adding = PersonaLibraryBrowser.Adding(
                repos: PersonaLibraryFixtures.repos + ["globex/markgraph"], looking: Set(PersonaLibraryFixtures.repos)
            )
            return readForPersonas()
        }
        let local = repos.filter(\.location.isLocal).map(\.repo.slug).sorted { $0.lowercased() < $1.lowercased() }
        guard !local.isEmpty else { return say("no repo on this Mac to read: add one in Repos") }
        let org = currentSession?.repos.first?.org ?? Self.busiestOrg(local)
        let looking = local.filter { Self.org(of: $0) == org }.prefix(3)
        personaUI.adding = PersonaLibraryBrowser.Adding(
            repos: local, looking: Set(looking.isEmpty ? [local[0]] : Array(looking))
        )
        readForPersonas()
    }

    private static func org(of slug: String) -> String {
        slug.split(separator: "/").first.map(String.init) ?? slug
    }

    /// The org with the most repos on this Mac.
    private static func busiestOrg(_ slugs: [String]) -> String? {
        let counts = Dictionary(slugs.map { (org(of: $0), 1) }, uniquingKeysWith: +)
        return counts.max { $0.value == $1.value ? $0.key > $1.key : $0.value < $1.value }?.key
    }

    /// `personas.repo <repo>`: look at it, or not (within one org: a persona never crosses the org wall).
    func lookAt(_ repo: String) {
        guard var adding = personaUI.adding, adding.repos.contains(repo) else { return }
        if adding.looking.contains(repo) {
            guard adding.looking.count > 1 else { return }
            adding.looking.remove(repo)
        } else {
            let org = Self.org(of: repo)
            adding.looking = adding.looking.filter { Self.org(of: $0) == org }
            adding.looking.insert(repo)
        }
        personaUI.adding = adding
    }

    /// `personas.read`: each repo looked at read (docs, owners, review, issues, checks, merges), then a cheap call
    /// proposes the people they serve.
    func readForPersonas() {
        guard var adding = personaUI.adding, !adding.reading else { return }
        adding.reading = true
        adding.done = []
        adding.problem = nil
        personaUI.adding = adding
        let looking = adding.repos.filter(adding.looking.contains)
        let checkouts = Dictionary(
            repos.filter(\.location.isLocal).map { ($0.repo.slug, $0.path) }, uniquingKeysWith: { first, _ in first }
        )
        let library = personaLibrary.personas
        let calls = personaCalls
        let fixture = isFixture
        let ui = personaUI
        Task {
            let digest: PersonaDigest
            if fixture {
                digest = PersonaLibraryFixtures.digest(now: Clock.now)
                ui.adding?.done = Set(PersonaDigest.Step.allCases)
            } else {
                var reads: [RepoReads] = []
                for slug in looking {
                    let parts = slug.split(separator: "/").map(String.init)
                    guard parts.count == 2 else { continue }
                    // A step is read once the last repo read it.
                    let last = slug == looking.last
                    let read = await GitHub.personaReads(
                        Repo(org: parts[0], name: parts[1]), checkout: checkouts[slug], caller: PersonaCalls.caller
                    ) { step in
                        if last { await MainActor.run { _ = ui.adding?.done.insert(step) } }
                    }
                    reads.append(read)
                }
                digest = PersonaDigest(reads: reads)
            }
            ui.adding?.digest = digest
            do {
                let (proposals, cost) = try await calls.propose(digest: digest, library: library, now: Clock.now)
                ui.adding?.proposals = proposals
                ui.adding?.picked = Set(proposals.filter { $0.strength >= 70 }.map(\.id))
                ui.adding?.cost = cost
                ui.adding?.cursor = 0
            } catch {
                ui.adding?.problem = "\(error)"
            }
            ui.adding?.reading = false
        }
    }

    /// The describe-one field's text: heed drafts that one, picked.
    func describePersona(_ text: String) {
        personaUI.adding?.describing = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, let adding = personaUI.adding else { return }
        let digest = adding.digest ?? PersonaDigest(reads: [])
        let library = personaLibrary.personas
        let calls = personaCalls
        let ui = personaUI
        say("drafting who you described…")
        Task {
            do {
                let (proposals, cost) = try await calls.propose(
                    digest: digest, library: library, describe: text, now: Clock.now
                )
                guard let proposal = proposals.first, var adding = ui.adding else { return }
                adding.proposals.removeAll { $0.id == proposal.id }
                adding.proposals.insert(proposal, at: 0)
                adding.picked.insert(proposal.id)
                adding.cursor = 0
                adding.cost = cost
                ui.adding = adding
                say("\(proposal.persona.name) drafted and picked")
            } catch {
                say("not drafted: \(error)")
            }
        }
    }

    func pickProposal() {
        guard var adding = personaUI.adding, adding.proposals.indices.contains(adding.cursor) else { return }
        let id = adding.proposals[adding.cursor].id
        if adding.picked.contains(id) { adding.picked.remove(id) } else { adding.picked.insert(id) }
        personaUI.adding = adding
    }

    func clickProposal(_ id: String) {
        guard var adding = personaUI.adding, let index = adding.proposals.firstIndex(where: { $0.id == id }) else {
            return
        }
        adding.cursor = index
        personaUI.adding = adding
        pickProposal()
    }

    /// `personas.overlap`: the first overlapping proposal sharpens the persona it overlaps, or both stay.
    func resolveOverlap(_ choice: PersonaOverlapChoice) {
        guard var adding = personaUI.adding, let overlapping = adding.overlapping,
              let index = adding.proposals.firstIndex(of: overlapping)
        else { return say("nothing overlaps") }
        let resolved = PersonaProposals.resolve(overlapping, choice, library: personaLibrary)
        adding.proposals[index] = resolved
        if adding.picked.remove(overlapping.id) != nil { adding.picked.insert(resolved.id) }
        personaUI.adding = adding
    }

    /// `personas.drafted`: the picked into the library as they are.
    func addDrafted() {
        guard let adding = personaUI.adding else { return }
        let picked = adding.pickedProposals.map(\.persona)
        guard !picked.isEmpty else { return say("pick one first: space") }
        personaUI.adding = nil
        let now = Clock.now
        goals.run { ops in
            for var persona in picked {
                persona.added = persona.added ?? now
                try await ops.saveLibrary(persona)
            }
        } done: { [weak self] result in
            switch result {
            case .success: self?.say("\(picked.count) persona\(picked.count == 1 ? "" : "s") in the library")
            case let .failure(error): self?.say("not added: \(error)")
            }
        }
    }

    // MARK: Defining with an agent

    /// `personas.define`: one ACP session per picked persona, the first now; ] goes on to the next.
    func defineProposals() {
        guard let adding = personaUI.adding else { return }
        let picked = adding.pickedProposals
        guard !picked.isEmpty else { return say("pick one first: space") }
        if isFixture {
            var first = PersonaLibraryFixtures.definition
            first.start.name = picked[0].persona.name
            first.draft.name = picked[0].persona.name
            personaUI.defining = [first] + picked.dropFirst().map { proposal in
                PersonaDefinition(start: proposal.persona, agent: "claude", via: "claude via ACP", repo: nil)
            }
            personaUI.defineIndex = 0
            return
        }
        let adapter = ACPAgents.chosen(config.helpers, defaultAgent: settings.defaultAgent)
        guard let adapter else { return say("heed knows no ACP way to your agent: [helpers] agent") }
        personaUI.defining = picked.map { proposal in
            let repo: String? = switch proposal.persona.scope {
            case let .repo(slug): slug
            default: adding.repos.first(where: adding.looking.contains)
            }
            return PersonaDefinition(start: proposal.persona, agent: adapter.agent, via: adapter.title, repo: repo)
        }
        personaUI.defineIndex = 0
        connectPersonaDefinition()
    }

    private func connectPersonaDefinition() {
        guard let definition = personaUI.current, !isFixture else { return }
        let adapter = ACPAgents.adapter(for: definition.agent)
            ?? ACPAgents.chosen(config.helpers, defaultAgent: settings.defaultAgent)
        guard let adapter else { return }
        let directory = definition.repo.flatMap { slug in
            repos.first { $0.location.isLocal && $0.repo.slug.lowercased() == slug.lowercased() }?.path
        }
        guard let directory else {
            return personaDefineFailed("\(definition.repo ?? "its repo") is not cloned on this Mac")
        }
        let prompt = PersonaDefinition.prompt(definition.start, repo: definition.repo)
        personaUI.editCurrent { $0.working = true }
        openAgentConversation(
            \.personaUI.defineConversation, adapter: adapter, directory: directory, handlers: personaHandlers
        ) { [weak self] in
            self?.personaDefineTurn(prompt)
        }
    }

    private var personaHandlers: ConversationHandlers {
        ConversationHandlers(
            failed: { [weak self] why in self?.personaDefineFailed(why) },
            reads: { [weak self] paths, root in
                let reads = PartDefinition.reads(paths, root: root, limit: 4)
                self?.personaUI.editCurrent { $0.reads = reads }
            },
            cost: { [weak self] cost in self?.personaUI.editCurrent { $0.cost = cost } }
        )
    }

    private func personaDefineFailed(_ why: String) {
        personaUI.editCurrent { definition in
            definition.working = false
            definition.problem = why
        }
        say(why)
    }

    /// One turn: the reply is read when it ends.
    func personaDefineTurn(_ text: String) {
        if isFixture {
            personaUI.editCurrent { $0.received("Noted.\n{\"question\": null, \"options\": []}") }
            return
        }
        let ui = personaUI
        guard let id = ui.current?.id else { return }
        let started = Clock.now
        let slot: ConversationSlot = \.personaUI.defineConversation
        let began = agentConversationTurn(slot, text: text, handlers: personaHandlers) { reply in
            ui.edit(id: id) { definition in
                definition.received(reply)
                definition.working = false
                definition.seconds += Clock.now.timeIntervalSince(started)
            }
        }
        if began { ui.editCurrent { $0.working = true } }
    }

    /// The answer field's text, sent.
    func answerPersonaAgent(_ text: String) {
        personaUI.answering = nil
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        personaUI.editCurrent { $0.say(text) }
        personaDefineTurn(text)
    }

    func pickPersonaOption(_ number: Int) {
        var answer: String?
        personaUI.editCurrent { answer = $0.pick(number - 1) }
        guard let answer else { return say("no option \(number)") }
        personaDefineTurn(answer)
    }

    private func endPersonaSession() {
        closeAgentConversation(\.personaUI.defineConversation)
    }

    /// `personas.next`: on to the next picked persona (its own session).
    func nextDefinition() {
        guard personaUI.defining.count > 1 else { return say("the only one") }
        endPersonaSession()
        personaUI.defineIndex = (personaUI.defineIndex + 1) % personaUI.defining.count
        if personaUI.current?.turns.isEmpty == true { connectPersonaDefinition() }
    }

    /// `personas.save`: the persona as defined into the library; on to the next, or the sheets close.
    func saveDefinition() {
        guard let definition = personaUI.current else { return }
        var persona = definition.draft
        persona.added = persona.added ?? Clock.now
        endPersonaSession()
        personaUI.defining.remove(at: personaUI.defineIndex)
        personaUI.adding?.proposals.removeAll { $0.id == definition.id }
        personaUI.adding?.picked.remove(definition.id)
        if personaUI.defining.isEmpty {
            personaUI.adding = nil
            personaUI.defineIndex = 0
        } else {
            personaUI.defineIndex %= personaUI.defining.count
            if personaUI.current?.turns.isEmpty == true { connectPersonaDefinition() }
        }
        saveToLibrary(persona, said: "\(persona.name) is in the library")
    }

    /// `personas.close`: the persona being defined (all of them: nothing saved), else Add a persona.
    func closePersonaSheet() {
        if personaUI.answering != nil {
            personaUI.answering = nil
            return
        }
        if !personaUI.defining.isEmpty {
            endPersonaSession()
            personaUI.defining = []
            personaUI.defineIndex = 0
            return
        }
        if personaUI.adding?.describing != nil {
            personaUI.adding?.describing = nil
            return
        }
        personaUI.adding = nil
    }

    // MARK: Keys in the Settings window

    /// A key pressed in the Settings window while Personas shows: the scope's binding, run as any key is. False lets
    /// it through.
    func personaSettingsKey(_ stroke: KeyStroke, typing: Bool) -> Bool {
        if typing {
            // In a field: ⎋ and ⌘S end the file's edit; ⎋ leaves the describe and answer fields.
            if personaUI.draft != nil, stroke == .escape || stroke == KeyStroke("s", .command) {
                saveLibraryDraft()
                return true
            }
            if stroke == .escape, personaUI.answering != nil || personaUI.adding?.describing != nil {
                closePersonaSheet()
                return true
            }
            return false
        }
        guard case let .command(line) = engine.scopedKeymaps[personaUI.scope]?.lookup([stroke]) else { return false }
        perform(CommandInvocation(parsing: line))
        return true
    }
}

/// Why a trial could not run.
private struct TrialProblem: Error, CustomStringConvertible {
    let description: String
}
