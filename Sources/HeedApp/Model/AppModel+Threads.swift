import Foundation
import HeedCore

/// The readers' threads: GitHub's rendered bodies and comments, fetched off the main actor when a reader (or
/// Attention's detail) opens a thread, and kept for the session.
extension AppModel {
    /// How many threads stay in memory; the oldest fetched goes first.
    static let conversationsKept = 40

    func conversation(_ repo: Repo, _ number: Int) -> ThreadConversation? {
        conversations[ThreadConversation.key(repo: repo, number: number)]
    }

    /// When you last looked at the thread in Attention's reader: the comments before fold, "new · N" marks the rest.
    func seenAt(_ repo: Repo, _ number: Int) -> Date? {
        attention.seen.threads[ThreadConversation.key(repo: repo, number: number)]
    }

    /// Fetches a thread's conversation unless one fetched in the last minute is still current (`updatedAt`: when
    /// the thread last changed, if known). What was there stays on screen while it loads.
    func loadConversation(_ repo: Repo, _ number: Int, updatedAt: Date? = nil) {
        guard !isFixture else { return }
        let key = ThreadConversation.key(repo: repo, number: number)
        if let known = conversations[key], Clock.now.timeIntervalSince(known.fetchedAt) < 60,
           updatedAt.map({ $0 <= known.fetchedAt }) ?? true
        {
            return
        }
        guard !conversationsLoading.contains(key) else { return }
        conversationsLoading.insert(key)
        Task {
            defer { conversationsLoading.remove(key) }
            do {
                let fetched = try await GitHub.conversation(repo: repo, number: number, caller: "reader.conversation")
                keepConversation(fetched)
            } catch {
                conversationErrors[key] = (error as? GitHub.Failure)?.description ?? error.localizedDescription
            }
        }
    }

    /// A thread fetched: kept, the oldest fetched going when there are too many.
    private func keepConversation(_ fetched: ThreadConversation) {
        let key = fetched.key
        if conversations[key] == nil, conversations.count >= Self.conversationsKept,
           let oldest = conversations.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key
        {
            conversations[oldest] = nil
        }
        conversations[key] = fetched
        conversationErrors[key] = nil
    }

    /// The thread as it is since `updatedAt`, for a summary: the one kept when it is that recent, else the one a
    /// reader is loading right now, else fetched (`caller`).
    func currentConversation(
        _ repo: Repo, _ number: Int, updatedAt: Date, caller: String
    ) async throws -> ThreadConversation {
        let key = ThreadConversation.key(repo: repo, number: number)
        var waited = 0
        while conversationsLoading.contains(key), waited < 150 {
            try await Task.sleep(for: .milliseconds(200))
            waited += 1
        }
        if let known = conversations[key], known.fetchedAt >= updatedAt { return known }
        let fetched = try await GitHub.conversation(repo: repo, number: number, caller: caller)
        keepConversation(fetched)
        return fetched
    }
}
