import Foundation
import HeedCore

/// Goals' item sources: the GitHub queries a goal's items come from (one item per PR or issue), heed's proposal for
/// a goal that reads like a set over GitHub, and the sync on heed's GitHub schedule. Every change goes through
/// `GoalOps`, every GitHub call through `GitHubSources` (gh, a `github` row each in `:log`). Fixtures and the tutor
/// never reach GitHub: their sources are `ItemSourceFixtures`.
extension AppModel {
    /// The goal a source command acts on: the one right-clicked, else the one selected in Goals.
    private var sourceSubject: HeedGoal? {
        if case let .row("goals", id)? = commandTarget, let goal = goals.snapshot.goal(id) { return goal }
        return view == .goals ? goals.selected : nil
    }

    // MARK: Commands

    /// `goal.source.add <query>`: a source on the goal, its Done when line with it, and a sync. No query: the
    /// command line, with the goal's repo filled in.
    func addGoalSource(_ words: [String]) {
        guard let goal = sourceSubject else { return say("no goal here") }
        let text = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return openCommandLine("goal.source.add prs " + (goalRepo(goal) ?? "")) }
        let parsed: ItemSourceQuery.Parsed
        do {
            parsed = try ItemSourceQuery.parse(text, repo: goalRepo(goal))
        } catch {
            return say("\(error)")
        }
        let now = Clock.now
        goals.run { ops in
            try await ops.addSource(goal: goal.id, ItemSource(
                query: parsed.query, label: parsed.label, rule: parsed.rule, addedAt: now
            ), now: now)
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(source):
                say("\(source.id): \(source.label), each done when \(Self.ruleText(source))")
                syncGoalSources(only: goal.id, force: true)
            case let .failure(error): say("no source added: \(error)")
            }
        }
    }

    /// `goal.source.remove [id]`: the source off the goal; its items stay. No id: the goal's only source, else the
    /// command line.
    func removeGoalSource(_ words: [String]) {
        guard let goal = sourceSubject else { return say("no goal here") }
        guard let id = sourceID(words.first, goal: goal, command: "goal.source.remove") else { return }
        let now = Clock.now
        goals.run { ops in try await ops.removeSource(goal: goal.id, id: id, now: now) } done: { [weak self] result in
            switch result {
            case let .success(source): self?.say("\(source.label) is off \(goal.title): its items stay")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `goal.source.edit <id> <query>`: a new query for the source; its items stay.
    func editGoalSource(_ words: [String]) {
        guard let goal = sourceSubject else { return say("no goal here") }
        guard let id = sourceID(words.first, goal: goal, command: "goal.source.edit") else { return }
        let text = words.dropFirst().joined(separator: " ")
        guard !text.isEmpty else {
            let query = goals.snapshot.sources(of: goal.id).source(id)?.query ?? ""
            return openCommandLine("goal.source.edit \(id) \(query)")
        }
        let parsed: ItemSourceQuery.Parsed
        do {
            parsed = try ItemSourceQuery.parse(text, repo: goalRepo(goal))
        } catch {
            return say("\(error)")
        }
        let now = Clock.now
        goals.run { ops in
            try await ops.editSource(goal: goal.id, id: id, query: parsed.query, label: parsed.label, now: now)
        } done: { [weak self] result in
            switch result {
            case let .success(source):
                self?.say("\(source.id) is \(source.label) now")
                self?.syncGoalSources(only: goal.id, force: true)
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `goal.source.rule <id> <rule>`: what done means for the source's items.
    func setGoalSourceRule(_ words: [String]) {
        guard let goal = sourceSubject else { return say("no goal here") }
        var words = words
        if words.count == 1, ItemSource.Rule(rawValue: words[0]) != nil { words.insert("", at: 0) }
        guard let id = sourceID(words.first.flatMap { $0.isEmpty ? nil : $0 }, goal: goal, command: "goal.source.rule")
        else { return }
        guard let word = words.dropFirst().first, let rule = ItemSource.Rule(rawValue: word) else {
            return openCommandLine("goal.source.rule \(id) ")
        }
        let now = Clock.now
        goals.run { ops in try await ops.setSourceRule(goal: goal.id, id: id, rule, now: now) } done: { [weak self] in
            switch $0 {
            case let .success(source):
                self?.say("\(source.label): each done when \(Self.ruleText(source))")
                self?.syncGoalSources(only: goal.id, force: true)
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `goal.source.accept` (`y` on the goal): yes to heed's proposal.
    func acceptGoalSource() {
        guard let goal = sourceSubject else { return say("no goal here") }
        guard goals.snapshot.sources(of: goal.id).proposal != nil else {
            return say("heed proposes no source for \(goal.title): :goal.source.add adds one")
        }
        let now = Clock.now
        goals.run { ops in try await ops.acceptSourceProposal(goal: goal.id, now: now) } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(source):
                say("\(source.label) feeds \(goal.title): one item per match, each done when \(Self.ruleText(source))")
                syncGoalSources(only: goal.id, force: true)
            case let .failure(error): say("\(error)")
            }
        }
    }

    /// `goal.source.dismiss`: no to heed's proposal; it is not proposed again.
    func dismissGoalSource() {
        guard let goal = sourceSubject else { return say("no goal here") }
        goals.run { ops in try await ops.dismissSourceProposal(goal: goal.id) } done: { [weak self] result in
            switch result {
            case let .success(proposal): self?.say("not proposed again: \(proposal.source.label)")
            case let .failure(error): self?.say("\(error)")
            }
        }
    }

    /// `goal.source.sync`: the goal's sources now, instead of on the next GitHub sync.
    func syncGoalSourcesNow() {
        guard let goal = sourceSubject else { return say("no goal here") }
        guard !goals.snapshot.sources(of: goal.id).sources.isEmpty else {
            return say("\(goal.title) has no sources: :goal.source.add adds one")
        }
        guard !isFixture, tutor == nil else { return say("fixture: nothing is asked of GitHub") }
        say("syncing \(goal.title)'s sources…")
        syncGoalSources(only: goal.id, force: true, tell: true)
    }

    /// The source a command names, or the goal's only one; nil (and the command line, or why) when neither.
    private func sourceID(_ word: String?, goal: HeedGoal, command: String) -> String? {
        let state = goals.snapshot.sources(of: goal.id)
        if let word {
            guard state.source(word) != nil else {
                say("\(goal.title) has no source \(word) (\(state.sources.map(\.id).joined(separator: ", ")))")
                return nil
            }
            return word
        }
        if state.sources.count == 1 { return state.sources[0].id }
        if state.sources.isEmpty {
            say("\(goal.title) has no sources: :goal.source.add adds one")
        } else {
            openCommandLine("\(command) ")
        }
        return nil
    }

    static func ruleText(_ source: ItemSource) -> String {
        source.what == .issues ? ItemSource.Rule.closed.phrase : source.rule.phrase
    }

    // MARK: Syncing

    /// On each GitHub sync: every active goal's sources whose last sync is older than the background interval (the
    /// poll interval while Goals shows), a search each and a lookup of the items that stopped matching. `force`:
    /// now. Never in fixtures or the tutor.
    func syncGoalSources(only: String? = nil, force: Bool = false, tell: Bool = false) {
        guard !isFixture, tutor == nil, let ops = goals.ops else { return }
        let interval = TimeInterval(config.githubPollSeconds) * (view == .goals ? 1 : 5)
        let now = Date()
        let due = goals.snapshot.goals.filter { goal in
            guard goal.status == .active, only == nil || goal.id == only, !goals.syncingSources.contains(goal.id)
            else { return false }
            let state = goals.snapshot.sources(of: goal.id)
            guard !state.sources.isEmpty else { return false }
            return force || state.syncedAt.map { now.timeIntervalSince($0) >= interval - 5 } ?? true
        }
        guard !due.isEmpty else { return }
        goals.syncingSources.formUnion(due.map(\.id))
        let run = ItemSourceSyncRun(ops: ops, github: GitHubSources())
        Task { [weak self] in
            var said: [String] = []
            for goal in due {
                do {
                    let summary = try await run.sync(goal: goal.id, now: Date())
                    if summary.added > 0 { said.append("\(goal.title): \(summary.added) new") }
                    for line in summary.met {
                        said.append("\(goal.title): ✓ \(line)")
                    }
                } catch {
                    said.append("\(goal.title): \(error)")
                }
            }
            guard let self else { return }
            goals.syncingSources.subtract(due.map(\.id))
            goals.reload()
            if tell || !said.isEmpty { say(said.first ?? "sources up to date") }
        }
    }

    // MARK: Proposing

    /// Goals that read like a set over GitHub get a source proposed, once per GOAL.md version: a cheap decision
    /// (when decisions are on) says what kind of set, the words say which repo or label. Goals with a source, or
    /// whose proposal is waiting, are left alone.
    func detectGoalSources() {
        guard !isFixture, tutor == nil, goals.ops != nil else { return }
        let snapshot = goals.snapshot
        let waiting = snapshot.goals.filter { goal in
            let state = snapshot.sources(of: goal.id)
            return goal.status == .active && state.sources.isEmpty && state.proposal == nil
                && state.checked != goal.version && !goals.detectingSources.contains(goal.id)
        }
        guard !waiting.isEmpty else { return }
        goals.detectingSources.formUnion(waiting.map(\.id))
        let decider: (any Decider)? = decisionsOn ? decider(caller: "goals.sources") : nil
        let inputs = waiting.map { goal in
            (goal, snapshot.docs[goal.id]?.goal ?? "", goalRepo(goal).map { [$0] } ?? [])
        }
        goals.run { ops in
            for (goal, statement, repos) in inputs {
                let proposal = await ItemSourceDetect.detect(
                    title: goal.title, statement: statement, repos: repos, goal: goal.id, decider: decider, now: Date()
                )
                try await ops.propose(source: proposal, goal: goal.id, version: goal.version)
            }
        } done: { [weak self] _ in
            self?.goals.detectingSources.subtract(waiting.map(\.id))
        }
    }

    // MARK: Fixtures

    /// The fake world's item sources: a goal reviewing an invented repo's open PRs, and one with a proposal waiting.
    func loadSourcesFixture() {
        guard isFixture else { return }
        goals.loadSourcesFixture()
    }
}
