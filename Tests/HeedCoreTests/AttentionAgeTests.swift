import Foundation
@testable import HeedCore
import Testing

struct AttentionAgeTests {
    /// 2033-05-18T03:33:20Z.
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func ago(days: Double) -> Date { now.addingTimeInterval(-days * 86400) }

    private func pull(_ number: Int, days: Double) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: docs, number: number), title: "PR \(number)",
            url: "https://github.com/acme/docs/pull/\(number)", state: .open, isDraft: false, headBranch: "b\(number)",
            review: nil, checks: CheckSummary(passed: 1, failed: 0), unresolvedThreads: 0, updatedAt: ago(days: days)
        )
    }

    private func issue(_ number: Int, days: Double) -> HeedCore.Issue {
        HeedCore.Issue(
            repo: docs, number: number, title: "Issue \(number)", url: "https://github.com/acme/docs/issues/\(number)",
            body: "", labels: [], author: "maria", updatedAt: ago(days: days), createdAt: ago(days: days + 1),
            assigned: true
        )
    }

    // MARK: Queries

    @Test func theSearchesCarryTheCutOffDay() {
        // 60 days before 2033-05-18 is 2033-03-19.
        #expect(AttentionAge.qualifier(days: 60, now: now) == "updated:>=2033-03-19")
        // Your own open PRs are never capped at GitHub: sessions, goals and the pilot need them however old.
        #expect(GitHub.pullSearchText(maxAgeDays: 60, now: now) == "is:open is:pr author:@me archived:false")
        #expect(GitHub.issueSearchBase(maxAgeDays: 60, now: now)
            == "is:open is:issue archived:false updated:>=2033-03-19")
        #expect(AttentionAge.qualifier(days: 1, now: now) == "updated:>=2033-05-17")
        #expect(AttentionAge.qualifier(days: 90, now: now) == "updated:>=2033-02-17")
    }

    @Test func theDayIsUTC() {
        // 00:30 UTC on the 18th, whatever the machine's zone: 2033-05-18T00:30:00Z.
        let early = Date(timeIntervalSince1970: 2_000_000_000 - 3 * 3600 - 3 * 60 - 20 + 1800)
        #expect(AttentionAge.qualifier(days: 0, now: early) == nil)
        #expect(AttentionAge.qualifier(days: 1, now: early) == "updated:>=2033-05-17")
    }

    @Test func noCapMeansNoQualifier() {
        #expect(AttentionAge.qualifier(days: 0, now: now) == nil && AttentionAge.since(days: 0, now: now) == nil)
        #expect(GitHub.pullSearchText(maxAgeDays: 0, now: now) == "is:open is:pr author:@me archived:false")
        #expect(GitHub.issueSearchBase(maxAgeDays: 0, now: now) == "is:open is:issue archived:false")
        #expect(GitHub.notificationsPath(unreadSince: nil) == "notifications?per_page=50")
    }

    @Test func theUnreadNotificationsPassSince() {
        let since = AttentionAge.since(days: 60, now: now)
        #expect(since == "2033-03-19T03:33:20Z")
        #expect(GitHub.notificationsPath(unreadSince: since)
            == "notifications?since=2033-03-19T03:33:20Z&per_page=50")
    }

    // MARK: The feed

    @Test func oldGitHubItemsLeaveAndRecentOnesStay() {
        let github = GitHubState(
            issues: [issue(7, days: 59), issue(8, days: 61)],
            pulls: [pull(1, days: 3), pull(2, days: 90)]
        )
        let items = AttentionFeed.items(github: github, sessions: [], maxAgeDays: 60, now: now)
        #expect(Set(items.map(\.id)) == ["acme/docs#1", "acme/docs#7"])
    }

    @Test func zeroShowsEverything() {
        let github = GitHubState(issues: [issue(8, days: 900)], pulls: [pull(2, days: 900)])
        let items = AttentionFeed.items(github: github, sessions: [], maxAgeDays: 0, now: now)
        #expect(Set(items.map(\.id)) == ["acme/docs#2", "acme/docs#8"])
    }

    @Test func oldNotificationsLeaveToo() {
        let note = InboxItem(
            id: "n1", kind: .ci, repo: docs, number: nil, title: "Build failed for main branch", reason: "ci_activity",
            unread: true, updatedAt: ago(days: 70), url: nil
        )
        #expect(AttentionFeed.items(github: GitHubState(inbox: [note]), sessions: [], maxAgeDays: 60, now: now).isEmpty)
        #expect(AttentionFeed.items(github: GitHubState(inbox: [note]), sessions: [], maxAgeDays: 0, now: now)
            .count == 1)
    }

    @Test func whatYouAreInStaysHoweverOld() {
        let tracked = PullRef(repo: docs, number: 2)
        var session = Session(
            id: "s1", title: "Work", repos: [docs], branch: "b", agent: "claude", state: ObservedState(.working),
            trackedPRs: [tracked]
        )
        session.issues = [IssueRef(repo: docs, number: 8)]
        let github = GitHubState(
            issues: [issue(8, days: 200), issue(9, days: 200), issue(10, days: 200)],
            pulls: [pull(2, days: 200), pull(3, days: 200), pull(4, days: 200), pull(5, days: 200)]
        )
        let exempt = AttentionAge.exempt(
            sessions: [session], goalPulls: ["acme/docs#3"], goalIssues: ["Acme/Docs#9"],
            watched: [PullRef(repo: docs, number: 4)]
        )
        let items = AttentionFeed.items(github: github, sessions: [session], maxAgeDays: 60, exempt: exempt, now: now)
        // Session's PR and issue, goal's PR and issue, watched PR: all stay. PR 5 and issue 10 are nobody's.
        #expect(Set(items.map { $0.id }) == ["acme/docs#2", "acme/docs#3", "acme/docs#4", "acme/docs#8", "acme/docs#9"])
    }

    @Test func aSessionKeepsItsThreadEvenWithoutTheExemptSet() {
        let session = Session(
            id: "s1", title: "Work", repos: [docs], branch: "b", agent: "claude", state: ObservedState(.working),
            trackedPRs: [PullRef(repo: docs, number: 2)]
        )
        let items = AttentionFeed.items(
            github: GitHubState(pulls: [pull(2, days: 200), pull(3, days: 200)]), sessions: [session],
            maxAgeDays: 60, now: now
        )
        #expect(items.map(\.id) == ["acme/docs#2"])
    }

    @Test func agentsAndGoalsAreNotGitHubs() {
        let agent = AttentionItem(
            id: "agent:s1", kind: .agent, repo: nil, number: nil, title: "t", url: nil, reasons: [.agentAsking],
            updatedAt: ago(days: 400)
        )
        let kept = AttentionAge.apply(to: [agent], days: 60, now: now)
        #expect(kept.count == 1)
    }

    // MARK: Config

    @Test func theDefaultIsSixtyDays() {
        #expect(HeedConfig.default.attention.maxAgeDays == 60)
        let (config, problems) = ConfigLoader.decode(ConfigLoader.defaultSource)
        #expect(problems.isEmpty && config?.attention.maxAgeDays == 60)
    }

    @Test func theKeyParses() {
        let (config, problems) = ConfigLoader.decode("[attention]\nmax_age_days = 14\n")
        #expect(problems.isEmpty && config?.attention.maxAgeDays == 14)
        #expect(ConfigLoader.decode("[attention]\nmax_age_days = 0\n").0?.attention.maxAgeDays == 0)
    }

    @Test func aNegativeOrNonNumberIsAProblem() {
        for text in ["-1", "\"sixty\"", "2.5"] {
            let (config, problems) = ConfigLoader.decode("[attention]\nmax_age_days = \(text)\n")
            #expect(problems.map(\.path) == ["attention.max_age_days"], "\(text)")
            #expect(config?.attention.maxAgeDays == 60)
        }
    }

    @Test func settingsListsItAsAdvanced() {
        let entry = SettingsCatalog.entry("attention.max_age_days")
        #expect(entry?.level == .advanced)
        #expect(entry?.page == .attention)
    }
}
