import Foundation
@testable import HeedCore
import Testing

// MARK: Parsing

struct TeamMentionParsingTests {
    @Test func findsTeamMentionsLowercased() {
        let text = "Thoughts, @acme/Docs-Eng? cc @acme/docs-all and @someone.\n@acme/platform_core: please look"
        #expect(TeamMentions.parse(text) == ["acme/docs-eng", "acme/docs-all", "acme/platform_core"])
    }

    @Test func skipsCodeEmailsAndPaths() {
        let text = """
        Mail ops@acme/docs-eng, see https://x.dev/@acme/docs-all, or `@acme/inline`.
        ```
        @acme/fenced
        ```
        Real: (@acme/docs-search).
        """
        #expect(TeamMentions.parse(text) == ["acme/docs-search"])
    }

    @Test func mentionsNextToEachOtherAreAllFound() {
        #expect(TeamMentions.parse("@acme/a @acme/b,@acme/c") == ["acme/a", "acme/b", "acme/c"])
    }

    @Test func viewerTeamsFromTabSeparatedLines() {
        let teams = GitHub.parseViewerTeams("acme\tdocs-eng\t\nacme\tdocs-search\tdocs-eng\n\nbroken\n")
        #expect(teams == [
            GitHubTeam(org: "acme", slug: "docs-eng"),
            GitHubTeam(org: "acme", slug: "docs-search", parent: "docs-eng"),
        ])
    }

    @Test func effectiveTeamsWalkParents() {
        let teams = ViewerTeams(teams: [
            GitHubTeam(org: "acme", slug: "search", parent: "docs-eng"),
            GitHubTeam(org: "acme", slug: "docs-eng", parent: "eng"),
            GitHubTeam(org: "Globex", slug: "ops", parent: "everyone"),
            GitHubTeam(org: "globex", slug: "everyone"),
        ], fetchedAt: .now)
        #expect(teams.effective.map(\.id) == [
            "acme/docs-eng", "acme/eng", "acme/search", "globex/everyone", "globex/ops",
        ])
        #expect(teams.teams(in: "ACME").map(\.id) == ["acme/docs-eng", "acme/eng", "acme/search"])
        // A listed parent keeps what GitHub said about it.
        #expect(teams.effective.first { $0.id == "acme/docs-eng" }?.parent == "eng")
    }

    @Test func teamsAreStaleAfterADay() {
        let now = Date()
        #expect(ViewerTeams().isStale(now: now))
        #expect(!ViewerTeams(fetchedAt: now.addingTimeInterval(-3600)).isStale(now: now))
        #expect(ViewerTeams(fetchedAt: now.addingTimeInterval(-ViewerTeams.refreshInterval)).isStale(now: now))
        #expect(!ViewerTeams(fetchedAt: now, note: ViewerTeams.missingScopeNote).available)
    }

    @Test func oneAliasPerTeamScopedToTheRepo() {
        let teams = [GitHubTeam(org: "acme", slug: "docs-eng"), GitHubTeam(org: "acme", slug: "docs-all")]
        let query = GitHub.teamSearchQuery(count: 2)
        #expect(query.hasPrefix("query($q0: String!, $q1: String!) {"))
        #expect(query.contains("t0: search(type: ISSUE, first: 100, query: $q0)"))
        #expect(query.contains("t1: search(type: ISSUE, first: 100, query: $q1)"))
        #expect(GitHub.teamSearchVariables(repo: Repo(org: "acme", name: "docs"), teams: teams) == [
            "q0": "repo:acme/docs team:acme/docs-eng", "q1": "repo:acme/docs team:acme/docs-all",
        ])
    }

    @Test func aWithheldSearchNeitherConfirmsNorRulesOut() {
        let teams = [GitHubTeam(org: "acme", slug: "a"), GitHubTeam(org: "acme", slug: "b")]
        let json = """
        {"data":{"t0":{"issueCount":1,"nodes":[{"url":"https://github.com/Acme/Docs/pull/7"},{}]},"t1":null},
         "errors":[{"type":"FORBIDDEN","extensions":{"saml_failure":true}}]}
        """
        #expect(GitHub
            .parseTeamSearch(Data(json.utf8), teams: teams) == ["acme/a": ["https://github.com/acme/docs/pull/7"]])
    }

    @Test func bodiesAreCollectedFromEveryLevel() {
        let thread: [String: Any] = [
            "body": "top",
            "comments": ["nodes": [["body": "c1"], ["body": NSNull()]]],
            "reviews": ["nodes": [["body": "r1", "comments": ["nodes": [["body": "rc1"]]]]]],
        ]
        #expect(GitHub.bodies(in: thread) == ["top", "c1", "r1", "rc1"])
    }

    @Test func notificationsKeepTheSubjectAPIURL() {
        let json = """
        [{"id":"9","reason":"team_mention","unread":true,"updated_at":"2026-10-05T19:00:52Z",
          "subject":{"title":"Archive old docs","type":"Issue","url":"https://api.github.com/repos/acme/docs/issues/12"},
          "repository":{"full_name":"acme/docs"}}]
        """
        let item = try? #require(GitHub.parseNotifications(Data(json.utf8)).first)
        #expect(item?.subjectAPI == "https://api.github.com/repos/acme/docs/issues/12")
        #expect(item?.teams == [])
    }

    /// A cache written before attribution existed (no `subjectAPI`, `teams`, `teamMentions`) still loads.
    @Test func olderCachesStillDecode() throws {
        let json = """
        {"inbox":[{"id":"1","kind":"PR","repo":{"org":"acme","name":"docs"},"number":3,"title":"t","reason":"mention",
          "unread":true,"updatedAt":0,"url":"https://github.com/acme/docs/pull/3"}],
         "issues":[],"pulls":[],"status":{"ok":{}}}
        """
        let state = try JSONDecoder().decode(GitHubState.self, from: Data(json.utf8))
        #expect(state.inbox.first?.teams == [] && state.inbox.first?.subjectAPI == nil)
        #expect(state.teams == ViewerTeams() && state.teamMentions == TeamMentionCache())
        let again = try JSONDecoder().decode(GitHubState.self, from: JSONEncoder().encode(state))
        #expect(again == state)
    }
}

