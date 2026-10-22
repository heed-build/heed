import Foundation
import Synchronization

/// What kind of call a row is: a command heed ran, a GitHub call (through gh, logged instead of its shell row), a
/// cheap-model run, a decision.
public struct CallKind: RawRepresentable, Hashable, Sendable, Codable, CustomStringConvertible {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public var description: String { rawValue }

    public static let shell = CallKind(rawValue: "shell")
    public static let github = CallKind(rawValue: "github")
    public static let llm = CallKind(rawValue: "llm")
    public static let decide = CallKind(rawValue: "decide")

    public static let all: [CallKind] = [.shell, .github, .llm, .decide]
}

/// One row of the call log. Never holds environment variables; stdout is kept only when the call failed.
public struct LoggedCall: Hashable, Sendable, Identifiable {
    /// Its row in the log; 0 until it is written.
    public var id: Int64 = 0
    public var at: Date
    public var kind: CallKind
    /// Which part of heed made it (`git.status`, `github.sync`).
    public var caller: String
    /// The host it ran on; nil for this Mac.
    public var host: String?
    /// What ran, as it could be typed again (for a host: the command on the host, not the ssh line).
    public var command: String
    public var cwd: String?
    public var duration: TimeInterval
    /// Nil when it never started, or has not ended (a stream that started).
    public var exitCode: Int?
    public var failed: Bool
    public var stdout: String?
    public var stderr: String?
    /// github: `graphql pullSearch`, `GET notifications`, `pr merge`. llm and decide: what was asked for.
    public var operation: String?
    /// github: whether it changed something on GitHub.
    public var write: Bool
    public var items: Int?
    /// github: entries SAML withheld.
    public var hidden: Int?
    public var rateCost: Int?
    public var rateRemaining: Int?
    public var agent: String?
    public var model: String?
    public var tokens: TokenCounts?
    public var cost: Double?
    /// The cost is an estimate from `[usage.prices]`, not what the agent reported.
    public var costEstimated: Bool
    /// Anything else: GraphQL variables, a prompt and response, why other agents were skipped.
    public var detail: [String: String]

    public init(
        at: Date, kind: CallKind, caller: String, host: String? = nil, command: String, cwd: String? = nil,
        duration: TimeInterval, exitCode: Int? = nil, failed: Bool = false, stdout: String? = nil,
        stderr: String? = nil, operation: String? = nil, write: Bool = false, items: Int? = nil, hidden: Int? = nil,
        rateCost: Int? = nil, rateRemaining: Int? = nil, agent: String? = nil, model: String? = nil,
        tokens: TokenCounts? = nil, cost: Double? = nil, costEstimated: Bool = false, detail: [String: String] = [:]
    ) {
        self.at = at
        self.kind = kind
        self.caller = caller
        self.host = host
        self.command = command
        self.cwd = cwd
        self.duration = duration
        self.exitCode = exitCode
        self.failed = failed
        self.stdout = stdout
        self.stderr = stderr
        self.operation = operation
        self.write = write
        self.items = items
        self.hidden = hidden
        self.rateCost = rateCost
        self.rateRemaining = rateRemaining
        self.agent = agent
        self.model = model
        self.tokens = tokens
        self.cost = cost
        self.costEstimated = costEstimated
        self.detail = detail
    }

    /// Output past this is cut (from the middle: the start says what it was, the end how it ended).
    public static let outputLimit = 16 * 1024

    static func truncated(_ text: String?) -> String? {
        guard let text, !text.isEmpty else { return nil }
        guard text.utf8.count > outputLimit else { return text }
        let half = outputLimit / 2
        let bytes = Array(text.utf8)
        let head = String(decoding: bytes.prefix(half), as: UTF8.self)
        let tail = String(decoding: bytes.suffix(half), as: UTF8.self)
        return "\(head)\n… \(bytes.count - outputLimit) bytes cut …\n\(tail)"
    }

