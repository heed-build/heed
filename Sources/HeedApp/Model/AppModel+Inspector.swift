import AppKit
import Foundation
import HeedCore

/// What the inspector shows beyond a session's own facts (`SessionContext`), and what its parts do.
extension AppModel {
    /// The Mindmap instance and tree that place this session's work, if any does.
    func placement(of session: Session) -> (instance: String, tree: MindmapTree)? {
        for instance in mindmap.instances {
            let tree = mindmap.tree(instance)
            if tree.work(for: session.id) != nil { return (instance, tree) }
        }
        return nil
    }

    func summary(of session: Session) -> String? {
        SessionContext.summary(of: session, entry: ledger.entries[session.id])
    }

    func learnedDecisions(of session: Session) -> [MindNode.Decision] {
        placement(of: session).map { SessionContext.decisions(for: session, in: $0.tree) } ?? []
    }

    func looseEnds(of session: Session) -> [(node: String, item: MindNode.OpenItem)] {
        placement(of: session).map { SessionContext.looseEnds(for: session, in: $0.tree) } ?? []
    }

    func overlaps(of session: Session) -> [(session: Session, files: [String])] {
        SessionContext.overlaps(of: session, sessions: sessions, worktrees: worktrees)
    }

    /// Loose ends handed to the session's agent as one prompt, when it can take one; it waits for nobody, so a busy
    /// agent says so and nothing is typed.
    func tackle(_ items: [MindNode.OpenItem], in session: Session) {
        guard !items.isEmpty else { return }
        guard let layout = layouts[session.id], let (_, paneID) = agentPane(in: layout) else {
            return flash = "\(session.title) has no agent pane to hand them to"
        }
        if case let .wait(reason) = Delivery.verdict(
            state: session.state.state, lastTyped: lastTyped[session.id], typingGrace: 20
        ) {
            return flash = "not now: \(reason)"
        }
        TerminalSurfaces.shared.typeLine(SessionContext.tackle(items), paneID: paneID)
        flash = "handed \(items.count) loose end\(items.count == 1 ? "" : "s") to \(session.agent)"
    }

    /// A loose end marked done, on the node it lives on.
    func resolveLooseEnd(_ item: MindNode.OpenItem, on node: String, of session: Session) {
        guard let instance = placement(of: session)?.instance else { return }
        Task { await mindmap.change(instance) { $0.resolve(item.text, in: node, now: Date()) } }
    }

    /// The inspector's right-click items: a loose end handed over or marked done, a path copied.
    func performInspector(_ command: CommandInvocation) {
        switch command.name {
        case "inspector.copy":
            let path = command.arguments.joined(separator: " ")
            if !path.isEmpty { copyPath(path) }
        case "inspector.resolve":
            guard let session = currentSession, command.arguments.count >= 2 else { return }
            let node = command.arguments[0]
            let text = command.arguments.dropFirst().joined(separator: " ")
            guard let item = looseEnds(of: session).first(where: { $0.node == node && $0.item.text == text })?.item
            else { return }
            resolveLooseEnd(item, on: node, of: session)
        default:
            guard let session = currentSession else { return }
            let text = command.arguments.joined(separator: " ")
            let all = looseEnds(of: session).map(\.item)
            tackle(text.isEmpty ? all : all.filter { $0.text == text }, in: session)
        }
    }

    /// A path on the pasteboard, said so.
    func copyPath(_ path: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        flash = "copied \(Paths.abbreviate(path))"
    }
}
