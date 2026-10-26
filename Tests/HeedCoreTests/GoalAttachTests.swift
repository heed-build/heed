import Foundation
@testable import HeedCore
import Synchronization
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func goal(_ id: String, _ title: String) -> HeedGoal { HeedGoal(id: id, title: title, createdAt: now) }

private func subject(
    _ id: String = "s9", kind: GoalLink.Kind = .session, title: String = "untitled", prompt: String = "",
    repos: [String] = ["acme/docs-toolkit"], branch: String = "", worktrees: [String] = [], files: [String] = [],
    pulls: [String] = [], issues: [String] = [], at: Date = now
) -> AttachSubject {
    AttachSubject(
        kind: kind, id: id, title: title, prompt: prompt, repos: repos, branch: branch, worktreePaths: worktrees,
        files: files, pulls: pulls, issues: issues, at: at
    )
}

private let anchorsDoc = GoalDoc(
    title: "Anchors survive page moves",
    goal: "A page that moves keeps every inbound anchor working: old URLs redirect to the right heading.",
    notTheGoal: ["Rewriting the link checker"],
    doneWhen: [GoalDoc.Criterion("every redirect target resolves to a heading")]
)
private let diagramsDoc = GoalDoc(
    title: "Sequence diagrams read cleanly",
    goal: "Arrows, labels and lifelines in sequence diagrams render without overlaps.",
    doneWhen: [GoalDoc.Criterion("arrowheads meet the lifeline exactly")]
)

private func anchors(
    branches: Set<String> = [], worktrees: Set<String> = [], files: Set<String> = [], pulls: Set<String> = [],
    repos: Set<String> = ["acme/docs-toolkit"], last: Date? = nil
) -> GoalContext {
    GoalContext(
        goal: goal("anchors", "Anchors survive page moves"), doc: anchorsDoc, repos: repos, branches: branches,
        worktreePaths: worktrees, files: files, pulls: pulls, lastActivity: last
    )
}

private func diagrams(repos: Set<String> = ["acme/diagrams"], branches: Set<String> = []) -> GoalContext {
    GoalContext(
        goal: goal("diagrams", "Sequence diagrams read cleanly"), doc: diagramsDoc, repos: repos, branches: branches
    )
}

struct AttachSignalsTests {
    @Test func noSignalIsNoCandidate() {
        let found = AttachSignals.score(
            subject(title: "bump the formatter", repos: ["acme/tools"]), goals: [anchors(), diagrams()], now: now
        )
        #expect(found.isEmpty)
        #expect(AttachSignals.score(subject(), goals: [], now: now).isEmpty)
    }

    @Test func eachSignalWeighsWhatItSays() throws {
        func only(_ s: AttachSubject, _ g: GoalContext) throws -> AttachCandidate {
            try #require(AttachSignals.score(s, goals: [g], now: now).first)
        }
        let worktree = try only(
            subject(repos: [], worktrees: ["/w/anchors-redirects"]), anchors(worktrees: ["/w/anchors-redirects"])
        )
        #expect(worktree.signals.map(\.kind) == [.worktree] && worktree.confidence == AttachSignals.worktreeWeight)
        let branch = try only(subject(repos: [], branch: "feature/anchors-x"), anchors(branches: ["feature/anchors-x"]))
        #expect(branch.signals.map(\.kind) == [.branch] && branch.confidence == AttachSignals.branchWeight)
        let family = try only(
            subject(repos: [], branch: "feature/anchors-validator"), anchors(branches: ["anchors-redirects"])
        )
        #expect(family.signals.map(\.kind) == [.family] && family.reason == "branch family anchors")
        let pull = try only(
            subject(repos: [], pulls: ["acme/docs-toolkit#12"]),
            anchors(pulls: ["acme/docs-toolkit#12"])
        )
        #expect(pull.confidence == AttachSignals.pullWeight && pull.reason == "acme/docs-toolkit#12 is on the goal")
        let files = try only(
            subject(repos: [], files: ["a", "b", "c", "d"]), anchors(files: ["a", "b", "c", "z"])
        )
        #expect(abs(files.confidence - AttachSignals.filesWeight * 0.75) < 1e-9)
        #expect(files.reason == "3 of 4 touched files on the goal")
        let repo = try only(subject(), anchors())
        #expect(repo.signals.map(\.kind) == [.repo] && abs(repo.confidence - AttachSignals.repoWeight) < 1e-9)
    }

