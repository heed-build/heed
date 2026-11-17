import Foundation
import HeedCore

/// The readers' threads: GitHub's rendered bodies and comments, fetched off the main actor when a reader (or
/// Attention's detail) opens a thread, and kept for the session.
extension AppModel {
    /// How many threads stay in memory; the oldest fetched goes first.
    static let conversationsKept = 40

    func conversation(_ repo: Repo, _ number: Int) -> ThreadConversation? {
        threads[ThreadConversation.key(repo: repo, number: number)]?.value
    }

    /// When you last looked at the thread in Attention's reader: the comments before fold, "new · N" marks the rest.
    func seenAt(_ repo: Repo, _ number: Int) -> Date? {
        attention.seen.threads[ThreadConversation.key(repo: repo, number: number)]
    }

    /// Fetches a thread's conversation unless one fetched in the last minute is still current (`updatedAt`: when
    /// the thread last changed, if known). What was there stays on screen while it loads; an earlier failure gives way
    /// to "loading" until this one ends.
    func loadConversation(_ repo: Repo, _ number: Int, updatedAt: Date? = nil) {
        guard !isFixture else { return }
        let key = ThreadConversation.key(repo: repo, number: number)
        if let known = threads[key]?.value, Clock.now.timeIntervalSince(known.fetchedAt) < 60,
           updatedAt.map({ $0 <= known.fetchedAt }) ?? true
        {
            return
        }
        guard threads[key]?.isLoading != true else { return }
        let token = threads[key, default: .idle].start()
        let task = Task { try await GitHub.conversation(repo: repo, number: number, caller: "reader.conversation") }
        threadFetches[key] = (token, task)
        Task {
            do {
                let fetched = try await task.value
                if threads[key]?.token == token { keepConversation(fetched, token: token) }
            } catch {
                threads[key]?.fail(token, (error as? GitHub.Failure)?.description ?? error.localizedDescription)
            }
            if threadFetches[key]?.token == token { threadFetches[key] = nil }
        }
    }

    /// A thread fetched: kept, the oldest fetched going when there are too many. `token`: the load it ends; without
    /// one (a summary's own fetch) it is kept unless a reader's load is running, whose result lands soon.
    private func keepConversation(_ fetched: ThreadConversation, token: LoadToken? = nil) {
        let key = fetched.key
        if let token {
            guard threads[key]?.token == token else { return }
        } else if threads[key]?.isLoading == true {
            return
        }
        if threads[key]?.value == nil, threads.values.count(where: { $0.value != nil }) >= Self.conversationsKept,
           let oldest = threads.compactMap({ key, load in load.value.map { (key, $0.fetchedAt) } })
           .min(by: { $0.1 < $1.1 })?.0
        {
            threads[oldest] = nil
        }
        if let token {
            threads[key]?.finish(token, with: fetched)
        } else {
            threads[key] = .loaded(fetched)
        }
    }

    /// The thread as it is since `updatedAt`, for a summary: the one kept when it is that recent, else the one a
    /// reader is loading right now (awaited), else fetched (`caller`).
    func currentConversation(
        _ repo: Repo, _ number: Int, updatedAt: Date, caller: String
    ) async throws -> ThreadConversation {
        let key = ThreadConversation.key(repo: repo, number: number)
        if let running = threadFetches[key], let fetched = try? await running.task.value,
           fetched.fetchedAt >= updatedAt
        {
            return fetched
        }
        if let known = threads[key]?.value, known.fetchedAt >= updatedAt { return known }
        let fetched = try await GitHub.conversation(repo: repo, number: number, caller: caller)
        keepConversation(fetched)
        return fetched
    }
}
