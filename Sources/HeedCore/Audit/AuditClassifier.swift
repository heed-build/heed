import Foundation

/// Reads outward actions from what ran: heed's own call-log rows, and the commands agents' hooks report. Only what
/// leaves this Mac counts: a push, a change on GitHub, a release, publish or deploy. Reading, fetching and
/// marking notifications read are not actions.
public enum AuditClassifier {
    /// What one command does outward, one entry per simple command that does something.
    public struct Found: Hashable, Sendable {
        public var tag: AuditClass
        public var what: String
        public var repo: String?
        public var number: Int?

        public init(tag: AuditClass, what: String, repo: String? = nil, number: Int? = nil) {
            self.tag = tag
            self.what = what
            self.repo = repo
            self.number = number
        }
    }

    /// The outward actions in a shell command line.
    public static func actions(in command: String) -> [Found] {
        actions(PermissionRisk.segments(command), depth: 0)
    }

    /// Whether a command line does anything outward.
    public static func isOutward(_ command: String) -> Bool { !actions(in: command).isEmpty }

    static func actions(_ segments: [[String]], depth: Int) -> [Found] {
        segments.flatMap { action($0, depth: depth) }
    }

    /// One simple command: its runner (`env`, `sudo`, `bash -c`) looked through, as `PermissionRisk` does.
    static func action(_ all: [String], depth: Int) -> [Found] {
        let words = Array(all.drop(while: PermissionRisk.isAssignment))
        guard let first = words.first else { return [] }
        let program = (first as NSString).lastPathComponent
        let rest = Array(words.dropFirst())
        if PermissionRisk.runners.contains(program) {
            guard depth < 4 else { return [] }
            return action(PermissionRisk.nested(rest), depth: depth + 1)
        }
        if PermissionRisk.shells.contains(program) || program == "eval" {
            guard depth < 4,
                  let script = program == "eval" ? rest.joined(separator: " ") : PermissionRisk.shellScript(rest)
            else { return [] }
            return actions(PermissionRisk.segments(script), depth: depth + 1)
        }
        switch program {
        case "git": return git(rest).map { [$0] } ?? []
        case "gh": return gh(rest).map { [$0] } ?? []
        default:
            guard PermissionRisk.publishes(program: program, rest) else { return [] }
            // The program and its verbs, up to its first option: `npm publish`, `cargo publish`, `fly deploy`.
            let shown = ([program] + rest.prefix { !$0.hasPrefix("-") }).prefix(4).joined(separator: " ")
            return [Found(tag: .publish, what: shown)]
        }
    }

    // MARK: git

    static func git(_ rest: [String]) -> Found? {
        let (sub, args, _) = PermissionRisk.gitSubcommand(rest)
        guard sub == "push" else { return nil }
        let refs = args.filter { !$0.hasPrefix("-") }
        if PermissionRisk.publishes(program: "git", rest) {
            let tags = refs.dropFirst().map { $0.replacingOccurrences(of: "refs/tags/", with: "") }
                .filter { $0 != "tag" }
            return Found(
                tag: .publish,
                what: tags.isEmpty ? "pushed tags" : "pushed tag \(tags.joined(separator: ", "))"
            )
        }
        let deleting = args.contains { $0 == "-d" || $0 == "--delete" }
        let forced = args.contains { $0 == "-f" || $0 == "--force" || $0.hasPrefix("--force-with-lease") }
        // `git push origin HEAD:feature/x`: what it lands on is after the colon.
        let branches = refs.dropFirst().map { ref -> String in
            let target = ref.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ref
            return target.replacingOccurrences(of: "refs/heads/", with: "").replacingOccurrences(of: "+", with: "")
        }
        let onto = branches.isEmpty ? "the current branch" : branches.joined(separator: ", ")
        if deleting { return Found(tag: .push, what: "deleted \(onto) on the remote") }
        return Found(
            tag: .push,
            what: (forced ? "force-pushed " : "pushed ") + (branches.isEmpty ? onto : "to \(onto)")
        )
    }

    // MARK: gh

