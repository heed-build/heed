import AppKit
import Foundation
import HeedCore

/// The four verbs run inside Browse: an agent over ACP in a temporary worktree, shown under the thread. The decisions
/// are `HeedCore`'s (`BrowseRun`'s life, `BrowsePolicy`, `BrowseWorktree`, `BrowseTrust`, `BrowseRunPrompt`); this runs
/// them. Not in the fake world: there a scripted agent plays the feed and nothing touches git, gh or an agent.
extension AppModel {
    // MARK: Starting

    /// F, I, C, R and `t`: an agent on the item under the cursor, in the reader. `words` are yours (`t`), in place of
    /// the verb's prompt. One run per item; as many at once as `[browse] max_runs`.
    func startBrowseRun(_ verb: BrowseVerb, item: BrowseItem, words: String? = nil) {
        let runs = browse.runs
        // The lowest level: whatever path got here (a key, a button, the menu, `t`), a write verb does not start while
        // agent edits are off, and the reader says so where the buttons were.
        if let why = BrowseVerbs.refusal(verb, runs: config.browse.runs) {
            if !browse.layout.showsReaderBeside { browse.reading = true }
            browse.startRefusals[item.id] = .init(verb: verb, why: why)
            return say("\(verb.title): \(why)")
        }
        let start = BrowseRuns.canStart(item: item.id, runs: runs.runs, max: config.browse.maxRuns)
        // From the list, the narrower layouts show the reader over it, so what the run says is seen.
        if !browse.layout.showsReaderBeside { browse.reading = true }
        if let reason = start.reason {
            // Said in the reader too, where it stays: the status line is gone in a few seconds.
            browse.startRefusals[item.id] = .init(verb: verb, why: reason)
            return say("\(verb.title): \(reason)")
        }
        browse.startRefusals[item.id] = nil
        // A run of this item that failed is dismissed first (its worktree, if it got one, goes).
        for old in runs.runs where old.itemID == item.id && old.phase.isOver {
            closeBrowseRun(old.id)
        }
        let adapter = browseAdapter()
        var run = BrowseRun(
            item: item, verb: verb, agent: adapter?.agent ?? "claude", adapter: adapter?.title ?? "claude via ACP",
            name: "", branch: "", worktree: "", phase: .preparing, startedAt: Clock.now, cap: config.helpers.spendCap
        )
        run.words = words.flatMap { $0.isEmpty ? nil : $0 }
        run.said(run.words ?? BrowseRun.youSaid(verb, item), at: Clock.now)
        if RepoPlace.of(item.repo, in: browseRecords).clones {
            // The repo is not on this Mac: the clone card asks first.
            run.phase = .needsClone
            run.cloneRoot = cloneRoot(.local)
            runs.runs.append(run)
            return
        }
        runs.runs.append(run)
        Task { await prepareBrowseRun(run.id) }
    }

    /// The agent Browse's runs use: `[browse] agent` over `[helpers] agent`, as the helpers' adapter is chosen.
    func browseAdapter() -> ACPAdapter? {
        var settings = config.helpers
        if let agent = config.browse.agent { settings.agent = agent }
        return ACPAgents.chosen(settings, defaultAgent: self.settings.defaultAgent)
    }

    private func browseRecord(for repo: Repo) -> RepoRecord? {
        browseRecords.first { $0.location.isLocal && $0.repo.slug.lowercased() == repo.slug.lowercased() }
    }

    private func browseItem(_ run: BrowseRun) -> BrowseItem? {
        browse.items
            .first { $0.id == run.itemID } ?? (isFixture ? Fixtures.Browse.cached.first { $0.id == run.itemID } : nil)
    }

    // MARK: Clone first

    /// ↩ on the clone card: clone, then run.
    func browseCloneGo() { browseClone(thenRun: true) }

    /// c on the clone card: clone and stop.
    func browseCloneOnly() { browseClone(thenRun: false) }

