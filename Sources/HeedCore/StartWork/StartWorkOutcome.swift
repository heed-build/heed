import Foundation

/// What Start work guessed for a prompt and what you started with: labels for a local model to learn better guesses
/// from later. Kept in heed.sqlite on this Mac only, for `[local] keep_days`; never sent anywhere.
public struct StartWorkOutcome: Hashable, Sendable {
    public var at: Date
    public var prompt: String
    /// The repo Start work selected by itself; nil when it selected none.
    public var guessedRepo: String?
    /// The branch name it filled in.
    public var guessedName: String
    /// The on-device model's advice was part of the guess.
    public var advised: Bool
    /// The repos you started in (record ids), the primary first.
    public var repos: [String]
    public var name: String
    /// Nil for a shell only.
    public var agent: String?
    public var planFirst: Bool

    public init(
        at: Date, prompt: String, guessedRepo: String?, guessedName: String, advised: Bool, repos: [String],
        name: String, agent: String?, planFirst: Bool
    ) {
        self.at = at
        self.prompt = prompt
        self.guessedRepo = guessedRepo
        self.guessedName = guessedName
        self.advised = advised
        self.repos = repos
        self.name = name
        self.agent = agent
        self.planFirst = planFirst
    }

    /// The prefix of a branch name: `fix` of `fix/crash`; nil without one.
    public static func prefix(of name: String) -> String? {
        guard let slash = name.firstIndex(of: "/"), slash != name.startIndex else { return nil }
        return String(name[..<slash])
    }

    public var guessedPrefix: String? { Self.prefix(of: guessedName) }
    public var prefix: String? { Self.prefix(of: name) }
}

// MARK: - Kept in heed.sqlite

public extension EventLog {
    /// Keeps one outcome, then drops those older than `keepDays`.
    func record(_ outcome: StartWorkOutcome, keepDays: Int) {
        do {
            try database.run(
                """
                INSERT INTO start_outcomes (at, prompt, guessed_repo, guessed_name, guessed_prefix, advised, repos, name,
                    prefix, agent, plan_first)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    SQLiteValue(outcome.at), .text(outcome.prompt), SQLiteValue(outcome.guessedRepo),
                    .text(outcome.guessedName), SQLiteValue(outcome.guessedPrefix), SQLiteValue(outcome.advised),
                    .text(outcome.repos.joined(separator: "\n")), .text(outcome.name), SQLiteValue(outcome.prefix),
                    SQLiteValue(outcome.agent), SQLiteValue(outcome.planFirst),
                ]
            )
        } catch {
            NSLog("heed: could not keep a Start work outcome: \(error)")
        }
        pruneStartOutcomes(now: outcome.at, keepDays: keepDays)
    }

    /// Drops outcomes older than `keepDays`. Returns how many went.
    @discardableResult
    func pruneStartOutcomes(now: Date, keepDays: Int) -> Int {
        do {
            try database.run(
                "DELETE FROM start_outcomes WHERE at < ?",
                [SQLiteValue(now.addingTimeInterval(-Double(keepDays) * 86400))]
            )
            return database.changes
        } catch {
            NSLog("heed: could not prune Start work outcomes: \(error)")
            return 0
        }
    }

    /// Outcomes kept, newest first.
    func startOutcomes(limit: Int = 100_000) throws -> [StartWorkOutcome] {
        try database.query(
            """
            SELECT at, prompt, guessed_repo, guessed_name, advised, repos, name, agent, plan_first FROM start_outcomes
            ORDER BY at DESC, id DESC LIMIT ?
            """,
            [.integer(Int64(limit))]
        ) { row in
            StartWorkOutcome(
                at: row[0].date ?? .distantPast, prompt: row[1].text ?? "", guessedRepo: row[2].text,
                guessedName: row[3].text ?? "", advised: row[4].bool ?? false,
                repos: (row[5].text ?? "").split(separator: "\n").map(String.init), name: row[6].text ?? "",
                agent: row[7].text, planFirst: row[8].bool ?? false
            )
        }
    }

    /// Settings' Delete all in Local decisions.
    func deleteStartOutcomes() {
        do {
            try database.run("DELETE FROM start_outcomes")
        } catch {
            NSLog("heed: could not delete Start work outcomes: \(error)")
        }
    }

    /// How many are kept, for Settings.
    func startOutcomeCount() throws -> Int {
        try database.scalar("SELECT COUNT(*) FROM start_outcomes")?.int ?? 0
    }
}
