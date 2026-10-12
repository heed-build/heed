import Foundation

/// What the first-run screen shows (design/screens/FirstRun.png), gathered off the main actor.
public struct FirstRunReport: Equatable, Sendable {
    public struct AgentFound: Equatable, Sendable {
        public let name: String
        /// Where its command resolves in your login shell; nil when it is not installed.
        public let path: String?

        public init(name: String, path: String?) {
            self.name = name
            self.path = path
        }
    }

    public var githubUser: String?
    public var githubProblem: String?
    public var agents: [AgentFound]

    public init(githubUser: String? = nil, githubProblem: String? = nil, agents: [AgentFound] = []) {
        self.githubUser = githubUser
        self.githubProblem = githubProblem
        self.agents = agents
    }

    /// Checks gh and resolves each agent's command in a login shell (an app opened from Finder has a minimal PATH;
    /// panes use the login shell's).
    public static func gather(agents: [AgentProfile]) async -> FirstRunReport {
        async let user: String? = try? GitHub.viewer()
        var found: [AgentFound] = []
        for agent in agents {
            let command = agent.command.split(separator: " ").first.map(String.init) ?? agent.command
            let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
            let path = try? await ProcessRunner.output(
                shell,
                ["-lc", "command -v \(ShellQuote.quote(command))"],
                timeout: .seconds(10)
            )
            let resolved = path?.trimmingCharacters(in: .whitespacesAndNewlines)
            found.append(AgentFound(name: agent.name, path: resolved?.isEmpty == false ? resolved : nil))
        }
        let login = await user
        return FirstRunReport(
            githubUser: login, githubProblem: login == nil ? "gh is not signed in: run gh auth login" : nil,
            agents: found
        )
    }
}
