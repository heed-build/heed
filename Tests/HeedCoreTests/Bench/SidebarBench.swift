import Foundation
@testable import HeedCore
import Testing

/// What one sidebar rebuild costs in HeedCore: the list over 200 sessions sorted by size with 40 done, and finding
/// each of their PRs among 2,000.
@Suite(.enabled(if: Bench.enabled), .serialized)
struct SidebarBench {
    static let repo = Repo(org: "acme", name: "docs")
    static let base = Date(timeIntervalSince1970: 1_000_000)

    static let sessions: [Session] = (0 ..< 200).map { index in
        var session = Session(
            id: "s\(index)", title: "session \(index)", repos: [repo], branch: "b\(index)", agent: "claude",
            state: ObservedState(index % 5 == 0 ? .idle : .working),
            trackedPRs: (0 ..< 3).map { PullRef(repo: repo, number: index * 10 + $0) }, lastActivity: base,
            createdAt: base
        )
        session.timeline = (0 ..< 40).map { TimelineEvent(at: base, text: "event \($0)") }
        return session
    }

    static let github = GitHubState(pulls: (0 ..< 2000).map { number in
        PullRequest(
            ref: PullRef(repo: repo, number: number), title: "pull \(number)", url: "", state: .open,
            isDraft: false, headBranch: "b", review: nil, checks: CheckSummary(), unresolvedThreads: 0,
            updatedAt: base
        )
    })

    @Test func aListOf200SessionsBySize() {
        let (median, slowest) = Bench.time(runs: 20) {
            _ = SessionList(
                Self.sessions, view: SessionsView(sort: .size), size: { $0.trackedPRs.count * 10 },
                closable: { Int($0.id.dropFirst())! % 5 == 0 }
            )
        }
        print(
            "sidebar list, 200 sessions by size: median \(Int(median * 1_000_000)) µs, slowest \(Int(slowest * 1_000_000)) µs"
        )
    }

    @Test func eachTrackedPullAmong2000() {
        let refs = Self.sessions.flatMap(\.trackedPRs)
        let (median, slowest) = Bench.time(runs: 20) {
            for ref in refs {
                _ = Self.github.pull(ref)
            }
        }
        print(
            "600 PR lookups among 2,000: median \(Int(median * 1_000_000)) µs, slowest \(Int(slowest * 1_000_000)) µs"
        )
    }
}
