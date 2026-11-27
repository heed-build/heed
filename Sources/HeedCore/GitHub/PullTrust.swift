import Foundation
import Synchronization

/// Whose PR heed treats as trusted, and who counts as someone who can write to the repo: the one definition both
/// Autopilot's merges (`HeedMerge`) and its runs (`PullAuthorship`, `Runs.ownStart`) use.
///
/// Someone can write to the repo when GitHub's author association says `OWNER` or `COLLABORATOR`, or when they are a
/// member of the organisation that owns it (`MEMBER`) and `gh api
/// repos/{owner}/{repo}/collaborators/{login}/permission`
/// says write, maintain or admin. Membership alone does not count.
///
/// A PR is trusted when it is yours, from any branch; or, on a branch of the repo itself, when someone who can write
/// to it opened it, or one of `trusted_authors` did. A PR from a fork is never trusted unless it is yours, whoever
/// opened it: anyone the fork's owner lets push to it can change it, so heed neither merges it on its own nor runs
/// your setup on it. Merge it by hand (`zM`).
public enum PullTrust {
    public struct Verdict: Hashable, Sendable {
        public let trusted: Bool
        public let text: String
    }

    /// Whether someone with this association can write to the repo: `verified` is what `gh` said about a member's
    /// permission (nil when not asked, or not known).
    public static func canWrite(_ trust: ExternalText.Trust, verified: Bool?) -> Bool {
        switch trust {
        case .owner, .collaborator: true
        case .member: verified == true
        case .bot, .stranger: false
        }
    }

    /// Whether a PR is trusted, and why, in the words the Watch view shows. `fork` nil is not known yet, and counts as
    /// a fork; `canWrite` is the permission `gh` gave for a member author.
    public static func author(
        login: String?, trust: ExternalText.Trust, fork: Bool?, viewer: String?, canWrite verified: Bool?,
        trustedAuthors: [String]
    ) -> Verdict {
        let who = login.map { "@" + $0 } ?? "someone"
        let byHand = "heed doesn't merge it on its own; merge it by hand (zM)"
        if let viewer, let login, login.lowercased() == viewer.lowercased() {
            return Verdict(trusted: true, text: "opened by you (\(who))")
        }
        switch fork {
        case true?: return Verdict(trusted: false, text: "\(who) opened it from a fork: \(byHand)")
        case nil: return Verdict(trusted: false, text: "heed doesn't know yet whether it is from a fork: \(byHand)")
        case false?: break
        }
        switch trust {
        case .owner: return Verdict(trusted: true, text: "opened by \(who), the repo's owner")
        case .collaborator: return Verdict(trusted: true, text: "opened by \(who), who can write to the repo")
        case .member where verified == true:
            return Verdict(trusted: true, text: "opened by \(who), an organisation member who can write to the repo")
        case .member, .bot, .stranger:
            let isBot = trust == .bot
            if let login, trustedAuthors.contains(where: { listed($0, login: login, isBot: isBot) }) {
                return Verdict(trusted: true, text: "opened by \(who), one of trusted_authors")
            }
            return Verdict(trusted: false, text: "\(notAWriter(who, trust: trust)): \(byHand)")
        }
    }

    /// Whether a `trusted_authors` entry names this author. A bot is named by an entry that says `[bot]` and a person
    /// by one that does not, and the author's type has to agree: nobody registers a login that a bot's name is, then
    /// is trusted as the bot, and a plain entry never trusts a bot.
    public static func listed(_ entry: String, login: String, isBot: Bool) -> Bool {
        guard entry.lowercased().hasSuffix("[bot]") == isBot else { return false }
        return GateCheck.normalize(entry) == GateCheck.normalize(login)
    }

    /// Why an author does not count: `@x isn't a collaborator`, and the like.
    public static func notAWriter(_ who: String, trust: ExternalText.Trust) -> String {
        switch trust {
        case .bot: "\(who) isn't in trusted_authors"
        case .member: "\(who) is an organisation member gh hasn't said can write to the repo"
        default: "\(who) isn't a collaborator"
        }
    }
}

