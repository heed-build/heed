import Foundation
import HeedCore

/// heed's read of Browse's items (`BrowseRead`) and the verbs an agent can be sent with. The decisions are
/// `HeedCore`'s (`BrowseReadQueue`, `BrowseReadState`, `BrowseVerbs`, `BrowseWorkPrompts`); this runs them. A read is
/// one cheap model call over the item's title, labels, a cut of its description and its last comments; it is kept
/// in `browse.sqlite` on this Mac and never written to GitHub. Never in the fake world.
extension AppModel {
    var browseReadMode: AttentionSummaryMode { config.browse.reads }

    /// Who you are, as the verbs and the rows read it (the fake world's viewer is `you`).
    var browseViewer: String? { github.viewer ?? (isFixture ? "you" : nil) }

    func browseReadState(_ item: BrowseItem) -> BrowseReadState {
        BrowseReadState.of(
            read: browse.reads[item.id], item: item, run: browse.readRuns[item.id],
            failure: browse.readFailures[item.id], mode: browseReadMode, modelCalls: config.llm.enabled
        )
    }

    /// The four verbs for an item, from heed's read of it (a stale one still counts: it is shown dimmed).
    func browseVerbs(_ item: BrowseItem) -> BrowseVerbs {
        BrowseVerbs.recommend(item: item, read: browse.reads[item.id], viewer: browseViewer)
    }

    private func browseReadDue(_ item: BrowseItem, _ trigger: BrowseReadQueue.Trigger, running: Bool? = nil) -> Bool {
        BrowseReadQueue.due(
            item, read: browse.reads[item.id], trigger: trigger, mode: browseReadMode,
            readAhead: config.browse.readAhead, modelCalls: config.llm.enabled,
            failure: browse.readFailures[item.id], running: running ?? (browse.readRuns[item.id] != nil),
            now: Clock.now, backoff: Double(config.llm.backoffMinutes) * 60
        )
    }

    // MARK: When a read is written

    /// The cursor rested on an item (after a moment): its read, when one is due.
    func browseReadOnOpen(_ item: BrowseItem) {
        guard !isFixture, view == .browse, browseReadDue(item, .open) else { return }
        Task { await writeBrowseRead(item, priority: .background) }
    }

    /// `browse.read` (`U`): the picked items, else the one under the cursor, read now (again when they have a read):
    /// ahead of background calls and past the daily cap, one at a time.
    func browseReadNow() {
        let ids = Set(actionIDs(.browse))
        let items = browse.rows.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        guard config.llm.enabled else {
            return say("model calls are off ([llm] enabled): Settings › Model calls turns them on")
        }
        guard !isFixture else { return say("reading \(items.count == 1 ? "it" : "\(items.count) items")") }
        let wanted = items.filter { browse.readRuns[$0.id].map(\.queued) ?? true }
        guard !wanted.isEmpty else { return say("already reading") }
        if wanted.count > 1 { say("reading \(wanted.count) items, one at a time") }
        for item in wanted {
            browse.readRuns[item.id] = SummaryRun(startedAt: Clock.now, queued: wanted.count > 1)
        }
        Task {
            for item in wanted {
                guard browse.readRuns[item.id] != nil else { continue }
                browse.readRuns[item.id] = SummaryRun(startedAt: Clock.now)
                if await !writeBrowseRead(item, priority: .interactive) {
                    for rest in wanted where browse.readRuns[rest.id]?.queued == true {
                        browse.readRuns[rest.id] = nil
                    }
                    return
                }
            }
        }
    }

    /// Writes one item's read: the thread as it is now (the description and last comments; the read goes on with the
    /// title and labels alone when the thread cannot be loaded), the cheap model's JSON answer, parsed by
    /// `BrowseReadParser`. A failure is kept with its reason. False when the model call failed (the queue stops
    /// there: the runner's back-off or cap would fail the rest the same way).
    @discardableResult
    func writeBrowseRead(_ item: BrowseItem, priority: LLMRequest.Priority) async -> Bool {
        let id = item.id
        browse.readRuns[id] = SummaryRun(startedAt: Clock.now)
        defer { browse.readRuns[id] = nil }
        let thread = try? await currentConversation(
            item.repo,
            item.number,
            updatedAt: item.updatedAt,
            caller: "browse.read"
        )
        let inputs = BrowseReadInputs.inputs(item, conversation: thread)
        let candidates = BrowseDuplicates.candidates(for: item, in: browse.items)
        do {
            let written = try await summarizer.write(
                kind: .browseRead, inputs: inputs, instructions: summaryInstructions(for: item.repo),
                caller: BrowseReadParser.caller, priority: priority,
                onStart: { [weak self] agent, model in
                    Task { @MainActor in
                        self?.browse.readRuns[id]?.agent = agent
                        self?.browse.readRuns[id]?.model = model
                    }
                }
            )
            guard let read = BrowseReadParser.parse(
                written.text, item: item, duplicates: candidates, now: Clock.now, agent: written.agent,
                model: written.model
            ) else {
                browse.readFailures[id] = SummaryFailure(
                    kind: .failed, text: "\(written.agent) answered with nothing heed could use", at: Clock.now,
                    forUpdate: item.updatedAt
                )
                return true
            }
            browse.keepRead(read)
            return true
        } catch {
            browse.readFailures[id] = SummaryFailure.of(error, at: Clock.now, forUpdate: item.updatedAt)
            return false
        }
    }

