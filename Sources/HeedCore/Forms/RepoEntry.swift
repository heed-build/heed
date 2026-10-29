import Foundation

/// A repo typed into a form rather than picked from the known ones (the new swarm form's repo field): `owner/name`, a
/// GitHub URL, or a path to a checkout on this Mac. `parse` reads the words (the format, at once, as you type);
/// `note` says what heed knows about it: a repo already here, one GitHub knows (cached, or asked with `gh repo view`),
/// one that does not exist, or one still being checked.
public enum RepoEntry {
    public enum Parsed: Equatable, Hashable, Sendable {
        case slug(Repo)
        /// A path as typed (`~/code/x`, `/Users/me/x`, `./x`): it must hold a git checkout.
        case path(String)

        /// What a lookup is keyed by: the slug lowercased, or the path.
        public var key: String {
            switch self {
            case let .slug(repo): repo.slug.lowercased()
            case let .path(path): path
            }
        }
    }

    /// What a check found. A slug is asked of GitHub (`gh repo view`); a path is looked at on disk.
    public enum Lookup: Equatable, Sendable {
        case checking
        /// The repo, as GitHub spells it, or the one checked out at the path.
        case found(Repo)
        case missing
        /// The check itself failed (gh not signed in, offline): the words why.
        case failed(String)
    }

    /// The field it is a note on.
    public static let field = "repos"

