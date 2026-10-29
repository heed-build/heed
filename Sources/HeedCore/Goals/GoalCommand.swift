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
        case planPropose = "plan propose", planShow = "plan show", planApprove = "plan approve"
        case ask
        /// `heed swarm send|note|answer`.
        case swarmSend = "swarm send", swarmNote = "swarm note", swarmAnswer = "swarm answer"
        /// `heed swarm summary`: the lead's end-of-build summary.
        case swarmSummary = "swarm summary"
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
    /// `plan propose --note`: what the proposal changes, in a line.
    public var note: String?
    /// `plan propose --file`: where the plan's JSON is (`-`: stdin). The CLI reads it into `text`.
    public var file: String?
    /// `ask --option`: the choices, in order.
    public var options: [String]?
    /// Sent by a background run (its goal from `HEED_GOAL`), not from a pane or a terminal.
    public var fromRun: Bool?
    /// `ask --effect`: what each option would change, in the order of `options` (empty where none was given).
    public var effects: [String]?
    /// `ask --to`: whom the question is for (`lead`, `you`, a task); `swarm send`: whom the message is for.
    public var to: String?
    /// `ask --timeout <minutes>` (`--no-wait`: 0): how long the CLI waits for the answer. The app ignores it.
    public var timeout: Double?
    /// `ask --id <n>`: a question asked before, read again (the CLI's own polls set it too).
    public var question: Int64?
    /// `swarm summary --decision`, `--follow-up`: the lead's decisions and follow-ups.
    public var decisions: [String]?
    public var followUps: [String]?

    public init(
        _ verb: Verb, goal: String? = nil, json: Bool = false, subject: String? = nil, text: String? = nil,
        parent: String? = nil, bySubagent: String? = nil, evidence: String? = nil, agent: String? = nil,
        item: String? = nil, background: Bool = false, note: String? = nil, file: String? = nil,
        options: [String]? = nil, effects: [String]? = nil, to: String? = nil, timeout: Double? = nil,
        question: Int64? = nil
    ) {
        self.effects = effects
        self.to = to
        self.timeout = timeout
        self.question = question
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
        self.note = note
        self.file = file
        self.options = options
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
    /// `ask` waited its timeout and no answer came: the question stays open (`heed goal ask --id <n>` waits again).
    case timedOut = 6
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
      criterion check <n|text> --evidence <text> [--item <id>]
                                             a Done when criterion met; evidence is required. With --item, a line
                                             of a swarm task's done-when instead of GOAL.md's
      link pr <url|org/repo#n|#n> [--item <id>]
                                             a PR on the goal (and on an item)
    Scope (waits for you as a proposal, like edits in the Goals view)
      propose <section> <text>               section: goal, not-the-goal, done-when, question, decision
    Work
      item spawn <id> [--agent <name>] [--background]
                                             start a session on the item, on this goal (capped per goal per day)
      review request <kind>                  ask the goal's reviewer of that kind for a re-check
    Swarm (the goal's swarm run; its lead drafts the plan, the owner approves it)
      plan show                              the plan: tasks by phase, questions and answers, feedback to act on
      plan propose --file <path|-> [--note <text>]
                                             a plan as JSON (tasks with id, title, phase, owner, estimate, after,
                                             doneWhen; scope for GOAL.md changes): before approval it is the draft,
                                             after it small changes apply and structural ones wait
      plan approve                           approve the plan (the owner, from a terminal; never an agent)
      ask <question> [--option <a> [--effect <what a changes>]]... [--to lead|you|<task>]
          [--timeout <minutes>|--no-wait]
                                             a question, and wait for its answer (printed on stdout). heed decides
                                             who may answer: the lead (scope), a peer (--to <task>, or the task
                                             yours waits for), heed's controller (reversible choices, repeats of
                                             the owner's answers), the owner (the goal, limits, deleting data,
                                             merging to main, more agents or time). Waits 9 minutes by default (give
                                             your shell tool its longest timeout), then exits 6
      ask --id <n> [--timeout <minutes>]     wait again for the answer to question n
    heed swarm send|note|answer (heed swarm --help): messages to other agents, progress notes, answers

    Item ids are <goal>/<slug> or just <slug>. Exit codes: 0 done, proposed or answered, 1 refused, 2 usage, 3
    Heed not reachable, 4 no goal (attach first or pass --goal), 5 held for you in Attention, 6 no answer before
    the timeout (the question stays open).
    """

    /// The goal of a run with no session (a spawned background run), when `--goal` is not given.
    public static let goalVariable = "HEED_GOAL"

    /// `heed goal`, `heed goal --help`, `heed goal help`: the usage, on stdout, exit 0.
    public static func wantsHelp(_ arguments: [String]) -> Bool {
        let words = arguments.first == "goal" || arguments.first == "swarm" ? Array(arguments.dropFirst()) : arguments
        return words.isEmpty || words.contains { $0 == "-h" || $0 == "--help" } || words.first == "help"
    }

    /// The control request `arguments` make, from the pane in `environment` (its `HEED_SESSION_ID`). `read` reads
    /// `--file` (`-` is stdin) for `plan propose`.
    public static func request(
        _ arguments: [String], environment: [String: String], read: (String) throws -> String = readFile
    ) throws -> ControlRequest {
        let session = environment[HeedEnvironment.sessionID].flatMap { $0.isEmpty ? nil : $0 }
        var command = try arguments.first == "swarm" ? SwarmCommandLine.parse(arguments) : parse(arguments)
        // A background run has no session: heed tells it its goal instead.
        if session == nil, let goal = environment[goalVariable], !goal.isEmpty {
            if command.goal == nil { command.goal = goal }
            command.fromRun = true
        }
        if let file = command.file {
            do {
                command.text = try read(file)
            } catch {
                throw usageError(
                    "could not read \(file == "-" ? "the plan on stdin" : file): \(error.localizedDescription)"
                )
            }
        }
        let pane = environment[HeedEnvironment.pane].flatMap { $0.isEmpty ? nil : $0 }
        return ControlRequest(method: .goal, session: session, goal: command, pane: session == nil ? nil : pane)
    }

    /// A file's text, or stdin's for `-`.
    public static func readFile(_ path: String) throws -> String {
        if path == "-" { return String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self) }
        return try String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8)
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
        let valued: Set = [
            "--goal", "--parent", "--by-subagent", "--evidence", "--agent", "--item", "--note", "--file", "--option",
            "--effect", "--to", "--timeout", "--id",
        ]
        var choices: [String] = []
        var effects: [String] = []
        var noWait = false
        while let word = rest.popFirst() {
            switch word {
            case "--json": json = true
            case "--no-wait":
                noWait = true
                options["--no-wait"] = ""
            case "--option":
                guard let value = rest.popFirst(), !value.isEmpty else { throw usageError("--option needs a value") }
                choices.append(value)
                effects.append("")
                options["--option"] = value
            case "--effect":
                guard let value = rest.popFirst(), !value.isEmpty else { throw usageError("--effect needs a value") }
                guard !choices.isEmpty else { throw usageError("--effect says what the --option before it changes") }
                effects[choices.count - 1] = value
                options["--effect"] = value
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
                if parts[0] == "--option" {
                    choices.append(parts[1])
                    effects.append("")
                }
                if parts[0] == "--effect" {
                    guard !choices.isEmpty else {
                        throw usageError("--effect says what the --option before it changes")
                    }
                    effects[choices.count - 1] = parts[1]
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
        case "ask": verb = .ask
        case "item", "decision", "question", "criterion", "link", "review", "plan":
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
            item: options["--item"], background: background, note: options["--note"], file: options["--file"],
            options: choices.isEmpty ? nil : choices,
            effects: effects.contains(where: { !$0.isEmpty }) ? effects : nil, to: options["--to"]
        )
        // Which options each command takes: anything else is a mistake worth saying, not ignoring.
        let allowed: Set<String> = switch verb {
        case .itemAdd: ["--parent", "--by-subagent"]
        case .itemDone, .decisionAdd: ["--evidence"]
        case .criterionCheck: ["--evidence", "--item"]
        case .itemSpawn: ["--agent"]
        case .linkPR: ["--item"]
        case .planPropose: ["--note", "--file"]
        case .ask: ["--option", "--effect", "--to", "--timeout", "--id", "--no-wait"]
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
        case .list, .show, .planShow, .planApprove:
            guard args.isEmpty else { throw usageError("\(verb.rawValue) takes no words") }
        case .planPropose:
            guard args.isEmpty else { throw usageError("plan propose takes the plan with --file <path|->, not words") }
            guard command.file != nil else {
                throw usageError("plan propose needs --file: a JSON file, or - to read it on stdin")
            }
        case .ask:
            if let timeout = options["--timeout"] {
                guard let minutes = Double(timeout), minutes >= 0, minutes.isFinite else {
                    throw usageError("--timeout takes minutes (0: do not wait)")
                }
                command.timeout = minutes
            }
            if noWait {
                guard command.timeout == nil else { throw usageError("--no-wait or --timeout, not both") }
                command.timeout = 0
            }
            guard let to = command.to else {
                if let id = options["--id"] {
                    guard let number = Int64(id), number > 0 else { throw usageError("--id takes a question's number") }
                    guard args.isEmpty, choices.isEmpty else {
                        throw usageError("ask --id waits for question \(id)'s answer: no new words or options")
                    }
                    command.question = number
                    return command
                }
                guard let text = joined(args[...]) else { throw usageError("ask needs a question") }
                command.text = text
                return command
            }
            guard options["--id"] == nil else { throw usageError("--to is for a new question, not --id") }
            guard !to.trimmingCharacters(in: .whitespaces).isEmpty else { throw usageError("--to needs whom") }
            guard let text = joined(args[...]) else { throw usageError("ask needs a question") }
            command.text = text
        case .swarmSend, .swarmNote, .swarmAnswer, .swarmSummary:
            throw usageError("\(verb.rawValue) is heed \(verb.rawValue): heed swarm --help")
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
