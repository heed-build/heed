import Foundation
@testable import HeedCore
import Synchronization
import Testing

/// A stand-in for heed's model calls: answers with `reply`, records what it was asked. No real model is called.
private final class StubModel: Sendable {
    let reply: String
    let fails: Bool
    let requests = Mutex<[LLMRequest]>([])
    init(_ reply: String, fails: Bool = false) {
        self.reply = reply
        self.fails = fails
    }

    var summarizer: Summarizer {
        Summarizer { request in
            self.requests.withLock { $0.append(request) }
            if self.fails { throw LLMError.failed(reasons: ["claude: daily cap"]) }
            return LLMResponse(text: self.reply, agent: "claude", model: "model-h")
        }
    }
}

struct LedgerTests {
    private let repo = Repo(org: "acme", name: "api")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(_ id: String = "s", prs: [PullRef] = []) -> Session {
        var session = Session(
            id: id, title: "Validate redirect anchors", repos: [repo], branch: "fix-anchors", agent: "claude",
            state: ObservedState(.done), trackedPRs: prs, createdAt: now.addingTimeInterval(-7200)
        )
        session.lastMessage = "Added the check and a failing test first. Tests pass."
        session.record("started · claude · 2 panes", at: now.addingTimeInterval(-7200))
        return session
    }