    /// After a view settled (entered, a fetch landed, the query changed): the top rows of the view that heed has not
    /// read (or whose read is stale) get one, in the order of the list, as many as the day's model calls allow
    /// (`SummaryQueue.budget`), one at a time, in the background. Not in the fake world, and only while Browse is
    /// what you are looking at.
    func queueAheadBrowseReads() {
        guard !isFixture, view == .browse, config.llm.enabled, browseReadMode == .ahead,
              config.browse.readAhead > 0, browse.readProgress == nil else { return }
        let top = config.browse.readAhead
        let rows = browse.readCandidates()
        let settings = config.llm
        let agents = llmStatuses.isEmpty
            ? config.work.agents.filter { LLMDialect.of($0) != nil }.map(\.name)
            : llmStatuses.filter(\.usable).map(\.name)
        let runner = llm
        guard rows.prefix(top).contains(where: { browseReadDue($0, .ahead) }) else { return }
        browse.readProgress = SummaryProgress(total: 0)
        Task {
            let spent = await runner.spentToday()
            let budget = SummaryQueue.budget(settings: settings, spent: spent, agents: agents)
            let plan = BrowseReadQueue.ahead(rows, top: top, budget: budget) { browseReadDue($0, .ahead) }
            if plan.cut > 0 {
                NSLog("heed: \(plan.cut) Browse reads wait for the next day's model calls (or for being asked)")
            }
            await runAheadBrowseReads(plan.ids)
        }
    }

    private func runAheadBrowseReads(_ ids: [String]) async {
        defer {
            browse.readProgress = nil
            for id in ids where browse.readRuns[id]?.queued == true {
                browse.readRuns[id] = nil
            }
        }
        guard !ids.isEmpty else { return }
        browse.readProgress = SummaryProgress(total: ids.count)
        for id in ids {
            browse.readRuns[id] = SummaryRun(startedAt: Clock.now, queued: true)
        }
        for id in ids {
            // One at a time, each as it is now; one read meanwhile (asked, or on open) is not written twice.
            guard view == .browse, let item = browse.items.first(where: { $0.id == id }),
                  browse.readRuns[id]?.queued == true, browseReadDue(item, .ahead, running: false)
            else {
                if browse.readRuns[id]?.queued == true { browse.readRuns[id] = nil }
                browse.readProgress?.done += 1
                continue
            }
            let ok = await writeBrowseRead(item, priority: .background)
            browse.readProgress?.done += 1
            if !ok { return }
        }
    }

    // MARK: The verbs

    /// F, I, C, R: an agent on the item under the cursor. One item at a time. A verb that does not fit says why. Until
    /// the agent view runs them, each opens Start work (or the review helper) with the verb's prompt, so the work
    /// starts the way a session does.
    func browseVerb(_ verb: BrowseVerb) {
        let ids = actionIDs(.browse)
        guard ids.count <= 1, let item = browseSelected else {
            return say("\(verb.title) works on one item at a time: clear the picks first")
        }
        let advice = browseVerbs(item)[verb]
        guard advice.availability != .unavailable else { return say("\(verb.title): \(advice.reason)") }
        switch verb {
        case .review where item.kind == .pull:
            startReview(PullRef(repo: item.repo, number: item.number), title: item.title.display)
        case .chat:
            openStartWork(
                prompt: BrowseWorkPrompts.prompt(.chat, item: item).text, fromCursor: false, chat: true
            )
        default:
            openStartWork(prompt: BrowseWorkPrompts.prompt(verb, item: item).text)
        }
    }

    /// `t` and the line under the buttons: Start work on the item, the prompt ready for what you want done.
    func browseTell() {
        guard let item = browseSelected else { return }
        openStartWork(prompt: BrowseWorkPrompts.told("", item: item).text)
    }
}
