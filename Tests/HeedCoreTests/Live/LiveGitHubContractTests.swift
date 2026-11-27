import Foundation
@testable import HeedCore
import Testing

/// What heed's real GitHub reads return from real GitHub, with the owner's `gh` login: the failures a fake `gh` cannot
/// show (a field that needs another token scope, a flag that does not exist, a shape the parser never met). Each test
/// drives the real HeedCore function and asserts shape facts (non-empty, types, nullability tolerated), never exact
/// values. Reads only; public repositories (cli/cli, kubernetes/kubernetes) and the smoke repository.
///
/// A real product bug a test finds is not hidden: the test asserts the right behaviour, and `productBug` records it as
/// a known issue (the suite stays runnable) with a line in the report.
@Suite("LiveGitHubContractTests", .enabled(if: LiveSmoke.enabled, LiveSmoke.enabledNote), .serialized)
struct LiveGitHubContractTests {
    static let cli = Repo(org: "cli", name: "cli")

    static func checkouts(_ slugs: String...) -> BrowseCheckouts {
        BrowseCheckouts(records: slugs.map { slug in
            let parts = slug.split(separator: "/").map(String.init)
            return RepoRecord(
                repo: Repo(org: parts[0], name: parts[1]),
                path: "/nonexistent/\(parts[1])",
                defaultBranch: "main"
            )
        })
    }

    static func query(_ scope: BrowseScope? = nil, _ tokens: [BrowseToken] = []) -> BrowseQuery {
        BrowseQuery(scope: scope, tokens: tokens)
    }

    /// The report's header: what gh and which token scopes this run used.
    static func header() async {
        let environment = await SmokeGH.environment()
        SmokeReport.shared.setHeader([
            "- date: \(Date())",
            "- gh: \(environment.version)",
            "- token scopes: \(environment.scopes)",
            "- model: \(LiveSmoke.model) only; smoke repository: \(LiveSmoke.slug)",
            "- caps: \(LiveSmoke.spendCap) USD and \(LiveSmoke.toolCallCap) tool calls per agent run, \(Int(LiveSmoke.wallClockCap / 60)) minutes wall clock",
        ])
        print("live smoke: gh \(environment.version); token scopes: \(environment.scopes)")
    }

    func shape(_ step: SmokeStep, _ items: [BrowseItem], in place: String) {
        for item in items {
            step.expect(item.number > 0, "\(place): an item with no number")
            step.expect(item.url.hasPrefix("https://github.com/"), "\(place): \(item.id) has url '\(item.url)'")
            step.expect(!item.title.display.isEmpty, "\(place): \(item.id) has an empty title")
            step.expect(
                item.createdAt > .distantPast && item.updatedAt >= item.createdAt,
                "\(place): \(item.id) has no usable dates"
            )
            step.expect(item.id == item.id.lowercased(), "\(place): id \(item.id) is not lowercased")
            if item.kind == .pull { step.expect(
                item.requestedReviewers != nil,
                "\(place): \(item.id) is a pull request with no review-request list (heavy page)"
            ) }
        }
    }

