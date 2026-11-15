import Foundation

/// Personas in sessions in the fake world: the anchors session (`s1`, acme) with three personas that join sessions
/// (Docs-site maintainer, your team's style, and the Skeptic, who joins sessions by default), an offer after a lot got
/// built, the panel's
/// verdict, and a PR held with a concern. The calls answer from the scripted text below, read by the real parser.
/// Invented, as every fixture is.
public enum SessionPanelFixtures {
    public static let session = "s1"

    public static let style = Persona(
        name: "Your team's style", knows: ["how acme names tests", "acme's review habits"],
        skepticalAbout: ["tests named after a bug number"], asksFirst: ["Would a reviewer here name it this way?"],
        who: "how acme writes and names its tests", scope: .org("acme"), joins: [.beforePR, .everyPlan],
        source: .learned,
        evidence: ["212 review comments on test names in a year"]
    )

    /// The library's files for the session shots: the Settings fixture's and your team's style. The Skeptic joins
    /// sessions by default, with no file.
    public static var files: [String: String] {
        var files = PersonaLibraryFixtures.files
        files[style.id] = style.render()
        return files
    }

    public static func library() -> PersonaLibrary {
        PersonaLibrary(files: files.compactMapValues(Persona.parse))
    }

    public static let lastMessage = "All five redirects resolve, the slug function is shared, and the sample site has a "
        + "moved page. 14 files changed. I think this part is done."

    public static func built(at: Date) -> SessionMilestone {
        SessionMilestone(
            kind: .built, key: "built@fixture", at: at, files: 14, added: 612, removed: 88,
            quote: "I think this part is done"
        )
    }

    public static let answer = """
    {"verdicts": [
      {"persona": "your-team-s-style", "verdict": "concern", "headline": "RedirectBug2841Tests describes the bug; name it after the behaviour, like AnchorLookupTests.", "reasoning": "Every test class in tests/ is named after what it checks (AnchorLookupTests, SlugCollisionTests), and this one is named after a ticket. tests/RedirectBug2841Tests.cs:14 also puts three behaviours in one fact, so a failure will not say which one broke. A reviewer here would ask for the rename and a fact per behaviour before approving.", "change": "Rename it to AnchorLookupTests and split the fact at line 14 into one per behaviour; then I am happy.", "fix": "team style: test names describe the bug, not the behaviour"},
      {"persona": "docs-site-maintainer", "verdict": "happy", "headline": "Server rules only, no chains. Old URLs keep working.", "reasoning": "The redirects are written as server rules in config/redirects.conf, one hop each, so a reader on an old link lands on the new heading without a second request. The new SlugMap.cs:48 is shared with the page builder, which means a moved page cannot drift from its redirect. Nothing here adds client-side script to the docs pages.", "change": "A redirect that points at another redirect, or a script that rewrites the hash in the browser, would make me a concern.", "fix": null},
      {"persona": "skeptic", "verdict": "happy", "headline": "Scope stayed small.", "reasoning": "The diff touches the redirect rules, the slug map and the tests for them, and nothing else: 14 files, none outside the three directories the task names. The one rename in src/Redirects/ is mechanical. I looked for a second feature riding along and did not find one.", "change": "A change to the build pipeline or the site theme in this diff would turn me into a concern.", "fix": null}
    ]}
    """

    /// The panel's answer before the PR: the same people, the maintainer on what the PR fixed.
    public static let prAnswer = """
    {"verdicts": [
      {"persona": "docs-site-maintainer", "verdict": "happy", "headline": "Server rules fixed; no client-side redirects left.", "reasoning": "The three commits replace the hash-rewriting script in assets/redirect.js with rules in config/redirects.conf, and delete the script. Old links resolve in one hop.", "change": "A rule that loops back to its own source would make me a concern.", "fix": null},
      {"persona": "your-team-s-style", "verdict": "concern", "headline": "Tests are named after the bug, not the behaviour (RedirectBug2841Tests).", "reasoning": "tests/RedirectBug2841Tests.cs is the only test class in the repo named after a ticket number; the others describe what they check. The assertions are fine, the name is what a reviewer will stop on.", "change": "Rename to AnchorLookupTests and I am happy.", "fix": "rename to AnchorLookupTests"},
      {"persona": "skeptic", "verdict": "happy", "headline": "Scope stayed small.", "reasoning": "Three files changed, all of them in the redirect path the PR title names.", "change": "Anything outside that path would turn me into a concern.", "fix": null}
    ]}
    """

    /// The calls, scripted: the look (before a PR, or at a milestone) and a persona's reply.
    public static let calls: SessionLookCalls.Run = { request in
        let text: String = switch request.operation {
        case "panel chat":
            "Rename it to AnchorLookupTests and keep the bug number in a comment; then I'm happy."
        default:
            request.call.prompt.contains(SessionMilestone.Kind.beforePR.title) ? prAnswer : answer
        }
        return LLMResponse(text: text, agent: "claude", model: "sonnet", cost: 0.011, duration: 9)
    }

    /// The strong look's headless read-only run, scripted.
    public static let read: SessionLookCalls.Read = { _, prompt, _ in
        PlanTalker.Answer(
            text: prompt.contains(SessionMilestone.Kind.beforePR.title) ? prAnswer : answer, model: "opus",
            dollars: 0.09
        )
    }

    /// The look the calls answer, read by the real parser.
    public static func look(_ milestone: SessionMilestone, library: PersonaLibrary, repos: [String]) -> SessionLook {
        let personas = SessionPanelInvites.relevant(library, repos: repos, for: milestone.kind)
        let seats = SessionPanelInvites.seats(personas)
        let text = milestone.kind == .beforePR ? prAnswer : answer
        return SessionLook(
            milestone: milestone, seats: seats, verdicts: PanelVerdict.parse(text, seats: seats), at: milestone.at,
            model: "sonnet", seconds: 9, dollars: 0.011,
            diff: milestone.kind == .beforePR ? DiffStat(files: 3, added: 26, removed: 7)
                : DiffStat(files: 14, added: 612, removed: 88),
            tier: .standard
        )
    }

    /// The agent's `gh pr create`, as its permission hook asks.
    public static func prAsk(at: Date) -> PermissionAsk {
        PermissionAsk(
            id: "fixture-pr", session: session, agent: "claude", tool: "Bash",
            command: "gh pr create --title \"Fix broken anchors in redirects\" --fill", askedAt: at
        )
    }
}
