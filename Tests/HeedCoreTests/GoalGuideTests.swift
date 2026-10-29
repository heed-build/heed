import Foundation
@testable import HeedCore
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func item(_ id: String, kind: GoalItem.Kind = .work, source: GoalItem.Source = .you) -> GoalItem {
    GoalItem(id: id, goal: "g", title: id, kind: kind, source: source, createdAt: t0)
}

private func edit(_ section: GoalEdit.Section, from: String, state: GoalEdit.State) -> GoalEdit {
    GoalEdit(goal: "g", section: section, op: .add, text: "x", from: from, state: state, at: t0)
}

private let newDoc = GoalDoc(title: "Faster search", goal: "Search is faster")

private let sharpDoc = GoalDoc(
    title: "Faster search",
    goal: "Search answers in under 200 ms for repos with a million files, for everyone on the team.",
    notTheGoal: ["Ranking across languages"],
    doneWhen: [GoalDoc.Criterion("p95 under 200 ms on the big fixture", met: true, evidence: "bench #12")]
)

struct GoalGuideTests {
    @Test func aNewGoalStartsAtSharpen() {
        let guide = GoalGuide.of(.init(doc: newDoc))
        #expect(guide.next?.step == .sharpen)
        #expect(guide.done == 0)
        #expect(guide.shows(hiddenWith: nil))
    }

    @Test func stepsTickOffFromWhatIsTrue() {
        // Sharpening suggestions waiting: the step waits on you, in GOAL.md.
        var input = GoalGuide.Input(doc: newDoc, edits: [edit(.notTheGoal, from: "sharpen", state: .proposed)])
        #expect(GoalGuide.of(input).steps[0].state == .waiting("1 suggestion wait in GOAL.md", command: "goal.doc"))
        #expect(GoalGuide.of(input).next?.step == .sharpen)
        // Answered: done, whatever was said.
        input.edits = [edit(.notTheGoal, from: "sharpen", state: .rejected)]
        #expect(GoalGuide.of(input).steps[0].state == .done("sharpened: 0 of 1 suggestions taken"))
        #expect(GoalGuide.of(input).next?.step == .doneWhen)
        // A sharp GOAL.md written by hand needs no sharpening, and has its criteria.
        input = GoalGuide.Input(doc: sharpDoc)
        #expect(GoalGuide.of(input).next?.step == .work)
        input.items = [item("a", kind: .question)]
        #expect(GoalGuide.of(input).next?.step == .work, "a question is not work")
        input.items.append(item("b"))
        #expect(GoalGuide.of(input).next?.step == .bars)
        input.quality = GoalQuality.fold([QualityRecord(goal: "g", at: t0, entry: .pins([.tests: 8]))], doc: sharpDoc)
        // Mirroring is optional: it is never the next step.
        #expect(GoalGuide.of(input).next?.step == .start)
        input.links = [GoalLink(goal: "g", kind: .session, target: "s1", at: t0)]
        #expect(GoalGuide.of(input).next == nil)
        #expect(!GoalGuide.of(input).shows(hiddenWith: nil))
        #expect(GoalGuide.of(input).steps.first { $0.step == .mirror }?.state == .todo)
    }

    @Test func aSwarmStartsTheWork() {
        let swarm = GoalSwarm(id: "g/swarm-1", goal: "g", number: 1, settings: SwarmSettings(repos: []), startedAt: t0)
        let state = GoalGuide.state(of: .start, .init(doc: sharpDoc, swarms: [swarm]))
        #expect(state == .done("swarm 1 planning"))
    }

    @Test func doneWhenProposalsWait() {
        let input = GoalGuide.Input(
            doc: GoalDoc(title: "t", goal: sharpDoc.goal, notTheGoal: ["x"]),
            edits: [edit(.doneWhen, from: "session", state: .proposed)]
        )
        #expect(GoalGuide.of(input).next?.state == .waiting("1 done-when line wait for your yes", command: "goal.doc"))
    }

    @Test func aHiddenCardComesBackWhenAStepGoesBack() {
        let before = GoalGuide.of(.init(doc: sharpDoc, items: [item("b")]))
        let hidden = before.doneSteps
        #expect(hidden == [.sharpen, .doneWhen, .work])
        #expect(!before.shows(hiddenWith: hidden))
        // More done since: still hidden.
        let more = GoalGuide.of(.init(doc: sharpDoc, items: [item("b")], mirror: GoalMirrorState(on: true)))
        #expect(!more.shows(hiddenWith: hidden))
        // The done-when lines were taken out: it shows again.
        var regressed = sharpDoc
        regressed.doneWhen = []
        #expect(GoalGuide.of(.init(doc: regressed, items: [item("b")])).shows(hiddenWith: hidden))
    }

