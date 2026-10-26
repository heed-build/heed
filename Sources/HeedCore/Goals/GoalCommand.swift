import Foundation

/// One `heed goal …` command, as the CLI parses it and the control socket carries it to the app. The app runs it
/// through `GoalControl` (and `GoalOps`), never the CLI process: the CLI only parses and prints.
public struct GoalCommand: Codable, Equatable, Sendable {
    public enum Verb: String, Codable, Sendable, CaseIterable {
        case list, show, attach
        case itemAdd = "item add", itemDone = "item done", itemMove = "item move", itemSpawn = "item spawn"
        case decisionAdd = "decision add"
        case questionAdd = "question add", questionAnswer = "question answer"
        case criterionCheck = "criterion check"
        case propose
        case linkPR = "link pr"
        case reviewRequest = "review request"
    }

    public var verb: Verb
    /// `--goal`: the goal to work on instead of the calling session's.
    public var goal: String?
    /// `--json`: answer as JSON, for agents and scripts.
    public var json: Bool
    /// What the verb is about: an item id, a question, a criterion's number or text, a section, a PR, a reviewer kind,
    /// a goal to attach to.
    public var subject: String?
    /// The words after the subject (a title, a decision, an answer, a column).
    public var text: String?
    public var parent: String?
    public var bySubagent: String?
    public var evidence: String?
    public var agent: String?
    public var item: String?
    public var background: Bool

    public init(
        _ verb: Verb, goal: String? = nil, json: Bool = false, subject: String? = nil, text: String? = nil,
        parent: String? = nil, bySubagent: String? = nil, evidence: String? = nil, agent: String? = nil,
        item: String? = nil, background: Bool = false
    ) {
        self.verb = verb
        self.goal = goal
        self.json = json
        self.subject = subject
        self.text = text
        self.parent = parent
        self.bySubagent = bySubagent
        self.evidence = evidence
        self.agent = agent
        self.item = item
        self.background = background
    }

    /// Record-kind commands apply at once (each a new version or item, undoable in the Goals view); scope-kind commands
    /// become proposals that wait for you, as in the UI. `criterion check` records only with evidence, which the
    /// parser insists on; `propose` is whatever `GoalEdits.classify` says, so a proposed decision still records.
    public var changesScope: Bool { verb == .propose }
}

/// How `heed goal` ends: agents read the code before the words.
public enum GoalExit: Int32, Codable, Sendable {
    /// Done (or proposed, when the command proposes).
    case ok = 0
    /// Heed refused: no such goal, item or column, nothing changed.
    case refused = 1
    /// The command line is wrong; the usage was printed.
    case usage = 2
    /// Heed is not running, or not reachable from here.
    case unreachable = 3
    /// No goal to work on: the session is on none and no `--goal` was given.
    case noGoal = 4
    /// Held for you: over the goal's spawn cap, asked in Attention.
    case waiting = 5
}

/// `heed goal …` from a terminal or an agent's shell.
public enum GoalCommandLine {
    public static let usage = """
    usage: heed goal [--goal <id>] [--json] <command>

    The goal is the one this session is on (HEED_SESSION_ID, set in every Heed pane); --goal names another.

    Read
      list                                   every goal: id, status, criteria met, items, title
      show                                   GOAL.md, items with their stages, quality bars and scores
    Record (applies at once, versioned, undoable in Heed)
      attach [<goal>]                        put this session on a goal (no goal: say which it is on)
      item add <title> [--parent <id>] [--by-subagent <name>]
                                             new work; --parent splits an item, --by-subagent names who does it
      item done <id> [--evidence <text>]     the item's card to Done
      item move <id> <column>                explore, planned, working, verify, done
      decision add <text>                    a decision taken, into GOAL.md
      question add <text>                    an open question, as a card in To explore
      question answer <id|question> <text>   the answer becomes a decision; the question closes
      criterion check <n|text> --evidence <text>
                                             a Done when criterion met; evidence is required
      link pr <url|org/repo#n|#n> [--item <id>]
                                             a PR on the goal (and on an item)
    Scope (waits for you as a proposal, like edits in the Goals view)
      propose <section> <text>               section: goal, not-the-goal, done-when, question, decision
    Work
      item spawn <id> [--agent <name>] [--background]
                                             start a session on the item, on this goal (capped per goal per day)
      review request <kind>                  ask the goal's reviewer of that kind for a re-check

    Item ids are <goal>/<slug> or just <slug>. Exit codes: 0 done or proposed, 1 refused, 2 usage, 3 Heed not
    reachable, 4 no goal (attach first or pass --goal), 5 held for you in Attention.
    """

