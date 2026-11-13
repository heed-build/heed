import Foundation

/// One thing heed did on its own, as Autopilot's Done tells it: an outcome sentence, a line of detail, and what it was
/// about. Only what heed records: the pilot log (sends, fixes, merges, Copilot and review asks heed made, not yours),
/// goal attachments it made, catch-up summaries it wrote, continue prompts it typed and sessions it named.
public struct AutopilotEntry: Hashable, Sendable, Identifiable {
    public var id: String
    public var at: Date
    public var capability: Capability
    public var text: String
    public var detail: String
    /// `org/name`, when it was about a repo.
    public var repo: String?
    public var ref: PullRef?
    public var session: String?
    /// Review items and checks the agent's push addressed (a green round's outcome), for the day's totals.
    public var addressed = 0

    public init(
        id: String, at: Date, capability: Capability, text: String, detail: String = "", repo: String? = nil,
        ref: PullRef? = nil, session: String? = nil, addressed: Int = 0
    ) {
        self.id = id
        self.at = at
        self.capability = capability
        self.text = text
        self.detail = detail
        self.repo = repo
        self.ref = ref
        self.session = session
        self.addressed = addressed
    }
}

/// A catch-up summary heed wrote, with what it was about.
public struct AutopilotCatchUp: Hashable, Sendable {
    public var id: String
    public var summary: CatchUpSummary
    public var title: String
    public var repo: String?

    public init(id: String, summary: CatchUpSummary, title: String, repo: String? = nil) {
        self.id = id
        self.summary = summary
        self.title = title
        self.repo = repo
    }
}

/// What Done reads.
public struct AutopilotRecord: Sendable {
    public var pilotLog: [PilotEvent] = []
    /// PR titles by `PullRef.description`.
    public var titles: [String: String] = [:]
    public var catchUps: [AutopilotCatchUp] = []
    public var attach: [AttachDecision] = []
    /// Goal titles by id.
    public var goalTitles: [String: String] = [:]
    public var sessions: [Session] = []
    public var continuePrompt = ""

    public init(
        pilotLog: [PilotEvent] = [], titles: [String: String] = [:], catchUps: [AutopilotCatchUp] = [],
        attach: [AttachDecision] = [], goalTitles: [String: String] = [:], sessions: [Session] = [],
        continuePrompt: String = ""
    ) {
        self.pilotLog = pilotLog
        self.titles = titles
        self.catchUps = catchUps
        self.attach = attach
        self.goalTitles = goalTitles
        self.sessions = sessions
        self.continuePrompt = continuePrompt
    }
}

public enum AutopilotDone {
    /// What "this week" covers: the last seven days.
    public static let week: TimeInterval = 7 * 86400

    /// Something you did, not heed: the pilot log marks those `(by you)`.
    public static func byYou(_ event: PilotEvent) -> Bool { event.text.hasSuffix("(by you)") }

    /// The number a pilot event's text starts its count with: `sent 3 items`, `the agent pushed: 2 items addressed`.
    static func count(in text: String) -> Int {
        let words = text.split(whereSeparator: { !$0.isNumber && !$0.isLetter })
        return words.lazy.compactMap { Int($0) }.first ?? 1
    }

    /// Everything heed did, newest first.
    public static func entries(_ record: AutopilotRecord) -> [AutopilotEntry] {
        var entries: [AutopilotEntry] = []
        for event in record.pilotLog where !byYou(event) {
            if let entry = entry(for: event, titles: record.titles) { entries.append(entry) }
        }
        for decision in record.attach where decision.verdict.action == .attach {
            guard [.settled, .accepted].contains(decision.state), let goal = decision.goal ?? decision.verdict.goal
            else { continue }
            let title = record.goalTitles[goal] ?? goal
            entries.append(AutopilotEntry(
                id: "attach-\(decision.id)-\(decision.subject.key)", at: decision.at, capability: .goals,
                text: "Put \(decision.subject.title) on \(title)", detail: decision.verdict.reason,
                repo: decision.subject.repos.first, session: decision.subject.kind == .session
                    ? decision.subject.id : nil
            ))
        }
        for catchUp in record.catchUps {
            let summary = catchUp.summary
            let covered = "\(summary.count) comment\(summary.count == 1 ? "" : "s")"
            entries.append(AutopilotEntry(
                id: "summary-\(catchUp.id)-\(summary.writtenAt.timeIntervalSince1970)", at: summary.writtenAt,
                capability: .summaries, text: "Caught you up on \(catchUp.title)",
                detail: [covered, summary.agent, summary.model].compactMap(\.self).joined(separator: " · "),
                repo: catchUp.repo
            ))
        }
        for session in record.sessions {
            let repo = session.repos.first?.slug
            for (index, event) in session.timeline.enumerated() {
                if !record.continuePrompt.isEmpty, event.text == "sent “\(record.continuePrompt)”" {
                    entries.append(AutopilotEntry(
                        id: "continue-\(session.id)-\(index)", at: event.at, capability: .resume,
                        text: "Told \(session.agent) to carry on in \(session.title)",
                        detail: "after a resume · “\(record.continuePrompt)”", repo: repo, session: session.id
                    ))
                }
            }
            // heed's own renames: a session still named by heed, after the last time you titled it.
            guard session.titleBy == .heed else { continue }
            for (index, event) in session.timeline.enumerated() where event.text.hasPrefix("renamed: ") {
                let change = event.text.dropFirst("renamed: ".count)
                let parts = change.components(separatedBy: " → ")
                entries.append(AutopilotEntry(
                    id: "name-\(session.id)-\(index)", at: event.at, capability: .names,
                    text: "Named a session \(parts.last ?? String(change))",
                    detail: parts.count > 1 ? "was \(parts[0])" : "", repo: repo, session: session.id
                ))
            }
        }
        return entries.sorted { $0.at != $1.at ? $0.at > $1.at : $0.id < $1.id }
    }

