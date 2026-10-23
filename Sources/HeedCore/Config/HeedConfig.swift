import Foundation

/// Everything `~/.config/heed/config.toml` says, as domain values. Every section has one shape: agents are all
/// `[agents.<name>]` with the same fields (built-in or custom), key bindings are `[keys.<mode or view>]` tables of
/// notation = command, repos and orgs are keyed by name.
public struct HeedConfig: Equatable, Sendable {
    public var work: WorkSettings
    public var insertEscape: String
    /// The system-wide shortcut that opens Start work over any app; "" turns it off.
    public var globalStartWork = "<C-M-Space>"
    /// The system-wide shortcut that brings Heed to the front; "" turns it off.
    public var globalActivate = "<C-M-h>"
    /// `[ui]`: Heed outside its window.
    public var showMenuBarItem = true
    public var showDockState = true
    /// `[notifications]`: a macOS notification when a session starts needing you.
    public var notifications = NotificationSettings()
    /// `[attention]`: quiet hours, which notifications respect.
    public var attention = AttentionSettings()
    /// `[summary] away_hours`: how long away (from the Mac, or with heed quit) before the summary of what happened
    /// opens on its own; 0 never opens it.
    public var summaryAwayHours = 8
    /// `[summary] when`, `idle_hours`, `include`: when History's ledger is written, and what it holds.
    public var ledger = LedgerSettings()
    /// `[keys.normal]`, `[keys.visual]`, ...: overrides laid over the defaults.
    public var keys: [Mode: [(String, String)]]
    /// `[keys.repos]`, `[keys.inbox]`, ...: per-view overrides.
    public var scopedKeys: [String: [(String, String)]]
    public var orgColors: [String: String]
    public var repos: [String: RepoConfig]
    public var cleanup: CleanupRule
    public var githubPollSeconds: Int
    public var tools = ToolSettings()
    public var issues = IssueRules()
    /// `[pilot]`, with org and repo levels: watching PRs, get it green.
    public var pilot = PilotRules()
    /// `[hosts.<name>]`: machines heed drives over ssh, by name.
    public var hosts: [String: HostConfig] = [:]
    /// `[updates]`: whether heed looks for a new version, and whether it asks before installing one.
    public var updates = UpdateSettings()
    /// `[usage]`: whether the inspector shows a cost, and the prices it estimates one from.
    public var usage = UsageSettings()
    /// `[log]`: how long the call log keeps each kind of call.
    public var log = CallRetention()
    /// `[llm]`, and `llm` / `llm_model` in `[agents.<name>]`: heed's own model calls.
    public var llm = LLMSettings()
    /// `[local]`: what heed keeps on this Mac to learn local decisions from (screen snapshots). Off by default.
    public var local = LocalSettings()
    /// `[start_work]`: whether the on-device model helps Start work guess.
    public var startWork = StartWorkSettings()

    public struct RepoConfig: Equatable, Sendable {
        public var color: String?
        public var issues: IssueVisibility?
        /// Pinned tasks (test, build, docs preview): name → command.
        public var tasks: [(String, String)]

        public static func == (lhs: RepoConfig, rhs: RepoConfig) -> Bool {
            lhs.color == rhs.color && lhs.issues == rhs.issues && lhs.tasks.map(\.0) == rhs.tasks.map(\.0) && lhs.tasks
                .map(\.1) == rhs.tasks
                .map(\.1)
        }
    }

    public static let `default` = HeedConfig(
        work: .default, insertEscape: DefaultKeys.insertEscape, keys: [:], scopedKeys: [:], orgColors: [:], repos: [:],
        cleanup: CleanupRule(), githubPollSeconds: 60
    )

    public static func == (lhs: HeedConfig, rhs: HeedConfig) -> Bool {
        func flat(_ table: [Mode: [(String, String)]]) -> [String] {
            table.sorted { $0.key.rawValue < $1.key.rawValue }
                .flatMap { mode, pairs in pairs.map { "\(mode):\($0)=\($1)" } }
        }
        func flat(_ table: [String: [(String, String)]]) -> [String] {
            table.sorted { $0.key < $1.key }.flatMap { scope, pairs in pairs.map { "\(scope):\($0)=\($1)" } }
        }
        let same = [
            lhs.work == rhs.work,
            lhs.insertEscape == rhs.insertEscape,
            lhs.globalStartWork == rhs.globalStartWork,
            lhs.globalActivate == rhs.globalActivate,
            lhs.showMenuBarItem == rhs.showMenuBarItem,
            lhs.showDockState == rhs.showDockState,
            lhs.notifications == rhs.notifications,
            lhs.attention == rhs.attention,
            lhs.summaryAwayHours == rhs.summaryAwayHours,
            lhs.ledger == rhs.ledger,
            flat(lhs.keys) == flat(rhs.keys),
            flat(lhs.scopedKeys) == flat(rhs.scopedKeys),
            lhs.orgColors == rhs.orgColors,
            lhs.repos == rhs.repos,
            lhs.cleanup == rhs.cleanup,
            lhs.githubPollSeconds == rhs.githubPollSeconds,
            lhs.tools == rhs.tools,
            lhs.issues == rhs.issues,
            lhs.pilot == rhs.pilot,
            lhs.hosts == rhs.hosts,
            lhs.usage == rhs.usage,
            lhs.log == rhs.log,
            lhs.llm == rhs.llm,
            lhs.local == rhs.local,
            lhs.startWork == rhs.startWork,
        ]
        return !same.contains(false)
    }

    /// The keymaps this config asks for, with problems reported per entry.
    public func keymaps() -> (keymaps: [Mode: Keymap], scoped: [String: Keymap], problems: [Keymaps.Problem]) {
        Keymaps.build(overrides: keys, scopedOverrides: scopedKeys, insertEscape: insertEscape)
    }
}

/// The one cleanup rule of version 1: worktrees with no activity for `idleDays` are removed by the sweep. Dirty or
/// unpushed work is never removed (not configurable), nor anything a pinned session uses.
public struct CleanupRule: Equatable, Sendable, Codable {
    /// Off by default: worktrees are only removed by hand until you turn this on.
    public var enabled = false
    public var idleDays = 14
    public var deleteBranch = true
    public var askBeforeSweep = false
    /// How long work saved from removed worktrees (`refs/heed/archive/…`) is kept before a sweep drops it; 0 keeps it.
    public var keepArchiveDays = 90

