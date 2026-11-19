import Foundation
@testable import HeedCore
import Testing

/// Calls in Insights: the retry marker, the per-caller summary, the caller filter, the jump from a failure, and the
/// tab.
@Suite(.scratch)
struct CallInsightsTests {
    private func call(
        _ caller: String = "browse.search", took: TimeInterval = 1, failed: Bool = false, cost: Int? = nil,
        detail: [String: String] = [:], at seconds: Double = 0
    ) -> LoggedCall {
        LoggedCall(
            at: Date(timeIntervalSince1970: 1_000_000 - seconds), kind: .github, caller: caller, command: "gh",
            duration: took, failed: failed, rateCost: cost, detail: detail
        )
    }

    // MARK: The retry marker

    @Test func aRetryIsMarkedWithItsPageSizeAndAttempt() {
        let first = CallRetry(pageSize: 100)
        let retry = CallRetry(pageSize: 50, attempt: 1)
        let light = CallRetry(pageSize: 10, attempt: 4, light: true)
        #expect(first.chip == "100/page" && !first.isRetry)
        #expect(retry.chip == "retry · 50/page" && retry.isRetry)
        #expect(light.chip == "retry · 10/page · light")
        // What is written reads back from a row.
        for marker in [first, retry, light] {
            #expect(CallRetry(call(detail: marker.detail)) == marker)
        }
        // The first ask leaves no retry key.
        #expect(first.detail == ["heed.page": "100"])
    }

    @Test func aCallThatSaidNothingIsNotMarked() {
        #expect(CallRetry(call()) == nil)
        // A GraphQL variable called page (the notifications') is not a page size.
        #expect(CallRetry(call(detail: ["page": "2"])) == nil)
        #expect(CallRetry(call(detail: ["heed.page": "0"])) == nil)
        #expect(CallRetry(call(detail: ["heed.page": "many"])) == nil)
        // A damaged attempt reads as the first ask, never as a negative one.
        #expect(CallRetry(call(detail: ["heed.page": "50", "heed.retry": "-3"]))?.attempt == 0)
        #expect(CallRetry.keys == ["heed.page", "heed.retry", "heed.light"])
    }

    /// The rows written before the marker, and the ones after, share one table: nothing about the schema changed.
    @Test func oldRowsStillLoadAndMarkedRowsKeepTheirMarker() async throws {
        let file = try Scratch.folder("heed-calls-old").appendingPathComponent("log.sqlite").path
        let old = call("github.sync", detail: ["q": "is:pr"], at: 10)
        let marked = call(detail: ["q": "org:x"].merging(CallRetry(pageSize: 25, attempt: 2).detail) { $1 }, at: 0)
        do {
            let store = try CallStore(path: file)
            await store.insert([old])
        }
        // Opened again by a heed that knows the marker: the old row loads, then a marked one is added beside it.
        let store = try CallStore(path: file)
        await store.insert([marked])
        let rows = try await store.calls()
        #expect(rows.map(\.caller) == ["browse.search", "github.sync"])
        #expect(CallRetry(rows[0]) == CallRetry(pageSize: 25, attempt: 2))
        #expect(CallRetry(rows[1]) == nil && rows[1].detail == ["q": "is:pr"])
        #expect(rows[0].detail["q"] == "org:x")
        #expect(try await store.callers() == ["browse.search", "github.sync"])
    }

