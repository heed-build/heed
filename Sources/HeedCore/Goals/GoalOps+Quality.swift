import Foundation

extension GoalLens: CodingKeyRepresentable {}

/// `goal_reviews`: a goal's quality record, one `QualityEntry` per row (its kind in `kind`, the entry as JSON in
/// `data`), never updated, only added to.
public extension GoalStore {
    func addQuality(_ record: QualityRecord) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(record.entry)
        try database.run(
            "INSERT INTO goal_reviews (goal, at, kind, data) VALUES (?, ?, ?, ?)",
            [
                .text(record.goal),
                SQLiteValue(record.at),
                .text(record.entry.kind),
                .text(String(decoding: data, as: UTF8.self)),
            ]
        )
    }

    /// A goal's record, oldest first (rows that no longer decode are skipped).
    func quality(of goal: String) throws -> [QualityRecord] {
        try database.query(
            "SELECT goal, at, data FROM goal_reviews WHERE goal = ? ORDER BY at, id", [.text(goal)]
        ) { row -> QualityRecord? in
            guard let text = row[2].text,
                  let entry = try? JSONDecoder().decode(QualityEntry.self, from: Data(text.utf8))
            else { return nil }
            return QualityRecord(goal: row[0].text ?? goal, at: row[1].date ?? .distantPast, entry: entry)
        }.compactMap(\.self)
    }
}

/// Quality goalposts and reviewers, through the one way goals change. Each operation adds to the record and returns
/// the goal's quality folded again; the goal's score (its ring) follows its confidence.
public extension GoalOps {
    /// A goal's quality now, against `table`.
    func quality(of goal: String, table: GoalBarTable = .defaults) throws -> GoalQuality {
        let doc = try GoalDoc.parse(text(of: goal))
        return try GoalQuality.fold(store.quality(of: goal), doc: doc, table: table)
    }

    /// Every goal's quality, by goal id.
    func qualities(table: GoalBarTable = .defaults) throws -> [String: GoalQuality] {
        var result: [String: GoalQuality] = [:]
        for goal in try store.goals() {
            result[goal.id] = try quality(of: goal.id, table: table)
        }
        return result
    }

    /// Adds entries to a goal's record, then sets its score to its confidence.
    @discardableResult
    func record(
        _ entries: [QualityEntry], goal id: String, at: Date, table: GoalBarTable = .defaults
    ) throws -> GoalQuality {
        guard var goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        for (offset, entry) in entries.enumerated() {
            // Entries recorded together keep their order.
            try store.addQuality(QualityRecord(
                goal: id,
                at: at.addingTimeInterval(Double(offset) * 0.001),
                entry: entry
            ))
        }
        let quality = try quality(of: id, table: table)
        let score = quality.confidence?.value
        if goal.score != score {
            goal.score = score
            try store.update(goal)
        }
        return quality
    }

    /// A profile for the goal's current GOAL.md version: written with what moved from the bars before (raised or
    /// lowered, both apply), and the reviewers its new lenses need. Nil when nothing changed.
    @discardableResult
    func setProfile(
        goal id: String, _ profile: GoalProfile, source: ProfileDecision.Source = .model, now: Date,
        table: GoalBarTable = .defaults
    ) throws -> ProfileDecision? {
        guard let goal = try store.goal(id) else { throw GoalOpError.unknownGoal(id) }
        let before = try quality(of: id, table: table)
        let old = GoalQuality.bars(profile: before.profile, pins: before.pins, table: table)
        let new = profile.bars(table, pins: before.pins)
        if before.profile?.profile == profile, before.profile?.goalVersion == goal.version { return nil }
        let changes = before.profile == nil ? [] : BarChange.between(old, new)
        let decision = ProfileDecision(
            profile: profile, bars: new, changes: changes, note: BarChange.note(profile: profile, changes: changes),
            goalVersion: goal.version, source: source
        )
        var entries: [QualityEntry] = [.profile(decision)]
        entries += ReviewPlanner.missing(bars: new, reviewers: before.reviewers).map {
            .reviewer(ReviewerConfig(id: $0.rawValue, kind: $0))
        }
        try record(entries, goal: id, at: now, table: table)
        return decision
    }

    /// Your bars for the goal: lens → bar, 0 takes the lens off; replaces the pins before.
    @discardableResult
    func pin(goal id: String, _ pins: [GoalLens: Double], now: Date, table: GoalBarTable = .defaults) throws
        -> GoalQuality
    {
        let before = try quality(of: id, table: table)
        let bars = GoalQuality.bars(profile: before.profile, pins: pins, table: table)
        var entries: [QualityEntry] = [.pins(pins)]
        entries += ReviewPlanner.missing(bars: bars, reviewers: before.reviewers).map {
            .reviewer(ReviewerConfig(id: $0.rawValue, kind: $0))
        }
        return try record(entries, goal: id, at: now, table: table)
    }

