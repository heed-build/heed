import Foundation

/// What an agent running inside Browse may do, decided by heed and never by what the agent says about itself. A pure
/// function of the permission request, the verb, the worktree and the repo: the app answers the agent's
/// `session/request_permission` with it, shows every refusal in the run's feed, and nothing else decides.
///
/// ## What this is, and is not
///
/// This is a best-effort filter over the text of the commands an agent asks to run and the paths it names. It is NOT
/// a sandbox. A command heed allows runs with the user's own file access and network; the policy only decides
/// whether to say yes to the text it was shown. Its posture, since the 2026-11-26 security review
/// (heed-plans/browse/audit/security.md), is default-deny: a command is allowed only when its name is on an explicit
/// per-verb list, its options are on that command's list, every word that names a file is resolved on disk (symlinks
/// followed, `..` never folded first) and has to end up inside the worktree, and the environment the agent starts in
/// holds no secrets (`BrowseRunEnvironment`).
///
/// What it does not defend, and what the OS sandbox (the next change) is for:
/// - A program it allows that does something else than its name says: `dotnet test`, `npm test`, `make` and `pytest`
///   run whatever the repo's code does, which is why only trusted authors' runs get them at all.
/// - Whatever the agent's own tools do without asking. Checked live against claude-agent-acp 0.108 in `default`
///   mode (2026-11): `echo`, `cat` and the Read tool on files in the working folder produced no
///   `session/request_permission` at all, so this policy never saw them (it saw `cat ~/.ssh/config`, `grep` of
///   `/etc/passwd` and a Read of `/etc/hosts`). Claude Code follows a link in the working folder on those reads, so
///   only the symlink scan at the start of a run (`PathResolver`), a stranger's head being checked out with
///   `core.symlinks=false`, and the locked session (`ACP.newSessionParams`) stand between a checkout and them.
///   The adapter also starts in `auto` mode, in which a model decides what to ask: heed sets `default` after
///   `session/new`, and a run is refused to start when that fails.
/// - A glob that expands, once the shell runs it, to files this text-level check cannot list: it is refused when it
///   has `..`, and its literal prefix is checked, nothing more.
/// - Anything an allowed command sends over the network: `git fetch`, `gh` and the build tools reach the network.
///   A command that downloads and runs (curl, wget, npx) is refused by name; a package install is not.
/// - A race: a path is resolved when the permission request is decided and used when the agent runs the command.
/// - A new way to say a thing: git, gh and the shells grow options. Anything not on a list is refused, so what
///   happens is a refusal the agent reports, never a silent pass.
///
/// ## Changelog
/// - 2026-11 hardening: default-deny command lists; a real word reader (`BrowseShell`) in place of ad-hoc splitting;
///   wrappers (`command`, `exec`, `time`, `timeout`, `stdbuf`, `nice`, `nohup`, `caffeinate`, `env`, `xargs`, shells,
///   interpreters) unwrapped with their real option tables or refused; no `$`, `~` or `{a,b}` in any word, no leading
///   environment assignment but a short list; per-subcommand option lists for git, gh api refused unless it is a bare
///   GET of this repo, repo and URL arguments refused, push only `origin HEAD:<branch>` to a branch that is not
///   protected and whose commits touch no file that runs code later; edits to workflows, hooks, package.json,
///   Makefile, agent settings and the like refused; paths resolved with `lstat` before they are judged; read tools'
///   raw input judged; more secret files; `allow_once` or nothing; Review runs builds, tests and readers only.
///
/// Three powers, by verb:
/// - Chat reads: files inside the worktree, and read-only git and gh. Nothing it can run changes a file, a branch or
///   GitHub.
/// - Review reads and runs: also builds and tests inside the worktree, but edits no file, commits nothing, pushes
///   nothing and writes nothing to GitHub. Its review is posted by you, from the panel.
/// - Fix and Implement write: edit files and run commands inside the worktree, commit, push a branch of this repo,
///   open and update pull requests, comment and label, all without asking, except for the files that run code.
///
/// What no verb may do: touch a path outside the worktree (a `..`, a `~`, an absolute path, a symlink out of it),
/// read or write secrets and credential files, act on another repo, force-push or delete a remote branch, push a
/// protected branch, change the repo's settings, download and run (curl | sh), or dump the environment. From an
/// author heed does not trust, only Chat is ever allowed.
public enum BrowsePolicy {
    public struct Context: Sendable {
        public var verb: BrowseVerb
        public var worktree: String
        public var repo: Repo
        public var defaultBranch: String
        /// The item's author counts as someone whose code heed runs (`PullTrust`).
        public var trusted: Bool
        /// The run may push: false on a pull request from a fork, whose branch is not this repo's.
        public var canPush: Bool
        /// The branch the run works on: the one `git push origin <branch>` may name.
        public var branch: String?
        /// Looks at what a push would publish. Nil: heed cannot, so a push is refused.
        public var pushGuard: (any BrowsePushGuard)?
        /// Where a path really points, for symlinks: `realpath(3)` for a path that need not exist.
        public var resolve: @Sendable (String) -> String

