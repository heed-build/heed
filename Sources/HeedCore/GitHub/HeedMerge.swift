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
        if settings.gateChecks.isEmpty {
            rule("Gate checks", .pass, "none named")
        } else {
            let failed = settings.gateChecks.filter { name in detail.failingChecks.contains { $0.name == name } }
            let passed = Set(detail.passedChecks ?? [])
            let missing = settings.gateChecks.filter { !passed.contains($0) && !failed.contains($0) }
            if !failed.isEmpty {
                rule("Gate checks", .fail, "\(failed.joined(separator: ", ")) failed")
            } else if !missing.isEmpty {
                rule("Gate checks", .wait, "\(missing.joined(separator: ", ")) not passed on \(short) yet")
            } else {
                rule("Gate checks", .pass, "\(settings.gateChecks.joined(separator: ", ")) passed")
            }
        }
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

    /// A review on the head commit: a human approval, or a trusted AI reviewer's. An AI reviewer counts when it
    /// approved, when it left a comment review none of whose threads is open, or when it left no review at all but its
    /// review check (one of `gate_checks`) passed on the head commit.
    static func reviewed(
        _ detail: PullDetail,
        settings: PilotSettings
    ) -> (state: GreenVerdict.Rule.State, text: String) {
        let head = detail.headSHA
        let short = String(head.prefix(7))
        let trusted = Set(settings.trustedReviewers.map { $0.lowercased() })
        let onHead = detail.reviews.filter { $0.commit == head }
        if let human = onHead.first(where: { $0.state == "APPROVED" && !trusted.contains($0.author.lowercased()) }) {
            return (.pass, "approved by @\(human.author) on \(short)")
        }
        for reviewer in settings.trustedReviewers {
            let theirs = onHead.filter { $0.author.lowercased() == reviewer.lowercased() }
            if theirs.contains(where: { $0.state == "APPROVED" }) {
                return (.pass, "approved by @\(reviewer) on \(short)")
            }
            let open = detail.threads.contains { !$0.isResolved && $0.author.lowercased() == reviewer.lowercased() }
            if theirs.contains(where: { $0.state == "COMMENTED" }), !open {
                return (.pass, "@\(reviewer) reviewed \(short) with nothing left open")
            }
            if theirs.isEmpty, !settings.gateChecks.isEmpty,
               Set(settings.gateChecks).isSubset(of: Set(detail.passedChecks ?? []))
            {
                return (.pass, "@\(reviewer)'s review check passed on \(short) without comments")
            }
        }
        if detail.reviews.contains(where: { $0.state == "APPROVED" }) {
            return (.wait, "approved before the last push; waiting for a review of \(short)")
        }
        return (.wait, "waiting for a review of \(short)")
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