// MARK: Cache

struct TeamMentionCacheTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(_ id: String, reason: String = "team_mention") -> InboxItem {
        InboxItem(
            id: id, kind: .issue, repo: Repo(org: "acme", name: "docs"), number: 1, title: "t", reason: reason,
            unread: true, updatedAt: now, url: "https://github.com/acme/docs/issues/1"
        )
    }

    @Test func onlyTeamReasonsNeedWork() {
        let cache = TeamMentionCache()
        #expect(cache.needs(item("1")))
        #expect(cache.needs(item("1", reason: "review_requested")))
        #expect(!cache.needs(item("1", reason: "mention")))
        #expect(!cache.needs(item("1", reason: "subscribed")))
    }

    @Test func anAttributionHoldsUntilTheReasonChanges() {
        var cache = TeamMentionCache()
        cache.record(item("1"), teams: ["acme/docs-eng"], source: .search, now: now)
        #expect(!cache.needs(item("1")))
        #expect(cache.teams(for: item("1")) == ["acme/docs-eng"])
        // The same thread, now a review request: worked out again, and the old teams no longer apply.
        #expect(cache.needs(item("1", reason: "review_requested")))
        #expect(cache.teams(for: item("1", reason: "review_requested")) == [])
    }

    @Test func failuresAreRetriedThenSettledAsUnknown() {
        var cache = TeamMentionCache()
        for attempt in 1 ... TeamMentionCache.maxAttempts {
            #expect(cache.needs(item("1")), "attempt \(attempt)")
            cache.failed(item("1"), now: now)
        }
        #expect(!cache.needs(item("1")))
        #expect(cache.entries["1"]?.source == .unknown && cache.entries["1"]?.attempts == TeamMentionCache.maxAttempts)
        // A new reason starts counting again.
        cache.failed(item("1", reason: "review_requested"), now: now)
        #expect(cache.entries["1"]?.attempts == 1 && cache.needs(item("1", reason: "review_requested")))
    }

    @Test func unseenEntriesAreDroppedAfterThirtyDays() {
        var cache = TeamMentionCache()
        cache.record(item("old"), teams: [], source: .unknown, now: now)
        cache.record(item("kept"), teams: [], source: .unknown, now: now)
        let later = now.addingTimeInterval(TeamMentionCache.retention - 60)
        cache.seen([item("kept")], now: later)
        #expect(Set(cache.entries.keys) == ["old", "kept"])
        cache.seen([item("kept")], now: now.addingTimeInterval(TeamMentionCache.retention + 60))
        #expect(Set(cache.entries.keys) == ["kept"])
    }

    @Test func appliedFillsTeamsPerItem() {
        var cache = TeamMentionCache()
        cache.record(item("1"), teams: ["acme/docs-eng"], source: .text, now: now)
        let applied = cache.applied(to: [item("1"), item("2"), item("1", reason: "comment")])
        #expect(applied.map(\.teams) == [["acme/docs-eng"], [], []])
    }
}

