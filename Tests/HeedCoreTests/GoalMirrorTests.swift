import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// GitHub in memory: the issues heed made, what it was asked, and a colleague's hands. Nothing reaches GitHub.
actor FakeTracker: MirrorGitHub {
    struct Issue {
        var number: Int
        var id: Int64
        var title: String
        var body: String
        var open = true
        var parent: Int?
        var labels: [String] = []
        var updatedAt: Date
        var comments: [RemoteComment] = []
    }

    private(set) var issues: [Int: Issue] = [:]
    /// Every call, as `GoalMirrorPlan`'s lines and the reads by name.
    private(set) var calls: [String] = []
    /// Searches miss issues made less than this many calls ago (GitHub's search index lags).
    var searchSees = true
    /// The call after this many writes throws.
    var failAfterWrites: Int?
    var permission = "WRITE"
    private var writes = 0
    private var clock = now
    private var nextComment: Int64 = 1000

    var writeCount: Int { calls.count { !$0.hasPrefix("GET") && !$0.hasPrefix("check") } }

    func set(searchSees: Bool) { self.searchSees = searchSees }
    func set(failAfterWrites: Int?) { self.failAfterWrites = failAfterWrites }
    func clearCalls() { calls = [] }

    private func tick() -> Date {
        clock += 60
        return clock
    }

    /// Runs once, at the next write: something you do in heed while a sync is writing.
    private var during: (@Sendable () async throws -> Void)?
    func set(during: @escaping @Sendable () async throws -> Void) { self.during = during }

    private func write(_ line: String) async throws {
        if let limit = failAfterWrites, writes >= limit { throw GitHub.Failure(description: "HTTP 502") }
        writes += 1
        calls.append(line)
        if let during {
            self.during = nil
            try await during()
        }
    }

    // A colleague on GitHub.
    func colleague(close number: Int) { issues[number]?.open = false
        issues[number]?.updatedAt = tick()
    }

    func colleague(reopen number: Int) { issues[number]?.open = true
        issues[number]?.updatedAt = tick()
    }

    func colleague(comment body: String, on number: Int, by author: String = "sam") {
        nextComment += 1
        let at = tick()
        issues[number]?.comments.append(RemoteComment(id: nextComment, author: author, body: body, at: at))
        issues[number]?.updatedAt = at
    }

    func check(repo: String) async throws -> TrackerCheck {
        calls.append("check \(repo)")
        return TrackerCheck.from(
            repo: repo,
            found: repo != "acme/gone",
            hasIssues: true,
            archived: false,
            permission: permission
        )
    }

    func marked(repo _: String, goal: String) async throws -> [RemoteIssue] {
        calls.append("GET search \(goal)")
        guard searchSees else { return [] }
        return issues.values.filter { $0.body.contains("heed:") && $0.body.contains(goal) }.map(remote)
    }

    private func remote(_ issue: Issue) -> RemoteIssue {
        RemoteIssue(
            number: issue.number, id: issue.id, title: issue.title, body: issue.body, open: issue.open,
            updatedAt: issue.updatedAt, parent: issue.parent
        )
    }

    func create(repo _: String, title: String, body: String, labels: [String]) async throws -> RemoteIssue {
        try await write("create \(title)")
        let number = (issues.keys.max() ?? 0) + 1
        let issue = Issue(
            number: number, id: Int64(9_000_000 + number), title: title, body: body, labels: labels, updatedAt: tick()
        )
        issues[number] = issue
        return remote(issue)
    }

    func edit(repo _: String, number: Int, title: String?, body: String?) async throws {
        try await write("edit #\(number)" + (title != nil ? " title" : "") + (body != nil ? " body" : ""))
        if let title { issues[number]?.title = title }
        if let body { issues[number]?.body = body }
        issues[number]?.updatedAt = tick()
    }

    func setState(repo _: String, number: Int, open: Bool) async throws {
        try await write("\(open ? "reopen" : "close") #\(number)")
        issues[number]?.open = open
        issues[number]?.updatedAt = tick()
    }

    func addSubIssue(repo _: String, parent: Int, child: Int64) async throws {
        guard let number = issues.values.first(where: { $0.id == child })?.number else {
            throw GitHub.Failure(description: "HTTP 404")
        }
        try await write("attach #\(number) to #\(parent)")
        issues[number]?.parent = parent
    }

    func comment(repo _: String, number: Int, body: String) async throws {
        try await write("comment #\(number): \(body)")
        nextComment += 1
        let at = tick()
        issues[number]?.comments.append(RemoteComment(
            id: nextComment, author: "you", body: body + "\n\n" + MirrorMarker.comment, at: at
        ))
        issues[number]?.updatedAt = at
    }

    func updated(repo _: String, since: Date) async throws -> [RemoteIssue] {
        calls.append("GET issues")
        return issues.values.filter { $0.updatedAt >= since }.map(remote)
    }

    func comments(repo _: String, number: Int, since: Date?) async throws -> [RemoteComment] {
        calls.append("GET comments #\(number)")
        return (issues[number]?.comments ?? []).filter { $0.at >= (since ?? .distantPast) }
    }
}

