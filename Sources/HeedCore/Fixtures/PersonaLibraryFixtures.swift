import Foundation

/// Settings › Personas in the fake world: two personas proposed from acme's repos, Security turned off, each persona's
/// last verdicts, Add a persona's reads and proposals, and a persona being defined with an agent, tried on a PR. The
/// calls answer from the scripted texts below, read by the real parsers. Invented, as every fixture is.
public enum PersonaLibraryFixtures {
    static let added = Date(timeIntervalSince1970: 1_799_712_000)

    public static let docsSite = Persona(
        name: "Docs-site maintainer", skepticalAbout: ["big redirects files", "client-side redirects"],
        asksFirst: ["Will the old URLs keep working?"], may: ["read", "comment"], mayNot: ["edit code"],
        who: "owns docs-website",
        about: "Owns docs-website's build and hosting. Cares that public URLs never break and that the build stays "
            + "under 4 minutes.",
        scope: .repo("acme/docs-website"), joins: [.goalPanels, .beforePR], source: .repos,
        evidence: [
            "CODEOWNERS: @docs-infra owns /config, /redirects",
            "38 review comments about broken links in 6 months",
            "CI step: check-links, required",
        ],
        added: added
    )

    public static let redirectUser = Persona(
        name: "Redirect-config user", skepticalAbout: ["error messages that name no file"],
        asksFirst: ["Can I tell what broke from the error alone?"], may: ["read", "comment"],
        mayNot: ["edit code"], who: "edits redirects.yml by hand", scope: .org("acme"), joins: [.goalPanels],
        source: .repos, evidence: ["redirects.yml edited by 14 people", "9 issues about redirect errors"],
        added: added
    )

    /// The library's files: the two from acme's repos, and Security turned off.
    public static var files: [String: String] {
        var result = [docsSite.id: docsSite.render(), redirectUser.id: redirectUser.render()]
        if let seat = BuiltInPersonas.seats.first(where: { $0.id == "security" }) {
            var security = BuiltInPersonas.persona(seat)
            security.on = false
            result[security.id] = security.render()
        }
        return result
    }

    /// Each persona's last verdicts, oldest first.
    public static let verdicts: [String: [PanelVerdict.Kind]] = [
        "skeptic": [.not, .not, .concern, .not, .not, .not],
        "purist": [.happy, .concern, .happy, .happy, .concern, .happy, .happy],
        "docs-site-maintainer": [.happy, .happy, .concern, .not, .happy, .happy, .happy],
        "redirect-config-user": [.happy, .happy, .happy, .happy, .happy, .happy, .happy],
        "adversary": [.concern, .not, .happy, .concern, .not, .happy],
        "newcomer": [.happy, .concern, .not, .happy, .happy],
        "ux": [.happy, .happy, .concern],
    ]

    public static let repos = ["acme/docs-toolkit", "acme/docs-website", "acme/sample-site"]

    /// What Add a persona read in acme's three repos.
    public static func digest(now: Date) -> PersonaDigest {
        let months: [Date] = (0 ..< 38).map { now.addingTimeInterval(-Double($0) * 4.7 * 86400) }
        return PersonaDigest(reads: [
            RepoReads(
                repo: "acme/docs-website", docs: ["README.md": "The docs site: build, preview, publish."],
                owners: ["/config @acme/docs-infra", "/redirects @acme/docs-infra"],
                reviewComments: months.map { RepoReads.ReviewComment(
                    path: "redirects/legacy.yml", body: "This link is broken after the move.", at: $0
                ) },
                issues: (0 ..< 160).map { RepoReads.Issue(title: "Broken link \($0)", labels: ["links"]) },
                requiredChecks: ["check-links", "build"], workflows: ["build", "check-links", "deploy", "preview"],
                merges: (0 ..< 12).map { RepoReads.Merge(mergedBy: "docs-bot-\($0 % 4)", author: "writer\($0)") }
            ),
            RepoReads(
                repo: "acme/docs-toolkit", docs: ["README.md": "The docs toolkit CLI.", "CONTRIBUTING.md": "Run it."],
                issues: (0 ..< 180).map { RepoReads.Issue(title: "Getting started \($0)", labels: ["cli"]) },
                requiredChecks: ["test"], workflows: ["release", "test", "lint"],
                merges: (0 ..< 9).map { RepoReads.Merge(mergedBy: "maint\($0 % 3)", author: "writer\($0)") }
            ),
            RepoReads(
                repo: "acme/sample-site", docs: ["README.md": "A sample site."],
                issues: (0 ..< 72).map { RepoReads.Issue(title: "Sample \($0)") },
                workflows: ["build", "lighthouse", "spellcheck"],
                merges: (0 ..< 4).map { RepoReads.Merge(mergedBy: "maint\($0 % 2)", author: "sample\($0)") }
            ),
        ])
    }

