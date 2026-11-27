import Foundation
@testable import HeedCore
import Testing

struct BrowseBuilderTests {
    /// 2033-05-18T03:33:20Z.
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let docs = Repo(org: "acme", name: "docs")
    private let ingest = Repo(org: "acme", name: "ingest")

    private func item(
        _ repo: Repo, _ number: Int, labels: [String] = [], days: Double, assignees: [String] = [],
        author: String = "mara", kind: BrowseItem.Kind = .issue
    ) -> BrowseItem {
        BrowseItem(
            repo: repo, number: number, kind: kind, title: ExternalText(
                "T\(number)",
                source: .issueTitle,
                author: .unknown
            ),
            author: author, labels: labels, assignees: assignees,
            createdAt: now.addingTimeInterval(-(days + 3) * 86400),
            updatedAt: now.addingTimeInterval(-days * 86400)
        )
    }

    private var items: [BrowseItem] {
        [
            item(docs, 1, labels: ["bug"], days: 1, assignees: ["you"]),
            item(docs, 2, labels: ["bug", "redirects"], days: 5),
            item(docs, 3, labels: ["enhancement"], days: 20, author: "jdoe"),
            item(ingest, 4, labels: ["bug", "perf"], days: 40),
            item(ingest, 5, labels: ["docs"], days: 80, kind: .pull),
        ]
    }

    @Test func theProjectFieldIsNotOffered() {
        #expect(!BrowseField.offered.contains(.project))
        #expect(!builder().fields.contains(.project))
        // Typing its name finds nothing to pick, and the number keys name the fields the popover shows.
        var typed = builder()
        type("proj", into: &typed)
        #expect(!typed.fields.contains(.project))
        var b = builder()
        b.open(.project)
        #expect(b.stage == .fields)
        #expect(BrowseField.offered.count == BrowseField.allCases.count - 1)
    }

    @Test func aStoredProjectTokenStillRendersForGitHubAndIsNotJudgedLocally() {
        let query = BrowseQuery(scope: .org("acme"), tokens: [.state(.open), .project("acme/7")])
        #expect(query.rendered(maxAgeDays: 90, now: now).contains("project:acme/7"))
        // GitHub judged it: every item it listed stays, instead of none (an item carries no Projects here).
        let kept = BrowseFilter(query: query, viewer: "you", maxAgeDays: 90, checkouts: nil)
            .apply(to: items, sort: .updated, now: now)
        #expect(kept.count == items.filter { $0.state == .open && $0.repo.org == "acme" }.count)
        #expect(!kept.isEmpty)
        #expect(BrowseScope.project(owner: "acme", number: 7, title: "Board").contains(items[0]))
    }

    private func builder(_ base: BrowseQuery? = nil, off: String? = nil) -> BrowseBuilder {
        BrowseBuilder(
            base: base ?? BrowseQuery(scope: .org("acme"), tokens: [.state(.open)]),
            context: .init(items: items, viewer: "you", maxAgeDays: 90, now: now, wordsOff: off)
        )
    }

    private func type(_ text: String, into builder: inout BrowseBuilder) {
        for character in text {
            _ = builder.handle(KeyStroke(String(character)))
        }
    }

    // MARK: Tokens and the GitHub string

    @Test func everyTokenKindRoundTripsThroughTheGitHubString() {
        let tokens: [BrowseToken] = [
            .type(.pulls), .state(.merged), .label(.any, ["bug", "good first issue"]), .label(.none, ["wontfix"]),
            .repo("acme/docs"), .org("acme"), .assignee("@me"), .author("mara"), .milestone("3.2"), .project("acme/7"),
            .created(.newerThan(30)), .created(.olderThan(7)), .activity(.olderThan(30)), .activity(.newerThan(3)),
            .linkedPull(true), .linkedPull(false), .language("C#"),
            .archived(false), .archived(true), .text("anchors lost"),
        ]
        for token in tokens {
            // One token at a time: a few (labels, two spans of one key) only mean something alone.
            let query = BrowseQuery(tokens: [token], showOlder: true)
            let text = query.rendered(maxAgeDays: 90, now: now)
            let back = BrowseQuery.parse(text, maxAgeDays: 90, now: now)
            #expect(back.tokens == [token], "\(token) rendered \(text) and read back \(back.tokens)")
        }
    }

    @Test func allLabelsRoundTripAsOneToken() {
        let query = BrowseQuery(tokens: [.label(.all, ["bug", "perf"])], showOlder: true)
        let text = query.rendered(maxAgeDays: 90, now: now)
        #expect(BrowseQuery.parse(text, maxAgeDays: 90, now: now).tokens == [.label(.all, ["bug", "perf"])])
    }

