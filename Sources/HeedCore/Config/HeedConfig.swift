import Foundation

/// Everything `~/.config/heed/config.toml` says, as domain values. Every section has one shape: agents are all
/// `[agents.<name>]` with the same fields (built-in or custom), key bindings are `[keys.<mode or view>]` tables of
/// notation = command, repos and orgs are keyed by name.
public struct HeedConfig: Equatable, Sendable {
    public var work: WorkSettings
    public var insertEscape: String
    /// `[keys.normal]`, `[keys.visual]`, ...: overrides laid over the defaults.
    public var keys: [Mode: [(String, String)]]
    /// `[keys.repos]`, `[keys.inbox]`, ...: per-view overrides.
    public var scopedKeys: [String: [(String, String)]]
    public var orgColors: [String: String]
    public var repos: [String: RepoConfig]
    public var cleanup: CleanupRule
    public var githubPollSeconds: Int

    public struct RepoConfig: Equatable, Sendable {
        public var color: String?
        /// Pinned tasks (test, build, docs preview): name → command.
        public var tasks: [(String, String)]

        public static func == (lhs: RepoConfig, rhs: RepoConfig) -> Bool {
            lhs.color == rhs.color && lhs.tasks.map(\.0) == rhs.tasks.map(\.0) && lhs.tasks.map(\.1) == rhs.tasks
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
        return lhs.work == rhs.work && lhs.insertEscape == rhs.insertEscape && flat(lhs.keys) == flat(rhs.keys)
            && flat(lhs.scopedKeys) == flat(rhs.scopedKeys) && lhs.orgColors == rhs.orgColors && lhs.repos == rhs.repos
            && lhs.cleanup == rhs.cleanup && lhs.githubPollSeconds == rhs.githubPollSeconds
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

    public init(enabled: Bool = false, idleDays: Int = 14, deleteBranch: Bool = true, askBeforeSweep: Bool = false) {
        self.enabled = enabled
        self.idleDays = idleDays
        self.deleteBranch = deleteBranch
        self.askBeforeSweep = askBeforeSweep
    }
}

public struct ConfigProblem: Equatable, Sendable, CustomStringConvertible {
    public let path: String
    public let message: String
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
        if let prefix = string(["worktrees", "default_prefix"]) { config.work.prefixes.defaultPrefix = prefix }
        if let table = root.value(at: ["worktrees", "prefixes"])?.table {
            var prefixes: [String: [String]] = [:]
            for prefix in table.keys {
                if let words = strings(["worktrees", "prefixes", prefix]) {
                    prefixes[prefix] = words.map { $0.lowercased() }
                }
            }
            config.work.prefixes.prefixes = prefixes
        }
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
        // [cleanup]
        if let flag = bool(["cleanup", "enabled"]) { config.cleanup.enabled = flag }
        if let days = integer(["cleanup", "idle_days"], range: 1 ... 365) { config.cleanup.idleDays = days }
        if let flag = bool(["cleanup", "delete_branch"]) { config.cleanup.deleteBranch = flag }
        if let flag = bool(["cleanup", "ask_before_sweep"]) { config.cleanup.askBeforeSweep = flag }
        // [github]
        if let seconds = integer(["github", "poll_seconds"], range: 15 ... 3600) { config.githubPollSeconds = seconds }

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
            }
        }
        if let repos = root.value(at: ["repos"])?.table {
            for slug in repos.keys {
                let repo = HeedConfig.RepoConfig(
                    color: string(["repos", slug, "color"]), tasks: pairs(["repos", slug, "tasks"])
                )
                config.repos[slug] = repo
                if !repo.tasks
                    .isEmpty { config.work.tasks[slug] = repo.tasks.map { TaskSpec(name: $0.0, command: $0.1) } }
            }
        }

        // [keys]
        if let escape = string(["keys", "insert_escape"]) { config.insertEscape = escape }
        if let keys = root.value(at: ["keys"])?.table {
            for name in keys.keys where name != "insert_escape" {
                let entries = pairs(["keys", name])
                if let mode = Mode(rawValue: name) {
                    config.keys[mode] = entries
                } else if DefaultKeys.scoped[name] != nil || ["sessions", "issues", "prs"].contains(name) {
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
    # Branches get a prefix picked by the prompt's first word ("Fix broken anchors" → fix/broken-anchors), else this.
    # "" means no prefix. The worktree folder uses - for /.
    default_prefix = "feature"

    [worktrees.prefixes]
    fix = ["fix", "bug", "broken", "crash", "repair", "resolve"]
    bump = ["bump", "upgrade", "update"]
    chore = ["chore", "cleanup", "tidy", "remove", "rename"]
    refactor = ["refactor", "restructure", "simplify"]
    docs = ["docs", "doc", "document", "readme"]
    test = ["test", "tests", "cover"]
    perf = ["perf", "speed", "optimize", "faster"]
    feature = ["add", "implement", "support", "create", "introduce", "build", "feature"]

    [sessions]
    default_agent = "claude"
    # On launch: ask which sessions to resume, resume them all, or none.
    resume_on_launch = "ask"           # ask | always | never
    # Typed into a resumed session that was mid-turn, once the agent is idle. "" turns it off.
    continue_prompt = "Continue where you left off."

    [cleanup]
    # Automatic cleanup, off by default. When on, worktrees with no activity (agent output, keystrokes, commits, PR
    # events) for idle_days are removed, wherever they live. Dirty or unpushed work is never removed, nor a pinned
    # session's.
    enabled = false
    idle_days = 14
    delete_branch = true               # the local branch; the remote is left alone
    ask_before_sweep = false

    [github]
    poll_seconds = 60

    # Agents. Built-ins (claude, codex, cursor, pi, opencode, gemini) can be overridden field by field; any other name
    # is a custom agent. Fields: command, prompt (argument | stdin | paste | file), plan, resume ("{id}" is the
    # agent's session id), and [agents.<name>.profiles] of name = command line.
    [agents.claude]
    command = "claude"
    plan = "--permission-mode plan"
    resume = "--resume {id}"

    # [agents.mytool]
    # command = "mytool"
    # prompt = "argument"
    # Agents without hooks get their state read from the screen; patterns per state refine it (regex):
    # [agents.mytool.patterns]
    # blocked = "Allow this\\?"
    # working = "Thinking"

    # Org and repo colors: teal, pink, lime, orange, periwinkle, sky. Repos inherit their org's.
    # [orgs.elastic]
    # color = "teal"

    # Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph.
    # [repos."elastic/docs-builder".tasks]
    # test = "dotnet test"

    [keys]
    # Leaves INSERT. It is also the terminal's quit signal, so pick something else if you need that.
    insert_escape = "<C-\\\\>"

    # Bindings per mode ([keys.normal], [keys.visual], ...) or per view ([keys.repos], [keys.inbox], [keys.history],
    # [keys.diff], [keys.pr]), in vim notation, each naming a command (the same names : completes). "" unbinds.
    # [keys.normal]
    # "gC" = ""
    # "<C-j>" = "row.next"
    """
}
