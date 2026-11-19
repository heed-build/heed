import Foundation

public enum BrowseSort: String, CaseIterable, Hashable, Sendable, Codable {
    case updated, created, comments, oldest
}

/// Local filtering, sorting and counting over the items heed holds: the cached answer of GitHub's search, narrowed
/// by a query's tokens without another call. GitHub stays the judge of what a search returns; this only narrows.
public struct BrowseFilter: Hashable, Sendable {
    public var query: BrowseQuery
    /// Your login, which `@me` stands for.
    public var viewer: String?
    public var maxAgeDays: Int
    /// heed's reads by item id, for the filters on class, size and agent-ready.
    public var reads: BrowseReads

    public init(query: BrowseQuery, viewer: String? = nil, maxAgeDays: Int = 90, reads: BrowseReads = [:]) {
        self.query = query
        self.viewer = viewer
        self.maxAgeDays = maxAgeDays
        self.reads = reads
    }

    public func matches(_ item: BrowseItem, now: Date) -> Bool {
        if let scope = query.scope, !scope.contains(item) { return false }
        if query.isCapped(maxAgeDays: maxAgeDays), let cutoff = AttentionAge.cutoff(days: maxAgeDays, now: now),
           item.updatedAt < cutoff { return false }
        return query.tokens.allSatisfy { matches(item, $0, now: now) }
    }

    private func login(_ value: String) -> String {
        (value == "@me" ? viewer ?? value : value).lowercased()
    }

    private func matches(_ item: BrowseItem, _ token: BrowseToken, now: Date) -> Bool {
        func within(_ date: Date, _ span: BrowseSpan) -> Bool {
            switch span {
            case let .newerThan(days): date >= dayStart(now.addingTimeInterval(-TimeInterval(days) * 86400))
            case let .olderThan(days): date < dayStart(now.addingTimeInterval(-TimeInterval(days) * 86400))
            }
        }
        let labels = Set(item.labels.map { $0.lowercased() })
        switch token {
        case let .type(type): return item.kind == (type == .issues ? .issue : .pull)
        case let .state(state): return item.state.rawValue == state.rawValue
        case let .label(mode, names):
            let wanted = names.map { $0.lowercased() }
            switch mode {
            case .any: return wanted.isEmpty || wanted.contains { labels.contains($0) }
            case .all: return wanted.allSatisfy { labels.contains($0) }
            case .none: return !wanted.contains { labels.contains($0) }
            }
        case let .repo(value): return item.repo.slug.lowercased() == value.lowercased()
        case let .org(value): return item.repo.org.lowercased() == value.lowercased()
        case let .assignee(value): return item.assignees.contains { $0.lowercased() == login(value) }
        case let .author(value): return item.author?.lowercased() == login(value)
        case let .milestone(value): return item.milestone?.lowercased() == value.lowercased()
        case let .project(value):
            return item.projects
                .contains {
                    value.lowercased().hasSuffix("/" + $0.lowercased()) || $0.lowercased() == value.lowercased()
                }
        case let .created(span): return within(item.createdAt, span)
        case let .activity(span): return within(item.updatedAt, span)
        case let .linkedPull(linked): return item.hasLinkedPull == linked
        case let .text(text):
            return text.split(separator: " ")
                .allSatisfy { item.title.contains(String($0)) || item.place.localizedCaseInsensitiveContains($0) }
        // What an item does not say (its repo's language, whether it is archived) is GitHub's to judge, as with `raw`.
        case .raw, .language, .archived: return true
        case let .heedClass(classes): return reads[item.id].map { classes.contains($0.kind) } ?? false
        case let .heedSize(sizes): return reads[item.id].map { sizes.contains($0.size) } ?? false
        case let .heedReady(least): return reads[item.id].map { $0.agentReady >= least } ?? false
        }
    }

    private func dayStart(_ date: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.startOfDay(for: date)
    }

    /// The items the query keeps, in `sort` order.
    public func apply(to items: [BrowseItem], sort: BrowseSort = .updated, now: Date) -> [BrowseItem] {
        sort.sorted(items.filter { matches($0, now: now) })
    }
}

public extension BrowseSort {
    /// `items` in this order; ties fall to the id, so the order is the same every time.
    func sorted(_ items: [BrowseItem]) -> [BrowseItem] {
        switch self {
        case .updated: items.sorted { ($0.updatedAt, $1.id) > ($1.updatedAt, $0.id) }
        case .created: items.sorted { ($0.createdAt, $1.id) > ($1.createdAt, $0.id) }
        case .comments: items.sorted { ($0.comments, $0.updatedAt, $1.id) > ($1.comments, $1.updatedAt, $0.id) }
        case .oldest: items.sorted { ($0.updatedAt, $0.id) < ($1.updatedAt, $1.id) }
        }
    }
}

/// How many items each value of a field has: what the filter menus and the rail show beside a name.
public struct BrowseFacets: Equatable, Sendable {
    public var repos: [String: Int] = [:]
    public var orgs: [String: Int] = [:]
    public var labels: [String: Int] = [:]
    public var authors: [String: Int] = [:]
    public var assignees: [String: Int] = [:]
    public var milestones: [String: Int] = [:]
    public var projects: [String: Int] = [:]
    public var issues = 0
    public var pulls = 0
    public var classes: [BrowseClass: Int] = [:]
    public var sizes: [BrowseSize: Int] = [:]
    /// Items heed has read, and those it has read as ready at `BrowseRead.readyLine` or more.
    public var read = 0
    public var ready = 0

    public init(of items: [BrowseItem], reads: BrowseReads = [:]) {
        for item in items {
            repos[item.repo.slug, default: 0] += 1
            orgs[item.repo.org, default: 0] += 1
            for label in item.labels {
                labels[label, default: 0] += 1
            }
            if let author = item.author { authors[author, default: 0] += 1 }
            for assignee in item.assignees {
                assignees[assignee, default: 0] += 1
            }
            if let milestone = item.milestone { milestones[milestone, default: 0] += 1 }
            for project in item.projects {
                projects[project, default: 0] += 1
            }
            if item.kind == .issue { issues += 1 } else { pulls += 1 }
            if let read = reads[item.id] {
                self.read += 1
                classes[read.kind, default: 0] += 1
                sizes[read.size, default: 0] += 1
                if read.agentReady >= BrowseRead.readyLine { ready += 1 }
            }
        }
    }

    /// The most common values first, ties by name.
    public static func ranked(_ counts: [String: Int]) -> [(name: String, count: Int)] {
        counts.map { (name: $0.key, count: $0.value) }.sorted {
            $0.count == $1.count ? $0.name.lowercased() < $1.name.lowercased() : $0.count > $1.count
        }
    }
}

public extension BrowseFilter {
    /// How many items a scope or a saved query holds in `items`, for the rail's counts.
    static func count(
        _ query: BrowseQuery,
        in items: [BrowseItem],
        viewer: String?,
        maxAgeDays: Int,
        now: Date,
        reads: BrowseReads = [:]
    ) -> Int {
        let filter = BrowseFilter(query: query, viewer: viewer, maxAgeDays: maxAgeDays, reads: reads)
        return items.count(where: { filter.matches($0, now: now) })
    }
}
