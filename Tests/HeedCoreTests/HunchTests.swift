import Foundation
@testable import HeedCore
import Testing

/// An invented two-file checkpoint: what the catalogue would get from Hunch.
private let pinned: [(name: String, repository: String, revision: String, files: [HunchCheckpoint.File])] = [
    (
        "multilingual",
        "makers/laya-ml",
        "bbbb",
        [HunchCheckpoint.File(path: "model.safetensors", size: 600, sha256: "B")]
    ),
    ("english", "makers/laya", "aaaa", [
        HunchCheckpoint.File(path: "model.safetensors", size: 1000, sha256: "AB"),
        HunchCheckpoint.File(path: "tokenizer/tokenizer.json", size: 24, sha256: "cd"),
    ]),
    ("klingon", "makers/laya-tlh", "cccc", []),
]

private let english = HunchCatalogue.make(pinned)[0]

struct HunchCatalogueTests {
    @Test func theCatalogueJoinsHunchsFilesWithHeedsDetailsInHeedsOrder() {
        let catalogue = HunchCatalogue.make(pinned)
        // A checkpoint heed has no details for is left out; the order is heed's, not Hunch's.
        #expect(catalogue.map(\.id) == ["english", "multilingual"])
        #expect(english.title == "Laya English" && english.recommended && english.license == "Apache-2.0")
        #expect(english.totalSize == 1024)
        #expect(english.files[0].sha256 == "ab", "sha256 is lowercased")
        #expect(english.directoryName == "makers--laya/aaaa")
        #expect(english.sourceURL.absoluteString == "https://huggingface.co/makers/laya/tree/aaaa")
        #expect(
            english.url(for: english.files[1]).absoluteString
                == "https://huggingface.co/makers/laya/resolve/aaaa/tokenizer/tokenizer.json"
        )
        #expect(catalogue[1].recommended == false)
    }

    @Test func sizesReadLikeFinder() {
        #expect(HunchCatalogue.size(512) == "512 bytes")
        #expect(HunchCatalogue.size(4096) == "4 KiB")
        #expect(HunchCatalogue.size(842_609_210 + 3_586_364) == "807 MiB")
        #expect(HunchCatalogue.size(1_288_490_189) == "1.2 GiB")
        #expect(HunchCatalogue.size(-5) == "0 bytes")
    }
}

struct HunchDownloadTests {
    private let file = HunchCheckpoint.File(path: "model.safetensors", size: 1000, sha256: "ab")

    @Test func eachFileKnowsItsNextStep() {
        #expect(HunchDownloadPlan.step(for: file, staged: nil, verified: false) == .fetch(from: 0))
        #expect(HunchDownloadPlan.step(for: file, staged: 0, verified: false) == .fetch(from: 0))
        #expect(HunchDownloadPlan.step(for: file, staged: 400, verified: false) == .fetch(from: 400))
        #expect(HunchDownloadPlan.step(for: file, staged: 1000, verified: false) == .verify)
        #expect(HunchDownloadPlan.step(for: file, staged: 1000, verified: true) == .done)
        #expect(HunchDownloadPlan.step(for: file, staged: 1001, verified: true) == .restart)
        // A verified mark on a file that shrank does not count.
        #expect(HunchDownloadPlan.step(for: file, staged: 999, verified: true) == .fetch(from: 999))
    }

