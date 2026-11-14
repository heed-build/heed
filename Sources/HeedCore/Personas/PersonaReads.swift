import Foundation

/// Add a persona's reads: a repo's docs and CODEOWNERS (from its checkout when there is one, else through gh), its
/// review comments, issues and labels, required checks and workflows, and who merged its last PRs. GETs only, each a
/// row in the call log under the caller given; a read that fails leaves its part empty and the rest goes on. The
/// trial's reads too: merged PRs, one PR's diff and what its review said.
public extension GitHub {
    /// Bytes read from a doc.
    static let personaDocBytes = 4000

    static func personaReads(
        _ repo: Repo, checkout: String?, caller: String,
        progress: @escaping @Sendable (PersonaDigest.Step) async -> Void = { _ in }
    ) async -> RepoReads {
        var reads = RepoReads(repo: repo.slug)
        let path = "repos/\(repo.slug)"
        // Docs and owners: the checkout first.
        if let checkout {
            let root = URL(fileURLWithPath: checkout)
            for name in ["README.md", "CONTRIBUTING.md", "README", "docs/README.md"] {
                if let text = readPrefix(root.appendingPathComponent(name)) { reads.docs[name] = text }
            }
            let docs = root.appendingPathComponent("docs")
            reads.docFiles = ((try? FileManager.default.contentsOfDirectory(atPath: docs.path)) ?? [])
                .filter { !$0.hasPrefix(".") }.sorted()
            for name in [".github/CODEOWNERS", "CODEOWNERS", "docs/CODEOWNERS"] {
                if let text = readPrefix(root.appendingPathComponent(name)) {
                    reads.owners = RepoReads.owners(text)
                    break
                }
            }
            let workflows = root.appendingPathComponent(".github/workflows")
            reads.workflows = ((try? FileManager.default.contentsOfDirectory(atPath: workflows.path)) ?? [])
                .filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }.map { ($0 as NSString).deletingPathExtension }
                .sorted()
        } else if let readme = await raw("\(path)/readme", operation: "GET readme", caller: caller) {
            reads.docs["README.md"] = String(readme.prefix(personaDocBytes))
        }
        await progress(.docs)
        if reads.owners.isEmpty,
           let owners = await raw(
               "\(path)/contents/.github/CODEOWNERS",
               operation: "GET CODEOWNERS",
               caller: caller
           )
        {
            reads.owners = RepoReads.owners(owners)
        }
        if let data = await json(
            ["api", "\(path)/pulls/comments?per_page=100&sort=created&direction=desc"],
            operation: "GET pulls/comments", caller: caller
        ) {
            reads.reviewComments = RepoReads.reviewComments(data)
        }
        await progress(.owners)
        if let data = await json(
            ["issue", "list", "-R", repo.slug, "--state", "all", "--limit", "200", "--json", "title,labels"],
            operation: "issue list", caller: caller
        ) {
            reads.issues = RepoReads.issues(data)
        }
        await progress(.issues)
        if let info = await json(["api", path], operation: "GET repo", caller: caller),
           let object = (try? JSONSerialization.jsonObject(with: info)) as? [String: Any],
           let branch = object["default_branch"] as? String,
           let data = await json(["api", "\(path)/branches/\(branch)"], operation: "GET branch", caller: caller)
        {
            reads.requiredChecks = RepoReads.requiredChecks(data)
        }
        await progress(.checks)
        if let data = await json(
            ["pr", "list", "-R", repo.slug, "--state", "merged", "--limit", "40", "--json", "author,mergedBy,files"],
            operation: "pr list (merged)", caller: caller
        ) {
            reads.merges = RepoReads.merges(data)
        }
        await progress(.merges)
        return reads
    }

    /// The repo's last merged PRs, for a trial.
    static func mergedPulls(_ repo: Repo, caller: String) async -> [PullListing] {
        guard let data = await json(
            [
                "pr",
                "list",
                "-R",
                repo.slug,
                "--state",
                "merged",
                "--limit",
                "15",
                "--json",
                "number,title,mergedAt,additions,deletions",
            ],
            operation: "pr list (merged)", caller: caller
        ) else { return [] }
        return PullListing.parse(data)
    }

    /// A PR's diff and what its review said.
    static func pullSample(_ repo: Repo, pull: PullListing, caller: String) async throws -> PullSample {
        let diff = try await GitHub.diff(PullRef(repo: repo, number: pull.number), caller: caller)
        let comments = await json(
            ["api", "repos/\(repo.slug)/pulls/\(pull.number)/comments?per_page=50"], operation: "GET pull comments",
            caller: caller
        )
        let reviews = await json(
            ["pr", "view", "\(pull.number)", "-R", repo.slug, "--json", "reviews"], operation: "pr view (reviews)",
            caller: caller
        )
        let review = PersonaTrial.review(comments: comments, reviews: reviews)
        return PullSample(
            repo: repo.slug, number: pull.number, title: pull.title, mergedAt: pull.mergedAt,
            diff: String(diff.prefix(PersonaTrial.diffLimit * 2)), reviewSaid: review.said, reviewPaths: review.paths
        )
    }

    private static func json(_ arguments: [String], operation: String, caller: String) async -> Data? {
        guard let result = try? await gh(arguments, operation: operation, timeout: .seconds(30), caller: caller),
              result.succeeded
        else { return nil }
        return Data(result.stdout.utf8)
    }

    /// A file's text through the contents API, raw.
    private static func raw(_ path: String, operation: String, caller: String) async -> String? {
        guard let result = try? await gh(
            ["api", "-H", "Accept: application/vnd.github.raw", path], operation: operation, timeout: .seconds(30),
            caller: caller
        ), result.succeeded else { return nil }
        return result.stdout
    }

    private static func readPrefix(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: personaDocBytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
