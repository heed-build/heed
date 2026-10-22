import Foundation
@testable import HeedCore
import Testing

struct PilotTests {
    private let heed = Repo(org: "globex", name: "heed")
    private let kibana = Repo(org: "acme", name: "kibana")
    private let docs = Repo(org: "acme", name: "docs-toolkit")
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func pull(_ repo: Repo, checks: CheckSummary = CheckSummary(passed: 1), threads: Int = 0) -> PullRequest {
        PullRequest(
            ref: PullRef(repo: repo, number: 1), title: "t", url: "", state: .open, isDraft: false, headBranch: "b",
            review: nil, checks: checks, unresolvedThreads: threads, updatedAt: now
        )
    }

    @Test func settingsResolveRepoThenOrgThenDefaultPerField() {
        let rules = PilotRules(
            defaults: PilotSettings(watch: true, green: .ask, maxRounds: 3),
            orgs: ["acme": PilotOverrides(watch: false, green: .auto)],
            repos: ["acme/docs-toolkit": PilotOverrides(watch: true)]
        )
        #expect(rules.resolve(heed) == PilotSettings(watch: true, green: .ask, maxRounds: 3))
        #expect(rules.resolve(kibana).watch == false)
        #expect(rules.resolve(kibana).green == .auto)
        // The repo turns watching back on; green still comes from its org.
        #expect(rules.resolve(docs).watch == true)
        #expect(rules.resolve(docs).green == .auto)
        #expect(rules.watchSource(docs) == "repo")
        #expect(rules.watchSource(kibana) == "org")
        #expect(rules.watchSource(heed) == "default")
    }

    @Test func aHandSetChoiceWinsAndSticksWhenSettingsChange() {
        var pipeline = PullFeedback(ref: PullRef(repo: heed, number: 1))
        let on = PilotSettings(watch: true, green: .auto)
        let off = PilotSettings(watch: false, green: .off)
        #expect(pipeline.effective(on).watching)
        #expect(!pipeline.effective(off).watching)
        // Untouched: settle writes what the settings say.
        pipeline.settle(off)
        #expect(!pipeline.watching && pipeline.autoFeed == .off)
        // By hand: wins over every later setting.
        pipeline.watching = true
        pipeline.watchSet = true
        pipeline.settle(off)
        #expect(pipeline.watching)
        #expect(pipeline.effective(off).watching)
        #expect(PullFeedback.effective(nil, off) == PullFeedback.Effective(watching: false, green: .off, maxRounds: 3))
    }