    /// The typed words read as a repo; nil when nothing is typed, a problem note when they are neither a repo nor a
    /// path.
    public static func parse(_ text: String) -> Result<Parsed, FieldNote>? {
        var typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !typed.isEmpty else { return nil }
        if typed.hasPrefix("/") || typed.hasPrefix("~") || typed.hasPrefix("./") || typed.hasPrefix("../") {
            return .success(.path(typed))
        }
        for prefix in ["https://github.com/", "http://github.com/", "github.com/", "git@github.com:"]
            where typed.lowercased().hasPrefix(prefix)
        {
            typed = String(typed.dropFirst(prefix.count))
            if typed.hasSuffix("/") { typed = String(typed.dropLast()) }
            if typed.hasSuffix(".git") { typed = String(typed.dropLast(4)) }
        }
        let parts = typed.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            return .failure(FieldNote(
                field,
                "\(text.trimmingCharacters(in: .whitespaces)) is not owner/name, "
                    + "a GitHub URL or a path (~/code/x)"
            ))
        }
        if let problem = ownerProblem(parts[0]) ?? nameProblem(parts[1]) {
            return .failure(FieldNote(field, problem))
        }
        return .success(.slug(Repo(org: parts[0], name: parts[1])))
    }

    /// GitHub's rules for a login: letters, digits and single dashes inside, at most 39.
    static func ownerProblem(_ owner: String) -> String? {
        if owner.isEmpty { return "owner/name needs an owner before the /" }
        let allowed = owner.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }
        guard allowed, !owner.hasPrefix("-"), !owner.hasSuffix("-"), !owner.contains("--"), owner.count <= 39 else {
            return "\(owner) cannot be a GitHub owner: letters, digits and single dashes"
        }
        return nil
    }

    /// GitHub's rules for a repo's name: letters, digits, `-`, `_` and `.`, at most 100, not `.` or `..`.
    static func nameProblem(_ name: String) -> String? {
        if name.isEmpty { return "owner/name needs a name after the /" }
        let allowed = name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "-_.".contains($0)) }
        guard allowed, name != ".", name != "..", name.count <= 100 else {
            return "\(name) cannot be a repo's name: letters, digits, - _ and ."
        }
        return nil
    }

    /// What heed knows about the parsed entry, where the form runs it (`place`: "this Mac", "@devbox").
    /// `here`: the slugs checked out there; `known`: slugs heed has seen anywhere (other hosts, PRs, issues), which
    /// are taken to exist without asking; `lookups`: answers so far, by `Parsed.key`. `local`: the form runs on this
    /// Mac (a path is only read there). `clonesInto`: where a repo that is not there yet is cloned.
    public static func note(
        _ parsed: Parsed, place: String, local: Bool, here: [String], known: [String], lookups: [String: Lookup],
        clonesInto: String, starting: String = "the swarm starts"
    ) -> FieldNote {
        switch parsed {
        case let .path(path):
            guard local else {
                return FieldNote(field, "a path is read on this Mac; on \(place) type owner/name")
            }
            switch lookups[parsed.key] {
            case let .found(repo)?:
                return FieldNote(field, "\(repo.slug), checked out at \(path): ↩ adds it", tone: .fine)
            case .missing?: return FieldNote(field, "no git checkout at \(path)")
            case let .failed(why)?: return FieldNote(field, "could not read \(path): \(why)")
            case .checking?, nil: return FieldNote(field, "looking at \(path)…", tone: .checking)
            }
        case let .slug(repo):
            if let slug = match(repo, in: here) {
                return FieldNote(field, "\(slug) is on \(place): ↩ adds it", tone: .fine)
            }
            let clone = "\(clonesInto)/\(repo.name)"
            if let slug = match(repo, in: known) {
                return FieldNote(
                    field,
                    "\(slug): ↩ adds it; heed clones it into \(clone) on \(place) when "
                        + starting,
                    tone: .fine
                )
            }
            switch lookups[parsed.key] {
            case let .found(found)?:
                return FieldNote(
                    field,
                    "\(found.slug) is on GitHub: ↩ adds it; heed clones it into \(clone) on "
                        + "\(place) when \(starting)",
                    tone: .fine
                )
            case .missing?:
                return FieldNote(field, "no repo \(repo.slug) on GitHub (or gh cannot see it)")
            case let .failed(why)?:
                return FieldNote(field, "could not check \(repo.slug) on GitHub: \(why)")
            case .checking?, nil:
                return FieldNote(field, "checking \(repo.slug) on GitHub…", tone: .checking)
            }
        }
    }

    /// A slug heed keeps (`org/name`) as a repo.
    public static func repo(_ slug: String) -> Repo {
        let parts = slug.split(separator: "/", maxSplits: 1).map(String.init)
        return Repo(org: parts.first ?? "", name: parts.count > 1 ? parts[1] : "")
    }

    /// The slug as heed knows it (GitHub's names are case-insensitive), or nil.
    public static func match(_ repo: Repo, in slugs: [String]) -> String? {
        slugs.first { $0.lowercased() == repo.slug.lowercased() }
    }

    /// What a fine entry adds to the form's repos: the slug as heed or GitHub spells it.
    public static func picked(_ parsed: Parsed, here: [String], known: [String], lookups: [String: Lookup]) -> String? {
        switch parsed {
        case .path:
            if case let .found(repo)? = lookups[parsed.key] { return repo.slug }
            return nil
        case let .slug(repo):
            if let slug = match(repo, in: here) ?? match(repo, in: known) { return slug }
            if case let .found(found)? = lookups[parsed.key] { return found.slug }
            return nil
        }
    }

    /// Whether a slug needs asking of GitHub: not checked out there, not seen anywhere, not asked yet.
    public static func needsLookup(_ parsed: Parsed, here: [String], known: [String], lookups: [String: Lookup])
        -> Bool
    {
        guard lookups[parsed.key] == nil else { return false }
        if case let .slug(repo) = parsed { return match(repo, in: here) == nil && match(repo, in: known) == nil }
        return true
    }

    /// The command that clones a repo the form picked into `root` where the swarm runs (`gh repo clone`, so gh's git
    /// protocol and sign-in apply).
    public static func cloneArguments(_ repo: Repo, into root: String) -> [String] {
        ["repo", "clone", repo.slug, "\(root)/\(repo.name)"]
    }

    /// `gh repo view`'s `nameWithOwner`, read back: the repo as GitHub spells it.
    public static func parseView(_ output: String) -> Repo? {
        guard case let .success(.slug(repo))? = parse(output) else { return nil }
        return repo
    }
}
