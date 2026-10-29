import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// A decider that answers from a closure and counts its calls; nil throws, as a decider that is off does.
private final class FakeDecider: Decider, @unchecked Sendable {
    typealias Answers = @Sendable ([String: Question]) -> [String: Answer]?
    private let answers: Answers
    private(set) var asked: [[String: Question]] = []
    private let lock = NSLock()

    init(_ answers: @escaping Answers) { self.answers = answers }

    func decide(subject _: String, state _: String, questions: [String: Question]) async throws -> [String: Answer] {
        lock.withLock { asked.append(questions) }
        guard let answer = answers(questions) else { throw DeciderError.off }
        return answer
    }

    static func picks(_ option: String, probability: Double = 0.9, same: Double = 0) -> FakeDecider {
        FakeDecider { questions in
            var out: [String: Answer] = [:]
            for (id, question) in questions {
                switch question {
                case let .choice(_, options):
                    var probabilities = Dictionary(uniqueKeysWithValues: options.map { ($0, 0.0) })
                    probabilities[option] = probability
                    out[id] = Answer(choice: option, probabilities: probabilities, confidence: 0.5)
                case .noul:
                    out[id] = Answer(probability: same, probabilities: ["true": same], confidence: 0.5)
                case .score: break
                }
            }
            return out
        }
    }
}

private func question(
    _ text: String, options: [String] = [], from: String? = "task:g/b", to: String? = nil, ladder: [String]? = nil,
    id: Int64 = 1, at: Date = now, category: String? = nil
) -> SwarmSteer {
    SwarmSteer(
        id: id, swarm: "g/swarm-1", goal: "g", at: at, actor: .agent, kind: .question, text: text, state: .pending,
        options: options, from: from, to: to, category: category, ladder: ladder, step: ladder?.first
    )
}

private func row(
    _ kind: SwarmSteer.Kind, _ text: String, id: Int64, actor: SwarmSteer.Actor = .you, about: Int64? = nil,
    at: Date = now, from: String? = nil, to: String? = nil, ref: String? = nil, step: String? = nil
) -> SwarmSteer {
    SwarmSteer(
        id: id, swarm: "g/swarm-1", goal: "g", at: at, actor: actor, kind: kind, text: text, about: about, ref: ref,
        from: from, to: to, step: step
    )
}

struct SwarmAuthorityTests {
    @Test func whatIsAlwaysYoursIsFoundFirstWhateverElseTheQuestionSays() {
        let cases: [(String, [String], SwarmAuthority.Category)] = [
            ("Should I delete the old cache rows?", [], .deleteData),
            ("Rename the test fixtures, then drop the table?", [], .deleteData),
            ("Force push the rebased branch?", [], .deleteData),
            ("Merge this into main once green?", [], .mergeMain),
            ("Land it on the default branch?", [], .mergeMain),
            ("We are at the budget: keep going?", [], .limits),
            ("Spend another $10 on reviews?", [], .limits),
            ("Spawn another agent for the docs?", [], .moreAgentsOrTime),
            ("Can I have more time for the parser?", [], .moreAgentsOrTime),
            ("Is offline mode part of the goal?", [], .goal),
            ("Change what done when says?", [], .goal),
        ]
        for (text, options, category) in cases {
            #expect(SwarmAuthority.category(text, options: options) == category, "\(text)")
            #expect(category.alwaysYou)
            let verdict = SwarmAuthority.classify(text, options: options, asker: .worker("g/a"), peer: "g/b")
            #expect(verdict.ladder == [.you], "\(text)")
            #expect(verdict.reason.contains("only you"))
        }
    }

    @Test func theRestByCategoryWithPeerLeadAndController() {
        #expect(SwarmAuthority.category("Name it TileCache or ChunkStore?") == .implementation)
        #expect(SwarmAuthority.category("Log a warning or skip it quietly?") == .implementation)
        #expect(SwarmAuthority.category("Unit tests with stubs or a temp folder?") == .implementation)
        #expect(SwarmAuthority.category("Should the idle codex take 3.1?") == .reassign)
        #expect(SwarmAuthority.category("Split this task in two?") == .scope)
        #expect(SwarmAuthority.category("Where does the parser live?") == .other)
        // The options count too.
        #expect(SwarmAuthority.category("Which way?", options: ["keep", "delete it"]) == .deleteData)

        let naming = SwarmAuthority.classify("Name it A or B?", asker: .worker("g/a"), peer: "g/b")
        #expect(naming.ladder == [.peer, .controller, .you])
        #expect(naming.peer == "g/b")
        #expect(SwarmAuthority.classify("Name it A or B?", asker: .worker("g/a")).ladder == [.controller, .you])
        #expect(SwarmAuthority.classify("Name it A or B?", asker: .worker("g/a"), to: .lead).ladder
            == [.lead, .controller, .you])
        #expect(SwarmAuthority.classify("Name it A or B?", asker: .worker("g/a"), to: .you).ladder == [.you])
        // Addressed to a task: that task is the peer, whatever was inferred.
        let addressed = SwarmAuthority.classify("Name it?", asker: .worker("g/a"), to: .task("g/c"), peer: "g/b")
        #expect(addressed.peer == "g/c")
        #expect(addressed.ladder.first == .peer)

        #expect(SwarmAuthority.classify("Split this task?", asker: .worker("g/a"), peer: "g/b").ladder == [.lead, .you])
        #expect(SwarmAuthority.classify("Split this task?", asker: .lead).ladder == [.you])
        #expect(SwarmAuthority.classify("Where is it?", asker: .worker("g/a"), peer: "g/b").ladder == [.peer, .you])
        #expect(SwarmAuthority.classify("Where is it?", asker: .worker("g/a")).ladder == [.you])
        #expect(SwarmAuthority.classify("Where is it?", asker: .lead, to: .lead).ladder == [.you])

        #expect(SwarmAuthority.Category.implementation.controllerMay)
        #expect(SwarmAuthority.Category.reassign.controllerMay)
        #expect(!SwarmAuthority.Category.other.controllerMay)
        #expect(!SwarmAuthority.Category.scope.controllerMay)
        #expect(!SwarmAuthority.mayRepeat(.mergeMain))
        #expect(SwarmAuthority.mayRepeat(.other))
    }
}

