import Foundation
@testable import HeedCore
import Testing

struct AttentionActionsTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let guides = Repo(org: "acme", name: "guides")

    private func item(
        _ id: String, kind: AttentionItem.Kind = .issue, number: Int? = 77,
        reasons: Set<AttentionReason> = [.teamMention]
    ) -> AttentionItem {
        AttentionItem(
            id: id, kind: kind, repo: guides, number: number, title: "Archive the old guides", url: nil,
            reasons: reasons, teams: ["acme/docs-eng"], updatedAt: now, author: "maintainer"
        )
    }

    @Test func theModelReadsWhyAndTheThread() {
        let detail = ThreadDetail(
            url: "u", body: "Proposal: archive them.",
            comments: [.init(author: "writer", text: "Fine by us.", at: now)], updatedAt: now
        )
        let inputs = AttentionText.inputs(for: item("acme/guides#77"), detail: detail)
        #expect(inputs.title == "Archive the old guides" && inputs.repo == "acme/guides#77")
        let thread = inputs.pullRequest ?? ""
        #expect(thread.contains("Why it is here: team mention"))
        #expect(thread.contains("Through the team: acme/docs-eng"))
        #expect(thread.contains("Opened by maintainer") && thread.contains("Proposal: archive them."))
        #expect(inputs.timeline == ["writer: Fine by us."])
        #expect(AttentionText.inputs(for: item("x"), detail: nil).timeline.isEmpty)
    }

    @Test func threadAndReplyPromptsAreHeeds() {
        #expect(Summarizer.system(.thread, instructions: "").contains("what it asks of them"))
        #expect(Summarizer.system(.reply, instructions: "").contains("[placeholder]"))
        #expect(Summarizer.system(.reply, instructions: "Sign with -- M").hasSuffix("Also: Sign with -- M"))
    }

    @Test func workStartsFromTheThreads() {
        let issue = Issue(
            repo: guides, number: 77, title: "Archive the old guides", url: "", body: "The whole text.", labels: [],
            author: nil, updatedAt: now
        )
        // One issue heed has the text of: its whole text.
        let whole = AttentionText.workPrompt([item("acme/guides#77")], issues: [issue])
        #expect(whole.contains("The whole text.") && whole.contains("Closes acme/guides#77"))
        // Several, or one not known: a list, agents left out.
        let list = AttentionText.workPrompt(
            [
                item("acme/guides#77"),
                item("acme/guides#81", kind: .pr, number: 81, reasons: [.reviewRequested]),
                item("agent:s1", kind: .agent, number: nil),
            ],
            issues: [issue], instructions: "Keep redirects."
        )
        #expect(list == """
        Look into these:
        - guides#77 Archive the old guides (team mention)
        - guides#81 Archive the old guides (review requested)

        Keep redirects.
        """)
        #expect(AttentionText.workPrompt([item("agent:s1", kind: .agent)], issues: []).isEmpty)
    }

    @Test func snoozeEnds() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Amsterdam"))
        #expect(AttentionText.snoozeEnd(nil, now: now) == now.addingTimeInterval(3 * 3600))
        #expect(AttentionText.snoozeEnd("", now: now) == now.addingTimeInterval(3 * 3600))
        #expect(AttentionText.snoozeEnd("30m", now: now) == now.addingTimeInterval(1800))
        #expect(AttentionText.snoozeEnd("2d", now: now) == now.addingTimeInterval(2 * 86400))
        let tomorrow = try #require(AttentionText.snoozeEnd("Tomorrow", now: now, calendar: calendar))
        let parts = calendar.dateComponents([.hour, .minute, .day], from: tomorrow)
        #expect(parts.hour == 9 && parts.minute == 0)
        #expect(parts.day == calendar.component(.day, from: now) + 1)
        #expect(AttentionText.snoozeEnd("soon", now: now) == nil)
        #expect(AttentionText.snoozeEnd("0h", now: now) == nil)
    }

    @Test func keysOpenAttentionWithAFilter() {
        let normal = Dictionary(DefaultKeys.normal.map { ($0.0, $0.1) }) { first, _ in first }
        #expect(normal["gm"] == "view.attention")
        #expect(normal["gi"] == "view.attention issues")
        #expect(normal["gp"] == "view.attention mine")
        #expect(normal["gw"] == "view.watch" && normal["ga"] == "session.attention")
        #expect(AttentionFilter(rawValue: "issues") == .issues && AttentionFilter(rawValue: "mine") == .myPRs)
        let scoped = Dictionary(DefaultKeys.scoped["attention"]!.map { ($0.0, $0.1) }) { first, _ in first }
        #expect(scoped["x"] == "attention.done" && scoped["Z"] == "attention.snooze" && scoped["M"] == "attention.mute")
        #expect(scoped["R"] == "attention.reply" && scoped["gS"] == "attention.session")
    }

    @Test func completionOffersFiltersAndDurations() {
        #expect(CommandCompletions.candidates("view.attention ").map(\.label) == AttentionFilter.allCases
            .map(\.rawValue))
        #expect(CommandCompletions.candidates("attention.snooze to").map(\.label) == ["tomorrow"])
        #expect(CommandAliases.resolve("attention") == CommandInvocation(name: "view", arguments: ["attention"]))
    }
}
