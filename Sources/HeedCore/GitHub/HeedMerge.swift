import Foundation

/// `merge = "heed"`: the rules a PR meets before heed merges it itself, checked again just before it does. The same
/// shape as the green verdict, so the Watch view lists them the same way.
public enum HeedMerge {
    public static func verdict(
        _ detail: PullDetail, settings: PilotSettings, selfReview: SelfReview?, now: Date
    ) -> GreenVerdict {
        var rules: [GreenVerdict.Rule] = []
        func rule(_ name: String, _ state: GreenVerdict.Rule.State, _ text: String) {
            rules.append(GreenVerdict.Rule(name: name, state: state, detail: text))
        }
        let short = String(detail.headSHA.prefix(7))
        if let blocker = GreenVerdict.of(detail).blocker {
            rule("Green", blocker.state, "\(blocker.name.lowercased()): \(blocker.detail)")
        } else {
            rule("Green", .pass, "every green rule holds")
        }
        let author = author(detail, settings: settings)
        rule("Author", author.trusted ? .pass : .fail, author.text)
        let review = reviewed(detail, settings: settings)
        rule("Reviewed after push", review.state, review.text)
        let last = ([detail.headCommittedAt] + detail.reviews.map(\.submittedAt)).compactMap(\.self).max()
        let quiet = TimeInterval(settings.quietMinutes * 60)
        if let last, now.timeIntervalSince(last) < quiet {
            rule("Quiet", .wait, "quiet for \(PilotDuration.text(quiet - now.timeIntervalSince(last))) more")
        } else {
            rule(
                "Quiet",
                .pass,
                settings.quietMinutes == 0 ? "no quiet window" : "nothing new for \(settings.quietMinutes)m"
            )
        }
        let gates = gateChecks(detail, settings: settings)
        rule("Gate checks", gates.state, gates.text)
        let holds = Set(settings.holdLabels.map { $0.lowercased() })
        if let label = (detail.labels ?? []).first(where: { holds.contains($0.lowercased()) }) {
            rule("No hold label", .fail, "labelled \(label)")
        } else {
            rule("No hold label", .pass, "none")
        }
        if settings.selfReview != nil {
            if let selfReview, selfReview.sha == detail.headSHA {
                rule(
                    "Self-review",
                    selfReview.approved ? .pass : .fail,
                    selfReview.approved ? "approved" : selfReview.summary
                )
            } else {
                rule("Self-review", .wait, "not run on \(short) yet")
            }
        }
        return GreenVerdict(rules: rules)
    }

    /// Whether heed merges this PR on its own: its author is the repo's owner or a collaborator (people who can write
    /// to it), or one of `trusted_authors`. Anyone else's PR is merged by hand (`zM`) only.
    public static func author(
        _ detail: PullDetail, settings: PilotSettings
    ) -> (trusted: Bool, text: String) {
        let who = detail.author.map { "@" + $0 } ?? "someone"
        switch detail.authorTrust {
        case .owner: return (true, "opened by \(who), the repo's owner")
        case .collaborator: return (true, "opened by \(who), who can write to the repo")
        case .bot, .stranger:
            let isBot = detail.authorTrust == .bot
            if let login = detail.author,
               settings.trustedAuthors.contains(where: { listed($0, login: login, isBot: isBot) })
            {
                return (true, "opened by \(who), one of trusted_authors")
            }
            let why = isBot ? "\(who) isn't in trusted_authors" : "\(who) isn't a collaborator"
            return (false, "\(why): heed doesn't merge it on its own; merge it by hand (zM)")
        }
    }

    /// Whether `entry` (from `trusted_reviewers` or `trusted_authors`) names `login`: compared without case and
    /// GitHub's `[bot]` suffix, and an entry ending in `[bot]` names only a bot.
    public static func listed(_ entry: String, login: String, isBot: Bool) -> Bool {
        if entry.lowercased().hasSuffix("[bot]"), !isBot { return false }
        return GateCheck.normalize(entry) == GateCheck.normalize(login)
    }