/// Who a PR is from, as `gh pr view --json author,authorAssociation,isCrossRepository` says, and whether heed treats
/// its code as yours (`PullTrust`). A PR heed does not trust is someone else's: heed's runs on it work sandboxed,
/// copy none of your files in and run none of your setup, and none starts on it by itself.
public struct PullAuthorship: Hashable, Sendable {
    public var author: String?
    /// `OWNER`, `MEMBER`, `COLLABORATOR`, `CONTRIBUTOR`, `FIRST_TIME_CONTRIBUTOR`, `NONE`, …
    public var association: String?
    /// From a fork.
    public var crossRepository: Bool
    /// A GitHub App or bot account opened it.
    public var isBot: Bool
    /// For an organisation member: whether `gh` said their permission on the repo is write, maintain or admin; nil
    /// when not asked.
    public var canWrite: Bool?
    /// The head commit when heed asked who opened it: a run checks out exactly this one.
    public var headSHA: String?

    public init(
        author: String?, association: String?, crossRepository: Bool, isBot: Bool = false, canWrite: Bool? = nil,
        headSHA: String? = nil
    ) {
        self.headSHA = headSHA
        self.author = author
        self.association = association
        self.crossRepository = crossRepository
        self.isBot = isBot
        self.canWrite = canWrite
    }

    /// What a fetched PR says about its author, as `gh pr view` would.
    public init(_ detail: PullDetail) {
        let trust = detail.authorTrust
        let association: String? = switch trust {
        case .owner: "OWNER"
        case .collaborator: "COLLABORATOR"
        case .member: "MEMBER"
        case .bot, .stranger: nil
        }
        self.init(
            author: detail.author, association: association, crossRepository: detail.crossRepository ?? true,
            isBot: trust == .bot,
            canWrite: trust == .member ? detail.writers.map { $0.contains(detail.author?.lowercased() ?? "") } : nil
        )
    }

    /// Who opened it, as the author of its title and description: trust from the association, as everywhere else
    /// (`ExternalText.Trust`).
    public var by: ExternalText.Author {
        ExternalText.Author(login: author, trust: .from(association: association, isBot: isBot))
    }

    /// A member opened it and heed has not asked `gh` about their permission yet.
    public var needsPermission: Bool { by.trust == .member && canWrite == nil }

    /// Whether heed trusts it (`PullTrust.author`): `viewer` is your login.
    public func trusted(viewer: String?, trustedAuthors: [String]) -> Bool {
        PullTrust.author(
            login: author, trust: by.trust, fork: crossRepository, viewer: viewer, canWrite: canWrite,
            trustedAuthors: trustedAuthors
        ).trusted
    }

    /// From `gh pr view --json author,authorAssociation,isCrossRepository`; nil when it is not that.
    public static func parse(_ json: String) -> PullAuthorship? {
        guard let value = JSONValue.parse(json), value["isCrossRepository"] != nil || value["authorAssociation"] != nil
        else { return nil }
        let login = value["author"]?["login"]?.string
        return PullAuthorship(
            author: login, association: value["authorAssociation"]?.string,
            crossRepository: value["isCrossRepository"]?.bool ?? true,
            isBot: value["author"]?["is_bot"]?.bool == true || (login?.hasSuffix("[bot]") ?? false),
            headSHA: value["headSHA"]?.string
        )
    }

    /// The jq object body that shapes the REST pull request like the old `gh pr view --json author,authorAssociation,
    /// isCrossRepository` answer (see `GitHub.pullFacts`).
    public static let restFields = """
    author: {login: .user.login, is_bot: (.user.type == "Bot")}, authorAssociation: .author_association, \
    isCrossRepository: ((.head.repo.full_name // "") != .base.repo.full_name), headSHA: .head.sha
    """
}

/// Who each PR is from, once asked: so a run that is about to start on its own can tell without waiting. What it
/// knows is kept for `lifetime`, and replaced whenever a sync fetches the PR again (`record`).
public final class PullTrustBook: Sendable {
    public static let shared = PullTrustBook()
    /// How long an answer is kept before heed asks again.
    public static let lifetime: TimeInterval = 10 * 60