    @Test(.timeLimit(.minutes(5))) func search() async throws {
        await Self.header()
        let log = try Self.callLog()
        let now = Date()
        let cliOnly = Self.checkouts("cli/cli")

        await Smoke.step("Contract", "BrowseFetch.search org scope (cli, is:open)") { step in
            let result = try await CallLog.$current.withValue(log.log) {
                try await BrowseFetch.search(
                    Self.query(.org("cli"), [.state(.open)]), maxAgeDays: 0, cap: 120, now: now, checkouts: cliOnly
                )
            }
            step.expect(!result.items.isEmpty, "no open items in org:cli")
            step.expect(result.total >= result.items.count, "total \(result.total) < items \(result.items.count)")
            step.expect(result.items.allSatisfy { $0.repo.org.lowercased() == "cli" }, "an item outside org:cli")
            step.expect(result.items.allSatisfy { $0.state == .open }, "is:open returned a non-open item")
            step.expect(
                result.items.contains { $0.kind == .pull } && result.items.contains { $0.kind == .issue },
                "org:cli had only one kind"
            )
            step.expect(result.hidden == 0, "cli has SAML-hidden items? \(result.hidden)")
            step.expect(result.groups == 1 && result.groupsTotal == 1, "an org scope ran \(result.groups) searches")
            shape(step, result.items, in: "org:cli")
            step.note("items \(result.items.count), total \(result.total), capped \(result.capped)")
        }

        await Smoke.step("Contract", "BrowseFetch.search repo scope (heed-smoke)") { step in
            let result = try await BrowseFetch.search(
                Self.query(.repo(LiveSmoke.repo)), maxAgeDays: 0, cap: 100, now: now,
                checkouts: Self.checkouts(LiveSmoke.slug)
            )
            step.expect(
                result.items.allSatisfy { $0.repo.slug.lowercased() == LiveSmoke.slug.lowercased() },
                "an item outside heed-smoke"
            )
            step.expect(result.total >= result.items.count, "total below items")
            shape(step, result.items, in: "repo:heed-smoke")
            step.note("items \(result.items.count) (earlier runs' closed items count), total \(result.total)")
        }

        await Smoke.step("Contract", "BrowseFetch.search default scope, 2 orgs") { step in
            let result = try await CallLog.$current.withValue(log.log) {
                try await BrowseFetch.search(
                    Self.query(nil, [.state(.open)]), maxAgeDays: 30, cap: 100, now: now,
                    checkouts: Self.checkouts("cli/cli", LiveSmoke.slug)
                )
            }
            step.expect(!result.items.isEmpty, "the default scope over cli and Mpdreamz found nothing in 30 days")
            let orgs = Set(result.items.map { $0.repo.org.lowercased() })
            step.expect(orgs.isSubset(of: ["cli", "mpdreamz"]), "an item from outside the two orgs: \(orgs)")
            step.expect(
                result.items.map(\.updatedAt) == result.items.map(\.updatedAt).sorted(by: >),
                "items are not newest first"
            )
            step.expect(Set(result.items.map(\.id)).count == result.items.count, "duplicate items")
            step.note("items \(result.items.count), groups \(result.groups), orgs \(orgs.sorted())")
        }

        await Smoke.step("Contract", "BrowseFetch.search chunked path (own repos, several searches)") { step in
            let repos = await BrowseFetch.orgRepos(owner: "kubernetes")
            let slugs = (repos ?? []).map(\.slug).filter { !$0.contains(" ") }.prefix(40)
            step.expect(slugs.count >= 20, "kubernetes lists only \(slugs.count) repos")
            let records = slugs.map { slug -> RepoRecord in
                let parts = slug.split(separator: "/").map(String.init)
                return RepoRecord(repo: Repo(org: parts[0], name: parts[1]), path: "/nonexistent/\(parts[1])")
            }
            let checkouts = BrowseCheckouts(records: records)
            let plan = BrowseDefaultScope.plan(
                checkouts.repoQualifiers(of: "kubernetes"),
                rest: "is:open sort:updated-desc"
            )
            step.expect(
                plan.groups.count >= 2,
                "\(slugs.count) repo qualifiers fit one search; the chunk path was not exercised"
            )
            let result = try await BrowseFetch.search(
                Self.query(.ownRepos("kubernetes"), [.state(.open)]), maxAgeDays: 0, cap: 150, now: now,
                checkouts: checkouts
            )
            step.expect(
                result.groups == plan.groups.count,
                "ran \(result.groups) searches, planned \(plan.groups.count)"
            )
            step.expect(!result.items.isEmpty, "the chunked search found nothing")
            step.expect(Set(result.items.map(\.id)).count == result.items.count, "duplicates after the merge")
            step.expect(
                result.items.map(\.updatedAt) == result.items.map(\.updatedAt).sorted(by: >),
                "merged items are not newest first"
            )
            step
                .note(
                    "repos \(slugs.count), searches \(result.groups), items \(result.items.count), total \(result.total)"
                )
        }

        await Smoke.step("Contract", "BrowseFetch.search over 1000 results (kubernetes/kubernetes)") { step in
            let result: BrowseFetch.Result
            do {
                result = try await BrowseFetch.search(
                    Self.query(.repo(Repo(org: "kubernetes", name: "kubernetes"))), maxAgeDays: 0, cap: 1200, now: now,
                    checkouts: Self.checkouts("kubernetes/kubernetes")
                )
            } catch {
                let text = "\(error)"
                // Seen live (2026-11-27): gh could not decode a truncated page. It is a transient, and heed fails the
                // whole fetch.
                step.productBug(
                    "P2-truncated-page",
                    "a page of the 1000-result search failed with '\(text)': BrowseFetchPolicy.classify sees it as permanent, so the page is not asked again",
                    reproduced: text.contains("unexpected end of JSON") && BrowseFetchPolicy
                        .classify(text) == .permanent
                )
                return step.expect(text.contains("unexpected end of JSON"), "threw: \(text)")
            }
            step.expect(result.total > 1000, "total \(result.total): kubernetes should hold more than 1000")
            step.expect(
                result.items.count <= 1000 && result.items.count >= 900,
                "items \(result.items.count): GitHub's search stops at 1000"
            )
            step.expect(!result.capped, "hasNextPage at the end of GitHub's 1000 was read as 'more to load'")
            step.note("items \(result.items.count), total \(result.total), capped \(result.capped)")
        }

        await Smoke.step("Contract", "BrowseFetch.search nonexistent org is empty, not an error") { step in
            let name = "heed-no-such-org-zz9q"
            let result = try await BrowseFetch.search(
                Self.query(.org(name)), maxAgeDays: 30, cap: 50, now: now, checkouts: Self.checkouts("\(name)/x")
            )
            step.expect(
                result.items.isEmpty && result.total == 0,
                "a nonexistent org returned \(result.items.count) items, total \(result.total)"
            )
        }

        await Smoke.step("Contract", "BrowseFetch.count, repoCount, orgRepos") { step in
            let query = Self.query(.org("cli"), [.state(.open)])
            let count = try await BrowseFetch.count(query, maxAgeDays: 0, now: now, checkouts: cliOnly)
            step.expect(count > 0, "count of open items in cli is \(count)")
            let searched = try await BrowseFetch.search(query, maxAgeDays: 0, cap: 10, now: now, checkouts: cliOnly)
            step.expect(
                abs(searched.total - count) <= 25,
                "count \(count) and the search's total \(searched.total) disagree"
            )
            let repoCount = await BrowseFetch.repoCount(owner: "cli")
            step.expect((repoCount ?? 0) > 5, "repoCount(cli) is \(String(describing: repoCount))")
            let repos = await BrowseFetch.orgRepos(owner: "cli")
            step.expect((repos?.count ?? 0) > 5, "orgRepos(cli) has \(repos?.count ?? -1) repos")
            step.expect(repos?.allSatisfy { $0.slug.hasPrefix("cli/") } == true, "a repo outside cli in orgRepos")
            step.expect(repos?.contains { $0.language != nil } == true, "no repo has a language")
            await step.expect(
                BrowseFetch.repoCount(owner: "heed-no-such-org-zz9q") == nil,
                "repoCount of a nonexistent owner is not nil"
            )
            step.note("count \(count), repoCount \(repoCount.map(String.init) ?? "nil"), orgRepos \(repos?.count ?? 0)")
        }

        await Smoke.step("Contract", "the call log's markers for GitHub reads") { step in
            await log.log.flush()
            let calls = try await log.log.store.calls(CallFilter())
            let searches = calls.filter { $0.kind == .github && $0.caller == BrowseFetch.caller }
            step.expect(!searches.isEmpty, "no github row for browse.search; callers: \(Set(calls.map(\.caller)))")
            step.expect(searches.allSatisfy { !$0.write && !$0.failed }, "a read marked as a write or failed")
            step.expect(
                searches.allSatisfy { $0.operation == "graphql browse search" },
                "operations: \(Set(searches.map { $0.operation ?? "nil" }))"
            )
            step.expect(searches.allSatisfy { ($0.items ?? -1) >= 0 }, "a search row without an item count")
            step.expect(
                searches.contains { $0.rateCost != nil && $0.rateRemaining != nil },
                "no row carries the rate limit"
            )
            step.expect(
                searches.allSatisfy { $0.command.hasPrefix("gh api graphql") && !$0.command.contains("gho_") },
                "a command line is not 'gh api graphql ...' or holds a token"
            )
            step.expect(
                !calls.contains { "\($0.command) \($0.stderr ?? "") \($0.stdout ?? "")".contains("gho_") },
                "a token reached the call log"
            )
            step
                .note(
                    "rows \(calls.count); browse.search rows \(searches.count); sample: \(searches.first?.command.prefix(80) ?? "")"
                )
        }

        await Smoke.step("Contract", "the call log marks SAML-withheld items (hidden)") { step in
            // `involves:@me` reaches orgs whose SAML this token has not been authorised for: GitHub answers with nulls
            // and errors, and the row says how many were withheld.
            _ = try await CallLog.$current.withValue(log.log) {
                try await GitHub.graphql(
                    BrowseFetch.countQuery, operation: "browse count", variables: ["q": "involves:@me is:open"],
                    caller: "browse.count"
                )
            }
            _ = try await CallLog.$current.withValue(log.log) {
                try await GitHub.graphql(
                    BrowseFetch.searchQuery(size: 100), operation: "browse search",
                    variables: ["q": "involves:@me is:open sort:updated-desc"], caller: "browse.search"
                )
            }
            await log.log.flush()
            let rows = try await log.log.store.calls(CallFilter())
                .filter { $0.detail["q"]?.hasPrefix("involves:@me") == true }
            step.expect(!rows.isEmpty, "the involves:@me calls were not logged")
            let hidden = rows.compactMap(\.hidden).max() ?? 0
            step.note("hidden marker on the involves:@me search: \(hidden)")
            if hidden == 0 { step.note("this token has no SAML-gated org: the hidden marker cannot be checked here") }
            step.expect(rows.allSatisfy { !$0.failed }, "an answered search with SAML errors was logged as failed")
        }
    }

