import Foundation

/// `[local]`: what heed keeps on this Mac for a local decision model to learn from. Nothing is kept unless
/// `record_screens` is on, and nothing kept here leaves the Mac.
public struct LocalSettings: Equatable, Sendable {
    /// Screen snapshots at each reported state change (`ScreenSnapshot`). Off by default.
    public var recordScreens = false
    /// Snapshots older than this are dropped.
    public var keepDays = 30

    public init(recordScreens: Bool = false, keepDays: Int = 30) {
        self.recordScreens = recordScreens
        self.keepDays = keepDays
    }
}

/// A terminal screen as plain text worth learning from: no escape sequences or control characters, no box drawing,
/// block or spinner glyphs, blank runs collapsed to one line, only the last lines.
public enum ScreenText {
    /// Escape sequences, longest forms first: OSC (title, hyperlinks) ended by BEL or ST, CSI (colors, cursor, erase),
    /// charset selection, then any other two-byte escape.
    private static let escapes = try? NSRegularExpression(
        pattern: #"\x{1B}\][^\x{07}\x{1B}]*(?:\x{07}|\x{1B}\\)?|\x{1B}\[[0-?]*[ -/]*[@-~]|\x{1B}[()*+][0-9A-Za-z]|\x{1B}[ -~]?"#
    )

    /// Spinners and progress marks agent TUIs animate in front of a line (Claude's ✻ ✶ ✳ ✢ ✽, dots, half circles).
    private static let spinners: Set<Unicode.Scalar> = Set("✻✶✳✢✽✺✹✷✸✦✧◐◓◑◒◴◵◶◷".unicodeScalars)

    private static func isGlyph(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        // Box drawing and block elements (borders, bars), braille (spinners).
        case 0x2500 ... 0x259F, 0x2800 ... 0x28FF: true
        default: spinners.contains(scalar)
        }
    }

    /// The cleaned last `lines` lines of `screen`. A line that held only glyphs (a box's border) goes; a blank one
    /// stays, but a run of them is one.
    public static func clean(_ screen: String, lines: Int = 30) -> String {
        var text = screen.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        if let escapes {
            text = escapes.stringByReplacingMatches(
                in: text, range: NSRange(text.startIndex..., in: text), withTemplate: ""
            )
        }
        var kept: [String] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var scalars = String.UnicodeScalarView()
            for scalar in raw.unicodeScalars {
                if scalar == "\t" {
                    scalars.append(" ")
                } else if scalar.value < 0x20 || scalar.value == 0x7F || isGlyph(scalar) {
                    continue
                } else {
                    scalars.append(scalar)
                }
            }
            var line = String(scalars)
            // A middle dot leading a line is a spinner frame; inside one it is a separator.
            if let dot = line.firstIndex(where: { !$0.isWhitespace }), line[dot] == "·" {
                line.remove(at: dot)
            }
            while line.last?.isWhitespace == true {
                line.removeLast()
            }
            let wasBlank = raw.allSatisfy { $0.isWhitespace }
            if line.isEmpty, !wasBlank { continue }
            if line.isEmpty, kept.last?.isEmpty ?? true { continue }
            kept.append(line)
        }
        while kept.last?.isEmpty == true {
            kept.removeLast()
        }
        return kept.suffix(lines).drop { $0.isEmpty }.joined(separator: "\n")
    }
}

/// What an agent's pane showed at a moment worth learning from, with the state heed knew it was in.
public struct ScreenSnapshot: Hashable, Sendable {
    /// Where the state came from, which says whether it is a label.
    public enum Source: String, Sendable, CaseIterable {
        /// The agent's hooks reported a change to `state`.
        case reported
        /// Taken while the hooks said working, now and then: what working looks like.
        case sampled
        /// Read from the screen (`ScreenGuess`) or guessed from a turn's end: not a label.
        case guessed

        public var labelled: Bool { self != .guessed }
    }

    public var at: Date
    public var session: String?
    public var agent: String
    public var state: AgentState
    /// The state before a change; nil for a sample taken while working.
    public var previous: AgentState?
    public var source: Source
    /// The session runs on a host rather than this Mac.
    public var remote: Bool
    /// `ScreenText.clean`'s output.
    public var text: String

    public init(
        at: Date, session: String?, agent: String, state: AgentState, previous: AgentState?, source: Source,
        remote: Bool, text: String
    ) {
        self.at = at
        self.session = session
        self.agent = agent
        self.state = state
        self.previous = previous
        self.source = source
        self.remote = remote
        self.text = text
    }

