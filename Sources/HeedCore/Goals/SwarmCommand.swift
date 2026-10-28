import Foundation

/// `heed swarm …`: messages between the swarm's agents and you, progress notes, and answers to questions heed handed
/// an agent. They travel as `heed goal` commands do (the control socket, `GoalControl`), and print and exit the same.
public enum SwarmCommandLine {
    public static let usage = """
    usage: heed swarm [--goal <id>] [--json] <command>

    The goal's active swarm. From a worker's tab the sender is its task, from the lead's pane the lead, from a
    terminal outside heed the owner.

      send <to> <text>                       a message: to a task (its number, 2.1, or id), lead, or @all (the
                                             lead and every task at work). heed types it into the agent's pane once
                                             it is idle and the owner is not typing there; a worker also finds it in
                                             heed goal plan show. Every message is in the steering log
      note <text>                            a progress note: what you are doing now, in a line. The plan pane and
                                             your task's log show it; write one every few minutes
      answer <question> <text>               answer a question heed handed you: a peer's (it asked your task), or a
                                             worker's scope question (you are the lead). The answer goes to the asker
      ask …                                  heed goal ask: a question, waiting for its answer

    Exit codes as heed goal: 0 done, 1 refused, 2 usage, 3 Heed not reachable, 4 no goal.
    """

    /// The command `arguments` make (`swarm` first, as `heed` passes them).
    public static func parse(_ arguments: [String]) throws -> GoalCommand {
        var words = arguments.first == "swarm" ? Array(arguments.dropFirst()) : arguments
        if words.first == "ask" { return try GoalCommandLine.parse(words) }
        var goal: String?
        var json = false
        var rest: [String] = []
        var index = 0
        while index < words.count {
            let word = words[index]
            switch word {
            case "--json": json = true
            case "--goal":
                guard index + 1 < words.count,
                      !words[index + 1].isEmpty else { throw usageError("--goal needs a value") }
                goal = words[index + 1]
                index += 1
            case "-h", "--help", "help": throw usageError(nil)
            case _ where word.hasPrefix("--goal="): goal = String(word.dropFirst(7))
            case _ where word.hasPrefix("--") && rest.isEmpty: throw usageError("unknown option \(word)")
            default: rest.append(word)
            }
            index += 1
        }
        words = rest
        guard let first = words.first else { throw usageError(nil) }
        let args = Array(words.dropFirst())
        func joined(_ words: ArraySlice<String>) -> String? {
            let text = words.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty ? nil : text
        }
        switch first {
        case "send":
            guard let to = args.first, !to.isEmpty else { throw usageError("send needs whom: 2.1, lead or @all") }
            guard let text = joined(args.dropFirst()) else { throw usageError("send needs a message") }
            return GoalCommand(.swarmSend, goal: goal, json: json, text: text, to: to)
        case "note":
            guard let text = joined(args[...]) else { throw usageError("note needs text") }
            return GoalCommand(.swarmNote, goal: goal, json: json, text: text)
        case "answer":
            guard let id = args.first, let number = Int64(id), number > 0 else {
                throw usageError("answer takes a question's number, then the answer")
            }
            guard let text = joined(args.dropFirst()) else { throw usageError("answer needs the answer") }
            return GoalCommand(.swarmAnswer, goal: goal, json: json, text: text, question: number)
        default:
            throw usageError("no command \(first)")
        }
    }

    static func usageError(_ problem: String?) -> HookCommandLine.UsageError {
        HookCommandLine.UsageError(description: problem.map { "heed swarm: \($0)\n\n\(usage)" } ?? usage)
    }
}

/// How `heed goal ask` waits: it asks, then reads the question again every few seconds until it has an answer, heed
/// refuses (the swarm stopped), or the timeout passes (exit 6: the question stays open). A heed that does not answer
/// for a moment (it restarted) is tried again until the timeout.
public enum GoalAskWait {
    /// Under the ten minutes an agent's shell tool runs a command at most (Claude Code's limit): an agent that gives
    /// the
    /// command its longest timeout sees it end by itself, and waits again with `--id` if it wants to.
    public static let defaultTimeout: TimeInterval = 9 * 60
    public static let interval: TimeInterval = 3

    /// The reply the CLI prints. `first`: heed's reply to the ask; `call` makes a request (a new connection each
    /// time); `sleep` and `clock` are the real ones outside tests.
    public static func wait(
        first: ControlReply, request: ControlRequest, call: (ControlRequest) throws -> ControlReply,
        sleep: (TimeInterval) -> Void, clock: () -> Date
    ) -> ControlReply {
        guard var command = request.goal, command.verb == .ask, let goal = first.goal, goal.exit == .ok,
              goal.outcome == "asked", let question = goal.question
        else { return first }
        let timeout = (command.timeout.map { $0 * 60 }) ?? defaultTimeout
        guard timeout > 0 else { return first }
        command.question = question
        command.text = nil
        command.options = nil
        command.effects = nil
        command.to = nil
        var poll = request
        poll.goal = command
        let start = clock()
        var last = first
        while clock().timeIntervalSince(start) < timeout {
            sleep(min(interval, max(timeout - clock().timeIntervalSince(start), 0)))
            guard let reply = try? call(poll), let answer = reply.goal else { continue }
            if answer.outcome != "asked" || answer.exit != .ok { return reply }
            last = reply
        }
        var timedOut = last
        let minutes = Int((timeout / 60).rounded())
        timedOut.goal = GoalReply(
            "timeout", exit: .timedOut,
            message: "no answer to question \(question) in \(minutes == 1 ? "a minute" : "\(minutes) min"): it stays "
                + "open (\(last.goal?.answer?.waitsFor.map { "with \($0)" } ?? "")); heed goal ask --id \(question) waits "
                + "again", goal: last.goal?.goal, question: question, answer: last.goal?.answer
        )
        return timedOut
    }
}