    // MARK: Pull requests

    struct Candidate {
        var ref: PullRef
        var author: String
        var association: String
        var fork: Bool
        var head: String
    }

    static func candidates() async throws -> (normal: Candidate?, fork: Candidate?, bot: Candidate?) {
        let list = try await SmokeGH.readJSON([
            "api",
            "repos/cli/cli/pulls?state=open&per_page=60",
        ]) as? [[String: Any]] ?? []
        func candidate(_ pull: [String: Any]) -> Candidate? {
            guard let number = pull["number"] as? Int,
                  let user = (pull["user"] as? [String: Any])?["login"] as? String else { return nil }
            let head = pull["head"] as? [String: Any]
            let headRepo = (head?["repo"] as? [String: Any])?["full_name"] as? String
            return Candidate(
                ref: PullRef(repo: cli, number: number), author: user,
                association: pull["author_association"] as? String ?? "",
                fork: headRepo?.lowercased() != "cli/cli", head: head?["sha"] as? String ?? ""
            )
        }
        let all = list.compactMap(candidate)
        let normal = all.first { !$0.fork && ["OWNER", "MEMBER", "COLLABORATOR"].contains($0.association) } ?? all
            .first { !$0.fork }
        let fork = all.first { $0.fork }
        var bot: Candidate?
        let found = try await SmokeGH.readJSON([
            "search",
            "prs",
            "author:app/dependabot",
            "--limit",
            "5",
            "--state",
            "open",
            "--json",
            "number,repository",
        ]) as? [[String: Any]] ?? []
        for item in found {
            guard let number = item["number"] as? Int,
                  let name = (item["repository"] as? [String: Any])?["nameWithOwner"] as? String,
                  let repo = GitHub.repo(name) else { continue }
            bot = Candidate(
                ref: PullRef(repo: repo, number: number),
                author: "",
                association: "",
                fork: false,
                head: ""
            )
            break
        }
        return (normal, fork, bot)
    }