    @Test func oldCachesStillLoad() throws {
        let fresh = PullFeedback(ref: PullRef(repo: heed, number: 1))
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(fresh)) as? [String: Any])
        for key in ["watchSet", "greenSet", "maxRounds", "pausedUntil", "pausedForever"] {
            json[key] = nil
        }
        let old = try JSONDecoder().decode(PullFeedback.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(!old.watchSet && !old.greenSet && old.maxRounds == 3 && old.pausedUntil == nil && !old.pausedForever)

        var domain = try #require(JSONSerialization
            .jsonObject(with: JSONEncoder().encode(Domain.empty)) as? [String: Any])
        domain["pilotLog"] = nil
        let loaded = try JSONDecoder().decode(Domain.self, from: JSONSerialization.data(withJSONObject: domain))
        #expect(loaded.pilotLog.isEmpty)
    }

    @Test func statusFollowsWhatThePRAndItsPipelineSay() {
        let settings = PilotSettings()
        let ref = PullRef(repo: heed, number: 1)
        func status(_ pull: PullRequest?, _ pipeline: PullFeedback?, session: Bool = true) -> PilotStatus {
            PilotStatus.of(pull: pull, pipeline: pipeline, settings: settings, hasSession: session, now: now)
        }
        #expect(status(pull(heed), nil) == .passing)
        #expect(status(pull(heed, checks: CheckSummary(passed: 1, failed: 2)), nil) == .failing(2))
        #expect(status(pull(heed, threads: 3), nil) == .changes(3))
        #expect(status(pull(heed, checks: CheckSummary(pending: 1)), nil) == .pending)
        #expect(PilotStatus.of(
            pull: pull(heed),
            pipeline: nil,
            settings: PilotSettings(watch: false),
            hasSession: true,
            now: now
        ) == .unwatched)

        var paused = PullFeedback(ref: ref)
        paused.pausedUntil = now.addingTimeInterval(600)
        #expect(status(pull(heed), paused) == .paused(until: now.addingTimeInterval(600)))
        paused.pausedUntil = now.addingTimeInterval(-1)
        #expect(status(pull(heed), paused) == .passing)

        var waiting = PullFeedback(ref: ref, items: [FeedbackItem(
            id: "t",
            kind: .review(location: "a", author: "r"),
            text: "x",
            status: .new
        )])
        #expect(status(pull(heed, threads: 1), waiting, session: false) == .stuck("no session to send feedback to"))
        waiting.rounds = 3
        #expect(status(pull(heed, threads: 1), waiting) == .stalled(rounds: 3))
        #expect(PilotStatus.stalled(rounds: 3).group == .stalled)
        // Stalled waits on a reviewer, not on you: it does not count toward what needs you.
        #expect(PilotStatus.stuck("x").needsYou && !PilotStatus.passing.needsYou && !PilotStatus.stalled(rounds: 3)
            .needsYou)

        var sent = PullFeedback(ref: ref, items: [FeedbackItem(
            id: "t",
            kind: .check(name: "lint"),
            text: "x",
            status: .sent
        )])
        sent.rounds = 1
        #expect(status(pull(heed, checks: CheckSummary(failed: 1, failedNames: ["lint"])), sent) == .feeding)
    }

    @Test func aFetchLogsWhatArrivedWasAddressedAndResolved() {
        let ref = PullRef(repo: heed, number: 1)
        var before = PullFeedback(ref: ref, items: [
            FeedbackItem(id: "t1", kind: .review(location: "a", author: "r"), text: "x", status: .sent),
            FeedbackItem(id: "check:lint", kind: .check(name: "lint"), text: "x", status: .new),
        ])
        before.rounds = 1
        var after = before
        after.items[0].status = .addressed
        after.items[1].status = .resolved
        after.items.append(FeedbackItem(id: "t2", kind: .review(location: "b", author: "r"), text: "y", status: .new))
        let events = PilotEvent.changes(from: before, to: after, at: now)
        #expect(events.map(\.kind) == [.items, .addressed, .resolved])
        #expect(events[0].text == "1 review thread arrived")
        #expect(events[2].text == "check lint resolved")
        let old = PilotEvent(at: now.addingTimeInterval(-15 * 86400), ref: events[0].ref, kind: .items, text: "old")
        let capped = PilotEvent.log(Array(repeating: old, count: PilotEvent.logLimit), adding: [events[1]])
        #expect(capped.count == PilotEvent.logLimit && capped.first == events[1])
    }

    @Test func durations() {
        #expect(PilotDuration.parse("1h") == .seconds(3600))
        #expect(PilotDuration.parse("30m") == .seconds(1800))
        #expect(PilotDuration.parse("2d") == .seconds(172_800))
        #expect(PilotDuration.parse("forever") == .forever)
        #expect(PilotDuration.parse("off") == .off)
        #expect(PilotDuration.parse("soon") == nil)
        #expect(PilotDuration.text(42 * 60) == "42m")
        #expect(PilotDuration.text(185 * 60) == "3h 5m")
        #expect(PilotDuration.text(2 * 86400) == "2d")
    }

    @Test func configReadsPilotAtEveryLevel() {
        let (config, problems) = ConfigLoader.decode("""
        [pilot]
        watch = true
        green = "auto"
        max_rounds = 5
        pause = "4h"
        [orgs.employer]
        watch = false
        [repos."employer/main"]
        watch = true
        green = "ask"
        [repos."acme/x"]
        green = "sometimes"
        """)
        #expect(config?.pilot.defaults == PilotSettings(watch: true, green: .auto, maxRounds: 5, pause: 4 * 3600))
        #expect(config?.pilot.orgs == ["employer": PilotOverrides(watch: false)])
        #expect(config?.pilot.repos["employer/main"] == PilotOverrides(watch: true, green: .ask))
        #expect(config?.pilot.resolve(Repo(org: "employer", name: "other")).watch == false)
        #expect(config?.pilot.resolve(Repo(org: "employer", name: "main")).watch == true)
        #expect(problems.map(\.path) == ["repos.acme/x.green"])
    }
}
