import HeedCore

/// Right-click menus: the facts about what was clicked, read from the model, for `ContextMenus` to build from. Each
/// item runs a command through `perform`, so a menu never does anything a key does not.
extension AppModel {
    /// A session in the sidebar or the rail.
    func sessionMenu(_ id: String) -> [MenuEntry] {
        guard let session = sessions.first(where: { $0.id == id }) else { return [] }
        var facts = ContextMenus.SessionFacts(id: id, title: session.title)
        facts.pulls = session.trackedPRs.count
        facts.openPulls = session.trackedPRs.count { github.pull($0).map { $0.state == .open } ?? true }
        facts.links = links(of: session).count
        facts.hasGitHubRepo = session.involvedRepos.contains { $0.org != "local" }
        facts.pilot = pilotFacts(session.trackedPRs, runLive: liveRuns.values.contains { $0.sessionID == id })
        facts.pinned = session.pinned
        facts.parked = session.parked
        facts.hasPrompt = !session.prompt.isEmpty
        facts.handoffAgents = handoffAgents(for: session)
        facts.chat = session.isChat
        return ContextMenus.session(facts)
    }

    /// A PR: a session's card in the inspector, or a PRs or Watch row.
    func pullMenu(_ ref: PullRef, place: ContextMenus.Place) -> [MenuEntry] {
        var facts = ContextMenus.PullFacts(ref: ref, place: place)
        facts.open = github.pull(ref).map { $0.state == .open } ?? true
        facts.pilot = pilotFacts([ref], runLive: liveRuns.values.contains { $0.ref == ref })
        facts.hasSession = sessions.contains { $0.trackedPRs.contains(ref) }
        return ContextMenus.pull(facts)
    }

    /// A run in the inspector.
    func runMenu(_ run: PilotRun) -> [MenuEntry] {
        ContextMenus.run(
            id: run.id, title: "\(run.goal.rawValue) #\(run.ref.number)", running: liveRuns[run.id] != nil
        )
    }

    /// A row of a list view, by position; nil where the view has no menu.
    func rowMenu(_ list: AppView, _ index: Int) -> [MenuEntry] {
        switch list {
        case .prs:
            let rows = pullRows
            return rows.indices.contains(index) ? pullMenu(rows[index].ref, place: .prs) : []
        case .watch:
            let rows = pilotRows
            return rows.indices.contains(index) ? pullMenu(rows[index].ref, place: .watch) : []
        case .inbox:
            let rows = inboxRows
            guard rows.indices.contains(index) else { return [] }
            let row = rows[index]
            var facts = itemFacts(.inbox, id: row.id, title: row.number.map { "\(row.repo.name) #\($0)" } ?? row.title)
            facts.unread = row.unread
            facts.hasURL = row.url != nil
            return ContextMenus.item(facts)
        case .issues:
            let rows = issueRows
            guard rows.indices.contains(index) else { return [] }
            let row = rows[index]
            var facts = itemFacts(.issue, id: row.id, title: "\(row.repo.name) #\(row.number)")
            facts.allIssues = config.issues.visibility(row.repo) == .all
            return ContextMenus.item(facts)
        case .repos:
            let rows = worktreeRows
            guard rows.indices.contains(index) else { return [] }
            let row = rows[index]
            let session = session(for: row)
            var facts = ContextMenus.WorktreeFacts(id: row.id, title: "\(row.repo.name) · \(row.branch ?? "detached")")
            let selected = selectedRows
            facts.count = selected.contains(row.id) ? selected.count : 1
            facts.hasSession = session != nil
            facts.pinned = session?.pinned ?? false
            facts.isMain = row.isMain
            facts.onGitHub = row.repo.org != "local"
            facts.allIssues = config.issues.visibility(row.repo) == .all
            return ContextMenus.worktree(facts)
        case .history:
            let rows = historyRows
            guard rows.indices.contains(index) else { return [] }
            let session = rows[index].session
            return ContextMenus.history(
                id: session.id, title: session.title, hasPrompt: !session.prompt.isEmpty,
                onGitHub: session.repos.contains { $0.org != "local" }
            )
        case .log:
            let rows = callLog.rows
            guard rows.indices.contains(index) else { return [] }
            let call = rows[index]
            return ContextMenus.call(
                id: call.id, title: call.operation ?? call.caller, caller: call.caller, agent: call.agent,
                callerFiltered: callLog.query.caller != nil, agentFiltered: callLog.query.agent != nil
            )
        case .sessions:
            return []
        }
    }

