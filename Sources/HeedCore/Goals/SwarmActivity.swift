import Foundation

public extension EventKind {
    /// A tool call an agent made (its `PostToolUse` hook): the tool, a short input, and whether it failed, with a
    /// digest of the error so a repeat is recognised (`ToolCall`).
    static let toolCall = EventKind(rawValue: "tool.call")
    /// What changed in a worktree since heed last looked (`git status`, `git diff --stat`, polled and rate limited).
    static let fileChange = EventKind(rawValue: "file.change")
    /// The kinds kept apart from the rest of the log: pruned by age and capped in size (`EventLog.pruneActivity`).
    static let activity: [EventKind] = [.toolCall, .fileChange]
}

/// One tool call, as heed keeps it: never the tool's whole input or output, only what the agents pane shows.
public struct ToolCall: Codable, Hashable, Sendable {
    /// `Bash`, `Edit`, `Read`.
    public var tool: String
    /// Its most telling argument, short: `dotnet test --filter Anchor`, `src/Validation/Anchors.cs`.
    public var input: String?
    public var error: Bool
    /// The error's digest (`ErrorDigest`), when it failed and said why.
    public var digest: String?

    public init(tool: String, input: String? = nil, error: Bool = false, digest: String? = nil) {
        self.tool = tool
        self.input = input
        self.error = error
        self.digest = digest
    }

    /// Longest input kept.
    public static let inputLimit = 80

    /// `Bash(dotnet test)`.
    public var label: String { input.map { "\(tool)(\($0))" } ?? tool }

    /// A `PostToolUse` (or `PostToolUseFailure`) hook's call: `tool_name`, `tool_input`, `tool_response` (or `error`).
    /// Nil without a tool name.
    public static func from(hook input: [String: Any]) -> ToolCall? {
        guard let tool = input["tool_name"] as? String, !tool.isEmpty else { return nil }
        let args = input["tool_input"] as? [String: Any] ?? [:]
        let detail = (args["command"] ?? args["file_path"] ?? args["path"] ?? args["pattern"] ?? args["url"]
            ?? args["description"]) as? String
        let short = detail.map { text -> String in
            let line = text.split(separator: "\n").first.map(String.init) ?? text
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            return trimmed.count > inputLimit ? String(trimmed.prefix(inputLimit - 1)) + "…" : trimmed
        }
        let failure = failure(input)
        return ToolCall(
            tool: tool, input: short?.isEmpty == true ? nil : short, error: failure.failed,
            digest: failure.text.flatMap(ErrorDigest.of)
        )
    }

