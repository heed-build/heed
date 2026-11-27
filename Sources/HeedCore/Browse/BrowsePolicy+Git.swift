import Foundation

extension BrowsePolicy {
    // MARK: git

    static let gitReads: Set<String> = [
        "status", "log", "diff", "show", "blame", "grep", "ls-files", "ls-tree", "rev-parse", "rev-list", "describe",
        "merge-base", "cat-file", "shortlog", "show-ref", "for-each-ref", "name-rev", "whatchanged", "reflog",
        "version", "count-objects", "check-ignore", "diff-tree", "diff-index", "range-diff", "cherry", "show-branch",
        "verify-commit", "check-attr",
    ]
    /// Subcommands that change the repo, for Fix and Implement; `branch`, `tag`, `stash`, `notes` only when they
    /// do more than list.
    static let gitLocalWrites: Set<String> = [
        "add", "rm", "mv", "commit", "restore", "reset", "merge", "rebase", "cherry-pick", "revert", "apply", "stash",
        "tag", "clean", "checkout", "switch", "pull", "branch", "bisect", "format-patch",
    ]
    private static let gitRefused: [String: String] = [
        "clone": "cloning another repo", "init": "making another repository",
        "submodule": "submodules reach other repos", "worktree": "worktrees are heed's",
        "filter-branch": "rewriting history", "filter-repo": "rewriting history", "update-ref": "moving refs by hand",
        "symbolic-ref": "moving refs by hand", "credential": "git's credentials", "daemon": "git daemon",
        "send-email": "sending email", "replace": "replacing objects", "hook": "hooks", "bundle": "bundles",
        "svn": "svn", "lfs": "lfs", "archive": "archives written outside the worktree", "write-tree": "plumbing",
        "commit-tree": "plumbing", "fast-import": "importing", "am": "applying mailboxes (it can run hooks)",
        "help": "man pages (they open a pager)", "instaweb": "a web server", "gui": "a window",
        "difftool": "external diff programs", "mergetool": "external merge programs", "web--browse": "a browser",
        "request-pull": "requests", "maintenance": "background jobs", "gc": "collecting garbage",
        "update-index": "plumbing", "sparse-checkout": "sparse checkouts", "notes": "notes",
    ]

    static func git(_ words: [String], _ context: Context, cwd: String) -> Verdict {
        var index = 1
        var cwd = cwd
        while index < words.count, words[index].hasPrefix("-") {
            let option = words[index]
            switch option {
            case "-C":
                guard index + 1 < words.count else { return .no("git -C without a folder") }
                let check = checkPath(words[index + 1], in: context, cwd: cwd, forWriting: false)
                guard check.allowed else { return check }
                cwd = folded(context.resolve(joined(words[index + 1], cwd: cwd)))
                index += 2
            case "--no-pager", "-P", "--no-optional-locks", "--no-replace-objects", "--literal-pathspecs",
                 "--glob-pathspecs", "--noglob-pathspecs", "--icase-pathspecs":
                index += 1
            case "-c":
                return .no("git -c can run commands through config: use git's own options")
            default:
                if option.hasPrefix("-c") || option.hasPrefix("--config-env") {
                    return .no("git -c can run commands through config: use git's own options")
                }
                return .no("git \(option) before the command points git elsewhere or opens a pager: not allowed")
            }
        }
        guard index < words.count else { return .yes }
        let sub = words[index]
        let args = Array(words.dropFirst(index + 1))
        if let why = gitRefused[sub] { return .no("git \(sub): \(why) is not allowed") }
        switch sub {
        case "push": return push(args, context, cwd: cwd)
        case "remote": return remote(args)
        case "config": return gitConfig(args)
        case "fetch": return fetch(args, context, cwd: cwd)
        case "ls-remote": return lsRemote(args, context, cwd: cwd)
        default: break
        }
        if listsOnly(sub, args, context, cwd: cwd) { return .yes }
        if gitReads.contains(sub) {
            if sub == "reflog", ["expire", "delete"].contains(args.first ?? "") {
                return .no("git reflog \(args[0]) changes the reflog")
            }
            return checkParsed(readOptions.parse(args, command: "git \(sub)"), context, cwd: cwd)
        }
        if sub == "bisect", !["start", "good", "bad", "new", "old", "reset", "skip", "log", "terms"]
            .contains(args.first ?? "")
        {
            return .no("git bisect \(args.first ?? "") is not allowed: `bisect run` runs a command")
        }
        guard gitLocalWrites.contains(sub), let spec = writeOptions[sub] else {
            return .no("git \(sub) is not one heed knows to allow")
        }
        guard context.power == .write else {
            return .no("\(context.verb.title) changes no commits or branches: git \(sub) is a change")
        }
        let parsed = spec.parse(args, command: "git \(sub)")
        let check = checkParsed(
            parsed, context, cwd: cwd, forWriting: false, positionalsAreText: ["commit", "tag", "stash"].contains(sub)
        )
        guard check.allowed else { return check }
        switch sub {
        case "checkout", "switch", "branch", "reset", "merge", "rebase", "cherry-pick":
            // Work stays off the branches a push would publish, as a name or as the value of -b and -c.
            let named = parsed.positionals + parsed.values.filter { $0.kind == .text }.map(\.value)
            if sub == "checkout" || sub == "switch" || sub == "branch" {
                if let bad = named.first(where: { isLocalDefault($0, context) }) {
                    return .no("work stays off \(bad): git \(sub) \(bad) is not allowed, branch from it instead")
                }
            }
        case "tag":
            break
        case "pull":
            if let first = parsed.positionals.first, first != "origin" {
                return .no("\(first) is another repository: only this repo's origin is allowed")
            }
        default: break
        }
        return .yes
    }

