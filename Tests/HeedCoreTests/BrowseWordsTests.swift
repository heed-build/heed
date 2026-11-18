import Foundation
@testable import HeedCore
import Testing

struct BrowseWordsTests {
    @Test func aValidAnswerBecomesTypedTokens() {
        let answer = """
        {"filters":[{"field":"state","value":"open"},{"field":"label","mode":"any","values":["bug"]},
        {"field":"updated","op":"older","days":30},{"field":"assignee","value":"@me"},
        {"field":"linked_pr","value":false},{"field":"type","value":"issues"}],"text":"anchors"}
        """
        let result = BrowseWords.understand(answer, viewer: "you")
        #expect(result.tokens == [
            .state(.open), .label(.any, ["bug"]), .activity(.olderThan(30)), .assignee("you"), .linkedPull(false),
            .type(.issues), .text("anchors"),
        ])
        #expect(result.dropped.isEmpty)
    }

    @Test func aFencedAnswerStillReads() {
        let result = BrowseWords.understand("```json\n{\"filters\":[{\"field\":\"state\",\"value\":\"closed\"}]}\n```")
        #expect(result.tokens == [.state(.closed)])
    }

    @Test func anUnknownFieldIsDroppedAndSaidNotRun() {
        let result = BrowseWords
            .understand(#"{"filters":[{"field":"sort","value":"comments-desc"},{"field":"state","value":"open"}]}"#)
        #expect(result.tokens == [.state(.open)])
        #expect(result.dropped == ["sort: not a filter heed knows"])
    }

    @Test func heedsOwnFieldsAreReportedNotRunBeforeClassificationExists() {
        let result = BrowseWords
            .understand(#"{"filters":[{"field":"agent_ready","min":70},{"field":"class","value":"bug"}]}"#)
        #expect(result.tokens.isEmpty)
        #expect(result.dropped.count == 2)
    }

    @Test func valuesOutOfRangeOrOfTheWrongShapeAreDropped() {
        let answer = """
        {"filters":[{"field":"created","op":"older","days":99999},{"field":"created","op":"sideways","days":3},
        {"field":"state","value":"deleted"},{"field":"repo","value":"not a repo"},
        {"field":"assignee","value":"x label:y"},{"field":"label","mode":"any","values":[]},
        {"field":"label","values":["bug\\nis:private"]}]}
        """
        let result = BrowseWords.understand(answer)
        #expect(result.tokens.isEmpty)
        #expect(result.dropped.count == 7)
    }

    @Test func hostileTextCannotCarryAQualifier() {
        let answer = #"{"filters":[],"text":"anchors is:private -label:bug org:secret \"quoted"}"#
        let result = BrowseWords.understand(answer)
        #expect(result.tokens == [.text("anchors")])
        #expect(result.dropped.count == 4)
        let query = BrowseQuery(tokens: result.tokens, showOlder: true)
        #expect(query.rendered(maxAgeDays: 90, now: Date()) == "anchors")
    }

    @Test func aHostileLabelIsQuotedByTheTokenNotInjected() {
        let result = BrowseWords.understand(#"{"filters":[{"field":"label","values":["bug\" -author:\"x"]}]}"#)
        guard case let .label(_, names)? = result.tokens.first else { Issue.record("no label"); return }
        let text = BrowseQuery(tokens: [.label(.any, names)], showOlder: true).rendered(maxAgeDays: 90, now: Date())
        // One quoted value, the inner quotes escaped: the parser reads it back as the same single label.
        #expect(BrowseQuery.parse(text, maxAgeDays: 90, now: Date()).tokens == [.label(.any, names)])
    }

    @Test func aSecondFilterOfTheSameKindAndTooManyAreDropped() {
        let many = (0 ..< 20).map { #"{"field":"milestone","value":"m\#($0)"}"# }.joined(separator: ",")
        let result = BrowseWords.understand("{\"filters\":[\(many)]}")
        #expect(result.tokens == [.milestone("m0")])
        #expect(result.dropped.count == 19)
    }

    @Test func notJSONIsReportedNotGuessed() {
        let result = BrowseWords.understand("Sure! Here are your bugs.")
        #expect(result.tokens.isEmpty && result.dropped.count == 1)
    }

    @Test func theSentenceIsHeedsOwnWordsInThePromptAndCut() {
        let inputs = BrowseWords.inputs(String(repeating: "a", count: 1000))
        #expect(inputs.title.text.count < 400)
    }
}
