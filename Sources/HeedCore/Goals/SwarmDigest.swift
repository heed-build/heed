import Foundation

/// "Since you last looked" (deck p14): what changed on a swarm since you last opened it, picked from its steering rows
/// and its tasks' states. Pure: the facts are heed's; a cheap model call turns them into two or three sentences
/// (`SummaryKind.swarmDigest`), cached by `key`, and without one the facts themselves are the digest.
public struct SwarmDigest: Hashable, Sendable {
    public var since: Date
    /// What happened, in order, a line each.
    public var facts: [String]
    /// Answers you or the controller gave since, a line each.
    public var decisions: [String]
    /// Plan versions made since: `v3 · you · moved 1.2 first`.
    public var versions: [String]
    /// Questions waiting on you now.
    public var waitingOnYou: Int
    /// The newest row it read: with `since`, what the cached text is keyed by.
    public var lastRow: Int64

    public var isEmpty: Bool { facts.isEmpty && decisions.isEmpty && versions.isEmpty }

    /// `<swarm>@<since>#<last row>`: a cached digest holds until a new row arrives or you look again.
    public func key(_ swarm: String) -> String { "\(swarm)@\(Int(since.timeIntervalSince1970))#\(lastRow)" }

    /// The most a digest lists of each.
    public static let limit = 6

    /// The digest of `board` since `since`. `states`: where each task stands now; `numbers`: the plan's task numbers.
    public static func of(
        _ board: SwarmBoard, since: Date, tasks: [SwarmTask], states: [String: SwarmTaskStatus], now _: Date
    ) -> SwarmDigest {
        let numbers = SwarmPlan.numbers(tasks)
        let rows = board.steering.filter { $0.at > since }
        func name(_ task: String?) -> String {
            guard let task else { return "a task" }
            let title = tasks.first { $0.id == task }?.title
            return [numbers[task], title].compactMap(\.self).joined(separator: " ")
        }
        var facts: [String] = []
        let done = tasks.filter { [.done, .merged].contains(states[$0.id]?.state) }
        let doneNow = board.steering.contains { $0.kind == .land && $0.at > since && $0.text.hasPrefix("Done") }
        if doneNow { facts.append("The swarm is done: every task merged in merge order.") }
        let started = rows.filter { $0.kind == .work && $0.text.contains(":") && !$0.text.contains(" ended: ") }
        if !started.isEmpty {
            let names = started.compactMap { SwarmSteering.taskRef($0) }.reduce(into: [String]()) {
                if !$0.contains($1) { $0.append($1) }
            }
            facts.append("Started: " + names.prefix(limit).map { name($0) }.joined(separator: ", ") + ".")
        }
        let landed = rows.filter { $0.kind == .land && !$0.text.hasPrefix("Done") }
        if !landed.isEmpty { facts.append("Every task has its PR; the swarm is landing.") }
        if !done.isEmpty, !doneNow { facts.append("\(done.count) of \(tasks.count) tasks merged or done.") }
        let stuck = rows.filter { $0.kind == .stuck && $0.step != SwarmStuck.Step.clear.rawValue }
        for row in stuck.prefix(limit) {
            facts.append("\(name(SwarmSteering.taskRef(row))) got stuck: \(row.reason ?? row.text).")
        }
        let unstuck = rows.filter { $0.kind == .stuck && $0.step == SwarmStuck.Step.clear.rawValue }
        if !unstuck.isEmpty {
            facts.append("Moving again: " + unstuck.compactMap { SwarmSteering.taskRef($0) }.map { name($0) }
                .joined(separator: ", ") + ".")
        }
        let retargets = rows.filter { $0.kind == .retarget }
        if !retargets.isEmpty { facts.append("\(retargets.count) stacked PR move\(retargets.count == 1 ? "" : "s").") }
        if rows.contains(where: { $0.kind == .limit && $0.actor == .heed }) {
            facts.append("It paused at a limit.")
        }
        let questions = SwarmSteering.questions(board.steering)
        let asked = questions.filter { $0.row.at > since }
        if !asked.isEmpty { facts.append("\(asked.count) question\(asked.count == 1 ? "" : "s") asked.") }
        var decisions: [String] = []
        for question in questions {
            guard let answer = question.answer, answer.at > since,
                  answer.actor == .you || answer.actor == .controller
            else { continue }
            let by = answer.actor == .you ? "you" : "the controller"
            let asked = question.row.text.count > 60 ? String(question.row.text.prefix(59)) + "…" : question.row.text
            decisions.append("\(answer.text): \(asked) (\(by))")
        }
        let versions = board.versions.filter { $0.at > since }.sorted { $0.number > $1.number }
            .map { "v\($0.number) · \($0.author.rawValue) · \($0.note)" }
        let waiting = questions.count(where: { question in
            question.answer == nil && SwarmLadder.position(question.row, rows: board.steering).step == .you
        })
        if facts.isEmpty, decisions.isEmpty, versions.isEmpty { facts.append("Nothing changed.") }
        return SwarmDigest(
            since: since, facts: Array(facts.prefix(limit)), decisions: Array(decisions.suffix(limit)),
            versions: Array(versions.prefix(limit)), waitingOnYou: waiting,
            lastRow: board.steering.compactMap(\.id).max() ?? 0
        )
    }

    /// The digest as text without a model: its facts, then what waits on you.
    public var plain: String {
        var lines = facts
        if waitingOnYou > 0 {
            lines
                .append(
                    "\(waitingOnYou) question\(waitingOnYou == 1 ? "" : "s") wait\(waitingOnYou == 1 ? "s" : "") on you."
                )
        }
        return lines.joined(separator: " ")
    }

    /// What the model reads: the facts, the decisions and the versions, as a timeline.
    public func inputs(title: String) -> SummaryInputs {
        SummaryInputs(
            title: title,
            timeline: facts + decisions.map { "Decided: \($0)" } + versions.map { "Plan \($0)" }
                + (waitingOnYou > 0 ? ["Waiting on the owner: \(waitingOnYou) question(s)"] : [])
        )
    }
}
