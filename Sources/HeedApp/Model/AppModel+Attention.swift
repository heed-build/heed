import AppKit
import Foundation
import HeedCore

/// Attention's glue on the app model: its items from the domain, its rows, and what its commands do. Its state lives in
/// `AttentionModel` (`attention`); this only reads the domain and runs commands.
extension AppModel {
    /// PRs the pilot is driving (getting green, feeding back, waiting on checks): their CI is the pilot's to act on,
    /// so it is no reason in Attention until the pilot stalls or needs you.
    var pilotDriving: Set<PullRef> {
        let driving: Set<PilotStatus.Group> = [.failing, .changes, .feeding, .pending]
        return Set(sessions.flatMap(\.trackedPRs).filter { driving.contains(pilotStatus(for: $0).group) })
    }

    /// Every Attention item, from the domain as it is now (the fake world adds its team mentions).
    var attentionItems: [AttentionItem] {
        var state = github
        if isFixture { state.inbox += Fixtures.attentionInbox }
        return AttentionFeed.items(
            github: state, sessions: sessions, details: attention.details, pilotDriving: pilotDriving,
            readyToMerge: readyToMergeRefs
        )
    }

    var attentionEntries: [AttentionEntry] {
        AttentionRanking.entries(
            live: attentionItems, stored: attention.stored.map(\.item), rules: config.attention.parsedRules,
            marks: attention.marks, viewer: github.viewer, now: Clock.now
        )
    }

    /// What the view lists: the filter, the sort, and `/`.
    var attentionRows: [AttentionEntry] {
        let text = filter(for: .attention)
        return AttentionRanking.list(attentionEntries, filter: attention.filter, sort: attention.sort, now: Clock.now)
            .filter { entry in
                let item = entry.item
                return FilterQuery.matches(
                    text,
                    [item.title, item.place, item.author ?? ""] + item.orderedReasons.map(\.text) + item.labels
                        + item.teams.sorted()
                )
            }
    }

    var attentionCounts: [AttentionFilter: Int] { AttentionRanking.counts(attentionEntries, now: Clock.now) }

    /// The row under the cursor.
    var attentionSelected: AttentionEntry? {
        let rows = attentionRows
        let index = cursor(in: .attention)
        return rows.indices.contains(index) ? rows[index] : nil
    }

    /// What the actions act on: the picked rows, else the one under the cursor (or the one right-clicked).
    private var attentionTargets: [AttentionEntry] {
        let ids = Set(actionIDs(.attention))
        return attentionRows.filter { ids.contains($0.id) }
    }

    // MARK: Sync

    /// After a GitHub sync: keeps what Attention shows (so muted and ignored items stay listed for 30 days), fetches
    /// details for threads that are new or changed, and summarizes boosted ones.
    func attentionSynced() async {
        guard !isFixture else { return }
        let now = Clock.now
        await attention.record(attentionItems, now: now)
        noteAttention()
        let needed = AttentionFeed.detailsNeeded(attentionItems, details: attention.details)
        if !needed.isEmpty {
            await attention.saveDetails(GitHub.threadDetails(needed, caller: "attention.details"), now: now)
        }
        for entry in attentionEntries.filter({ $0.live && $0.weight >= 2 && !$0.muted }).prefix(5) {
            summarize(entry.item)
        }
    }

    /// The items rules say to notify about, into `Notices` as one input: several from one sync come as one
    /// notification. What was there before heed's first sync is not news.
    func noteAttention() {
        let settings = config.notifications
        let entries = settings.enabled && settings.attention
            ? attentionEntries.compactMap { Notices.attention($0, now: Clock.now) } : []
        Notifier.shared.sync(
            .attention, entries, settings: settings, seen: !attention.notified, timing: Notices.attentionTiming
        )
        attention.notified = true
    }

    /// A notification's Open: Attention, on the item.
    func showAttentionItem(_ id: String) {
        attention.filter = attentionEntries.first { $0.id == id }?.muted == true ? .muted : .needsMe
        view = .attention
        moveCursor(.attention, to: id)
        activateHeed()
    }

    // MARK: Commands

    /// `view.attention [filter]`: `gm` opens it, `gi` with Issues, `gp` with My PRs.
    func openAttention(_ name: String?) {
        if let name {
            guard let filter = AttentionFilter(rawValue: name) else {
                say("no Attention filter named \(name)")
                return
            }
            if filter != attention.filter {
                attention.filter = filter
                itemCursor[.attention] = 0
            }
        }
        view = .attention
        attentionSelectionChanged()
    }

    /// `attention.filter [name]`: the next filter, or the one named.
    func cycleAttentionFilter(_ name: String?) {
        if let name {
            guard let filter = AttentionFilter(rawValue: name) else {
                say("no Attention filter named \(name)")
                return
            }
            attention.filter = filter
        } else {
            let all = AttentionFilter.allCases
            attention.filter = all[(all.firstIndex(of: attention.filter)! + 1) % all.count]
        }
        itemCursor[.attention] = 0
        attentionSelectionChanged()
    }