    @Test func aDefaultBranchSaysNothing() {
        #expect(AttachSignals.score(subject(repos: [], branch: "main"), goals: [anchors(branches: ["main"])], now: now)
            .isEmpty)
    }

    @Test func signalsAgreeIntoConfidence() throws {
        // Same family and 3 of 4 files: 1 − (1 − 0.65)(1 − 0.6) = 0.86, enough to attach.
        let found = try #require(AttachSignals.score(
            subject(branch: "feature/anchors-headings", files: ["a", "b", "c", "d"]),
            goals: [anchors(branches: ["anchors-redirects"], files: ["a", "b", "c"])], now: now
        ).first)
        let expected = AttachSignals.combine([AttachSignals.familyWeight, 0.6, AttachSignals.repoWeight])
        #expect(abs(found.confidence - expected) < 1e-9)
        #expect(found.confidence >= AttachSettings().auto)
        #expect(AttachSignals.combine([]) == 0 && AttachSignals.combine([1, 0.2]) == 1)
        #expect(AttachSignals.combine([2, -1]) == 1)
    }

    @Test func promptTermsMatchTheGoalButNotItsNonGoals() throws {
        let found = try #require(AttachSignals.score(
            subject(title: "redirect old anchors", prompt: "make moved headings redirect", repos: []),
            goals: [anchors(), diagrams()], now: now
        ).first)
        #expect(found.goal == "anchors" && found.signals.map(\.kind) == [.terms])
        #expect(found.reason.hasPrefix("mentions "))
        #expect(found.reason.contains("anchor"))
        // "link checker" is only in Not the goal: it is no reason.
        #expect(AttachSignals.score(subject(title: "link checker", repos: []), goals: [anchors()], now: now).isEmpty)
    }

    @Test func rarerTermsWeighMore() {
        let index = TermIndex([anchorsDoc, diagramsDoc, GoalDoc(title: "Heading styles", goal: "heading fonts")])
        #expect(index.idf("redirect") > index.idf("heading"))
        let rare = index.overlap("redirect", with: 0).share
        #expect(rare == 1)
        let mixed = index.overlap("redirect lifeline", with: 0).share
        #expect(mixed > 0 && mixed < 1)
    }

    @Test func anotherRepoIsDamped() throws {
        let other = try #require(AttachSignals.score(
            subject(repos: ["acme/elsewhere"], branch: "anchors-x"), goals: [anchors(branches: ["anchors-y"])], now: now
        ).first)
        #expect(other.otherRepo && other.reason.hasSuffix("other repo"))
        #expect(abs(other.confidence - AttachSignals.familyWeight * AttachSignals.otherRepoFactor) < 1e-9)
    }

    @Test func recencyOnlyAddsToAnotherSignal() throws {
        #expect(AttachSignals.score(subject(repos: []), goals: [anchors(last: now)], now: now).isEmpty)
        let fresh = try #require(AttachSignals.score(subject(), goals: [anchors(last: now - 3600)], now: now).first)
        let stale = try #require(AttachSignals.score(
            subject(), goals: [anchors(last: now - 3 * 86400)], now: now
        ).first)
        #expect(fresh.confidence > stale.confidence)
        #expect(stale.signals.map(\.kind) == [.repo])
    }

    @Test func tiesGoByGoalID() {
        var second = anchors()
        second.goal = goal("aardvark", "Other")
        second.doc = GoalDoc(title: "Other")
        let found = AttachSignals.score(subject(), goals: [anchors(), second], now: now)
        #expect(found.map(\.goal) == ["aardvark", "anchors"])
        #expect(found[0].confidence == found[1].confidence)
    }

    @Test func branchFamilies() {
        #expect(BranchFamily.stem("feature/anchors-redirects") == "anchors")
        #expect(BranchFamily.stem("docs-nav-spike-v1") == "docs-nav")
        #expect(BranchFamily.stem("fix/2841-tables") == "tables")
        #expect(BranchFamily.stem("main") == nil)
        #expect(BranchFamily.stem("v2") == nil)
        #expect(BranchFamily.prefix("feature/anchors-redirects") == "feature/anchors-")
        #expect(BranchFamily.prefix("docs-nav-spike-v1") == "docs-nav-")
        #expect(BranchFamily.prefix("anchors") == "anchors")
    }

    @Test func contextsGatherWhatIsOnAGoal() {
        let snapshot = GoalSnapshot(
            goals: [
                HeedGoal(id: "anchors", title: "Anchors", createdAt: now - 500),
                HeedGoal(id: "old", title: "Old", status: .archived, createdAt: now),
            ],
            links: [
                GoalLink(goal: "anchors", kind: .session, target: "s1", at: now - 100),
                GoalLink(goal: "anchors", kind: .pr, target: "acme/x#3", at: now - 50),
            ],
            docs: ["anchors": anchorsDoc]
        )
        let contexts = GoalContext.build(snapshot: snapshot, subjects: [
            "session:s1": subject("s1", branch: "anchors-a", worktrees: ["/w/anchors-a"], files: ["f"], at: now - 10),
        ])
        #expect(contexts.map(\.goal.id) == ["anchors"])
        let context = contexts[0]
        #expect(context.branches == ["anchors-a"] && context.files == ["f"] && context.pulls == ["acme/x#3"])
        #expect(context.repos == ["acme/docs-toolkit"] && context.lastActivity == now - 10)
    }
}

