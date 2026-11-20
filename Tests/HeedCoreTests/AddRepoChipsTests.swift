import Foundation
@testable import HeedCore
import Testing

/// The Add or clone chips: how many fit in two rows, the "+N more" rest, and the keys that walk and open them.
struct AddRepoChipsTests {
    private func layout(
        _ widths: [Double], available: Double = 100, rows: Int = 2, selected: Int? = nil, pinned: Set<Int> = [],
        recent: [Int] = [], more: Double = 30
    ) -> AddRepoChips.Result {
        AddRepoChips.layout(
            widths: widths, available: available, maxRows: rows, selected: selected, pinned: pinned, recent: recent,
            spacing: 10, moreWidth: more
        )
    }

    @Test func nothingAndOneChip() {
        #expect(layout([]) == .init(visible: [], overflow: []))
        #expect(layout([40]) == .init(visible: [0], overflow: []))
    }

    @Test func everythingThatFitsShowsWithoutAMoreChip() {
        // 40 + 10 + 40 = 90 on the first row, 40 on the second.
        #expect(layout([40, 40, 40]) == .init(visible: [0, 1, 2], overflow: []))
    }

    @Test func theRestGoesBehindMoreAndKeepsOrder() {
        let result = layout([40, 40, 40, 40, 40, 40], selected: 0)
        // Row one: 0 1. Row two: 2 and the more chip (40 + 10 + 30 = 80).
        #expect(result == .init(visible: [0, 1, 2], overflow: [3, 4, 5]))
    }

    @Test func theSelectedChipIsAlwaysShown() {
        let result = layout([40, 40, 40, 40, 40, 40], selected: 5)
        #expect(result.visible.contains(5))
        #expect(result.visible == result.visible.sorted())
        #expect(result == .init(visible: [0, 1, 5], overflow: [2, 3, 4]))
        for selected in 0 ..< 6 {
            #expect(layout([40, 40, 40, 40, 40, 40], selected: selected).visible.contains(selected))
        }
    }

    @Test func pinnedChipsStayAndVisibleAndOverflowPartitionTheChips() {
        let widths = [30.0, 50, 60, 20, 80, 45, 35, 25]
        for selected in widths.indices {
            let result = layout(widths, selected: selected, pinned: [0, 7])
            #expect(result.visible.contains(0) && result.visible.contains(7) && result.visible.contains(selected))
            #expect((result.visible + result.overflow).sorted() == Array(widths.indices))
            #expect(Set(result.visible).isDisjoint(with: result.overflow))
            #expect(result.visible == result.visible.sorted() && result.overflow == result.overflow.sorted())
        }
    }

    @Test func recentChipsKeepTheirPlaceBeforeTheRest() {
        let plain = layout([40, 40, 40, 40, 40, 40], selected: 0)
        #expect(plain.visible == [0, 1, 2])
        let withRecent = layout([40, 40, 40, 40, 40, 40], selected: 0, recent: [4])
        #expect(withRecent.visible == [0, 1, 4])
    }

    @Test func theGapBetweenChipsCounts() {
        #expect(AddRepoChips.pack([46, 46], available: 100, spacing: 10) == [[0], [1]])
        #expect(AddRepoChips.pack([45, 45], available: 100, spacing: 10) == [[0, 1]])
    }

    @Test func theFirstChipThatDoesNotFitEndsTheList() {
        // 2 is too wide for the second row beside the more chip; 3 is small enough, but skipping 2 would reorder.
        #expect(layout([40, 40, 90, 10], selected: 0) == .init(visible: [0, 1], overflow: [2, 3]))
    }

    @Test func oneVeryWideChipTakesItsOwnRowAndIsNeverSplit() {
        let result = layout([40, 400, 40, 40, 40], selected: 0)
        // The wide one is held to the row width (100): the rows are [0], [1], so only the more chip follows.
        #expect(AddRepoChips.pack([40, 400], available: 100, spacing: 10) == [[0], [1]])
        #expect(result.visible.contains(0))
        let rows = AddRepoChips.pack(
            result.visible.map { [40, 400, 40, 40, 40][$0] } + [30],
            available: 100,
            spacing: 10
        )
        #expect(rows.count <= 2)
    }

    @Test func aSelectedChipThatNeverFitsStillShows() {
        let result = layout([90, 90, 90, 90], rows: 1, selected: 3)
        #expect(result.visible.contains(3))
        #expect(result.overflow.count == 4 - result.visible.count)
    }

    @Test func overflowCountIsWhatDoesNotFit() {
        let result = layout(Array(repeating: 40, count: 20), selected: 0)
        #expect(result.visible.count + result.overflow.count == 20)
        #expect(result.overflow.count == 17)
    }

