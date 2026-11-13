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
                if conversations[key] == nil, conversations.count >= Self.conversationsKept,
                   let oldest = conversations.min(by: { $0.value.fetchedAt < $1.value.fetchedAt })?.key
                {
                    conversations[oldest] = nil
                }
                conversations[key] = fetched
                conversationErrors[key] = nil
            } catch {
                conversationErrors[key] = (error as? GitHub.Failure)?.description ?? error.localizedDescription
            }
        }
    }
}
