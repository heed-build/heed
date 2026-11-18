import Foundation

/// Items picked in Browse that look like one piece of work: the same repo, the same class (bug, feature, ...) and
/// titles or labels that overlap. A pure function of the picked items and heed's reads of them; no model is asked.
public struct BrowseGroup: Equatable, Sendable {
    public var ids: [String]
    public var repo: Repo
    public var kind: BrowseClass
    /// Labels the members share (the class's own label left out), else the title words they share.
    public var sharedLabels: [String]
    public var sharedWords: [String]
    /// Picked items that are not in the group, by id and place.
    public var apart: [(id: String, place: String, sameRepo: Bool)]

    public static func == (lhs: BrowseGroup, rhs: BrowseGroup) -> Bool {
        lhs.ids == rhs.ids && lhs.repo == rhs.repo && lhs.kind == rhs.kind && lhs.sharedLabels == rhs.sharedLabels
            && lhs.sharedWords == rhs.sharedWords && lhs.apart.map(\.id) == rhs.apart.map(\.id)
    }

    /// `docs-toolkit bugs`: what the group is, for a button's title.
    public var noun: String { "\(repo.name) \(BrowseGrouping.plural(kind))" }

    /// `One session for the 3 docs-toolkit bugs`.
    public var title: String { "One session for the \(ids.count) \(noun)" }
}

public enum BrowseGrouping {
    /// The class heed reads an item as: its read's, else the one its labels name.
    public static func kind(of item: BrowseItem, read: BrowseRead?) -> BrowseClass? {
        if let read { return read.kind }
        for label in item.labels {
            if let kind = BrowseClass(word: label) { return kind }
        }
        return nil
    }

    public static func plural(_ kind: BrowseClass) -> String {
        switch kind {
        case .bug: "bugs"
        case .feature: "features"
        case .docs: "docs issues"
        case .question: "questions"
        case .chore: "chores"
        }
    }

    public static func singular(_ kind: BrowseClass) -> String { kind == .docs ? "docs issue" : kind.rawValue }

    static let stopwords: Set<String> = [
        "when", "with", "that", "this", "from", "into", "have", "does", "should", "after", "before", "over", "under",
        "than", "then", "were", "will", "what", "where", "which", "about", "support", "add", "fix", "make",
    ]

    /// The words of a title that can say two items are about the same thing: four letters or more, no filler, one
    /// trailing `s` dropped.
    public static func words(_ title: String) -> Set<String> {
        var found = Set<String>()
        var current = ""
        func flush() {
            if current.count >= 4, !stopwords.contains(current) {
                found.insert(current.hasSuffix("s") && current.count > 4 ? String(current.dropLast()) : current)
            }
            current = ""
        }
        for character in title.lowercased() {
            if character.isLetter || character.isNumber { current.append(character) } else { flush() }
        }
        flush()
        return found
    }

    /// The largest set of picked issues of one repo and one class that hang together (a shared label or a shared
    /// title word, chained), or nil when no two do. PRs are never grouped: a session closes issues.
    public static func suggest(_ items: [BrowseItem], reads: BrowseReads) -> BrowseGroup? {
        struct Entry {
            var item: BrowseItem
            var kind: BrowseClass
            var labels: Set<String>
            var words: Set<String>
        }
        var buckets: [String: [Entry]] = [:]
        var order: [String] = []
        for item in items where item.kind == .issue {
            guard let kind = kind(of: item, read: reads[item.id]) else { continue }
            let key = "\(item.repo.slug.lowercased())|\(kind.rawValue)"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(Entry(
                item: item, kind: kind, labels: Set(item.labels.map { $0.lowercased() }),
                words: words(item.title.display)
            ))
        }
        var best: [Entry] = []
        for key in order {
            let entries = buckets[key] ?? []
            // Connected components over "shares a label or a word".
            var seen = Set<Int>()
            for start in entries.indices where !seen.contains(start) {
                var component = [start]
                var queue = [start]
                seen.insert(start)
                while let next = queue.popLast() {
                    for other in entries.indices where !seen.contains(other) {
                        let a = entries[next], b = entries[other]
                        if !a.labels.isDisjoint(with: b.labels) || !a.words.isDisjoint(with: b.words) {
                            seen.insert(other)
                            component.append(other)
                            queue.append(other)
                        }
                    }
                }
                if component.count > best.count { best = component.sorted().map { entries[$0] } }
            }
        }
        guard best.count >= 2, let first = best.first else { return nil }
        let kindWord = first.kind.rawValue
        var labels = best.dropFirst().reduce(first.labels) { $0.intersection($1.labels) }
        labels = labels.filter { BrowseClass(word: $0) != first.kind && $0 != kindWord }
        if labels.isEmpty {
            // Labels any two share, as a softer answer.
            var counted: [String: Int] = [:]
            for entry in best {
                for label in entry.labels where BrowseClass(word: label) != first.kind {
                    counted[
                        label,
                        default: 0
                    ] += 1
                }
            }
            labels = Set(counted.filter { $0.value >= 2 }.keys)
        }
        var shared = best.dropFirst().reduce(first.words) { $0.intersection($1.words) }
        if shared.isEmpty {
            var counted: [String: Int] = [:]
            for entry in best {
                for word in entry.words {
                    counted[word, default: 0] += 1
                }
            }
            shared = Set(counted.filter { $0.value >= 2 }.keys)
        }
        let ids = best.map(\.item.id)
        let apart = items.filter { !ids.contains($0.id) }.map {
            (id: $0.id, place: "#\($0.number)", sameRepo: $0.repo == first.item.repo)
        }
        return BrowseGroup(
            ids: ids, repo: first.item.repo, kind: first.kind,
            sharedLabels: labels.sorted(), sharedWords: shared.sorted(), apart: apart
        )
    }

