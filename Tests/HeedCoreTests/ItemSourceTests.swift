import Foundation
@testable import HeedCore
import Synchronization
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)
private let repo = "acme/widgets"

private func pull(
    _ number: Int, _ state: SourceMatch.State = .open, review: SourceMatch.Review? = nil, green: Bool = false,
    author: String = "tess"
) -> SourceMatch {
    SourceMatch(
        ref: "\(repo)#\(number)", kind: .pr, title: "PR \(number)", url: "https://github.com/\(repo)/pull/\(number)",
        author: author, state: state, checks: CheckSummary(passed: green ? 3 : 2, pending: green ? 0 : 1),
        review: review
    )
}

private func issue(_ number: Int, _ state: SourceMatch.State = .open) -> SourceMatch {
    SourceMatch(
        ref: "\(repo)#\(number)", kind: .issue, title: "Issue \(number)",
        url: "https://github.com/\(repo)/issues/\(number)", author: "omar", state: state
    )
}

private func source(_ rule: ItemSource.Rule = .reviewed, id: String = "s1", query: String? = nil) -> ItemSource {
    ItemSource(
        id: id, query: query ?? "is:pr is:open repo:\(repo)", label: "open PRs in \(repo)", rule: rule, addedAt: now
    )
}

struct ItemSourceQueryTests {
    @Test func wordsAndSearchesBecomeQueries() throws {
        let prs = try ItemSourceQuery.parse("prs acme/web")
        #expect(prs.query == "is:pr is:open repo:acme/web" && prs.label == "open PRs in acme/web" && prs
            .rule == .merged)
        #expect(try ItemSourceQuery.parse("issues acme/web").query == "is:issue is:open repo:acme/web")
        #expect(try ItemSourceQuery.parse("label \"good first issue\" acme/web").query
            == "is:open label:\"good first issue\" repo:acme/web")
        let reviews = try ItemSourceQuery.parse("reviews")
        #expect(reviews.query == "is:pr is:open review-requested:@me" && reviews.rule == .reviewed)
        #expect(try ItemSourceQuery.parse("milestone v2.0 acme/web").query == "is:open milestone:v2.0 repo:acme/web")
        #expect(try ItemSourceQuery.parse("https://github.com/acme/web/pulls").query == "is:pr is:open repo:acme/web")
        // A search keeps its words, and gets is:open unless it names a state.
        let search = try ItemSourceQuery.parse("is:pr repo:acme/web label:deps")
        #expect(search.query == "is:open is:pr repo:acme/web label:deps" && search.rule == .merged)
        #expect(try ItemSourceQuery.parse("is:issue is:closed repo:acme/web")
            .query == "is:issue is:closed repo:acme/web")
        // The goal's repo fills in for words that name none.
        #expect(try ItemSourceQuery.parse("prs", repo: "acme/api").query == "is:pr is:open repo:acme/api")
        #expect(throws: ItemSourceQuery.Problem.self) { try ItemSourceQuery.parse("prs") }
        #expect(throws: ItemSourceQuery.Problem.self) { try ItemSourceQuery.parse("all the things") }
        #expect(throws: ItemSourceQuery.Problem.self) { try ItemSourceQuery.parse("") }
    }

    @Test func whatASearchFinds() {
        #expect(ItemSourceQuery.what("is:pr is:open") == .pulls)
        #expect(ItemSourceQuery.what("review-requested:@me") == .pulls)
        #expect(ItemSourceQuery.what("is:issue label:x") == .issues)
        #expect(ItemSourceQuery.what("label:x") == .both)
        #expect(!ItemSource.Rule.reviewed.fits(.issues) && ItemSource.Rule.closed.fits(.issues))
        #expect(source().criterion == "All open PRs in acme/widgets reviewed by you")
    }
}

