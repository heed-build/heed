import Foundation
@testable import HeedCore
import Testing

/// A gh that answers call N from `N.out`, `N.err` and `N.code` in its folder (a missing code is 0) and notes what each
/// call was asked in `N.args`, so a test says exactly what GitHub does, call by call.
private struct FakeGh {
    let dir: URL
    private var calls = 0

    init() throws {
        dir = try Scratch.folder("heed-browse-gh")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        d='\(dir.path)'
        n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
        echo $n > "$d/count"
        printf '%s\\n' "$@" > "$d/$n.args"
        if [ ! -f "$d/$n.out" ] && [ ! -f "$d/$n.err" ]; then echo "no answer scripted for call $n" >&2; exit 99; fi
        cat "$d/$n.out" 2>/dev/null
        [ -f "$d/$n.err" ] && cat "$d/$n.err" >&2
        exit $(cat "$d/$n.code" 2>/dev/null || echo 0)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    }

    var path: String { dir.appendingPathComponent("gh").path }

    private mutating func next() -> Int {
        calls += 1
        return calls
    }

    mutating func answer(_ out: String) throws {
        try out.write(to: dir.appendingPathComponent("\(next()).out"), atomically: true, encoding: .utf8)
    }

    mutating func fail(_ message: String, stdout: String = "", code: Int = 1) throws {
        let n = next()
        try message.write(to: dir.appendingPathComponent("\(n).err"), atomically: true, encoding: .utf8)
        try stdout.write(to: dir.appendingPathComponent("\(n).out"), atomically: true, encoding: .utf8)
        try String(code).write(to: dir.appendingPathComponent("\(n).code"), atomically: true, encoding: .utf8)
    }

    /// What call `n` (1-based) was asked: its page size, whether it was light, and its cursor.
    func asked(_ n: Int) throws -> (size: Int, light: Bool, after: String?) {
        // The query spans lines, so the checks are looked for in the whole of what was asked.
        let whole = try String(contentsOf: dir.appendingPathComponent("\(n).args"), encoding: .utf8)
        let args = whole.split(separator: "\n").map(String.init)
        let query = try #require(args.first { $0.hasPrefix("query=") })
        let size = try #require(query.range(of: #"first: (\d+), after"#, options: .regularExpression))
        let digits = try #require(query[size].range(of: #"\d+"#, options: .regularExpression))
        return (
            Int(query[size][digits])!, !whole.contains("statusCheckRollup"),
            args.first { $0.hasPrefix("after=") }.map { String($0.dropFirst(6)) }
        )
    }

    var callCount: Int { (try? String(contentsOf: dir.appendingPathComponent("count"), encoding: .utf8))
        .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
    }
}

/// Collects the waits a retry asked for, without waiting.
private actor Sleeps {
    var waits: [Duration] = []
    func note(_ wait: Duration) { waits.append(wait) }
}

