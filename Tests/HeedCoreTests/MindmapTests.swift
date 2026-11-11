import Foundation
@testable import HeedCore
import Synchronization
import Testing

private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

private func entry(
    _ id: String, _ title: String, repos: [String] = ["acme/docs-toolkit"], chat: Bool = false, files: [String] = [],
    summary: String? = nil, decisions: [String] = [], followUps: [String] = []
) -> LedgerEntry {
    LedgerEntry(
        id: id, title: title, repos: repos, branch: title.replacingOccurrences(of: " ", with: "-"), chat: chat,
        startedAt: t0, files: files, summary: summary,
        decisions: decisions, followUps: followUps
    )
}

private func campaign(_ id: String, _ title: String, at: TimeInterval = 0) -> MindNode {
    MindNode(id: id, kind: .campaign, title: title, createdAt: t0.addingTimeInterval(at))
}

/// Answers every question it is asked: `choice` for choices (nil: the call fails), `probability` for statements.
private final class ScriptedDecider: Decider {
    let choice: String?
    let confidence: Double
    let probability: Double
    let asked = Mutex<[[String: Question]]>([])

    init(_ choice: String?, confidence: Double = 0.9, probability: Double = 0.9) {
        self.choice = choice
        self.confidence = confidence
        self.probability = probability
    }

    func decide(subject _: String, state _: String, questions: [String: Question]) async throws -> [String: Answer] {
        asked.withLock { $0.append(questions) }
        var answers: [String: Answer] = [:]
        for (id, question) in questions {
            switch question {
            case .choice, .score:
                guard let choice else { throw DeciderError.badAnswer("scripted") }
                answers[id] = Answer(choice: choice, probabilities: [choice: confidence], confidence: confidence)
            case .noul:
                answers[id] = Answer(
                    probability: probability, probabilities: ["true": probability, "false": 1 - probability],
                    confidence: max(probability, 1 - probability)
                )
            }
        }
        return answers
    }
}

struct MindmapInstanceTests {
    @Test func anOrgsWorkStaysInItsOrgAndYourOwnIsPersonal() {
        let context = MindmapInstance.Context(login: "Sam")
        #expect(MindmapInstance.of(entry("a", "x", repos: ["acme/web"]), context: context).instance == "acme")
        #expect(MindmapInstance.of(entry("b", "x", repos: ["sam/dots"]), context: context).instance
            == MindmapInstance.personal)
        #expect(MindmapInstance.of(entry("c", "x", repos: ["local/notes"]), context: context).instance
            == MindmapInstance.personal)
        // An org that happens to be called personal is still an org.
        #expect(MindmapInstance.of(entry("d", "x", repos: ["personal/site"]), context: context).instance == "personal")
        #expect(MindmapInstance.fileName("personal") == "org-personal.sqlite")
        #expect(MindmapInstance.fileName(MindmapInstance.personal) == "personal.sqlite")
    }

    @Test func aForkGoesWithItsUpstreamAndAChatWithItsFolder() {
        let context = MindmapInstance.Context(
            login: "sam", upstreams: ["sam/web": "acme/web"], chatRepos: ["chat1": "globex/api"]
        )
        #expect(MindmapInstance.of(entry("a", "x", repos: ["sam/web"]), context: context).instance == "acme")
        #expect(MindmapInstance.of(entry("chat1", "x", repos: [], chat: true), context: context).instance == "globex")
        #expect(MindmapInstance.of(entry("chat2", "x", repos: [], chat: true), context: context).instance
            == MindmapInstance.personal)
    }

    @Test func workAcrossTwoOrgsGoesByItsFirstRepoAndSaysSo() {
        let resolved = MindmapInstance.of(entry("a", "x", repos: ["acme/web", "globex/api"]), context: .init())
        #expect(resolved == .init(instance: "acme", spansOrgs: true))
        #expect(!MindmapInstance.of(entry("b", "x", repos: ["acme/web", "acme/api"]), context: .init()).spansOrgs)
    }
}

