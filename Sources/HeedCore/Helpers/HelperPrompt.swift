import Foundation

/// A reply heed will post once you approve: on a review thread (`threadID`, GitHub's node id) or, for a review of
/// someone else's PR, a comment on a line.
public struct HelperReply: Hashable, Sendable, Identifiable {
    public var id: String { threadID ?? place }
    /// The review thread it answers; nil for a review comment of yours.
    public var threadID: String?
    /// `reply on Redirects.cs:88`, `src/Arrow.cs:41`.
    public var place: String
    public var text: String

    public init(threadID: String?, place: String, text: String) {
        self.threadID = threadID
        self.place = place
        self.text = text
    }
}

/// What a helper did, read from the end of its last message (`heed-did:`, `heed-reply <n>:`, `heed-comment
/// <path>:<line>:`, `heed-verdict:`), with git's count of what changed.
public struct HelperCloseOut: Hashable, Sendable {
    public var did: [String]
    public var replies: [HelperReply]
    /// For a review: `approve`, `comment` or `request changes`, as the agent judged.
    public var verdict: String?
    /// Its last message without the heed lines: what it says it did when it wrote none.
    public var summary: String
    /// Commits it made on its branch, ahead of the PR's branch.
    public var commits: Int
    /// Uncommitted changes left in its worktree.
    public var dirty: Bool
    /// What was pushed, when it was.
    public var pushedSHA: String?

    public init(
        did: [String] = [], replies: [HelperReply] = [], verdict: String? = nil, summary: String = "",
        commits: Int = 0, dirty: Bool = false, pushedSHA: String? = nil
    ) {
        self.did = did
        self.replies = replies
        self.verdict = verdict
        self.summary = summary
        self.commits = commits
        self.dirty = dirty
        self.pushedSHA = pushedSHA
    }

    /// Something to push.
    public var hasChanges: Bool { commits > 0 || dirty }
}

/// The prompts a helper starts with, and how its last message is read back.
public enum HelperPrompt {
    /// What every helper is told about where it is and what it may not do.
    static func preamble(branch: String, prBranch: String) -> String {
        "You are a helper heed started on the user's behalf, in a git worktree of your own on the branch \(branch), "
            + "which starts from \(prBranch) (the pull request's branch). Work only in this worktree. Do not push, "
            + "and do not post anything to GitHub: heed shows the user what you did and pushes and replies once they "
            + "approve. Commit your changes on this branch with clear messages. Keep a short plan as you go."
    }

    /// How to end: the lines heed reads back.
    static let signOffGreen = """
    When you are done, end your final message with one line per thing you did, and one reply for each review \
    comment you addressed, exactly like this:
    heed-did: <what you did, in a few words>
    heed-reply <item number>: <your reply to that review comment, one or two sentences>
    """

    static let signOffReview = """
    When you are done, end your final message with your review, exactly like this:
    heed-did: <what you checked, in a few words> (one line each)
    heed-comment <path>:<line>: <a review comment on that line>
    heed-verdict: approve | comment | request changes
    """

    /// Get it green: the PR's queued feedback (its numbered items, each review comment's thread kept by number).
    public static func green(feedback: String, branch: String, prBranch: String) -> String {
        preamble(branch: branch, prBranch: prBranch) + "\n\n" + feedback + "\n\n" + signOffGreen
    }

    /// A review of someone else's PR: read it against its issue, run its tests, draft comments.
    public static func review(
        ref: PullRef, title: String, body: String, base: String, branch: String, prBranch: String,
        instructions: String = ""
    ) -> String {
        var text = preamble(branch: branch, prBranch: prBranch)
            + "\n\nReview pull request #\(ref.number) in \(ref.repo.slug), \"\(title)\", for the user. Read its "
            + "change (git diff origin/\(base)...HEAD) against what it says it does and the issue it links, run its "
            + "tests, and draft review comments where something is wrong, unclear or missing. Change no files and "
            + "make no commits."
        if !body.isEmpty { text += "\n\nIts description:\n" + body }
        if !instructions.isEmpty { text += "\n\n" + instructions }
        return text + "\n\n" + signOffReview
    }

    /// Steering while it works, or after its turn ended (Keep going).
    public static func steer(_ text: String) -> String {
        text + "\n\n(From the user, through heed. Carry on, and end with the heed lines as before.)"
    }

