import Foundation

extension BrowsePolicy {
    // MARK: gh

    static let ghReads: Set<String> = [
        "issue view", "issue list", "issue status", "pr view", "pr list", "pr diff", "pr checks", "pr status",
        "run view", "run list", "run watch", "repo view", "label list", "release view", "release list",
        "workflow view", "workflow list",
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
        "search": "searches beyond this repo", "status": "a status across repos", "browse": "opening a browser",
    ]

    private static let ghOptions: Options = {
        var spec = Options()
        spec.flags = "cdef"
        spec.shortValues = [
            "R": .text, "b": .text, "t": .text, "F": .read, "l": .text, "a": .text, "m": .text, "p": .text,
            "B": .text, "H": .text, "s": .text, "L": .text, "q": .text, "A": .text, "S": .text, "j": .text,
        ]
        spec.longs = [
            "comments", "draft", "fill", "fill-first", "fill-verbose", "edit-last", "create-if-none", "delete-last",
            "no-maintainer-edit", "dry-run", "patch", "name-only", "color", "watch", "fail-fast", "required",
            "log", "log-failed", "verbose", "exit-status", "version", "help", "ready", "no-color", "recover-unused",
            "all", "web-unused",
        ]
        spec.longValues = [
            "repo": .text, "body": .text, "body-file": .read, "title": .text, "label": .text, "assignee": .text,
            "milestone": .text, "project": .text, "base": .text, "head": .text, "state": .text, "limit": .text,
            "jq": .text, "json": .text, "author": .text, "search": .text, "template": .text, "add-label": .text,
            "remove-label": .text, "add-assignee": .text, "remove-assignee": .text, "add-reviewer": .text,
            "remove-reviewer": .text, "add-project": .text, "remove-project": .text, "reviewer": .text,
            "branch": .text, "workflow": .text, "event": .text, "status": .text, "user": .text, "app": .text,
            "commit": .text, "job": .text, "notes-file": .read, "notes": .text, "interval": .text, "mention": .text,
            "milestone-unused": .text, "type": .text, "color-unused": .text, "order": .text, "sort": .text,
        ]
        return spec
    }()

    private static let ghApiOptions: Options = {
        var spec = Options()
        spec.flags = "i"
        spec.shortValues = ["H": .text, "q": .text, "t": .text]
        spec.longs = ["paginate", "slurp", "silent", "include", "verbose"]
        spec.longValues = ["header": .text, "jq": .text, "template": .text, "cache": .text]
        return spec
    }()

    static func gh(_ words: [String], _ context: Context, cwd: String) -> Verdict {
        let args = Array(words.dropFirst())
        if args.first(where: { !$0.hasPrefix("-") }) == "api" {
            return api(args, context)
        }
        let parsed = ghOptions.parse(args, command: "gh")
        if let refusal = parsed.refusal { return .no(refusal) }
        for (name, value, _) in parsed.values where name == "R" || name == "repo" {
            if value.lowercased() != context.repo.slug.lowercased() {
                return .no("\(value) is not this item's repo (\(context.repo.slug))")
            }
        }
        for (_, value, kind) in parsed.values where kind == .read {
            if value == "-" {
                return .no("reading a text from stdin hides it: \(bodyHint)")
            }
            let check = checkPath(value, in: context, cwd: cwd, forWriting: false)
            if !check.allowed { return check }
        }
        let positional = parsed.positionals
        guard let group = positional.first else { return .yes }
        let key = positional.prefix(2).joined(separator: " ")
        for word in positional.dropFirst(2) {
            if word.contains("://") || word.contains("github.com/") || word.range(
                of: #"^\S+/\S+#[0-9]+$"#,
                options: .regularExpression
            ) != nil {
                return .no("\(word) names an item by its address: say its number, and it is this repo's")
            }
            if ["transfer", "fork", "clone"].contains(positional.dropFirst().first ?? ""),
               word.range(of: #"^[\w.\-]+/[\w.\-]+$"#, options: .regularExpression) != nil
            {
                return .no("\(word) is another repo: heed's runs act on this item's repo only")
            }
        }
        if let why = ghRefusedGroups[group], !ghReads.contains(key) {
            return .no("gh \(group): \(why) is not allowed")
        }
        if key == "pr review" {
            return .no("a review is posted from heed's panel after you approve it, not by the agent")
        }
        if ghReads.contains(key) {
            if context.power >= .run, parsed.seen.contains("comments") || parsed.seen.contains("c") {
                return .no(
                    "comments are other people's words and are given to the agent in the prompt, fenced: gh \(key) "
                        + "--comments is not allowed in a run that writes or builds"
                )
            }
            return .yes
        }
        if ghWrites.contains(key) {
            guard context.power == .write else {
                return .no("\(context.verb.title) writes nothing to GitHub: gh \(key) is a write")
            }
            return .yes
        }
        if ["--version", "version"].contains(group) || parsed.seen.contains("version") { return .yes }
        return .no("gh \(key.isEmpty ? group : key) is not allowed in a Browse run")
    }

    /// `gh api`: a bare GET of one endpoint of this repo. Every flag that writes (`-X`, `-f`, `-F`, `--input`,
    /// `--method`, in any spelling) or aims elsewhere (`--hostname`) is one the parser does not know, and so refused.
    static func api(_ args: [String], _ context: Context) -> Verdict {
        let rest = Array(args.drop(while: { $0 != "api" }).dropFirst())
        let parsed = ghApiOptions.parse(rest, command: "gh api")
        if let refusal = parsed.refusal {
            return .no(
                "gh api writes and any flag heed does not know are not allowed: use gh issue and gh pr (\(refusal))"
            )
        }
        guard parsed.positionals.count == 1, let endpoint = parsed.positionals.first else {
            return .no(parsed.positionals.isEmpty ? "gh api without an endpoint" : "gh api takes one endpoint")
        }
        for (name, value, _) in parsed.values where ["q", "jq", "t", "template"].contains(name) {
            if value
                .range(of: #"\benv\b|\$ENV|\$__loc__|input_filename|\binput\b"#, options: .regularExpression) != nil
            {
                return .no("a gh api -q or -t that reads the environment or other input is not allowed")
            }
        }
        let clean = (endpoint.hasPrefix("/") ? String(endpoint.dropFirst()) : endpoint).lowercased()
        let path = clean.split(separator: "?", maxSplits: 1).first.map(String.init) ?? clean
        if path.contains("graphql") { return .no("gh api graphql is not allowed: use gh issue and gh pr") }
        let repo = "repos/\(context.repo.slug.lowercased())"
        guard path == repo || path.hasPrefix(repo + "/") else {
            return .no("gh api \(endpoint) is not under \(context.repo.slug)")
        }
        if path.split(separator: "/").contains("..") || path.contains("%2e") || path.contains("//") {
            return .no("gh api with .. is not allowed")
        }
        if path.hasSuffix("/reviews") || path.contains("/reviews/") {
            return .no("reviews are posted from heed's panel after you approve them: read them with gh pr view")
        }
        if context.power >= .run, path.hasSuffix("/comments") || path.contains("/comments/") {
            return .no(
                "comments are other people's words and are given to the agent in the prompt, fenced: gh api "
                    + "\(endpoint) is not allowed in a run that writes or builds"
            )
        }
        return .yes
    }
}
