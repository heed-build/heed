import Foundation

// Attention's catch-up summaries: what is new in a thread since you last looked (the whole thread when you never
// did), written by heed's model calls, ahead of time for For you's New and on open for the rest, and always in one
// visible state on the reader's card.

/// `[attention] summaries`: when catch-up summaries are written.
public enum AttentionSummaryMode: String, CaseIterable, Hashable, Sendable {
    /// Ahead of time for every thread in For you's New (newest first, within the daily cap), and on open for the rest.
    case ahead
    /// Only when you open a thread in the reader.
    case open
    /// None.
    case off
}

/// A catch-up summary as kept (`attention.sqlite`): its text, what it covers, and who wrote it.
public struct CatchUpSummary: Hashable, Sendable, Codable {
    public var text: String
    /// When you had last looked when it was written: it covers what came after. Nil: it covers the whole thread.
    public var since: Date?
    /// The newest comment it covers: a comment by someone else after this makes it stale.
    public var coversUpTo: Date
    /// The comments by others it covered.
    public var count: Int
    /// The thread's state when it was written (`ThreadConversation.stateText`): a new state makes it stale.
    public var state: String
    public var writtenAt: Date
    public var agent: String?
    public var model: String?

    public init(
        text: String, since: Date?, coversUpTo: Date, count: Int, state: String, writtenAt: Date,
        agent: String? = nil, model: String? = nil
    ) {
        self.text = text
        self.since = since
        self.coversUpTo = coversUpTo
        self.count = count
        self.state = state
        self.writtenAt = writtenAt
        self.agent = agent
        self.model = model
    }

    /// Its lines, without their `- ` bullets: what the card lists.
    public var lines: [String] {
        text.split(whereSeparator: \.isNewline).map { line in
            var line = line.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• "] where line.hasPrefix(bullet) {
                line.removeFirst(bullet.count)
            }
            return line.trimmingCharacters(in: .whitespaces)
        }.filter { !$0.isEmpty }
    }

    /// Its first line: a row's preview once it is written.
    public var firstLine: String? { lines.first }

    /// `claude haiku`: who wrote it, as the card says it.
    public var writer: String? { CatchUp.writer(agent: agent, model: model) }
}

/// When you have seen a thread up to, counting what you wrote yourself.
public enum ThreadSeen {
    /// Whether the viewer wrote it.
    public static func isMine(_ comment: ThreadComment, viewer: String?) -> Bool {
        guard let viewer, !viewer.isEmpty, let login = comment.author?.login else { return false }
        return login.lowercased() == viewer.lowercased()
    }

    /// When you last looked at the thread in the reader, or when you last commented in it if that is later: writing
    /// a comment means you saw the thread up to it, so neither your own comments nor what came before them are new.
    public static func effective(_ seenAt: Date?, comments: [ThreadComment], viewer: String?) -> Date? {
        let mine = comments.filter { isMine($0, viewer: viewer) }.map(\.createdAt).max()
        switch (seenAt, mine) {
        case let (seen?, mine?): return max(seen, mine)
        case let (seen, mine): return seen ?? mine
        }
    }
}

/// What a catch-up summary is written from: the comments by others since you last looked and the state, or the
/// whole thread when you never looked or nothing is new.
public struct CatchUpInput: Hashable, Sendable {
    /// Nil: the whole thread.
    public var since: Date?
    /// The comments it covers, oldest first: only the new ones by others; with `since` nil, every comment.
    public var comments: [ThreadComment]
    /// The newest comment in the thread when it was written.
    public var coversUpTo: Date
    /// The state now, and the one the last summary saw when it is different.
    public var state: String
    public var previousState: String?
    /// The comments by others it covers.
    public var count: Int

    public var stateChanged: Bool { previousState.map { $0 != state } ?? false }
}

/// How a summary compares with the thread now.
public enum CatchUpFreshness: Hashable, Sendable {
    /// None written.
    case missing
    case upToDate
    /// Comments by others came after what it covers (`new`), or the thread's state changed.
    case stale(new: Int, stateChanged: Bool)
}

