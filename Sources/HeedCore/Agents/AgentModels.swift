import Foundation

/// One model an agent CLI takes: the id passed to its model flag, a short label, and the reasoning efforts it has
/// where they differ from the agent's own (codex's catalogue says per model; claude's older models lack some).
public struct AgentModel: Hashable, Sendable, Codable {
    public var id: String
    public var label: String
    /// nil: the agent's levels. Empty: this model takes no effort.
    public var efforts: [String]?
    /// nil: the agent's default.
    public var defaultEffort: String?

    public init(_ id: String, _ label: String, efforts: [String]? = nil, defaultEffort: String? = nil) {
        self.id = id
        self.label = label
        self.efforts = efforts
        self.defaultEffort = defaultEffort
    }
}

/// What one agent CLI can run on: its models, newest first, and its reasoning effort (thinking) levels when it takes
/// one at launch. `AgentModels.seed` holds what was verified by hand; `merged(listed:)` lays what the CLI itself lists
/// over it.
public struct AgentModelCatalog: Hashable, Sendable {
    public var agent: String
    public var models: [AgentModel]
    /// Effort levels, lowest first; empty: the agent takes none at launch.
    public var efforts: [String]
    /// The level the agent uses when none is passed; nil when it varies by model or is unknown.
    public var defaultEffort: String?
    /// Where the entries come from, for the picker's help.
    public var source: String
    /// The agent takes a model at launch (it has a `modelFlag`); false: there is nothing to pick.
    public var takesModel = true
    /// The model its launches use when none is picked (`[agents.<name>] model`), which the default entry names.
    public var configuredModel: String?

    public init(
        agent: String, models: [AgentModel], efforts: [String] = [], defaultEffort: String? = nil, source: String = ""
    ) {
        self.agent = agent
        self.models = models
        self.efforts = efforts
        self.defaultEffort = defaultEffort
        self.source = source
    }

    public func model(_ id: String?) -> AgentModel? {
        guard let id, !id.isEmpty else { return nil }
        return models.first { $0.id == id }
    }

    /// The effort levels with `model` chosen (nil: the agent's default model): its own when the catalogue knows them,
    /// else the agent's. Empty: no effort to pick.
    public func efforts(for model: String?) -> [String] {
        self.model(model)?.efforts ?? efforts
    }

    /// The level used when none is passed, with `model` chosen.
    public func defaultEffort(for model: String?) -> String? {
        self.model(model)?.defaultEffort ?? defaultEffort
    }

    /// This catalogue with what the CLI listed first (in its order, with the seed's labels and efforts where the seed
    /// knows more), then the seed's models it did not list.
    public func merged(listed: [AgentModel]) -> AgentModelCatalog {
        guard !listed.isEmpty else { return self }
        var seen = Set<String>()
        var models: [AgentModel] = []
        for var model in listed where seen.insert(model.id).inserted {
            if let known = self.model(model.id) {
                if model.label == model.id { model.label = known.label }
                if model.efforts == nil { model.efforts = known.efforts }
                if model.defaultEffort == nil { model.defaultEffort = known.defaultEffort }
            }
            models.append(model)
        }
        models += self.models.filter { seen.insert($0.id).inserted }
        var catalog = self
        catalog.models = models
        catalog.source = source.isEmpty ? "listed by \(agent)" : "listed by \(agent), then \(source)"
        return catalog
    }
}