struct ItemSourceSyncTests {
    @Test func eachMatchIsOneNewItemWithItsEvidence() throws {
        let plan = ItemSourceSync.plan(
            goal: "g", sources: [source()], results: ["s1": SourceResult(matches: [
                pull(1),
                pull(2, review: .approved),
            ])],
            items: [], evidence: [], now: now
        )
        #expect(plan.adds.map(\.title) == ["PR 1", "PR 2"])
        let first = try #require(plan.adds.first)
        #expect(first.sourced.ref == "acme/widgets#1" && first.sourced.author == "tess" && first.sourced
            .rule == .reviewed)
        #expect(first.evidence.contains { $0.kind == .criterion && $0.state == .inProgress })
        #expect(plan.adds[1].evidence.contains { $0.kind == .criterion && $0.state == .done })
        #expect(plan.adds[1].evidence.contains { $0.kind == .codeReview && $0.source == "you" })
    }

    @Test func aPRTwoSourcesFindIsOneItem() {
        let plan = ItemSourceSync.plan(
            goal: "g", sources: [source(), source(id: "s2", query: "is:pr review-requested:@me")],
            results: ["s1": SourceResult(matches: [pull(1)]), "s2": SourceResult(matches: [pull(1), pull(3)])],
            items: [], evidence: [], now: now
        )
        #expect(plan.adds.map(\.sourced.ref) == ["acme/widgets#1", "acme/widgets#3"])
        #expect(plan.adds.map(\.sourced.source) == ["s1", "s2"])
    }

    @Test func anItemTheGoalHadForThePRIsTakenIn() {
        let existing = GoalItem(
            id: "g/fix", goal: "g", title: "Fix it", source: .pr, links: [GoalItem.Link(.pr, "acme/widgets#1")],
            createdAt: now
        )
        let plan = ItemSourceSync.plan(
            goal: "g", sources: [source()], results: ["s1": SourceResult(matches: [pull(1)])], items: [existing],
            evidence: [], now: now
        )
        #expect(plan.adds.isEmpty)
        #expect(plan.updates.first?.id == "g/fix" && plan.updates.first?.sourced?.source == "s1")
        #expect(plan.evidence.allSatisfy { $0.item == "g/fix" } && !plan.evidence.isEmpty)
    }

    /// The goal after one sync of `matches`, through the store.
    private func synced(_ matches: [SourceMatch], rule: ItemSource.Rule = .reviewed) async throws -> GoalOps {
        let ops = try GoalOps.inMemory()
        let goal = try await ops.create(title: "Review PRs", statement: "", now: now)
        #expect(goal.id == "review-prs")
        try await ops.addSource(goal: "review-prs", source(rule), now: now)
        try await ops.applySources(
            goal: "review-prs", results: ["s1": SourceResult(matches: matches)], error: nil, now: now
        )
        return ops
    }

    @Test func aSecondSyncWithNothingNewWritesNothing() async throws {
        let ops = try await synced([pull(1), pull(2)])
        let before = try await ops.snapshot()
        let summary = try await ops.applySources(
            goal: "review-prs", results: ["s1": SourceResult(matches: [pull(1), pull(2)])], error: nil, now: now + 60
        )
        #expect(summary.added == 0 && summary.updated == 0 && summary.evidence == 0)
        #expect(try await ops.snapshot().items == before.items)
    }

    @Test func closedOnesGetEvidenceAndOnesThatLeftAreMarkedNeverDeleted() async throws {
        let ops = try await synced([pull(1), pull(2), pull(3), pull(4)])
        let snapshot = try await ops.snapshot()
        let lookups = ItemSourceSync.lookups(
            source: source(), items: snapshot.items(of: "review-prs"), evidence: snapshot.evidence
        )
        #expect(lookups.count == 4)
        // 1 still matches; 2 merged; 3 is open but out of the query; 4 is gone.
        try await ops.applySources(goal: "review-prs", results: ["s1": SourceResult(
            matches: [pull(1)], looked: ["acme/widgets#2": pull(2, .merged), "acme/widgets#3": pull(3)]
        )], error: nil, now: now + 60)
        let after = try await ops.snapshot()
        let items = Dictionary(uniqueKeysWithValues: after.items(of: "review-prs").map { ($0.sourced!.ref, $0) })
        #expect(items.count == 4)
        let merged = try #require(items["acme/widgets#2"])
        #expect(merged.sourced?.left == nil && Board.column(merged, evidence: after.evidence) == .done)
        #expect(items["acme/widgets#3"]?.sourced?.left == now + 60)
        #expect(items["acme/widgets#4"]?.sourced?.left == now + 60)
        #expect(items["acme/widgets#1"]?.sourced?.left == nil)
        #expect(Board.badge(items["acme/widgets#3"]!, evidence: after.evidence) == .left)
        // A merged one is not asked about again.
        #expect(!ItemSourceSync.lookups(source: source(), items: Array(items.values), evidence: after.evidence)
            .contains("acme/widgets#2"))
        // Back in the query: no longer marked.
        try await ops.applySources(
            goal: "review-prs", results: ["s1": SourceResult(matches: [pull(1), pull(3)])], error: nil, now: now + 120
        )
        let back = try await ops.snapshot().items(of: "review-prs").first { $0.sourced?.ref == "acme/widgets#3" }
        #expect(back?.sourced?.left == nil)
    }

    @Test func aFailedSourceLeavesItsItemsAlone() async throws {
        let ops = try await synced([pull(1)])
        try await ops.applySources(goal: "review-prs", results: [:], error: "s1: offline", now: now + 60)
        let snapshot = try await ops.snapshot()
        #expect(snapshot.items(of: "review-prs").first?.sourced?.left == nil)
        #expect(snapshot.sources(of: "review-prs").error == "s1: offline")
    }

    @Test func theRuleSaysWhereACardIs() async throws {
        let ops = try await synced([
            pull(1),
            pull(2, review: .commented),
            pull(3, .closed),
            pull(4, review: .changesRequested),
        ])
        let snapshot = try await ops.snapshot()
        func column(_ number: Int) -> Board.Column? {
            snapshot.items.first { $0.sourced?.ref == "acme/widgets#\(number)" }
                .map { Board.column($0, evidence: snapshot.evidence) }
        }
        // Waiting for your review is work to do; reviewed (any way) or closed is done.
        #expect(column(1) == .planned)
        #expect(column(2) == .done && column(3) == .done && column(4) == .done)
        // The same PRs by merged: open ones wait to land in Verify.
        let merging = try await synced([pull(1), pull(2, review: .commented)], rule: .merged)
        let other = try await merging.snapshot()
        #expect(other.items.allSatisfy { Board.column($0, evidence: other.evidence) == .verify })
    }

    @Test func aReviewAskedForAgainReopensTheItem() async throws {
        let ops = try await synced([pull(1, review: .approved)])
        var snapshot = try await ops.snapshot()
        #expect(snapshot.items.first.map { Board.column($0, evidence: snapshot.evidence) } == .done)
        var asked = pull(1, review: .approved)
        asked.reviewRequested = true
        try await ops.applySources(
            goal: "review-prs", results: ["s1": SourceResult(matches: [asked])], error: nil, now: now + 60
        )
        snapshot = try await ops.snapshot()
        let item = try #require(snapshot.items.first)
        #expect(Board.column(item, evidence: snapshot.evidence) == .planned)
        #expect(snapshot.evidence.contains { $0.kind == .criterion && $0.text == "#1 review re-requested" })
        #expect(snapshot.evidence.contains { $0.kind == .codeReview && $0.text == "#1 review re-requested" })
        // Reviewed again: done again.
        try await ops.applySources(goal: "review-prs", results: ["s1": SourceResult(
            matches: [pull(1, review: .commented)]
        )], error: nil, now: now + 120)
        snapshot = try await ops.snapshot()
        #expect(snapshot.items.first.map { Board.column($0, evidence: snapshot.evidence) } == .done)
    }

    @Test func greenAndIssueRules() {
        #expect(ItemSourceSync.met(.green, pull(1, green: true)) == "green")
        #expect(ItemSourceSync.met(.green, pull(1)) == nil)
        #expect(ItemSourceSync.met(.merged, pull(1, review: .approved)) == nil)
        #expect(ItemSourceSync.met(.reviewed, pull(1, .merged)) == "merged")
        #expect(ItemSourceSync.met(.closed, issue(5)) == nil)
        #expect(ItemSourceSync.met(.closed, issue(5, .closed)) == "closed")
    }

    @Test func everyItemDoneChecksTheSourcesLineOff() async throws {
        let ops = try await synced([pull(1, review: .approved), pull(2)])
        var doc = try await GoalDoc.parse(ops.text(of: "review-prs"))
        #expect(doc.doneWhen.map(\.text) == ["All open PRs in acme/widgets reviewed by you"])
        #expect(doc.doneWhen.first?.met == false)
        let summary = try await ops.applySources(goal: "review-prs", results: ["s1": SourceResult(
            matches: [pull(1, review: .approved), pull(2, review: .approved)]
        )], error: nil, now: now + 60)
        doc = try await GoalDoc.parse(ops.text(of: "review-prs"))
        #expect(summary.met == ["All open PRs in acme/widgets reviewed by you"])
        #expect(doc.doneWhen.first?.met == true && doc.doneWhen.first?.evidence == "2 of 2 reviewed")
    }
}

