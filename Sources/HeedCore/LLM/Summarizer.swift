import Foundation

/// What a summary is of, which decides heed's prompt for it.
public enum SummaryKind: String, Sendable, CaseIterable {
    /// Where a session's work stands and what it did: for history, attention and the timeline.
    case session
    /// A brief for an agent taking work over (a chat promoted to a session): what was decided and what is left.
    case handoff
    /// History's ledger: a summary, the decisions and the follow-ups, in the sections `LedgerText` reads.
    case ledger
    /// A GitHub thread in Attention: what it is about and what it asks of you.
    case thread
    /// A reply to a GitHub thread, drafted for you to read before anything is posted.
    case reply
    /// A goal broken into items, one `- ` line each (`GoalPlanner`).
    case goalPlan
    /// Changes to a goal's GOAL.md the work suggests, as JSON (`GoalEditProposer`).
    case goalEdits
    /// A sharper GOAL.md, as the same JSON edits, every one of them waiting for you (`w`).
    case goalSharpen
    /// A new goal's `GOAL.md`, drafted from the sessions and chats on no goal that hang together (Unassigned).
    case goalDraft
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
    /// A goal's GOAL.md, for the goal kinds.
    public var goal: String?
    /// What is known already (a goal's items), one per line.
    public var known: [String]

    public init(
        title: String, repo: String? = nil, branch: String? = nil, git: String? = nil, pullRequest: String? = nil,
        timeline: [String] = [], lastMessage: String? = nil, goal: String? = nil, known: [String] = []
    ) {
        self.title = title
        self.repo = repo
        self.branch = branch
        self.git = git
        self.pullRequest = pullRequest
        self.timeline = timeline
        self.lastMessage = lastMessage
        self.goal = goal
        self.known = known
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
        section("GOAL.md", goal)
        section("Already known", known.map { "- " + $0 }.joined(separator: "\n"))
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
        case .ledger:
            """
            You keep a ledger of software work for the developer who owns it, from its git history, pull request, \
            timeline and the coding agent's last message. Answer in exactly these sections, each heading on its own \
            line: "Summary:" then at most three short sentences of plain prose on what the work did and where it \
            stands; "Decisions:" then one "- " line per decision that was taken (none: "- none"); "Follow-ups:" then \
            one "- " line per thing left to do (none: "- none"). Only facts from the input; no preamble.
            """
        case .thread:
            """
            You summarize a GitHub issue or pull request thread for one developer, from its description and latest \
            comments. Say first what it asks of them, if anything (a review, an answer, a decision), then where it \
            stands, in at most three short sentences of plain prose. Name people when it matters who asked. No \
            preamble, no headings, no lists.
            """
        case .reply:
            """
            You draft a reply to a GitHub issue or pull request thread for the developer it is addressed to, from its \
            description and latest comments. Answer what was asked of them, briefly and politely, in their voice; \
            where you do not know a fact, leave a [placeholder] for them to fill in. Only the reply's text, in \
            GitHub Markdown, no preamble.
            """
        case .goalPlan:
            """
            You break a software goal into the pieces of work that reach it, from its GOAL.md. Answer with one "- " \
            line per piece, at most eight, each a short imperative title of at most eight words, in the order they \
            would be done. Leave out what the Not the goal section excludes and what is already known. Only the \
            lines; no preamble.
            """
        case .goalEdits:
            """
            You keep a goal's GOAL.md honest as the work teaches. From the GOAL.md and what a piece of work on it \
            found (its summary, decisions, follow-ups, last message), suggest only changes the work clearly supports: \
            a decision taken, an open question answered or raised, a done-when criterion met (with the evidence), a \
            new criterion or non-goal the work showed. Reply with only JSON: {"edits": [{"section": one of goal, \
            notTheGoal, doneWhen, openQuestions, decisions; "op": one of add, remove, replace, check; "text": the \
            line; "target": the existing line a remove, replace or check is about, or null; "evidence": what showed \
            it, or null; "reason": one short sentence}]}. No edits: {"edits": []}.
            """
        case .goalSharpen:
            """
            You sharpen a software goal's GOAL.md so a stranger could tell when it is done. Suggest at most five \
            changes: a goal statement with a measurable outcome, done-when criteria that can be checked, non-goals \
            that keep the work small, questions that block it. Reply with only JSON: {"edits": [{"section": one of \
            goal, notTheGoal, doneWhen, openQuestions, decisions; "op": one of add, remove, replace; "text": the \
            line; "target": the existing line a remove or replace is about, or null; "evidence": null; "reason": one \
            short sentence}]}.
            """
        case .goalDraft:
            """
            You draft a GOAL.md for a long-running goal that several pieces of software work share, from their titles \
            and first prompts. Write markdown in exactly this shape: "# " and a short title (at most five words); \
            "## Goal" then one or two sentences on the outcome they work toward; "## Not the goal" then "- " lines for \
            what is plainly out of scope (none: leave it empty); "## Done when" then "- [ ] " lines, each a checkable \
            result; "## Open questions" then "- " lines; "## Decisions" left empty. Only what the input supports; no \
            preamble.
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