/// The models and efforts heed offers per agent, so model and effort are picked from a list (with a custom id for
/// anything else) instead of typed. Seeded from each CLI's `--help` and the vendors' docs, verified on the date in
/// each entry's comment; where the CLI lists its models (`LLMDialect.modelListing`), that listing is parsed and laid
/// over the seed at runtime (`AgentModelCatalog.merged`). How each CLI takes the effort is `AgentProfile.effortFlag`.
public enum AgentModels {
    /// claude: `claude --help` (2.1.306) takes `--model <alias or full name>` and `--effort <level>` (low, medium,
    /// high, xhigh, max). Aliases and per-model effort levels and defaults from code.claude.com/docs/en/model-config
    /// ("Model aliases", "Adjust effort level"); ids from Anthropic's model table (cached 2026-10-06). Verified
    /// 2026-10-29. Opus, Sonnet and Haiku 5.5 default to medium, Opus 4.7 to xhigh, the rest that take effort to high;
    /// Opus and Sonnet 4.6 have no xhigh; Haiku 4.5 takes no effort.
    static let claude: AgentModelCatalog = {
        let all = ["low", "medium", "high", "xhigh", "max"]
        let noXhigh = ["low", "medium", "high", "max"]
        return AgentModelCatalog(
            agent: "claude",
            models: [
                AgentModel("fable", "Fable (latest)", defaultEffort: "high"),
                AgentModel("opus", "Opus (latest)", defaultEffort: "medium"),
                AgentModel("sonnet", "Sonnet (latest)", defaultEffort: "medium"),
                AgentModel("haiku", "Haiku (latest)", defaultEffort: "medium"),
                AgentModel("claude-fable-5-1", "Fable 5.1", defaultEffort: "high"),
                AgentModel("claude-opus-5-5", "Opus 5.5", defaultEffort: "medium"),
                AgentModel("claude-sonnet-5-5", "Sonnet 5.5", defaultEffort: "medium"),
                AgentModel("claude-haiku-5-5", "Haiku 5.5", defaultEffort: "medium"),
                AgentModel("claude-fable-5", "Fable 5", defaultEffort: "high"),
                AgentModel("claude-opus-5", "Opus 5", defaultEffort: "high"),
                AgentModel("claude-sonnet-5", "Sonnet 5", defaultEffort: "high"),
                AgentModel("claude-opus-4-8", "Opus 4.8", defaultEffort: "high"),
                AgentModel("claude-opus-4-7", "Opus 4.7", defaultEffort: "xhigh"),
                AgentModel("claude-opus-4-6", "Opus 4.6", efforts: noXhigh, defaultEffort: "high"),
                AgentModel("claude-sonnet-4-6", "Sonnet 4.6", efforts: noXhigh, defaultEffort: "high"),
                AgentModel("claude-haiku-4-5", "Haiku 4.5", efforts: []),
            ],
            efforts: all,
            source: "claude --help and Claude Code's model docs, 2026-10-29"
        )
    }()

    /// codex: `codex --help` (codex-cli 0.163.0) takes `-m, --model <MODEL>` and `-c key=value` config overrides;
    /// `model_reasoning_effort` is "such as low, medium, high, xhigh, max, or ultra" and "available levels depend on
    /// the
    /// model" (learn.chatgpt.com/docs/config-file/config-reference). Models, levels and defaults from
    /// `codex debug models` (0.163.0) and learn.chatgpt.com/docs/models, newest first by release. Verified 2026-10-29.
    /// gpt-6.1-terra is in the docs but was not in that catalogue, so it keeps the agent's levels.
    static let codex: AgentModelCatalog = {
        let ultra = ["low", "medium", "high", "xhigh", "max", "ultra"]
        let max = ["low", "medium", "high", "xhigh", "max"]
        return AgentModelCatalog(
            agent: "codex",
            models: [
                AgentModel("gpt-6.1-terra", "GPT-6.1 Terra"),
                AgentModel("gpt-6.1-sol", "GPT-6.1 Sol", efforts: ultra, defaultEffort: "low"),
                AgentModel("gpt-6-sol", "GPT-6 Sol", efforts: ultra, defaultEffort: "medium"),
                AgentModel("gpt-6-luna", "GPT-6 Luna", efforts: max, defaultEffort: "medium"),
                AgentModel("gpt-6-astra", "GPT-6 Astra", efforts: ultra, defaultEffort: "low"),
                AgentModel("gpt-5.6-terra", "GPT-5.6 Terra", efforts: ultra, defaultEffort: "medium"),
                AgentModel("gpt-5.6-sol", "GPT-5.6 Sol", efforts: ultra, defaultEffort: "low"),
                AgentModel("gpt-5.6-luna", "GPT-5.6 Luna", efforts: max, defaultEffort: "medium"),
                AgentModel("gpt-5.5", "GPT-5.5", efforts: ["low", "medium", "high", "xhigh"], defaultEffort: "medium"),
            ],
            efforts: ultra,
            source: "codex --help, codex debug models and the Codex model docs, 2026-10-29"
        )
    }()

    /// cursor-agent: cursor.com/docs/cli/reference/parameters gives `--model <model>` and `agent models` ("List
    /// available models for this account") but no model ids and no effort option; effort is part of a model's id
    /// (`-high`, `-low-fast`, cursor.com/docs/models). Verified 2026-10-29, cursor-agent not installed here: no seed,
    /// the picker offers what `cursor-agent models` lists.
    static let cursor = AgentModelCatalog(
        agent: "cursor", models: [], source: "cursor-agent's CLI docs, 2026-10-29 (it lists its own models)"
    )