    // MARK: Counts and the histogram

    @Test func facetCountsAreOfTheQueryWithoutTheField() {
        var picked = builder(BrowseQuery(scope: .org("acme"), tokens: [.state(.open), .label(.any, ["redirects"])]))
        picked.open(.label)
        let options = picked.picker!.options
        // Counted over the open items of the scope, ignoring the label token being edited.
        #expect(options.first { $0.value == "bug" }?.count == 3)
        #expect(options.first { $0.value == "enhancement" }?.count == 1)
        #expect(options.first?.value == "bug")
    }

    @Test func presetsCountWhatTheyWouldKeep() {
        var picked = builder()
        picked.open(.activity)
        let options = picked.picker!.options
        #expect(options.first { $0.value == "o30" }?.count == 2) // days 40 and 80
        #expect(options.first { $0.value == "n7" }?.count == 2) // days 1 and 5
    }

    @Test func theHistogramHasThirteenBucketsOldestFirstAndMarksWhatMatches() {
        var picked = builder(BrowseQuery(scope: .org("acme"), tokens: [], showOlder: true))
        picked.open(.label)
        _ = picked.handle(KeyStroke("Space")) // ticks bug
        let bars = picked.histogram
        #expect(bars.count == 13)
        #expect(bars.map(\.total).reduce(0, +) == 5)
        #expect(bars.map(\.matching).reduce(0, +) == 3)
        // Days 80 (oldest) land in the first slices, day 1 in the last.
        #expect(bars[12].total == 2 && bars[12].matching == 2) // days 1 and 5, both bugs
        #expect(bars[0].total == 0 || bars[0].total == 1)
    }

    @Test func wouldMatchCountsThePreviewAgainstTheQueryWithoutTheField() {
        var picked = builder(BrowseQuery(scope: .org("acme"), tokens: [.state(.open)]))
        picked.open(.label)
        #expect(picked.wouldMatch.of == 4 || picked.wouldMatch.of == 5)
        let before = picked.wouldMatch.matching
        _ = picked.handle(KeyStroke("Space"))
        #expect(picked.wouldMatch.matching < before || before == picked.wouldMatch.of)
        #expect(picked.raw.contains("label:bug"))
    }

    // MARK: Keys

    @Test func slashFlowPicksAFieldTicksValuesAndAppliesOneToken() {
        var picked = builder()
        type("lab", into: &picked)
        #expect(picked.fields == [.label])
        _ = picked.handle(KeyStroke("CR"))
        #expect(picked.stage == .values(.label))
        _ = picked.handle(KeyStroke("Space")) // bug
        _ = picked.handle(KeyStroke("Down"))
        _ = picked.handle(KeyStroke("Space"))
        _ = picked.handle(KeyStroke("Tab")) // is all of
        #expect(picked.mode == .all)
        let action = picked.handle(KeyStroke("CR"))
        guard case let .apply(query) = action else { Issue.record("not applied: \(action)"); return }
        #expect(query.tokens.contains(.label(.all, ["bug", "docs"])))
        #expect(query.tokens.contains(.state(.open)))
    }

    @Test func aFieldAlreadyInTheQueryOpensWithItsValuesTicked() {
        var picked = builder(BrowseQuery(scope: nil, tokens: [.label(.none, ["bug"])]))
        picked.open(.label)
        #expect(picked.picker?.selected == ["bug"])
        #expect(picked.mode == .none)
    }

    @Test func backspaceOnAnEmptyFieldRemovesTheLastToken() {
        var picked = builder(BrowseQuery(scope: nil, tokens: [.state(.open), .assignee("@me")]))
        let action = picked.handle(KeyStroke("BS"))
        #expect(action == .apply(BrowseQuery(scope: nil, tokens: [.state(.open)])))
    }

    @Test func escapeClosesAndAPickerEscapeGoesBackToTheFields() {
        var picked = builder()
        picked.open(.label)
        #expect(picked.handle(.escape) == .changed)
        #expect(picked.stage == .fields)
        #expect(picked.handle(.escape) == .close)
    }

    @Test func theHeedFieldsOpenAPickerLikeTheOthers() {
        var picked = builder()
        #expect(BrowseField.offered.filter { $0.disabledReason != nil }.isEmpty)
        picked.open(.heedClass)
        #expect(picked.stage == .values(.heedClass))
        #expect(picked.picker?.options.map(\.value) == ["bug", "feature", "docs", "question", "chore"])
        picked.open(.heedSize)
        #expect(picked.picker?.options.map(\.value) == ["S", "M", "L"])
    }

    @Test func copyGivesTheRawQuery() {
        var picked = builder()
        let action = picked.handle(KeyStroke("c", .command))
        #expect(action == .copy("org:acme is:open updated:>=2033-02-17"))
    }