public enum CatchUp {
    /// What to summarize. `seenAt` is when you last looked at the thread in the reader (the same time the reader folds
    /// at), made later by your own comments (`ThreadSeen.effective`). With something new by others since, or a new
    /// state, only that; otherwise (never looked, or nothing new) the whole thread.
    public static func input(
        _ conversation: ThreadConversation, seenAt: Date?, viewer: String?, previous: CatchUpSummary? = nil
    ) -> CatchUpInput {
        let comments = conversation.comments
        let covers = ([conversation.createdAt] + comments.map(\.createdAt)).max() ?? conversation.createdAt
        let state = conversation.stateText
        let previousState = previous?.state
        let others = { (list: [ThreadComment]) in list.count { !ThreadSeen.isMine($0, viewer: viewer) } }
        if let seen = ThreadSeen.effective(seenAt, comments: comments, viewer: viewer) {
            let new = comments.filter { $0.createdAt > seen && !ThreadSeen.isMine($0, viewer: viewer) }
            if !new.isEmpty || (previousState.map { $0 != state } ?? false) {
                return CatchUpInput(
                    since: seen, comments: new, coversUpTo: covers, state: state, previousState: previousState,
                    count: new.count
                )
            }
        }
        return CatchUpInput(
            since: nil, comments: comments, coversUpTo: covers, state: state, previousState: previousState,
            count: others(comments)
        )
    }

    /// The model's input: the thread's title and place, why it is in Attention, its state, then only what the
    /// summary covers (the new comments, or the description and every comment), as plain text.
    public static func inputs(
        for item: AttentionItem, conversation: ThreadConversation, input: CatchUpInput
    ) -> SummaryInputs {
        var header = [
            "\(conversation.kind == .pr ? "Pull request" : "Issue") #\(conversation.number): \(conversation.title)",
            "Why it is in their Attention: " + item.orderedReasons.map(\.text).joined(separator: ", "),
            "State: \(input.state)" +
                (input.stateChanged ? " (was \(input.previousState ?? "") when they looked)" : ""),
        ]
        if let author = conversation.author?.login { header.append("Opened by \(author)") }
        var timeline: [String] = []
        if let since = input.since {
            header.append(
                "They last looked at \(ISO8601DateFormatter().string(from: since)). Only what came after follows: "
                    + (input.comments.isEmpty ? "no new comments." : "\(input.comments.count) new.")
            )
        } else {
            header.append("They never looked at this thread, or nothing is new since: the whole thread follows.")
            let body = ThreadText.plain(conversation.bodyHTML)
            if !body.isEmpty { header.append("\nDescription:\n\(body)") }
        }
        for comment in input.comments {
            let text = comment.minimizedReason.map { "(hidden as \($0))" } ?? ThreadText.plain(comment.bodyHTML)
            timeline.append("\(comment.author?.login ?? "ghost") \(comment.verb): \(text)")
        }
        return SummaryInputs(
            title: conversation.title, repo: item.place, branch: item.branch,
            pullRequest: header.joined(separator: "\n"), timeline: timeline
        )
    }

    /// How `summary` compares with the thread as heed knows it now: comments by others after what it covers (from
    /// the conversation when loaded, and the details a sync fetched), a new state, or the item's own activity.
    public static func freshness(
        _ summary: CatchUpSummary?, item: AttentionItem, conversation: ThreadConversation?, detail: ThreadDetail?,
        viewer: String?
    ) -> CatchUpFreshness {
        guard let summary else { return .missing }
        let me = viewer?.lowercased()
        let fromConversation = conversation?.comments.count {
            $0.createdAt > summary.coversUpTo && !ThreadSeen.isMine($0, viewer: viewer)
        } ?? 0
        let fromDetail = detail?.comments.count {
            $0.at > summary.coversUpTo && $0.author.lowercased() != me
        } ?? 0
        var new = max(fromConversation, fromDetail)
        if new == 0, let others = item.activity?.others, others > summary.coversUpTo { new = 1 }
        let stateChanged = conversation.map { $0.stateText != summary.state } ?? false
        return new > 0 || stateChanged ? .stale(new: new, stateChanged: stateChanged) : .upToDate
    }

