import Foundation

/// What the inspector says about a session beyond its own facts: what it is about, what was decided around it, what was
/// left open, and which other sessions work on the same files.
public enum SessionContext {
    /// A few lines on what the session is about: its ledger summary while that is newer than its last activity, else
    /// the start of what its agent said last. Nil when there is neither.
    public static func summary(of session: Session, entry: LedgerEntry?) -> String? {
        if let entry, let summary = entry.summary?.trimmingCharacters(in: .whitespacesAndNewlines), !summary.isEmpty,
           (entry.summarizedAt ?? .distantPast) >= session.lastActivity.addingTimeInterval(-3600)
        {
            return clip(summary)
        }
        guard let last = session.lastMessage?.trimmingCharacters(in: .whitespacesAndNewlines), !last.isEmpty
        else { return entry?.summary.map(clip) }
        return clip(last)
    }

    /// At most three sentences, at most 280 characters, one paragraph.
    static func clip(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("```") }.joined(separator: " ")
        var sentences: [String] = []
        var current = ""
        for character in flat {
            current.append(character)
            if ".!?".contains(character) {
                sentences.append(current.trimmingCharacters(in: .whitespaces))
                current = ""
                if sentences.count == 3 { break }
            }
        }
        if sentences.count < 3, !current.trimmingCharacters(in: .whitespaces).isEmpty {
            sentences.append(current.trimmingCharacters(in: .whitespaces))
        }
        let joined = sentences.joined(separator: " ")
        return joined.count > 280 ? String(joined.prefix(279)) + "…" : joined
    }

    /// The decisions that stand where the session's work is placed: its campaign's (and what rose to it), else its own
    /// work node's. Pinned first.
    public static func decisions(for session: Session, in tree: MindmapTree) -> [MindNode.Decision] {
        guard let work = tree.work(for: session.id) else { return [] }
        let campaign = tree.path(to: work.id).last { $0.kind == .campaign }
        let decided = tree.decisions(of: campaign?.id ?? work.id).shown.filter { $0.supersededBy == nil }
        return decided.filter(\.pinned) + decided.filter { !$0.pinned }
    }

    /// What is left open around the session's work, with the node each item lives on (to mark it done there): its own
    /// first, then the rest of its campaign's.
    public static func looseEnds(for session: Session, in tree: MindmapTree) -> [(
        node: String,
        item: MindNode.OpenItem
    )] {
        guard let work = tree.work(for: session.id) else { return [] }
        let campaign = tree.path(to: work.id).last { $0.kind == .campaign }
        let own = work.stillOpen.map { (work.id, $0) }
        guard let campaign else { return own }
        let others = ([campaign] + tree.descendants(of: campaign.id)).filter { $0.id != work.id }
            .flatMap { node in node.stillOpen.map { (node.id, $0) } }
        return own + others
    }

    /// One prompt that hands the agent loose ends to tackle.
    public static func tackle(_ items: [MindNode.OpenItem]) -> String {
        let lines = items.enumerated().map { "\($0.offset + 1)) \($0.element.text) (\($0.element.kind.rawValue))" }
        return "Loose ends heed found around this work. Tackle them, or say why one should stay open: "
            + lines.joined(separator: " ")
    }

    /// Other open sessions whose worktrees change the same files as this one's (in the same repo), with those files.
    public static func overlaps(
        of session: Session, sessions: [Session], worktrees: [Worktree]
    ) -> [(session: Session, files: [String])] {
        func changed(_ owner: Session) -> [Repo: Set<String>] {
            var files: [Repo: Set<String>] = [:]
            for worktree in worktrees where owner.owns(worktree) {
                files[worktree.repo, default: []].formUnion(worktree.status?.paths ?? [])
            }
            return files
        }
        let mine = changed(session)
        guard !mine.values.allSatisfy(\.isEmpty) else { return [] }
        return sessions.compactMap { other in
            guard other.id != session.id, !other.isChat else { return nil }
            let shared = changed(other).flatMap { repo, files in files.intersection(mine[repo] ?? []) }.sorted()
            return shared.isEmpty ? nil : (other, shared)
        }
    }
}
