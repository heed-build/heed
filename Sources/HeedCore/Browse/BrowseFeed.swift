import Foundation

/// One line of a run's feed as Browse draws it: what you said, what it read, what it found, edited (with a small diff),
/// ran, tested, said on GitHub, opened and labelled, and what heed refused. Made from what the agent reported
/// (`HelperEntry`); nothing is invented.
public struct BrowseFeedLine: Identifiable, Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case you, read, said, edited, tested, ran, commented, openedPR, labelled, pushed, committed, refused, note
    }

    public var id: String
    public var kind: Kind
    public var text: String
    /// A quote, a command's first output line, the reason for a refusal.
    public var detail: String?
    /// An edit's diff, trimmed to a few lines.
    public var diff: [DiffLine] = []
    /// The pull request it opened, or the comment it made.
    public var link: String?
    /// The number a link points at (`2860`).
    public var number: Int?
    public var failed = false
    /// How many files a read line stands for (0: not a file read).
    public var reads = 0
    /// Labels put on the item, shown on the line of the pull request they went with.
    public var labels: [String] = []

    /// Whether the glyph is a warning, not the glyph of what it tried: a tool that failed (a refusal has its own).
    public var warns: Bool { failed && kind != .refused }
}

public enum BrowseFeed {
    /// How many lines of an edit's diff the feed keeps.
    public static let diffLines = 6

    public static func lines(_ feed: [HelperEntry]) -> [BrowseFeedLine] {
        var out: [BrowseFeedLine] = []
        for entry in feed {
            guard let line = line(entry) else { continue }
            // Consecutive file reads are one line: "Read 3 files".
            if line.reads > 0, var last = out.last, last.reads > 0 {
                last.reads += line.reads
                last.text = "Read \(last.reads) files"
                out[out.count - 1] = last
                continue
            }
            // A label put on right after a pull request opened is part of its line.
            if line.kind == .labelled, var last = out.last, last.kind == .openedPR {
                last.labels += line.labels
                out[out.count - 1] = last
                continue
            }
            out.append(line)
        }
        return out
    }

    static func line(_ entry: HelperEntry) -> BrowseFeedLine? {
        switch entry.body {
        case let .steer(text):
            return BrowseFeedLine(id: entry.id, kind: .you, text: text)
        case let .message(text):
            let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // heed's sign-off lines are the draft's, not the feed's.
            let shown = clean.split(separator: "\n", omittingEmptySubsequences: false)
                .filter { !$0.lowercased().hasPrefix("heed-") }.joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return shown.isEmpty ? nil : BrowseFeedLine(id: entry.id, kind: .said, text: shown)
        case let .note(text):
            return BrowseFeedLine(id: entry.id, kind: .note, text: text)
        case let .permission(title, answer):
            guard let answer, answer.hasPrefix("refused: ") else { return nil }
            return BrowseFeedLine(
                id: entry.id, kind: .refused, text: "Refused: \(title)",
                detail: String(answer.dropFirst("refused: ".count))
            )
        case let .tool(tool):
            return line(tool, id: entry.id)
        }
    }

    static func line(_ tool: HelperTool, id: String) -> BrowseFeedLine? {
        let failed = tool.status == .failed
        func make(_ kind: BrowseFeedLine.Kind, _ text: String, detail: String? = nil) -> BrowseFeedLine {
            BrowseFeedLine(id: id, kind: kind, text: text, detail: detail, failed: failed)
        }
        if let diff = tool.diffs.first, [.edit, .delete, .move].contains(tool.kind) || !tool.diffs.isEmpty {
            var line = make(
                .edited,
                "Edited \(diff.path) +\(tool.diffs.reduce(0) { $0 + $1.added }) \u{2013}\(tool.diffs.reduce(0) { $0 + $1.removed })"
            )
            line.diff = Array(diff.lines.filter { $0.kind != .context }.prefix(diffLines))
            return line
        }
        switch tool.kind {
        case .read, .search:
            var line = make(.read, "Read \(tool.paths.first ?? tool.title)")
            line.reads = 1
            return line
        case .edit, .delete, .move:
            return make(.edited, tool.title)
        case .think, .switchMode:
            return nil
        case .execute, .other, .fetch:
            break
        }
        guard let command = tool.command ?? (tool.kind == .execute ? tool.title : nil) else {
            return tool.kind == .fetch ? make(.read, "Read \(tool.title)") : make(.ran, tool.title)
        }
        return classify(command, tool: tool, make: make)
    }

