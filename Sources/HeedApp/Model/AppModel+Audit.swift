import AppKit
import Foundation
import HeedCore

/// Audit (`history.audit`): what heed and the agents did outside this Mac, and why. Causes are made where heed starts
/// something and carried with the work; heed's own outward calls arrive through `AuditTap`, the agents' through their
/// hooks' tool calls, releases and deployments from GitHub. Nothing here takes focus or notifies.
extension AppModel {
    // MARK: Starting

    /// Opens Audit on `heed.sqlite`, takes heed's own calls from now on, and looks for releases on heed's cadence.
    func startAudit(log: EventLog?) {
        guard !isFixture else { return }
        let roots: @Sendable () async -> [String] = { [weak self] in
            await MainActor.run { self?.auditRoots ?? [] }
        }
        audit.attach(log: log, roots: roots)
        TerminalSurfaces.shared.causeFor = { [weak self] pane, session in
            self?.auditCauseID(pane: pane, session: session)
        }
        AuditTap.install { [weak self] action, cause in
            Task { @MainActor in self?.recordHeedAction(action, cause: cause) }
        }
        startAuditReleases()
    }

    /// Where Always rules are kept: every local checkout and worktree heed knows.
    var auditRoots: [String] {
        let local = repos.filter(\.location.isLocal).map(\.path) + worktrees.filter(\.location.isLocal).map(\.path)
        return Array(Set(local)).sorted()
    }

    // MARK: Causes

    /// The cause of a command you ran: the key that runs it here and its name.
    func keyCause(_ command: CommandInvocation) -> Cause {
        let key = keyLabel(for: command.name)
        let name = ([command.name] + command.arguments).joined(separator: " ")
        return Cause(at: Clock.now, trigger: .key, detail: key.map { "\($0) · \(name)" } ?? ":\(name)")
    }

    /// Runs `body` under a cause of its own, below the one in effect (or the session's).
    func withCause<T>(
        _ trigger: Cause.Trigger, _ detail: String, session: Session? = nil, authors: [ExternalText.Author] = [],
        _ body: () throws -> T
    ) rethrows -> T {
        let cause = makeCause(trigger, detail, session: session, authors: authors)
        return try Cause.$current.withValue(cause, operation: body)
    }

    /// `withCause` for async work.
    func withCause<T>(
        _ trigger: Cause.Trigger, _ detail: String, session: Session? = nil, authors: [ExternalText.Author] = [],
        _ body: () async throws -> T
    ) async rethrows -> T {
        let cause = makeCause(trigger, detail, session: session, authors: authors)
        return try await Cause.$current.withValue(cause, operation: body)
    }

    func makeCause(
        _ trigger: Cause.Trigger, _ detail: String, session: Session?, authors: [ExternalText.Author]
    ) -> Cause {
        let parent = Cause.current ?? session.flatMap { audit.cause(session: $0.id, pane: nil) }
        let cause = Cause(
            at: Clock.now, trigger: trigger, detail: detail, parent: parent?.id,
            session: session?.id ?? parent?.session,
            sessionTitle: session?.title ?? parent?.sessionTitle, agent: session?.agent ?? parent?.agent,
            authors: authors
        )
        audit.note(cause)
        return cause
    }

    /// New sessions carry the cause they started under (`Cause.current`: the key, the rule, the event).
    func noticeAuditSessions(before: Domain, after: Domain) {
        let known = Set(before.sessions.map(\.id))
        for session in after.sessions where !known.contains(session.id) && audit.sessionCauses[session.id] == nil {
            let parent = Cause.current
            let cause = Cause(
                at: Clock.now, trigger: .session, detail: "started \(session.agent) on \"\(session.title)\"",
                parent: parent?.id, session: session.id, sessionTitle: session.title, agent: session.agent
            )
            if let parent { audit.note(parent) }
            audit.bind(session: session.id, to: cause)
        }
    }

    /// Heed hands `prompt` to the agent in `pane` (a launch, a message): whose text is in it goes on the cause of what
    /// that agent does next.
    func auditPrompt(_ prompt: Prompt, pane: String, session id: String?) {
        let session = id.flatMap { id in sessions.first { $0.id == id } }
        let authors = prompt.authors
        let base = audit.cause(session: id, pane: pane)
        // Nothing new: the pane keeps the cause it has.
        if authors.isEmpty, base != nil, Cause.current == nil { return }
        // What brought this prompt (a PR event, a key) hangs under the session or run it reached, when it is new.
        let parent = Cause.current.map { current in base.map { audit.reparent(current, under: $0) } ?? current }
            ?? base
        let cause = Cause(
            at: Clock.now, trigger: .session,
            detail: authors
                .isEmpty ? "heed's prompt" : "a prompt with \(authors.map(\.handle).joined(separator: ", "))",
            parent: parent?.id, session: id, sessionTitle: session?.title ?? parent?.sessionTitle,
            agent: session?.agent ?? parent?.agent, authors: authors
        )
        if let parent { audit.note(parent) }
        audit.bind(pane: pane, to: cause)
    }

    /// A helper heed starts on a PR: what started it (a key, a PR event, an Autopilot rule) is its parent.
    func noteHelperCause(_ id: String, _ what: String, sessionID: String?) {
        let session = sessionID.flatMap { id in sessions.first { $0.id == id } }
        let parent = Cause.current
        let cause = Cause(
            at: Clock.now, trigger: .helper, detail: what, parent: parent?.id, session: sessionID,
            sessionTitle: session?.title, agent: "helper"
        )
        if let parent { audit.note(parent) }
        audit.bind(pane: "helper:\(id)", to: cause)
    }

