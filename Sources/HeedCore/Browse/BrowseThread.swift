import Foundation

/// A Chat run has no GitHub login (`RunSandbox.kept` points `gh` at an empty folder), so heed reads the thread itself
/// and puts it in the prompt, each piece fenced as other people's text with its author's trust.
public enum BrowseThread {
    /// The newest comments sent, and the most characters of any one piece.
    public static let commentLimit = 30
    public static let bodyLimit = 8000
    public static let commentCharacters = 4000

    /// What a run whose thread could not be read is told.
    public static let unavailable: Prompt = "heed could not read the thread, and you have no GitHub login: work from the "
        + "title above and the repository, and say what you could not see."

    public static func prompt(_ thread: ThreadConversation) -> Prompt {
        let by = thread.author?.author ?? .unknown
        var lines: [Prompt] = [
            "The thread, as heed read it from GitHub (you have no GitHub login, so do not run `gh`; "
                + "use `git` in the worktree for code):",
        ]
        let body = ThreadText.plain(thread.bodyHTML)
        if !body.isEmpty {
            let text = ExternalText(
                String(body.prefix(bodyLimit)), source: thread.kind == .pr ? .pullBody : .issueBody, author: by
            )
            lines.append("Opened by \(name: thread.author?.login ?? "someone"):\n\(text)")
        }
        let comments = thread.comments.suffix(commentLimit)
        let older = thread.totalComments - comments.count(where: { $0.review == nil })
        if older > 0 || thread.comments.count > comments.count {
            lines.append("The oldest comments are not shown: the newest \(comments.count) follow.")
        }
        for comment in comments {
            let said: Prompt = if let reason = comment.minimizedReason {
                "(hidden as \(name: reason))"
            } else {
                Prompt(ExternalText(
                    String(ThreadText.plain(comment.bodyHTML).prefix(commentCharacters)), source: comment.review == nil
                        ? .comment : .review, author: comment.author?.author ?? .unknown
                ))
            }
            lines.append("\(name: comment.author?.login ?? "ghost") \(owner: comment.verb):\n\(said)")
        }
        return lines.joined(separator: "\n\n")
    }

    /// Whether a run gets heed's scrubbed `kept` environment (no gh, ssh or cloud logins): an author heed does not
    /// trust, and every Chat, whoever wrote the item, because Chat's policy has bypasses.
    public static func scrubbedEnvironment(trusted: Bool, verb: BrowseVerb) -> Bool {
        !trusted || verb == .chat
    }
}
