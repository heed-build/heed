import Foundation
@testable import HeedCore
import Testing

struct CallLogTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-calls-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func log() throws -> CallLog {
        try CallLog(store: CallStore(path: folder().appendingPathComponent("log.sqlite").path), delay: .seconds(60))
    }

    private func rows(_ log: CallLog, _ filter: CallFilter = CallFilter()) async throws -> [LoggedCall] {
        await log.flush()
        return try await log.store.calls(filter)
    }

    // MARK: Shell

    @Test func aFailedCommandKeepsItsOutput() async throws {
        let log = try log()
        let result = try await CallLog.$current.withValue(log) {
            try await ProcessRunner.run(
                "/bin/sh", ["-c", "echo out; echo err >&2; exit 3"], in: "/tmp", caller: "test.fail"
            )
        }
        #expect(result.status == 3)
        let calls = try await rows(log)
        #expect(calls.count == 1)
        let call = try #require(calls.first)
        #expect(call.kind == .shell && call.caller == "test.fail" && call.cwd == "/tmp" && call.host == nil)
        #expect(call.command == "/bin/sh -c 'echo out; echo err >&2; exit 3'")
        #expect(call.exitCode == 3 && call.failed)
        #expect(call.stdout == "out\n" && call.stderr == "err\n")
    }

    @Test func aCommandThatWorkedKeepsOnlyItsStderr() async throws {
        let log = try log()
        _ = try await CallLog.$current.withValue(log) {
            try await ProcessRunner.output("/bin/sh", ["-c", "echo out; echo note >&2"], caller: "test.ok")
        }
        let call = try #require(try await rows(log).first)
        #expect(!call.failed && call.exitCode == 0)
        #expect(call.stdout == nil && call.stderr == "note\n")
    }

    @Test func aCommandThatNeverStartedIsLoggedAsFailed() async throws {
        let log = try log()
        await CallLog.$current.withValue(log) {
            _ = try? await ProcessRunner.run("no-such-tool-heed-test", [], caller: "test.missing")
        }
        let call = try #require(try await rows(log).first)
        #expect(call.failed && call.exitCode == nil)
        #expect(call.stderr?.contains("not found") == true)
    }

    @Test func theEnvironmentIsNeverLogged() async throws {
        let log = try log()
        await CallLog.$current.withValue(log) {
            _ = try? await ProcessRunner.run(
                "/bin/sh", ["-c", "exit 1"], environment: ["HEED_TEST_SECRET": "hunter2"], caller: "test.env"
            )
        }
        let call = try #require(try await rows(log).first)
        #expect(!"\(call)".contains("hunter2"))
        #expect(!"\(call)".contains("HEED_TEST_SECRET"))
    }

    @Test func outputThatPrintsATokenIsNeverKept() {
        let failed = ProcessResult(status: 1, stdout: "gho_abc123", stderr: "gho_abc123")
        let call = LoggedCall.shell(
            at: .now, caller: "x", executable: "/opt/homebrew/bin/gh", arguments: ["auth", "token"], duration: 0,
            result: failed
        )
        #expect(call.stdout == nil && call.stderr == nil)
        // Other gh commands keep theirs.
        let other = LoggedCall.shell(
            at: .now, caller: "x", executable: "gh", arguments: ["api", "user"], duration: 0, result: failed
        )
        #expect(other.stdout == "gho_abc123")
    }

    /// heed never asks gh for its token: it runs gh and lets gh authenticate.
    @Test func heedNeverRunsGhAuthToken() throws {
        let sources = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources")
        let files = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
        var checked = 0
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            checked += 1
            #expect(!text.contains(#""auth", "token""#), "\(file.lastPathComponent)")
        }
        #expect(checked > 50)
    }

    @Test func longOutputIsCutInTheMiddle() {
        let text = String(repeating: "a", count: 20000) + "THE END"
        let cut = try? #require(LoggedCall.truncated(text))
        #expect((cut?.utf8.count ?? 0) < LoggedCall.outputLimit + 100)
        #expect(cut?.hasPrefix("aaa") == true && cut?.hasSuffix("THE END") == true && cut?
            .contains("bytes cut") == true)
        #expect(LoggedCall.truncated("") == nil)
    }

    @Test func aHostCallIsLoggedAsTheCommandOnTheHost() async throws {
        let log = try log()
        _ = try await CallLog.$current.withValue(log) {
            try await ProcessRunner.logged(
                caller: "git.status", host: "devbox", executable: "git", arguments: ["-C", "~/code/api", "status"]
            ) { ProcessResult(status: 0, stdout: "", stderr: "") }
        }
        let call = try #require(try await rows(log).first)
        #expect(call.host == "devbox" && call.command == "git -C '~/code/api' status")
    }

    @Test func callsAreWrittenInBatches() async throws {
        let log = try log()
        log.record(LoggedCall(at: .now, kind: .shell, caller: "x", command: "true", duration: 0))
        #expect(try await log.store.calls().isEmpty)
        await log.flush()
        #expect(try await log.store.calls().count == 1)
    }

    // MARK: GitHub

    /// A gh stand-in: notes its arguments, answers GraphQL with two search nodes and a rate limit, REST with a list.
    private func fakeGh(in dir: URL, exit: Int = 0) throws -> (path: String, args: URL) {
        let args = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" > '\(args.path)'
        case "$*" in
          *graphql*) echo '{"data":{"rateLimit":{"cost":1,"remaining":4987},"search":{"nodes":[{},{}]}}}' ;;
          *) echo '[{"id":"1"},{"id":"2"},{"id":"3"}]' ;;
        esac
        exit \(exit)
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, args)
    }

    @Test func aGitHubCallIsOneGitHubRowAndNoShellRow() async throws {
        let dir = try folder()
        let gh = try fakeGh(in: dir)
        let log = try log()
        _ = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(gh.path) {
                try await GitHub.graphql(
                    GitHub.pullSearchQuery, operation: "pullSearch", variables: ["q": "is:pr author:@me"],
                    caller: "github.sync"
                )
            }
        }
        let calls = try await rows(log)
        #expect(calls.map(\.kind) == [.github])
        let call = try #require(calls.first)
        #expect(call.caller == "github.sync" && call.operation == "graphql pullSearch" && !call.write)
        #expect(call.items == 2 && call.rateCost == 1 && call.rateRemaining == 4987 && call.hidden == 0)
        #expect(call.detail == ["q": "is:pr author:@me"])
        // The log keeps the operation's name, not the query's text.
        #expect(call.command == "gh api graphql -f query=@pullSearch -f 'q=is:pr author:@me'")
        // The query sent asks for the rate limit.
        let sent = try String(contentsOf: gh.args, encoding: .utf8)
        #expect(sent.contains("query=query($q: String!) { rateLimit { cost remaining } search("))
    }

    @Test func gitHubReadsAndWritesAreTold() async throws {
        let dir = try folder()
        let gh = try fakeGh(in: dir)
        let log = try log()
        try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(gh.path) {
                _ = try await GitHub.notifications(caller: "github.sync")
                try await GitHub.markRead(threadID: "42", caller: "inbox.markRead")
                try await GitHub.comment(
                    PullRef(repo: Repo(org: "acme", name: "api"), number: 7), body: "hi", caller: "copilot.ask"
                )
            }
        }
        let calls = try await rows(log)
        #expect(calls.count == 3 && calls.allSatisfy { $0.kind == .github })
        let byOperation = Dictionary(calls.map { ($0.operation ?? "", $0) }) { first, _ in first }
        #expect(byOperation["GET notifications"]?.items == 3)
        #expect(byOperation["GET notifications"]?.write == false)
        #expect(byOperation["PATCH notifications/threads"]?.write == true)
        #expect(byOperation["pr comment"]?.write == true)
        #expect(try await rows(log, { var filter = CallFilter(); filter.githubWritesOnly = true; return filter }())
            .count == 2)
    }

    @Test func aFailedGitHubCallKeepsItsOutput() async throws {
        let dir = try folder()
        let gh = try fakeGh(in: dir, exit: 1)
        let log = try log()
        await CallLog.$current.withValue(log) {
            await GitHub.$executable.withValue(gh.path) {
                _ = try? await GitHub.viewer(caller: "firstRun.check")
            }
        }
        let call = try #require(try await rows(log).first)
        #expect(call.failed && call.exitCode == 1 && call.stdout?.contains("\"id\"") == true)
    }

    /// gh exits 1 when an answer carries errors (SAML-withheld items) alongside its data: that call answered.
    @Test func aGraphQLAnswerWithErrorsIsNotAFailure() async throws {
        let dir = try folder()
        let gh = try fakeGh(in: dir, exit: 1)
        let log = try log()
        _ = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(gh.path) {
                try await GitHub.graphql(GitHub.pullSearchQuery, operation: "pullSearch", variables: [:], caller: "x")
            }
        }
        let call = try #require(try await rows(log).first)
        #expect(!call.failed && call.exitCode == 1 && call.stdout == nil && call.items == 2)
    }

    @Test func theRateLimitGoesInTheTopLevelSelection() {
        #expect(GitHub
            .withRateLimit("query { p0: repository { x } }") ==
            "query { rateLimit { cost remaining } p0: repository { x } }")
        #expect(GitHub.withRateLimit(GitHub.pullDetailQuery).contains("{ rateLimit { cost remaining } repository("))
    }

    // MARK: Retention

    private func call(_ kind: CallKind, daysAgo: Double, write: Bool = false, now: Date) -> LoggedCall {
        LoggedCall(
            at: now.addingTimeInterval(-daysAgo * 86400), kind: kind, caller: "c", command: "\(kind) \(daysAgo)",
            duration: 0.1, write: write
        )
    }

    @Test func eachKindIsKeptForItsOwnDays() async throws {
        let store = try CallStore(path: folder().appendingPathComponent("log.sqlite").path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.insert([
            call(.shell, daysAgo: 6, now: now), call(.shell, daysAgo: 8, now: now),
            call(.github, daysAgo: 2, now: now), call(.github, daysAgo: 4, now: now),
            call(.github, daysAgo: 80, write: true, now: now), call(.github, daysAgo: 100, write: true, now: now),
            call(.llm, daysAgo: 29, now: now), call(.llm, daysAgo: 31, now: now),
            call(.decide, daysAgo: 29, now: now), call(.decide, daysAgo: 31, now: now),
        ])
        let removed = await store.prune(now: now, retention: CallRetention())
        #expect(removed == 5)
        let kept = try await store.calls().map(\.command).sorted()
        #expect(kept == ["decide 29.0", "github 2.0", "github 80.0", "llm 29.0", "shell 6.0"])
    }

    @Test func eachKindKeepsAtMostItsNewestRows() async throws {
        let store = try CallStore(path: folder().appendingPathComponent("log.sqlite").path)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        await store.insert((0 ..< 10).map { call(.shell, daysAgo: Double($0) / 100, now: now) }
            + (0 ..< 3).map { call(.github, daysAgo: Double($0) / 100, now: now) })
        var retention = CallRetention()
        retention.maxRows = 4
        await store.prune(now: now, retention: retention)
        #expect(try await store.counts() == [.shell: 4, .github: 3])
        #expect(try await store.calls().filter { $0.kind == .shell }.map(\.command)
            == ["shell 0.0", "shell 0.01", "shell 0.02", "shell 0.03"])
    }

    // MARK: Reading

    @Test func theViewsFiltersNarrowTheRows() async throws {
        let store = try CallStore(path: folder().appendingPathComponent("log.sqlite").path)
        let now = Date()
        await store.insert([
            LoggedCall(at: now, kind: .shell, caller: "git.status", command: "git status", duration: 0.05),
            LoggedCall(
                at: now, kind: .shell, caller: "git.fetch", command: "git fetch", duration: 9, exitCode: 128,
                failed: true, stderr: "could not read 100% of it"
            ),
            LoggedCall(
                at: now, kind: .llm, caller: "summary.ledger", command: "claude -p", duration: 3, agent: "claude",
                tokens: TokenCounts(input: 1200, output: 80), cost: 0.004, costEstimated: true
            ),
        ])
        func filtered(_ change: (inout CallFilter) -> Void) async throws -> [String] {
            var filter = CallFilter()
            change(&filter)
            return try await store.calls(filter).map(\.command)
        }
        #expect(try await filtered { $0.kinds = [.llm] } == ["claude -p"])
        #expect(try await filtered { $0.caller = "git.status" } == ["git status"])
        #expect(try await filtered { $0.agent = "claude" } == ["claude -p"])
        #expect(try await filtered { $0.failedOnly = true } == ["git fetch"])
        #expect(try await filtered { $0.slowOnly = true } == ["git fetch"])
        #expect(try await filtered { $0.search = "100%" } == ["git fetch"])
        #expect(try await filtered { $0.search = "%" } == ["git fetch"])
        let llm = try #require(try await store.calls({ var f = CallFilter(); f.kinds = [.llm]; return f }()).first)
        #expect(llm.tokens == TokenCounts(input: 1200, output: 80) && llm.cost == 0.004 && llm.costEstimated)
    }

    @Test func retentionIsReadFromConfig() {
        let config = ConfigLoader.decode("""
        [log]
        shell_days = 2
        github_write_days = 365
        max_rows = 2000
        """).config
        #expect(config?.log.shellDays == 2 && config?.log.githubWriteDays == 365 && config?.log.maxRows == 2000)
        #expect(config?.log.githubReadDays == 3)
        #expect(HeedConfig.default.log == CallRetention())
    }
}