    @Test func theStateBeforeAnythingRunsComesFromTheDisk() {
        #expect(HunchDownloadPlan.state(english, staged: [:], verified: []) == .absent)
        let half = ["model.safetensors": Int64(500)]
        #expect(HunchDownloadPlan.state(english, staged: half, verified: []) == .partial(done: 500, total: 1024))
        let all = ["model.safetensors": Int64(1000), "tokenizer/tokenizer.json": 24]
        #expect(HunchDownloadPlan.state(english, staged: all, verified: ["model.safetensors"]) == .partial(
            done: 1024, total: 1024
        ))
        #expect(HunchDownloadPlan.state(
            english, staged: all, verified: ["model.safetensors", "tokenizer/tokenizer.json"]
        ) == .ready)
        // Bytes past a file's size never count.
        #expect(HunchDownloadPlan.completed(english, staged: ["model.safetensors": 5000]) == 1000)
    }

    @Test func aRangedReplyResumesOnlyFromWhereTheFileStopped() {
        #expect(HunchDownloadPlan.resume(from: 400, status: 206, contentRange: "bytes 400-999/1000") == .append)
        #expect(HunchDownloadPlan.resume(from: 400, status: 206, contentRange: "bytes 0-999/1000") == .fail(
            "the server resumed from the wrong place"
        ))
        #expect(HunchDownloadPlan.resume(from: 400, status: 206, contentRange: nil) == .fail(
            "the server resumed from the wrong place"
        ))
        #expect(HunchDownloadPlan.resume(from: 400, status: 200, contentRange: nil) == .replace)
        #expect(HunchDownloadPlan.resume(from: 1000, status: 416, contentRange: nil) == .replace)
        #expect(HunchDownloadPlan.resume(from: 0, status: 206, contentRange: "bytes 0-999/1000") == .replace)
        #expect(HunchDownloadPlan.resume(from: 0, status: 404, contentRange: nil) == .fail("HTTP 404"))
        #expect(HunchDownloadPlan.rangeStart("Bytes 12-20/30") == 12)
        #expect(HunchDownloadPlan.rangeStart("items 12-20/30") == nil)
    }

    @Test func theStateSaysHowFarAlong() {
        #expect(HunchDownloadState.downloading(done: 256, total: 1024, file: "x").fraction == 0.25)
        #expect(HunchDownloadState.downloading(done: 0, total: 0, file: "x").fraction == nil)
        #expect(HunchDownloadState.ready.fraction == nil)
        #expect(HunchDownloadState.verifying(file: "x", done: 1, total: 2).isActive)
        #expect(!HunchDownloadState.partial(done: 1, total: 2).isActive)
    }
}

struct HunchRoutingTests {
    private let weight = AttentionDecide.questions["weight"]!

    @Test func hunchTakesStatementsScalesAndAFewShortOptions() {
        #expect(HunchRouting.hunchTakes(.noul(instructions: "It is stuck.")))
        #expect(HunchRouting.hunchTakes(weight), "Attention's six levels are Hunch's")
        #expect(HunchRouting.hunchTakes(.choice(instructions: "x", options: ["a", "b", "c", "d", "e"])))
        #expect(!HunchRouting.hunchTakes(.choice(instructions: "x", options: ["a", "b", "c", "d", "e", "f"])))
        #expect(!HunchRouting.hunchTakes(.score(instructions: "x", levels: (1 ... 7).map(String.init))))
        #expect(!HunchRouting.hunchTakes(.choice(instructions: "x", options: ["a", String(repeating: "b", count: 41)])))
        #expect(HunchRouting.hunchTakes(.choice(instructions: "x", options: ["a", String(repeating: "b", count: 40)])))
    }

