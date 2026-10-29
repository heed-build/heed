import Foundation

/// Attention as the second input of `Notices`: what a rule says to notify about (`notify`, or `boost 3`).
public extension Notices {
    /// The id prefix of an Attention entry: its `session` is `attention:<item id>`, which Open routes to the item.
    static let attentionPrefix = "attention:"

    /// An entry for an item a rule asks to notify about; nil for anything else (muted, snoozed, done, or no such
    /// rule). Agents are left out: their sessions notify on their own.
    static func attention(_ entry: AttentionEntry, now: Date) -> Entry? {
        let item = entry.item
        guard entry.live, entry.outcome.action.notifies, !entry.muted, !entry.mark.hides(item, now: now),
              item.kind != .agent
        else { return nil }
        let place = item.repo.map { repo in item.number.map { "\(repo.name) #\($0)" } ?? repo.name }
        return Entry(
            id: attentionPrefix + item.id, title: [place, item.title].compactMap(\.self).joined(separator: " · "),
            agent: "", state: .asking, reason: item.orderedReasons.first { !$0.passive }?.text, kind: .attention,
            session: attentionPrefix + item.id
        )
    }

    /// An entry for a swarm's question that waits for you (an agent asking, as a session asking does): whatever the
    /// rules say, unless you muted, snoozed or set it aside.
    static func swarmQuestion(_ entry: AttentionEntry, now: Date) -> Entry? {
        let item = entry.item
        guard entry.live, GoalAttention.question(of: item) != nil, !entry.muted, !entry.mark.hides(item, now: now)
        else { return nil }
        // Its time in the id: a reminder (which moves it) notifies again, once.
        return Entry(
            id: attentionPrefix + item.id + "@\(Int(item.updatedAt.timeIntervalSince1970))", title: item.title,
            agent: "", state: .asking,
            reason: "a swarm asks you", kind: .attention, session: attentionPrefix + item.id
        )
    }

    /// Attention entries are facts GitHub already settled: no grace, no reminder. They still gather into one
    /// notification when several come in one sync.
    static let attentionTiming = Timing(grace: 0, reminder: nil)
}

/// The Decider's suggestion for items no rule matched: a weight, shown next to the item, never acted on.
public enum AttentionDecide {
    public static let levels = ["ignore", "lower", "normal", "boost 1", "boost 2", "boost 3"]

    public static let questions: [String: Question] = [
        "weight": .score(
            instructions: "How much does this GitHub thread or agent want the developer's attention right now? "
                + "ignore: noise; lower: can wait; normal; boost 1-3: increasingly urgent for them personally.",
            levels: levels
        ),
    ]

    /// What the Decider is shown: the thread as the summary reads it.
    public static func state(for item: AttentionItem, detail: ThreadDetail?) -> String {
        AttentionText.inputs(for: item, detail: detail).prompt
    }

    /// The suggested level, when the answer names one heed knows; `normal` suggests nothing.
    public static func suggestion(_ answers: [String: Answer]) -> String? {
        guard let choice = answers["weight"]?.choice, levels.contains(choice), choice != "normal" else { return nil }
        return choice
    }
}

/// What you did with an item, kept beside the Decider's `decide` rows (same kind, same subject), so a local model can
/// learn from what you did with what it was asked about (`HunchTrainingSet.attention`). The row carries the item as
/// the Decider would be shown it, so an item no one asked about still teaches something.
public enum AttentionLabel: String, Sendable {
    case done, snooze, mute, boost

    /// The call-log row for it: `decide`, command `label`, the item as `subject`.
    public func call(
        for item: AttentionItem, rule: AttentionRule?, suggestion: String?, at: Date,
        caller: String = "attention.label",
        state: String? = nil
    ) -> LoggedCall {
        var detail = [
            "subject": item.id,
            "label": rawValue,
            "reasons": item.orderedReasons.map(\.rawValue)
                .joined(separator: ","),
        ]
        if let rule { detail["rule"] = "\(rule.line): \(rule.text)" }
        if let suggestion { detail["suggested"] = suggestion }
        if let state = LoggedCall.truncated(state) { detail["state"] = state }
        return LoggedCall(
            at: at, kind: .decide, caller: caller, command: "label", duration: 0, operation: "label \(rawValue)",
            detail: detail
        )
    }
}
