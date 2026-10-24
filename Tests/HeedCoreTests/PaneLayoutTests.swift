import Foundation
@testable import HeedCore
import Testing

private func pane(_ id: String) -> PaneSpec { PaneSpec(id: id, role: .shell, title: id, directory: "/") }
private func leaf(_ id: String) -> PaneTree { .leaf(pane(id)) }

/// a | (b / c): a on the left, b above c on the right.
private let nested = PaneTree.split(
    .horizontal, leaf("a"), .split(.vertical, leaf("b"), leaf("c"), ratio: 0.5), ratio: 0.5
)

struct SplitRatioTests {
    @Test func aRatioIsSetAtItsPath() throws {
        let tree = nested.settingRatio(0.3, at: [.second])
        #expect(tree.ratio(at: []) == 0.5)
        #expect(tree.ratio(at: [.second]) == 0.3)
        #expect(tree.panes.map(\.id) == ["a", "b", "c"])
        #expect(nested.settingRatio(0.7, at: []).ratio(at: []) == 0.7)
    }

    @Test func aPathThatIsNoSplitChangesNothing() {
        #expect(nested.settingRatio(0.3, at: [.first]) == nested)
        #expect(nested.settingRatio(0.3, at: [.second, .second, .first]) == nested)
        #expect(nested.ratio(at: [.first]) == nil)
    }

    @Test func aStoredRatioStaysInsideTheBounds() {
        #expect(nested.settingRatio(0, at: []).ratio(at: []) == PaneTree.ratioBounds.lowerBound)
        #expect(nested.settingRatio(1.4, at: []).ratio(at: []) == PaneTree.ratioBounds.upperBound)
        #expect(nested.settingRatio(.nan, at: []).ratio(at: []) == 0.5)
        #expect(nested.settingRatio(.infinity, at: []).ratio(at: []) == 0.5)
    }

    @Test func resetGivesEachPaneAlongTheAxisAnEqualShare() {
        // a | b | c, built by splitting b: a gets a third, not a half.
        let row = PaneTree.split(
            .horizontal,
            leaf("a"),
            .split(.horizontal, leaf("b"), leaf("c"), ratio: 0.8),
            ratio: 0.2
        )
        let reset = row.resettingRatio(at: [])
        #expect(abs((reset.ratio(at: []) ?? 0) - 1.0 / 3) < 1e-9)
        // Only that split: the inner one keeps its ratio.
        #expect(reset.ratio(at: [.second]) == 0.8)
        // Across the axis a stack counts once: a | (b / c) is a half each.
        #expect(nested.settingRatio(0.2, at: []).resettingRatio(at: []).ratio(at: []) == 0.5)
    }

    @Test func equalizingResetsEverySplit() throws {
        let row = PaneTree.split(
            .horizontal,
            leaf("a"),
            .split(.horizontal, leaf("b"), leaf("c"), ratio: 0.8),
            ratio: 0.2
        )
        let equal = row.equalized()
        #expect(abs((equal.ratio(at: []) ?? 0) - 1.0 / 3) < 1e-9)
        #expect(equal.ratio(at: [.second]) == 0.5)
        #expect(equal.panes == row.panes)
    }

    @Test func resizingGrowsTheFocusedPaneOnItsSide() throws {
        // a is the first of the horizontal split: wider moves the divider right.
        let wider = try #require(nested.resizing("a", along: .horizontal, by: 0.1))
        #expect(abs((wider.ratio(at: []) ?? 0) - 0.6) < 1e-9)
        // b is in the second half: growing it moves the divider left.
        let widerB = try #require(nested.resizing("b", along: .horizontal, by: 0.1))
        #expect(abs((widerB.ratio(at: []) ?? 0) - 0.4) < 1e-9)
        // The innermost split of that axis: b taller moves the b / c divider down, the outer one stays.
        let taller = try #require(nested.resizing("b", along: .vertical, by: 0.1))
        #expect(abs((taller.ratio(at: [.second]) ?? 0) - 0.6) < 1e-9)
        #expect(taller.ratio(at: []) == 0.5)
        let shorterC = try #require(nested.resizing("c", along: .vertical, by: -0.1))
        #expect(abs((shorterC.ratio(at: [.second]) ?? 0) - 0.6) < 1e-9)
    }

