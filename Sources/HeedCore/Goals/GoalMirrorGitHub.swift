import Foundation

/// Whether a repo can be a goal's tracker, read before anything is written there.
public struct TrackerCheck: Hashable, Sendable, Codable {
    public var repo: String
    /// nil: it can. Else why not, in words.
    public var problem: String?

    public init(repo: String, problem: String? = nil) {
        self.repo = repo
        self.problem = problem
    }

    public var ok: Bool { problem == nil }

    /// From what GitHub says of the repo: issues on, not archived, and a permission that can open, close and attach
    /// issues (triage or more).
    public static func from(
        repo: String, found: Bool, hasIssues: Bool, archived: Bool, permission: String?
    ) -> TrackerCheck {
        guard found else { return TrackerCheck(repo: repo, problem: "\(repo) does not exist, or gh cannot see it") }
        guard hasIssues else { return TrackerCheck(repo: repo, problem: "\(repo) has issues turned off") }
        guard !archived else { return TrackerCheck(repo: repo, problem: "\(repo) is archived") }
        let able: Set<String> = ["TRIAGE", "WRITE", "MAINTAIN", "ADMIN"]
        guard let permission, able.contains(permission) else {
            return TrackerCheck(
                repo: repo,
                problem: "you can only read \(repo): sub-issues and closing need triage access or more"
            )
        }
        return TrackerCheck(repo: repo)
    }

    /// `org/name`, or nil when it is not one.
    public static func slug(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let parts = trimmed.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts.allSatisfy({ part in
            !part.isEmpty && part.allSatisfy { $0.isLetter || $0.isNumber || "-_.".contains($0) } && part
                .allSatisfy(\.isASCII)
        }) else { return nil }
        return trimmed
    }
}

/// What the mirror asks of GitHub. `GitHubMirror` runs gh; tests use an in-memory one, so nothing is written to GitHub
/// while testing.
public protocol MirrorGitHub: Sendable {
    func check(repo: String) async throws -> TrackerCheck
    /// The issues in `repo` whose body may carry one of `goal`'s markers (a search: it can lag behind a write).
    func marked(repo: String, goal: String) async throws -> [RemoteIssue]
    func create(repo: String, title: String, body: String, labels: [String]) async throws -> RemoteIssue
    func edit(repo: String, number: Int, title: String?, body: String?) async throws
    func setState(repo: String, number: Int, open: Bool) async throws
    func addSubIssue(repo: String, parent: Int, child: Int64) async throws
    func comment(repo: String, number: Int, body: String) async throws
    /// The issues in `repo` updated since `since` (all of them, open and closed).
    func updated(repo: String, since: Date) async throws -> [RemoteIssue]
    /// The comments on an issue, oldest first, updated since `since` when given.
    func comments(repo: String, number: Int, since: Date?) async throws -> [RemoteComment]
}

/// The mirror through gh: REST for issues and sub-issues, GraphQL for the repo check. Every call is a `github` row in
/// the call log, writes marked as writes, bodies left out of the logged command.
public struct GitHubMirror: MirrorGitHub {
    public var caller: String

    public init(caller: String = "goals.mirror") {
        self.caller = caller
    }

    static let checkQuery = """
    query($owner: String!, $name: String!) { repository(owner: $owner, name: $name) {
      nameWithOwner hasIssuesEnabled isArchived viewerPermission } }
    """

    public func check(repo: String) async throws -> TrackerCheck {
        guard let slug = TrackerCheck.slug(repo) else {
            return TrackerCheck(repo: repo, problem: "\(repo) is not org/name")
        }
        let parts = slug.split(separator: "/").map(String.init)
        let data = try await GitHub.graphql(
            Self.checkQuery, operation: "trackerCheck", variables: ["owner": parts[0], "name": parts[1]], caller: caller
        )
        return Self.parseCheck(data, repo: slug)
    }

    static func parseCheck(_ data: Data, repo: String) -> TrackerCheck {
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let node = (json?["data"] as? [String: Any])?["repository"] as? [String: Any]
        return TrackerCheck.from(
            repo: repo, found: node != nil, hasIssues: node?["hasIssuesEnabled"] as? Bool ?? false,
            archived: node?["isArchived"] as? Bool ?? false, permission: node?["viewerPermission"] as? String
        )
    }

    public func marked(repo: String, goal: String) async throws -> [RemoteIssue] {
        let query = "repo:\(repo) is:issue in:body heed \"\(goal)\""
        let result = try await GitHub.gh(
            ["api", "-X", "GET", "search/issues", "-f", "q=\(query)", "-f", "per_page=100"],
            operation: "GET search/issues", timeout: .seconds(30), caller: caller,
            items: { Self.parseIssues(Data($0.utf8), key: "items")?.count }
        )
        guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
        return Self.parseIssues(Data(result.stdout.utf8), key: "items") ?? []
    }

    public func create(repo: String, title: String, body: String, labels: [String]) async throws -> RemoteIssue {
        let fields = ["-f", "title=\(title)"] + labels.flatMap { ["-f", "labels[]=\($0)"] }
        let result = try await GitHub.gh(
            ["api", "-X", "POST", "repos/\(repo)/issues"] + fields + ["-f", "body=\(body)"],
            operation: "POST issues", write: true,
            shown: ["api", "-X", "POST", "repos/\(repo)/issues"] + fields + ["-f", "body=…"],
            timeout: .seconds(30), caller: caller
        )
        guard result.succeeded, let issue = Self.parseIssue(Data(result.stdout.utf8)) else {
            throw GitHub.Failure(description: GitHub.explain(result))
        }
        return issue
    }

