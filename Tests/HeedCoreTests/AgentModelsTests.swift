import Foundation
@testable import HeedCore
import Testing

/// The model catalogue, the pickers' logic, and how a picked model and effort reach each agent's command line.
struct AgentModelsTests {
    private func agent(_ name: String) throws -> AgentProfile {
        try #require(AgentProfile.builtIn.first { $0.name == name })
    }

    // MARK: The seed

    @Test func everyBuiltInHasACatalogueWithUniqueIds() {
        for agent in AgentProfile.builtIn {
            let catalog = AgentModels.catalog(agent.name)
            #expect(catalog.agent == agent.name)
            #expect(Set(catalog.models.map(\.id)).count == catalog.models.count, "\(agent.name)")
            #expect(!catalog.source.isEmpty, "\(agent.name)")
        }
        // cursor-agent documents no ids: it lists its own.
        #expect(AgentModels.catalog("cursor").models.isEmpty)
        #expect(AgentModels.catalog("mytool").models.isEmpty)
    }

    @Test func effortsFollowTheModel() {
        let claude = AgentModels.catalog("claude")
        #expect(claude.models.first?.id == "fable")
        #expect(claude.efforts(for: nil) == ["low", "medium", "high", "xhigh", "max"])
        #expect(claude.efforts(for: "claude-opus-4-6") == ["low", "medium", "high", "max"])
        #expect(claude.efforts(for: "claude-haiku-4-5").isEmpty)
        #expect(claude.defaultEffort(for: "opus") == "medium")
        #expect(claude.defaultEffort(for: "claude-opus-4-7") == "xhigh")
        // An unknown id gets the agent's levels.
        #expect(claude.efforts(for: "claude-next") == claude.efforts)
        let codex = AgentModels.catalog("codex")
        #expect(codex.efforts(for: "gpt-5.5") == ["low", "medium", "high", "xhigh"])
        #expect(codex.efforts(for: "gpt-6.1-sol").last == "ultra")
        #expect(AgentModels.catalog("opencode").efforts.isEmpty)
        #expect(AgentModels.catalog("gemini").efforts.isEmpty)
        #expect(AgentModels.catalog("pi").defaultEffort == "medium")
    }

    @Test func aProfileWithoutFlagsHasNothingToPick() throws {
        var claude = try agent("claude")
        #expect(!AgentModels.catalog(for: claude).efforts.isEmpty)
        claude.effortFlag = nil
        let noEffort = AgentModels.catalog(for: claude)
        #expect(noEffort.efforts.isEmpty)
        #expect(noEffort.efforts(for: "opus").isEmpty)
        claude.modelFlag = nil
        let nothing = AgentModels.catalog(for: claude)
        #expect(!nothing.takesModel && nothing.models.isEmpty)
    }

    @Test func aConfiguredModelAndEffortNameTheDefault() throws {
        var claude = try agent("claude")
        claude.model = "opus"
        claude.effort = "high"
        let catalog = AgentModels.catalog(for: claude)
        #expect(ModelPicker.models(catalog).first?.label == "default (opus)")
        #expect(ModelPicker.efforts(catalog, model: "sonnet").first?.label == "default (high)")
        // Haiku 4.5 takes no effort, configured or not.
        #expect(ModelPicker.efforts(catalog, model: "claude-haiku-4-5").isEmpty)
    }

    // MARK: Listings

    @Test func codexListingKeepsListedModelsByPriorityWithTheirEfforts() {
        let listing = """
        {"models": [
          {"slug": "gpt-b", "display_name": "B", "visibility": "list", "priority": 2,
           "default_reasoning_level": "medium",
           "supported_reasoning_levels": [{"effort": "low"}, {"effort": "medium"}]},
          {"slug": "gpt-hidden", "display_name": "Hidden", "visibility": "hide", "priority": 0},
          {"slug": "gpt-a", "display_name": "A", "visibility": "list", "priority": 1}
        ]}
        """
        let models = AgentModels.listed(.codex, listing: listing)
        #expect(models.map(\.id) == ["gpt-a", "gpt-b"])
        #expect(models[1].efforts == ["low", "medium"])
        #expect(models[1].defaultEffort == "medium")
        #expect(models[0].efforts == nil)
        #expect(AgentModels.listed(.codex, listing: "not json").isEmpty)
        #expect(AgentModels.listed(.claude, listing: listing).isEmpty)
    }

