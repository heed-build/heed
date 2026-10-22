import Foundation
import HeedCore

/// How Settings' Test of one agent went.
struct LLMTest: Equatable {
    var running = false
    var answer: String?
    var error: String?
    var model: String?
    var seconds: Double?
    var cost: Double?
}

/// heed's own model calls (`[llm]`, `LLMRunner`): configured from config.toml, told which agents are rate limited in
/// a session, and seeded with today's spend from the call log. Features call `runLLM`, never the runner directly.
extension AppModel {
    /// The runner follows the config; Settings' detected states are refreshed with it.
    func configureLLM() {
        guard !isFixture else { return }
        let agents = config.work.agents
        let llmSettings = config.llm
        let prices = config.usage.prices
        let runner = llm
        Task {
            await runner.configure(agents: agents, settings: llmSettings, prices: prices)
            await refreshLLMStatuses()
        }
    }

    /// On launch: today's spend from the call log, so a restart does not reset the daily cap. Fixtures never detect or
    /// call anything (their login states are made up, `fixtureLLMStatuses`).
    func startLLM() async {
        guard !isFixture else { return }
        await llm.configure(agents: config.work.agents, settings: config.llm, prices: config.usage.prices)
        if let log = CallLog.active {
            await log.flush()
            var filter = CallFilter()
            filter.kinds = [.llm]
            filter.limit = 100_000
            let calls = await (try? log.store.calls(filter)) ?? []
            await llm.seedSpend(from: calls)
        }
    }

    /// Detects again (`force`: even what was detected a moment ago).
    func refreshLLMStatuses(force: Bool = false) async {
        guard !isFixture else { return }
        llmStatuses = await llm.statuses(force: force)
    }

    /// A model call, with the sessions' rate limits up to date.
    func runLLM(_ request: LLMRequest) async throws -> LLMResponse {
        await llm.setLimited(LLMRunner.limits(of: sessions))
        return try await llm.run(request)
    }

    /// Settings' Test: one tiny call to `agent` alone, never cached, shown with its answer and timing.
    func testLLM(agent: String) {
        guard !isFixture, llmTests[agent]?.running != true else { return }
        llmTests[agent] = LLMTest(running: true)
        let request = LLMRequest(
            call: LLMCall(
                system: "You check that a connection works. Reply in at most five words.",
                prompt: "Say hello."
            ),
            priority: .interactive, caller: "settings.test", operation: "test", agent: agent, cached: false
        )
        Task {
            do {
                let response = try await runLLM(request)
                llmTests[agent] = LLMTest(
                    answer: response.text.trimmingCharacters(in: .whitespacesAndNewlines), model: response.model,
                    seconds: response.duration, cost: response.cost
                )
            } catch {
                llmTests[agent] = LLMTest(error: "\(error)")
            }
            await refreshLLMStatuses()
        }
    }

    /// What the fake world's Settings shows: one agent of each login state.
    static let fixtureLLMStatuses: [LLMAgentStatus] = {
        let at = Date(timeIntervalSince1970: 0)
        func status(
            _ name: String,
            _ command: String,
            _ path: String?,
            _ login: LLMAgentStatus.Login,
            _ model: String?
        ) -> LLMAgentStatus {
            LLMAgentStatus(name: name, command: command, path: path, login: login, detectedModel: model, checkedAt: at)
        }
        return [
            status("claude", "claude", "/Users/you/.local/bin/claude", .loggedIn, "haiku"),
            status("codex", "codex", "/opt/homebrew/bin/codex", .loggedIn, "fast-model"),
            status("cursor", "cursor-agent", nil, .notInstalled, nil),
            status("pi", "pi", "/opt/homebrew/bin/pi", .loggedOut, nil),
            status("opencode", "opencode", "/opt/homebrew/bin/opencode", .loggedOut, nil),
            status("gemini", "gemini", nil, .notInstalled, nil),
        ]
    }()
}