    /// The goal of a run with no session (a spawned background run), when `--goal` is not given.
    public static let goalVariable = "HEED_GOAL"

    /// `heed goal`, `heed goal --help`, `heed goal help`: the usage, on stdout, exit 0.
    public static func wantsHelp(_ arguments: [String]) -> Bool {
        let words = arguments.first == "goal" ? Array(arguments.dropFirst()) : arguments
        return words.isEmpty || words.contains { $0 == "-h" || $0 == "--help" } || words.first == "help"
    }

    /// The control request `arguments` make, from the pane in `environment` (its `HEED_SESSION_ID`).
    public static func request(_ arguments: [String], environment: [String: String]) throws -> ControlRequest {
        let session = environment[HeedEnvironment.sessionID].flatMap { $0.isEmpty ? nil : $0 }
        var command = try parse(arguments)
        // A background run has no session: heed tells it its goal instead.
        if command.goal == nil, session == nil, let goal = environment[goalVariable], !goal.isEmpty {
            command.goal = goal
        }
        return ControlRequest(method: .goal, session: session, goal: command)
    }

    /// What the CLI prints and how it exits, from heed's reply.
    public static func finish(_ reply: ControlReply, json: Bool) -> (out: String?, err: String?, code: Int32) {
        guard let goal = reply.goal else {
            return (
                nil,
                "heed goal: \(reply.error ?? "Heed did not answer: is it older than this heed?")",
                GoalExit.refused.rawValue
            )
        }
        let text = goal.rendered(json: json)
        return goal.exit == .ok || json ? (text, nil, goal.exit.rawValue) : (
            nil,
            "heed goal: " + text,
            goal.exit.rawValue
        )
    }