    /// A command's row: stderr always, stdout only when it failed, both truncated. Output of anything that prints a
    /// credential (`gh auth token`; heed never runs it) is never kept.
    public static func shell(
        at: Date, caller: String, host: String? = nil, executable: String, arguments: [String], cwd: String? = nil,
        duration: TimeInterval, result: ProcessResult?, error: String? = nil
    ) -> LoggedCall {
        let command = ([executable] + arguments).map(ShellQuote.quote).joined(separator: " ")
        let failed = result.map { !$0.succeeded } ?? true
        let secret = printsSecret(executable: executable, arguments: arguments)
        return LoggedCall(
            at: at, kind: .shell, caller: caller, host: host, command: command, cwd: cwd, duration: duration,
            exitCode: result.map { Int($0.status) }, failed: failed,
            stdout: failed && !secret ? truncated(result?.stdout) : nil,
            stderr: secret ? nil : truncated(error ?? result?.stderr)
        )
    }

    /// `gh auth token` (and `gh auth status -t`) print the token.
    static func printsSecret(executable: String, arguments: [String]) -> Bool {
        let name = (executable as NSString).lastPathComponent
        guard name == "gh", arguments.first == "auth" else { return false }
        return arguments.contains("token") || arguments.contains("-t") || arguments.contains("--show-token")
    }
}

/// How long the call log keeps each kind (`[log]` in config.toml), and how many rows at most. Pruned hourly.
public struct CallRetention: Equatable, Sendable {
    public var shellDays = 7
    public var githubReadDays = 3
    public var githubWriteDays = 90
    public var llmDays = 30
    public var decideDays = 30
    /// Rows kept per kind at most, newest first, whatever their age.
    public var maxRows = 50000

    public init() {}

    func days(_ kind: CallKind, write: Bool) -> Int {
        switch kind {
        case .shell: shellDays
        case .github: write ? githubWriteDays : githubReadDays
        case .llm: llmDays
        case .decide: decideDays
        default: shellDays
        }
    }
}

/// What the `:log` view asks for.
public struct CallFilter: Equatable, Sendable {
    public var kinds: Set<CallKind> = []
    public var caller: String?
    public var agent: String?
    public var failedOnly = false
    public var slowOnly = false
    public var githubWritesOnly = false
    /// `/`: matched against the command, caller, operation, host and stderr.
    public var search = ""
    /// Only calls from this time on.
    public var since: Date?
    public var limit = 500

    /// A call this long or longer is slow.
    public static let slow: TimeInterval = 5

    public init() {}
}