        public init(
            verb: BrowseVerb, worktree: String, repo: Repo, defaultBranch: String = "main", trusted: Bool = true,
            canPush: Bool = true, branch: String? = nil, pushGuard: (any BrowsePushGuard)? = nil,
            resolve: @escaping @Sendable (String) -> String = { PathResolver.realpath($0) }
        ) {
            self.verb = verb
            self.worktree = worktree
            self.repo = repo
            self.defaultBranch = defaultBranch
            self.trusted = trusted
            self.canPush = canPush
            self.branch = branch
            self.pushGuard = pushGuard
            self.resolve = resolve
        }

        var power: Power {
            guard trusted || verb == .chat else { return .none }
            switch verb {
            case .chat: return .read
            case .review: return .run
            case .fix, .implement: return .write
            }
        }
    }

    enum Power: Int, Comparable {
        case none, read, run, write
        static func < (lhs: Power, rhs: Power) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public struct Verdict: Equatable, Sendable {
        public var allowed: Bool
        /// Why not, in the words the feed shows.
        public var reason: String?
        static let yes = Verdict(allowed: true, reason: nil)
        static func no(_ reason: String) -> Verdict { Verdict(allowed: false, reason: reason) }
    }

    /// The option to send the agent, and the refusal for the feed when there is one.
    public struct Answer: Equatable, Sendable {
        public var optionID: String?
        public var refusal: String?
    }

    public static func answer(
        _ request: ACPPermissionRequest, verb: BrowseVerb, worktree: String, repo: Repo, defaultBranch: String = "main",
        trusted: Bool = true, canPush: Bool = true, branch: String? = nil, pushGuard: (any BrowsePushGuard)? = nil,
        resolve: @escaping @Sendable (String) -> String = { PathResolver.realpath($0) }
    ) -> Answer {
        answer(
            request,
            Context(
                verb: verb, worktree: worktree, repo: repo, defaultBranch: defaultBranch, trusted: trusted,
                canPush: canPush, branch: branch, pushGuard: pushGuard, resolve: resolve
            )
        )
    }

    public static func answer(_ request: ACPPermissionRequest, _ context: Context) -> Answer {
        let verdict = decide(request.toolCall, context)
        let reject = (request.option(.rejectOnce) ?? request.option(.rejectAlways))?.id
        if verdict.allowed {
            // Once, never always: each ask is judged again, and an "always" would stop the agent asking.
            guard let once = request.option(.allowOnce) else {
                return Answer(
                    optionID: reject,
                    refusal: "the agent offers no way to allow just this once, and heed never says always"
                )
            }
            return Answer(optionID: once.id, refusal: nil)
        }
        return Answer(optionID: reject, refusal: verdict.reason)
    }

    // MARK: Tool calls

    public static func decide(_ call: ACPToolCall, _ context: Context) -> Verdict {
        let power = context.power
        if power == .none {
            return .no("the author is not someone heed trusts: only Chat runs on their work, and it reads")
        }
        let kind = call.kind ?? .other
        switch kind {
        case .read, .search, .think:
            return reads(call, kind, context)
        case .fetch:
            return fetch(call.url)
        case .edit, .delete, .move:
            guard power == .write else {
                return .no("\(context.verb.title) does not change files")
            }
            guard !allPaths(call).isEmpty else { return .no("heed could not see which file it would change") }
            return paths(of: call, context, forWriting: true)
        case .execute:
            guard let line = call.command, !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                return .no("heed could not see which command it would run")
            }
            return command(line, context)
        case .switchMode:
            return .no("heed does not let an agent change its own mode")
        case .other:
            return .no("heed does not know this tool, so it does not run it")
        }
    }

    /// Hosts a fetch may reach: GitHub's, which `gh` reaches too. Anything else could carry the item's text out in
    /// its address.
    static let fetchHosts: Set<String> = [
        "github.com", "api.github.com", "raw.githubusercontent.com", "docs.github.com",
    ]

    static func fetch(_ url: String?) -> Verdict {
        guard let url, let host = URL(string: url)?.host?.lowercased() else {
            return .no("heed could not see which page it would fetch")
        }
        return fetchHosts.contains(host) ? .yes : .no("fetching \(host) is not allowed: only GitHub's pages are")
    }

