import Foundation
@testable import HeedCore
import Testing

struct AttentionRuleFormTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Every example the docs and the fixtures give.
    private static let documented = [
        "mention user:me                boost 3",
        "review requested:me            boost 2",
        "mention team:acme/docs-eng     boost 2",
        "mention team:acme/docs-all     lower",
        "mention team:acme/everyone     ignore",
        "author bot:dependabot          ignore",
        "label \"blocker\"                pin",
        "repo acme/*-archive            ignore",
        "agent blocked|asking           boost 3",
        "ci branch:main                 lower",
        "attach notify",
        "mention team:? lower",
        "author maria boost 1",
        "author me lower",
        "author bot boost 2 notify",
        "author human pin",
        "kind pr|issue boost 1",
        "draft lower",
        "ready boost 1",
        "size >500 lower",
        "size <50 boost 1",
        "age >7d ignore",
        "age <2h boost 2",
        "turn mine boost 1",
        "turn theirs lower",
        "reason teamMention|comment lower",
        "requested:team boost 1",
        "proposals pin notify",
        "agent boost 3",
        "any lower",
        "label \"needs review\" boost 2 pin",
        "mention boost 3  # the important ones",
    ]

    private func form(_ line: String) -> AttentionRuleForm? {
        if case let .form(form) = AttentionRuleForm.read(line) { return form }
        return nil
    }

    @Test(arguments: documented) func everyDocumentedRuleReadsAsAFormAndWritesBackTheSameRule(_ line: String) throws {
        let form = try #require(form(line), "\(line) should be editable")
        let parsed = try #require(try AttentionRules.parse(line, line: 1).get())
        let written = try #require(form.rule, "\(form.line) does not parse")
        #expect(AttentionRuleForm.same(written, parsed), "\(line) → \(form.line)")
        #expect(form.isValid, "\(line): \(form.problems)")
        // Reading the written line again gives the same form: it is stable.
        #expect(self.form(form.line) == form)
    }

    @Test func untouchedLinesAreSavedExactlyAsTheyWere() {
        let lines = Self.documented + ["# a comment of its own", "mention bogus boost 1", "age >1.5m lower"]
        var draft = AttentionRuleDraft(lines: lines)
        #expect(draft.saved == lines)
        draft.move(0, by: 1)
        draft.move(1, by: -1)
        #expect(draft.saved == lines)
        // Editing one line through a form changes that line only.
        draft.edit(2, to: AttentionRuleForm(clauses: [.reason(.mention)], weight: .lower).line)
        #expect(draft.saved[2] == "mention lower")
        #expect(Array(draft.saved[..<2]) == Array(lines[..<2]))
        #expect(Array(draft.saved[3...]) == Array(lines[3...]))
    }

    @Test func linesTheEditorCannotBuildAreReadOnlyNotDropped() {
        #expect(AttentionRuleForm.read("") == .blank)
        #expect(AttentionRuleForm.read("   ") == .blank)
        #expect(AttentionRuleForm.read("# keep me") == .comment("# keep me"))
        guard case let .readOnly(why) = AttentionRuleForm.read("mention bogus boost 1") else {
            Issue.record("a line that does not parse should be read-only")
            return
        }
        #expect(why.contains("bogus"))
        // Parses, but 90 seconds is not a whole number of minutes, hours or days.
        guard case .readOnly = AttentionRuleForm.read("age >1.5m lower") else {
            Issue.record("an age the editor cannot write should be read-only")
            return
        }
        // A quoted team with a space would be written back as two conditions: kept as written instead.
        guard case .readOnly = AttentionRuleForm.read("mention team:\"acme/x review\" boost 1") else {
            Issue.record("a rule the editor would write back differently should be read-only")
            return
        }
        #expect(form("age >90m lower")?.clauses == [.age(greater: true, amount: 90, unit: .m)])
        #expect(form("age >48h lower")?.clauses == [.age(greater: true, amount: 2, unit: .d)])
    }

    @Test func aTrailingCommentIsKept() throws {
        let form = try #require(form("mention boost 3 # the important ones"))
        #expect(form.comment == "the important ones")
        #expect(form.line == "mention boost 3  # the important ones")
        #expect(self.form("label \"a#b\" pin")?.comment == nil)
    }

    @Test(arguments: AttentionClause.Category.allCases) func everyKindOfConditionRoundTrips(
        _ category: AttentionClause.Category
    ) throws {
        let clause: AttentionClause = switch category {
        case .repo: .repo("acme/api|acme/web")
        case .label: .label("good first issue")
        case .team: .team("acme/docs-*")
        case .reasons: .reasons([.agentBlocked, .ciFailed])
        default: category.initial
        }
        #expect(clause.category == category)
        let form = AttentionRuleForm(clauses: [clause], weight: .boost2, notify: true)
        #expect(form.isValid, "\(form.problems)")
        #expect(self.form(form.line) == form, "\(form.line)")
    }

    @Test func clausesTheEditorShowsSeparatelyReadBackAsThemselves() {
        let clauses: [AttentionClause] = [
            .teamUnknown, .requestedOfMe(false), .author(.me), .author(.login("maria")), .author(.bot("renovate")),
            .author(.human), .agent([]), .agent(Set(AgentState.allCases)), .draft(false), .turn(mine: false),
            .size(greater: false, lines: 10), .age(greater: false, amount: 3, unit: .h), .mentionedMe,
        ] + AttentionReasonWord.allCases.map { .reason($0) }
        for clause in clauses {
            let form = AttentionRuleForm(clauses: [clause], weight: .lower)
            #expect(self.form(form.line)?.clauses == [clause], "\(form.line)")
        }
    }

    @Test func everyActionTheEditorOffersParsesAndReadsBack() {
        for weight in AttentionRuleForm.Weight.allCases {
            for pin in [false, true] {
                for notify in [false, true] {
                    let form = AttentionRuleForm(clauses: [.reason(.ci)], weight: weight, pin: pin, notify: notify)
                    let nothing = weight == .unchanged && !pin && !notify
                    #expect(form.isValid == !nothing, "\(form.line)")
                    guard form.isValid else { continue }
                    let back = self.form(form.line)
                    #expect(back?.action == form.action, "\(form.line)")
                    // Mute takes no other action: pin and notify are not written with it.
                    if weight == .ignore { #expect(form.line == "ci ignore") }
                }
            }
        }
    }

    @Test func noConditionsMeansEverything() {
        let form = AttentionRuleForm(weight: .lower)
        #expect(form.line == "any lower")
        #expect(form.isValid)
        #expect(form.summary == "Lower everything.")
    }

    @Test func badValuesAreCaughtWithAMessage() {
        func problem(_ clause: AttentionClause) -> String? {
            AttentionRuleForm(clauses: [clause], weight: .lower).problems.first?.message
        }
        #expect(problem(.repo("")) == "A repo needs a value.")
        #expect(problem(.repo("api"))?.contains("org/name") == true)
        #expect(problem(.repo("*api*")) == nil)
        #expect(problem(.repo("acme/api|web"))?.contains("org/name") == true)
        #expect(problem(.repo("acme/a pi")) == "A repo has no spaces.")
        #expect(problem(.repo("acme/\"api")) != nil)
        #expect(problem(.repo("acme/api#2"))?.contains("comment") == true)
        #expect(problem(.repo("acme/api|")) == "An empty choice around |: write a|b.")
        #expect(problem(.team("docs"))?.contains("org/name") == true)
        #expect(problem(.team("acme/docs")) == nil)
        #expect(problem(.branch("release/1.x")) == nil)
        #expect(problem(.branch("")) != nil)
        #expect(problem(.label("")) == "A label needs a name.")
        #expect(problem(.label("needs review")) == nil)
        #expect(problem(.label(" x")) != nil)
        #expect(problem(.label("say \"hi\"")) != nil)
        #expect(problem(.author(.login("me")))?.contains("menu") == true)
        #expect(problem(.author(.login("Bot")))?.contains("menu") == true)
        #expect(problem(.author(.login("a:b"))) != nil)
        #expect(problem(.author(.login("maria"))) == nil)
        #expect(problem(.author(.bot(""))) != nil)
        #expect(problem(.kind([])) == "Pick at least one kind.")
        #expect(problem(.reasons([])) == "Pick at least one reason.")
        #expect(problem(.size(greater: true, lines: -1)) != nil)
        #expect(problem(.size(greater: false, lines: 0)) != nil)
        #expect(problem(.size(greater: true, lines: 0)) == nil)
        #expect(problem(.age(greater: true, amount: 0, unit: .d)) != nil)
        #expect(problem(.age(greater: true, amount: 1, unit: .d)) == nil)
    }

    @Test func problemsSayWhichConditionTheyAreAbout() {
        let form = AttentionRuleForm(clauses: [.reason(.ci), .repo("api")], weight: .lower)
        #expect(form.problems.map(\.clause) == [1])
        #expect(AttentionRuleForm(clauses: [.reason(.ci)], weight: .unchanged).problems.map(\.message) == [
            "Pick what to do: a weight, pin or notify.",
        ])
    }

    @Test func rulesThatCanNeverMatchAreRefused() {
        func refused(_ clauses: [AttentionClause]) -> Bool {
            !AttentionRuleForm(clauses: clauses, weight: .lower).isValid
        }
        #expect(refused([.draft(true), .draft(false)]))
        #expect(refused([.turn(mine: true), .turn(mine: false)]))
        #expect(refused([.requestedOfMe(true), .requestedOfMe(false)]))
        #expect(refused([.kind([.pr]), .kind([.issue])]))
        #expect(!refused([.kind([.pr, .issue]), .kind([.issue])]))
        #expect(refused([.author(.human), .author(.anyBot)]))
        #expect(refused([.author(.bot("x")), .author(.human)]))
        #expect(refused([.size(greater: true, lines: 500), .size(greater: false, lines: 100)]))
        #expect(refused([.size(greater: true, lines: 5), .size(greater: false, lines: 6)]))
        #expect(!refused([.size(greater: true, lines: 5), .size(greater: false, lines: 7)]))
        #expect(refused([.size(greater: false, lines: 6), .size(greater: true, lines: 5)]))
        #expect(refused([.age(greater: true, amount: 2, unit: .d), .age(greater: false, amount: 24, unit: .h)]))
        #expect(!refused([.age(greater: true, amount: 1, unit: .d), .age(greater: false, amount: 2, unit: .d)]))
        #expect(refused([.age(greater: false, amount: 1, unit: .h), .age(greater: true, amount: 2, unit: .h)]))
        #expect(refused([.reason(.ci), .reason(.ci)]))
        #expect(!refused([.reason(.ci), .repo("acme/*")]))
    }

    @Test func theRuleInPlainWords() {
        let summaries: [(String, String)] = [
            ("review repo acme/api ignore", "Mute review requests in acme/api."),
            ("mention user:me boost 3", "Boost mentions of you by 3 (boost 3 notifies)."),
            (
                "mention team:acme/docs-eng boost 2",
                "Boost mentions of you or your teams through team acme/docs-eng by 2."
            ),
            ("author bot:dependabot|renovate ignore", "Mute items opened by the bot dependabot or renovate."),
            ("agent blocked|asking boost 3 notify", "Boost agents that are blocked or asking by 3, and notify me."),
            ("kind pr|issue draft lower", "Lower PRs or issues that are drafts."),
            ("label \"blocker\" pin", "Pin items labelled blocker."),
            ("attach notify", "Notify about which-goal questions."),
            ("ci branch:main boost 1 pin", "Boost CI failures on branch main by 1, pinned to the top."),
            ("user:me lower", "Lower items where you yourself were mentioned."),
            ("age >7d lower", "Lower items not updated for over 7 days."),
            ("age <1h boost 1", "Boost items updated in the last 1 hour by 1."),
            ("size <50 turn mine boost 1", "Boost items with fewer than 50 lines changed where it is your turn by 1."),
        ]
        for (line, summary) in summaries {
            #expect(form(line)?.summary == summary, "\(line)")
        }
    }

    @Test func howManyItemsARuleMatches() {
        func item(_ id: String, _ repo: String, _ reasons: Set<AttentionReason>) -> AttentionItem {
            let parts = repo.split(separator: "/").map(String.init)
            return AttentionItem(
                id: id, kind: .pr, repo: Repo(org: parts[0], name: parts[1]), number: 1, title: id, url: nil,
                reasons: reasons, updatedAt: now
            )
        }
        let items = [
            item("a", "acme/api", [.reviewRequested]), item("b", "acme/api", [.comment]),
            item("c", "acme/web", [.reviewRequested]), item("d", "acme/api", [.reviewRequested, .ciFailed]),
        ]
        let review = AttentionRuleForm(clauses: [.reason(.review), .repo("acme/api")], weight: .ignore)
        #expect(review.matchCount(in: items, viewer: nil, now: now) == 2)
        #expect(AttentionRuleForm(weight: .lower).matchCount(in: items, viewer: nil, now: now) == 4)
        #expect(AttentionRuleForm(clauses: [.repo("")], weight: .lower).matchCount(in: items, viewer: nil, now: now)
            == 0)
    }

    @Test func aRuleThatRepeatsOrShadowsAnotherIsRefused() {
        let draft = AttentionRuleDraft(lines: ["mention user:me boost 3", "# note", "ci lower", "bogus line"])
        let same = AttentionRuleForm(clauses: [.mentionedMe, .reason(.mention)], weight: .boost3)
        #expect(draft.conflict(same) == "Rule 1 already does this.")
        let sameItems = AttentionRuleForm(clauses: [.reason(.ci)], weight: .ignore)
        #expect(draft.conflict(sameItems)?.hasPrefix("Rule 3 matches exactly these items") == true)
        // Changing a rule in place does not conflict with itself.
        #expect(draft.conflict(sameItems, replacing: 2) == nil)
        #expect(draft.conflict(AttentionRuleForm(clauses: [.reason(.ci), .repo("acme/*")], weight: .ignore)) == nil)
        // After a rule that matches everything, nothing else ever decides.
        let everything = AttentionRuleDraft(lines: ["any lower"])
        #expect(everything.conflict(AttentionRuleForm(clauses: [.reason(.ci)], weight: .boost1))?
            .contains("everything") == true)
        #expect(everything.conflict(AttentionRuleForm(clauses: [.reason(.ci)], weight: .boost1), replacing: nil)
            != nil)
    }

    @Test func aRemovedRuleComesBack() {
        var draft = AttentionRuleDraft(lines: ["a boost 1", "b lower", "c pin"])
        draft.remove(at: 1)
        #expect(draft.lines == ["a boost 1", "c pin"])
        #expect(draft.removed == .init(index: 1, line: "b lower"))
        draft.undoRemove()
        #expect(draft.lines == ["a boost 1", "b lower", "c pin"])
        #expect(draft.removed == nil)
        draft.remove(at: 2)
        draft.remove(at: 0)
        draft.undoRemove()
        #expect(draft.lines == ["a boost 1", "b lower"])
    }

    @Test func suggestionsComeFromWhatHeedHasSeen() {
        let items = [
            AttentionItem(
                id: "1", kind: .pr, repo: Repo(org: "acme", name: "web"), number: 1, title: "", url: nil,
                reasons: [.teamMention], teams: ["acme/docs-eng"], updatedAt: now, author: "Maria",
                labels: ["blocker", "ui"]
            ),
            AttentionItem(
                id: "2", kind: .pr, repo: Repo(org: "acme", name: "api"), number: 2, title: "", url: nil,
                reasons: [.reviewRequested], updatedAt: now, author: "dependabot[bot]", authorIsBot: true,
                labels: ["blocker"]
            ),
        ]
        let suggestions = AttentionRuleSuggestions.from(
            items: items, repos: [Repo(org: "acme", name: "api"), Repo(org: "globex", name: "site")]
        )
        #expect(suggestions.repos == ["acme/api", "acme/web", "globex/site", "acme/*", "globex/*"])
        #expect(suggestions.teams == ["acme/docs-eng"])
        #expect(suggestions.labels == ["blocker", "ui"])
        #expect(suggestions.authors == ["Maria"])
        #expect(suggestions.bots == ["dependabot"])
    }
}