/// A goal with a GOAL.md, two items and a PR, on an in-memory store; `acme/planning` its tracker.
private func goal(mirror: Bool = true) async throws -> (GoalOps, String) {
    let ops = try GoalOps.inMemory()
    let goal = try await ops.create(title: "Faster builds", statement: "Builds take under a minute.", now: now)
    var doc = try await GoalDoc.parse(ops.text(of: goal.id))
    doc.notTheGoal = ["remote caching"]
    doc.doneWhen = [
        GoalDoc.Criterion("a clean build under 60s", met: true, evidence: "acme/api#7"),
        GoalDoc.Criterion("CI uses it"),
    ]
    doc.decisions = [GoalDoc.Decision("cache per branch", source: "you")]
    doc.openQuestions = ["what about Linux?"]
    try await ops.save(goal: goal.id, doc: doc, note: "filled in", now: now)
    try await ops.addItem(goal: goal.id, title: "Cache the module graph", source: .planner, now: now)
    try await ops.addItem(
        goal: goal.id, title: "Parallel linking", source: .you, links: [GoalItem.Link(.pr, "acme/api#9")], now: now + 1
    )
    try await ops.setTracker(goal: goal.id, repo: "acme/planning", now: now)
    if mirror { try await ops.setMirror(goal: goal.id, on: true) }
    return (ops, goal.id)
}

struct GoalMirrorRenderTests {
    @Test func theMetaIssueSaysTheGoalItsBarsAndItsPullsAndCarriesItsMarker() async throws {
        let (ops, id) = try await goal()
        let snapshot = try await ops.snapshot()
        let goal = try #require(snapshot.goal(id))
        let lenses = [GoalScore.Lens(lens: .code, bar: 7, score: 7.5), GoalScore.Lens(lens: .docs, bar: 6, score: nil)]
        let specs = try GoalMirrorRender.specs(
            goal: goal, doc: #require(snapshot.docs[id]), snapshot: snapshot, lenses: lenses,
            requiredLenses: Stage.lenses
        )
        let meta = try #require(specs.first)
        #expect(meta.key == .meta && meta.title == "Faster builds" && meta.open)
        for line in [
            "## Goal", "Builds take under a minute.", "- remote caching",
            "- [x] a clean build under 60s (evidence: acme/api#7)", "- [ ] CI uses it",
            "- cache per branch (source: you)", "- what about Linux?", "| code review | 7 | 7.5 ✓ |",
            "| docs | 6 | – |",
            "- acme/api#9", "Maintained by heed", "<!-- heed:goal faster-builds -->",
        ] {
            #expect(meta.body.contains(line), "meta body lacks \(line)")
        }
        #expect(specs.count == 3)
        #expect(specs[1].key == .item("faster-builds/cache-the-module-graph") && specs[1].open)
        #expect(specs[1].body.contains("<!-- heed:item faster-builds/cache-the-module-graph -->"))
        #expect(specs[2].body.contains("- acme/api#9"))
        // The same goal renders the same text.
        let again = try GoalMirrorRender.specs(
            goal: goal, doc: #require(snapshot.docs[id]), snapshot: snapshot, lenses: lenses,
            requiredLenses: Stage.lenses
        )
        #expect(again == specs)
    }

    @Test func anItemInDoneIsClosedWithItsEvidence() {
        let goal = HeedGoal(id: "g", title: "G", createdAt: now)
        let item = GoalItem(id: "g/a", goal: "g", title: "A", source: .you, createdAt: now)
        let merged = GoalEvidence(goal: "g", item: "g/a", kind: .merged, at: now, source: "pr", ref: "acme/api#3")
        let spec = GoalMirrorRender.item(item, goal: goal, column: .done, marks: [:], evidence: [merged])
        #expect(!spec.open && spec.closing == "Done in heed: merged acme/api#3.")
        let open = GoalMirrorRender.item(item, goal: goal, column: .verify, marks: [:], evidence: [])
        #expect(open.open && open.reopening.contains("Verify"))
    }

