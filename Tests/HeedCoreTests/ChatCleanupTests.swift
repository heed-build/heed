import Foundation
@testable import HeedCore
import Testing

/// The cleanup sweep removes closed chats' scratch folders a month after they closed: never a pinned chat's, never a
/// folder you picked, never anything outside the chats root, and only while the sweep is on.
struct ChatCleanupTests {
    private let now = Date()
    private let root = "/chats"
    private let on = CleanupRule(enabled: true)

    private func closed(
        _ id: String, daysAgo: Double, kind: ChatFolder.Kind = .scratch, path: String? = nil, pinned: Bool = false,
        host: String? = nil
    ) -> HistoryEntry {
        var session = Session(
            id: id, title: id, repos: [], branch: "", agent: "claude", state: .init(.done), pinned: pinned,
            workspace: .chat(ChatFolder(kind, path: path ?? "\(root)/2026-09-01-\(id)"))
        )
        session.host = host
        return HistoryEntry(session: session, closedAt: now.addingTimeInterval(-daysAgo * 86400), outcome: .closed)
    }

    private func plan(_ history: [HistoryEntry], rule: CleanupRule? = nil) -> SweepPlan {
        Sweep.plan(domain: Domain(history: history), rule: rule ?? on, now: now, chatsRoot: root)
    }

    @Test func oldScratchFoldersGoAndEverythingElseStays() {
        let removals = plan([
            closed("old", daysAgo: 31),
            closed("recent", daysAgo: 29),
            closed("pinned", daysAgo: 90, pinned: true),
            closed("picked", daysAgo: 90, kind: .folder, path: "/Users/you/Documents/receipts"),
            closed("outside", daysAgo: 90, path: "/Users/you/somewhere/else"),
            closed("nested", daysAgo: 90, path: "\(root)/a/b"),
            closed("remote", daysAgo: 90, path: "~/.heed/chats/x", host: "lab"),
        ]).chatRemovals
        #expect(removals.map(\.id) == ["old"])
        #expect(removals.first?.closedDays == 31)
        #expect(removals.first?.name == "2026-09-01-old")
    }

    @Test func theSweepOffRemovesNothing() {
        #expect(plan([closed("old", daysAgo: 90)], rule: CleanupRule(enabled: false)).chatRemovals.isEmpty)
    }

    @Test func theSweepSaysWhatItRemoves() {
        let only = plan([closed("old", daysAgo: 90)])
        #expect(!only.isEmpty)
        #expect(only.summary == "The sweep removes 1 chat scratch folder.")
    }

    @Test func onlyFoldersDirectlyUnderTheRootAreScratch() {
        #expect(Chats.isScratch("/chats/x", root: "/chats"))
        #expect(Chats.isScratch("/chats/x", root: "/chats/"))
        #expect(!Chats.isScratch("/chats", root: "/chats"))
        #expect(!Chats.isScratch("/chats/", root: "/chats"))
        #expect(!Chats.isScratch("/chats/..", root: "/chats"))
        #expect(!Chats.isScratch("/chats/a/b", root: "/chats"))
        #expect(!Chats.isScratch("/chatsx/a", root: "/chats"))
        #expect(!Chats.isScratch("/chats/a", root: ""))
    }

    @Test func removingAFolderNotesItSoTheNextSweepSkipsIt() throws {
        let base = NSTemporaryDirectory() + "heed-chat-sweep-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: base) }
        let folder = "\(base)/2026-09-01-old"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try "x".write(toFile: folder + "/notes.md", atomically: true, encoding: .utf8)
        let outside = NSTemporaryDirectory() + "heed-not-a-chat-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: outside) }
        let entry = closed("old", daysAgo: 40, path: folder)
        let domain = Domain(history: [entry])
        let planned = Sweep.plan(domain: domain, rule: on, now: now, chatsRoot: base)
        #expect(planned.chatRemovals.count == 1)
        // A removal naming a folder outside the root is refused, even if a plan said so.
        let forged = SweepPlan.ChatRemoval(id: "x", title: "x", path: outside, closedDays: 99)
        let (changes, failures) = Sweep.removeChatFolders(
            planned.chatRemovals + [forged],
            domain: domain,
            chatsRoot: base
        )
        #expect(!FileManager.default.fileExists(atPath: folder))
        #expect(FileManager.default.fileExists(atPath: outside))
        #expect(failures.count == 1)
        let after = domain.applying(changes)
        #expect(after.history.first?.session.timeline.last?.text == Sweep.chatRemovedNote)
        #expect(Sweep.plan(domain: after, rule: on, now: now, chatsRoot: base).chatRemovals.isEmpty)
        // Gone already (deleted by hand): counted as removed, not a failure.
        #expect(Sweep.removeChatFolders(planned.chatRemovals, domain: domain, chatsRoot: base).failures.isEmpty)
    }

    @Test func theSweepsNoteOutlivesARestart() async throws {
        let entry = closed("old", daysAgo: 40)
        var updated = entry
        updated.session.record(Sweep.chatRemovedNote, at: now)
        let before = Domain(history: [entry])
        let writes = DomainEvents.writes(before: before, changes: [.historyUpdated(updated)], now: now)
        let notes = writes.flatMap { write -> [LoggedEvent] in if case let .events(e) = write { e } else { [] } }
        #expect(notes.map(\.text) == [Sweep.chatRemovedNote])
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-sweep-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let log = try EventLog(path: dir.appendingPathComponent("heed.sqlite").path)
        await log.write([.closed(entry)] + writes)
        // What the next launch reads back: the note is there, so the sweep does not list the folder again.
        let history = try await log.history()
        #expect(history.first?.session.timeline.last?.text == Sweep.chatRemovedNote)
        #expect(Sweep.plan(domain: Domain(history: history), rule: on, now: now, chatsRoot: root).chatRemovals.isEmpty)
    }

    @Test func aScratchChatsMenuDeletesItsFolderAPickedOneHasNoDelete() {
        var facts = ContextMenus.SessionFacts(id: "c", title: "Cron")
        facts.chat = true
        facts.scratch = true
        let items = ContextMenus.session(facts).compactMap { if case let .item(item) = $0 { item } else { nil } }
        #expect(items.last?.title == "Delete with its scratch folder…")
        #expect(items.last?.command.name == "session.delete")
        facts.scratch = false
        let picked = ContextMenus.session(facts).compactMap { if case let .item(item) = $0 { item } else { nil } }
        #expect(!picked.contains { $0.command.name == "session.delete" })
    }
}