struct SwarmRepeatTests {
    private let history = [
        SwarmRepeat.Answered(
            id: 5, question: "Retry a flaky download three times, or once?", options: ["three times", "once"],
            answer: "once",
            at: now
        ),
        SwarmRepeat.Answered(id: 6, question: "Where do logs go?", options: [], answer: "stderr", at: now),
        SwarmRepeat.Answered(
            id: 9, question: "Default page size", options: [], answer: "100", at: now, rule: true
        ),
    ]

    @Test func exactMeansTheSameWordsAndOptions() throws {
        #expect(SwarmRepeat.normalised("Keep the cache, or DROP it?!") == "keep the cache or drop it")
        let found = try #require(SwarmRepeat.exact(
            "retry a flaky download three times or once", options: ["once", "three times"], among: history
        ))
        #expect(found.id == 5)
        #expect(SwarmRepeat.answer(found, options: ["once", "three times"]) == "once")
        // Other options: not the same question.
        #expect(SwarmRepeat.exact(
            "Retry a flaky download three times, or once?", options: ["three times", "once", "never"], among: history
        ) == nil)
        #expect(SwarmRepeat.exact("Where do logs go?", options: [], among: history)?.answer == "stderr")
        // An earlier answer that is none of the new options repeats nothing.
        #expect(SwarmRepeat.exact("Where do logs go?", options: ["file", "syslog"], among: history) == nil)
        // A rule matches its words whatever the options, if its answer is one of them.
        #expect(SwarmRepeat.exact("Default page size?", options: ["50", "100"], among: history)?.id == 9)
    }

    @Test func nearCandidatesNeedWordsInCommonAndTheSameOptions() {
        let near = SwarmRepeat.near(
            "Should a flaky download retry three times or once?", options: ["three times", "once"], among: history
        )
        #expect(near.map(\.id) == [5])
        #expect(SwarmRepeat.near("Where should metrics go?", options: [], among: history).isEmpty)
        // Rules reach further.
        #expect(SwarmRepeat.near("Page size default?", options: ["50", "100"], among: history).map(\.id) == [9])
        if case let .noul(text) = SwarmRepeat.sameQuestion("x?", history[0]) {
            #expect(text.contains("Retry a flaky download three times"))
        } else {
            Issue.record("a yes/no statement")
        }
    }

    @Test func answeredIsYourNewestAnswerPerQuestionAndYourRules() {
        let rows = [
            question("Retry or give up?", options: ["retry", "give up"], id: 1),
            row(.answer, "retry", id: 2, actor: .controller, about: 1),
            row(.overrule, "give up", id: 3, about: 1, ref: "steer:2"),
            question("Logs?", id: 4),
            row(.answer, "lead says stderr", id: 5, actor: .lead, about: 4),
            {
                var rule = row(.rule, "Default page size", id: 6)
                rule.answer = "100"
                return rule
            }(),
        ]
        let answered = SwarmRepeat.answered(rows)
        #expect(answered.map(\.id) == [6, 1])
        #expect(answered.last?.answer == "give up")
        #expect(answered.first?.rule == true)
    }
}

struct SwarmLadderTests {
    @Test func aQuestionClimbsItsLadderAsItsStepsTimeOut() {
        let asked = question("Name it?", options: ["a", "b"], to: "task:g/a", ladder: ["peer", "controller", "you"])
        var rows = [asked]
        let open = { SwarmSteering.questions(rows)[0] }
        #expect(SwarmLadder.position(asked, rows: rows) == SwarmLadder.Position(
            step: .peer, since: now, ladder: [.peer, .controller, .you], peer: "g/a"
        ))
        #expect(SwarmLadder.due(open(), rows: rows, now: now.addingTimeInterval(599)) == .none)
        #expect(SwarmLadder.due(open(), rows: rows, now: now.addingTimeInterval(600))
            == .escalate(.controller, "no answer from the peer in 10 min"))
        rows.append(row(
            .escalate,
            "to the controller",
            id: 2,
            actor: .heed,
            about: 1,
            at: now.addingTimeInterval(600),
            step: "controller"
        ))
        #expect(SwarmLadder.position(asked, rows: rows).step == .controller)
        #expect(SwarmLadder.due(open(), rows: rows, now: now.addingTimeInterval(601)) == .askController)
        #expect(SwarmLadder.due(open(), rows: rows, now: now.addingTimeInterval(600 + 180))
            == .escalate(.you, "the controller did not answer in 3 min"))
        rows.append(row(.escalate, "to you", id: 3, actor: .heed, about: 1, at: now, step: "you"))
        #expect(SwarmLadder.due(open(), rows: rows, now: now.addingTimeInterval(9999)) == .none)
        rows.append(row(.answer, "a", id: 4, about: 1))
        #expect(SwarmLadder.due(open(), rows: rows, now: now) == .none)
        // A question from before the ladder is yours.
        #expect(SwarmLadder.position(question("Old?", ladder: nil), rows: []).step == .you)
        #expect(SwarmLadder.next(after: .you, in: [.you]) == .you)
        #expect(SwarmLadder.next(after: .lead, in: [.lead, .you]) == .you)
    }

    @Test func thePeerIsTheNearestWorkAtWork() {
        let tasks = [
            SwarmTask(id: "g/a", title: "A", phase: "P"),
            SwarmTask(id: "g/b", title: "B", phase: "P", after: ["g/a"]),
            SwarmTask(id: "g/c", title: "C", phase: "P", after: ["g/b"]),
        ]
        #expect(SwarmLadder.peer(for: "g/b", tasks: tasks, live: ["g/a", "g/c"]) == "g/a")
        #expect(SwarmLadder.peer(for: "g/b", tasks: tasks, live: ["g/c"]) == "g/c")
        #expect(SwarmLadder.peer(for: "g/b", tasks: tasks, live: []) == nil)
        #expect(SwarmLadder.peer(for: "g/x", tasks: tasks, live: ["g/a"]) == nil)
    }
}

