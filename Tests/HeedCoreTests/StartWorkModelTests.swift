import Foundation
@testable import HeedCore
import Testing

/// Start work's model and effort fields: stepped with `h l`, Custom… typed, skipped when there is nothing to pick.
struct StartWorkModelTests {
    private let records = ["docs-toolkit"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func press(_ keys: String..., into form: inout StartWorkForm) {
        for key in keys {
            _ = form.handle(KeyStroke(key))
        }
    }

    private func form(agent: String = "claude") -> StartWorkForm {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix the docs build")
        form.choose(agent: agent)
        _ = form.handle(.escape)
        return form
    }

    @Test func modelAndEffortSitBetweenAgentAndOptions() {
        var form = form()
        form.focus(field: .agent)
        press("j", into: &form)
        #expect(form.field == .model)
        press("j", into: &form)
        #expect(form.field == .effort)
        press("j", into: &form)
        #expect(form.field == .options)
    }

    @Test func agentsWithoutEffortOrAShellSkipTheFields() {
        var gemini = form(agent: "gemini")
        #expect(gemini.fields == [.prompt, .repo, .worktree, .agent, .model, .options])
        gemini.focus(field: .model)
        press("j", into: &gemini)
        #expect(gemini.field == .options)
        var shell = form()
        shell.pickAgent(at: shell.agents.count - 1)
        #expect(shell.agent == nil)
        #expect(!shell.fields.contains(.model) && !shell.fields.contains(.effort))
    }

    @Test func hAndLStepModelsAndEffortsIntoTheCommand() throws {
        var form = form()
        form.focus(field: .model)
        press("l", "l", into: &form)
        #expect(form.model == "opus")
        form.focus(field: .effort)
        press("l", "l", "l", into: &form)
        #expect(form.effort == "high")
        let line = try #require(form.plan.command).posix
        #expect(line.contains("--model opus --effort high"))
        // Back to the defaults: nothing on the line.
        press("h", "h", "h", into: &form)
        form.focus(field: .model)
        press("h", "h", into: &form)
        #expect(form.model == nil && form.effort == nil)
        #expect(try !#require(form.plan.command).posix.contains("--model"))
    }

    @Test func aModelWithoutTheEffortDropsIt() {
        var form = form()
        form.pickModel("opus")
        form.pickEffort("xhigh")
        form.pickModel("claude-opus-4-6")
        #expect(form.effort == nil)
        form.pickEffort("high")
        form.pickModel("claude-haiku-4-5")
        #expect(form.effort == nil)
        #expect(!form.fields.contains(.effort))
    }

    @Test func customIsTypedAndMustNotBeEmpty() throws {
        var form = form()
        form.pickModel(ModelPicker.customTag)
        #expect(form.customModel && form.editing && form.field == .model)
        #expect(!form.canStart)
        #expect(form.modelProblem == "type a model id")
        _ = form.handle(KeyStroke("CR", .command))
        #expect(form.error == "type a model id, or pick a model")
        for char in "my model" {
            _ = form.handle(char == " " ? KeyStroke("Space") : KeyStroke(String(char)))
        }
        #expect(form.model == "mymodel")
        #expect(form.canStart)
        #expect(try #require(form.plan.command).posix.contains("--model mymodel"))
        form.paste(" -2\n")
        #expect(form.model == "mymodel-2")
    }

    @Test func anotherAgentStartsOnItsOwnDefaults() {
        var form = form()
        form.pickModel("opus")
        form.pickEffort("high")
        form.choose(agent: "codex")
        #expect(form.model == nil && form.effort == nil && !form.customModel)
        #expect(form.plan.model == nil)
    }

    @Test func listedModelsReachTheForm() {
        var form = form(agent: "codex")
        form.catalogs["codex"] = AgentModels.catalog("codex").merged(listed: [AgentModel("gpt-local", "Local")])
        form.focus(field: .model)
        press("l", into: &form)
        #expect(form.model == "gpt-local")
    }
}