    /// Lines of the screen kept.
    public static let lines = 30
    /// Past this much text the oldest snapshots go, whatever their age.
    public static let maxBytes = 64 * 1024 * 1024
    /// How long after a reported change the screen is read: a hook can fire before the agent drew what it reports.
    public static let settle: Duration = .seconds(1)

    /// What a change of a session's state is worth keeping as: reported (a label) or guessed; nil when the state did
    /// not change.
    public static func source(from previous: ObservedState, to next: ObservedState) -> Source? {
        guard next.state != previous.state else { return nil }
        return next.source == .reported ? .reported : .guessed
    }
}

/// How often snapshots are taken where they are not tied to a reported change: while working (negatives for the
/// waiting states) and for guessed states (which can flicker as the screen scrolls).
public struct ScreenSampler: Sendable {
    /// At most one sample this often while a session's hooks say working.
    public static let workingEvery: TimeInterval = 180
    /// At most one guessed snapshot this often per session.
    public static let guessedEvery: TimeInterval = 60

    private var workingSince: [String: Date] = [:]
    private var lastGuessed: [String: Date] = [:]

    public init() {}

    /// A reported change: going to working starts the clock (its own snapshot was just taken), anything else stops it.
    public mutating func reported(session: String, state: AgentState, at: Date) {
        workingSince[session] = state == .working ? at : nil
    }

    /// Asked while the session is reported working: true at most once every `workingEvery`. A session found working
    /// without its change seen (working since before heed started) waits a whole interval first.
    public mutating func sampleWorking(session: String, now: Date) -> Bool {
        guard let last = workingSince[session] else {
            workingSince[session] = now
            return false
        }
        guard now.timeIntervalSince(last) >= Self.workingEvery else { return false }
        workingSince[session] = now
        return true
    }

    /// A guessed change: true at most once every `guessedEvery` per session.
    public mutating func takeGuessed(session: String, now: Date) -> Bool {
        if let last = lastGuessed[session], now.timeIntervalSince(last) < Self.guessedEvery { return false }
        lastGuessed[session] = now
        return true
    }

    public mutating func forget(session: String) {
        workingSince[session] = nil
        lastGuessed[session] = nil
    }
}

/// What Settings › Agents › Local decisions shows of the snapshots kept.
public struct ScreenSnapshotCounts: Equatable, Sendable {
    public struct Labelled: Equatable, Sendable, Hashable {
        public var agent: String
        public var state: AgentState
        public var count: Int

        public init(agent: String, state: AgentState, count: Int) {
            self.agent = agent
            self.state = state
            self.count = count
        }
    }

    public struct Day: Equatable, Sendable, Hashable {
        /// The day's start.
        public var day: Date
        public var count: Int

        public init(day: Date, count: Int) {
            self.day = day
            self.count = count
        }
    }

    /// Labelled snapshots per agent and state, by agent then state name.
    public var labelled: [Labelled]
    public var unlabelled: Int
    public var total: Int
    /// The last seven days, oldest first, today last; days with none are there with 0.
    public var days: [Day]
    /// Text kept, in bytes.
    public var bytes: Int

    public init(labelled: [Labelled], unlabelled: Int, total: Int, days: [Day], bytes: Int) {
        self.labelled = labelled
        self.unlabelled = unlabelled
        self.total = total
        self.days = days
        self.bytes = bytes
    }

    /// Seven days, oldest first, ending today.
    public static func lastWeek(now: Date, calendar: Calendar = .current) -> [Date] {
        let today = calendar.startOfDay(for: now)
        return (0 ..< 7).reversed().compactMap { calendar.date(byAdding: .day, value: -$0, to: today) }
    }

    public static func empty(now: Date, calendar: Calendar = .current) -> ScreenSnapshotCounts {
        ScreenSnapshotCounts(
            labelled: [], unlabelled: 0, total: 0,
            days: lastWeek(now: now, calendar: calendar).map { Day(day: $0, count: 0) }, bytes: 0
        )
    }
}

// MARK: - Kept in heed.sqlite