    private func browseClone(thenRun: Bool) {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id), run.phase == .needsClone else {
            return say("nothing to clone: press F, I, C or R on an item whose repo is not on this Mac")
        }
        let id = run.id
        guard browse.runs.apply(id, .cloneStarted, at: Clock.now) != nil else { return }
        let slug = run.repo.slug
        let root = run.cloneRoot ?? cloneRoot(.local)
        guard !(isFixture || tutor != nil) else {
            // The fake world clones nothing.
            Task {
                try? await Task.sleep(for: .milliseconds(600))
                _ = browse.runs.apply(id, .cloned, at: Clock.now)
                if thenRun { playFakeRun(id) } else { finishCloneOnly(id, "cloned \(slug) (fake)") }
            }
            return
        }
        Task {
            switch await cloneRepo(slug, at: .local, caller: "browse.clone", root: root) {
            case .success:
                _ = browse.runs.apply(id, .cloned, at: Clock.now)
                if thenRun { await prepareBrowseRun(id) } else { finishCloneOnly(id, "cloned \(slug)") }
            case let .failure(note):
                _ = browse.runs.apply(id, .cloneFailed(note.text), at: Clock.now)
            }
        }
    }

    private func finishCloneOnly(_ id: String, _ text: String) {
        browse.runs.remove(id)
        say(text + ": it is in Repos")
    }

    /// d on the clone card: the folder it goes into.
    func browseCloneFolder() {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id), run.phase == .needsClone else {
            return say("no clone to place")
        }
        browse.runs.input = .init(kind: .folder, run: run.id, box: EditableText(run.cloneRoot ?? cloneRoot(.local)))
    }

    // MARK: Preparing

    /// The worktree, its setup, the agent, and the first turn: off the main actor except for what lands on the run.
    func prepareBrowseRun(_ id: String) async {
        let runs = browse.runs
        if let run = runs.run(id), let why = BrowseVerbs.refusal(run.verb, runs: config.browse.runs) {
            _ = runs.apply(id, .couldNotStart(why), at: Clock.now)
            return say("\(run.verb.title) on #\(run.number): \(why)")
        }
        guard !(isFixture || tutor != nil) else { return playFakeRun(id) }
        guard var run = runs.run(id), let item = browseItem(run) else { return }
        func fail(_ why: String) {
            let effects = runs.apply(id, .couldNotStart(why), at: Clock.now)
            _ = effects
            say("\(run.verb.title) on #\(run.number): \(why)")
        }
        if run.phase == .needsClone { _ = runs.apply(id, .cloneStarted, at: Clock.now); _ = runs.apply(
            id,
            .cloned,
            at: Clock.now
        ) }
        // The agent.
        var settings = config.helpers
        if let agent = config.browse.agent { settings.agent = agent }
        let defaultAgent = self.settings.defaultAgent
        guard let adapter = ACPAgents.chosen(settings, defaultAgent: defaultAgent) else {
            return fail("heed knows no ACP way to the agent: set [browse] agent")
        }
        let (executable, pathVariable) = await ToolLocator.shared.executable(adapter.executable)
        guard let executable else {
            return fail("\(adapter.executable) is not installed" + (adapter.install.map { ": \($0)" } ?? ""))
        }
        guard let record = browseRecord(for: item.repo)
        else { return fail("\(item.repo.name) is not cloned on this Mac") }
        runs.records[id] = record
        runs.update(id) { $0.agent = adapter.agent; $0.adapter = adapter.title }

        // Who wrote it, so how much the agent may do.
        let viewer = github.viewer
        let trustedAuthors = pilotSettings(for: PullRef(repo: item.repo, number: item.number)).trustedAuthors
        var verdict: BrowseTrust.Verdict
        var prBranch: String?
        if item.kind == .pull {
            let ref = PullRef(repo: item.repo, number: item.number)
            do {
                let authorship = try await GitHub.pullAuthorship(ref, caller: "browse.run")
                PullTrustBook.shared.record(authorship, for: ref)
                verdict = BrowseTrust.pull(authorship, viewer: viewer, trustedAuthors: trustedAuthors)
                prBranch = try await GitHub.pullForReview(ref, caller: "browse.run").head
            } catch {
                return fail("could not read who opened #\(item.number): \(error)")
            }
        } else {
            var canWrite: Bool?
            if let login = item.author, login.caseInsensitiveCompare(viewer ?? "") != .orderedSame, !item.authorIsBot {
                canWrite = await WriteAccessBook.shared.resolve(item.repo, login) { repo, login in
                    try await GitHub.canWrite(repo, login: login, caller: "browse.run")
                }
            }
            verdict = BrowseTrust.issue(item, viewer: viewer, canWrite: canWrite, trustedAuthors: trustedAuthors)
        }
        let mode = BrowseTrust.chatOnly(verdict)
        // The verb the run really has: an untrusted author's run is a Chat whatever was pressed.
        let effectiveVerb: BrowseVerb = if case .chatOnly = mode { .chat } else { run.verb }
        // A Fix on a pull request pushes to its branch only when it is this repo's own.
        let pushBranch = verdict.canPush ? prBranch : nil
        runs.update(id) {
            $0.mode = mode
            $0.canPush = verdict.canPush
            $0.prBranch = pushBranch
        }
        if case let .chatOnly(reason) = mode {
            runs.update(id) {
                $0.note(
                    "from someone heed does not trust (\(reason)): this run is a chat. It reads, edits nothing, runs none of the repo's code, and has no GitHub login",
                    at: Clock.now
                )
            }
        }

        // Its worktree.
        let root = Runs.worktreeRoot(local: self.settings.worktreeRoot, host: nil, hosts: config.hosts)
        let plan = BrowseWorktree.plan(for: item, defaultBranch: record.defaultBranch ?? "main", root: root)
        runs.defaultBranches[id] = record.defaultBranch ?? "main"
        runs.update(id) {
            $0.name = plan.name
            $0.branch = plan.branch
            $0.worktree = plan.path
            $0.story.worktree = plan.path
            $0.note("making its worktree \(plan.name)", at: Clock.now)
        }
        let worktree: String
        let trusted = verdict.trusted
        do {
            worktree = try await BrowseWorktree.create(
                plan,
                in: record,
                untrusted: !trusted,
                pinnedHead: verdict.headSHA
            )
        } catch {
            return fail("could not make its worktree: \(error)")
        }
        runs.update(id) { $0.worktree = worktree; $0.story.worktree = worktree }
        // A run closed while its worktree was being made leaves nothing behind.
        guard runs.run(id) != nil else {
            await BrowseWorktree.remove(path: worktree, branch: plan.branch, in: record)
            return
        }
        // A link in the tree that leads out of it is read by the agent's own tools without asking heed: an untrusted
        // head does not start (checkout wrote its links as plain files, so this is the belt), a trusted one is noted.
        let escaping = await Task.detached { PathResolver.escapingLinks(in: worktree) }.value
        if !escaping.isEmpty {
            let list = escaping.prefix(3).joined(separator: ", ")
            if !trusted {
                await BrowseWorktree.remove(path: worktree, branch: plan.branch, in: record)
                return fail(
                    "its checkout holds a link that leads outside it (\(list)): heed does not start an agent in it"
                )
            }
            runs.update(id) {
                $0.note(
                    "its checkout holds a link that leads outside it (\(list)): heed refuses reads through it",
                    at: Clock.now
                )
            }
        }
        let head = await Task.detached { GitPushGuard.head(of: worktree) }.value
        runs.startCommits[id] = head
        let setup = HelperSetup.steps(trusted: trusted, commands: self.settings.setup.commands(for: item.repo) ?? [])
        if setup.copyIncludes { _ = await WorktreeInclude.copy(from: record.path, to: worktree) }
        for command in setup.commands {
            runs.update(id) { $0.note("setting up: \(command)", at: Clock.now) }
            let result = try? await ProcessRunner.run(
                "/bin/sh", ["-c", command], in: worktree, timeout: .seconds(600), caller: "browse.setup"
            )
            if result?.succeeded != true { return fail("its setup failed: \(command)") }
        }

        // Its agent.
        let client: ACPClient
        do {
            // Every run, trusted or not, starts with what `RunSandbox.kept` keeps and nothing else: no tokens, no
            // GIT_*, proxy or loader variables. An untrusted run's gh also has no login.
            let folder = RunFolder.path(run: "heed-browse-\(id)", root: NSTemporaryDirectory())
            try? RunFolder.prepare(folder)
            let environment = BrowseRunEnvironment.make(
                ProcessInfo.processInfo.environment, agent: adapter.agent, folder: folder, trusted: trusted,
                verb: runs.run(id)?.effectiveVerb ?? .chat, path: pathVariable
            )
            client = try ACPClient(transport: ACPProcessTransport(
                executable: executable, arguments: adapter.arguments, directory: worktree, environment: environment
            ))
        } catch {
            return fail("\(adapter.executable) did not start: \(error)")
        }
        runs.clients[id] = client
        await client.start()
        Task { [weak self] in
            for await event in client.events {
                self?.browseRunEvent(id, event)
            }
        }
        do {
            let info = try await client.initialize(clientVersion: appVersion)
            // Locked: no setting sources, no hooks, no allow rules, no bypass (claude-agent-acp). Then the mode is set
            // to default: the adapter starts in `auto`, or in what the repo's settings name, otherwise.
            let session = try await client.newSession(cwd: worktree, locked: true)
            do {
                try await client.setMode(sessionID: session, mode: "default")
            } catch where adapter.agent == "claude" {
                await client.close()
                return fail("could not set \(adapter.title)'s permission mode to default: \(error)")
            } catch {
                runs.update(id) { $0.note(
                    "\(adapter.title) has no permission mode to set; heed answers its asks",
                    at: Clock.now
                ) }
            }
            runs.sessionIDs[id] = session
            _ = runs.apply(
                id,
                .ready(note: "\(info.name ?? adapter.title) started in \(Paths.tilde(worktree))"),
                at: Clock.now
            )
        } catch let ACPError.rpc(_, message) where message.localizedCaseInsensitiveContains("auth") {
            await client.close()
            return fail("\(adapter.agent) needs you to sign in first (run \(adapter.agent) once in a terminal)")
        } catch {
            await client.close()
            return fail("\(error)")
        }
        guard let current = runs.run(id) else { return }
        run = current
        let place = BrowseRunPrompt.Place(
            worktree: worktree, branch: plan.branch, defaultBranch: record.defaultBranch ?? "main",
            prBranch: pushBranch,
            fork: item.kind == .pull && !verdict.canPush
        )
        // No agent fetches comments itself (a comment on a trusted author's item can be a stranger's): heed reads the
        // thread and fences it, for every verb. When it cannot, a Chat is told so and the rest are told there are none.
        let chat = run.effectiveVerb == .chat
        var thread: Prompt? = chat ? BrowseThread.unavailable : nil
        if let conversation = try? await GitHub.conversation(
            repo: item.repo, number: item.number, caller: "browse.run.thread"
        ) {
            thread = BrowseThread.prompt(conversation, login: !chat)
        } else {
            runs.update(id) { $0.note(
                "could not read the thread: the run works from the title and the repo",
                at: Clock.now
            ) }
        }
        runBrowseTurn(id, BrowseRunPrompt.start(run, item: item, place: place, thread: thread))
        let timeout = pilotSettings(for: PullRef(repo: item.repo, number: item.number)).runTimeout
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(timeout))
            guard let self, let live = browse.runs.run(id), live.phase == .working else { return }
            stopBrowseRun(id, why: "ran \(PilotDuration.text(timeout)), its run_timeout")
        }
    }

    // MARK: Turns

    func runBrowseTurn(_ id: String, _ text: Prompt) {
        let runs = browse.runs
        guard let client = runs.clients[id], let session = runs.sessionIDs[id] else { return }
        guard runs.apply(id, .turnStarted, at: Clock.now) != nil else { return }
        auditPrompt(text, pane: "browse:\(id)", session: nil)
        runs.turns[id] = Task { [weak self] in
            do {
                let stop = try await client.prompt(sessionID: session, text: text)
                self?.browseTurnEnded(id, stop)
            } catch {
                self?.browseTurnFailed(id, error)
            }
        }
    }

    private func browseTurnEnded(_ id: String, _ stop: ACPStopReason) {
        let runs = browse.runs
        runs.turns[id] = nil
        let cancel = runs.cancelling.removeValue(forKey: id)
        carryOut(
            runs.apply(id, .turnEnded(stop, cancel: cancel, connected: runs.clients[id] != nil), at: Clock.now),
            id
        )
    }

    private func browseTurnFailed(_ id: String, _ error: Error) {
        let runs = browse.runs
        runs.turns[id] = nil
        runs.cancelling[id] = nil
        carryOut(runs.apply(id, .turnFailed("\(error)"), at: Clock.now), id)
    }

    private func carryOut(_ effects: [BrowseRun.Effect]?, _ id: String) {
        for effect in effects ?? [] {
            switch effect {
            case .finishTurn: finishBrowseTurn(id)
            case let .steer(text): runBrowseTurn(id, BrowseRunPrompt.steer(text))
            }
        }
    }

    /// Its turn ended: a review's last message is read as the draft you post, edit or discard.
    private func finishBrowseTurn(_ id: String) {
        guard let run = browse.runs.run(id), run.verb == .review else { return }
        let message = run.story.feed.reversed().lazy.compactMap { entry -> String? in
            if case let .message(text) = entry.body { return text }
            return nil
        }.first ?? ""
        browse.runs.update(id) { $0.drafted(from: message) }
    }

    /// heed stops a turn: its spend cap, its timeout.
    func stopBrowseRun(_ id: String, why: String) {
        guard let session = browse.runs.sessionIDs[id], let client = browse.runs.clients[id] else { return }
        browse.runs.cancelling[id] = .stop(why)
        Task { await client.cancel(sessionID: session) }
    }

    // MARK: What the agent sends

    func browseRunEvent(_ id: String, _ event: ACPEvent) {
        let runs = browse.runs
        switch event {
        case let .update(_, update):
            runs.update(id) { $0.apply(update, at: Clock.now) }
            if let run = runs.run(id), run.overCap, run.phase == .working, runs.cancelling[id] == nil {
                stopBrowseRun(id, why: "reached its $\(DollarsText.text(run.story.cap)) spend cap")
            }
        case let .permission(requestID, _, request):
            guard let run = runs.run(id), let client = runs.clients[id] else { return }
            let context = BrowsePolicy.Context(
                verb: run.effectiveVerb, worktree: run.worktree, repo: run.repo,
                defaultBranch: runs.defaultBranches[id] ?? "main", trusted: run.mode == .full, canPush: run.canPush,
                branch: run.branch, pushGuard: GitPushGuard(start: runs.startCommits[id])
            )
            // Symlinks are looked up off the main actor.
            Task { [weak self] in
                let answer = await Task.detached { BrowsePolicy.answer(request, context) }.value
                if let why = answer.refusal {
                    let what = request.toolCall.command ?? request.toolCall.title ?? request.toolCall.paths?.first ?? "a tool"
                    self?.browse.runs.update(id) { $0.refused(what, why: why, at: Clock.now) }
                }
                await client.answerPermission(requestID, optionID: answer.optionID)
            }
        case let .closed(reason):
            runs.clients[id] = nil
            carryOut(
                runs.apply(id, .agentExited("its agent exited" + (reason.map { ": \($0)" } ?? "")), at: Clock.now),
                id
            )
        }
    }

    // MARK: Steering

    /// ↩ or `i`: the line under the feed; ↩ again sends.
    func browseRunSteer() {
        guard let item = browseSelected else { return }
        guard let run = browse.runs.current(for: item.id) else {
            return say("no run on this item: F fix · I implement · C chat · R review, or t to say what you want")
        }
        guard run.canSteer else { return say("the run is \(run.phase.text): steer it once it is working") }
        browse.runs.input = .init(kind: .steer, run: run.id, box: EditableText())
    }

    /// `t`: say in your own words what an agent should do with the item; heed's verb for it (else Chat) runs it.
    func browseTellRun() {
        guard let item = browseSelected else { return }
        if browse.runs.current(for: item.id) != nil { return browseRunSteer() }
        browse.runs.input = .init(kind: .steer, run: "tell:" + item.id, box: EditableText())
    }

    func steerBrowseRun(_ id: String, _ text: String) {
        let runs = browse.runs
        guard let run = runs.run(id), run.canSteer else { return }
        if let why = BrowseVerbs.refusal(run.verb, runs: config.browse.runs) { return say("\(run.verb.title): \(why)") }
        let max = config.browse.maxRuns
        if case .done = run.phase, max > 0, BrowseRuns.working(runs.runs) >= max {
            return say("\(max) runs are working: wait for one to finish")
        }
        runs.update(id) { $0.said(text, at: Clock.now) }
        if isFixture || tutor != nil { return playFakeSteer(id) }
        if run.phase == .working, let session = runs.sessionIDs[id], let client = runs.clients[id] {
            runs.cancelling[id] = .steer(text)
            Task { await client.cancel(sessionID: session) }
        } else {
            guard runs.clients[id] != nil else { return say("its agent is gone: keep it as a session to carry on") }
            runBrowseTurn(id, BrowseRunPrompt.steer(text))
        }
    }

    /// A key while the panel's line is open: ↩ sends it, ⎋ closes it, the rest types.
    func typeBrowseInput(_ stroke: KeyStroke) {
        guard var input = browse.runs.input else { return }
        if stroke == .escape { return browse.runs.input = nil }
        if stroke == KeyStroke("CR") {
            browse.runs.input = nil
            return submitBrowseInput(input)
        }
        if stroke == KeyStroke("v", .command), let text = NSPasteboard.general.string(forType: .string) {
            input.box.paste(text)
        } else {
            _ = input.box.handle(stroke)
        }
        browse.runs.input = input
    }

    private func submitBrowseInput(_ input: BrowseRunsModel.Input) {
        let text = input.box.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch input.kind {
        case .steer:
            guard !text.isEmpty else { return }
            if input.run.hasPrefix("tell:") {
                let id = String(input.run.dropFirst("tell:".count))
                guard let item = browse.items.first(where: { $0.id == id }) ?? Fixtures.Browse.cached
                    .first(where: { $0.id == id })
                else { return }
                let verb = config.browse.runs == .chat ? BrowseVerb.chat : browseVerbs(item).recommended?.verb ?? .chat
                startBrowseRun(verb, item: item, words: text)
            } else {
                steerBrowseRun(input.run, text)
            }
        case .folder:
            guard !text.isEmpty else { return }
            browse.runs.update(input.run) { $0.cloneRoot = text }
        case .review:
            browse.runs.update(input.run) { _ = $0.editDraft(text) }
        }
    }

    // MARK: Closing

    /// esc: the run closes and its worktree goes (a branch it pushed stays on its remote). On the clone card it is
    /// "Not now". Without a run, esc is what it always was.
    func closeBrowseRun() {
        if let item = browseSelected, browse.startRefusals.removeValue(forKey: item.id) != nil { return }
        guard let item = browseSelected,
              let run = browse.runs.current(for: item.id) ?? browse.runs.runs.first(where: { $0.itemID == item.id })
        else { return perform(CommandInvocation(name: "overlay.close")) }
        closeBrowseRun(run.id)
    }

    func closeBrowseRun(_ id: String) {
        let runs = browse.runs
        guard let run = runs.run(id) else { return }
        let client = runs.clients[id]
        let record = runs.records[id]
        let sessionID = runs.sessionIDs[id]
        if run.phase == .needsClone { _ = runs.apply(id, .declined, at: Clock.now) } else {
            _ = runs.apply(id, .closed("closed"), at: Clock.now)
        }
        runs.remove(id)
        let worktree = run.worktree
        let branch = run.branch
        guard !isFixture, tutor == nil else { return }
        Task {
            if let client, let sessionID { await client.cancel(sessionID: sessionID) }
            await client?.close()
            guard let record, !worktree.isEmpty, FileManager.default.fileExists(atPath: worktree) else { return }
            let unpushed = await Git.unpushedSinceCreation(record, branch: branch)
            await BrowseWorktree.remove(path: worktree, branch: branch, in: record)
            if unpushed > 0 {
                say(
                    "closed: \(unpushed) commit\(unpushed == 1 ? "" : "s") that were never pushed went with the worktree"
                )
            }
        }
    }

    // MARK: Keeping

    /// s: the run becomes a session. Its worktree moves under heed's usual naming, its branch is renamed, and a session
    /// opens in it; nothing is removed.
    func keepBrowseRun() {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id) else {
            return browseTell()
        }
        guard run.phase != .needsClone, run.phase != .cloning, run.phase != .preparing else {
            return say("the run is not ready yet: keep it once it is working")
        }
        if let why = BrowseKeep.refusal(run) { return say(why) }
        guard BrowseVerbs.mayKeep(runs: config.browse.runs) else {
            return say("Not kept: \(BrowseVerbs.editsOff). A kept run is a full session, and a chat run stays a chat.")
        }
        let id = run.id
        let runs = browse.runs
        guard !(isFixture || tutor != nil) else {
            runs.remove(id)
            return say("fixture: no IO (the run would become a session in its worktree)")
        }
        guard let record = runs.records[id] else { return say("heed cannot find the repo this run works in") }
        let client = runs.clients[id]
        let sessionID = runs.sessionIDs[id]
        let taken = Set(worktrees.compactMap(\.branch))
        let branch = BrowseWorktree.promoted(verb: run.verb, title: run.title, taken: taken)
        let newPath = StartWork.worktreePath(for: record, name: branch, settings: settings, hosts: config.hosts)
        runs.remove(id)
        Task {
            if let client, let sessionID { await client.cancel(sessionID: sessionID) }
            await client?.close()
            // Give the agent a moment to let go of the folder.
            try? await Task.sleep(for: .milliseconds(400))
            do {
                _ = try await BrowseWorktree.promote(
                    record,
                    from: run.worktree,
                    branch: run.branch,
                    to: branch,
                    at: newPath
                )
                let listed = try await Git.worktrees(of: record)
                guard let worktree = listed.first(where: { Paths.expand($0.path) == newPath || $0.path == newPath })
                    ?? listed.first(where: { $0.branch == branch })
                else { return say("kept the work at \(newPath), but git did not list it") }
                let agent = settings.agent(run.agent) ?? settings.agent(settings.defaultAgent)
                let changes = [DomainChange.worktreesListed(repo: record.repo, listed)] + Import.session(
                    for: worktree, agent: agent, resume: nil, integration: integration,
                    prompt: BrowseKeep.prompt(run, item: item)
                )
                for case let .layoutChanged(_, layout) in changes {
                    for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                        TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                    }
                }
                commit(changes)
                view = .sessions
                if case let .sessionUpserted(session)? = changes.first(where: {
                    if case .sessionUpserted = $0 { true } else { false }
                }) {
                    select(sessionID: session.id)
                }
                say("kept as a session on \(branch)")
            } catch {
                say("could not keep the run as a session: \(error). Its worktree is still at \(run.worktree)")
            }
        }
    }

    // MARK: A review

    /// P: post the drafted review to the pull request. The one explicit action: a review is public speech.
    func postBrowseReview() {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id), run.draft != nil else {
            return say("no drafted review to post")
        }
        guard run.kind == .pull else {
            return say("a review posts on a pull request: open that one in Browse and review it there")
        }
        var started: BrowseReviewDraft?
        browse.runs.update(run.id) { started = $0.beginPost() }
        guard let draft = started else { return say("the review is not waiting to be posted") }
        let id = run.id
        guard !(isFixture || tutor != nil) else {
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                browse.runs.update(id) { $0.posted(); $0.note(
                    "posted your review (fake world: nothing was sent)",
                    at: Clock.now
                ) }
            }
            return
        }
        let ref = PullRef(repo: run.repo, number: run.number)
        Task {
            do {
                try await GitHub.review(ref, verdict: draft.verdict.rawValue, body: draft.body, caller: "browse.review")
                browse.runs.update(id) { $0.posted(); $0.note(
                    "posted your review: \(draft.verdict.title.lowercased())",
                    at: Clock.now
                ) }
                say("posted your review on #\(run.number)")
            } catch {
                browse.runs.update(id) { $0.postFailed("\(error)") }
                say("could not post the review: \(error)")
            }
        }
    }

    /// E: change the drafted review's text before it is posted.
    func editBrowseReview() {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id), let draft = run.draft,
              draft.state == .drafted
        else { return say("no drafted review to edit") }
        browse.runs.input = .init(kind: .review, run: run.id, box: EditableText(draft.body, multiline: true))
    }

    /// X: throw the draft away; nothing is posted.
    func discardBrowseReview() {
        guard let item = browseSelected, let run = browse.runs.current(for: item.id) else { return }
        var discarded = false
        browse.runs.update(run.id) { discarded = $0.discardDraft() }
        say(discarded ? "discarded the review: nothing was posted" : "no drafted review to discard")
    }

    // MARK: The fake world

    /// A scripted agent plays the feed, with no IO: ready, then each step a moment apart, then the turn's end.
    func playFakeRun(_ id: String) {
        let runs = browse.runs
        guard let run = runs.run(id), let item = browseItem(run) else { return }
        let place = Fixtures.Browse.FakeAgent.worktree(for: item)
        runs.update(id) {
            $0.name = place.name
            $0.branch = place.branch
            $0.worktree = place.path
            $0.story.worktree = place.path
        }
        _ = runs.apply(id, .ready(note: "claude started in \(place.path)"), at: Clock.now)
        let script = Fixtures.Browse.FakeAgent.updates(run.verb, item: item)
        runs.scripts[id] = Task { [weak self] in
            for update in script {
                try? await Task.sleep(for: .milliseconds(700))
                guard !Task.isCancelled, let self else { return }
                browse.runs.update(id) { $0.apply(update, at: Clock.now) }
            }
            guard let self, !Task.isCancelled else { return }
            carryOut(browse.runs.apply(id, .turnEnded(.endTurn, cancel: nil, connected: true), at: Clock.now), id)
        }
    }

    private func playFakeSteer(_ id: String) {
        let runs = browse.runs
        _ = runs.apply(id, .turnStarted, at: Clock.now)
        runs.scripts[id] = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled, let self else { return }
            browse.runs.update(id) { $0.apply(
                .agentMessage("Understood. In the fake world there is nothing more to do."),
                at: Clock.now
            ) }
            _ = browse.runs.apply(id, .turnEnded(.endTurn, cancel: nil, connected: true), at: Clock.now)
        }
    }
}