    /// `gate_checks`, each from its app (`GateCheck`). On a PR heed would not merge on its own (see `author`) none
    /// counts: its checks run what the PR itself changes.
    static func gateChecks(
        _ detail: PullDetail, settings: PilotSettings
    ) -> (state: GreenVerdict.Rule.State, text: String) {
        guard !settings.gateChecks.isEmpty else { return (.pass, "none named") }
        let short = String(detail.headSHA.prefix(7))
        guard author(detail, settings: settings).trusted else {
            return (.fail, "not counted on a PR heed doesn't merge on its own (see Author)")
        }
        var failed: [String] = []
        var missing: [String] = []
        var passed: [String] = []
        for gate in settings.gateChecks.map(GateCheck.init) {
            switch gate.state(on: detail) {
            case .failed: failed.append(gate.entry)
            case .missing:
                let apps = gate.apps(on: detail).sorted().joined(separator: " or ")
                missing.append("\(gate.name) (from \(apps))")
            case let .passed(app): passed.append("\(gate.name) (\(app))")
            }
        }
        if !failed.isEmpty { return (.fail, "\(failed.joined(separator: ", ")) failed") }
        if !missing.isEmpty { return (.wait, "\(missing.joined(separator: ", ")) not passed on \(short) yet") }
        return (.pass, "\(passed.joined(separator: ", ")) passed")
    }

    /// A review on the head commit: an approval from someone who can write to the repo, or a trusted reviewer's
    /// (`trusted_reviewers`). A trusted reviewer counts when it approved, when it left a comment review none of whose
    /// threads is open, or when it left no review at all but every gate check passed on the head commit (its review
    /// check among them). Anyone else's approval is shown and does not count.
    static func reviewed(
        _ detail: PullDetail,
        settings: PilotSettings
    ) -> (state: GreenVerdict.Rule.State, text: String) {
        let head = detail.headSHA
        let short = String(head.prefix(7))
        let onHead = detail.reviews.filter { $0.commit == head }
        func trusted(_ review: PullDetail.Review) -> Bool {
            settings.trustedReviewers.contains { listed($0, login: review.author, isBot: review.trust == .bot) }
        }
        let approvals = onHead.filter { $0.state == "APPROVED" }
        if let approval = approvals.first(where: { $0.trust.isCollaborator || trusted($0) }) {
            return (.pass, "approved by @\(approval.author) on \(short)")
        }
        for reviewer in settings.trustedReviewers {
            let theirs = onHead.filter { listed(reviewer, login: $0.author, isBot: $0.trust == .bot) }
            let open = detail.threads.contains { thread in
                !thread.isResolved && listed(reviewer, login: thread.author, isBot: thread.trust == .bot)
            }
            if theirs.contains(where: { $0.state == "COMMENTED" }), !open {
                return (.pass, "@\(theirs[0].author) reviewed \(short) with nothing left open")
            }
            if theirs.isEmpty, !settings.gateChecks.isEmpty, gateChecks(detail, settings: settings).state == .pass {
                return (.pass, "@\(reviewer)'s review check passed on \(short) without comments")
            }
        }
        if let outside = approvals.first {
            let why = outside.trust == .bot ? "isn't in trusted_reviewers" : "isn't a collaborator"
            return (.wait, "@\(outside.author) approved \(short), but \(why)")
        }
        if detail.reviews.contains(where: { $0.state == "APPROVED" && ($0.trust.isCollaborator || trusted($0)) }) {
            return (.wait, "approved before the last push; waiting for a review of \(short)")
        }
        return (.wait, "waiting for a review of \(short)")
    }

    /// What heed does with a PR when it comes to merge it: the rules are checked again on the detail it merges, and
    /// any that no longer holds (the author's or a reviewer's trust among them) holds the PR. `--admin` on a refused
    /// merge is offered only with `admin_merge` and a verdict that held.
    public enum Attempt: Hashable, Sendable {
        case hold(String)
        case merge(adminRetry: Bool)
    }

    public static func attempt(_ verdict: GreenVerdict, adminMerge: Bool) -> Attempt {
        if let blocker = verdict.blocker { return .hold("\(blocker.name): \(blocker.detail)") }
        return .merge(adminRetry: adminMerge && verdict.isGreen)
    }

    /// The comment heed leaves on a PR it merged: each rule and what it found.
    public static func comment(_ verdict: GreenVerdict, method: String) -> String {
        "Merged by [heed](https://heed.build) (\(method)) because every merge rule held:\n\n"
            + verdict.rules.map { "- **\($0.name)**: \($0.detail)" }.joined(separator: "\n")
    }
}

/// What the self-review command said about one head commit.
public struct SelfReview: Hashable, Sendable, Codable {
    public let sha: String
    public let approved: Bool
    /// Its reason, or the first lines of its answer.
    public let summary: String
    public let at: Date