    @Test func aDoneOrArchivedGoalClosesItsMetaIssue() {
        let doc = GoalDoc(title: "G")
        #expect(!GoalMirrorRender.meta(
            goal: HeedGoal(id: "g", title: "G", status: .done, createdAt: now),
            doc: doc,
            lenses: [],
            pulls: []
        ).open)
        #expect(!GoalMirrorRender.meta(
            goal: HeedGoal(id: "g", title: "G", status: .archived, createdAt: now),
            doc: doc,
            lenses: [],
            pulls: []
        ).open)
    }

    @Test func markersNameTheGoalAndItemTheyAreFor() {
        #expect(MirrorMarker.key(in: "x\n<!-- heed:goal g -->", goal: "g") == .meta)
        #expect(MirrorMarker.key(in: "<!-- heed:item g/a-b -->", goal: "g") == .item("g/a-b"))
        #expect(MirrorMarker.key(in: "<!-- heed:goal g2 -->", goal: "g") == nil)
        #expect(MirrorMarker.key(in: "<!-- heed:item g2/a -->", goal: "g") == nil)
        #expect(MirrorMarker.key(in: "heed g", goal: "g") == nil)
        #expect(MirrorDigest.of("a") == MirrorDigest.of("a") && MirrorDigest.of("a") != MirrorDigest.of("b"))
        #expect(MirrorDigest.of("hello") == "a430d84680aabd0b")
    }
}

struct GoalMirrorPlanTests {
    private func spec(_ key: MirrorKey, _ title: String = "T", body: String = "B", open: Bool = true) -> MirrorSpec {
        MirrorSpec(key: key, title: title, body: body, open: open, closing: "closed", reopening: "reopened")
    }

    private func issue(
        _ number: Int,
        title: String = "T",
        body: String = "B",
        open: Bool = true,
        attached: Bool = true
    ) -> MirroredIssue {
        MirroredIssue(
            number: number,
            id: Int64(number * 10),
            title: title,
            body: MirrorDigest.of(body),
            open: open,
            attached: attached
        )
    }

    @Test func theMetaIssueComesFirstAndItemsWaitForIt() {
        let specs = [spec(.meta), spec(.item("g/a")), spec(.item("g/b"))]
        #expect(GoalMirrorPlan.writes(specs, state: GoalMirrorState(on: true)) == [
            .create(.meta, title: "T", body: "B"),
        ])
        var state = GoalMirrorState(on: true, meta: issue(1))
        #expect(GoalMirrorPlan.writes(specs, state: state).map(\.line) == ["create item g/a", "create item g/b"])
        state.items["g/a"] = issue(2, attached: false)
        #expect(GoalMirrorPlan.writes(specs, state: state).map(\.line) == ["create item g/b", "attach item g/a to #1"])
        #expect(GoalMirrorPlan.writes(specs, state: state).last == .attach(item: "g/a", parent: 1, child: 20))
    }

    @Test func nothingNewIsNoWrite() {
        let state = GoalMirrorState(on: true, meta: issue(1), items: ["g/a": issue(2)])
        #expect(GoalMirrorPlan.writes([spec(.meta), spec(.item("g/a"))], state: state).isEmpty)
    }

    @Test func onlyWhatChangedIsWritten() {
        let state = GoalMirrorState(on: true, meta: issue(1), items: ["g/a": issue(2)])
        #expect(GoalMirrorPlan.writes([spec(.meta, "New"), spec(.item("g/a"))], state: state) == [
            .edit(.meta, number: 1, title: "New", body: nil),
        ])
        #expect(GoalMirrorPlan.writes([spec(.meta), spec(.item("g/a"), body: "C")], state: state) == [
            .edit(.item("g/a"), number: 2, title: nil, body: "C"),
        ])
    }

    @Test func itemsCloseAndReopenWithTheirStage() {
        let state = GoalMirrorState(on: true, meta: issue(1), items: ["g/a": issue(2), "g/b": issue(3, open: false)])
        let writes = GoalMirrorPlan.writes(
            [spec(.meta), spec(.item("g/a"), open: false), spec(.item("g/b"))], state: state
        )
        #expect(writes == [
            .close(.item("g/a"), number: 2, comment: "closed"), .reopen(.item("g/b"), number: 3, comment: "reopened"),
        ])
    }

    @Test func anItemAColleagueChangedWaitsForYourAnswer() {
        var state = GoalMirrorState(on: true, meta: issue(1), items: ["g/a": issue(2, open: false)])
        state.asks = [MirrorAsk(item: "g/a", issue: 2, kind: .done, at: now)]
        #expect(GoalMirrorPlan.writes([spec(.meta), spec(.item("g/a"))], state: state).isEmpty)
        // Its text still follows the goal.
        #expect(GoalMirrorPlan.writes([spec(.meta), spec(.item("g/a"), "U")], state: state).map(\.line)
            == ["edit item g/a #2 title"])
    }

    @Test func aWriteMadeIsNotMadeAgain() {
        let specs = [spec(.meta), spec(.item("g/a"), open: false)]
        var state = GoalMirrorState(on: true)
        var made = 0
        // Bounded: a plan that repeats itself fails here instead of hanging.
        for _ in 0 ..< 10 {
            guard let write = GoalMirrorPlan.writes(specs, state: state).first else { break }
            made += 1
            let remote: RemoteIssue? = if case .create = write { RemoteIssue(number: made, id: Int64(made)) } else {
                nil
            }
            state = state.applied(write, made: remote)
        }
        // meta, item, attach, close.
        #expect(made == 4)
        #expect(state.items["g/a"]?.attached == true && state.items["g/a"]?.open == false)
    }

    @Test func issuesFoundByTheirMarkersAreTakenBackNotMadeAgain() {
        let found = [
            RemoteIssue(number: 4, id: 40, title: "G", body: "<!-- heed:goal g -->"),
            RemoteIssue(number: 5, id: 50, title: "A", body: "<!-- heed:item g/a -->", open: false, parent: 4),
            RemoteIssue(number: 6, id: 60, title: "Other", body: "<!-- heed:goal other -->"),
            RemoteIssue(number: 7, id: 70, title: "Plain", body: "heed g"),
        ]
        let state = GoalMirrorState(on: true).adopting(found, goal: "g")
        #expect(state.meta?.number == 4 && state.items.keys.sorted() == ["g/a"])
        #expect(state.items["g/a"]?.attached == true && state.items["g/a"]?.open == false)
        // Taken back, the body is written over once; nothing is created.
        let writes = GoalMirrorPlan.writes([spec(.meta), spec(.item("g/a"), open: false)], state: state)
        #expect(writes.map(\.line) == ["edit meta #4 title body", "edit item g/a #5 title body"])
    }
}