    /// `claude haiku`.
    public static func writer(agent: String?, model: String?) -> String? {
        let parts = [agent, model].compactMap { $0?.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

/// Why a summary could not be written, from the runner's error: what the card says, and when to try again.
public struct SummaryFailure: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case rateLimited, loggedOut, budget, timeout, noAgent, thread, failed
    }

    public var kind: Kind
    /// `claude rate limited until 14:10`.
    public var text: String
    /// When it may work again, when known (a rate limit's reset, the daily cap's next day).
    public var until: Date?
    public var at: Date
    /// The item's `updatedAt` when it failed: a newer update tries again.
    public var forUpdate: Date

    public init(kind: Kind, text: String, until: Date? = nil, at: Date, forUpdate: Date) {
        self.kind = kind
        self.text = text
        self.until = until
        self.at = at
        self.forUpdate = forUpdate
    }

    /// From what a summary's attempt threw; nil for model calls being off (that is the off state, not a failure).
    public static func of(
        _ error: Error, at now: Date, forUpdate: Date, calendar: Calendar = .current
    ) -> SummaryFailure? {
        guard let error = error as? LLMError else {
            return SummaryFailure(
                kind: .thread, text: "could not load the thread: \(short("\(error)"))", at: now, forUpdate: forUpdate
            )
        }
        switch error {
        case .disabled:
            return nil
        case let .overBudget(until, reasons):
            let reason = reasons.first.map(spoken) ?? "the daily cap is reached"
            return SummaryFailure(
                kind: .budget, text: "\(reason), until \(AgentUsage.clock(until))", until: until, at: now,
                forUpdate: forUpdate
            )
        case let .noAgent(reasons), let .failed(reasons):
            let kinds = reasons.map(kind(of:))
            // The most telling reason leads: a rate limit, a login, the cap, a timeout, then anything else.
            let order: [Kind] = [.rateLimited, .loggedOut, .budget, .timeout]
            let fallback: Kind = error == .failed(reasons: reasons) ? .failed : .noAgent
            let lead = order.first(where: kinds.contains) ?? fallback
            let index = kinds.firstIndex(of: lead) ?? 0
            let reason = reasons.indices.contains(index) ? spoken(reasons[index]) : "no agent to call"
            return SummaryFailure(
                kind: lead, text: short(reason),
                until: lead == .rateLimited ? clockTime(in: reason, after: now, calendar: calendar) : nil,
                at: now, forUpdate: forUpdate
            )
        case let .unparseable(agent, _):
            return SummaryFailure(
                kind: .failed,
                text: "\(agent) answered with nothing usable",
                at: now,
                forUpdate: forUpdate
            )
        }
    }

    static func kind(of reason: String) -> Kind {
        let text = reason.lowercased()
        if text.contains("rate limit") || text.contains("usage limit") { return .rateLimited }
        if text.contains("not logged in") || text.contains("logged out") || text.contains("login") { return .loggedOut }
        if text.contains("daily cap") { return .budget }
        if text.contains("timed out") { return .timeout }
        if text.contains("not found") || text.contains(": off") || text.contains("no such agent") { return .noAgent }
        return .failed
    }

    /// `claude: rate limited until 14:10` as a line says it: `claude rate limited until 14:10`.
    static func spoken(_ reason: String) -> String {
        guard let colon = reason.range(of: ": ") else { return reason }
        return reason.replacingCharacters(in: colon, with: " ")
    }

    static func short(_ text: String) -> String {
        let line = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        return line.count > 120 ? String(line.prefix(119)) + "…" : line
    }

    /// The `HH:MM` in `text` as the next such time after `now`.
    static func clockTime(in text: String, after now: Date, calendar: Calendar) -> Date? {
        guard let match = text.range(of: #"\b([01]?\d|2[0-3]):[0-5]\d\b"#, options: .regularExpression) else {
            return nil
        }
        let parts = text[match].split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2,
              let today = calendar.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: now)
        else { return nil }
        return today > now ? today : calendar.date(byAdding: .day, value: 1, to: today)
    }

    /// Whether a summary may be tried again on its own (↻ always may): the item changed since, or the time the
    /// failure named passed, or, when it named none, `backoff` since it failed.
    public func mayRetry(updatedAt: Date, now: Date, backoff: TimeInterval) -> Bool {
        if updatedAt > forUpdate { return true }
        if let until { return now >= until }
        return now >= at.addingTimeInterval(backoff)
    }
}

/// A summary being written: since when, and which agent and model took the call once it started.
public struct SummaryRun: Hashable, Sendable {
    public var startedAt: Date
    public var agent: String?
    public var model: String?
    /// In the ahead queue, not started yet.
    public var queued: Bool

    public init(startedAt: Date, agent: String? = nil, model: String? = nil, queued: Bool = false) {
        self.startedAt = startedAt
        self.agent = agent
        self.model = model
        self.queued = queued
    }
}

