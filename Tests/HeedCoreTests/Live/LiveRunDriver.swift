import Foundation
@testable import HeedCore
import Testing

/// What one permission the agent asked for got from `BrowsePolicy`.
struct SmokeAsk: Sendable {
    var kind: String
    var title: String
    var command: String?
    var paths: [String]
    var refusal: String?
    var allowed: Bool { refusal == nil }

    var line: String {
        let what = command ?? title.nilIfEmpty ?? paths.first ?? kind
        return "\(allowed ? "allowed" : "REFUSED") [\(kind)] \(what.prefix(200))" + (refusal.map { " -- \($0)" } ?? "")
    }
}

/// A Browse run as the app makes one, driven from a test. The app's `prepareBrowseRun`, `browseRunEvent` and
/// `finishBrowseTurn` (`Sources/HeedApp/Model/AppModel+BrowseRun.swift`) are glue over HeedCore pieces; this runs the
/// same pieces in the same order: trust, worktree, link check, setup, the scrubbed environment, the locked ACP session
/// in
/// `default` mode, the thread read by heed and fenced, one turn answered by `BrowsePolicy`, the review draft, close.
/// If the app's order changes, change this with it.
final class LiveBrowseRun: @unchecked Sendable {
    let item: BrowseItem
    let verb: BrowseVerb
    let record: RepoRecord
    private let lock = NSLock()
    private var _run: BrowseRun
    private var _asked: [SmokeAsk] = []
    private var _capped: String?

    var run: BrowseRun { lock.withLock { _run } }
    var asked: [SmokeAsk] { lock.withLock { _asked } }
    var capped: String? { lock.withLock { _capped } }
    var refused: [SmokeAsk] { asked.filter { !$0.allowed } }
    var lines: [BrowseFeedLine] { BrowseFeed.lines(run.story.feed) }

    var verdict: BrowseTrust.Verdict?
    var plan: BrowseWorktree.Plan?
    var worktree = ""
    var seconds = 0.0
    var stop: ACPStopReason?
    var model: String?
    private var client: ACPClient?
    private var sessionID: String?

    init(verb: BrowseVerb, item: BrowseItem, record: RepoRecord) {
        self.item = item
        self.verb = verb
        self.record = record
        _run = BrowseRun(
            item: item, verb: verb, agent: "claude", adapter: "claude via ACP", name: "", branch: "", worktree: "",
            phase: .preparing, startedAt: Date(), cap: LiveSmoke.spendCap
        )
    }

    private func mutate(_ body: (inout BrowseRun) -> Void) { lock.withLock { body(&_run) } }

