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
            flat(lhs.keys) == flat(rhs.keys),
            flat(lhs.scopedKeys) == flat(rhs.scopedKeys),
            lhs.orgColors == rhs.orgColors,
            lhs.repos == rhs.repos,
            lhs.cleanup == rhs.cleanup,
            lhs.githubPollSeconds == rhs.githubPollSeconds,
            lhs.tools == rhs.tools,
            lhs.issues == rhs.issues,
            lhs.pilot == rhs.pilot,
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
        if let flag = bool(["sessions", "shell_split"]) { config.work.shellSplit = flag }
        if let text = string(["sessions", "persist"]) {
            if let persist = PanePersistence(rawValue: text.lowercased()) {
                config.work.persist = persist
            } else {
                problems.append(ConfigProblem(path: "sessions.persist", message: "expected none or zmx"))
            }
        }
        // [cleanup]
        if let flag = bool(["cleanup", "enabled"]) { config.cleanup.enabled = flag }
        if let days = integer(["cleanup", "idle_days"], range: 1 ... 365) { config.cleanup.idleDays = days }
        if let flag = bool(["cleanup", "delete_branch"]) { config.cleanup.deleteBranch = flag }
        if let flag = bool(["cleanup", "ask_before_sweep"]) { config.cleanup.askBeforeSweep = flag }
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
                if let issues = visibility(["orgs", org, "issues"]) { config.issues.orgs[org] = issues }
                let pilot = pilotOverrides(["orgs", org])
                if !pilot.isEmpty { config.pilot.orgs[org] = pilot }
            }
        }
        if let repos = root.value(at: ["repos"])?.table {
            for slug in repos.keys {
                let repo = HeedConfig.RepoConfig(
                    color: string(["repos", slug, "color"]), issues: visibility(["repos", slug, "issues"]),
                    tasks: pairs(["repos", slug, "tasks"])
                )
                config.repos[slug] = repo
                if let issues = repo.issues { config.issues.repos[slug] = issues }
                let pilot = pilotOverrides(["repos", slug])
                if !pilot.isEmpty { config.pilot.repos[slug] = pilot }
                if !repo.tasks
                    .isEmpty { config.work.tasks[slug] = repo.tasks.map { TaskSpec(name: $0.0, command: $0.1) } }
            }
        }

        // [keys]
        if let escape = string(["keys", "insert_escape"]) { config.insertEscape = escape }
        if let shortcut = string(["keys", "global_start_work"]) { config.globalStartWork = shortcut }
        if let shortcut = string(["keys", "global_activate"]) { config.globalActivate = shortcut }
        // [ui]
        if let flag = bool(["ui", "menu_bar"]) { config.showMenuBarItem = flag }
        if let flag = bool(["ui", "dock_state"]) { config.showDockState = flag }

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
    # Open a shell split beside the agent in new sessions (Start work can still toggle it per session).
    shell_split = false
    # Keep every pane's terminal alive in a zmx session, so agents keep running when heed quits, restarts or updates,
    # and come back as they were: none (panes end with heed) or zmx.
    persist = "none"

    [cleanup]
    # Automatic cleanup, off by default. When on, worktrees with no activity (agent output, keystrokes, commits, PR
    # events) for idle_days are removed, wherever they live. Dirty or unpushed work is never removed, nor a pinned
    # session's.
    enabled = false
    idle_days = 14
    delete_branch = true               # the local branch; the remote is left alone
    ask_before_sweep = false

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

    [tools]
    # Where git and gh are. Empty means detect: your login shell's PATH (fish, zsh, bash, nu), then the usual places
    # (Homebrew, mise, nix, ~/.local/bin), then /usr/bin. Set a path when detection picks the wrong one.
    git = ""                           # e.g. "/opt/homebrew/bin/git"
    gh = ""
    # Directories searched first, for git, gh and agent commands alike.
    path = []

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
    # issues = "all"

    # Pinned tasks per repo, each run in its own pane; the exit code sets the tab's glyph.
    # [repos."elastic/docs-builder".tasks]
    # test = "dotnet test"

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
