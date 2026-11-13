import Foundation
@testable import HeedCore
import Testing

/// Autopilot: where each capability is on, what heed did on its own (and only that), the nudges it can back with a
/// number, Now's cards, and the config its switches write.
struct AutopilotTests {
    private let docs = Repo(org: "acme", name: "docs")
    private let site = Repo(org: "acme", name: "site")
    private let tool = Repo(org: "other", name: "tool")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }

    private var config: HeedConfig {
        var config = HeedConfig.default
        config.pilot = PilotRules(
            orgs: ["acme": PilotOverrides(reviewers: ["copilot"])],
            repos: [docs.slug: PilotOverrides(green: .auto, merge: .heed), site.slug: PilotOverrides(green: .off)]
        )
        return config
    }

    // MARK: Coverage

    @Test func cellsReadEachLevel() {
        #expect(AutopilotCoverage.cell(.green, repo: docs, config: config) == AutopilotCell(.on, "auto"))
        #expect(AutopilotCoverage.cell(.green, repo: site, config: config).state == .off)
        #expect(AutopilotCoverage.cell(.green, repo: tool, config: config) == AutopilotCell(.ask, "ask"))
        #expect(AutopilotCoverage.cell(.merge, repo: docs, config: config) == AutopilotCell(.on, "heed"))
        #expect(AutopilotCoverage.cell(.reviewers, repo: site, config: config) == AutopilotCell(.on, "copilot"))
        #expect(AutopilotCoverage.cell(.reviewers, repo: tool, config: config).state == .off)
    }

    @Test func mergeAutoWhereGitHubRefusesItIsHeld() {
        var config = config
        config.pilot.repos[tool.slug] = PilotOverrides(merge: .auto)
        let cell = AutopilotCoverage.cell(
            .merge, repo: tool, config: config, facts: AutopilotRepoFacts(allowsAutoMerge: false)
        )
        #expect(cell.state == .ask && cell.warning && cell.note == "auto-merge off on GitHub")
    }

    @Test func notWatchedIsOffWhateverGreenSays() {
        var config = config
        config.pilot.repos[docs.slug]?.watch = false
        #expect(AutopilotCoverage.cell(.green, repo: docs, config: config) == AutopilotCell(
            .off,
            "off",
            note: "not watched"
        ))
    }

    @Test func summaryCountsAskAsHalf() {
        let summary = AutopilotCoverage.summary(.green, repos: [docs, site, tool], config: config)
        #expect(summary.on == 1 && summary.ask == 1 && summary.total == 3)
        #expect(summary.text == "on in 1 of 3 repos · 1 ask")
        #expect(abs(summary.fraction - 0.5) < 0.001)
        #expect(AutopilotCoverage.summary(.cleanup, repos: [docs], config: config).text == "off")
        #expect(AutopilotCoverage.summary(.summaries, repos: [docs], config: config).text == "ahead")
    }

    @Test func offCountIsCapabilitiesOffSomewhere() {
        // green (site), merge (site, tool), copilot (all), reviewers (tool), cleanup (off everywhere).
        #expect(AutopilotCoverage.offCount(repos: [docs, site, tool], config: config) == 5)
    }

    // MARK: Done

    private func event(_ hours: Double, _ repo: Repo, _ number: Int, _ kind: PilotEvent.Kind, _ text: String)
        -> PilotEvent
    {
        PilotEvent(at: ago(hours), ref: PullRef(repo: repo, number: number), kind: kind, text: text)
    }

    @Test func doneKeepsWhatHeedDidAndLeavesOutYours() {
        let log = [
            event(1, docs, 1, .sent, "sent 2 items to claude (round 1)"),
            event(2, docs, 1, .sent, "sent 3 items to claude (round 1) (by you)"),
            event(3, docs, 1, .addressed, "the agent pushed: 2 items addressed"),
            event(4, docs, 1, .waiting, "2 queued, held: the agent is working"),
            event(5, docs, 1, .merged, "Fix it"),
            event(6, docs, 2, .copilot, "asked Copilot to resolve the conflicts (by you)"),
            event(7, docs, 2, .review, "could not ask @x to review"),
            event(8, docs, 2, .review, "asked @copilot to review"),
        ]
        let entries = AutopilotDone.entries(AutopilotRecord(pilotLog: log, titles: ["acme/docs#1": "Fix it"]))
        #expect(entries.map(\.capability) == [.green, .green, .merge, .reviewers])
        #expect(entries[0].text == "Sent 2 items to claude (round 1)")
        #expect(entries[1].text == "2 items fixed" && entries[1].addressed == 2)
        #expect(entries[2].text == "Merged Fix it" && entries[2].detail.isEmpty)
    }

    @Test func doneReadsAttachSummariesContinueAndNames() {
        var named = Session(
            id: "s1",
            title: "Arrow fix",
            repos: [docs],
            branch: "b",
            agent: "claude",
            state: ObservedState(.idle)
        )
        named.titleBy = .heed
        named.record("renamed: fix arrows → Arrow fix", at: ago(2))
        named.record("sent “Go on.”", at: ago(3))
        var yours = Session(
            id: "s2",
            title: "Mine",
            repos: [docs],
            branch: "c",
            agent: "claude",
            state: ObservedState(.idle)
        )
        yours.titleBy = .you
        yours.record("renamed: x → Mine", at: ago(1))
        let subject = AttachSubject(kind: .session, id: "s1", title: "Arrow fix", repos: [docs.slug], at: ago(4))
        let attached = AttachDecision(
            subject: subject, trigger: .started,
            verdict: AttachVerdict(action: .attach, goal: "g1", confidence: 0.9, reason: "same files"), at: ago(4)
        )
        let asked = AttachDecision(
            subject: subject, trigger: .started,
            verdict: AttachVerdict(action: .ask, goal: "g1", confidence: 0.6, reason: "maybe"), at: ago(5)
        )
        let summary = CatchUpSummary(
            text: "t", since: nil, coversUpTo: ago(6), count: 3, state: "open", writtenAt: ago(6), agent: "claude"
        )
        let record = AutopilotRecord(
            catchUps: [AutopilotCatchUp(id: "i1", summary: summary, title: "A thread")],
            attach: [attached, asked], goalTitles: ["g1": "Arrows"], sessions: [named, yours], continuePrompt: "Go on."
        )
        let entries = AutopilotDone.entries(record)
        #expect(entries.map(\.capability) == [.names, .resume, .goals, .summaries])
        #expect(entries[0].text == "Named a session Arrow fix" && entries[0].detail == "was fix arrows")
        #expect(entries[2].text == "Put Arrow fix on Arrows")
        #expect(entries[3].text == "Caught you up on A thread" && entries[3].detail == "3 comments · claude")
    }

    @Test func daysGroupNewestFirstWithTotals() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let log = [
            event(1, docs, 1, .merged, "One"),
            event(2, docs, 1, .addressed, "the agent pushed: 3 items addressed"),
            event(30, site, 2, .merged, "Two"),
            event(200, site, 3, .merged, "Too old"),
        ]
        let week = AutopilotDone.thisWeek(AutopilotDone.entries(AutopilotRecord(pilotLog: log)), now: now)
        #expect(week.count == 3)
        let days = AutopilotDone.days(week, now: now, calendar: calendar)
        #expect(days.map(\.title) == ["Today", "Yesterday"])
        #expect(days[0].totals == "2 things · 1 merged · 3 fixed")
        #expect(AutopilotDone.days(week, repo: site.slug, now: now, calendar: calendar).map { $0.entries.count } == [1])
        #expect(AutopilotDone.days(week, capability: .green, now: now, calendar: calendar).first?.entries.count == 1)
        #expect(AutopilotDone.repoCounts(week) == [docs.slug: 2, site.slug: 1])
    }

    @Test func sentByYouCountsItemsThisWeek() {
        let log = [
            event(1, site, 1, .sent, "sent 3 items to claude (round 1) (by you)"),
            event(2, site, 2, .sent, "sent 1 item to claude (round 1) (by you)"),
            event(3, docs, 1, .sent, "sent 5 items to claude (round 1)"),
            event(300, site, 1, .sent, "sent 9 items to claude (round 1) (by you)"),
        ]
        #expect(AutopilotDone.sentByYou(log, now: now) == [site.slug: 4])
    }

    // MARK: Nudges

    @Test func nudgesNeedANumberBehindThem() {
        let signals = AutopilotSignals(
            sentByYou: [site.slug: 7, docs.slug: 9], greenWaiting: [tool.slug: 2], removable: [docs.slug: 1]
        )
        let nudges = AutopilotNudges.all(repos: [docs, site, tool], config: config, signals: signals)
        // docs has green on auto: what you sent there is no nudge.
        #expect(!nudges.contains { $0.capability == .green && $0.repo == docs.slug })
        #expect(AutopilotNudges.best(.green, in: nudges)?.repo == site.slug)
        #expect(AutopilotNudges.best(.green, in: nudges)?.short == "green: 7 sent by hand")
        #expect(AutopilotNudges.couldHelp(tool.slug, in: nudges)?.short == "merge: 2 green PRs waiting")
        #expect(AutopilotNudges.best(.cleanup, in: nudges)?.text.hasPrefix("1 worktree would go") == true)
        #expect(AutopilotNudges.all(repos: [docs], config: config, signals: AutopilotSignals()).isEmpty)
    }

    // MARK: Now

    @Test func nowCardsStalledFirstAndMergedGone() {
        let pulls = [
            AutopilotPull(ref: PullRef(repo: docs, number: 1), status: .failing(1), merge: .off),
            AutopilotPull(ref: PullRef(repo: docs, number: 2), status: .green, merge: .auto),
            AutopilotPull(ref: PullRef(repo: docs, number: 3), status: .stalled(rounds: 3), merge: .off),
            AutopilotPull(ref: PullRef(repo: docs, number: 4), status: .closed(merged: true), merge: .auto),
            AutopilotPull(
                ref: PullRef(repo: docs, number: 5),
                status: .conflicted("x"),
                merge: .off,
                copilotAsked: true
            ),
            AutopilotPull(ref: PullRef(repo: docs, number: 6), status: .unwatched, merge: .off),
            AutopilotPull(ref: PullRef(repo: docs, number: 7), status: .green, merge: .off),
        ]
        #expect(AutopilotNow.ordered(pulls).map(\.ref.number) == [3, 1, 7, 2, 5, 6])
        #expect(AutopilotNow.activeCount(pulls) == 4)
    }

    // MARK: Switches

    @Test func switchesWriteWhatSettingsWrites() throws {
        let writes = try AutopilotSwitch.writes(.green, .on, repo: site, config: config)
        #expect(writes == [AutopilotSwitch.Write(["repos", site.slug, "green"], .string("auto"))])
        #expect(
            try AutopilotSwitch.writes(.merge, .on, repo: tool, config: config, facts: .init(allowsAutoMerge: false))
                == [AutopilotSwitch.Write(["repos", tool.slug, "merge"], .string("heed"))]
        )
        #expect(throws: AutopilotSwitch.Refusal.self) {
            try AutopilotSwitch.writes(.merge, .ask, repo: tool, config: config)
        }
        #expect(
            try AutopilotSwitch.writes(.cleanup, .ask, repo: nil, config: config) == [
                AutopilotSwitch.Write(["cleanup", "enabled"], .bool(true)),
                AutopilotSwitch.Write(["cleanup", "ask_before_sweep"], .bool(true)),
            ]
        )
    }

    @Test func everywhereSetsTheDefaultAndClearsOverrides() throws {
        let writes = try AutopilotSwitch.everywhere(.green, config: config)
        #expect(writes.first == AutopilotSwitch.Write(["pilot", "green"], .string("auto")))
        #expect(writes.contains(AutopilotSwitch.Write(["repos", site.slug, "green"], nil)))
        var applied = config
        AutopilotSwitch.apply(writes, to: &applied)
        for repo in [docs, site, tool] {
            #expect(AutopilotCoverage.cell(.green, repo: repo, config: applied).state == .on)
        }
    }

    @Test func appliedInMemoryAsTheFileWouldRead() throws {
        var applied = config
        let switches: [(Capability, Repo)] = [(.green, site), (.copilot, tool), (.reviewers, tool)]
        for (capability, repo) in switches {
            try AutopilotSwitch.apply(
                AutopilotSwitch.writes(capability, .on, repo: repo, config: applied),
                to: &applied
            )
            #expect(AutopilotCoverage.cell(capability, repo: repo, config: applied).state == .on)
        }
        let globals: [Capability] = [.cleanup, .goals, .summaries, .resume, .names]
        for capability in globals {
            try AutopilotSwitch.apply(
                AutopilotSwitch.writes(capability, .off, repo: nil, config: applied),
                to: &applied
            )
            #expect(AutopilotCoverage.global(capability, config: applied).state == .off)
            try AutopilotSwitch.apply(AutopilotSwitch.writes(capability, .on, repo: nil, config: applied), to: &applied)
            #expect(AutopilotCoverage.global(capability, config: applied).state == .on)
        }
        #expect(applied.work.continuePrompt == AutopilotSwitch.continuePrompt)
    }

    @Test func everyCapabilityTellsItsWholeStory() {
        for capability in Capability.allCases {
            #expect(!capability.sentence.isEmpty && !capability.without.isEmpty && !capability.with.isEmpty)
            #expect(capability.steps.count >= 2 && !capability.never.isEmpty)
            #expect(SettingsPage.named(capability.settingsPage) != nil)
            if let command = capability.command { #expect(Commands.spec(command) != nil) }
        }
    }

    @Test func tabsKeepTheirKeysInEveryView() {
        for scope in AutopilotTabs.panes.map(\.pane) {
            let bound = Dictionary((DefaultKeys.scoped[scope] ?? []).map { ($0.0, $0.1) }) { first, _ in first }
            for (key, command) in AutopilotTabs.keys {
                #expect(bound[key] == command, "\(scope) \(key)")
            }
        }
        #expect(DefaultKeys.normal.contains { $0 == ("gw", "view.autopilot") })
    }
}