// MARK: Attribution against a stand-in gh

/// A gh stand-in, answering from files in its folder: `teams` (or `teams-error`), `mentions` (`org/slug url`
/// lines: what each team search returns), `thread.json`, `reviewers`, `notifications`, and `max-batch` (a team
/// search with more aliases fails with HTTP 502).
private struct StandInGh {
    let dir: URL
    let path: String

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-teams-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gh")
        try #"""
        #!/bin/sh
        D='\#(dir.path)'
        case "$*" in
          *user/teams*)
            if [ -f "$D/teams-error" ]; then cat "$D/teams-error" >&2; exit 1; fi
            cat "$D/teams" ;;
          *requested_reviewers*)
            if [ -f "$D/reviewers" ]; then cat "$D/reviewers"; else echo 'HTTP 404' >&2; exit 1; fi ;;
          *issueCount*)
            n=0
            for a in "$@"; do case "$a" in q[0-9]*=*) n=$((n+1)) ;; esac; done
            if [ -f "$D/max-batch" ] && [ "$n" -gt "$(cat "$D/max-batch")" ]; then echo 'HTTP 502' >&2; exit 1; fi
            out='{"data":{"rateLimit":{"cost":1,"remaining":4000}'
            for a in "$@"; do
              case "$a" in
                q[0-9]*=*)
                  key="${a%%=*}"; team="${a##*team:}"; nodes=''
                  for u in $(awk -v t="$team" 'tolower($1)==tolower(t){print $2}' "$D/mentions" 2>/dev/null); do
                    nodes="$nodes${nodes:+,}{\"url\":\"$u\"}"
                  done
                  out="$out,\"t${key#q}\":{\"issueCount\":0,\"nodes\":[$nodes]}" ;;
              esac
            done
            echo "$out}}" ;;
          *issueOrPullRequest*)
            if [ -f "$D/thread.json" ]; then cat "$D/thread.json"; else echo 'HTTP 502' >&2; exit 1; fi ;;
          *notifications*) cat "$D/notifications" ;;
          *) echo "unexpected: $*" >&2; exit 1 ;;
        esac
        """#.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        path = script.path
    }

    func file(_ name: String, _ text: String) throws {
        try text.write(to: dir.appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func remove(_ name: String) throws {
        try FileManager.default.removeItem(at: dir.appendingPathComponent(name))
    }

    /// Runs `body` against this gh, returning its result and the GitHub call-log rows it made (operations, in order).
    func run<T: Sendable>(_ body: () async throws -> T) async throws -> (T, [LoggedCall]) {
        let log = try CallLog(
            store: CallStore(path: dir.appendingPathComponent("log-\(UUID().uuidString).sqlite").path),
            delay: .seconds(60)
        )
        let value = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(path) { try await body() }
        }
        await log.flush()
        let calls = try await log.store.calls(CallFilter()).sorted { $0.at < $1.at }
        return (value, calls)
    }
}

/// Serialized: each test spawns several stand-in gh processes, and a fork while another test is writing its own
/// stand-in script can leave that script busy (ETXTBSY) when it runs.
@Suite(.serialized) struct TeamAttributionTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")

    private func thread(
        _ id: String, _ number: Int, reason: String = "team_mention", kind: InboxItem.Kind = .issue, repo: Repo? = nil
    ) -> InboxItem {
        let repo = repo ?? docs
        let path = kind == .pr ? "pull" : "issues"
        return InboxItem(
            id: id, kind: kind, repo: repo, number: number, title: "Thread \(number)", reason: reason, unread: true,
            updatedAt: now, url: "https://github.com/\(repo.slug)/\(path)/\(number)"
        )
    }

    private let threeTeams = "acme\tdocs-eng\t\nacme\tdocs-all\t\nacme\tdocs-search\tdocs-eng\nglobex\tops\t\n"

    @Test func searchAttributesTheMentionedTeamAndCachesIt() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("mentions", "acme/docs-eng https://github.com/acme/docs/issues/12\n")
        let inbox = [thread("t1", 12), thread("t2", 13, reason: "subscribed")]

        let ((teams, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: inbox, teams: ViewerTeams(), cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(teams.available && teams.teams.count == 4)
        #expect(cache.teams(for: inbox[0]) == ["acme/docs-eng"])
        #expect(cache.entries["t1"]?.source == .search)
        #expect(cache.entries["t2"] == nil)
        // One call for your teams, one search for the three acme teams; globex is not searched.
        #expect(calls.map(\.operation) == ["GET user/teams", "graphql teamSearch"])
        #expect(calls.allSatisfy { $0.kind == .github && !$0.write && $0.caller == "github.sync" })
        #expect(calls.last?.detail["q0"] == "repo:acme/docs team:acme/docs-all")
        #expect(calls.last?.detail.count == 3)

        // Steady state: nothing new, no call; an update to the thread with the same reason, still none.
        var updated = inbox[0]
        updated.updatedAt = now.addingTimeInterval(3600)
        let (_, again) = try await gh.run {
            await GitHub.attributeTeams(inbox: [updated], teams: teams, cache: cache, now: now, caller: "github.sync")
        }
        #expect(again.isEmpty)

        // The reason changing works it out again.
        let (_, changed) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t1", 12, reason: "review_requested", kind: .pr)], teams: teams, cache: cache, now: now,
                caller: "github.sync"
            )
        }
        #expect(changed.map(\.operation) == ["GET pulls/requested_reviewers"])
    }

    @Test func threadsInOneRepoShareTheSearch() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("mentions", """
        acme/docs-all https://github.com/acme/docs/issues/12
        acme/docs-eng https://github.com/acme/docs/issues/12
        acme/docs-search https://github.com/acme/docs/issues/14
        acme/docs-all https://github.com/acme/api/issues/1
        """)
        let api = Repo(org: "acme", name: "api")
        let inbox = [thread("a", 12), thread("b", 14), thread("c", 1, repo: api)]
        let ((_, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: inbox, teams: ViewerTeams(), cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(cache.teams(for: inbox[0]) == ["acme/docs-all", "acme/docs-eng"])
        #expect(cache.teams(for: inbox[1]) == ["acme/docs-search"])
        #expect(cache.teams(for: inbox[2]) == ["acme/docs-all"])
        // One search per repo, not per thread.
        #expect(calls.map(\.operation) == ["GET user/teams", "graphql teamSearch", "graphql teamSearch"])
    }

    @Test func aFailingBatchIsSplitIntoPairs() async throws {
        let gh = try StandInGh()
        let eight = (1 ... 8).map { "acme\tteam-\($0)\t" }.joined(separator: "\n")
        try gh.file("teams", eight)
        try gh.file("mentions", "acme/team-5 https://github.com/acme/docs/issues/12\n")
        try gh.file("max-batch", "2")
        let ((_, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: ViewerTeams(), cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        #expect(cache.teams(for: thread("t", 12)) == ["acme/team-5"])
        let searches = calls.filter { $0.operation == "graphql teamSearch" }
        // Six aliases (failed), then three pairs; then the last two teams in one call.
        #expect(searches.map(\.detail.count) == [6, 2, 2, 2, 2])
        #expect(searches.map(\.failed) == [true, false, false, false, false])
    }

    @Test func searchFindingNothingFallsBackToTheThreadsText() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("thread.json", """
        {"data":{"repository":{"issueOrPullRequest":{"body":"Proposal for @acme/everyone",
          "comments":{"nodes":[{"body":"Looping in @ACME/docs-all"},{"body":"`@acme/docs-eng` in code"}]}}}}}
        """)
        let ((_, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: ViewerTeams(), cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        // @acme/everyone is not one of your teams; the code span does not count.
        #expect(cache.teams(for: thread("t", 12)) == ["acme/docs-all"])
        #expect(cache.entries["t"]?.source == .text)
        #expect(calls.map(\.operation) == ["GET user/teams", "graphql teamSearch", "graphql threadText"])
        #expect(calls.last?.detail == ["owner": "acme", "name": "docs", "number": "12"])
    }

    @Test func noTeamFoundAnywhereIsUnknown() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file(
            "thread.json",
            #"{"data":{"repository":{"issueOrPullRequest":{"body":"nothing","comments":{"nodes":[]}}}}}"#
        )
        let ((_, cache), _) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: ViewerTeams(), cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        #expect(cache.entries["t"]?.source == .unknown && cache.teams(for: thread("t", 12)).isEmpty)
        #expect(!cache.needs(thread("t", 12)))
    }

    @Test func threadsStillInTheInboxAreKeptAndOthersDropAfterThirtyDays() async throws {
        let gh = try StandInGh()
        var cache = TeamMentionCache()
        cache.record(thread("kept", 1), teams: ["acme/docs-eng"], source: .search, now: now)
        cache.record(thread("gone", 2), teams: ["acme/docs-eng"], source: .search, now: now)
        let later = now.addingTimeInterval(TeamMentionCache.retention + 60)
        let ((_, pruned), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("kept", 1)], teams: ViewerTeams(fetchedAt: later), cache: cache, now: later,
                caller: "github.sync"
            )
        }
        #expect(Set(pruned.entries.keys) == ["kept"] && pruned.entries["kept"]?.seenAt == later)
        #expect(calls.isEmpty)
    }

    @Test func urlsMatchWhateverTheirCase() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("mentions", "acme/docs-eng https://github.com/acme/docs/issues/12\n")
        let mixed = thread("t", 12, repo: Repo(org: "Acme", name: "Docs"))
        let ((_, cache), _) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [mixed], teams: ViewerTeams(), cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(cache.teams(for: mixed) == ["acme/docs-eng"] && cache.entries["t"]?.source == .search)
    }

    @Test func aRepoInAnOrgYouHaveNoTeamsInCostsNoCall() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        let other = thread("t", 3, repo: Repo(org: "initech", name: "web"))
        let ((_, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [other], teams: ViewerTeams(), cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(cache.entries["t"]?.source == .unknown)
        #expect(calls.map(\.operation) == ["GET user/teams"])
    }

    @Test func aFailedFallbackIsRetriedNextSync() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        let ((teams, cache), _) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: ViewerTeams(), cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        #expect(cache.entries["t"]?.source == nil && cache.needs(thread("t", 12)))
        try gh.file("thread.json", #"{"data":{"repository":{"issueOrPullRequest":{"body":"@acme/docs-eng"}}}}"#)
        let ((_, retried), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: teams, cache: cache, now: now, caller: "github.sync"
            )
        }
        #expect(retried.teams(for: thread("t", 12)) == ["acme/docs-eng"])
        // Teams were fresh: not fetched again.
        #expect(calls.map(\.operation) == ["graphql teamSearch", "graphql threadText"])
    }

    @Test func withoutReadOrgThereIsANoteAndNoAttribution() async throws {
        let gh = try StandInGh()
        try gh.file("teams-error", """
        gh: This API operation needs the "read:org" scope. To request it, run:  gh auth refresh -h github.com -s read:org
        """)
        let ((teams, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: ViewerTeams(), cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        #expect(teams.note == ViewerTeams.missingScopeNote && !teams.available)
        #expect(cache.entries.isEmpty)
        #expect(calls.map(\.operation) == ["GET user/teams"])
        // Not asked again until tomorrow, or a forced sync.
        let (_, later) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: teams, cache: cache, now: now.addingTimeInterval(600),
                caller: "github.sync"
            )
        }
        #expect(later.isEmpty)
        try gh.remove("teams-error")
        try gh.file("teams", threeTeams)
        try gh.file("mentions", "acme/docs-eng https://github.com/acme/docs/issues/12\n")
        let ((fixed, attributed), _) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 12)], teams: teams, cache: cache, refresh: true, now: now.addingTimeInterval(600),
                caller: "github.sync"
            )
        }
        #expect(fixed.available && attributed.teams(for: thread("t", 12)) == ["acme/docs-eng"])
    }

    @Test func staleTeamsAreRefreshedOnlyWhenAThreadNeedsThem() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        let old = ViewerTeams(
            teams: [GitHubTeam(org: "acme", slug: "docs-eng")],
            fetchedAt: now.addingTimeInterval(-2 * 86400)
        )
        let (_, quiet) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 1, reason: "mention")], teams: old, cache: TeamMentionCache(), now: now,
                caller: "github.sync"
            )
        }
        #expect(quiet.isEmpty)
        try gh.file("mentions", "acme/docs-search https://github.com/acme/docs/issues/1\n")
        let ((teams, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [thread("t", 1)], teams: old, cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(teams.fetchedAt == now && teams.teams.count == 4)
        #expect(cache.teams(for: thread("t", 1)) == ["acme/docs-search"])
        #expect(calls.first?.operation == "GET user/teams")
    }

    @Test func reviewRequestsComeThroughTheRequestedTeams() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("reviewers", "docs-search\nsecurity\n")
        let pull = thread("p", 7, reason: "review_requested", kind: .pr)
        let ((_, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: [pull], teams: ViewerTeams(), cache: TeamMentionCache(), now: now, caller: "github.sync"
            )
        }
        #expect(cache.teams(for: pull) == ["acme/docs-search"])
        #expect(cache.entries["p"]?.source == .reviewers)
        #expect(calls.map(\.operation) == ["GET user/teams", "GET pulls/requested_reviewers"])
        #expect(calls.last?.command.contains("repos/acme/docs/pulls/7/requested_reviewers") == true)
    }

    @Test func atMostTheLimitIsWorkedOutPerSync() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("reviewers", "docs-eng\n")
        let pulls = (1 ... 5).map { thread("p\($0)", $0, reason: "review_requested", kind: .pr) }
        let ((teams, cache), calls) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: pulls, teams: ViewerTeams(), cache: TeamMentionCache(), limit: 2, now: now,
                caller: "github.sync"
            )
        }
        #expect(calls.count(where: { $0.operation == "GET pulls/requested_reviewers" }) == 2)
        let ((_, next), more) = try await gh.run {
            await GitHub.attributeTeams(
                inbox: pulls,
                teams: teams,
                cache: cache,
                limit: 2,
                now: now,
                caller: "github.sync"
            )
        }
        #expect(more.count == 2 && next.entries.count == 4)
    }

    @Test func syncFillsTheInboxTeams() async throws {
        let gh = try StandInGh()
        try gh.file("teams", threeTeams)
        try gh.file("mentions", "acme/docs-eng https://github.com/acme/docs/issues/12\n")
        try gh.file("notifications", """
        [{"id":"9","reason":"team_mention","unread":true,"updated_at":"2026-10-05T19:00:52Z",
          "subject":{"title":"Archive old docs","type":"Issue","url":"https://api.github.com/repos/acme/docs/issues/12"},
          "repository":{"full_name":"acme/docs"}},
         {"id":"10","reason":"mention","unread":true,"updated_at":"2026-10-05T18:00:52Z",
          "subject":{"title":"Typo","type":"Issue","url":"https://api.github.com/repos/acme/docs/issues/13"},
          "repository":{"full_name":"acme/docs"}}]
        """)
        let previous = GitHubState(viewer: "you")
        let (state, _) = try await gh.run {
            try await GitHub.sync(parts: [.inbox], tracked: [], previous: previous, now: now, caller: "github.sync")
        }
        #expect(state.inbox.map(\.teams) == [["acme/docs-eng"], []])
        #expect(state.teamMentions.entries["9"]?.source == .search)
        #expect(state.teams.available)
        // A sync without the inbox keeps the teams it had.
        let (kept, calls) = try await gh.run {
            try await GitHub.sync(parts: [], tracked: [], previous: state, now: now, caller: "github.sync")
        }
        #expect(kept.inbox.map(\.teams) == [["acme/docs-eng"], []] && calls.isEmpty)
    }
}
