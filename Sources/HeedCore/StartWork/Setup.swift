import Foundation

/// `setup = [...]` per repo (`[repos."org/name"]`) and per org (`[orgs.<name>]`): the commands a new worktree runs
/// before its agent starts. Unset means heed proposes what it detects, and runs nothing until you approve; `[]` means
/// none, and heed stops proposing.
public struct SetupRules: Hashable, Sendable, Codable {
    public var orgs: [String: [String]] = [:]
    public var repos: [String: [String]] = [:]

    public init(orgs: [String: [String]] = [:], repos: [String: [String]] = [:]) {
        self.orgs = orgs
        self.repos = repos
    }

    /// The commands a repo's new worktrees run, the repo's own before its org's; nil when neither sets any.
    public func commands(for repo: Repo) -> [String]? {
        repos[repo.slug] ?? orgs[repo.org]
    }
}

/// What heed would set a repo's worktrees up with, from the files in its main checkout.
public struct SetupProposal: Hashable, Sendable {
    /// The commands, in order.
    public var commands: [String]
    /// What each was detected from (`mise.toml`, `pnpm-lock.yaml`), one per command.
    public var reasons: [String]

    public init(commands: [String], reasons: [String]) {
        self.commands = commands
        self.reasons = reasons
    }

    public var isEmpty: Bool { commands.isEmpty }

    /// `mise install (mise.toml)`, for one line in a dialog.
    public var lines: [String] { zip(commands, reasons).map { "\($0) (\($1))" } }
}

/// Proposes setup commands from a checkout's files. mise first: a repo that uses it gets `mise install` alone (its
/// tools, and the `postinstall` hooks that install the rest). Otherwise a lockfile picks its package manager's install;
/// one install at the root covers a workspace. Git hooks need nothing of their own: they live in the shared git dir,
/// and husky's per-worktree setup runs from the package install's `prepare`.
public enum SetupDetection {
    /// mise's project config files, relative to the checkout's root.
    public static let miseFiles = [
        "mise.toml", ".mise.toml", "mise/config.toml", ".mise/config.toml", ".config/mise.toml",
        ".config/mise/config.toml",
    ]

    /// Lockfile → install, in the order they are proposed. Cargo and Go fetch on build, so they need nothing.
    static let lockfiles: [(file: String, command: String)] = [
        ("pnpm-lock.yaml", "pnpm install"),
        ("bun.lock", "bun install"),
        ("bun.lockb", "bun install"),
        ("package-lock.json", "npm ci"),
        ("yarn.lock", "yarn install"),
        ("uv.lock", "uv sync"),
        ("poetry.lock", "poetry install"),
    ]

    /// The proposal for a checkout holding `files` (paths relative to its root: the top level, and `.config/…`,
    /// `mise/…`, `.mise/…`).
    public static func propose(files: [String]) -> SetupProposal {
        let present = Set(files)
        if let mise = miseFiles.first(where: present.contains) {
            return SetupProposal(commands: ["mise install"], reasons: [mise])
        }
        var commands: [String] = []
        var reasons: [String] = []
        for (file, command) in lockfiles where present.contains(file) && !commands.contains(command) {
            commands.append(command)
            reasons.append(file)
        }
        if let solution = files.sorted().first(where: {
            !$0.contains("/") && ($0.hasSuffix(".sln") || $0.hasSuffix(".slnx") || $0.hasSuffix(".csproj"))
        }) {
            commands.append("dotnet restore")
            reasons.append(solution)
        }
        return SetupProposal(commands: commands, reasons: reasons)
    }

    /// The files `propose` looks at, listed in the checkout at `path` (here or on a host).
    public static func files(at path: String, on location: Location = .local) async -> [String] {
        let script = #"cd "$1" 2>/dev/null || exit 0; ls -A; for d in .config mise .mise; do "#
            + #"[ -d "$d" ] && ls -A "$d" | sed "s|^|$d/|"; done; [ -d .config/mise ] && "#
            + #"ls -A .config/mise | sed "s|^|.config/mise/|"; exit 0"#
        let output = await (try? ProcessRunner.output(
            on: location, "sh", ["-c", script, "sh", path], timeout: .seconds(10)
        )) ?? ""
        return output.split(separator: "\n").map(String.init)
    }

    /// The proposal for the checkout at `path`.
    public static func detect(at path: String, on location: Location = .local) async -> SetupProposal {
        await propose(files: files(at: path, on: location))
    }
}

