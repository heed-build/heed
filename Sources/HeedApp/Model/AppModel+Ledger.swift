import Foundation
import HeedCore

/// History's ledger: when an entry is written (`[summary] when`), what it is written from (git where the work lives,
/// its PRs, heed's timeline, the agent's last message), and the model call through `summarizer`. Fixtures never write.
extension AppModel {
    /// At launch: what the event log keeps, and an hourly look for idle sessions.
    func startLedger(log: EventLog?) {
        ledger.attach(log: log)
        guard !isFixture else { return }
        Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3600))
                guard let self else { return }
                let due = Ledger.idle(
                    sessions: sessions, entries: ledger.entries, settings: config.ledger, now: Date()
                )
                for id in due {
                    await writeLedger(id, trigger: .idle)
                }
            }
        }
    }

    /// After a commit: the summaries the change asks for (a PR opened or merged, a chat closed).
    func noticeLedger(before: Domain, after: Domain) {
        guard !isFixture, config.llm.enabled else { return }
        for (id, trigger) in Ledger.triggers(before: before, after: after, settings: config.ledger) {
            Task { await writeLedger(id, trigger: trigger) }
        }
    }

    /// The sessions working in these worktrees, open or closed.
    func ledgerSessions(of worktrees: [Worktree]) -> [String] {
        let all = sessions + history.map(\.session)
        return Array(Set(worktrees.flatMap { worktree in
            all.filter { $0.owns(worktree) }.map(\.id)
        })).sorted()
    }

    /// Removes after the summaries of the work in these worktrees were written, or `Ledger.removalWait` passed.
    func summarizingFirst(_ worktrees: [Worktree], remove: @escaping @MainActor @Sendable () async -> Void) async {
        let ids = ledgerSessions(of: worktrees)
        guard !isFixture, config.llm.enabled, config.ledger.writes(on: .worktreeRemoved), !ids.isEmpty else {
            await remove()
            return
        }
        await Ledger.summarizeThenRemove {
            for id in ids {
                await self.writeLedger(id, trigger: .worktreeRemoved)
            }
        } remove: {
            await remove()
        }
    }

    /// `ledger.summarize`: the entry under the cursor (in the ledger), else the session in front.
    func summarizeLedgerNow() {
        guard !isFixture else {
            say("fixture: no IO")
            return
        }
        let id = view == .ledger ? ledger.selected?.id : (view == .history ? selectedHistory?.id : currentSession?.id)
        guard let id else {
            say("no session to summarize")
            return
        }
        guard config.llm.enabled else {
            say("model calls are off ([llm] enabled, or Settings › Agents)")
            return
        }
        say("writing the summary…")
        Task {
            await writeLedger(id, trigger: .onDemand)
            say(ledger.entries[id]?.failure.map { "summary failed: \($0)" } ?? "summary written")
        }
    }

    /// `ledger.edit [text]`: with text, the entry's summary becomes it; without, the command line opens with the
    /// summary typed, to change.
    func editLedger(_ words: [String]) {
        guard let entry = ledger.selected else {
            say("no ledger entry here")
            return
        }
        guard !words.isEmpty else {
            openCommandLine("ledger.edit " + (entry.summary ?? ""))
            return
        }
        var edited = entry
        edited.summary = words.joined(separator: " ")
        edited.source = .edited
        edited.summarizedAt = Clock.now
        ledger.upsert(edited, persist: !isFixture)
        say("summary edited")
    }

    /// Writes a session's entry: the facts, git's view of the work where it lives, its agent's working time, then
    /// what the model says. One at a time per session.
    func writeLedger(_ id: String, trigger: LedgerTrigger) async {
        guard !ledger.writing.contains(id) else { return }
        let closed = history.first { $0.id == id }
        guard let session = sessions.first(where: { $0.id == id }) ?? closed?.session else { return }
        ledger.setWriting(id, true)
        defer { ledger.setWriting(id, false) }
        let settings = config.ledger
        var entry = Ledger.facts(session: session, closed: closed, pulls: github, previous: ledger.entries[id])
        let git = await ledgerGit(session)
        if settings.include.contains(.files), let git {
            entry.diff = git.diff ?? entry.diff
            entry.files = git.files.isEmpty ? entry.files : git.files
        }
        if let log = ledger.log,
           let states = try? await log.events(session: id, kinds: [.state], limit: 5000), !states.isEmpty
        {
            let worked = Timeline.agentTime(states, now: closed?.closedAt ?? Date())
            entry.agentTime = worked.time
            entry.agentTimeEstimated = worked.estimated
        }
        if config.llm.enabled, !settings.include.isDisjoint(with: [.summary, .decisions, .followUps]) {
            let pulls = session.trackedPRs.compactMap { pullDetails[$0.description] }
            entry = await Ledger.write(
                entry, inputs: Ledger.inputs(session: session, git: git?.text, pulls: pulls),
                include: settings.include, trigger: trigger, summarizer: summarizer,
                instructions: summaryInstructions(for: session.repos.first), now: Date()
            )
        }
        ledger.upsert(entry)
    }

    /// Git's view of the session's work in its first repo: its worktree when it is still there, else its branch,
    /// else what was saved when it was removed. Nil for a chat or when git cannot tell.
    private func ledgerGit(_ session: Session) async -> LedgerGit? {
        guard !session.isChat, let repo = session.repos.first,
              let record = repos.first(where: { $0.id == StartContext.id(repo, session.location) })
        else { return nil }
        let base = record.defaultBranch ?? "main"
        if let worktree = worktrees.first(where: { session.owns($0) && $0.repo == repo }) {
            return await LedgerGit.read(path: worktree.path, tip: "HEAD", base: base, on: record.location)
        }
        if let branch = await LedgerGit.read(path: record.path, tip: session.branch, base: base, on: record.location) {
            return branch
        }
        return await LedgerGit.read(
            path: record.path, tip: "heed/archive/\(session.branch)", base: base, on: record.location
        )
    }
}
