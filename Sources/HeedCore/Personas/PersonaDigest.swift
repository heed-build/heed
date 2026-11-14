import Foundation

/// What heed read in one repo to propose the people it serves: its docs, who owns what, what review keeps saying,
/// what its issues are about, what CI requires, and who merges what. Projected from gh's and the checkout's answers;
/// raw JSON never leaves `PersonaReads`.
public struct RepoReads: Hashable, Sendable {
    public struct ReviewComment: Hashable, Sendable {
        public var path: String
        public var body: String
        public var at: Date?

        public init(path: String, body: String, at: Date? = nil) {
            self.path = path
            self.body = body
            self.at = at
        }
    }

    public struct Issue: Hashable, Sendable {
        public var title: String
        public var labels: [String]

        public init(title: String, labels: [String] = []) {
            self.title = title
            self.labels = labels
        }
    }

    public struct Merge: Hashable, Sendable {
        public var mergedBy: String
        public var author: String
        public var paths: [String]

        public init(mergedBy: String, author: String, paths: [String] = []) {
            self.mergedBy = mergedBy
            self.author = author
            self.paths = paths
        }
    }

    public var repo: String
    /// README, CONTRIBUTING and the like, by file name (already cut to a few hundred words each).
    public var docs: [String: String]
    /// The names under `docs/`.
    public var docFiles: [String]
    /// CODEOWNERS' rules, comments dropped.
    public var owners: [String]
    public var reviewComments: [ReviewComment]
    public var issues: [Issue]
    public var requiredChecks: [String]
    public var workflows: [String]
    public var merges: [Merge]

    public init(
        repo: String, docs: [String: String] = [:], docFiles: [String] = [], owners: [String] = [],
        reviewComments: [ReviewComment] = [], issues: [Issue] = [], requiredChecks: [String] = [],
        workflows: [String] = [], merges: [Merge] = []
    ) {
        self.repo = repo
        self.docs = docs
        self.docFiles = docFiles
        self.owners = owners
        self.reviewComments = reviewComments
        self.issues = issues
        self.requiredChecks = requiredChecks
        self.workflows = workflows
        self.merges = merges
    }

    // MARK: Projections

    /// CODEOWNERS' text into its rules: blank lines and comments dropped.
    public static func owners(_ text: String) -> [String] {
        text.split(separator: "\n").map { line in
            let rule = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
            return rule.trimmingCharacters(in: .whitespaces)
        }
        .filter { !$0.isEmpty }
    }

    /// `gh api repos/{repo}/pulls/comments`: each comment's path, body and when.
    public static func reviewComments(_ data: Data) -> [ReviewComment] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let body = row["body"] as? String else { return nil }
            return ReviewComment(
                path: row["path"] as? String ?? "", body: body,
                at: (row["created_at"] as? String).flatMap(iso.date(from:))
            )
        }
    }

    /// `gh issue list --json title,labels`.
    public static func issues(_ data: Data) -> [Issue] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let title = row["title"] as? String else { return nil }
            let labels = (row["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            return Issue(title: title, labels: labels)
        }
    }

    /// `gh pr list --state merged --json author,mergedBy,files`.
    public static func merges(_ data: Data) -> [Merge] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            let merger = (row["mergedBy"] as? [String: Any])?["login"] as? String
            guard let merger else { return nil }
            let author = (row["author"] as? [String: Any])?["login"] as? String ?? ""
            let paths = (row["files"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return Merge(mergedBy: merger, author: author, paths: paths)
        }
    }

    /// `gh api repos/{repo}/branches/{branch}`: the required checks its protection names (readers see them too).
    public static func requiredChecks(_ data: Data) -> [String] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let protection = object["protection"] as? [String: Any],
              let checks = protection["required_status_checks"] as? [String: Any]
        else { return [] }
        let contexts = checks["contexts"] as? [String] ?? []
        let named = (checks["checks"] as? [[String: Any]] ?? []).compactMap { $0["context"] as? String }
        var seen = Set<String>()
        return (contexts + named).filter { seen.insert($0).inserted }
    }

    /// The folder a path is in, as far as two levels (`redirects/`, `docs/guides/`), or the file at the root.
    static func folder(_ path: String) -> String {
        let parts = path.split(separator: "/")
        guard parts.count > 1 else { return path }
        return parts.prefix(min(2, parts.count - 1)).joined(separator: "/") + "/"
    }
}

/// The reads, summed across repos for the Add a persona sheet's left column, and cut into the compact text a cheap
/// model reads to propose the people the repos serve.
public struct PersonaDigest: Hashable, Sendable {
    /// What heed reads, as the sheet lists it.
    public enum Step: String, CaseIterable, Sendable {
        case docs, owners, issues, checks, merges

        public var title: String {
            switch self {
            case .docs: "README, CONTRIBUTING, docs/"
            case .owners: "CODEOWNERS, review comments"
            case .issues: "issues and their labels"
            case .checks: "CI and required checks"
            case .merges: "who merges what"
            }
        }

