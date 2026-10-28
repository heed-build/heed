import Foundation
@testable import HeedCore
import Synchronization
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func item(
    _ slug: String, kind: GoalItem.Kind = .work, source: GoalItem.Source = .session, links: [GoalItem.Link] = [],
    placement: GoalItem.Placement? = nil
) -> GoalItem {
    GoalItem(
        id: "g/\(slug)", goal: "g", title: slug, kind: kind, source: source, links: links, placement: placement,
        createdAt: now
    )
}

private func evidence(
    _ slug: String, _ kind: GoalEvidence.Kind, _ state: GoalEvidence.State = .done, minutes: Double = 0,
    id: Int64? = nil
) -> GoalEvidence {
    GoalEvidence(id: id, goal: "g", item: "g/\(slug)", kind: kind, state: state, at: now + minutes * 60, source: "test")
}

struct StagesTests {
    @Test func theNewestEvidenceOfAKindDecidesItsStage() {
        let marks = Stages.of(item("a"), evidence: [
            evidence("a", .codeReview, .issue, minutes: 1),
            evidence("a", .codeReview, .done, minutes: 2),
            evidence("a", .perf, .done, minutes: 1),
            evidence("a", .perf, .issue, minutes: 3),
            evidence("a", .dx, .inProgress),
            evidence("b", .built),
        ])
        #expect(marks[.codeReview] == .done)
        #expect(marks[.perf] == .issue)
        #expect(marks[.dx] == .inProgress)
        // Another item's evidence is not this one's.
        #expect(marks[.built] == .notYet && marks[.plan] == .notYet && marks[.merged] == .notYet)
    }

    @Test func atTheSameMomentTheOneStoredLaterWins() {
        let marks = Stages.of(item("a"), evidence: [
            evidence("a", .perf, .done, id: 2), evidence("a", .perf, .issue, id: 1),
        ])
        #expect(marks[.perf] == .done)
    }

    @Test func laterStagesImplyTheOnesBeforeThem() {
        let merged = Stages.of(item("a"), evidence: [evidence("a", .merged)])
        #expect(merged[.pr] == .done && merged[.built] == .done && merged[.merged] == .done)
        let draft = Stages.of(item("a"), evidence: [evidence("a", .pr, .inProgress)])
        #expect(draft[.pr] == .inProgress && draft[.built] == .done)
        // A build that is broken stays broken, PR or not.
        let broken = Stages.of(item("a"), evidence: [evidence("a", .pr), evidence("a", .built, .issue)])
        #expect(broken[.built] == .issue)
        #expect(Stages.of(item("p", source: .planner), evidence: [])[.plan] == .done)
        #expect(Stages.of(item("s", source: .swarm), evidence: [])[.plan] == .done)
        #expect(Stages.of(item("y", source: .you), evidence: [])[.plan] == .notYet)
    }

    @Test func lensesTheGoalDoesNotNeedAreNotApplicable() {
        let marks = Stages.of(
            item("a"), evidence: [evidence("a", .perf, .issue), evidence("a", .codeReview)],
            requiredLenses: [.codeReview]
        )
        #expect(marks[.perf] == .notApplicable && marks[.dx] == .notApplicable && marks[.planReview] == .notApplicable)
        #expect(marks[.codeReview] == .done)
        // Only lenses can be n/a: the plan, the build, the PR and the merge always count.
        let none = Stages.of(item("a"), evidence: [], requiredLenses: [])
        #expect([Stage.plan, .built, .pr, .merged].allSatisfy { none[$0] == .notYet })
        #expect(Stage.allCases.map { StageMark.done.glyph + $0.title }.count == 8)
        #expect(StageMark.allCases.map(\.glyph) == ["✓", "◐", "!", "○", "·"])
    }
}