struct CallLogViewTests {
    @Test func theKindCyclesThroughAllThenEach() {
        var query = CallLogQuery()
        var seen: [CallKind?] = []
        for _ in 0 ..< 5 {
            query.cycleKind()
            seen.append(query.kind)
        }
        #expect(seen == [.shell, .github, .llm, .decide, nil])
        query.cycleKind(to: .github)
        #expect(query.kind == .github)
        query.cycleKind(to: .github)
        #expect(query.kind == nil)
    }

    @Test func callerAndAgentToggle() {
        var query = CallLogQuery()
        query.toggleCaller("git.status")
        #expect(query.caller == "git.status")
        query.toggleCaller("git.status")
        #expect(query.caller == nil)
        query.toggleAgent("claude")
        query.toggleAgent(nil)
        #expect(query.agent == nil && query.isEmpty)
    }

    /// Fixtures and shots filter in memory, the app in SQL: both must say the same of every call.
    @Test func filteringInMemoryAgreesWithTheStore() async throws {
        let store = try CallStore(path: ":memory:")
        let calls = Fixtures.calls
        await store.insert(calls.reversed())
        var queries: [CallLogQuery] = [CallLogQuery()]
        for kind in CallKind.all {
            var query = CallLogQuery()
            query.kind = kind
            queries.append(query)
        }
        let edits: [(inout CallLogQuery) -> Void] = [
            { $0.failedOnly = true }, { $0.slowOnly = true }, { $0.githubWritesOnly = true },
            { $0.caller = "github.sync" }, { $0.agent = "claude" },
        ]
        for edit in edits {
            var query = CallLogQuery()
            edit(&query)
            queries.append(query)
        }
        for query in queries {
            for search in ["", "GIT", "devbox", "resolve host", "%"] {
                let filter = query.filter(search: search)
                let stored = try await store.calls(filter).map(\.command)
                let inMemory = calls.filter(filter.matches).map(\.command)
                #expect(stored == inMemory, "\(query) /\(search)")
            }
        }
        #expect(try await store.calls(CallLogQuery().filter(search: "")).count == calls.count)
    }