    @Test func opencodeListingIsNewestFirstFromLoggedInProviders() {
        let listing = """
        acme/old
        {
          "providerID": "acme", "name": "Old", "release_date": "2026-01-01", "status": "active"
        }
        acme/new
        {
          "providerID": "acme", "name": "New", "release_date": "2026-09-01"
        }
        acme/gone
        {
          "providerID": "acme", "name": "Gone", "release_date": "2026-10-01", "status": "deprecated"
        }
        other/model
        {
          "providerID": "other", "name": "Other", "release_date": "2026-10-01"
        }
        """
        let models = AgentModels.listed(.opencode, listing: listing, login: "●  Acme  api")
        #expect(models.map(\.id) == ["acme/new", "acme/old"])
        #expect(models.first?.label == "New")
    }

    @Test func aListingIsCapped() {
        let rows = (1 ... 50).map { "prov  model-\($0)  yes" }.joined(separator: "\n")
        let listing = "provider  model  thinking\n" + rows
        #expect(AgentModels.listed(.pi, listing: listing).count == AgentModels.listedLimit)
    }

    @Test func listedModelsComeFirstThenTheSeedsOthers() {
        let seed = AgentModelCatalog(
            agent: "codex",
            models: [AgentModel("gpt-a", "GPT A", efforts: ["low"]), AgentModel("gpt-old", "GPT Old")],
            efforts: ["low", "high"], source: "seed"
        )
        let merged = seed.merged(listed: [AgentModel("gpt-new", "gpt-new"), AgentModel("gpt-a", "gpt-a")])
        #expect(merged.models.map(\.id) == ["gpt-new", "gpt-a", "gpt-old"])
        // What the seed knows fills in what the listing lacks.
        #expect(merged.models[1].label == "GPT A")
        #expect(merged.models[1].efforts == ["low"])
        #expect(merged.source.hasPrefix("listed by codex"))
        #expect(seed.merged(listed: []) == seed)
    }

    // MARK: The picker