struct AttachRulesTests {
    @Test func readsRulesAndReportsBadLinesByNumber() {
        let rules = AttachRules(text: """
        # learnt
        never worktree:*/docs-nav* -> nav
        always branch:feature/anchors-* -> anchors

        ignore chat:*   # every chat
        sometimes branch:x -> nav
        never branch:x
        ignore branch:x -> nav
        always -> nav
        always colour:red -> nav
        always branch -> nav
        never title:"fix the build #2" -> nav
        """)
        #expect(rules.rules.map(\.line) == [2, 3, 5, 12])
        #expect(rules.rules[3].conditions == [AttachRule.Condition(.title, "fix the build #2")])
        #expect(rules.problems.map(\.line) == [6, 7, 8, 9, 10, 11])
        #expect(rules.problems[0].description == "line 6: sometimes: a rule starts with always, never or ignore")
        #expect(rules.problems[1].message == "never needs a goal: … -> <goal>")
        #expect(rules.problems[2].message == "ignore takes no goal")
    }

    @Test func linesRoundTrip() {
        for line in [
            "never worktree:*/docs-nav* -> nav", "always branch:feature/anchors-* -> anchors", "ignore chat:*",
            "ignore repo:acme/sandbox title:\"try *\"",
        ] {
            #expect(AttachRules(text: line).rules.first?.text == line)
        }
    }

    @Test func firstIgnoreOrAlwaysSettlesAndNeversAddUp() {
        let rules = AttachRules(text: """
        never branch:anchors-* -> diagrams
        always branch:anchors-* -> anchors
        ignore branch:*
        """)
        let ruling = rules.ruling(subject(branch: "anchors-x"))
        #expect(ruling.goal == "anchors" && ruling.excluded == ["diagrams"] && ruling.rule?.line == 2)
        #expect(rules.ruling(subject(branch: "other")).ignored)
        #expect(rules.ruling(subject(branch: "")).goal == nil)
        // A never before an always for the same goal wins.
        let blocked = AttachRules(text: "never branch:* -> anchors\nalways branch:a* -> anchors")
        #expect(blocked.ruling(subject(branch: "abc")).goal == nil)
        // A rule about a goal that is gone does nothing.
        #expect(rules.ruling(subject(branch: "anchors-x"), goals: ["diagrams"]).ignored)
    }

    @Test func fieldsMatchWhatTheySay() {
        let chat = subject(kind: .chat, title: "Scratch ideas", prompt: "Ask about CI caches", repos: [])
        let session = subject(title: "Scratch ideas", branch: "feature/x", worktrees: ["/w/x-1"])
        func matches(_ line: String, _ s: AttachSubject) -> Bool { AttachRules(text: line).rules[0].matches(s) }
        #expect(matches("ignore chat:scratch*", chat) && !matches("ignore chat:scratch*", session))
        #expect(matches("ignore session:scratch*", session) && !matches("ignore session:scratch*", chat))
        #expect(matches("ignore title:scratch*", chat) && matches("ignore title:scratch*", session))
        #expect(matches("ignore prompt:\"*ci cache*\"", chat))
        // Unquoted, the space splits the pattern: a problem, not a rule.
        #expect(AttachRules(text: "ignore prompt:*ci cache*").rules.isEmpty)
        #expect(matches("ignore worktree:*/x-?", session) && !matches("ignore worktree:*/x-?", chat))
        #expect(matches("ignore repo:acme/*", session) && !matches("ignore repo:acme/*", chat))
        #expect(matches("ignore branch:feature/*", session) && !matches("ignore branch:*", chat))
        #expect(matches("ignore branch:feature/* title:scratch*", session))
        #expect(!matches("ignore branch:feature/* title:other", session))
    }