    /// Every path a call names: its locations, the paths of its diffs, and the paths in its raw input.
    static func allPaths(_ call: ACPToolCall) -> [String] {
        var all = (call.paths ?? []) + (call.inputPaths ?? [])
        for case let .diff(path, _, _) in call.content ?? [] {
            all.append(path)
        }
        return all
    }

    static func paths(of call: ACPToolCall, _ context: Context, forWriting: Bool) -> Verdict {
        for path in allPaths(call) {
            let verdict = checkPath(path, in: context, cwd: context.worktree, forWriting: forWriting)
            if !verdict.allowed { return verdict }
        }
        return .yes
    }

    /// A read, a search, or a thought. A search tool (Glob, Grep) often names no `locations`: its raw `path` and
    /// `pattern` are judged, and a read that names nothing is not allowed, because heed cannot tell what it reads.
    static func reads(_ call: ACPToolCall, _ kind: ACPToolKind, _ context: Context) -> Verdict {
        let verdict = paths(of: call, context, forWriting: false)
        guard verdict.allowed else { return verdict }
        for pattern in call.patterns ?? [] {
            let check = checkGlob(pattern, in: context, cwd: context.worktree)
            if !check.allowed { return check }
        }
        guard kind != .think else { return .yes }
        let named = !allPaths(call).isEmpty
        if named || (kind == .search && !(call.patterns ?? []).isEmpty) { return .yes }
        return .no("heed could not see which file it would \(kind == .read ? "read" : "search")")
    }