struct SwarmDeliveryTests {
    @Test func messagesQuestionsAndAnswersWaitUntilHandedOver() {
        var rows = [
            row(.message, "Hold off on the schema change", id: 1, from: "lead", to: "all"),
            row(.message, "Your parser returns spans now", id: 2, actor: .agent, from: "task:g/a", to: "task:g/b"),
            question(
                "Name it?",
                options: ["a", "b"],
                from: "task:g/b",
                to: "task:g/a",
                ladder: ["peer", "controller", "you"],
                id: 3
            ),
            question("Split it?", from: "task:g/c", ladder: ["lead", "you"], id: 4),
        ]
        rows[0].targets = ["task:g/a", "task:g/b"]
        let numbers = ["g/a": "1.1", "g/b": "1.2", "g/c": "2.1"]
        var pending = SwarmDelivery.pending(rows, numbers: numbers, now: now)
        #expect(pending.map { "\($0.row.id ?? 0)>\($0.to.raw)" }
            == ["1>task:g/a", "1>task:g/b", "2>task:g/b", "3>task:g/a", "4>lead"])
        #expect(pending[0].line.contains("message from the lead: Hold off on the schema change"))
        #expect(pending[2].line.contains("reply: heed swarm send a"))
        #expect(pending[3].line.contains("heed swarm answer 3"))
        #expect(pending[3].line.contains("task 1.2 asks you"))

        rows.append(row(.deliver, "typed", id: 5, actor: .heed, about: 1, ref: "task:g/a"))
        rows.append(row(.answer, "a", id: 6, actor: .agent, about: 3, at: now, from: "task:g/a"))
        pending = SwarmDelivery.pending(rows, now: now)
        // Answered: the question is nobody's any more; the fresh answer waits its grace for the asker's own ask.
        #expect(pending.map { "\($0.row.id ?? 0)>\($0.to.raw)" } == ["1>task:g/b", "2>task:g/b", "4>lead"])
        pending = SwarmDelivery.pending(rows, now: now.addingTimeInterval(30))
        #expect(pending.contains { $0.row.id == 6 && $0.to == .task("g/b") })
        #expect(pending.first { $0.row.id == 6 }?.line.contains("(by task 1.1)") == false)
        // Its `heed goal ask` is waiting: it reads the answer itself.
        #expect(!SwarmDelivery.pending(rows, waiting: [3], now: now.addingTimeInterval(30)).contains { $0.row.id == 6 })
        // Overruled: only the answer that stands is typed.
        rows.append(row(.overrule, "b", id: 7, about: 3, at: now, ref: "steer:6"))
        pending = SwarmDelivery.pending(rows, now: now.addingTimeInterval(30))
        #expect(!pending.contains { $0.row.id == 6 })
        #expect(pending.first { $0.row.id == 7 }?.line.contains("overrules") == true)
        #expect(SwarmDelivery.pending(for: .lead, rows, now: now).map(\.row.id) == [4])
    }

    @Test func addressesParseAndRead() {
        let tasks = [
            SwarmTask(id: "g/cache", title: "Cache", phase: "P"),
            SwarmTask(id: "g/docs", title: "D", phase: "Q"),
        ]
        #expect(SwarmAddress.parse("2.1", tasks: tasks) == .task("g/docs"))
        #expect(SwarmAddress.parse("@cache", tasks: tasks) == .task("g/cache"))
        #expect(SwarmAddress.parse("g/docs", tasks: tasks) == .task("g/docs"))
        #expect(SwarmAddress.parse("@all", tasks: tasks) == .all)
        #expect(SwarmAddress.parse("lead", tasks: tasks) == .lead)
        #expect(SwarmAddress.parse("nobody", tasks: tasks) == nil)
        for address in [SwarmAddress.you, .lead, .all, .controller, .heed, .task("g/x"), .session("s1")] {
            #expect(SwarmAddress(raw: address.raw) == address)
        }
        #expect(SwarmAddress(raw: "task:") == nil)
        #expect(SwarmAddress.task("g/docs").label(["g/docs": "2.1"]) == "task 2.1")
    }

    @Test func aTasksLogHasWhatWasSaidToItAndByIt() {
        var rows = [
            row(.message, "Hold off on the schema change", id: 1, from: "lead", to: "all"),
            row(.note, "reading the tile index", id: 2, actor: .agent, from: "task:g/a"),
            question("Name it?", from: "task:g/a", id: 3),
            row(.answer, "A", id: 4, actor: .controller, about: 3),
            row(.note, "other", id: 5, actor: .agent, from: "task:g/b"),
            row(.work, "started", id: 6, actor: .heed, ref: "task:g/a"),
        ]
        rows[0].targets = ["task:g/a"]
        #expect(SwarmMessages.log(of: "g/a", rows).map(\.id) == [1, 2, 3, 4])
    }
}

struct SwarmControllerTests {
    private let named = question("Name it TileCache or ChunkStore?", options: ["TileCache", "ChunkStore"])