struct GoalSourceOpsTests {
    private func goal() async throws -> GoalOps {
        let ops = try GoalOps.inMemory()
        try await ops.create(title: "Review PRs", statement: "", now: now)
        return ops
    }

    @Test func sourcesAreAddedOnceAndRulesFitWhatTheyFind() async throws {
        let ops = try await goal()
        let added = try await ops.addSource(goal: "review-prs", source(id: ""), now: now)
        #expect(added.id == "s1")
        await #expect(throws: GoalOpError.self) { try await ops.addSource(goal: "review-prs", source(), now: now) }
        let issues = ItemSource(query: "is:issue is:open repo:\(repo)", label: "issues", rule: .reviewed, addedAt: now)
        await #expect(throws: GoalOpError.self) { try await ops.addSource(goal: "review-prs", issues, now: now) }
        await #expect(throws: GoalOpError.self) {
            try await ops.setSourceRule(goal: "review-prs", id: "s9", .merged, now: now)
        }
    }

    @Test func aRuleChangeRewordsTheLineAndRemovingTakesItOut() async throws {
        let ops = try await goal()
        try await ops.addSource(goal: "review-prs", source(), now: now)
        try await ops.applySources(
            goal: "review-prs",
            results: ["s1": SourceResult(matches: [pull(1)])],
            error: nil,
            now: now
        )
        try await ops.setSourceRule(goal: "review-prs", id: "s1", .merged, now: now)
        var doc = try await GoalDoc.parse(ops.text(of: "review-prs"))
        #expect(doc.doneWhen.map(\.text) == ["All open PRs in acme/widgets merged"])
        #expect(try await ops.snapshot().items.first?.sourced?.rule == .merged)
        try await ops.removeSource(goal: "review-prs", id: "s1", now: now + 5)
        doc = try await GoalDoc.parse(ops.text(of: "review-prs"))
        #expect(doc.doneWhen.isEmpty)
        let snapshot = try await ops.snapshot()
        // Its items stay, marked.
        #expect(snapshot.items.count == 1 && snapshot.items.first?.sourced?.left == now + 5)
        #expect(snapshot.sources(of: "review-prs").sources.isEmpty)
    }

    @Test func aProposalIsTakenOrSaidNoToOnce() async throws {
        let ops = try await goal()
        let proposal = SourceProposal(source: source(id: ""), because: "review all open PRs", by: .words)
        try await ops.propose(source: proposal, goal: "review-prs", version: 1)
        #expect(try await ops.sourceState(of: "review-prs").proposal == proposal)
        #expect(try await ops.sourceState(of: "review-prs").checked == 1)
        try await ops.dismissSourceProposal(goal: "review-prs")
        try await ops.propose(source: proposal, goal: "review-prs", version: 2)
        #expect(try await ops.sourceState(of: "review-prs").proposal == nil)
        await #expect(throws: GoalOpError.self) { try await ops.acceptSourceProposal(goal: "review-prs", now: now) }

        let other = try await goal()
        try await other.propose(source: proposal, goal: "review-prs", version: 1)
        let added = try await other.acceptSourceProposal(goal: "review-prs", now: now)
        #expect(added.origin == .proposal && added.id == "s1")
        #expect(try await other.sourceState(of: "review-prs").proposal == nil)
    }
}