    /// Whether the call failed, and what it said. Claude Code's `PostToolUseFailure` carries `error`; a response may
    /// say `is_error`, `success: false`, a non-zero exit code, or be text that starts with an error.
    static func failure(_ input: [String: Any]) -> (failed: Bool, text: String?) {
        if let error = input["error"] as? String, !error.isEmpty { return (true, error) }
        let response = input["tool_response"]
        if let text = response as? String {
            let head = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let failed = head.hasPrefix("error") || head.hasPrefix("fatal:") || head.contains("exit code 1")
                || head.hasPrefix("failed")
            return (failed, failed ? text : nil)
        }
        guard let object = response as? [String: Any] else { return (false, nil) }
        let said = (object["error"] as? String) ?? (object["stderr"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (object["stdout"] as? String) ?? (object["output"] as? String)
        if object["is_error"] as? Bool == true || object["isError"] as? Bool == true
            || object["success"] as? Bool == false || object["interrupted"] as? Bool == true
        {
            return (true, said)
        }
        for key in ["exit_code", "exitCode", "returncode"] {
            if let code = object[key] as? Int, code != 0 { return (true, said) }
        }
        if let error = object["error"] as? String, !error.isEmpty { return (true, error) }
        return (false, nil)
    }

    /// The event-log row for a call.
    public func event(at: Date, session: String?, subject: String, payload: [String: String] = [:]) -> LoggedEvent {
        var fields = payload
        fields["tool"] = tool
        if let input { fields["input"] = input }
        if error { fields["error"] = "1" }
        if let digest { fields["digest"] = digest }
        return LoggedEvent(at: at, kind: .toolCall, session: session, subject: subject, text: label, payload: fields)
    }

    /// The call a row holds back; nil for any other row.
    public init?(event: LoggedEvent) {
        guard event.kind == .toolCall, let tool = event.payload["tool"] else { return nil }
        self.init(
            tool: tool, input: event.payload["input"], error: event.payload["error"] == "1",
            digest: event.payload["digest"]
        )
    }
}

/// An error, reduced to what stays the same when the same thing fails again: its telling line, numbers, paths' hashes,
/// quotes and spacing evened out, lower case, at most `limit` characters.
public enum ErrorDigest {
    public static let limit = 90

    public static func of(_ text: String) -> String? {
        let lines = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else { return nil }
        let telling = lines.first { line in
            let lower = line.lowercased()
            return ["error", "failed", "fatal", "exception", "panic", "cannot", "can't", "not found", "denied"]
                .contains { lower.contains($0) }
        } ?? lines[0]
        // Hashes and addresses first: a run of hex digits is one mark, whatever its digits.
        let unhexed = telling.lowercased()
            .replacingOccurrences(of: #"\b(0x)?[0-9a-f]{6,}\b"#, with: "#", options: .regularExpression)
        var digest = ""
        var lastWasDigit = false
        for character in unhexed {
            if character.isNumber {
                if !lastWasDigit { digest.append("#") }
                lastWasDigit = true
                continue
            }
            lastWasDigit = false
            if character == "\"" || character == "'" || character == "`" { continue }
            if character.isWhitespace {
                if digest.last != " " { digest.append(" ") }
                continue
            }
            digest.append(character)
        }
        digest = digest.trimmingCharacters(in: .whitespaces)
        guard !digest.isEmpty else { return nil }
        return digest.count > limit ? String(digest.prefix(limit - 1)) + "…" : digest
    }
}

/// How often activity is kept: a worker's tool calls at most one per `gap` (a failed one always), the ones in between
/// counted on the next one kept. One per key (a worker).
public struct ActivityThrottle: Sendable {
    public var gap: TimeInterval
    private var last: [String: Date] = [:]
    private var skipped: [String: Int] = [:]

    public init(gap: TimeInterval = 2) { self.gap = gap }

    /// Whether to keep a call now, and how many were skipped since the last one kept.
    public mutating func keep(_ key: String, at now: Date, error: Bool) -> (keep: Bool, skipped: Int) {
        if !error, let previous = last[key], now.timeIntervalSince(previous) < gap {
            skipped[key, default: 0] += 1
            return (false, 0)
        }
        last[key] = now
        let count = skipped.removeValue(forKey: key) ?? 0
        return (true, count)
    }

    public mutating func forget(_ key: String) {
        last[key] = nil
        skipped[key] = nil
    }
}

/// What changed in a worktree, from `git status --porcelain` and `git diff --stat HEAD`: the files, lines in and out.
public struct FileActivity: Hashable, Sendable, Codable {
    public var files: [String]
    public var insertions: Int
    public var deletions: Int
    /// The worktree's commit: a new commit is a change too, though it leaves nothing uncommitted.
    public var head: String?

    public init(files: [String] = [], insertions: Int = 0, deletions: Int = 0, head: String? = nil) {
        self.files = files
        self.insertions = insertions
        self.deletions = deletions
        self.head = head
    }

    public var isEmpty: Bool { files.isEmpty }

    /// `3 files · +64 −12`.
    public var line: String {
        "\(files.count) file\(files.count == 1 ? "" : "s") · +\(insertions) −\(deletions)"
    }

    /// The files `git status --porcelain` lists (renames by their new name) and the totals of `git diff --stat`.
    public static func parse(status: String, diffStat: String, head: String? = nil) -> FileActivity {
        var files: [String] = []
        for line in status.split(whereSeparator: \.isNewline) where line.count > 3 {
            var path = String(line.dropFirst(3))
            if let arrow = path.range(of: " -> ") { path = String(path[arrow.upperBound...]) }
            path = path.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            if !path.isEmpty, !files.contains(path) { files.append(path) }
        }
        var insertions = 0
        var deletions = 0
        if let summary = diffStat.split(whereSeparator: \.isNewline).last(where: { $0.contains("changed") }) {
            for part in summary.split(separator: ",") {
                let words = part.split(separator: " ")
                guard let number = words.first.flatMap({ Int($0) }) else { continue }
                if part.contains("insertion") { insertions = number }
                if part.contains("deletion") { deletions = number }
            }
        }
        let commit = head?.trimmingCharacters(in: .whitespacesAndNewlines)
        return FileActivity(
            files: files, insertions: insertions, deletions: deletions,
            head: commit?.isEmpty == false ? commit : nil
        )
    }

    /// The row to keep when the worktree changed since `previous`: its files or lines, or a new commit. The first
    /// look is only kept when there is something uncommitted.
    public static func change(from previous: FileActivity?, to now: FileActivity) -> FileActivity? {
        guard now != previous else { return nil }
        if previous == nil, now.isEmpty { return nil }
        return now
    }

    /// `3 files · +64 −12`, or `committed` when a commit left nothing uncommitted.
    public func line(after previous: FileActivity?) -> String {
        isEmpty && head != previous?.head ? "committed" : line
    }

    /// Files a row lists, at most.
    public static let fileLimit = 6

    public func event(at: Date, session: String?, worktree: String, subject: String, payload: [String: String] = [:])
        -> LoggedEvent
    {
        var fields = payload
        fields["files"] = files.prefix(Self.fileLimit).joined(separator: "\n")
        fields["count"] = "\(files.count)"
        fields["insertions"] = "\(insertions)"
        fields["deletions"] = "\(deletions)"
        if let head { fields["head"] = String(head.prefix(12)) }
        return LoggedEvent(
            at: at, kind: .fileChange, session: session, worktree: worktree, subject: subject, text: line,
            payload: fields
        )
    }
}

/// How often a worker's worktree is read: at most every `interval`, only while its worker is live.
public enum FileActivityPolling {
    public static let interval: TimeInterval = 60

    public static func due(last: Date?, now: Date, interval: TimeInterval = interval) -> Bool {
        last.map { now.timeIntervalSince($0) >= interval } ?? true
    }
}

/// One line of a worker's activity, as the agents pane lists it: a tool call or a file change.
public struct SwarmActivityLine: Hashable, Sendable, Identifiable {
    public enum Kind: Hashable, Sendable {
        case tool(ToolCall)
        case files(FileActivity)
    }

    public var at: Date
    public var kind: Kind
    /// Calls skipped before it by the throttle.
    public var skipped: Int

    public var id: String { "\(at.timeIntervalSince1970)-\(text)" }

    public init(at: Date, kind: Kind, skipped: Int = 0) {
        self.at = at
        self.kind = kind
        self.skipped = skipped
    }

    public var text: String {
        switch kind {
        case let .tool(call): call.error ? "\(call.label) · \(call.digest ?? "failed")" : call.label
        case let .files(change): change.line
        }
    }

    public var isError: Bool { if case let .tool(call) = kind { call.error } else { false } }

    /// The line a row holds; nil for any other row.
    public init?(event: LoggedEvent) {
        let skipped = event.payload["skipped"].flatMap(Int.init) ?? 0
        if let call = ToolCall(event: event) {
            self.init(at: event.at, kind: .tool(call), skipped: skipped)
        } else if event.kind == .fileChange {
            let files = (event.payload["files"] ?? "").split(separator: "\n").map(String.init)
            let change = FileActivity(
                files: files, insertions: event.payload["insertions"].flatMap(Int.init) ?? 0,
                deletions: event.payload["deletions"].flatMap(Int.init) ?? 0
            )
            self.init(at: event.at, kind: .files(change))
        } else {
            return nil
        }
    }
}

/// A worker's activity, folded into what the stuck signal reads.
public enum SwarmActivityFacts {
    /// The newest line's time, and the error digests of its tool calls (oldest first, nil for a call that went fine).
    public static func of(_ lines: [SwarmActivityLine]) -> (last: Date?, errors: [String?]) {
        let sorted = lines.sorted { $0.at < $1.at }
        let errors: [String?] = sorted.compactMap { line in
            guard case let .tool(call) = line.kind else { return nil }
            return .some(call.error ? (call.digest ?? call.tool) : nil)
        }
        return (sorted.last?.at, errors)
    }
}
