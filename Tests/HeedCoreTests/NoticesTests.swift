import Foundation
@testable import HeedCore
import Testing

struct NoticesTests {
    /// Today's timing before grace existed: the burst window only.
    private let on = NotificationSettings(graceSeconds: 0, reminderMinutes: 0)
    private let start = Date(timeIntervalSince1970: 1000)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func note(
        _ notices: inout Notices, _ id: String, _ old: AgentState, _ new: AgentState, reason: String? = nil,
        agent: String = "claude", settings: NotificationSettings? = nil, after seconds: TimeInterval = 0
    ) {
        notices.note(
            id: id, title: "t-\(id)", agent: agent, from: old, to: ObservedState(new, reason: reason),
            settings: settings ?? on, at: at(seconds)
        )
    }

    @Test func oneSessionEnteringNeedsYouIsOneNotice() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, reason: "Bash(rm -rf build)")
        #expect(!notices.due(at: at(1)))
        #expect(notices.due(at: at(Notices.window)))
        let notice = notices.drain(at: at(Notices.window))
        #expect(notice == .one(.init(
            id: "a",
            title: "t-a",
            agent: "claude",
            state: .blocked,
            reason: "Bash(rm -rf build)"
        )))
        #expect(notice?.title == "t-a")
        #expect(notice?.body == "Blocked: Bash(rm -rf build)")
        #expect(notices.pending.isEmpty && notices.next == nil)
    }

    @Test func aBurstIsOneSummaryBlockedFirst() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, reason: TurnEnd.question)
        note(&notices, "b", .working, .blocked, after: 1)
        note(&notices, "c", .done, .asking, after: 2)
        let notice = notices.drain(at: at(Notices.window))
        guard case let .summary(entries) = notice else { Issue.record("expected a summary"); return }
        #expect(entries.map(\.id) == ["b", "a", "c"])
        #expect(notice?.title == "3 sessions need you")
        #expect(notice?.session == "b")
        #expect(notice?.body == "t-b · blocked\nt-a · asking\nt-c · asking")
    }

    @Test func oneNoticePerStateChange() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked)
        note(&notices, "a", .blocked, .blocked, reason: "again")
        note(&notices, "a", .blocked, .asking)
        #expect(notices.pending.map(\.state) == [.asking])
    }

    @Test func aSessionThatMovesOnLeavesTheBatch() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked)
        note(&notices, "a", .blocked, .working)
        #expect(notices.pending.isEmpty && notices.next == nil)
        #expect(notices.drain(at: at(Notices.window)) == nil)
    }

    @Test func onlyWantedStates() {
        var notices = Notices()
        note(&notices, "a", .working, .done)
        note(&notices, "b", .working, .limited)
        note(&notices, "c", .working, .idle)
        #expect(notices.pending.isEmpty)
        note(&notices, "d", .working, .asking, settings: NotificationSettings(asking: false))
        note(&notices, "e", .working, .blocked, settings: NotificationSettings(enabled: false))
        #expect(notices.pending.isEmpty)
        note(&notices, "f", .working, .blocked, settings: NotificationSettings(asking: false))
        #expect(notices.pending.map(\.id) == ["f"])
    }

    @Test func theSessionOnScreenIsLeftOut() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked)
        note(&notices, "b", .working, .asking)
        #expect(notices.drain(at: at(3)) { $0 == "a" } == .one(.init(
            id: "b", title: "t-b", agent: "claude", state: .asking
        )))
        note(&notices, "c", .working, .blocked, after: 10)
        #expect(notices.drain(at: at(13)) { _ in true } == nil)
    }

    // MARK: Grace

    private let grace = NotificationSettings(graceSeconds: 30, reminderMinutes: 0)

    @Test func nothingBeforeTheGraceThenTheBurstWindow() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, settings: grace)
        #expect(notices.next == at(30 + Notices.window))
        #expect(!notices.due(at: at(30)))
        #expect(notices.drain(at: at(30)) == nil)
        #expect(notices.due(at: at(33)))
        #expect(notices.drain(at: at(33)) == .one(.init(id: "a", title: "t-a", agent: "claude", state: .blocked)))
        #expect(notices.next == nil)
    }

    @Test func aPromptThatClearsWithinTheGraceNeverShows() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, settings: grace)
        note(&notices, "a", .blocked, .working, settings: grace, after: 29)
        #expect(notices.next == nil)
        #expect(notices.drain(at: at(60)) == nil)
    }

    @Test func aChangeOfStateStartsTheGraceOver() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, settings: grace)
        note(&notices, "a", .blocked, .asking, settings: grace, after: 20)
        #expect(notices.drain(at: at(33)) == nil)
        #expect(notices.next == at(53))
        #expect(notices.drain(at: at(53))?.body == "Asking")
    }

    @Test func burstsAfterTheGraceStillComeAsOne() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, settings: grace)
        note(&notices, "b", .working, .blocked, settings: grace, after: 2)
        note(&notices, "c", .working, .asking, settings: grace, after: 10)
        guard case let .summary(entries) = notices.drain(at: at(33)) else { Issue.record("expected a summary"); return }
        #expect(entries.map(\.id) == ["b", "a"])
        #expect(notices.next == at(43))
        #expect(notices.drain(at: at(43))?.session == "c")
    }

    @Test func guessedStatesWaitTheSameGrace() {
        var notices = Notices()
        notices.note(
            id: "a", title: "t-a", agent: "codex", from: .working,
            to: ObservedState(.asking, source: .guessed, reason: TurnEnd.question), settings: grace, at: start
        )
        #expect(notices.next == at(33))
    }

    // MARK: Reminder

    private let remind = NotificationSettings(graceSeconds: 30, reminderMinutes: 15)

    @Test func oneReminderThenSilence() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, reason: "Bash(ls)", settings: remind)
        #expect(notices.drain(at: at(33))?.body == "Blocked: Bash(ls)")
        #expect(notices.next == at(33 + 15 * 60 + Notices.window))
        #expect(notices.drain(at: at(33 + 15 * 60)) == nil)
        let reminder = notices.drain(at: at(36 + 15 * 60))
        #expect(reminder?.body == "Still blocked: Bash(ls)")
        #expect(notices.next == nil)
        #expect(notices.drain(at: at(10 * 3600)) == nil)
        #expect(notices.stage(of: "a") == .done)
    }

    @Test func leavingAndComingBackStartsOver() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, settings: remind)
        _ = notices.drain(at: at(33))
        _ = notices.drain(at: at(33 + 15 * 60 + 3))
        note(&notices, "a", .blocked, .working, settings: remind, after: 2000)
        #expect(notices.stage(of: "a") == nil)
        note(&notices, "a", .working, .blocked, settings: remind, after: 2100)
        #expect(notices.drain(at: at(2133))?.body == "Blocked")
    }

    @Test func noReminderOnceItMovesOn() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, settings: remind)
        _ = notices.drain(at: at(33))
        note(&notices, "a", .asking, .working, settings: remind, after: 600)
        #expect(notices.next == nil)
    }

    @Test func reminderZeroIsNone() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, settings: grace)
        _ = notices.drain(at: at(33))
        #expect(notices.stage(of: "a") == .notified(remind: nil))
        #expect(notices.next == nil)
    }

    @Test func remindersTogetherSayStill() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, settings: remind)
        note(&notices, "b", .working, .asking, settings: remind, after: 1)
        _ = notices.drain(at: at(33))
        #expect(notices.drain(at: at(36 + 15 * 60))?.title == "2 sessions still need you")
    }

    @Test func seenOnScreenStillGetsItsReminder() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, settings: remind)
        #expect(notices.drain(at: at(33)) { _ in true } == nil)
        #expect(notices.drain(at: at(36 + 15 * 60))?.body == "Still blocked")
    }

    @Test func configDecodes() {
        #expect(HeedConfig.default.notifications == NotificationSettings(
            enabled: true, asking: true, blocked: true, graceSeconds: 30, reminderMinutes: 15
        ))
        let (config, problems) = ConfigLoader.decode("""
        [notifications]
        enabled = true
        asking = false
        grace_seconds = 0
        reminder_minutes = 5
        """)
        #expect(problems.isEmpty)
        #expect(config?.notifications == NotificationSettings(
            enabled: true, asking: false, blocked: true, graceSeconds: 0, reminderMinutes: 5
        ))
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.notifications == NotificationSettings())
        let bad = ConfigLoader.decode("[notifications]\ngrace_seconds = -1\n")
        #expect(bad.problems.map(\.path) == ["notifications.grace_seconds"])
        #expect(bad.config?.notifications.graceSeconds == 30)
        #expect(Notices.Timing(NotificationSettings()) == Notices.Timing(grace: 30, reminder: 900))
    }
}