struct GoalMirrorSyncTests {
    @Test func aSyncMakesTheMetaIssueAndASubIssuePerItemThenNothing() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        let state = await sync.sync(goal: id, labels: ["heed-goal"], now: now)
        #expect(state.error == nil && state.pending == 0 && state.syncedAt == now)
        #expect(await tracker.calls == [
            "GET search faster-builds", "create Faster builds", "create Cache the module graph",
            "create Parallel linking", "attach #2 to #1", "attach #3 to #1",
        ])
        let issues = await tracker.issues
        #expect(issues[1]?.body.contains("<!-- heed:goal faster-builds -->") == true)
        #expect(issues[2]?.parent == 1 && issues[3]?.parent == 1 && issues[2]?.labels == ["heed-goal"])
        // The numbers are where the views read them.
        let snapshot = try await ops.snapshot()
        #expect(snapshot.goal(id)?.tracker == GoalTracker(repo: "acme/planning", metaIssue: 1))
        #expect(snapshot.items(of: id).map(\.issueNumber) == [2, 3])
        // Again with nothing new: no write at all, not even a search.
        await tracker.clearCalls()
        await sync.sync(goal: id, now: now + 60)
        #expect(await tracker.calls.isEmpty)
    }

    @Test func twoSyncsAtOnceMakeEachIssueOnce() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        async let first = sync.sync(goal: id, now: now)
        async let second = sync.sync(goal: id, now: now)
        _ = await (first, second)
        await sync.sync(goal: id, now: now + 60)
        #expect(await tracker.issues.count == 3)
    }

    @Test func anAnswerGivenDuringASyncIsKept() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        await sync.sync(goal: id, now: now)
        await tracker.colleague(close: 2)
        _ = await sync.poll(goal: id, now: now + 600)
        // The goal changes, and while the sync writes that, the ask is answered no.
        try await ops.propose(
            GoalEdit(goal: id, section: .decisions, op: .add, text: "x", from: "you", at: now), now: now + 610
        )
        let item = "\(id)/cache-the-module-graph"
        await tracker.set(during: { try await ops.answer(ask: item, yes: false, now: now + 620) })
        await sync.sync(goal: id, now: now + 620)
        #expect(try await ops.mirror(of: id).asks.isEmpty)
        await sync.sync(goal: id, now: now + 700)
        #expect(await tracker.issues[2]?.open == true)
    }

    @Test func offWritesNothing() async throws {
        let (ops, id) = try await goal(mirror: false)
        let tracker = FakeTracker()
        let state = await GoalMirrorSync(ops: ops, github: tracker, limits: .tests).sync(goal: id, now: now)
        let calls = await tracker.calls
        #expect(!state.on && calls.isEmpty)
        await #expect(throws: GoalMirrorError.noTracker("x")) {
            let ops = try GoalOps.inMemory()
            try await ops.create(title: "x", statement: "", now: now)
            try await ops.setMirror(goal: "x", on: true)
        }
    }

    @Test func aLostStateFindsItsIssuesByMarkerAndMakesNoneTwice() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        await GoalMirrorSync(ops: ops, github: tracker, limits: .tests).sync(goal: id, now: now)
        // The state is gone (a new Mac, a restored store): mirroring is on again, from nothing.
        try await ops.save(mirror: GoalMirrorState(on: true, repo: "acme/planning"), goal: id)
        await tracker.clearCalls()
        let state = await GoalMirrorSync(ops: ops, github: tracker, limits: .tests).sync(goal: id, now: now + 60)
        #expect(await tracker.issues.count == 3)
        #expect(await tracker.calls.allSatisfy { !$0.hasPrefix("create") && !$0.hasPrefix("attach") })
        #expect(state.meta?.number == 1 && state.items.count == 2 && state.error == nil)
    }

    @Test func aFullBatchLeavesTheRestForTheNextSync() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: MirrorLimits(writesPerSync: 2, pause: .zero))
        let first = await sync.sync(goal: id, now: now)
        var count = await tracker.writeCount
        #expect(count == 2 && first.pending == 2 && first.syncedAt == nil)
        let second = await sync.sync(goal: id, now: now + 60)
        count = await tracker.writeCount
        #expect(second.pending == 1 && count == 4)
        let third = await sync.sync(goal: id, now: now + 120)
        count = await tracker.writeCount
        #expect(third.pending == 0 && third.syncedAt == now + 120 && count == 5)
    }

    @Test func aFailedWriteKeepsWhatWentThroughAndSaysWhy() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        await tracker.set(failAfterWrites: 2)
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        let state = await sync.sync(goal: id, now: now)
        #expect(state.error == "HTTP 502" && state.meta?.number == 1 && state.items.count == 1)
        await tracker.set(failAfterWrites: nil)
        let after = await sync.sync(goal: id, now: now + 60)
        let issues = await tracker.issues
        #expect(after.error == nil && issues.count == 3)
    }

    @Test func doneItemsCloseWithTheirEvidenceAndEditsFollowTheGoal() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        await sync.sync(goal: id, now: now)
        await tracker.clearCalls()
        try await ops.addEvidence(GoalEvidence(
            goal: id, item: "\(id)/parallel-linking", kind: .merged, at: now + 10, source: "pr", ref: "acme/api#9"
        ))
        try await ops.propose(
            GoalEdit(goal: id, section: .decisions, op: .add, text: "link in parallel", from: "you", at: now),
            now: now + 20
        )
        await sync.sync(goal: id, now: now + 60)
        let calls = await tracker.calls
        #expect(calls == [
            "edit #1 body", "edit #3 body", "comment #3: Done in heed: merged acme/api#9.", "close #3",
        ])
        let issues = await tracker.issues
        #expect(issues[3]?.open == false && issues[1]?.body.contains("- link in parallel") == true)
    }

    @Test func aNewTrackerStartsOverThere() async throws {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        await sync.sync(goal: id, now: now)
        try await ops.setTracker(goal: id, repo: "acme/roadmap", now: now)
        let state = try await ops.mirror(of: id)
        #expect(state.on && state.repo == "acme/roadmap" && state.meta == nil && state.items.isEmpty)
        #expect(try await ops.snapshot().items(of: id).allSatisfy { $0.issueNumber == nil })
    }
}