struct MindmapStoreTests {
    @Test func everyInstanceHasItsOwnFileAndNoneSeesAnothers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("heed-mindmap-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let acme = try #require(await MindmapStore.open("acme", in: directory))
        let mine = try #require(await MindmapStore.open(MindmapInstance.personal, in: directory))
        try await acme.upsert([campaign("c1", "Make the docs nav trustworthy")])
        try await mine.upsert([campaign("c2", "Dotfiles that apply cleanly")])
        #expect(try await acme.nodes().map(\.id) == ["c1"])
        #expect(try await mine.nodes().map(\.id) == ["c2"])
        #expect(MindmapStore.instances(in: directory) == [MindmapInstance.personal, "acme"].sorted())
        try await acme.delete(["c1"])
        #expect(try await acme.nodes().isEmpty)
        // Opened again, it is still there.
        let again = try #require(await MindmapStore.open(MindmapInstance.personal, in: directory))
        #expect(try await again.nodes().map(\.title) == ["Dotfiles that apply cleanly"])
    }
}

struct MindmapPlaceTests {
    private func tree(_ campaigns: [MindNode], work: [(LedgerEntry, String)] = []) -> MindmapTree {
        var tree = MindmapTree(campaigns)
        for (entry, parent) in work {
            tree.upsert(MindNode.work(entry, parent: parent, now: t0))
        }
        return tree
    }

    @Test func theWordsSettleClearMatchesAndClearMisses() async {
        let toc = entry("e1", "fix toc ordering", files: ["src/Toc.cs"])
        let base = tree([campaign("nav", "Docs nav")], work: [(toc, "nav")])
        let ledger = ["e1": toc]
        let same = await MindmapPlace.decide(
            entry("e2", "fix toc ordering again"), in: base, ledger: ledger, decider: ScriptedDecider(nil)
        )
        guard case .campaign("nav", _, "words", true) = same.outcome else { Issue.record("\(same)"); return }
        let unrelated = await MindmapPlace.decide(
            entry("e3", "sign release artifacts"), in: base, ledger: ledger, decider: ScriptedDecider(nil)
        )
        guard case .new(_, "words") = unrelated.outcome else { Issue.record("\(unrelated)"); return }
        #expect(unrelated.state == nil)
    }