    @Test func resizingWithNoSplitOnThatAxisIsNil() {
        #expect(nested.resizing("a", along: .vertical, by: 0.1) == nil)
        #expect(leaf("a").resizing("a", along: .horizontal, by: 0.1) == nil)
        #expect(nested.resizing("zz", along: .horizontal, by: 0.1) == nil)
    }

    @Test func resizingStopsAtTheBounds() throws {
        var tree = nested
        for _ in 0 ..< 30 {
            tree = try #require(tree.resizing("a", along: .horizontal, by: 0.1))
        }
        #expect(tree.ratio(at: []) == PaneTree.ratioBounds.upperBound)
    }

    @Test func splittingAndClosingKeepOtherRatios() {
        let tree = nested.settingRatio(0.3, at: []).splitting("b", axis: .horizontal, with: pane("d"))
        #expect(tree.ratio(at: []) == 0.3)
        #expect(tree.ratio(at: [.second, .first]) == 0.5)
        #expect(tree.removing("d")?.ratio(at: []) == 0.3)
    }
}

struct PaneSizingTests {
    let sizing = PaneSizing(minimumWidth: 100, minimumHeight: 80, divider: 1)

    @Test func theFirstPaneGetsItsShareOfTheSpaceBesideTheDivider() {
        #expect(sizing.firstExtent(of: nested, total: 1001) == 500)
        #expect(abs(sizing.firstExtent(of: nested.settingRatio(0.3, at: []), total: 1001) - 300) < 1e-9)
    }

    @Test func noPaneShrinksBelowTheMinimum() {
        #expect(sizing.firstExtent(of: nested.settingRatio(0.05, at: []), total: 1001) == 100)
        #expect(sizing.firstExtent(of: nested.settingRatio(0.95, at: []), total: 1001) == 900)
    }

    @Test func aNestedSplitNeedsRoomForAllItsPanes() {
        // The right of a | (b | c) needs two minimum widths and a divider.
        let row = PaneTree.split(
            .horizontal,
            leaf("a"),
            .split(.horizontal, leaf("b"), leaf("c"), ratio: 0.5),
            ratio: 0.95
        )
        #expect(row.minimumExtent(along: .horizontal, sizing) == 302)
        #expect(PaneTree.split(.horizontal, leaf("b"), leaf("c"), ratio: 0.5)
            .minimumExtent(along: .horizontal, sizing) == 201)
        #expect(row.minimumExtent(along: .vertical, sizing) == 80)
        #expect(nested.minimumExtent(along: .vertical, sizing) == 161)
        #expect(sizing.firstExtent(of: row, total: 1001) == 1000 - 201)
    }

    @Test func tooLittleRoomSharesItByWhatEachSideNeeds() {
        // 100 + 201 do not fit in 150: a gets 100/301 of it.
        let row = PaneTree.split(
            .horizontal,
            leaf("a"),
            .split(.horizontal, leaf("b"), leaf("c"), ratio: 0.5),
            ratio: 0.5
        )
        #expect(abs(sizing.firstExtent(of: row, total: 151) - 150 * 100 / 301) < 1e-9)
    }

    @Test func aDraggedDividerBecomesARatio() {
        #expect(sizing.ratio(forFirstExtent: 250, of: nested, total: 1001) == 0.25)
        // Past the minimum it stops where the pane would be too small.
        #expect(sizing.ratio(forFirstExtent: 20, of: nested, total: 1001) == 0.1)
        #expect(sizing.ratio(forFirstExtent: 990, of: nested, total: 1001) == 0.9)
    }

    @Test func aLeafHasNoSplitToSize() {
        #expect(sizing.firstExtent(of: leaf("a"), total: 500) == 500)
    }
}