    @Test func itPicksWithinItsAuthorityAndOtherwiseSuggestsOrDeclines() async {
        let decider = FakeDecider.picks("ChunkStore", probability: 0.7)
        let picked = await SwarmController.decide(named, category: .implementation, history: [], decider: decider)
        #expect(picked == .answer("ChunkStore", reason: "70% for it"))
        if case let .choice(text, options)? = decider.asked.first?["answer"] {
            #expect(options == ["TileCache", "ChunkStore"])
            #expect(text.contains("Name it TileCache"))
        } else {
            Issue.record("asked a choice")
        }
        // On its own it does not answer what is not its own; asked by you about what is always yours, it suggests.
        #expect(await SwarmController.decide(named, category: .other, history: [], decider: decider)
            == .decline("a question heed cannot place is not the controller's to answer"))
        #expect(await SwarmController.decide(
            named, category: .mergeMain, history: [], decider: decider, mode: .askedByYou
        ) == .suggest("ChunkStore", reason: "70% for it"))
        #expect(await SwarmController.decide(named, category: .other, history: [], decider: decider, mode: .askedByYou)
            == .answer("ChunkStore", reason: "70% for it"))
        // No options, no decider: it declines.
        let open = question("Where does it go?")
        #expect(await SwarmController.decide(open, category: .implementation, history: [], decider: decider)
            == .decline("the question has no options to pick from"))
        let off = FakeDecider { _ in nil }
        if case let .decline(why) = await SwarmController.decide(
            named,
            category: .implementation,
            history: [],
            decider: off
        ) {
            #expect(why.contains("could not decide"))
        } else {
            Issue.record("declined")
        }
    }

    @Test func repeatsComeFirstExactWithoutADeciderNearOnlyOnAClearYes() async {
        let earlier = SwarmRepeat.Answered(
            id: 5, question: "Name it TileCache or ChunkStore?", options: ["ChunkStore", "TileCache"],
            answer: "TileCache", at: now
        )
        let never = FakeDecider { _ in nil }
        #expect(await SwarmController.decide(named, category: .implementation, history: [earlier], decider: never)
            == .repeatOf(earlier, answer: "TileCache", similar: false))
        #expect(never.asked.isEmpty)
        // Never for what is always yours.
        #expect(await SwarmController.decide(named, category: .deleteData, history: [earlier], decider: never)
            == .decline("deleting data is not the controller's to answer"))

        let similar = question(
            "Should we name it TileCache or rather ChunkStore?",
            options: ["TileCache", "ChunkStore"]
        )
        let unsure = FakeDecider.picks("ChunkStore", same: 0.6)
        #expect(await SwarmController.decide(similar, category: .implementation, history: [earlier], decider: unsure)
            == .answer("ChunkStore", reason: "90% for it"))
        let sure = FakeDecider.picks("ChunkStore", same: 0.85)
        #expect(await SwarmController.decide(similar, category: .implementation, history: [earlier], decider: sure)
            == .repeatOf(earlier, answer: "TileCache", similar: true))
        #expect(sure.asked.count == 1)
    }

    @Test func itReadsOnlyTheRowsOwnWords() {
        var row = named
        row.effects = ["", "renames the module"]
        let state = SwarmController.state(row)
        #expect(state.contains("Question: Name it TileCache or ChunkStore?"))
        #expect(state.contains("Option ChunkStore: renames the module"))
        #expect(state.contains("Option TileCache\n"))
        #expect(state.contains("(b)"))
    }
}

struct SwarmSteeringOpsTests {
    private func world(running: Bool = true) async throws -> (GoalOps, GoalSwarm) {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        let started = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.setLead(swarm: started.id, session: "lead-1", now: now)
        try await ops.proposePlan(swarm: started.id, input: SwarmPlanInput.parse("""
        [{"id": "a", "title": "A", "phase": "Build", "owner": "claude"},
         {"id": "b", "title": "B", "phase": "Build", "owner": "claude", "after": ["a"]}]
        """, goal: goal.id), now: now)
        try await ops.approvePlan(swarm: started.id, now: now)
        if running {
            for task in ["a", "b"] {
                try await ops.startWorker(swarm: started.id, SwarmWorker(
                    id: "w-\(task)", task: "faster-builds/\(task)", owner: GoalItem.Owner(agent: "claude"),
                    host: "lead-1", repo: "acme/site", branch: "swarm/\(task)", base: "main", worktree: "/wt/\(task)",
                    startedAt: now
                ), text: "started", now: now)
            }
        }
        return try await (ops, ops.board(of: started.id).swarm)
    }

