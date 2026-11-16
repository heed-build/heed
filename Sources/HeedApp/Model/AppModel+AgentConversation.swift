import Foundation
import HeedCore

/// "Define with an agent" (a goal's part, a persona): one read-only ACP conversation at a time in a slot, the same
/// code for both. Whatever arrives for a conversation that is no longer the slot's (an event, a reply, a client
/// made after it was closed) is dropped, and that client closed.
extension AppModel {
    typealias ConversationSlot = ReferenceWritableKeyPath<AppModel, AgentConversation?>

    /// What a defining conversation reports, for the definition on screen.
    struct ConversationHandlers {
        /// It could not connect, a turn failed, or the agent exited while it was answering: why.
        var failed: @MainActor (String) -> Void
        /// Everything it read so far, and the directory it reads in.
        var reads: @MainActor ([String], String?) -> Void
        var cost: @MainActor (Double) -> Void
    }

    /// Opens a conversation in `directory` into `slot`, closing any there; `ready` runs once its session is open.
    func openAgentConversation(
        _ slot: ConversationSlot, adapter: ACPAdapter, directory: String, handlers: ConversationHandlers,
        ready: @escaping @MainActor () -> Void
    ) {
        closeAgentConversation(slot)
        let conversation = AgentConversation(root: directory)
        self[keyPath: slot] = conversation
        let id = conversation.id
        Task {
            let (path, pathVariable) = await ToolLocator.shared.executable(adapter.executable)
            guard self[keyPath: slot]?.id == id else { return }
            guard let path else {
                return conversationFailed(
                    slot, id, "\(adapter.executable) is not installed" + (adapter.install.map { ": \($0)" } ?? ""),
                    handlers
                )
            }
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = pathVariable
            do {
                let transport = try ACPProcessTransport(
                    executable: path, arguments: adapter.arguments, directory: directory, environment: environment
                )
                let client = ACPClient(transport: transport)
                // Closed while the agent was being found: this client is nobody's.
                guard AgentConversation.update(&self[keyPath: slot], id, { $0.attach(client) }) else {
                    return await client.close()
                }
                await client.start()
                Task { [weak self] in
                    for await event in client.events {
                        self?.conversationEvent(event, slot, id, client: client, handlers)
                    }
                }
                _ = try await client.initialize(clientVersion: appVersion)
                let session = try await client.newSession(cwd: directory)
                // Closed while connecting: closing it closed the client too.
                guard AgentConversation.update(&self[keyPath: slot], id, { $0.connected(session: session) }) else {
                    return
                }
                ready()
            } catch {
                conversationFailed(slot, id, "\(error)", handlers)
            }
        }
    }

    /// One turn: `done` gets the agent's reply when it ends. False when the conversation has no session yet (or is
    /// in a turn already).
    @discardableResult
    func agentConversationTurn(
        _ slot: ConversationSlot, text: String, handlers: ConversationHandlers,
        done: @escaping @MainActor (String) -> Void
    ) -> Bool {
        guard let id = self[keyPath: slot]?.id else { return false }
        var turn: (client: ACPClient, session: String)?
        AgentConversation.update(&self[keyPath: slot], id) { turn = $0.beginTurn() }
        guard let turn else { return false }
        Task {
            do {
                _ = try await turn.client.prompt(sessionID: turn.session, text: .owner(text))
                var reply: String?
                AgentConversation.update(&self[keyPath: slot], id) { reply = $0.endTurn() }
                if let reply { done(reply) }
            } catch {
                conversationFailed(slot, id, "\(error)", handlers)
            }
        }
        return true
    }

    /// Ends the slot's conversation, closing its client (one still being made closes itself when it sees it gone).
    func closeAgentConversation(_ slot: ConversationSlot) {
        if let client = AgentConversation.close(&self[keyPath: slot]) {
            Task { await client.close() }
        }
    }

    private func conversationFailed(
        _ slot: ConversationSlot, _ id: UUID, _ why: String, _ handlers: ConversationHandlers
    ) {
        guard AgentConversation.update(&self[keyPath: slot], id, { $0.failed(why) }) else { return }
        handlers.failed(why)
    }

    private func conversationEvent(
        _ event: ACPEvent, _ slot: ConversationSlot, _ id: UUID, client: ACPClient, _ handlers: ConversationHandlers
    ) {
        // An event of an earlier conversation (a client still draining) is dropped.
        guard let conversation = self[keyPath: slot], conversation.id == id else { return }
        switch event {
        case let .update(_, update):
            switch update {
            case let .agentMessage(chunk):
                AgentConversation.update(&self[keyPath: slot], id) { $0.received(chunk) }
            case let .toolCall(call), let .toolCallUpdate(call):
                if [.read, .search].contains(call.kind ?? .other), let paths = call.paths, !paths.isEmpty {
                    AgentConversation.update(&self[keyPath: slot], id) { $0.read(paths) }
                    handlers.reads(self[keyPath: slot]?.paths ?? [], conversation.root)
                }
            case let .usage(_, _, cost, _): if let cost { handlers.cost(cost) }
            default: break
            }
        case let .permission(requestID, _, request):
            // Reading goes ahead; anything that would change something is refused (DefinePolicy).
            Task { await client.answerPermission(requestID, optionID: DefinePolicy.answer(request)) }
        case let .closed(reason):
            if conversation.exitInterrupts {
                conversationFailed(slot, id, "the agent exited" + (reason.map { ": \($0)" } ?? ""), handlers)
            }
        }
    }
}