/// A Decider with a fixed choice (nil: the call fails).
private final class FakeDecider: Decider {
    let choice: String?
    let asked = Mutex(0)

    init(_ choice: String?) { self.choice = choice }

    func decide(subject _: String, state _: String, questions _: [String: Question]) async throws -> [String: Answer] {
        asked.withLock { $0 += 1 }
        guard let choice else { throw DeciderError.badAnswer("fake") }
        return ["set": Answer(choice: choice, probabilities: [choice: 0.9], confidence: 0.9)]
    }
}

struct ItemSourceDetectTests {
    @Test func theWordsReadSetsOverGitHub() {
        #expect(ItemSourceDetect.intent("Review all open PRs in acme/web") == .reviewPulls)
        #expect(ItemSourceDetect.intent("Get every dependency PR merged") == .mergePulls)
        #expect(ItemSourceDetect.intent("Close every issue labelled flaky") == .closeIssues)
        #expect(ItemSourceDetect.intent("Keep up with PRs that ask for my review") == .reviewRequests)
        #expect(ItemSourceDetect.intent("Anchors survive page moves") == .none)
        #expect(ItemSourceDetect.intent("Print every page review") == .none)
        let words = ItemSourceDetect.words("Close every issue labelled flaky in acme/widgets.")
        #expect(words.repo == "acme/widgets" && words.label == "flaky")
        #expect(ItemSourceDetect.words("Fix the issues in milestone \"2.0 beta\" of acme/web").milestone == "2.0 beta")
    }

