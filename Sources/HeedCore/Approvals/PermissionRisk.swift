import Foundation

/// What an ask could do, read from its tool and command, kept honest and simple: a tag is only given when the words
/// show it, and "read only" only when every part of a command is a known reader with nothing written.
public enum PermissionRisk: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
    /// Releases, publishes or deploys: what others get once it ran. Always asked, never allowed for good.
    case publishes
    case writesGitHub = "writes GitHub"
    case outsideWorktree = "outside worktree"
    case network
    case readOnly = "read only"

    /// Worst first: the order tags are shown in.
    public static func < (lhs: PermissionRisk, rhs: PermissionRisk) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }

    /// The tags for `ask`, worst first. `roots` are the session's worktrees (and folder): a path in none of them is
    /// outside.
    public static func tags(for ask: PermissionAsk, roots: [String], home: String = Paths.home) -> [PermissionRisk] {
        var tags: Set<PermissionRisk> = []
        let tool = ask.tool
        switch tool {
        case "Read", "Glob", "Grep", "LS", "NotebookRead", "read", "glob", "grep", "list":
            tags.insert(.readOnly)
        case "WebFetch", "WebSearch", "webfetch", "websearch":
            tags.formUnion([.readOnly, .network])
        default:
            break
        }
        if tool.hasPrefix("mcp__github") || tool.hasPrefix("mcp_github") {
            tags.insert(.network)
            let verb = tool.lowercased()
            if ["create", "update", "merge", "push", "add", "delete", "close", "comment", "edit", "fork", "request"]
                .contains(where: { verb.contains($0) })
            {
                tags.insert(.writesGitHub)
            }
        }
        if let command = ask.command {
            tags.formUnion(Self.command(command))
            for path in commandPaths(command) where outside(path, cwd: ask.cwd, roots: roots, home: home) {
                tags.insert(.outsideWorktree)
            }
        }
        for path in ask.paths where outside(path, cwd: ask.cwd, roots: roots, home: home) {
            tags.insert(.outsideWorktree)
        }
        return tags.sorted()
    }

    // MARK: Commands

    /// The tags a shell command's words show, for anywhere heed reads a command: an ask, or a tool call an agent's
    /// hook reported. Paths are not read here (they need the session's worktrees).
    public static func tags(forCommand command: String) -> Set<PermissionRisk> {
        Self.command(command)
    }

    /// Whether `command` releases, publishes or deploys something (`npm publish`, `gh release create`, `git push
    /// --tags`, `kubectl apply`, ...).
    public static func publishes(_ command: String) -> Bool {
        Self.command(command).contains(.publishes)
    }

    /// The tags a shell command's words show.
    static func command(_ command: String, depth: Int = 0) -> Set<PermissionRisk> {
        let segments = segments(command)
        var tags: Set<PermissionRisk> = []
        var allRead = !segments.isEmpty && !writesFiles(command)
        for words in segments {
            let kind = classify(words, depth: depth)
            if kind.network { tags.insert(.network) }
            if kind.writesGitHub { tags.insert(.writesGitHub) }
            if kind.publishes { tags.insert(.publishes) }
            if !kind.readOnly { allRead = false }
        }
        if allRead { tags.insert(.readOnly) }
        return tags
    }

    struct Kind {
        var readOnly = false
        var network = false
        var writesGitHub = false
        var publishes = false

        /// What a command run by another shows, which is never read only: heed does not follow what runs it.
        mutating func add(_ tags: Set<PermissionRisk>) {
            network = network || tags.contains(.network)
            writesGitHub = writesGitHub || tags.contains(.writesGitHub)
            publishes = publishes || tags.contains(.publishes)
        }
    }

    /// Programs that only read, whatever their arguments; the ones with options that write or run something are
    /// read separately below. Anything not listed is not read only.
    static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "pwd", "which", "echo", "stat", "du", "df", "cut",
        "jq", "diff", "true", "whoami", "printenv", "type", "realpath", "dirname", "basename", "test", "[", "tr", "nl",
        "column", "cd",
    ]
    static let gitReaders: Set<String> = [
        "status", "log", "diff", "show", "rev-parse", "ls-files", "blame", "describe", "shortlog", "grep", "reflog",
        "cat-file", "ls-tree", "merge-base", "rev-list", "whatchanged",
    ]
    static let gitNetwork: Set<String> = ["push", "pull", "fetch", "clone", "ls-remote", "remote update"]
    static let networkTools: Set<String> = [
        "curl", "wget", "ssh", "scp", "rsync", "nc", "telnet", "ftp", "sftp", "brew", "http", "xh", "ping",
    ]
    static let installers: Set<String> = [
        "install", "add", "publish", "i", "ci", "update", "upgrade", "fetch", "pull", "push", "login", "restore",
    ]
    static let packageTools: Set<String> = [
        "npm", "yarn", "pnpm", "bun", "pip", "pip3", "uv", "cargo", "go", "gem", "dotnet", "mix", "composer", "docker",
        "podman", "nuget", "swift", "poetry", "pipx", "mise",
    ]
    /// Programs that run the command in their arguments.
    static let runners: Set<String> = [
        "env", "xargs", "nice", "time", "timeout", "gtimeout", "command", "nohup", "watch", "sudo", "doas", "exec",
        "builtin", "caffeinate", "stdbuf", "ionice", "unbuffer", "flock", "parallel", "script", "arch", "chroot",
        "strace", "dtruss", "sandbox-exec",
    ]
    /// Shells that run the text after `-c`; `eval` runs its arguments.
    static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh", "fish", "csh", "tcsh"]
    /// Where a program named by its path is still the system's own.
    static let systemDirectories = ["/bin/", "/usr/bin/", "/usr/local/bin/", "/opt/homebrew/bin/"]

    /// One simple command (its words).
    static func classify(_ all: [String], depth: Int = 0) -> Kind {
        // `NAME=value cmd`: only a locale or time zone leaves a reader reading; anything else may change what runs.
        var start = 0
        var assigned = false
        while start < all.count, isAssignment(all[start]) {
            let name = all[start].split(separator: "=", maxSplits: 1).first.map(String.init) ?? ""
            if !(name == "LANG" || name == "TZ" || name == "NO_COLOR" || name.hasPrefix("LC_")) { assigned = true }
            start += 1
        }
        let words = Array(all[start...])
        guard let first = words.first else { return Kind() }
        let program = (first as NSString).lastPathComponent
        let rest = Array(words.dropFirst())
        var kind = Kind()
        if runners.contains(program) {
            if program == "command", let flag = rest.first, flag == "-v" || flag == "-V" {
                kind.readOnly = true
            } else if depth < 4 {
                kind.add(command(nested(rest).map(quote).joined(separator: " "), depth: depth + 1))
            }
        } else if shells.contains(program) || program == "eval" {
            if depth < 4, let script = program == "eval" ? rest.joined(separator: " ") : shellScript(rest) {
                kind.add(command(script, depth: depth + 1))
            }
        } else {
            kind = classify(program: program, rest)
        }
        kind.publishes = kind.publishes || publishes(program: program, rest)
        if assigned { kind.readOnly = false }
        if first.contains("/"), !systemDirectories.contains(where: { first.hasPrefix($0) }) { kind.readOnly = false }
        return kind
    }

    /// A program and its arguments, with nothing in front.
    static func classify(program: String, _ rest: [String]) -> Kind {
        var kind = Kind()
        switch program {
        case "git":
            let (sub, args, plain) = gitSubcommand(rest)
            kind.readOnly = plain && gitReads(sub, args)
            kind.network = gitNetwork.contains(sub)
            kind.writesGitHub = sub == "push"
        case "gh":
            kind.network = true
            let (area, verb) = (rest.first ?? "", rest.dropFirst().first ?? "")
            switch area {
            case "api":
                let writes = rest.contains { ["-f", "-F", "--field", "--raw-field", "--input"].contains($0) }
                    || zip(rest, rest.dropFirst()).contains { flag, value in
                        ["-X", "--method"].contains(flag) && value.uppercased() != "GET"
                    } || rest.contains { $0.hasPrefix("-X") && $0.count > 2 && $0.uppercased() != "-XGET" }
                kind.writesGitHub = writes
                kind.readOnly = !writes
            case "pr", "issue", "release", "repo", "run", "workflow", "label", "gist", "secret", "variable", "cache":
                // `checkout`, `clone` and `download` write files here, so they are not read only either.
                let readers: Set = ["view", "list", "diff", "checks", "status", "watch", ""]
                let local: Set = ["checkout", "clone", "download"]
                kind.readOnly = readers.contains(verb)
                kind.writesGitHub = !kind.readOnly && !local.contains(verb)
            case "search", "status", "help", "--version", "version":
                kind.readOnly = true
            case "auth":
                kind.readOnly = verb == "status"
            default:
                break
            }
        case "find":
            let acts: Set = [
                "-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls",
            ]
            kind.readOnly = !rest.contains { acts.contains($0) }
        case "fd", "fdfind":
            kind.readOnly = !rest.contains {
                ["-x", "-X", "--exec", "--exec-batch"].contains($0) || $0.hasPrefix("--exec")
                    || shortCluster($0, has: "x") || shortCluster($0, has: "X")
            }
        case "rg":
            kind.readOnly = !rest.contains { $0 == "--pre" || $0.hasPrefix("--pre=") || $0.hasPrefix("--pre-glob") }
        case "sort":
            kind.readOnly = !rest.contains {
                $0 == "--output" || $0.hasPrefix("--output=") || $0.hasPrefix("--compress-program")
                    || shortCluster($0, has: "o")
            }
        case "sed":
            kind.readOnly = sedReads(rest)
        case "awk", "gawk", "mawk", "nawk":
            kind.readOnly = awkReads(rest)
        case "tree":
            kind.readOnly = !rest.contains { $0 == "-o" || $0.hasPrefix("-o") }
        case "uniq":
            // A second file name is where uniq writes.
            kind.readOnly = rest.count(where: { !$0.hasPrefix("-") && !$0.allSatisfy(\.isNumber) }) <= 1
        case "date":
            kind.readOnly = !rest
                .contains { $0 == "-s" || $0.hasPrefix("--set") || !$0.hasPrefix("-") && !$0.hasPrefix("+") }
        case "file":
            kind.readOnly = !rest.contains { $0 == "-C" || $0 == "--compile" }
        default:
            kind.readOnly = readers.contains(program)
            kind.network = networkTools.contains(program)
                || (packageTools.contains(program) && rest.contains { installers.contains($0) })
        }
        return kind
    }

    /// `NAME=value`, a variable set for the command (or the shell).
    static func isAssignment(_ word: String) -> Bool {
        guard let equals = word.firstIndex(of: "="), equals != word.startIndex else { return false }
        return word[..<equals].allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    /// `-abc` holding `letter` (not a `--long` option).
    static func shortCluster(_ word: String, has letter: Character) -> Bool {
        word.hasPrefix("-") && !word.hasPrefix("--") && word.dropFirst().contains(letter)
    }

    /// A word quoted again for `segments`, so a runner's command reads as it would run.
    static func quote(_ word: String) -> String {
        word.isEmpty || word.contains { " \t\n;|&()<>'\"\\$`{}".contains($0) }
            ? "'" + word.replacingOccurrences(of: "'", with: "'\\''") + "'" : word
    }

    /// The command a runner runs: its words after the runner's own options, numbers (`timeout 5`) and variables (`env
    /// A=1`). Only for the tags it shows, so a near guess is enough.
    static func nested(_ words: [String]) -> [String] {
        var index = 0
        while index < words.count {
            let word = words[index]
            if runnerValueOptions.contains(word) {
                index += 2
            } else if word.hasPrefix("-") || isAssignment(word) || word.first.map(\.isNumber) == true {
                index += 1
            } else {
                break
            }
        }
        return Array(words[min(index, words.count)...])
    }

    /// Runner options whose value is the next word (`sudo -u root`, `xargs -I {}`, `nice -n 5`).
    static let runnerValueOptions: Set<String> = ["-u", "-g", "-n", "-s", "-k", "-C", "-p", "-I", "-L", "-P", "-d"]

    /// The text a shell runs with `-c` (`bash -lc '…'` too); nil for a script file or a shell on its own.
    static func shellScript(_ words: [String]) -> String? {
        guard let flag = words.firstIndex(where: { $0 == "-c" || shortCluster($0, has: "c") }),
              flag + 1 < words.count
        else { return nil }
        return words[flag + 1]
    }

    /// git's subcommand after its own options, the subcommand's arguments, and whether those options leave it
    /// reading (`-c`, `--exec-path` and anything heed does not know may not).
    static func gitSubcommand(_ words: [String]) -> (String, [String], Bool) {
        var index = 0
        var plain = true
        while index < words.count, words[index].hasPrefix("-") {
            let word = words[index]
            if ["-C", "--git-dir", "--work-tree", "--namespace"].contains(word) {
                index += 2
                continue
            }
            if !(["--no-pager", "-P", "--no-optional-locks", "--bare", "--literal-pathspecs", "--no-replace-objects"]
                .contains(word) || word.hasPrefix("--git-dir=") || word.hasPrefix("--work-tree=")
                || word.hasPrefix("--namespace="))
            {
                plain = false
            }
            index += 1
        }
        guard index < words.count else { return ("", [], plain) }
        return (words[index], Array(words[(index + 1)...]), plain)
    }

    /// A git subcommand that only reads, with arguments that write nothing and run nothing heed does not see.
    static func gitReads(_ sub: String, _ args: [String]) -> Bool {
        let acts = args.contains {
            $0 == "--output" || $0.hasPrefix("--output=") || $0 == "--ext-diff" || $0 == "-O"
                || $0.hasPrefix("--open-files-in-pager") || $0.hasPrefix("-O") || $0 == "--filters" || $0 == "--textconv"
        }
        if acts { return false }
        switch sub {
        case "branch":
            return args.allSatisfy { ["-a", "-r", "-v", "-vv", "--list", "--show-current", "-l"].contains($0) }
        case "remote":
            return args.allSatisfy { $0 == "-v" }
        case "reflog":
            return !["expire", "delete", "drop"].contains(args.first ?? "")
        default:
            return gitReaders.contains(sub)
        }
    }

    /// sed with no in-place edit, no script file, and a script whose commands only print: no `w`, `W` or `e`
    /// command, and no `s` with the `w` or `e` flag. A script heed cannot read is not read only.
    static func sedReads(_ args: [String]) -> Bool {
        var scripts: [String] = []
        var positional: [String] = []
        var index = 0
        while index < args.count {
            let word = args[index]
            if word == "-e" || word == "--expression" {
                guard index + 1 < args.count else { return false }
                scripts.append(args[index + 1])
                index += 2
                continue
            }
            if word.hasPrefix("--expression=") {
                scripts.append(String(word.dropFirst("--expression=".count)))
            } else if word == "-f" || word.hasPrefix("--file") || word.hasPrefix("-i") || word.hasPrefix("--in-place")
                || shortCluster(word, has: "i") || shortCluster(word, has: "f")
            {
                return false
            } else if word == "-l" {
                index += 1
            } else if !word.hasPrefix("-") || word == "-" {
                positional.append(word)
            } else if word.hasPrefix("--"), ![
                "--quiet",
                "--silent",
                "--regexp-extended",
                "--posix",
                "--debug",
                "--null-data",
                "--separate",
                "--unbuffered",
                "--sandbox",
            ].contains(word) {
                return false
            }
            index += 1
        }
        if scripts.isEmpty {
            guard let script = positional.first else { return false }
            scripts = [script]
        }
        return scripts.allSatisfy(sedScriptReads)
    }

    static func sedScriptReads(_ script: String) -> Bool {
        let allowed: Set<Character> = [
            "p", "P", "d", "D", "n", "N", "q", "Q", "=", "l", "y", "g", "G", "h", "H", "x", "b", "t", "T", ":", "z",
            "F", "{", "}", "#", "r", "R",
        ]
        for line in script.split(whereSeparator: { $0 == "\n" || $0 == ";" }) {
            var rest = Substring(line.drop { $0 == " " || $0 == "\t" })
            // The address: line numbers, `$`, `/regex/`, ranges and `!`.
            while let char = rest.first {
                if char.isNumber || " ,$!~+\t".contains(char) {
                    rest = rest.dropFirst()
                } else if char == "/" {
                    guard let end = endOfDelimited(rest, delimiter: "/") else { return false }
                    rest = rest[end...]
                } else {
                    break
                }
            }
            guard let command = rest.first else { continue }
            if command == "s" {
                guard let delimiter = rest.dropFirst().first, delimiter != "\\", delimiter != "\n",
                      let pattern = endOfDelimited(rest.dropFirst(), delimiter: delimiter),
                      let replacement = endOfDelimited(rest[rest.index(before: pattern)...], delimiter: delimiter)
                else { return false }
                let flags = rest[replacement...]
                if flags.contains("w") || flags.contains("e") || flags.contains("W") { return false }
            } else if command == "{" || command == "}" {
                if rest.dropFirst().contains(where: { !" \t".contains($0) }) { return false }
            } else if !allowed.contains(command) {
                return false
            }
        }
        return true
    }

    /// Past the closing `delimiter` of text that starts with an opening one, backslashes escaping; nil when it does
    /// not close.
    static func endOfDelimited(_ text: Substring, delimiter: Character) -> Substring.Index? {
        guard text.first == delimiter else { return nil }
        var index = text.index(after: text.startIndex)
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex { index = text.index(after: index) }
                continue
            }
            if text[index] == delimiter { return text.index(after: index) }
            index = text.index(after: index)
        }
        return nil
    }

    /// awk with its program on the command line, which neither runs a command (`system`, a pipe), redirects
    /// output, reads with `getline` nor loads code. `>` is refused even as a comparison: heed does not parse awk.
    static func awkReads(_ args: [String]) -> Bool {
        if args.contains(where: {
            $0.hasPrefix("-f") || $0.hasPrefix("--file") || $0.hasPrefix("-i") || $0.hasPrefix("--include")
                || $0.hasPrefix("-l") || $0.hasPrefix("--load") || $0.hasPrefix("-E") || $0.hasPrefix("--exec")
        }) {
            return false
        }
        let text = args.joined(separator: " ")
        return !["system", "|", ">", "getline", "@load", "close(", "fflush"].contains { text.contains($0) }
    }

    // MARK: Releases, publishes and deploys

    /// The verbs that put something out where others get it, by tool: a package registry, a release, a pushed
    /// image or tag, a deploy. Only named verbs count: a tool on its own (`vercel`) or with another verb is not.
    static func publishes(program: String, _ rest: [String]) -> Bool {
        let verbs = rest.filter { !$0.hasPrefix("-") }
        let verb = verbs.first ?? ""
        let second = verbs.dropFirst().first ?? ""
        switch program {
        case "npm", "pnpm", "bun":
            return verb == "publish" || isReleaseTask(program: program, verbs)
        case "yarn":
            return verb == "publish" || (verb == "npm" && second == "publish") || isReleaseTask(program: program, verbs)
        case "cargo": return verb == "publish"
        case "dotnet": return verb == "nuget" && second == "push"
        case "nuget": return verb == "push"
        case "gem": return verb == "push"
        case "twine": return verb == "upload"
        case "poetry", "uv", "hatch", "flit": return verb == "publish"
        case "swift": return verb == "package-registry" && second == "publish"
        case "gh":
            return (verb == "release" && ["create", "upload", "edit"].contains(second))
                || (verb == "workflow" && second == "run")
        case "git":
            let (sub, args, _) = gitSubcommand(rest)
            guard sub == "push" else { return false }
            let refs = args.filter { !$0.hasPrefix("-") }
            return args.contains { $0 == "--tags" || $0 == "--follow-tags" }
                || refs.contains { $0.hasPrefix("refs/tags/") || $0.contains(":refs/tags/") }
                || refs.dropFirst().first == "tag"
        case "docker", "podman":
            return verb == "push" || (["image", "manifest"].contains(verb) && second == "push")
                || rest.contains("--push") || rest.contains { $0.hasPrefix("--push=") && $0 != "--push=false" }
        case "fly", "flyctl": return verb == "deploy"
        case "vercel": return verb == "deploy" || rest.contains("--prod")
        case "netlify": return verb == "deploy"
        case "kubectl": return verb == "apply" || (verb == "rollout" && !["status", "history"].contains(second))
        case "helm": return ["upgrade", "install", "rollback"].contains(verb)
        case "terraform", "tofu": return verb == "apply" || verb == "destroy"
        case "brew": return verb.hasPrefix("bump-")
        case "goreleaser": return verb == "release"
        case "mise", "make", "just", "task", "rake":
            return isReleaseTask(program: program, verbs)
        default: return false
        }
    }

    /// A task named for what it does: `release`, `publish` or `deploy` (`release:npm`, `deploy-prod`), run by a task
    /// runner (`mise run release`, `npm run publish`, `make deploy`).
    static func isReleaseTask(program: String, _ verbs: [String]) -> Bool {
        let tasks: [String] = switch program {
        case "npm", "pnpm", "yarn", "bun":
            verbs.first == "run" || verbs.first == "run-script" ? Array(verbs.dropFirst().prefix(1)) : []
        case "mise": verbs.first == "run" || verbs.first == "r" ? Array(verbs.dropFirst()) : []
        default: verbs
        }
        return tasks.contains { task in
            ["release", "publish", "deploy"].contains { name in
                task == name || task.hasPrefix(name + ":") || task.hasPrefix(name + "-") || task.hasPrefix(name + "_")
            }
        }
    }

    /// A redirect into a file (`>`, `>>`, `tee`), not to /dev/null or between streams; or a substitution that runs
    /// more than heed reads.
    static func writesFiles(_ command: String) -> Bool {
        if command.contains("$(") || command.contains("`") || command.contains("<(") || command.contains(">(") {
            return true
        }
        let stripped = command.replacingOccurrences(of: "2>&1", with: "")
            .replacingOccurrences(of: ">&2", with: "")
            .replacingOccurrences(of: #"\d?>>?\s*/dev/null"#, with: "", options: .regularExpression)
        let unquoted = stripped.replacingOccurrences(of: #"'[^']*'|"[^"]*""#, with: "", options: .regularExpression)
        return unquoted.contains(">") || segments(command).contains { $0.first == "tee" }
    }

    /// The simple commands in a line: split on `&&`, `||`, `;`, `|` and newlines, outside quotes.
    static func segments(_ command: String) -> [[String]] {
        var segments: [[String]] = []
        var words: [String] = []
        var word = ""
        var quote: Character?
        var hasWord = false
        func endWord() {
            if hasWord { words.append(word) }
            word = ""
            hasWord = false
        }
        func endSegment() {
            endWord()
            if !words.isEmpty { segments.append(words) }
            words = []
        }
        var chars = Array(command)
        chars.append(" ")
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if let open = quote {
                if char == open { quote = nil } else { word.append(char) }
            } else if char == "'" || char == "\"" {
                quote = char
                hasWord = true
            } else if char == "\\", index + 1 < chars.count {
                index += 1
                word.append(chars[index])
                hasWord = true
            } else if char == " " || char == "\t" {
                endWord()
            } else if char == "\n" || char == ";" || char == "|" || char == "&" {
                // `&&`, `||` and `|&` are one separator; a lone `&` backgrounds, which ends the command too.
                if index + 1 < chars.count, chars[index + 1] == char || chars[index + 1] == "&" { index += 1 }
                endSegment()
            } else if char == "(" || char == ")" || char == "{" || char == "}" {
                endWord()
            } else {
                word.append(char)
                hasWord = true
            }
            index += 1
        }
        endSegment()
        return segments
    }

    /// The words of a command that name a path: absolute or home-relative ones, relative ones that climb (`../x`), and
    /// `cd`'s argument.
    static func commandPaths(_ command: String) -> [String] {
        segments(command).flatMap { words -> [String] in
            words.enumerated().compactMap { index, word in
                let value = word.split(separator: "=", maxSplits: 1).last.map(String.init) ?? word
                if value.hasPrefix("/") || value.hasPrefix("~") { return value }
                // A relative path that climbs out of where it starts, and `cd`'s.
                if value == ".." || value.hasPrefix("../") || value.contains("/../") || value.hasSuffix("/..") {
                    return value
                }
                if index > 0, words[index - 1] == "cd", value.hasPrefix("..") { return value }
                return nil
            }
        }
    }

    /// Whether `path` is outside every root. Relative paths are read from `cwd` (else the first root). A URL, and the
    /// system's null and terminal devices, are not paths.
    static func outside(_ path: String, cwd: String?, roots: [String], home: String) -> Bool {
        guard !roots.isEmpty, !path.contains("://"), !path.hasPrefix("/dev/") else { return false }
        let expanded = path.hasPrefix("~") ? home + path.dropFirst() : path
        let base = cwd ?? roots[0]
        let absolute = expanded.hasPrefix("/") ? expanded : base + "/" + expanded
        let normal = URL(fileURLWithPath: absolute).standardizedFileURL.path
        return !roots.contains { root in
            let root = URL(fileURLWithPath: root).standardizedFileURL.path
            return normal == root || normal.hasPrefix(root.hasSuffix("/") ? root : root + "/")
        }
    }
}