        public var icon: String {
            switch self {
            case .docs: "folder"
            case .owners: "arrow.triangle.branch"
            case .issues: "questionmark"
            case .checks: "checkmark"
            case .merges: "person.2"
            }
        }
    }

    public var reads: [RepoReads]

    public init(reads: [RepoReads]) {
        self.reads = reads
    }

    /// Per step, how much there was: `3 repos`, `6 months`, `412`, `9`, `23 people`.
    public func count(_ step: Step, now: Date) -> String {
        switch step {
        case .docs:
            let repos = reads.count { !$0.docs.isEmpty || !$0.docFiles.isEmpty }
            return "\(repos) repo\(repos == 1 ? "" : "s")"
        case .owners:
            let dates = reads.flatMap(\.reviewComments).compactMap(\.at)
            guard let oldest = dates.min() else {
                let comments = reads.reduce(0) { $0 + $1.reviewComments.count }
                return "\(comments) comment\(comments == 1 ? "" : "s")"
            }
            let months = max(1, Int((now.timeIntervalSince(oldest) / (30 * 86400)).rounded()))
            return "\(months) month\(months == 1 ? "" : "s")"
        case .issues:
            return "\(reads.reduce(0) { $0 + $1.issues.count })"
        case .checks:
            return "\(Set(reads.flatMap { $0.requiredChecks + $0.workflows }).count)"
        case .merges:
            let people = Set(reads.flatMap { $0.merges.flatMap { [$0.mergedBy, $0.author] } }.filter { !$0.isEmpty })
            return "\(people.count) people"
        }
    }

    /// The most the model reads, in characters: a cheap call over a compact digest.
    public static let limit = 12000

    /// The text the model reads, each repo's sections cut to a few lines; the whole at most `limit` characters.
    public func render(limit: Int = limit) -> String {
        let share = max(1500, limit / max(reads.count, 1))
        let text = reads.map { Self.render($0, limit: share) }.joined(separator: "\n\n")
        return text.count <= limit ? text : String(text.prefix(limit)) + "\n…"
    }

    static func render(_ reads: RepoReads, limit: Int) -> String {
        var lines = ["# \(reads.repo)"]
        for name in reads.docs.keys.sorted() {
            let text = GoalDoc.oneLine(reads.docs[name] ?? "")
            lines.append("\(name): \(text.prefix(name.lowercased().hasPrefix("readme") ? 900 : 400))")
        }
        if !reads.docFiles.isEmpty {
            lines.append("docs/: " + reads.docFiles.prefix(25).joined(separator: ", "))
        }
        if !reads.owners.isEmpty {
            lines.append("CODEOWNERS: " + reads.owners.prefix(15).joined(separator: "; "))
        }
        if !reads.reviewComments.isEmpty {
            let folders = Self.top(reads.reviewComments.map { RepoReads.folder($0.path) }, 6)
            lines.append("review comments: \(reads.reviewComments.count), most on " + folders.joined(separator: ", "))
            for comment in reads.reviewComments.prefix(20) {
                lines.append("- \(comment.path): \(GoalDoc.oneLine(comment.body).prefix(140))")
            }
        }
        if !reads.issues.isEmpty {
            let labels = Self.top(reads.issues.flatMap(\.labels), 12)
            lines.append("issues: \(reads.issues.count)" + (labels.isEmpty ? "" : ", labels " + labels.joined(
                separator: ", "
            )))
            for issue in reads.issues.prefix(15) {
                lines.append("- \(issue.title.prefix(100))")
            }
        }
        if !reads.requiredChecks.isEmpty {
            lines.append("required checks: " + reads.requiredChecks.joined(separator: ", "))
        }
        if !reads.workflows.isEmpty {
            lines.append("CI workflows: " + reads.workflows.prefix(10).joined(separator: ", "))
        }
        if !reads.merges.isEmpty {
            let byMerger = Dictionary(grouping: reads.merges, by: \.mergedBy)
            let people = byMerger.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1
                .value.count
            }
            lines.append("who merges what (last \(reads.merges.count) merged PRs):")
            for (person, merges) in people.prefix(8) {
                let folders = Self.top(merges.flatMap { $0.paths.map(RepoReads.folder) }, 3)
                lines.append("- \(person): \(merges.count)" + (folders.isEmpty ? "" : ", in " + folders.joined(
                    separator: ", "
                )))
            }
        }
        let text = lines.joined(separator: "\n")
        return text.count <= limit ? text : String(text.prefix(limit)) + "\n…"
    }

    /// The most common values, most first (ties by name).
    static func top(_ values: [String], _ count: Int) -> [String] {
        let counts = Dictionary(values.map { ($0, 1) }, uniquingKeysWith: +)
        return counts.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(count).map {
            $0.value > 1 ? "\($0.key) (\($0.value))" : $0.key
        }
    }
}