    /// Everything up to and including the first turn's end. `extra` is added to the prompt after heed's own (a test's
    /// instruction to the model). Throws what the app would show as a failed run.
    func go(
        worktreeRoot: String, extra: String = "", runFolderRoot: String, extraEnvironment: [String: String] = [:]
    ) async throws {
        let started = Date()
        defer { seconds = Date().timeIntervalSince(started) }
        let id = run.id

        // The agent, as the app chooses it.
        let command = ProcessInfo.processInfo.environment["HEED_LIVE_ACP"] ?? "npx -y @agentclientprotocol/claude-agent-acp"
        guard let adapter = ACPAgents.chosen(HelperSettings(agent: "claude", command: command), defaultAgent: "claude")
        else { throw SmokeFailure("heed knows no ACP way to the agent") }
        let (found, pathVariable) = await ToolLocator.shared.executable(adapter.executable)
        guard let executable = found else { throw SmokeFailure("\(adapter.executable) is not installed") }

        // Who wrote it, so how much the agent may do.
        let viewer = try await GitHub.viewer(caller: "live.run")
        var verdict: BrowseTrust.Verdict
        var prBranch: String?
        if item.kind == .pull {
            let ref = PullRef(repo: item.repo, number: item.number)
            let authorship = try await GitHub.pullAuthorship(ref, caller: "browse.run")
            verdict = BrowseTrust.pull(authorship, viewer: viewer, trustedAuthors: [])
            prBranch = try await GitHub.pullForReview(ref, caller: "browse.run").head
        } else {
            var canWrite: Bool?
            if let login = item.author, login.caseInsensitiveCompare(viewer) != .orderedSame, !item.authorIsBot {
                canWrite = try? await GitHub.canWrite(item.repo, login: login, caller: "browse.run")
            }
            verdict = BrowseTrust.issue(item, viewer: viewer, canWrite: canWrite, trustedAuthors: [])
        }
        self.verdict = verdict
        let mode = BrowseTrust.chatOnly(verdict)
        let pushBranch = verdict.canPush ? prBranch : nil
        mutate {
            $0.mode = mode
            $0.canPush = verdict.canPush
            $0.prBranch = pushBranch
        }

        // Its worktree.
        let plan = BrowseWorktree.plan(for: item, defaultBranch: record.defaultBranch ?? "main", root: worktreeRoot)
        self.plan = plan
        mutate { $0.name = plan.name; $0.branch = plan.branch; $0.worktree = plan.path; $0.story.worktree = plan.path }
        let trusted = verdict.trusted
        worktree = try await BrowseWorktree.create(plan, in: record, untrusted: !trusted, pinnedHead: verdict.headSHA)
        let path = worktree
        mutate { $0.worktree = path; $0.story.worktree = path }
        let escaping = await Task.detached { PathResolver.escapingLinks(in: path) }.value
        if !escaping.isEmpty,
           !trusted { throw SmokeFailure("its checkout holds a link that leads outside it: \(escaping)") }
        let startCommit = await Task.detached { GitPushGuard.head(of: path) }.value
        let setup = HelperSetup.steps(trusted: trusted, commands: [])
        if setup.copyIncludes { _ = await WorktreeInclude.copy(from: record.path, to: path) }

        // Its agent: the sandbox's kept environment, `gh` without a login for an untrusted run and for every Chat.
        let effective = run.effectiveVerb
        let folder = RunFolder.path(run: "heed-browse-\(id)", root: runFolderRoot)
        try RunFolder.prepare(folder)
        var environment = BrowseRunEnvironment.make(
            ProcessInfo.processInfo.environment, agent: adapter.agent, folder: folder, trusted: trusted,
            verb: effective,
            path: pathVariable
        )
        // Haiku only, the one thing the app does not do.
        environment["ANTHROPIC_MODEL"] = LiveSmoke.model
        environment.merge(extraEnvironment) { _, new in new }
        let transport = try RecordingTransport(ACPProcessTransport(
            executable: executable, arguments: adapter.arguments, directory: path, environment: environment
        ))
        let client = ACPClient(transport: transport)
        self.client = client
        await client.start()
        defer { Live.keep("smoke-\(verb.rawValue)-\(item.number).jsonl", transport.log.all.joined(separator: "\n")) }

        let context = BrowsePolicy.Context(
            verb: effective, worktree: path, repo: item.repo, defaultBranch: record.defaultBranch ?? "main",
            trusted: mode == .full, canPush: verdict.canPush, branch: plan.branch,
            pushGuard: GitPushGuard(start: startCommit)
        )
        let reader = Task { [self] in
            for await event in client.events {
                switch event {
                case let .update(_, update):
                    mutate { $0.apply(update, at: Date()) }
                    watchCaps()
                case let .permission(requestID, _, request):
                    // Looked up off the actor, as the app does.
                    let answer = await Task.detached { BrowsePolicy.answer(request, context) }.value
                    let call = request.toolCall
                    let ask = SmokeAsk(
                        kind: call.kind?.rawValue ?? "?", title: call.title ?? "", command: call.command,
                        paths: call.paths ?? [], refusal: answer.refusal
                    )
                    lock.withLock { _asked.append(ask) }
                    if let why = answer.refusal {
                        let what = call.command ?? call.title ?? call.paths?.first ?? "a tool"
                        mutate { $0.refused(what, why: why, at: Date()) }
                    }
                    await client.answerPermission(requestID, optionID: answer.optionID)
                case .closed:
                    return
                }
            }
        }
        defer { reader.cancel() }

        let info = try await client.initialize(clientVersion: "live-smoke")
        let session = try await client.newSession(cwd: path, locked: true, timeout: .seconds(120))
        try await client.setMode(sessionID: session, mode: "default")
        sessionID = session
        model = info.name
        _ = mutateEffects { $0.apply(.ready(note: "\(info.name ?? adapter.title) started"), at: Date()) }

        // heed reads the thread and fences it; no agent fetches comments itself.
        let chat = run.effectiveVerb == .chat
        var thread: Prompt? = chat ? BrowseThread.unavailable : nil
        if let conversation = try? await GitHub.conversation(
            repo: item.repo,
            number: item.number,
            caller: "browse.run.thread"
        ) {
            thread = BrowseThread.prompt(conversation, login: !chat)
        }
        let place = BrowseRunPrompt.Place(
            worktree: path, branch: plan.branch, defaultBranch: record.defaultBranch ?? "main", prBranch: pushBranch,
            fork: item.kind == .pull && !verdict.canPush,
            signing: await CommitSigning.detect(in: path, parent: ProcessInfo.processInfo.environment)
        )
        var prompt = BrowseRunPrompt.start(run, item: item, place: place, thread: thread)
        if !extra.isEmpty { prompt += Prompt.owner("\n\n" + extra) }

        // The one turn, under its caps.
        _ = mutateEffects { $0.apply(.turnStarted, at: Date()) }
        let watchdog = Task { [self] in
            try? await Task.sleep(for: .seconds(LiveSmoke.runTimeout))
            guard !Task.isCancelled else { return }
            cap("ran longer than \(Int(LiveSmoke.runTimeout)) seconds")
        }
        let stop: ACPStopReason
        do {
            stop = try await client.prompt(sessionID: session, text: prompt)
        } catch {
            watchdog.cancel()
            await client.close()
            throw error
        }
        watchdog.cancel()
        self.stop = stop
        // A cap that stopped the turn is read as heed reads it.
        let cancel = capped.map { BrowseRun.Cancel.stop($0) }
        let effects = mutateEffects { $0.apply(.turnEnded(stop, cancel: cancel, connected: true), at: Date()) } ?? []
        if effects.contains(.finishTurn), run.verb == .review {
            let message = run.story.feed.reversed().lazy.compactMap { entry -> String? in
                if case let .message(text) = entry.body { return text }
                return nil
            }.first ?? ""
            mutate { $0.drafted(from: message) }
        }
        try await Task.sleep(for: .milliseconds(500))
        await client.close()
        self.client = nil
    }

