import Foundation
@testable import HeedCore
import Testing

private let now = Date(timeIntervalSince1970: 1_800_000_000)

struct PersonaLibraryFileTests {
    /// A file written before the library: every new field at its default, and it renders exactly as it was.
    @Test func anOldFileReadsAndRendersAsItWas() throws {
        let old = """
        name: Release engineer
        knows: signed builds
        skeptical about: unsigned artifacts
        asks first: what does a user download?
        may: read, run
        may not: edit code

        A note of my own.
        """
        let persona = try #require(Persona.parse(old))
        #expect(persona.scope == .everywhere)
        #expect(persona.joins.isEmpty)
        #expect(persona.source == .yours)
        #expect(persona.on)
        #expect(persona.evidence.isEmpty)
        #expect(persona.render() == old + "\n")
        #expect(persona.brief.hasPrefix("You are Release engineer.\n"))
    }

    @Test func theLibrarysLinesRoundTrip() throws {
        var persona = PersonaLibraryFixtures.docsSite
        persona.on = false
        persona.sharpens = "newcomer"
        let text = persona.render()
        #expect(text.contains("scope: repo acme/docs-website\n"))
        #expect(text.contains("joins: goal panels, before a PR\n"))
        #expect(text.contains("source: repos\n"))
        #expect(text.contains("on: no\n"))
        #expect(text.contains("evidence:\n- CODEOWNERS: @docs-infra owns /config, /redirects\n"))
        #expect(Persona.parse(text) == persona)
    }

