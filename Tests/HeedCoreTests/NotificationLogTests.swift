import Foundation
@testable import HeedCore
import Testing

/// Each notification decision (posted, or not and why) goes to the event log.
struct NotificationLogTests {
    private let start = Date(timeIntervalSince1970: 1000)
    private let settings = NotificationSettings(graceSeconds: 30, reminderMinutes: 15)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func change(_ notices: inout Notices, _ id: String, _ old: AgentState, _ new: AgentState, _ after: Double) {
        notices.note(
            id: id, title: "t-\(id)", agent: "claude", from: old, to: ObservedState(new, reason: "Bash(ls)"),
            settings: settings, at: at(after)
        )
    }

    private func outcomes(_ notices: inout Notices) -> [String] {
        notices.takeDecisions().map { "\($0.entry.id) \($0.outcome.rawValue)\($0.entry.reminder ? " reminder" : "")" }
    }

    @Test func everyDecisionIsRecordedOnce() {
        var notices = Notices()
        change(&notices, "a", .working, .blocked, 0)
        change(&notices, "b", .working, .asking, 0)
        change(&notices, "c", .working, .asking, 0)
        change(&notices, "c", .asking, .working, 10)
        #expect(outcomes(&notices) == ["c cleared within the grace"])
        _ = notices.drain(at: at(33)) { $0 == "b" }
        #expect(outcomes(&notices) == ["a posted", "b on screen"])
        #expect(outcomes(&notices).isEmpty)
        _ = notices.drain(at: at(33 + 900 + 3), quiet: true)
        #expect(outcomes(&notices) == ["a quiet hours reminder", "b quiet hours reminder"])
        // Leaving after it was shown is not a decision.
        change(&notices, "a", .blocked, .working, 2000)
        #expect(outcomes(&notices).isEmpty)
    }

    @Test func whatLeavesASyncWithinTheGraceIsCleared() throws {
        var notices = Notices()
        let ref = PullRef(repo: Repo(org: "acme", name: "api"), number: 12)
        let session = Session(
            id: "s1", title: "Fix the parser", repos: [ref.repo], branch: "fix", agent: "claude",
            state: ObservedState(.working), trackedPRs: [ref]
        )
        let pull = try #require(Notices.pull(ref, status: .stuck("conflicts"), of: session))
        notices.sync(.pull, [pull], timing: Notices.Timing(settings), at: start)
        notices.sync(.pull, [], timing: Notices.Timing(settings), at: at(5))
        let decision = try #require(notices.takeDecisions().first)
        #expect(decision.outcome == .cleared)
        let event = decision.event(about: session)
        #expect(event.kind == .notification && event.session == "s1" && event.repo == "acme/api")
        #expect(event.subject == "pull:acme/api#12")
        #expect(event.text == "not notified (cleared within the grace): Needs you: conflicts")
        #expect(event.payload == ["outcome": "cleared within the grace", "kind": "pull", "reminder": "false"])
    }

    @Test func theStoreWritesThemToTheLog() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-notify-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        let store = DomainStore(file: dir.appendingPathComponent("domain.json"), log: log)
        let entry = Notices.Entry(id: "s1", title: "Docs", agent: "claude", state: .blocked, reason: "Bash(ls)")
        await store.log([Notices.Decision(entry: entry, outcome: .posted, at: start).event(about: nil)])
        await store.flushAll()
        let logged = try await log.events(kinds: [.notification], limit: 10)
        #expect(logged.map(\.text) == ["notified: Blocked: Bash(ls)"])
        #expect(logged.first?.session == "s1" && logged.first?.subject == nil)
    }
}
