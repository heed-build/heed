import AppKit
import Foundation
import HeedCore

/// Helpers on the app model: heed's next step for an Attention item and its one key, and the helpers themselves,
/// agents heed starts over ACP (`ACPClient`) in worktrees of their own, drawn in a split it owns. A helper never
/// types into your session and never pushes or posts until you approve its close-out (or the repo's Always).
/// The domain is `HeedCore`'s (`HelperRun`, `NextStep`, `HelperPrompt`, `HelperGit`); this runs the IO, off the main
/// actor, and the keys.
extension AppModel {
    // MARK: heed's next step

    /// What decides an item's next step, from the domain.
    func nextStepFacts(_ item: AttentionItem) -> NextStep.Facts {
        var facts = NextStep.Facts(viewer: github.viewer)
        guard let repo = item.repo, let number = item.number else { return facts }
        let ref = PullRef(repo: repo, number: number)
        if let helper = helpers.current(on: ref) { facts.helper = helper.kind }
        guard item.kind == .pr else { return facts }
        let open = (feedback[ref.description]?.items ?? []).filter { $0.status != .resolved }
        var checks: [String] = open.compactMap { item in
            if case let .check(name) = item.kind { return name }
            return nil
        }
        var comments = open.count { if case .review = $0.kind { true } else { false } }
        let detail = pullDetails[ref.description]
        if checks.isEmpty, comments == 0, let detail {
            checks = detail.failingChecks.map(\.name)
            comments = detail.threads.count { !$0.isResolved }
        }
        facts.failingChecks = Array(NSOrderedSet(array: checks)) as? [String] ?? checks
        facts.reviewComments = comments
        facts.approvalsNeeded = detail?.reviewDecision == "REVIEW_REQUIRED" ? 1 : 0
        if detail?.mergeable == "CONFLICTING" { facts.conflictBase = detail?.baseBranch }
        facts.status = pilotStatus(for: ref)
        facts.mergeOn = pilot(for: ref).merge != .off
        facts.autopilotSetUp = config.pilot.repos[repo.slug] != nil || config.pilot.orgs[repo.org] != nil
        return facts
    }

    /// heed's own step for an item.
    func nextStep(for item: AttentionItem) -> NextStep? { NextStep.of(item, facts: nextStepFacts(item)) }

    /// The step the proposal shows: heed's own, or another `.` moved it to.
    func proposedStep(for item: AttentionItem) -> NextStep? {
        let own = nextStep(for: item)
        guard let pick = helpers.proposal[item.id], pick > 0 else { return own }
        let others = NextStep.others(item, proposed: own)
        return others.indices.contains(pick - 1) ? others[pick - 1] : own
    }

    /// `D`: heed's next step for the item under the cursor. `always` (Y) first turns the step's Autopilot capability
    /// on for the repo, so heed does it by itself from now on.
    func doNextStep(always: Bool) {
        guard view == .attention, let item = attentionSelected?.item else { return flash = "no item here" }
        guard let step = proposedStep(for: item) else { return flash = "heed has no next step for this" }
        if always {
            guard let capability = step.capability, let repo = item.repo else {
                return flash = "\(step.title) has no Always: it is yours to send each time"
            }
            do {
                try writeAutopilot(AutopilotSwitch.writes(
                    capability, .on, repo: repo, config: config,
                    facts: autopilotFacts[repo.slug] ?? AutopilotRepoFacts()
                ))
            } catch let AutopilotSwitch.Refusal.noChoice(why) {
                return flash = why
            } catch {}
        }
        guard let repo = item.repo, let number = item.number else { return }
        let ref = PullRef(repo: repo, number: number)
        switch step {
        case .review: startReview(ref, title: item.title)
        case .draftReply: perform(CommandInvocation(name: "attention.reply"))
        case .getGreen, .resolveConflict: getItGreen(ref)
        case .merge: perform(CommandInvocation(name: "pilot.merge.now"))
        case let .setUpAutopilot(repo): perform(CommandInvocation(name: "repo.setup", arguments: [repo.slug]))
        case .startWork: perform(CommandInvocation(name: "items.start"))
        case .helping:
            if let helper = helpers.current(on: ref) { openHelper(helper.id) }
        case let .nothing(why): flash = "\(why): nothing to do"
        }
        if always, let capability = step.capability {
            flash = "\(capability.title) on in \(repo.name): heed does this by itself from now on"
        }
    }

    /// `.`: Other, a small menu of the item's other next steps and what else you can do with it; again closes it.
    func otherNextStep() {
        guard view == .attention, let item = attentionSelected?.item, item.repo != nil, item.number != nil,
              item.kind == .pr || item.kind == .issue
        else { return flash = "no other step for this" }
        if helpers.otherMenu == item.id { return helpers.otherMenu = nil }
        helpers.otherMenu = item.id
        helpers.otherRow = 0
        helpers.otherSteps += 1
    }