    @Test(.timeLimit(.minutes(3))) func pullAuthorship() async throws {
        let found = try await Self.candidates()
        let viewer = try await GitHub.viewer(caller: "live.contract")

        for (label, candidate) in [("normal", found.normal), ("fork", found.fork), ("bot", found.bot)] {
            await Smoke.step("Contract", "pullAuthorship + pullForReview + BrowseTrust on a \(label) PR") { step in
                guard let candidate else { return step.note("no \(label) pull request found to test with") }
                let ref = candidate.ref
                let authorship = try await GitHub.pullAuthorship(ref, caller: "live.contract")
                step
                    .note(
                        "\(ref): author \(authorship.author ?? "nil"), association \(authorship.association ?? "nil"), cross-repo \(authorship.crossRepository), bot \(authorship.isBot), canWrite \(String(describing: authorship.canWrite)), head \(authorship.headSHA?.prefix(7) ?? "nil")"
                    )
                step.expect(authorship.author?.isEmpty == false, "no author login")
                step.expect(authorship.headSHA?.count == 40, "head SHA is '\(authorship.headSHA ?? "nil")'")
                step.expect(authorship.association != nil, "no authorAssociation")
                let review = try await GitHub.pullForReview(ref, caller: "live.contract")
                step.expect(!review.head.isEmpty && !review.base.isEmpty, "empty branch names")
                step.expect(!review.title.display.isEmpty, "empty title")
                step.expect(
                    review.authorship?.author == authorship.author,
                    "pullForReview's author differs from pullAuthorship's"
                )
                let verdict = BrowseTrust.pull(authorship, viewer: viewer, trustedAuthors: [])
                step.expect(verdict.headSHA == authorship.headSHA, "the verdict lost the head SHA")
                switch label {
                case "fork":
                    step.expect(authorship.crossRepository, "a fork PR is not cross-repository")
                    step.expect(
                        !verdict.trusted && !verdict.canPush,
                        "a stranger's fork PR is trusted (\(verdict.text)) or pushable"
                    )
                    step.expect(
                        { if case .chatOnly = BrowseTrust.chatOnly(verdict) { true } else { false } }(),
                        "a fork PR is not Chat-only"
                    )
                case "bot":
                    step.expect(
                        authorship.isBot,
                        "dependabot's PR is not a bot PR (author \(authorship.author ?? "nil"))"
                    )
                    step.expect(!verdict.trusted, "a bot PR is trusted without trusted_authors: \(verdict.text)")
                    let login = authorship.author ?? ""
                    step.expect(
                        PullTrust.listed("dependabot[bot]", login: login, isBot: true)
                            || PullTrust.listed("dependabot", login: login, isBot: true),
                        "no spelling of 'dependabot' in trusted_authors matches the login pullAuthorship returns ('\(login)')"
                    )
                default:
                    step.expect(authorship.isBot == false, "a human's PR is a bot PR")
                    step.expect(!authorship.crossRepository, "an in-repo branch is cross-repository")
                }
            }
        }
    }