    /// A new reviewer on the goal (`id` made unique), or a change to one.
    @discardableResult
    func spawn(_ config: ReviewerConfig, goal id: String, now: Date, table: GoalBarTable = .defaults) throws
        -> ReviewerConfig
    {
        let before = try quality(of: id, table: table)
        var config = config
        let taken = Set(before.reviewers.map(\.id))
        if taken.contains(config.id) {
            var number = 2
            while taken.contains("\(config.kind.rawValue)-\(number)") {
                number += 1
            }
            config.id = "\(config.kind.rawValue)-\(number)"
        }
        try record([.reviewer(config)], goal: id, at: now, table: table)
        return config
    }

    /// Accept the risk of an objection, or open it again.
    @discardableResult
    func setObjection(
        goal id: String, reviewer: String, objection: String, _ state: Objection.State, now: Date,
        table: GoalBarTable = .defaults
    ) throws -> GoalQuality {
        let quality = try record(
            [.action(ObjectionAction(reviewer: reviewer, objection: objection, state: state))],
            goal: id, at: now, table: table
        )
        try share(quality, reviewer: nil, goal: id, now: now)
        return quality
    }

    /// A reviewer run started: it counts on the day's budget.
    func runStarted(_ start: ReviewRunStart, goal id: String, now: Date, table: GoalBarTable = .defaults) throws {
        try record([.run(start)], goal: id, at: now, table: table)
    }

    /// A reviewer run ended; its objections are matched to the ones before (by id and words here, `pairs` from a
    /// model).
    @discardableResult
    func reviewEnded(_ result: ReviewResult, goal id: String, now: Date, table: GoalBarTable = .defaults)
        throws -> GoalQuality
    {
        let quality = try record([.review(result)], goal: id, at: now, table: table)
        try share(quality, reviewer: result.report == nil ? nil : result.reviewer, goal: id, now: now)
        return quality
    }

    /// The review in the goal's shared model (`ReviewEvidence`): the reviewer's evidence on the items it looked at,
    /// an item (source reviewer) for each new open HIGH objection, and done evidence on the items of objections that
    /// were fixed or whose risk you accepted.
    private func share(_ quality: GoalQuality, reviewer id: String?, goal: String, now: Date) throws {
        var items = try store.items().filter { $0.goal == goal }
        if let id, let reviewer = quality.reviewer(id) {
            let bar = reviewer.config.kind.lens.flatMap { lens in quality.lenses.first { $0.lens == lens }?.bar }
            for evidence in ReviewEvidence.of(reviewer: reviewer, bar: bar, goal: goal, items: items, at: now) {
                try addEvidence(evidence)
            }
        }
        for (reviewer, objection) in ReviewEvidence.newItems(quality, items: items) {
            let item = try addItem(
                goal: goal, title: objection.text, source: .reviewer, links: [GoalItem.Link(.review, reviewer.id)],
                reason: "\(reviewer.config.title): HIGH " + ReviewEvidence.marker(
                    reviewer: reviewer.id,
                    objection: objection.id
                ),
                now: now
            )
            items.append(item)
            if let lens = reviewer.config.kind.lens, let stage = ReviewEvidence.stage(lens) {
                try addEvidence(GoalEvidence(
                    goal: goal, item: item.id, kind: stage.evidence, state: .issue, at: now,
                    source: reviewer.config.kind.title.lowercased(), text: objection.evidence ?? "HIGH objection",
                    ref: "review:\(reviewer.id)"
                ))
            }
        }
        for (item, objection) in ReviewEvidence.settled(quality, items: items) {
            let reviewer = item.linked(.review).first.flatMap { quality.reviewer($0) }
            let kind = reviewer?.config.kind.lens.flatMap(ReviewEvidence.stage)?.evidence ?? .codeReview
            try addEvidence(GoalEvidence(
                goal: goal, item: item.id, kind: kind, state: .done, at: now,
                source: reviewer?.config.kind.title.lowercased() ?? "reviewer", text: objection.state.text,
                ref: reviewer.map { "review:\($0.id)" }
            ))
        }
    }

    /// Marks the goal done, or undoes that (back to active, and held until what made it done changes).
    func markDone(goal id: String, _ done: Bool, now: Date, table: GoalBarTable = .defaults) throws {
        let quality = try quality(of: id, table: table)
        try record([.done(DoneMark(done: done, basis: quality.doneBasis))], goal: id, at: now, table: table)
        try setStatus(goal: id, done ? .done : .active, now: now)
    }

    /// The HIGH objections still open on a goal, for its items: what the items part turns into work.

    /// Lays down fixture records.
    func adopt(quality records: [QualityRecord]) throws {
        for record in records {
            try store.addQuality(record)
        }
        // Their reviews in the shared model, as a review ending puts them there.
        for goal in Set(records.map(\.goal)).sorted() {
            let quality = try quality(of: goal)
            for reviewer in quality.live where reviewer.lastReviewAt != nil {
                try share(quality, reviewer: reviewer.id, goal: goal, now: reviewer.lastReviewAt ?? Date())
            }
        }
        for goal in Set(records.map(\.goal)) {
            guard var current = try store.goal(goal) else { continue }
            current.score = try quality(of: goal).confidence?.value
            try store.update(current)
        }
    }
}
