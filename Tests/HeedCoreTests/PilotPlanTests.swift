import Foundation
@testable import HeedCore
import Testing

/// What heed would do next for a PR: the PR card's `next` line and the `pilot.why` explainer.
struct PilotPlanTests {
    private let repo = Repo(org: "acme", name: "site")
    private let now = Date(timeIntervalSince1970: 1_000_000)
    private var ref: PullRef { PullRef(repo: repo, number: 7) }

    private func settings(_ edit: (inout PilotSettings) -> Void = { _ in }) -> PilotSettings {
        var settings = PilotSettings(green: .ask)
        edit(&settings)
        return settings
    }

    private func next(
        _ settings: PilotSettings, _ status: PilotStatus = .failing(1), pipeline: PullFeedback? = nil,
        agent: String? = "claude"
    ) -> PilotPlan.Step {
        PilotPlan.next(settings: settings, pipeline: pipeline, status: status, sessionAgent: agent, now: now)
    }

    private func text(_ step: PilotPlan.Step) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return PilotPlan.text(step, now: now, calendar: calendar)
    }

    @Test func aBackgroundRoundNamesTheAgentModelTimeoutAndInstructions() {
        let plain = next(settings())
        #expect(text(plain) == "background run · claude · 30m")
        let configured = next(settings {
            $0.agent = "codex"
            $0.model = "big-model"
            $0.runTimeout = 2700
            $0.greenInstructions = "Run the linter first.\n\n"
        })
        #expect(text(configured) == "background run · codex big-model · 45m · 1 instruction")
        // No agent configured and no session to borrow one from.
        #expect(text(next(settings(), agent: nil)) == "background run · the session's agent · 30m")
    }

    @Test func aConflictedPRTakesTheMergeAgentAndModel() {
        let base = settings {
            $0.agent = "codex"
            $0.model = "big-model"
        }
        #expect(text(next(base, .conflicted("conflicts with main"))) == "conflict run · codex big-model · 30m")
        var merge = base
        merge.mergeAgent = "claude"
        merge.mergeModel = "small-model"
        #expect(text(next(merge, .conflicted("x"))) == "conflict run · claude small-model · 30m")
        // A model of its own without an agent of its own keeps the run agent.
        var model = base
        model.mergeModel = "small-model"
        #expect(text(next(model, .conflicted("x"))) == "conflict run · codex small-model · 30m")
        // A green PR's next round, should feedback arrive, is get it green's.
        #expect(text(next(merge, .green)) == "background run · codex big-model · 30m")
        var copilot = base
        copilot.copilotConflicts = true
        #expect(next(copilot, .conflicted("x")) == .copilot(.merged))
        #expect(text(next(copilot, .conflicted("x"))) == "Copilot is asked to resolve the conflicts")
    }

    @Test func runInSessionTypesIntoTheSessionsAgent() {
        let step = next(settings {
            $0.runIn = .session
            $0.agent = "codex"
            $0.greenInstructions = "One.\nTwo."
        })
        #expect(text(step) == "typed into the session's claude · 2 instructions")
        #expect(PilotPlan.keys(for: step) == ["run_in", "green_instructions"])
    }

    @Test func nothingWhenGreenIsOffUnwatchedOrDone() {
        #expect(text(next(settings { $0.green = .off })) == "nothing: get it green is off")
        #expect(text(next(settings(), .unwatched)) == "nothing: not watched")
        #expect(text(next(settings(), .closed(merged: true))) == "nothing: merged")
        #expect(text(next(settings(), .closed(merged: false))) == "nothing: closed")
        #expect(text(next(settings(), .stuck("no session"))) == "nothing: no session to send to")
        // A hand-set green on the PR wins over the settings.
        var pipeline = PullFeedback(ref: ref)
        pipeline.autoFeed = .off
        pipeline.greenSet = true
        #expect(text(next(settings(), pipeline: pipeline)) == "nothing: get it green is off")
    }

    @Test func greenOffWithMergingOnSaysHowItMerges() {
        let auto = next(settings {
            $0.green = .off
            $0.merge = .auto
        }, .green)
        #expect(auto == .merging(.auto))
        #expect(text(auto) == "no rounds (green off) · GitHub's auto-merge, once its requirements are met")
        #expect(PilotPlan.keys(for: auto) == ["green", "merge"])
        // Merge set on the PR by hand counts.
        var pipeline = PullFeedback(ref: ref)
        pipeline.merge = .heed
        pipeline.mergeSet = true
        #expect(text(next(settings { $0.green = .off }, pipeline: pipeline))
            == "no rounds (green off) · heed merges once its rules hold")
    }

    @Test func greenProgressSaysTheRoundAndWhatWentLast() {
        var pipeline = PullFeedback(ref: ref)
        pipeline.rounds = 1
        let log = [
            PilotEvent(at: now - 60, ref: ref, kind: .items, text: "check lint arrived"),
            PilotEvent(at: now - 31 * 60, ref: ref, kind: .sent, text: "sent 2 items to claude (round 1)"),
            PilotEvent(at: now - 90 * 60, ref: ref, kind: .sent, text: "sent 1 item to claude (round 1)"),
        ]
        #expect(PilotPlan.greenProgress(pipeline: pipeline, settings: settings(), log: log, now: now)
            == "round 1 of 3 · last: sent 2 items to claude (round 1), 31m ago")
        #expect(PilotPlan.greenProgress(pipeline: nil, settings: settings(), log: [], now: now)
            == "round 0 of 3 · nothing sent yet")
        #expect(PilotPlan.greenProgress(pipeline: nil, settings: settings { $0.green = .off }, log: log, now: now)
            == nil)
        #expect(PilotPlan.greenProgress(pipeline: nil, settings: settings { $0.watch = false }, log: log, now: now)
            == nil)
    }

    @Test func pausedAndStopped() {
        #expect(text(next(settings(), .paused(until: nil))) == "paused until resumed")
        // 1_000_000 is 13:46:40 UTC.
        #expect(text(next(settings(), .paused(until: now.addingTimeInterval(1640)))) == "paused until 14:14")
        #expect(text(next(settings(), .paused(until: now.addingTimeInterval(3 * 86400)))) == "paused for 3d")
        #expect(text(next(settings(), .stalled(rounds: 3))) == "stopped after 3 rounds")
        // Out of rounds with nothing open yet: the next round would not go either.
        var pipeline = PullFeedback(ref: ref)
        pipeline.rounds = 3
        #expect(next(settings(), pipeline: pipeline) == .stopped(rounds: 3))
    }

    @Test func sourcesSayWhereEachSettingComesFrom() {
        var config = HeedConfig.default
        var org = PilotOverrides()
        org.agent = "codex"
        org.greenInstructions = "Run the linter first."
        var repoLevel = PilotOverrides(merge: .auto)
        repoLevel.model = "big-model"
        config.pilot = PilotRules(orgs: ["acme": org], repos: ["acme/site": repoLevel])
        var pipeline = PullFeedback(ref: ref)
        pipeline.autoFeed = .auto
        pipeline.greenSet = true
        let sources = PilotPlan.sources(for: repo, pipeline: pipeline, in: config)
        #expect(sources["agent"] == .init(key: "agent", value: "codex", origin: "org acme"))
        #expect(sources["model"]?.origin == "repo")
        #expect(sources["run_in"]?.isDefault == true)
        #expect(sources["run_timeout"]?.value == "30m")
        #expect(sources["green"] == .init(key: "green", value: "auto", origin: "this PR"))
        #expect(sources["merge"]?.origin == "repo")

        let settings = config.pilot.resolve(repo)
        let step = next(settings)
        #expect(PilotPlan.help(step, sources: sources) == """
        run_in: background (default)
        agent: codex (org acme)
        model: big-model (repo)
        run_timeout: 30m (default)
        green_instructions: Run the linter first. (org acme)
        """)

        let rows = PilotPlan.rows(
            settings: settings, pipeline: pipeline, status: .failing(1), sessionAgent: "claude", sources: sources,
            now: now
        )
        #expect(rows.map(\.title) == ["Watching", "Get it green", "A round", "Conflicts", "Get it merged"])
        let round = rows[2]
        #expect(round.value == "background run")
        #expect(round.detail == "codex big-model in its own worktree, 30m at most, 1 instruction added")
        #expect(round.origin == "org acme · repo")
        #expect(rows[0].isDefault)
        #expect(rows[1].value == "auto")
        #expect(rows[1].origin == "this PR")
        #expect(rows[3].value == "codex big-model")
        #expect(rows[4].detail.hasPrefix("GitHub's auto-merge"))
    }

    @Test func explainerRowsFollowTheState() {
        var pipeline = PullFeedback(ref: ref)
        pipeline.items = [
            FeedbackItem(id: "a", kind: .check(name: "lint"), text: "lint failed", status: .queued),
            FeedbackItem(id: "b", kind: .check(name: "test"), text: "test failed", status: .queued),
        ]
        pipeline.rounds = 1
        func rows(_ settings: PilotSettings, _ status: PilotStatus) -> [PilotPlan.Row] {
            PilotPlan.rows(
                settings: settings, pipeline: pipeline, status: status, sessionAgent: "claude", sources: [:], now: now
            )
        }
        let ask = rows(settings(), .failing(2))
        #expect(ask[1].detail == "2 items queued: they go when you send them · 1 of 3 rounds used")
        #expect(ask[1].tone == .ask)
        let session = rows(settings { $0.runIn = .session }, .failing(2))
        #expect(session[2].value == "the session's agent")
        #expect(session[3].value == "the session's claude")
        let conflicted = rows(settings { $0.mergeAgent = "codex" }, .conflicted("x"))
        #expect(conflicted[3].value == "codex")
        #expect(conflicted[3].tone == .busy)
        #expect(rows(settings(), .stalled(rounds: 3))[1].detail == "stopped after 3 rounds without a new approval")
        #expect(rows(settings { $0.merge = .heed }, .green)[4].detail == "heed merges once every rule below holds")
    }

    @Test func holdsListFailuresThenPendingThenPassing() {
        typealias Rule = GreenVerdict.Rule
        let green = GreenVerdict(rules: [
            Rule(name: "Open", state: .pass, detail: "open"),
            Rule(name: "Checks pass", state: .wait, detail: "test still running"),
            Rule(name: "Threads resolved", state: .fail, detail: "1 thread open"),
        ])
        let merge = GreenVerdict(rules: [
            Rule(name: "Green", state: .fail, detail: "threads resolved: 1 thread open"),
            Rule(name: "Quiet", state: .wait, detail: "quiet for 3m more"),
        ])
        #expect(PilotPlan.holds(green).map(\.name) == ["Threads resolved", "Checks pass", "Open"])
        #expect(PilotPlan.holds(green, merge: merge).map(\.name) == [
            "Threads resolved",
            "Checks pass",
            "Quiet",
            "Open",
        ])
    }
}