@Suite(.scratch)
struct BrowseFetchPolicyTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let html = "<html><body><h1>502 Bad Gateway</h1></body></html>"
    private let gh502 = "gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)"

    private func query(_ org: String = "globex") -> BrowseQuery {
        BrowseQuery(scope: .org(org), tokens: [.state(.open)])
    }

    /// A page of `numbers` (newest first), with `total` as GitHub's count and `next` as the end cursor.
    private func page(_ numbers: [Int], total: Int, next: String? = nil, light: Bool = false) -> String {
        let nodes = numbers.map { n in
            let heavy = light ? "" : """
            ,"reviewRequests":{"nodes":[{"requestedReviewer":{"login":"ada"}}]},"closingIssuesReferences":{"totalCount":0},
            "commits":{"nodes":[{"commit":{"statusCheckRollup":{"state":"SUCCESS"}}}]}
            """
            return """
            {"number":\(n),"title":"t\(n)","url":"https://github.com/globex/api/pull/\(n)","state":"OPEN",
            "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-02-\(String(format: "%02d", 28 - n % 28))T00:00:00Z",
            "repository":{"nameWithOwner":"globex/api"},"author":{"login":"ada","__typename":"User"},
            "labels":{"nodes":[]},"assignees":{"nodes":[]},"comments":{"totalCount":0},
            "isDraft":false,"reviewDecision":null\(heavy)}
            """
        }.joined(separator: ",")
        let cursor = next.map { "\"\($0)\"" } ?? "null"
        return """
        {"data":{"rateLimit":{"cost":1,"remaining":4000},"search":{"issueCount":\(total),
        "pageInfo":{"hasNextPage":\(next != nil),"endCursor":\(cursor)},"nodes":[\(nodes)]}}}
        """
    }

    private func run(
        _ gh: FakeGh, query: BrowseQuery? = nil, cap: Int = 300, memory: BrowseFetchMemory = BrowseFetchMemory(),
        sleeps: Sleeps = Sleeps()
    ) async throws -> BrowseFetch.Result {
        try await GitHub.$executable.withValue(gh.path) {
            try await BrowseFetch.search(
                query ?? self.query(), maxAgeDays: 60, cap: cap, now: now, memory: memory,
                sleep: { await sleeps.note($0) }
            )
        }
    }

    private func message(_ gh: FakeGh, memory: BrowseFetchMemory = BrowseFetchMemory(), sleeps: Sleeps = Sleeps())
        async -> String?
    {
        do {
            _ = try await run(gh, memory: memory, sleeps: sleeps)
            return nil
        } catch {
            return (error as? GitHub.Failure)?.description ?? "\(error)"
        }
    }

    // MARK: A page that fails is asked again, smaller, from the same cursor

    @Test func aPageThatGets502IsAskedAgainSmallerAndNothingIsLostOrDoubled() async throws {
        var gh = try FakeGh()
        try gh.fail(gh502)
        try gh.answer(page(Array(1 ... 50), total: 60, next: "c50"))
        try gh.answer(page(Array(51 ... 60), total: 60))
        let sleeps = Sleeps()
        let result = try await run(gh, sleeps: sleeps)
        #expect(Set(result.items.map(\.number)) == Set(1 ... 60) && result.items.count == 60)
        #expect(result.total == 60 && !result.capped)
        #expect(await sleeps.waits == [.milliseconds(500)])
        let calls = try (1 ... gh.callCount).map { try gh.asked($0) }
        // The retry keeps the cursor (none: the first page); the next page continues from the end of the page that
        // answered, and does not climb back to 100.
        #expect(calls.map(\.size) == [100, 50, 50])
        #expect(calls.map(\.after) == [nil, nil, "c50"])
    }

    @Test func aLaterPageThatFailsIsAskedAgainFromItsOwnCursor() async throws {
        var gh = try FakeGh()
        try gh.answer(page(Array(1 ... 3), total: 6, next: "c3"))
        try gh.fail(gh502)
        try gh.answer(page(Array(4 ... 5), total: 6, next: "c5"))
        try gh.answer(page([6], total: 6))
        let result = try await run(gh)
        #expect(result.items.map(\.number).sorted() == Array(1 ... 6))
        let calls = try (1 ... gh.callCount).map { try gh.asked($0) }
        #expect(calls.map(\.after) == [nil, "c3", "c3", "c5"])
        #expect(calls.map(\.size) == [100, 100, 50, 50])
    }

    @Test func aDataNullAnswerIsATransientFailureToo() async throws {
        var gh = try FakeGh()
        let body = #"{"data":null,"errors":[{"message":"Something went wrong while executing your query."}]}"#
        try gh.fail("gh: Something went wrong while executing your query.", stdout: body)
        try gh.answer(page([1, 2], total: 2))
        let result = try await run(gh)
        #expect(result.items.count == 2 && gh.callCount == 2)
    }

    @Test func aTimeoutOfGhItselfIsAskedAgainSmaller() async throws {
        var gh = try FakeGh()
        try gh.fail("gh: Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout")
        try gh.answer(page([1], total: 1))
        let result = try await run(gh)
        let second = try gh.asked(2)
        #expect(result.items.count == 1 && second.size == 50)
    }

    @Test func aSearchThatKeepsFailingGivesUpWithAMessageAfterTheLadder() async throws {
        var gh = try FakeGh()
        for _ in 0 ..< 5 {
            try gh.fail(gh502)
        }
        // A sixth call would find no answer scripted and exit 99, which is not transient: the cap on retries is
        // what these five calls prove.
        let sleeps = Sleeps()
        let text = await message(gh, sleeps: sleeps)
        #expect(text ==
            "GitHub timed out running this search (HTTP 502). Narrow it: a repo, a label, or a shorter age, then try again.")
        #expect(gh.callCount == 5)
        #expect(await sleeps.waits == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(2)])
        let sizes = try (1 ... 5).map { try gh.asked($0).size }
        #expect(sizes == [100, 50, 25, 10, 10])
    }

    @Test func aGatewayPageOfHTMLNeverReachesThePerson() async throws {
        var gh = try FakeGh()
        for _ in 0 ..< 5 {
            try gh.fail("", stdout: html)
        }
        let text = try #require(await message(gh))
        #expect(text.hasPrefix("GitHub timed out running this search"))
        #expect(!text.contains("<") && !text.contains("{"))
    }

    // MARK: Permanent failures are not asked again

    @Test(arguments: [
        ("gh: To use GitHub CLI, run: gh auth login", "gh is not signed in (gh auth login)"),
        (
            "gh: HTTP 403: Resource protected by organization SAML enforcement",
            "gh: HTTP 403: Resource protected by organization SAML enforcement"
        ),
        ("gh: HTTP 401: Bad credentials", "gh: HTTP 401: Bad credentials"),
        (
            "gh: Could not resolve to an Organization with the login of 'nope'.",
            "gh: Could not resolve to an Organization with the login of 'nope'."
        ),
        (
            "gh: Field 'nope' doesn't exist on type 'PullRequest'",
            "gh: Field 'nope' doesn't exist on type 'PullRequest'"
        ),
    ])
    func aPermanentFailureIsNotRetried(_ failure: String, _ shown: String) async throws {
        var gh = try FakeGh()
        try gh.fail(failure)
        try gh.answer(page([1], total: 1))
        let sleeps = Sleeps()
        let text = await message(gh, sleeps: sleeps)
        #expect(text == shown)
        #expect(gh.callCount == 1)
        #expect(await sleeps.waits.isEmpty)
    }

    // MARK: Classification

    @Test(arguments: [
        ("gh: HTTP 502: Bad Gateway (https://api.github.com/graphql)", BrowseFetchPolicy.Kind.transient(code: 502)),
        ("HTTP 503: Service Unavailable", .transient(code: 503)),
        ("HTTP 504: Gateway Timeout", .transient(code: 504)),
        ("502 Bad Gateway", .transient(code: 502)),
        ("gh: Something went wrong while executing your query.", .transient(code: nil)),
        ("gh: timed out after 45 seconds", .transient(code: nil)),
        ("Post \"https://api.github.com/graphql\": net/http: TLS handshake timeout", .transient(code: nil)),
        ("Get \"https://api.github.com/graphql\": EOF", .transient(code: nil)),
        ("read tcp: connection reset by peer", .transient(code: nil)),
        ("GitHub did not answer (HTTP 502)", .transient(code: 502)),
        ("gh: To use GitHub CLI, run: gh auth login", .permanent),
        ("gh is not signed in (gh auth login)", .permanent),
        ("HTTP 401: Bad credentials", .permanent),
        ("HTTP 403: Resource protected by organization SAML enforcement", .permanent),
        ("Could not resolve to a Repository", .permanent),
        ("Field 'x' doesn't exist on type 'Issue'", .permanent),
        ("Parse error on \"}\" (RCURLY) at [1, 2]", .permanent),
        ("something else entirely", .permanent),
        ("", .permanent),
    ])
    func classification(_ text: String, _ kind: BrowseFetchPolicy.Kind) {
        #expect(BrowseFetchPolicy.classify(text) == kind)
    }

    @Test func theSecondaryRateLimitIsItsOwnKind() {
        let text = "You have exceeded a secondary rate limit. Please wait a few minutes before you try again."
        #expect(BrowseFetchPolicy.classify(text) == .rateLimited(wait: nil))
        #expect(BrowseFetchPolicy
            .classify("was submitted too quickly. retry-after: 7") == .rateLimited(wait: .seconds(7)))
    }

    @Test func theLadderIsOrderedAndEndsLight() {
        #expect(BrowseFetchPolicy.rungs.map(\.size) == [100, 50, 25, 10, 10])
        #expect(BrowseFetchPolicy.rungs.map(\.light) == [false, false, false, false, true])
        #expect((0 ..< 5).map(BrowseFetchPolicy.backoff(afterRung:))
            == [.milliseconds(500), .seconds(1), .seconds(2), .seconds(2), .seconds(2)])
    }

    // MARK: Remembered size

    @Test func theSizeASearchSettledOnIsKeptUntilTheScopeOrQueryChanges() async throws {
        let memory = BrowseFetchMemory()
        var first = try FakeGh()
        try first.fail(gh502)
        try first.fail(gh502)
        try first.answer(page([1], total: 1))
        _ = try await run(first, memory: memory)
        let sizefirst3 = try first.asked(3).size
        #expect(sizefirst3 == 25)

        // The same search again (a refresh) starts at 25, not 100.
        var again = try FakeGh()
        try again.answer(page([1], total: 1))
        _ = try await run(again, memory: memory)
        let sizeagain1 = try again.asked(1).size
        #expect(sizeagain1 == 25)

        // Another scope starts over.
        var other = try FakeGh()
        try other.answer(page([1], total: 1))
        _ = try await run(other, query: query("initech"), memory: memory)
        let sizeother1 = try other.asked(1).size
        #expect(sizeother1 == 100)
    }

    // MARK: Secondary rate limit

    @Test func aSecondaryRateLimitIsWaitedOutOnceUpToTheCap() async throws {
        var gh = try FakeGh()
        try gh.fail("You have exceeded a secondary rate limit. retry-after: 7")
        try gh.answer(page([1], total: 1))
        let sleeps = Sleeps()
        let result = try await run(gh, sleeps: sleeps)
        #expect(result.items.count == 1)
        #expect(await sleeps.waits == [.seconds(7)])
        // The same page at the same size: waiting is not a reason to ask for less.
        let sizegh2 = try gh.asked(2).size
        #expect(sizegh2 == 100)
    }

    @Test func aSecondaryRateLimitWithNoWaitSaidIsWaitedTenSeconds() async throws {
        var gh = try FakeGh()
        try gh.fail("was submitted too quickly")
        try gh.answer(page([1], total: 1))
        let sleeps = Sleeps()
        _ = try await run(gh, sleeps: sleeps)
        #expect(await sleeps.waits == [.seconds(10)])
    }

    @Test func aWaitPastTheCapOrASecondLimitFailsWithoutWaiting() async throws {
        var long = try FakeGh()
        try long.fail("secondary rate limit. retry-after: 90")
        let sleeps = Sleeps()
        let text = try #require(await message(long, sleeps: sleeps))
        let longWaits = await sleeps.waits
        #expect(text.contains("limiting how fast") && long.callCount == 1 && longWaits.isEmpty)

        var twice = try FakeGh()
        try twice.fail("secondary rate limit. retry-after: 5")
        try twice.fail("secondary rate limit. retry-after: 5")
        try twice.answer(page([1], total: 1))
        let again = Sleeps()
        let second = try #require(await message(twice, sleeps: again))
        let twiceWaits = await again.waits
        #expect(second.contains("limiting how fast") && twice.callCount == 2 && twiceWaits == [.seconds(5)])
    }

    // MARK: The light rung

    @Test func theLastRungAsksForNoChecksAndTheChecksShowAsUnknown() async throws {
        var gh = try FakeGh()
        for _ in 0 ..< 4 {
            try gh.fail(gh502)
        }
        try gh.answer(page([1, 2], total: 2, light: true))
        let result = try await run(gh)
        let last = try gh.asked(5)
        #expect(last.size == 10 && last.light)
        let fourth = try gh.asked(4)
        #expect(!fourth.light)
        #expect(result.items.count == 2)
        for item in result.items {
            #expect(item.kind == .pull && item.checks == nil && item.requestedReviewers == nil)
        }
    }

    @Test func aHeavyPageStillReadsChecksAndReviewers() async throws {
        var gh = try FakeGh()
        try gh.answer(page([1], total: 1))
        let item = try #require(await run(gh).items.first)
        #expect(item.checks == .passing && item.requestedReviewers == ["ada"])
    }

    // MARK: Pages and totals

    @Test func theTotalIsWhatGitHubSaysNotASumOverPages() async throws {
        var gh = try FakeGh()
        try gh.answer(page([1, 2], total: 4, next: "c2"))
        try gh.answer(page([3, 4], total: 4))
        let result = try await run(gh)
        #expect(result.total == 4 && result.items.count == 4 && !result.capped)
    }

    @Test func aCapStillStopsAndSaysCapped() async throws {
        var gh = try FakeGh()
        try gh.fail(gh502)
        try gh.answer(page([1, 2], total: 9, next: "c2"))
        try gh.answer(page([3, 4], total: 9, next: "c4"))
        let result = try await run(gh, cap: 3)
        #expect(result.items.count == 3 && result.capped && gh.callCount == 3)
    }

    // MARK: The other calls

    @Test func aCountIsAskedAgainAfterATransientFailureAndGivesUpAfterThree() async throws {
        var gh = try FakeGh()
        try gh.fail(gh502)
        try gh.answer(page([], total: 42))
        let sleeps = Sleeps()
        let total = try await GitHub.$executable.withValue(gh.path) {
            try await BrowseFetch.count(query(), maxAgeDays: 60, now: now, sleep: { await sleeps.note($0) })
        }
        #expect(total == 42 && gh.callCount == 2)

        var down = try FakeGh()
        for _ in 0 ..< 4 {
            try down.fail(gh502)
        }
        let waits = Sleeps()
        await #expect(throws: (any Error).self) {
            try await GitHub.$executable.withValue(down.path) {
                try await BrowseFetch.count(query(), maxAgeDays: 60, now: now, sleep: { await waits.note($0) })
            }
        }
        let downWaits = await waits.waits
        #expect(down.callCount == 4 && downWaits == [.milliseconds(500), .seconds(1), .seconds(2)])
    }

    @Test func aCountDoesNotRetryAPermanentFailure() async throws {
        var gh = try FakeGh()
        try gh.fail("gh: HTTP 401: Bad credentials")
        await #expect(throws: (any Error).self) {
            try await GitHub.$executable.withValue(gh.path) {
                try await BrowseFetch.count(query(), maxAgeDays: 60, now: now, sleep: { _ in })
            }
        }
        #expect(gh.callCount == 1)
    }

    @Test func theRepoCountAndTheOrgRepoListAreAskedAgain() async throws {
        var counts = try FakeGh()
        try counts.fail(gh502)
        try counts.answer(#"{"data":{"repositoryOwner":{"repositories":{"totalCount":812}}}}"#)
        let count = await GitHub.$executable.withValue(counts.path) {
            await BrowseFetch.repoCount(owner: "globex", sleep: { _ in })
        }
        #expect(count == 812)

        var repos = try FakeGh()
        try repos.fail(gh502)
        try repos.answer(#"[{"nameWithOwner":"globex/api","primaryLanguage":{"name":"Go"},"isArchived":false}]"#)
        let listed = await GitHub.$executable.withValue(repos.path) {
            await BrowseFetch.orgRepos(owner: "globex", sleep: { _ in })
        }
        #expect(listed?.map(\.slug) == ["globex/api"] && repos.callCount == 2)

        var gone = try FakeGh()
        try gone.fail("gh: HTTP 404: Not Found")
        let none = await GitHub.$executable.withValue(gone.path) {
            await BrowseFetch.orgRepos(owner: "globex", sleep: { _ in })
        }
        #expect(none == nil && gone.callCount == 1)
    }

    // MARK: What explain says

    @Test func explainNeverReturnsAGatewayPage() {
        let html = ProcessResult(status: 1, stdout: html, stderr: "")
        #expect(GitHub.explain(html) == "GitHub did not answer in time" || GitHub.explain(html)
            .hasPrefix("GitHub did not answer"))
        let gh = ProcessResult(status: 1, stdout: "", stderr: gh502)
        #expect(GitHub.explain(gh) == "GitHub did not answer (HTTP 502)")
        let json = ProcessResult(
            status: 1,
            stdout: #"{"message":"Something went wrong while executing your query."}"#,
            stderr: ""
        )
        #expect(!GitHub.explain(json).contains("{"))
    }
}