struct GoalMirrorBackTests {
    private func synced() async throws -> (GoalOps, String, FakeTracker, GoalMirrorSync) {
        let (ops, id) = try await goal()
        let tracker = FakeTracker()
        let sync = GoalMirrorSync(ops: ops, github: tracker, limits: .tests)
        await sync.sync(goal: id, now: now)
        return (ops, id, tracker, sync)
    }

    @Test func aColleagueClosingASubIssueAsksWhetherTheItemIsDone() async throws {
        let (ops, id, tracker, sync) = try await synced()
        await tracker.colleague(close: 2)
        _ = await sync.poll(goal: id, now: now + 600)
        let state = try await ops.mirror(of: id)
        #expect(state.asks.map(\.kind) == [.done] && state.asks.first?.item == "\(id)/cache-the-module-graph")
        // Nothing changed on the goal by itself, and the sync leaves the sub-issue as the colleague left it.
        #expect(try await ops.snapshot().item("\(id)/cache-the-module-graph")?.placement == nil)
        await tracker.clearCalls()
        await sync.sync(goal: id, now: now + 700)
        #expect(await tracker.calls.isEmpty)
        // Asked again on the next poll: still one ask.
        _ = await sync.poll(goal: id, now: now + 800)
        #expect(try await ops.mirror(of: id).asks.count == 1)
    }

