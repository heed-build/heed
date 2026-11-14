import Foundation
@testable import HeedCore
import Testing

/// A helper's ACP permission requests in the one approvals queue: what the queue shows of them, which of the agent's
/// options each answer sends, that one request is settled once from either place, and that a cancelled or ended turn
/// takes its ask away.
struct HelperApprovalTests {
    private let ref = PullRef(repo: Repo(org: "acme", name: "docs-toolkit"), number: 2841)
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private let allOptions: [ACPPermissionRequest.Option] = [
        .init(id: "once", name: "Allow", kind: .allowOnce),
        .init(id: "always", name: "Always Allow", kind: .allowAlways),
        .init(id: "no", name: "Reject", kind: .rejectOnce),
    ]

    private func asking(
        _ call: ACPToolCall = ACPToolCall(id: "t6", title: "`dotnet test`", kind: .execute, command: "dotnet test"),
        options: [ACPPermissionRequest.Option]? = nil, request: JSONValue = 7
    ) -> HelperRun {
        var run = HelperRun(
            id: "h1", kind: .green, ref: ref, title: "Fix broken anchors", agent: "claude", adapter: "claude via ACP",
            sessionID: "s1", prBranch: "fix-anchors", branch: "heed/get-it-green/fix-anchors", worktree: "/wt/h",
            startedAt: t0, cap: 0.5
        )
        run.phase = .working
        run.ask(ACPPermissionRequest(toolCall: call, options: options ?? allOptions), id: request, at: t0)
        return run
    }

    @Test func aHelperAskIsAnEntryInTheQueue() throws {
        let run = asking()
        let ask = try #require(PermissionAsk.from(helper: run))
        #expect(ask.id == "helper-h1-7" && ask.channel == .helper && ask.helperID == "h1")
        #expect(ask.agent == "helper · claude" && ask.session == "helper:h1")
        #expect(ask.tool == "Bash" && ask.command == "dotnet test" && ask.title == "Run a command")
        #expect(ask.helper?.repo == "docs-toolkit" && ask.helper?.number == 2841)
        #expect(ask.helper?.headline == "Getting #2841 green" && ask.askedAt == t0)
        #expect(ask.why == nil, "a title that only repeats the command is no reason")

        let hook = PermissionAsk(id: "k", session: "s2", agent: "claude", tool: "Bash", command: "ls", askedAt: t0 - 5)
        let queue = ApprovalQueue(asks: [hook])
        let groups = queue.groups(helpers: ApprovalQueue.helperAsks([run])) { $0 == "helper:h1" ? ["/wt/h"] : [] }
        #expect(groups.map(\.first.id) == ["k", "helper-h1-7"], "oldest first, among the hook asks")
        #expect(groups[1].answerable && groups[1].canAlways && !groups[1].takesReason)
        #expect(ApprovalSummary(groups).text == "2 asks from 2 agents")
        #expect(ApprovalSummary.initials("helper · claude") == "hp")
    }

