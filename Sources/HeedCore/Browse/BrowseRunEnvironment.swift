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
    public static func make(
        _ parent: [String: String], agent: String, folder: String, trusted: Bool, path: String?
    ) -> [String: String] {
        var environment = RunSandbox.kept(GitEnvironment.scrubbed(parent), agent: agent, folder: folder)
        if let path, !path.isEmpty { environment["PATH"] = path }
        if trusted { environment["GH_CONFIG_DIR"] = nil }
        return environment
    }
}
