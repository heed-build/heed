import Foundation

/// A big paste into Start work's prompt, kept beside it rather than in it: a log, a diff, a stack trace. The agent is
/// told where the file is (on a host, the text goes in the prompt after all, fenced), so the prompt stays short and an
/// agent that takes its prompt on the command line still gets everything.
public struct PromptAttachment: Hashable, Sendable, Identifiable {
    public enum Kind: String, Hashable, Sendable {
        case log, diff, trace, json, text

        /// What the chip calls it: "CI log", "diff", "stack trace", "JSON", "text".
        public var title: String {
            switch self {
            case .log: "log"
            case .diff: "diff"
            case .trace: "stack trace"
            case .json: "JSON"
            case .text: "text"
            }
        }
    }

    public var id: Int
    public var kind: Kind
    public var text: String

    public init(id: Int, text: String) {
        self.id = id
        self.text = text
        kind = PromptAttachments.kind(of: text)
    }

    public var lines: Int { text.split(separator: "\n", omittingEmptySubsequences: false).count }

    /// `paste-2.log`: its file's name.
    public var fileName: String {
        let suffix = switch kind {
        case .log: "log"
        case .diff: "diff"
        case .json: "json"
        case .trace, .text: "txt"
        }
        return "paste-\(id).\(suffix)"
    }
}

public enum PromptAttachments {
    /// A paste this long becomes an attachment instead of text in the prompt.
    public static let minLines = 20
    public static let minCharacters = 2000

    public static func isLarge(_ text: String) -> Bool {
        text.count >= minCharacters || text.split(separator: "\n", omittingEmptySubsequences: false).count > minLines
    }

    /// What a paste looks like, from its lines: a diff's `@@`/`+++`, a stack trace's `at …`/`Traceback`, JSON that
    /// parses, timestamped or levelled lines for a log; else plain text.
    public static func kind(of text: String) -> PromptAttachment.Kind {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !lines.isEmpty else { return .text }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if lines.contains(where: { $0.hasPrefix("@@ ") }) || lines.contains(where: { $0.hasPrefix("diff --git") })
            || (lines.contains { $0.hasPrefix("+++ ") } && lines.contains { $0.hasPrefix("--- ") })
        {
            return .diff
        }
        if trimmed.first == "{" || trimmed.first == "[",
           (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8), options: [.fragmentsAllowed])) != nil
        {
            return .json
        }
        let traceLines = lines.filter {
            $0.hasPrefix("at ") || $0.hasPrefix("Traceback") || $0.hasPrefix("File \"") || $0.contains("Exception")
                || $0.hasPrefix("Fatal error") || $0.hasPrefix("panic:")
        }
        if traceLines.count >= 3 { return .trace }
        let logLines = lines.filter { line in
            line.range(of: #"^\[?\d{4}-\d{2}-\d{2}[T ]\d{2}:\d{2}"#, options: .regularExpression) != nil
                || line.range(of: #"\b(ERROR|WARN|WARNING|INFO|DEBUG)\b"#, options: .regularExpression) != nil
                || line.hasPrefix("##[")
        }
        return logLines.count * 3 >= lines.count ? .log : .text
    }

    /// The prompt the agent gets: what you typed, then where each attachment is. Without a path (work on a host) the
    /// attachment's text goes in, fenced.
    public static func prompt(_ typed: String, attachments: [(PromptAttachment, path: String?)]) -> String {
        guard !attachments.isEmpty else { return typed }
        var parts = [typed.trimmingCharacters(in: .whitespacesAndNewlines)]
        let filed = attachments.compactMap { attachment, path in
            path.map { "- \($0) (\(attachment.kind.title), \(attachment.lines) lines)" }
        }
        if !filed.isEmpty { parts.append("Attached, read these files:\n" + filed.joined(separator: "\n")) }
        for (attachment, path) in attachments where path == nil {
            parts.append("Attached \(attachment.kind.title):\n```\n\(attachment.text)\n```")
        }
        return parts.filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
}

/// A PR or issue linked in the prompt: a chip with its title once heed has fetched it, and the title is what the
/// branch is named from.
public struct PromptLink: Hashable, Sendable {
    public enum Ref: Hashable, Sendable {
        case pull(PullRef)
        case issue(IssueRef)

        public var isPull: Bool { if case .pull = self { true } else { false } }
    }

    public var ref: Ref
    public var url: String

    /// `org/repo#12`.
    public var label: String {
        switch ref {
        case let .pull(pull): pull.description
        case let .issue(issue): "\(issue.repo.slug)#\(issue.number)"
        }
    }

    /// Every PR and issue URL in `text`, in order, once each.
    public static func links(in text: String) -> [PromptLink] {
        var seen: Set<String> = []
        var found: [PromptLink] = []
        let pattern = #"https?://github\.com/[\w.-]+/[\w.-]+/(pull|issues)/\d+"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        for match in regex.matches(in: text, range: range) {
            guard let swiftRange = Range(match.range, in: text) else { continue }
            let url = String(text[swiftRange])
            guard seen.insert(url).inserted else { continue }
            if let pull = PullRef(url: url) {
                found.append(PromptLink(ref: .pull(pull), url: url))
            } else if let issue = IssueRef(url: url) {
                found.append(PromptLink(ref: .issue(issue), url: url))
            }
        }
        return found
    }
}