    @Test func aWorkersQuestionGoesToItsPeerAndARepeatIsAnsweredAtOnce() async throws {
        let (ops, swarm) = try await world()
        let asked = try await ops.ask(
            swarm: swarm.id, question: "Name it TileCache or ChunkStore?", options: ["TileCache", "ChunkStore", ""],
            effects: ["", "renames the module", "ignored"], from: .task("faster-builds/b"), actor: .agent, now: now
        )
        #expect(asked.category == "implementation")
        #expect(asked.ladder == ["peer", "controller", "you"])
        #expect(asked.to == "task:faster-builds/a")
        #expect(asked.effects == ["", "renames the module"])
        #expect(asked.from == "task:faster-builds/b")
        let id = try #require(asked.id)
        // Not the asker's to answer, nor a task's it was not asked of; the peer's is.
        await #expect(throws: GoalOpError.notYours(id, "a peer")) {
            try await ops.answer(
                swarm: swarm.id,
                question: id,
                text: "ChunkStore",
                actor: .agent,
                from: .task("faster-builds/b"),
                now: now
            )
        }
        await #expect(throws: GoalOpError.notYours(id, "a peer")) {
            try await ops.answer(swarm: swarm.id, question: id, text: "ChunkStore", actor: .lead, from: .lead, now: now)
        }
        let peer = try await ops.answer(
            swarm: swarm.id, question: id, text: "ChunkStore", actor: .agent, from: .task("faster-builds/a"), now: now
        )
        #expect(peer.kind == .answer)
        // You overrule it: a row of its own, pointing at the peer's answer.
        let overrule = try await ops.answer(swarm: swarm.id, question: id, text: "TileCache", now: now)
        #expect(overrule.kind == .overrule)
        #expect(overrule.state == .overruled)
        #expect(overrule.ref == "steer:\(peer.id ?? 0)")
        #expect(overrule.reason?.hasSuffix(": ChunkStore") == true)
        var board = try await ops.board(of: swarm.id)
        #expect(board.questions.first?.answer?.id == overrule.id)
        #expect(SwarmSteering.overruled(board.steering) == [peer.id ?? 0])
        #expect(SwarmSteering.state(peer, overruled: SwarmSteering.overruled(board.steering)) == .overruled)
        // Asked again in the same words: your answer, repeated by the controller at once.
        let again = try await ops.ask(
            swarm: swarm.id, question: "name it tilecache or chunkstore", options: ["ChunkStore", "TileCache"],
            from: .task("faster-builds/a"), actor: .agent, now: now
        )
        board = try await ops.board(of: swarm.id)
        let repeated = try #require(board.questions.first { $0.id == again.id }?.answer)
        #expect(repeated.actor == .controller)
        #expect(repeated.text == "TileCache")
        #expect(repeated.reason?.hasPrefix("a repeat of your answer to") == true)
        // Never for what is always yours.
        let merge = try await ops.ask(
            swarm: swarm.id, question: "Merge to main now?", options: ["yes", "no"], from: .task("faster-builds/a"),
            actor: .agent, now: now
        )
        #expect(merge.ladder == ["you"])
        let mergeID = try #require(merge.id)
        try await ops.answer(swarm: swarm.id, question: mergeID, text: "no", now: now)
        let mergeAgain = try await ops.ask(
            swarm: swarm.id, question: "Merge to main now?", options: ["yes", "no"], from: .task("faster-builds/a"),
            actor: .agent, now: now
        )
        board = try await ops.board(of: swarm.id)
        #expect(board.questions.first { $0.id == mergeAgain.id }?.answer == nil)
    }

    @Test func escalationsRulesSuggestionsMessagesNotesAndHandOvers() async throws {
        let (ops, swarm) = try await world()
        let asked = try await ops.ask(
            swarm: swarm.id, question: "Default page size: 50 or 100?", options: ["50", "100"],
            from: .task("faster-builds/a"),
            to: .lead, actor: .agent, now: now
        )
        let id = try #require(asked.id)
        #expect(asked.ladder == ["lead", "controller", "you"])
        #expect(try await ops.escalate(swarm: swarm.id, question: id, to: .controller, why: "timed out", now: now)?.step
            == "controller")
        #expect(try await ops.escalate(swarm: swarm.id, question: id, to: .controller, why: "again", now: now) == nil)
        // At the controller's step it is nobody else's, but the one it was asked of may still answer.
        await #expect(throws: GoalOpError.notYours(id, "the controller")) {
            try await ops.answer(
                swarm: swarm.id, question: id, text: "50", actor: .agent, from: .task("faster-builds/b"), now: now
            )
        }
        try await ops.suggest(swarm: swarm.id, question: id, option: "100", reason: "80% for it", now: now)
        var board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.suggestion(board.questions[0], rows: board.steering)?.text == "100")
        try await ops.rule(swarm: swarm.id, question: id, answer: "100", now: now)
        try await ops.answer(swarm: swarm.id, question: id, text: "100", now: now)
        board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.suggestion(board.questions[0], rows: board.steering) == nil)
        let rule = try #require(board.steering.last { $0.kind == .rule })
        #expect(rule.answer == "100" && rule.options == ["50", "100"])

        let all = try await ops.message(
            swarm: swarm.id,
            from: .lead,
            to: .all,
            text: "Hold off on the schema change",
            actor: .lead,
            now: now
        )
        #expect(all.targets == ["task:faster-builds/a", "task:faster-builds/b"])
        let fromWorker = try await ops.message(
            swarm: swarm.id, from: .task("faster-builds/a"), to: .all, text: "The parser returns spans now",
            actor: .agent, now: now
        )
        #expect(fromWorker.targets == ["lead", "task:faster-builds/b"])
        try await ops.note(swarm: swarm.id, from: .task("faster-builds/a"), text: "parsing", actor: .agent, now: now)
        try await ops.delivered(swarm: swarm.id, row: all.id ?? 0, to: .task("faster-builds/a"), how: "typed", now: now)
        board = try await ops.board(of: swarm.id)
        let pending = SwarmDelivery.pending(board.steering, now: now)
        #expect(pending.filter { $0.row.id == all.id }.map(\.to) == [.task("faster-builds/b")])
        #expect(SwarmMessages.log(of: "faster-builds/a", board.steering).map(\.kind)
            == [.question, .escalate, .suggest, .answer, .message, .message, .note])
        await #expect(throws: GoalOpError.noTitle) {
            try await ops.note(swarm: swarm.id, from: .lead, text: "  ", actor: .lead, now: now)
        }
    }

    @Test func retargetFailuresWaitUntilMovedOrLeft() async throws {
        let (ops, swarm) = try await world()
        let move = SwarmLanding.Retarget(
            task: "faster-builds/b", pr: 12, parent: "faster-builds/a", parentPR: 11, from: "swarm/a", to: "main",
            stackedOn: nil, edit: true
        )
        let failed = try await ops.retargetFailed(swarm: swarm.id, move, error: "gh: no", now: now)
        var board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.retargetFailures(board.steering).map(\.id) == [failed.id])
        try await ops.leaveRetarget(swarm: swarm.id, failure: failed.id ?? 0, now: now)
        board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.retargetFailures(board.steering).isEmpty)
        let again = try await ops.retargetFailed(swarm: swarm.id, move, error: "gh: no", now: now)
        board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.retargetFailures(board.steering).map(\.id) == [again.id])
        try await ops.retargeted(swarm: swarm.id, move, now: now)
        board = try await ops.board(of: swarm.id)
        #expect(SwarmSteering.retargetFailures(board.steering).isEmpty)
    }

    @Test func needsYouHasTheQuestionsAtYourStepAndTheFailedMoves() async throws {
        let (ops, swarm) = try await world()
        let yours = try await ops.ask(
            swarm: swarm.id, question: "Delete the old rows?", options: ["yes", "no"], from: .task("faster-builds/b"),
            actor: .agent, now: now
        )
        try await ops.ask(
            swarm: swarm.id, question: "Name it A or B?", options: ["A", "B"], from: .task("faster-builds/b"),
            actor: .agent, now: now
        )
        let move = SwarmLanding.Retarget(
            task: "faster-builds/b", pr: 12, parent: "faster-builds/a", parentPR: 11, from: "swarm/a", to: "main",
            stackedOn: nil, edit: true
        )
        try await ops.retargetFailed(swarm: swarm.id, move, error: "gh: no", now: now)
        let board = try await ops.board(of: swarm.id)
        let goal = try #require(try await ops.snapshot().goal("faster-builds"))
        let items = GoalAttention.items(
            goals: [goal], qualities: [:], waiting: [:], swarms: [board.swarm], boards: [board], now: now
        )
        #expect(items.map(\.id) == ["goal:faster-builds:ask:\(yours.id ?? 0)", "goal:faster-builds:retarget"])
        #expect(items[0].title == "Faster builds: task 1.2 asks: Delete the old rows?")
        #expect(GoalAttention.question(of: items[0])?.question == yours.id)
        #expect(GoalAttention.question(of: items[1]) == nil)
        #expect(GoalAttention.isRetarget(items[1]))
        #expect(items[1].title.contains("could not move #12 to main"))
        #expect(items[0].placeholderSummary.contains("1…9"))
    }

    @Test func overrulesOfTheControllerTeachHunch() async throws {
        let (ops, swarm) = try await world()
        let asked = try await ops.ask(
            swarm: swarm.id, question: "Retry or give up?", options: ["retry", "give up"],
            from: .task("faster-builds/a"),
            actor: .agent, now: now
        )
        let id = try #require(asked.id)
        try await ops.answer(swarm: swarm.id, question: id, text: "retry", actor: .controller, reason: "x", now: now)
        try await ops.answer(swarm: swarm.id, question: id, text: "Give up", now: now.addingTimeInterval(5))
        let other = try await ops.ask(
            swarm: swarm.id, question: "Name it?", options: ["a", "b"], from: .task("faster-builds/a"), actor: .agent,
            now: now
        )
        try await ops.answer(
            swarm: swarm.id,
            question: other.id ?? 0,
            text: "a",
            actor: .agent,
            from: .task("faster-builds/b"),
            now: now
        )
        try await ops.answer(swarm: swarm.id, question: other.id ?? 0, text: "b", now: now)
        let examples = try await HunchTrainingSet.swarm(ops.steering(goal: nil))
        // Only the controller's answer overruled teaches; the peer's does not.
        #expect(examples.count == 1)
        let example = try #require(examples.first)
        #expect(example.family == .swarm)
        #expect(example.answer == "give up")
        #expect(example.id == "\("swarm:\(swarm.id)#\(id)")")
        #expect(example.state == SwarmController.state(asked))
        #expect(example.question == SwarmController.question(asked))
    }
}

