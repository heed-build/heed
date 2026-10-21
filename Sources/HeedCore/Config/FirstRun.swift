import Foundation

/// What the first-run screen shows (design/screens/FirstRun.png), gathered off the main actor.
public struct FirstRunReport: Equatable, Sendable {
    public struct AgentFound: Equatable, Sendable {
        public let name: String
        /// Where its command resolves on the detected search path; nil when it is not installed.
        public let path: String?

        public init(name: String, path: String?) {
            self.name = name
            self.path = path
        }
    }

    public var githubUser: String?
    public var githubProblem: String?
    public var agents: [AgentFound]
    /// git and gh, and the search path agents were looked up on.
    public var tools: ToolReport?

    public init(
        githubUser: String? = nil, githubProblem: String? = nil, agents: [AgentFound] = [], tools: ToolReport? = nil
    ) {
        self.githubUser = githubUser
        self.githubProblem = githubProblem
        self.agents = agents
        self.tools = tools
    }

    /// Checks gh and looks each agent's command up on the detected search path (an app opened from Finder has a
    /// minimal PATH; see `ToolDetection`).
    public static func gather(agents: [AgentProfile]) async -> FirstRunReport {
        let tools = await ToolLocator.shared.report()
        var problem: String?
        var login: String?
        if let missing = tools.tool("gh"), missing.path == nil {
            problem = missing.problem
        } else {
            do { login = try await GitHub.viewer(caller: "firstRun.check") } catch { problem = "\(error)" }
        }
        let found = agents.map { agent in
            let command = agent.command.split(separator: " ").first.map(String.init) ?? agent.command
            return AgentFound(name: agent.name, path: ToolDetection.find(command, in: tools.searchPath))
        }
        return FirstRunReport(githubUser: login, githubProblem: problem, agents: found, tools: tools)
    }
}
