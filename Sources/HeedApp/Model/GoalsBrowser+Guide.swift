import Foundation
import HeedCore

/// The guided first steps (`GoalGuide`) and how far each goal is (`GoalProgress`), read from the snapshot; and which
/// goals' cards were hidden, with what was done when they were (kept in UserDefaults, never by fixtures).
extension GoalsBrowser {
    static let hiddenGuidesKey = "heed.goalGuidesHidden"

    func guide(of goal: HeedGoal) -> GoalGuide {
        GoalGuide.of(GoalGuide.Input(
            doc: snapshot.docs[goal.id], edits: snapshot.edits.filter { $0.goal == goal.id },
            items: snapshot.items(of: goal.id), links: snapshot.links(of: goal.id), quality: qualities[goal.id],
            mirror: mirror(of: goal.id), swarms: snapshot.swarms(of: goal.id)
        ))
    }

    func progress(of goal: HeedGoal) -> GoalProgress {
        GoalProgress.of(
            doc: snapshot.docs[goal.id], items: snapshot.items(of: goal.id), evidence: snapshot.evidence(of: goal.id),
            quality: qualities[goal.id]
        )
    }

    /// The goal's next step when its card shows (not hidden, or a step went back since); nil otherwise.
    func shownGuide(of goal: HeedGoal) -> GoalGuide? {
        guard goal.status == .active else { return nil }
        let guide = guide(of: goal)
        return guide.shows(hiddenWith: hiddenGuides[goal.id]) ? guide : nil
    }

    /// `goal.guide`: hides the card (remembering what was done), or shows it again.
    func toggleGuide(_ goal: HeedGoal) -> Bool {
        let guide = guide(of: goal)
        if guide.shows(hiddenWith: hiddenGuides[goal.id]) {
            hiddenGuides[goal.id] = guide.doneSteps
            return false
        }
        hiddenGuides[goal.id] = nil
        return true
    }

    static func loadHiddenGuides() -> [String: Set<GoalStep>] {
        let stored = UserDefaults.standard.dictionary(forKey: hiddenGuidesKey) as? [String: [String]] ?? [:]
        return stored.mapValues { Set($0.compactMap(GoalStep.init(rawValue:))) }
    }

    static func saveHiddenGuides(_ hidden: [String: Set<GoalStep>]) {
        UserDefaults.standard.set(hidden.mapValues { $0.map(\.rawValue).sorted() }, forKey: hiddenGuidesKey)
    }

    /// The tab strip's counts for the selected goal: what waits on each pane.
    func tabCounts(needsYou: Int) -> GoalPaneTabs.Counts {
        GoalPaneTabs.Counts(
            proposals: proposals.count,
            objections: reviewers.reduce(0) { $0 + $1.objections.count { $0.state == .open } },
            gaps: personaRows.count { $0.coverage.state == .gap },
            questions: board?.openQuestions.count ?? 0,
            needsYou: needsYou,
            asks: attach.asks.count
        )
    }
}