    @Test(.timeLimit(.minutes(3))) func conversationAndDetail() async throws {
        let found = try await Self.candidates()
        let issues = try await SmokeGH.readJSON([
            "api",
            "repos/cli/cli/issues?state=all&per_page=30&sort=comments",
        ]) as? [[String: Any]] ?? []
        let issueNumber = issues.first { $0["pull_request"] == nil }?["number"] as? Int

        await Smoke.step("Contract", "GitHub.conversation on an issue") { step in
            let number = try #require(issueNumber)
            let conversation = try await GitHub.conversation(repo: Self.cli, number: number, caller: "live.contract")
            step.expect(conversation.kind == .issue && conversation.number == number, "kind/number wrong")
            step.expect(!conversation.title.isEmpty && conversation.url.hasPrefix("https://"), "no title or url")
            step.expect(
                conversation.totalComments >= conversation.comments.count,
                "totalComments below the loaded comments"
            )
            step.expect(
                conversation.comments.map(\.createdAt) == conversation.comments.map(\.createdAt).sorted(),
                "comments are not oldest first"
            )
            step.expect(["OPEN", "CLOSED"].contains(conversation.state), "state \(conversation.state)")
            step.expect(!conversation.comments.isEmpty, "the most-commented issue has no comments loaded")
            step
                .note(
                    "#\(number): \(conversation.comments.count) of \(conversation.totalComments) comments, state \(conversation.state), reason \(conversation.stateReason ?? "nil")"
                )
        }

        await Smoke.step("Contract", "GitHub.conversation on a pull request, and BrowseThread.prompt") { step in
            let candidate = try #require(found.normal)
            let conversation = try await GitHub.conversation(
                repo: Self.cli,
                number: candidate.ref.number,
                caller: "live.contract"
            )
            step.expect(conversation.kind == .pr, "a PR read as \(conversation.kind)")
            step.expect(["OPEN", "MERGED", "CLOSED"].contains(conversation.state), "state \(conversation.state)")
            let text = BrowseThread.prompt(conversation, login: false).text
            step.expect(!text.isEmpty, "an empty thread prompt")
            step.note("\(candidate.ref): \(conversation.comments.count) comments, prompt \(text.count) chars")
        }

        await Smoke.step("Contract", "GitHub.pullDetail") { step in
            let candidate = try #require(found.normal)
            let detail = try await GitHub.pullDetail(candidate.ref, caller: "live.contract")
            step.expect(detail.headSHA.count == 40, "head sha '\(detail.headSHA)'")
            step.expect(!detail.baseBranch.isEmpty && !detail.headBranch.isEmpty, "empty branches")
            step.expect(!detail.title.display.isEmpty, "empty title")
            step.expect(detail.additions + detail.deletions >= 0 && detail.commitCount >= 1, "no commits")
            step.expect(
                detail.state != nil && detail.mergeable != nil,
                "state/mergeable unread: \(detail.state ?? "nil") \(detail.mergeable ?? "nil")"
            )
            step
                .note(
                    "\(detail.ref): +\(detail.additions) -\(detail.deletions), \(detail.commitCount) commits, review \(detail.reviewDecision ?? "nil"), mergeState \(detail.mergeState ?? "nil"), checks \(detail.checks)"
                )
        }
    }

