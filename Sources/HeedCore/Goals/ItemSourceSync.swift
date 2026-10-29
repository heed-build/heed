import Foundation

/// A PR or issue as a source's query finds it, projected from GitHub's answer: what an item needs (title, link,
/// author) and what its done rule reads (state, checks, your review).
public struct SourceMatch: Hashable, Sendable {
    public enum State: String, Hashable, Sendable {
        case open, closed, merged
    }

    /// Your newest review of a PR.
    public enum Review: String, Hashable, Sendable {
        case approved, changesRequested, commented

        public var words: String {
            switch self {
            case .approved: "approved"
            case .changesRequested: "changes requested"
            case .commented: "commented"
            }
        }
    }

    /// `org/repo#n`.
    public var ref: String
    public var kind: GoalItem.Sourced.Kind
    public var title: String
    public var url: String
    public var author: String?
    public var state: State
    public var isDraft: Bool
    /// A PR's checks on its newest commit; nil for an issue.
    public var checks: CheckSummary?
    public var review: Review?
    /// A review of yours is asked for now: after a review of yours, someone asked again (GitHub drops your request
    /// when you review).
    public var reviewRequested: Bool

    public init(
        ref: String, kind: GoalItem.Sourced.Kind, title: String, url: String, author: String? = nil,
        state: State = .open, isDraft: Bool = false, checks: CheckSummary? = nil, review: Review? = nil,
        reviewRequested: Bool = false
    ) {
        self.reviewRequested = reviewRequested
        self.ref = ref
        self.kind = kind
        self.title = title
        self.url = url
        self.author = author
        self.state = state
        self.isDraft = isDraft
        self.checks = checks
        self.review = review
    }

    /// `#12`.
    public var number: String { ref.split(separator: "#").last.map { "#\($0)" } ?? ref }

    /// Reviewed by you, and your review asked for again since.
    public var reReview: Bool { review != nil && reviewRequested }

    /// Every check passing (none failing or running, at least one passed).
    public var green: Bool {
        guard let checks else { return false }
        return checks.failed == 0 && checks.pending == 0 && checks.passed > 0
    }
}

/// What one sync of a source found: the PRs and issues that match now, and the ones the goal has from it that no
/// longer do, looked up by number (closed, merged, or open but out of the query). A source whose search failed has
/// no result, and its items are left as they are.
public struct SourceResult: Hashable, Sendable {
    public var matches: [SourceMatch]
    /// The goal's items of the source that did not match, by ref: what GitHub says of each now. A ref missing here
    /// was not found (deleted, or out of reach).
    public var looked: [String: SourceMatch]
    /// GitHub has more than the first page: how many it said there are.
    public var total: Int?

    public init(matches: [SourceMatch], looked: [String: SourceMatch] = [:], total: Int? = nil) {
        self.matches = matches
        self.looked = looked
        self.total = total
    }
}

/// Keeps a goal's items in step with its sources: one item per matching PR or issue, made when it first matches,
/// with evidence for what changed since the last sync, marked when it stops matching while open, and never
/// deleted. Pure: `GoalOps.applySources` writes what it says.
public enum ItemSourceSync {
    /// A new item: what it is called, where it came from, and its first evidence.
    public struct NewItem: Hashable, Sendable {
        public var title: String
        public var sourced: GoalItem.Sourced
        public var reason: String
        public var evidence: [GoalEvidence]
    }

    public struct Plan: Hashable, Sendable {
        public var adds: [NewItem] = []
        /// Items whose `sourced` (or title) changes: adopted by a source, left it, back in it, a new rule.
        public var updates: [GoalItem] = []
        /// Evidence for items the goal has (their ids filled in).
        public var evidence: [GoalEvidence] = []

        public var isEmpty: Bool { adds.isEmpty && updates.isEmpty && evidence.isEmpty }
    }