    @Test func correctionsWriteLinesForThingsLikeThis() {
        #expect(AttachRules.never(subject(worktrees: ["/w/docs-nav-spike-v1"]), goal: "nav").text
            == "never worktree:*/docs-nav-* -> nav")
        #expect(AttachRules.never(subject(branch: "feature/anchors-headings"), goal: "a").text
            == "never branch:feature/anchors-* -> a")
        #expect(AttachRules.ignore(subject(kind: .chat, repos: [])).text == "ignore chat:*")
        #expect(AttachRules.ignore(subject(kind: .chat)).text == "ignore chat:* repo:acme/docs-toolkit")
        #expect(AttachRules.ignore(subject(title: "tidy up", branch: "main")).text == "ignore title:\"tidy up\"")
        // What heed writes reads back as the same rule, and matches the thing it was written for.
        let thing = subject(branch: "feature/anchors-headings")
        let rule = AttachRules.never(thing, goal: "a")
        #expect(AttachRules(text: rule.text).rules.first?.matches(thing) == true)
    }
}

struct AttachPolicyTests {
    private func candidate(_ goal: String, _ confidence: Double) -> AttachCandidate {
        AttachCandidate(goal: goal, confidence: confidence, signals: [AttachSignal(.repo, confidence, "r")])
    }

    private let settings = AttachSettings()

    @Test func thresholdsDecide() {
        func act(_ c: Double) -> AttachAction {
            AttachPolicy.decide(ruling: AttachRuling(), candidates: [candidate("a", c)], settings: settings).action
        }
        #expect(act(0.85) == .attach && act(0.9) == .attach)
        #expect(act(0.849) == .ask && act(0.5) == .ask)
        #expect(act(0.499) == .leave && act(0.1) == .leave)
        let none = AttachPolicy.decide(ruling: AttachRuling(), candidates: [], settings: settings)
        #expect(none.action == .leave && none.goal == nil && none.reason == "no goal matches")
    }

    @Test func closeGoalsAskEvenWhenSure() {
        let close = AttachPolicy.decide(
            ruling: AttachRuling(), candidates: [candidate("a", 0.92), candidate("b", 0.85)], settings: settings,
            titles: ["b": "Bee"]
        )
        #expect(close.action == .ask && close.goal == "a" && close.alternative == "b")
        #expect(close.reason.hasSuffix("close to Bee"))
        let apart = AttachPolicy.decide(
            ruling: AttachRuling(), candidates: [candidate("a", 0.92), candidate("b", 0.82)], settings: settings
        )
        #expect(apart.action == .attach)
    }

    @Test func theModelIsWantedOnlyWhenUnsure() {
        #expect(!AttachPolicy.needsModel([], settings: settings))
        #expect(!AttachPolicy.needsModel([candidate("a", 0.4)], settings: settings))
        #expect(AttachPolicy.needsModel([candidate("a", 0.5)], settings: settings))
        #expect(AttachPolicy.needsModel([candidate("a", 0.84)], settings: settings))
        #expect(!AttachPolicy.needsModel([candidate("a", 0.85)], settings: settings))
        #expect(AttachPolicy.needsModel([candidate("a", 0.9), candidate("b", 0.81)], settings: settings))
        #expect(!AttachPolicy.needsModel([candidate("a", 0.9), candidate("b", 0.8)], settings: settings))
    }

    @Test func theModelMovesTheNumberWithinItsWeight() {
        let sure = AttachOpinion(probabilities: ["a": 1, "b": 0, "none": 0], confidence: 1, choice: "a")
        // 0.4·0.7 + 0.6·1 = 0.88: the model lifts a 0.7 to attach…
        let lifted = AttachPolicy.decide(
            ruling: AttachRuling(), candidates: [candidate("a", 0.7)], opinion: sure, settings: settings
        )
        #expect(lifted.action == .attach && abs(lifted.confidence - 0.88) < 1e-9 && lifted.basis == .model)
        #expect(lifted.reason.contains("model: fits a (100% sure)"))
        // …but not a 0.5 (0.4·0.5 + 0.6 = 0.8).
        let half = AttachPolicy.decide(
            ruling: AttachRuling(), candidates: [candidate("a", 0.5)], opinion: sure, settings: settings
        )
        #expect(half.action == .ask)
        // None, surely: a 0.7 drops below asking.
        let none = AttachOpinion(probabilities: ["a": 0, "none": 1], confidence: 1, choice: "none")
        let dropped = AttachPolicy.decide(
            ruling: AttachRuling(), candidates: [candidate("a", 0.7)], opinion: none, settings: settings
        )
        #expect(dropped.action == .leave && dropped.reason.contains("model: none fits"))
        // An unsure model hardly moves anything.
        let unsure = AttachOpinion(probabilities: ["a": 0, "none": 1], confidence: 0, choice: "none")
        #expect(AttachPolicy.blend([candidate("a", 0.7)], with: unsure)[0].confidence == 0.7)
        // The model can swap two close goals.
        let swap = AttachOpinion(probabilities: ["a": 0.1, "b": 0.9], confidence: 0.8, choice: "b")
        #expect(AttachPolicy.blend([candidate("a", 0.7), candidate("b", 0.65)], with: swap).map(\.goal) == ["b", "a"])
    }