    @Test func theRestGoesOnDeviceFirstThenToAModelCall() {
        #expect(HunchRouting.overflow(localReady: true, modelCalls: true) == .local)
        #expect(HunchRouting.overflow(localReady: false, modelCalls: true) == .model)
        #expect(HunchRouting.overflow(localReady: false, modelCalls: false) == DecisionRoute.none)
        let questions: [String: Question] = [
            "weight": weight, "same": .choice(instructions: "x", options: ["a", "b", "c", "d", "e", "new"]),
        ]
        #expect(HunchRouting.routes(questions, hunchReady: true, localReady: false, modelCalls: true) == [
            "weight": .hunch, "same": .model,
        ])
        // Without a model, everything goes where the rest goes.
        #expect(HunchRouting.routes(questions, hunchReady: false, localReady: true, modelCalls: true) == [
            "weight": .local, "same": .local,
        ])
        #expect(HunchRouting.summary(localReady: true, modelCalls: true).hasSuffix("go to Apple's on-device model."))
        #expect(HunchRouting.summary(localReady: false, modelCalls: false).contains("go unanswered"))
    }

    @Test func aRoutedDecisionAsksEachPartOfItsDeciderAndMergesTheAnswers() async throws {
        let hunch = RecordingDecider(name: "hunch")
        let local = RecordingDecider(name: "local")
        let decider = RoutedDecider(deciders: [.hunch: hunch, .local: local]) {
            HunchRouting.routes($0, hunchReady: true, localReady: true, modelCalls: true)
        }
        let answers = try await decider.decide(subject: "s", state: "x", questions: [
            "weight": weight, "stuck": .noul(instructions: "It is stuck."),
            "same": .choice(instructions: "x", options: ["a", "b", "c", "d", "e", "new"]),
        ])
        #expect(await hunch.asked == [["stuck", "weight"]])
        #expect(await local.asked == [["same"]])
        #expect(answers.mapValues(\.choice) == ["weight": "hunch", "stuck": "hunch", "same": "local"])
    }

    @Test func aQuestionNothingCanAnswerFailsTheDecision() async throws {
        let decider = RoutedDecider(deciders: [.hunch: RecordingDecider(name: "hunch")]) {
            HunchRouting.routes($0, hunchReady: true, localReady: false, modelCalls: false)
        }
        await #expect(throws: DeciderError.unavailable("no decider can answer same on this Mac")) {
            try await decider.decide(subject: "s", state: "x", questions: [
                "same": .choice(instructions: "x", options: ["a", "b", "c", "d", "e", "new"]),
            ])
        }
        await #expect(throws: DeciderError.noQuestions) {
            try await decider.decide(subject: "s", state: "x", questions: [:])
        }
    }

    @Test func hunchDecisionsWriteDecideRowsWithTheModelTheyUsed() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-hunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let log = try CallLog(
            store: CallStore(path: folder.appendingPathComponent("log.sqlite").path), delay: .seconds(60)
        )
        let answer = Answer(probability: 0.8, probabilities: ["true": 0.8, "false": 0.2], confidence: 0.8)
        try await CallLog.$current.withValue(log) {
            let good = HunchDecider(caller: "attention.rank", model: "laya-english+head-1") { _, _ in
                ["stuck": answer, "extra": answer]
            }
            let answers = try await good.decide(
                subject: "item-1", state: "s", questions: ["stuck": .noul(instructions: "It is stuck.")]
            )
            #expect(answers.keys.sorted() == ["stuck"], "only what was asked")
            let missing = HunchDecider(caller: "attention.rank", model: "laya-english") { _, _ in [:] }
            await #expect(throws: DeciderError.badAnswer("stuck missing")) {
                try await missing.decide(
                    subject: "item-2", state: "s", questions: ["stuck": .noul(instructions: "It is stuck.")]
                )
            }
        }
        await log.flush()
        var filter = CallFilter()
        filter.kinds = [.decide]
        let rows = try await log.store.calls(filter)
        let ok = try #require(rows.first { $0.detail["subject"] == "item-1" })
        #expect(ok.agent == "hunch" && ok.model == "laya-english+head-1" && !ok.failed)
        #expect(ok.detail["questions"] == #"{"stuck":"noul"}"# && ok.detail["state"] == "s")
        #expect(ok.detail["answers"]?.contains(#""probability":0.8"#) == true)
        let failed = try #require(rows.first { $0.detail["subject"] == "item-2" })
        #expect(failed.failed && failed.stderr?.contains("stuck missing") == true)
    }
}

/// Answers every question with its own name as the choice, and remembers what it was asked.
private actor RecordingDecider: Decider {
    let name: String
    var asked: [[String]] = []

    init(name: String) {
        self.name = name
    }

    func decide(subject _: String, state _: String, questions: [String: Question]) async throws -> [String: Answer] {
        asked.append(questions.keys.sorted())
        return questions.mapValues { _ in Answer(choice: name, probabilities: [name: 1], confidence: 1) }
    }
}

struct HunchTrainingSetTests {
    private let day = Date(timeIntervalSince1970: 1_900_000_000)

    private func label(_ subject: String, _ label: String, at: TimeInterval, state: String? = nil) -> LoggedCall {
        var detail = ["subject": subject, "label": label]
        if let state { detail["state"] = state }
        return LoggedCall(
            at: day.addingTimeInterval(at), kind: .decide, caller: "attention.label", command: "label", duration: 0,
            detail: detail
        )
    }

    private func asked(_ subject: String, state: String, at: TimeInterval) -> LoggedCall {
        LoggedCall(
            at: day.addingTimeInterval(at), kind: .decide, caller: "attention.rank", command: "decide", duration: 0,
            detail: ["subject": subject, "state": state]
        )
    }

