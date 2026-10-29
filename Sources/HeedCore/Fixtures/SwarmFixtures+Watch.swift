import Foundation

/// The fake world's watched swarm: what its workers did (tool calls and file changes), the stuck episode of 2.2 with
/// the ladder heed climbed for it, "since you last looked", and the rows a done run's summary is made of. Invented, as
/// every fixture is.
public extension SwarmFixtures {
    /// Laid over the steering world (`Running.watch`): 2.2 hit the same build error three times; heed nudged it, then
    /// asked on its behalf, and the controller answered. Back references count into this list (`-n`).
    static func watch(now: Date = Clock.now) -> [SwarmSteer] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ minutes: Double) -> Date { Date(timeIntervalSince1970: base - minutes * 60) }
        let goal = anchors
        let swarm = "\(goal)/swarm-1"
        let task = "\(goal)/validator-speed"
        let address = SwarmAddress.task(task).raw
        let why = "the same error 3×: \(stuckDigest); no tool call or file change for 13 min"
        let signal = SwarmStuck.Signal(reasons: [.sameError(stuckDigest, count: 3), .noProgress(minutes: 13)])
        let asked = SwarmStuck.question(number: "2.2", title: "Validator speed on a 10k-page site", signal: signal)
        func row(
            _ minutes: Double, _ actor: SwarmSteer.Actor, _ kind: SwarmSteer.Kind, _ text: String,
            reason: String? = nil, state: SwarmSteer.State = .applied, about: Int64? = nil, ref: String? = nil,
            step: String? = nil, from: String? = nil, to: String? = nil, options: [String] = [],
            effects: [String]? = nil, ladder: [String]? = nil, category: String? = nil
        ) -> SwarmSteer {
            SwarmSteer(
                swarm: swarm, goal: goal, at: ago(minutes), actor: actor, kind: kind, text: text, reason: reason,
                state: state, about: about, ref: ref, options: options, from: from, to: to, effects: effects,
                category: category, ladder: ladder, step: step
            )
        }
        return [
            // 1-3: stuck, the nudge, typed in when its turn paused.
            row(
                26,
                .heed,
                .stuck,
                "Validator speed on a 10k-page site looks stuck",
                reason: why,
                ref: "task:\(task)",
                step: "nudge"
            ),
            row(26, .heed, .message, SwarmStuck.nudge(signal), from: "heed", to: address),
            row(25, .heed, .deliver, "typed into its pane", about: -2, ref: address),
            // 4: its note on what it tried.
            row(
                22,
                .agent,
                .note,
                "Tried caching anchor lookups per page: same build error, the index type is not "
                    + "where the link pass looks",
                from: address
            ),
            // 5-6: still stuck ten minutes on: heed asks on its behalf; the controller answers it (7), handed over (8).
            row(
                12, .heed, .question, asked.text, reason: "a stuck worker: a reversible implementation choice, the "
                    + "controller may answer it", state: .pending, from: address, options: asked.options,
                effects: asked.effects, ladder: ["controller", "you"],
                category: SwarmAuthority.Category.implementation.rawValue
            ),
            row(
                12,
                .heed,
                .stuck,
                "Validator speed on a 10k-page site is still stuck",
                reason: why,
                about: -5,
                ref: "task:\(task)",
                step: "ask"
            ),
            row(
                11,
                .controller,
                .answer,
                "try a different approach",
                reason: "by the controller: a reversible implementation choice, 77% for it",
                about: -5,
                from: SwarmAddress.controller.raw
            ),
            row(10, .heed, .deliver, "typed into its pane", about: -7, ref: address),
        ]
    }

    /// What Hunch read of the live workers' panes, by task, in the fake world with Hunch as the decider: 2.1's screen
    /// loops: Hunch says stuck, so its signal does.
    static func screenReadings(now: Date = Clock.now) -> [String: HunchScreen.Reading] {
        let at = Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 40)
        return [
            "\(anchors)/sample-site": HunchScreen.Reading(state: .stuck, confidence: 0.84, at: at),
        ]
    }

    /// The build error 2.2 keeps hitting, as its digest.
    static let stuckDigest = "error cs#: the name pageindex does not exist in the current context"

    /// What each worker did lately, by task, oldest first.
    static func activity(now: Date = Clock.now) -> [String: [SwarmActivityLine]] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ minutes: Double) -> Date { Date(timeIntervalSince1970: base - minutes * 60) }
        func call(_ minutes: Double, _ tool: String, _ input: String, error: String? = nil, skipped: Int = 0)
            -> SwarmActivityLine
        {
            SwarmActivityLine(
                at: ago(minutes),
                kind: .tool(ToolCall(tool: tool, input: input, error: error != nil, digest: error)),
                skipped: skipped
            )
        }
        func files(_ minutes: Double, _ paths: [String], _ plus: Int, _ minus: Int) -> SwarmActivityLine {
            SwarmActivityLine(
                at: ago(minutes),
                kind: .files(FileActivity(files: paths, insertions: plus, deletions: minus))
            )
        }
        let speed = [
            call(50, "Read", "src/Links/LinkPass.cs"),
            call(47, "Bash", "dotnet run --project bench -- --pages 10000", skipped: 2),
            call(41, "Edit", "src/Links/LinkPass.cs"),
            files(40, ["src/Links/LinkPass.cs"], 38, 9),
            call(38, "Edit", "src/Links/PageIndex.cs"),
            files(37, ["src/Links/LinkPass.cs", "src/Links/PageIndex.cs"], 71, 12),
            call(36, "Bash", "dotnet build", error: stuckDigest),
            call(30, "Bash", "dotnet build", error: stuckDigest),
            call(27, "Bash", "dotnet build", error: stuckDigest),
        ]
        let sample = [
            call(17, "Read", "tests/sample/site.yml"),
            call(14, "Write", "tests/sample/generate.sh"),
            call(12, "Bash", "tests/sample/generate.sh --pages 10000 --moved 300", skipped: 4),
            files(11, ["tests/sample/generate.sh", "tests/sample/site.yml"], 120, 3),
            call(6, "Bash", "dotnet test --filter SampleSite"),
            call(3, "Edit", "tests/sample/site.yml"),
        ]
        return ["\(anchors)/validator-speed": speed, "\(anchors)/sample-site": sample]
    }

    /// When you last looked at the anchors swarm, in the fake world.
    static func lastLooked(now: Date = Clock.now) -> Date {
        Date(timeIntervalSince1970: now.timeIntervalSince1970.rounded(.down) - 2 * 3600)
    }

    /// "Since you last looked", as a model would have written it: fixed text, so the shots stay the same.
    static let digestText = "1.2 merged and 1.1's PR is green; 2.1 and 2.2 started, stacked on it. 2.2 got stuck on "
        + "the same build error: heed nudged it, then the controller told it to try a different approach. Two "
        + "questions wait on you."

    /// What a done run's summary is made of, laid over the done world (`Running.summary`): its questions and who
    /// answered them, a stuck episode, and the lead's own summary. Back references count into this list (`-n`).
    static func summaryRows(now: Date = Clock.now) -> [SwarmSteer] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        let goal = anchors
        let swarm = "\(goal)/swarm-1"
        let speed = SwarmAddress.task("\(goal)/validator-speed").raw
        let sample = SwarmAddress.task("\(goal)/sample-site").raw
        func row(
            _ hours: Double, _ actor: SwarmSteer.Actor, _ kind: SwarmSteer.Kind, _ text: String,
            reason: String? = nil, about: Int64? = nil, ref: String? = nil, step: String? = nil, from: String? = nil,
            to: String? = nil, options: [String] = [], ladder: [String]? = nil, decisions: [String]? = nil,
            followUps: [String]? = nil
        ) -> SwarmSteer {
            SwarmSteer(
                swarm: swarm, goal: goal, at: ago(hours), actor: actor, kind: kind, text: text, reason: reason,
                state: kind == .question ? .pending : .applied, about: about, ref: ref, options: options, from: from,
                to: to, ladder: ladder, step: step ?? ladder?.first, decisions: decisions, followUps: followUps
            )
        }
        return [
            // 1-2: yours, after a 13-minute wait.
            row(
                2.0,
                .agent,
                .question,
                "Fail the check on a missing anchor, or warn?",
                from: speed,
                options: ["fail", "warn"],
                ladder: ["you"]
            ),
            row(1.78, .you, .answer, "warn", about: -1, from: SwarmAddress.you.raw),
            // 3-4: the controller's.
            row(
                1.9,
                .agent,
                .question,
                "Name the sample's folder of moved pages moved/ or relocated/?",
                from: sample,
                options: ["moved/", "relocated/"],
                ladder: ["controller", "you"]
            ),
            row(
                1.89,
                .controller,
                .answer,
                "moved/",
                reason: "by the controller: a reversible implementation choice",
                about: -3,
                from: SwarmAddress.controller.raw
            ),
            // 5-6: a peer's.
            row(
                1.7,
                .agent,
                .question,
                "Does the validator read pages as it walks the site?",
                from: sample,
                to: speed,
                ladder: ["peer", "you"]
            ),
            row(1.66, .agent, .answer, "yes, one page at a time", about: -5, from: speed),
            // 7-11: 2.2 stuck on the same error, nudged, asked for, unstuck.
            row(
                1.6,
                .heed,
                .stuck,
                "Validator speed on a 10k-page site looks stuck",
                reason: "the same error 4×: \(stuckDigest)",
                ref: "task:\(goal)/validator-speed",
                step: "nudge"
            ),
            row(
                1.45,
                .heed,
                .question,
                "2.2 Validator speed on a 10k-page site is still stuck: how should it go on?",
                from: speed,
                options: ["try a different approach", "stop and wait for the owner"],
                ladder: ["controller", "you"]
            ),
            row(
                1.45,
                .heed,
                .stuck,
                "Validator speed on a 10k-page site is still stuck",
                about: -8,
                ref: "task:\(goal)/validator-speed",
                step: "ask"
            ),
            row(
                1.44,
                .controller,
                .answer,
                "try a different approach",
                reason: "by the controller: a reversible implementation choice",
                about: -8,
                from: SwarmAddress.controller.raw
            ),
            row(
                1.3,
                .heed,
                .stuck,
                "Validator speed on a 10k-page site moves again",
                ref: "task:\(goal)/validator-speed",
                step: "clear"
            ),
            // 12: the lead's summary.
            row(
                0.08, .lead, .summary,
                "Anchors survive page moves: ids come from heading text, moved assemblies keep their redirects, and "
                    + "the validator checks a 10k-page sample site in under a minute.",
                from: SwarmAddress.lead.raw, decisions: ["A missing anchor warns; it does not fail the check"],
                followUps: ["Pages moved twice: follow redirect chains", "Document the warn setting"]
            ),
        ]
    }
}