    public func edit(repo: String, number: Int, title: String?, body: String?) async throws {
        let fields = (title.map { ["-f", "title=\($0)"] } ?? [])
        try await write(
            ["-X", "PATCH", "repos/\(repo)/issues/\(number)"] + fields + (body.map { ["-f", "body=\($0)"] } ?? []),
            shown: ["-X", "PATCH", "repos/\(repo)/issues/\(number)"] + fields + (body == nil ? [] : ["-f", "body=…"]),
            operation: "PATCH issues"
        )
    }

    public func setState(repo: String, number: Int, open: Bool) async throws {
        let fields = open ? ["-f", "state=open"] : ["-f", "state=closed", "-f", "state_reason=completed"]
        let arguments = ["-X", "PATCH", "repos/\(repo)/issues/\(number)"] + fields
        try await write(arguments, shown: arguments, operation: "PATCH issues state")
    }

    public func addSubIssue(repo: String, parent: Int, child: Int64) async throws {
        // `sub_issue_id` is the issue's id (not its number), sent typed (-F) so it reaches GitHub as an integer.
        let arguments = ["-X", "POST", "repos/\(repo)/issues/\(parent)/sub_issues", "-F", "sub_issue_id=\(child)"]
        try await write(arguments, shown: arguments, operation: "POST issues/sub_issues")
    }

    public func comment(repo: String, number: Int, body: String) async throws {
        let path = "repos/\(repo)/issues/\(number)/comments"
        try await write(
            ["-X", "POST", path, "-f", "body=\(body)\n\n\(MirrorMarker.comment)"],
            shown: ["-X", "POST", path, "-f", "body=…"], operation: "POST issues/comments"
        )
    }

    public func updated(repo: String, since: Date) async throws -> [RemoteIssue] {
        let result = try await GitHub.gh(
            [
                "api", "-X", "GET", "repos/\(repo)/issues", "-f", "state=all", "-f", "since=\(Self.iso(since))",
                "-f", "sort=updated", "-f", "direction=desc", "-f", "per_page=100",
            ],
            operation: "GET issues", timeout: .seconds(30), caller: caller,
            items: { Self.parseIssues(Data($0.utf8), key: nil)?.count }
        )
        guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
        return Self.parseIssues(Data(result.stdout.utf8), key: nil) ?? []
    }

    public func comments(repo: String, number: Int, since: Date?) async throws -> [RemoteComment] {
        let result = try await GitHub.gh(
            ["api", "-X", "GET", "repos/\(repo)/issues/\(number)/comments", "-f", "per_page=100"]
                + (since.map { ["-f", "since=\(Self.iso($0))"] } ?? []),
            operation: "GET issues/comments", timeout: .seconds(30), caller: caller,
            items: { Self.parseComments(Data($0.utf8)).count }
        )
        guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
        return Self.parseComments(Data(result.stdout.utf8))
    }

    private func write(_ arguments: [String], shown: [String], operation: String) async throws {
        let result = try await GitHub.gh(
            ["api"] + arguments, operation: operation, write: true, shown: ["api"] + shown, timeout: .seconds(30),
            caller: caller
        )
        guard result.succeeded else { throw GitHub.Failure(description: GitHub.explain(result)) }
    }

    // MARK: Parsing

    static func iso(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    /// A REST issue: `number`, `id`, `title`, `body`, `state`, `updated_at`, `parent_issue_url`. Pull requests (the
    /// issues API lists them too) are left out.
    static func issue(_ node: [String: Any]) -> RemoteIssue? {
        guard node["pull_request"] == nil, let number = node["number"] as? Int,
              let id = (node["id"] as? NSNumber)?.int64Value else { return nil }
        let parent = (node["parent_issue_url"] as? String).flatMap { url in
            url.split(separator: "/").last.flatMap { Int($0) }
        }
        return RemoteIssue(
            number: number, id: id, title: node["title"] as? String ?? "", body: node["body"] as? String,
            open: (node["state"] as? String) != "closed", updatedAt: GitHub.date(node["updated_at"] as? String),
            parent: parent
        )
    }

    static func parseIssue(_ data: Data) -> RemoteIssue? {
        ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]).flatMap(issue)
    }

    /// A list of issues, or a search answer's `items`.
    static func parseIssues(_ data: Data, key: String?) -> [RemoteIssue]? {
        let json = try? JSONSerialization.jsonObject(with: data)
        let list = key.map { ((json as? [String: Any])?[$0]) } ?? json
        return (list as? [[String: Any]])?.compactMap(issue)
    }

    static func parseComments(_ data: Data) -> [RemoteComment] {
        let list = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] ?? []
        return list.compactMap { node in
            guard let id = (node["id"] as? NSNumber)?.int64Value else { return nil }
            return RemoteComment(
                id: id, author: (node["user"] as? [String: Any])?["login"] as? String ?? "ghost",
                body: node["body"] as? String ?? "", at: GitHub.date(node["created_at"] as? String)
            )
        }
    }
}
