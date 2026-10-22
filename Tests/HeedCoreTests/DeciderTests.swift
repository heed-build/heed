import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// Answers every request with fixed JSON, and keeps the requests.
private final class FakeModel: Sendable {
    let reply: String
    let requests = Mutex<[LLMRequest]>([])
    init(_ reply: String) { self.reply = reply }

    var run: @Sendable (LLMRequest) async throws -> LLMResponse {
        { request in
            self.requests.withLock { $0.append(request) }
            return LLMResponse(
                text: self.reply, json: LLMDialect.jsonObject(in: self.reply), agent: "claude", model: "model-h",
                tokens: TokenCounts(input: 10, output: 5), cost: 0.0001
            )
        }
    }
}

struct DeciderTests {
    private let questions: [String: Question] = [
        "next": .choice(instructions: "What happens next?", options: ["merge", "fix", "wait"]),
        "risk": .score(instructions: "How risky is the change?", levels: ["low", "medium", "high"]),
        "stuck": .noul(instructions: "The agent is stuck."),
    ]

    private func log() throws -> CallLog {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("heed-decide-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return try CallLog(
            store: CallStore(path: folder.appendingPathComponent("log.sqlite").path),
            delay: .seconds(60)
        )
    }

    @Test func answersAreReadAndNormalized() async throws {
        let model = FakeModel("""
        {"next": {"probabilities": {"merge": 2, "fix": 1, "wait": 1}, "confidence": 0.8},
         "risk": {"probabilities": {"low": 0.25, "medium": 0.5, "high": 0.25}, "confidence": 0.6},
         "stuck": {"probability": 0.1, "confidence": 1.4}}
        """)
        let answers = try await LLMDecider(caller: "test", run: model.run)
            .decide(subject: "session-1", state: "PR open, checks green", questions: questions)
        let next = try #require(answers["next"])
        // Probabilities out of range are clamped to 0…1 before they are normalized.
        #expect(next.choice == "merge" && next.probabilities == ["merge": 1.0 / 3, "fix": 1.0 / 3, "wait": 1.0 / 3])
        let risk = try #require(answers["risk"])
        #expect(risk.choice == "medium" && risk.score == 1.0 && risk.confidence == 0.6)
        let stuck = try #require(answers["stuck"])
        #expect(stuck.probability == 0.1 && stuck.probabilities == ["true": 0.1, "false": 0.9] && stuck.confidence == 1)
    }