    /// The command `arguments` make (`goal` first, as `heed` passes them).
    public static func parse(_ arguments: [String]) throws -> GoalCommand {
        var words: [String] = []
        var options: [String: String] = [:]
        var json = false
        var background = false
        var rest = ArraySlice(arguments.first == "goal" ? Array(arguments.dropFirst()) : arguments)
        let valued: Set = ["--goal", "--parent", "--by-subagent", "--evidence", "--agent", "--item"]
        while let word = rest.popFirst() {
            switch word {
            case "--json": json = true
            case "--background": background = true
            case "-h", "--help", "help": throw usageError(nil)
            case _ where valued.contains(word):
                guard let value = rest.popFirst(), !value.isEmpty else { throw usageError("\(word) needs a value") }
                options[word] = value
            case _ where word.hasPrefix("--") && word.contains("="):
                let parts = word.split(separator: "=", maxSplits: 1).map(String.init)
                guard valued.contains(parts[0]), parts.count == 2, !parts[1].isEmpty else {
                    throw usageError("unknown option \(parts[0])")
                }
                options[parts[0]] = parts[1]
            case _ where word.hasPrefix("--"):
                throw usageError("unknown option \(word)")
            default: words.append(word)
            }
        }
        guard let first = words.first else { throw usageError(nil) }
        let verb: GoalCommand.Verb
        var args = Array(words.dropFirst())
        switch first {
        case "list", "ls": verb = .list
        case "show": verb = .show
        case "attach": verb = .attach
        case "propose": verb = .propose
        case "item", "decision", "question", "criterion", "link", "review":
            guard let second = args.first else { throw usageError("\(first) needs a command") }
            args.removeFirst()
            guard let found = GoalCommand.Verb(rawValue: "\(first) \(second)") else {
                throw usageError("no command \(first) \(second)")
            }
            verb = found
        default: throw usageError("no command \(first)")
        }
        var command = GoalCommand(
            verb, goal: options["--goal"], json: json, parent: options["--parent"],
            bySubagent: options["--by-subagent"], evidence: options["--evidence"], agent: options["--agent"],
            item: options["--item"], background: background
        )
        // Which options each command takes: anything else is a mistake worth saying, not ignoring.
        let allowed: Set<String> = switch verb {
        case .itemAdd: ["--parent", "--by-subagent"]
        case .itemDone, .criterionCheck, .decisionAdd: ["--evidence"]
        case .itemSpawn: ["--agent"]
        case .linkPR: ["--item"]
        default: []
        }
        for option in options.keys where option != "--goal" && !allowed.contains(option) {
            throw usageError("\(verb.rawValue) takes no \(option)")
        }
        if background, verb != .itemSpawn { throw usageError("\(verb.rawValue) takes no --background") }
        func joined(_ words: ArraySlice<String>) -> String? {
            let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        switch verb {
        case .list, .show:
            guard args.isEmpty else { throw usageError("\(verb.rawValue) takes no words") }
        case .attach:
            guard args.count <= 1 else { throw usageError("attach takes one goal") }
            command.subject = args.first
        case .itemAdd, .decisionAdd, .questionAdd:
            guard let text = joined(args[...]) else { throw usageError("\(verb.rawValue) needs text") }
            command.text = text
        case .itemDone, .itemSpawn:
            guard args.count == 1 else { throw usageError("\(verb.rawValue) takes one item id") }
            command.subject = args[0]
        case .itemMove:
            guard args.count == 2 else { throw usageError("item move takes an item id and a column") }
            guard Board.Column(word: args[1]) != nil else {
                throw usageError("no column \(args[1]) (\(Board.Column.allCases.map(\.word).joined(separator: ", ")))")
            }
            command.subject = args[0]
            command.text = args[1]
        case .questionAnswer:
            guard args.count >= 2, let text = joined(args.dropFirst()) else {
                throw usageError("question answer takes a question and an answer")
            }
            command.subject = args[0]
            command.text = text
        case .criterionCheck:
            guard let subject = joined(args[...]) else { throw usageError("criterion check needs a criterion") }
            guard command.evidence?.trimmingCharacters(in: .whitespaces).isEmpty == false else {
                throw usageError("criterion check needs --evidence: a criterion is met only with evidence")
            }
            command.subject = subject
        case .propose:
            guard let section = args.first, GoalCommandLine.section(section) != nil else {
                throw usageError("propose takes a section: \(sections.joined(separator: ", "))")
            }
            guard let text = joined(args.dropFirst()) else { throw usageError("propose needs text") }
            command.subject = section
            command.text = text
        case .linkPR:
            guard args.count == 1, let pr = args.first else { throw usageError("link pr takes one PR") }
            guard pr.hasPrefix("#") || PullRef(url: pr) != nil || PullRef(slug: pr) != nil else {
                throw usageError("not a PR: \(pr) (a URL, org/repo#n or #n)")
            }
            command.subject = pr
        case .reviewRequest:
            guard args.count == 1 else { throw usageError("review request takes one reviewer kind") }
            command.subject = args[0]
        }
        return command
    }

    public static let sections = ["goal", "not-the-goal", "done-when", "question", "decision"]

    /// The GOAL.md section `propose` names.
    public static func section(_ word: String) -> GoalEdit.Section? {
        switch word.lowercased() {
        case "goal": .goal
        case "not-the-goal", "non-goal", "nongoal": .notTheGoal
        case "done-when", "criterion": .doneWhen
        case "question", "open-question": .openQuestions
        case "decision": .decisions
        default: nil
        }
    }

    static func usageError(_ problem: String?) -> HookCommandLine.UsageError {
        HookCommandLine.UsageError(description: problem.map { "heed goal: \($0)\n\n\(usage)" } ?? usage)
    }
}