    // MARK: Option tables

    static let readOptions: Options = {
        var spec = Options()
        spec.flags = "abcdeghiklmnpqrstuvwxzABCDEFGHIKLMNPRSTUVWZL0123456789"
        spec.longs = [
            "oneline", "shortstat", "numstat", "name-only", "name-status", "summary", "patch", "no-patch",
            "patch-with-stat", "graph", "no-decorate", "abbrev-commit", "no-abbrev-commit", "all-match", "invert-grep",
            "regexp-ignore-case", "extended-regexp", "fixed-strings", "perl-regexp", "first-parent", "merges",
            "no-merges", "reverse", "follow", "full-history", "simplify-merges", "ancestry-path", "branches", "tags",
            "remotes", "all", "no-color", "color-words", "function-context", "ignore-space-change",
            "ignore-all-space", "ignore-space-at-eol", "ignore-blank-lines", "minimal", "patience", "histogram",
            "find-copies-harder", "cached", "staged", "merge-base", "raw", "root", "no-renames", "check", "count",
            "line-number", "files-with-matches", "files-without-match", "untracked", "word-regexp", "invert-match",
            "ignore-case", "text", "null", "heading", "break", "show-function", "only-matching", "quiet", "and", "or",
            "not", "exclude-standard", "no-recursive", "recursive", "full-name", "deleted", "modified", "others",
            "ignored", "stage", "unmerged", "killed", "error-unmatch", "deduplicate", "eol", "short", "long",
            "porcelain", "branch", "ahead-behind", "no-ahead-behind", "verbose", "show-signature", "no-walk",
            "boundary", "left-right", "left-only", "right-only", "cherry-pick", "cherry-mark", "cherry", "topo-order",
            "date-order", "author-date-order", "parents", "children", "no-abbrev", "list", "show-current", "heads",
            "symbolic-full-name", "verify", "show-toplevel", "show-prefix", "is-inside-work-tree", "abbrev-ref",
            "always", "dirty", "exact-match", "long", "no-ext-diff", "no-textconv", "tabs", "name", "refs",
            "first-parent", "show-origin", "numbered", "no-pager", "no-merges", "simplify-by-decoration",
            "sparse", "exclude", "git-dir", "absolute-git-dir", "git-common-dir", "show-cdup", "end-of-options",
            "no-index-unused",
        ]
        spec.longValues = [
            "format": .text, "pretty": .text, "author": .text, "committer": .text, "grep": .text, "since": .text,
            "until": .text, "after": .text, "before": .text, "max-count": .text, "skip": .text, "diff-filter": .text,
            "diff-algorithm": .text, "max-depth": .text, "context": .text, "after-context": .text,
            "before-context": .text, "threads": .text, "min-parents": .text, "max-parents": .text, "sort": .text,
            "points-at": .text, "stat-width": .text, "stat-name-width": .text, "date": .text, "abbrev-len": .text,
            "glob": .text, "tags-pattern": .text, "match": .text, "rev": .text, "contains-rev": .text,
        ]
        spec.longOptional = [
            "stat", "color", "abbrev", "decorate", "word-diff", "relative", "find-renames", "find-copies", "contains",
            "no-contains", "merged", "no-merged", "unified", "ignore-submodules", "untracked-files", "no-color-moved",
            "color-moved", "word-diff-regex", "dirstat",
        ]
        return spec
    }()

