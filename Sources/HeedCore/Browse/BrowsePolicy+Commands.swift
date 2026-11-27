import Foundation

extension BrowsePolicy {
    // MARK: Commands

    static let maxDepth = 3

    static func command(_ text: String, _ context: Context, depth: Int = 0, cwd: String? = nil) -> Verdict {
        guard depth < maxDepth else { return .no("the command nests too deep for heed to check") }
        var cwd = cwd ?? context.worktree
        let parsed = BrowseShell.parse(text)
        if parsed.substitution {
            return .no("a command substitution hides what would run: write the command out" + teaching(text))
        }
        if parsed.heredoc { return .no("a here-document: write the file with an edit instead" + teaching(text)) }
        if parsed.shellPipe { return .no("piping into a shell is never allowed") }
        if parsed.grouped {
            return .no("a subshell, a group or an unclosed quote hides what would run: write the commands one by one")
        }
        for segment in parsed.segments {
            for target in segment.redirects + segment.inputs {
                let writing = segment.redirects.contains(target)
                if target.opaque || target.glob {
                    return .no("a redirect to \(target.text) hides which file it names: write the path out")
                }
                if writing, context.power < .write, target.text != "/dev/null" {
                    return .no("\(context.verb.title) does not write files")
                }
                let check = checkPath(target.text, in: context, cwd: cwd, forWriting: writing)
                if !check.allowed { return check }
            }
            var words = segment.words
            var assigned = false
            while let first = words.first, BrowseShell.isAssignment(first) {
                let check = assignment(first.text, context)
                if !check.allowed { return check }
                assigned = true
                words.removeFirst()
            }
            guard !words.isEmpty else {
                if assigned { return .no("an assignment on its own sets a variable the next command would use") }
                continue
            }
            let verdict = preflight(words, context, cwd: cwd)
            if !verdict.allowed { return verdict }
            let step = single(words.map(\.text), context, cwd: &cwd, depth: depth)
            if !step.allowed { return step }
        }
        return .yes
    }

    /// What to say after refusing a substitution or a here-document, for the commands that models habitually write
    /// that way: the exact spelling heed allows.
    static func teaching(_ text: String) -> String {
        let words = text.split(whereSeparator: \.isWhitespace)
        let isGH = words.first == "gh"
        let mentionsBody = text.contains("--body") || text.contains(" -b ") || text.contains(" -F ")
        if isGH, mentionsBody {
            return ". " + bodyHint
        }
        if text.hasPrefix("git commit") || text.contains(" git commit") {
            return ". Write the message in single quotes (`git commit -m 'message'`, add more `-m '...'` for more "
                + "paragraphs), or in a file inside the worktree (`git commit -F message.txt`)"
        }
        return ""
    }

    /// How to give gh a text that heed can read.
    static let bodyHint =
        "Write the body to a file inside the worktree with your edit tool and use `gh pr create --title '...' "
            + "--body-file body.md`, or pass a single-quoted `--body '...'` (the same for `gh pr comment` and `gh pr edit`). "
            + "Do not commit the body file"

    /// The words themselves: the command's name is plain text, and no word leans on `$`, `~` or a brace expansion;
    /// a glob may not climb with `..` and its literal front has to be inside the worktree.
    private static func preflight(_ words: [BrowseShell.Word], _ context: Context, cwd: String) -> Verdict {
        if let head = words.first {
            if head.opaque || head.glob || head.escaped || head.text.contains("=") || head.text.contains("{")
                || head.text.contains("}")
            {
                return .no("the command's name (\(head.text)) is spelled so that heed cannot tell what it runs")
            }
        }
        for word in words {
            if word.opaque {
                return .no(
                    "\(word.text) uses $, ~ or a {a,b} expansion, so heed cannot tell what it names: write it out "
                        + "(single quotes keep a $ as text)"
                )
            }
            if word.glob {
                let check = checkGlob(word.text, in: context, cwd: cwd)
                if !check.allowed { return check }
            }
        }
        return .yes
    }

    // MARK: Environment assignments

    /// The few settings a command may be given in front of it: they change how it prints, not what it runs.
    private static let harmlessVariables: Set<String> = [
        "CI", "NO_COLOR", "FORCE_COLOR", "NODE_ENV", "TZ", "LANG", "LC_ALL", "RUST_BACKTRACE", "RUST_LOG",
        "DOTNET_NOLOGO", "DOTNET_CLI_TELEMETRY_OPTOUT", "PYTHONDONTWRITEBYTECODE", "TERM",
    ]