    @Test func theWordsAloneProposeASource() throws {
        let review = try #require(ItemSourceDetect.byWords(
            title: "Review all open PRs in acme/web", statement: "", repos: [], now: now
        ))
        #expect(review.source.query == "is:pr is:open repo:acme/web" && review.source.rule == .reviewed)
        #expect(review.by == .words)
        let flaky = try #require(ItemSourceDetect.byWords(
            title: "Close every flaky issue", statement: "Every issue labelled flaky.", repos: ["acme/api"], now: now
        ))
        #expect(flaky.source.query == "is:issue is:open label:flaky repo:acme/api" && flaky.source.rule == .closed)
        // No repo to search: nothing to propose.
        #expect(ItemSourceDetect.byWords(title: "Review all open PRs", statement: "", repos: [], now: now) == nil)
        #expect(ItemSourceDetect.byWords(title: "Faster builds", statement: "", repos: ["a/b"], now: now) == nil)
    }

    @Test func theModelSaysWhatKindAndTheWordsWhere() async throws {
        let decider = FakeDecider("merge-prs")
        let found = try #require(await ItemSourceDetect.detect(
            title: "Land the dependency bump PRs", statement: "In acme/web.", repos: [], goal: "g", decider: decider,
            now: now
        ))
        #expect(found.by == .model && found.source.rule == .merged && found.source.query.contains("repo:acme/web"))
        #expect(decider.asked.withLock { $0 } == 1)
        // A goal that speaks of no PRs or issues is not worth a call.
        let quiet = FakeDecider("merge-prs")
        #expect(await ItemSourceDetect.detect(
            title: "Faster builds", statement: "Under a minute.", repos: ["a/b"], goal: "g", decider: quiet, now: now
        ) == nil)
        #expect(quiet.asked.withLock { $0 } == 0)
        // The model says none: nothing, whatever the words.
        #expect(await ItemSourceDetect.detect(
            title: "Review all open PRs in acme/web", statement: "", repos: [], goal: "g", decider: FakeDecider("none"),
            now: now
        ) == nil)
        // The call fails: the words decide.
        let fallback = await ItemSourceDetect.detect(
            title: "Review all open PRs in acme/web", statement: "", repos: [], goal: "g", decider: FakeDecider(nil),
            now: now
        )
        #expect(fallback?.by == .words && fallback?.source.rule == .reviewed)
    }
}

