import Foundation

/// `[standup]`: a report written on the days you choose, one per Mindmap (each org, and personal, never mixed),
/// answering your own questions from what the Mindmap and the ledger hold.
public struct StandupSettings: Equatable, Sendable {
    /// Off until you turn it on: every report is a model call per question.
    public var enabled = false
    /// Weekdays, 1 Sunday … 7 Saturday (Calendar's numbering).
    public var days: [Int] = [2, 3, 4, 5, 6]
    /// The time of day, minutes after midnight.
    public var at = 8 * 60 + 40
    /// What a report covers: since the last report (nil), or this many days back.
    public var rangeDays: Int?
    public var questions = StandupSettings.defaultQuestions
    /// Questions of one Mindmap's own, by instance (`[orgs.<name>] standup_questions`, `[standup] personal_questions`).
    public var questionsByInstance: [String: [String]] = [:]

    /// The questions `instance`'s report answers: its own, or everyone's.
    public func questions(for instance: String) -> [String] {
        questionsByInstance[instance].flatMap { $0.isEmpty ? nil : $0 } ?? questions
    }

    public static let defaultQuestions = [
        "What did I finish since the last standup?",
        "What am I working on next?",
        "What is blocked or waiting on someone?",
    ]

    public static let dayNames = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]

    public init() {}

    /// `08:40` → 520; nil when it is not a time.
    public static func minutes(_ text: String) -> Int? {
        let parts = text.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0 ..< 24).contains(parts[0]), (0 ..< 60).contains(parts[1]) else { return nil }
        return parts[0] * 60 + parts[1]
    }
}

/// When the next report is due.
public enum StandupSchedule {
    /// The most recent moment a report was due at or before `now`, within the last eight days.
    public static func lastSlot(before now: Date, settings: StandupSettings, calendar: Calendar = .current) -> Date? {
        for back in 0 ... 7 {
            guard let day = calendar.date(byAdding: .day, value: -back, to: calendar.startOfDay(for: now)) else {
                continue
            }
            guard settings.days.contains(calendar.component(.weekday, from: day)) else { continue }
            let slot = day.addingTimeInterval(TimeInterval(settings.at * 60))
            if slot <= now { return slot }
        }
        return nil
    }

    /// Whether a report is due: a slot has passed since the last one. Missed while the Mac slept or heed was quit, it
    /// runs once, when heed next looks.
    public static func due(now: Date, last: Date?, settings: StandupSettings, calendar: Calendar = .current) -> Bool {
        guard settings.enabled,
              let slot = lastSlot(before: now, settings: settings, calendar: calendar)
        else { return false }
        return last.map { $0 < slot } ?? true
    }

    /// Where a report starts: the last report, or `rangeDays` back (a week when there was none).
    public static func from(now: Date, last: Date?, settings: StandupSettings) -> Date {
        if let days = settings.rangeDays { return now.addingTimeInterval(-TimeInterval(days) * 86400) }
        return last ?? now.addingTimeInterval(-7 * 86400)
    }
}

/// One report: one Mindmap's answers to your questions over a range.
public struct StandupReport: Codable, Hashable, Sendable, Identifiable {
    public struct Answer: Codable, Hashable, Sendable {
        public var question: String
        public var text: String

        public init(question: String, text: String) {
            self.question = question
            self.text = text
        }
    }

    public var id: String
    public var instance: String
    public var at: Date
    public var from: Date
    public var answers: [Answer]
    public var edited: Bool

    public init(id: String, instance: String, at: Date, from: Date, answers: [Answer], edited: Bool = false) {
        self.id = id
        self.instance = instance
        self.at = at
        self.from = from
        self.answers = answers
        self.edited = edited
    }

    /// For the clipboard: markdown (the questions as headings, PR links kept) or plain text.
    public func text(markdown: Bool, only question: String? = nil) -> String {
        let shown = answers.filter { question == nil || $0.question == question }
        if markdown {
            return shown.map { "**\($0.question)**\n\n\($0.text)" }.joined(separator: "\n\n")
        }
        return shown.map { answer in
            answer.question + "\n" + answer.text.replacingOccurrences(of: "**", with: "")
        }.joined(separator: "\n\n")
    }
}

/// What a report is written from: one Mindmap's work in the range, its campaigns, decisions and what is open.
public enum StandupInputs {
    public static func make(
        instance: String, tree: MindmapTree, ledger: [String: LedgerEntry], from: Date, now _: Date
    ) -> SummaryInputs {
        var lines: [String] = []
        let work = tree.nodes.values.filter { $0.kind == .work }.compactMap { node -> (MindNode, LedgerEntry)? in
            guard let id = node.entry, let entry = ledger[id], entry.updatedAt >= from else { return nil }
            return (node, entry)
        }.sorted { $0.1.updatedAt > $1.1.updatedAt }
        for (node, entry) in work.prefix(40) {
            let campaign = MemoryBrief.anchor(of: node.id, in: tree)?.title ?? "Unsorted"
            let pulls = entry.pulls.map { "\($0.repo.slug)#\($0.number)" }.joined(separator: " ")
            lines.append("work [\(campaign)] \(entry.title) (\(entry.outcome))\(pulls.isEmpty ? "" : " \(pulls)"): "
                + (entry.summary ?? ""))
        }
        let touched = Set(work.compactMap { MemoryBrief.anchor(of: $0.0.id, in: tree)?.id })
        for campaign in tree.campaigns where touched.contains(campaign.id) {
            lines.append("campaign \(campaign.title)\(campaign.stage.map { " (\($0.rawValue))" } ?? ""): "
                + (campaign.synopsis ?? ""))
            for item in tree.stillOpen(under: campaign.id).prefix(6) {
                lines.append("open [\(campaign.title)] \(item.kind.rawValue): \(item.text)")
            }
        }
        return SummaryInputs(title: "Standup for \(MindmapInstance.title(instance))", known: lines)
    }
}
