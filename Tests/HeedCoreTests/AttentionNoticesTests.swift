import Foundation
@testable import HeedCore
import Testing

struct AttentionNoticesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let guides = Repo(org: "acme", name: "guides")

    private func entry(
        _ id: String, kind: AttentionItem.Kind = .issue, rule: String? = "mention boost 3",
        mark: AttentionMark = .init(),
        live: Bool = true
    ) -> AttentionEntry {
        let item = AttentionItem(
            id: id, kind: kind, repo: guides, number: 77, title: "Archive the old guides", url: nil,
            reasons: [.teamMention, .yourPR], updatedAt: now.addingTimeInterval(-60)
        )
        let rules = AttentionRules(lines: rule.map { [$0] } ?? [])
        return AttentionEntry(
            item: item, outcome: rules.outcome(for: item, viewer: "you", now: now), mark: mark, live: live
        )
    }

    @Test func onlyWhatARuleSaysToNotifyAbout() throws {
        let notified = try #require(Notices.attention(entry("acme/guides#77"), now: now))
        #expect(notified.id == "attention:acme/guides#77" && notified.session == "attention:acme/guides#77")
        #expect(notified.kind == .attention && notified.title == "guides #77 · Archive the old guides")
        #expect(notified.body == "Wants you: team mention")
        #expect(Notices.attention(entry("a", rule: "mention boost 2 notify"), now: now) != nil)
        #expect(Notices.attention(entry("a", rule: "mention boost 2"), now: now) == nil)
        #expect(Notices.attention(entry("a", rule: nil), now: now) == nil)
        #expect(Notices.attention(entry("a", mark: AttentionMark(mutedAt: now)), now: now) == nil)
        #expect(Notices.attention(entry("a", mark: AttentionMark(snoozedUntil: now.addingTimeInterval(60))), now: now)
            == nil)
        #expect(Notices.attention(entry("a", live: false), now: now) == nil)
        #expect(Notices.attention(entry("agent:s1", kind: .agent, rule: "any boost 3"), now: now) == nil)
    }

    @Test func oneSyncComesAsOneNotificationWithoutGraceOrReminder() throws {
        var notices = Notices()
        let entries = ["a", "b", "c"].compactMap { Notices.attention(entry($0), now: now) }
        notices.sync(.attention, entries, timing: Notices.attentionTiming, at: now)
        #expect(notices.next == now.addingTimeInterval(Notices.window))
        let drained = notices.drain(at: now.addingTimeInterval(Notices.window))
        let notice = try #require(drained)
        #expect(notice.title == "3 things want you in Attention")
        #expect(notice.session == "attention:a")
        // No reminder afterwards.
        #expect(notices.next == nil)
        let events = notices.takeDecisions().map { $0.event(about: nil) }
        #expect(events.count == 3 && events
            .allSatisfy { $0.session == nil && $0.subject?.hasPrefix("attention:") == true })
    }

    @Test func whatWasThereAtLaunchIsNotNews() {
        var notices = Notices()
        let entries = [Notices.attention(entry("a"), now: now)!]
        notices.sync(.attention, entries, timing: Notices.attentionTiming, at: now, seen: true)
        #expect(notices.next == nil)
        // A new one in a later sync is.
        notices.sync(
            .attention, entries + [Notices.attention(entry("b"), now: now)!], timing: Notices.attentionTiming, at: now
        )
        let drained = notices.drain(at: now.addingTimeInterval(Notices.window))
        #expect(drained.map(\.title) == "guides #77 · Archive the old guides")
    }

    @Test func quietHoursHoldAttentionToo() {
        var notices = Notices()
        notices.sync(
            .attention, [Notices.attention(entry("a"), now: now)!], timing: Notices.attentionTiming, at: now
        )
        let drained = notices.drain(at: now.addingTimeInterval(Notices.window), quiet: true)
        #expect(drained == nil)
        #expect(notices.takeDecisions().map(\.outcome) == [.quiet])
    }

    @Test func theDecidersSuggestionIsALevelOrNothing() {
        func answer(_ choice: String) -> [String: Answer] {
            ["weight": Answer(choice: choice, probabilities: [:], confidence: 0.6)]
        }
        #expect(AttentionDecide.suggestion(answer("boost 2")) == "boost 2")
        #expect(AttentionDecide.suggestion(answer("ignore")) == "ignore")
        #expect(AttentionDecide.suggestion(answer("normal")) == nil)
        #expect(AttentionDecide.suggestion(answer("urgent")) == nil)
        #expect(AttentionDecide.suggestion([:]) == nil)
        if case let .score(_, levels) = AttentionDecide.questions["weight"] {
            #expect(levels == AttentionDecide.levels)
        } else {
            Issue.record("weight is a score question")
        }
        #expect(AttentionDecide.state(for: entry("x").item, detail: nil).contains("Why it is here: team mention"))
    }

    @Test func labelsSitBesideTheDecideRows() {
        let item = entry("acme/guides#77").item
        let rule = AttentionRules(lines: ["mention boost 3"]).rules.first
        let call = AttentionLabel.done.call(for: item, rule: rule, suggestion: "boost 2", at: now)
        #expect(call.kind == .decide && call.command == "label" && call.operation == "label done")
        #expect(call.caller == "attention.label" && call.at == now && !call.failed)
        #expect(call.detail == [
            "subject": "acme/guides#77", "label": "done", "reasons": "teamMention,yourPR",
            "rule": "1: mention boost 3", "suggested": "boost 2",
        ])
        #expect(AttentionLabel.mute.call(for: item, rule: nil, suggestion: nil, at: now).detail.keys.sorted() == [
            "label", "reasons", "subject",
        ])
    }

    @Test func theToggleIsInTheConfig() throws {
        let (config, problems) = ConfigLoader.decode("[notifications]\nattention = false\n")
        #expect(problems.isEmpty && config?.notifications.attention == false)
        #expect(HeedConfig.default.notifications.attention)
    }
}
