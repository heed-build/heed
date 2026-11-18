import Foundation

/// What an agent running inside Browse may do, decided by heed and never by what the agent says about itself. A pure
/// function of the permission request, the verb, the worktree and the repo: the app answers the agent's
/// `session/request_permission` with it, shows every refusal in the run's feed, and nothing else decides.
///
/// Three powers, by verb:
/// - Chat reads: files inside the worktree, and read-only git and gh. Nothing it can run changes a file, a branch or
///   GitHub.
/// - Review reads and runs: also builds and tests inside the worktree, but edits no file, commits nothing, pushes
///   nothing and writes nothing to GitHub. Its review is posted by you, from the panel.
/// - Fix and Implement write: edit files and run commands inside the worktree, commit, push a branch of this repo,
///   open and update pull requests, comment and label, all without asking.
///
/// What no verb may do: touch a path outside the worktree (a `..`, a `~`, an absolute path, a symlink out of it),
/// read or write secrets and credential files, act on another repo, force-push or delete a remote branch, push the
/// default branch, change the repo's settings, download and run (curl | sh), or dump the environment. From an author
/// heed does not trust, only Chat is ever allowed. This is a guard on the commands an agent asks to run, not a
/// sandbox: a test suite the agent runs executes whatever the repo's code does, which is why only trusted authors'
/// work runs at all.
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
        /// Where a path really points, for symlinks (the app passes `resolvingSymlinksInPath`).
        public var resolve: @Sendable (String) -> String

        public init(
            verb: BrowseVerb, worktree: String, repo: Repo, defaultBranch: String = "main", trusted: Bool = true,
            canPush: Bool = true, resolve: @escaping @Sendable (String) -> String = { $0 }
        ) {
            self.verb = verb
            self.worktree = worktree
            self.repo = repo
            self.defaultBranch = defaultBranch
            self.trusted = trusted
            self.canPush = canPush
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
        trusted: Bool = true, canPush: Bool = true, resolve: @escaping @Sendable (String) -> String = { $0 }
    ) -> Answer {
        answer(
            request,
            Context(
                verb: verb, worktree: worktree, repo: repo, defaultBranch: defaultBranch, trusted: trusted,
                canPush: canPush, resolve: resolve
            )
        )
    }

    public static func answer(_ request: ACPPermissionRequest, _ context: Context) -> Answer {
        let verdict = decide(request.toolCall, context)
        if verdict.allowed {
            return Answer(optionID: (request.option(.allowOnce) ?? request.option(.allowAlways))?.id, refusal: nil)
        }
        return Answer(
            optionID: (request.option(.rejectOnce) ?? request.option(.rejectAlways))?.id, refusal: verdict.reason
        )
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
            return paths(of: call, context, forWriting: false)
        case .fetch:
            return fetch(call.url)
        case .edit, .delete, .move:
            guard power == .write else {
                return .no("\(context.verb.title) does not change files")
            }
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

    static func paths(of call: ACPToolCall, _ context: Context, forWriting: Bool) -> Verdict {
        var all = call.paths ?? []
        for case let .diff(path, _, _) in call.content ?? [] {
            all.append(path)
        }
        for path in all {
            let verdict = checkPath(path, in: context, cwd: context.worktree, forWriting: forWriting)
            if !verdict.allowed { return verdict }
        }
        return .yes
    }

    // MARK: Paths

    /// A path as a list of components with `.` and `..` folded away, or nil when it names a home (`~`) or leans on a
    /// variable: heed cannot tell where those point.
    static func normalized(_ path: String, cwd: String) -> String? {
        if path.hasPrefix("~") || path.contains("$") { return nil }
        let joined = path.hasPrefix("/") ? path : cwd + "/" + path
        var parts: [Substring] = []
        for part in joined.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." {
                if !parts.isEmpty { parts.removeLast() }
                continue
            }
            parts.append(part)
        }
        return canonical("/" + parts.joined(separator: "/"))
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
        let root = canonical(normalized(context.worktree, cwd: "/") ?? context.worktree)
        guard let place = normalized(path, cwd: cwd) else {
            return .no("\(path) leans on ~ or a variable, so heed cannot tell where it points")
        }
        guard inside(place, root) else {
            return .no("\(path) is outside this run's worktree")
        }
        // A symlink that leads out of it.
        let real = canonical(context.resolve(place))
        guard inside(real, root) || inside(real, canonical(context.resolve(root))) else {
            return .no("\(path) leads outside this run's worktree")
        }
        if let secret = secretReason(place) { return .no("\(path) is \(secret)") }
        if forWriting, place.split(separator: "/").contains(".git") {
            return .no("\(path) is inside .git: use git, not an edit")
        }
        return .yes
    }

    /// Why a path is not for an agent, when it is not: credentials, keys, environment files.
    static func secretReason(_ path: String) -> String? {
        let parts = path.split(separator: "/").map { $0.lowercased() }
        let folders: Set<String> = [".ssh", ".aws", ".gnupg", ".kube", ".azure", ".docker", ".password-store"]
        if parts.contains(where: folders.contains) { return "a credentials folder" }
        if let gh = parts.firstIndex(of: "gh"), gh > 0, parts[gh - 1] == ".config" { return "gh's login" }
        guard let name = parts.last else { return nil }
        let files: Set<String> = [
            ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".pgpass", "credentials", "credentials.json",
            "hosts.yml", "secrets.json", "secrets.yml", "secrets.yaml", "service-account.json", "token",
        ]
        if files.contains(name) { return "a credentials file" }
        if name == ".env" || (name.hasPrefix(".env.") && ![".example", ".sample", ".template", ".dist"]
            .contains(where: { name.hasSuffix($0) }))
        {
            return "an environment file"
        }
        if name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519") || name.hasPrefix("id_ecdsa")
            || name.hasPrefix("id_dsa")
        {
            return "an ssh key"
        }
        for suffix in [".pem", ".p12", ".pfx", ".key", ".keychain", ".keychain-db", ".kdbx"]
            where name.hasSuffix(suffix)
        {
            return "a key file"
        }
        return nil
    }

    // MARK: Commands

    static let maxDepth = 3

    static func command(_ text: String, _ context: Context, depth: Int = 0, cwd: String? = nil) -> Verdict {
        guard depth < maxDepth else { return .no("the command nests too deep for heed to check") }
        var cwd = cwd ?? context.worktree
        let parsed = Shell.parse(text)
        if parsed.substitution { return .no("a command substitution hides what would run: write the command out") }
        if parsed.heredoc { return .no("a here-document: write the file with an edit instead") }
        if parsed.shellPipe { return .no("piping into a shell is never allowed") }
        for segment in parsed.segments {
            var words = segment.words
            while let first = words.first, Shell.isAssignment(first) {
                let value = String(first[first.index(after: first.firstIndex(of: "=")!)...])
                if looksLikePath(value) {
                    let check = checkPath(value, in: context, cwd: cwd, forWriting: false)
                    if !check.allowed { return check }
                }
                words.removeFirst()
            }
            for target in segment.redirects {
                let check = checkPath(target, in: context, cwd: cwd, forWriting: true)
                if !check.allowed { return check }
                if context.power < .write, target != "/dev/null" {
                    return .no("\(context.verb.title) does not write files")
                }
            }
            guard !words.isEmpty else { continue }
            let verdict = single(words, context, cwd: &cwd, depth: depth)
            if !verdict.allowed { return verdict }
        }
        return .yes
    }

    private static let wrappers: Set<String> = [
        "time",
        "nohup",
        "nice",
        "command",
        "builtin",
        "exec",
        "stdbuf",
        "caffeinate",
    ]
    private static let neverRun: [String: String] = [
        "sudo": "sudo", "su": "su", "doas": "doas", "ssh": "ssh", "scp": "scp", "sftp": "sftp", "rsync": "rsync",
        "nc": "nc", "ncat": "ncat", "netcat": "netcat", "telnet": "telnet", "osascript": "osascript",
        "security": "the keychain's security tool", "launchctl": "launchctl", "open": "open", "defaults": "defaults",
        "curl": "curl: downloads", "wget": "wget: downloads", "eval": "eval", "printenv": "printing the environment",
        "tccutil": "tccutil", "crontab": "crontab", "pbcopy": "the clipboard", "pbpaste": "the clipboard",
        "dscl": "dscl", "chown": "chown", "diskutil": "diskutil", "hdiutil": "hdiutil", "mkfs": "mkfs", "dd": "dd",
        "kill": "kill", "killall": "killall", "pkill": "pkill", "shutdown": "shutdown", "reboot": "reboot",
        "networksetup": "networksetup", "scutil": "scutil", "pmset": "pmset", "systemsetup": "systemsetup",
    ]
    private static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "ag", "find", "diff", "cmp", "sort", "uniq",
        "tr", "cut", "jq", "stat", "file", "pwd", "echo", "printf", "which", "type", "tree", "basename", "dirname",
        "realpath", "readlink", "du", "df", "date", "true", "false", "test", "[", "less", "more", "column", "nl", "tac",
        "rev", "xxd", "od", "md5", "shasum", "sha256sum", "sed", "awk", "uname", "whoami", "id", "hostname", "sleep",
        "expr", "seq",
    ]

    private static func base(_ word: String) -> String { (word as NSString).lastPathComponent }

    private static func single(_ input: [String], _ context: Context, cwd: inout String, depth: Int) -> Verdict {
        var words = input
        unwrap: while let first = words.first {
            let name = base(first)
            if wrappers.contains(name) {
                words.removeFirst()
                if name ==
                    "nice"
                { while let flag = words.first,
                        flag
                        .hasPrefix("-")
                    {
                        words.removeFirst(); if words.first.flatMap(Int.init) != nil { words.removeFirst() }
                    }
                }
            } else if name == "env" {
                words.removeFirst()
                while let next = words.first, Shell.isAssignment(next) || next.hasPrefix("-") {
                    if next.hasPrefix("-") { return .no("env \(next) is not allowed") }
                    words.removeFirst()
                }
                if words.isEmpty { return .no("printing the environment would show secrets") }
            } else if name == "timeout" {
                words.removeFirst()
                while let flag = words.first, flag.hasPrefix("-") {
                    words.removeFirst()
                }
                if !words.isEmpty { words.removeFirst() }
            } else {
                break unwrap
            }
        }
        guard let rawName = words.first else { return .yes }
        let name = base(rawName)
        if rawName.contains("/") {
            let check = checkPath(rawName, in: context, cwd: cwd, forWriting: false)
            if !check.allowed, !systemBinary(rawName) { return check }
        }
        if let why = neverRun[name] { return .no("\(why) is never allowed in a Browse run") }
        if ["export", "set", "declare", "typeset"].contains(name),
           words.count == 1 || words.contains("-p") || words.contains("-x")
        {
            return .no("printing the environment would show secrets")
        }
        switch name {
        case "git": return git(words, context, cwd: cwd)
        case "gh": return gh(words, context, cwd: cwd)
        case "cd":
            guard words.count >= 2 else { return .no("cd with no folder goes to your home") }
            let check = checkPath(words[1], in: context, cwd: cwd, forWriting: false)
            if check.allowed, let place = normalized(words[1], cwd: cwd) { cwd = place }
            return check
        case "bash", "sh", "zsh", "dash", "ksh":
            guard context.power >= .run
            else { return .no("\(context.verb.title) runs no scripts, only read-only commands") }
            if let flag = words
                .firstIndex(where: { $0 == "-c" || ($0.hasPrefix("-") && !$0.hasPrefix("--") && $0.hasSuffix("c")) }),
                words.indices.contains(flag + 1)
            {
                return command(words[flag + 1], context, depth: depth + 1, cwd: cwd)
            }
            return pathWords(Array(words.dropFirst()), name: name, context, cwd: cwd)
        case "xargs":
            var rest = Array(words.dropFirst())
            while let flag = rest.first, flag.hasPrefix("-") {
                rest.removeFirst()
            }
            guard !rest.isEmpty else { return .yes }
            return single(rest, context, cwd: &cwd, depth: depth)
        default: break
        }
        let readOnly = readers.contains(name) && !writesFiles(name, words)
        if context.power == .read, !readOnly {
            return .no("\(context.verb.title) only runs read-only commands: \(name) is not one")
        }
        return pathWords(Array(words.dropFirst()), name: name, context, cwd: cwd)
    }

    /// Tools that live outside the worktree and that a command may name by path.
    private static func systemBinary(_ path: String) -> Bool {
        ["/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/", "/sbin/", "/usr/libexec/"]
            .contains { path.hasPrefix($0) }
    }

    private static func writesFiles(_ name: String, _ words: [String]) -> Bool {
        switch name {
        case "sed": words
            .contains { $0 == "--in-place" || $0.hasPrefix("--in-place") || ($0.hasPrefix("-i") && !$0.hasPrefix("--"))
            }
        case "find": words
            .contains { ["-exec", "-execdir", "-delete", "-ok", "-fprint", "-fprintf", "-fls"].contains($0) }
        case "awk": words.contains { $0.contains("system(") || $0.contains("print >") || $0.contains("printf >") }
        default: false
        }
    }

    /// Every word that is a path: inside the worktree, no secrets.
    static func pathWords(_ words: [String], name: String, _ context: Context, cwd: String) -> Verdict {
        for word in words {
            var candidates = [word]
            if word.hasPrefix("-") {
                guard let equals = word.firstIndex(of: "=") else { continue }
                candidates = [String(word[word.index(after: equals)...])]
            }
            if word.hasPrefix("$"), !["echo", "printf", "test", "["].contains(name) {
                return .no("\(word) hides which path it names")
            }
            let pieces = candidates.flatMap { $0.contains(" ") ? $0.split(separator: " ").map(String.init) : [$0] }
            for piece in pieces {
                if looksLikePath(piece) {
                    let verdict = checkPath(piece, in: context, cwd: cwd, forWriting: false)
                    if !verdict.allowed { return verdict }
                } else if let secret = secretReason("/" + piece) {
                    return .no("\(piece) is \(secret)")
                }
            }
        }
        return .yes
    }

    static func looksLikePath(_ word: String) -> Bool {
        if word.contains("://") { return false }
        return word.hasPrefix("~") || word.contains("/") || word == ".."
    }

    // MARK: git

    static let gitReads: Set<String> = [
        "status", "log", "diff", "show", "blame", "grep", "ls-files", "ls-tree", "rev-parse", "rev-list", "describe",
        "merge-base", "cat-file", "shortlog", "show-ref", "for-each-ref", "name-rev", "whatchanged", "reflog", "help",
        "version", "fetch", "count-objects", "check-ignore", "diff-tree", "diff-index", "range-diff", "cherry",
        "show-branch", "verify-commit", "ls-remote", "var", "check-attr",
    ]
    static let gitLocalWrites: Set<String> = [
        "add", "rm", "mv", "commit", "restore", "reset", "merge", "rebase", "cherry-pick", "revert", "apply", "am",
        "stash", "tag", "clean", "checkout", "switch", "pull", "branch", "bisect", "notes", "format-patch",
        "sparse-checkout", "update-index", "gc", "prune", "maintenance",
    ]
    private static let gitRefused: [String: String] = [
        "clone": "cloning another repo", "init": "making another repository",
        "submodule": "submodules reach other repos",
        "worktree": "worktrees are heed's", "filter-branch": "rewriting history", "filter-repo": "rewriting history",
        "update-ref": "moving refs by hand", "symbolic-ref": "moving refs by hand", "credential": "git's credentials",
        "daemon": "git daemon", "send-email": "sending email", "replace": "replacing objects", "hook": "hooks",
        "bundle": "bundles", "svn": "svn", "lfs": "lfs", "archive": "archives written outside the worktree",
        "write-tree": "plumbing", "commit-tree": "plumbing", "fast-import": "importing",
    ]

    static func git(_ words: [String], _ context: Context, cwd: String) -> Verdict {
        var index = 1
        var cwd = cwd
        while index < words.count, words[index].hasPrefix("-") {
            let option = words[index]
            if option == "-C" {
                guard index + 1 < words.count else { return .no("git -C without a folder") }
                let check = checkPath(words[index + 1], in: context, cwd: cwd, forWriting: false)
                guard check.allowed, let place = normalized(words[index + 1], cwd: cwd) else { return check }
                cwd = place
                index += 2
            } else if option == "-c" || option.hasPrefix("--config-env") {
                return .no("git -c can run commands through config: use git's own options")
            } else if option.hasPrefix("--git-dir") || option.hasPrefix("--work-tree") || option
                .hasPrefix("--exec-path")
                || option.hasPrefix("--namespace") || option.hasPrefix("--super-prefix")
            {
                return .no("\(option) points git elsewhere")
            } else {
                index += 1
            }
        }
        guard index < words.count else { return .yes }
        let sub = words[index]
        let args = Array(words.dropFirst(index + 1))
        if let why = gitRefused[sub] { return .no("git \(sub): \(why) is not allowed") }
        if args.contains("--no-index") { return .no("git --no-index reads files outside the repo") }
        if args.contains("--no-verify") { return .no("skipping hooks (--no-verify) is not allowed") }
        for (position, arg) in args.enumerated() {
            var target: String?
            if ["-o", "--output", "--output-directory"].contains(arg),
               position + 1 < args.count { target = args[position + 1] }
            if arg.hasPrefix("--output="),
               let equals = arg.firstIndex(of: "=") { target = String(arg[arg.index(after: equals)...]) }
            if let target {
                let check = checkPath(target, in: context, cwd: cwd, forWriting: true)
                if !check.allowed { return check }
            }
        }
        switch sub {
        case "push": return push(args, context)
        case "remote":
            if args.isEmpty || args == ["-v"] || ["show", "get-url"].contains(args.first ?? "") { return .yes }
            return .no("changing remotes is not allowed")
        case "config":
            if ["--get", "--get-all", "--list", "-l", "--get-regexp"].contains(args.first ?? "") { return .yes }
            return .no("changing git's config is not allowed")
        default: break
        }
        if gitReads.contains(sub) {
            if sub == "fetch", args.contains(where: { $0.hasPrefix("--upload-pack") || $0.hasPrefix("--exec") }) {
                return .no("git fetch with a custom command is not allowed")
            }
            if sub == "ls-remote" || sub == "fetch", let other = otherRemote(args) { return .no(other) }
            return .yes
        }
        if gitLocalWrites.contains(sub) {
            if listsOnly(sub, args) { return .yes }
            guard context.power == .write else {
                return .no("\(context.verb.title) changes no commits or branches: git \(sub) is a change")
            }
            if sub == "pull", let other = otherRemote(args) { return .no(other) }
            if ["checkout", "switch", "branch"].contains(sub),
               args.contains(where: { !$0.hasPrefix("-") && isLocalDefault($0, context) })
            {
                return .no(
                    "work stays off \(context.defaultBranch): git \(sub) \(context.defaultBranch) is not allowed"
                )
            }
            return .yes
        }
        return .no("git \(sub) is not one heed knows to allow")
    }

    /// `git branch` and `git tag` that only list, `git stash list`: reads.
    private static func listsOnly(_ sub: String, _ args: [String]) -> Bool {
        switch sub {
        case "branch":
            let listing: Set<String> = [
                "-a",
                "-r",
                "-v",
                "-vv",
                "--list",
                "-l",
                "--show-current",
                "--merged",
                "--no-merged",
                "--contains",
            ]
            return args.isEmpty || args
                .allSatisfy {
                    listing.contains($0) || ($0.first != "-" && args.contains { $0 == "--list" || $0 == "-l" })
                }
        case "tag":
            return args.isEmpty || args
                .allSatisfy {
                    $0 == "-l" || $0 == "--list" || $0.first != "-" && args.contains { $0 == "-l" || $0 == "--list" }
                }
        case "stash": return ["list", "show"].contains(args.first ?? "")
        case "notes": return ["list", "show"].contains(args.first ?? "")
        default: return false
        }
    }

    static func isLocalDefault(_ word: String, _ context: Context) -> Bool {
        word == context.defaultBranch || word == "refs/heads/\(context.defaultBranch)"
    }

    private static func otherRemote(_ args: [String]) -> String? {
        guard let word = args.first(where: { !$0.hasPrefix("-") }) else { return nil }
        if word.contains("://") || word.contains("@") || word.hasSuffix(".git") || word.hasPrefix("/") || word
            .hasPrefix(".")
        {
            return "\(word) is another repository: only this repo's origin is allowed"
        }
        return nil
    }

    static func push(_ args: [String], _ context: Context) -> Verdict {
        guard context.power == .write else { return .no("\(context.verb.title) pushes nothing") }
        guard context.canPush else {
            return .no("this pull request is from a fork, so heed cannot push to its branch: say so instead")
        }
        var positionals: [String] = []
        for arg in args {
            switch arg {
            case "-f", "--force", "--force-if-includes", "-d", "--delete", "--mirror", "--prune", "--all":
                return .no(
                    "git push \(arg) is never allowed: no force-push, no deleting remote branches, no whole-repo pushes"
                )
            default:
                if arg.hasPrefix("--force-with-lease") || arg.hasPrefix("--delete") || arg.hasPrefix("--receive-pack")
                    || arg.hasPrefix("--exec") || arg.hasPrefix("--repo")
                {
                    return .no("git push \(arg) is never allowed")
                }
                if arg.hasPrefix("-") { continue }
                positionals.append(arg)
            }
        }
        if let remote = positionals.first, remote != "origin" {
            return .no("\(remote) is not this repo's origin: only a push to origin is allowed")
        }
        for refspec in positionals.dropFirst() {
            if refspec.hasPrefix("+") { return .no("a forced refspec (+) is never allowed") }
            if refspec.hasPrefix(":") { return .no("pushing an empty source deletes a remote branch: never allowed") }
            let destination = refspec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).last
                .map(String.init) ?? refspec
            if isLocalDefault(destination, context) {
                return .no("pushing \(context.defaultBranch) is never allowed: the work goes on a branch")
            }
            if destination.hasPrefix("refs/"), !destination.hasPrefix("refs/heads/") {
                return .no("pushing \(destination) is not allowed: only branches")
            }
        }
        return .yes
    }

    // MARK: gh

    static let ghReads: Set<String> = [
        "issue view", "issue list", "issue status", "pr view", "pr list", "pr diff", "pr checks", "pr status",
        "run view", "run list", "run watch", "repo view", "label list", "release view", "release list",
        "workflow view", "workflow list", "--version", "version", "help",
    ]
    static let ghWrites: Set<String> = [
        "issue comment", "issue edit", "issue create", "pr create", "pr edit", "pr comment", "pr ready", "pr checkout",
        "pr update-branch",
    ]
    private static let ghRefusedGroups: [String: String] = [
        "repo": "changing a repo", "secret": "secrets", "variable": "variables", "ssh-key": "ssh keys",
        "gpg-key": "gpg keys", "auth": "gh's login", "config": "gh's config", "alias": "aliases",
        "extension": "extensions", "codespace": "codespaces", "workflow": "workflows", "cache": "caches",
        "ruleset": "rulesets", "project": "projects", "gist": "gists", "org": "organisations",
        "release": "releases", "label": "labels (a repo setting)", "attestation": "attestations",
        "completion": "completion", "agent-task": "agent tasks", "copilot": "copilot",
        "search": "searches beyond this repo",
        "status": "a status across repos", "browse": "opening a browser",
    ]

    static func gh(_ words: [String], _ context: Context, cwd: String) -> Verdict {
        var positional: [String] = []
        var index = 1
        var repoFlag: String?
        var apiMethod: String?
        var apiFields = false
        var apiPath: String?
        let fileFlags = ["--body-file", "-F", "--input", "--notes-file"]
        while index < words.count {
            let word = words[index]
            if word == "-R" || word == "--repo" {
                guard index + 1 < words.count else { return .no("gh \(word) without a repo") }
                repoFlag = words[index + 1]
                index += 2
                continue
            }
            if word.hasPrefix("--repo=") { repoFlag = String(word.dropFirst("--repo=".count)) }
            for flag in fileFlags where word == flag || word.hasPrefix(flag + "=") {
                let value: String = if word.hasPrefix("--"), let equals = word.firstIndex(of: "=") {
                    String(word[word.index(after: equals)...])
                } else {
                    index + 1 < words.count ? words[index + 1] : ""
                }
                if positional.first == "api" { apiFields = true } else {
                    let check = checkPath(value, in: context, cwd: cwd, forWriting: false)
                    if !check.allowed { return check }
                }
            }
            if positional.first == "api" {
                if word == "-X" || word == "--method" {
                    apiMethod = index + 1 < words.count ? words[index + 1].uppercased() : "?"
                    index += 2
                    continue
                }
                if word.hasPrefix("--method=") { apiMethod = String(word.dropFirst("--method=".count)).uppercased() }
                if ["-f", "--field", "--raw-field"].contains(word) || word.hasPrefix("--field=")
                    || word.hasPrefix("--raw-field=")
                {
                    apiFields = true
                }
                if !word.hasPrefix("-"), positional.count == 1 { apiPath = word }
            }
            if !word.hasPrefix("-"), positional.count < 3 {
                let previous = words[index - 1]
                let valueOfFlag = index > 1 && previous.hasPrefix("-") && !previous.contains("=") && positional
                    .count >= 2
                if !valueOfFlag { positional.append(word) }
            }
            index += 1
        }
        if let repoFlag, repoFlag.lowercased() != context.repo.slug.lowercased() {
            return .no("\(repoFlag) is not this item's repo (\(context.repo.slug))")
        }
        guard let group = positional.first else { return .yes }
        if group == "api" { return api(method: apiMethod, fields: apiFields, path: apiPath, context) }
        let key = positional.prefix(2).joined(separator: " ")
        if let why = ghRefusedGroups[group], !ghReads.contains(key) {
            return .no("gh \(group): \(why) is not allowed")
        }
        if ghReads.contains(key) || ghReads.contains(group) { return .yes }
        if key == "pr review" {
            return .no("a review is posted from heed's panel after you approve it, not by the agent")
        }
        if ghWrites.contains(key) {
            guard context.power == .write else {
                return .no("\(context.verb.title) writes nothing to GitHub: gh \(key) is a write")
            }
            return .yes
        }
        return .no("gh \(key.isEmpty ? group : key) is not allowed in a Browse run")
    }

    static func api(method: String?, fields: Bool, path: String?, _ context: Context) -> Verdict {
        guard let path else { return .no("gh api without an endpoint") }
        if (method ?? "GET") != "GET" || fields {
            return .no("gh api writes are not allowed: use gh issue and gh pr")
        }
        let clean = (path.hasPrefix("/") ? String(path.dropFirst()) : path).lowercased()
        let repo = "repos/\(context.repo.slug.lowercased())"
        guard clean == repo || clean.hasPrefix(repo + "/") else {
            return .no("gh api \(path) is not under \(context.repo.slug)")
        }
        if clean.contains("..") { return .no("gh api with .. is not allowed") }
        return .yes
    }

    // MARK: Shell words

    /// A command line as heed reads it: its segments (split at `;`, `&&`, `||`, `|`, `&` and newlines), the words
    /// of each, the files it redirects into, and whether it hides a command (a substitution) or pipes into a shell.
    struct Shell {
        struct Segment {
            var words: [String] = []
            var redirects: [String] = []
            var piped = false
        }

        var segments: [Segment] = []
        var substitution = false
        var heredoc = false
        var shellPipe = false

        static func isAssignment(_ word: String) -> Bool {
            guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
            return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
        }

        static func parse(_ text: String) -> Shell {
            var shell = Shell()
            var segment = Segment()
            var word = ""
            var inWord = false
            var quote: Character?
            var redirect = false
            let chars = Array(text)
            var index = 0

            func endWord() {
                guard inWord else { return }
                if redirect { segment.redirects.append(word) } else { segment.words.append(word) }
                redirect = false
                word = ""
                inWord = false
            }
            func endSegment(pipe: Bool) {
                endWord()
                if !segment.words.isEmpty || !segment.redirects.isEmpty { shell.segments.append(segment) }
                segment = Segment()
                segment.piped = pipe
            }
            while index < chars.count {
                let c = chars[index]
                let next: Character? = index + 1 < chars.count ? chars[index + 1] : nil
                if let open = quote {
                    if c == open {
                        quote = nil
                    } else if open == "\"", c == "\\", let next {
                        word.append(next)
                        index += 1
                    } else {
                        if open == "\"", c == "`" || (c == "$" && next == "(") { shell.substitution = true }
                        word.append(c)
                    }
                    index += 1
                    continue
                }
                switch c {
                case "'", "\"":
                    quote = c
                    inWord = true
                case "\\":
                    if let next {
                        word.append(next)
                        inWord = true
                        index += 1
                    }
                case "`":
                    shell.substitution = true
                case "$":
                    if next == "(" { shell.substitution = true }
                    word.append(c)
                    inWord = true
                case " ", "\t":
                    endWord()
                case "\n", ";":
                    endSegment(pipe: false)
                case "&":
                    if next == ">" {
                        endWord()
                        redirect = true
                        index += 1
                        if index + 1 < chars.count, chars[index + 1] == ">" { index += 1 }
                    } else {
                        endSegment(pipe: false)
                        if next == "&" { index += 1 }
                    }
                case "|":
                    if next == "|" {
                        endSegment(pipe: false)
                        index += 1
                    } else {
                        endSegment(pipe: true)
                    }
                case ">", "<":
                    if next == "(" {
                        shell.substitution = true
                    } else if c == "<", next == "<" {
                        shell.heredoc = true
                        index += 1
                    } else if c == ">", next == "&" {
                        // 2>&1: no file.
                        index += 1
                        while index + 1 < chars.count,
                              chars[index + 1].isNumber || chars[index + 1] == "-"
                        {
                            index += 1
                        }
                        if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false }
                    } else {
                        if inWord, word.allSatisfy(\.isNumber) { word = ""; inWord = false } else { endWord() }
                        if c == ">" {
                            if next == ">" { index += 1 }
                            redirect = true
                        }
                    }
                default:
                    word.append(c)
                    inWord = true
                }
                index += 1
            }
            endSegment(pipe: false)
            let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "source", "eval", "."]
            for segment in shell.segments where segment.piped {
                if let first = segment.words.first, shells.contains((first as NSString).lastPathComponent),
                   !segment.words.contains("-c")
                {
                    shell.shellPipe = true
                }
            }
            return shell
        }
    }
}
