import Foundation
@testable import HeedCore
import Testing

private let good = """
Here is the handoff you asked for.

## Work

Anchors in redirected docs links must keep working across moves. The session fixed the redirect map.

## Done

- Redirects resolve (acme/docs-toolkit#12)
- Anchor test fixtures (acme/docs-toolkit#14)

## Decisions

- Keep the slug code in the toolkit: the website copy drifts.

## Open

- The website vendors its own slug code
- A sample site should prove both

## Risks

- Old links in the wild still break until the website updates.

## Next

1. Delete the website's slug copy
2. Add the sample-site proof
"""

struct SessionHandoffParseTests {
    @Test func readsTheFixedHeadingsAndDropsWordsBeforeTheFirst() throws {
        let handoff = try SessionHandoff.read(good).get()
        #expect(handoff.work.hasPrefix("Anchors in redirected docs links"))
        #expect(handoff.filled == SessionHandoff.Section.allCases)
        #expect(SessionHandoff.items(handoff.done) == [
            "Redirects resolve (acme/docs-toolkit#12)",
            "Anchor test fixtures (acme/docs-toolkit#14)",
        ])
        #expect(SessionHandoff.items(handoff.next) == ["Delete the website's slug copy", "Add the sample-site proof"])
        #expect(handoff.doneCount == 2 && handoff.openCount == 2)
        #expect(!handoff.work.contains("Here is the handoff"))
    }

    @Test func takesAnyLevelCaseOrderAndTheAliasesOfAHeading() throws {
        let text = "### NEXT STEPS:\n- b\n\n# Done so far\n- a\n\n## The Work\nWhat it is\n"
        let handoff = try SessionHandoff.read(text).get()
        #expect(handoff.work == "What it is")
        #expect(handoff.done == "- a")
        #expect(handoff.next == "- b")
    }

    @Test func anUnknownHeadingStaysInItsSectionAndAHeadingInAFenceIsText() throws {
        let text = "## Work\nThe work.\n\n## Done\n- a\n\n### Extra notes\nmore\n\n```\n## Risks\n```\n"
        let handoff = try SessionHandoff.read(text).get()
        #expect(handoff.done.contains("**Extra notes**") && handoff.done.contains("more"))
        #expect(handoff.done.contains("## Risks"))
        #expect(handoff.risks.isEmpty)
    }

    @Test func emptyNoWorkOrOnlyWorkIsNotAHandoff() {
        #expect(SessionHandoff.read("  \n ") == .failure(.empty))
        guard case let .failure(noWork) = SessionHandoff.read("## Done\n- a\n\n## Open\n- b") else {
            Issue.record("a handoff without Work was read")
            return
        }
        #expect(noWork.description.contains("## Work"))
        guard case let .failure(onlyWork) = SessionHandoff.read("## Work\nThe work.") else {
            Issue.record("a handoff of only Work was read")
            return
        }
        #expect(onlyWork.description.contains("only Work"))
        // Prose without headings, a transcript, or a JSON blob is not a handoff either.
        #expect(SessionHandoff.parse("I did a lot of things today.") == nil)
        #expect(SessionHandoff.parse("{\"work\": \"x\"}") == nil)
    }

    @Test func aLongHandoffIsCutAtALine() throws {
        let long = "## Work\nW\n\n## Done\n" + (0 ..< 4000).map { "- item \($0)" }.joined(separator: "\n")
        let handoff = try SessionHandoff.read(long).get()
        #expect(handoff.done.count <= SessionHandoff.maxLength)
        #expect(handoff.done.hasSuffix("item \(handoff.doneCount - 1)"))
    }

    @Test func itRoundTripsThroughGoalMDWithItsHeadingsAsBoldLines() throws {
        let handoff = try SessionHandoff.read(good).get()
        let doc = handoff.apply(to: GoalDoc.new(title: "Anchors", statement: "S"))
        let text = doc.render()
        #expect(text.contains("## Handoff"))
        #expect(text.contains("**Done**"))
        #expect(!text.contains("### "))
        // None of its headings became a section of GOAL.md: the goal has no decisions of its own.
        #expect(GoalDoc.parse(text).decisions.isEmpty)
        // GOAL.md still has its own sections and the handoff is one extra among them.
        let again = GoalDoc.parse(text)
        #expect(again.extras.map(\.heading).contains("Handoff"))
        #expect(SessionHandoff.read(from: again) == handoff)
        // An edit in GOAL.md is what is read next.
        var edited = again
        edited.extras = edited.extras.map {
            $0.heading == "Handoff" ? GoalDoc
                .Extra(heading: "Handoff", body: $0.body + "\n\n**Risks**\n\nNew risk.") : $0
        }
        #expect(SessionHandoff.read(from: edited)?.risks.contains("New risk.") == true)
        // Applying again replaces it, never doubles it.
        #expect(handoff.apply(to: again).extras.count(where: { $0.heading == "Handoff" }) == 1)
    }

    @Test func theAskIsOneLineNamingEveryHeadingAndTheCommand() {
        let text = SessionHandoff.ask.text
        #expect(!text.contains("\n"))
        for section in SessionHandoff.Section.allCases {
            #expect(text.contains("\"## \(section.heading)\""))
        }
        #expect(text.contains("heed goal handoff"))
    }
}