/// What the reader's summary card shows: always one of these.
public enum SummaryCardState: Hashable, Sendable {
    /// Being written (or about to be): the run, and the summary it replaces, if any.
    case summarizing(SummaryRun?, previous: CatchUpSummary?)
    case upToDate(CatchUpSummary)
    case stale(CatchUpSummary, new: Int, stateChanged: Bool)
    /// The runner's reason, and the summary from before, if any.
    case failed(SummaryFailure, previous: CatchUpSummary?)
    case off(Off)

    public enum Off: Hashable, Sendable {
        /// `[llm] enabled = false`.
        case modelCalls
        /// `[attention] summaries = "off"`.
        case summaries

        /// `model calls are off`.
        public var text: String {
            switch self {
            case .modelCalls: "model calls are off"
            case .summaries: "summaries are off"
            }
        }

        /// What Turn on runs: Settings on the page that turns it on.
        public var command: String {
            switch self {
            case .modelCalls: "settings.open model-calls"
            case .summaries: "settings.open attention"
            }
        }
    }

    /// The card's state: off when model calls or summaries are; then a run in progress; then a failure since the last
    /// summary; then how the summary compares with the thread. With none written yet it is about to be (the reader
    /// asks for one when it opens a thread).
    public static func of(
        summary: CatchUpSummary?, freshness: CatchUpFreshness, run: SummaryRun?, failure: SummaryFailure?,
        mode: AttentionSummaryMode, modelCalls: Bool
    ) -> SummaryCardState {
        if !modelCalls { return .off(.modelCalls) }
        if mode == .off { return .off(.summaries) }
        if let run { return .summarizing(run, previous: summary) }
        if let failure, summary.map({ $0.writtenAt < failure.at }) ?? true {
            return .failed(failure, previous: summary)
        }
        switch freshness {
        case .upToDate: return summary.map(SummaryCardState.upToDate) ?? .summarizing(nil, previous: nil)
        case let .stale(new, changed):
            return summary.map { .stale($0, new: new, stateChanged: changed) } ?? .summarizing(nil, previous: nil)
        case .missing: return .summarizing(nil, previous: nil)
        }
    }

    /// The chip: `summarizing…`, `up to date`, `stale · 2 new`, `failed`, `off`.
    public var chip: String {
        switch self {
        case .summarizing: "summarizing…"
        case .upToDate: "up to date"
        case let .stale(_, new, changed):
            new > 0 ? "stale · \(new) new" : changed ? "stale · state changed" : "stale"
        case .failed: "failed"
        case .off: "off"
        }
    }

    /// The line beside the chip: who and since when, what it covers, why it failed.
    public func line(now: Date) -> String {
        switch self {
        case let .summarizing(run, _):
            guard let run else { return "starting" }
            if run.queued { return "waiting its turn in the queue" }
            let who = CatchUp.writer(agent: run.agent, model: run.model) ?? "waiting for a model call"
            return "\(who), started \(CatchUp.age(run.startedAt, now: now))"
        case let .upToDate(summary):
            return summary.since == nil
                ? "written for the whole thread"
                : "written for the \(summary.count) new comment\(summary.count == 1 ? "" : "s")"
        case let .stale(_, new, changed):
            if new > 0 { return "\(new) new comment\(new == 1 ? "" : "s") since it was written" }
            return changed ? "the thread's state changed since it was written" : "the thread changed since"
        case let .failed(failure, _):
            return failure.text
        case let .off(reason):
            return reason.text
        }
    }

    /// The summary shown under the chip (a stale or failed one stays, dimmed).
    public var summary: CatchUpSummary? {
        switch self {
        case let .summarizing(_, previous), let .failed(_, previous): previous
        case let .upToDate(summary), let .stale(summary, _, _): summary
        case .off: nil
        }
    }
}

/// When a summary is due, and the ahead queue.
public enum SummaryQueue {
    public enum Trigger: Hashable, Sendable {
        /// The ahead queue, after a sync.
        case ahead
        /// The thread opened in the reader.
        case open
        /// ↻ (`attention.summarize`): always, while summaries and model calls are on.
        case asked
    }

    /// Only threads are summarized: an issue or a PR, never an agent, a goal, a CI run or a release.
    public static func summarizable(_ item: AttentionItem) -> Bool {
        (item.kind == .pr || item.kind == .issue) && item.repo != nil && item.number != nil
    }