    public init(
        enabled: Bool = false, idleDays: Int = 14, deleteBranch: Bool = true, askBeforeSweep: Bool = false,
        keepArchiveDays: Int = 90
    ) {
        self.enabled = enabled
        self.idleDays = idleDays
        self.deleteBranch = deleteBranch
        self.askBeforeSweep = askBeforeSweep
        self.keepArchiveDays = keepArchiveDays
    }
}

public struct ConfigProblem: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
    public init(path: String, message: String) {
        self.path = path
        self.message = message
    }

    public var description: String { path.isEmpty ? message : "\(path): \(message)" }
}

public enum ConfigLoader {
    /// `~/.config/heed/config.toml` (or `$XDG_CONFIG_HOME/heed/config.toml`).
    public static func defaultFile() -> URL {
        let base = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config")
        return base.appendingPathComponent("heed/config.toml")
    }

    /// Parses and decodes. A syntax error returns no config (the caller keeps the last good one); a value that does
    /// not fit is reported and its default kept, so one typo never disables the rest.
    public static func decode(_ source: String) -> (config: HeedConfig?, problems: [ConfigProblem]) {
        let document: TOMLDocument
        do {
            document = try TOMLDocument(source)
        } catch {
            return (nil, [ConfigProblem(path: "", message: error.description)])
        }
        var problems: [ConfigProblem] = []
        var config = HeedConfig.default
        let root = document.root

        func string(_ path: [String]) -> String? {
            guard let value = root.value(at: path) else { return nil }
            guard let text = value.string else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected a string"))
                return nil
            }
            return text
        }
        func integer(_ path: [String], range: ClosedRange<Int>) -> Int? {
            guard let value = root.value(at: path) else { return nil }
            guard let number = value.integer, range.contains(number) else {
                problems.append(ConfigProblem(
                    path: path.joined(separator: "."),
                    message: "expected a number from \(range.lowerBound) to \(range.upperBound)"
                ))
                return nil
            }
            return number
        }
        func bool(_ path: [String]) -> Bool? {
            guard let value = root.value(at: path) else { return nil }
            guard let flag = value.bool else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected true or false"))
                return nil
            }
            return flag
        }
        func strings(_ path: [String]) -> [String]? {
            guard let value = root.value(at: path) else { return nil }
            guard let items = value.array?.compactMap(\.string), items.count == value.array?.count else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected a list of strings"))
                return nil
            }
            return items
        }
        func pairs(_ path: [String]) -> [(String, String)] {
            guard let table = root.value(at: path)?.table else { return [] }
            return table.keys.compactMap { key in
                guard let text = table[key]?.string else {
                    problems.append(ConfigProblem(
                        path: (path + [key]).joined(separator: "."),
                        message: "expected a string"
                    ))
                    return nil
                }
                return (key, text)
            }
        }

        // [worktrees]
        if let root = string(["worktrees", "root"]) { config.work.worktreeRoot = root }
        if let roots = strings(["worktrees", "repo_roots"]) { config.work.repoRoots = roots }
        if let paths = strings(["worktrees", "repo_paths"]) { config.work.repoPaths = paths }
        if let prefix = string(["worktrees", "default_prefix"]) { config.work.prefixes.defaultPrefix = prefix }
        if let flag = bool(["worktrees", "offer_trust"]) { config.work.offerTrust = flag }
        if let table = root.value(at: ["worktrees", "prefixes"])?.table {
            var prefixes: [String: [String]] = [:]
            for prefix in table.keys {
                if let words = strings(["worktrees", "prefixes", prefix]) {
                    prefixes[prefix] = words.map { $0.lowercased() }
                }
            }
            config.work.prefixes.prefixes = prefixes
        }
        // [start_work]
        if let flag = bool(["start_work", "smart_guesses"]) { config.startWork.smartGuesses = flag }
        // [sessions]
        if let agent = string(["sessions", "default_agent"]) { config.work.defaultAgent = agent }
        if let policy = string(["sessions", "resume_on_launch"]) {
            if let parsed = ResumePolicy(rawValue: policy) {
                config.work.resumeOnLaunch = parsed
            } else {
                problems.append(ConfigProblem(
                    path: "sessions.resume_on_launch",
                    message: "expected ask, always or never"
                ))
            }
        }
        if let text = string(["sessions", "continue_prompt"]) { config.work.continuePrompt = text }
        if let flag = bool(["sessions", "shell_split"]) { config.work.shellSplit = flag }
        if let text = string(["sessions", "persist"]) {
            if let persist = PanePersistence(rawValue: text.lowercased()) {
                config.work.persist = persist
            } else {
                problems.append(ConfigProblem(path: "sessions.persist", message: "expected auto, zmx or none"))
            }
        }
        // [cleanup]
        if let flag = bool(["cleanup", "enabled"]) { config.cleanup.enabled = flag }
        if let days = integer(["cleanup", "idle_days"], range: 1 ... 365) { config.cleanup.idleDays = days }
        if let flag = bool(["cleanup", "delete_branch"]) { config.cleanup.deleteBranch = flag }
        if let flag = bool(["cleanup", "ask_before_sweep"]) { config.cleanup.askBeforeSweep = flag }
        if let days = integer(["cleanup", "keep_archive_days"], range: 0 ... 3650) {
            config.cleanup.keepArchiveDays = days
        }
        // [github]
        if let seconds = integer(["github", "poll_seconds"], range: 15 ... 3600) { config.githubPollSeconds = seconds }
        // [pilot], and the same keys under [orgs.<name>] and [repos."org/name"] below
        func green(_ path: [String]) -> AutoFeed? {
            guard let text = string(path) else { return nil }
            guard let mode = AutoFeed.named(text) else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected off, ask or auto"))
                return nil
            }
            return mode
        }
        func merge(_ path: [String]) -> MergeMode? {
            guard let text = string(path) else { return nil }
            guard let mode = MergeMode.named(text) else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected off, auto or heed"))
                return nil
            }
            return mode
        }
        func mergeMethod(_ path: [String]) -> String? {
            guard let text = string(path)?.lowercased() else { return nil }
            guard ["squash", "merge", "rebase"].contains(text) else {
                problems.append(ConfigProblem(
                    path: path.joined(separator: "."),
                    message: "expected squash, merge or rebase"
                ))
                return nil
            }
            return text
        }
        func pilotOverrides(_ base: [String]) -> PilotOverrides {
            var overrides = PilotOverrides(
                watch: bool(base + ["watch"]), green: green(base + ["green"]),
                maxRounds: integer(base + ["max_rounds"], range: 1 ... 20), merge: merge(base + ["merge"]),
                mergeMethod: mergeMethod(base + ["merge_method"]), updateBranches: bool(base + ["update_branches"]),
                copilotConflicts: bool(base + ["copilot_conflicts"]),
                copilotComments: bool(base + ["copilot_comments"]), reviewers: strings(base + ["reviewers"])
            )
            overrides.quietMinutes = integer(base + ["quiet_minutes"], range: 0 ... 1440)
            overrides.trustedReviewers = strings(base + ["trusted_reviewers"])
            overrides.gateChecks = strings(base + ["gate_checks"])
            overrides.holdLabels = strings(base + ["hold_labels"])
            overrides.selfReview = string(base + ["self_review"]).map { $0.trimmingCharacters(in: .whitespaces) }
            if base.first == "repos" { overrides.adminMerge = bool(base + ["admin_merge"]) }
            for removed in ["send_after_idle", "send_to"] where root.value(at: base + [removed]) != nil {
                problems.append(ConfigProblem(
                    path: (base + [removed]).joined(separator: "."),
                    message: "no longer used: get it green always runs in the background now"
                ))
            }
            overrides.agent = string(base + ["agent"]).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            overrides.model = string(base + ["model"]).flatMap { $0.isEmpty ? nil : $0 }
            overrides.mergeAgent = string(base + ["merge_agent"]).flatMap { $0.isEmpty ? nil : $0.lowercased() }
            overrides.mergeModel = string(base + ["merge_model"]).flatMap { $0.isEmpty ? nil : $0 }
            if let text = string(base + ["run_in"]) {
                if let runIn = RunIn.named(text) {
                    overrides.runIn = runIn
                } else {
                    problems.append(ConfigProblem(
                        path: (base + ["run_in"]).joined(separator: "."), message: "expected background or session"
                    ))
                }
            }
            let trimmed = { (key: String) in
                string(base + [key]).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            }
            overrides.greenInstructions = trimmed("green_instructions")
            overrides.reviewInstructions = trimmed("review_instructions")
            overrides.startInstructions = trimmed("start_instructions")
            overrides.summaryInstructions = trimmed("summary_instructions")
            overrides.summarySignOff = bool(base + ["summary_sign_off"])
            return overrides
        }
        let pilotDefaults = pilotOverrides(["pilot"])
        if let watch = pilotDefaults.watch { config.pilot.defaults.watch = watch }
        if let mode = pilotDefaults.green { config.pilot.defaults.green = mode }
        if let rounds = pilotDefaults.maxRounds { config.pilot.defaults.maxRounds = rounds }
        if let mode = pilotDefaults.merge { config.pilot.defaults.merge = mode }
        if let method = pilotDefaults.mergeMethod { config.pilot.defaults.mergeMethod = method }
        if let flag = pilotDefaults.updateBranches { config.pilot.defaults.updateBranches = flag }
        if let flag = pilotDefaults.copilotConflicts { config.pilot.defaults.copilotConflicts = flag }
        if let flag = pilotDefaults.copilotComments { config.pilot.defaults.copilotComments = flag }
        if let list = pilotDefaults.reviewers { config.pilot.defaults.reviewers = list }
        if let minutes = pilotDefaults.quietMinutes { config.pilot.defaults.quietMinutes = minutes }
        if let list = pilotDefaults.trustedReviewers { config.pilot.defaults.trustedReviewers = list }
        if let list = pilotDefaults.gateChecks { config.pilot.defaults.gateChecks = list }
        if let list = pilotDefaults.holdLabels { config.pilot.defaults.holdLabels = list }
        if let command = pilotDefaults.selfReview { config.pilot.defaults.selfReview = command.isEmpty ? nil : command }
        config.pilot.defaults.agent = pilotDefaults.agent
        config.pilot.defaults.model = pilotDefaults.model
        if let runIn = pilotDefaults.runIn { config.pilot.defaults.runIn = runIn }
        config.pilot.defaults.mergeAgent = pilotDefaults.mergeAgent
        config.pilot.defaults.mergeModel = pilotDefaults.mergeModel
        config.pilot.defaults.greenInstructions = pilotDefaults.greenInstructions ?? ""
        config.pilot.defaults.reviewInstructions = pilotDefaults.reviewInstructions ?? ""
        config.pilot.defaults.startInstructions = pilotDefaults.startInstructions ?? ""
        config.pilot.defaults.summaryInstructions = pilotDefaults.summaryInstructions ?? ""
        if let flag = pilotDefaults.summarySignOff { config.pilot.defaults.summarySignOff = flag }
        if let text = string(["pilot", "run_timeout"]) {
            if case let .seconds(seconds) = PilotDuration.parse(text), seconds >= 60 {
                config.pilot.defaults.runTimeout = seconds
            } else {
                problems.append(ConfigProblem(path: "pilot.run_timeout", message: "expected a duration like 30m or 1h"))
            }
        }
        if bool(["pilot", "admin_merge"]) != nil {
            problems.append(ConfigProblem(
                path: "pilot.admin_merge",
                message: "admin_merge is per repo only: [repos.\"org/name\"] admin_merge = true"
            ))
        }
        if let text = string(["pilot", "merge_schedule"]) {
            if text.lowercased() == "manual" {
                config.pilot.defaults.mergeSchedule = nil
            } else if case let .seconds(seconds) = PilotDuration.parse(text), seconds >= 300 {
                config.pilot.defaults.mergeSchedule = seconds
            } else {
                problems.append(ConfigProblem(
                    path: "pilot.merge_schedule",
                    message: "expected a duration of at least 5m, like 15m or 1h, or manual"
                ))
            }
        }
        if let text = string(["pilot", "pause"]) {
            switch PilotDuration.parse(text) {
            case let .seconds(seconds): config.pilot.defaults.pause = seconds
            case .forever: config.pilot.defaults.pause = nil
            case .off, nil:
                problems.append(ConfigProblem(
                    path: "pilot.pause",
                    message: "expected a duration like 1h, 30m or forever"
                ))
            }
        }
        // [tools]
        if let git = string(["tools", "git"]) { config.tools.git = git }
        if let gh = string(["tools", "gh"]) { config.tools.gh = gh }
        if let zmx = string(["tools", "zmx"]) { config.tools.zmx = zmx }
        if let tailscale = string(["tools", "tailscale"]) { config.tools.tailscale = tailscale }
        if let path = strings(["tools", "path"]) { config.tools.path = path }
        func visibility(_ path: [String]) -> IssueVisibility? {
            guard let text = string(path) else { return nil }
            guard let parsed = IssueVisibility(rawValue: text) else {
                problems.append(ConfigProblem(path: path.joined(separator: "."), message: "expected all or involved"))
                return nil
            }
            return parsed
        }
        // [issues]
        if let fallback = visibility(["issues", "default"]) { config.issues.fallback = fallback }

        // [agents.<name>]: built-ins are overridden field by field; other names are custom agents.
        if let agents = root.value(at: ["agents"])?.table {
            for name in agents.keys {
                guard agents[name]?.table != nil else {
                    problems.append(ConfigProblem(path: "agents.\(name)", message: "expected a table"))
                    continue
                }
                let base = config.work.agents.first { $0.name == name }
                guard let command = string(["agents", name, "command"]) ?? base?.command else {
                    problems.append(ConfigProblem(
                        path: "agents.\(name).command",
                        message: "a custom agent needs a command"
                    ))
                    continue
                }
                var agent = base ?? AgentProfile(name: name, command: command)
                agent.command = command
                if let delivery = string(["agents", name, "prompt"]) {
                    if let parsed = PromptDelivery(rawValue: delivery) {
                        agent.prompt = parsed
                    } else {
                        problems.append(ConfigProblem(
                            path: "agents.\(name).prompt", message: "expected argument, stdin, paste or file"
                        ))
                    }
                }
                if let plan = string(["agents", name, "plan"]) { agent.planArguments = plan.isEmpty ? nil : plan }
                if let flag = string(["agents", name, "model_flag"]) { agent.modelFlag = flag.isEmpty ? nil : flag }
                if let resume = string(["agents", name, "resume"]) {
                    agent.resumeArguments = resume.isEmpty ? nil : resume
                }
                for (profile, line) in pairs(["agents", name, "profiles"]) {
                    agent.profiles[profile] = line
                }
                for (state, pattern) in pairs(["agents", name, "patterns"]) {
                    guard AgentState(rawValue: state) != nil else {
                        problems.append(ConfigProblem(path: "agents.\(name).patterns.\(state)", message: "not a state"))
                        continue
                    }
                    guard (try? NSRegularExpression(pattern: pattern)) != nil else {
                        problems.append(ConfigProblem(
                            path: "agents.\(name).patterns.\(state)",
                            message: "not a valid regex"
                        ))
                        continue
                    }
                    agent.patterns[state] = pattern
                }
                let llm = LLMSettings.Agent(
                    enabled: bool(["agents", name, "llm"]), model: string(["agents", name, "llm_model"])
                )
                if llm != LLMSettings.Agent() { config.llm.agents[name] = llm }
                if let index = config.work.agents.firstIndex(where: { $0.name == name }) {
                    config.work.agents[index] = agent
                } else {
                    config.work.agents.append(agent)
                }
            }
        }
        if config.work.agent(config.work.defaultAgent) == nil {
            problems.append(ConfigProblem(
                path: "sessions.default_agent",
                message: "no agent named \(config.work.defaultAgent)"
            ))
            config.work.defaultAgent = HeedConfig.default.work.defaultAgent
        }

        // [orgs.<name>] and [repos."org/name"]
        if let orgs = root.value(at: ["orgs"])?.table {
            for org in orgs.keys {
                if let color = string(["orgs", org, "color"]) { config.orgColors[org] = color }
                if let issues = visibility(["orgs", org, "issues"]) { config.issues.orgs[org] = issues }
                if let setup = strings(["orgs", org, "setup"]) { config.work.setup.orgs[org] = setup }
                let pilot = pilotOverrides(["orgs", org])
                if !pilot.isEmpty { config.pilot.orgs[org] = pilot }
            }
        }
        // [hosts.<name>]: ssh, tailscale, transport, user, repo_roots, worktree_root, color.
        if let hosts = root.value(at: ["hosts"])?.table {
            let colors = ["teal", "periwinkle", "pink", "sky"]
            for name in hosts.keys.sorted() {
                var host = HostConfig(name: name, ssh: string(["hosts", name, "ssh"]))
                if let roots = strings(["hosts", name, "repo_roots"]) {
                    host.repoRoots = roots
                    host.explicitRepoRoots = true
                }
                if let root = string(["hosts", name, "worktree_root"]) {
                    host.worktreeRoot = root
                    host.explicitWorktreeRoot = true
                }
                if let machine = string(["hosts", name, "tailscale"]) {
                    if machine.isEmpty || machine.contains(where: \.isWhitespace) {
                        problems.append(ConfigProblem(
                            path: "hosts.\(name).tailscale",
                            message: "expected a machine name on your tailnet, like \"devbox\""
                        ))
                    } else {
                        host.tailscale = machine
                    }
                }
                if let transport = string(["hosts", name, "transport"]) {
                    if let parsed = HostTransport(rawValue: transport) {
                        host.transport = parsed
                    } else {
                        problems.append(ConfigProblem(
                            path: "hosts.\(name).transport",
                            message: "expected ssh or tailscale"
                        ))
                    }
                }
                if host.transport == .ssh, host.tailscale != nil {
                    problems.append(ConfigProblem(
                        path: "hosts.\(name).transport",
                        message: "transport = \"ssh\" ignores tailscale = \"\(host.tailscale ?? "")\""
                    ))
                }
                if let user = string(["hosts", name, "user"]), !user.isEmpty { host.user = user }
                if let color = string(["hosts", name, "color"]) {
                    if colors.contains(color) {
                        host.color = color
                    } else {
                        problems.append(ConfigProblem(
                            path: "hosts.\(name).color",
                            message: "expected one of \(colors.joined(separator: ", ")) (amber and green mean states)"
                        ))
                    }
                }
                config.hosts[name] = host
            }
        }
        if let repos = root.value(at: ["repos"])?.table {
            for slug in repos.keys {
                let repo = HeedConfig.RepoConfig(
                    color: string(["repos", slug, "color"]), issues: visibility(["repos", slug, "issues"]),
                    tasks: pairs(["repos", slug, "tasks"])
                )
                config.repos[slug] = repo
                if let setup = strings(["repos", slug, "setup"]) { config.work.setup.repos[slug] = setup }
                if let issues = repo.issues { config.issues.repos[slug] = issues }
                let pilot = pilotOverrides(["repos", slug])
                if !pilot.isEmpty { config.pilot.repos[slug] = pilot }
                if !repo.tasks
                    .isEmpty { config.work.tasks[slug] = repo.tasks.map { TaskSpec(name: $0.0, command: $0.1) } }
            }
        }
        // Launches read it from the work settings; the rule itself is [pilot]'s, with its org and repo levels.
        config.work.signOff = config.pilot.signOffRule

        // [keys]
        if let escape = string(["keys", "insert_escape"]) { config.insertEscape = escape }
        if let shortcut = string(["keys", "global_start_work"]) { config.globalStartWork = shortcut }
        if let shortcut = string(["keys", "global_activate"]) { config.globalActivate = shortcut }
        // [ui]
        if let flag = bool(["ui", "menu_bar"]) { config.showMenuBarItem = flag }
        if let flag = bool(["ui", "dock_state"]) { config.showDockState = flag }
        // [notifications]
        if let flag = bool(["notifications", "enabled"]) { config.notifications.enabled = flag }
        if let flag = bool(["notifications", "asking"]) { config.notifications.asking = flag }
        if let flag = bool(["notifications", "blocked"]) { config.notifications.blocked = flag }
        if let flag = bool(["notifications", "attention"]) { config.notifications.attention = flag }
        if let seconds = integer(["notifications", "grace_seconds"], range: 0 ... 3600) {
            config.notifications.graceSeconds = seconds
        }
        if let minutes = integer(["notifications", "reminder_minutes"], range: 0 ... 1440) {
            config.notifications.reminderMinutes = minutes
        }
        // [attention]
        if let text = string(["attention", "quiet"]) {
            if text.isEmpty {
                config.attention.quiet = nil
            } else if let quiet = QuietHours(parsing: text) {
                config.attention.quiet = quiet
            } else {
                problems.append(ConfigProblem(
                    path: "attention.quiet",
                    message: "expected \"HH:MM-HH:MM\" (24-hour, like \"22:00-07:00\"), or \"\""
                ))
            }
        }
        if let lines = strings(["attention", "rules"]) {
            config.attention.rules = lines
            for problem in AttentionRules(lines: lines).problems {
                problems.append(ConfigProblem(path: "attention.rules", message: problem.description))
            }
        }
        // [summary]
        if let hours = integer(["summary", "away_hours"], range: 0 ... 720) { config.summaryAwayHours = hours }
        if let names = strings(["summary", "when"]) {
            let triggers = names.compactMap { LedgerTrigger(rawValue: $0) }.filter(LedgerTrigger.configurable.contains)
            if triggers.count == names.count {
                config.ledger.when = Set(triggers)
            } else {
                problems.append(ConfigProblem(
                    path: "summary.when",
                    message: "expected some of " + LedgerTrigger.configurable.map { "\"\($0.rawValue)\"" }
                        .joined(separator: ", ")
                ))
            }
        }
        if let hours = integer(["summary", "idle_hours"], range: 0 ... 720) { config.ledger.idleHours = hours }
        if let names = strings(["summary", "include"]) {
            let parts = names.compactMap(LedgerPart.init(rawValue:))
            if parts.count == names.count {
                config.ledger.include = Set(parts)
            } else {
                problems.append(ConfigProblem(
                    path: "summary.include",
                    message: "expected some of " + LedgerPart.allCases.map { "\"\($0.rawValue)\"" }
                        .joined(separator: ", ")
                ))
            }
        }
        // [updates]
        if let flag = bool(["updates", "check"]) { config.updates.check = flag }
        if let text = string(["updates", "install"]) {
            if let install = UpdateSettings.Install(rawValue: text.lowercased()) {
                config.updates.install = install
            } else {
                problems.append(ConfigProblem(path: "updates.install", message: "expected ask or auto"))
            }
        }
        // [log]
        if let days = integer(["log", "shell_days"], range: 1 ... 365) { config.log.shellDays = days }
        if let days = integer(["log", "github_read_days"], range: 1 ... 365) { config.log.githubReadDays = days }
        if let days = integer(["log", "github_write_days"], range: 1 ... 365) { config.log.githubWriteDays = days }
        if let days = integer(["log", "llm_days"], range: 1 ... 365) { config.log.llmDays = days }
        if let days = integer(["log", "decide_days"], range: 1 ... 365) { config.log.decideDays = days }
        if let rows = integer(["log", "max_rows"], range: 1000 ... 1_000_000) { config.log.maxRows = rows }
        // [llm]
        if let flag = bool(["llm", "enabled"]) { config.llm.enabled = flag }
        if let seconds = integer(["llm", "timeout_seconds"], range: 10 ... 900) { config.llm.timeoutSeconds = seconds }
        if let count = integer(["llm", "concurrency"], range: 1 ... 8) { config.llm.concurrency = count }
        if let minutes = integer(["llm", "backoff_minutes"], range: 0 ... 1440) { config.llm.backoffMinutes = minutes }
        if let count = integer(["llm", "daily_calls"], range: 0 ... 100_000) { config.llm.dailyCalls = count }
        if let value = root.value(at: ["llm", "daily_dollars"]) {
            let dollars: Double? = switch value {
            case let .float(number): number
            case let .integer(number): Double(number)
            default: nil
            }
            if let dollars, dollars >= 0 {
                config.llm.dailyDollars = dollars
            } else {
                problems.append(ConfigProblem(
                    path: "llm.daily_dollars",
                    message: "expected a number of dollars, 0 or more"
                ))
            }
        }
        // [local]
        if let flag = bool(["local", "record_screens"]) { config.local.recordScreens = flag }
        if let days = integer(["local", "keep_days"], range: 1 ... 365) { config.local.keepDays = days }
        // [usage]
        if let flag = bool(["usage", "show_cost"]) { config.usage.showCost = flag }
        for (prefix, text) in pairs(["usage", "prices"]) {
            if let price = UsagePrices.Price(parsing: text) {
                config.usage.prices.byPrefix[prefix] = price
            } else {
                problems.append(ConfigProblem(
                    path: "usage.prices.\(prefix)",
                    message: "expected \"input / output\" or \"input / output / cache read / cache write\", USD per million tokens"
                ))
            }
        }

        if let keys = root.value(at: ["keys"])?.table {
            for name in keys.keys where !["insert_escape", "global_start_work", "global_activate"].contains(name) {
                let entries = pairs(["keys", name])
                if let mode = Mode(rawValue: name) {
                    config.keys[mode] = entries
                } else if DefaultKeys.scoped[name] != nil || ["issues", "prs"].contains(name) {
                    config.scopedKeys[name] = entries
                } else {
                    problems.append(ConfigProblem(path: "keys.\(name)", message: "not a mode or a view"))
                }
            }
        }
        return (config, problems)
    }

    /// The commented config written on first launch. Every key is shown with its default.
    public static let defaultSource = """
    # Heed configuration. Saved changes apply right away; mistakes are reported in the status bar and the last good
    # config stays in use. Settings (⌘,) edits this file too, except key bindings, which live only here.

    [worktrees]
    # Worktrees are created at <root>/<repo>/<name>.
    root = "~/code/wt"
    # Directories scanned (two levels deep) for repositories.
    repo_roots = ["~/Projects", "~/code"]
    # Repos outside the roots, added when you import one of their worktrees by path (I in Sessions, :import <path>).
    repo_paths = []
    # Branches get a prefix picked by the prompt's first word ("Fix broken anchors" → fix/broken-anchors), else this.
    # "" means no prefix. The worktree folder uses - for /.
    default_prefix = "feature"
    # When heed first starts an agent in a repo, offer (once per repo) to trust it ahead of time: for Claude Code, so it
    # does not ask in every new worktree, and for mise when the repo's config sets [env]. Local repos only.
    offer_trust = true

    [worktrees.prefixes]
    fix = ["fix", "bug", "broken", "crash", "repair", "resolve"]
    bump = ["bump", "upgrade", "update"]
    chore = ["chore", "cleanup", "tidy", "remove", "rename"]
    refactor = ["refactor", "restructure", "simplify"]
    docs = ["docs", "doc", "document", "readme"]
    test = ["test", "tests", "cover"]
    perf = ["perf", "speed", "optimize", "faster"]
    feature = ["add", "implement", "support", "create", "introduce", "build", "feature"]

    [start_work]
    # Where the Mac has Apple's on-device model (Apple Intelligence, macOS 26): it suggests the repo when the prompt
    # names none, the branch name's words, and the prefix when the first word picks none. On this Mac only, never sent
    # anywhere; your own picks and typing always win. Elsewhere, or false: the rules above alone.
    smart_guesses = true

    [sessions]
    default_agent = "claude"
    # On launch: ask which sessions to resume, resume them all, or none.
    resume_on_launch = "ask"           # ask | always | never
    # Typed into a resumed session that was mid-turn, once the agent is idle. "" turns it off.
    continue_prompt = "Continue where you left off."
    # Open a shell split beside the agent in new sessions (Start work can still toggle it per session).
    shell_split = false
    # Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
    # and come back as they were: auto (zmx when it is installed and works; Settings > General shows its check),
    # zmx, or none (panes end with heed).
    persist = "auto"

    [cleanup]
    # Automatic cleanup, off by default. When on, worktrees with no activity (agent output, keystrokes, commits, PR
    # events) for idle_days are removed, wherever they live. Dirty or unpushed work is never removed, nor a pinned
    # session's.
    enabled = false
    idle_days = 14
    delete_branch = true               # the local branch; the remote is left alone
    ask_before_sweep = false
    # Removing a worktree saves its commits (and uncommitted changes) as refs/heed/archive/<branch> first, so R in
    # History can bring it back. Sweeps drop those older than this many days; 0 keeps them.
    keep_archive_days = 90

    [github]
    # How often the view on screen refreshes from GitHub; the others refresh five times less often.
    poll_seconds = 60

    [pilot]
    # Follow the PRs your sessions track: their review threads and failing checks, shown in the Watch view (gw).
    # Read-only, so on; turn it off for an org or a repo under [orgs.<name>] or [repos."org/name"] (watch = false).
    watch = true
    # What happens to what a watched PR collects: off (shown only), ask (you queue it) or auto (sent to the agent
    # once it is idle). Also per org and per repo.
    green = "ask"
    # Prompts sent without a new approval before get it green stops.
    max_rounds = 3
    # Where each round of get it green (or get it merged) goes: background (an agent in its own tab, worktree and branch,
    # heed/get-it-green/<branch>, all removed when it is done) or session (the session's own agent, once it is idle and
    # you have not typed in it for five minutes). Also per org and per repo.
    run_in = "background"
    # Which agent and model background runs use; empty: the session's agent and that agent's default model. Also per
    # org and per repo.
    agent = ""
    model = ""
    # Merge conflicts with the base are usually simple: background runs for them can use a cheaper agent and model.
    # Empty: agent and model above. Also per org and per repo.
    merge_agent = ""
    merge_model = ""
    # A run still working after this long is stopped.
    run_timeout = "30m"
    # How long zp pauses a PR: 30m, 1h, 4h, 1d, or forever.
    pause = "1h"
    # Get it merged: off; auto (heed turns on GitHub's auto-merge for a PR, and GitHub merges it once its own
    # requirements are met); or heed (heed merges it itself once the rules below hold). Per org and per repo too, and M
    # cycles one PR.
    merge = "off"
    # squash, merge or rebase; unset takes the first the repo allows, in that order.
    # merge_method = "squash"
    # How often a repo's merge queue runs (15m, 1h, ...), or manual (only :merge.run).
    merge_schedule = "1h"
    # Bring the queue's PRs that fell behind their base up to date on each run.
    update_branches = true
    # Hand work on a watched PR to GitHub's Copilot coding agent instead of your session's agent, sparing its tokens:
    # merge conflicts, review comments, or both (one comment on the PR asks for both). Only where Copilot can work in
    # the repo; elsewhere, and with these off, your agent gets them. Per org and per repo too.
    copilot_conflicts = false
    copilot_comments = false
    # Who heed asks to review a PR once it is open and not a draft, once per PR: logins, "org/team", or "copilot".
    reviewers = []
    # merge = "heed" merges a PR when it is green, reviewed after its last push (a human approval, or a trusted AI
    # reviewer's), quiet for quiet_minutes, its gate_checks passed, without a hold label, and, with self_review set,
    # approved by that command. Each per org and per repo too.
    quiet_minutes = 5
    # AI reviewers whose review counts: an approval, a comment review with none of its threads open, or no review at
    # all once its review check (named in gate_checks) passed on the head commit.
    trusted_reviewers = []    # e.g. ["copilot-pull-request-reviewer"]
    gate_checks = []
    hold_labels = ["hold", "do-not-merge", "wip"]
    # A command that reads the prompt and the PR's diff on stdin and answers APPROVE, or REQUEST_CHANGES: <why>.
    # self_review = "claude -p"
    # [repos."org/name"] admin_merge = true retries a refused merge with --admin, bypassing branch protection. Repo only.
    # Extra instructions heed adds to its prompts, per org and per repo too (a repo's "" clears its org's): after get it
    # green's feedback items, to the self-review's criteria, after the issue text Start work begins from, and to what
    # heed asks its model calls ([llm]) for in a summary. They add to what heed sends, and the agent still reads the
    # repo's own AGENTS.md or CLAUDE.md.
    # green_instructions = "Resolve the review threads your changes addressed, and any that no longer apply."
    # review_instructions = ""
    # start_instructions = ""
    # summary_instructions = ""
    # Ask agents (claude, codex) to end their final message with a "heed-summary: ..." line, which then is the ledger's
    # summary (History, L). Off by default; per org and per repo too.
    summary_sign_off = false

    [issues]
    # Which issues the Issues view shows per repo: "involved" (assigned to you or mentioning you) or "all" open
    # issues. Override per org ([orgs.<org>] issues = "all") or per repo ([repos."org/name"] issues = "involved");
    # the most specific wins. w in Issues (I in Repos) flips the repo under the cursor.
    default = "involved"

    [ui]
    # A menu bar item: an owl that shows how many sessions need you, with those sessions, Start work and Open Heed.
    menu_bar = true
    # The Dock icon shows the same: a badge in the state's colour (blocked, else asking) with the count.
    dock_state = true

    [notifications]
    # A macOS notification when a session starts needing you (its agent, a helper tab, or a PR the pilot cannot send
    # feedback for), unless Heed is in front showing that session. Several within a few seconds come as one. Open brings
    # Heed forward on the session; a Claude permission prompt also gets Allow. Per state: asking (questions, a plan to
    # approve) and blocked (a permission prompt).
    enabled = true
    asking = true
    blocked = true
    # Attention items a rule says to notify about (notify, or boost 3), several from one sync as one notification.
    attention = true
    # Only once it has needed you this long, so a prompt that clears itself stays quiet; 0 notifies at once.
    grace_seconds = 30
    # One reminder if it still needs you this long after the notification, then nothing until it comes back; 0: none.
    reminder_minutes = 15

    [attention]
    # Quiet hours: no notifications from start to end, local time, 24-hour ("22:00-07:00"); "" for none. What needed
    # you meanwhile is not notified when they end: Needs you and the Dock badge show it. macOS Focus applies as well.
    quiet = ""
    # What matters in Attention, one rule a line, first match wins: what to match, then boost 1-3, lower, ignore, pin
    # or notify. Inputs: mention, review, assigned, ci, mine, agent, user:me, team:org/slug (team:? when unknown),
    # requested:me|team, author (a login, me, bot, bot:name, human), label, repo, branch, kind, draft, ready,
    # size >n, age >7d, turn mine|theirs, reason, any. Globs (*, ?) and a|b work in values. Ignored items stay
    # under Muted for 30 days. Settings › Attention edits them and shows what an edit would change.
    # rules = [
    #   "mention user:me             boost 3",
    #   "review requested:me         boost 2",
    #   "mention team:acme/docs-eng  boost 2",
    #   "mention team:acme/everyone  ignore",
    #   "author bot:dependabot       ignore",
    #   "label \"blocker\"             pin",
    #   "agent blocked|asking        boost 3",
    #   "ci branch:main              lower",
    # ]

    [summary]
    # While you were away: what still waits on you, then what merged, how background runs ended, which agents
    # finished, the reviews that arrived and the sessions that closed, by day. It opens on its own when you come back
    # after this many hours away from the Mac or with heed quit (0: never on its own); gZ opens it any time.
    away_hours = 8
    # History's ledger (L in History): a short summary of each piece of work, kept after its worktree is gone, written
    # by a cheap model through heed's model calls ([llm]). When: "pr_opened", "pr_merged", "worktree_removed" (the
    # removal waits for it, 30 s at most), "idle" (no activity for idle_hours), "chat_closed". ledger.summarize writes
    # one any time. Include: "summary", "decisions", "follow_ups", "files" (from git, no model).
    when = ["pr_opened", "pr_merged", "worktree_removed", "idle"]
    idle_hours = 24
    include = ["summary", "decisions", "follow_ups", "files"]

    [updates]
    # Look for a new version of heed once a day (on GitHub, heed's releases). Each update is signed; heed installs
    # only what its key signed, and Apple has notarized.
    check = true
    # ask: show what is new and install when you say so. auto: download in the background and install on quit.
    install = "ask"                    # ask | auto

    [usage]
    # The inspector shows each session's model and tokens, as its agent's hooks report them, and a cost marked ≈: what
    # the agent reported (opencode), else an estimate from the prices below. false leaves the cost out.
    show_cost = true
    # USD per million tokens, by model name prefix (the longest match wins): "input / output", or
    # "input / output / cache read / cache write" (cache defaults: a tenth of input to read, 1.25× to write). None are
    # built in, so with none set only reported costs show.
    [usage.prices]
    # "model-a" = "3 / 15"

    [log]
    # The call log (:log): every command heed runs, its GitHub calls and (later) its model runs, with how long each
    # took and how it ended. Kept this many days per kind, and at most max_rows rows of each kind; pruned hourly.
    shell_days = 7
    github_read_days = 3
    github_write_days = 90
    llm_days = 30
    decide_days = 30
    max_rows = 50000

    [llm]
    # heed's own short model calls (summaries, typed decisions), made headless through the agent CLIs you are logged
    # in to (claude, codex, gemini, opencode, pi, cursor), each with a cheap model, taking turns. No API keys: your
    # logins are used as they are. Each call runs in an empty temporary directory with tools off and nothing saved, and
    # shows in :log with which agent took it and why others were skipped. false: heed makes no model calls at all.
    enabled = true
    # A call still running after this long is stopped; this many run at once (more wait, the ones you asked for first).
    timeout_seconds = 120
    concurrency = 2
    # An agent whose call failed is skipped for this long; one rate limited in a session, until its limit resets.
    backoff_minutes = 10
    # Per agent per day: background calls stop until tomorrow at this many calls, or once this many dollars were spent
    # (counted where a cost is known: reported by the agent, or estimated from [usage.prices]). 0: no cap.
    daily_calls = 100
    daily_dollars = 1.0

    [local]
    # Screen snapshots for a local decision model to learn from: at each state an agent's hooks report (working,
    # asking, blocked, idle, done), the cleaned last 30 lines of its pane, the agent and the state; now and then one
    # while it works; and, unlabelled, states read from the screen. Kept in heed.sqlite on this Mac only, never sent
    # anywhere and never in the call log; dropped after keep_days, the oldest first past 64 MB. Off by default.
    record_screens = false
    keep_days = 30

    [tools]
    # Where git and gh are. Empty means detect: your login shell's PATH (fish, zsh, bash, nu), then the usual places
    # (Homebrew, mise, nix, ~/.local/bin), then /usr/bin. Set a path when detection picks the wrong one.
    git = ""                           # e.g. "/opt/homebrew/bin/git"
    gh = ""
    # The tailscale CLI, for hosts on your tailnet. Empty: the search path, then the Tailscale app's own binary.
    tailscale = ""
    # Directories searched first, for git, gh and agent commands alike.
    path = []

    # Agents. Built-ins (claude, codex, cursor, pi, opencode, gemini) can be overridden field by field; any other name
    # is a custom agent. Fields: command, prompt (argument | stdin | paste | file), plan, resume ("{id}" is the
    # agent's session id), and [agents.<name>.profiles] of name = command line. For heed's own model calls ([llm]):
    # llm = false leaves an agent out, and llm_model picks its model (empty: a cheap one heed detects, haiku for claude).
    [agents.claude]
    command = "claude"
    plan = "--permission-mode plan"
    resume = "--resume {id}"
    # llm = true
    # llm_model = "haiku"

    # [agents.mytool]
    # command = "mytool"
    # prompt = "argument"
    # Agents without hooks get their state read from the screen; patterns per state refine it (regex):
    # [agents.mytool.patterns]
    # blocked = "Allow this\\?"
    # working = "Thinking"

    # Org and repo colors: teal, pink, lime, orange, periwinkle, sky. Repos inherit their org's.
    # [orgs.acme]
    # color = "teal"
    # issues = "all"

    # Setup per repo (or per org): commands each new worktree runs before its agent starts, joined with &&. Unset, heed
    # proposes what it detects (mise install when the repo uses mise, else its lockfiles' installs) and runs nothing
    # until you approve it in Repos (S); [] runs nothing and stops the proposal. Files .worktreeinclude names (gitignored
    # ones only) are copied from the main checkout into each new worktree either way.
    # [repos."acme/docs-toolkit"]
    # setup = ["pnpm install"]

    # Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph. New sessions open them as
    # tabs; ! picks one to run, from these and what the worktree offers (mise tasks, make targets, package.json scripts).
    # [repos."acme/docs-toolkit".tasks]
    # test = "dotnet test"

    # Hosts: machines heed drives over your own ssh (gH adds them from ~/.ssh/config or your tailnet). A host whose
    # machine is on your tailnet goes over it, its ssh alias pointed at the machine's MagicDNS name; a machine running
    # Tailscale SSH needs no key of yours. transport = "ssh" keeps a host off the tailnet.
    # [hosts.devbox]
    # ssh = "devbox"                   # an alias from ~/.ssh/config, or user@address; the name by default
    # tailscale = "devbox"             # the machine on your tailnet, when its name differs
    # transport = "ssh"                # ssh | tailscale; unset prefers the tailnet
    # user = "you"                     # who to log in as over the tailnet, without an ssh alias
    # repo_roots = ["~/code"]          # where its repos are, two levels deep; unset, heed asks after the first check
    # worktree_root = "~/code/wt"      # where its worktrees go; :host.roots (ctrl-r in gH) asks again
    # color = "teal"                   # teal, periwinkle, pink or sky

    [keys]
    # Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
    insert_escape = "<C-\\\\>"
    # Opens Start work in a floating panel over any app, wherever you are; "" turns it off. The panel's window title is
    # "Heed Start Work", for window manager rules (yabai: app="^Heed$" title="^Heed Start Work$" manage=off).
    global_start_work = "<C-M-Space>"
    # Brings Heed to the front from any app; "" turns it off.
    global_activate = "<C-M-h>"
    # Shift+Escape leaves INSERT too; a plain Escape always goes to the terminal. [keys.insert] "<S-Esc>" = "" unbinds.

    # Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.repos], [keys.inbox], [keys.history],
    # [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
    # [keys.normal]
    # "gC" = ""
    # "<C-j>" = "row.next"
    """
}