    static func gh(_ rest: [String]) -> Found? {
        let (area, verb) = (rest.first ?? "", rest.dropFirst().first ?? "")
        let repo = option(["-R", "--repo"], in: rest)
        let number = rest.dropFirst(2).first { !$0.hasPrefix("-") }.flatMap(numberIn)
        let short = repo.map { " " + (($0 as NSString).lastPathComponent) } ?? ""
        let ref = number.map { "#\($0)" } ?? "a PR"
        switch area {
        case "pr":
            switch verb {
            case "merge": return Found(tag: .merge, what: "merged \(ref)\(short)", repo: repo, number: number)
            case "comment": return Found(tag: .comment, what: "commented on \(ref)\(short)", repo: repo, number: number)
            case "review":
                let what = rest.contains { $0 == "--approve" || $0 == "-a" } ? "approved \(ref)"
                    : rest.contains { $0 == "--request-changes" || $0 == "-r" } ? "asked for changes on \(ref)"
                    : "reviewed \(ref)"
                return Found(tag: .review, what: what + short, repo: repo, number: number)
            case "edit":
                if let reviewers = option(["--add-reviewer"], in: rest) {
                    return Found(
                        tag: .review, what: "asked \(reviewers) to review \(ref)\(short)", repo: repo, number: number
                    )
                }
                return Found(tag: .write, what: "edited \(ref)\(short)", repo: repo, number: number)
            case "create": return Found(tag: .write, what: "opened a PR\(short)", repo: repo)
            case "close", "reopen", "ready", "lock", "unlock":
                return Found(
                    tag: .write,
                    what: "\(verb == "ready" ? "marked ready" : verb + "d") \(ref)\(short)",
                    repo: repo,
                    number: number
                )
            case "update-branch":
                return Found(tag: .write, what: "brought \(ref)\(short) up to date", repo: repo, number: number)
            default: break
            }
        case "release":
            if ["create", "upload", "edit"].contains(verb) {
                let tag = rest.dropFirst(2).first { !$0.hasPrefix("-") }
                let what = verb == "create" ? "release \(tag ?? "")" : "release \(verb) \(tag ?? "")"
                return Found(tag: .publish, what: what.trimmingCharacters(in: .whitespaces) + short, repo: repo)
            }
        case "workflow" where verb == "run":
            let name = rest.dropFirst(2).first { !$0.hasPrefix("-") } ?? "a workflow"
            return Found(tag: .publish, what: "ran \(name)\(short)", repo: repo)
        case "issue":
            if verb == "comment" {
                return Found(tag: .comment, what: "commented on \(ref)\(short)", repo: repo, number: number)
            }
        case "api":
            return api(rest)
        default: break
        }
        guard PermissionRisk.classify(program: "gh", rest).writesGitHub else { return nil }
        return Found(
            tag: .write,
            what: (["gh"] + rest.prefix(3).filter { !$0.hasPrefix("-") }).joined(separator: " "),
            repo: repo,
            number: number
        )
    }

    /// `gh api -X POST repos/o/r/issues/12/comments`: what the path and method change. Notification state (read,
    /// muted) is heed's own bookkeeping, not an action.
    static func api(_ rest: [String]) -> Found? {
        guard PermissionRisk.classify(program: "gh", rest).writesGitHub else { return nil }
        let method = (option(["-X", "--method"], in: rest) ?? "POST").uppercased()
        guard let path = rest.dropFirst().first(where: { !$0.hasPrefix("-") && $0.contains("/") || $0 == "graphql" }),
              !path.hasPrefix("notifications")
        else { return nil }
        if path == "graphql" {
            // Reads go through graphql too; only a mutation changes anything.
            guard rest.contains(where: { $0.contains("mutation") }) else { return nil }
            return Found(tag: .write, what: "GraphQL mutation")
        }
        let parts = path.split(separator: "/").map(String.init)
        guard parts.first == "repos", parts.count >= 3 else {
            return Found(tag: .write, what: "gh api \(method) \(path)")
        }
        let repo = "\(parts[1])/\(parts[2])"
        let tail = Array(parts.dropFirst(3))
        let number = tail.count >= 2 ? Int(tail[1]) : nil
        let ref = number.map { "#\($0)" } ?? ""
        switch (tail.first, tail.last) {
        case ("issues", "comments"), ("pulls", "comments"):
            return Found(tag: .comment, what: "commented on \(ref) \(parts[2])", repo: repo, number: number)
        case ("pulls", "reviews"):
            return Found(tag: .review, what: "reviewed \(ref) \(parts[2])", repo: repo, number: number)
        case ("pulls", "merge"):
            return Found(tag: .merge, what: "merged \(ref) \(parts[2])", repo: repo, number: number)
        case ("releases", _):
            return Found(tag: .publish, what: "release \(parts[2])", repo: repo)
        case ("dispatches", _), ("deployments", _):
            return Found(tag: .publish, what: "\(tail[0]) \(parts[2])", repo: repo)
        default:
            return Found(
                tag: .write,
                what: "\(method) \(tail.joined(separator: "/")) \(parts[2])",
                repo: repo,
                number: number
            )
        }
    }