struct BoardTests {
    @Test func evidenceDecidesTheColumn() {
        #expect(Board.column(item("q", kind: .question), evidence: []) == .toExplore)
        #expect(Board.column(item("q", kind: .question), evidence: [evidence("q", .decision)]) == .done)
        #expect(Board
            .column(item("q", kind: .question), evidence: [evidence("q", .decision, .inProgress)]) == .toExplore)
        #expect(Board.column(item("found"), evidence: []) == .toExplore)
        #expect(Board.column(item("mine", source: .you), evidence: []) == .planned)
        #expect(Board.column(item("raised", source: .reviewer), evidence: []) == .planned)
        #expect(Board.column(item("p", source: .planner), evidence: []) == .planned)
        #expect(Board.column(item("p", source: .planner), evidence: [evidence("p", .built, .inProgress)]) == .working)
        #expect(Board.column(item("s", links: [GoalItem.Link(.session, "s1")]), evidence: []) == .working)
        #expect(Board.column(item("b"), evidence: [evidence("b", .built)]) == .working)
        #expect(Board
            .column(item("b"), evidence: [evidence("b", .built), evidence("b", .perf, .inProgress)]) == .verify)
        #expect(Board.column(item("r"), evidence: [evidence("r", .codeReview)]) == .planned.step(-1))
        #expect(Board.column(item("pr"), evidence: [evidence("pr", .pr, .issue)]) == .verify)
        #expect(Board.column(item("m"), evidence: [evidence("m", .pr), evidence("m", .merged)]) == .done)
    }

    @Test func aCardMovedByHandStaysUntilNewerEvidence() {
        let moved = item("a", source: .planner, placement: GoalItem.Placement(.verify, at: now + 60))
        #expect(Board.column(moved, evidence: []) == .verify)
        // Evidence from before the move does not move it back.
        #expect(Board.column(moved, evidence: [evidence("a", .built, .inProgress, minutes: 0)]) == .verify)
        // Evidence at the same moment does not either; newer evidence does.
        #expect(Board.column(moved, evidence: [evidence("a", .built, .inProgress, minutes: 1)]) == .verify)
        #expect(Board.column(moved, evidence: [evidence("a", .built, .inProgress, minutes: 2)]) == .working)
        // Another item's evidence does not count.
        #expect(Board.column(moved, evidence: [evidence("b", .merged, minutes: 9)]) == .verify)
    }

    @Test func columnsKeepTheOrderItemsCameIn() {
        var second = item("second", source: .you)
        second.createdAt = now + 5
        let columns = Board.columns([second, item("first", source: .you)], evidence: [])
        #expect(columns[.planned]?.map(\.slug) == ["first", "second"])
        #expect(Board.Column.allCases.allSatisfy { columns[$0] != nil })
        #expect(Board.Column.toExplore.step(-1) == nil && Board.Column.done.step(1) == nil)
        #expect(Board.Column.working.step(1) == .verify && Board.Column.working.step(-1) == .planned)
    }

    @Test func badgesSayWhatTheCardMostlyIs() {
        #expect(Board.badge(item("q", kind: .question), evidence: [evidence("q", .pr)]) == .question)
        #expect(Board.badge(item("a"), evidence: [evidence("a", .built), evidence("a", .perf, minutes: 1)]) == .bench)
        #expect(Board.badge(item("a"), evidence: [evidence("a", .codeReview)]) == .review)
        #expect(Board.badge(item("a"), evidence: [evidence("a", .merged)]) == .pr)
        #expect(Board.badge(item("a", links: [GoalItem.Link(.pr, "acme/x#1")]), evidence: []) == .pr)
        var planned = item("a", source: .swarm)
        planned.phase = "Build"
        #expect(Board.badge(planned, evidence: []) == .swarm)
        // A swarm item with no phase was dropped from its plan.
        #expect(Board.badge(item("a", source: .swarm), evidence: []) == .dropped)
        #expect(Board.badge(item("a", links: [GoalItem.Link(.session, "s1")]), evidence: []) == .session)
        #expect(Board.badge(item("a", source: .chat), evidence: []) == .chat)
        #expect(Board.badge(item("a", source: .you), evidence: []) == .item)
        #expect(Board.Badge.pr.title == "PR" && Board.Badge.bench.title == "BENCH")
    }

    @Test func aDraggedCardLandsInTheColumnUnderItsMiddle() {
        // Columns 200 wide, 10 apart: the next column starts 210 along.
        #expect(BoardDrag.target(from: 1, by: 0, width: 200, spacing: 10, count: 5) == 1)
        #expect(BoardDrag.target(from: 1, by: 100, width: 200, spacing: 10, count: 5) == 1)
        #expect(BoardDrag.target(from: 1, by: 110, width: 200, spacing: 10, count: 5) == 2)
        #expect(BoardDrag.target(from: 1, by: -110, width: 200, spacing: 10, count: 5) == 0)
        #expect(BoardDrag.target(from: 0, by: -900, width: 200, spacing: 10, count: 5) == 0)
        #expect(BoardDrag.target(from: 3, by: 900, width: 200, spacing: 10, count: 5) == 4)
        #expect(BoardDrag.target(from: 2, by: 420, width: 200, spacing: 10, count: 5) == 4)
        #expect(BoardDrag.target(from: 2, by: 50, width: 0, spacing: 10, count: 5) == 2)
    }
}

struct GoalEditsTests {
    private func edit(
        _ section: GoalEdit.Section, _ op: GoalEdit.Op, _ text: String, target: String? = nil, evidence: String? = nil
    ) -> GoalEdit {
        GoalEdit(
            goal: "g", section: section, op: op, text: text, target: target, evidence: evidence, from: "test", at: now
        )
    }

