import Foundation
@testable import HeedCore
import Testing

/// Right-click menus: which items appear for what was clicked, and what each one acts on.
struct ContextMenuTests {
    private let ref = PullRef(repo: Repo(org: "o", name: "r"), number: 7)

    private func items(_ entries: [MenuEntry]) -> [MenuItem] {
        entries.compactMap { if case let .item(item) = $0 { item } else { nil } }
    }

    private func commands(_ entries: [MenuEntry]) -> [String] { items(entries).map(\.command.name) }

    private func item(_ name: String, in entries: [MenuEntry]) -> MenuItem? {
        items(entries).first { $0.command.name == name }
    }

    @Test func anAttentionThreadOffersItsActionsOnItself() {
        var facts = ContextMenus.AttentionFacts(id: "acme/guides#77", title: "guides #77")
        facts.hasSession = true
        let menu = ContextMenus.attention(facts)
        #expect(commands(menu) == [
            "open.reader", "open.browser", "attention.session", "attention.reply", "items.start", "items.add",
            "attention.done", "attention.snooze", "attention.snooze", "attention.mute",
        ])
        #expect(items(menu).allSatisfy { $0.command.target == .row(view: "attention", id: "acme/guides#77") })
        #expect(item("attention.session", in: menu)?.enabled == false)
        #expect(items(menu).filter { $0.command.name == "attention.snooze" }.map(\.command.arguments) == [
            ["1h"], ["tomorrow"],
        ])
    }

    @Test func anAgentInAttentionHasNoThreadToReplyToOrMute() {
        var facts = ContextMenus.AttentionFacts(id: "agent:s2", title: "Cross-link validator")
        facts.isAgent = true
        facts.itemSession = true
        facts.hasURL = false
        facts.hasThread = false
        let menu = ContextMenus.attention(facts)
        #expect(commands(menu) == ["attention.session", "attention.done", "attention.snooze", "attention.snooze"])
        #expect(item("attention.session", in: menu)?.enabled == true)
    }

    @Test func severalPickedAttentionItemsSayHowMany() {
        var facts = ContextMenus.AttentionFacts(id: "a", title: "a")
        facts.count = 3
        facts.hasThread = false
        let menu = ContextMenus.attention(facts)
        #expect(items(menu).map(\.title).contains("Done with the 3 picked"))
        #expect(item("attention.reply", in: menu)?.enabled == false)
        #expect(item("attention.mute", in: menu)?.enabled == false)
    }

    @Test func aTargetResolvesWhatTheCommandsReadFromTheCursor() {
        let issue = IssueRef(repo: Repo(org: "a", name: "b"), number: 3)
        #expect(CommandTarget.pull(ref).pulls == [ref])
        #expect(CommandTarget.pull(ref).url == "https://github.com/o/r/pull/7")
        #expect(CommandTarget.pull(ref).repos == [ref.repo])
        #expect(CommandTarget.issue(issue).url == "https://github.com/a/b/issues/3")
        #expect(CommandTarget.issue(issue).pulls == nil)
        #expect(CommandTarget.run("r1").runID == "r1")
        // A session names no PR, URL or repo of its own: the commands read those from the session, as keys do.
        #expect(CommandTarget.session("s").pulls == nil)
        #expect(CommandTarget.session("s").url == nil)
        #expect(CommandTarget.session("s").repos == nil)
        // Keys and `:` never carry one.
        #expect(CommandInvocation(parsing: "pilot.green").target == nil)
    }

    @Test func aSessionWithoutPRsHasNoPilotItems() {
        var facts = ContextMenus.SessionFacts(id: "s", title: "Fix it")
        facts.hasPrompt = true
        let menu = ContextMenus.session(facts)
        #expect(menu.first == .header("Fix it"))
        #expect(commands(menu) == [
            "session.agent", "overlay.diff", "session.pin", "session.park", "work.again", "session.close",
            "session.delete",
        ])
        #expect(item("session.agent", in: menu)?.title == "Type into its agent")
        // Every item acts on the session clicked.
        #expect(items(menu).allSatisfy { $0.command.target == .session("s") })
        // Sections are apart, with no separator at either end or twice.
        #expect(menu.count { $0 == .separator } == 2)
        #expect(menu.last != .separator)
    }

    @Test func aSessionsPilotItemsFollowWhereItsPRsStand() {
        var facts = ContextMenus.SessionFacts(id: "s", title: "Fix it")
        facts.pulls = 2
        facts.openPulls = 2
        facts.links = 3
        facts.hasGitHubRepo = true
        facts.pinned = true
        facts.pilot.merging = true
        var menu = ContextMenus.session(facts)
        #expect(commands(menu).starts(with: [
            "session.agent", "overlay.item", "overlay.diff", "open.browser", "open.repo",
        ]))
        #expect(item("open.browser", in: menu)?.title == "Open in browser…")
        #expect(item("session.pin", in: menu)?.title == "Unpin")
        #expect(item("pilot.merge", in: menu)?.checked == true)
        #expect(item("pilot.retry", in: menu) == nil)
        #expect(item("pilot.run", in: menu) == nil)
        #expect(item("pilot.run.stop", in: menu) == nil)
        // Sessions have no Copilot item; a PR card does.
        #expect(item("pilot.copilot", in: menu) == nil)

        facts.pilot.stalled = true
        facts.pilot.runLive = true
        menu = ContextMenus.session(facts)
        #expect(item("pilot.retry", in: menu) != nil)
        #expect(item("pilot.run", in: menu) != nil)
        #expect(item("pilot.run.stop", in: menu) != nil)

        // Every PR merged or closed: the pilot items stay, disabled, except asking why.
        facts.openPulls = 0
        menu = ContextMenus.session(facts)
        #expect(item("pilot.green", in: menu)?.enabled == false)
        #expect(item("pilot.why", in: menu)?.enabled == true)
    }

    @Test func aPRCardActsOnThatPRAlone() {
        var facts = ContextMenus.PullFacts(ref: ref, place: .inspector)
        facts.hasSession = true
        facts.pilot.watching = true
        let menu = ContextMenus.pull(facts)
        #expect(menu.first == .header("r #7"))
        #expect(items(menu).allSatisfy { $0.command.target == .pull(ref) })
        #expect(item("overlay.item", in: menu)?.title == "Open here")
        #expect(item("pilot.watch", in: menu)?.checked == true)
        #expect(item("pilot.copilot", in: menu) != nil)
        // No reviewers configured: nothing to ask.
        #expect(item("pilot.reviewers", in: menu) == nil)
        #expect(item("open.repo", in: menu) == nil)
        #expect(item("pr.untrack", in: menu)?.command.arguments == [ref.url])
        #expect(item("merge.run", in: menu) == nil)
    }

    @Test func aWatchRowOffersItsMergeQueueAndNoUntrack() {
        var facts = ContextMenus.PullFacts(ref: ref, place: .watch)
        facts.pilot.reviewers = true
        let menu = ContextMenus.pull(facts)
        #expect(item("overlay.item", in: menu)?.title == "Open")
        #expect(item("open.repo", in: menu) != nil)
        #expect(item("pr.session", in: menu) == nil)
        #expect(item("pilot.reviewers", in: menu) != nil)
        #expect(item("merge.run", in: menu) != nil)
        #expect(item("merge.queue", in: menu) != nil)
        #expect(item("pr.untrack", in: menu) == nil)
        #expect(item("merge.run", in: ContextMenus.pull(.init(ref: ref, place: .prs))) == nil)
    }

    @Test func runsAndIssues() {
        #expect(commands(ContextMenus.run(id: "r1", title: "get it green #7", running: true))
            == ["pilot.run", "pilot.run.stop"])
        #expect(commands(ContextMenus.run(id: "r1", title: "get it green #7", running: false)) == ["open.reader"])
        let issue = IssueRef(repo: ref.repo, number: 3)
        let menu = ContextMenus.issue(issue)
        #expect(commands(menu) == ["overlay.item", "open.browser", "issue.remove"])
        #expect(item("issue.remove", in: menu)?.command.arguments == [issue.url])
        // The key shown is the command's by name: `issue.remove` is unbound, so it reads `:issue.remove`.
        #expect(item("issue.remove", in: menu)?.keyCommand == "issue.remove")
    }

    @Test func everyItemRunsARealCommand() {
        var session = ContextMenus.SessionFacts(id: "s", title: "t")
        session.pulls = 1
        session.openPulls = 1
        session.links = 1
        session.hasGitHubRepo = true
        session.hasPrompt = true
        session.pilot.stalled = true
        session.pilot.runLive = true
        var pull = ContextMenus.PullFacts(ref: ref, place: .watch)
        pull.pilot = session.pilot
        pull.pilot.reviewers = true
        pull.hasSession = true
        let menus = [
            ContextMenus.session(session), ContextMenus.pull(pull),
            ContextMenus.pull(.init(ref: ref, place: .inspector)), ContextMenus.issue(IssueRef(
                repo: ref.repo,
                number: 1
            )),
            ContextMenus.run(id: "r", title: "r", running: true), ContextMenus.run(id: "r", title: "r", running: false),
        ]
        for name in menus.flatMap(commands) {
            #expect(Commands.spec(name) != nil, "\(name) is not a command")
        }
    }

    @Test func aRowTargetNamesItsViewAndARepoTargetItsRepo() {
        let repo = Repo(org: "o", name: "r")
        #expect(CommandTarget.row(view: "inbox", id: "n1").row(in: "inbox") == "n1")
        #expect(CommandTarget.row(view: "inbox", id: "n1").row(in: "issues") == nil)
        #expect(CommandTarget.row(view: "repos", id: "/p").repos == nil)
        #expect(CommandTarget.repo(repo).repos == [repo])
        #expect(CommandTarget.tab("t").url == nil)
    }

    @Test func inboxAndIssueRowsCountWhatTheyActOn() {
        var facts = ContextMenus.ItemFacts(kind: .inbox, id: "n1", title: "r #4")
        facts.unread = true
        var menu = ContextMenus.item(facts)
        #expect(commands(menu) == [
            "open.reader", "open.browser", "open.repo", "items.start", "items.add", "items.read",
        ])
        #expect(items(menu).allSatisfy { $0.command.target == .row(view: "inbox", id: "n1") })
        // No session selected to add to; already read.
        #expect(item("items.add", in: menu)?.enabled == false)
        #expect(item("items.start", in: menu)?.title == "Start a session from it")

        facts.count = 3
        facts.unread = false
        facts.hasURL = false
        facts.hasSession = true
        menu = ContextMenus.item(facts)
        #expect(item("items.start", in: menu)?.title == "Start a session from the 3 picked")
        #expect(item("items.add", in: menu)?.enabled == true)
        #expect(item("items.read", in: menu)?.enabled == false)
        #expect(item("open.browser", in: menu) == nil)

        var issue = ContextMenus.ItemFacts(kind: .issue, id: "i1", title: "r #5")
        issue.allIssues = true
        menu = ContextMenus.item(issue)
        #expect(item("items.read", in: menu) == nil)
        #expect(item("issues.visibility", in: menu)?.checked == true)
        #expect(items(menu).allSatisfy { $0.command.target == .row(view: "issues", id: "i1") })
    }

    @Test func theIssuesRepoColumn() {
        let repo = Repo(org: "o", name: "r")
        let menu = ContextMenus.issueRepo(repo, allIssues: false)
        #expect(commands(menu) == ["issues.repo", "issues.visibility", "open.repo"])
        #expect(items(menu).allSatisfy { $0.command.target == .repo(repo) })
        #expect(commands(ContextMenus.issueRepo(Repo(org: "local", name: "x"), allIssues: false))
            == ["issues.repo", "issues.visibility"])
        // The All row has no repo: it shows every repo's issues.
        let all = ContextMenus.issueRepo(nil, allIssues: false)
        #expect(commands(all) == ["issues.repo"])
        #expect(item("issues.repo", in: all)?.command.target == nil)
    }

    @Test func theReposColumnSetsARepoUp() {
        let repo = Repo(org: "o", name: "r")
        let menu = ContextMenus.repo(repo, allIssues: true)
        #expect(menu.first == .header("o/r"))
        #expect(commands(menu) == ["repo.setup", "issues.visibility", "open.repo"])
        #expect(items(menu).allSatisfy { $0.command.target == .repo(repo) })
        #expect(item("issues.visibility", in: menu)?.checked == true)
        // A repo that is not on GitHub has nothing to sample.
        #expect(commands(ContextMenus.repo(Repo(org: "local", name: "x"), allIssues: false)) == ["issues.visibility"])
    }

    @Test func aWorktreeMenuNeverRemovesTheMainCheckout() {
        var facts = ContextMenus.WorktreeFacts(id: "/w", title: "r · fix")
        var menu = ContextMenus.worktree(facts)
        #expect(item("select.open", in: menu)?.title == "Import as a session")
        #expect(item("select.pin", in: menu) == nil)
        #expect(item("select.remove", in: menu) != nil)
        #expect(item("repo.setup", in: menu)?.title == "Set up merging and green…")
        facts.onGitHub = false
        #expect(item("repo.setup", in: ContextMenus.worktree(facts)) == nil)
        facts.onGitHub = true
        facts.hasSession = true
        facts.pinned = true
        facts.isMain = true
        menu = ContextMenus.worktree(facts)
        #expect(item("select.open", in: menu)?.title == "Go to its session")
        #expect(item("select.pin", in: menu)?.checked == true)
        #expect(item("select.remove", in: menu) == nil)
        facts.count = 2
        menu = ContextMenus.worktree(facts)
        #expect(item("select.remove", in: menu)?.title == "Remove 2 worktrees…")
        #expect(item("select.copy", in: menu)?.title == "Copy 2 paths")
    }

    @Test func historyAndTabs() {
        #expect(commands(ContextMenus.history(id: "h", title: "t", hasPrompt: true, onGitHub: true))
            == ["history.reopen", "history.again", "open.repo"])
        #expect(commands(ContextMenus.history(id: "h", title: "t", hasPrompt: false, onGitHub: false))
            == ["history.reopen"])
        let tab = ContextMenus.tab(id: "t1", title: "agent", zoomed: true, runLive: false)
        #expect(commands(tab) == ["tab.new", "pane.split.right", "pane.split.below", "pane.zoom", "tab.close"])
        #expect(item("pane.zoom", in: tab)?.checked == true)
        #expect(items(tab).allSatisfy { $0.command.target == .tab("t1") })
        #expect(item("pilot.run.stop", in: ContextMenus.tab(id: "t1", title: "x", zoomed: false, runLive: true)) != nil)
    }

    @Test func everyPhaseTwoItemRunsARealCommand() {
        var worktree = ContextMenus.WorktreeFacts(id: "/w", title: "w")
        worktree.hasSession = true
        let menus = [
            ContextMenus.item(.init(kind: .inbox, id: "a", title: "a")),
            ContextMenus.item(.init(kind: .issue, id: "a", title: "a")),
            ContextMenus.issueRepo(Repo(org: "o", name: "r"), allIssues: true), ContextMenus.worktree(worktree),
            ContextMenus.repo(Repo(org: "o", name: "r"), allIssues: false),
            ContextMenus.history(id: "h", title: "h", hasPrompt: true, onGitHub: true),
            ContextMenus.tab(id: "t", title: "t", zoomed: false, runLive: true),
        ]
        for name in menus.flatMap(commands) {
            #expect(Commands.spec(name) != nil, "\(name) is not a command")
        }
    }

    @Test func theDiffOverlayActsOnTheLineClicked() {
        let menu = ContextMenus.diff(file: 2, row: 7, path: "src/a/b.swift", line: true, split: true, hasCommits: false)
        #expect(menu.first == .header("b.swift"))
        #expect(commands(menu) == ["diff.copy", "diff.edit", "diff.ask", "diff.ask.now", "diff.commit", "diff.split"])
        #expect(items(menu).allSatisfy { $0.command.target == .diffLine(file: 2, row: 7) })
        #expect(item("diff.commit", in: menu)?.enabled == false)
        #expect(item("diff.split", in: menu)?.checked == true)
    }

    @Test func aRightClickOnSelectedLinesActsOnThemAll() {
        let menu = ContextMenus.diff(
            file: 0, row: 3, path: "a.swift", line: true, split: false, hasCommits: true, selected: true
        )
        #expect(item("diff.copy", in: menu)?.title == "Copy path:lines")
        #expect(item("diff.ask", in: menu)?.title == "Note on these lines")
        #expect(item("diff.ask.now", in: menu)?.title == "Ask the agent about these lines now")
        let plain = ContextMenus.diff(file: 0, row: 3, path: "a.swift", line: true, split: false, hasCommits: true)
        #expect(item("diff.ask", in: plain)?.title == "Note on this hunk")
    }

    @Test func feedbackItems() {
        var facts = ContextMenus.FeedbackFacts(id: "t1", title: "a.swift:3 typo")
        facts.queueable = true
        facts.queued = true
        facts.anyQueued = true
        var menu = ContextMenus.feedback(facts)
        #expect(commands(menu) == [
            "feedback.queue", "feedback.send", "feedback.dismiss", "feedback.session", "open.browser",
        ])
        #expect(item("feedback.queue", in: menu)?.checked == true)
        #expect(items(menu).allSatisfy { $0.command.target == .feedback("t1") })
        // Sent already, nothing queued, a session's own note: no PR to start from or open.
        facts.queueable = false
        facts.queued = false
        facts.anyQueued = false
        facts.onPull = false
        menu = ContextMenus.feedback(facts)
        #expect(item("feedback.queue", in: menu)?.enabled == false)
        #expect(item("feedback.send", in: menu)?.enabled == false)
        #expect(item("feedback.session", in: menu) == nil)
        for name in commands(menu) + commands(ContextMenus.diff(
            file: 0, row: 0, path: "a", line: false, split: false, hasCommits: true
        )) {
            #expect(Commands.spec(name) != nil, "\(name) is not a command")
        }
    }
}