    @Test func rulesComeFirst() {
        let always = AttachRules(text: "always branch:x* -> b").ruling(subject(branch: "xy"))
        let verdict = AttachPolicy.decide(ruling: always, candidates: [candidate("a", 0.99)], settings: settings)
        #expect(verdict.action == .attach && verdict.goal == "b" && verdict.basis == .rule && verdict.confidence == 1)
        #expect(verdict.reason == "rule line 1: always branch:x* -> b")
        let ignore = AttachRules(text: "ignore branch:x*").ruling(subject(branch: "xy"))
        #expect(AttachPolicy.decide(ruling: ignore, candidates: [candidate("a", 0.99)], settings: settings).action
            == .ignore)
        let never = AttachRules(text: "never branch:x* -> a").ruling(subject(branch: "xy"))
        let next = AttachPolicy.decide(
            ruling: never, candidates: [candidate("a", 0.99), candidate("b", 0.6)], settings: settings
        )
        #expect(next.goal == "b" && next.action == .ask)
    }
}

/// Answers every request with fixed JSON, counting the calls.
private final class FakeModel: Sendable {
    let reply: String
    let calls = Mutex(0)
    let prompts = Mutex<[String]>([])
    init(_ reply: String) { self.reply = reply }

    var run: @Sendable (LLMRequest) async throws -> LLMResponse {
        { request in
            self.calls.withLock { $0 += 1 }
            self.prompts.withLock { $0.append(request.call.prompt + "\n" + request.call.system) }
            return LLMResponse(
                text: self.reply, json: LLMDialect.jsonObject(in: self.reply), agent: "claude", model: "model-h",
                tokens: TokenCounts(input: 10, output: 5)
            )
        }
    }
}

struct GoalAttacherTests {
    private let contexts = [anchors(branches: ["anchors-redirects"]), diagrams()]

    @Test func sureSignalsSpendNoCall() async {
        let model = FakeModel("{}")
        let outcome = await GoalAttacher.decide(
            subject(branch: "anchors-redirects"), contexts: contexts, rules: AttachRules(), settings: AttachSettings(),
            decider: LLMDecider(caller: "test", run: model.run), now: now
        )
        #expect(outcome.verdict.action == .attach && outcome.verdict.goal == "anchors")
        #expect(model.calls.withLock { $0 } == 0 && outcome.opinion == nil)
    }

    @Test func unsureSignalsAskTheModelAndFoldItIn() async {
        let model = FakeModel(#"{"goal": {"probabilities": {"anchors": 1, "none": 0}, "confidence": 1}}"#)
        let outcome = await GoalAttacher.decide(
            subject(branch: "feature/anchors-headings"), contexts: contexts, rules: AttachRules(),
            settings: AttachSettings(), decider: LLMDecider(caller: "test", run: model.run), now: now
        )
        #expect(model.calls.withLock { $0 } == 1)
        #expect(outcome.opinion?.choice == "anchors")
        #expect(outcome.verdict.basis == .model && outcome.verdict.action == .attach)
        let prompt = model.prompts.withLock { $0[0] }
        #expect(prompt.contains("Goal anchors: Anchors survive page moves"))
        #expect(prompt.contains("Not the goal: Rewriting the link checker"))
        #expect(prompt.contains("anchors, none"))
    }

    @Test func aFailedOrMissingModelLeavesTheSignals() async {
        let broken = FakeModel("not json")
        let failed = await GoalAttacher.decide(
            subject(branch: "feature/anchors-headings"), contexts: contexts, rules: AttachRules(),
            settings: AttachSettings(), decider: LLMDecider(caller: "test", run: broken.run), now: now
        )
        #expect(failed.verdict.action == .ask && failed.verdict.basis == .signals && failed.modelError != nil)
        let off = await GoalAttacher.decide(
            subject(branch: "feature/anchors-headings"), contexts: contexts, rules: AttachRules(),
            settings: AttachSettings(model: false), decider: LLMDecider(caller: "test", run: broken.run), now: now
        )
        #expect(off.modelError == "attach_model is off" && broken.calls.withLock { $0 } == 1)
    }

    @Test func rulesSpareTheModel() async {
        let model = FakeModel("{}")
        let outcome = await GoalAttacher.decide(
            subject(branch: "feature/anchors-headings"), contexts: contexts,
            rules: AttachRules(text: "ignore branch:feature/*"), settings: AttachSettings(),
            decider: LLMDecider(caller: "test", run: model.run), now: now
        )
        #expect(outcome.verdict.action == .ignore && model.calls.withLock { $0 } == 0)
    }

    @Test func triggersFromDomainChanges() {
        var session = Session(
            id: "s1", title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.working),
            createdAt: now
        )
        session.prompt = ""
        let empty = Domain(repos: [])
        var before = Domain(repos: [])
        before.sessions = [session]
        #expect(AttachTrigger.of(before: empty, after: before).map(\.1) == [.started])
        var after = before
        after.sessions[0].prompt = "do it"
        #expect(AttachTrigger.of(before: before, after: after).map(\.1) == [.prompt])
        session.prompt = "do it"
        before.sessions = [session]
        after = before
        after.sessions[0].trackedPRs = [PullRef(repo: Repo(org: "acme", name: "x"), number: 1)]
        #expect(AttachTrigger.of(before: before, after: after).map(\.1) == [.pull])
        #expect(AttachTrigger.of(before: after, after: after).isEmpty)
        var started = Domain(repos: [])
        started.sessions = [session]
        #expect(AttachTrigger.of(before: empty, after: started).map(\.1) == [.prompt])
    }
}