    public init(sha: String, approved: Bool, summary: String, at: Date) {
        self.sha = sha
        self.approved = approved
        self.summary = summary
        self.at = at
    }

    /// The prompt, then the diff, on the command's stdin. `instructions` (the repo's `review_instructions`) add to
    /// what to look for; the answer's first line stays APPROVE or REQUEST_CHANGES, which heed reads.
    /// The diff is the PR author's, fenced like the description.
    public static func prompt(_ detail: PullDetail, diff: String, instructions: String = "") -> Prompt {
        let limit = 200_000
        let cut = diff.count > limit ? String(diff.prefix(limit)) + "\n[diff cut at \(limit) characters]" : diff
        let by = detail.body.author
        return """
        You are reviewing a pull request just before it is merged. Read its description and diff. Answer with APPROVE \
        alone on the first line when it is safe to merge, or REQUEST_CHANGES: <the reason, in one line> when it is \
        not. \
        Look for bugs, missing tests, leftover debugging and anything the description promises that the diff does \
        not do.\(instructions.isEmpty ? "" : "\n\n\(owner: instructions)")

        PR #\(detail.ref.number): \(detail.title)

        \(detail.body)

        \(ExternalText(cut, source: .diff, author: by))
        """
    }

    /// Runs the `self_review` command with the prompt on stdin (through the shell, so `claude -p` and pipes work),
    /// with the PATH tool detection found, in an empty folder of its own, with its agent's tools off (`noTools`), for
    /// up to ten minutes.
    public static func run(_ command: String, prompt: Prompt) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("heed-self-review-\(UUID().uuidString)", isDirectory: true)
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("prompt.txt")
        try prompt.text.write(to: file, atomically: true, encoding: .utf8)
        let tool = String(command.split(separator: " ").first ?? "")
        let path = await ToolLocator.shared.executable(tool).pathVariable
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "\(noTools(command)) < \(ShellQuote.quote(file.path))"], in: work.path,
            environment: ["PATH": path], timeout: .seconds(600), caller: "merge.command"
        )
        guard result.succeeded else {
            throw ProcessError(command: command, result: result, reason: "exit \(result.status)")
        }
        return result.stdout
    }

    /// The command with its agent's tools turned off, the flags `LLMDialect` uses for the same agent, right after the
    /// executable: `claude` gets `--tools '' --strict-mcp-config`, `pi` `--no-tools --no-extensions --no-mcp`. A
    /// command that names its tools itself, and any other command, runs as written.
    public static func noTools(_ command: String) -> String {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        let space = trimmed.firstIndex(of: " ") ?? trimmed.endIndex
        let executable = String(trimmed[..<space])
        let rest = String(trimmed[space...])
        let flags: String
        switch (executable as NSString).lastPathComponent {
        case "claude":
            guard !rest.contains("--tools") else { return command }
            flags = " --tools '' --strict-mcp-config"
        case "pi":
            guard !rest.contains("--no-tools"), !rest.contains("--tools") else { return command }
            flags = " --no-tools --no-extensions --no-mcp"
        default:
            return command
        }
        return executable + flags + rest
    }

    /// The first non-empty line, markdown emphasis and headings trimmed, is the verdict: exactly `APPROVE` approves,
    /// `REQUEST_CHANGES: <why>` refuses with its reason, and anything else is a refusal too, saying what it was.
    public static func parse(_ output: String, sha: String, at: Date) -> SelfReview {
        let lines = output.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let first = lines.first ?? ""
        let markdown = CharacterSet(charactersIn: "*`#_>").union(.whitespaces)
        let word = first.trimmingCharacters(in: markdown)
        if word == "APPROVE" {
            return SelfReview(sha: sha, approved: true, summary: "approved", at: at)
        }
        let reason: String
        if word.hasPrefix("REQUEST_CHANGES") {
            let after = word.dropFirst("REQUEST_CHANGES".count).trimmingCharacters(in: markdown)
            let text = after.hasPrefix(":") ? String(after.dropFirst()).trimmingCharacters(in: markdown) : after
            reason = text.isEmpty ? "changes requested, no reason given" : text
        } else if first.isEmpty {
            reason = "no answer"
        } else {
            reason = "the answer did not start with APPROVE or REQUEST_CHANGES: \(first)"
        }
        return SelfReview(sha: sha, approved: false, summary: String(reason.prefix(300)), at: at)
    }
}