    @Test func riskTagsReadTheToolCall() throws {
        let push = asking(ACPToolCall(id: "t", title: "git push", kind: .execute, command: "git push origin HEAD"))
        let tags = try PermissionRisk.tags(for: #require(PermissionAsk.from(helper: push)), roots: ["/wt/h"])
        #expect(tags.contains(.writesGitHub) && tags.contains(.network))

        let edit = asking(ACPToolCall(
            id: "t", title: "Edit /etc/hosts", kind: .edit,
            content: [.diff(path: "/etc/hosts", oldText: "a", newText: "b")], paths: ["/etc/hosts"]
        ))
        let ask = try #require(PermissionAsk.from(helper: edit))
        #expect(ask.tool == "Edit" && ask.paths == ["/etc/hosts"] && ask.patch == "- a\n+ b")
        #expect(PermissionRisk.tags(for: ask, roots: ["/wt/h"]).contains(.outsideWorktree))

        let fetch = asking(ACPToolCall(id: "t", title: "Fetch", kind: .fetch, url: "https://example.com"))
        let page = try #require(PermissionAsk.from(helper: fetch))
        #expect(page.tool == "WebFetch" && page.url == "https://example.com")
        #expect(PermissionRisk.tags(for: page, roots: ["/wt/h"]).contains(.network))
    }

    @Test func answersMapToTheAgentsOwnOptions() throws {
        let permission = try #require(asking().permission)
        #expect(permission.option(for: PermissionAnswer(.allow))?.id == "once")
        #expect(permission.option(for: PermissionAnswer(.allow, always: true))?.id == "always")
        #expect(permission.option(for: PermissionAnswer(.deny))?.id == "no")
        #expect(permission.option(for: .pass) == nil)

        let sparse = try #require(asking(options: [
            .init(id: "ok", name: "Allow", kind: .allowOnce), .init(id: "never", name: "Never", kind: .rejectAlways),
        ]).permission)
        #expect(sparse.option(for: PermissionAnswer(.allow, always: true))?.id == "ok", "no always: once")
        #expect(sparse.option(for: PermissionAnswer(.deny))?.id == "never", "no reject once: reject always")

        let onlyAlways = try #require(asking(options: [.init(id: "a", name: "Always", kind: .allowAlways)]).permission)
        #expect(onlyAlways.option(for: PermissionAnswer(.allow)) == nil, "a plain yes never becomes an always")
        #expect(try !#require(PermissionAsk.from(helper: asking(options: [allOptions[0]]))).offersAlways)
    }

    @Test func aRequestIsSettledOnceFromEitherPlace() throws {
        var run = asking()
        let id = try #require(run.askID)
        #expect(run.settle(id, PermissionAnswer(.allow, always: true)) == .send(
            requestID: 7, optionID: "always", word: "allowed always"
        ))
        #expect(run.permission == nil && run.phase == .working && run.approvals == 1)
        #expect(run.settle(id, PermissionAnswer(.deny)) == .stale, "the second answer sends nothing")
        #expect(run.approvals == 1)
        #expect(ApprovalQueue.helperAsks([run]).isEmpty)

        // An answer meant for an earlier request never settles the next one.
        run.ask(
            ACPPermissionRequest(toolCall: ACPToolCall(id: "t7", kind: .execute, command: "ls"), options: allOptions),
            id: 8,
            at: t0
        )
        #expect(run.settle(id, PermissionAnswer(.allow)) == .stale)
        #expect(run.permission != nil)

        var picky = asking(options: [.init(id: "a", name: "Always", kind: .allowAlways)])
        #expect(try picky.settle(#require(picky.askID), PermissionAnswer(.allow)) == .noOption)
        #expect(picky.permission != nil, "no such option: it still asks")
    }

    @Test func aCancelledOrEndedTurnTakesItsAskAway() throws {
        var cancelled = asking()
        cancelled.answered("cancelled")
        #expect(ApprovalQueue.helperAsks([cancelled]).isEmpty)

        var passed = asking()
        #expect(try passed.settle(#require(passed.askID), .pass) == .send(
            requestID: 7,
            optionID: nil,
            word: "cancelled"
        ))
        #expect(ApprovalQueue.helperAsks([passed]).isEmpty)

        var ended = asking()
        ended.withdrawPermission()
        ended.phase = .done(.endTurn)
        #expect(ApprovalQueue.helperAsks([ended]).isEmpty)
        #expect(ended.feed.last?.body == .permission(title: "dotnet test", answer: "withdrawn"))

        var stopped = asking()
        stopped.phase = .stopped("cap")
        #expect(ApprovalQueue.helperAsks([stopped]).isEmpty, "a helper that is not live asks nothing")
        #expect(try stopped.settle(#require(stopped.askID), PermissionAnswer(.allow)) == .stale)
    }

    @Test func theSessionLinePointsAtTheApprovals() throws {
        let line = try #require(SessionHelperLine.of(
            [asking()], tracked: [], sessionID: "s1", leftAt: nil, dismissed: []
        ))
        #expect(line.asks && line.needsYou)
        var answered = asking()
        answered.answered("allowed")
        let quiet = try #require(SessionHelperLine.of(
            [answered], tracked: [], sessionID: "s1", leftAt: nil, dismissed: []
        ))
        #expect(!quiet.asks)
    }
}