    // MARK: Account

    @Test(.timeLimit(.minutes(3))) func account() async throws {
        await Smoke.step("Contract", "GitHub.viewer, orgs, listRepos") { step in
            let viewer = try await GitHub.viewer(caller: "live.contract")
            let api = try await SmokeGH.read(["api", "user", "--jq", ".login"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            step.expect(viewer == api && !viewer.isEmpty, "viewer '\(viewer)' vs gh's '\(api)'")
            let orgs = await GitHub.orgs(caller: "live.contract")
            step.expect(orgs.allSatisfy { !$0.isEmpty && !$0.contains(" ") }, "a malformed org login")
            step.note("viewer \(viewer), \(orgs.count) orgs")
            switch await GitHub.listRepos(owner: nil, caller: "live.contract") {
            case let .success(mine):
                step.expect(
                    mine.contains { $0.repo.slug.lowercased() == LiveSmoke.slug.lowercased() },
                    "your repos do not list heed-smoke (\(mine.count) listed)"
                )
                step.expect(
                    mine.allSatisfy { !$0.repo.org.isEmpty && !$0.repo.name.isEmpty },
                    "a listing with no owner or name"
                )
            case let .failure(failure): step.expect(false, "listRepos(nil) failed: \(failure)")
            }
            switch await GitHub.listRepos(owner: "cli", caller: "live.contract") {
            case let .success(listed):
                step.expect(listed.contains { $0.repo.slug == "cli/cli" }, "cli's repos do not list cli/cli")
                step.expect(listed.contains { $0.pushedAt != nil }, "no listing has a push date")
            case let .failure(failure): step.expect(false, "listRepos(cli) failed: \(failure)")
            }
            if let org = orgs.first {
                if case let .failure(failure) = await GitHub.listRepos(owner: org, caller: "live.contract") {
                    step.note("listRepos(\(org)) failed: \(failure) (an org behind SAML says so here)")
                }
            }
        }

        await Smoke.step("Contract", "AddRepoForm lists from the real answers") { step in
            let orgs = await GitHub.orgs(caller: "live.contract")
            var lists: [String: AddRepoForm.ListState] = [:]
            for owner in ["", "cli"] {
                switch await GitHub.listRepos(owner: owner.isEmpty ? nil : owner, caller: "live.contract") {
                case let .success(listed): lists[owner] = .loaded(listed)
                case let .failure(failure): lists[owner] = .failed("\(failure)")
                }
            }
            var form = AddRepoForm(
                orgs: ["cli"] + orgs.filter { $0 != "cli" }.prefix(2),
                records: [],
                roots: ["~/Projects"],
                then: .add,
                lists: lists
            )
            step.expect(!form.rows.isEmpty, "the first tab (yours) lists nothing")
            step.expect(
                form.count(.org("cli")) ?? 0 > 5,
                "the cli tab counts \(String(describing: form.count(.org("cli"))))"
            )
            form.addOrgs(["cli", "newly-arrived"])
            step.expect(form.tabs.count(where: { $0 == .org("cli") }) == 1, "addOrgs duplicated the cli tab")
            step.note("your tab: \(form.rows.count) rows; cli: \(form.count(.org("cli")) ?? 0)")
        }
    }

    // MARK: Goals item sources

    @Test(.timeLimit(.minutes(3))) func goalsItemSources() async throws {
        let sources = GitHubSources(caller: "live.contract.sources")

        await Smoke.step("Contract", "Goals item source: search shape and a query with SAML-withheld nodes") { step in
            let found = try await sources.search("repo:cli/cli is:open is:pr")
            step.expect(
                !found.matches.isEmpty && found.total >= found.matches.count,
                "a plain search: \(found.matches.count) of \(found.total)"
            )
            step.expect(
                found.matches.allSatisfy { $0.ref.contains("#") && !$0.title.isEmpty && $0.url.hasPrefix("https://") },
                "a malformed match"
            )
            step.expect(found.matches.allSatisfy { $0.kind == .pr }, "is:pr returned an issue")

            // `involves:@me` reaches orgs behind SAML: GitHub answers with `nodes` holding nulls beside real nodes, and
            // errors. The audit's P1: `nodes as? [[String: Any]]` is nil for an array holding a null, so one withheld
            // node empties the page.
            let data = try await GitHub.graphql(
                GitHubSources.searchQuery, operation: "sourceSearch",
                variables: ["q": "involves:@me is:open sort:updated-desc"], caller: "live.contract.sources"
            )
            let json = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
            let search = try #require((json["data"] as? [String: Any])?["search"] as? [String: Any])
            let nodes = search["nodes"] as? [Any] ?? []
            let nulls = nodes.count(where: { $0 is NSNull })
            let real = nodes.count - nulls
            step
                .note(
                    "involves:@me: issueCount \(search["issueCount"] ?? "?"), page of \(nodes.count): \(real) real nodes, \(nulls) nulls"
                )
            let parsed = try GitHubSources.parseSearch(data)
            if nulls > 0, real > 0 {
                // P1 (fixed): a null node no longer drops the page, and the nulls are counted as withheld.
                step.expect(
                    parsed.matches.count >= real / 2 && parsed.withheld == nulls,
                    "Goals parseSearch read \(parsed.matches.count) matches (withheld \(parsed.withheld)) from a page with \(real) real nodes and \(nulls) nulls"
                )
            } else {
                step
                    .note(
                        "this token sees no mixed SAML page right now (\(nulls) nulls, \(real) real): the P1 cannot be observed live; see the synthetic check"
                    )
            }
        }

        await Smoke.step("Contract", "Goals item source: a mixed null/real page, synthesised") { step in
            // The same bug without needing a SAML org on the account: a page with one null in front of a real node.
            let page = #"{"data":{"viewer":{"login":"me"},"search":{"issueCount":2,"pageInfo":{"hasNextPage":false,"endCursor":null},"nodes":[null,{"__typename":"Issue","number":7,"title":"t","url":"https://github.com/a/b/issues/7","state":"OPEN","repository":{"nameWithOwner":"a/b"},"author":{"login":"x"}}]}}}"#
            let parsed = try GitHubSources.parseSearch(Data(page.utf8))
            step.expect(
                parsed.matches.map(\.ref) == ["a/b#7"] && parsed.withheld == 1,
                "P1: parseSearch returns \(parsed.matches.count) matches (withheld \(parsed.withheld)) for [null, issue]"
            )
        }

        await Smoke.step("Contract", "Goals item source: lookup shapes") { step in
            let issues = try await SmokeGH.readJSON([
                "api",
                "repos/cli/cli/issues?state=open&per_page=10",
            ]) as? [[String: Any]] ?? []
            let refs = issues.prefix(6).compactMap { ($0["number"] as? Int).map { "cli/cli#\($0)" } }
            let found = try await sources.lookup(refs + ["cli/cli#99999999"])
            step.expect(
                found.count == refs.count,
                "looked up \(refs.count) real refs plus one missing: got \(found.count) back"
            )
            step.expect(Set(found.map(\.ref)) == Set(refs), "refs differ: \(found.map(\.ref)) vs \(refs)")
            step.expect(
                found.contains { $0.kind == .issue } && found.contains { $0.kind == .pr },
                "kinds: \(found.map(\.kind))"
            )
        }
    }

    // MARK: Plumbing

    struct Log { let log: CallLog }

    static func callLog() throws -> Log {
        let folder = try LiveSmoke.scratch("contract-log")
        return try Log(log: CallLog(
            store: CallStore(path: folder.appendingPathComponent("log.sqlite").path),
            delay: .seconds(60)
        ))
    }
}