    static func option(_ names: [String], in words: [String]) -> String? {
        for (index, word) in words.enumerated() {
            if names.contains(word), index + 1 < words.count { return words[index + 1] }
            for name in names where name.hasPrefix("--") && word.hasPrefix(name + "=") {
                return String(word.dropFirst(name.count + 1))
            }
        }
        return nil
    }

    /// `412`, `#412`, or a PR URL's number.
    static func numberIn(_ word: String) -> Int? {
        if let number = Int(word.hasPrefix("#") ? String(word.dropFirst()) : word) { return number }
        return PullRef(url: word)?.number
    }

    // MARK: heed's own calls

    /// The action a row of heed's call log is: a GitHub write heed made, or a `git push` it ran. Nil for anything
    /// else.
    public static func action(_ call: LoggedCall, cause: Cause?) -> AuditAction? {
        let isPush = call.kind == .shell && call.command.contains("push")
        guard call.kind == .github && call.write || isPush else { return nil }
        // A host's command is the command on the host; heed's own shell rows are quoted as `ShellQuote` writes them.
        guard let found = actions(in: call.command).first else { return nil }
        return AuditAction(
            at: call.at, actor: .heed, tag: found.tag, what: found.what, command: call.command, repo: found.repo,
            url: url(found), cause: cause?.id, session: cause?.session, sessionTitle: cause?.sessionTitle,
            agent: call.agent, outcome: call.failed ? .failed : .done
        )
    }

    // MARK: Agents' calls

    /// The action an agent's reported tool call is: a shell command that does something outward, or a GitHub tool
    /// (an MCP server's) that writes.
    public static func action(
        _ call: ToolCall, at: Date, session: String?, sessionTitle: String?, agent: String?, repo: String?,
        cause: Cause?
    ) -> AuditAction? {
        let found: Found?
        let command: String
        if let text = call.command ?? call.input, shellTools.contains(call.tool) {
            command = text
            found = actions(in: text).first
        } else if call.tool.hasPrefix("mcp__github") || call.tool.hasPrefix("mcp_github") {
            command = call.label
            found = githubTool(call.tool)
        } else {
            return nil
        }
        guard let found else { return nil }
        let where_ = found.repo ?? repo
        return AuditAction(
            at: at, actor: .agent, tag: found.tag, what: found.what, command: command, repo: where_,
            url: url(Found(tag: found.tag, what: found.what, repo: where_, number: found.number)), cause: cause?.id,
            session: session, sessionTitle: sessionTitle, agent: agent, outcome: call.error ? .failed : .done
        )
    }

    /// The tools agents run shell commands with.
    public static let shellTools: Set<String> = ["Bash", "bash", "shell", "exec_command", "run_shell_command"]

    /// A GitHub MCP tool, by the verb in its name.
    static func githubTool(_ tool: String) -> Found? {
        let name = tool.lowercased()
        let verb = name.components(separatedBy: "github_").dropFirst().joined(separator: "github_")
            .trimmingCharacters(in: CharacterSet(charactersIn: "_"))
        // Readers name themselves first: get_, list_, search_.
        if ["get", "list", "search", "read"].contains(where: { verb.hasPrefix($0 + "_") || verb == $0 }) { return nil }
        if name.contains("merge") { return Found(tag: .merge, what: "merged a PR (\(verb))") }
        if name.contains("comment") { return Found(tag: .comment, what: "commented (\(verb))") }
        if name.contains("review") { return Found(tag: .review, what: "reviewed (\(verb))") }
        if name.contains("push") { return Found(tag: .push, what: "pushed (\(verb))") }
        if name.contains("release") { return Found(tag: .publish, what: "release (\(verb))") }
        guard ["create", "update", "add", "delete", "close", "edit", "fork", "request"].contains(where: name.contains)
        else { return nil }
        return Found(tag: .write, what: verb)
    }

    static func url(_ found: Found) -> String? {
        guard let repo = found.repo, repo.contains("/") else { return nil }
        guard let number = found.number else { return "https://github.com/\(repo)" }
        return "https://github.com/\(repo)/pull/\(number)"
    }
}