    private let doc = GoalDoc(
        title: "G", goal: "Quick search.", notTheGoal: ["Hosted search"],
        doneWhen: [GoalDoc.Criterion("p95 query under 200 ms")], openQuestions: ["Which fields need re-indexing?"],
        decisions: [GoalDoc.Decision("Index titles, not bodies", source: "you")]
    )

    @Test func onlyRecordingWhatHappenedAppliesItself() {
        #expect(edit(.decisions, .add, "Ranks live in the index folder").kind == .record)
        #expect(edit(.openQuestions, .remove, "Which fields need re-indexing?").kind == .record)
        #expect(edit(.doneWhen, .check, "p95 query under 200 ms", evidence: "acme/b#3").kind == .record)
        // A criterion ticked with nothing to show for it waits.
        #expect(edit(.doneWhen, .check, "p95 query under 200 ms").kind == .scope)
        #expect(edit(.doneWhen, .check, "p95 query under 200 ms", evidence: "  ").kind == .scope)
        for (section, op) in [
            (GoalEdit.Section.goal, GoalEdit.Op.replace), (.notTheGoal, .add), (.doneWhen, .add),
            (.openQuestions, .add), (.decisions, .remove), (.decisions, .replace), (.doneWhen, .remove),
            (.notTheGoal, .remove),
        ] {
            #expect(edit(section, op, "x").kind == .scope, "\(section) \(op)")
        }
        // What the model calls it does not matter: classify decides.
        let claimed = GoalEdit(goal: "g", section: .notTheGoal, op: .add, text: "x", from: "m", kind: nil, at: now)
        #expect(claimed.kind == .scope)
    }

    @Test func applyMakesTheChangeOnceAndRevertTakesItOut() throws {
        let decided = try #require(GoalEdits.apply(edit(.decisions, .add, "Ranks live in the index folder"), to: doc))
        #expect(decided.decisions.last == GoalDoc.Decision("Ranks live in the index folder", source: "test"))
        #expect(GoalEdits.apply(edit(.decisions, .add, "index titles, not bodies."), to: doc) == nil)
        #expect(GoalEdits.revert(edit(.decisions, .add, "Ranks live in the index folder"), in: decided) == doc)

        let answered = try #require(GoalEdits.apply(
            edit(.openQuestions, .remove, "answered", target: "which fields need re-indexing"), to: doc
        ))
        #expect(answered.openQuestions.isEmpty)
        #expect(GoalEdits.revert(
            edit(.openQuestions, .remove, "x", target: "Which fields need re-indexing?"),
            in: answered
        ) == doc)

        let met = try #require(GoalEdits.apply(
            edit(.doneWhen, .check, "P95 query under 200 ms", evidence: "bench 140 ms"), to: doc
        ))
        #expect(met.doneWhen == [GoalDoc.Criterion("p95 query under 200 ms", met: true, evidence: "bench 140 ms")])
        #expect(GoalEdits.apply(edit(.doneWhen, .check, "p95 query under 200 ms", evidence: "e"), to: met) == nil)
        #expect(GoalEdits.revert(edit(.doneWhen, .check, "p95 query under 200 ms"), in: met) == doc)

        #expect(try #require(GoalEdits.apply(edit(.notTheGoal, .add, "Spelling suggestions"), to: doc)).notTheGoal
            == ["Hosted search", "Spelling suggestions"])
        #expect(GoalEdits.apply(edit(.notTheGoal, .add, "hosted search"), to: doc) == nil)
        #expect(try #require(GoalEdits.apply(edit(.goal, .replace, "Queries answer in 200 ms."), to: doc))
            .goal == "Queries answer in 200 ms.")
        #expect(GoalEdits.apply(edit(.goal, .replace, "Quick search."), to: doc) == nil)
        #expect(try #require(GoalEdits.apply(edit(.doneWhen, .add, "results stay stable across restarts"), to: doc))
            .doneWhen.count == 2)
        #expect(try #require(GoalEdits.apply(
            edit(.decisions, .replace, "Index headings", target: "Index titles, not bodies"), to: doc
        )).decisions[0].text == "Index headings")
        // What it is about is not there: nothing to do.
        #expect(GoalEdits.apply(edit(.openQuestions, .remove, "x", target: "Is it raining?"), to: doc) == nil)
        #expect(GoalEdits.apply(edit(.doneWhen, .check, "nope", evidence: "e"), to: doc) == nil)
        #expect(GoalEdits.revert(edit(.goal, .replace, "x"), in: doc) == nil)
    }

    @Test func linesAndNotesSayWhatChanged() {
        #expect(edit(.notTheGoal, .add, "ranking across languages").line == "+ Not the goal: ranking across languages")
        #expect(edit(.doneWhen, .check, "x", target: "fast", evidence: "#3").line == "✓ Done when: fast (#3)")
        #expect(GoalEdits.note(edit(.decisions, .add, "Ranks live in the index folder"))
            == "decision: Ranks live in the index folder")
        #expect(GoalEdits.note(edit(.openQuestions, .remove, "x", target: "Why?")) == "answered: Why?")
        #expect(GoalEdits.note(edit(.notTheGoal, .add, String(repeating: "a", count: 60))).hasSuffix("…"))
    }
}