    func toggleAttentionSort() {
        attention.sort = attention.sort == .recent ? .weight : .recent
        itemCursor[.attention] = 0
        say(attention.sort.title.lowercased())
    }

    /// `x`: done. The thread is marked read on GitHub; heed hides it until something new happens in it.
    func attentionDone() {
        let targets = attentionTargets
        guard !targets.isEmpty else { return }
        let now = Clock.now
        for entry in targets {
            var mark = entry.mark
            mark.doneAt = max(now, entry.item.updatedAt)
            attention.setMark(mark, for: entry.id)
        }
        let threads = targets.compactMap(\.item.notificationID)
        if !threads.isEmpty { commit(.inboxRead(threads)) }
        clearPicks()
        say(targets.count == 1 ? "done" : "done with \(targets.count)")
        recordLabel(.done, targets)
        guard !isFixture, !threads.isEmpty else { return }
        Task {
            for thread in threads {
                try? await GitHub.markRead(threadID: thread, caller: "attention.done")
            }
        }
    }

    /// `Z`: out of the feed until later; local, nothing is told to GitHub.
    func attentionSnooze(_ argument: String?) {
        let targets = attentionTargets
        guard !targets.isEmpty else { return }
        guard let until = AttentionText.snoozeEnd(argument, now: Clock.now) else {
            say("snooze for 30m, 3h, 2d or until tomorrow")
            return
        }
        for entry in targets {
            var mark = entry.mark
            mark.snoozedUntil = until
            attention.setMark(mark, for: entry.id)
        }
        clearPicks()
        let day = until.timeIntervalSince(Clock.now) > 20 * 3600
        say("snoozed until \(until.formatted(date: day ? .abbreviated : .omitted, time: .shortened))")
        recordLabel(.snooze, targets)
    }

    /// `M`: mute the thread on GitHub (its subscription ignored, so it holds everywhere); listed under Muted.
    func attentionMute() {
        let targets = attentionTargets.filter { $0.item.notificationID != nil }
        guard !targets.isEmpty else {
            say("only a GitHub notification thread can be muted")
            return
        }
        for entry in targets {
            var mark = entry.mark
            mark.mutedAt = Clock.now
            attention.setMark(mark, for: entry.id)
        }
        clearPicks()
        say(targets.count == 1 ? "muted" : "muted \(targets.count)")
        recordLabel(.mute, targets)
        guard !isFixture else { return }
        let threads = targets.compactMap(\.item.notificationID)
        Task {
            for thread in threads {
                do {
                    try await GitHub.muteThread(threadID: thread, caller: "attention.mute")
                } catch {
                    say("could not mute on GitHub: \(error)")
                }
            }
        }
    }

    /// `gS`: the session the item belongs to (an agent's own, or one tracking the thread).
    func attentionGoToSession() {
        guard let entry = attentionTargets.first ?? attentionSelected else { return }
        guard let id = entry.item.session, sessions.contains(where: { $0.id == id }) else {
            say("no session for this one")
            return
        }
        view = .sessions
        select(sessionID: id)
    }

    /// `R`: a reply drafted by the model, shown in full; posting it is a GitHub write you confirm.
    func attentionReply() {
        guard let entry = attentionTargets.first ?? attentionSelected, let repo = entry.item.repo,
              let number = entry.item.number, entry.item.kind == .pr || entry.item.kind == .issue
        else {
            say("a reply needs an issue or PR")
            return
        }
        let item = entry.item
        if isFixture {
            attention.draft = (item.id, Fixtures.attentionDraft)
            confirmReply(item, repo: repo, number: number, text: Fixtures.attentionDraft)
            return
        }
        guard config.llm.enabled else {
            say("drafting a reply needs heed's model calls ([llm] enabled)")
            return
        }
        attention.draft = (item.id, nil)
        let inputs = AttentionText.inputs(for: item, detail: detail(of: item))
        let instructions = summaryInstructions(for: repo)
        Task {
            do {
                let text = try await summarizer.summarize(
                    kind: .reply, inputs: inputs, instructions: instructions, caller: "attention.reply",
                    priority: .interactive
                )
                attention.draft = (item.id, text)
                confirmReply(item, repo: repo, number: number, text: text)
            } catch {
                attention.draft = nil
                say("could not draft a reply: \(error)")
            }
        }
    }

    private func confirmReply(_ item: AttentionItem, repo: Repo, number: Int, text: String) {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        ask(Confirmation(
            title: "Post this reply on \(repo.slug)#\(number)?",
            lines: Array(lines.prefix(14)) + (lines.count > 14 ? ["…"] : []),
            kept: ["Nothing is posted unless you say so. Copy it to edit it on GitHub."],
            accept: "Post", cancel: "Discard", destructive: false,
            action: { [weak self] in self?.postReply(item, repo: repo, number: number, text: text) },
            alternatives: [Confirmation.Alternative(label: "Copy", key: "c") { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self?.say("reply copied")
            }],
            onCancel: { [weak self] in self?.attention.draft = nil }
        ))
    }

