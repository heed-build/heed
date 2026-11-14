import Foundation
@testable import HeedCore
import Testing

/// The new-goal wizard against real Claude Code on haiku: one planning turn as heed runs it (headless, read-only, in a
/// throwaway repo, the conversation on stdin), then the panel's read and the done-when draft through heed's model
/// calls.
/// Three calls in all. What claude printed is kept in the capture folder.
@Suite(.enabled(if: Live.enabled, "live: HEED_LIVE=1 calls a model"), .serialized)
struct LiveWizardTests {
    @Test(.timeLimit(.minutes(5))) func aPlanTurnThePanelAndTheCriteria() async throws {
        let folder = try Live.scratch("wizard")
        defer { try? FileManager.default.removeItem(at: folder) }
        let repo = try await Live.repo(in: folder, files: [
            "README.md": "# slugger\n\nTurns headings into URL anchors. `slug(\"Hello World\")` gives `hello-world`.\n",
        ])
        let claude = try Live.which("claude")
        let environment = Live.cleanEnvironment()

        // 1. One planning turn: the planner on haiku instead of opus (the model is the talker's to choose).
        let talker = PlanTalker(agent: "claude", command: claude, model: Live.model) { arguments, stdin, directory in
            let input = folder.appendingPathComponent("plan.in")
            try stdin.write(to: input, atomically: true, encoding: .utf8)
            let result = try await ProcessRunner.run(
                arguments[0], Array(arguments.dropFirst()), in: directory, environment: environment,
                timeout: .seconds(240), input: input, caller: "live.wizard"
            )
            Live.keep("wizard-plan.out", result.stdout + "\n--- stderr\n" + result.stderr)
            return result.stdout
        }
        var conversation = PlanConversation()
        conversation.answer("duplicate headings get the same anchor. fix it in slugger")
        let turn = try await talker.turn(
            title: "Unique anchors in slugger", statement: "", conversation: conversation, repos: [repo]
        )
        #expect(!turn.reply.question.isEmpty)
        #expect(turn.reply.options.count <= 3)
        #expect(!turn.reply.plan.steps.isEmpty)
        #expect(turn.cost.dollars != nil)
        #expect(turn.cost.model?.contains("haiku") == true)

        // 2 and 3. The panel and the criteria through heed's model calls, claude only, on its cheap model (haiku).
        let runner = LLMRunner(agents: AgentProfile.builtIn.filter { $0.name == "claude" })
        let calls = WizardCalls { request in
            let response = try await runner.run(request)
            Live.keep("wizard-\(request.operation ?? "call").out", response.text)
            return response
        }
        let plan = turn.reply.plan
        let seats = PanelInvites.invite(plan: plan, statement: "fix it in slugger", repos: ["slugger"])
        let (verdicts, panelCost) = try await calls.panel(plan: plan, seats: seats)
        #expect(verdicts.count == seats.count)
        #expect(verdicts.allSatisfy { !$0.quote.isEmpty })
        #expect(panelCost.model?.contains("haiku") == true)
        let (draft, _) = try await calls.draftDone(plan: plan, version: 1)
        #expect(!draft.criteria.isEmpty)
        #expect(draft.criteria.contains { $0.check.kind != .none })
    }
}