    @Test func readsTheLibrarysLinesLoosely() throws {
        let persona = try #require(Persona.parse("""
        name: SRE
        Scope: org: acme
        joins: panels, before a PR, nonsense
        source: from your repos
        evidence: paged 4 times; owns alerts.yml
        on: off
        """))
        #expect(persona.scope == .org("acme"))
        #expect(persona.joins == [.goalPanels, .beforePR])
        #expect(persona.source == .repos)
        #expect(persona.evidence == ["paged 4 times", "owns alerts.yml"])
        #expect(!persona.on)
    }

    /// Records in `goal_reviews` written before the library still decode.
    @Test func oldRecordsDecode() throws {
        let json = #"{"name":"X","knows":[],"skepticalAbout":[],"asksFirst":[],"may":[],"mayNot":[],"notes":""}"#
        let persona = try JSONDecoder().decode(Persona.self, from: Data(json.utf8))
        #expect(persona.name == "X")
        #expect(persona.scope == .everywhere)
        let again = try JSONDecoder().decode(Persona.self, from: JSONEncoder().encode(PersonaLibraryFixtures.docsSite))
        #expect(again == PersonaLibraryFixtures.docsSite)
    }
}

struct PersonaScopeTests {
    @Test func parsesEveryWayOfWritingIt() {
        #expect(PersonaScope(text: "everywhere") == .everywhere)
        #expect(PersonaScope(text: "org acme") == .org("acme"))
        #expect(PersonaScope(text: "org: acme") == .org("acme"))
        #expect(PersonaScope(text: "repo acme/site") == .repo("acme/site"))
        #expect(PersonaScope(text: "acme/site") == .repo("acme/site"))
        #expect(PersonaScope(text: "acme") == .org("acme"))
        #expect(PersonaScope(text: "  ") == nil)
    }

    @Test func theOrgWall() {
        #expect(PersonaScope.everywhere.applies(to: []))
        #expect(PersonaScope.org("acme").applies(to: ["ACME/site"]))
        #expect(!PersonaScope.org("acme").applies(to: ["globex/site"]))
        #expect(!PersonaScope.org("acme").applies(to: []))
        #expect(PersonaScope.repo("acme/site").applies(to: ["acme/site", "globex/x"]))
        #expect(!PersonaScope.repo("acme/site").applies(to: ["acme/other"]))
    }
}

struct PersonaLibraryMergeTests {
    let library = PersonaLibrary(files: PersonaLibraryFixtures.files.compactMapValues(Persona.parse))

    @Test func builtInsFirstThenYours() {
        let ids = library.entries.map(\.id)
        #expect(ids.prefix(4) == ["skeptic", "purist", "scope-keeper", "ux"])
        #expect(ids.count == BuiltInPersonas.seats.count + 2)
        #expect(ids.suffix(2) == ["docs-site-maintainer", "redirect-config-user"])
        #expect(library.count(.builtIn) == 11)
        #expect(library.count(.repos) == 2)
        #expect(library.entry("skeptic")?.persona.asksFirst == ["Should we do this at all?"])
    }

    @Test func aFileStandsInForItsBuiltIn() {
        let security = library.entry("security")
        #expect(security?.hasFile == true)
        #expect(security?.persona.on == false)
        #expect(security?.isBuiltIn == true)
    }

    @Test func offersOnlyWhatIsOnAndInScope() {
        let ids = Set(library.offered(for: ["globex/markgraph"]).map(\.id))
        #expect(!ids.contains("security"))
        #expect(!ids.contains("redirect-config-user"))
        #expect(!ids.contains("docs-site-maintainer"))
        #expect(ids.contains("skeptic"))
        let acme = Set(library.offered(for: ["acme/docs-website"]).map(\.id))
        #expect(acme.contains("redirect-config-user"))
        #expect(acme.contains("docs-site-maintainer"))
    }

    @Test func noTeamStyleUnlessOneExists() {
        #expect(library.teamStyle(for: ["acme/docs-website"]) == nil)
        var learned = Persona(name: "Your team's style", source: .learned)
        learned.scope = .org("acme")
        let with = PersonaLibrary(files: [learned.id: learned])
        #expect(with.teamStyle(for: ["acme/x"])?.id == learned.id)
        #expect(with.teamStyle(for: ["globex/x"]) == nil)
    }
}

struct PanelFromLibraryTests {
    let plan = Set<PanelInvites.Signal>([.authNet])

    @Test func withoutTheLibraryNothingChanges() {
        #expect(PanelInvites.invite(signals: plan).map(\.id) == ["skeptic", "purist", "scope-keeper", "ux", "security"])
    }

    @Test func offIsNotInvitedAndEditedSitsAsEdited() {
        var purist = BuiltInPersonas.persona(PanelInvites.purist)
        purist.asksFirst = ["Is there one way to do it?"]
        let files = PersonaLibraryFixtures.files.compactMapValues(Persona.parse).merging([purist.id: purist]) { $1 }
        let library = PersonaLibrary(files: files)
        let seats = PanelInvites.invite(signals: plan, library: library, scope: ["globex/x"])
        #expect(!seats.contains { $0.id == "security" })
        let seated = seats.first { $0.id == "purist" }
        #expect(seated?.brief.contains("Is there one way to do it?") == true)
        #expect(seats.first { $0.id == "skeptic" } == PanelInvites.skeptic)
    }

    @Test func libraryPersonasJoinOnlyInTheirScope() {
        let library = PersonaLibrary(files: PersonaLibraryFixtures.files.compactMapValues(Persona.parse))
        let acme = PanelInvites.invite(signals: [], library: library, scope: ["acme/docs-website"]).map(\.id)
        #expect(acme.contains("docs-site-maintainer"))
        #expect(acme.contains("redirect-config-user"))
        let globex = PanelInvites.invite(signals: [], library: library, scope: ["globex/markgraph"]).map(\.id)
        #expect(!globex.contains("docs-site-maintainer"))
        #expect(!globex.contains("redirect-config-user"))
    }

    @Test func aSharperOneTakesTheBuiltInsSeatInItsScope() {
        var sharper = Persona(name: "Newcomer for acme", who: "reads only the docs", scope: .org("acme"))
        sharper.sharpens = "newcomer"
        sharper.joins = [.goalPanels]
        let library = PersonaLibrary(files: [sharper.id: sharper])
        let acme = PanelInvites.invite(signals: [.publicPackage], library: library, scope: ["acme/cli"]).map(\.id)
        #expect(acme.contains(sharper.id))
        #expect(!acme.contains("newcomer"))
        let globex = PanelInvites.invite(signals: [.publicPackage], library: library, scope: ["globex/cli"]).map(\.id)
        #expect(globex.contains("newcomer"))
        #expect(!globex.contains(sharper.id))
    }
}

struct PersonaProposalTests {
    let library = PersonaLibrary(files: [:]).personas

    @Test func rankedStrongestFirstWithEvidenceAndOverlaps() {
        let proposals = PersonaProposals.parse(
            PersonaLibraryFixtures.proposals, repos: PersonaLibraryFixtures.repos, library: library, now: now
        )
        #expect(proposals.map(\.strength) == [92, 81, 74, 63, 41])
        #expect(proposals[0].persona.scope == .repo("acme/docs-website"))
        #expect(proposals[0].persona.source == .repos)
        #expect(proposals[0].persona.evidence.count == 3)
        #expect(proposals[0].summary == "CODEOWNERS · 38 link comments · required check")
        #expect(proposals[2].overlaps == "newcomer")
        #expect(proposals[0].overlaps == nil)
    }

    @Test func dropsTheUnfoundedAndKeepsInsideTheWall() {
        let text = """
        {"personas": [
        {"name": "Ghost", "strength": 99, "evidence": []},
        {"name": "Owner", "strength": 140, "evidence": ["CODEOWNERS"], "scope": "org globex"},
        {"name": "owner", "strength": 20, "evidence": ["x"]},
        {"name": "Anyone", "strength": "55", "evidence": ["README"], "scope": "everywhere"}
        ]}
        """
        let proposals = PersonaProposals.parse(text, repos: ["acme/a", "acme/b"], library: [], now: now)
        #expect(proposals.map(\.persona.name) == ["Owner", "Anyone"])
        #expect(proposals[0].strength == 100)
        // Another org's scope, or everywhere, from acme's repos: acme.
        #expect(proposals[0].persona.scope == .org("acme"))
        #expect(proposals[1].persona.scope == .org("acme"))
        #expect(PersonaProposals.scope(nil, repos: ["acme/a", "globex/b"]) == .repo("acme/a"))
        #expect(PersonaProposals.scope(nil, repos: ["acme/a"]) == .repo("acme/a"))
    }

    @Test func atMostSix() {
        let rows = (1 ... 9).map { #"{"name": "P\#($0)", "strength": \#($0), "evidence": ["e"]}"# }
        let proposals = PersonaProposals.parse(
            "{\"personas\": [\(rows.joined(separator: ","))]}", repos: ["acme/a"], library: [], now: now
        )
        #expect(proposals.count == PersonaProposals.limit)
        #expect(proposals.first?.persona.name == "P9")
    }

    @Test func overlapByWhatTheyAsk() {
        let newcomer = BuiltInPersonas.persona(PanelInvites.seats(for: .publicPackage)[1])
        let first = Persona(name: "CLI first-timer", asksFirst: ["Could I use this from the docs alone?"])
        #expect(PersonaProposals.overlap(first, in: [newcomer])?.id == "newcomer")
        let other = Persona(name: "Release manager", asksFirst: ["What goes in the changelog?"])
        #expect(PersonaProposals.overlap(other, in: [newcomer]) == nil)
    }

    @Test func sharpenOrKeepBoth() throws {
        let library = PersonaLibrary(files: [:])
        let proposal = try #require(PersonaProposals.parse(
            PersonaLibraryFixtures.proposals, repos: PersonaLibraryFixtures.repos, library: library.personas, now: now
        ).first { $0.overlaps != nil })
        let sharpened = PersonaProposals.resolve(proposal, .sharpen, library: library)
        #expect(sharpened.persona.name == "Newcomer for acme")
        #expect(sharpened.persona.sharpens == "newcomer")
        #expect(sharpened.overlaps == nil)
        let kept = PersonaProposals.resolve(proposal, .keep, library: library)
        #expect(kept.persona.name == "CLI first-timer")
        #expect(kept.overlaps == nil)
    }
}

struct PersonaDigestTests {
    @Test func countsWhatItRead() {
        let digest = PersonaLibraryFixtures.digest(now: now)
        #expect(digest.count(.docs, now: now) == "3 repos")
        #expect(digest.count(.owners, now: now) == "6 months")
        #expect(digest.count(.issues, now: now) == "412")
        #expect(digest.count(.checks, now: now) == "9")
        #expect(digest.count(.merges, now: now) == "23 people")
    }

    @Test func theTextIsCompact() {
        let digest = PersonaLibraryFixtures.digest(now: now)
        let text = digest.render()
        #expect(text.display.count <= PersonaDigest.limit + 2)
        #expect(text.display.contains("# acme/docs-website"))
        #expect(text.display.contains("CODEOWNERS: /config @acme/docs-infra"))
        #expect(text.display.contains("review comments: 38, most on redirects/ (38)"))
        #expect(digest.render(limit: 500).display.count <= 502)
    }

    @Test func readsGitHubsAnswers() {
        let comments = #"[{"path":"a/b/c.md","body":"broken","created_at":"2026-01-02T00:00:00Z"}]"#
        #expect(RepoReads.reviewComments(Data(comments.utf8)).first?.path == "a/b/c.md")
        let issues = #"[{"title":"t","labels":[{"name":"bug"}]}]"#
        #expect(RepoReads.issues(Data(issues.utf8)) == [RepoReads.Issue(title: "t", labels: ["bug"])])
        let merges = #"[{"author":{"login":"a"},"mergedBy":{"login":"m"},"files":[{"path":"x/y"}]},{"mergedBy":null}]"#
        #expect(RepoReads.merges(Data(merges.utf8)) == [RepoReads.Merge(mergedBy: "m", author: "a", paths: ["x/y"])])
        let branch = #"{"protection":{"required_status_checks":{"contexts":["build"],"checks":[{"context":"lint"}]}}}"#
        #expect(RepoReads.requiredChecks(Data(branch.utf8)) == ["build", "lint"])
        #expect(RepoReads.owners("# owners\n/docs @a # them\n\n* @b") == ["/docs @a", "* @b"])
        #expect(RepoReads.folder("redirects/legacy.yml") == "redirects/")
        #expect(RepoReads.folder("README.md") == "README.md")
    }
}

struct PersonaDefinitionTests {
    @Test func marksWhatTheAgentAdded() {
        let definition = PersonaLibraryFixtures.definition
        #expect(definition.draft.skepticalAbout == ["redirect chains", "client-side redirects", "builds over 4 min"])
        #expect(definition.draft.mayNot == ["suggest code"])
        #expect(definition.changed == ["client-side redirects", "builds over 4 min", "suggest code"])
        #expect(definition.turns.count == 5)
        #expect(definition.openQuestion == nil)
    }

    @Test func aReplyWithoutJSONIsAllText() {
        let read = PersonaDefinition.read("Just thinking.")
        #expect(read.text == "Just thinking.")
        #expect(read.patch == nil)
    }
}

struct PersonaTrialTests {
    @Test func linksOnlyIntoTheDiff() throws {
        let text = #"{"verdict": "concern", "quote": "“A chain.”", "lines": ["redirects/legacy.yml:41", "nope.md:1"]}"#
        let trial = try #require(PersonaTrial.parse(text, pull: PersonaLibraryFixtures.pull))
        #expect(trial.verdict == .concern)
        #expect(trial.quote == "A chain.")
        #expect(trial.lines == ["redirects/legacy.yml:41"])
        #expect(trial.agrees == true)
        #expect(trial.reviewSaid == "Collapse the chained redirects before this goes out.")
        #expect(PersonaTrial.parse("{}", pull: PersonaLibraryFixtures.pull) == nil)
    }

    @Test func picksARecentReadablePR() {
        let pulls = [
            PullListing(number: 1, title: "old", mergedAt: now.addingTimeInterval(-900), size: 40),
            PullListing(number: 2, title: "huge", mergedAt: now, size: 9000),
            PullListing(number: 3, title: "new", mergedAt: now.addingTimeInterval(-60), size: 30),
        ]
        #expect(PersonaTrial.pick(pulls, tried: [])?.number == 3)
        #expect(PersonaTrial.pick(pulls, tried: [3])?.number == 1)
        #expect(PersonaTrial.pick(pulls, tried: [1, 3])?.number == 2)
        #expect(PersonaTrial.pick(pulls, tried: [1, 2, 3]) == nil)
    }

    @Test func whatReviewSaid() {
        let comments = #"[{"path":"a.md","body":"fix this"}]"#
        let reviews = #"{"reviews":[{"body":""},{"body":"LGTM after the fix"}]}"#
        let review = PersonaTrial.review(comments: Data(comments.utf8), reviews: Data(reviews.utf8))
        #expect(review.said == ["fix this", "LGTM after the fix"])
        #expect(review.paths == ["a.md"])
    }
}

struct PersonaVerdictHistoryTests {
    @Test func theLastSevenNewestLast() {
        var older = GoalWizard(goal: "a", at: now)
        older.panel.rounds = [[PanelVerdict(seat: "skeptic", kind: .not, quote: "")]]
        older.updatedAt = now
        var newer = GoalWizard(goal: "b", at: now)
        newer.updatedAt = now.addingTimeInterval(60)
        newer.panel.rounds = (0 ..< 7).map { index in
            [PanelVerdict(seat: "skeptic", kind: index == 6 ? .concern : .happy, quote: "")]
        }
        let history = PersonaVerdicts.history([newer, older])
        #expect(history["skeptic"]?.count == 7)
        #expect(history["skeptic"]?.last == .concern)
        #expect(history["skeptic"]?.first == .happy)
        #expect(PersonaVerdicts.history([older])["skeptic"] == [.not])
    }
}

struct PersonaKeysTests {
    /// Every key the Settings window reads for Personas binds: none waits on a NORMAL key (`]` would, on `]p`).
    @Test func everyKeyBinds() {
        let built = Keymaps.build()
        for scope in PersonaKeys.scopes {
            #expect(!built.problems.contains { $0.message.contains("[keys.\(scope)]") }, "\(scope)")
            for (_, command) in PersonaKeys.scoped[scope] ?? [] {
                #expect(built.scoped[scope]?.keys(for: command).isEmpty == false, "\(scope): \(command)")
            }
        }
    }
}
