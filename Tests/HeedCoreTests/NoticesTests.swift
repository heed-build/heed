import Foundation
@testable import HeedCore
import Testing

struct NoticesTests {
    private let on = NotificationSettings()
    private let start = Date(timeIntervalSince1970: 1000)

    private func note(
        _ notices: inout Notices, _ id: String, _ old: AgentState, _ new: AgentState, reason: String? = nil,
        agent: String = "claude", settings: NotificationSettings? = nil, after seconds: TimeInterval = 0
    ) {
        notices.note(
            id: id, title: "t-\(id)", agent: agent, from: old, to: ObservedState(new, reason: reason),
            settings: settings ?? on, at: start.addingTimeInterval(seconds)
        )
    }

    @Test func oneSessionEnteringNeedsYouIsOneNotice() {
        var notices = Notices()
        note(&notices, "a", .working, .blocked, reason: "Bash(rm -rf build)")
        #expect(!notices.due(at: start.addingTimeInterval(1)))
        #expect(notices.due(at: start.addingTimeInterval(Notices.window)))
        let notice = notices.drain()
        #expect(notice == .one(.init(
            id: "a",
            title: "t-a",
            agent: "claude",
            state: .blocked,
            reason: "Bash(rm -rf build)"
        )))
        #expect(notice?.title == "t-a")
        #expect(notice?.body == "Blocked: Bash(rm -rf build)")
        #expect(notices.pending.isEmpty && notices.since == nil)
    }

    @Test func aBurstIsOneSummaryBlockedFirst() {
        var notices = Notices()
        note(&notices, "a", .working, .asking, reason: TurnEnd.question)
        note(&notices, "b", .working, .blocked, after: 1)
        note(&notices, "c", .done, .asking, after: 2)
        let notice = notices.drain()
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
        #expect(notices.pending.isEmpty && notices.since == nil)
        #expect(notices.drain() == nil)
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
        #expect(notices.drain { $0 == "a" } == .one(.init(id: "b", title: "t-b", agent: "claude", state: .asking)))
        note(&notices, "a", .working, .blocked)
        #expect(notices.drain { _ in true } == nil)
    }

    @Test func configDecodes() {
        #expect(HeedConfig.default.notifications == NotificationSettings(enabled: true, asking: true, blocked: true))
        let (config, problems) = ConfigLoader.decode("""
        [notifications]
        enabled = true
        asking = false
        """)
        #expect(problems.isEmpty)
        #expect(config?.notifications == NotificationSettings(enabled: true, asking: false, blocked: true))
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.notifications == NotificationSettings())
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