    /// A command's key as it works in `scope` with no menu over it: Other lists Attention's keys while its own `↩`
    /// shadows the reader's.
    func keyText(for command: String, asIn scope: String) -> String {
        KeyLabels.label(
            for: command, keymaps: engine.keymaps, scoped: engine.scopedKeymaps, scope: scope, mode: mode
        )?.text ?? ":\(command)"
    }

    /// The Other menu's rows for an item.
    func otherMenuEntries(for item: AttentionItem) -> [OtherMenu.Entry] {
        OtherMenu.entries(item, own: nextStep(for: item), proposed: proposedStep(for: item))
    }

    /// The item Other is open for, when it is the one under the cursor.
    var otherMenuItem: AttentionItem? {
        guard view == .attention, let item = attentionSelected?.item, helpers.otherMenu == item.id else { return nil }
        return item
    }

    /// A row of Other: propose that step (heed's own again, or another), or run that action.
    func pickOther(_ entry: OtherMenu.Entry, for item: AttentionItem) {
        helpers.otherMenu = nil
        switch entry {
        case .own:
            helpers.proposal[item.id] = 0
            flash = "back to heed's own step"
        case let .step(step):
            let others = NextStep.others(item, proposed: nextStep(for: item))
            guard let index = others.firstIndex(of: step) else { return }
            helpers.proposal[item.id] = index + 1
            flash = "proposed instead: \(step.title)"
        case let .action(action):
            perform(CommandInvocation(name: action.command))
        }
        updateScope()
    }

    /// Get it green from Attention: every new item of the PR queued, then sent (a helper, by default).
    private func getItGreen(_ ref: PullRef) {
        var pipeline = feedback[ref.description] ?? PullFeedback(ref: ref)
        for index in pipeline.items.indices where pipeline.items[index].status == .new {
            pipeline.items[index].status = .queued
        }
        commit(.feedbackChanged(pipeline))
        deliver(ref, explicit: true)
    }

    // MARK: Which helper shows

    /// The helper drawn in the current view's split: in Attention the item under the cursor's (unless you closed
    /// it), in Sessions the one you watch (Watch it), in Now the tile you opened.
    var visibleHelper: HelperRun? {
        switch view {
        case .attention:
            guard let item = attentionSelected?.item, let repo = item.repo, let number = item.number,
                  let helper = helpers.current(on: PullRef(repo: repo, number: number)),
                  !helpers.hidden.contains(helper.id)
            else { return nil }
            return helper
        case .sessions:
            guard let helper = helpers.run(helpers.shown),
                  currentSession.map({ $0.trackedPRs.contains(helper.ref) || $0.id == helper.sessionID }) == true
            else { return nil }
            return helper
        case .watch: return helpers.run(helpers.shown)
        default: return nil
        }
    }

    /// The scope helper keys take while a helper's split shows: over Attention's, over Now's, or on their own. A
    /// small menu open (Other, the session's helpers) goes first.
    var helperScope: String? {
        if otherMenuItem != nil { return "attentionother" }
        if view == .sessions, helpers.listOpen { return "sessionshelpers" }
        guard visibleHelper != nil else { return nil }
        switch view {
        case .attention: return "attentionhelper"
        case .watch: return "watchhelper"
        default: return "sessionshelper"
        }
    }

    /// The session's helper line: every helper on its PRs, what needs you first, finished ones until seen.
    func helperLine(for session: Session) -> SessionHelperLine? {
        SessionHelperLine.of(
            helpers.runs, tracked: session.trackedPRs, sessionID: session.id, leftAt: helpers.leftAt[session.id],
            dismissed: helpers.dismissed
        )
    }

    /// The helper the sidebar's row and `gO` are about: the first on the session's line that is live or waits for
    /// its close-out.
    func sessionHelper(for session: Session) -> HelperRun? {
        helperLine(for: session)?.entries.lazy.compactMap { self.helpers.run($0.id) }
            .first { $0.phase.isLive || $0.phase.awaitsCloseOut }
    }

    /// The session shown in Sessions changed: the one left counts as looked at now (its finished helpers are seen),
    /// and the helper list closes.
    func noteSessionShown() {
        let now = view == .sessions ? currentSession?.id : nil
        guard now != helpers.lookingAt else { return }
        if let left = helpers.lookingAt { helpers.leftAt[left] = Clock.now }
        helpers.lookingAt = now
        if helpers.listOpen { helpers.listOpen = false }
    }

    private func isClosedOut(_ helper: HelperRun) -> Bool {
        if case .closed = helper.phase { return true }
        return false
    }

    func openHelper(_ id: String) {
        helpers.shown = id
        helpers.hidden.remove(id)
        updateScope()
    }

    // MARK: Commands