    /// A glob or a search pattern that might name a place: no `..`, no `~` or variable, and when it is absolute, its
    /// literal front must be inside the worktree. A pattern with none of those searches where the agent is.
    static func checkGlob(_ pattern: String, in context: Context, cwd: String) -> Verdict {
        if pattern.hasPrefix("~") || pattern.contains("$") {
            return .no("\(pattern) leans on ~ or a variable, so heed cannot tell where it points")
        }
        if pattern.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
            return .no("\(pattern) climbs out with .. : heed cannot tell where it points")
        }
        guard pattern.hasPrefix("/") else { return .yes }
        let front = pattern.prefix { !"*?[{".contains($0) }
        let folder = front.lastIndex(of: "/").map { String(front[...$0]) } ?? "/"
        return checkPath(folder, in: context, cwd: cwd, forWriting: false)
    }

    // MARK: Paths

    /// A path joined to `cwd` with `.` and empty parts dropped and nothing else: `..` stays, because what it climbs
    /// out of is only known once the links in front of it are resolved.
    static func joined(_ path: String, cwd: String) -> String {
        let full = path.hasPrefix("/") ? path : cwd + "/" + path
        let parts = full.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return "/" + parts.joined(separator: "/")
    }

    /// `..` applied lexically: only for a place nothing can be resolved at, and for the secrets check.
    static func folded(_ path: String) -> String {
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return "/" + parts.joined(separator: "/")
    }

    /// macOS spells /var, /tmp and /etc as /private/…: both are the same place.
    static func canonical(_ path: String) -> String {
        for alias in ["/var", "/tmp", "/etc"]
            where path == "/private" + alias || path.hasPrefix("/private" + alias + "/")
        {
            return String(path.dropFirst("/private".count))
        }
        return path
    }

    static func inside(_ path: String, _ root: String) -> Bool {
        path == root || path.hasPrefix(root == "/" ? "/" : root + "/")
    }

    static func checkPath(_ path: String, in context: Context, cwd: String, forWriting: Bool) -> Verdict {
        guard !path.isEmpty else { return .yes }
        if path == "/dev/null" { return .yes }
        if path.hasPrefix("~") || path.contains("$") {
            return .no("\(path) leans on ~ or a variable, so heed cannot tell where it points")
        }
        let place = joined(path, cwd: cwd)
        // The root as written and as it is on disk (a worktree under /var is really under /private/var).
        let written = canonical(folded(context.worktree))
        let root = canonical(folded(context.resolve(written)))
        var real = canonical(context.resolve(place))
        // A resolver that leaves a `..` in is one that cannot look (a test's stand-in): fold it, never trust it.
        if real.split(separator: "/").contains("..") { real = canonical(folded(real)) }
        guard inside(real, root) || inside(real, written) else {
            let leads = inside(folded(place), written) || inside(folded(place), root)
            let here = "the worktree is ./ (\(context.worktree)): use paths inside it"
            return .no(
                leads
                    ? "\(path) leads outside this run's worktree; \(here)"
                    : "\(path) is outside this run's worktree; \(here)"
            )
        }
        if forWriting {
            for candidate in [real, folded(place)] {
                let inner = relative(candidate, to: [root, written])
                if inner.contains(".git") { return .no("\(path) is inside .git: use git, not an edit") }
                if let why = protectedWrite(inner) { return .no("\(path) \(why)") }
            }
        }
        if let secret = secretReason(real) ?? secretReason(folded(place)) { return .no("\(path) is \(secret)") }
        return .yes
    }

    /// The components of `path` below whichever root holds it, lowercased.
    static func relative(_ path: String, to roots: [String]) -> [String] {
        for root in roots where inside(path, root) {
            return path.dropFirst(root.count).split(separator: "/").map { $0.lowercased() }
        }
        return path.split(separator: "/").map { $0.lowercased() }
    }

    /// Files that run code, or decide what runs, later: CI, hooks, scripts a build calls, agent settings. An edit of
    /// one is how an injected agent gets its code run with the user's logins on the next push or the next build.
    static let protectedFolders: Set<String> = [".github", ".husky", ".githooks", ".claude"]
    static let protectedNames: Set<String> = [
        "package.json", "makefile", "gnumakefile", "justfile", ".mcp.json", ".worktreeinclude", "mise.toml",
        ".mise.toml", "mise.local.toml", "agents.md", "claude.md", ".envrc", ".tool-versions",
        ".pre-commit-config.yaml", "lefthook.yml", "lefthook.yaml", ".gitlab-ci.yml", "jenkinsfile",
    ]

    /// Why a file (components, lowercased, below the worktree) is not for an agent to change, when it is not.
    static func protectedWrite(_ components: [String]) -> String? {
        guard let name = components.last else { return nil }
        guard components.contains(where: protectedFolders.contains) || protectedNames.contains(name) else { return nil }
        return "is a file that runs code or sets up tools (CI, hooks, build scripts, agent settings): heed does not "
            + "let a run change it. Say in your final message what the change should be, and the user will make it by hand"
    }

    /// Why a path is not for an agent, when it is not: credentials, keys, environment files, shell history.
    static func secretReason(_ path: String) -> String? {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let folders: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".azure", ".docker", ".password-store"]
        if parts.contains(where: folders.contains) { return "a credentials folder" }
        if let gh = parts.firstIndex(of: "gh"), gh > 0, parts[gh - 1] == ".config" { return "gh's login" }
        guard let name = parts.last else { return nil }
        let files: Set<String> = [
            ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", "credentials", "credentials.json",
            "hosts.yml", "secrets.json", "secrets.yml", "secrets.yaml", "service-account.json", "token",
            ".credentials.json", ".envrc", ".dev.vars",
        ]
        if files.contains(name) { return "a credentials file" }
        if name == ".env" || (name.hasPrefix(".env.") && ![".example", ".sample", ".template", ".dist"]
            .contains(where: { name.hasSuffix($0) }))
        {
            return "an environment file"
        }
        if name.hasPrefix(".dev.vars") { return "an environment file" }
        let histories: Set<String> = [
            ".zsh_history", ".bash_history", ".python_history", ".node_repl_history", ".psql_history",
            ".mysql_history", ".sqlite_history", ".lesshst", "fish_history", ".fish_history", ".sh_history",
            ".zhistory",
        ]
        if histories.contains(name) { return "a shell history" }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa")
            || name.hasPrefix("id_dsa")
        {
            return "an ssh key"
        }
        for suffix in [".tfvars", ".tfstate", ".tfstate.backup"] where name.hasSuffix(suffix) {
            return "a terraform variables or state file"
        }
        for suffix in [".pem", ".p12", ".pfx", ".key", ".keychain", ".keychain-db", ".kdbx"]
            where name.hasSuffix(suffix)
        {
            return "a key file"
        }
        return nil
    }

    // MARK: Branches

    /// Branches a run never pushes to: the repo's default and the names that publish or release.
    static func protectedBranch(_ name: String, _ context: Context) -> Bool {
        var branch = name.lowercased()
        if branch.hasPrefix("refs/heads/") { branch = String(branch.dropFirst("refs/heads/".count)) }
        let fixed: Set<String> = [
            context.defaultBranch.lowercased(), "main", "master", "trunk", "production", "prod", "gh-pages",
        ]
        return fixed.contains(branch) || branch.hasPrefix("release/") || branch.hasPrefix("releases/")
            || branch.hasPrefix("release-")
    }

    static func isLocalDefault(_ word: String, _ context: Context) -> Bool { protectedBranch(word, context) }
}
