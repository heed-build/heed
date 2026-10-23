import Foundation
import HeedCore

/// The control socket's requests, answered on the main actor. Nothing here takes focus unless the request asks:
/// a session started from an editor starts off screen, as a resumed one does.
extension AppModel {
    func startControl() {
        guard !isFixture, controlServer == nil else { return }
        let server = ControlServer { [weak self] request in
            await self?.control(request) ?? .failure("Heed is closing")
        }
        do {
            try server.start()
        } catch {
            flash = "control socket: \(error)"
            return
        }
        controlServer = server
        publishControl()
    }

    /// Every session as the socket describes it.
    var controlSessions: [ControlSession] {
        sessions.map { session in
            let pilot = sessionPilot(session)
            let needsYou = session.state.state.needsYou || pilot.status?.needsYou == true || pilot.helperNeedsYou
            return ControlSession(session, needsYou: needsYou, group: SessionGroup.of(session, pilot: pilot))
        }
    }

    func publishControl() {
        guard let controlServer else { return }
        controlServer.publish(controlSessions)
    }

    func control(_ request: ControlRequest) async -> ControlReply {
        switch request.method {
        case .sessions, .watch: ControlReply(sessions: controlSessions)
        case .start: await controlStart(request)
        case .send: controlSend(request)
        case .show: controlShow(request)
        }
    }

    /// Starts `agent` on `prompt` in `directory`: as work in that worktree when heed knows it, else as a chat in the
    /// folder. A worktree that already has a session is refused with that session's id, so the caller can send to it.
    private func controlStart(_ request: ControlRequest) async -> ControlReply {
        guard let directory = request.directory, !directory.isEmpty else { return .failure("start needs a directory") }
        let path = Self.canonical(Paths.expand(directory))
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .failure("no folder at \(path)")
        }
        let name = request.agent.flatMap { $0.isEmpty ? nil : $0 } ?? settings.defaultAgent
        guard let agent = settings.agent(name) else {
            return .failure("no agent \(name) (\(settings.agents.map(\.name).joined(separator: ", ")))")
        }
        let prompt = request.prompt ?? ""
        let changes: [DomainChange]
        if let worktree = worktrees.first(where: { $0.location.isLocal && Self.canonical($0.path) == path }) {
            if let existing = session(for: worktree) {
                return ControlReply(ok: false, error: "\(existing.title) already works there", session: existing.id)
            }
            changes = Import.session(
                for: worktree, agent: agent, resume: nil, integration: integration, prompt: prompt,
                arguments: request.arguments ?? []
            )
        } else {
            var plan = StartWorkPlan(prompt: prompt, repos: [], name: "", agent: agent, integration: integration)
            plan.chat = ChatPlan(kind: .folder, name: path)
            plan.arguments = request.arguments ?? []
            do {
                changes = try await StartWork.execute(plan, settings: settings, hosts: config.hosts)
            } catch {
                return .failure("start failed: \(error)")
            }
        }
        guard case let .sessionUpserted(session)? = changes.first(where: {
            if case .sessionUpserted = $0 { true } else { false }
        }) else { return .failure("start made no session") }
        var panes: [PaneSpec] = []
        for case let .layoutChanged(_, layout) in changes {
            for pane in layout.tabs.flatMap(\.tree.panes) where pane.command != nil {
                TerminalSurfaces.shared.autostartPanes.insert(pane.id)
                panes.append(pane)
            }
        }
        commit(changes)
        // Started now, on or off screen; heed comes forward only when asked.
        for pane in panes {
            TerminalSurfaces.shared.prepare(pane, sessionID: session.id)
        }
        if request.focus == true { show(sessionID: session.id) }
        flash = "started \(session.title) from another app"
        return ControlReply(session: session.id)
    }

    /// Types `text` into the session's agent pane and presses Return, only when the agent is idle or done and you
    /// have not just typed there yourself.
    private func controlSend(_ request: ControlRequest) -> ControlReply {
        guard let id = request.session, let session = sessions.first(where: { $0.id == id }) else {
            return .failure("no session \(request.session ?? "")")
        }
        guard let text = request.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .failure("nothing to send")
        }
        guard let layout = layouts[id], let (_, paneID) = agentPane(in: layout),
              TerminalSurfaces.shared.hasTerminal(paneID: paneID)
        else { return .failure("\(session.title) has no running agent pane: open it in Heed") }
        if case let .wait(reason) = Delivery.verdict(state: session.state.state, lastTyped: lastTyped[id]) {
            return .failure("not sent: \(reason)")
        }
        TerminalSurfaces.shared.typeLine(text, paneID: paneID)
        var sent = session
        sent.record("sent \(text.count) characters from another app")
        commit(.sessionUpserted(sent))
        if request.focus == true { show(sessionID: id) }
        return ControlReply(session: id)
    }

    private func controlShow(_ request: ControlRequest) -> ControlReply {
        guard let id = request.session, sessions.contains(where: { $0.id == id }) else {
            return .failure("no session \(request.session ?? "")")
        }
        if request.focus == true {
            show(sessionID: id)
        } else {
            view = .sessions
            select(sessionID: id)
        }
        return ControlReply(session: id)
    }

    /// A path as the file system names it: symlinks resolved (`/tmp` is `/private/tmp`), no trailing slash.
    nonisolated static func canonical(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}