/// `[updates]`.
public struct UpdateSettings: Equatable, Sendable {
    public enum Install: String, Sendable {
        case ask, auto
    }

    public var check = true
    public var install = Install.ask

    public init(check: Bool = true, install: Install = .ask) {
        self.check = check
        self.install = install
    }
}

/// `[notifications]`.
public struct NotificationSettings: Equatable, Sendable {
    public var enabled = true
    public var asking = true
    public var blocked = true
    /// Attention items a rule says to notify about.
    public var attention = true
    /// How long something must keep needing you before it notifies, so a prompt that clears itself stays quiet. 0:
    /// at once (after the few seconds that gather a burst into one).
    public var graceSeconds = 30
    /// One reminder when it still needs you this long after the notification; 0: none.
    public var reminderMinutes = 15

    public init(
        enabled: Bool = true, asking: Bool = true, blocked: Bool = true, graceSeconds: Int = 30,
        reminderMinutes: Int = 15
    ) {
        self.enabled = enabled
        self.asking = asking
        self.blocked = blocked
        self.graceSeconds = graceSeconds
        self.reminderMinutes = reminderMinutes
    }

    /// Whether a session (or a helper tab) entering `state` is worth a notification: the Needs you states, each when
    /// turned on. A PR that needs you only asks for `enabled`.
    public func wants(_ state: AgentState) -> Bool {
        guard enabled else { return false }
        return switch state {
        case .asking: asking
        case .blocked: blocked
        default: false
        }
    }
}