/// The gh adapter: one search per source, lookups by number, a `github` row per call.
struct GitHubSourcesTests {
    private func fakeGh() throws -> (path: String, args: URL, dir: URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-sources-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let args = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" -- >> '\(args.path)'
        case "$*" in
          *issueOrPullRequest*) echo '{"data":{"viewer":{"login":"me"},"r0":{"issueOrPullRequest":{"__typename":"PullRequest","number":7,"title":"Old","url":"https://github.com/acme/widgets/pull/7","state":"MERGED","isDraft":false,"repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"lin"},"viewerLatestReview":{"state":"COMMENTED"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"User","login":"sam"}}]},"commits":{"nodes":[]}}},"r1":{"issueOrPullRequest":null}}}' ;;
          *after=c1*) echo '{"data":{"viewer":{"login":"me"},"search":{"issueCount":2,"pageInfo":{"hasNextPage":false,"endCursor":"c2"},"nodes":[{"__typename":"Issue","number":13,"title":"Flaky test","url":"https://github.com/acme/widgets/issues/13","state":"OPEN","repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"omar"}}]}}}' ;;
          *) echo '{"data":{"rateLimit":{"cost":1,"remaining":4990},"viewer":{"login":"me"},"search":{"issueCount":2,"pageInfo":{"hasNextPage":true,"endCursor":"c1"},"nodes":[{"__typename":"PullRequest","number":12,"title":"Cache templates","url":"https://github.com/acme/widgets/pull/12","state":"OPEN","isDraft":false,"repository":{"nameWithOwner":"acme/widgets"},"author":{"login":"tess"},"viewerLatestReview":{"state":"APPROVED"},"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team"}},{"requestedReviewer":{"__typename":"User","login":"me"}}]},"commits":{"nodes":[{"commit":{"statusCheckRollup":{"contexts":{"nodes":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS","startedAt":"2026-10-26T10:00:00Z"}]}}}}]}}]}}}' ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, args, dir)
    }

    @Test func searchesAndLookupsReadGitHubsAnswer() async throws {
        let gh = try fakeGh()
        let log = try CallLog(
            store: CallStore(path: gh.dir.appendingPathComponent("log.sqlite").path), delay: .seconds(60)
        )
        let github = GitHubSources()
        let (found, looked) = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(gh.path) {
                let found = try await github.search("is:open repo:acme/widgets")
                let looked = try await github.lookup(["acme/widgets#7", "acme/widgets#8"])
                return (found, looked)
            }
        }
        #expect(found.total == 2 && found.matches.map(\.ref) == ["acme/widgets#12", "acme/widgets#13"])
        let pr = try #require(found.matches.first)
        // Approved, then asked again: the ask that is open now counts. Someone else's request does not.
        #expect(pr.reReview && ItemSourceSync.met(.reviewed, pr) == nil)
        #expect(looked.first?.reviewRequested == false && looked.first?.review == .commented)
        #expect(pr.kind == .pr && pr.author == "tess" && pr.review == .approved && pr.green && pr.state == .open)
        #expect(found.matches[1].kind == .issue && found.matches[1].author == "omar")
        #expect(looked.map(\.ref) == ["acme/widgets#7"] && looked.first?.state == .merged)
        await log.flush()
        let calls = try await log.store.calls(CallFilter())
        #expect(calls.count == 3 && calls
            .allSatisfy { $0.kind == .github && $0.caller == "goals.sources" && !$0.write })
        let sent = try String(contentsOf: gh.args, encoding: .utf8)
        #expect(sent.contains("q=is:open repo:acme/widgets"))
        // The second page asks after the first one's cursor.
        #expect(sent.contains("after=c1"))
    }

    @Test func aSyncRunSearchesEachSourceAndLooksUpWhatLeft() async throws {
        let ops = try GoalOps.inMemory()
        try await ops.create(title: "Review PRs", statement: "", now: now)
        try await ops.addSource(goal: "review-prs", source(), now: now)
        let github = FakeSources(matches: [pull(1), pull(2)])
        let run = ItemSourceSyncRun(ops: ops, github: github)
        #expect(try await run.sync(goal: "review-prs", now: now).added == 2)
        github.matches.withLock { $0 = [pull(1)] }
        github.looked.withLock { $0 = [pull(2, .closed)] }
        try await run.sync(goal: "review-prs", now: now + 60)
        #expect(github.lookups.withLock { $0 } == [["acme/widgets#2"]])
        let snapshot = try await ops.snapshot()
        let closed = try #require(snapshot.items.first { $0.sourced?.ref == "acme/widgets#2" })
        #expect(Board.column(closed, evidence: snapshot.evidence) == .done && closed.sourced?.left == nil)
        // A search that fails says so, and keeps the items.
        github.fails.withLock { $0 = true }
        try await run.sync(goal: "review-prs", now: now + 120)
        #expect(try await ops.sourceState(of: "review-prs").error?.hasPrefix("s1:") == true)
        #expect(try await ops.snapshot().items.count == 2)
    }
}