struct AllowFromNotificationTests {
    private let prompt = """
    ╭───────────────────────────────────────────╮
    │ Bash command                              │
    │   rm -rf build                            │
    │ Do you want to proceed?                   │
    │ ❯ 1. Yes                                  │
    │   2. Yes, and don't ask again this session│
    │   3. No, and tell Claude what to do       │
    ╰───────────────────────────────────────────╯


    """

    @Test func claudesPromptWithTheCursorOnYes() {
        #expect(ScreenGuess.allowsWithReturn(agent: "claude", screen: prompt))
    }

    @Test func anythingElseIsLeftToYou() {
        #expect(!ScreenGuess.allowsWithReturn(agent: "codex", screen: prompt))
        let moved = prompt.replacingOccurrences(of: "❯ 1. Yes", with: "  1. Yes")
            .replacingOccurrences(of: "  3. No", with: "❯ 3. No")
        #expect(!ScreenGuess.allowsWithReturn(agent: "claude", screen: moved))
        #expect(!ScreenGuess.allowsWithReturn(agent: "claude", screen: "> \n  ❯ 1. Yes is what I typed"))
        let gone = prompt + String(repeating: "output line\n", count: 20)
        #expect(!ScreenGuess.allowsWithReturn(agent: "claude", screen: gone))
    }
}