    private static func table(
        flags: String = "", shortValues: [Character: Options.Value] = [:], longs: Set<String> = [],
        longValues: [String: Options.Value] = [:], longOptional: Set<String> = []
    ) -> Options {
        var spec = Options()
        spec.flags = flags
        spec.shortValues = shortValues
        spec.longs = longs
        spec.longValues = longValues
        spec.longOptional = longOptional
        return spec
    }

    static let writeOptions: [String: Options] = [
        "add": table(
            flags: "Auvn",
            longs: [
                "all",
                "update",
                "verbose",
                "dry-run",
                "intent-to-add",
                "ignore-errors",
                "renormalize",
                "sparse",
                "no-warn-embedded-repo",
                "ignore-missing",
                "refresh",
                "no-ignore-removal",
            ],
            longValues: ["chmod": .text]
        ),
        "rm": table(
            flags: "rnqf",
            longs: ["cached", "force", "dry-run", "quiet", "recursive", "ignore-unmatch", "sparse"]
        ),
        "mv": table(flags: "fkvn", longs: ["force", "verbose", "dry-run"]),
        "commit": table(
            flags: "aqsv", shortValues: ["m": .text, "F": .read, "C": .text],
            longs: [
                "all",
                "amend",
                "no-edit",
                "allow-empty",
                "allow-empty-message",
                "signoff",
                "no-signoff",
                "quiet",
                "verbose",
                "only",
                "include",
                "dry-run",
                "short",
                "porcelain",
                "reset-author",
                "no-status",
                "no-gpg-sign",
            ],
            longValues: [
                "message": .text,
                "file": .read,
                "author": .text,
                "date": .text,
                "reuse-message": .text,
                "fixup": .text,
                "squash": .text,
                "cleanup": .text,
                "trailer": .text,
            ],
            longOptional: ["untracked-files", "gpg-sign"]
        ),
        "restore": table(
            flags: "SWq", shortValues: ["s": .text],
            longs: [
                "staged",
                "worktree",
                "quiet",
                "overlay",
                "no-overlay",
                "ignore-unmerged",
                "ours",
                "theirs",
                "merge",
                "ignore-skip-worktree-bits",
            ],
            longValues: ["source": .text]
        ),
        "reset": table(flags: "q", longs: ["hard", "soft", "mixed", "keep", "merge", "quiet", "no-refresh", "refresh"]),
        "merge": table(
            flags: "qv", shortValues: ["m": .text, "s": .text, "X": .text],
            longs: [
                "no-ff",
                "ff",
                "ff-only",
                "squash",
                "no-squash",
                "no-commit",
                "commit",
                "abort",
                "continue",
                "quiet",
                "verbose",
                "no-edit",
                "autostash",
                "no-autostash",
                "signoff",
                "no-signoff",
                "log",
                "no-log",
                "stat",
                "no-stat",
                "allow-unrelated-histories",
                "quit",
            ],
            longValues: ["message": .text, "strategy": .text, "strategy-option": .text, "file": .read]
        ),
        "rebase": table(
            flags: "qv", shortValues: ["s": .text, "X": .text],
            longs: [
                "continue",
                "abort",
                "skip",
                "quit",
                "autostash",
                "no-autostash",
                "keep-empty",
                "no-keep-empty",
                "root",
                "quiet",
                "verbose",
                "no-stat",
                "stat",
                "fork-point",
                "no-fork-point",
                "committer-date-is-author-date",
                "reapply-cherry-picks",
                "no-reapply-cherry-picks",
                "update-refs",
                "no-update-refs",
                "ff",
                "no-ff",
                "force-rebase",
                "signoff",
                "ignore-date",
            ],
            longValues: ["onto": .text, "strategy": .text, "strategy-option": .text, "empty": .text],
            longOptional: ["rebase-merges"]
        ),
        "cherry-pick": table(
            flags: "nxs", shortValues: ["m": .text, "X": .text],
            longs: [
                "continue",
                "abort",
                "quit",
                "skip",
                "no-commit",
                "signoff",
                "ff",
                "allow-empty",
                "keep-redundant-commits",
                "allow-empty-message",
            ],
            longValues: ["mainline": .text, "strategy": .text, "strategy-option": .text]
        ),
        "revert": table(
            flags: "ns", shortValues: ["m": .text, "X": .text],
            longs: ["no-commit", "no-edit", "continue", "abort", "quit", "skip", "signoff"],
            longValues: ["mainline": .text, "strategy": .text, "strategy-option": .text]
        ),
        "stash": table(
            flags: "uqkaS", shortValues: ["m": .text],
            longs: ["include-untracked", "keep-index", "no-keep-index", "quiet", "all", "staged", "index"],
            longValues: ["message": .text]
        ),
        "tag": table(
            flags: "adflv", shortValues: ["m": .text, "F": .read],
            longs: ["annotate", "delete", "force", "list", "contains-unused"],
            longValues: ["message": .text, "file": .read, "sort": .text, "points-at": .text, "format": .text],
            longOptional: ["contains", "merged", "no-merged"]
        ),
        "clean": table(flags: "fndxXq", longs: ["force", "dry-run", "quiet"]),
        "checkout": table(
            flags: "qfmt", shortValues: ["b": .text, "B": .text],
            longs: [
                "force",
                "quiet",
                "detach",
                "track",
                "no-track",
                "merge",
                "ours",
                "theirs",
                "no-guess",
                "guess",
                "ignore-other-worktrees",
                "overlay",
                "no-overlay",
            ],
            longValues: ["conflict": .text]
        ),
        "switch": table(
            flags: "qfmt", shortValues: ["c": .text, "C": .text],
            longs: [
                "detach",
                "discard-changes",
                "force",
                "merge",
                "quiet",
                "track",
                "no-track",
                "guess",
                "no-guess",
                "ignore-other-worktrees",
            ],
            longValues: ["create": .text, "force-create": .text, "orphan": .text]
        ),
        "pull": table(
            flags: "qvr",
            longs: [
                "ff-only",
                "ff",
                "no-ff",
                "rebase",
                "no-rebase",
                "autostash",
                "no-autostash",
                "no-edit",
                "no-commit",
                "quiet",
                "verbose",
                "squash",
                "no-tags",
            ]
        ),
        "apply": table(
            flags: "Rv3n", shortValues: ["p": .text, "C": .text],
            longs: [
                "check",
                "stat",
                "numstat",
                "summary",
                "reverse",
                "3way",
                "index",
                "cached",
                "quiet",
                "verbose",
                "ignore-space-change",
                "ignore-whitespace",
                "unidiff-zero",
            ],
            longValues: ["whitespace": .text]
        ),
        "format-patch": table(
            flags: "nNqs",
            longs: [
                "stdout",
                "cover-letter",
                "numbered",
                "no-numbered",
                "signoff",
                "no-signoff",
                "quiet",
                "no-stat",
                "stat",
                "patch",
                "no-patch",
                "no-binary",
                "binary",
                "full-index",
                "minimal",
                "histogram",
                "patience",
            ]
        ),
        "branch": table(
            flags: "adDfmMlvarcC", shortValues: ["u": .text],
            longs: [
                "delete",
                "force",
                "move",
                "copy",
                "list",
                "all",
                "remotes",
                "verbose",
                "show-current",
                "unset-upstream",
                "no-track",
                "track",
            ],
            longValues: ["set-upstream-to": .text, "sort": .text, "format": .text, "points-at": .text],
            longOptional: ["merged", "no-merged", "contains", "no-contains", "color", "abbrev", "column"]
        ),
        "bisect": table(),
    ]

