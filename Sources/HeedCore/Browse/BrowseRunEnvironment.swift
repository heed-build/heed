import Foundation

/// The environment a Browse run's agent, and everything it starts, inherit. Every run gets what `RunSandbox.kept`
/// keeps (where programs and home are, who you are, the language, heed's own variables and the agent's own login)
/// and nothing else: no `GH_TOKEN`, no cloud or ssh login, no `GIT_*`, `*_PROXY`, `LD_*`, `DYLD_*`, `PAGER`,
/// `EDITOR`, `NODE_OPTIONS` or `BASH_ENV` that a parent process happened to have, so there is nothing for
/// `echo $GH_TOKEN` to print and nothing that makes an allowed command run another.
public enum BrowseRunEnvironment {
    /// `parent` filtered to the kept names, `PATH` set to the one heed found the agent's tools on. `folder` is the
    /// run's scratch folder: an untrusted run's `gh` is pointed at an empty config folder in it, so it has no login.
    /// A trusted run's `gh` finds your login where it always does (in `HOME`), which is how it opens pull requests.
    /// Whether a run's `gh` has no login: an author heed does not trust, and every Chat, whoever wrote the item,
    /// because Chat's policy has bypasses. The one place that decides it.
    public static func emptyGitHubLogin(trusted: Bool, verb: BrowseVerb) -> Bool { !trusted || verb == .chat }

    /// Whether a run signs commits with what you already have open: a trusted run that writes (Fix, Implement), never a
    /// Chat or Review and never an untrusted author's run. `nil` is no verb: no signing.
    public static func mayUseSigningAgent(trusted: Bool, verb: BrowseVerb?) -> Bool {
        trusted && (verb == .fix || verb == .implement)
    }

    /// What a signed commit needs from the environment, kept for a run that may use the signing agent and for no
    /// other: the ssh agent's socket (`commit.gpgsign` with `gpg.format = ssh`, the key held by the agent) and where
    /// gpg keeps its home and agent (`gpg.format = openpgp`). Everything else stays scrubbed.
    public static let signingVariables = ["SSH_AUTH_SOCK", "GNUPGHOME", "GPG_AGENT_INFO"]

    public static func make(
        _ parent: [String: String], agent: String, folder: String, trusted: Bool, verb: BrowseVerb? = nil,
        path: String?
    ) -> [String: String] {
        var environment = RunSandbox.kept(GitEnvironment.scrubbed(parent), agent: agent, folder: folder)
        if let path, !path.isEmpty { environment["PATH"] = path }
        if !emptyGitHubLogin(trusted: trusted, verb: verb ?? .fix) { environment["GH_CONFIG_DIR"] = nil }
        if mayUseSigningAgent(trusted: trusted, verb: verb) {
            for name in signingVariables {
                if let value = parent[name], !value.isEmpty { environment[name] = value }
            }
        }
        return environment
    }
}