    /// The plan for `results` (by source id) against the goal's items and evidence. Each PR or issue is one item
    /// per goal, whichever source found it first; an item the goal had for that PR already (from a session's branch)
    /// is taken in rather than made twice.
    public static func plan(
        goal: String, sources: [ItemSource], results: [String: SourceResult], items: [GoalItem],
        evidence known: [GoalEvidence], now: Date
    ) -> Plan {
        var plan = Plan()
        var items = items
        var claimed: Set<String> = []
        func index(of ref: String) -> Int? {
            items.firstIndex { $0.sourced?.ref == ref }
                ?? items
                .firstIndex {
                    $0.sourced == nil && ($0.linked(.pr).contains(ref) || $0.linked(.issue).contains(ref))
                }
        }
        for source in sources {
            guard let result = results[source.id] else { continue }
            for match in result.matches where !claimed.contains(match.ref) {
                claimed.insert(match.ref)
                let fresh = evidence(match, rule: source.rule, goal: goal, item: nil, source: source, now: now)
                guard let at = index(of: match.ref) else {
                    plan.adds.append(NewItem(
                        title: match.title,
                        sourced: GoalItem.Sourced(
                            source: source.id, ref: match.ref, kind: match.kind, url: match.url, author: match.author,
                            rule: source.rule
                        ),
                        reason: "from \(source.label)", evidence: fresh
                    ))
                    continue
                }
                var item = items[at]
                let before = item
                var sourced = item.sourced ?? GoalItem.Sourced(
                    source: source.id, ref: match.ref, kind: match.kind, url: match.url, rule: source.rule
                )
                if sourced.source != source.id, sources.contains(where: { $0.id == sourced.source }),
                   results[sourced.source]?.matches.contains(where: { $0.ref == match.ref }) == true
                {
                    // Its own source found it too: that one keeps it.
                } else {
                    sourced.source = source.id
                    sourced.rule = source.rule
                }
                sourced.left = nil
                sourced.author = match.author ?? sourced.author
                sourced.url = match.url
                item.sourced = sourced
                if !item.linked(linkKind(match.kind)).contains(match.ref) {
                    item.links.append(GoalItem.Link(linkKind(match.kind), match.ref))
                }
                if item != before {
                    items[at] = item
                    plan.updates.append(item)
                }
                let ruled = evidence(match, rule: sourced.rule, goal: goal, item: item.id, source: source, now: now)
                plan.evidence += GoalPulls.fresh(ruled, known: known)
            }
        }
        // The goal's items from a source that ran, which no source matched this time.
        for source in sources {
            guard let result = results[source.id] else { continue }
            for (at, item) in items.enumerated() {
                guard var sourced = item.sourced, sourced.source == source.id, !claimed.contains(sourced.ref)
                else { continue }
                claimed.insert(sourced.ref)
                var updated = item
                if sourced.rule != source.rule {
                    sourced.rule = source.rule
                }
                if let current = result.looked[sourced.ref] {
                    if current.state == .open {
                        if sourced.left == nil { sourced.left = now }
                    } else {
                        sourced.left = nil
                    }
                    plan.evidence += GoalPulls.fresh(
                        evidence(current, rule: sourced.rule, goal: goal, item: item.id, source: source, now: now),
                        known: known
                    )
                } else if sourced.left == nil, !finished(item, known: known) {
                    sourced.left = now
                }
                updated.sourced = sourced
                if updated != item {
                    items[at] = updated
                    plan.updates.append(updated)
                }
            }
        }
        return plan
    }

    /// The refs of a source's items to look up by number on a sync: those it has that are not done with yet. One
    /// that merged or closed is not asked about again.
    public static func lookups(source: ItemSource, items: [GoalItem], evidence known: [GoalEvidence]) -> [String] {
        items.compactMap { item in
            guard let sourced = item.sourced, sourced.source == source.id, !finished(item, known: known) else {
                return nil
            }
            return sourced.ref
        }
    }