    /// An Inbox or Issues row: the picked rows when it is one of them, else it alone (see `actionIDs`).
    private func itemFacts(_ kind: ContextMenus.ItemFacts.Kind, id: String, title: String) -> ContextMenus.ItemFacts {
        var facts = ContextMenus.ItemFacts(kind: kind, id: id, title: title)
        let picked = pickedIDs(kind == .inbox ? .inbox : .issues)
        facts.count = picked.contains(id) ? picked.count : 1
        facts.hasSession = currentSession != nil
        return facts
    }

    /// A repo in the Issues repo column (nil: its All row).
    func issueRepoMenu(_ repo: Repo?) -> [MenuEntry] {
        ContextMenus.issueRepo(repo, allIssues: repo.map { config.issues.visibility($0) == .all } ?? false)
    }

    /// A tab of the current session.
    func tabMenu(_ id: String) -> [MenuEntry] {
        guard let tab = currentTabs.first(where: { $0.id == id }) else { return [] }
        // Only the tab the agent runs in hands it off.
        let holdsAgent = tab.tree.panes.contains { $0.role == .agent } && !liveRuns.values.contains { $0.tabID == id }
        return ContextMenus.tab(
            id: id, title: tab.title, zoomed: tab.zoomed, runLive: liveRuns.values.contains { $0.tabID == id },
            handoffAgents: holdsAgent ? currentSession.map(handoffAgents) ?? [] : []
        )
    }

    /// The agents a session can be handed to: every configured one but its own.
    private func handoffAgents(for session: Session) -> [String] {
        Handoff.candidates(agents: settings.agents.map(\.name), current: session.agent)
    }

    /// The pilot as the commands see it for these PRs: watch and pause toggle on all of them, green and merge cycle
    /// from the first (see `togglePilotWatch`, `pausePilot`, `cyclePilotGreen`, `togglePilotMerge`).
    private func pilotFacts(_ refs: [PullRef], runLive: Bool) -> ContextMenus.PilotFacts {
        var facts = ContextMenus.PilotFacts()
        guard let first = refs.first else { return facts }
        facts.watching = refs.allSatisfy { pilot(for: $0).watching }
        facts.green = pilot(for: first).green != .off
        facts.merging = pilot(for: first).merge != .off
        facts.paused = refs.allSatisfy { feedback[$0.description]?.isPaused(Clock.now) == true }
        facts.stalled = refs.contains { if case .stalled = pilotStatus(for: $0) { true } else { false } }
        facts.runLive = runLive
        facts.reviewers = refs.contains { !pilotSettings(for: $0).reviewers.isEmpty }
        return facts
    }

    /// A file in the diff overlay's list (`row` nil), or a line of its unified diff.
    func diffMenu(file: Int, row: Int?) -> [MenuEntry] {
        guard diffFiles.indices.contains(file) else { return [] }
        return ContextMenus.diff(
            file: file, row: row ?? 0, path: diffFiles[file].path, line: row != nil, split: diffSplit,
            hasCommits: !diffCommits.isEmpty
        )
    }

    /// A feedback item in the PR overlay or reader, or one of the session's own notes.
    func feedbackMenu(_ item: FeedbackItem) -> [MenuEntry] {
        let line = item.promptLine
        var facts = ContextMenus.FeedbackFacts(id: item.id, title: line.count > 60 ? line.prefix(59) + "…" : line)
        facts.queueable = item.status == .new || item.status == .queued
        facts.queued = item.status == .queued
        facts.anyQueued = feedbackItems.contains { $0.status == .queued }
        facts.onPull = feedbackPull != nil
        return ContextMenus.feedback(facts)
    }

    /// A right-click in the diff overlay or the PR overlay points its cursor at what was clicked.
    func rightClickDiff(file: Int, row: Int?) -> Bool {
        guard clicksReachLists else { return false }
        pointDiff(file: file, row: row ?? 0)
        return true
    }

    func rightClickFeedback(_ id: String) -> Bool {
        guard clicksReachLists else { return false }
        pointFeedback(id)
        return true
    }

    /// A right-click on a session selects it, as a click does, without typing into it.
    func rightClickSession(_ id: String) -> Bool {
        guard clicksReachLists else { return false }
        clickSession(id)
        return true
    }

    /// A right-click on a list row moves the cursor there, as a click does.
    func rightClickRow(_ list: AppView, _ index: Int) -> Bool {
        guard clicksReachLists, view == list, !rowMenu(list, index).isEmpty else { return false }
        clickRow(list, index)
        return true
    }

    /// A right-click on a tab selects it, as a click does.
    func rightClickTab(_ index: Int) -> Bool {
        guard clicksReachLists else { return false }
        clickedOutsideTerminal()
        selectTab(index)
        return true
    }

    /// A right-click in the inspector or the Issues repo column acts on what it names; it only hands the keyboard
    /// back to heed.
    func rightClickNamed() -> Bool {
        guard clicksReachLists else { return false }
        clickedOutsideTerminal()
        return true
    }
}