    private static func classify(
        _ command: String, tool: HelperTool, make: (BrowseFeedLine.Kind, String, String?) -> BrowseFeedLine
    ) -> BrowseFeedLine? {
        let output = tool.output
        let words = command.split(separator: " ").map(String.init)
        func has(_ phrase: String) -> Bool { command.contains(phrase) }
        let failed = tool.status == .failed
        let reason = firstLine(output)
        // A command heed refused has its own line (the refusal, with why): not also a line saying it ran.
        if failed, output?.localizedCaseInsensitiveContains("refused permission") == true { return nil }
        if failed, has("gh pr create") {
            return make(.openedPR, "Tried to open a pull request", reason ?? flag("--title", in: words))
        }
        if failed, has("gh issue comment") || has("gh pr comment") {
            return make(.commented, "Tried to comment", reason)
        }
        if failed, has("gh issue edit") || has("gh pr edit") {
            return make(.labelled, "Tried to edit the item", reason)
        }
        if failed, has("git push") { return make(.pushed, "Could not push" + (reason.map { ": \($0)" } ?? ""), nil) }
        if failed, has("git commit") {
            if CommitSigning.failed(output ?? "") {
                return make(
                    .committed, "Could not commit: signing failed",
                    "commit signing needs your ssh agent (or gpg-agent with your key unlocked) and it is not available "
                        + "in this run: " + (reason ?? "")
                )
            }
            return make(.committed, "Could not commit" + (reason.map { ": \($0)" } ?? ""), nil)
        }
        if has("gh pr create") {
            var line = make(.openedPR, "Opened a pull request", nil)
            if let url = output.flatMap { pullURL(in: $0) } ?? pullURL(in: command) {
                line.link = url
                line.number = Int(url.split(separator: "/").last ?? "")
                line.text = "Opened PR #\(line.number ?? 0)"
                line.detail = flag("--title", in: words)
            } else {
                line.detail = flag("--title", in: words)
            }
            return line
        }
        if has("gh issue comment") || has("gh pr comment") {
            let number = words.firstIndex { $0 == "comment" }
                .flatMap {
                    words.indices
                        .contains($0 + 1) ? Int(words[$0 + 1].trimmingCharacters(in: CharacterSet(charactersIn: "#"))) :
                        nil
                }
            var line = make(
                .commented,
                "Commented" + (number.map { " on #\($0)" } ?? ""),
                flag("--body", in: words) ?? flag("-b", in: words)
            )
            line.number = number
            return line
        }
        if has("gh issue edit") || has("gh pr edit"), let label = flag("--add-label", in: words) {
            var line = make(.labelled, "Labelled \(label)", nil)
            line.labels = [label]
            return line
        }
        if has("git push") { return make(.pushed, "Pushed", firstLine(output)) }
        if has("git commit") { return make(
            .committed,
            "Committed",
            flag("-m", in: words) ?? flag("--message", in: words)
        ) }
        if isTest(command) {
            return make(.tested, tool.status == .failed ? "Tests fail" : "Tests pass", firstLine(output))
        }
        if has("gh issue view") || has("gh pr view") {
            return make(.read, "Read the \(has("gh pr") ? "pull request" : "issue") and its comments", nil)
        }
        if has("gh pr diff") || has("git diff") { return make(.read, "Read the diff", nil) }
        if failed { return make(.ran, "Failed: \(command.prefix(80))", reason) }
        return make(.ran, "Ran \(command.prefix(80))", firstLine(output))
    }

    static func isTest(_ command: String) -> Bool {
        [
            "dotnet test",
            "swift test",
            "npm test",
            "npm run test",
            "yarn test",
            "pnpm test",
            "cargo test",
            "go test",
            "pytest",
            "make test",
            "mise run test",
            "rspec",
            "mvn test",
            "gradle test",
            "./gradlew test",
            "bun test",
        ]
        .contains { command.contains($0) }
    }

    private static func firstLine(_ text: String?) -> String? {
        text?.split(whereSeparator: \.isNewline).first.map(String.init)
    }

    private static func flag(_ name: String, in words: [String]) -> String? {
        guard let index = words.firstIndex(of: name), words.indices.contains(index + 1) else { return nil }
        let rest = Array(words[(index + 1)...])
        guard let first = rest.first else { return nil }
        // A quoted value runs to its closing quote.
        guard let quote = first.first, "'\"".contains(quote) else { return first }
        var text: [String] = []
        for word in rest {
            text.append(word)
            if word.last == quote, word.count > 1 || text.count > 1 { break }
        }
        return text.joined(separator: " ").trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
    }

    /// `https://github.com/acme/docs-toolkit/pull/2860` in a text.
    static func pullURL(in text: String) -> String? {
        guard let range = text.range(of: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#, options: .regularExpression)
        else { return nil }
        return String(text[range])
    }
}