    func performHelper(_ command: CommandInvocation) {
        // A click on a menu's row (or its Take it over) names the row.
        if let row = command.arguments.first.flatMap(Int.init) {
            if otherMenuItem != nil { helpers.otherRow = row } else if helpers.listOpen { helpers.listRow = row }
        }
        switch command.name {
        case "helper.do": doNextStep(always: false)
        case "helper.always": doNextStep(always: true)
        case "helper.other": otherNextStep()
        case "helper.watch": watchHelper()
        case "helper.takeover": takeOverHelper()
        case "helper.menu.next": moveMenu(by: 1)
        case "helper.menu.prev": moveMenu(by: -1)
        case "helper.menu.pick": pickMenu()
        case "helper.menu.close":
            helpers.otherMenu = nil
            helpers.listOpen = false
        case "helper.dismiss": dismissHelpers()
        case "helper.tile.next": moveTile(by: 1)
        case "helper.tile.prev": moveTile(by: -1)
        default:
            guard let helper = visibleHelper ?? helpers.run(helpers.shown) else { return flash = "no helper here" }
            performOn(helper, command)
        }
        updateScope()
    }

    private func performOn(_ helper: HelperRun, _ command: CommandInvocation) {
        let id = helper.id
        switch command.name {
        case "helper.steer": helpers.steer = EditableText()
        case "helper.pause": pauseHelper(id)
        case "helper.stop": stopHelper(id, why: "you stopped it")
        case "helper.zoom": helpers.zoomed.toggle()
        case "helper.close":
            helpers.hidden.insert(id)
            if helpers.shown == id { helpers.shown = nil }
            helpers.zoomed = false
        case "helper.allow": answerHelper(id, .allowOnce)
        case "helper.allow.always": answerHelper(id, .allowAlways)
        case "helper.deny": answerHelper(id, .rejectOnce)
        case "helper.push": closeOutHelper(id, replies: true)
        case "helper.push.only": closeOutHelper(id, replies: false)
        case "helper.throwaway": throwAwayHelper(id)
        case "helper.diff": toggleHelperDiff(helper)
        default: flash = "\(command.name): not built yet"
        }
    }

    /// `gW` (Watch it): the session's helper, in a split under its panes; with more than one on its PRs, their list
    /// over the helper line. Again closes either.
    private func watchHelper() {
        if view == .sessions {
            if helpers.listOpen { return helpers.listOpen = false }
            if let shown = visibleHelper {
                helpers.shown = nil
                helpers.hidden.insert(shown.id)
                return
            }
            if let session = currentSession, let line = helperLine(for: session) {
                guard line.entries.count == 1 else {
                    helpers.listOpen = true
                    helpers.listRow = 0
                    return
                }
                return openHelper(line.entries[0].id)
            }
        }
        guard let helper = helpers.active.first else { return flash = "no helper at work" }
        openHelper(helper.id)
    }

    /// `j` `k` in the open menu.
    private func moveMenu(by step: Int) {
        if let item = otherMenuItem {
            let count = otherMenuEntries(for: item).count
            helpers.otherRow = min(max(helpers.otherRow + step, 0), max(count - 1, 0))
        } else if view == .sessions, helpers.listOpen, let session = currentSession {
            let count = helperLine(for: session)?.entries.count ?? 0
            helpers.listRow = min(max(helpers.listRow + step, 0), max(count - 1, 0))
        }
    }

    /// `↩` in the open menu: Other's row, or the session list's helper (watched).
    private func pickMenu() {
        if let item = otherMenuItem {
            let entries = otherMenuEntries(for: item)
            guard entries.indices.contains(helpers.otherRow) else { return }
            return pickOther(entries[helpers.otherRow], for: item)
        }
        guard view == .sessions, helpers.listOpen, let entry = selectedListEntry else { return }
        helpers.listOpen = false
        openHelper(entry.id)
    }

    /// The row under the cursor in the session's helper list.
    var selectedListEntry: SessionHelperLine.Entry? {
        guard helpers.listOpen, let session = currentSession,
              let entries = helperLine(for: session)?.entries, entries.indices.contains(helpers.listRow)
        else { return nil }
        return entries[helpers.listRow]
    }

    /// `x` in the list (a finished helper there), or the line's ✕ (every finished one on it): off the line.
    private func dismissHelpers() {
        if helpers.listOpen {
            guard let entry = selectedListEntry, entry.standing == .finished else {
                return flash = "only a finished helper leaves the line"
            }
            helpers.dismissed.insert(entry.id)
            let count = currentSession.flatMap { helperLine(for: $0) }?.entries.count ?? 0
            if count == 0 { helpers.listOpen = false }
            helpers.listRow = min(helpers.listRow, max(count - 1, 0))
            return
        }
        guard let finished = currentSession.flatMap({ helperLine(for: $0) })?.finished, !finished.isEmpty else {
            return flash = "no finished helper on this session"
        }
        helpers.dismissed.formUnion(finished.map(\.id))
    }

