import Foundation
@testable import HeedCore
import Testing

struct AttentionRuleEditingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(_ id: String, _ reasons: Set<AttentionReason>, teams: Set<String> = [], labels: [String] = [])
        -> AttentionItem
    {
        AttentionItem(
            id: id, kind: .issue, repo: Repo(org: "acme", name: "docs"), number: 1, title: id, url: nil,
            reasons: reasons, teams: teams, updatedAt: now, labels: labels
        )
    }

    @Test func levels() {
        #expect(AttentionLevel(AttentionAction()) == .normal)
        #expect(AttentionLevel(AttentionAction(boost: 1)) == .high)
        #expect(AttentionLevel(AttentionAction(boost: 2, pin: true)) == .pinned)
        #expect(AttentionLevel(AttentionAction(lower: true)) == .low)
        #expect(AttentionLevel(AttentionAction(ignore: true)) == .hidden)
    }

    @Test func tryBeforeYouSaveCountsWhatWouldMove() {
        let items = (0 ..< 5).map { item("all\($0)", [.teamMention], teams: ["acme/docs-all"]) }
            + [
                item("eng", [.teamMention], teams: ["acme/docs-eng"]),
                item("me", [.mentioned]),
                item("blocker", [.assigned], labels: ["blocker"]),
            ]
        let saved = AttentionRules(lines: ["mention boost 1", "label blocker pin"])
        let edited = AttentionRules(lines: [
            "mention team:acme/docs-all lower", "mention boost 1", "label blocker pin", "mention team:? ignore",
        ])
        let preview = AttentionRulePreview.of(saved: saved, edited: edited, items: items, viewer: "you", now: now)
        #expect(preview.items == 8)
        #expect(preview.changed == 5)
        #expect(preview.moves == [.init(from: .high, to: .low, count: 5)])
        // First-match counts per edited line; the last line never wins.
        #expect(preview.matches == [1: 5, 2: 2, 3: 1])
        let same = AttentionRulePreview.of(saved: saved, edited: saved, items: items, viewer: "you", now: now)
        #expect(same.changed == 0 && same.moves.isEmpty)
    }

    @Test func movesAreOrderedMostFirst() {
        let items = [item("a", [.comment]), item("b", [.comment]), item("c", [.assigned])]
        let preview = AttentionRulePreview.of(
            saved: AttentionRules(), edited: AttentionRules(lines: ["comment ignore", "assigned boost 2"]),
            items: items, viewer: nil, now: now
        )
        #expect(preview.moves == [
            .init(from: .normal, to: .hidden, count: 2), .init(from: .normal, to: .high, count: 1),
        ])
    }

    @Test func aDraftEditsAsAListOrAsText() {
        var draft = AttentionRuleDraft(lines: ["mention boost 3", "ci lower"])
        draft.add("  author bot ignore ")
        draft.add("label x pin", at: 0)
        draft.add("   ")
        #expect(draft.lines == ["label x pin", "mention boost 3", "ci lower", "author bot ignore"])
        draft.move(3, by: -1)
        #expect(draft.lines == ["label x pin", "mention boost 3", "author bot ignore", "ci lower"])
        draft.move(0, by: -1)
        draft.move(3, by: 1)
        draft.move(9, by: -8)
        #expect(draft.lines.first == "label x pin" && draft.lines.last == "ci lower")
        draft.remove(at: 0)
        draft.remove(at: 9)
        draft.edit(0, to: "mention boost 7")
        #expect(draft.problem(line: 1) == "boost takes 1, 2 or 3")
        #expect(draft.problem(line: 2) == nil)
        draft.text = "mention boost 2\n\n# note\nci lower\n\n"
        #expect(draft.lines == ["mention boost 2", "", "# note", "ci lower"])
        #expect(draft.saved == ["mention boost 2", "# note", "ci lower"])
        #expect(draft.rules.rules.count == 2)
    }

    @Test func rulesAreWrittenOneALineAndReadBack() throws {
        let source = """
        [attention]
        quiet = ""
        rules = ["any lower"]

        [summary]
        away_hours = 8
        """
        let lines = ["mention user:me boost 3", "label \"blocker\" pin"]
        let written = try TOMLDocument(source).setting(
            ["attention", "rules"], to: .array(lines.map { .string($0) }), multiline: true
        )
        #expect(written.contains("""
        rules = [
          "mention user:me boost 3",
          "label \\"blocker\\" pin",
        ]
        """))
        let (config, problems) = ConfigLoader.decode(written)
        #expect(problems.isEmpty && config?.attention.rules == lines && config?.summaryAwayHours == 8)
        // A table without rules gets them added; none at all is an empty array.
        let added = try TOMLDocument("[attention]\nquiet = \"\"\n").setting(
            ["attention", "rules"], to: .array([]), multiline: true
        )
        #expect(added == "[attention]\nquiet = \"\"\nrules = []\n")
    }
}
