import Foundation
import HeedCore

/// Where a tool result came from, for Claude's auto mode: heed keeps the facts its hooks read (`OriginKeeper`), asks
/// GitHub (read only, off the main actor) when a hook found it did not know enough, and records each note it gave in
/// Audit, on the cause of what that agent does next.
extension AppModel {
    /// What heed holds changed: the facts are projected again, off the main actor, in the order taken here.
    func noticeOrigins() {
        guard !isFixture else { return }
        let checkouts = (repos.filter(\.location.isLocal).map { (path: $0.path, repo: $0.repo) }
            + worktrees.filter(\.location.isLocal).map { (path: $0.path, repo: $0.repo) })
        let snapshot = OriginKeeper.Snapshot(
            viewer: github.viewer, checkouts: checkouts, details: Array(pullDetails.values), issues: github.issues
        )
        origins.submit(snapshot)
    }

    /// A hook's report on one call that brought GitHub content in.
    func noticeOrigin(_ report: OriginReport, message: HookMessage, session: Session) {
        if let note = report.note { auditOriginNote(note, authors: report.authors, message: message, session: session) }
        guard !isFixture else { return }
        let origins = origins, subject = report.subject, hadNote = report.note != nil
        Task.detached(priority: .utility) {
            await origins.warm(subject, hadNote: hadNote) { repo, number in
                try await GitHub.origin(repo: repo, number: number, caller: "origin.warm")
            }
        }
    }

    /// The note, as a cause under the one the agent works under: what it does next in that pane hangs below it, so
    /// its row in Audit says what heed told auto mode, and whose text it had read.
    private func auditOriginNote(
        _ note: String, authors: [ExternalText.Author], message: HookMessage, session: Session
    ) {
        let key = message.pane ?? session.id
        let told = audit.toldCause(key)
        let detail = "Told auto mode: \(note)"
        guard told?.detail != detail else { return }
        let named = message.cause.flatMap { audit.cause($0) }.flatMap { $0.session == session.id ? $0 : nil }
        let parent = told ?? named ?? audit.cause(session: session.id, pane: message.pane)
        let cause = Cause(
            at: message.sentAt, trigger: .agent, detail: detail, parent: parent?.id, session: session.id,
            sessionTitle: session.title, agent: message.agent ?? session.agent, authors: authors
        )
        if let parent { audit.note(parent) }
        audit.bind(told: key, to: cause)
    }
}
