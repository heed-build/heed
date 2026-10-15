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
            "overlay.diff", "session.pin", "session.park", "work.again", "session.close", "session.delete",
        ])
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
        #expect(commands(menu).starts(with: ["overlay.item", "overlay.diff", "open.browser", "open.repo"]))
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
}
