import Foundation

/// `goal_swarms`, `goal_plans` and `goal_steering`: swarm runs (their settings and state as JSON), plan versions (the
/// tasks as JSON) and steering rows (the row as JSON). Plan versions and steering rows are only inserted.
extension GoalStore {
    private static let swarmEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        return encoder
    }()

    private static let swarmDecoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }()

    private static func encoded(_ value: some Encodable) throws -> SQLiteValue {
        try .text(String(decoding: swarmEncoder.encode(value), as: UTF8.self))
    }

    private static func decoded<T: Decodable>(_ type: T.Type, _ value: SQLiteValue) -> T? {
        value.text.flatMap { try? swarmDecoder.decode(type, from: Data($0.utf8)) }
    }

    // MARK: Runs

    /// Every swarm run, oldest first.
    func swarms() throws -> [GoalSwarm] {
        try database
            .query("SELECT data FROM goal_swarms ORDER BY started_at, id") { Self.decoded(GoalSwarm.self, $0[0]) }
            .compactMap(\.self)
    }

    func swarm(_ id: String) throws -> GoalSwarm? {
        try database.query("SELECT data FROM goal_swarms WHERE id = ?", [.text(id)]) {
            Self.decoded(GoalSwarm.self, $0[0])
        }.first ?? nil
    }

    /// Adds or replaces a run.
    func save(_ swarm: GoalSwarm) throws {
        try database.run("""
        INSERT OR REPLACE INTO goal_swarms (id, goal, status, started_at, ended_at, data) VALUES (?, ?, ?, ?, ?, ?)
        """, [
            .text(swarm.id), .text(swarm.goal), .text(swarm.status.rawValue), SQLiteValue(swarm.startedAt),
            SQLiteValue(swarm.endedAt), Self.encoded(swarm),
        ])
    }

    // MARK: Plan versions

    func add(_ version: SwarmPlanVersion) throws {
        try database.run("""
        INSERT INTO goal_plans (swarm, goal, version, at, author, note, items) VALUES (?, ?, ?, ?, ?, ?, ?)
        """, [
            .text(version.swarm), .text(version.goal), SQLiteValue(version.number), SQLiteValue(version.at),
            .text(version.author.rawValue), .text(version.note), Self.encoded(version.tasks),
        ])
    }

    /// A run's plan versions, newest first.
    func plans(of swarm: String) throws -> [SwarmPlanVersion] {
        try database.query(
            "SELECT swarm, goal, version, at, author, note, items FROM goal_plans WHERE swarm = ? ORDER BY version DESC",
            [.text(swarm)]
        ) { row in
            SwarmPlanVersion(
                swarm: row[0].text ?? "", goal: row[1].text ?? "", number: row[2].int ?? 0,
                at: row[3].date ?? .distantPast,
                author: SwarmPlanVersion.Author(rawValue: row[4].text ?? "") ?? .lead, note: row[5].text ?? "",
                tasks: Self.decoded([SwarmTask].self, row[6]) ?? []
            )
        }
    }

    // MARK: Steering

    /// Adds a steering row; it comes back with its id.
    func add(_ steer: SwarmSteer) throws -> SwarmSteer {
        var stored = steer
        stored.id = nil
        try database.run(
            "INSERT INTO goal_steering (swarm, goal, at, actor, kind, state, data) VALUES (?, ?, ?, ?, ?, ?, ?)",
            [
                .text(steer.swarm), .text(steer.goal), SQLiteValue(steer.at), .text(steer.actor.rawValue),
                .text(steer.kind.rawValue), .text(steer.state.rawValue), Self.encoded(stored),
            ]
        )
        stored.id = database.lastInsertRowID
        return stored
    }

    /// A run's steering rows, oldest first.
    func steering(of swarm: String) throws -> [SwarmSteer] {
        try database.query("SELECT id, data FROM goal_steering WHERE swarm = ? ORDER BY id", [.text(swarm)]) { row in
            Self.decoded(SwarmSteer.self, row[1]).map { steer in
                var steer = steer
                steer.id = row[0].int64
                return steer
            }
        }.compactMap(\.self)
    }
}
