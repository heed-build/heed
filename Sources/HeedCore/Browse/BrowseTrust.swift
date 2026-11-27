import Foundation

/// Whether heed runs an agent with its hands on an item: the same rule as everywhere (`PullTrust`). Someone's work is
/// trusted when it is yours, or someone who can write to the repo wrote it, or `trusted_authors` names them. A pull
/// request from a fork is never trusted unless it is yours. From anyone else a Browse run is a Chat: it reads, edits
/// nothing and runs none of the repo's code, and says why.
public enum BrowseTrust {
    public struct Verdict: Equatable, Sendable {
        public var trusted: Bool
        /// In the words the run's header and feed use.
        public var text: String
        /// A pull request's head is this repo's own branch, so a push can go to it.
        public var canPush: Bool
    }

    /// Whether a `trusted_authors` entry names this author. A bot is named by an entry that says `[bot]` and a person
    /// by one that does not, and the author's type has to agree: nobody registers a login that a bot's name is, then
    /// is trusted as the bot, and an app slug that is nobody's account yet is not a person's.
    static func listed(_ entry: String, login: String, isBot: Bool) -> Bool {
        let namesABot = entry.lowercased().hasSuffix("[bot]")
        guard namesABot == isBot else { return false }
        return GateCheck.normalize(entry) == GateCheck.normalize(login)
    }

    /// An issue: `canWrite` is what `gh` said about the author's permission on the repo (nil: not asked or not known).
    public static func issue(
        _ item: BrowseItem, viewer: String?, canWrite: Bool?, trustedAuthors: [String]
    ) -> Verdict {
        let who = item.author.map { "@" + $0 } ?? "someone"
        guard let login = item.author else {
            return Verdict(trusted: false, text: "heed does not know who opened it", canPush: true)
        }
        if let viewer, login.caseInsensitiveCompare(viewer) == .orderedSame {
            return Verdict(trusted: true, text: "opened by you", canPush: true)
        }
        if item.authorIsBot {
            if trustedAuthors.contains(where: { listed($0, login: login, isBot: true) }) {
                return Verdict(trusted: true, text: "opened by \(who), one of trusted_authors", canPush: true)
            }
            return Verdict(trusted: false, text: "\(who) isn't in trusted_authors", canPush: true)
        }
        if canWrite == true {
            return Verdict(trusted: true, text: "opened by \(who), who can write to the repo", canPush: true)
        }
        if trustedAuthors.contains(where: { listed($0, login: login, isBot: false) }) {
            return Verdict(trusted: true, text: "opened by \(who), one of trusted_authors", canPush: true)
        }
        return Verdict(trusted: false, text: "\(who) can't write to \(item.repo.slug)", canPush: true)
    }

    /// A pull request, from what `gh pr view` said of its author (`PullAuthorship`).
    public static func pull(_ authorship: PullAuthorship, viewer: String?, trustedAuthors: [String]) -> Verdict {
        let verdict = PullTrust.author(
            login: authorship.author, trust: authorship.by.trust, fork: authorship.crossRepository, viewer: viewer,
            canWrite: authorship.canWrite, trustedAuthors: trustedAuthors
        )
        return Verdict(trusted: verdict.trusted, text: verdict.text, canPush: !authorship.crossRepository)
    }

    /// The reason a Chat-only run gives.
    public static func chatOnly(_ verdict: Verdict) -> BrowseRun.Mode {
        verdict.trusted ? .full : .chatOnly(reason: verdict.text)
    }
}
