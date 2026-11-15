import Foundation
import Synchronization

/// Who a PR is from, as `gh pr view --json author,authorAssociation,isCrossRepository` says, and whether heed treats
/// its code as yours: from you, or from the repo's owner, a member or a collaborator, on a branch of the repo itself.
/// A PR from a fork, or from anyone else, is someone else's: heed's runs on it work sandboxed, copy none of your
/// files in and run none of your setup, and none starts on it by itself.
public struct PullAuthorship: Hashable, Sendable {
    public var author: String?
    /// `OWNER`, `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `NONE`, …
    public var association: String?
    /// From a fork.
    public var crossRepository: Bool

    public init(author: String?, association: String?, crossRepository: Bool) {
        self.author = author
        self.association = association
        self.crossRepository = crossRepository
    }

    /// The associations that can write to the repo.
    public static let writers: Set<String> = ["OWNER", "MEMBER", "COLLABORATOR"]

    /// Yours (`viewer` is your login), or from someone who can write to the repo on one of its own branches.
    public func trusted(viewer: String?) -> Bool {
        if let viewer, let author, author.lowercased() == viewer.lowercased() { return true }
        guard !crossRepository, let association else { return false }
        return Self.writers.contains(association.uppercased())
    }

    /// From `gh pr view --json author,authorAssociation,isCrossRepository`; nil when it is not that.
    public static func parse(_ json: String) -> PullAuthorship? {
        guard let value = JSONValue.parse(json), value["isCrossRepository"] != nil || value["authorAssociation"] != nil
        else { return nil }
        return PullAuthorship(
            author: value["author"]?["login"]?.string, association: value["authorAssociation"]?.string,
            crossRepository: value["isCrossRepository"]?.bool ?? true
        )
    }

    /// The fields to ask `gh pr view` for.
    public static let fields = "author,authorAssociation,isCrossRepository"
}

/// Who each PR is from, once asked: so a run that is about to start on its own can tell without waiting.
public final class PullTrustBook: Sendable {
    public static let shared = PullTrustBook()

    private let known = Mutex<[String: PullAuthorship]>([:])

    public init() {}

    public func authorship(_ ref: PullRef) -> PullAuthorship? { known.withLock { $0[ref.description] } }

    public func record(_ authorship: PullAuthorship, for ref: PullRef) {
        known.withLock { $0[ref.description] = authorship }
    }

    /// Whether `ref` is trusted: nil until heed knows who it is from.
    public func trusted(_ ref: PullRef, viewer: String?) -> Bool? { authorship(ref)?.trusted(viewer: viewer) }

    /// What heed knows, else asked with `fetch` (and kept). A failed ask is not kept, and trusts nothing.
    public func resolve(
        _ ref: PullRef, viewer: String?, fetch: @Sendable (PullRef) async throws -> PullAuthorship
    ) async -> Bool {
        if let known = trusted(ref, viewer: viewer) { return known }
        guard let fetched = try? await fetch(ref) else { return false }
        record(fetched, for: ref)
        return fetched.trusted(viewer: viewer)
    }
}

public extension GitHub {
    /// Who a PR is from: `gh pr view --json author,authorAssociation,isCrossRepository`.
    static func pullAuthorship(_ ref: PullRef, caller: String) async throws -> PullAuthorship {
        let result = try await gh(
            ["pr", "view", "\(ref.number)", "-R", ref.repo.slug, "--json", PullAuthorship.fields],
            operation: "pr view", timeout: .seconds(30), caller: caller
        )
        guard result.succeeded, let authorship = PullAuthorship.parse(result.stdout) else {
            throw Failure(description: explain(result))
        }
        return authorship
    }
}