    /// `git branch`, `git tag`, `git stash list`, `git bisect log`: the forms that only look.
    private static func listsOnly(_ sub: String, _ args: [String], _ context: Context, cwd: String) -> Bool {
        let listing: Set<String> = [
            "list",
            "l",
            "merged",
            "no-merged",
            "contains",
            "no-contains",
            "show-current",
            "a",
            "r",
            "v",
            "all",
            "remotes",
            "verbose",
            "points-at",
        ]
        switch sub {
        case "branch", "tag":
            guard let spec = writeOptions[sub] else { return false }
            let parsed = spec.parse(args, command: "git \(sub)")
            guard parsed.refusal == nil, checkParsed(parsed, context, cwd: cwd).allowed else { return false }
            let acts = parsed.seen.subtracting(listing)
                .subtracting(["color", "abbrev", "column", "sort", "format", "vv", "n"])
            if !acts.isEmpty { return false }
            return parsed.positionals.isEmpty || !parsed.seen.isDisjoint(with: listing)
        case "stash": return ["list", "show"].contains(args.first ?? "")
        case "bisect": return ["log", "terms"].contains(args.first ?? "")
        default: return false
        }
    }

    // MARK: remote, config, fetch

    private static func remote(_ args: [String]) -> Verdict {
        if args.isEmpty || args == ["-v"] { return .yes }
        if ["show", "get-url"].contains(args[0]), args.count == 1 || (args.count == 2 && args[1] == "origin") {
            return .yes
        }
        return .no("changing remotes is not allowed")
    }

