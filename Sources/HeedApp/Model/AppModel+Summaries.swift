import Foundation
import HeedCore

/// Attention's catch-up summaries: written ahead for For you's New after a sync (`[attention] summaries = "ahead"`),
/// on open for the rest, again with ↻ (`attention.summarize`); each in one visible state on the reader's card, a
/// failure kept with the runner's reason instead of swallowed. The decisions are `HeedCore`'s (`CatchUp`,
/// `SummaryQueue`, `SummaryCardState`); this runs them.
extension AppModel {
    var summaryMode: AttentionSummaryMode { config.attention.summaries }

    /// The thread an item is about, when a reader or a summary loaded it.
    func conversation(for item: AttentionItem) -> ThreadConversation? {
        guard let repo = item.repo, let number = item.number else { return nil }
        return conversation(repo, number)
    }

    func catchUpFreshness(_ item: AttentionItem) -> CatchUpFreshness {
        CatchUp.freshness(
            attention.catchUps[item.id], item: item, conversation: conversation(for: item), detail: detail(of: item),
            viewer: github.viewer
        )
    }

    /// What the reader's card shows for the item.
    func summaryCard(_ item: AttentionItem) -> SummaryCardState {
        SummaryCardState.of(
            summary: attention.catchUps[item.id], freshness: catchUpFreshness(item),
            run: attention.summaryRuns[item.id], failure: attention.summaryFailures[item.id], mode: summaryMode,
            modelCalls: config.llm.enabled
        )
    }

    /// A row's preview: the summary's first line once it is written and up to date.
    func summaryPreview(_ item: AttentionItem) -> String? {
        guard catchUpFreshness(item) == .upToDate else { return nil }
        return attention.catchUps[item.id]?.firstLine
    }

    private func summaryDue(_ item: AttentionItem, _ trigger: SummaryQueue.Trigger, running: Bool? = nil) -> Bool {
        SummaryQueue.due(
            item, trigger: trigger, mode: summaryMode, modelCalls: config.llm.enabled,
            freshness: catchUpFreshness(item), failure: attention.summaryFailures[item.id],
            running: running ?? (attention.summaryRuns[item.id] != nil), now: Clock.now,
            backoff: Double(config.llm.backoffMinutes) * 60
        )
    }

    /// The reader opened a thread (after a moment on it): its summary, when one is due.
    func summarizeOnOpen(_ item: AttentionItem) {
        guard !isFixture, summaryDue(item, .open) else { return }
        Task { await writeSummary(item, priority: .background) }
    }

    /// `attention.summarize` (`U`, ↻ on the card): the summary under the cursor written again now, ahead of
    /// background calls and past the daily cap.
    func attentionSummarize() {
        guard let item = (attentionTargets.first ?? attentionSelected)?.item else { return }
        guard config.llm.enabled else {
            say("model calls are off ([llm] enabled): Settings › Model calls turns them on")
            return
        }
        guard summaryMode != .off else {
            say("summaries are off ([attention] summaries): Settings › Attention turns them on")
            return
        }
        guard SummaryQueue.summarizable(item) else {
            say("only an issue or a PR has a summary")
            return
        }
        guard attention.summaryRuns[item.id].map({ $0.queued }) ?? true else {
            say("already summarizing")
            return
        }
        guard !isFixture else {
            say("summarizing")
            return
        }
        Task { await writeSummary(item, priority: .interactive) }
    }

