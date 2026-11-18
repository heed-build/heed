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

    /// One prompt for several picked items (`s` on a selection): the issues one pull request should close, each with
    /// its `Closes` line, in the order picked. Titles stay fenced. `instructions` are the repos' own
    /// `start_instructions`, after the list and before the `Closes` lines, as Attention's prompt puts them.
    /// `related`: heed found the items hang together (`BrowseGrouping`). When it did not, the prompt says so, asks
    /// for a pull request per issue, and does not promise one pull request, which across repos is not possible.
    public static func together(_ items: [BrowseItem], related: Bool = true, instructions: String = "") -> Prompt {
        guard !items.isEmpty else { return "" }
        let extra: [Prompt] = instructions.isEmpty ? [] : ["", .owner(instructions)]
        let issues = items.filter { $0.kind == .issue }
        if items.count == 1, let item = items.first {
            var lines: [Prompt] = [headline(item) + readFirst(item)]
            lines += extra
            if item.kind == .issue { lines += ["", "Closes \(name: item.repo.slug)#\(item.number)"] }
            return lines.joined(separator: "\n")
        }
        guard related else {
            var lines: [Prompt] = [
                "Look into these in one session. heed found nothing that ties them together, so they may be unrelated: "
                    + "say so if they are, and give each issue its own pull request that closes it.",
            ]
            lines += items.map { item in
                let kind: Prompt = item.kind == .pull ? "pull request" : "issue"
                return "- \(kind) \(name: item.repo.slug)#\(item.number) \(item.title)\n  \(name: item.url)"
            }
            lines.append("Read each one and its comments first (`gh issue view <number> --repo <repo> --comments`).")
            lines += extra
            return lines.joined(separator: "\n")
        }
        let head: Prompt = issues.count == items.count
            ? "Work on these together. They look related; open one pull request that addresses all of them."
            : "Look into these together. One pull request should close the issues; the pull requests are context."
        var lines: [Prompt] = [head]
        lines += items.map { item in
            let kind: Prompt = item.kind == .pull ? "pull request" : "issue"
            return "- \(kind) \(name: item.repo.slug)#\(item.number) \(item.title)\n  \(name: item.url)"
        }
        lines.append("Read each one and its comments first (`gh issue view <number> --repo <repo> --comments`).")
        lines += extra
        if !issues.isEmpty {
            lines.append("")
            lines += issues.map { "Closes \(name: $0.repo.slug)#\($0.number)" }
        }
        return lines.joined(separator: "\n")
    }
}