    /// heed's note over the grouping: what it noticed, and what it leaves out. Names numbers, labels and words
    /// only: nothing another person wrote is quoted but single title words.
    public static func note(_ group: BrowseGroup, items: [BrowseItem]) -> String {
        let numbers = group.ids.compactMap { id in items.first { $0.id == id }.map { "#\($0.number)" } }
        var text = "heed noticed \(list(numbers)) are all \(plural(group.kind)) in \(group.repo.name)"
        if let label = group.sharedLabels.first {
            text += " labelled \(label)"
        } else if !group.sharedWords.isEmpty {
            text += " that all mention \(list(group.sharedWords.prefix(2).map { "“\($0)”" }))"
        }
        text += group.kind == .bug ? ", so one session can fix them together." : ", so one session can take them together."
        let elsewhere = group.apart.filter { !$0.sameRepo }
        if let one = elsewhere.first, elsewhere.count == 1 {
            text += " \(one.place) is in another repo."
        } else if elsewhere.count > 1 {
            text += " \(list(elsewhere.map(\.place))) are in other repos."
        }
        return text
    }

    /// `#1`, `#1 and #2`, `#1, #2 and #3`.
    static func list(_ parts: [String]) -> String {
        switch parts.count {
        case 0: ""
        case 1: parts[0]
        default: parts.dropLast().joined(separator: ", ") + " and " + parts[parts.count - 1]
        }
    }

    /// One line from local reads: `4 bugs · size S-M · all agent-ready (64-91%)`. Items heed has not read yet
    /// count as such rather than being guessed at.
    public static func summary(_ items: [BrowseItem], reads: BrowseReads) -> String {
        guard !items.isEmpty else { return "" }
        var parts: [String] = []
        var kinds: [BrowseClass: Int] = [:]
        var unclassed = 0
        for item in items {
            if let kind = kind(of: item, read: reads[item.id]) { kinds[kind, default: 0] += 1 } else { unclassed += 1 }
        }
        var classes = BrowseClass.allCases.compactMap { kind in
            kinds[kind].map { "\($0) \($0 == 1 ? singular(kind) : plural(kind))" }
        }
        if unclassed > 0 { classes.append("\(unclassed) unclassed") }
        parts.append(classes.joined(separator: ", "))
        let read = items.compactMap { reads[$0.id] }
        if !read.isEmpty {
            let sizes = read.map(\.size)
            let low = sizes.min { $0.pips < $1.pips }!, high = sizes.max { $0.pips < $1.pips }!
            parts.append("size " + (low == high ? low.rawValue : "\(low.rawValue)-\(high.rawValue)"))
            let ready = read.map(\.agentReady)
            let span = ready.min() == ready.max() ? "\(ready[0])%" : "\(ready.min()!)-\(ready.max()!)%"
            let good = read.count(where: { $0.agentReady >= BrowseRead.readyLine })
            parts.append(
                (good == items
                    .count ? "all agent-ready" : good == 0 ? "none agent-ready" :
                    "\(good) of \(items.count) agent-ready")
                    + " (\(span))"
            )
        }
        let unread = items.count - read.count
        if unread > 0 { parts.append(read.isEmpty ? "not read yet" : "\(unread) not read yet") }
        return parts.joined(separator: " · ")
    }
}