struct SwarmSteeringCommandTests {
    private func parse(_ line: [String]) throws -> GoalCommand { try GoalCommandLine.parse(line) }

    @Test func askTakesOptionsEffectsWhomAndHowLongToWait() throws {
        let command = try parse([
            "goal", "ask", "Keep", "or", "drop?", "--option", "keep", "--effect", "blocks 2.3", "--option", "drop",
            "--to", "lead", "--timeout", "5",
        ])
        #expect(command.text == "Keep or drop?")
        #expect(command.options == ["keep", "drop"])
        #expect(command.effects == ["blocks 2.3", ""])
        #expect(command.to == "lead")
        #expect(command.timeout == 5)
        #expect(try parse(["goal", "ask", "x?", "--option=a", "--effect=b"]).effects == ["b"])
        #expect(try parse(["goal", "ask", "x?", "--no-wait"]).timeout == 0)
        #expect(try parse(["goal", "ask", "--id", "12"]).question == 12)
        #expect(try parse(["goal", "ask", "x?", "--option", "a"]).effects == nil)
        for bad in [
            ["goal", "ask", "x?", "--effect", "b"], ["goal", "ask", "x?", "--timeout", "soon"],
            ["goal", "ask", "x?", "--timeout", "-1"], ["goal", "ask", "x?", "--no-wait", "--timeout", "3"],
            ["goal", "ask", "--id", "x"], ["goal", "ask", "more", "--id", "3"], ["goal", "ask", "--to", "lead"],
            ["goal", "ask", "--id", "3", "--to", "lead"], ["goal", "show", "--to", "lead"],
        ] {
            #expect(throws: HookCommandLine.UsageError.self, "\(bad)") { try parse(bad) }
        }
    }

