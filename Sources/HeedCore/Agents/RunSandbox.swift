import Foundation

/// The folder a run heed starts writes its report and last message to: heed's own, outside the run's worktree, new
/// for every run, so what the run reads back is only what it wrote. On this Mac it is
/// `~/Library/Application Support/Heed/runs/<run id>`; on a host, `~/.heed/runs/<run id>`.
public enum RunFolder {
    /// `~/Library/Application Support/Heed/runs`.
    public static func localRoot() -> String {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed/runs").path
    }

    public static func path(run: String, root: String = localRoot()) -> String {
        let base = root.hasSuffix("/") ? String(root.dropLast()) : root
        return "\(base)/\(run)"
    }

    /// On a host, under its home (kept as `~/` so the host's shell expands it).
    public static func hostPath(run: String) -> String { "~/.heed/runs/\(run)" }

    /// Where `gh` looks for its login during the run: an empty folder of the run's own, so it has none.
    public static func ghConfig(_ folder: String) -> String { "\(folder)/gh" }

    /// Report files a branch could carry in the worktree, under `.heed/`: removed before a run starts, and never read.
    public static let worktreeLeftovers = ["review.json", "evaluation.json", "last-message.txt"]

    public static func leftovers(in worktree: String) -> [String] {
        worktreeLeftovers.map { "\(worktree)/.heed/\($0)" }
    }

    /// Whether a report was written by this run: changed at or after the run started (a second of slack for file
    /// systems that keep whole seconds).
    public static func isFresh(modified: Date?, started: Date) -> Bool {
        guard let modified else { return false }
        return modified >= started.addingTimeInterval(-1)
    }

    /// Makes the run's folder empty and new: anything left under the same id goes first.
    public static func prepare(_ folder: String) throws {
        let files = FileManager.default
        if files.fileExists(atPath: folder) { try files.removeItem(atPath: folder) }
        try files.createDirectory(atPath: ghConfig(folder), withIntermediateDirectories: true)
    }

    /// A report this run wrote: the file's contents when it changed after `started`, else nil.
    public static func read(_ path: String, started: Date) -> Data? {
        let modified = (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        guard isFresh(modified: modified, started: started) else { return nil }
        return FileManager.default.contents(atPath: path)
    }

    /// The text of a last-message file this run wrote.
    public static func readText(_ path: String, started: Date) -> String? {
        read(path, started: started).map { String(decoding: $0, as: UTF8.self) }
    }

    public static func remove(_ folder: String) {
        try? FileManager.default.removeItem(atPath: folder)
    }

    /// The commands that make a host's run folder new (`rm -rf`, then `mkdir -p` with its gh folder).
    public static func hostPrepare(_ folder: String) -> [[String]] {
        [["rm", "-rf", folder], ["mkdir", "-p", ghConfig(folder)]]
    }

    /// A new, empty run folder for `run` where `location` is: its path.
    public static func make(run: String, on location: Location) async throws -> String {
        guard !location.isLocal else {
            let folder = path(run: run)
            try prepare(folder)
            return folder
        }
        let folder = hostPath(run: run)
        for command in hostPrepare(folder) {
            _ = try await ProcessRunner.output(
                on: location, command[0], Array(command.dropFirst()), caller: "runs.folder"
            )
        }
        return folder
    }

    /// Removes report files the worktree's branch carries, before the run starts.
    public static func clearLeftovers(in worktree: String, on location: Location) async {
        let paths = leftovers(in: worktree)
        if location.isLocal {
            for path in paths {
                try? FileManager.default.removeItem(atPath: path)
            }
        } else {
            _ = try? await ProcessRunner.run(on: location, "rm", ["-f"] + paths, caller: "runs.folder")
        }
    }

    /// Removes the run's folder when the run is done with it.
    public static func discard(_ folder: String, on location: Location) async {
        if location.isLocal {
            remove(folder)
        } else {
            _ = try? await ProcessRunner.run(on: location, "rm", ["-rf", folder], caller: "runs.folder")
        }
    }
}

/// The OS sandboxes heed starts review, walk and spawn runs in when they work on someone else's code or text, as the
/// agents' own CLIs offer them (checked against `claude --help` 2.1.319 and the Claude Code settings schema, and
/// `codex exec --help` 0.163.0 with its `sandbox_workspace_write` config):
///
/// - claude: its sandbox through `--settings` (`sandbox.enabled`, `failIfUnavailable`, no unsandboxed commands,
///   writes only to the worktree and the run's folder, no network but the hosts the run needs, credential folders
///   unreadable), only your user settings besides (`--setting-sources user`: none from the worktree, which the branch
///   could carry), and no MCP servers (`--strict-mcp-config`).
/// - codex: a permissions profile of heed's (`default_permissions`, checked against `codex sandbox` 0.163.0): writes
///   in the worktree, the run's folder and the temp folders, credential folders unreadable, no network.
/// - others: no sandbox heed can ask for; heed says so on the run and does not start them on its own for someone
///   else's PR.
///
/// What a sandboxed run cannot do: reach the network (a review not at all; a walk only package registries; codex
/// never),
/// write outside its worktree and its run folder (so caches in your home and the repo's shared git folder are
/// read-only), use your GitHub, ssh or cloud logins, or run anything outside the sandbox. Its environment starts
/// empty and gets back only what it needs (`environment`). Tests that download
/// packages or need a login fail there, and the run is told to say so in its report rather than retry.
public enum RunSandbox {
    /// What the run may reach over the network.
    public enum Network: Hashable, Sendable {
        /// Nothing (reviews).
        case none
        /// Package registries only (walks, which install what a newcomer would).
        case packages
    }

