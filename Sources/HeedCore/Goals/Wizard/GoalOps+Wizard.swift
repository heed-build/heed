import Foundation

extension GoalStore {
    /// Every goal's wizard, by goal id; goals that never went through it are left out.
    func wizards() throws -> [String: GoalWizard] {
        let rows = try database.query("SELECT goal, data FROM goal_wizards") { row in
            (row[0].text ?? "", Self.decode(GoalWizard.self, row[1]))
        }
        return Dictionary(rows.compactMap { goal, wizard in wizard.map { (goal, $0) } }) { _, last in last }
    }

    func save(wizard: GoalWizard) throws {
        try database.run(
            "INSERT OR REPLACE INTO goal_wizards (goal, data) VALUES (?, ?)", [.text(wizard.goal), Self.json(wizard)]
        )
    }
}

/// The wizard's state, kept per goal: read, started, saved after every change.
public extension GoalOps {
    func wizards() throws -> [String: GoalWizard] { try store.wizards() }

    func wizard(of goal: String) throws -> GoalWizard? { try store.wizards()[goal] }

    /// The goal's wizard, made at step 1 when it has none.
    @discardableResult
    func startWizard(goal: String, now: Date) throws -> GoalWizard {
        guard try store.goal(goal) != nil else { throw GoalOpError.unknownGoal(goal) }
        if let existing = try store.wizards()[goal] { return existing }
        let wizard = GoalWizard(goal: goal, at: now)
        try store.save(wizard: wizard)
        return wizard
    }

    func save(wizard: GoalWizard) throws {
        guard try store.goal(wizard.goal) != nil else { throw GoalOpError.unknownGoal(wizard.goal) }
        try store.save(wizard: wizard)
    }

    /// Fixtures: wizards laid into the in-memory store.
    func adopt(wizards: [GoalWizard]) throws {
        for wizard in wizards {
            try store.save(wizard: wizard)
        }
    }
}