    @Test func aCloseCallIsOneQuestionHunchTakesWithFourCampaignsAtMost() async {
        let campaigns = (1 ... 6).map { campaign("k\($0)", "nav tables part \($0)", at: Double($0)) }
        let decider = ScriptedDecider("c2", confidence: 0.92)
        let placed = await MindmapPlace.decide(
            entry("e1", "nav tables collapsed"), in: tree(campaigns), ledger: [:], decider: decider, route: "hunch"
        )
        let question = try? #require(decider.asked.withLock { $0.first?["place"] })
        #expect(question.map(HunchRouting.hunchTakes) == true)
        if case let .choice(_, options) = question { #expect(options == ["c1", "c2", "c3", "c4", "new"]) }
        #expect(placed.options.count == 4)
        guard case let .campaign(id, confidence, "hunch", true) = placed.outcome else {
            Issue.record("\(placed)")
            return
        }
        #expect(id == placed.options[1] && confidence == 0.92)
    }

    @Test func anUnsureAnswerIsASuggestionAndAFailedCallSuggestsOnlyTheVeryClose() async {
        let base = tree([campaign("nav", "nav tables")])
        let unsure = await MindmapPlace.decide(
            entry("e1", "nav tables collapsed"), in: base, ledger: [:], decider: ScriptedDecider("c1", confidence: 0.4)
        )
        guard case .campaign("nav", _, _, false) = unsure.outcome else { Issue.record("\(unsure)"); return }
        let failed = await MindmapPlace.decide(
            entry("e2", "nav tables collapsed"), in: base, ledger: [:], decider: ScriptedDecider(nil)
        )
        guard case .campaign("nav", _, "words", false) = failed.outcome else { Issue.record("\(failed)"); return }
    }

    @Test func recordingPlacesNewWorkAndLeavesWhereYouPutItAlone() {
        var tree = tree([campaign("nav", "Docs nav"), campaign("rel", "Releases")])
        let work = entry("e1", "fix toc", decisions: ["Index order wins"], followUps: ["Stable sibling key"])
        let placed = MindmapPlace.Placed(
            outcome: .campaign("nav", confidence: 0.9, route: "hunch", sure: true), state: "s", options: ["nav"]
        )
        MindmapPlace.record(work, placed: placed, in: &tree, now: t0)
        #expect(tree.work(for: "e1")?.parent == "nav")
        #expect(tree["nav"]?.synopsisStale == true)
        tree.move("work:e1", to: "rel", now: t0)
        tree.resolve("Stable sibling key", in: "work:e1", now: t0)
        // The ledger writes the summary again; heed places it again: where you put it, and what you marked, stay.
        MindmapPlace.record(work, placed: placed, in: &tree, now: t0.addingTimeInterval(60))
        #expect(tree.work(for: "e1")?.parent == "rel")
        #expect(tree.work(for: "e1")?.open.first?.resolvedBy == "you")
    }

    @Test func newWorkResolvesFollowUpsAndSupersedesDecisionsItGoesAgainst() async {
        let spike = entry("e1", "nav spike", decisions: ["Sort the nav by title"], followUps: ["Stable sibling key"])
        var tree = tree([campaign("nav", "Docs nav")], work: [(spike, "nav")])
        let next = entry("e2", "fix toc ordering", decisions: ["Index file order wins"])
        let checks = MindmapPlace.checks(for: next, campaign: "nav", in: tree)
        #expect(checks.map(\.kind) == [.resolves, .contradicts])
        let held = await MindmapPlace.confirm(checks, entry: next, decider: ScriptedDecider("x", probability: 0.85))
        MindmapPlace.apply(held, entry: next, to: &tree, now: t0)
        #expect(tree.work(for: "e1")?.open.first?.resolvedBy == "e2")
        #expect(tree.work(for: "e1")?.decisions.first?.supersededBy == "Index file order wins")
        let unsure = await MindmapPlace.confirm(checks, entry: next, decider: ScriptedDecider("x", probability: 0.6))
        #expect(unsure.isEmpty)
    }

    @Test func checksStayWithinWhatHunchIsAskedAtOnce() {
        let many = entry("e1", "nav", decisions: (1 ... 5).map { "decision \($0)" }, followUps: ["a", "b", "c"])
        let tree = tree([campaign("nav", "Docs nav")], work: [(many, "nav")])
        #expect(MindmapPlace.checks(for: entry("e2", "next"), campaign: "nav", in: tree).count == MindmapPlace
            .maxChecks)
        // The new work's own follow-ups and decisions are not checked against it.
        #expect(MindmapPlace.checks(for: many, campaign: "nav", in: tree).isEmpty)
    }
}

struct MindmapTreeTests {
    private let now = t0.addingTimeInterval(3600)

    @Test func aNodeNeverMovesIntoItselfOrBelowItself() {
        var tree = MindmapTree([
            MindNode(id: "area", kind: .area, title: "Docs", createdAt: t0),
            MindNode(id: "nav", parent: "area", kind: .campaign, title: "Nav", createdAt: t0),
        ])
        let ok1 = tree.move("area", to: "nav", now: now)
        #expect(!ok1)
        let ok2 = tree.move("area", to: "area", now: now)
        #expect(!ok2)
        let ok3 = tree.move("nav", to: nil, now: now)
        #expect(ok3)
        #expect(tree["nav"]?.madeBy == .you)
        #expect(tree.roots.map(\.id).sorted() == ["area", "nav"])
    }

    @Test func groupingNestsSiblingsAndLiftingTheLastOneOutDropsTheGroup() {
        var tree = MindmapTree([
            campaign("nav", "Nav"),
            MindNode.work(entry("e1", "spike"), parent: "nav", now: t0),
            MindNode.work(entry("e2", "toc"), parent: "nav", now: t0),
        ])
        let ok4 = tree.group(["work:e1", "work:e2"], title: "Ordering", id: "g1", now: now)
        #expect(ok4)
        #expect(tree.children(of: "nav").map(\.id) == ["g1"])
        #expect(tree.path(to: "work:e1").map(\.id) == ["nav", "g1"])
        #expect(tree.entries(under: "nav").sorted() == ["e1", "e2"])
        tree.lift("work:e1", now: now)
        tree.lift("work:e2", now: now)
        #expect(tree["g1"] == nil)
        #expect(tree.children(of: "nav").count == 2)
        // Siblings only: work from two places is not grouped.
        var other = tree
        other.upsert(campaign("rel", "Releases"))
        other.upsert(MindNode.work(entry("e3", "sign"), parent: "rel", now: t0))
        let ok5 = other.group(["work:e1", "work:e3"], title: "x", id: "g2", now: now)
        #expect(!ok5)
    }

