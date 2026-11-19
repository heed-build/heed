import AppKit
import HeedCore

/// Browse with more than one item picked: one session for the related ones, a goal from all, a session each, and
/// GitHub writes to all of them. What is decided is `HeedCore`'s (`BrowseGrouping`, `BrowseBulk`, `BrowseBulkForm`);
/// this runs them. The agent verbs are for one item.
extension AppModel {
    /// The picked items, in the list's order.
    var browseBulkItems: [BrowseItem] {
        let ids = pickedIDs(.browse)
        return browse.rows.filter { ids.contains($0.id) }
    }

    /// heed's grouping of the picked items (nothing when none hang together).
    var browseBulkGroup: BrowseGroup? { BrowseGrouping.suggest(browseBulkItems, reads: browse.reads) }

    func performBrowseBulk(_ command: CommandInvocation) {
        switch command.name {
        case "browse.select.all":
            let ids = Set(browse.rows.map(\.id))
            pick(pickedIDs(.browse) == ids ? [] : ids, in: .browse)
        case "browse.bulk.session": browseBulkSession()
        case "browse.bulk.each": browseBulkEach()
        case "browse.bulk.goal": browseBulkGoal()
        case "browse.bulk.label": browseBulkOpen { .init(typing: .label, items: $0, viewer: $1) }
        case "browse.bulk.comment": browseBulkOpen { .init(typing: .comment, items: $0, viewer: $1) }
        case "browse.bulk.assign": browseBulkOpen { .init(assigning: $0, viewer: $1) }
        case "browse.bulk.close": browseBulkOpen { .init(closing: $0, viewer: $1) }
        default: break
        }
    }

    private func browseBulkOpen(_ make: ([BrowseItem], String?) -> BrowseBulkForm) {
        let items = browseBulkItems
        guard !items.isEmpty else { return say("pick items first: space picks, v a range, a all") }
        browse.bulk = make(items, browseViewer)
    }

    // MARK: Sessions

    /// `s`: one session for the related group heed noticed (the picks narrow to it), else for all the picks. Start
    /// work opens with the prompt: each issue and its `Closes` line.
    private func browseBulkSession() {
        let items = browseBulkItems
        guard items.count >= 2 else { return say("pick two items or more: space picks, v a range, a all") }
        if let group = BrowseGrouping.suggest(items, reads: browse.reads) { pick(Set(group.ids), in: .browse) }
        perform(CommandInvocation(name: "items.start"))
    }

    /// `S`: a Start work for each item, one after the other; more than five asks first.
    private func browseBulkEach() {
        let items = browseBulkItems
        guard items.count >= 2 else { return say("pick two items or more: space picks, v a range, a all") }
        if BrowseBulk.eachNeedsConfirm(items.count) {
            browse.bulk = BrowseBulkForm(each: items, viewer: browseViewer)
        } else {
            startEach(items)
        }
    }

    private func startEach(_ items: [BrowseItem]) {
        let prompts = items.map { item -> String in
            if let verb = browseVerbs(item).recommended?.verb {
                return BrowseWorkPrompts.prompt(verb, item: item).text
            }
            return BrowseWorkPrompts.told("", item: item).text
        }
        guard let first = items.first else { return }
        clearPicks()
        browse.eachQueue = Array(prompts.dropFirst())
        say("\(items.count) sessions: this is the first, the rest open as each closes")
        openStartWork(
            prompt: prompts[0],
            context: StartContext(repos: [first.repo.slug], label: "\(first.repo.name)#\(first.number)")
        )
    }

    /// A Start work form closed: the next of a "session for each" opens.
    func browseEachNext() {
        guard !browse.eachQueue.isEmpty, startWork == nil else { return }
        let prompt = browse.eachQueue.removeFirst()
        let rest = browse.eachQueue.count
        say(rest == 0 ? "the last of the sessions" : "next session: \(rest) more after it")
        openStartWork(prompt: prompt, fromCursor: false)
    }

    // MARK: A goal

    /// `G`: a goal from the picked items. The goal is made with each item on it (a work item linked to its issue or
    /// pull request) and goes to its wizard, which plans it with you before anything runs. The least invasive path:
    /// the goal's own create and add-item operations, not a new item source (a source is a query, and picks are
    /// not).
    private func browseBulkGoal() {
        let items = browseBulkItems
        guard !items.isEmpty else { return say("pick items first: space picks, v a range, a all") }
        let draft = BrowseBulk.goalDraft(items)
        guard !(isFixture || tutor != nil) else {
            clearPicks()
            return say("fixture: no IO (a goal “\(draft.title)” would be made, each item on it)")
        }
        let now = Clock.now
        clearPicks()
        goals.run { ops in
            let goal = try await ops.create(title: draft.title, statement: draft.statement, now: now)
            for item in items {
                try await ops.addItem(
                    goal: goal.id, title: item.title.display, source: .you,
                    links: [.init(item.kind == .pull ? .pr : .issue, item.place)], reason: "picked in Browse", now: now
                )
            }
            return goal
        } done: { [weak self] result in
            guard let self else { return }
            switch result {
            case let .success(goal):
                say("goal \(goal.title) made with \(items.count) items: the wizard plans it with you")
                startWizard(goal.id, firstMessage: draft.statement)
            case let .failure(error): say("no goal made: \(error)")
            }
        }
    }

    // MARK: GitHub writes

    func answerBrowseBulk(_ stroke: KeyStroke) {
        guard var form = browse.bulk else { return }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            for character in (text.split(separator: "\n").first ?? "").prefix(600) {
                _ = form.handle(KeyStroke(character == " " ? "Space" : String(character)))
            }
            browse.bulk = form
            return
        }
        let action = form.handle(stroke)
        browse.bulk = form
        switch action {
        case .none, .changed: break
        case .close:
            let wasReport = if case .report = form.stage { true } else { false }
            browse.bulk = nil
            if wasReport { clearPicks() }
        case .startEach:
            browse.bulk = nil
            startEach(form.items)
        case let .run(plan): runBrowseBulk(plan, items: form.items)
        }
    }

    private func runBrowseBulk(_ plan: BrowsePlan, items: [BrowseItem]) {
        let fake = isFixture || tutor != nil
        Task { [weak self] in
            let report = await BrowseBulk.run(plan, items: items) { action, item in
                if fake { return }
                try await BrowseBulk.write(action, item: item)
            }
            guard let self else { return }
            browse.bulk?.finished(report)
            // The list shows what was written at once; the next fetch confirms it.
            let done = Set(report.entries.filter { $0.outcome == .done }.map(\.itemID))
            let changed = items.filter { done.contains($0.id) }.map { BrowseBulk.updated($0, by: plan.action) }
            browse.apply(changed)
            say(report.summary)
        }
    }
}