struct SplitPersistenceTests {
    /// A layout cached before ratios could change, in the form it was written then.
    let cached = """
    {"split":{"_0":"horizontal","_1":{"leaf":{"_0":{"id":"a","role":"shell","title":"a","directory":"/",\
    "location":{"local":{}}}}},"_2":{"leaf":{"_0":{"id":"b","role":"shell","title":"b","directory":"/",\
    "location":{"local":{}}}}},"ratio":0.5}}
    """

    @Test func cachedLayoutsStillRead() throws {
        let tree = try JSONDecoder().decode(PaneTree.self, from: Data(cached.utf8))
        #expect(tree.panes.map(\.id) == ["a", "b"])
        #expect(tree.ratio(at: []) == 0.5)
    }

    @Test func aSplitWithoutARatioIsEqual() throws {
        let old = cached.replacingOccurrences(of: ",\"ratio\":0.5", with: "")
        #expect(old != cached)
        let tree = try JSONDecoder().decode(PaneTree.self, from: Data(old.utf8))
        #expect(tree.ratio(at: []) == 0.5)
    }

    @Test func aRatioOutOfRangeReadsAsEqual() throws {
        for bad in ["0", "1", "-3", "7.5"] {
            let json = cached.replacingOccurrences(of: "\"ratio\":0.5", with: "\"ratio\":\(bad)")
            let tree = try JSONDecoder().decode(PaneTree.self, from: Data(json.utf8))
            #expect(tree.ratio(at: []) == 0.5, "ratio \(bad)")
        }
    }

    @Test func aDraggedRatioSurvivesTheCache() throws {
        let tree = nested.settingRatio(0.3, at: []).settingRatio(0.7, at: [.second])
        let layout = SessionLayout(tabs: [PaneTab(title: "t", tree: tree)])
        let read = try JSONDecoder().decode(SessionLayout.self, from: JSONEncoder().encode(layout))
        #expect(read == layout)
        #expect(read.tabs[0].tree.ratio(at: [.second]) == 0.7)
    }

    @Test func theCacheIsWrittenAsBefore() throws {
        // Older builds read what this one writes.
        let tree = try JSONDecoder().decode(PaneTree.self, from: Data(cached.utf8))
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        let written = try JSONSerialization.jsonObject(with: encoder.encode(tree)) as? NSDictionary
        let expected = try JSONSerialization.jsonObject(with: Data(cached.utf8)) as? NSDictionary
        #expect(written == expected)
    }
}

struct TabOrderTests {
    private func layout(_ titles: [String], active: Int) -> SessionLayout {
        SessionLayout(tabs: titles.map { PaneTab(id: $0, title: $0, tree: leaf("p" + $0)) }, activeTab: active)
    }

    @Test func movingATabKeepsTheSameTabActive() {
        var tabs = layout(["a", "b", "c", "d"], active: 1)
        tabs.moveTab(from: 0, to: 3)
        #expect(tabs.tabs.map(\.id) == ["b", "c", "d", "a"])
        #expect(tabs.tabs[tabs.activeTab].id == "b")
        tabs.moveTab(from: 0, to: 2)
        #expect(tabs.tabs.map(\.id) == ["c", "d", "b", "a"])
        #expect(tabs.tabs[tabs.activeTab].id == "b")
        tabs.moveTab(from: 3, to: 0)
        #expect(tabs.tabs.map(\.id) == ["a", "c", "d", "b"])
        #expect(tabs.tabs[tabs.activeTab].id == "b")
    }

    @Test func movingOutOfRangeChangesNothing() {
        var tabs = layout(["a", "b"], active: 0)
        tabs.moveTab(from: 0, to: 5)
        #expect(tabs.tabs.map(\.id) == ["a", "b"])
        tabs.moveTab(from: -1, to: 0)
        tabs.moveTab(from: 1, to: 1)
        #expect(tabs.tabs.map(\.id) == ["a", "b"])
    }