    /// The registries a walk may reach: what a README's install step usually fetches from.
    public static let packageHosts = [
        "registry.npmjs.org", "registry.yarnpkg.com", "pypi.org", "files.pythonhosted.org", "crates.io",
        "index.crates.io", "static.crates.io", "proxy.golang.org", "sum.golang.org", "api.nuget.org",
        "rubygems.org", "repo.maven.apache.org", "formulae.brew.sh", "ghcr.io", "objects.githubusercontent.com",
    ]

    /// Whether heed can hold `agent` to a sandbox.
    public static func isSandboxed(agent: String) -> Bool { ["claude", "codex"].contains(agent) }

    /// Credential folders a sandboxed run's commands and file tools may not read.
    public static let credentialPaths = [
        "~/.ssh", "~/.gnupg", "~/.aws", "~/.azure", "~/.config/gcloud", "~/.config/gh", "~/.kube", "~/.docker",
        "~/.netrc", "~/.npmrc", "~/.pypirc", "~/.git-credentials", "~/.config/git/credentials",
    ]

    /// A path as Claude's sandbox settings take it: `//abs` for an absolute path, `~/…` as it is.
    static func sandboxPath(_ path: String) -> String { path.hasPrefix("/") ? "/" + path : path }

    /// Claude's settings for a sandboxed run, as JSON (`--settings` takes a JSON string). `hooks`: heed's hook
    /// settings for a run in a tab, folded in because claude takes one `--settings`.
    public static func claudeSettings(
        worktree: String, folder: String, network: Network, deny: [String], hooks: Bool = false,
        autoAllow: Bool = true
    ) -> String {
        let domains = network == .packages ? packageHosts : []
        var settings: [String: Any] = [
            "sandbox": [
                "enabled": true,
                "failIfUnavailable": true,
                "allowUnsandboxedCommands": false,
                "autoAllowBashIfSandboxed": autoAllow,
                "network": ["allowedDomains": domains, "allowLocalBinding": false],
                "filesystem": [
                    "allowWrite": [sandboxPath(worktree), sandboxPath(folder)],
                    "denyRead": credentialPaths,
                ],
            ],
            "permissions": [
                "deny": deny + credentialPaths.flatMap { ["Read(\($0))", "Read(\($0)/**)"] },
            ],
        ]
        if hooks,
           let data = AgentIntegration.claudeSettingsJSON().data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            settings["hooks"] = object["hooks"]
        }
        let data = try? JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys, .withoutEscapingSlashes]
        )
        return data.map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    /// What every sandboxed claude run is denied, whatever else it may use.
    public static let claudeDenied = [
        "WebFetch", "WebSearch", "Bash(git push:*)", "Bash(git commit:*)", "Bash(gh:*)",
    ]

    /// claude's arguments: the settings, then the tool lists, then `--permission-mode dontAsk` (nobody is there to
    /// answer; it also ends the variadic tool lists, so a prompt after them stays the prompt).
    /// `autoAllow`: every sandboxed shell command allowed without a rule (off keeps the shell to `allowed`).
    public static func claude(
        allowed: [String], denied: [String], worktree: String, folder: String, network: Network, hooks: Bool = false,
        mode: String = "dontAsk", autoAllow: Bool = true
    ) -> [String] {
        let deny = denied + claudeDenied.filter { !denied.contains($0) }
        let settings = claudeSettings(
            worktree: worktree, folder: folder, network: network, deny: deny, hooks: hooks, autoAllow: autoAllow
        )
        return [
            "--settings", settings,
            "--setting-sources", "user",
            "--strict-mcp-config",
            "--allowedTools",
        ] + allowed + ["--disallowedTools"] + deny + ["--permission-mode", mode]
    }

    /// The name of the permissions profile heed gives a codex run (`default_permissions`).
    static let codexProfile = "heed-run"

    /// codex's: a permissions profile of heed's own (`default_permissions`), on codex's `:workspace` (writes in the
    /// worktree and the temp folders), with the run's folder writable, the credential folders unreadable and no
    /// network. No `--sandbox` flag: codex takes the flag over the profile (checked with `codex exec` 0.163.0).
    public static func codex(folder: String) -> [String] {
        let entries = credentialPaths.map { "\(tomlString($0))=\"none\"" } + ["\(tomlString(folder))=\"write\""]
        let profile = "permissions.\(codexProfile)"
        return [
            "-c", "default_permissions=\(tomlString(codexProfile))",
            "-c", "\(profile).extends=\":workspace\"",
            "-c", "\(profile).network.enabled=false",
            "-c", "\(profile).filesystem={\(entries.joined(separator: ","))}",
        ]
    }

    /// `text` as a TOML basic string.
    static func tomlString(_ text: String) -> String {
        "\"" + text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    // MARK: The run's environment

    /// What every run gets from the environment it starts in: where programs and home are, who you are, the terminal,
    /// the language and the temp folder.
    public static let baseVariables = [
        "PATH", "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "TERM", "TERMINFO", "COLORTERM", "LANG", "LC_ALL",
        "LC_CTYPE", "LC_COLLATE", "LC_MESSAGES", "LC_MONETARY", "LC_NUMERIC", "LC_TIME",
    ]

    /// heed's own, which the run's hooks and `heed goal` reach heed with.
    public static let heedVariables = [
        HeedEnvironment.sessionID, HeedEnvironment.pane, HeedEnvironment.token, HeedEnvironment.socket,
        HeedEnvironment.binary, HeedControl.socketVariable, GoalCommandLine.goalVariable,
    ]

    /// The login and config variables of the agent itself: only the running agent's are kept.
    public static func agentVariables(_ agent: String) -> [String] {
        switch agent {
        case "claude":
            [
                "ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_CUSTOM_HEADERS",
                "CLAUDE_CODE_OAUTH_TOKEN", "CLAUDE_CONFIG_DIR", "CLAUDE_CODE_USE_BEDROCK", "CLAUDE_CODE_USE_VERTEX",
                "CLAUDE_CODE_USE_FOUNDRY",
            ]
        case "codex": ["OPENAI_API_KEY", "CODEX_API_KEY", "OPENAI_BASE_URL", "CODEX_HOME"]
        default: []
        }
    }

    /// A cloud the agent itself runs on: its variables, kept only when `variable` is set (claude on Bedrock, Vertex or
    /// Foundry).
    public struct AgentCloud: Hashable, Sendable {
        public var variable: String
        public var names: [String]
    }

    public static func agentClouds(_ agent: String) -> [AgentCloud] {
        guard agent == "claude" else { return [] }
        return [
            AgentCloud(variable: "CLAUDE_CODE_USE_BEDROCK", names: [
                "AWS_REGION", "AWS_DEFAULT_REGION", "AWS_PROFILE", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY",
                "AWS_SESSION_TOKEN", "AWS_BEARER_TOKEN_BEDROCK", "AWS_CONFIG_FILE", "AWS_SHARED_CREDENTIALS_FILE",
                "ANTHROPIC_BEDROCK_BASE_URL", "CLAUDE_CODE_SKIP_BEDROCK_AUTH",
            ]),
            AgentCloud(variable: "CLAUDE_CODE_USE_VERTEX", names: [
                "ANTHROPIC_VERTEX_PROJECT_ID", "CLOUD_ML_REGION", "GOOGLE_APPLICATION_CREDENTIALS",
                "GOOGLE_CLOUD_PROJECT", "CLOUDSDK_CONFIG", "ANTHROPIC_VERTEX_BASE_URL", "CLAUDE_CODE_SKIP_VERTEX_AUTH",
            ]),
            AgentCloud(variable: "CLAUDE_CODE_USE_FOUNDRY", names: [
                "ANTHROPIC_FOUNDRY_API_KEY", "ANTHROPIC_FOUNDRY_RESOURCE", "ANTHROPIC_FOUNDRY_BASE_URL",
                "AZURE_CLIENT_ID", "AZURE_TENANT_ID", "AZURE_CLIENT_SECRET", "CLAUDE_CODE_SKIP_FOUNDRY_AUTH",
            ]),
        ]
    }

    /// The names a run of `agent` keeps whatever else is set: the base, heed's and the agent's own, then `extra`
    /// (what heed itself sets on the agent's line, such as its telemetry). Only shell names.
    public static func keptNames(agent: String, extra: [String] = []) -> [String] {
        var seen: Set<String> = []
        return (baseVariables + heedVariables + agentVariables(agent) + extra.sorted())
            .filter { isName($0) && seen.insert($0).inserted }
    }

    static func isName(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, first == "_" || CharacterSet.letters.contains(first) else {
            return false
        }
        let allowed = CharacterSet(charactersIn: "_").union(.alphanumerics)
        return text.unicodeScalars.allSatisfy { $0.isASCII && allowed.contains($0) }
    }

    /// The variables a run of `agent` gets from `environment`: only the kept names, a cloud's only when its switch is
    /// set; then `gh` pointed at an empty folder and git kept from asking for a password. For a process heed starts
    /// itself with a set environment (a helper over ACP).
    public static func kept(_ environment: [String: String], agent: String, folder: String) -> [String: String] {
        var names = keptNames(agent: agent)
        for cloud in agentClouds(agent) where !(environment[cloud.variable] ?? "").isEmpty {
            names += cloud.names
        }
        var out = environment.filter { names.contains($0.key) }
        out["GH_CONFIG_DIR"] = RunFolder.ghConfig(folder)
        out["GIT_TERMINAL_PROMPT"] = "0"
        return out
    }

    /// The words that start a sandboxed run's command: `/bin/sh -c <script> sh`, the agent's own words after them.
    /// The script runs where the run does (in the pane's shell for a run in a tab, on the host for a host's), so it
    /// sees the environment the agent would have, your shell config's exports included, and hands the agent only
    /// what `keptNames` lists: it starts it under `/usr/bin/env -i`, which begins from an empty environment, with
    /// each kept variable that is set, `gh` pointed at an empty folder and git kept from asking for a password.
    /// POSIX sh, whatever the pane's shell is.
    public static func environment(agent: String, folder: String, keeping extra: [String] = []) -> [String] {
        ["/bin/sh", "-c", environmentScript(agent: agent, folder: folder, keeping: extra), "sh"]
    }

    static func environmentScript(agent: String, folder: String, keeping extra: [String] = []) -> String {
        // Each set variable goes before the agent's words, as `NAME=value` for env to set.
        func keep(_ names: [String]) -> String {
            #"for n in \#(names.joined(separator: " ")); do eval "[ -z \"\${$n+x}\" ] || "#
                + #"set -- \"$n=\${$n}\" \"\$@\""; done"#
        }
        let clouds = agentClouds(agent).map { cloud in
            "if [ -n \"${\(cloud.variable):-}\" ]; then \(keep(cloud.names.filter(isName))); fi"
        }
        let gh = RunFolder.ghConfig(folder)
        let ghWord = gh.hasPrefix("~/")
            ? "GH_CONFIG_DIR=\"$HOME\"/" + ShellQuote.quote(String(gh.dropFirst(2)))
            : ShellQuote.quote("GH_CONFIG_DIR=\(gh)")
        return ([keep(keptNames(agent: agent, extra: extra))] + clouds
            + ["exec /usr/bin/env -i \(ghWord) GIT_TERMINAL_PROMPT=0 \"$@\""])
            .joined(separator: "\n")
    }

    /// What a sandboxed run is told about where it is.
    public static func note(folder: String, network: Network) -> String {
        "Your shell runs in a sandbox: it writes only inside your working folder and \(folder), "
            + (network == .none ? "has no network, " : "reaches only package registries, ")
            + "and is not logged in to GitHub, ssh or any cloud. A step that needs a download or a login fails here: "
            + "say so in your report instead of retrying it."
    }

    /// What a run with no sandbox is, in a few words, for the line that says it started.
    public static func unsandboxedNote(agent: String) -> String { "\(agent) has no sandbox heed can start it in" }

    /// Drops a `--settings <file>` pair (heed's hooks, which a sandboxed run carries in its own settings instead).
    public static func withoutSettings(_ arguments: [String]) -> [String] {
        var out: [String] = []
        var skip = false
        for word in arguments {
            if skip {
                skip = false
                continue
            }
            if word == "--settings" {
                skip = true
                continue
            }
            out.append(word)
        }
        return out
    }
}
