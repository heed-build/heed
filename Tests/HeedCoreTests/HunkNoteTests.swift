import Foundation
@testable import HeedCore
import Testing

struct HunkNoteTests {
    let repo = Repo(org: "acme", name: "app")

    func lines(_ count: Int, from start: Int = 10) -> [DiffLine] {
        (0 ..< count).map { offset in
            DiffLine(
                kind: offset % 3 == 0 ? .added : .context, oldNumber: start + offset, newNumber: start + offset,
                text: "line \(offset)"
            )
        }
    }

    @Test func aNoteIsQueuedWithItsHunk() {
        let hunk = [
            DiffLine(kind: .context, oldNumber: 76, newNumber: 76, text: "{"),
            DiffLine(kind: .deleted, oldNumber: 77, newNumber: nil, text: "old()"),
            DiffLine(kind: .added, oldNumber: nil, newNumber: 77, text: "new()"),
        ]
        let note = FeedbackItem.note(
            "  Lowercase it once.\n", path: "src/File.cs", line: 77, repo: repo, lines: hunk, id: "note:1"
        )
        #expect(note.status == .queued)
        #expect(note.text == "Lowercase it once.")
        #expect(note.kind == .note(path: "src/File.cs", line: 77, repo: repo))
        #expect(note.hunk == [" {", "-old()", "+new()"])
        #expect(note.noteLocation == "src/File.cs:77")
        #expect(note.promptLine == "src/File.cs:77 (you): Lowercase it once.\n```diff\n {\n-old()\n+new()\n```")
    }

    @Test func aLongHunkKeepsTheLinesAroundTheCursor() {
        let note = FeedbackItem.note("x", path: "a", line: 50, repo: nil, lines: lines(60), focus: 40)
        #expect(note.hunk?.count == FeedbackItem.noteHunkLimit)
        #expect(note.hunk?.first?.hasSuffix("line 30") == true)
        let end = FeedbackItem.note("x", path: "a", line: 69, repo: nil, lines: lines(60), focus: 59)
        #expect(end.hunk?.last?.hasSuffix("line 59") == true)
        let top = FeedbackItem.note("x", path: "a", line: 10, repo: nil, lines: lines(60))
        #expect(top.hunk?.first?.hasSuffix("line 0") == true)
    }