    @Test func todaysUsageIsPerAgentWithEstimatesMarked() async throws {
        let calls = Fixtures.calls
        let hourAgo = Clock.now.addingTimeInterval(-3600)
        let usage = CallUsage(rows: calls, since: hourAgo)
        #expect(usage.agents.map(\.name) == ["claude", "codex"])
        #expect(usage.agents[0].calls == 1 && usage.agents[0].estimated && usage.agents[0].cost == 0.0052)
        #expect(!usage.agents[1].estimated)
        // The newest rate limit seen.
        #expect(usage.rateRemaining == 4812)
        #expect(CallUsage.money(0.0052, estimated: true) == "≈$0.005")
        #expect(CallUsage.money(1.5, estimated: false) == "$1.50")

        let store = try CallStore(path: ":memory:")
        await store.insert(calls)
        #expect(try await store.usage(since: hourAgo) == usage)
        #expect(try await store.usage(since: Clock.now).agents.isEmpty)
    }

    @Test func aCallsMenuCopiesAndNarrows() {
        let menu = ContextMenus.call(
            id: 7, title: "graphql pullSearch", caller: "github.sync", agent: nil, callerFiltered: false,
            agentFiltered: false
        )
        let items = menu.compactMap { entry -> MenuItem? in
            if case let .item(item) = entry { return item }
            return nil
        }
        #expect(items.map(\.command.name) == ["log.copy", "log.caller"])
        #expect(items.allSatisfy { $0.command.target == .row(view: "log", id: "7") })
        #expect(items[1].title == "Only github.sync")
        let narrowed = ContextMenus.call(
            id: 7, title: "x", caller: "c", agent: "claude", callerFiltered: true, agentFiltered: false
        )
        #expect(narrowed.count == 4)
    }

    @Test func theLogIsReachedByName() {
        #expect(CommandAliases.resolve("log") == CommandInvocation(name: "view", arguments: ["log"]))
        #expect(CommandCompletions.candidates("log.kind g").map(\.label) == ["github"])
        #expect(DefaultKeys.normal.allSatisfy { $0.1 != "view.log" })
    }
}