struct AttachOpsTests {
    private func ops() throws -> (GoalOps, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heed-attach-\(UUID().uuidString)")
        return try (GoalOps(path: ":memory:", files: GoalFiles(root: root)), root)
    }

    private func outcome(_ action: AttachAction, _ goal: String?, _ confidence: Double = 0.9) -> GoalAttacher.Outcome {
        GoalAttacher.Outcome(
            verdict: AttachVerdict(action: action, goal: goal, confidence: confidence, reason: "why"),
            candidates: [], opinion: nil, modelError: nil
        )
    }

    @Test func autoAttachesAndUndoLearnsNever() async throws {
        let (ops, root) = try ops()
        let made = try await ops.create(title: "Anchors", statement: "s", now: now)
        let thing = subject(branch: "feature/anchors-headings")
        let decision = try await ops.act(
            thing,
            trigger: .started,
            outcome: outcome(.attach, made.id),
            tokens: 15,
            now: now
        )
        #expect(decision.id > 0 && decision.state == .settled && decision.label == "auto")
        let link = try #require(try await ops.snapshot().links.first)
        #expect(link.origin == .auto && link.confidence == 0.9 && link.reason == "why")

        let undone = try await ops.undo(now: now)
        #expect(undone.state == .undone && undone.id == decision.id)
        #expect(try await ops.snapshot().links.isEmpty)
        let text = try String(contentsOf: root.appendingPathComponent("attach.rules"), encoding: .utf8)
        #expect(text.hasPrefix("# How heed puts"))
        #expect(text.hasSuffix("you undid untitled on anchors\nnever branch:feature/anchors-* -> anchors\n"))
        #expect(try await ops.rules().rules.count == 1)
        await #expect(throws: AttachOpError.nothingToUndo) { try await ops.undo(now: now) }
    }

    @Test func undoLeavesWhatYouMoved() async throws {
        let (ops, _) = try ops()
        let a = try await ops.create(title: "A", statement: "", now: now)
        let b = try await ops.create(title: "B", statement: "", now: now)
        let decision = try await ops.act(subject(), trigger: .started, outcome: outcome(.attach, a.id), now: now)
        try await ops.attach(GoalLink(goal: b.id, kind: .session, target: "s9", at: now))
        await #expect(throws: AttachOpError.movedSince("untitled")) { try await ops.undo(decision.id, now: now) }
        await #expect(throws: AttachOpError.nothingToUndo) { try await ops.undo(now: now) }
    }

    @Test func answers() async throws {
        let (ops, _) = try ops()
        let a = try await ops.create(title: "A", statement: "", now: now)
        let b = try await ops.create(title: "B", statement: "", now: now)
        func ask(_ id: String, kind: GoalLink.Kind = .session) async throws -> AttachDecision {
            try await ops.act(
                subject(id, kind: kind, branch: "\(id)topic-x"), trigger: .prompt, outcome: outcome(.ask, a.id, 0.6),
                now: now
            )
        }
        let yes = try await ops.answer(ask("s1").id, .yes, now: now)
        #expect(yes.state == .accepted)
        #expect(try await ops.snapshot().links.first { $0.target == "s1" }?.origin == .asked)
        await #expect(throws: AttachOpError.notAProposal) { try await ops.answer(yes.id, .no, now: now) }

        let no = try await ops.answer(ask("s2").id, .no, now: now)
        #expect(no.state == .declined && no.leftUnassigned)
        #expect(try await ops.rulesText().contains("never branch:s2topic-* -> a\n"))

        let moved = try await ops.answer(ask("s3").id, .move(b.id), now: now)
        #expect(moved.state == .moved && moved.goal == b.id)
        let link = try await ops.snapshot().links.first { $0.target == "s3" }
        #expect(link?.goal == b.id && link?.origin == .manual)
        #expect(try await ops.rulesText().contains("never branch:s3topic-* -> a\n"))

        let ignored = try await ops.answer(ask("c1", kind: .chat).id, .ignore, now: now)
        #expect(ignored.state == .ignored)
        #expect(try await ops.rulesText().contains("\nignore chat:* repo:acme/docs-toolkit\n"))
        // The same lesson twice is one line.
        _ = try await ops.answer(ask("c2", kind: .chat).id, .ignore, now: now)
        #expect(try await ops.rulesText().components(separatedBy: "ignore chat:*").count == 2)
        #expect(try await ops.rules().rules.count == 3)
    }