    public static let proposals = """
    {"personas": [
    {"name": "Docs-site maintainer", "who": "owns docs-website", "asksFirst": "Will the old URLs keep working?", \
    "skepticalAbout": ["big redirects files"], "evidence": ["CODEOWNERS: @docs-infra owns /config, /redirects", \
    "38 review comments about broken links in 6 months", "CI step: check-links, required"], \
    "summary": "CODEOWNERS · 38 link comments · required check", "strength": 92, "scope": "repo acme/docs-website"},
    {"name": "Redirect-config user", "who": "edits redirects.yml by hand", \
    "asksFirst": "Can I tell what broke from the error alone?", "evidence": ["redirects.yml edited by 14 people", \
    "9 issues about redirect errors"], "summary": "redirects.yml edited by 14 people · 9 issues", "strength": 81, \
    "scope": "org acme"},
    {"name": "CLI first-timer", "who": "reads only the docs", "asksFirst": "Could I use this from the docs alone?", \
    "evidence": ["README quickstart", "6 issues about getting started"], \
    "summary": "README quickstart · 6 issues “getting started”", "strength": 74, "scope": "org acme", \
    "overlaps": "newcomer"},
    {"name": "Release manager", "who": "ships the toolkit", "asksFirst": "What goes in the changelog?", \
    "evidence": ["release.yml", "tags", "CHANGELOG discipline"], "summary": "release.yml · tags · CHANGELOG discipline", \
    "strength": 63, "scope": "repo acme/docs-toolkit"},
    {"name": "Translation contributor", "who": "translates the docs", "asksFirst": "Is the new text easy to translate?", \
    "evidence": ["locales/", "2 contributors"], "summary": "locales/ · 2 contributors", "strength": 41, \
    "scope": "repo acme/docs-website"}
    ]}
    """

    static let described = """
    {"personas": [{"name": "On-call SRE", "who": "gets paged for the docs site", \
    "asksFirst": "Will this page me at night?", "skepticalAbout": ["noisy alerts"], "evidence": [], \
    "summary": "you described them", "strength": 70, "scope": "org acme"}]}
    """

    static let trial = """
    {"verdict": "concern", "quote": "Two of these redirects point at a page that itself redirects. That's a chain; \
    collapse them before merge.", "lines": ["redirects/legacy.yml:41, 88"]}
    """

    /// The scripted model calls.
    public static let calls: PersonaCalls.Run = { request in
        let text = switch request.operation ?? "" {
        case "describe a persona": described
        case "try a persona on a PR": trial
        default: proposals
        }
        return LLMResponse(text: text, agent: "claude", model: "haiku", cost: 0.004, duration: 9)
    }

    /// The PR a trial reads.
    public static let pull = PullSample(
        repo: "acme/docs-website", number: 1912, title: "Move the guides under /docs/guides",
        mergedAt: Date(timeIntervalSince1970: 1_799_600_000),
        diff: "diff --git a/redirects/legacy.yml b/redirects/legacy.yml\n@@ -40,3 +40,5 @@\n+/old: /new\n",
        reviewSaid: ["Collapse the chained redirects before this goes out."], reviewPaths: ["redirects/legacy.yml"]
    )

    /// Docs-site maintainer, a minute into being defined.
    public static var definition: PersonaDefinition {
        var start = docsSite
        start.about = "Owns docs-website's build and hosting."
        start.skepticalAbout = ["redirect chains"]
        start.mayNot = []
        var definition = PersonaDefinition(
            start: start, agent: "claude", via: "claude via ACP", repo: "acme/docs-website"
        )
        definition.reads = ["CODEOWNERS", "netlify.toml", "redirects/ · 412 rules", "38 review threads"]
        definition.received("""
        The people who own /redirects block PRs for three reasons, in order: a public URL stops resolving, a redirect \
        chain gets longer than one hop, and builds that get slower. Should they care about build time, or is that \
        someone else's?
        {"question": null, "options": ["yes, < 4 min is theirs", "no, CI owns that"], "persona": \
        {"skepticalAbout": ["redirect chains", "builds over 4 min"]}}
        """)
        definition.pick(0)
        definition.say("yes. and they hate client-side redirects")
        definition.received("""
        Noted. One more: may they suggest code, or only comment?
        {"question": null, "options": ["comment only", "suggest changes"], "persona": \
        {"skepticalAbout": ["redirect chains", "client-side redirects", "builds over 4 min"], \
        "mayNot": ["suggest code"]}}
        """)
        definition.pick(0)
        definition.seconds = 70
        definition.cost = 0.03
        definition.tried = [1912]
        definition.trial = PersonaTrial.parse(trial, pull: pull)
        return definition
    }
}
