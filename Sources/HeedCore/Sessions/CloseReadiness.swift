import Foundation

/// Whether a session's work is done with, so closing it loses nothing: every PR it tracks merged or closed, nothing in
/// its worktrees not pushed or not committed, its agent not busy or waiting on you, and no follow-up left open in its
/// ledger entry. Heed only says so (the sidebar's Can close band); you close it.
public enum CloseReadiness {
    public struct Ready: Hashable, Sendable {
        /// `merged · nothing open`, for the row.
        public var reason: String
        /// How it goes to History when closed.
        public var outcome: Outcome
    }

    public static func check(
        _ session: Session, pulls: GitHubState, pending: PendingChanges, followUps: [String]?,
        group: SessionGroup
    ) -> Ready? {
        guard !session.isChat, !session.trackedPRs.isEmpty else { return nil }
        guard group != .pinned, group != .needsYou, !session.state.state.needsYou, session.state.state != .working
        else { return nil }
        let states = session.trackedPRs.map { pulls.pull($0)?.state }
        // A PR heed does not know the state of yet is not done.
        guard states.allSatisfy({ $0 == .merged || $0 == .closed }) else { return nil }
        guard pending.ahead == 0, pending.dirty == 0 else { return nil }
        guard (followUps ?? []).isEmpty else { return nil }
        let merged = states.allSatisfy { $0 == .merged }
        return Ready(
            reason: "\(merged ? "merged" : "closed") · nothing open", outcome: merged ? .merged : .closed
        )
    }
}