    /// `git config` reads of one key or of the local list; nothing else, and no other file than the repo's own.
    private static func gitConfig(_ args: [String]) -> Verdict {
        let readers: Set<String> = ["--get", "--get-all", "--get-regexp"]
        let lists: Set<String> = ["--list", "-l"]
        let extras: Set<String> = ["--local", "--show-origin", "--name-only", "-z", "--null"]
        let rest = args.filter { !extras.contains($0) }
        let key = #"^[A-Za-z0-9][A-Za-z0-9.\-_*+\\]*$"#
        if rest.count == 2, readers.contains(rest[0]), rest[1].range(of: key, options: .regularExpression) != nil {
            return .yes
        }
        if rest.count == 1, lists.contains(rest[0]) { return .yes }
        // `git config user.name`: one key and nothing to set it to is a read.
        if rest.count == 1, rest[0].range(of: key, options: .regularExpression) != nil,
           rest[0].contains(".") { return .yes }
        if args
            .contains(where: {
                $0 == "--file" || $0 == "-f" || $0.hasPrefix("--file=") || $0 == "--global" || $0 == "--system"
            })
        {
            return .no("git config --file, --global and --system read files outside this repo")
        }
        return .no("changing git's config, or reading more than one key, is not allowed")
    }

    private static func fetch(_ args: [String], _: Context, cwd _: String) -> Verdict {
        let spec = table(
            flags: "qv", longs: ["quiet", "verbose", "tags", "no-tags", "unshallow-unused", "no-recurse-submodules"],
            longValues: ["depth": .text]
        )
        let parsed = spec.parse(args, command: "git fetch")
        if let refusal = parsed.refusal { return .no(refusal) }
        return remoteWords(parsed.positionals, command: "git fetch")
    }

    private static func lsRemote(_ args: [String], _: Context, cwd _: String) -> Verdict {
        let spec = table(flags: "q", longs: ["heads", "tags", "refs", "quiet"])
        let parsed = spec.parse(args, command: "git ls-remote")
        if let refusal = parsed.refusal { return .no(refusal) }
        return remoteWords(parsed.positionals, command: "git ls-remote")
    }

    /// `origin` and the plain names after it: no other remote, no URL, no refspec that moves a ref by hand.
    private static func remoteWords(_ words: [String], command: String) -> Verdict {
        guard let remote = words.first else { return .yes }
        guard remote == "origin"
        else { return .no("\(remote) is another repository: only this repo's origin is allowed") }
        for refspec in words.dropFirst() {
            if refspec.hasPrefix("+") || refspec.contains(":") || refspec.hasPrefix("-") {
                return .no("\(command) \(refspec): name the branch only, with no + and no destination")
            }
        }
        return .yes
    }