    /// Resuming after a pause.
    public static let resume = "Carry on where you stopped. End with the heed lines as before."

    /// Reads a helper's last message: its heed lines, and the rest as the summary. `threads` maps a get it green
    /// item number (1-based) to its review thread and where it is.
    public static func closeOut(
        _ message: String, threads: [Int: (id: String, location: String)] = [:]
    ) -> HelperCloseOut {
        var out = HelperCloseOut()
        var rest: [String] = []
        for raw in message.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let plain = line.hasPrefix("- ") ? String(line.dropFirst(2)) : line
            if let text = value(plain, after: "heed-did:") {
                if !text.isEmpty { out.did.append(text) }
            } else if let text = value(plain, after: "heed-verdict:") {
                out.verdict = text.lowercased()
            } else if plain.lowercased().hasPrefix("heed-reply ") {
                let body = plain.dropFirst("heed-reply ".count)
                guard let colon = body.firstIndex(of: ":"),
                      let number = Int(body[..<colon].trimmingCharacters(in: .whitespaces).trimmingCharacters(
                          in: CharacterSet(charactersIn: "#")
                      ))
                else { continue }
                let text = body[body.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                // A reply to an item that is no review comment has no thread to go on: heed drops it.
                guard let thread = threads[number], !text.isEmpty else { continue }
                out.replies.append(HelperReply(threadID: thread.id, place: thread.location, text: text))
            } else if plain.lowercased().hasPrefix("heed-comment ") {
                let body = String(plain.dropFirst("heed-comment ".count))
                // `<path>:<line>: text`: the place ends at the colon after the line number.
                let parts = body.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
                guard parts.count == 3, Int(parts[1].trimmingCharacters(in: .whitespaces)) != nil else { continue }
                let text = parts[2].trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                out.replies.append(HelperReply(
                    threadID: nil, place: "\(parts[0]):\(parts[1].trimmingCharacters(in: .whitespaces))", text: text
                ))
            } else {
                rest.append(String(raw))
            }
        }
        out.summary = rest.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return out
    }

    private static func value(_ line: String, after prefix: String) -> String? {
        guard line.lowercased().hasPrefix(prefix) else { return nil }
        return line.dropFirst(prefix.count).trimmingCharacters(in: .whitespaces)
    }

    /// A get it green prompt's review items by number (`1) …`), with their threads: what `closeOut` maps replies
    /// to. Checks and notes have no thread.
    public static func threads(_ items: [FeedbackItem]) -> [Int: (id: String, location: String)] {
        var threads: [Int: (id: String, location: String)] = [:]
        for (index, item) in items.enumerated() {
            if case let .review(location, _) = item.kind { threads[index + 1] = (item.id, location) }
        }
        return threads
    }

    /// The review heed posts for you: what it checked and each comment by where it is, under one review.
    public static func reviewBody(_ closeOut: HelperCloseOut) -> String {
        var lines: [String] = []
        if !closeOut.did.isEmpty { lines += closeOut.did.map { "- \($0)" } }
        if !closeOut.replies.isEmpty {
            if !lines.isEmpty { lines.append("") }
            lines += closeOut.replies.map { "**\($0.place)**: \($0.text)" }
        }
        return lines.isEmpty ? closeOut.summary : lines.joined(separator: "\n")
    }

    /// What the session's agent is told once a helper pushed: never typed, shown on the session (`notify`).
    public static func pushedNote(_ helper: HelperRun, sha: String, did: [String]) -> String {
        let what = did.prefix(2).joined(separator: " + ")
        return "heed pushed \(sha.prefix(7)) to \(helper.prBranch)" + (what.isEmpty ? "" : ": \(what)")
            + ". Pull before your next change."
    }

    /// What the session is told while a helper works on its PR.
    public static func workingNote(_ helper: HelperRun) -> String {
        "A helper is " + helper.headline.prefix(1).lowercased() + helper.headline.dropFirst()
            + " in its own worktree. It pushes to \(helper.prBranch) only once you approve; pull before your next "
            + "change."
    }

    /// Take it over: where the helper's work is, for the session to pick up.
    public static func takeOverNote(_ helper: HelperRun) -> String {
        "You took over the helper on #\(helper.ref.number): its work is on the branch \(helper.branch) in "
            + "\(helper.worktree). Merge it into \(helper.prBranch) with: git merge \(helper.branch)"
    }
}