private final class FakeSources: SourceGitHub {
    let matches: Mutex<[SourceMatch]>
    let looked = Mutex<[SourceMatch]>([])
    let lookups = Mutex<[[String]]>([])
    let fails = Mutex(false)

    init(matches: [SourceMatch]) { self.matches = Mutex(matches) }

    func search(_: String) async throws -> (matches: [SourceMatch], total: Int) {
        if fails.withLock({ $0 }) { throw GitHub.Failure(description: "offline") }
        let found = matches.withLock { $0 }
        return (found, found.count)
    }

    func lookup(_ refs: [String]) async throws -> [SourceMatch] {
        lookups.withLock { $0.append(refs) }
        return looked.withLock { $0 }.filter { refs.contains($0.ref) }
    }
}

struct GoalSourceCommandTests {
    private func parse(_ line: String) throws -> GoalCommand {
        try GoalCommandLine.parse(line.split(separator: " ").map(String.init))
    }

    @Test func theCLIParsesSources() throws {
        let add = try parse("goal source add prs acme/web --rule reviewed")
        #expect(add.verb == .sourceAdd && add.text == "prs acme/web" && add.rule == "reviewed")
        #expect(try parse("goal source list").verb == .sourceList)
        #expect(try parse("goal source remove s1").subject == "s1")
        #expect(throws: HookCommandLine.UsageError.self) { try parse("goal source add prs acme/web --rule maybe") }
        #expect(throws: HookCommandLine.UsageError.self) { try parse("goal source remove") }
        #expect(throws: HookCommandLine.UsageError.self) { try parse("goal source list extra") }
        #expect(throws: HookCommandLine.UsageError.self) { try parse("goal item add x --rule merged") }
    }

