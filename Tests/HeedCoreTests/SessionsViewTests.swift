import Foundation
@testable import HeedCore
import Testing

/// The sidebar's View menu: grouping by status, campaign, repo or nothing; sorting; and how long you have been away.
struct SessionsViewTests {
    private let base = Date(timeIntervalSince1970: 1_000_000)

    private func session(
        _ id: String, _ state: AgentState = .working, repo: String? = "docs", touched minutesAgo: Double? = nil,
        started startedAgo: Double = 600, pinned: Bool = false, parked: Bool = false
    ) -> Session {
        var result = Session(
            id: id, title: id, repos: repo.map { [Repo(org: "acme", name: $0)] } ?? [], branch: id, agent: "claude",
            state: ObservedState(state), pinned: pinned, parked: parked,
            lastActivity: base.addingTimeInterval(-startedAgo * 60),
            createdAt: base.addingTimeInterval(-startedAgo * 60)
        )
        result.lastTouched = minutesAgo.map { base.addingTimeInterval(-$0 * 60) }
        return result
    }

    @Test func touchedFallsBackToWhenItStarted() {
        let never = session("a", started: 30)
        #expect(never.touched == never.createdAt)
        let touched = session("b", touched: 5)
        #expect(touched.touched == base.addingTimeInterval(-300))
    }

    @Test func youRecentFirstAndIdleLongestSortByYourTouchNotTheAgents() {
        var busy = session("busy", touched: 120)
        busy.lastActivity = base // the agent is busy right now; you are not
        let sessions = [busy, session("now", touched: 1), session("never", started: 300)]
        let recent = SessionList(sessions, view: SessionsView(sort: .touched))
        #expect(recent.ordered.map(\.id) == ["now", "busy", "never"])
        let idle = SessionList(sessions, view: SessionsView(sort: .idle))
        #expect(idle.ordered.map(\.id) == ["never", "busy", "now"])
        let started = SessionList(sessions, view: SessionsView(sort: .started))
        #expect(started.ordered.map(\.id) == ["never", "busy", "now"])
    }

    @Test func groupingByStatusIsTheSidebarAsItWas() {
        let sessions = [session("park", .done), session("work"), session("ask", .asking)]
        let list = SessionList(sessions)
        #expect(list.sections.map(\.group) == [.needsYou, .working, .parked])
        #expect(list.view == .standard)
    }

    @Test func groupingByRepoKeepsPinnedAndNeedsYouOnTop() {
        let sessions = [
            session("docs-1", touched: 10), session("graph-1", repo: "graph", touched: 1),
            session("pin", repo: "graph", pinned: true), session("ask", .asking, repo: "docs"),
            session("docs-parked", .done, touched: 0), session("chat", repo: nil, touched: 0),
        ]
        let list = SessionList(sessions, view: SessionsView(grouping: .repo, sort: .touched))
        #expect(list.sections.map(\.id) == [
            "status:Pinned", "status:Needs you", "repo:acme/graph", "repo:acme/docs", "status:Chats",
        ])
        // Parked stays in its repo, after the live work there; its status group still says parked.
        #expect(list.sections[3].sessions.map(\.id) == ["docs-1", "docs-parked"])
        #expect(list.groups["docs-parked"] == .parked)
        #expect(list.group(of: "ask") == .needsYou)
        #expect(list.ordered.count == sessions.count)
    }

    @Test func groupingByCampaignPutsUnplacedLast() {
        let redirects = SessionCampaign(id: "c1", title: "Docs nav › Redirects", stage: .landing)
        let sessions = [session("loose", touched: 0), session("anchors", touched: 5), session("moved", touched: 9)]
        let list = SessionList(
            sessions, view: SessionsView(grouping: .campaign, sort: .touched),
            campaign: { $0.id == "loose" ? nil : redirects }
        )
        #expect(list.sections.map(\.header) == [.campaign(redirects), .unplaced])
        #expect(list.sections[0].sessions.map(\.id) == ["anchors", "moved"])
    }

    @Test func noGroupingIsOneListUnderTheBands() {
        let sessions = [session("a"), session("b", .asking), session("c", repo: "graph")]
        let list = SessionList(sessions, view: SessionsView(grouping: .none))
        #expect(list.sections.map(\.id) == ["status:Needs you", "all"])
        #expect(list.sections[1].sessions.map(\.id) == ["a", "c"])
    }

    @Test func theCampaignOfAPieceOfWorkIsTheNearestCampaignAboveIt() {
        var campaign = MindNode(id: "camp", parent: "area", kind: .campaign, title: "Redirects", createdAt: base)
        campaign.stage = .building
        let tree = MindmapTree([
            MindNode(id: "area", kind: .area, title: "Docs", createdAt: base), campaign,
            MindNode(id: "group", parent: "camp", kind: .group, title: "Mine", createdAt: base),
            MindNode(id: "work:s1", parent: "group", kind: .work, title: "w", createdAt: base),
            MindNode(id: "work:s2", kind: .work, title: "w", createdAt: base),
        ])
        #expect(SessionCampaign.of(entry: "s1", in: tree) == SessionCampaign(
            id: "camp", title: "Docs › Redirects", stage: .building
        ))
        #expect(SessionCampaign.of(entry: "s2", in: tree) == nil)
        #expect(SessionCampaign.of(entry: "none", in: tree) == nil)
    }

    @Test func idleAgeIsQuietUnderAQuarterHour() {
        func text(_ minutes: Double) -> String? {
            SessionsView.idleText(since: base.addingTimeInterval(-minutes * 60), now: base)
        }
        #expect(text(14) == nil)
        #expect(text(48) == "48m")
        #expect(text(185) == "3h")
        #expect(text(60 * 24 * 2) == "2d")
        #expect(text(60 * 24 * 35) == "5w")
        #expect(SessionsView.idleWarmth(since: base.addingTimeInterval(-30 * 60), now: base) == 0)
        #expect(SessionsView.idleWarmth(since: base.addingTimeInterval(-2 * 3600), now: base) == 1)
        #expect(SessionsView.idleWarmth(since: base.addingTimeInterval(-2 * 86400), now: base) == 2)
    }

    @Test func choicesStepAndTheLabelSaysThem() {
        #expect(SessionsView.next(SessionsView.Grouping.none) == .status)
        #expect(SessionsView.next(SessionsView.Sort.attention) == .touched)
        #expect(SessionsView.standard.label == "status")
        #expect(SessionsView(grouping: .repo, sort: .idle).label == "repo · idle")
    }

    @Test func lastTouchedSurvivesTheStore() throws {
        let original = session("a", touched: 3)
        let read = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(original))
        #expect(read.lastTouched == original.lastTouched)
    }
}