    private static func assignment(_ word: String, _: Context) -> Verdict {
        let name = String(word[..<word.firstIndex(of: "=")!])
        let value = String(word[word.index(after: word.firstIndex(of: "=")!)...])
        guard harmlessVariables.contains(name) else {
            return .no(
                "\(name)= in front of a command can change what it runs (GIT_*, GH_*, PATH, PAGER and the like): "
                    + "heed allows only \(harmlessVariables.sorted().prefix(4).joined(separator: ", ")) and a few more"
            )
        }
        let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "_.,:@+-".contains($0) }
        return plain ? .yes : .no("the value of \(name) has to be plain text")
    }

    // MARK: Names

    private static let systemDirectories = [
        "/usr/bin/", "/bin/", "/usr/local/bin/", "/opt/homebrew/bin/", "/usr/sbin/", "/sbin/",
    ]

    /// `/usr/bin/git` is `git`; `/usr/bin/../../tmp/x` and `/usr/bin/cu?l` are not a name at all.
    private static func systemName(_ path: String) -> String? {
        for directory in systemDirectories where path.hasPrefix(directory) {
            let name = String(path.dropFirst(directory.count))
            if !name.isEmpty, !name.contains("/") { return name }
        }
        return nil
    }

    private static let neverRun: [String: String] = [
        "sudo": "sudo", "su": "su", "doas": "doas", "ssh": "ssh", "scp": "scp", "sftp": "sftp", "rsync": "rsync",
        "nc": "nc", "ncat": "ncat", "netcat": "netcat", "telnet": "telnet", "osascript": "osascript",
        "security": "the keychain's security tool", "launchctl": "launchctl", "open": "open", "defaults": "defaults",
        "curl": "curl: downloads", "wget": "wget: downloads", "eval": "eval", "printenv": "printing the environment",
        "env": "printing the environment", "export": "export", "source": "source", ".": "source",
        "tccutil": "tccutil", "crontab": "crontab", "pbcopy": "the clipboard", "pbpaste": "the clipboard",
        "dscl": "dscl", "chown": "chown", "diskutil": "diskutil", "hdiutil": "hdiutil", "mkfs": "mkfs", "dd": "dd",
        "kill": "kill", "killall": "killall", "pkill": "pkill", "shutdown": "shutdown", "reboot": "reboot",
        "networksetup": "networksetup", "scutil": "scutil", "pmset": "pmset", "systemsetup": "systemsetup",
        "npx": "npx: downloads and runs", "bunx": "bunx: downloads and runs", "pnpx": "pnpx: downloads and runs",
        "awk": "awk: it can run commands", "gawk": "awk: it can run commands", "nawk": "awk: it can run commands",
        "ln": "ln: a link can lead out of the worktree", "builtin": "builtin", "alias": "alias",
        "docker": "docker", "kubectl": "kubectl", "terraform": "terraform", "brew": "brew",
        "gem": "gem", "pip": "pip", "pip3": "pip",
    ]

    // MARK: One command

    private static func base(_ word: String) -> String { (word as NSString).lastPathComponent }

    /// Unwraps `time`, `timeout`, `env` and the other commands that run another, with their own option tables, until
    /// the command that really runs; refuses a wrapper it cannot read. Nil with a verdict when it is done.
    private static func unwrapped(_ input: [String], _ context: Context) -> (words: [String], done: Verdict?) {
        var words = input
        for _ in 0 ..< 8 {
            guard let head = words.first else { return (words, .yes) }
            let name = head.contains("/") ? (systemName(head) ?? head) : head
            var index = 1
            func refuse(_ why: String) -> (words: [String], done: Verdict?) { (words, .no(why)) }
            func isNumber(_ text: String?) -> Bool { text.map { Int($0) != nil || Double($0) != nil } ?? false }
            switch name {
            case "command":
                while index < words.count, words[index].hasPrefix("-") {
                    switch words[index] {
                    case "-p": index += 1
                    case "-v", "-V": return (words, .yes)
                    case "--": index += 1
                    default: return refuse("command \(words[index]) is not an option heed knows")
                    }
                    if words[index - 1] == "--" { break }
                }
            case "exec":
                while index < words.count, words[index].hasPrefix("-") {
                    switch words[index] {
                    case "-c", "-l": index += 1
                    case "-a": index += 2
                    case "--": index += 1
                    default: return refuse("exec \(words[index]) is not an option heed knows")
                    }
                    if words[index - 1] == "--" { break }
                }
            case "time":
                if index < words.count, words[index] == "-p" { index += 1 }
                if index < words.count,
                   words[index].hasPrefix("-") { return refuse("time \(words[index]) is not allowed") }
            case "nohup":
                if index < words.count,
                   words[index].hasPrefix("-") { return refuse("nohup \(words[index]) is not allowed") }
            case "nice":
                if index < words.count {
                    let option = words[index]
                    if option == "-n" {
                        guard index + 1 < words.count,
                              Int(words[index + 1]) != nil else { return refuse("nice -n needs a number") }
                        index += 2
                    } else if option
                        .hasPrefix("--adjustment=") || (option.hasPrefix("-") && Int(option.dropFirst()) != nil)
                    {
                        index += 1
                    } else if option.hasPrefix("-") {
                        return refuse("nice \(option) is not an option heed knows")
                    }
                }
            case "timeout":
                while index < words.count {
                    let word = words[index]
                    if word == "--foreground" || word == "--preserve-status" || word == "-v" || word == "--verbose" {
                        index += 1
                    } else if word == "-s" || word == "-k" || word == "--signal" || word == "--kill-after" {
                        index += 2
                    } else if word.hasPrefix("--signal=") || word.hasPrefix("--kill-after=")
                        || (word.hasPrefix("-s") && word.count > 2) || (word.hasPrefix("-k") && word.count > 2)
                    {
                        index += 1
                    } else if word.hasPrefix("-") {
                        return refuse("timeout \(word) is not an option heed knows")
                    } else {
                        break
                    }
                }
                guard index < words.count, words[index].range(
                    of: #"^[0-9]+(\.[0-9]+)?[smhd]?$"#,
                    options: .regularExpression
                ) != nil
                else { return refuse("timeout without a duration heed can read") }
                index += 1
            case "stdbuf":
                while index < words.count, words[index].hasPrefix("-") {
                    let word = words[index]
                    if ["-i", "-o", "-e", "--input", "--output", "--error"].contains(word) {
                        index += 2
                    } else if ["-i", "-o", "-e"].contains(String(word.prefix(2))) && word.count > 2
                        || word.hasPrefix("--input=") || word.hasPrefix("--output=") || word.hasPrefix("--error=")
                    {
                        index += 1
                    } else {
                        return refuse("stdbuf \(word) is not an option heed knows")
                    }
                }
            case "caffeinate":
                while index < words.count, words[index].hasPrefix("-") {
                    let word = words[index]
                    if word == "-t" || word == "-w" {
                        index += 2
                    } else if word.dropFirst().allSatisfy({ "dimsu".contains($0) }), word.count > 1 {
                        index += 1
                    } else {
                        return refuse("caffeinate \(word) is not an option heed knows")
                    }
                }
                if index >= words.count { return refuse("caffeinate with no command") }
            case "env":
                while index < words.count {
                    let word = words[index]
                    if BrowseShell.isAssignment(.init(text: word)) {
                        let check = assignment(word, context)
                        if !check.allowed { return (words, check) }
                        index += 1
                    } else if word.hasPrefix("-") {
                        return refuse("env \(word) is not allowed")
                    } else {
                        break
                    }
                }
                if index >= words.count { return refuse("printing the environment would show secrets") }
            default:
                return (words, nil)
            }
            guard index <= words.count else { return refuse("\(name) is missing a value") }
            words = Array(words.dropFirst(index))
        }
        return (words, .no("the command wraps itself too deep for heed to check"))
    }

    static func single(_ input: [String], _ context: Context, cwd: inout String, depth: Int) -> Verdict {
        let (words, done) = unwrapped(input, context)
        if let done { return done }
        guard let rawName = words.first else { return .yes }
        var name = rawName
        if rawName.contains("/") {
            if let system = systemName(rawName) {
                name = system
            } else {
                return script(words, context, cwd: cwd)
            }
        }
        if let why = neverRun[name] { return .no("\(why) is never allowed in a Browse run") }
        let args = Array(words.dropFirst())
        switch name {
        case "git": return git(words, context, cwd: cwd)
        case "gh": return gh(words, context, cwd: cwd)
        case "cd":
            guard words.count == 2 else { return .no("cd takes one folder, and without one it goes to your home") }
            let check = checkPath(words[1], in: context, cwd: cwd, forWriting: false)
            if check.allowed { cwd = folded(context.resolve(joined(words[1], cwd: cwd))) }
            return check
        case "bash", "sh", "zsh", "dash", "ksh", "fish", "csh", "tcsh":
            return shell(name, args, context, cwd: cwd, depth: depth)
        case "busybox":
            guard !args.isEmpty else { return .no("busybox without an applet") }
            return single(args, context, cwd: &cwd, depth: depth)
        case "xargs":
            guard context.power == .write else {
                return .no("\(context.verb.title) does not run xargs: heed cannot see the files it is given")
            }
            return xargs(args, context, cwd: &cwd, depth: depth)
        case "set":
            let allowed: Set<String> = ["-e", "-u", "-x", "+x", "-o", "pipefail", "-eu", "-euo", "+e", "+u"]
            return args.allSatisfy(allowed.contains) ? .yes : .no("set \(args.joined(separator: " ")) is not allowed")
        case "exit", "true", "false", ":": return .yes
        default: break
        }
        if readers.contains(name) { return reader(name, args, context, cwd: cwd) }
        if let tool = tools[name] {
            guard context.power >= .run else {
                return .no("\(context.verb.title) only runs read-only commands: \(name) is not one")
            }
            return build(name, tool, args, context, cwd: cwd)
        }
        if context.power == .write {
            if let verdict = writeCommand(name, args, context, cwd: cwd) { return verdict }
        }
        if context.power == .read {
            return .no("\(context.verb.title) only runs read-only commands: \(name) is not one")
        }
        if context.power == .run {
            return .no("\(context.verb.title) runs builds, tests and read-only commands: \(name) is not one")
        }
        return .no("heed does not know \(name), so it does not run it")
    }

    /// A script of the repo: `./gradlew`, `scripts/test.sh`. Only a run that writes runs the repo's own scripts.
    private static func script(_ words: [String], _ context: Context, cwd: String) -> Verdict {
        guard let path = words.first else { return .yes }
        let check = checkPath(path, in: context, cwd: cwd, forWriting: false)
        guard check.allowed else { return check }
        let name = base(path)
        guard context.power >= .run
        else { return .no("\(context.verb.title) runs no scripts, only read-only commands") }
        if context.power == .run, !["gradlew", "mvnw"].contains(name) {
            return .no("\(context.verb.title) runs builds and tests, not the repo's scripts: \(name) is not one")
        }
        return argumentPaths(Array(words.dropFirst()), context, cwd: cwd)
    }

    // MARK: Shells, xargs

    /// `bash -c '…'`, with the flags a shell takes in front of it: parsed, never skipped over.
    private static func shell(
        _ name: String,
        _ args: [String],
        _ context: Context,
        cwd: String,
        depth: Int
    ) -> Verdict {
        guard context.power >= .run else {
            return .no("\(context.verb.title) runs no scripts, only read-only commands")
        }
        var index = 0
        var script: String?
        var sawC = false
        scan: while index < args.count {
            let word = args[index]
            if word == "--" { index += 1; break }
            guard word.hasPrefix("-") || word.hasPrefix("+"), word.count > 1 else { break }
            if word.hasPrefix("--") { return .no("\(name) \(word) is not an option heed knows") }
            var consumed = 1
            for flag in word.dropFirst() {
                switch flag {
                case "c": sawC = true
                case "e", "u", "x", "v", "n", "f", "C", "l", "b", "B", "E", "T", "h", "k", "m", "p", "t": break
                case "o", "O":
                    // `-o pipefail`: the next word is its value.
                    consumed = 2
                default: return .no("\(name) -\(flag) is not an option heed knows")
                }
            }
            index += consumed
            if sawC, index <= args.count {
                if index < args.count { script = args[index] }
                break scan
            }
        }
        if sawC {
            guard let script else { return .no("\(name) -c without a script") }
            return command(script, context, depth: depth + 1, cwd: cwd)
        }
        // A script file: only a run that writes runs one, and it has to be inside the worktree.
        guard context.power == .write else {
            return .no("\(context.verb.title) runs commands with -c, not script files")
        }
        guard index < args.count else { return .no("\(name) without a script reads commands from stdin") }
        let check = checkPath(args[index], in: context, cwd: cwd, forWriting: false)
        guard check.allowed else { return check }
        return argumentPaths(Array(args.dropFirst(index + 1)), context, cwd: cwd)
    }

    private static func xargs(_ args: [String], _ context: Context, cwd: inout String, depth: Int) -> Verdict {
        var index = 0
        let flags: Set<String> = ["-0", "-o", "-r", "-t", "-x", "--null", "--no-run-if-empty", "--verbose", "-p"]
        let valued: Set<String> = ["-I", "-J", "-L", "-n", "-P", "-s", "-R", "-S", "-E", "-d", "-a"]
        while index < args.count, args[index].hasPrefix("-"), args[index] != "-" {
            let word = args[index]
            if word == "-p" { return .no("xargs -p asks on a terminal heed does not have") }
            if word == "-a" || word
                .hasPrefix("-a") { return .no("xargs -a reads its arguments from a file: pipe it in") }
            if flags.contains(word) {
                index += 1
            } else if valued.contains(word) {
                index += 2
            } else if let first = word.dropFirst().first, valued.contains("-" + String(first)), word.count > 2 {
                index += 1
            } else if word.hasPrefix("--max-args=") || word.hasPrefix("--max-procs=") || word.hasPrefix("--replace") {
                index += 1
            } else if word == "--" {
                index += 1
                break
            } else {
                return .no("xargs \(word) is not an option heed knows")
            }
        }
        guard index < args.count else { return .yes }
        // Its words are arguments to the command after it, so the command is judged with them as given.
        return single(Array(args.dropFirst(index)), context, cwd: &cwd, depth: depth)
    }

    // MARK: Readers

    static let readers: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "find", "diff", "cmp", "uniq", "tr", "cut",
        "stat", "file", "pwd", "echo", "printf", "which", "type", "tree", "basename", "dirname", "realpath",
        "readlink", "du", "df", "date", "test", "[", "column", "nl", "tac", "rev", "od", "md5", "shasum", "sha256sum",
        "sed", "uname", "whoami", "id", "hostname", "sleep", "expr", "seq",
    ]
    /// Commands whose words are text, not files: only a word that looks like a path is judged.
    private static let textCommands: Set<String> = [
        "echo", "printf", "which", "type", "basename", "dirname", "test", "[", "expr", "seq", "sleep", "date", "uname",
        "whoami", "id", "hostname", "pwd", "tr", "cut",
    ]

    private static func reader(_ name: String, _ args: [String], _ context: Context, cwd: String) -> Verdict {
        switch name {
        case "sed": return sed(args, context, cwd: cwd)
        case "find": return find(args, context, cwd: cwd)
        case "rg":
            if args.contains(where: { $0.hasPrefix("--pre") || $0.hasPrefix("--hostname-bin") }) {
                return .no("rg --pre runs a command on every file it searches")
            }
        case "tree":
            if args.contains(where: { $0 == "-o" || $0.hasPrefix("-o") && $0.count > 2 && !$0.hasPrefix("--") }) {
                return .no("tree -o writes a file")
            }
        case "date":
            if args.contains(where: { $0 == "-s" || $0.hasPrefix("--set") || $0.hasPrefix("-f") }) {
                return .no("date -s changes the clock")
            }
        case "uniq":
            if args.count(where: { !$0.hasPrefix("-") }) > 1 { return .no("uniq with two files writes the second") }
        default: break
        }
        return argumentPaths(args, context, cwd: cwd, textOnly: textCommands.contains(name))
    }

    private static let sedAddress = #"(?:[0-9]+|\$|/[^/]*/)"#

    /// `sed -n '1,20p'`: all a reader may do.
    private static func sed(_ args: [String], _ context: Context, cwd: String) -> Verdict {
        var scripts: [String] = []
        var files: [String] = []
        var inPlace = false
        var quiet = false
        var index = 0
        var sawScript = false
        while index < args.count {
            let word = args[index]
            if word == "-n" || word == "--quiet" || word == "--silent" {
                quiet = true
            } else if ["-E", "-r", "--regexp-extended", "-s", "-u", "-z", "--posix"].contains(word) {
                // no effect on what runs
            } else if word == "-i" || word.hasPrefix("-i") && !word.hasPrefix("--") || word.hasPrefix("--in-place") {
                inPlace = true
                // BSD: `-i ''` takes an empty or dotted suffix as its own word.
                if word == "-i", index + 1 < args.count, args[index + 1].isEmpty || args[index + 1].hasPrefix(".") {
                    index += 1
                }
            } else if word == "-e" || word == "--expression" {
                guard index + 1 < args.count else { return .no("sed -e without a script") }
                scripts.append(args[index + 1])
                sawScript = true
                index += 1
            } else if word.hasPrefix("--expression=") {
                scripts.append(String(word.dropFirst("--expression=".count)))
                sawScript = true
            } else if word.hasPrefix("-"), word.count > 1 {
                return .no("sed \(word) is not an option heed knows: sed -f, w and e can run or write")
            } else if !sawScript {
                scripts.append(word)
                sawScript = true
            } else {
                files.append(word)
            }
            index += 1
        }
        guard !scripts.isEmpty else { return .no("sed without a script") }
        if inPlace, context.power < .write { return .no("\(context.verb.title) does not change files: sed -i does") }
        let editing = context.power == .write
        for script in scripts {
            let pattern = editing
                ? "^(?:\(sedAddress)(?:,\(sedAddress))?)?(?:[pdq=]|s([^\\\\\\n]).*\\1.*\\1[gGIiMmp0-9]*)$"
                : "^[0-9]+(?:,(?:[0-9]+|\\$))?p$"
            if !editing, !quiet { return .no("sed without -n prints the whole file: use -n with a line range") }
            if script.range(of: pattern, options: .regularExpression) == nil {
                return .no(
                    "heed reads only simple sed scripts (a line range with p, or s/a/b/ with g, i): '\(script)' is not "
                        + "one, and sed -f, w and e can run commands or write files"
                )
            }
        }
        return argumentPaths(files, context, cwd: cwd, forWriting: inPlace)
    }

    private static func find(_ args: [String], _ context: Context, cwd: String) -> Verdict {
        let refused: Set<String> = [
            "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls", "-files0-from",
        ]
        if let bad = args.first(where: { refused.contains($0) }) {
            return .no("find \(bad) runs a command or writes a file: use xargs or grep")
        }
        if args.contains("-delete"), context.power < .write {
            return .no("\(context.verb.title) does not change files: find -delete does")
        }
        return argumentPaths(args, context, cwd: cwd, forWriting: args.contains("-delete"))
    }

    /// Every word that names a file, judged with the file's real place: positionals in full, options' values after
    /// `=` or attached.
    static func argumentPaths(
        _ args: [String], _ context: Context, cwd: String, forWriting: Bool = false, textOnly: Bool = false
    ) -> Verdict {
        var rest = ArraySlice(args)
        var afterDashes = false
        while let word = rest.popFirst() {
            var candidate: String?
            if !afterDashes, word == "--" {
                afterDashes = true
                continue
            }
            if !afterDashes, word.hasPrefix("-"), word.count > 1 {
                if let equals = word.firstIndex(of: "="), word.hasPrefix("--") {
                    candidate = String(word[word.index(after: equals)...])
                } else if !word.hasPrefix("--"), word.count > 2 {
                    candidate = String(word.dropFirst(2))
                    if candidate?.hasPrefix("=") == true { candidate = String(candidate!.dropFirst()) }
                    if candidate.map(looksLikePath) != true { candidate = nil }
                }
            } else if word != "-" {
                candidate = word
            }
            guard let candidate, !candidate.isEmpty else { continue }
            if textOnly, !looksLikePath(candidate) { continue }
            for piece in candidate.contains(" ") && textOnly ? candidate.split(separator: " ")
                .map(String.init) : [candidate]
            {
                if textOnly, !looksLikePath(piece) { continue }
                let verdict = checkPath(piece, in: context, cwd: cwd, forWriting: forWriting)
                if !verdict.allowed { return verdict }
            }
        }
        return .yes
    }

    static func looksLikePath(_ word: String) -> Bool {
        if word.contains("://") { return false }
        return word.hasPrefix("~") || word.contains("/") || word == ".."
    }

    // MARK: Build and test tools

    enum Subcommands {
        case any
        case only(Set<String>)
        case none

        func allows(_ sub: String?) -> Bool {
            switch self {
            case .any: true
            case .none: false
            case let .only(set): sub.map(set.contains) ?? false
            }
        }
    }

    struct Tool {
        /// What Review may run, and what Fix and Implement may.
        var run: Subcommands
        var write: Subcommands
    }

    static let tools: [String: Tool] = {
        let node = Tool(
            run: .only(["test", "t", "tst", "run", "run-script", "exec"]),
            write: .only([
                "test", "t", "tst", "run", "run-script", "install", "i", "ci", "add", "remove", "rm", "update", "ls",
                "list", "outdated", "audit", "exec", "dlx", "lint", "build", "dev", "start", "install-test", "version",
            ])
        )
        let jvm = Tool(
            run: .only([
                "test",
                "build",
                "check",
                "assemble",
                "compile",
                "verify",
                "clean",
                "compileJava",
                "compileKotlin",
                "testClasses",
            ]),
            write: .any
        )
        return [
            "dotnet": Tool(
                run: .only(["build", "test", "restore", "--version", "--info", "list", "build-server"]),
                write: .only([
                    "build", "test", "restore", "run", "clean", "format", "pack", "add", "remove", "new",
                    "sln", "list", "--version", "--info", "ef", "msbuild", "vstest", "build-server", "watch",
                ])
            ),
            "swift": Tool(
                run: .only(["build", "test", "--version"]),
                write: .only(["build", "test", "run", "package", "--version", "format"])
            ),
            "npm": node, "pnpm": node, "yarn": node, "bun": node,
            "make": Tool(run: .any, write: .any), "gmake": Tool(run: .any, write: .any),
            "cargo": Tool(
                run: .only(["build", "test", "check", "clippy", "doc", "--version"]),
                write: .only([
                    "build", "test", "check", "clippy", "doc", "run", "fmt", "add", "remove", "update", "clean",
                    "bench",
                    "fix", "tree", "metadata", "--version", "fetch",
                ])
            ),
            "go": Tool(
                run: .only(["build", "test", "vet", "list", "version"]),
                write: .only([
                    "build",
                    "test",
                    "vet",
                    "run",
                    "mod",
                    "fmt",
                    "generate",
                    "get",
                    "list",
                    "clean",
                    "version",
                    "work",
                ])
            ),
            "mise": Tool(run: .only(["run", "r"]), write: .only(["run", "r", "tasks", "ls", "x"])),
            "gradle": jvm, "gradlew": jvm, "mvn": jvm, "mvnw": jvm,
            "pytest": Tool(run: .any, write: .any), "py.test": Tool(run: .any, write: .any),
            "tox": Tool(run: .any, write: .any), "nox": Tool(run: .any, write: .any),
            "rspec": Tool(run: .any, write: .any), "jest": Tool(run: .any, write: .any),
            "vitest": Tool(run: .any, write: .any), "ctest": Tool(run: .any, write: .any),
            "mypy": Tool(run: .any, write: .any), "flake8": Tool(run: .any, write: .any),
            "pylint": Tool(run: .any, write: .any), "shellcheck": Tool(run: .any, write: .any),
            "tsc": Tool(run: .any, write: .any), "eslint": Tool(run: .any, write: .any),
            "swiftlint": Tool(run: .any, write: .any), "swiftformat": Tool(run: .none, write: .any),
            "prettier": Tool(run: .none, write: .any), "black": Tool(run: .none, write: .any),
            "ruff": Tool(run: .none, write: .any), "rake": Tool(run: .only(["test", "spec"]), write: .any),
            "mix": Tool(run: .only(["test", "compile"]), write: .any),
            "xcodebuild": Tool(run: .only(["build", "test", "-version"]), write: .any),
            "python": Tool(run: .only(["-m"]), write: .any), "python3": Tool(run: .only(["-m"]), write: .any),
            "node": Tool(run: .none, write: .any), "ruby": Tool(run: .none, write: .any),
            "perl": Tool(run: .none, write: .none),
        ]
    }()

    private static let interpreters: Set<String> = ["python", "python3", "node", "ruby", "perl"]

    /// What Review (which runs tests and no scripts) may run to test, for a refusal and for its prompt.
    static let testHint =
        "To run the tests use `python -m pytest` or `python -m unittest`, `npm test`, `pnpm test`, `yarn test`, "
            + "`dotnet test`, `swift test`, `cargo test`, `go test ./...`, `make test`, `mise run test` or `pytest`"

    private static let ciScript = #"^(test|build|lint|check|typecheck|tsc|coverage|verify|ci|compile|format:check|types)([:\-].*)?$"#
    private static let publishWord = #"^(publish|deploy|release|ship|push|upload|login|logout|adduser|token|whoami|owner|yank)([:\-].*)?$"#
    private static let publishing: Set<String> = [
        "npm", "pnpm", "yarn", "bun", "make", "gmake", "cargo", "dotnet", "gradle", "gradlew", "mvn", "mvnw", "mise",
        "go", "swift", "rake", "mix",
    ]
    private static let pythonModules: Set<String> = [
        "pytest", "unittest", "pip", "venv", "black", "ruff", "mypy", "build", "pylint", "flake8", "coverage", "tox",
        "nox",
    ]

    private static func build(
        _ name: String, _ tool: Tool, _ args: [String], _ context: Context, cwd: String
    ) -> Verdict {
        let allowed = context.power == .write ? tool.write : tool.run
        let words = args.filter { !$0.hasPrefix("-") }
        let sub = words.first
        switch allowed {
        case .none:
            return .no("\(context.verb.title) does not run \(name)" +
                (interpreters.contains(name) ? ". " + testHint : ""))
        case let .only(set):
            if !args.isEmpty, !set.contains(sub ?? ""), !set.contains(args.first ?? "") {
                if interpreters.contains(name) {
                    return .no(
                        "\(context.verb.title) runs the tests, not scripts: `\(name) \(args[0])` is a script. " +
                            testHint
                    )
                }
                return .no(
                    "\(context.verb.title) does not run `\(name) \(sub ?? args[0])`: \(name) is allowed for "
                        + (context.power == .write ? "builds, tests and dependencies" : "builds and tests")
                )
            }
        case .any: break
        }
        if publishing.contains(name),
           let bad = words.first(where: { $0.range(of: publishWord, options: .regularExpression) != nil })
        {
            return .no("\(name) \(bad) publishes or logs in: never from a run")
        }
        switch name {
        case "npm", "pnpm", "yarn", "bun":
            if sub == "run" || sub == "run-script" || sub == "exec" || sub == "dlx" {
                guard sub == "run" || sub == "run-script" else {
                    return .no("\(name) \(sub ?? "") downloads and runs a package: heed does not allow it")
                }
                let script = words.dropFirst().first ?? ""
                if context.power == .run, script.range(of: ciScript, options: .regularExpression) == nil {
                    return .no(
                        "\(context.verb.title) runs the build and test scripts (test, build, lint, check): \(script) is not one"
                    )
                }
            }
        case "mise":
            let task = words.dropFirst().first ?? ""
            if context.power == .run, task.range(of: ciScript, options: .regularExpression) == nil {
                return .no(
                    "\(context.verb.title) runs the build and test tasks (test, build, lint, check): \(task) is not one"
                )
            }
        case "make", "gmake":
            if context.power == .run {
                let targets = words.filter { !$0.contains("=") }
                if let bad = targets
                    .first(where: { $0.range(of: ciScript + "|^all$", options: .regularExpression) == nil })
                {
                    return .no(
                        "\(context.verb.title) runs the make targets test, build, check and lint: \(bad) is not one"
                    )
                }
            }
        case "python", "python3":
            return python(args, context, cwd: cwd)
        case "node":
            return node(args, context, cwd: cwd)
        case "ruby", "perl":
            return interpreter(name, args, context, cwd: cwd)
        case "eslint", "prettier", "black", "ruff", "swiftformat", "swiftlint":
            if context.power == .run, args.contains(where: { $0 == "--fix" || $0 == "--write" || $0 == "-w" }) {
                return .no("\(context.verb.title) does not change files: \(name) \("--fix") does")
            }
        default: break
        }
        return argumentPaths(args, context, cwd: cwd)
    }

    private static func python(_ args: [String], _ context: Context, cwd: String) -> Verdict {
        var index = 0
        while index < args.count, args[index].hasPrefix("-"), args[index] != "-m" {
            let word = args[index]
            if ["-u", "-B", "-b", "-s", "-S", "-E", "-I", "-O", "-q", "-v"].contains(word) || word.hasPrefix("-W")
                || word.hasPrefix("-X")
            {
                index += word == "-W" || word == "-X" ? 2 : 1
            } else {
                return .no("python \(word) is not allowed: write the code in a file, or use -m")
            }
        }
        guard index < args.count else { return .no("python with no script reads commands from stdin") }
        if args[index] == "-m" {
            guard index + 1 < args.count, pythonModules.contains(args[index + 1]) else {
                return .no(
                    "python -m runs pytest, unittest and a few tools: \(index + 1 < args.count ? args[index + 1] : "") is not one"
                )
            }
            if context.power == .run, !["pytest", "unittest"].contains(args[index + 1]) {
                return .no("\(context.verb.title) runs tests only: python -m \(args[index + 1]) is not one")
            }
            return argumentPaths(Array(args.dropFirst(index + 2)), context, cwd: cwd)
        }
        guard context.power == .write
        else { return .no("\(context.verb.title) runs no scripts: python \(args[index]) is one") }
        let check = checkPath(args[index], in: context, cwd: cwd, forWriting: false)
        return check.allowed ? argumentPaths(Array(args.dropFirst(index + 1)), context, cwd: cwd) : check
    }

    private static func node(_ args: [String], _ context: Context, cwd: String) -> Verdict {
        guard context.power == .write else { return .no("\(context.verb.title) runs no scripts: node runs one") }
        let refused: Set<String> = [
            "-e", "--eval", "-p", "--print", "-r", "--require", "--import", "--loader", "--experimental-loader", "-i",
            "--interactive", "--input-type",
        ]
        if let bad = args
            .first(where: { refused.contains($0) || $0.hasPrefix("--eval=") || $0.hasPrefix("--require=") })
        {
            return .no("node \(bad) runs code from the command line: write it in a file")
        }
        return argumentPaths(args, context, cwd: cwd)
    }

    private static func interpreter(_ name: String, _ args: [String], _ context: Context, cwd: String) -> Verdict {
        guard context.power == .write else { return .no("\(context.verb.title) runs no scripts: \(name) runs one") }
        guard let first = args.first, !first.hasPrefix("-") else {
            return .no("\(name) with an option (-e, -c) runs code from the command line: write it in a file")
        }
        return argumentPaths(args, context, cwd: cwd)
    }

    // MARK: Commands that change files (Fix and Implement)

    private static let fileMutators: Set<String> = ["mkdir", "touch", "cp", "mv", "rm", "rmdir", "tee", "chmod", "tar"]

    private static func writeCommand(_ name: String, _ args: [String], _ context: Context, cwd: String) -> Verdict? {
        switch name {
        case "mkdir", "touch", "cp", "mv", "rm", "rmdir", "tee":
            return argumentPaths(args, context, cwd: cwd, forWriting: true)
        case "chmod":
            // The mode is not a file.
            let rest = args.drop { $0.hasPrefix("-") }.dropFirst()
            return argumentPaths(Array(rest), context, cwd: cwd, forWriting: true)
        case "tar":
            let first = args.first ?? ""
            let flags = first.hasPrefix("-") ? first.dropFirst() : first[...]
            guard !args.contains(where: { $0.hasPrefix("--") || $0.contains("checkpoint") }),
                  flags.allSatisfy({ "cxtvzjJfpCk".contains($0) })
            else {
                return .no(
                    "tar with an option heed does not know: --to-command and --use-compress-program run commands"
                )
            }
            return argumentPaths(args, context, cwd: cwd, forWriting: true)
        case "sort":
            let allowedShort = Set("nrufbhVcsdMmk")
            for word in args where word.hasPrefix("-") {
                if word.hasPrefix("--") {
                    guard ["--numeric-sort", "--reverse", "--unique", "--ignore-case", "--stable"].contains(word)
                    else {
                        return .no(
                            "sort \(word) is not an option heed knows (--output and --compress-program write and run)"
                        )
                    }
                } else if word.hasPrefix("-k") || word.hasPrefix("-t") {
                    continue
                } else if !word.dropFirst().allSatisfy(allowedShort.contains) {
                    return .no("sort \(word) is not an option heed knows (-o writes a file)")
                }
            }
            return argumentPaths(args, context, cwd: cwd)
        case "jq":
            let refused = [
                "--rawfile",
                "--slurpfile",
                "--argfile",
                "-f",
                "--from-file",
                "-L",
                "--seq",
                "--stream-errors",
            ]
            if args.contains(where: { refused.contains($0) || $0.hasPrefix("--from-file") }) {
                return .no("jq reading its program or data from another file is not allowed")
            }
            if args.contains(where: { $0.range(
                of: #"\benv\b|\$ENV|input_filename|\$__loc__|getpath|import|include"#,
                options: .regularExpression
            ) != nil }) {
                return .no("a jq program that reads the environment or files is not allowed")
            }
            return argumentPaths(args, context, cwd: cwd)
        default:
            return nil
        }
    }
}