    @Test func aNewLookSupersedesAnOpenAsk() async throws {
        let (ops, _) = try ops()
        let a = try await ops.create(title: "A", statement: "", now: now)
        let first = try await ops.act(subject(), trigger: .started, outcome: outcome(.ask, a.id, 0.6), now: now)
        _ = try await ops.act(subject(), trigger: .ledger, outcome: outcome(.attach, a.id), now: now + 1)
        let all = try await ops.decisions()
        #expect(all.map(\.state) == [.settled, .superseded] && all[1].id == first.id)
    }

    @Test func aSuggestionBecomesAGoalWithItsWork() async throws {
        let (ops, _) = try ops()
        let things = (1 ... 3).map { subject("s\($0)", title: "table widths \($0)", at: now - Double($0) * 3600) }
        for thing in things {
            _ = try await ops.act(thing, trigger: .started, outcome: outcome(.leave, nil, 0.1), now: now)
        }
        let suggestion = try #require(Clusters.suggest(things, minimum: 2).first)
        let goal = try await ops.create(
            suggestion: suggestion, draft: "# Table widths\n\n## Goal\n\nColumns fit.\n\n## Done when\n\n- [ ] fits\n",
            now: now
        )
        let snapshot = try await ops.snapshot()
        #expect(goal.title == "Table widths" && snapshot.goal(goal.id)?.version == 2)
        #expect(snapshot.docs[goal.id]?.doneWhen.map(\.text) == ["fits"])
        #expect(snapshot.links(of: goal.id).map(\.origin) == [.asked, .asked, .asked])
        #expect(try await ops.decisions().allSatisfy { $0.state == .clustered })
    }

    @Test func attachingFindsTheItemTheWorkIsOn() async throws {
        let (ops, _) = try ops()
        let a = try await ops.create(title: "A", statement: "", now: now)
        let byBranch = try await ops.addItem(
            goal: a.id, title: "Something else", source: .you, links: [GoalItem.Link(.branch, "anchors-x")], now: now
        )
        let byWords = try await ops.addItem(goal: a.id, title: "Redirect heading anchors", source: .you, now: now)
        _ = try await ops.addItem(goal: a.id, title: "Unrelated widget", source: .you, now: now)
        _ = try await ops.act(
            subject("s1", branch: "anchors-x"), trigger: .started, outcome: outcome(.attach, a.id), now: now
        )
        let ask = try await ops.act(
            subject("s2", title: "anchors should redirect to headings"), trigger: .prompt,
            outcome: outcome(.ask, a.id, 0.6), now: now
        )
        _ = try await ops.answer(ask.id, .yes, now: now)
        // One shared word is not enough.
        _ = try await ops.act(
            subject("s3", title: "polish the widget"), trigger: .started, outcome: outcome(.attach, a.id), now: now
        )
        let snapshot = try await ops.snapshot()
        func item(_ id: String) -> String? { snapshot.links.first { $0.target == id }?.item }
        #expect(item("s1") == byBranch.id && item("s2") == byWords.id && item("s3") == nil)
        #expect(snapshot.item(byBranch.id)?.linked(.session) == ["s1"])
        #expect(snapshot.item(byWords.id)?.linked(.session) == ["s2"])
    }

    @Test func fixturesKeepRulesInMemory() async throws {
        let ops = try GoalOps.inMemory()
        try await ops.setRules("ignore chat:*\nbad line\n")
        #expect(try await ops.rules().rules.count == 1)
        #expect(try await ops.rules().problems.map(\.line) == [2])
    }
}

