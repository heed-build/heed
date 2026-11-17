import Foundation
@testable import HeedCore
import Testing

struct GitHubSyncStampTests {
    private static let earlier = Date(timeIntervalSince1970: 1_800_000_000)
    private static let later = earlier.addingTimeInterval(60)

    private static func state(at: Date, title: String = "Fix it") -> GitHubState {
        let repo = Repo(org: "o", name: "r")
        let item = InboxItem(
            id: "1", kind: .pr, repo: repo, number: 3, title: title, reason: "team_mention", unread: true,
            updatedAt: earlier, url: nil
        )
        var mentions = TeamMentionCache()
        mentions.record(item, teams: ["o/t"], source: .search, now: at)
        return GitHubState(
            viewer: "me", inbox: [item], syncedAt: at, status: .ok, teamMentions: mentions,
            fetches: GitHubFetches(notifications: SourceFetch(fetched: 1, total: 1, capped: false, at: at))
        )
    }

    /// Two syncs a minute apart that brought the same: only the stamp differs, so the data is left alone.
    @Test func aSyncThatBroughtNothingNewHasTheSameData() {
        let first = Self.state(at: Self.earlier)
        let second = Self.state(at: Self.later)
        #expect(first != second)
        #expect(second.sameData(as: first))
        #expect(second.stamped(first.stamp) == first)
    }

    @Test func aSyncThatBroughtSomethingHasNewData() {
        #expect(!Self.state(at: Self.later, title: "Fix it again").sameData(as: Self.state(at: Self.earlier)))
        var offline = Self.state(at: Self.earlier)
        offline.status = .offline("no network")
        #expect(!offline.sameData(as: Self.state(at: Self.earlier)))
    }

    @Test func theNewerStampWins() {
        let old = Self.state(at: Self.earlier)
        let newer = Self.state(at: Self.later).stamp
        #expect(old.freshened(by: newer).syncedAt == Self.later)
        #expect(old.freshened(by: newer).fetches == newer.fetches)
        #expect(old.freshened(by: nil) == old)
        // A stamp older than the state's own changes nothing.
        #expect(Self.state(at: Self.later).freshened(by: old.stamp) == Self.state(at: Self.later))
    }
}