/// `log.sqlite`: the call log, apart from `heed.sqlite` so pruning it never touches history. One actor owns the
/// connection.
public actor CallStore {
    private let database: SQLiteDatabase

    public init(path: String) throws {
        database = try SQLiteDatabase(path: path)
        try database.migrate(Self.schema)
    }

    static let schema = [
        SQLiteMigration(sql: """
        CREATE TABLE calls (
            id INTEGER PRIMARY KEY,
            at REAL NOT NULL,
            kind TEXT NOT NULL,
            caller TEXT NOT NULL,
            host TEXT,
            command TEXT NOT NULL,
            cwd TEXT,
            duration REAL NOT NULL,
            exit_code INTEGER,
            failed INTEGER NOT NULL DEFAULT 0,
            stdout TEXT,
            stderr TEXT,
            operation TEXT,
            write INTEGER NOT NULL DEFAULT 0,
            items INTEGER,
            hidden INTEGER,
            rate_cost INTEGER,
            rate_remaining INTEGER,
            agent TEXT,
            model TEXT,
            tokens TEXT,
            cost REAL,
            cost_estimated INTEGER NOT NULL DEFAULT 0,
            detail TEXT
        );
        CREATE INDEX calls_at ON calls (at);
        CREATE INDEX calls_kind ON calls (kind, write, at);
        """),
    ]

    public func insert(_ calls: [LoggedCall]) {
        guard !calls.isEmpty else { return }
        do {
            try database.transaction {
                let insert = try database.prepare("""
                INSERT INTO calls (at, kind, caller, host, command, cwd, duration, exit_code, failed, stdout, stderr,
                    operation, write, items, hidden, rate_cost, rate_remaining, agent, model, tokens, cost,
                    cost_estimated, detail)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """)
                for call in calls {
                    try insert.bind(Self.values(call))
                    try insert.run()
                }
            }
        } catch {
            NSLog("heed: could not write the call log: \(error)")
        }
    }

    private static func json(_ value: some Encodable) -> String? {
        (try? JSONEncoder.heed.encode(value)).map { String(decoding: $0, as: UTF8.self) }
    }

    private static func values(_ call: LoggedCall) -> [SQLiteValue] {
        [
            SQLiteValue(call.at), .text(call.kind.rawValue), .text(call.caller), SQLiteValue(call.host),
            .text(call.command), SQLiteValue(call.cwd), .real(call.duration), SQLiteValue(call.exitCode),
            SQLiteValue(call.failed), SQLiteValue(call.stdout), SQLiteValue(call.stderr), SQLiteValue(call.operation),
            SQLiteValue(call.write), SQLiteValue(call.items), SQLiteValue(call.hidden), SQLiteValue(call.rateCost),
            SQLiteValue(call.rateRemaining), SQLiteValue(call.agent), SQLiteValue(call.model),
            SQLiteValue(call.tokens.flatMap(json)), SQLiteValue(call.cost), SQLiteValue(call.costEstimated),
            SQLiteValue(call.detail.isEmpty ? nil : json(call.detail)),
        ]
    }

    /// Drops what is past its kind's age, then the oldest rows of a kind past `maxRows`. Returns how many went.
    @discardableResult
    public func prune(now: Date, retention: CallRetention) -> Int {
        var removed = 0
        do {
            try database.transaction {
                for kind in CallKind.all {
                    for write in kind == .github ? [false, true] : [false] {
                        let cutoff = now.addingTimeInterval(-Double(retention.days(kind, write: write)) * 86400)
                        try database.run(
                            "DELETE FROM calls WHERE kind = ? AND (? = 0 OR write = ?) AND at < ?",
                            [
                                .text(kind.rawValue),
                                SQLiteValue(kind == .github),
                                SQLiteValue(write),
                                SQLiteValue(cutoff),
                            ]
                        )
                        removed += database.changes
                    }
                    try database.run(
                        """
                        DELETE FROM calls WHERE kind = ? AND id NOT IN (
                            SELECT id FROM calls WHERE kind = ? ORDER BY at DESC, id DESC LIMIT ?
                        )
                        """,
                        [.text(kind.rawValue), .text(kind.rawValue), .integer(Int64(retention.maxRows))]
                    )
                    removed += database.changes
                }
            }
        } catch {
            NSLog("heed: could not prune the call log: \(error)")
        }
        return removed
    }

    /// Newest first.
    public func calls(_ filter: CallFilter = CallFilter()) throws -> [LoggedCall] {
        var clauses: [String] = []
        var values: [SQLiteValue] = []
        if !filter.kinds.isEmpty {
            clauses.append("kind IN (\(filter.kinds.map { _ in "?" }.joined(separator: ", ")))")
            values += filter.kinds.sorted { $0.rawValue < $1.rawValue }.map { .text($0.rawValue) }
        }
        if let caller = filter.caller {
            clauses.append("caller = ?")
            values.append(.text(caller))
        }
        if let agent = filter.agent {
            clauses.append("agent = ?")
            values.append(.text(agent))
        }
        if filter.failedOnly { clauses.append("failed = 1") }
        if filter.slowOnly {
            clauses.append("duration >= ?")
            values.append(.real(CallFilter.slow))
        }
        if filter.githubWritesOnly { clauses.append("kind = 'github' AND write = 1") }
        if let since = filter.since {
            clauses.append("at >= ?")
            values.append(SQLiteValue(since))
        }
        let search = filter.search.trimmingCharacters(in: .whitespaces)
        if !search.isEmpty {
            let pattern = "%" + search.replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_") + "%"
            clauses.append(
                "(" + ["command", "caller", "operation", "host", "stderr", "agent"]
                    .map { "\($0) LIKE ? ESCAPE '\\'" }.joined(separator: " OR ") + ")"
            )
            values += Array(repeating: .text(pattern), count: 6)
        }
        var sql = "SELECT id, at, kind, caller, host, command, cwd, duration, exit_code, failed, stdout, stderr, operation, "
            + "write, items, hidden, rate_cost, rate_remaining, agent, model, tokens, cost, cost_estimated, detail "
            + "FROM calls"
        if !clauses.isEmpty { sql += " WHERE " + clauses.joined(separator: " AND ") }
        sql += " ORDER BY at DESC, id DESC LIMIT ?"
        values.append(.integer(Int64(filter.limit)))
        return try database.query(sql, values) { row in
            var call = LoggedCall(
                at: row[1].date ?? .distantPast, kind: CallKind(rawValue: row[2].text ?? ""),
                caller: row[3].text ?? "", host: row[4].text, command: row[5].text ?? "", cwd: row[6].text,
                duration: row[7].double ?? 0, exitCode: row[8].int, failed: row[9].bool ?? false,
                stdout: row[10].text, stderr: row[11].text, operation: row[12].text, write: row[13].bool ?? false,
                items: row[14].int, hidden: row[15].int, rateCost: row[16].int, rateRemaining: row[17].int,
                agent: row[18].text, model: row[19].text,
                tokens: row[20].data.flatMap { try? JSONDecoder.heed.decode(TokenCounts.self, from: $0) },
                cost: row[21].double, costEstimated: row[22].bool ?? false,
                detail: row[23].data.flatMap { try? JSONDecoder.heed.decode([String: String].self, from: $0) } ?? [:]
            )
            call.id = row[0].int64 ?? 0
            return call
        }
    }

    /// LLM calls per agent since `since` (today, for the view's strip), and the GitHub rate limit as last seen.
    public func usage(since: Date) throws -> CallUsage {
        var llm = CallFilter()
        llm.kinds = [.llm]
        llm.since = since
        llm.limit = 100_000
        let rate = try database.query(
            "SELECT rate_remaining, at FROM calls WHERE rate_remaining IS NOT NULL ORDER BY at DESC, id DESC LIMIT 1"
        ) { ($0[0].int, $0[1].date) }.first
        return try CallUsage(llm: calls(llm), rateRemaining: rate?.0, rateAt: rate?.1)
    }

    /// Rows per kind, for the measurements and the view's counts.
    public func counts() throws -> [CallKind: Int] {
        let rows = try database.query("SELECT kind, count(*) FROM calls GROUP BY kind") {
            (CallKind(rawValue: $0[0].text ?? ""), $0[1].int ?? 0)
        }
        return Dictionary(rows) { first, _ in first }
    }
}