struct GoalSourcesTests {
    @Test func plannerLinesBecomeTitles() {
        let answer = """
        Here is the plan:
        - Survey the query paths.
        * Tokenize each field
        1. Store ranks
        - survey the query paths
        - none
        """
        // A sentence before the list reads as a line of its own; a heading-like line ending in a colon does not.
        #expect(GoalPlanner.titles(answer) == ["Survey the query paths", "Tokenize each field", "Store ranks"])
        let titles = GoalPlanner.titles("- a\n- b\n- c\n- d\n- e\n- f\n- g\n- h\n- i\n- j")
        #expect(titles.count == 8 && titles.first == "a")
        let inputs = GoalPlanner.inputs(title: "G", doc: "# G\n", items: [item("existing")])
        #expect(inputs.prompt.contains("## GOAL.md\n# G") && inputs.prompt.contains("## Already known\n- existing"))
    }

    @Test func onlyAScopeChangeAsksThePlannerAgain() {
        let old = GoalDoc(title: "G", goal: "x", doneWhen: [GoalDoc.Criterion("a")])
        var decided = old
        decided.decisions = [GoalDoc.Decision("d")]
        decided.doneWhen[0].met = true
        #expect(!GoalPlanner.scopeChanged(from: old, to: decided))
        var rescoped = old
        rescoped.notTheGoal = ["y"]
        #expect(GoalPlanner.scopeChanged(from: old, to: rescoped))
        #expect(GoalPlanner.scopeChanged(from: nil, to: old))
        var criteria = old
        criteria.doneWhen.append(GoalDoc.Criterion("b"))
        #expect(GoalPlanner.scopeChanged(from: old, to: criteria))
    }