    // MARK: push

    static func push(_ args: [String], _ context: Context, cwd: String) -> Verdict {
        guard context.power == .write else { return .no("\(context.verb.title) pushes nothing") }
        guard context.canPush else {
            return .no("this pull request is from a fork, so heed cannot push to its branch: say so instead")
        }
        for arg in args where arg.lowercased().contains("force") || arg == "-d" || arg.lowercased().contains("delete")
            || arg == "--mirror" || arg == "--all" || arg == "--prune"
        {
            return .no(
                "git push \(arg) is never allowed: no force-push, no deleting remote branches, no whole-repo pushes"
            )
        }
        let spec = table(
            flags: "uqvn", longs: [
                "set-upstream",
                "quiet",
                "verbose",
                "porcelain",
                "progress",
                "no-progress",
                "dry-run",
            ]
        )
        let parsed = spec.parse(args, command: "git push")
        if let refusal = parsed.refusal {
            return .no(refusal + ": a push is `git push -u origin HEAD` or `git push origin HEAD:<branch>`")
        }
        let words = parsed.positionals
        guard words.count >= 2, words[0] == "origin" else {
            return .no("name the branch and the remote: `git push -u origin HEAD` or `git push origin HEAD:<branch>`")
        }
        for refspec in words.dropFirst() {
            let verdict = pushRefspec(refspec, context, cwd: cwd)
            if !verdict.allowed { return verdict }
        }
        guard let guardian = context.pushGuard, let changed = guardian.changedFiles(in: context.worktree) else {
            return .no("heed could not look at what this push would publish, so it does not push")
        }
        for file in changed {
            let parts = file.split(separator: "/").map { $0.lowercased() }
            if protectedWrite(parts) != nil {
                return .no(
                    "this push changes \(file), a file that runs code or sets up tools (CI, hooks, build scripts, agent "
                        + "settings): heed does not push it. Drop that change, say in your final message what it should be, "
                        + "and the user will make it by hand"
                )
            }
        }
        return .yes
    }

    private static let branchName = #"^[A-Za-z0-9._@+\-][A-Za-z0-9._/@+\-]*$"#

    private static func pushRefspec(_ refspec: String, _ context: Context, cwd _: String) -> Verdict {
        if refspec.hasPrefix("+") { return .no("a forced refspec (+) is never allowed") }
        if refspec.hasPrefix(":") { return .no("pushing an empty source deletes a remote branch: never allowed") }
        let sides = refspec.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        guard sides.count <= 2 else { return .no("\(refspec) is not a refspec heed understands") }
        let source = sides[0]
        // The source is HEAD, this run's own branch, or a local branch by its full name: not a tag, not another ref.
        guard source == "HEAD" || source == context.branch || source.hasPrefix("refs/heads/") else {
            return .no(
                "push `HEAD` or this run's branch (\(context.branch ?? "its own")), not \(source): it may be a tag or another ref"
            )
        }
        var destination = sides.count == 2 ? sides[1] : source
        if sides.count == 1, source == "HEAD" {
            guard let current = context.pushGuard?.currentBranch(in: context.worktree), current != "HEAD" else {
                return .no("heed could not tell which branch HEAD is on, so it does not push it")
            }
            destination = current
        }
        if destination.hasPrefix("refs/heads/") { destination = String(destination.dropFirst("refs/heads/".count)) }
        if destination.hasPrefix("refs/") || destination.isEmpty || destination == "HEAD" {
            return .no("pushing \(destination.isEmpty ? refspec : destination) is not allowed: only branches")
        }
        guard destination.range(of: branchName, options: .regularExpression) != nil, !destination.contains("..") else {
            return .no("\(destination) is not a branch name heed allows")
        }
        if protectedBranch(destination, context) {
            return .no(
                "pushing \(destination) is never allowed: the work goes on a branch, and a pull request merges it"
            )
        }
        return .yes
    }
}