struct HandoffCommandLineTests {
    @Test func handoffReadsStdinUnlessAFileIsGiven() throws {
        let stdin = try GoalCommandLine.request(
            ["goal", "handoff"], environment: ["HEED_SESSION_ID": "s1"], read: { path in path == "-" ? good : "" }
        )
        #expect(stdin.goal?.verb == .handoff)
        #expect(stdin.goal?.text == good)
        #expect(stdin.session == "s1")
        let file = try GoalCommandLine.request(
            ["goal", "handoff", "--file", "/tmp/h.md"], environment: [:], read: { "from \($0)" }
        )
        #expect(file.goal?.text == "from /tmp/h.md")
        #expect(throws: (any Error).self) { try GoalCommandLine.parse(["goal", "handoff", "words"]) }
    }
}

struct HandoffAskTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let claude = AgentInbox.claude(socket: "/tmp/cc-socks/1.sock")

    private func ask(
        state: AgentState = .idle, pane: Bool = true, host: String? = nil, timeout: TimeInterval = 180
    ) -> HandoffAsk? {
        HandoffAsk.begin(
            session: "s1", agent: "claude", state: state, hasAgentPane: pane, host: host, timeout: timeout, now: now
        )
    }

    // MARK: Fallbacks

    @Test func noAgentPaneOrAnExitedOrRemoteAgentSkipsStraightToTheFallbackWithWhy() throws {
        let none = try #require(ask(pane: false))
        #expect(!none.isOpen)
        #expect(none.resolution == .without("its agent isn't running (no agent pane): started without a handoff"))
        let exited = try #require(ask(state: .exited))
        #expect(exited.resolution == .without("its agent has exited: started without a handoff"))
        let remote = try #require(ask(host: "build-box"))
        #expect(remote
            .resolution ==
            .without("its agent runs on build-box, where heed cannot reach it: started without a handoff"))
    }

    @Test func aTimeoutOfZeroNeverAsks() {
        #expect(ask(timeout: 0) == nil)
    }

    @Test func theTimeoutFallsBackWithANoteOnlyOnceTheTimeIsUp() throws {
        var ask = try #require(ask(timeout: 120))
        ask.tick(now: now.addingTimeInterval(119))
        #expect(ask.isOpen && ask.resolution == nil)
        ask.tick(now: now.addingTimeInterval(120))
        guard case let .without(note?) = ask.resolution else {
            Issue.record("no fallback after the timeout")
            return
        }
        #expect(note.contains("claude did not hand off within") && note.hasSuffix("started without a handoff"))
    }

    @Test func skipStartsWithoutItAndWithoutANote() throws {
        var ask = try #require(ask())
        ask.skip()
        #expect(ask.resolution == .without(nil))
        // Nothing later changes it.
        ask.tick(now: now.addingTimeInterval(10000))
        #expect(ask.receive(good) == .failure(.missing("heed is not waiting for a handoff from this session")))
        #expect(ask.resolution == .without(nil))
    }

    @Test func aMalformedHandoffIsRefusedKeepsTheAskOpenAndTheTimeoutSaysWhatItWas() throws {
        var ask = try #require(ask(timeout: 60))
        ask.delivered(.delivered(.claudeInbox))
        guard case .failure = ask.receive("just some words") else {
            Issue.record("a malformed handoff was taken")
            return
        }
        #expect(ask.isOpen)
        #expect(ask.problem != nil)
        // It may try again, and a readable one ends the ask with it.
        guard case .success = ask.receive(good) else {
            Issue.record("a good handoff was refused")
            return
        }
        guard case let .handoff(handoff)? = ask.resolution else {
            Issue.record("no handoff")
            return
        }
        #expect(handoff.work.hasPrefix("Anchors"))
        // Or it never does, and the timeout says what the last try was.
        var other = try #require(self.ask(timeout: 60))
        other.receive("nonsense")
        other.tick(now: now.addingTimeInterval(61))
        guard case let .without(note?) = other.resolution else {
            Issue.record("no fallback")
            return
        }
        #expect(note.contains("its last try:") && note.contains("no Work section"))
    }

    // MARK: Delivery

    @Test func deliveryStatesMoveTheAsk() throws {
        var ask = try #require(ask())
        ask.delivered(.waiting("the agent is working"))
        #expect(ask.unsent && ask.detail == "waiting: the agent is working")
        ask.delivered(.delivered(.claudeInbox))
        #expect(!ask.unsent && ask.isOpen)
        #expect(ask.detail == "asked through Claude's inbox: it is writing it")
        // Once sent, a later "waiting" does not unsend it.
        ask.delivered(.waiting("x"))
        #expect(!ask.unsent)
        var failed = try #require(self.ask())
        failed.delivered(.failed("claude has no agent pane"))
        #expect(failed.resolution == .without("claude has no agent pane: started without a handoff"))
        var held = try #require(self.ask())
        held.delivered(.queued(.claudeInbox, "held for your approval in the session"))
        #expect(held.isOpen && !held.unsent)
    }

    @Test func neverTypesIntoABusySession() {
        // Without an inbox the ask is typed, so only while idle or done and not while you type there.
        for state in [AgentState.working, .blocked, .asking, .limited, .exited] {
            let route = HandoffAsk.route(
                state: state, lastTyped: nil, inbox: nil, settings: ChannelSettings(), now: now
            )
            #expect(route != .type, "typed into a \(state) session")
            guard case .wait = route else {
                Issue.record("\(state): \(route)")
                continue
            }
        }
        // Idle and done, nobody typing: typed.
        for state in [AgentState.idle, .done] {
            #expect(HandoffAsk
                .route(state: state, lastTyped: nil, inbox: nil, settings: ChannelSettings(), now: now) == .type)
        }
        // You typed there a moment ago: it waits.
        #expect(HandoffAsk.route(
            state: .idle, lastTyped: now.addingTimeInterval(-5), inbox: nil, settings: ChannelSettings(), now: now
        ) != .type)
        // The same with an inbox turned off in settings: still never typed while busy.
        let off = ChannelSettings(claudeInbox: false)
        #expect(HandoffAsk.route(state: .working, lastTyped: nil, inbox: claude, settings: off, now: now) != .type)
    }

    @Test func anInboxHoldsTheAskSoItGoesWhateverTheAgentDoesAndNothingIsTyped() {
        for state in [AgentState.working, .blocked, .asking, .idle, .done] {
            #expect(
                HandoffAsk.route(state: state, lastTyped: now, inbox: claude, settings: ChannelSettings(), now: now)
                    == .channel(claude)
            )
        }
        // But not to an agent that has exited.
        #expect(HandoffAsk
            .route(state: .exited, lastTyped: nil, inbox: claude, settings: ChannelSettings(), now: now) !=
            .channel(claude))
    }
}