    @Test func titlesAreMatchedByTheirWords() {
        #expect(GoalItemMatch.similarity("Split QueryPlanner", "split the queryplanner") == 1)
        #expect(GoalItemMatch.similarity("Cache tokens", "Latency baseline") == 0)
        let items = [item("Token cache per field"), item("Latency baseline")].map { item -> GoalItem in
            var item = item
            item.title = item.slug
            return item
        }
        #expect(GoalItemMatch.quick("token caches per field", items: items) == .existing(
            item: "g/Token cache per field",
            confidence: 1
        ))
        #expect(GoalItemMatch.quick("Drop the legacy parser", items: items) == .new(confidence: 1))
        #expect(GoalItemMatch.quick("cache the tokens of synonyms", items: items) == nil)
        #expect(GoalItemMatch.quick("anything", items: []) == .new(confidence: 1))
    }

    @Test func closeCallsAskTheDecider() async {
        let items = [GoalItem(
            id: "g/tokens",
            goal: "g",
            title: "Token cache per field",
            source: .planner,
            createdAt: now
        )]
        let title = "cache the tokens of synonyms"
        let same = FakeDecider(["same": Answer(
            choice: "tokens",
            probabilities: ["tokens": 0.8, "new": 0.2],
            confidence: 0.7
        )])
        #expect(await GoalItemMatch.decide(title, items: items, goal: "g", decider: same)
            == .existing(item: "g/tokens", confidence: 0.8))
        let asked = same.states.withLock { $0.first ?? "" }
        #expect(asked.contains("- tokens: Token cache per field"))
        let new = FakeDecider(["same": Answer(
            choice: "new",
            probabilities: ["tokens": 0.1, "new": 0.9],
            confidence: 0.6
        )])
        #expect(await GoalItemMatch.decide(title, items: items, goal: "g", decider: new) == .new(confidence: 0.9))
        // No model, or a failed call: the closest item when it is half alike, else new.
        #expect(await GoalItemMatch.decide(title, items: items, goal: "g", decider: nil) == .new(confidence: 0.5))
        #expect(await GoalItemMatch.decide(
            "token cache per synonym",
            items: items,
            goal: "g",
            decider: FakeDecider(nil)
        )
            == .existing(item: "g/tokens", confidence: 0.6))
        // A sure answer never calls the model.
        let unused = FakeDecider(nil)
        _ = await GoalItemMatch.decide("Token cache per field", items: items, goal: "g", decider: unused)
        let calls = unused.states.withLock(\.count)
        #expect(calls == 0)
    }

    @Test func ledgerFollowUpsAreItemsAndQuestionsAndDecisionsSeparate() {
        var entry = LedgerEntry(id: "s1", title: "Tokenizer trial", startedAt: now)
        entry.followUps = ["Store ranks beside the index", "Do synonyms need their own table?", "none"]
        entry.decisions = ["Index titles, not bodies", " "]
        let found = GoalDiscovery.from(entry)
        #expect(found.items == ["Store ranks beside the index"])
        #expect(found.questions == ["Do synonyms need their own table?"])
        #expect(found.decisions == ["Index titles, not bodies"])
    }

    @Test func proposerAnswersBecomeEdits() {
        let answer = """
        Sure: {"edits": [
          {"section": "notTheGoal", "op": "add", "text": "ranking across languages", "target": null,
           "evidence": "3 of 5 sample queries", "reason": "a separate piece of work", "kind": "record"},
          {"section": "Decisions", "op": "add", "text": "Ranks live in the index folder", "evidence": "chat"},
          {"section": "done_when", "op": "check", "target": "p95 query under 200 ms", "evidence": "140 ms"},
          {"section": "mood", "op": "add", "text": "x"},
          {"section": "decisions", "op": "shout", "text": "x"},
          {"section": "decisions", "op": "add"}
        ]}
        """
        let edits = GoalEditProposer.edits(answer, goal: "g", from: "Tokenizer trial", now: now)
        #expect(edits.map(\.section) == [.notTheGoal, .decisions, .doneWhen])
        #expect(edits.map(\.kind) == [.scope, .record, .record])
        #expect(edits[2].text == "p95 query under 200 ms" && edits[2].target == "p95 query under 200 ms")
        #expect(edits.allSatisfy { $0.from == "Tokenizer trial" && $0.state == .proposed })
        #expect(GoalEditProposer.edits(answer, goal: "g", from: "w", now: now, scopeOnly: true)
            .allSatisfy { $0.kind == .scope })
        #expect(GoalEditProposer.edits("no json here", goal: "g", from: "x", now: now).isEmpty)
        var entry = LedgerEntry(id: "s1", title: "Tokenizer trial", startedAt: now)
        entry.decisions = ["d1"]
        let inputs = GoalEditProposer.inputs(goal: "G", doc: "# G\n", entry: entry, lastMessage: "done")
        #expect(inputs.prompt.contains("Decision: d1") && inputs.prompt.contains("## GOAL.md"))
    }

    @Test func aGoalsModelCallsAreCappedPerDay() {
        let calendar = Calendar(identifier: .gregorian)
        let today = Array(repeating: now, count: 5)
        #expect(GoalBudget.allows(runs: today, now: now, calendar: calendar))
        #expect(!GoalBudget.allows(runs: today + [now], now: now, calendar: calendar))
        #expect(GoalBudget.allows(runs: today + [now - 3 * 86400], now: now, calendar: calendar))
        #expect(!GoalBudget.allows(runs: [], now: now, limit: 0, calendar: calendar))
    }
}

struct GoalPullsTests {
    private let repo = Repo(org: "acme", name: "search-kit")

