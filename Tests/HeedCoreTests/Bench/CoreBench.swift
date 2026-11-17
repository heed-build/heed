import Foundation
@testable import HeedCore
import Testing

/// What the app's hot paths cost in HeedCore, on a world bigger than most: 50 sessions, 300 worktrees, 200 PRs.
/// Each prints its median and slowest; the ceilings are about ten times what each took when written, so they catch a
/// regression,
/// not a slow day.
@Suite(.enabled(if: Bench.enabled), .serialized)
struct CoreBench {
    /// The world the list and Attention are built from, as domain values.
    struct World {
        var sessions: [Session] = []
        var worktrees: [Worktree] = []
        var github = GitHubState(viewer: "me")

        static let shared = World()

        init() {
            let now = Clock.now
            let repos = (0 ..< 20).map { Repo(org: "acme", name: "repo\($0)") }
            let states: [AgentState] = [.working, .idle, .blocked, .asking, .done, .limited, .working, .idle]
            for index in 0 ..< 300 {
                let repo = repos[index % repos.count]
                worktrees.append(Worktree(
                    repo: repo, path: "/src/\(repo.name).worktrees/branch\(index)", branch: "branch\(index)",
                    head: String(format: "%040x", index), isMain: false,
                    status: WorktreeStatus(changedFiles: index % 4, ahead: index % 3)
                ))
            }
            for index in 0 ..< 200 {
                let repo = repos[index % repos.count]
                github.pulls.append(PullRequest(
                    ref: PullRef(repo: repo, number: 1000 + index), title: "Change number \(index)",
                    url: "https://github.com/\(repo.slug)/pull/\(1000 + index)",
                    state: index % 5 == 0 ? .merged : .open, isDraft: index % 7 == 0, headBranch: "branch\(index)",
                    review: index % 6 == 0 ? .changesRequested : nil,
                    checks: CheckSummary(passed: 10, failed: index % 4 == 0 ? 1 : 0),
                    unresolvedThreads: index % 3, updatedAt: now.addingTimeInterval(Double(-index * 600))
                ))
                github.inbox.append(InboxItem(
                    id: "n\(index)", kind: .pr, repo: repo, number: 1000 + index, title: "Change number \(index)",
                    reason: index % 2 == 0 ? "review_requested" : "mention", unread: index % 3 != 0,
                    updatedAt: now.addingTimeInterval(Double(-index * 300)), url: nil
                ))
            }
            for index in 0 ..< 50 {
                let repo = repos[index % repos.count]
                var session = Session(
                    id: "s\(index)", title: "Session \(index)", prompt: "Do thing \(index)", repos: [repo],
                    branch: "branch\(index)", agent: "claude", state: ObservedState(states[index % states.count]),
                    trackedPRs: (0 ..< 4).map { PullRef(repo: repo, number: 1000 + index + $0 * 50) },
                    pinned: index % 10 == 0, parked: index % 9 == 0,
                    lastActivity: now.addingTimeInterval(Double(-index * 120))
                )
                session.worktreePaths = ["/src/\(repo.name).worktrees/branch\(index)"]
                sessions.append(session)
            }
        }
    }

    static func report(_ name: String, _ timing: (median: Double, slowest: Double)) {
        print("\(name): median \(String(format: "%.3f", timing.median * 1000)) ms, slowest "
            + "\(String(format: "%.3f", timing.slowest * 1000)) ms")
    }

    /// As the sidebar builds it on every rebuild: sizes and Can close from the worktrees, like the app's closures.
    @Test func sessionList() {
        let world = World.shared
        let timing = Bench.time(runs: 50) {
            let list = SessionList(world.sessions, size: { session in
                PendingChanges(world.worktrees.filter { session.owns($0) }).lines ?? 0
            }, closable: { session in
                CloseReadiness.check(
                    session, pulls: world.github, pending: PendingChanges(world.worktrees.filter { session.owns($0) }),
                    followUps: nil, group: SessionGroup.of(session)
                ) != nil
            })
            precondition(list.ordered.count == world.sessions.count)
        }
        Self.report("SessionList, 50 sessions × 300 worktrees", timing)
        #expect(timing.median < 0.03, "median \(timing.median)")
    }

