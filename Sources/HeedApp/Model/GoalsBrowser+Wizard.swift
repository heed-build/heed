import Foundation
import HeedCore

extension GoalsBrowser {
    /// Shots: a goal part-way through the wizard, laid over the fake world (and into its in-memory store).
    func loadWizardFixture(_ fixture: GoalFixture, wizard state: GoalWizard) {
        var fresh = snapshot
        if fresh.goal(fixture.goal.id) == nil {
            let added = GoalFixtures.snapshot([fixture])
            fresh.goals = (fresh.goals + added.goals).sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
            fresh.docs.merge(added.docs) { _, new in new }
            apply(fresh)
        }
        wizard.set(state)
        guard let ops else { return }
        let load = fixtureLoad
        Task {
            await load?.value
            try? await ops.adopt([fixture])
            try? await ops.adopt(wizards: [state])
        }
    }
}
