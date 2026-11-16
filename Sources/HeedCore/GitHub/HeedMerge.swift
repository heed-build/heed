import Foundation

/// `merge = "heed"`: the rules a PR meets before heed merges it itself, checked again just before it does. The same
/// shape as the green verdict, so the Watch view lists them the same way.
public enum HeedMerge {
    /// `viewer` is your login: a PR of yours is trusted from any branch (`PullTrust`).
    public static func verdict(
        _ detail: PullDetail, settings: PilotSettings, selfReview: SelfReview?, now: Date, viewer: String? = nil
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
        let author = author(detail, settings: settings, viewer: viewer)
        rule("Author", author.trusted ? .pass : .fail, author.text)
        let review = reviewed(detail, settings: settings, viewer: viewer)
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
        let gates = gateChecks(detail, settings: settings, viewer: viewer)
        rule("Gate checks", gates.state, gates.text)
        let holds = Set(settings.holdLabels.map { $0.lowercased() })
        if let label = (detail.labels ?? []).first(where: { holds.contains($0.lowercased()) }) {
            rule("No hold label", .fail, "labelled \(label)")
        } else {
            rule("No hold label", .pass, "none")
        }
        if let command = settings.selfReview {
            if case let .refused(reason) = SelfReview.toolless(command) {
                rule("Self-review", .fail, "not run: \(reason)")
            } else if let selfReview, selfReview.sha == detail.headSHA {
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

    /// Whether heed merges this PR on its own: `PullTrust.author`, the same rule heed's runs follow. Yours; or, on a
    /// branch of the repo, opened by someone who can write to it or by one of `trusted_authors`. Anyone else's PR,
    /// and any PR from a fork but yours, is merged by hand (`zM`) only.
    public static func author(
        _ detail: PullDetail, settings: PilotSettings, viewer: String? = nil
    ) -> (trusted: Bool, text: String) {
        let trust = detail.authorTrust
        let verdict = PullTrust.author(
            login: detail.author, trust: trust, fork: detail.crossRepository, viewer: viewer,
            canWrite: trust == .member ? detail.author.flatMap { login in
                detail.writers.map { $0.contains(login.lowercased()) }
            } : nil,
            trustedAuthors: settings.trustedAuthors
        )
        return (verdict.trusted, verdict.text)
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
        _ detail: PullDetail, settings: PilotSettings, viewer: String? = nil
    ) -> (state: GreenVerdict.Rule.State, text: String) {
        guard !settings.gateChecks.isEmpty else { return (.pass, "none named") }
        let short = String(detail.headSHA.prefix(7))
        guard author(detail, settings: settings, viewer: viewer).trusted else {
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

    /// A review on the head commit: an approval from someone who can write to the repo (`PullTrust.canWrite`: an
    /// organisation member counts only once `gh` said they can), or a trusted reviewer's (`trusted_reviewers`). A
    /// trusted reviewer counts when it approved, when it left a comment review none of whose
    /// threads is open, or when it left no review at all but every gate check passed on the head commit (its review
    /// check among them). Anyone else's approval is shown and does not count.
    static func reviewed(
        _ detail: PullDetail,
        settings: PilotSettings,
        viewer: String? = nil
    ) -> (state: GreenVerdict.Rule.State, text: String) {
        let head = detail.headSHA
        let short = String(head.prefix(7))
        let onHead = detail.reviews.filter { $0.commit == head }
        func trusted(_ review: PullDetail.Review) -> Bool {
            settings.trustedReviewers.contains { listed($0, login: review.author, isBot: review.trust == .bot) }
        }
        func counts(_ review: PullDetail.Review) -> Bool {
            detail.canWrite(review.author, trust: review.trust) || trusted(review)
        }
        let approvals = onHead.filter { $0.state == "APPROVED" }
        if let approval = approvals.first(where: counts) {
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
            if theirs.isEmpty, !settings.gateChecks.isEmpty,
               gateChecks(detail, settings: settings, viewer: viewer).state == .pass
            {
                return (.pass, "@\(reviewer)'s review check passed on \(short) without comments")
            }
        }
        if let outside = approvals.first {
            let why = switch outside.trust {
            case .bot: "isn't in trusted_reviewers"
            case .member: "is an organisation member gh hasn't said can write to the repo"
            default: "isn't a collaborator"
            }
            return (.wait, "@\(outside.author) approved \(short), but \(why)")
        }
        if detail.reviews.contains(where: { $0.state == "APPROVED" && counts($0) }) {
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

    /// The self-review of exactly the head commit it is stamped with (`detail.headSHA`): the diff is asked for that
    /// commit (`diff(base, head)`, `GitHub.compareDiff`), not for whatever the PR's head is by then, so what was
    /// approved is what `--match-head-commit` merges. A command heed cannot turn the tools off for does not run.
    public static func review(
        _ detail: PullDetail, command: String, instructions: String, now: Date,
        diff: @Sendable (_ base: String, _ head: String) async throws -> String,
        run: @Sendable (_ command: String, _ prompt: Prompt) async throws -> String = {
            try await SelfReview.run($0, prompt: $1)
        }
    ) async -> SelfReview {
        let sha = detail.headSHA
        if case let .refused(reason) = toolless(command) {
            return SelfReview(sha: sha, approved: false, summary: "not run: \(reason)", at: now)
        }
        guard !sha.isEmpty else {
            return SelfReview(sha: sha, approved: false, summary: "not run: the head commit isn't known", at: now)
        }
        do {
            let diff = try await diff(detail.baseBranch, sha)
            let output = try await run(command, prompt(detail, diff: diff, instructions: instructions))
            return parse(output, sha: sha, at: now)
        } catch {
            return SelfReview(sha: sha, approved: false, summary: "the self-review failed: \(error)", at: now)
        }
    }

    /// Why a self-review command does not run.
    public struct Refused: Error, CustomStringConvertible {
        public let description: String
    }

    /// Runs the `self_review` command with the prompt on stdin (through the shell, so `claude -p` and pipes work),
    /// with the PATH tool detection found, in an empty folder of its own, with its agent's tools off (`toolless`), for
    /// up to ten minutes. A command heed cannot turn the tools off for throws `Refused` and does not run.
    public static func run(_ command: String, prompt: Prompt) async throws -> String {
        switch toolless(command) {
        case let .refused(reason): throw Refused(description: reason)
        case let .run(line, locate): return try await execute(line, locate: locate, prompt: prompt)
        }
    }

    /// `line` through `/bin/sh -c` with the prompt on stdin, in an empty folder, with PATH from where `locate` is.
    static func execute(_ line: String, locate: String, prompt: Prompt) async throws -> String {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("heed-self-review-\(UUID().uuidString)", isDirectory: true)
        let work = scratch.appendingPathComponent("work", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let file = scratch.appendingPathComponent("prompt.txt")
        try prompt.text.write(to: file, atomically: true, encoding: .utf8)
        let path = await ToolLocator.shared.executable(locate).pathVariable
        let result = try await ProcessRunner.run(
            "/bin/sh", ["-c", "\(line) < \(ShellQuote.quote(file.path))"], in: work.path,
            environment: ["PATH": path], timeout: .seconds(600), caller: "merge.command"
        )
        guard result.succeeded else {
            throw ProcessError(command: line, result: result, reason: "exit \(result.status)")
        }
        return result.stdout
    }

    /// What heed runs for a `self_review` command: the command with its agent's tools off, or why it does not run.
    public enum Toolless: Hashable, Sendable {
        /// The line to run, and the program whose folder goes on PATH.
        case run(String, locate: String)
        case refused(String)
    }

    /// The command with its agent's tools turned off, the flags `LLMDialect` uses for the same agent, right after the
    /// agent's executable: `claude` gets `--tools '' --strict-mcp-config`, `pi` `--no-tools --no-extensions --no-mcp`.
    /// heed reads past a leading `env`, `NAME=value` assignments and a package runner (`npx`, `bunx`, `pnpx`,
    /// `pnpm dlx`, with `-y`/`--yes`) running `@anthropic-ai/claude-code` to find the agent. A command that
    /// names its tools itself runs as written. Any other command does not run: heed cannot tell it has no tools
    /// (codex's read-only sandbox still runs shell commands, for one).
    public static func toolless(_ command: String) -> Toolless {
        let trimmed = command.trimmingCharacters(in: .whitespaces)
        var tokens: [(text: String, range: Range<String.Index>)] = []
        var index = trimmed.startIndex
        while index < trimmed.endIndex {
            guard !trimmed[index].isWhitespace else {
                index = trimmed.index(after: index)
                continue
            }
            let start = index
            while index < trimmed.endIndex, !trimmed[index].isWhitespace {
                index = trimmed.index(after: index)
            }
            tokens.append((String(trimmed[start ..< index]), start ..< index))
        }
        guard !tokens.isEmpty else { return .refused("self_review is empty") }
        func unknown(_ what: String) -> Toolless {
            .refused("heed knows no way to turn the tools off for \(what); use claude or pi in self_review")
        }
        let plain =
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-./@=:+,")
        var at = 0
        if tokens[at].text == "env" {
            at += 1
            if at < tokens.count, tokens[at].text.hasPrefix("-") { return unknown("`env \(tokens[at].text)`") }
        }
        while at < tokens.count, tokens[at].text.range(of: #"^[A-Za-z_][A-Za-z0-9_]*="#, options: .regularExpression)
            != nil
        {
            guard tokens[at].text.unicodeScalars.allSatisfy(plain.contains) else {
                return unknown("an assignment heed can't read (`\(tokens[at].text)`)")
            }
            at += 1
        }
        guard at < tokens.count else { return .refused("self_review names no command") }
        let runners: Set = ["npx", "bunx", "pnpx"]
        // The program found on PATH: the runner, else the agent itself.
        var runner: String?
        let pnpmDlx = tokens[at].text == "pnpm" && tokens.dropFirst(at + 1).first?.text == "dlx"
        if runners.contains(tokens[at].text) || pnpmDlx {
            runner = tokens[at].text
            at += pnpmDlx ? 2 : 1
            while at < tokens.count, ["-y", "--yes", "-q", "--quiet"].contains(tokens[at].text) {
                at += 1
            }
            guard at < tokens.count else { return .refused("self_review names no command after the runner") }
        }
        let token = tokens[at]
        guard token.text.unicodeScalars.allSatisfy(plain.contains) else { return unknown("`\(token.text)`") }
        // After a runner, a package (its version cut off); else a program, by name or path.
        let name = if runner != nil {
            token.text.range(of: #"^(@[^/@]+/)?[^@]+"#, options: .regularExpression).map { String(token.text[$0]) }
                ?? token.text
        } else {
            (token.text as NSString).lastPathComponent
        }
        // After a runner only Claude Code's own package is clear: `npx claude` would fetch whatever npm calls that.
        let agent: String? = switch (name, runner != nil) {
        case ("@anthropic-ai/claude-code", true), ("claude", false): "claude"
        case ("pi", false): "pi"
        default: nil
        }
        let locate = runner ?? token.text
        let rest = String(trimmed[token.range.upperBound...])
        let head = String(trimmed[..<token.range.upperBound])
        let flags: String
        switch agent {
        case "claude":
            guard !rest.contains("--tools") else { return .run(command, locate: locate) }
            flags = " --tools '' --strict-mcp-config"
        case "pi":
            guard !rest.contains("--no-tools"), !rest.contains("--tools") else {
                return .run(command, locate: locate)
            }
            flags = " --no-tools --no-extensions --no-mcp"
        default:
            return name == "codex" ? .refused("codex has no flag that turns its tools off; use claude or pi in "
                + "self_review") : unknown("`\(name)`")
        }
        return .run(head + flags + rest, locate: locate)
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
