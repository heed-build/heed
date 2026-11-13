import Foundation
@testable import HeedCore
import Testing

/// The Repos view's repo column as a filter, and what each repo's line says from what heed already has.
struct RepoBrowseTests {
    private let toolkit = Repo(org: "acme", name: "docs-toolkit")
    private let markgraph = Repo(org: "globex", name: "markgraph")
    private let scratch = Repo(org: "local", name: "scratch")

    private func worktree(_ repo: Repo, _ name: String) -> Worktree {
        Worktree(repo: repo, path: "/wt/\(repo.name)/\(name)", branch: name, head: "", isMain: false)
    }

    @Test func pickingARepoNarrowsTheTableAndAllShowsEveryRow() {
        let rows = [worktree(toolkit, "a"), worktree(toolkit, "b"), worktree(markgraph, "c")]
        #expect(RepoFilter.rows(rows, repo: nil) == rows)
        #expect(RepoFilter.rows(rows, repo: markgraph).map(\.branch) == ["c"])
        #expect(RepoFilter.rows(rows, repo: scratch).isEmpty)
    }

    @Test func theColumnMovesFromAllThroughTheReposAndStopsAtItsEnds() {
        let repos = [toolkit, markgraph]
        #expect(RepoFilter.index(of: nil, in: repos) == 0)
        #expect(RepoFilter.index(of: markgraph, in: repos) == 2)
        // A repo no longer listed is All.
        #expect(RepoFilter.index(of: scratch, in: repos) == 0)
        #expect(RepoFilter.moved(nil, by: 1, in: repos) == toolkit)
        #expect(RepoFilter.moved(toolkit, by: 1, in: repos) == markgraph)
        #expect(RepoFilter.moved(markgraph, by: 1, in: repos) == markgraph)
        #expect(RepoFilter.moved(toolkit, by: -1, in: repos) == nil)
        #expect(RepoFilter.moved(nil, by: -3, in: repos) == nil)
        // G and gg: the last and the first rows.
        #expect(RepoFilter.repo(at: .max, in: repos) == markgraph)
        #expect(RepoFilter.repo(at: 0, in: []) == nil)
    }

    @Test func allGroupsTheRowsByRepo() {
        let rows = [worktree(toolkit, "a"), worktree(toolkit, "b"), worktree(markgraph, "c")]
        let groups = RepoFilter.groups(rows)
        #expect(groups.map(\.index) == [0, 2])
        #expect(groups.map(\.repo) == [toolkit, markgraph])
    }

    private func main(_ status: WorktreeStatus?) -> Worktree {
        Worktree(repo: toolkit, path: "/r", branch: "main", head: "", isMain: true, status: status)
    }

    private let record = RepoRecord(repo: Repo(org: "acme", name: "docs-toolkit"), path: "/r", defaultBranch: "main")

    @Test func mainSaysHowItStandsAgainstOrigin() {
        let now = Date()
        let behind = RepoSummary.of(
            record, main: main(WorktreeStatus(behind: 3, upstream: "origin/main")), lastWorked: nil, hosts: [],
            setup: nil, now: now
        )
        #expect(behind.main?.text == "main ↓3")
        #expect(behind.mainLong == "main ↓3 behind origin · clean")
        let level = RepoSummary.of(
            record, main: main(WorktreeStatus(upstream: "origin/main")), lastWorked: nil, hosts: [], setup: nil,
            now: now
        )
        #expect(level.main == RepoSummary.Part("main ✓", .dim))
        #expect(level.mainLong == "main up to date with origin · clean")
        let dirty = RepoSummary.of(
            record, main: main(WorktreeStatus(changedFiles: 2, ahead: 1, upstream: "origin/main")), lastWorked: nil,
            hosts: [], setup: nil, now: now
        )
        #expect(dirty.main == RepoSummary.Part("main ↑1 *", .warning))
        #expect(dirty.mainLong == "main ↑1 ahead of origin · 2 files changed")
        // Before the first scan heed has nothing to say about main, and says nothing.
        let unread = RepoSummary.of(record, main: nil, lastWorked: nil, hosts: [], setup: nil, now: now)
        #expect(unread.main == nil)
        #expect(unread.line.isEmpty)
    }

    @Test func theLineSaysWhenHostsAndWhatSetupLacks() {
        let now = Date()
        let notSetUp = RepoSetupStatus(
            merging: .init(state: .notSetUp, text: "merging: not set up"),
            green: .init(state: .notSetUp, text: "green: not set up (ask)")
        )
        let summary = RepoSummary.of(
            record, main: main(WorktreeStatus(behind: 3, upstream: "origin/main")),
            lastWorked: now.addingTimeInterval(-60), hosts: ["devbox"], setup: notSetUp, now: now
        )
        #expect(summary.line == "main ↓3 · today · also @devbox · not set up")
        let mergingProblem = RepoSetupStatus(
            merging: .init(state: .warning, text: "merging: ⚠ auto needs GitHub's auto-merge"),
            green: .init(state: .notSetUp, text: "green: not set up (ask)")
        )
        #expect(RepoSummary.setupPart(mergingProblem) == RepoSummary.Part("merging ⚠", .warning))
        let greenOnly = RepoSetupStatus(
            merging: .init(state: .ok, text: "merging: ok · auto"),
            green: .init(state: .notSetUp, text: "green: not set up (ask)")
        )
        #expect(RepoSummary.setupPart(greenOnly) == RepoSummary.Part("green not set up", .dim))
        let done = RepoSetupStatus(
            merging: .init(state: .ok, text: "merging: ok · auto"), green: .init(state: .off, text: "green: off")
        )
        #expect(RepoSummary.setupPart(done) == nil)
        // A repo with no GitHub remote says so, and has no setup to lack.
        let local = RepoSummary.of(
            RepoRecord(repo: scratch, path: "/s"), main: nil, lastWorked: nil, hosts: [], setup: notSetUp, now: now
        )
        #expect(local.line == "no remote")
    }

    @Test func whenAndAgeReadShort() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        // A Friday at noon.
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 11, day: 13, hour: 12)))
        func ago(_ days: Double) -> Date { now.addingTimeInterval(-days * 86400) }
        #expect(RepoSummary.when(ago(0.1), now: now, calendar: calendar) == "today")
        #expect(RepoSummary.when(ago(1), now: now, calendar: calendar) == "yesterday")
        #expect(RepoSummary.when(ago(3), now: now, calendar: calendar) == "Tue")
        #expect(RepoSummary.when(ago(21), now: now, calendar: calendar) == "3 weeks")
        #expect(RepoSummary.when(ago(90), now: now, calendar: calendar) == "3 months")
        #expect(RepoSummary.when(ago(800), now: now, calendar: calendar) == "2 years")
        #expect(RepoSummary.age(now.addingTimeInterval(-5 * 60), now: now) == "5 m")
        #expect(RepoSummary.age(now.addingTimeInterval(-4 * 3600), now: now) == "4 h")
        #expect(RepoSummary.age(ago(2), now: now) == "2 d")
        #expect(RepoSummary.age(ago(35), now: now) == "5 w")
    }
}