    private func postReply(_: AttentionItem, repo: Repo, number: Int, text: String) {
        attention.draft = nil
        guard !isFixture else { return }
        Task {
            do {
                try await GitHub.comment(repo: repo, number: number, body: text, caller: "attention.reply")
                say("reply posted on \(repo.name)#\(number)")
            } catch {
                say("could not post: \(error)")
            }
        }
    }

    // MARK: Detail and summaries

    func detail(of item: AttentionItem) -> ThreadDetail? {
        item.url.flatMap { attention.details[$0.lowercased()] }
    }

    /// The cursor moved in Attention: after a moment on the row, its details and summary are fetched (each once per
    /// update of the thread).
    func attentionSelectionChanged() {
        guard view == .attention, !isFixture, let item = attentionSelected?.item else { return }
        Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard view == .attention, attentionSelected?.item.id == item.id else { return }
            await fetchDetail(item)
            summarize(item)
            suggestWeight(item)
        }
    }

    private func fetchDetail(_ item: AttentionItem) async {
        guard item.kind == .pr || item.kind == .issue, let url = item.url else { return }
        if let known = detail(of: item), known.updatedAt >= item.updatedAt { return }
        await attention.saveDetails(
            GitHub.threadDetails([(url, item.updatedAt)], caller: "attention.details"), now: Clock.now
        )
    }

    /// Writes the item's summary with the cheap model, unless there is one for this update (or one on the way).
    func summarize(_ item: AttentionItem) {
        guard !isFixture, config.llm.enabled, item.kind != .agent, !attention.summarizing.contains(item.id),
              attention.summary(for: item) == nil
        else { return }
        attention.summarizing.insert(item.id)
        let inputs = AttentionText.inputs(for: item, detail: detail(of: item))
        let instructions = summaryInstructions(for: item.repo)
        Task {
            defer { attention.summarizing.remove(item.id) }
            if await attention.loadSummary(for: item) != nil { return }
            guard let text = try? await summarizer.summarize(
                kind: .thread, inputs: inputs, instructions: instructions, caller: "attention.summary"
            ) else { return }
            attention.saveSummary(text, for: item)
        }
    }

    /// Settings' try before you save: what `rules` would change, against the rules in use, over the items of the last
    /// 30 days (live and remembered).
    func attentionPreview(_ rules: AttentionRules) -> AttentionRulePreview {
        let live = attentionItems
        let ids = Set(live.map(\.id))
        let items = live + attention.stored.map(\.item).filter { !ids.contains($0.id) }
        return AttentionRulePreview.of(
            saved: config.attention.parsedRules, edited: rules, items: items, viewer: github.viewer, now: Clock.now
        )
    }

    /// For an item no rule matched, the Decider suggests a weight: shown next to it, never acted on.
    func suggestWeight(_ item: AttentionItem) {
        guard !isFixture, config.llm.enabled, attentionEntries.first(where: { $0.id == item.id })?.outcome.rule == nil
        else { return }
        if let known = attention.suggestions[item.id], known.updatedAt >= item.updatedAt { return }
        attention.suggestions[item.id] = (item.updatedAt, nil)
        let state = AttentionDecide.state(for: item, detail: detail(of: item))
        let decider = decider(caller: "attention.rank")
        Task {
            guard let answers = try? await decider.decide(
                subject: item.id, state: state, questions: AttentionDecide.questions
            ) else { return }
            attention.suggestions[item.id] = (item.updatedAt, AttentionDecide.suggestion(answers))
        }
    }

    /// What you did with items, beside the Decider's rows: what a later local model learns from.
    private func recordLabel(_ label: AttentionLabel, _ entries: [AttentionEntry]) {
        guard !isFixture else { return }
        for entry in entries {
            CallLog.record(label.call(
                for: entry.item, rule: entry.outcome.rule, suggestion: attention.suggestions[entry.id]?.level,
                at: Clock.now
            ))
        }
    }

    // MARK: Menus

    func attentionMenu(_ index: Int) -> [MenuEntry] {
        let rows = attentionRows
        guard rows.indices.contains(index) else { return [] }
        let item = rows[index].item
        var facts = ContextMenus.AttentionFacts(
            id: item.id, title: item.number.map { "\(item.repo?.name ?? "") #\($0)" } ?? item.title
        )
        let picked = pickedIDs(.attention)
        facts.count = picked.contains(item.id) ? picked.count : 1
        facts.hasSession = currentSession != nil
        facts.itemSession = item.session.map { id in sessions.contains { $0.id == id } } ?? false
        facts.hasURL = item.url != nil
        facts.hasThread = item.notificationID != nil
        facts.isAgent = item.kind == .agent
        return ContextMenus.attention(facts)
    }
}