    @Test func theActiveTabMovesByCountSteps() {
        var tabs = layout(["a", "b", "c", "d"], active: 1)
        let forward = tabs.moveActiveTab(by: 1)
        #expect(forward)
        #expect(tabs.tabs.map(\.id) == ["a", "c", "b", "d"])
        #expect(tabs.activeTab == 2)
        // A count past the end stops at the end.
        let pastEnd = tabs.moveActiveTab(by: 9)
        #expect(pastEnd)
        #expect(tabs.tabs.map(\.id) == ["a", "c", "d", "b"])
        #expect(tabs.activeTab == 3)
        let atEnd = tabs.moveActiveTab(by: 1)
        #expect(!atEnd)
        let back = tabs.moveActiveTab(by: -3)
        #expect(back)
        #expect(tabs.tabs.map(\.id) == ["b", "a", "c", "d"])
        let atStart = tabs.moveActiveTab(by: -1)
        #expect(!atStart)
    }
}

struct TabDragTests {
    let widths: [Double] = [100, 60, 80, 120]

    @Test func aSmallDragStaysPut() {
        #expect(TabDrag.target(dragging: 1, by: 5, widths: widths) == 1)
        #expect(TabDrag.target(dragging: 1, by: -20, widths: widths) == 1)
    }

    @Test func pastANeighboursMiddleItTakesItsPlace() {
        // Tab 1 (60 wide, centre 130) past tab 2's middle (centre 200 once tab 1 is out: 100 + 40 = 140): 11 points.
        #expect(TabDrag.target(dragging: 1, by: 11, widths: widths) == 2)
        #expect(TabDrag.target(dragging: 1, by: 9, widths: widths) == 1)
        #expect(TabDrag.target(dragging: 1, by: -81, widths: widths) == 0)
        #expect(TabDrag.target(dragging: 0, by: 1000, widths: widths) == 3)
        #expect(TabDrag.target(dragging: 3, by: -1000, widths: widths) == 0)
    }

    @Test func theOthersMakeRoomByTheDraggedTabsWidth() {
        // Tab 0 dragged to 2: tabs 1 and 2 slide left by its width.
        #expect(TabDrag.shift(of: 1, dragging: 0, to: 2, widths: widths) == -100)
        #expect(TabDrag.shift(of: 2, dragging: 0, to: 2, widths: widths) == -100)
        #expect(TabDrag.shift(of: 3, dragging: 0, to: 2, widths: widths) == 0)
        // Tab 3 dragged to 1: tabs 1 and 2 slide right.
        #expect(TabDrag.shift(of: 0, dragging: 3, to: 1, widths: widths) == 0)
        #expect(TabDrag.shift(of: 1, dragging: 3, to: 1, widths: widths) == 120)
        #expect(TabDrag.shift(of: 2, dragging: 3, to: 1, widths: widths) == 120)
        #expect(TabDrag.shift(of: 3, dragging: 3, to: 1, widths: widths) == 0)
    }
}

struct FrameThrottleTests {
    @Test func atMostOneUpdateAFrame() {
        var throttle = FrameThrottle(interval: 1.0 / 60)
        let admitted = [0, 0.005, 0.017, 0.02].map { throttle.admit(at: $0) }
        #expect(admitted == [true, false, true, false])
        #expect(throttle.wait(at: 0.021) > 0.012)
        throttle.reset()
        let afterReset = throttle.admit(at: 0.021)
        #expect(afterReset)
        #expect(throttle.wait(at: 0.05) == 0)
    }
}

struct PaneKeysTests {
    @Test func sizesAndTabMovesHaveVimKeys() throws {
        let built = Keymaps.build()
        #expect(built.problems.isEmpty)
        let normal = try #require(built.keymaps[.normal])
        let expected = [
            ("<C-w>>", "pane.wider"), ("<C-w><lt>", "pane.narrower"), ("<C-w>+", "pane.taller"),
            ("<C-w>-", "pane.shorter"), ("<C-w>=", "pane.equalize"), ("g>", "tab.move.right"),
            ("g<lt>", "tab.move.left"),
        ]
        for (keys, command) in expected {
            #expect(try normal.lookup(KeyNotation.parse(keys)) == .command(command), "\(keys)")
        }
        // The keys around them still do what they did.
        #expect(try normal.lookup(KeyNotation.parse("<C-w>v")) == .command("pane.split.right"))
        #expect(try normal.lookup(KeyNotation.parse("gt")) == .command("tab.next"))
    }
}