    /// The close-out of a helper (its push, its replies), under the helper's cause.
    func helperCloseOutCause(_ id: String) -> Cause {
        let base = audit.cause(session: nil, pane: "helper:\(id)")
        let how = Cause.current.map { $0.trigger == .key ? "close-out, by you (\($0.detail))" : "close-out" }
            ?? "close-out"
        let cause = Cause(
            at: Clock.now, trigger: .helper, detail: how, parent: base?.id, session: base?.session,
            sessionTitle: base?.sessionTitle, agent: base?.agent
        )
        audit.note(cause)
        return cause
    }

    /// The cause a pane's agent works under, for its environment (`HEED_CAUSE`).
    func auditCauseID(pane: String, session: String) -> String? { audit.cause(session: session, pane: pane)?.id }

    // MARK: Recording

    /// One of heed's own calls that left this Mac, from `AuditTap`.
    func recordHeedAction(_ action: AuditAction, cause: Cause?) {
        var action = action
        if let cause { audit.note(cause) }
        if let id = action.session ?? cause?.session, let session = sessions.first(where: { $0.id == id }) {
            action.session = id
            action.sessionTitle = action.sessionTitle ?? session.title
            action.repo = action.repo ?? session.repos.first?.slug
        }
        audit.record(action)
    }

    /// An agent's tool call its hooks reported: recorded when it did something outside this Mac, with the approval
    /// that let it through.
    func auditToolCall(_ call: ToolCall, message: HookMessage, session: Session) {
        // The cause its environment names, when it is one heed made for this session.
        let named = message.cause.flatMap { audit.cause($0) }.flatMap { $0.session == session.id ? $0 : nil }
        let base = named ?? audit.cause(session: session.id, pane: message.pane)
        guard var action = AuditClassifier.action(
            call, at: message.sentAt, session: session.id, sessionTitle: session.title,
            agent: message.agent ?? session.agent, repo: session.repos.first?.slug, cause: base
        ) else { return }
        action.approval = takeAuditApproval(session: session.id, command: action.command)
            ?? .init(by: .agent, detail: "an Always rule or the agent's own mode")
        audit.record(action)
    }

    /// What you answered to an outward ask, kept until the agent's call shows it ran; a no is recorded at once as
    /// held.
    func auditAnswer(_ group: ApprovalGroup, _ answer: PermissionAnswer, by: AuditAction.Approval.By = .you) {
        guard answer.decision != .pass else { return }
        for ask in group.asks {
            guard let command = ask.command, AuditClassifier.isOutward(command) else {
                if answer.always { recordAlwaysGrant(ask) }
                continue
            }
            if answer.always { recordAlwaysGrant(ask) }
            let detail = answer.decision == .allow ? (answer.always ? "allowed always" : "allowed once") : "denied"
            let approval = AuditAction.Approval(by: by, at: Clock.now, detail: detail)
            guard answer.decision == .deny,
                  let session = sessions.first(where: { $0.id == ask.session }),
                  var action = AuditClassifier.action(
                      ToolCall(tool: "Bash", input: command, command: command), at: Clock.now, session: session.id,
                      sessionTitle: session.title, agent: ask.agent, repo: session.repos.first?.slug,
                      cause: audit.cause(session: session.id, pane: ask.pane)
                  )
            else {
                auditApprovals[ask.session, default: []].append((command, approval))
                continue
            }
            action.approval = approval
            action.outcome = .held
            audit.record(action)
        }
    }

    private func takeAuditApproval(session: String, command: String) -> AuditAction.Approval? {
        guard var list = auditApprovals[session],
              let index = list.firstIndex(where: { command.hasPrefix($0.command) || $0.command.hasPrefix(command) })
        else { return nil }
        let approval = list.remove(at: index).approval
        auditApprovals[session] = list.isEmpty ? nil : list
        return approval
    }

    // MARK: Export

    /// `:audit.export`: the whole record, as JSON lines, to a file you pick.
    func exportAudit() {
        guard !isFixture else { return flash = "fixture: nothing to export" }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "heed-audit.jsonl"
        panel.allowedContentTypes = []
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor [weak self] in await self?.writeAudit(to: url) }
        }
    }

    private func writeAudit(to url: URL) async {
        guard let text = await audit.exportText() else { return flash = "Audit has no record to export" }
        do {
            try await Task.detached { try Data(text.utf8).write(to: url, options: .atomic) }.value
            flash = "Audit written to \(Paths.abbreviate(url.path))"
        } catch {
            flash = "could not write \(url.lastPathComponent): \(error)"
        }
    }

    // MARK: Releases

    /// Every 30 minutes, the releases and deployments on the repos heed watches (read only, off the main actor): any
    /// no recorded cause explains goes in as outside heed.
    private func startAuditReleases() {
        auditReleaseTask?.cancel()
        auditReleaseTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(90))
            while !Task.isCancelled {
                await self?.checkAuditReleases()
                try? await Task.sleep(for: .seconds(30 * 60))
            }
        }
    }

    private func checkAuditReleases() async {
        let watched = Array(Set(sessions.flatMap(\.repos) + history.prefix(50).flatMap(\.session.repos)))
            .filter { repo in repos.contains { $0.repo == repo } }.prefix(20)
        guard !watched.isEmpty else { return }
        let found = await withTaskGroup(of: [GitHubRelease].self) { group in
            for repo in watched {
                group.addTask { await GitHub.releases(repo, caller: "audit.releases") }
            }
            var all: [GitHubRelease] = []
            for await list in group {
                all += list
            }
            return all
        }
        let unexplained = AuditOutside.unexplained(
            found, actions: audit.book.actions, since: audit.startedAt, known: audit.book.outsideKeys
        )
        for release in unexplained.sorted(by: { $0.at < $1.at }) {
            audit.record(release.action())
        }
    }
}
