import Foundation

/// When you last looked: at each thread (opened in Attention's reader), and at Attention as a whole (when you last
/// left it). What tells New since from Waiting on you, and where the reader folds the comments you read.
public struct AttentionSeen: Hashable, Sendable {
    /// By item id (`AttentionItem.id`, which is `ThreadConversation.key` for an issue or PR).
    public var threads: [String: Date]
    /// When you last left Attention: the "since" of New since.
    public var leftAt: Date?

    public init(threads: [String: Date] = [:], leftAt: Date? = nil) {
        self.threads = threads
        self.leftAt = leftAt
    }

    /// When you last looked at the item: in the reader, or at Attention, whichever is later; nil when never.
    public func since(_ id: String) -> Date? {
        switch (threads[id], leftAt) {
        case let (thread?, left?): max(thread, left)
        case let (thread, left): thread ?? left
        }
    }

    /// Whether someone other than you did something in it since you last looked (`AttentionActivity.isNew`): a
    /// thread you never looked at, in an Attention you never left, is new when anyone but you is in it.
    public func isNew(_ item: AttentionItem) -> Bool {
        AttentionActivity.isNew(item, since: since(item.id) ?? .distantPast)
    }
}

/// A thread shown in Attention's reader, from when it showed: whether leaving it counts as having read it.
public struct AttentionVisit: Hashable, Sendable {
    public var id: String
    public var startedAt: Date
    /// Opened on purpose: a click on its row, or ↩.
    public var opened: Bool

    /// How long a thread has to stay in the reader to count as read when you only moved onto it with j or k.
    public static let dwell: TimeInterval = 2

    public init(id: String, startedAt: Date, opened: Bool = false) {
        self.id = id
        self.startedAt = startedAt
        self.opened = opened
    }

    /// What leaving it at `now` records as when you looked: the time it showed, once you opened it or it stayed
    /// `dwell`; nil when you only passed over it. What came in while you read stays new.
    public func seen(leavingAt now: Date) -> Date? {
        opened || now.timeIntervalSince(startedAt) >= Self.dwell ? startedAt : nil
    }
}

/// What a row says under its title, besides its reasons.
public enum AttentionPreview: Hashable, Sendable {
    /// The newest comment: who and its first line.
    case comment(author: String, text: String)
    /// The model's summary, its first line.
    case summary(String)
    /// You looked and nobody did anything since.
    case nothingNew(since: Date)

    /// The newest comment when it is new to you (or you never looked), else the summary, else that nothing is new
    /// since you looked; nil when there is nothing to say (the reasons say it).
    public static func of(
        _: AttentionItem, detail: ThreadDetail?, summary: String?, isNew: Bool, seenAt: Date?
    ) -> AttentionPreview? {
        if isNew || seenAt == nil, let comment = detail?.comments.last,
           let line = comment.text.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty
        {
            return .comment(author: comment.author, text: line)
        }
        if let line = summary?.split(whereSeparator: \.isNewline).first.map(String.init), !line.isEmpty {
            return .summary(line)
        }
        if !isNew, let seenAt { return .nothingNew(since: seenAt) }
        return nil
    }
}

/// What Attention lists under a tab, in its sections. For you has three: New since you last looked (activity by
/// someone else since), Waiting on you (an open ask with nothing new), and Mentioned before (old mentions and
/// assignments no notification is about: folded, counted). The other tabs are one list.
public struct AttentionListing: Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case new, waiting, before, all
    }

    public struct Section: Hashable, Sendable {
        public var kind: Kind
        /// The index in `rows` of its first row.
        public var start: Int
        /// How many it has, listed or folded.
        public var total: Int
        public var folded: Bool

        /// How many rows it lists.
        public var count: Int { folded ? 0 : total }
        public var range: Range<Int> { start ..< start + count }
    }

    public var rows: [AttentionEntry]
    public var sections: [Section]

    public init(rows: [AttentionEntry], sections: [Section]) {
        self.rows = rows
        self.sections = sections
    }

    public func section(_ kind: Kind) -> Section? { sections.first { $0.kind == kind } }

    /// The ids a section lists (none when folded).
    public func ids(_ kind: Kind) -> [String] {
        section(kind).map { rows[$0.range].map(\.id) } ?? []
    }

    /// The sections that start at row `index` (a header goes above it).
    public func sections(startingAt index: Int) -> [Section] { sections.filter { $0.start == index } }

    /// What `filter` lists, in order. For you's sections are decided by `seen`, which the app holds still while
    /// you are in Attention, so rows do not jump as you read them; `unfoldBefore` lists Mentioned before.
    public static func of(
        _ entries: [AttentionEntry], filter: AttentionFilter, sort: AttentionSort = .recent, seen: AttentionSeen,
        unfoldBefore: Bool = false, now: Date
    ) -> AttentionListing {
        let listed = AttentionRanking.list(entries, filter: filter, sort: sort, now: now)
        guard filter == .forYou else {
            return AttentionListing(rows: listed, sections: [Section(
                kind: .all,
                start: 0,
                total: listed.count,
                folded: false
            )])
        }
        var new: [AttentionEntry] = []
        var waiting: [AttentionEntry] = []
        var before: [AttentionEntry] = []
        for entry in listed {
            if !entry.item.wantsYou {
                before.append(entry)
            } else if seen.isNew(entry.item) {
                new.append(entry)
            } else if entry.item.reasons.contains(where: \.waits) {
                waiting.append(entry)
            }
        }
        var rows: [AttentionEntry] = []
        var sections: [Section] = []
        for (kind, members) in [(Kind.new, new), (.waiting, waiting), (.before, before)] where !members.isEmpty {
            let folded = kind == .before && !unfoldBefore
            sections.append(Section(kind: kind, start: rows.count, total: members.count, folded: folded))
            if !folded { rows += members }
        }
        return AttentionListing(rows: rows, sections: sections)
    }

    /// The count on each tab: For you counts New and Waiting on you (not what is folded), the rest what they list.
    public static func counts(
        _ entries: [AttentionEntry], seen: AttentionSeen, now: Date
    ) -> [AttentionFilter: Int] {
        Dictionary(uniqueKeysWithValues: AttentionFilter.allCases.map { filter in
            let listing = of(entries, filter: filter, seen: seen, now: now)
            let count = filter == .forYou
                ? listing.sections.filter { $0.kind != .before }.map(\.total).reduce(0, +)
                : listing.rows.count
            return (filter, count)
        })
    }
}