    /// A pilot event as an outcome, when it is one heed made happen.
    static func entry(for event: PilotEvent, titles: [String: String]) -> AutopilotEntry? {
        let title = titles[event.ref.description]
        let capability: Capability
        var text = event.text
        var detail = ""
        var addressed = 0
        switch event.kind {
        case .sent:
            capability = .green
            text = capitalized(event.text)
        case .addressed:
            capability = .green
            addressed = count(in: event.text)
            text = "\(addressed) item\(addressed == 1 ? "" : "s") fixed"
            detail = event.text
        case .resolved:
            capability = .green
            text = capitalized(event.text)
        case .merged:
            capability = .merge
            // The log keeps the title when it had one (`Fix label clipping`), else what happened (`merged into main`).
            let name = title ?? (event.text.lowercased().hasPrefix("merged") ? "#\(event.ref.number)" : event.text)
            text = "Merged " + name
            detail = event.text == name ? "" : event.text
        case .autoMerge:
            capability = .merge
            text = capitalized(event.text.components(separatedBy: ";").first ?? event.text)
            detail = event.text.components(separatedBy: "; ").dropFirst().joined(separator: "; ")
        case .updated:
            capability = .merge
            text = "Brought " + (title ?? "#\(event.ref.number)") + " up to date"
            detail = event.text
        case .copilot:
            capability = .copilot
            text = capitalized(event.text)
        case .review:
            guard !event.text.hasPrefix("could not") else { return nil }
            capability = .reviewers
            text = capitalized(event.text)
        case .items, .queued, .waiting, .stuck, .retry, .helperDone, .watch, .green, .pause, .merge, .held:
            return nil
        }
        if detail.isEmpty, let title, event.kind != .merged { detail = title }
        return AutopilotEntry(
            id: "pilot-\(event.id)", at: event.at, capability: capability, text: text, detail: detail,
            repo: event.ref.repo.slug, ref: event.ref, addressed: addressed
        )
    }

    static func capitalized(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.uppercased() + text.dropFirst()
    }

    /// What happened since `now - week`.
    public static func thisWeek(_ entries: [AutopilotEntry], now: Date) -> [AutopilotEntry] {
        let start = now.addingTimeInterval(-week)
        return entries.filter { $0.at >= start && $0.at <= now }
    }

    public static func counts(_ entries: [AutopilotEntry]) -> [Capability: Int] {
        entries.reduce(into: [:]) { $0[$1.capability, default: 0] += 1 }
    }

    public static func repoCounts(_ entries: [AutopilotEntry]) -> [String: Int] {
        entries.reduce(into: [:]) { counts, entry in
            if let repo = entry.repo { counts[repo, default: 0] += 1 }
        }
    }

    /// One day of Done, newest first, with its totals.
    public struct Day: Hashable, Sendable, Identifiable {
        public var start: Date
        public var title: String
        public var entries: [AutopilotEntry]
        public var id: Date { start }

        /// `9 things · 2 merged · 4 fixed`.
        public var totals: String {
            let merged = entries.count { $0.capability == .merge && $0.text.hasPrefix("Merged") }
            let fixed = entries.reduce(0) { $0 + $1.addressed }
            var parts = ["\(entries.count) thing\(entries.count == 1 ? "" : "s")"]
            if merged > 0 { parts.append("\(merged) merged") }
            if fixed > 0 { parts.append("\(fixed) fixed") }
            return parts.joined(separator: " · ")
        }
    }

    /// The week's entries narrowed to a capability and a repo, by day, newest first.
    public static func days(
        _ entries: [AutopilotEntry], capability: Capability? = nil, repo: String? = nil, now: Date,
        calendar: Calendar = .current
    ) -> [Day] {
        let shown = entries.filter { entry in
            (capability == nil || entry.capability == capability) && (repo == nil || entry.repo == repo)
        }
        let today = calendar.startOfDay(for: now)
        var days: [Day] = []
        for entry in shown {
            let start = calendar.startOfDay(for: entry.at)
            if days.last?.start == start {
                days[days.count - 1].entries.append(entry)
            } else {
                days.append(Day(
                    start: start,
                    title: dayTitle(start, today: today, calendar: calendar),
                    entries: [entry]
                ))
            }
        }
        return days
    }

    static func dayTitle(_ start: Date, today: Date, calendar: Calendar) -> String {
        if start == today { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: today), start == yesterday {
            return "Yesterday"
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEEE d MMM"
        return formatter.string(from: start)
    }

    /// Items you sent to an agent yourself this week, by repo: what green on auto would have sent for you.
    public static func sentByYou(_ log: [PilotEvent], now: Date) -> [String: Int] {
        let start = now.addingTimeInterval(-week)
        return log.filter { $0.kind == .sent && byYou($0) && $0.at >= start }
            .reduce(into: [:]) { $0[$1.ref.repo.slug, default: 0] += count(in: $1.text) }
    }
}
