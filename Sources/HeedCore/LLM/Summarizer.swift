import Foundation

/// What a summary is of, which decides heed's prompt for it.
public enum SummaryKind: String, Sendable, CaseIterable {
    /// Where a session's work stands and what it did: for history, attention and the timeline.
    case session
    /// A brief for an agent taking work over (a chat promoted to a session): what was decided and what is left.
    case handoff
}

/// What a summary is written from: git, the PR, heed's own timeline and the agent's last message. Each part is cut to
/// `limit` characters (its end kept: the latest matters most), so a call stays small.
public struct SummaryInputs: Hashable, Sendable {
    public var title: String
    public var repo: String?
    public var branch: String?
    /// `git log --oneline` and `git diff --stat`, as text.
    public var git: String?
    /// The PR's title, state, checks and review, as text.
    public var pullRequest: String?
    /// heed's timeline for it, oldest first, one event per line.
    public var timeline: [String]
    public var lastMessage: String?

    public init(
        title: String, repo: String? = nil, branch: String? = nil, git: String? = nil, pullRequest: String? = nil,
        timeline: [String] = [], lastMessage: String? = nil
    ) {
        self.title = title
        self.repo = repo
        self.branch = branch
        self.git = git
        self.pullRequest = pullRequest
        self.timeline = timeline
        self.lastMessage = lastMessage
    }

    public static let limit = 6000

    static func cut(_ text: String) -> String {
        guard text.count > limit else { return text }
        return "…" + text.suffix(limit - 1)
    }

    /// The input as the model reads it: the parts that are there, under headings.
    var prompt: String {
        var parts = ["Work: \(title)"]
        if let repo { parts.append("Repo: \(repo)" + (branch.map { ", branch \($0)" } ?? "")) }
        func section(_ name: String, _ text: String?) {
            guard let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
            parts.append("\n## \(name)\n\(Self.cut(text))")
        }
        section("Git", git)
        section("Pull request", pullRequest)
        section("Timeline", timeline.joined(separator: "\n"))
        section("The agent's last message", lastMessage)
        return parts.joined(separator: "\n")
    }
}

/// Summaries written by a cheap model through heed's model calls. heed's prompts are built in; `instructions` (the
/// repo's `summary_instructions`, resolved like the other `*_instructions`) are added to them, never replace them.
public struct Summarizer: Sendable {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse
    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    static func system(_ kind: SummaryKind, instructions: String) -> String {
        let base = switch kind {
        case .session:
            """
            You summarize a piece of software work for the developer who owns it, from its git history, pull request, \
            timeline and the coding agent's last message. Say where it stands first (done, waiting on review, blocked \
            on something, still in progress), then what changed, in at most three short sentences of plain prose. \
            Name files, checks and people only when they matter. No preamble, no headings, no lists.
            """
        case .handoff:
            """
            You write a handoff brief for a coding agent that takes this work over, from its git history, pull \
            request, timeline and the last message. State the goal, what was decided, what is done and what is left, \
            in at most six short lines. Only facts from the input; no preamble.
            """
        }
        let extra = instructions.trimmingCharacters(in: .whitespacesAndNewlines)
        return extra.isEmpty ? base : base + "\n\nAlso: " + extra
    }

    /// The summary's text. Identical inputs are answered from the runner's cache.
    public func summarize(
        kind: SummaryKind, inputs: SummaryInputs, instructions: String = "", caller: String,
        priority: LLMRequest.Priority = .background
    ) async throws -> String {
        let response = try await run(LLMRequest(
            call: LLMCall(system: Self.system(kind, instructions: instructions), prompt: inputs.prompt),
            priority: priority, caller: caller, operation: "summarize \(kind.rawValue)"
        ))
        let text = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw LLMError.failed(reasons: ["\(response.agent): an empty summary"]) }
        return text
    }
}