    private func pull(
        _ number: Int, _ state: PullRequest.State, branch: String = "b", draft: Bool = false,
        checks: CheckSummary = CheckSummary(passed: 3)
    ) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo, number: number), title: "PR \(number)", url: "", state: state, isDraft: draft,
            headBranch: branch, review: nil, checks: checks, unresolvedThreads: 0, updatedAt: now
        )
    }

    private func session(_ id: String, branch: String, prs: [Int] = []) -> Session {
        Session(
            id: id, title: id, repos: [repo], branch: branch, agent: "claude", state: ObservedState(.idle),
            trackedPRs: prs.map { PullRef(repo: repo, number: $0) }, lastActivity: now
        )
    }

    @Test func aPRSaysWhereItStands() {
        func states(_ pull: PullRequest) -> [String] {
            GoalPulls.evidence(pull, goal: "g", item: "g/a", now: now)
                .map { "\($0.kind.rawValue) \($0.state.rawValue)" }
        }
        #expect(states(pull(1, .open)) == ["pr done"])
        #expect(states(pull(1, .open, draft: true)) == ["pr inProgress"])
        #expect(states(pull(1, .open, checks: CheckSummary(passed: 2, failed: 1))) == ["pr issue"])
        #expect(states(pull(1, .merged)) == ["pr done", "merged done"])
        #expect(states(pull(1, .closed)) == ["pr issue"])
        #expect(GoalPulls.evidence(pull(1, .open), goal: "g", item: nil, now: now)[0].text == "#1 open · CI ok")
        #expect(GoalPulls.evidence(pull(2, .open, checks: CheckSummary(pending: 1)), goal: "g", item: nil, now: now)[0]
            .ref == "acme/search-kit#2")
    }

    @Test func thePRsOfTheGoalsSessionsAndItemsAreFound() {
        let links = [
            GoalLink(goal: "g", kind: .session, target: "s1", at: now),
            GoalLink(goal: "g", kind: .session, target: "s2", item: "g/tokens", at: now),
            GoalLink(goal: "other", kind: .session, target: "s3", at: now),
            GoalLink(goal: "g", kind: .pr, target: "acme/search-kit#9", at: now),
        ]
        let items = [
            GoalItem(
                id: "g/planner",
                goal: "g",
                title: "Planner",
                source: .planner,
                links: [GoalItem.Link(.session, "s1")],
                createdAt: now
            ),
            GoalItem(id: "g/tokens", goal: "g", title: "Tokens", source: .planner, createdAt: now),
            GoalItem(
                id: "g/ranks",
                goal: "g",
                title: "Ranks",
                source: .you,
                links: [GoalItem.Link(.branch, "ranks")],
                createdAt: now
            ),
        ]
        let sessions = [
            session("s1", branch: "planner", prs: [1]), session("s2", branch: "tokens"), session(
                "s3",
                branch: "x",
                prs: [4]
            ),
        ]
        let pulls = [
            pull(1, .open, branch: "planner"), pull(2, .merged, branch: "tokens"), pull(3, .open, branch: "ranks"),
            pull(4, .open, branch: "x"), pull(5, .open, branch: "unrelated"), pull(9, .open, branch: "nine"),
        ]
        let found = GoalPulls.findings(
            goal: "g",
            links: links,
            items: items,
            sessions: sessions,
            pulls: pulls,
            now: now
        )
        #expect(found.map(\.ref.number) == [1, 2, 3, 9])
        #expect(found.map(\.item) == ["g/planner", "g/tokens", "g/ranks", nil])
        #expect(found.map(\.session) == ["s1", "s2", nil, nil])
        #expect(found[1].evidence.map(\.kind) == [.pr, .merged])
    }

    @Test func onlyWhatChangedIsRecordedAgain() {
        let known = GoalPulls.evidence(pull(1, .open), goal: "g", item: "g/a", now: now - 60)
        #expect(GoalPulls.fresh(GoalPulls.evidence(pull(1, .open), goal: "g", item: "g/a", now: now), known: known)
            .isEmpty)
        let merged = GoalPulls.evidence(pull(1, .merged), goal: "g", item: "g/a", now: now)
        #expect(GoalPulls.fresh(merged, known: known).map(\.kind) == [.pr, .merged])
    }
}

struct GoalItemOpsTests {
    private func ops() throws -> (GoalOps, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-goal-items-\(UUID().uuidString)")
        let ops = try GoalOps(
            path: dir.appendingPathComponent("goals.sqlite").path,
            files: GoalFiles(root: dir.appendingPathComponent("goals"))
        )
        return (ops, dir)
    }