    /// Now's live tiles: `h` `l` move between them; `j` back in the list leaves them.
    private func moveTile(by step: Int) {
        let count = helpers.active.count
        guard count > 0 else { return flash = "no helper at work" }
        let next = (helpers.tile ?? (step > 0 ? -1 : count)) + step
        helpers.tile = min(max(next, 0), count - 1)
    }

    /// `↩` on a tile in Now opens its helper in a split.
    func openTile() -> Bool {
        guard view == .watch, let tile = helpers.tile, helpers.active.indices.contains(tile) else { return false }
        openHelper(helpers.active[tile].id)
        return true
    }

    /// A key while the steer box is open: `↩` sends it to the helper shown, `⎋` closes it, the rest types.
    func typeSteer(_ stroke: KeyStroke) {
        guard var box = helpers.steer else { return }
        if stroke == .escape { return helpers.steer = nil }
        if stroke == KeyStroke("CR") {
            helpers.steer = nil
            let text = box.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, let helper = visibleHelper ?? helpers.run(helpers.shown) else { return }
            return steerHelper(helper.id, text)
        }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            box.paste(text)
        } else {
            _ = box.handle(stroke)
        }
        helpers.steer = box
    }

    /// `d` in the close-out: everything the helper changed, from git.
    private func toggleHelperDiff(_ helper: HelperRun) {
        helpers.showDiff.toggle()
        guard helpers.showDiff, helpers.diff[helper.id] == nil, !isFixture else { return }
        let base = helpers.bases[helper.id] ?? "HEAD"
        Task {
            helpers.diff[helper.id] = await HelperGit.diff(worktree: helper.worktree, base: base, repo: helper.ref.repo)
        }
    }

    // MARK: Starting one

    /// Whether helpers can run: the adapter on the login shell's PATH, looked up off the main actor.
    func helperAvailability() async -> ACPAgents.Availability {
        let settings = config.helpers
        let defaultAgent = self.settings.defaultAgent
        let adapter = ACPAgents.chosen(settings, defaultAgent: defaultAgent)
        var found: String?
        if let adapter { found = await ToolLocator.shared.executable(adapter.executable).path }
        let availability = ACPAgents.availability(settings, defaultAgent: defaultAgent) { name in
            name == adapter?.executable ? found : nil
        }
        helpers.availability = availability
        return availability
    }

    /// A review of someone else's PR: its branches from gh, then a helper on them. Nothing is posted until you send
    /// it.
    func startReview(_ ref: PullRef, title: String) {
        if let helper = helpers.current(on: ref) { return openHelper(helper.id) }
        guard !isFixture else { return flash = "fixture: no IO (a review helper would start)" }
        flash = "starting a review helper on #\(ref.number)…"
        let instructions = pilotSettings(for: ref).reviewInstructions
        Task {
            do {
                let pull = try await GitHub.pullForReview(ref, caller: "helper.review")
                _ = await startHelper(
                    .review,
                    ref: ref,
                    title: pull.title.isEmpty ? title : pull.title,
                    headBranch: pull.head,
                    items: [],
                    sessionID: nil
                ) { branch, prBranch in
                    HelperPrompt.review(
                        ref: ref, title: pull.title, body: pull.body, base: pull.base, branch: branch,
                        prBranch: prBranch, instructions: instructions
                    )
                }
            } catch {
                flash = "could not read #\(ref.number): \(error)"
            }
        }
    }

    /// Starts a helper: its worktree from the PR's branch (never yours), the repo's setup, its agent over ACP, and
    /// its first turn. Returns what it is (`a claude helper`), or nil when it could not start (the reason flashed,
    /// logged, and kept on the helper).
    func startHelper(
        _ kind: HelperKind, ref: PullRef, title: String? = nil, headBranch: String? = nil, items: [FeedbackItem],
        sessionID: String?, prompt: @escaping (_ branch: String, _ prBranch: String) -> String
    ) async -> String? {
        let availability = await helperAvailability()
        guard case let .ready(adapter, executable) = availability else {
            flash = availability.text
            logPilot(ref, .helperDone, "no helper started: \(availability.text)")
            return nil
        }
        let local = repos.filter(\.location.isLocal)
        guard let record = Runs.clone(for: ref, in: local, at: .local) else {
            flash = "\(ref.repo.name) is not cloned on this Mac: helpers run here"
            return nil
        }
        guard let prBranch = headBranch ?? github.pull(ref)?.headBranch ?? pullDetails[ref.description]?.headBranch
        else {
            flash = "no branch for #\(ref.number)"
            return nil
        }
        let root = Runs.worktreeRoot(local: settings.worktreeRoot, host: nil, hosts: config.hosts)
        let branch = "\(Runs.prefix)\(kind.slug)/\(prBranch)"
        let path = "\(root)/heed/\(ref.repo.name)/\(kind.slug)-\(prBranch.replacingOccurrences(of: "/", with: "-"))"
        var helper = HelperRun(
            kind: kind, ref: ref, title: title ?? github.pull(ref)?.title ?? pullDetails[ref.description]?.title ?? "",
            agent: adapter.agent, adapter: adapter.title, sessionID: sessionID, prBranch: prBranch, branch: branch,
            worktree: path, startedAt: Clock.now, cap: config.helpers.spendCap
        )
        let id = helper.id
        helper.append(.note("making its worktree from \(prBranch)"), at: Clock.now)
        helpers.runs.insert(helper, at: 0)
        helpers.items[id] = items
        helpers.records[id] = record
        if view == .attention || view == .watch { openHelper(id) }
        func fail(_ why: String) -> String? {
            helpers.update(id) {
                $0.phase = .failed(why)
                $0.endedAt = Clock.now
                $0.append(.note(why), at: Clock.now)
            }
            flash = "helper on #\(ref.number): \(why)"
            logPilot(ref, .helperDone, "\(kind.title(ref.number)) could not start: \(why)")
            recordRun(id, outcome: .failed(why))
            return nil
        }
        let worktree: String
        do {
            worktree = try await Git.addRunWorktree(record, path: path, branch: prBranch, runBranch: branch)
        } catch {
            return fail("could not make its worktree: \(error)")
        }
        helpers.update(id) { $0.worktree = worktree }
        _ = await WorktreeInclude.copy(from: record.path, to: worktree)
        for command in settings.setup.commands(for: ref.repo) ?? [] {
            helpers.update(id) { $0.append(.note("setting up: \(command)"), at: Clock.now) }
            let result = try? await ProcessRunner.run(
                "/bin/sh", ["-c", command], in: worktree, timeout: .seconds(600), caller: "helper.setup"
            )
            if result?.succeeded != true { return fail("its setup failed: \(command)") }
        }
        helpers.bases[id] = await HelperGit.head(worktree)
        recordRun(id, outcome: nil)
        let client: ACPClient
        do {
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = await ToolLocator.shared.executable(adapter.executable).pathVariable
            let transport = try ACPProcessTransport(
                executable: executable, arguments: adapter.arguments, directory: worktree, environment: environment
            )
            client = ACPClient(transport: transport)
        } catch {
            return fail("\(adapter.executable) did not start: \(error)")
        }
        helpers.clients[id] = client
        await client.start()
        Task { [weak self] in
            for await event in client.events {
                self?.helperEvent(id, event)
            }
        }
        do {
            let info = try await client.initialize(clientVersion: appVersion)
            let session = try await client.newSession(cwd: worktree)
            helpers.sessionIDs[id] = session
            helpers.update(id) {
                $0.phase = .working
                $0.append(.note("\(info.name ?? adapter.title) started in \(worktree)"), at: Clock.now)
            }
        } catch let ACPError.rpc(_, message) where message.localizedCaseInsensitiveContains("auth") {
            await client.close()
            return fail("\(adapter.agent) needs you to sign in first (run \(adapter.agent) once in a terminal)")
        } catch {
            await client.close()
            return fail("\(error)")
        }
        if let sessionID { notifySession(sessionID, helperID: id, HelperPrompt.workingNote(helper)) }
        logPilot(ref, .watch, "\(kind.title(ref.number)): a \(adapter.title) helper in \(branch)")
        runTurn(id, prompt(branch, prBranch))
        watchTimeout(id, after: pilotSettings(for: ref).runTimeout)
        return "a \(adapter.agent) helper"
    }

    /// One prompt turn; its end is read by why it was cancelled, if it was.
    private func runTurn(_ id: String, _ text: String) {
        guard let client = helpers.clients[id], let session = helpers.sessionIDs[id] else { return }
        helpers.update(id) {
            $0.phase = .working
            $0.closeOut = nil
        }
        helpers.turns[id] = Task { [weak self] in
            do {
                let stop = try await client.prompt(sessionID: session, text: text)
                self?.turnEnded(id, stop)
            } catch {
                self?.turnFailed(id, error)
            }
        }
    }

    private func turnEnded(_ id: String, _ stop: ACPStopReason) {
        helpers.turns[id] = nil
        switch helpers.cancelling.removeValue(forKey: id) {
        case .pause:
            helpers.update(id) {
                $0.phase = .paused
                $0.append(.note("paused"), at: Clock.now)
            }
        case let .steer(text):
            guard helpers.clients[id] != nil else {
                return helpers.update(id) { $0.phase = .paused }
            }
            runTurn(id, HelperPrompt.steer(text))
        case let .stop(why):
            helpers.update(id) { $0.phase = .stopped(why) }
            finishTurn(id)
        case nil:
            helpers.update(id) { $0.phase = .done(stop) }
            finishTurn(id)
        }
    }

    private func turnFailed(_ id: String, _ error: Error) {
        helpers.turns[id] = nil
        helpers.cancelling[id] = nil
        guard let helper = helpers.run(id), helper.phase.isLive else { return }
        helpers.update(id) {
            $0.phase = .failed("\(error)")
            $0.append(.note("\(error)"), at: Clock.now)
        }
        recordRun(id, outcome: .failed("\(error)"))
    }

    /// Its turn ended: what it did, from its last message and git. With the repo's Always (get it green on auto),
    /// heed pushes and replies at once; otherwise the close-out waits for you.
    private func finishTurn(_ id: String) {
        guard let helper = helpers.run(id) else { return }
        let base = helpers.bases[id] ?? "HEAD"
        let threads = HelperPrompt.threads(helpers.items[id] ?? [])
        guard !isFixture else {
            // The fake world's helper stops where it is: no git to ask.
            helpers.update(id) {
                $0.closeOut = $0.closeOut ?? HelperCloseOut(summary: "Stopped in the fake world.")
                $0.endedAt = Clock.now
            }
            return
        }
        let message = helper.feed.reversed().lazy.compactMap { entry -> String? in
            if case let .message(text) = entry.body { return text }
            return nil
        }.first ?? ""
        Task {
            let changes = await HelperGit.changes(worktree: helper.worktree, base: base)
            var closeOut = HelperPrompt.closeOut(message, threads: threads)
            closeOut.commits = changes.commits
            closeOut.dirty = changes.dirty
            helpers.update(id) {
                $0.closeOut = closeOut
                if !changes.files.isEmpty || closeOut.hasChanges { $0.files = changes.files }
                $0.endedAt = Clock.now
            }
            logPilot(helper.ref, .helperDone, "\(helper.headline): \(helper.phase.text), waiting for your close-out")
            if helper.kind != .review, closeOut.hasChanges, pilot(for: helper.ref).green == .auto {
                closeOutHelper(id, replies: true)
            }
        }
    }

    private func watchTimeout(_ id: String, after seconds: TimeInterval) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard let self, let helper = helpers.run(id), helper.phase.isLive else { return }
            stopHelper(id, why: "ran \(PilotDuration.text(seconds)), its run_timeout")
        }
    }

    // MARK: What the agent sends

    private func helperEvent(_ id: String, _ event: ACPEvent) {
        switch event {
        case let .update(_, update):
            helpers.update(id) { $0.apply(update, at: Clock.now) }
            if let helper = helpers.run(id), helper.overCap, helper.phase.isLive, helpers.cancelling[id] == nil {
                stopHelper(id, why: "reached its $\(DollarsText.text(helper.cap)) spend cap")
            }
        case let .permission(requestID, _, request):
            helpers.update(id) { $0.ask(request, id: requestID, at: Clock.now) }
            if let helper = helpers.run(id) {
                flash = "\(helper.headline): wants to run \(request.toolCall.command ?? request.toolCall.title ?? "a tool")"
            }
        case let .closed(reason):
            helpers.clients[id] = nil
            guard let helper = helpers.run(id), helper.phase.isLive else { return }
            let why = "its agent exited" + (reason.map { ": \($0)" } ?? "")
            helpers.update(id) {
                $0.phase = .failed(why)
                $0.permission = nil
                $0.append(.note(why), at: Clock.now)
            }
            recordRun(id, outcome: .failed(why))
        }
    }

    // MARK: Steering

    private func answerHelper(_ id: String, _ kind: ACPPermissionRequest.Option.Kind) {
        guard let helper = helpers.run(id), let permission = helper.permission else {
            return flash = "the helper is not asking anything"
        }
        let option = permission.option(kind)
            ?? permission.option(kind == .rejectOnce ? .rejectAlways : .allowOnce)
        guard let option else { return flash = "the agent offered no such answer" }
        let answer = switch option.kind {
        case .allowOnce: "allowed"
        case .allowAlways: "allowed always"
        case .rejectOnce, .rejectAlways: "denied"
        }
        helpers.update(id) { $0.answered(answer) }
        guard let client = helpers.clients[id] else { return }
        Task { await client.answerPermission(permission.requestID, optionID: option.id) }
    }

    /// `p`: a working helper's turn is cancelled and it waits; a paused one carries on.
    private func pauseHelper(_ id: String) {
        guard let helper = helpers.run(id) else { return }
        switch helper.phase {
        case .paused:
            helpers.update(id) { $0.append(.note("resumed"), at: Clock.now) }
            runTurn(id, HelperPrompt.resume)
        case .working, .asking:
            cancelTurn(id, .pause)
        default:
            flash = "the helper is \(helper.phase.text): nothing to pause"
        }
    }

    /// What you tell it: while it works its turn is cancelled and your words start the next; after it ended (Keep
    /// going), they start another.
    private func steerHelper(_ id: String, _ text: String) {
        guard let helper = helpers.run(id), helpers.clients[id] != nil else {
            return flash = "the helper's agent is gone: nothing to tell"
        }
        helpers.update(id) { $0.append(.steer(text), at: Clock.now) }
        switch helper.phase {
        case .working, .asking: cancelTurn(id, .steer(text))
        case .starting: flash = "the helper is starting: tell it once it works"
        case .paused, .done, .stopped: runTurn(id, HelperPrompt.steer(text))
        case .failed, .closed: flash = "the helper is \(helper.phase.text)"
        }
    }

    func stopHelper(_ id: String, why: String) {
        guard let helper = helpers.run(id) else { return }
        guard helper.phase.isLive else { return flash = "the helper is \(helper.phase.text)" }
        if case .paused = helper.phase {
            helpers.update(id) { $0.phase = .stopped(why) }
            return finishTurn(id)
        }
        cancelTurn(id, .stop(why))
    }

    private func cancelTurn(_ id: String, _ reason: HelpersModel.CancelReason) {
        helpers.cancelling[id] = reason
        guard let client = helpers.clients[id], let session = helpers.sessionIDs[id] else {
            // No agent to cancel (it is gone, or the fake world's): the turn ends here.
            if helpers.run(id)?.permission != nil { helpers.update(id) { $0.answered("cancelled") } }
            return turnEnded(id, .cancelled)
        }
        // A permission it waits on is answered cancelled, as ACP asks of a cancelled turn.
        if let permission = helpers.run(id)?.permission {
            helpers.update(id) { $0.answered("cancelled") }
            Task { await client.answerPermission(permission.requestID, optionID: nil) }
        }
        Task { await client.cancel(sessionID: session) }
    }

    // MARK: Close-out

    /// Push and reply (`⌘↩`), or Push only (`P`): what it committed (and what it left, committed now) goes to the
    /// PR's branch, then its replies; a review is posted as one review. The session is told, its worktree removed.
    func closeOutHelper(_ id: String, replies: Bool) {
        guard let helper = helpers.run(id), let closeOut = helper.closeOut else {
            return flash = "the helper has not finished: its close-out comes when it does"
        }
        guard !isFixture else { return flash = "fixture: nothing pushed or posted" }
        let record = helpers.records[id]
        flash = helper.kind == .review ? "posting the review…" : "pushing to \(helper.prBranch)…"
        Task {
            do {
                var what: [String] = []
                if helper.kind == .review {
                    guard replies else { return flash = "a review has nothing to push: ⌘↩ posts it" }
                    try await GitHub.review(
                        helper.ref, verdict: closeOut.verdict, body: HelperPrompt.reviewBody(closeOut),
                        caller: "helper.review"
                    )
                    what.append("posted the review")
                } else {
                    guard closeOut.hasChanges else { return flash = "nothing to push: it changed nothing" }
                    let sha = try await HelperGit.push(
                        worktree: helper.worktree, prBranch: helper.prBranch,
                        message: closeOut.did.first ?? helper.headline
                    )
                    helpers.update(id) { $0.closeOut?.pushedSHA = sha }
                    what.append("pushed \(sha.prefix(7))")
                    if replies {
                        var posted = 0
                        for reply in closeOut.replies {
                            guard let thread = reply.threadID else { continue }
                            try await GitHub.replyToThread(thread, body: reply.text, caller: "helper.reply")
                            posted += 1
                        }
                        if posted > 0 { what.append("replied on \(posted) thread\(posted == 1 ? "" : "s")") }
                    }
                    if let sessionID = helper.sessionID {
                        notifySession(
                            sessionID,
                            helperID: id,
                            HelperPrompt.pushedNote(helper, sha: sha, did: closeOut.did)
                        )
                    }
                }
                finish(
                    id,
                    how: what.joined(separator: ", "),
                    record: record,
                    outcome: helper.kind == .review
                        ? .noChanges : .pushed(max(closeOut.commits, 1))
                )
            } catch {
                flash = "\(helper.headline): \(error)"
                helpers.update(id) { $0.append(.note("close-out failed: \(error)"), at: Clock.now) }
            }
        }
    }

    /// `X` twice: the helper's agent stopped, its worktree and branch removed, nothing pushed or posted.
    func throwAwayHelper(_ id: String) {
        guard let helper = helpers.run(id) else { return }
        if let armed = helpers.throwAwayArmed, armed.id == id, Clock.now.timeIntervalSince(armed.at) < 4 {
            helpers.throwAwayArmed = nil
            if helper.phase.isLive { stopHelper(id, why: "thrown away") }
            finish(id, how: "thrown away", record: helpers.records[id], outcome: .stopped)
            return
        }
        helpers.throwAwayArmed = (id, Clock.now)
        flash = "\(keyText(for: "helper.throwaway", in: helperScope ?? "sessionshelper")) again throws away what it did"
    }

    /// `gO` (Take it over): the helper stops, its worktree and branch stay, and the session is told where they are.
    func takeOverHelper() {
        let picked = selectedListEntry.flatMap { helpers.run($0.id) }
        guard let session = currentSession,
              let helper = picked ?? visibleHelper ?? sessionHelper(for: session)
        else { return flash = "no helper on this session's PRs" }
        guard helper.phase.isLive || helper.phase.awaitsCloseOut else {
            return flash = "the helper is \(helper.phase.text): nothing to take over"
        }
        helpers.listOpen = false
        if helper.phase.isLive { cancelTurn(helper.id, .stop("you took it over")) }
        let id = helper.id
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            await self?.helpers.clients[id]?.close()
        }
        notifySession(session.id, helperID: id, HelperPrompt.takeOverNote(helper))
        helpers.update(id) {
            $0.phase = .closed("taken over")
            $0.endedAt = Clock.now
        }
        recordRun(id, outcome: .stopped)
        if helpers.shown == id { helpers.shown = nil }
        flash = "the helper stopped; its branch \(helper.branch) is yours"
    }

    private func finish(_ id: String, how: String, record: RepoRecord?, outcome: PilotRun.Outcome) {
        guard let helper = helpers.run(id) else { return }
        let client = helpers.clients.removeValue(forKey: id)
        helpers.update(id) {
            $0.phase = .closed(how)
            $0.endedAt = $0.endedAt ?? Clock.now
        }
        recordRun(id, outcome: outcome)
        logPilot(helper.ref, .helperDone, "\(helper.headline): \(how)")
        flash = "\(helper.headline): \(how)"
        if helpers.shown == id { helpers.shown = nil }
        helperClosed(helper.ref)
        Task {
            await client?.close()
            if let record, !isFixture { await Git.removeWorktree(record, path: helper.worktree, branch: helper.branch) }
        }
    }

    /// The helper in the PR's history (`PilotRun`): started, and how it ended.
    private func recordRun(_ id: String, outcome: PilotRun.Outcome?) {
        guard let helper = helpers.run(id) else { return }
        var run = PilotRun(
            id: id, ref: helper.ref, sessionID: helper.sessionID ?? "", goal: helper.kind.goal, agent: helper.agent,
            model: nil, startedAt: helper.startedAt, items: helpers.items[id]?.count ?? 0, prBranch: helper.prBranch,
            branch: helper.branch, worktree: helper.worktree, startSHA: helpers.bases[id]
        )
        if let outcome {
            run.endedAt = Clock.now
            run.outcome = outcome
        }
        commit(.runUpdated(run))
    }

    /// What heed tells a session about a helper: always a band over its panes, and through its agent's own channel
    /// (Claude's inbox, codex's queue) when it has one (`notify(session:text:mayType: false)`). Never typed in: an
    /// agent without a channel gets the band only. The outcome is kept on the band and in the session's events.
    func notifySession(_ sessionID: String, helperID: String, _ text: String) {
        helpers.notices[sessionID] = HelpersModel.SessionNotice(helperID: helperID, text: text, at: Clock.now)
        guard !isFixture else { return }
        Task {
            let outcome = await notify(session: sessionID, text: text, mayType: false)
            if helpers.notices[sessionID]?.helperID == helperID, helpers.notices[sessionID]?.text == text {
                helpers.notices[sessionID]?.outcome = outcome
            }
            // notify records what it sent; what it did not send is on the band only, and said so.
            guard !outcome.sent, var session = sessions.first(where: { $0.id == sessionID }) else { return }
            session.record("heed (band only, \(outcome.summary)): \(text.prefix(80))")
            commit(.sessionUpserted(session))
        }
    }
}