struct AttachDayTests {
    @Test func countsTodayOncePerThing() {
        let start = now - 3600
        func decision(
            _ id: String,
            _ action: AttachAction,
            state: AttachDecision.State? = nil,
            at: Date,
            resolved: Date? = nil,
            tokens: Int = 0
        ) -> AttachDecision {
            AttachDecision(
                subject: subject(id), trigger: .started, verdict: AttachVerdict(action: action, goal: "a", reason: ""),
                state: state, resolvedAt: resolved, tokens: tokens, at: at
            )
        }
        let day = AttachDay.of([
            decision("s1", .attach, at: now),
            decision("s2", .ask, at: now, tokens: 1200),
            decision("s3", .leave, at: now - 60),
            decision("s3", .ask, state: .accepted, at: now - 120, resolved: now - 100, tokens: 2000),
            decision("s4", .attach, state: .undone, at: now - 7200, resolved: now),
            decision("s5", .ask, state: .declined, at: now - 30, resolved: now),
            decision("s6", .leave, at: now - 9000),
        ], since: start)
        #expect(day == AttachDay(looked: 4, auto: 1, proposed: 2, left: 3, corrections: 2, tokens: 3200))
        #expect(day.text == "4 looked · 1 auto · 2 proposed · 3 left · 2 corrections · 3.2k tokens")
    }
}

struct ClustersTests {
    private func thing(
        _ id: String,
        _ title: String,
        repo: String? = "acme/docs-toolkit",
        days: Double
    ) -> AttachSubject {
        subject(id, title: title, repos: repo.map { [$0] } ?? [], at: now - days * 86400)
    }

    @Test func groupsSharedWordsInOneRepoAndWindow() throws {
        let found = Clusters.suggest([
            thing("a", "table column widths overflow", days: 0),
            thing("b", "column widths in wide tables", days: 1),
            thing("c", "wide table column header widths", days: 2),
            thing("d", "bump the formatter", days: 0),
            thing("e", "table column widths again", repo: "acme/other", days: 0),
            thing("f", "table column widths, last spring", days: 40),
        ])
        let one = try #require(found.first)
        #expect(found.count == 1)
        #expect(Set(one.subjects.map(\.id)) == ["a", "b", "c"])
        #expect(one.terms.prefix(3) == ["column", "table", "width"] && one.title == "Column table width")
        #expect(one.place == "acme/docs-toolkit · 2 days")
        #expect(one.draftInputs.timeline.count == 3 && one.draftInputs.repo == "acme/docs-toolkit")
        #expect(GoalDoc.parse(one.fallbackDraft).title == "Column table width")
    }

    @Test func tooFewIsNoSuggestion() {
        #expect(Clusters.suggest([thing("a", "table column widths", days: 0), thing("b", "table column", days: 0)])
            .isEmpty)
        #expect(Clusters.suggest([]).isEmpty)
    }

    @Test func linksChainThroughTheMiddle() {
        // a and c share nothing, but each shares two words with b.
        let found = Clusters.suggest([
            thing("a", "lifeline arrow spacing", days: 0), thing("b", "arrow spacing label overlap", days: 0),
            thing("c", "label overlap zoom", days: 0),
        ])
        #expect(found.first?.subjects.count == 3)
    }

    @Test func draftsWithTheGoalDraftPrompt() async throws {
        let model = FakeModel("# Column widths\n\n## Goal\n\nTables fit.\n")
        let text = try await Summarizer(run: model.run).summarize(
            kind: .goalDraft, inputs: SummaryInputs(title: "x", timeline: ["session a"]), caller: "test"
        )
        #expect(GoalDoc.parse(text).title == "Column widths")
        #expect(model.prompts.withLock { $0[0] }.contains("You draft a GOAL.md"))
    }
}

struct GoalAttachAttentionTests {
    @Test func theDetailSaysWhatTheGoalItemIsByItsReason() {
        let decision = AttachDecision(
            subject: subject("c1", kind: .chat, title: "Lifelines"), trigger: .prompt,
            verdict: AttachVerdict(action: .ask, goal: "a", confidence: 0.6, reason: "why"), at: now
        )
        let ask = AttachItemSource(decision: decision, goalTitle: "A").item
        #expect(ask.id == "goal-attach:chat:c1" && ask.kind == .goal && ask.reasons == [.goalAttach])
        #expect(ask.placeholderSummary == "heed is unsure which goal this belongs to.")
        var proposals = ask
        proposals.reasons = [.goalProposals]
        #expect(proposals.placeholderSummary == "Changes to the goal's GOAL.md the work suggests: ↩ shows them.")
        proposals.kind = .agent
        #expect(proposals.placeholderSummary == "An agent waiting on you.")
        proposals.kind = .pr
        #expect(proposals.placeholderSummary == "No summary yet.")
        #expect(GoalAttachAsks.key(of: ask.id) == "chat:c1" && GoalAttachAsks.key(of: "acme/x#1") == nil)
    }
}