    /// pi: `pi --help` (1.3.0) takes `--model <pattern>` ("provider/id", optional ":<thinking>") and `--thinking
    /// <level>` (off, minimal, low, medium, high, xhigh, max); `defaultThinkingLevel` is medium (its docs/settings.md).
    /// Ids from pi's bundled model catalogue (anthropic, openai, google providers), newest first per provider.
    /// Verified 2026-10-29.
    static let pi = AgentModelCatalog(
        agent: "pi",
        models: [
            AgentModel("anthropic/claude-fable-5-1", "Fable 5.1"),
            AgentModel("anthropic/claude-haiku-5-5", "Haiku 5.5"),
            AgentModel("anthropic/claude-sonnet-5-5", "Sonnet 5.5"),
            AgentModel("anthropic/claude-opus-5-5", "Opus 5.5"),
            AgentModel("openai/gpt-6.1-sol", "GPT-6.1 Sol"),
            AgentModel("openai/gpt-6-luna", "GPT-6 Luna"),
            AgentModel("openai/gpt-6-astra", "GPT-6 Astra"),
            AgentModel("google/gemini-4-argon", "Gemini 4 Argon"),
            AgentModel("google/gemini-3.8-flash", "Gemini 3.8 Flash"),
        ],
        efforts: ["off", "minimal", "low", "medium", "high", "xhigh", "max"],
        defaultEffort: "medium",
        source: "pi --help and pi's model catalogue, 2026-10-29"
    )

    /// opencode: `opencode --help` (1.19.3) takes `-m, --model` as provider/model. Reasoning effort is `--variant`, on
    /// `opencode run` only, not the TUI heed starts: no effort here. Ids from the models.dev catalogue opencode reads,
    /// newest first per provider. Verified 2026-10-29.
    static let opencode = AgentModelCatalog(
        agent: "opencode",
        models: [
            AgentModel("anthropic/claude-haiku-5-5", "Haiku 5.5"),
            AgentModel("anthropic/claude-sonnet-5-5", "Sonnet 5.5"),
            AgentModel("anthropic/claude-opus-5-5", "Opus 5.5"),
            AgentModel("anthropic/claude-fable-5-1", "Fable 5.1"),
            AgentModel("openai/gpt-6.1-terra", "GPT-6.1 Terra"),
            AgentModel("openai/gpt-6.1-sol", "GPT-6.1 Sol"),
            AgentModel("openai/gpt-6-luna", "GPT-6 Luna"),
            AgentModel("openai/gpt-6-astra", "GPT-6 Astra"),
            AgentModel("google/gemini-4-argon", "Gemini 4 Argon"),
            AgentModel("google/gemini-3.8-flash", "Gemini 3.8 Flash"),
        ],
        source: "opencode --help and models.dev, 2026-10-29"
    )

    /// gemini: geminicli.com/docs/cli/cli-reference gives `-m, --model` (default `auto`) and the aliases auto and pro
    /// (gemini-2.5-pro, or gemini-3-pro-preview with preview features), flash and flash-lite; no thinking or effort
    /// flag. Full ids from geminicli.com/docs/cli/model. Verified 2026-10-29; gemini is not installed here.
    static let gemini = AgentModelCatalog(
        agent: "gemini",
        models: [
            AgentModel("auto", "Auto"),
            AgentModel("pro", "Pro"),
            AgentModel("flash", "Flash"),
            AgentModel("flash-lite", "Flash-Lite"),
            AgentModel("gemini-3-pro-preview", "Gemini 3 Pro (preview)"),
            AgentModel("gemini-3-flash-preview", "Gemini 3 Flash (preview)"),
            AgentModel("gemini-2.5-pro", "Gemini 2.5 Pro"),
            AgentModel("gemini-2.5-flash", "Gemini 2.5 Flash"),
            AgentModel("gemini-2.5-flash-lite", "Gemini 2.5 Flash-Lite"),
        ],
        source: "Gemini CLI's reference, 2026-10-29"
    )

    /// Every built-in agent's catalogue, by agent name.
    public static let seed: [String: AgentModelCatalog] = Dictionary(
        uniqueKeysWithValues: [claude, codex, cursor, pi, opencode, gemini].map { ($0.agent, $0) }
    )

