import Foundation

/// What Attention's actions need beyond the item: the model's inputs for a summary or a reply, the prompt work starts
/// from, and how long a snooze lasts.
public enum AttentionText {
    /// A thread as the model reads it: title, place, why it is here, its description and latest comments.
    public static func inputs(for item: AttentionItem, detail: ThreadDetail?) -> SummaryInputs {
        var thread: [String] = ["Why it is here: " + item.orderedReasons.map(\.text).joined(separator: ", ")]
        if !item.teams.isEmpty { thread.append("Through the team: " + item.teams.sorted().joined(separator: ", ")) }
        if let author = item.author ?? detail?.author { thread.append("Opened by \(author)") }
        if let detail, !detail.body.isEmpty { thread.append("\nDescription:\n\(detail.body)") }
        return SummaryInputs(
            title: item.title, repo: item.place, branch: item.branch,
            pullRequest: thread.joined(separator: "\n"),
            timeline: detail?.comments.map { "\($0.author): \($0.text)" } ?? []
        )
    }

    /// The prompt Start work opens with, from items: one issue's whole text when it is the only one and known,
    /// otherwise a list of what to look into.
    public static func workPrompt(_ items: [AttentionItem], issues: [Issue], instructions: String = "") -> String {
        let threads = items.filter { $0.kind != .agent }
        guard !threads.isEmpty else { return "" }
        let known = threads.compactMap { item in
            issues.first { item.kind == .issue && AttentionItem.threadID($0.repo, $0.number) == item.id }
        }
        if known.count == threads.count { return WorkPrompt.from(issues: known, instructions: instructions) }
        let refs = threads.map { item in
            "- \(item.repo?.name ?? "")\(item.number.map { "#\($0)" } ?? "") \(item.title) "
                + "(\(item.orderedReasons.map(\.text).joined(separator: ", ")))"
        }
        return (["Look into these:"] + refs + (instructions.isEmpty ? [] : ["", instructions])).joined(separator: "\n")
    }

    /// When a snooze given as `30m`, `3h`, `2d` or `tomorrow` (9:00 the next morning) ends; nil when it does not
    /// read. No argument: three hours.
    public static func snoozeEnd(_ text: String?, now: Date, calendar: Calendar = .current) -> Date? {
        guard let text = text?.trimmingCharacters(in: .whitespaces).lowercased(), !text.isEmpty else {
            return now.addingTimeInterval(3 * 3600)
        }
        if text == "tomorrow" {
            let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
            return calendar.date(bySettingHour: 9, minute: 0, second: 0, of: tomorrow)
        }
        guard let seconds = AttentionRules.duration(text), seconds > 0 else { return nil }
        return now.addingTimeInterval(seconds)
    }
}