    @Test func aDecisionRisesWhenTwoChildrenCiteItOrItIsPinned() {
        var tree = MindmapTree([
            campaign("nav", "Nav"),
            MindNode.work(entry("e1", "a", decisions: ["Keep the tree", "Spike only"]), parent: "nav", now: t0),
            MindNode.work(entry("e2", "b", decisions: ["Keep the tree"]), parent: "nav", now: t0),
        ])
        var decided = tree.decisions(of: "nav")
        #expect(decided.shown.map(\.text) == ["Keep the tree"])
        #expect(decided.inside == 1)
        tree.togglePin("Spike only", in: "work:e1", now: now)
        decided = tree.decisions(of: "nav")
        #expect(Set(decided.shown.map(\.text)) == ["Keep the tree", "Spike only"])
        #expect(decided.inside == 0)
    }

    @Test func joiningMovesEverythingAcrossAndAChangeMarksEveryNodeAboveStale() {
        var tree = MindmapTree([
            MindNode(id: "area", kind: .area, title: "Docs", createdAt: t0),
            MindNode(id: "nav", parent: "area", kind: .campaign, title: "Nav", createdAt: t0),
            MindNode(id: "toc", parent: "area", kind: .campaign, title: "TOC", createdAt: t0),
            MindNode.work(entry("e1", "a", followUps: ["x"]), parent: "toc", now: t0),
        ])
        let ok6 = tree.join("toc", into: "nav", now: now)
        #expect(ok6)
        #expect(tree["toc"] == nil)
        #expect(tree.work(for: "e1")?.parent == "nav")
        #expect(tree.stillOpen(under: "area").map(\.text) == ["x"])
        #expect(tree["area"]?.synopsisStale == true)
        let ok7 = tree.join("area", into: "nav", now: now)
        #expect(!ok7)
    }
}

struct MindmapLearningTests {
    @Test func whatYouDoWithAnAskedPlacementBecomesAnExample() {
        let asked = MindNode.Placement(confidence: 0.5, route: "hunch", state: "the state", options: ["nav", "rel"])
        var work = MindNode.work(entry("e1", "a"), parent: "nav", now: t0)
        work.placement = asked
        work.suggested = true
        var tree = MindmapTree([campaign("nav", "Nav"), campaign("rel", "Rel"), campaign("x", "X"), work])
        tree.accept("work:e1", now: t0)
        #expect(tree.work(for: "e1")?.placement?.verdict == "c1")
        tree.move("work:e1", to: "rel", now: t0)
        #expect(tree.work(for: "e1")?.placement?.verdict == "c2")
        tree.move("work:e1", to: nil, now: t0)
        #expect(tree.work(for: "e1")?.placement?.verdict == "new")
        // A campaign it was not offered teaches nothing new.
        tree.move("work:e1", to: "x", now: t0)
        #expect(tree.work(for: "e1")?.placement?.verdict == "new")
        let examples = HunchTrainingSet.mindmap(Array(tree.nodes.values))
        #expect(examples.count == 1)
        #expect(examples.first?.id == "mindmap:e1" && examples.first?.answer == "new")
        #expect(examples.first?.family == .mindmap && examples.first?.state == "the state")
        #expect(examples.first.map { HunchRouting.hunchTakes($0.question) } == true)
    }

    @Test func placementsTheWordsSettledTeachNothing() {
        var work = MindNode.work(entry("e1", "a"), parent: "nav", now: t0)
        work.placement = .init(confidence: 0.9, route: "words")
        var tree = MindmapTree([campaign("nav", "Nav"), campaign("rel", "Rel"), work])
        tree.move("work:e1", to: "rel", now: t0)
        #expect(HunchTrainingSet.mindmap(Array(tree.nodes.values)).isEmpty)
    }
}

