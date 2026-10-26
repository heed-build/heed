import Foundation

/// The fake world's personas, on `GoalFixtures`' anchors goal: who it needs, worked out from its board, the files, and
/// the session spawned with one. Invented, as every fixture is.
public enum PersonaFixtures {
    static let goal = "anchors-survive-page-moves"

    /// The derivation and the spawns, as `goal_reviews` records.
    public static func records(now: Date = Clock.now) -> [QualityRecord] {
        let base = now.timeIntervalSince1970.rounded(.down)
        func ago(_ hours: Double) -> Date { Date(timeIntervalSince1970: base - hours * 3600) }
        return [
            QualityRecord(goal: goal, at: ago(3 * 24), entry: .personaSpawn(PersonaSpawn(
                persona: Persona.slug(largeSites.name), mode: .session, target: "s2"
            ))),
            QualityRecord(goal: goal, at: ago(0.5), entry: .personas(PersonaDerivation(
                needs: needs, signature: "fixture", goalVersion: 3
            ))),
        ]
    }

    /// Each goal's persona files, by id: the derivation's drafts, with the information architect's edited by you.
    public static func files() -> [String: [String: String]] {
        var texts = Dictionary(uniqueKeysWithValues: needs.map { ($0.id, $0.persona.render()) })
        var edited = architect
        edited.asksFirst.append("which URL do people bookmark?")
        edited.notes = "Ask before proposing a new file format: the team keeps one source of redirects."
        texts[edited.id] = edited.render()
        return [goal: texts]
    }

    static func ref(_ slug: String, _ label: String) -> PersonaRef { PersonaRef(.item, "\(goal)/\(slug)", label: label)
    }

    static let architect = Persona(
        name: "Docs information architect",
        knows: ["site structure", "URL design", "redirect maps"],
        skepticalAbout: ["redirect chains", "rules in two places"],
        asksFirst: ["where does a moved page's old URL go?"],
        may: ["read", "write notes"], mayNot: ["edit code"]
    )

    static let ciSpecialist = Persona(
        name: "CI pipeline specialist",
        knows: ["CI runners", "required checks", "build caches"],
        skepticalAbout: ["checks that only warn", "slow required jobs"],
        asksFirst: ["what fails the build, and when?"]
    )

    static let linkGraph = Persona(
        name: "Link-graph engineer",
        knows: ["cross-reference resolution", "heading ids", "incremental link checks"],
        skepticalAbout: ["ids made from titles", "silent fallbacks"],
        asksFirst: ["what is the anchor's identity?"]
    )

    static let largeSites = Persona(
        name: "Large-site performance engineer",
        knows: ["10k-page builds", "profiling", "allocation"],
        skepticalAbout: ["per-page rebuilds", "unbounded indexes"],
        asksFirst: ["what is the baseline?"]
    )

    static let screenReader = Persona(
        name: "Screen-reader user",
        knows: ["skip links", "heading navigation"],
        skepticalAbout: ["focus lost on redirect"],
        asksFirst: ["where does focus land after a redirect?"]
    )

    static let writer = Persona(
        name: "Technical writer",
        knows: ["docs for contributors", "migration notes"],
        skepticalAbout: ["undocumented flags"],
        asksFirst: ["who reads this first?"]
    )

    static let needs: [PersonaNeed] = [
        PersonaNeed(
            persona: architect, when: .now,
            why: "Two open questions ask where redirect rules live, and assemblies have no answer yet. "
                + "Nobody with that view has looked.",
            evidence: [
                ref("rules-home", "Where do redirect rules live?"),
                ref("assembly-file", "Do assemblies need a redirects file of their own?"),
                PersonaRef(.question, "1", label: "Do assemblies need a redirects file of their own?"),
            ]
        ),
        PersonaNeed(
            persona: ciSpecialist, when: .now,
            why: "The validator only runs locally so far, and done-when asks for it in CI for assemblies.",
            evidence: [
                ref("validator-ci", "Cross-link validator in CI"),
                PersonaRef(.criterion, "2", label: "the cross-link validator runs in CI for assemblies"),
            ]
        ),
        PersonaNeed(
            persona: linkGraph, when: .now,
            why: "Redirects resolve to headings now; ids from heading text are the next break. 2 of 3 items are "
                + "about this.",
            evidence: [
                ref("resolve-targets", "Resolve redirect targets to headings"),
                ref("heading-ids", "Anchor ids from heading text"),
                ref("assembly-redirects", "Redirects for moved assemblies"),
            ],
            // The implementation reviewer's look at #2841 counts as its.
            reviewer: .implementation
        ),
        PersonaNeed(
            persona: largeSites, when: .now,
            why: "The anchor index is rebuilt per page; a 10k-page site is the stated case.",
            evidence: [ref("validator-speed", "Validator speed on a 10k-page site")], reviewer: .perfProber
        ),
        PersonaNeed(
            persona: screenReader, when: .soon,
            why: "Only once redirects land on the website: where focus goes after one.",
            evidence: [ref("website-redirects", "Redirects for moved website pages")]
        ),
        PersonaNeed(
            persona: writer, when: .later,
            why: "redirects.yml and the new check need documenting once the format settles.",
            evidence: [ref("removed-heading", "Should a removed heading redirect to the page top?")]
        ),
    ]
}