    @Test func parsesTheSections() {
        let parsed = LedgerText.parse("""
        **Summary:** Redirect targets are validated against real headings.
        A failing test names the redirect.

        Decisions:
        - Generate the map at build time
        - Validate anchors in a separate pass
        ## Follow-ups:
        - none
        """)
        #expect(parsed
            .summary == "Redirect targets are validated against real headings. A failing test names the redirect.")
        #expect(parsed.decisions == ["Generate the map at build time", "Validate anchors in a separate pass"])
        #expect(parsed.followUps.isEmpty)
        // No headings at all: it is all summary.
        #expect(LedgerText.parse("Just prose.").summary == "Just prose.")
    }

    @Test func writesWhatTheModelSaidAndAsksForWhatIsIncluded() async throws {
        let model = StubModel("Summary: Added anchor checks.\nDecisions:\n- Build-time map\nFollow-ups:\n- Moved pages")
        let entry = LedgerEntry(id: "s", title: "t", startedAt: now)
        var include = Set(LedgerPart.allCases)
        include.remove(.followUps)
        let written = await Ledger.write(
            entry, inputs: Ledger.inputs(session: session(), git: "abc fix anchors", pulls: []), include: include,
            trigger: .prOpened, summarizer: model.summarizer, instructions: "Mention the ticket.", now: now
        )
        #expect(written.summary == "Added anchor checks.")
        #expect(written.decisions == ["Build-time map"])
        #expect(written.followUps.isEmpty)
        #expect(written.source == .model && written.trigger == "PR opened" && written.summarizedAt == now)
        let request = try #require(model.requests.withLock { $0.first })
        #expect(request.caller == "ledger.pr_opened")
        #expect(request.call.system.contains("Mention the ticket."))
        #expect(request.call.system.contains("Leave these sections out: Follow-ups."))
        #expect(request.call.prompt.contains("Tests pass."))
        #expect(request.call.prompt.contains("abc fix anchors"))
        // Each part left out is left out of the entry, whatever the model still wrote.
        let none = await Ledger.write(
            entry, inputs: SummaryInputs(title: "t"), include: [.summary], trigger: .onDemand,
            summarizer: model.summarizer, instructions: "", now: now
        )
        #expect(none.decisions.isEmpty && none.followUps.isEmpty && none.summary == "Added anchor checks.")
    }

    @Test func aFailedWriteKeepsTheOldSummaryAndSaysWhy() async {
        var entry = LedgerEntry(id: "s", title: "t", startedAt: now)
        entry.summary = "Earlier summary."
        let written = await Ledger.write(
            entry, inputs: SummaryInputs(title: "t"), include: Set(LedgerPart.allCases), trigger: .onDemand,
            summarizer: StubModel("", fails: true).summarizer, instructions: "", now: now
        )
        #expect(written.summary == "Earlier summary.")
        #expect(written.failure?.contains("daily cap") == true)
    }

    @Test func factsComeFromTheSessionAndItsPRs() {
        let pr = PullRef(repo: repo, number: 12)
        var github = GitHubState()
        github.pulls = [PullRequest(
            ref: pr, title: "x", url: "", state: .open, isDraft: false, headBranch: "fix-anchors", review: nil,
            checks: CheckSummary(), unresolvedThreads: 0, updatedAt: now
        )]
        let facts = Ledger.facts(session: session(prs: [pr]), closed: nil, pulls: github, previous: nil)
        #expect(facts.outcome == "PR open" && facts.repos == ["acme/api"] && facts.pulls == [pr])
        let closed = HistoryEntry(session: session(), closedAt: now, outcome: .abandoned)
        var previous = facts
        previous.summary = "kept"
        let after = Ledger.facts(session: session(), closed: closed, pulls: github, previous: previous)
        #expect(after.outcome == "abandoned" && after.endedAt == now && after.summary == "kept")
    }

    @Test func diffStatsParse() {
        #expect(DiffStat.parse(" 9 files changed, 212 insertions(+), 38 deletions(-)")
            == DiffStat(files: 9, added: 212, removed: 38))
        #expect(DiffStat.parse(" 1 file changed, 1 insertion(+)") == DiffStat(files: 1, added: 1, removed: 0))
        #expect(DiffStat.parse("") == nil)
        #expect(DiffStat(files: 9, added: 212, removed: 38).text == "+212 −38 · 9 files")
    }

    @Test func domainChangesAskForSummaries() {
        let pr = PullRef(repo: repo, number: 12)
        let before = Domain(sessions: [session()])
        var after = Domain(sessions: [session(prs: [pr])])
        var settings = LedgerSettings()
        #expect(Ledger.triggers(before: before, after: after, settings: settings).map(\.1) == [.prOpened])
        settings.when.remove(.prOpened)
        #expect(Ledger.triggers(before: before, after: after, settings: settings).isEmpty)
        var merged = after
        merged.github.pulls = [PullRequest(
            ref: pr, title: "x", url: "", state: .merged, isDraft: false, headBranch: "fix-anchors", review: nil,
            checks: CheckSummary(), unresolvedThreads: 0, updatedAt: now
        )]
        #expect(Ledger.triggers(before: after, after: merged, settings: LedgerSettings()).map(\.1) == [.prMerged])
        // A chat closing is off by default.
        var chat = session("c")
        chat.workspace = .chat(ChatFolder(.scratch, path: "/chats/x"))
        let open = Domain(sessions: [chat])
        after = open.applying([.sessionClosed(HistoryEntry(session: chat, closedAt: now, outcome: .closed))])
        #expect(Ledger.triggers(before: open, after: after, settings: LedgerSettings()).isEmpty)
        settings = LedgerSettings()
        settings.when.insert(.chatClosed)
        #expect(Ledger.triggers(before: open, after: after, settings: settings).map(\.1) == [.chatClosed])
    }

    @Test func idleSessionsWithoutAFreshSummary() {
        var quiet = session("quiet")
        quiet.lastActivity = now.addingTimeInterval(-25 * 3600)
        var busy = session("busy")
        busy.lastActivity = now.addingTimeInterval(-3600)
        var written = session("written")
        written.lastActivity = now.addingTimeInterval(-30 * 3600)
        var entry = LedgerEntry(id: "written", title: "t", startedAt: now)
        entry.summarizedAt = now.addingTimeInterval(-26 * 3600)
        let due = Ledger.idle(
            sessions: [quiet, busy, written], entries: ["written": entry], settings: LedgerSettings(), now: now
        )
        #expect(due == ["quiet"])
        var off = LedgerSettings()
        off.idleHours = 0
        #expect(Ledger.idle(sessions: [quiet], entries: [:], settings: off, now: now).isEmpty)
    }

    @Test func removalWaitsForTheSummaryButNotForever() async {
        let order = Mutex<[String]>([])
        await Ledger.summarizeThenRemove(timeout: .seconds(5)) {
            try? await Task.sleep(for: .milliseconds(50))
            order.withLock { $0.append("summary") }
        } remove: {
            order.withLock { $0.append("remove") }
        }
        #expect(order.withLock { $0 } == ["summary", "remove"])

        let slow = Mutex<[String]>([])
        let started = Date()
        await Ledger.summarizeThenRemove(timeout: .milliseconds(100)) {
            try? await Task.sleep(for: .seconds(5))
            slow.withLock { $0.append("summary") }
        } remove: {
            slow.withLock { $0.append("remove") }
        }
        #expect(slow.withLock { $0 } == ["remove"])
        #expect(Date().timeIntervalSince(started) < 2)
    }

    @Test func settingsDecode() {
        let (config, problems) = ConfigLoader.decode("""
        [summary]
        when = ["pr_merged", "chat_closed"]
        idle_hours = 12
        include = ["summary", "files"]
        """)
        #expect(problems.isEmpty)
        #expect(config?.ledger.when == [.prMerged, .chatClosed])
        #expect(config?.ledger.idleHours == 12)
        #expect(config?.ledger.include == [.summary, .files])
        #expect(ConfigLoader.decode("[summary]\nwhen = [\"never\"]\n").problems.count == 1)
        #expect(LedgerSettings().when == [.prOpened, .prMerged, .worktreeRemoved, .idle])
    }

    @Test func entriesRoundTripThroughTheEventLog() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heed-ledger-\(UUID()).sqlite")
        defer { try? FileManager.default.removeItem(at: file) }
        let log = try #require(await EventLog.open(at: file))
        var entry = LedgerEntry(id: "s", title: "t", startedAt: now)
        entry.summary = "one"
        await log.write([.ledger(entry)])
        entry.summary = "two"
        await log.write([.ledger(entry)])
        let read = try await log.ledger()
        #expect(read.map(\.summary) == ["two"])
    }
}

