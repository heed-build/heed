import Foundation

/// The fake world's steering, laid over the running anchors swarm: a worker asked its peer and had its answer, the lead
/// told everyone something, the controller answered a naming question and you overruled it, and two questions wait for
/// you in Needs you (one with the controller's suggestion, one the lead did not answer in time, one without options
/// whose answer the controller drafted). Invented, as every fixture is.
public extension SwarmFixtures {
    /// The rows, oldest first, without ids; `about` and an overrule's `ref` count back into this list (`-n` is the
    /// n-th row, 1-based) until `SwarmFixtures.number` gives them ids.
    static func steering(now: Date = Clock.now) -> [SwarmSteer] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        let goal = anchors
        let swarm = "\(goal)/swarm-1"
        let speed = SwarmAddress.task("\(goal)/validator-speed").raw
        let sample = SwarmAddress.task("\(goal)/sample-site").raw
        func row(
            _ hours: Double, _ actor: SwarmSteer.Actor, _ kind: SwarmSteer.Kind, _ text: String,
            reason: String? = nil, state: SwarmSteer.State = .applied, about: Int64? = nil, ref: String? = nil,
            options: [String] = [], from: String? = nil, to: String? = nil, effects: [String]? = nil,
            category: SwarmAuthority.Category? = nil, ladder: [SwarmAuthority.Answerer]? = nil,
            step: SwarmAuthority.Answerer? = nil, targets: [String]? = nil
        ) -> SwarmSteer {
            SwarmSteer(
                swarm: swarm, goal: goal, at: ago(hours), actor: actor, kind: kind, text: text, reason: reason,
                state: state, about: about, ref: ref, options: options, from: from, to: to, effects: effects,
                category: category?.rawValue, ladder: ladder?.map(\.rawValue), step: (step ?? ladder?.first)?.rawValue,
                targets: targets
            )
        }
        return [
            // 1: a progress note. 2-3: the lead to everyone at work, typed into one pane so far.
            row(0.5, .agent, .note, "Profiling the link pass: most of the time goes to anchor lookups", from: speed),
            row(
                0.45, .lead, .message, "1.1's PR is green: stay stacked on its branch, do not rebase on main yet",
                from: SwarmAddress.lead.raw, to: SwarmAddress.all.raw, targets: [speed, sample]
            ),
            row(0.44, .heed, .deliver, "typed into its pane", about: -2, ref: speed),
            // 4: a scope question for the lead (6: it did not answer in time).
            row(
                0.4, .agent, .question, "Should the sample site also cover pages moved twice, or is that a follow-up?",
                reason: "the plan's scope: the lead answers a worker's, its structural changes wait for you",
                state: .pending, options: ["in this task", "a follow-up"], from: sample, category: .scope,
                ladder: [.lead, .you]
            ),
            // 5: a peer question (7: answered by the peer; 8: read by the asker's waiting `heed goal ask`).
            row(
                0.25, .agent, .question,
                "Does the validator read pages as it walks the site, or load the whole site first?",
                reason: "heed cannot place it: yours, after who was asked", state: .pending,
                options: ["as it walks", "the whole site first"], from: sample, to: speed, category: .other,
                ladder: [.peer, .you]
            ),
            row(0.23, .heed, .escalate, "to you", reason: "no answer from the lead in 10 min", about: -4, step: .you),
            row(0.22, .agent, .answer, "as it walks", about: -5, from: speed),
            row(0.22, .heed, .deliver, "read by heed goal ask", about: -7, ref: sample),
            // 9: a naming question the controller answered (10), which you overruled (13), retyped (14).
            row(
                0.2, .agent, .question, "Name the sample's folder of moved pages moved/ or relocated/?",
                reason: "a reversible implementation choice: the controller may answer it", state: .pending,
                options: ["moved/", "relocated/"], from: sample, category: .implementation, ladder: [.controller, .you]
            ),
            row(
                0.19, .controller, .answer, "moved/",
                reason: "by the controller: a reversible implementation choice, 64% for it", about: -9,
                from: SwarmAddress.controller.raw
            ),
            // 11: always yours: deleting data. You asked the controller; it suggests (12).
            row(
                0.14, .agent, .question,
                "Drop the cached timings of the old 2k-page run from the benchmark data?",
                reason: "deleting data: only you answer it", state: .pending,
                options: ["drop them", "keep them as a baseline"], from: speed,
                effects: [
                    "the speed report compares against the 10k run only",
                    "the report keeps a before and after line; 40 MB stays in the repo",
                ],
                category: .deleteData, ladder: [.you]
            ),
            row(
                0.12,
                .controller,
                .suggest,
                "keep them as a baseline",
                reason: "81% for it",
                state: .pending,
                about: -11
            ),
            row(
                0.1, .you, .overrule, "relocated/", reason: "overrules the controller: moved/", state: .overruled,
                about: -9, ref: "steer:-10", from: SwarmAddress.you.raw
            ),
            row(0.09, .heed, .deliver, "typed into its pane", about: -13, ref: sample),
            // 15: another note.
            row(0.05, .agent, .note, "Generated 1,200 of 10,000 pages; 300 of them moved", from: sample),
            // 16: a question with no options: the controller drafts an answer (17) and it goes on to you (18).
            row(
                0.04, .agent, .question, "What should the moved-pages report file be called?",
                reason: "a reversible implementation choice: the controller may answer it", state: .pending,
                from: sample, category: .implementation, ladder: [.controller, .you]
            ),
            row(
                0.035, .controller, .suggest, "Call it moved-pages.md, next to the speed report.",
                reason: "drafted, the question has no options: yours to take", state: .pending, about: -16
            ),
            row(
                0.035, .heed, .escalate, "to you",
                reason: "no options to pick from: the controller drafted an answer for you to take or not",
                about: -16, step: .you
            ),
        ]
    }

    /// `rows` with ids from `first` on, their back references (`about`, `steer:` refs) resolved.
    static func number(_ rows: [SwarmSteer], from first: Int64) -> [SwarmSteer] {
        func resolve(_ value: Int64) -> Int64 { value < 0 ? first + -value - 1 : value }
        return rows.enumerated().map { index, row in
            var row = row
            row.id = first + Int64(index)
            row.about = row.about.map(resolve)
            if let ref = row.ref, ref.hasPrefix("steer:"), let value = Int64(ref.dropFirst(6)) {
                row.ref = "steer:\(resolve(value))"
            }
            return row
        }
    }
}