    @Test func thePickerOffersDefaultModelsAndCustom() {
        let catalog = AgentModels.catalog("claude")
        let options = ModelPicker.models(catalog)
        #expect(options.first == ModelPicker.Option(tag: "", label: "agent's default"))
        #expect(options.last?.tag == ModelPicker.customTag)
        #expect(options.contains(ModelPicker.Option(
            tag: "claude-opus-5-5",
            label: "Opus 5.5",
            detail: "claude-opus-5-5"
        )))
        #expect(ModelPicker.selection(nil, in: catalog) == ModelPicker.defaultTag)
        #expect(ModelPicker.selection(" ", in: catalog) == ModelPicker.defaultTag)
        #expect(ModelPicker.selection("opus", in: catalog) == "opus")
        #expect(ModelPicker.selection("my-own-model", in: catalog) == ModelPicker.customTag)
    }

    @Test func pickingStoresTheIdNothingOrKeepsTheCustomOne() {
        let catalog = AgentModels.catalog("claude")
        #expect(ModelPicker.value(picking: "opus", current: nil, in: catalog) == "opus")
        #expect(ModelPicker.value(picking: "", current: "opus", in: catalog) == nil)
        #expect(ModelPicker.value(picking: ModelPicker.customTag, current: "opus", in: catalog) == nil)
        #expect(ModelPicker.value(picking: ModelPicker.customTag, current: "mine", in: catalog) == "mine")
    }

    @Test func aCustomIdMustBeTyped() {
        #expect(ModelPicker.problem(custom: "") == "type a model id")
        #expect(ModelPicker.problem(custom: "   ") == "type a model id")
        #expect(ModelPicker.problem(custom: "two words") == "a model id has no spaces")
        #expect(ModelPicker.problem(custom: " opus[1m] ") == nil)
    }

    @Test func stepsWrapAndEffortsKeepWhatIsConfigured() {
        let catalog = AgentModels.catalog("claude")
        #expect(ModelPicker.step(nil, by: 1, in: catalog) == "fable")
        #expect(ModelPicker.step(nil, by: -1, in: catalog) == catalog.models.last?.id)
        #expect(ModelPicker.step("fable", by: -1, in: catalog) == nil)
        #expect(ModelPicker.stepEffort(nil, by: 1, in: catalog, model: "opus") == "low")
        #expect(ModelPicker.stepEffort("max", by: 1, in: catalog, model: "opus") == nil)
        #expect(ModelPicker.stepEffort(nil, by: 1, in: catalog, model: "claude-haiku-4-5") == nil)
        let efforts = ModelPicker.efforts(catalog, model: "claude-opus-4-6", current: "xhigh")
        #expect(efforts.first?.label == "default (high)")
        #expect(efforts.map(\.tag) == ["", "low", "medium", "high", "max", "xhigh"])
        #expect(ModelPicker.efforts(AgentModels.catalog("gemini"), model: nil).isEmpty)
        #expect(ModelPicker.effort("xhigh", after: "claude-opus-4-6", in: catalog) == nil)
        #expect(ModelPicker.effort("high", after: "claude-opus-4-6", in: catalog) == "high")
        #expect(ModelPicker.line(model: "claude-opus-5-5", effort: "high", in: catalog) == "Opus 5.5 · high")
        #expect(ModelPicker.line(model: nil, effort: nil, in: catalog) == "default model")
    }

    // MARK: The command line

    @Test func eachAgentTakesModelAndEffortItsOwnWay() throws {
        let cases: [(String, String)] = [
            ("claude", "claude --model opus --effort high"),
            ("codex", "codex --model opus -c model_reasoning_effort=high"),
            ("pi", "pi --model opus --thinking high"),
            // These take no effort at launch: it is left out, the model stays.
            ("cursor", "cursor-agent --model opus"),
            ("opencode", "opencode --model opus"),
            ("gemini", "gemini --model opus"),
        ]
        for (name, line) in cases {
            let command = try agent(name).launchCommand(prompt: "", model: "opus", effort: "high")
            #expect(command.posix == line, "\(name)")
        }
    }

    @Test func theAgentsConfiguredModelAndEffortApplyUnlessSomethingPicks() throws {
        var claude = try agent("claude")
        #expect(claude.launchCommand(prompt: "").posix == "claude")
        claude.model = "sonnet"
        claude.effort = "low"
        #expect(claude.launchCommand(prompt: "").posix == "claude --model sonnet --effort low")
        #expect(claude.launchCommand(prompt: "", model: "opus", effort: "max")
            .posix == "claude --model opus --effort max")
        #expect(claude.launchCommand(prompt: "", model: " ", effort: "").posix == "claude --model sonnet --effort low")
    }

    @Test func anEffortTemplateQuotesTheLevel() throws {
        var custom = AgentProfile(name: "mytool", command: "mytool")
        custom.effortFlag = "--reasoning={level}"
        #expect(custom.launchCommand(prompt: "", effort: "it's").posix == "mytool --reasoning='it'\\''s'")
        custom.effortFlag = nil
        #expect(custom.launchCommand(prompt: "", effort: "high").posix == "mytool")
    }

    @Test func startWorkPassesThePickedModelAndEffort() throws {
        var plan = try StartWorkPlan(prompt: "fix it", repos: [], name: "fix", agent: agent("codex"))
        plan.model = "gpt-6-luna"
        plan.effort = "max"
        let line = try #require(plan.command).posix
        #expect(line.contains("--model gpt-6-luna -c model_reasoning_effort=max"))
    }

    // MARK: Config

    @Test func configReadsAgentModelEffortAndPilotEfforts() throws {
        let source = """
        [agents.claude]
        model = "opus"
        effort = "High"
        [agents.mytool]
        command = "mytool"
        effort_flag = "--think {level}"
        [pilot]
        effort = "low"
        merge_model = "haiku"
        merge_effort = "medium"
        [repos."acme/docs"]
        effort = "max"
        """
        let config = try #require(ConfigLoader.decode(source).config)
        let claude = try #require(config.work.agent("claude"))
        #expect(claude.model == "opus")
        #expect(claude.effort == "high")
        #expect(claude.effortFlag == "--effort")
        #expect(config.work.agent("mytool")?.effortFlag == "--think {level}")
        #expect(config.pilot.defaults.effort == "low")
        let green = config.pilot.defaults.runAgent(for: .green)
        #expect(green.effort == "low")
        let merged = config.pilot.defaults.runAgent(for: .merged)
        #expect(merged.model == "haiku" && merged.effort == "medium")
        #expect(config.pilot.resolve(Repo(org: "acme", name: "docs")).effort == "max")
        // The default file leaves them empty: unset.
        #expect(HeedConfig.default.pilot.defaults.effort == nil)
        #expect(HeedConfig.default.work.agent("claude")?.model == nil)
    }

    @Test func aMergeAgentOfItsOwnDoesNotInheritTheRunEffort() {
        var settings = PilotSettings()
        settings.effort = "high"
        #expect(settings.runAgent(for: .merged).effort == "high")
        settings.mergeAgent = "codex"
        #expect(settings.runAgent(for: .merged).effort == nil)
    }

    @Test func overridePickersPickForTheRightAgent() {
        var config = HeedConfig.default
        var org = PilotOverrides()
        org.agent = "codex"
        org.model = "gpt-6-luna"
        config.pilot = PilotRules(orgs: ["acme": org], repos: [:])
        let docs = OverrideScope.repo(Repo(org: "acme", name: "docs"))
        #expect(Overrides.pickerAgent("agent", at: docs, in: config) == "codex")
        // The conflict agent falls back to the run agent, then to the default agent.
        #expect(Overrides.pickerAgent("merge_agent", at: docs, in: config) == "codex")
        #expect(Overrides.pickerAgent("agent", at: .org("other"), in: config) == config.work.defaultAgent)
        #expect(Overrides.pickerModel("merge_model", at: docs, in: config) == "gpt-6-luna")
        #expect(Overrides.keys.contains { $0.id == "effort" && $0.kind == .effort(agent: "agent", model: "model") })
        #expect(Overrides.keys.contains { $0.id == "merge_model" && $0.kind == .model(agent: "merge_agent") })
    }

    // MARK: Handing off

    @Test func handoffCompletesAgentsThenModelsThenEfforts() {
        let catalogs = ["claude": AgentModels.catalog("claude"), "codex": AgentModels.catalog("codex")]
        let agents = Handoff.completions("", agents: ["claude", "codex"], current: "claude", catalogs: catalogs)
        #expect(agents.map(\.value) == ["codex"])
        let models = Handoff.completions("codex ", agents: ["claude", "codex"], current: "claude", catalogs: catalogs)
        #expect(models.first?.value == "codex -")
        #expect(models.contains { $0.value == "codex gpt-5.5" })
        let efforts = Handoff.completions(
            "codex gpt-5.5 ", agents: ["claude", "codex"], current: "claude", catalogs: catalogs
        )
        #expect(efforts.map(\.value) == ["low", "medium", "high", "xhigh"].map { "codex gpt-5.5 \($0)" })
        var context = CompletionContext()
        context.agents = ["claude", "codex"]
        context.currentAgent = "claude"
        context.catalogs = catalogs
        let lines = CommandCompletions.candidates("agent.switch codex gpt-5.5 h", context).map(\.line)
        #expect(lines == ["agent.switch codex gpt-5.5 high"])
        #expect(Handoff.Choice(model: "-", effort: "HIGH") == Handoff.Choice(model: nil, effort: "high"))
    }

    // MARK: Swarms

    @Test func aTasksOwnerGetsTheTeamsModelAndEffort() {
        let settings = SwarmSettings(
            lead: GoalItem.Owner(agent: "claude", model: "opus", effort: "high"),
            workers: [SwarmSettings.Worker(agent: "codex", model: "gpt-6-luna", effort: "low", count: 2)]
        )
        #expect(settings.resolved(GoalItem.Owner(agent: "codex"))
            == GoalItem.Owner(agent: "codex", model: "gpt-6-luna", effort: "low"))
        // An owner naming its own model keeps it, without the team's effort for another model.
        #expect(settings.resolved(GoalItem.Owner(agent: "codex", model: "gpt-5.5"))
            == GoalItem.Owner(agent: "codex", model: "gpt-5.5"))
        #expect(settings.resolved(GoalItem.Owner(agent: "codex", model: "gpt-6-luna"))
            == GoalItem.Owner(agent: "codex", model: "gpt-6-luna", effort: "low"))
        // The lead's agent without workers of its own: the lead's.
        #expect(settings.resolved(GoalItem.Owner(agent: "claude")).effort == "high")
        #expect(settings.resolved(GoalItem.Owner(agent: "pi")) == GoalItem.Owner(agent: "pi"))
        #expect(settings.workers[0].label == "codex · gpt-6-luna · low ×2")
    }

    @Test func aPlansOwnerMayNameAnEffort() throws {
        let owner = try SwarmPlanInput.owner(["agent": "codex", "model": "gpt-5.5", "effort": "HIGH"], index: 0)
        #expect(owner == GoalItem.Owner(agent: "codex", model: "gpt-5.5", effort: "high"))
    }
}