    @Test func theRawFieldParsesWhatItCanAndKeepsTheRest() {
        var picked = builder()
        picked.open(.githubQuery)
        #expect(picked.stage == .raw)
        picked.input.set("is:issue label:bug sort:comments-desc")
        guard case let .apply(query) = picked.handle(KeyStroke("CR")) else { Issue.record("not applied"); return }
        #expect(query.tokens == [.type(.issues), .label(.any, ["bug"]), .raw("sort:comments-desc")])
        #expect(query.scope == .org("acme"))
        #expect(query.showOlder)
    }

    // MARK: Words

    @Test func wordsAskTheModelOnceAndApplyWhatItUnderstood() {
        var picked = builder()
        type("bugs nobody touched", into: &picked)
        #expect(picked.isWords)
        #expect(picked.handle(KeyStroke("CR")) == .read("bugs nobody touched"))
        #expect(picked.reading == .reading)
        picked.setReading(.ready(BrowseUnderstanding(tokens: [.label(.any, ["bug"]), .activity(.olderThan(30))])))
        _ = picked.handle(KeyStroke("Tab"))
        #expect(picked.editing)
        _ = picked.handle(KeyStroke("x")) // drops the label
        #expect(picked.understood == [.activity(.olderThan(30))])
        guard case let .apply(query) = picked.handle(KeyStroke("CR")) else { Issue.record("not applied"); return }
        #expect(query.tokens == [.state(.open), .activity(.olderThan(30))])
    }

    @Test func withTheModelOffWordsSearchAsTextAndTheCardSaysWhy() {
        var picked = builder(off: "model calls are off")
        type("anchors lost", into: &picked)
        guard case let .apply(query) = picked.handle(KeyStroke("CR")) else { Issue.record("not applied"); return }
        #expect(query.tokens.last == .text("anchors lost"))
        #expect(picked.context.wordsOff == "model calls are off")
    }

    @Test func wordsHandedOverFromTheQuickJumpAreReadEvenWhenTheyNameAField() {
        var picked = builder()
        #expect(picked.askWords("labels that rot") == .read("labels that rot"))
        var off = builder(off: "model calls are off")
        guard case let .apply(query) = off.askWords("labels that rot") else { Issue.record("not applied"); return }
        #expect(query.tokens.last == .text("labels that rot"))
    }

    @Test func commandReturnSearchesWordsAsTextWithoutAskingTheModel() {
        var picked = builder()
        type("anchors", into: &picked)
        guard case let .apply(query) = picked.handle(KeyStroke("CR", .command))
        else { Issue.record("not applied"); return }
        #expect(query.tokens.last == .text("anchors"))
    }

    // MARK: Saving

    @Test func saveAsQueryPicksAGlyphThatCanBeChanged() {
        var picked = builder(BrowseQuery(scope: .org("acme"), tokens: [.label(.any, ["bug"])]))
        _ = picked.handle(KeyStroke("s", .command))
        #expect(picked.stage == .save)
        #expect(picked.draft?.glyph == .bug && picked.draft?.name.text == "bug")
        _ = picked.handle(KeyStroke("Tab"))
        _ = picked.handle(KeyStroke("t", .control))
        guard case let .keep(keep) = picked.handle(KeyStroke("CR")) else { Issue.record("not kept"); return }
        #expect(keep.glyph == .sprout && keep.tint != BrowseGlyph.sprout.tint && keep.id == nil)
        #expect(keep.query.tokens == [.label(.any, ["bug"])])
    }

    @Test func renamingOpensTheSaveStepOnTheSavedQuery() {
        let saved = SavedQuery(id: "q1", name: "Old", glyph: .star, query: BrowseQuery(tokens: [.state(.open)]))
        var picked = BrowseBuilder(renaming: saved, context: .init(items: [], now: now))
        picked.draft?.name.set("New")
        guard case let .keep(keep) = picked.handle(KeyStroke("CR")) else { Issue.record("not kept"); return }
        #expect(keep.id == "q1" && keep.name == "New" && keep.glyph == .star)
    }

    @Test func savedQueriesMoveByOnePlaceAndStopAtTheEnds() {
        let list = ["a", "b", "c"].map { SavedQuery(id: $0, name: $0, query: BrowseQuery()) }
        #expect(SavedQuery.moved(list, id: "c", by: -1).map(\.id) == ["a", "c", "b"])
        #expect(SavedQuery.moved(list, id: "a", by: -1).map(\.id) == ["a", "b", "c"])
        #expect(SavedQuery.moved(list, id: "b", by: 5).map(\.id) == ["a", "c", "b"])
    }
}