    private struct Entry { let authorship: PullAuthorship; let at: Date }

    private let known = Mutex<[String: Entry]>([:])
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    public init(ttl: TimeInterval = PullTrustBook.lifetime, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.clock = clock
    }

    /// What heed knows of the PR, while it is fresh.
    public func authorship(_ ref: PullRef) -> PullAuthorship? {
        let now = clock()
        return known.withLock { known in
            guard let entry = known[ref.description] else { return nil }
            guard now.timeIntervalSince(entry.at) < ttl else {
                known[ref.description] = nil
                return nil
            }
            return entry.authorship
        }
    }

    public func record(_ authorship: PullAuthorship, for ref: PullRef) {
        let now = clock()
        known.withLock { $0[ref.description] = Entry(authorship: authorship, at: now) }
    }

    /// Everything heed knows is asked again.
    public func forget() { known.withLock { $0.removeAll() } }

    /// Whether `ref` is trusted: nil until heed knows who it is from (a member author's permission included).
    public func trusted(_ ref: PullRef, viewer: String?, trustedAuthors: [String]) -> Bool? {
        guard let authorship = authorship(ref) else { return nil }
        let trusted = authorship.trusted(viewer: viewer, trustedAuthors: trustedAuthors)
        return !trusted && authorship.needsPermission ? nil : trusted
    }

    /// What heed knows, else asked with `fetch` (and kept). A failed ask is not kept, and trusts nothing.
    public func resolve(
        _ ref: PullRef, viewer: String?, trustedAuthors: [String],
        fetch: @Sendable (PullRef) async throws -> PullAuthorship
    ) async -> Bool {
        if let known = trusted(ref, viewer: viewer, trustedAuthors: trustedAuthors) { return known }
        guard let fetched = try? await fetch(ref) else { return false }
        record(fetched, for: ref)
        return fetched.trusted(viewer: viewer, trustedAuthors: trustedAuthors)
    }
}

/// What `gh` said about whether someone can write to a repo, kept for `lifetime`: the permission check behind an
/// organisation member's trust (`PullTrust`). A failed check is not kept, and counts as no write access.
public final class WriteAccessBook: Sendable {
    public static let shared = WriteAccessBook()
    public static let lifetime: TimeInterval = 10 * 60

    private struct Entry { let canWrite: Bool; let at: Date }

    private let known = Mutex<[String: Entry]>([:])
    private let ttl: TimeInterval
    private let clock: @Sendable () -> Date

    public init(ttl: TimeInterval = WriteAccessBook.lifetime, clock: @escaping @Sendable () -> Date = { Date() }) {
        self.ttl = ttl
        self.clock = clock
    }

    private static func key(
        _ repo: Repo,
        _ login: String
    ) -> String { "\(repo.slug.lowercased())|\(login.lowercased())" }

    /// The answer heed has, while it is fresh.
    public func canWrite(_ repo: Repo, _ login: String) -> Bool? {
        let now = clock()
        return known.withLock { known in
            guard let entry = known[Self.key(repo, login)] else { return nil }
            guard now.timeIntervalSince(entry.at) < ttl else {
                known[Self.key(repo, login)] = nil
                return nil
            }
            return entry.canWrite
        }
    }

    public func forget() { known.withLock { $0.removeAll() } }

    /// The answer heed has, else asked with `fetch` and kept.
    public func resolve(
        _ repo: Repo, _ login: String, fetch: @Sendable (Repo, String) async throws -> Bool
    ) async -> Bool {
        if let known = canWrite(repo, login) { return known }
        guard let answer = try? await fetch(repo, login) else { return false }
        let now = clock()
        known.withLock { $0[Self.key(repo, login)] = Entry(canWrite: answer, at: now) }
        return answer
    }

    /// Of `logins`, the ones that can write (lowercased), each asked once.
    public func writers(
        among logins: [String], in repo: Repo, fetch: @Sendable (Repo, String) async throws -> Bool
    ) async -> [String] {
        var writers: [String] = []
        for login in Set(logins.map { $0.lowercased() }).sorted() where await resolve(repo, login, fetch: fetch) {
            writers.append(login)
        }
        return writers
    }
}