/// `$0.50`.
enum DollarsText {
    static func text(_ dollars: Double) -> String { String(format: "%.2f", dollars) }
}

extension AppModel {
    /// The fake world's helpers (`Fixtures.helpers`), for shots and the tutor: the anchors PR's helper at work
    /// (or, `done`, waiting for its close-out), a review and a conflict. Its session was told. No agent runs.
    func loadHelperFixture(done: Bool = false, line: Bool = false) {
        var runs = Fixtures.helpers(now: Clock.now)
        if done { runs[0] = Fixtures.anchorsHelperDone(now: Clock.now) }
        if line { runs += Fixtures.sessionLineHelpers(now: Clock.now) }
        helpers.runs = runs
        helpers.availability = .ready(ACPAgents.adapter(for: "claude")!, path: "/opt/homebrew/bin/claude-agent-acp")
        helpers.notices["s1"] = HelpersModel.SessionNotice(
            helperID: runs[0].id, text: HelperPrompt.workingNote(runs[0]), at: Clock.now
        )
        updateScope()
    }

    /// The fake world's own get it green is a helper, as `run_in = "helper"` (the default) has it: bump-spec-tests'
    /// PR at work, when the world has that session.
    func adoptFixtureHelpers() {
        guard sessions.contains(where: { $0.id == "s5" }) else { return }
        helpers.runs = [Fixtures.specHelper(now: Clock.now)]
        helpers.availability = .ready(ACPAgents.adapter(for: "claude")!, path: "/opt/homebrew/bin/claude-agent-acp")
    }
}