    private func mutateEffects(_ body: (inout BrowseRun) -> [BrowseRun.Effect]?) -> [BrowseRun.Effect]? {
        lock.withLock { body(&_run) }
    }

    private func watchCaps() {
        let run = run
        let tools = run.story.feed.count { if case .tool = $0.body { true } else { false } }
        if run.overCap {
            cap("reached its $\(LiveSmoke.spendCap) spend cap")
        } else if tools > LiveSmoke.toolCallCap {
            cap("made more than \(LiveSmoke.toolCallCap) tool calls")
        }
    }

    private func cap(_ why: String) {
        let fire = lock.withLock { () -> Bool in
            guard _capped == nil else { return false }
            _capped = why
            return true
        }
        guard fire, let client, let sessionID else { return }
        Task { await client.cancel(sessionID: sessionID) }
    }

    /// What the run spent, as the agent reported it.
    var usage: String {
        let usage = run.story.usage
        return "cost \(usage.cost.map { String(format: "$%.3f", $0) } ?? "not reported"), context tokens \(usage.tokens)"
    }

    /// What the report says of the run's asks: every command, allowed or refused.
    var askLines: [String] { asked.map(\.line) }

    /// Closing the run as the app does (`closeBrowseRun`): the worktree goes unless it holds work nothing else has.
    @discardableResult
    func close() async -> BrowseCloseDecision {
        guard !worktree.isEmpty, FileManager.default.fileExists(atPath: worktree), let plan else { return .remove }
        let unpushed = await Git.unpushedSinceCreation(record, branch: plan.branch)
        let status = try? await Git.status(at: worktree, on: record.location)
        let dirty = status.map { $0.changedFiles + $0.untrackedFiles }
        let decision = BrowseCloseDecision.decide(unpushed: unpushed, dirty: dirty)
        if decision == .remove { await BrowseWorktree.remove(path: worktree, branch: plan.branch, in: record) }
        return decision
    }

    /// Removes the worktree whatever it holds: the test is over.
    func discard() async {
        guard let plan, !worktree.isEmpty else { return }
        await BrowseWorktree.remove(path: worktree, branch: plan.branch, in: record)
    }
}