    @Test func aPullPromptPutsEachItemOnItsLineOnceANoteQuotesAHunk() {
        let ref = PullRef(repo: repo, number: 7)
        var pipeline = PullFeedback(ref: ref, items: [
            FeedbackItem(id: "t1", kind: .review(location: "A.cs:3", author: "rev"), text: "Rename", status: .queued),
        ])
        #expect(pipeline.prompt() == "Review feedback on PR #7: address each item, run the tests, then push. "
            + "1) A.cs:3 (@rev): Rename")
        pipeline.items.append(.note("Test it", path: "B.cs", line: 4, repo: repo, lines: lines(1), id: "note:1"))
        #expect(pipeline.prompt() == "Review feedback on PR #7: address each item, run the tests, then push. "
            + "1) A.cs:3 (@rev): Rename\n2) B.cs:4 (you): Test it\n```diff\n+line 0\n```")
    }

    @Test func gitHubNeverResolvesANote() throws {
        let ref = PullRef(repo: repo, number: 7)
        var pipeline = PullFeedback(ref: ref, items: [.note("x", path: "a", line: 1, repo: repo, lines: [])])
        let detail = PullDetail(
            ref: ref, title: "", body: "", author: nil, baseBranch: "main", headBranch: "b", additions: 0,
            deletions: 0, commitCount: 1, headSHA: "abc", reviews: [], threads: [], failingChecks: [],
            checks: CheckSummary(), closes: [], fetchedAt: Date()
        )
        pipeline.merge(detail)
        #expect(pipeline.items[0].status == .queued)
        #expect(CopilotAsk.items(pipeline, settings: PilotSettings(), everything: true).isEmpty)
    }

    @Test func sessionNotesPromptAndSend() {
        var notes: [FeedbackItem] = [
            .note("One", path: "a", line: 1, repo: repo, lines: [], id: "note:1"),
            .note("Two", path: "b", line: 2, repo: repo, lines: [], id: "note:2"),
        ]
        notes[1].status = .new
        #expect(SessionNotes.prompt(notes) == "Feedback on your changes: address each item, then run the tests. "
            + "1) a:1 (you): One")
        SessionNotes.markSent(&notes)
        #expect(notes.map(\.status) == [.sent, .new])
        #expect(SessionNotes.prompt(notes) == nil)
    }

    @Test func notesMoveToTheSessionsPullOnceItTracksOne() {
        let other = Repo(org: "acme", name: "docs")
        var session = Session(
            title: "t",
            repos: [repo, other],
            branch: "b",
            agent: "claude",
            state: ObservedState(.idle)
        )
        session.notes = [
            .note("app", path: "a", line: 1, repo: repo, lines: [], id: "note:1"),
            .note("docs", path: "d", line: 1, repo: other, lines: [], id: "note:2"),
        ]
        #expect(SessionNotes.adopt(&session, into: [:]).isEmpty)
        let ref = PullRef(repo: repo, number: 3)
        session.track(ref, because: "test")
        var domain = Domain()
        domain.apply(.sessionUpserted(session))
        #expect(domain.feedback[ref.description]?.items.map(\.id) == ["note:1"])
        #expect(domain.sessions[0].notes.map(\.id) == ["note:2"])
    }

    @Test func aClosedPullDoesNotTakeNotes() {
        var session = Session(title: "t", repos: [repo], branch: "b", agent: "claude", state: ObservedState(.idle))
        let old = PullRef(repo: repo, number: 1)
        let new = PullRef(repo: repo, number: 2)
        session.trackedPRs = [old, new]
        #expect(SessionNotes.pull(for: repo, in: session) == new)
        #expect(SessionNotes.pull(for: repo, in: session) { $0 != new } == old)
        #expect(SessionNotes.pull(for: Repo(org: "x", name: "y"), in: session) == nil)
    }

    @Test func sessionsCachedBeforeNotesStillLoadAndNotesRoundTrip() throws {
        var session = Session(title: "t", repos: [repo], branch: "b", agent: "claude", state: ObservedState(.idle))
        let encoder = JSONEncoder()
        var json = try #require(JSONSerialization.jsonObject(with: encoder.encode(session)) as? [String: Any])
        json["notes"] = nil
        let old = try JSONDecoder().decode(Session.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(old.notes.isEmpty)
        session.notes = [.note("x", path: "a", line: 1, repo: repo, lines: lines(2), id: "note:1")]
        let back = try JSONDecoder().decode(Session.self, from: encoder.encode(session))
        #expect(back.notes == session.notes)
    }

    @Test func theCommentBoxTypesQueuesAndCancels() {
        var draft = HunkNoteDraft(fileID: "f", hunk: 0, row: 3, path: "a", line: 1, repo: nil)
        #expect(draft.handle(KeyStroke("CR")) == .handled)
        for key in ["H", "i"] {
            _ = draft.handle(KeyStroke(key))
        }
        _ = draft.handle(KeyStroke("Space"))
        _ = draft.handle(KeyStroke("CR", .shift))
        _ = draft.handle(KeyStroke("j"))
        #expect(draft.text == "Hi \nj")
        _ = draft.handle(KeyStroke("BS"))
        #expect(draft.text == "Hi \n")
        #expect(draft.handle(KeyStroke("CR")) == .queue(send: false))
        #expect(draft.handle(KeyStroke("CR", .command)) == .queue(send: true))
        #expect(draft.handle(.escape) == .cancel)
    }

    @Test func hunksCountTheirUnsentNotes() {
        let file = FileDiff(
            repo: repo, path: "a", oldPath: nil, status: .modified,
            hunks: [
                Hunk(header: "@@", oldStart: 10, newStart: 10, lines: lines(5)),
                Hunk(header: "@@", oldStart: 40, newStart: 40, lines: lines(5, from: 40)),
            ],
            binary: false, staged: false
        )
        var sent = FeedbackItem.note("s", path: "a", line: 41, repo: repo, lines: [])
        sent.status = .sent
        let notes: [FeedbackItem] = [
            .note("1", path: "a", line: 12, repo: repo, lines: []),
            .note("2", path: "a", line: 42, repo: repo, lines: []),
            .note("3", path: "a", line: 44, repo: repo, lines: []),
            .note("elsewhere", path: "b", line: 12, repo: repo, lines: []),
            sent,
        ]
        #expect(file.noteCounts(notes) == [0: 1, 1: 2])
    }
}