    @Test func attentionActionsBecomeWeightsOfTheItemsState() throws {
        let examples = HunchTrainingSet.attention(
            labels: [
                label("pr-1", "mute", at: 100, state: "a noisy bot thread"),
                label("pr-2", "boost", at: 100),
                label("pr-3", "snooze", at: 100),
                label("pr-4", "flag", at: 100, state: "x"),
            ],
            decisions: [
                asked("pr-2", state: "old review request", at: 10),
                asked("pr-2", state: "review request", at: 50),
                asked("pr-2", state: "after the label", at: 200),
            ]
        ).sorted { $0.id < $1.id }
        // pr-3 has no state anywhere, pr-4's label teaches nothing: both left out.
        #expect(examples.map(\.id) == ["attention:pr-1", "attention:pr-2"])
        #expect(examples[0].answer == "ignore" && examples[0].weight == 1 && examples[0].state == "a noisy bot thread")
        // The newest state asked before the label.
        #expect(examples[1].answer == "boost 1" && examples[1].state == "review request")
        #expect(examples[1].question == AttentionDecide.questions["weight"])
        #expect(examples.allSatisfy { $0.family == .attention })
    }

    @Test func aLabelRowCarriesTheItemAsTheDeciderSeesIt() throws {
        let item = AttentionItem(
            id: "acme/widgets#7", kind: .pr, repo: Repo(org: "acme", name: "widgets"), number: 7,
            title: "Retry uploads", url: nil, reasons: [.reviewRequested], updatedAt: day
        )
        let call = AttentionLabel.mute.call(for: item, rule: nil, suggestion: nil, at: day, state: "Retry uploads …")
        #expect(call.detail["state"] == "Retry uploads …")
        #expect(AttentionLabel.mute.call(for: item, rule: nil, suggestion: nil, at: day).detail["state"] == nil)
        let examples = HunchTrainingSet.attention(labels: [call], decisions: [])
        #expect(examples.first?.state == "Retry uploads …" && examples.first?.answer == "ignore")
    }

    @Test func theNewestLabelOfAnItemWins() {
        let examples = HunchTrainingSet.attention(
            labels: [label("pr-1", "snooze", at: 100, state: "s"), label("pr-1", "done", at: 300, state: "s")],
            decisions: []
        )
        #expect(examples.count == 1 && examples[0].answer == "normal" && examples[0].weight == 0.5)
    }

    private func decision(
        _ id: Int64, _ state: AttachDecision.State, proposed: String?, goal: String?, action: AttachAction = .ask
    ) -> AttachDecision {
        AttachDecision(
            id: id,
            subject: AttachSubject(
                kind: .session, id: "s\(id)", title: "Fix the flaky upload test", prompt: "make uploads retry",
                repos: ["acme/widgets"], branch: "fix-upload", files: ["Upload.swift"], pulls: ["acme/widgets#4"],
                at: day
            ),
            trigger: .started, verdict: AttachVerdict(action: action, goal: proposed, reason: "signals"),
            state: state, goal: goal, resolvedAt: day, at: day
        )
    }