    /// A page that fails is asked again smaller, and the log says which ask each row was.
    @Test func browseRecordsEachAskOfAPage() async throws {
        let dir = try Scratch.folder("heed-calls-ladder")
        let script = dir.appendingPathComponent("gh")
        let answer = """
        {"data":{"rateLimit":{"cost":1,"remaining":4000},"search":{"issueCount":0,\
        "pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[]}}}
        """
        try """
        #!/bin/sh
        d='\(dir.path)'
        n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
        echo $n > "$d/count"
        if [ $n -le 2 ]; then echo 'gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)' >&2; exit 1; fi
        echo '\(answer)'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = try CallLog(
            store: CallStore(path: dir.appendingPathComponent("log.sqlite").path), delay: .seconds(60)
        )
        let checkouts = BrowseCheckouts(records: [RepoRecord(repo: Repo(org: "globex", name: "api"), path: "/x")])
        _ = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(script.path) {
                try await BrowseFetch.search(
                    BrowseQuery(scope: .org("globex"), tokens: [.state(.open)]), maxAgeDays: 60,
                    checkouts: checkouts, memory: BrowseFetchMemory(), sleep: { _ in }
                )
            }
        }
        await log.flush()
        let rows = try await log.store.calls().reversed()
        #expect(rows.map(\.failed) == [true, true, false])
        #expect(rows.compactMap { CallRetry($0) } == [
            CallRetry(pageSize: 100), CallRetry(pageSize: 50, attempt: 1), CallRetry(pageSize: 25, attempt: 2),
        ])
        // The variables the search was asked with are still there beside the marker.
        #expect(rows.allSatisfy { $0.detail["q"] != nil })
    }

    // MARK: The per-caller summary

    @Test func theSummaryCountsFailuresRetriesAndSpendPerCaller() throws {
        var rows: [LoggedCall] = []
        // Ten calls taking 1…10 s: nearest rank gives a median of 5 s and a p95 of 10 s.
        for second in 1 ... 10 {
            rows.append(call(took: Double(second), failed: second == 10, cost: 2, at: Double(second)))
        }
        rows.append(call(detail: CallRetry(pageSize: 50, attempt: 1).detail))
        rows.append(call("git.status", took: 0.04))
        rows.append(call("git.status", took: 0.06))
        let summaries = CallerSummary.of(rows)
        #expect(summaries.map(\.caller) == ["browse.search", "git.status"])
        let browse = summaries[0]
        #expect(browse.calls == 11 && browse.failures == 1 && browse.retries == 1)
        #expect(browse.rateCost == 20)
        // 1…10 plus a 1 s call: sorted 1,1,2,…,10 (11 values): rank ceil(5.5) = 6th is 5; ceil(10.45) = 11th is 10.
        #expect(browse.median == 5 && browse.p95 == 10)
        let git = summaries[1]
        #expect(git.calls == 2 && git.failures == 0 && git.rateCost == 0 && git.median == 0.04 && git.p95 == 0.06)
        #expect(CallerSummary.of([]).isEmpty)
    }

    @Test func theWorstCallerComesFirst() {
        let rows = [
            call("a", failed: false), call("a"), call("a"),
            call("b", failed: true),
            call("c", failed: true), call("c", failed: true),
            call("d"), call("d"), call("d"), call("d"),
        ]
        // Most failures first, then the busier, then by name.
        #expect(CallerSummary.of(rows).map(\.caller) == ["c", "b", "d", "a"])
        #expect(CallerSummary.of([call("z"), call("y")]).map(\.caller) == ["y", "z"])
    }

    @Test func percentilesAreNearestRank() {
        #expect(CallerSummary.percentile([], 0.5) == 0)
        #expect(CallerSummary.percentile([7], 0.95) == 7)
        #expect(CallerSummary.percentile([1, 2], 0.5) == 1)
        #expect(CallerSummary.percentile([1, 2, 3, 4], 0.5) == 2)
        #expect(CallerSummary.percentile((1 ... 20).map(Double.init), 0.95) == 19)
        #expect(CallerSummary.percentile((1 ... 20).map(Double.init), 1) == 20)
    }

    @Test func theFixturesHaveAFailingRetryLadder() throws {
        let rows = Fixtures.calls.filter { $0.caller == "browse.search" }
        #expect(rows.map(\.failed) == [false, true, true])
        #expect(rows.compactMap { CallRetry($0) }.map(\.chip) == ["retry · 25/page", "retry · 50/page", "100/page"])
        let summary = try #require(CallerSummary.of(Fixtures.calls).first)
        #expect(summary.caller == "browse.search" && summary.failures == 2 && summary.retries == 2)
    }

    // MARK: The caller filter and the jump from a failure

    @Test func callersCycleThroughAllThenEachInTurn() {
        var query = CallLogQuery()
        let known = ["git.status", "browse.search", "github.sync"]
        query.cycleCaller(among: known)
        #expect(query.caller == "browse.search")
        query.cycleCaller(among: known)
        #expect(query.caller == "git.status" || query.caller == "github.sync")
        query.cycleCaller(among: known)
        query.cycleCaller(among: known)
        #expect(query.caller == nil)
        // A name sets it, the same name again (or all) clears it; the other filters stay.
        query.failedOnly = true
        query.cycleCaller(among: known, named: "git.status")
        #expect(query.caller == "git.status" && query.failedOnly)
        query.cycleCaller(among: known, named: "git.status")
        #expect(query.caller == nil)
        query.cycleCaller(among: known, named: "github.sync")
        query.cycleCaller(among: known, named: "all")
        #expect(query.caller == nil)
        // A caller no longer known starts the cycle over.
        query.caller = "gone"
        query.cycleCaller(among: known)
        #expect(query.caller == "browse.search")
    }

    @Test func theCallerFilterNarrowsTheRowsTheSameInMemoryAndInTheStore() async throws {
        let store = try CallStore(path: ":memory:")
        let calls = Fixtures.calls
        await store.insert(calls.reversed())
        var query = CallLogQuery()
        query.cycleCaller(among: [], named: "browse.search")
        let filter = query.filter(search: "")
        let stored = try await store.calls(filter)
        #expect(stored.count == 3 && stored.map(\.id) != [])
        #expect(stored.map(\.command) == calls.filter(filter.matches).map(\.command))
    }

    @Test func seeingACallerOpensItsCallsOnTheNewestFailure() {
        let query = CallLogQuery.seeing(caller: "browse.search")
        #expect(query.caller == "browse.search" && !query.failedOnly && query.kind == nil)
        let rows = [call(failed: false), call(failed: true), call(failed: true)]
        #expect(CallLogSelection.newestFailed(in: rows) == 1)
        // Nothing failed: the newest call. Nothing at all: no row.
        #expect(CallLogSelection.newestFailed(in: [call(), call()]) == 0)
        #expect(CallLogSelection.newestFailed(in: []) == nil)
        let fixture = Fixtures.calls.filter(query.filter(search: "").matches)
        #expect(fixture[CallLogSelection.newestFailed(in: fixture) ?? -1].failed)
    }

    @Test func theCommandsAreNamedAndComplete() {
        for name in ["history.calls", "log.callers", "log.see", "view.log"] {
            #expect(Commands.spec(name) != nil, Comment(rawValue: name))
        }
        var context = CompletionContext()
        context.logCallers = ["git.status", "browse.search"]
        let callers = CommandCompletions.candidates("log.callers b", context).map(\.label)
        #expect(callers == ["browse.search"])
        #expect(CommandCompletions.candidates("log.see ", context).map(\.label).sorted()
            == ["browse.search", "git.status"])
        #expect(CommandAliases.resolve("log") == CommandInvocation(name: "view", arguments: ["log"]))
        #expect(DefaultKeys.scoped["log"]?.contains { $0 == ("p", "log.callers") } == true)
    }

    // MARK: Insights' tab

    @Test func theCallLogLightsInsightsTab() {
        #expect(HistoryPaneTabs.contains("log"))
        for pane in ["dashboard", "history", "ledger", "mindmap", "standup", "telemetry", "audit"] {
            #expect(HistoryPaneTabs.contains(pane), Comment(rawValue: pane))
        }
        // Not Insights'.
        for other in ["sessions", "attention", "trace", "goals", "autopilot", "browse", "watch"] {
            #expect(!HistoryPaneTabs.contains(other), Comment(rawValue: other))
        }
        let calls = HistoryPaneTabs.panes.first { $0.pane == "log" }
        #expect(calls?.command == "history.calls" && calls?.title == "Calls")
        // The old way in is still bound to nothing and still named.
        #expect(DefaultKeys.normal.allSatisfy { $0.1 != "view.log" })
    }
}