    @Test func anAgentAddsListsAndRemovesSources() async throws {
        let ops = try GoalOps.inMemory()
        try await ops.create(title: "Review PRs", statement: "", now: now)
        let caller = GoalCaller(session: "s1", title: "Triage", repo: "acme/web")
        func run(_ line: String) async throws -> GoalReply? {
            var command = try parse(line)
            command.goal = "review-prs"
            if case let .reply(reply) = await GoalControl.run(
                command,
                caller: caller,
                ops: ops,
                files: .fixture,
                now: now
            ) {
                return reply
            }
            return nil
        }
        let added = try await run("goal source add prs --rule reviewed")
        #expect(added?.outcome == "added" && added?.sources?.first?.query == "is:pr is:open repo:acme/web")
        #expect(try await ops.sourceState(of: "review-prs").sources.first?.origin == .agent)
        let list = try await run("goal source list")
        #expect(list?.sources?.map(\.id) == ["s1"] && list?.rendered(json: false)
            .contains("done when reviewed") == true)
        #expect(try await run("goal source add nonsense")?.exit == .refused)
        #expect(try await run("goal source remove s1")?.outcome == "removed")
        #expect(try await run("goal source remove s1")?.exit == .refused)
    }

    @Test func aPRItemStartsAReview() {
        let item = GoalItem(
            id: "g/pr-12", goal: "g", title: "Cache templates", source: .github, createdAt: now,
            sourced: GoalItem.Sourced(
                source: "s1", ref: "acme/widgets#12", kind: .pr, url: "https://github.com/acme/widgets/pull/12",
                author: "tess", rule: .reviewed
            )
        )
        let prompt = item.workPrompt(goal: "Review PRs", doc: "~/g/GOAL.md")
        #expect(prompt.hasPrefix("Review PR acme/widgets#12 “Cache templates” by @tess"))
        #expect(prompt.contains("gh pr checkout 12 --repo acme/widgets") && prompt.contains("Cache templates"))
    }

    @Test func aSourcesMenuOffersItsRules() {
        let entries = ContextMenus.goalSource(
            id: "s1", label: "open PRs", query: "is:pr is:open", rule: .reviewed, what: .pulls
        )
        let names = entries.flatMap { entry -> [CommandInvocation] in
            switch entry {
            case let .item(item): [item.command]
            case let .submenu(_, items): items.map(\.command)
            default: []
            }
        }
        #expect(names.contains(CommandInvocation(name: "goal.source.rule", arguments: ["s1", "green"])))
        #expect(names.contains(CommandInvocation(name: "goal.source.remove", arguments: ["s1"])))
        let issues = ContextMenus.goalSource(id: "s2", label: "x", query: "is:issue", rule: .closed, what: .issues)
        #expect(!issues.contains { if case .submenu = $0 { true } else { false } })
    }

    @Test func theFixtureSourcesMakeABoard() throws {
        let fixtures = ItemSourceFixtures.all(now: now)
        let snapshot = GoalFixtures.snapshot(fixtures)
        let goal = ItemSourceFixtures.reviewGoal
        let columns = Board.columns(snapshot.items(of: goal), evidence: snapshot.evidence(of: goal))
        #expect(columns[.done]?.count == 2 && columns[.working]?.count == 1 && columns[.planned]?.count == 4)
        let states = ItemSourceFixtures.states(now: now)
        #expect(states[ItemSourceFixtures.issuesGoal]?.proposal?.source.query
            == "is:issue is:open label:flaky repo:acme/widgets")
        let progress = SourceProgress.of(
            states[goal]!.sources[0], items: snapshot.items(of: goal), evidence: snapshot.evidence(of: goal)
        )
        #expect(progress == SourceProgress(done: 2, total: 6, left: 1))
    }
}

struct GoalSourceGuideTests {
    private var doc: GoalDoc {
        var doc = GoalDoc.new(
            title: "Close flaky issues",
            statement: "Close every issue labelled flaky in acme/web now."
        )
        doc.notTheGoal = ["A new test runner"]
        doc.doneWhen = [GoalDoc.Criterion("The nightly run passes three nights in a row")]
        return doc
    }

    @Test func aProposedSourceWaitsInAddTheWorkAndTakingItTicksIt() {
        let proposal = SourceProposal(source: source(id: ""), because: "close every issue", by: .words)
        var input = GoalGuide.Input(doc: doc, sources: GoalSourceState(proposal: proposal))
        let waiting = GoalGuide.of(input)
        #expect(waiting.next?.step == .work)
        #expect(waiting.next?.state == .waiting(
            "heed proposes items from open PRs in acme/widgets, one per match", command: "goal.source.accept"
        ))
        #expect(waiting.next?.command == "goal.source.accept")
        input.sources = GoalSourceState(sources: [source()])
        let taken = GoalGuide.of(input)
        #expect(taken.steps.first { $0.step == .work }?.state == .done("items come from open PRs in acme/widgets"))
        #expect(taken.next?.step != .work)
        #expect(GoalGuide.of(GoalGuide.Input(doc: doc)).next?.state == .todo)
    }

    @Test func theDialogChecksTheQueryAsItIsTyped() {
        #expect(FormChecks.source(query: "", repo: nil, rule: nil).note(for: "query", tried: false) == nil)
        #expect(FormChecks.source(query: "", repo: nil, rule: nil).blocking != nil)
        let bad = FormChecks.source(query: "prs", repo: nil, rule: nil)
        #expect(bad.note(for: "query")?.tone == .problem && bad.blocking != nil)
        let fine = FormChecks.source(query: "prs", repo: "acme/web", rule: .reviewed)
        #expect(fine.note(for: "query") == FieldNote("query", "searches is:pr is:open repo:acme/web", tone: .fine))
        #expect(fine.blocking == nil)
        let wrongRule = FormChecks.source(query: "issues acme/web", repo: nil, rule: .reviewed)
        #expect(wrongRule.note(for: "rule")?.tone == .problem)
    }
}
