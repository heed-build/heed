import Foundation

/// Personas in sessions in the fake world: the anchors session (`s1`, acme) with three personas that join sessions
/// (the Skeptic before a PR, Docs-site maintainer, and your team's style), an offer after a lot got built, the panel's
/// verdict, and a PR held with a concern. The calls answer from the scripted text below, read by the real parser.
/// Invented, as every fixture is.
public enum SessionPanelFixtures {
    public static let session = "s1"

    public static let style = Persona(
        name: "Your team's style", knows: ["how acme names tests", "acme's review habits"],
        skepticalAbout: ["tests named after a bug number"], asksFirst: ["Would a reviewer here name it this way?"],
        who: "how acme writes and names its tests", scope: .org("acme"), joins: [.everyPlan], source: .learned,
        evidence: ["212 review comments on test names in a year"]
    )

    /// The library's files for the session shots: the Settings fixture's, the Skeptic joining before a PR, and your
    /// team's style.
    public static var files: [String: String] {
        var files = PersonaLibraryFixtures.files
        var skeptic = BuiltInPersonas.persona(PanelInvites.skeptic)
        skeptic.joins = [.goalPanels, .beforePR]
        files[skeptic.id] = skeptic.render()
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
      {"persona": "your-team-s-style", "verdict": "concern", "quote": "RedirectBug2841Tests describes the bug; name it after the behaviour, like AnchorLookupTests.", "fix": "team style: test names describe the bug, not the behaviour"},
      {"persona": "docs-site-maintainer", "verdict": "happy", "quote": "Server rules only, no chains. Old URLs keep working.", "fix": null},
      {"persona": "skeptic", "verdict": "happy", "quote": "Scope stayed small.", "fix": null}
    ]}
    """

    /// The panel's answer before the PR: the same people, the maintainer on what the PR fixed.
    public static let prAnswer = """
    {"verdicts": [
      {"persona": "docs-site-maintainer", "verdict": "happy", "quote": "Server rules fixed; no client-side redirects left.", "fix": null},
      {"persona": "your-team-s-style", "verdict": "concern", "quote": "Tests are named after the bug, not the behaviour (RedirectBug2841Tests).", "fix": "rename to AnchorLookupTests"},
      {"persona": "skeptic", "verdict": "happy", "quote": "Scope stayed small.", "fix": null}
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
        return LLMResponse(text: text, agent: "claude", model: "haiku", cost: 0.002, duration: 5)
    }

    /// The look the calls answer, read by the real parser.
    public static func look(_ milestone: SessionMilestone, library: PersonaLibrary, repos: [String]) -> SessionLook {
        let personas = SessionPanelInvites.relevant(library, repos: repos, for: milestone.kind)
        let seats = SessionPanelInvites.seats(personas)
        let text = milestone.kind == .beforePR ? prAnswer : answer
        return SessionLook(
            milestone: milestone, seats: seats, verdicts: PanelVerdict.parse(text, seats: seats), at: milestone.at,
            model: "haiku", seconds: 5, dollars: 0.002,
            diff: milestone.kind == .beforePR ? DiffStat(files: 3, added: 26, removed: 7)
                : DiffStat(files: 14, added: 612, removed: 88)
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