    @Test func gapsMakeAnUnfinishedDocLookUnfinished() {
        #expect(GoalDocGaps.of(GoalDoc(title: "t")) == [.noStatement, .noNotTheGoal, .noDoneWhen])
        #expect(GoalDocGaps.of(newDoc) == [.thinStatement, .noNotTheGoal, .noDoneWhen])
        #expect(GoalDocGaps.of(sharpDoc).isEmpty)
        #expect(GoalDocGaps.isVague("Search is faster"))
        #expect(GoalDocGaps.isVague("ships soon"), "too short to check")
        #expect(!GoalDocGaps.isVague("Search is faster than 200 ms"))
        #expect(!GoalDocGaps.isVague("the suite runs on each PR"))
        var doc = sharpDoc
        doc.doneWhen.append(GoalDoc.Criterion("it feels better"))
        #expect(GoalDocGaps.of(doc) == [.vagueCriterion(1)])
        #expect(!GoalDocGaps.prompt(.noDoneWhen).isEmpty)
    }

    @Test func progressSaysWhatIsLeft() {
        var doc = sharpDoc
        doc.doneWhen.append(GoalDoc.Criterion("docs page for the new flags"))
        let quality = GoalQuality.fold(
            [QualityRecord(goal: "g", at: t0, entry: .pins([.tests: 8, .docs: 6]))], doc: doc
        )
        let items = [item("a"), item("b"), item("q", kind: .question)]
        let progress = GoalProgress.of(doc: doc, items: items, evidence: [], quality: quality)
        #expect(progress.criteriaMet == 1 && progress.criteria.count == 2)
        #expect(progress.criteria[0].evidence == "bench #12")
        #expect(progress.itemsDone == 0 && progress.itemsTotal == 2)
        #expect(progress.left.first == "docs page for the new flags")
        #expect(progress.left.contains { $0.hasPrefix("tests – under its bar 8") })
        #expect(progress.line.hasPrefix("1/2 criteria · 0/2 items · 0/"))
        #expect(progress.confidence != nil)
        let empty = GoalProgress.of(doc: newDoc, items: [], evidence: [], quality: nil)
        #expect(empty.left == ["No done-when criteria yet: nothing says when it is done"])
        #expect(empty.line == "no criteria")
        #expect(empty.confidence == nil)
    }

    @Test func theFakeSharpenerSuggestsWhatIsMissing() {
        let answer = GoalSharpenFixture.answer(title: "Faster search", doc: newDoc)
        let edits = GoalEditProposer.edits(answer, goal: "g", from: "sharpen", now: t0, scopeOnly: true)
        #expect(edits.map(\.section) == [.goal, .notTheGoal, .doneWhen, .openQuestions])
        #expect(edits.allSatisfy { $0.kind == .scope })
        let sharp = GoalEditProposer.edits(
            GoalSharpenFixture.answer(title: "x", doc: sharpDoc), goal: "g", from: "sharpen", now: t0
        )
        #expect(sharp.map(\.section) == [.openQuestions])
    }

    @Test func paneTabsNameEveryPaneOnce() {
        let all = GoalPaneTabs.tabs(swarm: true, approved: true, counts: .init(proposals: 3))
        #expect(all.map(\.pane) == [
            "overview", "doc", "board", "reviewers", "personas", "evaluations", "plan", "agents", "map", "unassigned",
        ])
        #expect(all[1].count == 3)
        // Every tab's command is one of Goals' pane keys (or the overview), so the strip shows the same keys.
        let panes = Set(DefaultKeys.goalPanes.map(\.1))
        for tab in all where tab.pane != "overview" {
            #expect(panes.contains(tab.command), "\(tab.command)")
        }
        #expect(Set(DefaultKeys.goalPanes.map(\.1)).isSubset(of: Set(all.map(\.command))))
        #expect(!GoalPaneTabs.tabs(swarm: false, approved: false).contains { $0.pane == "plan" })
        #expect(!GoalPaneTabs.tabs(swarm: true, approved: false).contains { $0.pane == "map" })
        #expect(GoalPaneTabs.crumb(goal: "Faster search", pane: "board") == ["Goals", "Faster search", "Board"])
        #expect(GoalPaneTabs.crumb(goal: "Faster search", pane: "overview") == ["Goals", "Faster search"])
        #expect(GoalPaneTabs.crumb(goal: "Faster search", pane: "unassigned") == ["Goals", "Unassigned"])
    }
}