    @Test func attachCorrectionsSayWhetherAThingBelongsToAGoal() throws {
        let titles = ["uploads": "Reliable uploads", "docs": "Docs refresh"]
        let examples = HunchTrainingSet.attach([
            decision(1, .accepted, proposed: "uploads", goal: "uploads"),
            decision(2, .declined, proposed: "docs", goal: nil),
            decision(3, .undone, proposed: "docs", goal: nil, action: .attach),
            decision(4, .moved, proposed: "docs", goal: "uploads"),
            decision(5, .ignored, proposed: "docs", goal: nil),
            decision(6, .open, proposed: "docs", goal: nil),
            decision(7, .settled, proposed: "docs", goal: "docs", action: .attach),
        ], goalTitles: titles)
        let pairs = examples.map { "\($0.id)=\($0.answer)" }
        #expect(pairs == [
            "attach:1:uploads=true", "attach:2:docs=false", "attach:3:docs=false", "attach:4:docs=false",
            "attach:4:uploads=true",
        ])
        #expect(examples[0].question == .noul(instructions: "This work belongs to the goal \"Reliable uploads\"."))
        #expect(examples[0].state == """
        Session: Fix the flaky upload test
        Asked: make uploads retry
        Repos: acme/widgets
        Branch: fix-upload
        Files: Upload.swift
        Links: acme/widgets#4
        """)
        // A goal without a known title is named by its slug.
        #expect(HunchTrainingSet.attach([decision(8, .declined, proposed: "gone", goal: nil)], goalTitles: [:])[0]
            .question == .noul(instructions: "This work belongs to the goal \"gone\"."))
    }

    private func snapshot(_ state: AgentState, _ source: ScreenSnapshot.Source, at: TimeInterval) -> ScreenSnapshot {
        ScreenSnapshot(
            at: day.addingTimeInterval(at), session: "s1", agent: "claude", state: state, previous: .working,
            source: source, remote: false, text: "Allow edits to Package.swift? [y/n]"
        )
    }

    @Test func labelledScreensSayWhetherTheAgentWaits() {
        let examples = HunchTrainingSet.screens([
            snapshot(.asking, .reported, at: 1), snapshot(.blocked, .reported, at: 2),
            snapshot(.working, .sampled, at: 3), snapshot(.done, .reported, at: 4),
            snapshot(.asking, .guessed, at: 5),
        ])
        #expect(examples.map(\.answer) == ["true", "true", "false"])
        var long = snapshot(.asking, .reported, at: 9)
        long.text = (1 ... 30).map { "line \($0)" }.joined(separator: "\n")
        let kept = HunchTrainingSet.screens([long])[0].state.split(separator: "\n")
        #expect(kept.count == 20 && kept.first == "line 11" && kept.last == "line 30")
        #expect(examples[0].id == "screen:s1:1900000001000" && examples[0].question == HunchTrainingSet.waitingQuestion)
    }

    private func example(_ id: String, _ family: HunchFamily, at: TimeInterval, answer: String = "true")
        -> HunchExample
    {
        HunchExample(
            id: id, family: family, state: "s", question: HunchTrainingSet.waitingQuestion, answer: answer, weight: 1,
            at: day.addingTimeInterval(at)
        )
    }

    @Test func mergingReplacesByIDAndKeepsTheNewestWithinTheCaps() {
        let merged = HunchTrainingSet.merge(
            [example("a", .screens, at: 1, answer: "true"), example("b", .screens, at: 2)],
            [example("a", .screens, at: 3, answer: "false"), example("c", .attach, at: 0)]
        )
        #expect(merged.map(\.id) == ["a", "b", "c"])
        #expect(merged[0].answer == "false")
        // An older copy never replaces a newer one.
        #expect(HunchTrainingSet.merge([example("a", .screens, at: 5)], [example("a", .screens, at: 1, answer: "x")])[0]
            .answer == "true")

        let many = (0 ..< HunchTrainingSet.maxPerFamily + 10).map { example("s\($0)", .screens, at: Double($0)) }
        let capped = HunchTrainingSet.merge(many, [example("t", .attach, at: -1)])
        #expect(HunchTrainingSet.counts(capped) == [.screens: HunchTrainingSet.maxPerFamily, .attach: 1])
        #expect(capped.first?.id == "s\(HunchTrainingSet.maxPerFamily + 9)", "the newest are kept")
        let lots = (0 ..< HunchTrainingSet.maxExamples).flatMap { index in
            HunchFamily.allCases.map { example("\($0.rawValue)\(index)", $0, at: Double(index)) }
        }
        #expect(HunchTrainingSet.merge(lots, []).count == HunchTrainingSet.maxExamples)
    }

    @Test func oneInFiveIsHeldOutAndStaysHeldOut() {
        let examples = (0 ..< 1000).map { example("screen:s:\($0)", .screens, at: Double($0)) }
        let (train, heldOut) = HunchTrainingSet.split(examples)
        #expect(train.count + heldOut.count == 1000)
        #expect((175 ... 225).contains(heldOut.count), "\(heldOut.count) of 1000")
        #expect(heldOut.allSatisfy(\.heldOut) && !train.contains(where: \.heldOut))
        // By id, not by position: the same example is held out in a larger set.
        let more = HunchTrainingSet.split(examples + [example("new", .attach, at: 5000)]).heldOut
        #expect(Set(heldOut.map(\.id)).isSubset(of: Set(more.map(\.id))))
        #expect(HunchTrainingSet.hash("abc") == 0xE71F_A219_0541_574B, "FNV-1a, the same on every Mac")
    }

    @Test func theSetRoundTripsThroughItsFileAndSurvivesADamagedLine() {
        let examples = [example("a", .screens, at: 1), example("b", .attach, at: 2)]
        var data = HunchTrainingSet.encode(examples)
        #expect(HunchTrainingSet.encode(examples.reversed()) == data, "sorted, so the file only changes with the set")
        data.append(Data("{not json\n".utf8))
        #expect(HunchTrainingSet.decode(data) == examples.sorted(by: HunchTrainingSet.newestFirst))
    }

    @Test func longStatesAreCut() {
        let long = String(repeating: "a", count: 5000) + "END"
        #expect(HunchTrainingSet.trimmed(long, keepEnd: true).hasSuffix("END"))
        #expect(HunchTrainingSet.trimmed(long, keepEnd: false).count == HunchTrainingSet.maxStateLength)
        #expect(HunchTrainingSet.trimmed("short", keepEnd: true) == "short")
    }
}

struct HunchLearningTests {
    private let now = Date(timeIntervalSince1970: 1_900_000_000)
    private let idle = HunchConditions(idleSeconds: 600, onPower: true, thermal: 0, lowPowerMode: false)

    @Test func aNewHeadIsAdoptedOnlyWhenItIsNoWorseOnHeldOutExamples() {
        let before = HunchScore(count: 20, correct: 14, loss: 0.6)
        #expect(HunchAdopt.verdict(before: before, after: HunchScore(count: 20, correct: 16, loss: 0.9)) == .adopt)
        #expect(HunchAdopt.verdict(before: before, after: HunchScore(count: 20, correct: 14, loss: 0.5)) == .adopt)
        #expect(HunchAdopt.verdict(before: before, after: HunchScore(count: 20, correct: 13, loss: 0.1)) == .keep(
            "worse on held-out examples: 65% (13 of 20) against 70% (14 of 20)"
        ))
        #expect(HunchAdopt.verdict(before: before, after: HunchScore(count: 20, correct: 14, loss: 0.7)) == .keep(
            "no better on held-out examples (70% (14 of 20)) and less sure of the right answers"
        ))
        #expect(HunchAdopt.verdict(before: before, after: before) == .keep(
            "no different on held-out examples (70% (14 of 20))"
        ))
        #expect(HunchAdopt.verdict(
            before: HunchScore(count: 9, correct: 1, loss: 2), after: HunchScore(count: 9, correct: 9, loss: 0)
        ) == .keep("only 9 held-out examples, 10 needed to judge"))
    }

    @Test func trainingWaitsForExamplesIdlenessAndPower() {
        let fresh = HunchLearningRecord()
        func due(
            _ record: HunchLearningRecord = HunchLearningRecord(), examples: Int = 100, heldOut: Int = 20,
            when conditions: HunchConditions? = nil, asked: Bool = false
        ) -> HunchSchedule.Due {
            HunchSchedule.due(
                now: now, record: record, examples: examples, heldOut: heldOut, conditions: conditions ?? idle,
                asked: asked
            )
        }
        #expect(due(fresh) == .train)
        #expect(due(examples: 29, heldOut: 10) == .wait(
            "waiting for 30 examples with 10 held out (29 so far, 10 held out)"
        ))
        #expect(due(examples: 100, heldOut: 9) == .wait(
            "waiting for 30 examples with 10 held out (100 so far, 9 held out)"
        ))
        #expect(due(when: HunchConditions(idleSeconds: 10, onPower: true, thermal: 0, lowPowerMode: false)) == .wait(
            "waiting until the Mac is idle"
        ))
        #expect(due(when: HunchConditions(idleSeconds: 999, onPower: false, thermal: 0, lowPowerMode: false)) == .wait(
            "on battery: training waits for power"
        ))
        #expect(due(when: HunchConditions(idleSeconds: 999, onPower: true, thermal: 2, lowPowerMode: false)) == .wait(
            "the Mac is hot: training waits"
        ))
        #expect(due(when: HunchConditions(idleSeconds: 999, onPower: true, thermal: 1, lowPowerMode: true)) == .wait(
            "Low Power Mode is on"
        ))
        let recent = HunchLearningRecord(trainedAt: now.addingTimeInterval(-3600), examplesAtRun: 90)
        #expect(due(recent) == .wait("next run after 20 new examples (10 so far)"))
        #expect(due(recent, examples: 110) == .wait("trained less than 12 hours ago"))
        let old = HunchLearningRecord(trainedAt: now.addingTimeInterval(-13 * 3600), examplesAtRun: 90)
        #expect(due(old, examples: 110) == .train)
        // Retrain now skips the counts and the idle wait, not the power.
        let busy = HunchConditions(idleSeconds: 0, onPower: true, thermal: 0, lowPowerMode: false)
        #expect(due(recent, when: busy, asked: true) == .train)
        #expect(due(
            recent,
            when: HunchConditions(idleSeconds: 0, onPower: false, thermal: 0, lowPowerMode: false),
            asked: true
        ) == .wait("on battery: training waits for power"))
        #expect(due(examples: 5, heldOut: 1, asked: true) == .wait(
            "waiting for 30 examples with 10 held out (5 so far, 1 held out)"
        ))
    }

    @Test func aRunStopsWhenYouUseTheMacUnlessYouAskedForIt() {
        let active = HunchConditions(idleSeconds: 3, onPower: true, thermal: 0, lowPowerMode: false)
        #expect(HunchSchedule.shouldStop(active, asked: false) == "stopped: you are using the Mac")
        #expect(HunchSchedule.shouldStop(active, asked: true) == nil)
        #expect(HunchSchedule.shouldStop(idle, asked: false) == nil)
        #expect(HunchSchedule.shouldStop(
            HunchConditions(idleSeconds: 999, onPower: true, thermal: 3, lowPowerMode: false), asked: true
        ) == "the Mac is hot: training waits")
    }

    @Test func theStatusFollowsTheDownloadAndTraining() {
        #expect(HunchStatus.of(supported: false, download: .ready, training: nil) == .unavailable(
            "Hunch needs a Mac with Apple silicon."
        ))
        #expect(HunchStatus.of(supported: true, download: .absent, training: nil) == .noModel)
        #expect(HunchStatus.of(supported: true, download: .downloading(done: 1, total: 4, file: "x"), training: nil)
            == .downloading(0.25))
        #expect(HunchStatus.of(supported: true, download: .partial(done: 2, total: 4), training: nil)
            == .stopped(0.5, nil))
        #expect(HunchStatus.of(supported: true, download: .failed("offline", done: 0, total: 4), training: nil)
            == .stopped(0, "offline"))
        #expect(HunchStatus.of(supported: true, download: .ready, training: nil) == .ready)
        #expect(HunchStatus.of(supported: true, download: .ready, training: .some(0.5)) == .learning(0.5))
        #expect(HunchStatus.of(supported: true, download: .ready, training: .some(nil)) == .learning(nil))
        #expect(HunchStatus.learning(nil).label == "learning" && HunchStatus.noModel.label == "no model")
        #expect(HunchStatus.ready.modelReady && !HunchStatus.downloading(0.4).modelReady)
    }

    @Test func learningIsOnOnceAModelIsDownloadedUnlessSaidOtherwise() {
        #expect(HunchSettings().learns(modelReady: true))
        #expect(!HunchSettings().learns(modelReady: false))
        #expect(!HunchSettings(learn: false).learns(modelReady: true))
        #expect(HunchSettings().effectiveCheckpoint == "english")
    }

    @Test func onlyTheHeadInUseIsKept() {
        let name = HunchFolder.headName(checkpoint: "english", at: now)
        #expect(name == "english-1900000000.safetensors")
        #expect(HunchFolder.headsToDelete(
            ["english-1.safetensors", name, "notes.txt", "english-2.safetensors"], inUse: name
        ) == ["english-1.safetensors", "english-2.safetensors"])
        #expect(HunchFolder.headsToDelete([name], inUse: nil) == [name])
        let folder = HunchFolder(root: URL(fileURLWithPath: "/m"))
        #expect(folder.staging(english).path == "/m/.partial/makers--laya--aaaa")
        #expect(folder.checkpoint(english).path == "/m/makers--laya/aaaa")
        #expect(folder.head(name).path == "/m/learning/heads/\(name)")
    }

    @Test func diskUsageIsSummedForThePane() {
        let usage = HunchDiskUsage(
            checkpoints: ["english": 846_195_574], partial: 0, examples: 2_100_000, heads: 52_000_000
        )
        #expect(usage.summary(titles: ["english": "Laya English"])
            == "859 MiB: Laya English 807 MiB, training set 2 MiB, trained head 50 MiB")
        #expect(HunchDiskUsage().summary(titles: [:]) == "Nothing yet.")
    }
}

struct HunchSetupTests {
    private func evaluate(
        _ decider: DecisionSettings.Choice?, hunch: HunchStatus, local: LocalModel = .unsupported
    ) -> InferenceSetup {
        var llm = LLMSettings()
        llm.agent = "claude"
        return InferenceSetup.evaluate(
            llm: llm, decisions: DecisionSettings(decider: decider), statuses: nil, local: local, tests: SetupTests(),
            hunch: hunch
        )
    }

    @Test func hunchsStateIsTheDecisionsState() {
        #expect(evaluate(.hunch, hunch: .ready).decisions == .configured(
            "Hunch on this Mac; choices among many options go to a model call."
        ))
        #expect(evaluate(.hunch, hunch: .ready, local: .available).decisions.detail.hasSuffix(
            "go to Apple's on-device model."
        ))
        #expect(evaluate(.hunch, hunch: .learning(0.3)).decisions.label == "configured")
        #expect(evaluate(.hunch, hunch: .noModel).decisions == .failing(
            "Hunch has no model yet: download one below. Until then decisions go to a model call."
        ))
        // Without a model, decisions still go somewhere: nothing is listed as going without.
        #expect(evaluate(.hunch, hunch: .noModel).degraded.isEmpty)
        #expect(!evaluate(.local, hunch: .noModel).degraded.isEmpty, "the on-device model is not on this Mac")
        #expect(evaluate(.hunch, hunch: .downloading(0.42)).decisions == .configured(
            "Hunch's model is downloading 42%. Until then decisions go to a model call."
        ))
        #expect(evaluate(.hunch, hunch: .stopped(0.5, "offline")).decisions == .failing(
            "Hunch's download stopped 50% (offline): Download resumes it. Until then decisions go to a model call."
        ))
        #expect(evaluate(.hunch, hunch: .unavailable("Hunch needs a Mac with Apple silicon.")).decisions == .failing(
            "Hunch needs a Mac with Apple silicon."
        ))
    }

    @Test func theReminderSaysWhereHunchIs() {
        func reminder(_ hunch: HunchStatus, _ decider: DecisionSettings.Choice? = .hunch) -> String? {
            evaluate(decider, hunch: hunch).reminder(enabled: true, hiddenThisLaunch: false)
        }
        #expect(reminder(.noModel) == "Hunch has no model")
        #expect(reminder(.downloading(0.42)) == "Hunch downloading 42%")
        #expect(reminder(.stopped(0.5, nil)) == "Hunch's download stopped")
        #expect(reminder(.ready) == nil)
        #expect(reminder(.learning(nil)) == nil)
        // Hunch's state is not news when another decider is chosen.
        #expect(reminder(.noModel, .model) == nil)
    }

    @Test func aDownloadedModelIsSuggestedButSetUpNeverDownloadsOne() {
        #expect(InferenceSetup.suggestedDecider(local: .available, agent: "claude", hunch: .ready) == .hunch)
        #expect(InferenceSetup.suggestedDecider(local: .available, agent: "claude", hunch: .noModel) == .local)
        #expect(InferenceSetup.suggestedDecider(local: .unsupported, agent: nil, hunch: .downloading(0.1)) == .off)
        #expect(InferenceSetup.name(.hunch) == "Hunch")
        // Chosen, Hunch stays the suggestion: Set up never trades it away while the model is missing.
        #expect(evaluate(.hunch, hunch: .noModel, local: .available).suggestedDecider == .hunch)
        #expect(evaluate(nil, hunch: .noModel, local: .available).suggestedDecider == .local)
    }

    @Test func configChoosesHunchAndItsCheckpoint() throws {
        let (decoded, problems) = ConfigLoader.decode("""
        [decisions]
        decider = "hunch"
        [hunch]
        checkpoint = "Multilingual"
        learn = false
        """)
        #expect(problems.isEmpty)
        let config = try #require(decoded)
        #expect(config.decisions.decider == .hunch)
        #expect(config.hunch == HunchSettings(checkpoint: "multilingual", learn: false))
        let (bad, badProblems) = ConfigLoader.decode("[hunch]\ncheckpoint = \"klingon\"\n")
        #expect(bad?.hunch.checkpoint == nil)
        #expect(badProblems.map(\.message) == ["expected english or multilingual"])
        let (unset, _) = ConfigLoader.decode("")
        #expect(unset?.hunch == HunchSettings())
    }
}