    @Test func itemsAreAddedMovedSplitAndKeptAcrossReopening() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "Quick search", statement: "x", now: now)
        let first = try await ops.addItem(goal: goal.id, title: "Cache tokens", source: .planner, now: now)
        let again = try await ops.addItem(
            goal: goal.id, title: "Cache tokens", source: .session, confidence: 0.8, reason: "follow-up", now: now + 1
        )
        #expect(first.id == "quick-search/cache-tokens" && again.id == "quick-search/cache-tokens-2")
        await #expect(throws: GoalOpError.unknownGoal("nope")) {
            try await ops.addItem(goal: "nope", title: "x", source: .you, now: now)
        }
        await #expect(throws: GoalOpError.noTitle) { try await ops.addItem(
            goal: goal.id,
            title: " ",
            source: .you,
            now: now
        ) }
        let moved = try await ops.move(item: first.id, to: .verify, now: now + 2)
        #expect(moved.placement == GoalItem.Placement(.verify, at: now + 2))
        #expect(try await ops.done(item: again.id, now: now + 3).placement?.column == .done)
        let parts = try await ops.split(item: first.id, into: ["Cache titles", "Cache synonyms"], now: now + 4)
        #expect(parts.map(\.parent) == [first.id, first.id] && parts.map(\.goal) == [goal.id, goal.id])
        let linked = try await ops.link(item: first.id, GoalItem.Link(.session, "s1"))
        _ = try await ops.link(item: first.id, GoalItem.Link(.session, "s1"))
        #expect(linked.links == [GoalItem.Link(.session, "s1")])
        await #expect(throws: GoalOpError.unknownItem("quick-search/x")) {
            try await ops.move(item: "quick-search/x", to: .done, now: now)
        }
        let reopened = try GoalOps(path: dir.appendingPathComponent("goals.sqlite").path, files: ops.files)
        let items = try await reopened.snapshot().items(of: goal.id)
        #expect(items.count == 4 && items.first { $0.id == first.id }?.links == linked.links)
        #expect(items.first { $0.id == again.id }?.confidence == 0.8)
    }

    @Test func evidenceIsKeptOnceAndValidated() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "G", statement: "x", now: now)
        let item = try await ops.addItem(goal: goal.id, title: "A", source: .you, now: now)
        let entry = GoalEvidence(goal: goal.id, item: item.id, kind: .pr, at: now, source: "#1", ref: "acme/x#1")
        let stored = try await ops.addEvidence(entry)
        #expect(stored?.id != nil)
        var later = entry
        later.at = now + 60
        #expect(try await ops.addEvidence(later) == nil)
        later.state = .issue
        #expect(try await ops.addEvidence(later) != nil)
        // Back to what it said before is news again: the newest is what counts.
        var back = entry
        back.at = now + 120
        #expect(try await ops.addEvidence(back) != nil)
        await #expect(throws: GoalOpError.unknownItem("g/none")) {
            try await ops.addEvidence(GoalEvidence(goal: goal.id, item: "g/none", kind: .perf, at: now, source: "x"))
        }
        let snapshot = try await ops.snapshot()
        #expect(snapshot.evidence(of: goal.id).count == 3)
        #expect(try Board.column(#require(snapshot.item(item.id)), evidence: snapshot.evidence) == .verify)
    }

    @Test func recordEditsApplyAndUndoScopeEditsWait() async throws {
        let (ops, dir) = try ops()
        defer { try? FileManager.default.removeItem(at: dir) }
        let goal = try await ops.create(title: "G", statement: "Quick search.", now: now)
        var doc = try await GoalDoc.parse(ops.text(of: goal.id))
        doc.openQuestions = ["Which fields need re-indexing?"]
        try await ops.save(goal: goal.id, doc: doc, note: "q", now: now)
        func edit(_ section: GoalEdit.Section, _ op: GoalEdit.Op, _ text: String, target: String? = nil) -> GoalEdit {
            GoalEdit(
                goal: goal.id,
                section: section,
                op: op,
                text: text,
                target: target,
                from: "Tokenizer trial",
                at: now
            )
        }
        let decided = try await ops.propose(edit(.decisions, .add, "Ranks live in the index folder"), now: now + 1)
        #expect(decided.state == .applied && decided.version == 3 && decided.kind == .record)
        #expect(try await ops.versions(of: goal.id).first?.author == .heed)
        #expect(try await GoalDoc.parse(ops.text(of: goal.id)).decisions.map(\.source) == ["Tokenizer trial"])
        // The same decision again changes nothing.
        #expect(try await ops.propose(edit(.decisions, .add, "ranks live in the index folder"), now: now + 2)
            .state == .moot)

        let scope = try await ops.propose(edit(.notTheGoal, .add, "Hosted search"), now: now + 3)
        #expect(scope.state == .proposed && scope.kind == .scope && scope.id != nil)
        let twice = try await ops.propose(edit(.notTheGoal, .add, "hosted search"), now: now + 4)
        #expect(twice.id == scope.id)
        // A record edit can be made to wait; a scope edit cannot be made to skip waiting.
        var forced = edit(.notTheGoal, .add, "Spelling suggestions")
        forced.kind = .record
        #expect(try await ops.propose(forced, now: now + 5).state == .proposed)
        var held = edit(.decisions, .add, "Keep the old index as a fallback")
        held.kind = .scope
        let waiting = try await ops.propose(held, now: now + 5)
        #expect(waiting.state == .proposed)
        #expect(try await ops.snapshot().proposals(of: goal.id).count == 3)

        let accepted = try await ops.accept(edit: #require(scope.id), text: "Hosted search services", now: now + 6)
        #expect(accepted.state == .applied && accepted.text == "Hosted search services")
        #expect(try await GoalDoc.parse(ops.text(of: goal.id)).notTheGoal == ["Hosted search services"])
        #expect(try await ops.versions(of: goal.id).first?.author == .you)
        await #expect(throws: try GoalOpError.editNot(.proposed, #require(scope.id))) {
            try await ops.accept(edit: #require(scope.id), now: now)
        }
        #expect(try await ops.reject(edit: #require(waiting.id), now: now + 7).state == .rejected)

        let undone = try await ops.undo(edit: #require(decided.id), now: now + 8)
        #expect(undone.state == .undone)
        #expect(try await GoalDoc.parse(ops.text(of: goal.id)).decisions.isEmpty)
        #expect(try await ops.versions(of: goal.id).first?.note.hasPrefix("undid decision") == true)

        let answered = try await ops.propose(
            edit(.openQuestions, .remove, "answered", target: "which fields need re-indexing"), now: now + 9
        )
        #expect(answered.state == .applied)
        #expect(try await ops.propose(edit(.openQuestions, .remove, "x", target: "gone?"), now: now + 9).state == .moot)
        await #expect(throws: GoalOpError.unknownEdit(999)) { try await ops.undo(edit: 999, now: now) }
    }
}