struct LedgerGitTests {
    @Test func readsAWorktreeAndItsArchiveAgainstTheBase() async throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("heed-ledger-git-\(UUID())").path
        defer { try? FileManager.default.removeItem(atPath: base) }
        func git(_ args: [String]) async throws {
            _ = try await ProcessRunner.output("git", ["-C", base] + args, caller: "test")
        }
        try FileManager.default.createDirectory(atPath: base, withIntermediateDirectories: true)
        try "a\n".write(toFile: base + "/a.txt", atomically: true, encoding: .utf8)
        for args in [
            ["init", "-q", "-b", "main"],
            ["config", "user.email", "t@t"],
            ["config", "user.name", "t"],
            ["add", "."],
            ["commit", "-qm", "base"],
            ["checkout", "-qb", "spike"],
        ] {
            try await git(args)
        }
        try "a\nb\nc\n".write(toFile: base + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: base + "/b.txt", atomically: true, encoding: .utf8)
        try await git(["add", "."])
        try await git(["commit", "-qm", "Validate anchors"])
        let read = try #require(await LedgerGit.read(path: base, tip: "spike", base: "main"))
        #expect(read.log.hasSuffix("Validate anchors"))
        #expect(read.diff == DiffStat(files: 2, added: 3, removed: 0))
        #expect(read.files == ["a.txt", "b.txt"])
        #expect(read.text.contains("Diff: +3 −0 · 2 files"))
        #expect(await LedgerGit.read(path: base, tip: "gone", base: "main") == nil)
    }

    @Test func filesAreMostChangedFirst() {
        #expect(LedgerGit.files("1\t1\tsmall.txt\n10\t2\tbig.swift\n-\t-\timage.png") == [
            "big.swift", "small.txt", "image.png",
        ])
    }
}

struct LedgerFixtureTests {
    @Test func theFakeWorldsLedgerIsItsSessions() {
        let domain = Fixtures.main
        let known = Set(domain.sessions.map(\.id) + domain.history.map(\.id))
        for entry in Fixtures.ledger {
            #expect(known.contains(entry.id), "\(entry.id) is not in the fake world")
        }
    }

    @Test func anEntryHasAMenu() {
        let names = ContextMenus.ledger(id: "s", title: "t", reopenable: true, onGitHub: true).compactMap {
            if case let .item(item) = $0 { item.command.name } else { nil }
        }
        #expect(names == ["ledger.summarize", "ledger.edit", "history.reopen", "open.repo", "history.ledger"])
    }
}

struct LedgerFixtureConsistencyTests {
    @Test func listedFilesMatchTheDiff() {
        for entry in Fixtures.ledger where !entry.files.isEmpty {
            #expect(entry.files.count == min(entry.diff?.files ?? 0, Ledger.fileLimit), "\(entry.id)")
        }
    }
}