    @Test func swarmSendNoteAndAnswer() throws {
        let send = try SwarmCommandLine.parse([
            "swarm",
            "send",
            "@all",
            "Hold",
            "off",
            "on",
            "the",
            "schema",
            "change",
            "--json",
        ])
        #expect(send.verb == .swarmSend && send.to == "@all" && send.text == "Hold off on the schema change" && send
            .json)
        let note = try SwarmCommandLine.parse(["swarm", "--goal", "g", "note", "reading", "the", "tile", "index"])
        #expect(note.verb == .swarmNote && note.goal == "g" && note.text == "reading the tile index")
        let answer = try SwarmCommandLine.parse(["swarm", "answer", "12", "use", "ChunkStore"])
        #expect(answer.verb == .swarmAnswer && answer.question == 12 && answer.text == "use ChunkStore")
        #expect(try SwarmCommandLine.parse(["swarm", "ask", "x?", "--no-wait"]).verb == .ask)
        // A word that starts with -- after the command is part of the message.
        #expect(try SwarmCommandLine.parse(["swarm", "note", "ran", "--verbose"]).text == "ran --verbose")
        for bad in [
            ["swarm"],
            ["swarm", "send", "lead"],
            ["swarm", "send"],
            ["swarm", "note"],
            ["swarm", "answer", "x", "y"],
            ["swarm", "answer", "3"],
            ["swarm", "shout", "x"],
            ["swarm", "--loud", "note", "x"],
        ] {
            #expect(throws: HookCommandLine.UsageError.self, "\(bad)") { try SwarmCommandLine.parse(bad) }
        }
        let request = try GoalCommandLine.request(
            ["swarm", "note", "x"], environment: [HeedEnvironment.sessionID: "s1", HeedEnvironment.pane: "p1"]
        )
        #expect(request.goal?.verb == .swarmNote && request.session == "s1" && request.pane == "p1")
        #expect(GoalCommandLine.wantsHelp(["swarm"]))
        #expect(GoalCommandLine.wantsHelp(["swarm", "--help"]))
        #expect(!GoalCommandLine.wantsHelp(["swarm", "note", "x"]))
    }

    private func reply(_ outcome: String, exit: GoalExit = .ok, question: Int64? = 7) -> ControlReply {
        ControlReply(goal: GoalReply(outcome, exit: exit, message: outcome, goal: "g", question: question))
    }

    @Test func askWaitsReadingAgainUntilAnsweredRefusedOrTimedOut() throws {
        let request = ControlRequest(method: .goal, goal: GoalCommand(.ask, text: "x?", timeout: 1))
        var clock = now
        var polls: [ControlRequest] = []
        var answers = [reply("asked"), reply("asked"), reply("answered")]
        let answered = GoalAskWait.wait(
            first: reply("asked"), request: request,
            call: { request in
                polls.append(request)
                return answers.removeFirst()
            },
            sleep: { clock = clock.addingTimeInterval($0) }, clock: { clock }
        )
        #expect(answered.goal?.outcome == "answered")
        #expect(polls.count == 3)
        #expect(polls.allSatisfy { $0.goal?.question == 7 && $0.goal?.text == nil && $0.goal?.verb == .ask })

        // Heed away for a moment: tried again; never answered: exit 6 after the timeout, the question kept.
        clock = now
        var calls = 0
        let timedOut = GoalAskWait.wait(
            first: reply("asked"), request: request,
            call: { _ in
                calls += 1
                if calls == 2 { throw ControlClientError.closed }
                return reply("asked")
            },
            sleep: { clock = clock.addingTimeInterval($0) }, clock: { clock }
        )
        #expect(timedOut.goal?.exit == .timedOut)
        #expect(timedOut.goal?.question == 7)
        #expect(timedOut.goal?.message.contains("heed goal ask --id 7") == true)
        #expect(calls == 20)
        #expect(GoalCommandLine.finish(timedOut, json: false).code == 6)

        // Refused (the swarm stopped): at once.
        let refused = GoalAskWait.wait(
            first: reply("asked"), request: request, call: { _ in reply("refused", exit: .refused) },
            sleep: { _ in }, clock: { now }
        )
        #expect(refused.goal?.exit == .refused)
        // Answered at once, not waiting, or not an ask: no reads.
        let never: (ControlRequest) throws -> ControlReply = { _ in
            Issue.record("no read")
            return reply("x")
        }
        #expect(GoalAskWait.wait(
            first: reply("answered"),
            request: request,
            call: never,
            sleep: { _ in },
            clock: { now }
        ).goal?.outcome == "answered")
        let noWait = ControlRequest(method: .goal, goal: GoalCommand(.ask, text: "x?", timeout: 0))
        #expect(GoalAskWait.wait(
            first: reply("asked"),
            request: noWait,
            call: never,
            sleep: { _ in },
            clock: { now }
        ).goal?.outcome == "asked")
        let show = ControlRequest(method: .goal, goal: GoalCommand(.planShow))
        #expect(GoalAskWait.wait(
            first: reply("asked"),
            request: show,
            call: never,
            sleep: { _ in },
            clock: { now }
        ).goal?.outcome == "asked")
    }
}

struct SwarmSteeringControlTests {
    private let lead = GoalCaller(session: "lead-1", title: "Lead")
    private let workerA = GoalCaller(session: "lead-1", title: "worker", worker: "faster-builds/a")
    private let workerB = GoalCaller(session: "lead-1", title: "worker", worker: "faster-builds/b")

    private func world() async throws -> (GoalOps, GoalSwarm) {
        let ops = try GoalOps(path: ":memory:", files: .fixture)
        let goal = try await ops.create(title: "Faster builds", statement: "x", now: now)
        try await ops.attach(GoalLink(goal: goal.id, kind: .session, target: "lead-1", origin: .swarm, at: now))
        let started = try await ops.startSwarm(goal: goal.id, settings: SwarmSettings(), now: now)
        try await ops.setLead(swarm: started.id, session: "lead-1", now: now)
        try await ops.proposePlan(swarm: started.id, input: SwarmPlanInput.parse("""
        [{"id": "a", "title": "A", "phase": "Build"}, {"id": "b", "title": "B", "phase": "Build", "after": ["a"]}]
        """, goal: goal.id), now: now)
        try await ops.approvePlan(swarm: started.id, now: now)
        for task in ["a", "b"] {
            try await ops.startWorker(swarm: started.id, SwarmWorker(
                id: "w-\(task)", task: "faster-builds/\(task)", owner: GoalItem.Owner(agent: "claude"),
                host: "lead-1", repo: "acme/site", branch: "swarm/\(task)", base: "main", worktree: "/wt/\(task)",
                startedAt: now
            ), text: "started", now: now)
        }
        return try await (ops, ops.board(of: started.id).swarm)
    }

    private func run(_ command: GoalCommand, _ ops: GoalOps, caller: GoalCaller?) async -> GoalReply? {
        var command = command
        if caller == nil { command.goal = "faster-builds" }
        let outcome = await GoalControl.run(command, caller: caller, ops: ops, files: .fixture, now: now)
        if case let .reply(reply) = outcome { return reply }
        return nil
    }

