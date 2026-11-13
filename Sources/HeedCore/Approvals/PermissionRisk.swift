import Foundation

/// What an ask could do, read from its tool and command, kept honest and simple: a tag is only given when the words
/// show it, and "read only" only when every part of a command is a known reader with nothing written.
public enum PermissionRisk: String, Codable, Hashable, Sendable, CaseIterable, Comparable {
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

    /// The tags a shell command's words show.
    static func command(_ command: String) -> Set<PermissionRisk> {
        let segments = segments(command)
        var tags: Set<PermissionRisk> = []
        var allRead = !segments.isEmpty && !writesFiles(command)
        for words in segments {
            let kind = classify(words)
            if kind.network { tags.insert(.network) }
            if kind.writesGitHub { tags.insert(.writesGitHub) }
            if !kind.readOnly { allRead = false }
        }
        if allRead { tags.insert(.readOnly) }
        return tags
    }

    struct Kind {
        var readOnly = false
        var network = false
        var writesGitHub = false
    }

    static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "rg", "egrep", "fgrep", "pwd", "which", "echo", "file", "stat",
        "du", "df", "tree", "sort", "uniq", "cut", "jq", "diff", "true", "date", "whoami", "env", "printenv", "type",
        "realpath", "dirname", "basename", "test", "[", "less", "more", "awk", "tr", "nl", "column", "fd", "cd",
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

    /// One simple command (its words, environment assignments skipped).
    static func classify(_ all: [String]) -> Kind {
        var words = all.drop { $0.contains("=") && !$0.hasPrefix("-") && !$0.hasPrefix("=") }
        if words.first == "sudo" || words.first == "command" || words.first == "time" { words = words.dropFirst() }
        guard let program = words.first.map({ ($0 as NSString).lastPathComponent }) else { return Kind() }
        let rest = Array(words.dropFirst())
        var kind = Kind()
        switch program {
        case "git":
            let sub = rest.first { !$0.hasPrefix("-") } ?? ""
            kind.readOnly = gitReaders.contains(sub) || (sub == "branch" && rest.allSatisfy {
                $0 == "branch" || ["-a", "-r", "-v", "-vv", "--list", "--show-current", "-l"].contains($0)
            }) || (sub == "remote" && rest.dropFirst().allSatisfy { $0 == "-v" })
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
                let readers: Set = [
                    "view",
                    "list",
                    "diff",
                    "checks",
                    "status",
                    "watch",
                    "download",
                    "clone",
                    "checkout",
                    "",
                ]
                kind.readOnly = readers.contains(verb)
                kind.writesGitHub = !kind.readOnly
            case "search", "status", "browse", "auth", "help", "--version", "version":
                kind.readOnly = area != "auth" || verb == "status"
            default:
                kind.writesGitHub = false
            }
        case "find":
            kind.readOnly = !rest.contains { ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint"].contains($0) }
        case "sed":
            kind.readOnly = !rest.contains { $0.hasPrefix("-i") || $0 == "--in-place" }
        default:
            kind.readOnly = readers.contains(program)
            kind.network = networkTools.contains(program)
                || (packageTools.contains(program) && rest.contains { installers.contains($0) })
        }
        if program == "awk" { kind.readOnly = !all.joined(separator: " ").contains("system(") }
        return kind
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

    /// The words of a command that name a path: absolute or home-relative ones, and `cd`'s argument.
    static func commandPaths(_ command: String) -> [String] {
        segments(command).flatMap { words -> [String] in
            words.enumerated().compactMap { index, word in
                let value = word.split(separator: "=", maxSplits: 1).last.map(String.init) ?? word
                if value.hasPrefix("/") || value.hasPrefix("~") { return value }
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
