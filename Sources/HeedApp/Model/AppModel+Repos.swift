import HeedCore

/// What the Repos view shows about each repo and worktree, from what heed already has (no IO).
extension AppModel {
    /// Each listed repo's summary, by record id: its main checkout against origin, when you last worked there, the
    /// hosts it is also on, and what its setup lacks.
    var repoSummaries: [String: RepoSummary] {
        let lastWorked = StartWork.lastWorked(sessions: sessions, closed: history)
        let now = Clock.now
        return Dictionary(uniqueKeysWithValues: sortedRepos.map { record in
            let main = worktrees.first {
                $0.isMain && $0.repo == record.repo && $0.location == record.location && $0.path == record.path
            } ?? worktrees.first { $0.isMain && $0.repo == record.repo && $0.location == record.location }
            let hosts = repos.filter { $0.repo == record.repo }.compactMap(\.location.hostName)
                .filter { $0 != record.location.hostName }
            let setup = record.repo.org == "local" ? nil : setupStatus(for: record.repo)
            return (record.id, RepoSummary.of(
                record, main: main, lastWorked: lastWorked[record.id], hosts: Array(Set(hosts)).sorted(),
                setup: setup, now: now
            ))
        })
    }

    /// The record the column picked, on this Mac when it is there.
    var pickedRecord: RepoRecord? {
        guard let picked = pickedRepo else { return nil }
        return sortedRepos.first { $0.repo == picked }
    }

    /// When a worktree was last touched, for the table: your last keystroke in its session (or the session's
    /// start), else its last commit.
    func worktreeAge(_ worktree: Worktree) -> String? {
        let since = session(for: worktree)?.touched ?? lastCommits[worktree.path]
        return since.map { RepoSummary.age($0, now: Clock.now) }
    }
}