    @Test func yesMovesTheItemNoPutsTheSubIssueBack() async throws {
        let (ops, id, tracker, sync) = try await synced()
        await tracker.colleague(close: 2)
        await tracker.colleague(close: 3)
        _ = await sync.poll(goal: id, now: now + 600)
        try await ops.answer(ask: "\(id)/cache-the-module-graph", yes: true, now: now + 700)
        try await ops.answer(ask: "\(id)/parallel-linking", yes: false, now: now + 700)
        #expect(try await ops.snapshot().item("\(id)/cache-the-module-graph")?.placement?.column == .done)
        await tracker.clearCalls()
        await sync.sync(goal: id, now: now + 800)
        let calls = await tracker.calls
        #expect(calls.contains("reopen #3") && !calls.contains("reopen #2") && !calls.contains("close #2"))
        #expect(try await ops.mirror(of: id).asks.isEmpty)
    }

    @Test func reopeningADoneItemsSubIssueAsksWhetherItIsNotDone() async throws {
        let (ops, id, tracker, sync) = try await synced()
        try await ops.done(item: "\(id)/parallel-linking", now: now + 10)
        await sync.sync(goal: id, now: now + 60)
        #expect(await tracker.issues[3]?.open == false)
        await tracker.colleague(reopen: 3)
        _ = await sync.poll(goal: id, now: now + 600)
        #expect(try await ops.mirror(of: id).asks.map(\.kind) == [.reopen])
        try await ops.answer(ask: "\(id)/parallel-linking", yes: true, now: now + 700)
        let snapshot = try await ops.snapshot()
        let item = try #require(snapshot.item("\(id)/parallel-linking"))
        #expect(Board.column(item, evidence: snapshot.evidence) == .working)
    }

    @Test func commentsOnTheMetaIssueComeBackForTheProposerOnce() async throws {
        let (ops, id, tracker, sync) = try await synced()
        await tracker.colleague(comment: "Should this cover Windows?", on: 1)
        let poll = try #require(await sync.poll(goal: id, now: now + 600))
        #expect(poll.comments.map(\.body) == ["Should this cover Windows?"] && poll.issue == "acme/planning#1")
        // Not read yet (no budget today): asked again.
        #expect(await sync.poll(goal: id, now: now + 700)?.comments.count == 1)
        try await sync.read(comments: #require(poll.through), goal: id)
        #expect(await sync.poll(goal: id, now: now + 800) == nil)
        // heed's own comments are not read back.
        try await ops.done(item: "\(id)/parallel-linking", now: now + 900)
        await sync.sync(goal: id, now: now + 900)
        #expect(await sync.poll(goal: id, now: now + 1000) == nil)
    }

    @Test func heedsOwnCommentsOnTheMetaIssueAreNotReadBack() async throws {
        let (ops, id, tracker, sync) = try await synced()
        _ = try await ops.archive(goal: id, now: now + 60)
        await sync.sync(goal: id, now: now + 60)
        let meta = await tracker.issues[1]
        #expect(meta?.open == false && meta?.comments.count == 1)
        #expect(await sync.poll(goal: id, now: now + 600) == nil)
        #expect(GoalMirrorBack.fresh([
            RemoteComment(id: 3, author: "you", body: "x\n\n" + MirrorMarker.comment, at: now),
            RemoteComment(id: 2, author: "sam", body: "b", at: now),
            RemoteComment(id: 1, author: "sam", body: "a", at: now),
        ], after: 1).map(\.id) == [2])
    }

    @Test func aCommentProposesOnlyQuestionsAndDecisionsAndEachWaits() {
        let edits = [
            GoalEdit(goal: "g", section: .decisions, op: .add, text: "ship on Linux first", from: "x", at: now),
            GoalEdit(goal: "g", section: .openQuestions, op: .add, text: "Windows?", from: "x", at: now),
            GoalEdit(goal: "g", section: .notTheGoal, op: .add, text: "mobile", from: "x", at: now),
            GoalEdit(goal: "g", section: .openQuestions, op: .remove, text: "Linux?", from: "x", at: now),
        ]
        let kept = GoalMirrorBack.proposals(edits)
        #expect(kept.map(\.text) == ["ship on Linux first", "Windows?"])
        #expect(kept.allSatisfy { $0.kind == .scope })
    }

    @Test func aProposedCommentWaitsInGoalMD() async throws {
        let (ops, id) = try await goal()
        let before = try await ops.text(of: id)
        let edit = GoalMirrorBack.proposals([
            GoalEdit(goal: id, section: .decisions, op: .add, text: "ship on Linux first", from: "@sam", at: now),
        ])[0]
        let proposed = try await ops.propose(edit, now: now)
        #expect(proposed.state == .proposed && proposed.kind == .scope)
        #expect(try await ops.text(of: id) == before)
    }
}