    /// The seed for `agent`: a built-in's, or an empty one (custom agents: default or a custom id).
    public static func catalog(_ agent: String) -> AgentModelCatalog {
        seed[agent] ?? AgentModelCatalog(agent: agent, models: [])
    }

    /// What the pickers offer for a configured agent: its seed with what its CLI `listed` laid over it, without
    /// efforts when it has no `effortFlag` and without models when it has no `modelFlag`.
    public static func catalog(for agent: AgentProfile, listed: [AgentModel] = []) -> AgentModelCatalog {
        var catalog = catalog(agent.name).merged(listed: listed)
        if agent.effortFlag?.isEmpty ?? true {
            catalog.efforts = []
            catalog.defaultEffort = nil
            catalog.models = catalog.models.map { model in
                var model = model
                model.efforts = []
                model.defaultEffort = nil
                return model
            }
        }
        if agent.modelFlag?.isEmpty ?? true {
            catalog.models = []
            catalog.takesModel = false
        }
        catalog.configuredModel = agent.model
        // A configured effort is what every model starts on when none is picked.
        if let effort = agent.effort, !catalog.efforts.isEmpty {
            catalog.defaultEffort = effort
            catalog.models = catalog.models.map { model in
                var model = model
                if model.efforts?.isEmpty != true { model.defaultEffort = effort }
                return model
            }
        }
        return catalog
    }

    /// The most a listing contributes, so a provider with hundreds of models keeps the picker short.
    public static let listedLimit = 30

    /// The models in what the agent's own listing printed (`LLMDialect.modelListing`): codex's catalogue with its
    /// efforts, opencode's newest first (only providers `login` names), pi's and cursor's ids. Empty for agents without
    /// a listing or output that does not parse.
    public static func listed(_ dialect: LLMDialect, listing: String, login: String = "") -> [AgentModel] {
        let models: [AgentModel] = switch dialect {
        case .claude, .gemini: []
        case .codex: codex(listing)
        case .opencode: opencode(listing, providers: login)
        case .pi: LLMDialect.piModels(listing).map { AgentModel($0, $0) }
        case .cursor: LLMDialect.cursorModels(listing).map { AgentModel($0, $0) }
        }
        return Array(models.prefix(listedLimit))
    }

    /// `codex debug models`: listed (not hidden) models by priority, with their levels and default.
    static func codex(_ listing: String) -> [AgentModel] {
        guard let json = try? JSONSerialization.jsonObject(with: Data(listing.utf8)) as? [String: Any],
              let models = json["models"] as? [[String: Any]]
        else { return [] }
        return models.filter { ($0["visibility"] as? String ?? "list") == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                guard let slug = model["slug"] as? String, !slug.isEmpty else { return nil }
                let levels = (model["supported_reasoning_levels"] as? [[String: Any]])?
                    .compactMap { $0["effort"] as? String }
                return AgentModel(
                    slug, model["display_name"] as? String ?? slug, efforts: levels?.isEmpty == false ? levels : nil,
                    defaultEffort: model["default_reasoning_level"] as? String
                )
            }
    }

    /// `opencode models --verbose`: a `provider/model` line, then that model as JSON. Active models of providers the
    /// login check lists, newest release first.
    static func opencode(_ listing: String, providers: String) -> [AgentModel] {
        let known = LLMDialect.plain(providers).lowercased()
        var found: [(model: AgentModel, released: String)] = []
        var id: String?
        var json = ""
        func finish() {
            defer { json = "" }
            guard let current = id else { return }
            let object = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
            let provider = (object["providerID"] as? String ?? current.split(separator: "/").first.map(String.init))?
                .lowercased() ?? ""
            guard !provider.isEmpty, known.contains(provider) else { return }
            if let status = object["status"] as? String, status != "active" { return }
            found.append((
                AgentModel(current, object["name"] as? String ?? current),
                object["release_date"] as? String ?? ""
            ))
        }
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            if !line.hasPrefix(" "), !line.hasPrefix("{"), !line.hasPrefix("}"), line.contains("/") {
                finish()
                id = line.trimmingCharacters(in: .whitespaces)
            } else {
                json += line + "\n"
            }
        }
        finish()
        // Stable: same-day releases keep the listing's order.
        return found.enumerated()
            .sorted { $0.element.released != $1.element.released ? $0.element.released > $1.element.released
                : $0.offset < $1.offset
            }
            .map(\.element.model)
    }
}
