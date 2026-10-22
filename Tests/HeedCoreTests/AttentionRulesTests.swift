import Foundation
@testable import HeedCore
import Testing

struct AttentionRulesTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(
        _ reasons: Set<AttentionReason>, kind: AttentionItem.Kind = .pr, repo: String = "acme/docs",
        teams: Set<String> = [], author: String? = nil, bot: Bool = false, labels: [String] = [],
        branch: String? = nil, agent: AgentState? = nil, draft: Bool? = nil, size: Int? = nil,
        age: TimeInterval = 60, last: String? = nil
    ) -> AttentionItem {
        let parts = repo.split(separator: "/").map(String.init)
        return AttentionItem(
            id: UUID().uuidString, kind: kind, repo: Repo(org: parts[0], name: parts[1]), number: 1, title: "t",
            url: nil, reasons: reasons, teams: teams, updatedAt: now.addingTimeInterval(-age), author: author,
            authorIsBot: bot, labels: labels, isDraft: draft, size: size, branch: branch, agentState: agent,
            lastCommenter: last
        )
    }

    private func rule(_ line: String) throws -> AttentionRule {
        let rules = AttentionRules(lines: [line])
        #expect(rules.problems.isEmpty, "\(rules.problems)")
        return try #require(rules.rules.first)
    }

    private func matches(_ line: String, _ item: AttentionItem) throws -> Bool {
        try rule(line).matches(item, viewer: "you", now: now)
    }

    // MARK: The brief's rules

    @Test func theBriefsRulesParse() {
        let rules = AttentionRules(lines: [
            "mention user:me                     boost 3",
            "review requested:me                 boost 2",
            "mention team:acme/docs-eng          boost 2",
            "mention team:acme/docs-all          lower",
            "mention team:acme/everyone          ignore",
            "author bot:dependabot               ignore",
            "label \"blocker\"                     pin",
            "repo acme/*-archive                 ignore",
            "agent blocked|asking                boost 3",
            "ci branch:main                      lower",
        ])
        #expect(rules.problems.isEmpty)
        #expect(rules.rules.map(\.line) == Array(1 ... 10))
        #expect(rules.rules.map(\.action.text) == [
            "boost 3", "boost 2", "boost 2", "lower", "ignore", "ignore", "pin", "ignore", "boost 3", "lower",
        ])
        #expect(rules.rules[2].match == "mention team:acme/docs-eng")
    }

    @Test func firstMatchWins() {
        let rules = AttentionRules(lines: [
            "mention team:acme/everyone ignore",
            "mention boost 2",
            "any lower",
        ])
        let everyone = item([.teamMention], teams: ["acme/everyone"])
        let other = item([.teamMention], teams: ["acme/docs-eng"])
        let review = item([.reviewRequested])
        #expect(rules.outcome(for: everyone, viewer: "you", now: now).rule?.line == 1)
        #expect(rules.outcome(for: other, viewer: "you", now: now).rule?.line == 2)
        #expect(rules.outcome(for: review, viewer: "you", now: now).rule?.line == 3)
        #expect(AttentionRules(lines: ["mention boost"]).outcome(for: review, viewer: nil, now: now).rule == nil)
    }

    // MARK: Inputs

    @Test func mentionsDirectAndByTeam() throws {
        #expect(try matches("mention user:me boost 3", item([.mentioned])))
        #expect(try !matches("mention user:me boost 3", item([.teamMention], teams: ["acme/docs-eng"])))
        #expect(try matches("mention boost 1", item([.teamMention])))
        #expect(try matches("mention team:acme/docs-* boost 2", item([.teamMention], teams: ["acme/docs-eng"])))
        #expect(try !matches("mention team:acme/docs-* boost 2", item([.teamMention], teams: ["acme/web"])))
        #expect(try matches("mention team:ACME/Docs-Eng boost 2", item([.teamMention], teams: ["acme/docs-eng"])))
        // The team is unknown: team:? matches it, a named team does not.
        #expect(try matches("mention team:? lower", item([.teamMention])))
        #expect(try !matches("mention team:? lower", item([.teamMention], teams: ["acme/docs-eng"])))
        #expect(try !matches("mention team:? lower", item([.mentioned])))
        #expect(try !matches("mention team:acme/* lower", item([.teamMention])))
    }

    @Test func reviewRequestsOfYouOrATeam() throws {
        #expect(try matches("review requested:me boost 2", item([.reviewRequested])))
        #expect(try !matches("review requested:me boost 2", item([.reviewRequested], teams: ["acme/docs-eng"])))
        #expect(try matches("review requested:team lower", item([.reviewRequested], teams: ["acme/docs-eng"])))
        #expect(try !matches("review requested:team lower", item([.reviewRequested])))
        #expect(try matches("review team:acme/docs-eng boost 1", item([.reviewRequested], teams: ["acme/docs-eng"])))
        #expect(try !matches("review boost 1", item([.mentioned])))
    }

    @Test func authorsAndBots() throws {
        let bot = item([.reviewRequested], author: "dependabot", bot: true)
        let suffixed = item([.reviewRequested], author: "renovate[bot]")
        let person = item([.reviewRequested], author: "Maria")
        #expect(try matches("author bot:dependabot ignore", bot))
        #expect(try !matches("author bot:dependabot ignore", person))
        #expect(try matches("author bot:renovate ignore", suffixed))
        #expect(try matches("author bot lower", suffixed) && matches("author bot lower", bot))
        #expect(try !matches("author bot lower", person))
        #expect(try matches("author human boost 1", person) && !matches("author human boost 1", bot))
        #expect(try !matches("author human boost 1", item([.reviewRequested])))
        #expect(try matches("author maria boost 1", person) && matches("author mar* boost 1", person))
        #expect(try matches("author:maria boost 1", person))
        #expect(try matches("author me lower", item([.comment], author: "you")))
        #expect(try !matches("author me lower", person))
    }

    @Test func labelsReposBranchesKinds() throws {
        let labelled = item([.assigned], kind: .issue, labels: ["Blocker", "docs"])
        #expect(try matches("label \"blocker\" pin", labelled))
        #expect(try matches("label:doc* pin", labelled))
        #expect(try !matches("label \"needs review\" pin", labelled))
        #expect(try matches("label \"needs review\" pin", item([.assigned], labels: ["needs review"])))
        #expect(try matches("repo acme/*-archive ignore", item([.subscribed], repo: "acme/guides-archive")))
        #expect(try !matches("repo acme/*-archive ignore", item([.subscribed], repo: "acme/guides")))
        #expect(try matches("repo acme/api|acme/web lower", item([.subscribed], repo: "acme/web")))
        #expect(try matches("ci branch:main lower", item([.ciFailed], kind: .ci, branch: "main")))
        #expect(try !matches("ci branch:main lower", item([.ciFailed], kind: .ci, branch: "fix")))
        #expect(try !matches("ci branch:main lower", item([.ciFailed], kind: .ci)))
        #expect(try matches("kind issue|release lower", labelled))
        #expect(try !matches("kind release lower", labelled))
    }

    @Test func agentsByState() throws {
        let blocked = item([.agentBlocked], kind: .agent, agent: .blocked)
        let limited = item([.agentLimited], kind: .agent, agent: .limited)
        #expect(try matches("agent blocked|asking boost 3", blocked))
        #expect(try !matches("agent blocked|asking boost 3", limited))
        #expect(try matches("agent lower", limited))
        #expect(try !matches("agent lower", item([.mentioned])))
    }

    @Test func draftSizeAgeTurn() throws {
        #expect(try matches("draft lower", item([.reviewRequested], draft: true)))
        #expect(try !matches("draft lower", item([.reviewRequested], draft: false)))
        #expect(try matches("ready boost 1", item([.reviewRequested], draft: false)))
        #expect(try !matches("ready boost 1", item([.reviewRequested])))
        #expect(try matches("size >500 lower", item([.reviewRequested], size: 501)))
        #expect(try !matches("size >500 lower", item([.reviewRequested], size: 500)))
        #expect(try matches("size <50 boost 1", item([.reviewRequested], size: 49)))
        #expect(try !matches("size <50 boost 1", item([.reviewRequested])))
        #expect(try matches("age >7d lower", item([.subscribed], age: 8 * 86400)))
        #expect(try !matches("age >7d lower", item([.subscribed], age: 6 * 86400)))
        #expect(try matches("age <2h boost 1", item([.subscribed], age: 3600)))
        #expect(try matches("age >30m lower", item([.subscribed], age: 31 * 60)))
        #expect(try matches("turn mine boost 1", item([.comment], last: "maria")))
        #expect(try !matches("turn mine boost 1", item([.comment], last: "You")))
        #expect(try matches("turn theirs lower", item([.comment], last: "you")))
        #expect(try !matches("turn theirs lower", item([.comment])))
    }

    @Test func reasonsByName() throws {
        #expect(try matches("assigned boost 1", item([.assigned])))
        #expect(try matches("mine boost 1", item([.yourPR])))
        #expect(try matches("changes boost 1", item([.changesRequested])))
        #expect(try matches("reason stateChange|comment lower", item([.comment])))
        #expect(try !matches("reason stateChange lower", item([.comment])))
        #expect(try matches("any lower", item([])))
        #expect(try matches("mention repo acme/docs label:x boost 1", item([.mentioned], labels: ["x"])))
        #expect(try !matches("mention repo acme/docs label:x boost 1", item([.mentioned], labels: ["y"])))
    }

    @Test func globs() {
        #expect(Glob.matches("acme/*", "acme/docs"))
        #expect(Glob.matches("*-archive", "guides-archive"))
        #expect(Glob.matches("a?c", "abc") && !Glob.matches("a?c", "ac"))
        #expect(Glob.matches("a*b*c", "aXXbYYc") && !Glob.matches("a*b*c", "aXXbYY"))
        #expect(Glob.matches("DOCS", "docs") && !Glob.matches("docs", "docs-eng"))
        #expect(Glob.matches("x|docs*", "docs-eng"))
        #expect(Glob.matches("*", "") && !Glob.matches("a", ""))
        #expect(Glob.matches("*ab", "aab") && Glob.matches("*-eng", "docs-eng-eng"))
    }

    // MARK: Actions

    @Test func everyAction() throws {
        #expect(try rule("any boost").action == AttentionAction(boost: 1))
        #expect(try rule("any boost 3").action.notifies)
        #expect(try !rule("any boost 2").action.notifies)
        #expect(try rule("any boost 2 notify").action.notifies)
        #expect(try rule("any lower").action.weight == -1)
        #expect(try rule("any boost 2").action.weight == 2)
        #expect(try rule("any ignore").action.ignore)
        #expect(try rule("any pin").action.pin && rule("any pin notify").action.notify)
        #expect(try rule("any lower").action.notifies == false)
    }

    // MARK: Problems

    @Test func badLinesAreReportedAndSkipped() {
        let rules = AttentionRules(lines: [
            "mention user:me boost 3",
            "",
            "# a comment",
            "mention user:me",
            "boost 2",
            "mention boost 7",
            "mention user:maria boost 1",
            "frobnicate lower",
            "agent sleepy lower",
            "time 22:00-08:00 quiet",
            "any ignore notify",
            "any boost 2 lower",
            "review requested:you lower",
            "size big lower",
            "age >7y lower",
            "turn yours lower",
            "codeowner boost 1",
            "author team boost 1",
            "kind gist lower",
            "reason nope lower",
            "any lower mention",
            "label lower",
            "ci branch:main lower # trailing comment",
        ])
        #expect(rules.rules.map(\.line) == [1, 23])
        #expect(rules.problems.map(\.line) == Array(4 ... 22))
        let byLine = Dictionary(uniqueKeysWithValues: rules.problems.map { ($0.line, $0.message) })
        #expect(byLine[4]?.contains("no action") == true)
        #expect(byLine[5]?.contains("nothing to match") == true)
        #expect(byLine[6] == "boost takes 1, 2 or 3")
        #expect(byLine[7]?.contains("user: takes me") == true)
        #expect(byLine[8] == "frobnicate is not a rule input")
        #expect(byLine[10]?.contains("[attention] quiet") == true)
        #expect(byLine[11]?.contains("ignore hides") == true)
        #expect(byLine[17]?.contains("CODEOWNER") == true)
        #expect(byLine[21]?.contains("conditions come first") == true)
        #expect(byLine[22] == "label needs a value")
        #expect(rules.problems.first?
            .description == "line 4: no action: end it with boost n, lower, ignore, pin or notify")
    }

    @Test func wordsKeepQuotedStringsAndDropComments() {
        #expect(AttentionRules.words("label \"needs review\"  pin # why") == ["label", "\"needs review\"", "pin"])
        #expect(AttentionRules.words("label \"a # b\" pin") == ["label", "\"a # b\"", "pin"])
    }

    // MARK: Config

    @Test func rulesComeFromTheConfigAndBadLinesAreProblems() throws {
        let toml = """
        [attention]
        quiet = "22:00-08:00"
        rules = [
          "mention user:me boost 3",
          "frobnicate lower",
        ]
        """
        let (decoded, problems) = ConfigLoader.decode(toml)
        let config = try #require(decoded)
        #expect(config.attention.rules.count == 2)
        #expect(config.attention.parsedRules.rules.count == 1)
        #expect(config.attention.quiet != nil)
        #expect(problems.map(\.description) == ["attention.rules: line 2: frobnicate is not a rule input"])
    }

    @Test func theTemplatesExampleRulesParse() {
        let lines = ConfigLoader.defaultSource.split(separator: "\n")
            .drop { !$0.contains("# rules = [") }.dropFirst()
            .prefix { !$0.contains("# ]") }
            .map { line -> String in
                let text = line.trimmingCharacters(in: .whitespaces).dropFirst(2).trimmingCharacters(in: .whitespaces)
                return String(text.dropFirst().dropLast(2)).replacingOccurrences(of: "\\\"", with: "\"")
            }
        #expect(lines.count == 8)
        let rules = AttentionRules(lines: lines)
        #expect(rules.problems.isEmpty, "\(rules.problems)")
        #expect(rules.rules.count == 8)
    }
}