/// Setting a new worktree up: its setup commands run in the pane before the agent, and files `.worktreeinclude` names
/// are copied in from the main checkout.
public enum WorktreeSetup {
    /// The line a new pane types: the setup commands, then `command` (the agent) only when every one of them passed.
    /// The setup runs under `sh -c` as a step of its own, so the line works in any shell that knows `&&` (zsh, bash,
    /// fish) and the agent still runs in your shell. A failure says which command failed and how to start the agent by
    /// hand, and leaves the pane at its prompt; with `report`, it also tells heed (`heed task-exit`), which ends a
    /// background run as failed. No setup: `command` unchanged.
    public static func paneCommand(
        setup: [String],
        then command: ShellCommand?,
        report: Bool = false
    ) -> ShellCommand? {
        let steps = setup.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !steps.isEmpty else { return command }
        return ShellCommand([.setup(SetupScript(steps: steps, report: report))] + (command?.steps ?? []))
    }

    /// The file a package manager's install needs in the worktree's root, so a repo without one (an org-wide `npm ci`
    /// in a repo that has no `package.json`) skips the step instead of failing. Nil for any other command.
    static func manifest(for step: String) -> String? {
        let words = step.split(separator: " ")
        guard words.count >= 2 else { return nil }
        switch (words[0], words[1]) {
        case ("npm", "ci"), ("npm", "install"), ("pnpm", "install"), ("yarn", "install"), ("bun", "install"):
            return "package.json"
        case ("uv", "sync"), ("poetry", "install"):
            return "pyproject.toml"
        default:
            return nil
        }
    }

    /// The reason a background run's setup failed, for its outcome.
    public static func failureReason(_ setup: [String]) -> String {
        "setup failed (\(setup.joined(separator: " && ")))"
    }
}

/// A worktree's setup commands as the sh script a pane runs before its agent.
public struct SetupScript: Hashable, Sendable, Codable {
    public var steps: [String]
    /// Tell heed when a step fails (`heed task-exit`), for background runs.
    public var report: Bool

    public init(steps: [String], report: Bool = false) {
        self.steps = steps
        self.report = report
    }

    /// The script; `next` is the command that follows it on the line, as typed, for the failure's hint.
    public func script(next: String?) -> String {
        let hint = next.map { "start the agent with:\n  \($0)" } ?? "open a new shell."
        return steps.map { step in
            let failed = "heed: setup failed (\(step)); fix it, then \(hint)"
            let tell = report ? #" "${HEED_BIN:-true}" task-exit "$c";"# : ""
            let run = "printf '\\033[2mheed: setup: %s\\033[0m\\n' \(ShellQuote.quote(step)); "
                + "{ \(step); } || { c=$?; printf '\\n%s\\n' \(ShellQuote.quote(failed));\(tell) exit \"$c\"; }"
            guard let manifest = WorktreeSetup.manifest(for: step) else { return run }
            let skipped = "heed: setup: skipped \(step) (no \(manifest))"
            return "if [ -f \(manifest) ]; then \(run); "
                + "else printf '\\033[2m%s\\033[0m\\n' \(ShellQuote.quote(skipped)); fi"
        }.joined(separator: "; ")
    }
}

/// `.worktreeinclude` (at the main checkout's root, in .gitignore syntax): files it matches that git ignores are
/// copied into each new worktree, so `.env` and friends come along. Tracked files never are: the worktree has them.
/// The same convention other tools that make worktrees follow.
public enum WorktreeInclude {
    public static let file = ".worktreeinclude"

    /// Copies what `.worktreeinclude` names from `main` into `worktree`, here or on a host, leaving files the worktree
    /// already has alone. Returns the paths copied, relative to the root; none when there is no `.worktreeinclude`.
    @discardableResult
    public static func copy(from main: String, to worktree: String, on location: Location = .local) async -> [String] {
        // Untracked files the include file matches, kept only when the repo's own ignore rules ignore them too.
        let script = """
        cd "$1" 2>/dev/null && [ -f \(file) ] || exit 0
        git -c core.quotePath=false ls-files --others --ignored --exclude-from=\(file) \
        | git -c core.quotePath=false check-ignore --stdin \
        | while IFS= read -r f; do
          [ -e "$2/$f" ] && continue
          mkdir -p "$2/$(dirname "$f")" && cp -p "$f" "$2/$f" && printf '%s\\n' "$f"
        done
        exit 0
        """
        let output = await (try? ProcessRunner.output(
            on: location, "sh", ["-c", script, "sh", main, worktree], timeout: .seconds(60)
        )) ?? ""
        return output.split(separator: "\n").map(String.init)
    }
}
