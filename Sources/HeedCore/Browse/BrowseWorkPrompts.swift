import Foundation

/// What an agent is told for each verb on an item: small pure builders, so Start work opens with them now and the
/// agent view that runs them reuses them. The title is other people's text and stays fenced; heed's own read is
/// not sent, since an agent reads the item itself.
public enum BrowseWorkPrompts {
    public static func prompt(_ verb: BrowseVerb, item: BrowseItem) -> Prompt {
        let pull = item.kind == .pull
        let what = pull ? "pull request" : "issue"
        let place: Prompt = "\(name: item.repo.slug)#\(item.number)"
        let head = headline(item)
        let read = readFirst(item)
        switch verb {
        case .fix:
            if pull {
                return head + "\(read) Address the feedback on this pull request: look at the failing checks and "
                    + "the review comments, push the fixes to its branch, and say in a comment what changed."
            }
            return head + "\(read) Reproduce the bug, fix it, add a test that fails without the fix, and open a "
                + "pull request that closes it (`Closes \(place)`). Comment on the issue with what you found."
        case .implement:
            return head + "\(read) Build what it asks for, with tests, and open a pull request that closes it "
                + "(`Closes \(place)`). If the request leaves a design decision open, stop and ask before building."
        case .chat:
            return head + "\(read) Talk it through with me: find the cause or the context in the code, say what "
                + "you would do and what is unclear, and draft a reply if one is needed. Do not change any files."
        case .review:
            if pull {
                return head + "\(read) Review it: read the diff, run the tests, and draft a review for me to "
                    + "approve or edit before anything is posted."
            }
            return head + "\(read) Find the pull request that closes this \(name: what), read its diff, run the tests, "
                + "and draft a review for me to approve or edit before anything is posted."
        }
    }

    static func headline(_ item: BrowseItem) -> Prompt {
        let kind = item.kind == .pull ? "Pull request" : "Issue"
        return "\(name: kind) \(name: item.repo.slug)#\(item.number): \(item.title)\n\(name: item.url)\n\n"
    }

    static func readFirst(_ item: BrowseItem) -> Prompt {
        let word = item.kind == .pull ? "pr" : "issue"
        return "Read it and its comments first (`gh \(name: word) view \(item.number) --repo \(name: item.repo.slug) --comments`)."
    }

    /// The free-text line: the item, then what you said.
    public static func told(_ words: String, item: BrowseItem) -> Prompt {
        let pull = item.kind == .pull
        let head = headline(item)
        return words.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? head + readFirst(item) + " Then: "
            : head + "\(owner: words.trimmingCharacters(in: .whitespacesAndNewlines))"
    }
}