    /// Whether `item` should get a summary written now.
    public static func due(
        _ item: AttentionItem, trigger: Trigger, mode: AttentionSummaryMode, modelCalls: Bool,
        freshness: CatchUpFreshness, failure: SummaryFailure?, running: Bool, now: Date, backoff: TimeInterval
    ) -> Bool {
        guard modelCalls, mode != .off, summarizable(item), !running else { return false }
        if trigger == .asked { return true }
        if trigger == .ahead, mode != .ahead { return false }
        if freshness == .upToDate { return false }
        if let failure, !failure.mayRetry(updatedAt: item.updatedAt, now: now, backoff: backoff) { return false }
        return true
    }

    /// The ahead queue: New's threads that are due, newest first, cut at `budget`. Returns the ids in order and how
    /// many were left out for the budget.
    public static func ahead(
        _ new: [AttentionEntry], budget: Int, due: (AttentionItem) -> Bool
    ) -> (ids: [String], cut: Int) {
        let wanted = new.map(\.item).filter(due).sorted { lhs, rhs in
            lhs.updatedAt != rhs.updatedAt ? lhs.updatedAt > rhs.updatedAt : lhs.id < rhs.id
        }
        let take = max(0, min(budget, wanted.count))
        return (wanted.prefix(take).map(\.id), wanted.count - take)
    }

    /// Calls the ahead queue may make today: what the agents that can take calls have left of `[llm] daily_calls`
    /// (none for one past its dollar cap), less `reserve` kept for everything else, and never more than `perRun`.
    public static func budget(
        settings: LLMSettings, spent: [String: (calls: Int, dollars: Double)], agents: [String], reserve: Int = 10,
        perRun: Int = 25
    ) -> Int {
        guard settings.enabled else { return 0 }
        let usable = agents.filter { settings.isEnabled($0) && (settings.only == nil || settings.only == $0) }
        var left = 0
        for agent in usable {
            let used = spent[agent] ?? (0, 0)
            if settings.dailyDollars > 0, used.dollars >= settings.dailyDollars { continue }
            left += settings.dailyCalls > 0 ? max(0, settings.dailyCalls - used.calls) : perRun + reserve
        }
        return min(perRun, max(0, left - reserve))
    }
}

/// The ahead queue at work: how many it set out to write and how many are done, for the list's footer.
public struct SummaryProgress: Hashable, Sendable {
    public var total: Int
    public var done: Int

    public init(total: Int, done: Int = 0) {
        self.total = total
        self.done = done
    }

    /// `summarizing 2 of 5`.
    public var text: String { "summarizing \(min(done + 1, total)) of \(total)" }
}

public extension CatchUp {
    /// `3 s ago`, `2 min ago`.
    static func age(_ date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "\(seconds) s ago" }
        if seconds < 3600 { return "\(seconds / 60) min ago" }
        if seconds < 86400 { return "\(seconds / 3600) h ago" }
        return "\(seconds / 86400) d ago"
    }
}

/// GitHub's rendered HTML as plain text, for the model: block ends become line breaks, list items `- `, tags go,
/// entities are decoded.
public enum ThreadText {
    public static func plain(_ html: String) -> String {
        var text = html
        let breaks = [
            #"<br\s*/?>"#, #"</p>"#, #"</div>"#, #"</li>"#, #"</pre>"#, #"</h[1-6]>"#, #"</tr>"#, #"</blockquote>"#,
            #"</ul>"#, #"</ol>"#, #"</table>"#,
        ]
        for pattern in breaks {
            text = text.replacingOccurrences(of: pattern, with: "\n", options: [.regularExpression, .caseInsensitive])
        }
        text = text.replacingOccurrences(
            of: #"<li\b[^>]*>"#,
            with: "- ",
            options: [.regularExpression, .caseInsensitive]
        )
        text = text.replacingOccurrences(of: #"</t[dh]>"#, with: " | ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let entities = [
            "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&#x27;": "'", "&apos;": "'", "&nbsp;": " ",
        ]
        for (entity, character) in entities {
            text = text.replacingOccurrences(of: entity, with: character)
        }
        text = text.replacingOccurrences(of: "&amp;", with: "&")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var result: [String] = []
        for line in lines where !(line.isEmpty && (result.last?.isEmpty ?? true)) {
            result.append(line)
        }
        return result.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