struct TrackerCheckTests {
    @Test func aTrackerNeedsIssuesAndTriage() {
        #expect(TrackerCheck.from(repo: "a/b", found: true, hasIssues: true, archived: false, permission: "TRIAGE").ok)
        #expect(TrackerCheck.from(repo: "a/b", found: true, hasIssues: true, archived: false, permission: "ADMIN").ok)
        #expect(!TrackerCheck.from(repo: "a/b", found: true, hasIssues: true, archived: false, permission: "READ").ok)
        #expect(!TrackerCheck.from(repo: "a/b", found: false, hasIssues: false, archived: false, permission: nil).ok)
        #expect(!TrackerCheck.from(repo: "a/b", found: true, hasIssues: false, archived: false, permission: "WRITE").ok)
        #expect(!TrackerCheck.from(repo: "a/b", found: true, hasIssues: true, archived: true, permission: "WRITE").ok)
        #expect(TrackerCheck.slug(" acme/planning ") == "acme/planning")
        for bad in ["acme", "acme/", "/x", "a/b/c", "a b/c", ""] {
            #expect(TrackerCheck.slug(bad) == nil, "\(bad)")
        }
    }

    @Test func theCheckReadsGitHubsAnswer() {
        let data = Data("""
        {"data":{"repository":{"nameWithOwner":"acme/planning","hasIssuesEnabled":true,"isArchived":false,
        "viewerPermission":"READ"}}}
        """.utf8)
        #expect(GitHubMirror.parseCheck(data, repo: "acme/planning").problem?.contains("triage") == true)
        #expect(GitHubMirror.parseCheck(Data(#"{"data":{"repository":null}}"#.utf8), repo: "a/b").ok == false)
    }
}