    @Test func widthsComeFromTheTextAndAreCapped() {
        #expect(AddRepoChips.width(title: "ab", count: nil) < AddRepoChips.width(title: "ab", count: 120))
        #expect(AddRepoChips.width(title: String(repeating: "x", count: 40), count: 5) == AddRepoChips.maxChipWidth)
    }

    // MARK: The form

    private func manyForm(orgs: Int = 16) -> AddRepoForm {
        let names = (0 ..< orgs).map { "org\($0)" }
        var lists: [String: AddRepoForm.ListState] = [:]
        for (index, name) in names.enumerated() {
            lists[name] = .loaded((0 ..< index + 1).map { RepoListing(repo: RepoEntry.repo("\(name)/r\($0)")) })
        }
        return AddRepoForm(orgs: names, records: [], roots: ["~/Projects"], then: .setup, lists: lists)
    }

    @Test func chipsAreYourGitHubThenOrgsByCountThenTheFolder() {
        let form = manyForm(orgs: 4)
        let titles = form.chipOrder.map { form.tabs[$0].title }
        #expect(titles == ["Your GitHub", "org3", "org2", "org1", "org0", "A folder on this Mac"])
    }

    @Test func manyOrgsShowTwoRowsAndAMoreChip() {
        let form = manyForm()
        let layout = form.chipLayout
        #expect(!layout.overflow.isEmpty)
        #expect(form.chipRows.count <= 2)
        #expect(form.chipRows.last?.last == .some(nil))
        let shown = form.chipRows.flatMap { $0.compactMap(\.self) }
        #expect(Set(shown) == Set(layout.visible))
        #expect(shown.contains(0) && shown.contains(form.tabs.count - 1))
    }

    @Test func fewOrgsShowEverythingAsBefore() {
        let form = manyForm(orgs: 3)
        #expect(form.chipLayout.overflow.isEmpty)
        #expect(form.chipRows.flatMap { $0.compactMap(\.self) }.count == form.tabs.count)
        #expect(form.chipRows.allSatisfy { !$0.contains { $0 == nil } })
    }

    @Test func tabWalksEveryChipVisibleOrNotAndTheTabAlwaysShows() {
        var form = manyForm()
        var seen = Set<Int>()
        for _ in form.tabs {
            _ = form.handle(KeyStroke("Tab"))
            seen.insert(form.tab)
            #expect(form.chipLayout.visible.contains(form.tab))
        }
        #expect(seen == Set(form.tabs.indices))
        _ = form.handle(KeyStroke("Tab", .shift))
        #expect(form.chipLayout.visible.contains(form.tab))
    }

    @Test func controlOOpensTheListEscClosesItBeforeTheDialog() {
        var form = manyForm()
        #expect(form.orgMenu == nil)
        #expect(form.handle(KeyStroke("o", .control)) == .none)
        #expect(form.orgMenu != nil)
        #expect(form.menuTabs == form.chipLayout.overflow)
        #expect(form.handle(.escape) == .none)
        #expect(form.orgMenu == nil)
        #expect(form.handle(.escape) == .cancel)
    }

    @Test func controlOWithEveryOrgShownDoesNothing() {
        var form = manyForm(orgs: 2)
        #expect(form.handle(KeyStroke("o", .control)) == .none)
        #expect(form.orgMenu == nil)
    }

    @Test func theListFiltersMovesAndChooses() throws {
        var form = manyForm()
        _ = form.handle(KeyStroke("o", .control))
        let first = form.menuTabs
        _ = form.handle(KeyStroke("0"))
        #expect(form.menuTabs.allSatisfy { form.tabs[$0].title.contains("0") })
        #expect(form.menuTabs.count < first.count)
        _ = form.handle(KeyStroke("BS"))
        _ = form.handle(KeyStroke("Down"))
        let target = try #require(form.menuTabs.dropFirst().first)
        #expect(form.handle(KeyStroke("CR")) == .none)
        #expect(form.orgMenu == nil)
        #expect(form.tab == target)
        #expect(form.chipLayout.visible.contains(target))
        #expect(form.query.isEmpty)
    }

    @Test func tabAndSubmitLeaveTheListInsteadOfTrappingFocus() {
        var form = manyForm()
        _ = form.handle(KeyStroke("o", .control))
        let before = form.tab
        _ = form.handle(KeyStroke("Tab"))
        #expect(form.orgMenu == nil && form.tab != before)
        _ = form.handle(KeyStroke("o", .control))
        #expect(form.handle(KeyStroke("CR", .command)) == .submit)
        #expect(form.orgMenu == nil)
    }

    @Test func aRecentTabKeepsItsChipAfterWalkingAway() {
        var form = manyForm()
        let overflow = form.chipLayout.overflow
        form.select(tab: overflow[0])
        form.select(tab: 0)
        #expect(form.chipLayout.visible.contains(overflow[0]))
    }
}