public extension EventLog {
    /// Keeps one snapshot, then drops what is past `keepDays` or the size cap.
    func record(
        _ snapshot: ScreenSnapshot, keepDays: Int, now: Date = Date(), maxBytes: Int = ScreenSnapshot.maxBytes
    ) {
        do {
            try database.run(
                """
                INSERT INTO screens (at, session, agent, state, previous, source, labelled, remote, text, bytes)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                [
                    SQLiteValue(snapshot.at), SQLiteValue(snapshot.session), .text(snapshot.agent),
                    .text(snapshot.state.rawValue), SQLiteValue(snapshot.previous?.rawValue),
                    .text(snapshot.source.rawValue), SQLiteValue(snapshot.source.labelled),
                    SQLiteValue(snapshot.remote),
                    .text(snapshot.text), .integer(Int64(snapshot.text.utf8.count)),
                ]
            )
        } catch {
            NSLog("heed: could not keep a screen snapshot: \(error)")
        }
        pruneScreens(now: now, keepDays: keepDays, maxBytes: maxBytes)
    }

    /// Drops snapshots older than `keepDays`, then the oldest past `maxBytes` of text. Returns how many went.
    @discardableResult
    func pruneScreens(now: Date, keepDays: Int, maxBytes: Int = ScreenSnapshot.maxBytes) -> Int {
        do {
            return try database.transaction {
                try database.run(
                    "DELETE FROM screens WHERE at < ?", [SQLiteValue(now.addingTimeInterval(-Double(keepDays) * 86400))]
                )
                var removed = database.changes
                try database.run(
                    """
                    DELETE FROM screens WHERE id IN (
                        SELECT id FROM (
                            SELECT id, SUM(bytes) OVER (ORDER BY at DESC, id DESC) AS kept FROM screens
                        ) WHERE kept > ?
                    )
                    """,
                    [.integer(Int64(maxBytes))]
                )
                removed += database.changes
                return removed
            }
        } catch {
            NSLog("heed: could not prune screen snapshots: \(error)")
            return 0
        }
    }

    /// Snapshots kept, newest first.
    func screenSnapshots(limit: Int = 100_000) throws -> [ScreenSnapshot] {
        try database.query(
            "SELECT at, session, agent, state, previous, source, remote, text FROM screens ORDER BY at DESC, id DESC "
                + "LIMIT ?",
            [.integer(Int64(limit))]
        ) { row in
            ScreenSnapshot(
                at: row[0].date ?? .distantPast, session: row[1].text, agent: row[2].text ?? "",
                state: AgentState(rawValue: row[3].text ?? "") ?? .idle,
                previous: row[4].text.flatMap(AgentState.init(rawValue:)),
                source: ScreenSnapshot.Source(rawValue: row[5].text ?? "") ?? .guessed, remote: row[6].bool ?? false,
                text: row[7].text ?? ""
            )
        }
    }

    /// What Settings shows: labelled per agent and state, unlabelled, the last seven days, the text's size.
    func screenCounts(now: Date = Date(), calendar: Calendar = .current) throws -> ScreenSnapshotCounts {
        let labelled = try database.query(
            "SELECT agent, state, COUNT(*) FROM screens WHERE labelled = 1 GROUP BY agent, state ORDER BY agent, state"
        ) { row in
            ScreenSnapshotCounts.Labelled(
                agent: row[0].text ?? "", state: AgentState(rawValue: row[1].text ?? "") ?? .idle,
                count: row[2].int ?? 0
            )
        }
        let unlabelled = try database.scalar("SELECT COUNT(*) FROM screens WHERE labelled = 0")?.int ?? 0
        let total = try database.scalar("SELECT COUNT(*) FROM screens")?.int ?? 0
        let bytes = try database.scalar("SELECT COALESCE(SUM(bytes), 0) FROM screens")?.int ?? 0
        let week = ScreenSnapshotCounts.lastWeek(now: now, calendar: calendar)
        var perDay: [Date: Int] = [:]
        for at in try database.query("SELECT at FROM screens WHERE at >= ?", [SQLiteValue(week.first)], row: {
            $0[0].date ?? .distantPast
        }) {
            perDay[calendar.startOfDay(for: at), default: 0] += 1
        }
        return ScreenSnapshotCounts(
            labelled: labelled, unlabelled: unlabelled, total: total,
            days: week.map { ScreenSnapshotCounts.Day(day: $0, count: perDay[$0] ?? 0) }, bytes: bytes
        )
    }

    /// Settings' Delete all.
    func deleteScreens() {
        do {
            try database.run("DELETE FROM screens")
        } catch {
            NSLog("heed: could not delete screen snapshots: \(error)")
        }
    }
}