    /// Attention's recompute: the feed from the domain, then ranked by the rules.
    @Test func attentionEntries() {
        let world = World.shared
        let rules = AttentionRules(lines: Fixtures.attentionRules)
        let timing = Bench.time(runs: 50) {
            let items = AttentionFeed.items(github: world.github, sessions: world.sessions)
            let entries = AttentionRanking.entries(live: items, rules: rules, marks: [:], viewer: "me", now: Clock.now)
            precondition(!entries.isEmpty)
        }
        Self.report("AttentionFeed.items + AttentionRanking.entries, 200 PRs", timing)
        #expect(timing.median < 0.08, "median \(timing.median)")
    }

    /// The screen-reading tick guesses each session's state from its pane: 50 lines of 200 columns.
    @Test func screenGuess() {
        let patterns = ScreenGuess.patterns(for: AgentProfile(name: "x", command: "x"))
        let line = String(repeating: "output text ", count: 17).prefix(200)
        let screen = Array(repeating: String(line), count: 50).joined(separator: "\n")
        var guessed: AgentState?
        let timing = Bench.time(runs: 100) { guessed = ScreenGuess.guess(screen, patterns: patterns) }
        #expect(guessed == nil)
        Self.report("ScreenGuess.guess, 50×200 screen", timing)
        #expect(timing.median < 0.005, "median \(timing.median)")
    }

    /// A PR body shown by the reader and the card, read through `display` a hundred times.
    @Test func externalTextDisplay() {
        let paragraph = "This changes the parser so tabs count as indentation. See #12 and https://example.com.\n"
        let body = ExternalText(
            String(repeating: paragraph, count: 20 * 1024 / paragraph.utf8.count), source: .pullBody, author: .unknown
        )
        var length = 0
        let timing = Bench.time(runs: 10) {
            for _ in 0 ..< 100 {
                length += body.display.count
            }
        }
        #expect(length > 0)
        Self.report("ExternalText.display, 20 KB × 100", timing)
        #expect(timing.median < 3, "median \(timing.median)")
    }

    /// A review round's prompt: ten comments, each fenced.
    @Test func promptWithTenFences() {
        var prompt: Prompt = "Address the review comments below.\n"
        for index in 0 ..< 10 {
            let comment = ExternalText(
                String(repeating: "Please rename this and add a test for comment \(index). ", count: 20),
                source: .comment, author: ExternalText.Author(login: "reviewer\(index)", trust: .collaborator)
            )
            prompt += "\nComment \(index):\n\(comment)\n"
        }
        var length = 0
        let timing = Bench.time(runs: 100) { length += prompt.text.count }
        #expect(length > 0)
        Self.report("Prompt.text, 10 fences", timing)
        #expect(timing.median < 0.005, "median \(timing.median)")
    }

    /// Audit's book at a busy year: 50k actions under 500 causes, applied and turned into rows.
    @Test func auditBook() {
        let now = Clock.now
        var records: [AuditRecord] = []
        for index in 0 ..< 500 {
            let root = Cause(id: "root\(index)", at: now, trigger: .key, detail: "o · work.start")
            records.append(.cause(root))
            records.append(.cause(Cause(
                id: "cause\(index)", at: now, trigger: .pullEvent, detail: "a comment", parent: root.id,
                authors: [ExternalText.Author(login: "someone\(index)", trust: .stranger)]
            )))
        }
        for index in 0 ..< 50000 {
            records.append(.action(AuditAction(
                id: "a\(index)", at: now.addingTimeInterval(Double(-index)), actor: .agent, tag: .push,
                what: "pushed to branch\(index % 300)", command: "git push origin branch\(index % 300)",
                repo: "acme/repo\(index % 20)", cause: "cause\(index % 500)"
            )))
        }
        var count = 0
        let timing = Bench.time(runs: 5) {
            var book = AuditBook()
            book.apply(records)
            count = book.rows.count
        }
        #expect(count == 50000)
        Self.report("AuditBook.apply + rows, 50k actions", timing)
        #expect(timing.median < 6, "median \(timing.median)")
    }

    /// A turn's last words as one 4k-character line, the shape that used to be slow (#272).
    @Test func turnEndOnALongLine() {
        let line = String(repeating: "I changed the handler and the tests pass now. ", count: 87)
            + "Should I also update the docs?"
        var asks = false
        let timing = Bench.time(runs: 100) { asks = TurnEnd.asksYou(line) }
        #expect(line.count > 4000)
        #expect(asks)
        Self.report("TurnEnd.asksYou, one 4k-char line", timing)
        #expect(timing.median < 0.015, "median \(timing.median)")
    }
}