struct AttentionRankingTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(_ id: String, _ reasons: Set<AttentionReason>, minutes: Double, labels: [String] = [])
        -> AttentionItem
    {
        AttentionItem(
            id: id, kind: .pr, repo: Repo(org: "acme", name: "docs"), number: 1, title: id, url: nil, reasons: reasons,
            updatedAt: now.addingTimeInterval(-minutes * 60), labels: labels
        )
    }

    private let rules = AttentionRules(lines: [
        "label \"blocker\" pin",
        "review boost 2",
        "repo acme/docs label:noise ignore",
        "mention lower",
    ])

    @Test func pinnedFirstThenRecentOrWeight() {
        let live = [
            item("mention", [.mentioned], minutes: 1),
            item("review", [.reviewRequested], minutes: 5),
            item("plain", [.comment], minutes: 3),
            item("pinned", [.comment], minutes: 50, labels: ["blocker"]),
        ]
        let entries = AttentionRanking.entries(live: live, rules: rules, marks: [:], viewer: "you", now: now)
        #expect(AttentionRanking.list(entries, filter: .needsMe, now: now).map(\.id) == [
            "pinned", "mention", "plain", "review",
        ])
        #expect(AttentionRanking.list(entries, filter: .needsMe, sort: .weight, now: now).map(\.id) == [
            "pinned", "review", "plain", "mention",
        ])
    }

    @Test func mutedListsIgnoredAndMutedLiveOrRemembered() {
        let live = [
            item("noise", [.comment], minutes: 1, labels: ["noise"]),
            item("muted", [.comment], minutes: 2),
            item("snoozed", [.comment], minutes: 3),
            item("done", [.comment], minutes: 4),
            item("kept", [.comment], minutes: 5),
        ]
        let gone = [item("old-noise", [.comment], minutes: 900, labels: ["noise"]), item("old", [.comment], minutes: 9)]
        let marks = [
            "muted": AttentionMark(mutedAt: now),
            "snoozed": AttentionMark(snoozedUntil: now.addingTimeInterval(60)),
            "done": AttentionMark(doneAt: now),
        ]
        let entries = AttentionRanking.entries(
            live: live, stored: gone + [live[4]], rules: rules, marks: marks, viewer: "you", now: now
        )
        #expect(entries.count == 7)
        #expect(AttentionRanking.list(entries, filter: .needsMe, now: now).map(\.id) == ["kept"])
        #expect(AttentionRanking.list(entries, filter: .muted, now: now).map(\.id) == ["noise", "muted", "old-noise"])
        let counts = AttentionRanking.counts(entries, now: now)
        #expect(counts[.needsMe] == 1 && counts[.muted] == 3 && counts[.reviews] == 0)
        // Snoozed comes back when it is due.
        let later = now.addingTimeInterval(120)
        #expect(AttentionRanking.list(entries, filter: .needsMe, now: later).map(\.id) == ["snoozed", "kept"])
    }
}
