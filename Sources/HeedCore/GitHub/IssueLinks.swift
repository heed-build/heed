import Foundation

/// An issue, by repo and number: what a session links to besides its PRs.
public struct IssueRef: Hashable, Sendable, Codable, CustomStringConvertible {
    public var repo: Repo
    public var number: Int

    public init(repo: Repo, number: Int) {
        self.repo = repo
        self.number = number
    }

    /// `https://github.com/org/name/issues/123` (with or without a trailing path).
    public init?(url: String) {
        let parts = url.split(separator: "/").map(String.init)
        guard let issues = parts.firstIndex(of: "issues"), issues >= 2, issues + 1 < parts.count,
              let number = Int(parts[issues + 1].prefix { $0.isNumber })
        else { return nil }
        self.init(repo: Repo(org: parts[issues - 2], name: parts[issues - 1]), number: number)
    }

    public var description: String { "\(repo.slug)#\(number)" }
    public var url: String { "https://github.com/\(repo.slug)/issues/\(number)" }
}

/// What heed knows of a linked issue beyond its number: fetched when a session shows it.
public struct IssueInfo: Hashable, Sendable {
    public var title: String
    public var closed: Bool
    public var body: String
    public var labels: [String]
    public var author: String?
    public var updatedAt: Date

    public init(
        title: String, closed: Bool, body: String = "", labels: [String] = [], author: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.title = title
        self.closed = closed
        self.body = body
        self.labels = labels
        self.author = author
        self.updatedAt = updatedAt
    }
}

/// One thing a session links to on GitHub: a PR or an issue. The inspector lists them, `gB` opens them.
public enum SessionLink: Hashable, Sendable {
    case pull(PullRef)
    case issue(IssueRef)
    case repo(Repo)

    public var url: String {
        switch self {
        case let .pull(ref): ref.url
        case let .issue(ref): ref.url
        case let .repo(repo): "https://github.com/\(repo.slug)"
        }
    }

    public var label: String {
        switch self {
        case let .pull(ref): "\(ref.repo.name) #\(ref.number)"
        case let .issue(ref): "\(ref.repo.name) #\(ref.number)"
        case let .repo(repo): repo.slug
        }
    }
}

public enum IssueLinks {
    /// GitHub's closing keywords: `Closes #12`, `fixes org/repo#3`, `Resolved: https://github.com/o/r/issues/4`.
    /// A bare `#12` is in `defaultRepo`.
    public static func referenced(in text: String, defaultRepo: Repo?) -> [IssueRef] {
        let pattern = #"(?i)\b(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)\b:?\s+(https://github\.com/[\w.-]+/[\w.-]+/issues/\d+|[\w.-]+/[\w.-]+#\d+|#\d+)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        var result: [IssueRef] = []
        for match in regex.matches(in: text, range: range) {
            guard let span = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[span])
            let ref: IssueRef?
            if token.hasPrefix("https://") {
                ref = IssueRef(url: token)
            } else if token.hasPrefix("#") {
                ref = defaultRepo.flatMap { repo in Int(token.dropFirst()).map { IssueRef(repo: repo, number: $0) } }
            } else {
                let parts = token.split(separator: "#")
                let slug = parts.first.map { $0.split(separator: "/") } ?? []
                ref = slug.count == 2 && parts.count == 2
                    ? Int(parts[1])
                    .map { IssueRef(repo: Repo(org: String(slug[0]), name: String(slug[1])), number: $0) }
                    : nil
            }
            if let ref, !result.contains(ref) { result.append(ref) }
        }
        return result
    }

    /// A session's issues: those added by hand, those its prompt closes, and those its PRs close; without duplicates,
    /// and without the ones taken off by hand.
    public static func issues(
        added: [IssueRef], prompt: String, defaultRepo: Repo?, closedByPulls: [IssueRef], hidden: [IssueRef]
    ) -> [IssueRef] {
        var result: [IssueRef] = []
        for ref in added + referenced(in: prompt, defaultRepo: defaultRepo) + closedByPulls
            where !result.contains(ref) && !hidden.contains(ref)
        {
            result.append(ref)
        }
        return result
    }

    /// The links in the order the inspector lists them: open PRs, merged, closed, then open issues, closed issues.
    public static func ordered(
        pulls: [PullRef], state: (PullRef) -> PullRequest.State?, issues: [IssueRef], closed: (IssueRef) -> Bool
    ) -> [SessionLink] {
        func rank(_ pull: PullRef) -> Int {
            switch state(pull) {
            case .open, nil: 0
            case .merged: 1
            case .closed: 2
            }
        }
        let sortedPulls = pulls.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        let sortedIssues = issues.enumerated().sorted {
            (closed($0.element) ? 1 : 0, $0.offset) < (closed($1.element) ? 1 : 0, $1.offset)
        }
        return sortedPulls.map { .pull($0.element) } + sortedIssues.map { .issue($0.element) }
    }

    /// The compare page that opens a PR for a pushed branch.
    public static func compareURL(repo: Repo, branch: String) -> String {
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        return "https://github.com/\(repo.slug)/compare/\(encoded)?expand=1"
    }
}

/// `gB` (or `gR`) when there is more than one place to go: the links, a cursor, and keys to pick one or all.
public struct LinkPicker: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case handled, cancel
        case open([SessionLink])
    }

    public let title: String
    public let links: [SessionLink]
    /// The links still open (PRs not merged or closed, issues not closed), for `o` and `p`.
    public let open: Set<SessionLink>
    public private(set) var cursor = 0

    public init(title: String, links: [SessionLink], open: Set<SessionLink> = []) {
        self.title = title
        self.links = links
        self.open = open
    }

    /// `j` `k` (`⌃n` `⌃p`, arrows) move, `↩` opens the one under the cursor, `1`–`9` open that one, `a` opens all, `o`
    /// all the open ones, `p` the open pull requests, `⎋` (or `q`) closes.
    public mutating func handle(_ stroke: KeyStroke) -> Outcome {
        switch stroke {
        case KeyStroke("j"), KeyStroke("n", .control), KeyStroke("Down"):
            cursor = min(cursor + 1, links.count - 1)
        case KeyStroke("k"), KeyStroke("p", .control), KeyStroke("Up"):
            cursor = max(cursor - 1, 0)
        case KeyStroke("CR"):
            return links.indices.contains(cursor) ? .open([links[cursor]]) : .cancel
        case KeyStroke("a"):
            return .open(links)
        case KeyStroke("o"):
            let picked = links.filter(open.contains)
            return picked.isEmpty ? .handled : .open(picked)
        case KeyStroke("p"):
            let picked = links.filter { link in
                if case .pull = link { open.contains(link) } else { false }
            }
            return picked.isEmpty ? .handled : .open(picked)
        case .escape, KeyStroke("q"):
            return .cancel
        default:
            if let number = Int(stroke.key), (1 ... 9).contains(number), stroke.modifiers.isEmpty {
                return links.indices.contains(number - 1) ? .open([links[number - 1]]) : .handled
            }
        }
        return .handled
    }
}