    @Test func aWorkerAsksItsPeerAnswersAndTheAskerReadsIt() async throws {
        let (ops, swarm) = try await world()
        let asked = try #require(await run(
            GoalCommand(.ask, text: "Name it A or B?", options: ["A", "B"]), ops, caller: workerB
        ))
        #expect(asked.outcome == "asked")
        let id = try #require(asked.question)
        #expect(asked.answer?.waitsFor == "task 1.1")
        #expect(asked.message.contains("waits for task 1.1"))
        // The peer finds it in plan show (read once: a hand-over row).
        let show = await run(GoalCommand(.planShow), ops, caller: workerA)
        #expect(show?.plan?.inbox?.first?.contains("heed swarm answer \(id)") == true)
        #expect(await run(GoalCommand(.planShow), ops, caller: workerA)?.plan?.inbox == [])
        let answered = await run(GoalCommand(.swarmAnswer, text: "B", question: id), ops, caller: workerA)
        #expect(answered?.outcome == "answered")
        #expect(answered?.message == "answered: task 1.2 gets \"B\"")
        // The asker's wait reads it, and heed will not type it as well.
        let read = try #require(await run(GoalCommand(.ask, question: id), ops, caller: workerB))
        #expect(read.outcome == "answered")
        #expect(read.message == "B\n(answered by task 1.1)")
        #expect(read.rendered(json: false) == "B\n(answered by task 1.1)")
        let board = try await ops.board(of: swarm.id)
        #expect(SwarmDelivery.pending(board.steering, now: .distantFuture).isEmpty)
        // A question of yours from a terminal: refused for an unknown whom.
        #expect(await run(GoalCommand(.ask, text: "x?", to: "nobody"), ops, caller: workerA)?.exit == .refused)
        #expect(await run(GoalCommand(.ask, question: 999), ops, caller: workerA)?.exit == .refused)
    }

    @Test func messagesAndNotesFromPanesAndFromYou() async throws {
        let (ops, swarm) = try await world()
        let sent = await run(
            GoalCommand(.swarmSend, text: "The parser returns spans now", to: "1.2"),
            ops,
            caller: workerA
        )
        #expect(sent?.outcome == "sent")
        #expect(sent?.message == "sent to task 1.2: heed types it into its pane once its agent is idle")
        #expect(await run(GoalCommand(.swarmSend, text: "x", to: "@all"), ops, caller: lead)?.message
            == "sent to everyone (2 at work): heed types it into each pane once its agent is idle")
        #expect(await run(GoalCommand(.swarmSend, text: "x", to: "lead"), ops, caller: nil)?.outcome == "sent")
        #expect(await run(GoalCommand(.swarmSend, text: "x", to: "1.1"), ops, caller: workerA)?.exit == .refused)
        #expect(await run(GoalCommand(.swarmSend, text: "x", to: "9.9"), ops, caller: workerA)?.exit == .refused)
        #expect(await run(GoalCommand(.swarmNote, text: "parsing"), ops, caller: workerA)?.outcome == "noted")
        #expect(await run(GoalCommand(.swarmNote, text: "parsing"), ops, caller: nil)?.exit == .refused)
        let board = try await ops.board(of: swarm.id)
        let rows = board.steering.filter { $0.kind == .message || $0.kind == .note }
        #expect(rows.map(\.actor) == [.agent, .lead, .you, .agent])
        #expect(rows.map(\.from) == ["task:faster-builds/a", "lead", "you", "task:faster-builds/a"])
    }
}

struct SwarmSteeringKeyTests {
    @Test func needsYouAndThePlanHaveTheSteeringKeys() throws {
        let built = Keymaps.build()
        func command(_ key: String, _ scope: String) throws -> String? {
            guard case let .command(line) = try built.scoped[scope]?.lookup(KeyNotation.parse(key)) else { return nil }
            return line
        }
        #expect(try command("1", "swarmask") == "swarm.answer.option 1")
        #expect(try command("9", "swarmask") == "swarm.answer.option 9")
        #expect(try command("i", "swarmask") == "swarm.answer")
        #expect(try command("c", "swarmask") == "swarm.controller")
        #expect(try command("A", "swarmask") == "swarm.similar")
        // The rest is Attention's.
        #expect(try command("y", "swarmask") == "goal.ask.yes")
        #expect(try command("x", "swarmask") == "attention.done")
        #expect(try command("1", "attention") == nil)
        #expect(try command("c", "goalplan") == "swarm.controller")
        #expect(try command("w", "goalplan") == "swarm.log.who")
        #expect(try command("q", "goalplan") == "swarm.log.jump")
        for name in [
            "swarm.controller",
            "swarm.similar",
            "swarm.overrule",
            "swarm.log.who",
            "swarm.log.jump",
            "swarm.send",
        ] {
            #expect(Commands.all.contains { $0.name == name }, "\(name)")
        }
    }
}

struct SwarmControllerDraftTests {
    private func open(_ text: String) -> SwarmSteer {
        SwarmSteer(
            id: 1, swarm: "g/swarm-1", goal: "g", at: now, actor: .agent, kind: .question, text: text,
            state: .pending, from: "task:g/b"
        )
    }

    @Test func aQuestionWithNoOptionsGetsADraftOnlyForAReversibleChoice() async {
        let decider = FakeDecider { _ in nil }
        let draft: SwarmController.Draft = { _ in "  \"Call it TileCache.\"  " }
        let row = open("What should the cache type be called?")
        #expect(await SwarmController.decide(
            row,
            category: .implementation,
            history: [],
            decider: decider,
            draft: draft
        ) == .draft("Call it TileCache."))
        // Asked by you it is still only a draft, never an answer.
        #expect(await SwarmController.decide(
            row, category: .implementation, history: [], decider: decider, mode: .askedByYou, draft: draft
        ) == .draft("Call it TileCache."))
        // Not a reversible choice: no draft, whoever asks.
        #expect(await SwarmController.decide(
            row, category: .scope, history: [], decider: decider, mode: .askedByYou, draft: draft
        ) == .decline("the question has no options to pick from"))
        #expect(await SwarmController.decide(row, category: .deleteData, history: [], decider: decider, draft: draft)
            == .decline("deleting data is not the controller's to answer"))
        // A draft that has nothing to say is a decline.
        #expect(await SwarmController.decide(
            row, category: .implementation, history: [], decider: decider, draft: { _ in "NONE." }
        ) == .decline("the question has no options to pick from"))
        #expect(decider.asked.isEmpty)
    }

    @Test func theDraftIsCleanedUp() {
        #expect(SwarmController.draftAnswer("Answer: Use the default.") == "Use the default.")
        #expect(SwarmController.draftAnswer("“Keep it local.”") == "Keep it local.")
        #expect(SwarmController.draftAnswer("Keep it.\n\nAdd a test.") == "Keep it. Add a test.")
        #expect(SwarmController.draftAnswer("none") == nil)
        #expect(SwarmController.draftAnswer("   ") == nil)
        let long = SwarmController.draftAnswer(String(repeating: "a", count: 400))
        #expect(long?.count == SwarmController.draftLimit)
        #expect(long?.hasSuffix("…") == true)
    }

    @Test func theDraftReadsTheQuestionAndTheGoal() {
        let inputs = SwarmController.draftInputs(open("What should it be called?"), goal: "# Tiles")
        #expect(inputs.prompt.contains("Question: What should it be called?"))
        #expect(inputs.prompt.contains("# Tiles"))
    }
}