    /// Whether its PR merged or closed, or its issue closed, as far as its evidence says.
    static func finished(_ item: GoalItem, known: [GoalEvidence]) -> Bool {
        let mine = known.filter { $0.item == item.id }
        if mine.contains(where: { $0.kind == .merged && $0.state == .done }) { return true }
        let newest = mine.filter { $0.kind == .pr || $0.kind == .issue }.max { Stages.newer($1, than: $0) }
        guard let newest else { return false }
        return newest.kind == .issue ? newest.state == .done : newest.text.hasSuffix("closed without merging")
    }

    static func linkKind(_ kind: GoalItem.Sourced.Kind) -> GoalItem.Link.Kind { kind == .pr ? .pr : .issue }

    /// What a PR or issue shows: its state (as `GoalPulls` says a PR's), your review of a PR, and whether the
    /// source's rule is met (`criterion`: done, or in progress when it is not or no longer).
    public static func evidence(
        _ match: SourceMatch, rule: ItemSource.Rule, goal: String, item: String?, source: ItemSource, now: Date
    ) -> [GoalEvidence] {
        func entry(_ kind: GoalEvidence.Kind, _ state: GoalEvidence.State, _ text: String, from: String? = nil)
            -> GoalEvidence
        {
            GoalEvidence(
                goal: goal, item: item, kind: kind, state: state, at: now, source: from ?? match.number, text: text,
                ref: match.ref
            )
        }
        var found: [GoalEvidence] = []
        switch match.kind {
        case .pr:
            let source = match.number
            switch match.state {
            case .merged: found += [entry(.pr, .done, "\(source) merged"), entry(.merged, .done, "\(source) merged")]
            case .closed: found.append(entry(.pr, .issue, "\(source) closed without merging"))
            case .open:
                let checks = match.checks ?? CheckSummary()
                if checks.failed > 0 {
                    found.append(entry(.pr, .issue, "\(source) open · CI failing"))
                } else if match.isDraft {
                    found.append(entry(.pr, .inProgress, "\(source) draft"))
                } else {
                    let ci = checks.pending > 0 ? "CI running" : checks.passed > 0 ? "CI ok" : "open"
                    found.append(entry(.pr, .done, "\(source) open · \(ci)"))
                }
            }
            if let review = match.review {
                found.append(match.reReview
                    ? entry(.codeReview, .inProgress, "\(source) review re-requested", from: "you")
                    : entry(
                        .codeReview, review == .changesRequested ? .issue : .done, "\(source) \(review.words) by you",
                        from: "you"
                    ))
            }
        case .issue:
            found.append(entry(
                .issue, match.state == .open ? .inProgress : .done,
                "\(match.number) \(match.state == .open ? "open" : "closed")"
            ))
        }
        let met = met(rule, match)
        let waiting = rule == .reviewed && match.reReview ? "\(match.number) review re-requested"
            : "\(match.number) not \(match.kind == .issue ? "closed" : rule.phrase) yet"
        found.append(entry(
            .criterion, met == nil ? .inProgress : .done, met.map { "\(match.number) \($0)" } ?? waiting,
            from: source.label
        ))
        return found
    }

    /// Whether `match` is done by `rule`, and how, in words; nil while it is not. A PR or issue that closed is done
    /// whatever the rule: nothing is left to do on it.
    public static func met(_ rule: ItemSource.Rule, _ match: SourceMatch) -> String? {
        switch match.state {
        case .merged: return "merged"
        case .closed: return match.kind == .pr ? "closed without merging" : "closed"
        case .open:
            guard match.kind == .pr else { return nil }
            switch rule {
            case .merged, .closed: return nil
            // Asked again after you reviewed: "review all PRs" means the ask that is open now.
            case .reviewed: return match.reReview ? nil : match.review.map { "reviewed by you (\($0.words))" }
            case .green: return match.green ? "green" : nil
            }
        }
    }
}