    @Test func theExpectedScoreWeighsTheLevels() async throws {
        let model =
            FakeModel(#"{"risk": {"probabilities": {"low": 0, "medium": 0.2, "high": 0.8}, "confidence": 0.5}}"#)
        let answers = try await LLMDecider(caller: "test", run: model.run)
            .decide(subject: "s", state: "x", questions: ["risk": questions["risk"]!])
        #expect(answers["risk"]?.choice == "high")
        #expect(abs((answers["risk"]?.score ?? 0) - 1.8) < 1e-9)
    }

    @Test func aTieGoesToTheOptionListedFirst() throws {
        let json = Data(#"{"next": {"probabilities": {"merge": 0.4, "fix": 0.4, "wait": 0.2}, "confidence": 0.5}}"#
            .utf8)
        let answers = try LLMDecider.answers(json, questions: ["next": questions["next"]!])
        #expect(answers["next"]?.choice == "merge")
    }

    @Test func answersThatDoNotFitAreRejected() throws {
        let cases: [(String, DeciderError)] = [
            (#"{"next": {"probabilities": {}, "confidence": 1}}"#, .badAnswer("next has no probabilities")),
            (#"{"other": {}}"#, .badAnswer("next missing")),
            (#"{"stuck": {"confidence": 1}}"#, .badAnswer("stuck has no probability")),
        ]
        for (reply, error) in cases {
            let subset = reply.contains("stuck") ? ["stuck": questions["stuck"]!] : ["next": questions["next"]!]
            #expect(throws: error) { try LLMDecider.answers(Data(reply.utf8), questions: subset) }
        }
    }

    @Test func theCallAsksForEveryQuestionWithASchema() async throws {
        let model = FakeModel(#"{"stuck": {"probability": 0.5, "confidence": 0.5}}"#)
        _ = try await LLMDecider(caller: "attention.rank", priority: .interactive, run: model.run)
            .decide(subject: "s", state: "the state", questions: ["stuck": questions["stuck"]!])
        let request = try #require(model.requests.withLock { $0.first })
        #expect(request.caller == "attention.rank" && request.priority == .interactive)
        #expect(request.operation == "decide stuck")
        #expect(request.call.prompt.contains("the state") && request.call.prompt.contains("The agent is stuck."))
        let schema = try JSONSerialization
            .jsonObject(with: Data(#require(request.call.schema).utf8)) as? [String: Any]
        #expect(schema?["required"] as? [String] == ["stuck"])
        let full = try JSONSerialization.jsonObject(with: Data(LLMDecider.schema(questions).utf8)) as? [String: Any]
        let next = (full?["properties"] as? [String: Any])?["next"] as? [String: Any]
        let probabilities = (next?["properties"] as? [String: Any])?["probabilities"] as? [String: Any]
        #expect(probabilities?["required"] as? [String] == ["merge", "fix", "wait"])
    }

    @Test func everyDecisionWritesADecideRowWithItsSubject() async throws {
        let log = try log()
        let good = FakeModel(#"{"stuck": {"probability": 0.7, "confidence": 0.9}}"#)
        let bad = FakeModel("no idea")
        try await CallLog.$current.withValue(log) {
            _ = try await LLMDecider(caller: "test", run: good.run)
                .decide(subject: "session-1", state: "s", questions: ["stuck": questions["stuck"]!])
            await #expect(throws: DeciderError.badAnswer("no JSON")) {
                try await LLMDecider(caller: "test", run: bad.run)
                    .decide(subject: "session-2", state: "s", questions: ["stuck": questions["stuck"]!])
            }
        }
        await log.flush()
        var filter = CallFilter()
        filter.kinds = [.decide]
        let rows = try await log.store.calls(filter)
        #expect(rows.count == 2)
        let ok = try #require(rows.first { $0.detail["subject"] == "session-1" })
        #expect(!ok.failed && ok.agent == "claude" && ok.model == "model-h" && ok.cost == 0.0001)
        #expect(ok.detail["questions"] == #"{"stuck":"noul"}"#)
        #expect(ok.detail["answers"]?.contains(#""probability":0.7"#) == true)
        let failed = try #require(rows.first { $0.detail["subject"] == "session-2" })
        #expect(failed.failed && failed.stderr?.contains("no JSON") == true && failed.detail["answers"] == nil)
    }

    @Test func nothingToDecideMakesNoCall() async {
        let model = FakeModel("{}")
        await #expect(throws: DeciderError.noQuestions) {
            try await LLMDecider(caller: "test", run: model.run).decide(subject: "s", state: "x", questions: [:])
        }
        #expect(model.requests.withLock { $0.isEmpty })
    }

    // MARK: Summaries

    @Test func summariesAddTheInstructionsToHeedsPrompt() async throws {
        let model = FakeModel("  Waiting on review; the redirect tests pass.\n")
        let inputs = SummaryInputs(
            title: "Fix broken anchors", repo: "acme/docs", branch: "fix/anchors", git: "abc123 Fix anchors",
            pullRequest: "#12 open, checks green", timeline: ["09:00 started", "09:40 PR opened"],
            lastMessage: "Done; opened the PR."
        )
        let summary = try await Summarizer(run: model.run)
            .summarize(
                kind: .session,
                inputs: inputs,
                instructions: "Mention the PR number.",
                caller: "history.summary"
            )
        #expect(summary == "Waiting on review; the redirect tests pass.")
        let request = try #require(model.requests.withLock { $0.first })
        #expect(request.call.system.hasPrefix(Summarizer.system(.session, instructions: "")))
        #expect(request.call.system.hasSuffix("Also: Mention the PR number."))
        #expect(request.call.schema == nil && request.cached && request.operation == "summarize session")
        for part in [
            "Work: Fix broken anchors",
            "Repo: acme/docs, branch fix/anchors",
            "## Git\nabc123",
            "## Timeline\n09:00",
            "## The agent's last message\nDone",
        ] {
            #expect(request.call.prompt.contains(part), "\(part)")
        }
        #expect(!SummaryInputs(title: "t").prompt.contains("##"))
    }

    @Test func longInputsKeepTheirEnd() {
        let text = String(repeating: "a", count: SummaryInputs.limit) + "the end"
        let cut = SummaryInputs.cut(text)
        #expect(cut.count == SummaryInputs.limit && cut.hasPrefix("…") && cut.hasSuffix("the end"))
        #expect(SummaryInputs.cut("short") == "short")
    }

    @Test func anEmptySummaryIsAnError() async {
        let model = FakeModel("   ")
        await #expect(throws: LLMError.self) {
            try await Summarizer(run: model.run).summarize(
                kind: .handoff,
                inputs: SummaryInputs(title: "t"),
                caller: "c"
            )
        }
    }

    @Test func summaryInstructionsResolveLikeTheOthers() throws {
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        summary_instructions = "Keep it short."
        [orgs.acme]
        summary_instructions = "Mention the ticket."
        [repos."acme/quiet"]
        summary_instructions = ""
        """)
        #expect(problems.isEmpty)
        let pilot = try #require(config?.pilot)
        #expect(pilot.resolve(Repo(org: "other", name: "x")).summaryInstructions == "Keep it short.")
        #expect(pilot.resolve(Repo(org: "acme", name: "api")).summaryInstructions == "Mention the ticket.")
        #expect(pilot.resolve(Repo(org: "acme", name: "quiet")).summaryInstructions == "")
    }
}
