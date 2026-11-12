import Foundation
import HeedCore

/// How much each session changed, kept fresh: a session's repos are listed again (with their status and, for its own
/// worktrees, their size against the base) when its agent finishes a turn, at most once a minute a repo.
extension AppModel {
    /// The worktrees of open sessions: the ones heed measures.
    var sessionWorktreePaths: Set<String> { Set(sessions.flatMap(\.worktreePaths)) }

    func noticeTurnEnds(before: Domain, after: Domain) {
        guard !isFixture else { return }
        let earlier = Dictionary(before.sessions.map { ($0.id, $0.lastMessage) }) { first, _ in first }
        for session in after.sessions where !session.isChat {
            guard let previous = earlier[session.id], previous != session.lastMessage, session.lastMessage != nil
            else { continue }
            refreshWorktrees(of: session)
        }
    }

    func refreshWorktrees(of session: Session, now: Date = Date()) {
        let measured = sessionWorktreePaths
        for repo in session.repos {
            // Every clone of the repo on the session's machine: a listing replaces what was known there.
            let clones = repos.filter { $0.repo == repo && $0.location.hostName == session.host }
            let key = "\(repo.slug)@\(session.host ?? "")"
            guard !clones.isEmpty, now.timeIntervalSince(sizeRefreshedAt[key] ?? .distantPast) > 60 else { continue }
            sizeRefreshedAt[key] = now
            Task {
                var listed: [Worktree] = []
                for record in clones {
                    for worktree in await (try? Git.worktrees(of: record)) ?? []
                        where !listed.contains(where: { $0.path == worktree.path })
                    {
                        var worktree = worktree
                        worktree.status = try? await Git.status(
                            at: worktree.path, on: record.location, withSize: measured.contains(worktree.path)
                        )
                        listed.append(worktree)
                    }
                }
                guard !listed.isEmpty else { return }
                commit(.worktreesListed(repo: repo, listed))
            }
        }
    }
}