/// A Decider with a fixed answer (nil: the call fails), keeping the states it was asked about.
private final class FakeDecider: Decider {
    let answers: [String: Answer]?
    let states = Mutex<[String]>([])

    init(_ answers: [String: Answer]?) { self.answers = answers }

    func decide(subject _: String, state: String, questions _: [String: Question]) async throws -> [String: Answer] {
        states.withLock { $0.append(state) }
        guard let answers else { throw DeciderError.badAnswer("fake") }
        return answers
    }
}

struct GoalItemFixtureTests {
    @Test func theFixtureBoardHasACardInEveryColumnAndWorkWaitingForYou() throws {
        let snapshot = GoalFixtures.snapshot(GoalFixtures.all(now: now))
        let goal = "anchors-survive-page-moves"
        let columns = Board.columns(snapshot.items(of: goal), evidence: snapshot.evidence(of: goal))
        for column in Board.Column.allCases {
            #expect(columns[column]?.isEmpty == false, "\(column) is empty")
        }
        let badges = Set(snapshot.items(of: goal).map { Board.badge($0, evidence: snapshot.evidence) })
        #expect(badges.isSuperset(of: [.question, .session, .pr, .bench, .swarm]))
        #expect(snapshot.proposals(of: goal).count == 3)
        // Every proposal still applies to the goal as it is now.
        let doc = try #require(snapshot.docs[goal])
        for edit in snapshot.proposals(of: goal) {
            #expect(GoalEdits.apply(edit, to: doc) != nil && edit.kind == .scope)
        }
        // Items point at the fake world's sessions.
        let ids = Set(Fixtures.main.sessions.map(\.id))
        for target in snapshot.items.flatMap({ $0.linked(.session) }) {
            #expect(ids.contains(target))
        }
    }
}

struct GoalVersionDiffTests {
    @Test func aVersionShowsTheLinesItTookOutAndPutIn() {
        let old = "# G\n\n## Goal\n\nQuick search.\n\n## Decisions\n\n- Index titles\n"
        let new = "# G\n\n## Goal\n\nQuick search.\n\n## Decisions\n\n- Index titles\n- Rank by recency\n"
        #expect(GoalVersionDiff.of(old: old, new: new) == [GoalVersionDiff.Line(
            added: true,
            text: "Rank by recency"
        )])
        let reworded = new.replacingOccurrences(of: "Quick search.", with: "Search in 200 ms.")
        #expect(GoalVersionDiff.of(old: new, new: reworded) == [
            GoalVersionDiff.Line(added: false, text: "Quick search."),
            GoalVersionDiff.Line(added: true, text: "Search in 200 ms."),
        ])
        #expect(GoalVersionDiff.of(old: nil, new: "# G\n\nx\n") == [GoalVersionDiff.Line(added: true, text: "x")])
        #expect(GoalVersionDiff.of(old: new, new: new).isEmpty)
    }

    @Test func goalsWithProposalsAreOneNoticeEach() {
        let snapshot = GoalFixtures.snapshot(GoalFixtures.all(now: now))
        let notices = GoalNotice.of(snapshot)
        #expect(notices.map(\.goal) == ["anchors-survive-page-moves"] && notices.first?.proposals == 3)
        let items = AttentionFeed.items(github: GitHubState(), sessions: [], goals: notices)
        #expect(items.map(\.id) == ["goal:anchors-survive-page-moves"])
        #expect(items.first?.reasons == [.goalProposals] && items.first?.kind == .goal && items.first?.wantsYou == true)
        #expect(items.first?.onGitHub == false)
        let rules = AttentionRules(lines: ["proposals boost 2", "kind:goal pin", "reason:goalProposals ignore"])
        #expect(rules.problems.isEmpty)
        #expect(rules.rules.allSatisfy { $0.matches(items[0], viewer: nil, now: now) })
    }

    @Test func anItemsWorkPromptNamesItsGoalAndFile() {
        let work = GoalItem(id: "g/a", goal: "g", title: "Cache tokens", source: .you, createdAt: now)
        #expect(work.workPrompt(goal: "Quick search", doc: "~/goals/g/GOAL.md")
            == "Cache tokens\n\nThis is one item of the goal Quick search; its GOAL.md is ~/goals/g/GOAL.md.")
        var question = work
        question.kind = .question
        question.title = "Do synonyms need a table?"
        #expect(question.workPrompt(goal: "Q", doc: "d").hasPrefix("Find out: Do synonyms need a table?"))
        #expect(Board.Column(word: "explore") == .toExplore && Board.Column(word: "Verify") == .verify)
        #expect(Board.Column(word: "w") == .working && Board.Column(word: "") == nil && Board.Column(word: "x") == nil)
    }
}
