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
/// - codex: `--sandbox workspace-write` with `sandbox_workspace_write.network_access=false`, and the run's folder
///   writable (`--add-dir`).
/// - others: no sandbox heed can ask for; heed says so on the run and does not start them on its own for someone
///   else's PR.
///
/// What a sandboxed run cannot do: reach the network (a review not at all; a walk only package registries; codex
/// never),
/// write outside its worktree and its run folder (so caches in your home and the repo's shared git folder are
/// read-only), use your GitHub, ssh or cloud logins, or run anything outside the sandbox. Tests that download
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

    /// codex's: writes in the worktree and the run's folder, no network.
    public static func codex(folder: String) -> [String] {
        ["--sandbox", "workspace-write", "-c", "sandbox_workspace_write.network_access=false", "--add-dir", folder]
    }

    // MARK: The run's environment

    /// Variables that carry logins, always unset.
    public static let credentialVariables = [
        "GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "GH_HOST", "SSH_AUTH_SOCK",
        "SSH_AGENT_PID", "AWS_ACCESS_KEY_ID", "AWS_SECRET_ACCESS_KEY", "AWS_SESSION_TOKEN", "AWS_PROFILE",
        "GOOGLE_APPLICATION_CREDENTIALS", "GOOGLE_API_KEY", "CLOUDSDK_AUTH_ACCESS_TOKEN", "AZURE_CLIENT_SECRET",
        "AZURE_CLIENT_ID", "AZURE_TENANT_ID", "NPM_TOKEN", "NODE_AUTH_TOKEN", "DOCKER_AUTH_CONFIG",
        "HOMEBREW_GITHUB_API_TOKEN",
    ]

    /// Prefixes of cloud and service logins.
    static let credentialPrefixes = [
        "AWS_", "GOOGLE_", "GCLOUD_", "CLOUDSDK_", "AZURE_", "ARM_", "DIGITALOCEAN_", "HEROKU_", "VAULT_", "OP_",
    ]

    /// Suffixes of secrets, outside the agents' own (`ANTHROPIC_API_KEY`, `CLAUDE_CODE_OAUTH_TOKEN`).
    static let secretSuffixes = ["_TOKEN", "_SECRET", "_PASSWORD", "_SECRET_ACCESS_KEY", "_API_KEY"]

    static let agentPrefixes = ["ANTHROPIC_", "CLAUDE_", "OPENAI_", "CODEX_", "GEMINI_", "OPENROUTER_", "HEED_"]

    /// The variables to unset: the fixed ones, and those of `present` (the names in heed's environment) that look
    /// like a login. A cloud the agent itself runs on stays (Bedrock, Vertex, Foundry).
    public static func unset(present: [String]) -> [String] {
        let keep: [String] = (present.contains("CLAUDE_CODE_USE_BEDROCK") ? ["AWS_"] : [])
            + (present.contains("CLAUDE_CODE_USE_VERTEX") ? ["GOOGLE_", "GCLOUD_", "CLOUDSDK_"] : [])
            + (present.contains("CLAUDE_CODE_USE_FOUNDRY") ? ["AZURE_"] : [])
        func kept(_ name: String) -> Bool { keep.contains { name.hasPrefix($0) } }
        let found = present.filter { name in
            guard !agentPrefixes.contains(where: { name.hasPrefix($0) }) else { return false }
            return credentialPrefixes.contains { name.hasPrefix($0) } || secretSuffixes.contains { name.hasSuffix($0) }
        }
        var seen: Set<String> = []
        return (credentialVariables + found.sorted()).filter { !kept($0) && seen.insert($0).inserted }
    }

    /// The words that start a sandboxed run's command: `/usr/bin/env`, each login unset, `gh` pointed at an empty
    /// folder and git kept from asking for a password. The agent's own words follow.
    public static func environment(present: [String], folder: String) -> [String] {
        ["/usr/bin/env"] + unset(present: present).flatMap { ["-u", $0] }
            + ["GH_CONFIG_DIR=\(RunFolder.ghConfig(folder))", "GIT_TERMINAL_PROMPT=0"]
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