public extension PullTrustBook {
    /// Whether `ref` is trusted, asking GitHub who it is from (`GitHub.pullAuthorship`) when heed does not know yet:
    /// the one way the app finds out before a run, helper or reviewer starts on a PR. `caller` names the ask in the
    /// call log.
    func resolveOnGitHub(_ ref: PullRef, viewer: String?, trustedAuthors: [String], caller: String) async -> Bool {
        await resolve(ref, viewer: viewer, trustedAuthors: trustedAuthors) { ref in
            try await GitHub.pullAuthorship(ref, caller: caller)
        }
    }
}

public extension GitHub {
    /// Who a PR is from: `gh pr view --json author,authorAssociation,isCrossRepository`, and for an organisation
    /// member, their permission on the repo (`canWrite`, through `WriteAccessBook.shared`).
    static func pullAuthorship(_ ref: PullRef, caller: String) async throws -> PullAuthorship {
        let result = try await pullFacts(ref, fields: PullAuthorship.restFields, caller: caller)
        guard result.succeeded, var authorship = PullAuthorship.parse(result.stdout) else {
            throw Failure(description: explain(result))
        }
        if authorship.needsPermission, let login = authorship.author {
            authorship.canWrite = await WriteAccessBook.shared.resolve(ref.repo, login) { repo, login in
                try await canWrite(repo, login: login, caller: caller)
            }
        }
        return authorship
    }

    /// What `gh pr view --json` used to say about a PR, read from the REST pull request instead: `gh pr view` has no
    /// `authorAssociation` field (gh 2.96 answers `Unknown JSON field`), and the REST pull request has it as
    /// `author_association`. `fields` is a jq object body, so the answer has the shape `PullAuthorship.parse` and
    /// `pullForReview` read: `author`, `authorAssociation`, `isCrossRepository` (a PR from a fork, or from a deleted
    /// fork) and the branch names, title and description.
    static func pullFacts(_ ref: PullRef, fields: String, caller: String) async throws -> ProcessResult {
        try await gh(
            ["api", "repos/\(ref.repo.slug)/pulls/\(ref.number)", "--jq", "{\(fields)}"],
            operation: "GET pull request", timeout: .seconds(30), caller: caller
        )
    }

    /// Whether `login` can write to `repo`: `gh api repos/{owner}/{repo}/collaborators/{login}/permission` says
    /// write, maintain or admin. A login GitHub would not allow is not asked about.
    static func canWrite(_ repo: Repo, login: String, caller: String) async throws -> Bool {
        guard login.range(of: #"^[A-Za-z0-9-]{1,39}$"#, options: .regularExpression) != nil else { return false }
        let result = try await gh(
            ["api", "repos/\(repo.slug)/collaborators/\(login)/permission"], operation: "GET collaborator permission",
            timeout: .seconds(20), caller: caller
        )
        guard result.succeeded, let canWrite = RepoPermission.canWrite(result.stdout) else {
            throw Failure(description: explain(result))
        }
        return canWrite
    }

    /// A fetched PR with `writers` filled in: which of its organisation members (author, reviewers, thread authors)
    /// can write to the repo, through `book`.
    static func withWriters(
        _ detail: PullDetail, book: WriteAccessBook = .shared,
        fetch: @Sendable (Repo, String) async throws -> Bool
    ) async -> PullDetail {
        var detail = detail
        detail.writers = await book.writers(among: detail.memberLogins, in: detail.ref.repo, fetch: fetch)
        return detail
    }
}

/// The answer of `gh api repos/{owner}/{repo}/collaborators/{login}/permission`.
public enum RepoPermission {
    /// Whether it says write, maintain or admin (`permission`, or the finer `role_name`); nil when it is not that
    /// answer.
    public static func canWrite(_ json: String) -> Bool? {
        guard let value = JSONValue.parse(json), let permission = value["permission"]?.string else { return nil }
        let writes: Set<String> = ["admin", "maintain", "write"]
        return writes.contains(permission.lowercased()) || writes
            .contains(value["role_name"]?.string?.lowercased() ?? "")
    }
}
