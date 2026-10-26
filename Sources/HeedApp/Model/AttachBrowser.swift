import Foundation
import HeedCore
import Observation

/// Goals › Unassigned (`goal.unassigned`): heed's recent attach decisions, its open asks, the goals it suggests from
/// work on no goal, and the rules it learnt. Read from `GoalOps` after every change; the cursor moves over the rows
/// (asks first, then suggestions, then the feed).
@MainActor
@Observable
final class AttachBrowser {
    enum Row: Hashable, Identifiable {
        case ask(AttachDecision)
        case suggestion(GoalSuggestion)
        case decision(AttachDecision)

        var id: String {
            switch self {
            case let .ask(decision): "ask:\(decision.id)"
            case let .suggestion(suggestion): "suggest:\(suggestion.id)"
            case let .decision(decision): "decision:\(decision.id)"
            }
        }
    }

    /// Newest first.
    private(set) var decisions: [AttachDecision] = []
    private(set) var rules = AttachRules()
    private(set) var cursor = 0
    /// Suggestions you said no to, until heed restarts.
    private(set) var dismissed: Set<String> = []
    /// Things being looked at now, so one is not looked at twice at once.
    @ObservationIgnored var inFlight: Set<String> = []
    /// Links, by key, from the goals' snapshot: what is on a goal by now.
    private(set) var linked: Set<String> = []

    func load(decisions fresh: [AttachDecision], rules read: AttachRules, linked keys: Set<String>) {
        if fresh != decisions { decisions = fresh }
        if read != rules { rules = read }
        if keys != linked { linked = keys }
        cursor = min(cursor, max(rows.count - 1, 0))
    }

    /// heed's open asks, newest first.
    var asks: [AttachDecision] { GoalAttachAsks.open(decisions, linked: linked) }

    /// The feed: every decision but the open asks and those a newer one replaced.
    var feed: [AttachDecision] {
        decisions.filter { $0.state != .open && $0.state != .superseded }
    }

    /// Work on no goal heed could make a goal of: its latest decision left it, and no rule ignores it.
    var suggestions: [GoalSuggestion] {
        var latest: [String: AttachDecision] = [:]
        for decision in decisions where latest[decision.subject.key] == nil {
            latest[decision.subject.key] = decision
        }
        let loose = latest.values.filter { $0.leftUnassigned && $0.state != .open && !linked.contains($0.subject.key) }
            .map(\.subject)
        return Clusters.suggest(loose).filter { !dismissed.contains($0.id) }
    }

    var rows: [Row] { asks.map(Row.ask) + suggestions.map(Row.suggestion) + feed.map(Row.decision) }

    var selected: Row? {
        let rows = rows
        return rows.indices.contains(cursor) ? rows[cursor] : nil
    }

    func setCursor(_ index: Int) {
        let count = rows.count
        guard count > 0 else { return }
        cursor = min(max(index, 0), count - 1)
    }

    func dismiss(_ suggestion: GoalSuggestion) {
        dismissed.insert(suggestion.id)
        cursor = min(cursor, max(rows.count - 1, 0))
    }

    /// Things on no goal, for the sidebar: open asks and what was left.
    var unassignedCount: Int {
        var latest: [String: AttachDecision] = [:]
        for decision in decisions where latest[decision.subject.key] == nil {
            latest[decision.subject.key] = decision
        }
        return latest.values.count { $0.leftUnassigned && !linked.contains($0.subject.key) }
    }

    func today(now: Date) -> AttachDay {
        AttachDay.of(decisions, since: Calendar.current.startOfDay(for: now))
    }
}

extension GoalsBrowser {
    /// Reads the decisions and the rules again, after any change.
    func reloadAttach() async {
        guard let ops else { return }
        let decisions = await (try? ops.decisions(limit: 300)) ?? attach.decisions
        let rules = await ops.rules()
        let before = attach.asks.count
        attach.load(decisions: decisions, rules: rules, linked: Set(snapshot.links.map(\.key)))
        // The tutor and Attention follow the asks.
        if attach.asks.count != before { changed() }
    }

    /// The fixture's decisions with the ids the in-memory store gives them (in time order, from 1), at once.
    func loadFixtureAttach(_ decisions: [AttachDecision]) {
        let stored = decisions.sorted { $0.at < $1.at }.enumerated().map { index, decision in
            var decision = decision
            decision.id = Int64(index + 1)
            return decision
        }
        attach.load(
            decisions: stored.reversed(), rules: AttachRules(text: GoalFixtures.attachRules),
            linked: Set(snapshot.links.map(\.key))
        )
    }

    /// `goal.unassigned`: Unassigned, or back to the overview.
    func toggleUnassigned() {
        show(pane == .unassigned ? .overview : .unassigned)
    }
}