/// The gh adapter: argument shapes as GitHub's REST docs give them, and a `github` row per call, writes as writes.
struct GitHubMirrorTests {
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("heed-mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A gh stand-in: appends its arguments (one per line, then `--`) and answers like the REST API.
    private func fakeGh(in dir: URL) throws -> (path: String, args: URL) {
        let args = dir.appendingPathComponent("args")
        let script = dir.appendingPathComponent("gh")
        try """
        #!/bin/sh
        printf '%s\\n' "$@" -- >> '\(args.path)'
        case "$*" in
          *search/issues*) echo '{"total_count":1,"items":[{"number":4,"id":40,"title":"G","state":"open","body":"<!-- heed:goal g -->","updated_at":"2026-10-26T10:00:00Z","parent_issue_url":null}]}' ;;
          *"POST repos/acme/planning/issues "*|*"POST repos/acme/planning/issues"*) echo '{"number":12,"id":3000000012,"title":"T","state":"open","updated_at":"2026-10-26T10:00:00Z"}' ;;
          *comments*) echo '[{"id":7,"user":{"login":"sam"},"body":"hi","created_at":"2026-10-26T10:00:00Z"}]' ;;
          *) echo '[{"number":5,"id":50,"title":"A","state":"closed","updated_at":"2026-10-26T10:00:00Z","parent_issue_url":"https://api.github.com/repos/acme/planning/issues/4"},{"number":6,"id":60,"state":"open","pull_request":{}}]' ;;
        esac
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script.path, args)
    }

    @Test func everyCallIsAGitHubRowAndWritesAreWrites() async throws {
        let dir = try folder()
        let gh = try fakeGh(in: dir)
        let log = try CallLog(
            store: CallStore(path: dir.appendingPathComponent("log.sqlite").path),
            delay: .seconds(60)
        )
        let mirror = GitHubMirror()
        let (made, found, updated, comments) = try await CallLog.$current.withValue(log) {
            try await GitHub.$executable.withValue(gh.path) {
                let made = try await mirror.create(
                    repo: "acme/planning",
                    title: "T",
                    body: "secret body",
                    labels: ["heed-goal"]
                )
                try await mirror.edit(repo: "acme/planning", number: 12, title: nil, body: "new body")
                try await mirror.setState(repo: "acme/planning", number: 12, open: false)
                try await mirror.addSubIssue(repo: "acme/planning", parent: 4, child: 3_000_000_012)
                try await mirror.comment(repo: "acme/planning", number: 12, body: "Done")
                let found = try await mirror.marked(repo: "acme/planning", goal: "g")
                let updated = try await mirror.updated(repo: "acme/planning", since: now)
                let comments = try await mirror.comments(repo: "acme/planning", number: 4, since: nil)
                return (made, found, updated, comments)
            }
        }
        #expect(made.number == 12 && made.id == 3_000_000_012)
        #expect(found.map(\.number) == [4] && found.first?.body == "<!-- heed:goal g -->")
        // Pull requests the issues API lists are left out; the parent comes from parent_issue_url.
        #expect(updated.map(\.number) == [5] && updated.first?.parent == 4 && updated.first?.open == false)
        #expect(comments.map(\.author) == ["sam"])
        await log.flush()
        let calls = try await log.store.calls(CallFilter())
        #expect(calls.count == 8 && calls.allSatisfy { $0.kind == .github && $0.caller == "goals.mirror" })
        #expect(calls.count(where: \.write) == 5)
        // Bodies stay out of the log.
        #expect(calls.allSatisfy { !$0.command.contains("secret body") && !$0.command.contains("new body") })
        let sent = try String(contentsOf: gh.args, encoding: .utf8).components(separatedBy: "--\n")
        #expect(sent[0]
            .contains(
                "-X\nPOST\nrepos/acme/planning/issues\n-f\ntitle=T\n-f\nlabels[]=heed-goal\n-f\nbody=secret body"
            ))
        #expect(sent[2].contains("PATCH\nrepos/acme/planning/issues/12\n-f\nstate=closed\n-f\nstate_reason=completed"))
        // sub_issue_id is the issue's id, typed.
        #expect(sent[3].contains("POST\nrepos/acme/planning/issues/4/sub_issues\n-F\nsub_issue_id=3000000012"))
        #expect(sent[4].contains("body=Done\n\n<!-- heed -->"))
        #expect(sent[5].contains("GET\nsearch/issues\n-f\nq=repo:acme/planning is:issue in:body heed \"g\""))
        #expect(sent[6].contains("since=2027-01-15T08:00:00Z"))
    }
}

struct GoalMirrorSettingsTests {
    @Test func aNewGoalsTrackerIsTheReposThenTheOrgsThenTheDefault() throws {
        let config = try #require(ConfigLoader.decode("""
        [goals]
        tracker = "acme/planning"
        mirror_label = "heed-goal"

        [orgs.beta]
        goals_tracker = "beta/roadmap"
        goals_mirror = true

        [repos."beta/site"]
        goals_tracker = "beta/site-plans"
        goals_mirror = false
        """).config)
        let mirror = config.goals.mirror
        #expect(mirror.tracker(for: "acme/api") == "acme/planning")
        #expect(mirror.tracker(for: "beta/api") == "beta/roadmap")
        #expect(mirror.tracker(for: "beta/site") == "beta/site-plans")
        #expect(mirror.tracker(for: nil) == "acme/planning")
        #expect(!mirror.mirrors(for: "acme/api") && mirror.mirrors(for: "beta/api") && !mirror
            .mirrors(for: "beta/site"))
        #expect(mirror.labels == ["heed-goal"])
        // Off and trackerless by default.
        let plain = try #require(ConfigLoader.decode("").config).goals.mirror
        #expect(plain.tracker(for: "acme/api") == nil && !plain.mirrors(for: nil) && plain.labels.isEmpty)
    }

    @Test func theMirrorsTableComesWithTheStore() throws {
        let store = try GoalStore(path: ":memory:")
        #expect(try store.schemaVersion == GoalStore.schema.count)
        #expect(try store.mirror(of: "x") == nil)
    }
}