struct MindmapNamingTests {
    @Test func campaignsComeOnlyWithWorkTheModelWasShown() {
        let reply = """
        Here you go:
        {"campaigns":[
          {"title":"Make the docs nav trustworthy","intent":"Pages sit where the index says.","area":"Docs",
           "work":["e1","e2","e9"]},
          {"title":"Nothing real","work":["e9"]},
          {"title":"Signed releases","area":"Releases","work":["e2","e3"]}
        ]}
        """
        let proposals = MindmapNaming.parse(reply, known: ["e1", "e2", "e3"])
        #expect(proposals.map(\.title) == ["Make the docs nav trustworthy", "Signed releases"])
        // An id goes to the first campaign that names it.
        #expect(proposals.map(\.work) == [["e1", "e2"], ["e3"]])
        #expect(MindmapNaming.parse("no json here", known: ["e1"]).isEmpty)
    }

    @Test func namingMakesAreasAndCampaignsAndLeavesYourWorkWhereItIs() {
        var mine = MindNode.work(entry("e3", "c"), parent: nil, now: t0)
        mine.madeBy = .you
        var tree = MindmapTree([
            MindNode.work(entry("e1", "a"), parent: nil, now: t0),
            MindNode.work(entry("e2", "b"), parent: nil, now: t0),
            mine,
        ])
        let proposal = MindmapNaming.Proposal(title: "Docs nav", intent: "x", area: "Docs", work: ["e1", "e2", "e3"])
        MindmapNaming.apply([proposal], to: &tree, now: t0)
        let campaign = try? #require(tree.campaigns.first)
        #expect(campaign?.parent == "area:docs")
        #expect(tree["area:docs"]?.kind == .area)
        #expect(tree.work(for: "e1")?.parent == campaign?.id && tree.work(for: "e2")?.parent == campaign?.id)
        #expect(tree.work(for: "e3")?.parent == nil)
        // The same area is reused by name.
        MindmapNaming.apply(
            [.init(title: "Docs search", area: "docs", work: ["e3"])], to: &tree, now: t0
        )
        #expect(tree.nodes.values.count { $0.kind == .area } == 1)
    }
}

struct MindmapStatsTests {
    @Test func statsCountWhatYouAnsweredAndHowOftenHeedHadItRight() {
        func work(_ id: String, chose: String, verdict: String?) -> MindNode {
            var node = MindNode.work(entry(id, id), parent: nil, now: t0)
            node.placement = .init(
                confidence: 0.6, route: "hunch", state: "s", options: ["a", "b"], chose: chose, verdict: verdict
            )
            return node
        }
        var words = MindNode.work(entry("w", "w"), parent: nil, now: t0)
        words.placement = .init(confidence: 1, route: "words")
        let stats = MindmapStats([MindmapTree([
            work("e1", chose: "c1", verdict: "c1"), work("e2", chose: "c1", verdict: "c2"),
            work("e3", chose: "new", verdict: nil), words,
        ])])
        #expect(stats.routes["hunch"] == .init(asked: 3, answered: 2, right: 1))
        #expect(stats.routes["words"] == nil)
        #expect(stats.total.rate == 0.5)
    }
}

struct MindmapFactsTests {
    @Test func factsAddUpTheWorkUnderANodeFromTheLedger() {
        var one = entry("e1", "a", files: ["Toc.cs", "Nav.cs"])
        one.pulls = [PullRef(repo: Repo(org: "acme", name: "docs"), number: 1)]
        one.agentTime = 600
        one.agent = "claude"
        var two = entry("e2", "b", repos: ["acme/site"], files: ["Toc.cs"])
        two.pulls = [PullRef(repo: Repo(org: "acme", name: "site"), number: 2)]
        two.outcome = "PR open"
        two.agentTime = 300
        two.agent = "codex"
        let tree = MindmapTree([
            campaign("nav", "Nav"), MindNode.work(one, parent: "nav", now: t0), MindNode.work(
                two,
                parent: "nav",
                now: t0
            ),
        ])
        let facts = MindmapFacts(of: "nav", in: tree, ledger: ["e1": one, "e2": two])
        #expect(facts.pieces == 2 && facts.pulls == 2 && facts.openPulls == 1)
        #expect(facts.agentTime == 900)
        #expect(facts.repos == ["docs-toolkit", "site"] && facts.agents == ["claude", "codex"])
        #expect(facts.mostTouched?.file == "Toc.cs" && facts.mostTouched?.times == 2)
    }
}