struct HandoffPromotionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func theHandoffReplacesTheStaleStatementAndWhatItLeftOpenIsWhatWasFound() throws {
        let handoff = try SessionHandoff.read(good).get()
        let draft = GoalPromotion(session: "s1", title: "Anchors", statement: "Fix broken anchors.", found: ["old"])
        let promoted = draft.handingOff(handoff)
        #expect(promoted.statement.hasPrefix("Anchors in redirected docs links"))
        #expect(promoted.found == ["The website vendors its own slug code", "A sample site should prove both"])
        #expect(promoted.handoff == handoff)
        // A handoff with nothing open keeps what heed had found.
        let quiet = try SessionHandoff.read("## Work\nW\n\n## Done\n- a").get()
        #expect(draft.handingOff(quiet).found == ["old"])
    }

    @Test func promotingStoresTheHandoffInGoalMDAndTheTLDRReflectsIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("heed-handoff-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let ops = try GoalOps(
            path: dir.appendingPathComponent("goals.sqlite").path,
            files: GoalFiles(root: dir.appendingPathComponent("goals"))
        )
        let handoff = try SessionHandoff.read(good).get()
        let promotion = GoalPromotion(session: "s1", title: "Anchors survive moves", statement: "old prompt")
            .handingOff(handoff)
        let goal = try await ops.promote(promotion, now: now)
        let doc = try await GoalDoc.parse(ops.text(of: goal.id))
        #expect(SessionHandoff.read(from: doc) == handoff)
        #expect(doc.goal.hasPrefix("Anchors in redirected docs links"))
        // The session is on it as part 1, as before.
        #expect(try await ops.snapshot().links.contains { $0.target == "s1" })
        // The TL;DR says so.
        let wizard = GoalWizard(goal: goal.id, at: now)
        let inputs = TLDRInputs.build(wizard, doc: doc, goalVersion: 2)
        #expect(inputs.settled.first == "Started from the session's handoff: 2 done, 2 open, 1 risk, 2 next.")
        #expect(inputs.steps.first { $0.step == .plan }?.detail.contains("from a handoff") == true)
        // And the planner reads it.
        let prompt = PlanTalk.prompt(
            title: "t", statement: "s", turns: [], plan: nil, repos: [], weakest: nil, handoff: handoff.promptText
        )
        #expect(prompt.contains("# Handoff from the session") && prompt.contains("**Done**"))
        #expect(!PlanTalk.prompt(title: "t", statement: "s", turns: [], plan: nil, repos: [], weakest: nil)
            .contains("Handoff"))
    }
}