/// Where calls are recorded: `record` is cheap and never waits (a lock and an append); rows reach `log.sqlite` in
/// batches, a moment later. The app installs one (`install`); tests use their own with `$current`.
public final class CallLog: Sendable {
    public let store: CallStore
    private let pending = Mutex<(calls: [LoggedCall], scheduled: Bool)>(([], false))
    private let delay: Duration

    public init(store: CallStore, delay: Duration = .milliseconds(250)) {
        self.store = store
        self.delay = delay
    }

    /// Opens `log.sqlite` off the main actor; nil (logged) when it cannot be opened, and nothing is logged.
    public static func open(at file: URL) async -> CallLog? {
        await Task.detached(priority: .utility) {
            do {
                return try CallLog(store: CallStore(path: file.path))
            } catch {
                NSLog("heed: could not open \(file.path) (\(error)); calls are not logged")
                return nil
            }
        }.value
    }

    private static let installed = Mutex<CallLog?>(nil)
    @TaskLocal public static var current: CallLog?

    /// The log every call is recorded in from now on.
    public static func install(_ log: CallLog?) { installed.withLock { $0 = log } }

    /// The log in effect: the task's own (tests), else the installed one.
    public static var active: CallLog? { current ?? installed.withLock { $0 } }

    /// Records a call in the active log, if there is one.
    public static func record(_ call: LoggedCall) { active?.record(call) }

    public func record(_ call: LoggedCall) {
        let schedule = pending.withLock { state in
            state.calls.append(call)
            defer { state.scheduled = true }
            return !state.scheduled
        }
        guard schedule else { return }
        let delay = delay
        Task.detached(priority: .utility) { [self] in
            try? await Task.sleep(for: delay)
            await flush()
        }
    }

    /// Writes what is pending now.
    public func flush() async {
        let calls = pending.withLock { state in
            defer { state = ([], false) }
            return state.calls
        }
        await store.insert(calls)
    }
}