    /// Writes the item's catch-up summary: the thread as it is now, only what is new since you last looked (or the
    /// whole of it), through heed's model calls. A failure is kept with its reason. False when the model call
    /// failed (the ahead queue stops there); a thread that could not be loaded is not the runner's failure.
    @discardableResult
    func writeSummary(_ item: AttentionItem, priority: LLMRequest.Priority) async -> Bool {
        guard let repo = item.repo, let number = item.number else { return true }
        let id = item.id
        attention.summaryRuns[id] = SummaryRun(startedAt: Clock.now)
        defer { attention.summaryRuns[id] = nil }
        let thread: ThreadConversation
        do {
            thread = try await currentConversation(
                repo, number, updatedAt: item.updatedAt, caller: "attention.summary"
            )
        } catch {
            attention.summaryFailures[id] = SummaryFailure.of(error, at: Clock.now, forUpdate: item.updatedAt)
            return true
        }
        let input = CatchUp.input(
            thread, seenAt: attention.seen.threads[id], viewer: github.viewer, previous: attention.catchUps[id]
        )
        do {
            let written = try await summarizer.write(
                kind: .catchUp, inputs: CatchUp.inputs(for: item, conversation: thread, input: input),
                instructions: summaryInstructions(for: repo), caller: "attention.summary", priority: priority,
                onStart: { [weak self] agent, model in
                    Task { @MainActor in
                        self?.attention.summaryRuns[id]?.agent = agent
                        self?.attention.summaryRuns[id]?.model = model
                    }
                }
            )
            attention.saveCatchUp(CatchUpSummary(
                text: written.text, since: input.since, coversUpTo: input.coversUpTo, count: input.count,
                state: input.state, writtenAt: Clock.now, agent: written.agent, model: written.model
            ), for: id)
            return true
        } catch {
            attention.summaryFailures[id] = SummaryFailure.of(error, at: Clock.now, forUpdate: item.updatedAt)
            return false
        }
    }

    /// After a sync, with `[attention] summaries = "ahead"`: a summary for every thread in For you's New that has
    /// none up to date, newest first, as many as the day's model calls allow (`SummaryQueue.budget`), a few at a
    /// time (one fewer than `[llm] concurrency`, so what you ask for gets a slot). A failed call stops the run:
    /// the runner's back-off or cap would fail the rest the same way.
    func queueAheadSummaries() {
        guard !isFixture, config.llm.enabled, summaryMode == .ahead, attention.summaryProgress == nil else { return }
        let listing = AttentionListing.of(attentionEntries, filter: .forYou, seen: attention.seen, now: Clock.now)
        let new = listing.section(.new).map { Array(listing.rows[$0.range]) } ?? []
        guard !new.isEmpty else { return }
        let settings = config.llm
        let agents = llmStatuses.isEmpty
            ? config.work.agents.filter { LLMDialect.of($0) != nil }.map(\.name)
            : llmStatuses.filter(\.usable).map(\.name)
        let runner = llm
        attention.summaryProgress = SummaryProgress(total: 0)
        Task {
            let spent = await runner.spentToday()
            let budget = SummaryQueue.budget(settings: settings, spent: spent, agents: agents)
            let plan = SummaryQueue.ahead(new, budget: budget) { summaryDue($0, .ahead) }
            if plan.cut > 0 {
                NSLog("heed: \(plan.cut) summaries in New wait for the next day's model calls (or for being opened)")
            }
            await runAhead(plan.ids, width: max(1, settings.concurrency - 1))
        }
    }

    private func runAhead(_ ids: [String], width: Int) async {
        defer {
            attention.summaryProgress = nil
            for id in ids where attention.summaryRuns[id]?.queued == true {
                attention.summaryRuns[id] = nil
            }
        }
        guard !ids.isEmpty else { return }
        attention.summaryProgress = SummaryProgress(total: ids.count)
        for id in ids {
            attention.summaryRuns[id] = SummaryRun(startedAt: Clock.now, queued: true)
        }
        var next = 0
        while next < ids.count {
            let chunk = ids[next ..< min(next + width, ids.count)]
            next += chunk.count
            // Each as it is now; one opened (and summarized) meanwhile is not written twice.
            let items = chunk.compactMap { id in
                attentionEntries.first { $0.id == id }?.item
            }.filter { summaryDue($0, .ahead, running: false) && attention.summaryRuns[$0.id]?.queued == true }
            let results = await withTaskGroup(of: Bool.self) { group in
                for item in items {
                    group.addTask { await self.writeSummary(item, priority: .background) }
                }
                var results: [Bool] = []
                for await result in group {
                    results.append(result)
                }
                return results
            }
            attention.summaryProgress?.done += chunk.count
            if results.contains(false) { return }
        }
    }
}
