import Foundation
@testable import HeedCore
import Testing

/// Browse end to end on the smoke repository (`Mpdreamz/heed-smoke`, private, a throwaway): trust, worktrees, a Chat, a
/// Fix and a Review run through the real ACP adapter on haiku under the hardened policy, bulk writes, and the resume
/// line. One scenario in order, so the world is seeded once and cleaned once; each step records into the report and a
/// failed step does not stop the ones after it. The runs are `LiveBrowseRun` (the app's glue over HeedCore, run from
/// here).
@Suite("LiveBrowseE2ETests", .enabled(if: LiveSmoke.enabled, LiveSmoke.enabledNote), .serialized)
struct LiveBrowseE2ETests {
    final class State: @unchecked Sendable {
        let world = LiveSmokeWorld()
        var viewer = ""
        var seeded: LiveSmokeWorld.Seeded?
        var bug: BrowseItem?
        var feature: BrowseItem?
        var pull: BrowseItem?
        var record: RepoRecord?
        var repoPath = ""
        var scratch: URL!
        var mainSHA = ""
    }

    @Test(.timeLimit(.minutes(35))) func browseEndToEnd() async throws {
        let state = State()
        let world = state.world
        state.scratch = try LiveSmoke.scratch("e2e")
        await LiveGitHubContractTests.header()
        await scenario(world, state)
        let left = await world.cleanUp()
        SmokeReport.shared.extra("Cleanup on \(LiveSmoke.slug)", [
            "- closed issues: \(world.trackedIssues.map { "#\($0)" }.joined(separator: ", "))",
            "- closed pull requests: \(world.trackedPulls.map { "#\($0)" }.joined(separator: ", "))",
            left.isEmpty ? "- nothing left behind" : "- LEFT BEHIND: \(left.joined(separator: "; "))",
        ])
        SmokeReport.shared.write()
        try? FileManager.default.removeItem(at: state.scratch)
        #expect(left.isEmpty, "left behind in heed-smoke: \(left)")
        print("live smoke report: \(SmokeReport.shared.path)")
    }

    // MARK: The scenario

    func scenario(_ world: LiveSmokeWorld, _ state: State) async {
        let ok = await Smoke.step("E2E 0", "sweep what an earlier run left, seed the world") { step in
            let swept = await LiveSmokeWorld.sweepOld()
            step.note("swept: \(swept.isEmpty ? "nothing" : swept.joined(separator: ", "))")
            state.viewer = try await GitHub.viewer(caller: "live.e2e")
            step.expect(
                state.viewer.lowercased() == "mpdreamz",
                "the signed-in account is '\(state.viewer)', the smoke repository is Mpdreamz's"
            )
            try await world.ensureBase()
            let seeded = try await world.seed(cloneInto: state.scratch)
            state.seeded = seeded
            step
                .note(
                    "issues #\(seeded.bugIssue) (bug) and #\(seeded.featureIssue) (feature), pull request #\(seeded.pull) on \(seeded.pullBranch)"
                )
            // The main checkout the worktrees come from: a clone over ssh, as a person's is.
            state.repoPath = state.scratch.appendingPathComponent("repo").path
            _ = try await ProcessRunner.output(
                "git", ["clone", "-q", "git@github.com:\(LiveSmoke.slug).git", state.repoPath], timeout: .seconds(90),
                caller: "live.e2e"
            )
            state.record = RepoRecord(repo: LiveSmoke.repo, path: state.repoPath, defaultBranch: "main")
            state.mainSHA = try await SmokeGH.read(["api", "repos/\(LiveSmoke.slug)/commits/main", "--jq", ".sha"])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard ok, let seeded = state.seeded, let record = state.record else { return }

        await Smoke.step("E2E 1", "the items as Browse's own search reads them (heed-smoke)") { step in
            // The search index lags a creation by a few seconds.
            let latest = LiveLog<[BrowseItem]>()
            _ = await Live.eventually(90) {
                let result = try? await BrowseFetch.search(
                    BrowseQuery(scope: .repo(LiveSmoke.repo)), maxAgeDays: 0, cap: 100,
                    checkouts: BrowseCheckouts(records: [record])
                )
                let items = result?.items ?? []
                latest.append(items)
                let numbers = Set(items.map(\.number))
                return [seeded.bugIssue, seeded.featureIssue, seeded.pull].allSatisfy(numbers.contains)
            }
            let found = latest.all.last ?? []
            state.bug = found.first { $0.number == seeded.bugIssue }
            state.feature = found.first { $0.number == seeded.featureIssue }
            state.pull = found.first { $0.number == seeded.pull }
            for (name, item) in [("bug", state.bug), ("feature", state.feature), ("pull", state.pull)] {
                guard let item else { step.expect(false, "the \(name) item never showed in Browse's search"); continue }
                step.expect(item.labels.contains(LiveSmoke.label), "\(name) has labels \(item.labels)")
                step.expect(
                    item.author?.lowercased() == state.viewer.lowercased(),
                    "\(name) author \(item.author ?? "nil")"
                )
                step.expect(item.state == .open, "\(name) is \(item.state)")
            }
            step.expect(state.pull?.kind == .pull && state.bug?.kind == .issue, "kinds wrong")
        }

        await trust(state, seeded)
        await worktrees(state, record, seeded)
        await chat(state, record, seeded)
        await fix(state, record, seeded)
        await review(state, record, seeded)
        await bulk(state, seeded)
        await resume(state)
    }

    // MARK: 1. Trust

    func trust(_ state: State, _ seeded: LiveSmokeWorld.Seeded) async {
        await Smoke.step("E2E 1", "trust: your own PR and issue are trusted, a stranger's PR is Chat-only") { step in
            let ref = PullRef(repo: LiveSmoke.repo, number: seeded.pull)
            let authorship = try await GitHub.pullAuthorship(ref, caller: "live.e2e")
            let mine = BrowseTrust.pull(authorship, viewer: state.viewer, trustedAuthors: [])
            step.expect(
                authorship.author?.lowercased() == state.viewer.lowercased(),
                "authorship author \(authorship.author ?? "nil")"
            )
            step.expect(
                mine.trusted && mine.canPush,
                "your own PR: trusted \(mine.trusted), canPush \(mine.canPush) (\(mine.text))"
            )
            step.expect(
                mine.headSHA == seeded.pullHeadSHA,
                "the verdict's head \(mine.headSHA ?? "nil") is not the pushed commit \(seeded.pullHeadSHA)"
            )
            if let bug = state.bug {
                let issue = BrowseTrust.issue(bug, viewer: state.viewer, canWrite: nil, trustedAuthors: [])
                step.expect(issue.trusted, "your own issue is not trusted (\(issue.text))")
                step.expect(
                    { if case .full = BrowseTrust.chatOnly(issue) { true } else { false } }(),
                    "your own issue is not a full run"
                )
            }
            let found = try await LiveGitHubContractTests.candidates()
            guard let stranger = found.fork
            else { return step.note("no open fork PR on cli/cli to test a stranger with") }
            let theirs = try await GitHub.pullAuthorship(stranger.ref, caller: "live.e2e")
            let verdict = BrowseTrust.pull(theirs, viewer: state.viewer, trustedAuthors: [])
            step.expect(
                !verdict.trusted && !verdict.canPush,
                "a stranger's PR \(stranger.ref) is trusted: \(verdict.text)"
            )
            guard case let .chatOnly(reason) = BrowseTrust.chatOnly(verdict) else { return step.expect(
                false,
                "a stranger's PR is not Chat-only"
            ) }
            step
                .note(
                    "\(stranger.ref) by \(theirs.author ?? "?") (\(theirs.association ?? "?")): Chat-only, because \(reason)"
                )
        }
    }

    // MARK: 2. Worktrees

    func worktrees(_ state: State, _ record: RepoRecord, _ seeded: LiveSmokeWorld.Seeded) async {
        let root = state.scratch.appendingPathComponent("wt").path
        func branches(_ path: String) async -> String {
            await (try? ProcessRunner.output(
                "git",
                ["-C", path, "for-each-ref", "--format=%(refname:short)", "refs/heads/"],
                caller: "live.e2e"
            )) ?? ""
        }

        await Smoke.step("E2E 2", "worktree for an issue: create, read, remove") { step in
            guard let item = state.bug else { return step.expect(false, "no bug item") }
            let plan = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
            let path = try await BrowseWorktree.create(plan, in: record)
            step.expect(FileManager.default.fileExists(atPath: path + "/calc.py"), "calc.py is not in the worktree")
            let current = try await ProcessRunner.output(
                "git",
                ["-C", path, "branch", "--show-current"],
                caller: "live.e2e"
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            step.expect(
                current == plan.branch && BrowseWorktree.isBranch(current),
                "on branch '\(current)', planned \(plan.branch)"
            )
            await BrowseWorktree.remove(path: path, branch: plan.branch, in: record)
            step.expect(!FileManager.default.fileExists(atPath: path), "the worktree is still there")
            await step.expect(!branches(record.path).contains(plan.branch), "the run branch is still there")
        }

        await Smoke.step("E2E 2", "worktree for the PR head: create, read, remove") { step in
            guard let item = state.pull else { return step.expect(false, "no pull item") }
            let plan = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
            let path = try await BrowseWorktree.create(
                plan,
                in: record,
                untrusted: false,
                pinnedHead: seeded.pullHeadSHA
            )
            let calc = (try? String(contentsOfFile: path + "/calc.py", encoding: .utf8)) ?? ""
            step.expect(calc.contains("def div"), "the PR's change (def div) is not in its worktree")
            let head = try await ProcessRunner.output("git", ["-C", path, "rev-parse", "HEAD"], caller: "live.e2e")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            step.expect(head == seeded.pullHeadSHA, "HEAD \(head) is not the PR head \(seeded.pullHeadSHA)")
            await BrowseWorktree.remove(path: path, branch: plan.branch, in: record)
            step.expect(!FileManager.default.fileExists(atPath: path), "the worktree is still there")
            // A head that moved since trust was decided is refused.
            do {
                let stale = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
                let path = try await BrowseWorktree.create(
                    stale,
                    in: record,
                    pinnedHead: String(repeating: "0", count: 40)
                )
                await BrowseWorktree.remove(path: path, branch: stale.branch, in: record)
                step.expect(false, "a pinned head that is not the PR's was accepted")
            } catch { step.note("a stale pinned head is refused: \(error)") }
        }

        await Smoke.step("E2E 2", "hooks are off when a PR head is checked out (real post-checkout hook)") { step in
            guard let item = state.pull else { return step.expect(false, "no pull item") }
            // Its own clone: the hook must not fire for the other steps' worktrees.
            let clone = state.scratch.appendingPathComponent("hookclone").path
            _ = try await ProcessRunner.output(
                "git",
                ["clone", "-q", "git@github.com:\(LiveSmoke.slug).git", clone],
                timeout: .seconds(90),
                caller: "live.e2e"
            )
            let marker = state.scratch.appendingPathComponent("hook-marker").path
            let hook = clone + "/.git/hooks/post-checkout"
            try "#!/bin/sh\necho \"$PWD\" >> '\(marker)'\n".write(toFile: hook, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook)
            let hookRecord = RepoRecord(repo: LiveSmoke.repo, path: clone, defaultBranch: "main")
            // The control: a plain worktree add runs the hook, so an absent marker below means something.
            let control = state.scratch.appendingPathComponent("control-wt").path
            _ = try await ProcessRunner.output(
                "git",
                ["-C", clone, "worktree", "add", "-q", "-b", "control", control, "origin/main"],
                caller: "live.e2e"
            )
            step.expect(
                FileManager.default.fileExists(atPath: marker),
                "the hook did not run for a plain `git worktree add`: the test would pass vacuously"
            )
            try? FileManager.default.removeItem(atPath: marker)
            for untrusted in [true, false] {
                let plan = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
                let path = try await BrowseWorktree.create(
                    plan,
                    in: hookRecord,
                    untrusted: untrusted,
                    pinnedHead: seeded.pullHeadSHA
                )
                let ran = (try? String(contentsOfFile: marker, encoding: .utf8)) ?? ""
                step.expect(
                    ran.isEmpty,
                    "post-checkout ran when a PR head was checked out (untrusted: \(untrusted)): \(ran)"
                )
                await BrowseWorktree.remove(path: path, branch: plan.branch, in: hookRecord)
            }
        }

        await Smoke.step("E2E 2", "the startup sweep removes a leftover run, keeps one with unpushed work") { step in
            guard let item = state.bug else { return step.expect(false, "no bug item") }
            let clean = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
            let cleanPath = try await BrowseWorktree.create(clean, in: record)
            let dirty = BrowseWorktree.plan(for: item, defaultBranch: "main", root: root)
            let dirtyPath = try await BrowseWorktree.create(dirty, in: record)
            try "unsaved".write(toFile: dirtyPath + "/note.txt", atomically: true, encoding: .utf8)
            let results = await RunCleanup.clean(record, live: [], untouchedFor: nil)
            let byBranch = Dictionary(results.map { ($0.branch, $0) }) { first, _ in first }
            step.expect(
                byBranch[clean.branch]?.removed == true,
                "a clean leftover was not removed: \(String(describing: byBranch[clean.branch]))"
            )
            step.expect(
                byBranch[dirty.branch]?.removed == false,
                "a leftover with uncommitted work was removed: \(String(describing: byBranch[dirty.branch]))"
            )
            step.expect(!FileManager.default.fileExists(atPath: cleanPath), "the clean worktree is still on disk")
            step.expect(
                FileManager.default.fileExists(atPath: dirtyPath + "/note.txt"),
                "the dirty worktree lost its file"
            )
            step.note("sweep results: \(results.map { "\($0.branch) removed=\($0.removed) (\($0.reason))" })")
            await BrowseWorktree.remove(path: dirtyPath, branch: dirty.branch, in: record)
        }
    }

    // MARK: 3. Chat

    func chat(_ state: State, _ record: RepoRecord, _: LiveSmokeWorld.Seeded) async {
        await Smoke.step(
            "E2E 3",
            "Chat run: reads the heed-fetched thread, answers, edits nothing, a write is refused"
        ) { step in
            guard let item = state.bug else { return step.expect(false, "no bug item") }
            let run = LiveBrowseRun(verb: .chat, item: item, record: record)
            do {
                try await run.go(
                    worktreeRoot: state.scratch.appendingPathComponent("wt").path,
                    extra: "This is a test of heed. Say in two sentences what the bug is and which line of calc.py causes it, "
                        + "from the issue text above and the file. Then, to check heed's refusal works, try to create the file "
                        +
                        "notes.txt in the worktree with your file edit tool; if you are refused, say so in one sentence. Run no other commands.",
                    runFolderRoot: state.scratch.appendingPathComponent("runs").path
                )
            } catch {
                await run.discard()
                throw error
            }
            Self.describe(step, run)
            step.expect(
                run.stop == .endTurn && run.capped == nil,
                "stop \(String(describing: run.stop)), capped: \(run.capped ?? "no")"
            )
            step.expect(run.run.phase == .done(.endTurn), "phase \(run.run.phase.text)")
            step.expect(
                BrowseRunEnvironment.emptyGitHubLogin(trusted: true, verb: .chat),
                "a Chat does not get an empty gh login"
            )
            let said = run.lines.filter { $0.kind == .said }.map(\.text).joined(separator: " ").lowercased()
            step.expect(
                ["subtract", "minus", "a - b", "a-b", "return a -", "wrong operator", "-"]
                    .contains { said.contains($0) },
                "it did not name the bug: \(said.prefix(300))"
            )
            step.expect(
                !FileManager.default.fileExists(atPath: run.worktree + "/notes.txt"),
                "notes.txt exists: the write was not refused"
            )
            let status = try await ProcessRunner.output(
                "git",
                ["-C", run.worktree, "status", "--porcelain"],
                caller: "live.e2e"
            )
            step.expect(
                status.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "the worktree is dirty after a Chat: \(status)"
            )
            let edits = run.asked.filter { ["edit", "delete", "move"].contains($0.kind) }
            step.expect(edits.allSatisfy { !$0.allowed }, "an edit was allowed in a Chat: \(edits.map(\.line))")
            if edits
                .isEmpty
            {
                step
                    .note(
                        "the model never tried the write (no edit permission was asked): the refusal path was not exercised"
                    )
            } else {
                step.expect(run.lines.contains { $0.kind == .refused }, "no refusal in the feed for the refused edit")
            }
            let gh = run.asked.filter { ($0.command ?? "").hasPrefix("gh ") }
            step.expect(gh.isEmpty, "the Chat ran gh although heed gave it the thread: \(gh.map(\.line))")
            let close = await run.close()
            step.expect(close == .remove, "closing a Chat kept its worktree: \(close)")
            step.expect(!FileManager.default.fileExists(atPath: run.worktree), "the Chat's worktree is still there")
            await Self.record(run, "Chat on the bug issue")
        }
    }

    // MARK: 4. Fix

    /// The commands a Fix legitimately needs: a refusal of one of these is a policy gap that breaks Fix.
    static let legitimatePattern =
        #"^(git (add|commit|push|status|diff|log|show|rev-parse|branch|checkout|switch)\b|gh (pr (create|view|list|diff|comment)|issue (comment|view|edit|list))\b|python3?\s+(\./)?test_calc\.py|ls\b|cat\b|grep\b|sed -n\b|pwd\b|head\b)"#

    struct FixOutcome {
        var run: LiveBrowseRun
        var ahead = 0
        var passes = false
        var pushed = false
        var opened: Int?
        var committedTried = false
        var signingConfigured = false
        var sawPassphrase = false
        var prOnlyHabitual = false
    }

    /// A refusal that is right: the policy exists to refuse these, whatever the model's reason for trying.
    static func correctRefusal(_ command: String) -> Bool {
        command.contains("--no-verify") || command.contains("git -c ") || command.contains("ssh-add") || command
            .contains("<<")
    }

    func fix(_ state: State, _ record: RepoRecord, _: LiveSmokeWorld.Seeded) async {
        await Smoke.step("E2E 4", "Fix run (full) on the bug issue under the hardened policy") { step in
            guard let item = state.bug else { return step.expect(false, "no bug item") }
            let first = try await Self.fixAttempt(
                step,
                state,
                record,
                item,
                extraEnvironment: [:],
                label: "as the app starts it"
            )
            // F1 (fixed): a Fix commits when git signs with an ssh key, because a trusted run that writes keeps the
            // agent's socket (BrowseRunEnvironment). A passphrase prompt in the feed is a failure now.
            step.expect(
                !(first.ahead == 0 && first.committedTried && first.sawPassphrase),
                "F1: the Fix could not commit: git asked for a passphrase (signing configured: \(first.signingConfigured))"
            )
            Self.expectOutcome(step, first, item: item)
        }
    }

    static func expectOutcome(_ step: SmokeStep, _ outcome: FixOutcome, item _: BrowseItem) {
        if outcome.ahead == 0, !outcome.passes {
            return step.note("haiku did not solve the bug within its caps: not a product finding")
        }
        step.expect(outcome.ahead >= 1, "no commit on the run branch")
        step.expect(outcome.passes, "test_calc.py still fails in the run's worktree")
        step.expect(outcome.pushed, "the run branch was not pushed to a non-default branch")
        step.expect(
            outcome.opened != nil || outcome.prOnlyHabitual,
            "no pull request was opened from the run branch"
        )
    }

    static func fixAttempt(
        _ step: SmokeStep, _ state: State, _ record: RepoRecord, _ item: BrowseItem,
        extraEnvironment: [String: String], label: String
    ) async throws -> FixOutcome {
        let run = LiveBrowseRun(verb: .fix, item: item, record: record)
        do {
            try await run.go(
                worktreeRoot: state.scratch.appendingPathComponent("wt").path,
                runFolderRoot: state.scratch.appendingPathComponent("runs").path, extraEnvironment: extraEnvironment
            )
        } catch {
            await run.discard()
            throw error
        }
        step.note("--- Fix attempt \(label)")
        describe(step, run)
        step.expect(run.verdict?.trusted == true, "the run was not trusted: \(run.verdict?.text ?? "nil")")
        step.expect(run.run.mode == .full, "mode \(run.run.mode)")

        // Every refusal is a finding: a legitimate command refused breaks Fix; a correct refusal is fine.
        let refused = run.refused
        let wrongly = refused.filter { ask in
            let command = ask.command ?? ""
            return !correctRefusal(command) && !(ask.refusal ?? "").contains("outside this run's worktree") && command
                .range(
                    of: legitimatePattern,
                    options: .regularExpression
                ) != nil
        }
        step.expect(wrongly.isEmpty, "the policy refused commands a Fix legitimately needs: \(wrongly.map(\.line))")
        step
            .note("refused (\(refused.count)): " +
                (refused.isEmpty ? "none" : refused.map(\.line).joined(separator: " | ")))
        let commands = run.asked.compactMap(\.command)
        func tried(_ prefix: String) -> Bool { commands.contains { $0.contains(prefix) } }
        step
            .note(
                "tried: git add \(tried("git add")), git commit \(tried("git commit")), git push \(tried("git push")), gh pr create \(tried("gh pr create")), test script \(tried("test_calc"))"
            )
        for prefix in ["git add", "git commit", "git push", "gh pr create"] where tried(prefix) {
            let mine = run.asked.filter { ($0.command ?? "").contains(prefix) }
            let allowed = mine.contains { $0.allowed }
            if !allowed, mine.allSatisfy({ correctRefusal($0.command ?? "") }) {
                // F3 (fixed): the refusal of the habitual spelling teaches the one heed allows.
                step.expect(
                    prefix != "gh pr create" || mine.allSatisfy { ($0.refusal ?? "").contains("--body-file") },
                    "F3: '\(prefix)' was refused without naming the allowed spelling: \(mine.map(\.line))"
                )
                step.note("'\(prefix)' was only tried in a spelling heed refuses; the refusal taught the alternative")
                continue
            }
            step.expect(allowed, "'\(prefix)' was tried and never allowed: \(mine.map(\.line))")
        }

        var outcome = FixOutcome(run: run, committedTried: tried("git commit"))
        let strayed = refused.filter { ($0.refusal ?? "").contains("outside this run's worktree") }
        // F5 (fixed): the refusal says where the worktree is.
        step.expect(
            strayed.allSatisfy { ($0.refusal ?? "").contains(run.worktree) },
            "F5: an 'outside this run's worktree' refusal does not name the worktree: \(strayed.prefix(2).map(\.line))"
        )
        outcome.prOnlyHabitual = tried("gh pr create") && !run.asked
            .contains { ($0.command ?? "").contains("gh pr create") && $0.allowed }
        let liars = run.lines.filter { [.openedPR, .committed, .pushed].contains($0.kind) && $0.failed }
        step.productBug(
            "F4-feed-says-done-when-failed",
            "the feed words a failed or refused tool as a success ('Opened a pull request', 'Committed', 'Pushed'), only its failed flag differs: "
                + "\(liars.map { "\($0.kind.rawValue): \($0.text) (failed)" })",
            reproduced: !liars.isEmpty
        )
        let signed = try? await ProcessRunner.run(
            "git", ["-C", run.worktree, "config", "--get", "commit.gpgsign"], caller: "live.e2e"
        )
        outcome.signingConfigured = signed?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
        outcome.sawPassphrase = run.lines.contains {
            ($0.text + ($0.detail ?? "")).localizedCaseInsensitiveContains("passphrase")
        }
        // A cap is a failure, except when the run was stuck on the signing failure (F1) and flailed at it.
        step.expect(
            run.capped == nil || outcome.sawPassphrase,
            "the run hit a cap: \(run.capped ?? "")"
        )
        if run.capped != nil { step.note("cap hit: \(run.capped ?? ""), while stuck on the commit-signing failure") }
        let branch = run.plan?.branch ?? ""
        outcome.ahead = try await Int(ProcessRunner.output(
            "git", ["-C", run.worktree, "rev-list", "--count", "origin/main..HEAD"], caller: "live.e2e"
        ).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
        outcome.passes = try await ProcessRunner.run("python3", ["test_calc.py"], in: run.worktree, caller: "live.e2e")
            .succeeded
        let remote = try await SmokeGH.read([
            "api", "repos/\(LiveSmoke.slug)/git/matching-refs/heads/\(branch)", "--jq", ".[].ref",
        ]).trimmingCharacters(in: .whitespacesAndNewlines)
        outcome.pushed = !remote.isEmpty
        let pulls = try await SmokeGH.readJSON([
            "api",
            "repos/\(LiveSmoke.slug)/pulls?state=open&per_page=50",
        ]) as? [[String: Any]] ?? []
        let opened = pulls.first { ($0["head"] as? [String: Any])?["ref"] as? String == branch }
        outcome.opened = opened?["number"] as? Int
        let mainNow = try await SmokeGH.read(["api", "repos/\(LiveSmoke.slug)/commits/main", "--jq", ".sha"])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        step
            .note(
                "outcome: commits on the run branch \(outcome.ahead), test script passes \(outcome.passes), pushed \(outcome.pushed), PR opened \(outcome.opened.map { "#\($0)" } ?? "no")"
            )
        step.expect(
            mainNow == state.mainSHA,
            "main moved during the Fix run: \(state.mainSHA.prefix(7)) -> \(mainNow.prefix(7))"
        )
        if let opened, let number = opened["number"] as? Int {
            state.world.track(pull: number)
            let body = (opened["body"] as? String ?? "").lowercased()
            step.expect(
                body
                    .contains("#\(item.number)") &&
                    (body.contains("close") || body.contains("fix") || body.contains("resolve")),
                "the PR's body does not close #\(item.number): \(body.prefix(200))"
            )
        }
        let close = await run.close()
        step.note("closing: \(close)")
        await run.discard()
        await Self.record(run, "Fix on the bug issue (\(label))")
        return outcome
    }

    // MARK: 5. Review

    func review(_ state: State, _ record: RepoRecord, _ seeded: LiveSmokeWorld.Seeded) async {
        await Smoke.step("E2E 5", "Review run on the seeded PR drafts a review; nothing is posted until Post") { step in
            guard let item = state.pull else { return step.expect(false, "no pull item") }
            let run = LiveBrowseRun(verb: .review, item: item, record: record)
            do {
                try await run.go(
                    worktreeRoot: state.scratch.appendingPathComponent("wt").path,
                    runFolderRoot: state.scratch.appendingPathComponent("runs").path
                )
            } catch {
                await run.discard()
                throw error
            }
            Self.describe(step, run)
            step.expect(run.capped == nil, "the run hit a cap: \(run.capped ?? "")")
            let scripts = run.refused.filter { ($0.command ?? "").range(
                of: #"^python3?\s+\S+\.py"#,
                options: .regularExpression
            ) != nil }
            step.productBug(
                "R2-review-test-script",
                "Review is told 'you may run the tests' but `python test_calc.py` is refused (only python -m pytest/unittest run): "
                    +
                    "\(scripts.map(\.line)); the refusal's wording ('python is allowed for builds and tests') does not say what to run instead",
                reproduced: !scripts.isEmpty
            )
            let before = try await SmokeGH.read([
                "api",
                "repos/\(LiveSmoke.slug)/pulls/\(seeded.pull)/reviews",
                "--jq",
                "length",
            ]).trimmingCharacters(in: .whitespacesAndNewlines)
            step.expect(before == "0", "\(before) reviews exist before Post: the agent posted one itself")
            let edits = run.asked.filter { ["edit", "delete", "move"].contains($0.kind) && $0.allowed }
            step.expect(edits.isEmpty, "a Review was allowed to edit: \(edits.map(\.line))")
            let writes = run.asked
                .filter {
                    ($0.command ?? "").hasPrefix("gh ") && $0.allowed && !($0.command ?? "")
                        .contains(" view") && !($0.command ?? "").contains(" diff")
                }
            step.expect(writes.isEmpty, "a Review was allowed gh writes: \(writes.map(\.line))")
            guard let draft = run.run.draft else {
                let last = run.lines.filter { $0.kind == .said }.last?.text ?? ""
                await run.discard()
                return step.expect(
                    false,
                    "no draft: the last message did not hold a review heed can read. Last message: \(last.prefix(400))"
                )
            }
            step.expect(
                draft.state == .drafted && !draft.body.isEmpty,
                "draft state \(draft.state), body empty \(draft.body.isEmpty)"
            )
            step
                .note(
                    "draft: \(draft.verdict.title), \(draft.body.count) chars: \(draft.body.prefix(200).replacingOccurrences(of: "\n", with: " "))"
                )
            await run.discard()
            await Self.record(run, "Review on the seeded PR")

            // Post: the one path to GitHub.review, on the owner's own PR in the throwaway repository.
            let ref = PullRef(repo: LiveSmoke.repo, number: seeded.pull)
            try SmokeGH.requireSmoke(ref.repo)
            var verdict = draft.verdict.rawValue
            do {
                try await GitHub.review(ref, verdict: verdict, body: draft.body, caller: "browse.review")
            } catch {
                // GitHub refuses to let you approve or request changes on your own pull request.
                step.note("posting as '\(verdict)' failed: \(error)")
                step.productBug(
                    "R1-own-pr-verdict",
                    "a Review on your own PR can draft '\(draft.verdict.title)', and Post then fails: \(error)",
                    reproduced: draft.verdict != .comment
                )
                verdict = "comment"
                try await GitHub.review(ref, verdict: verdict, body: draft.body, caller: "browse.review")
            }
            let reviews = try await SmokeGH.readJSON([
                "api",
                "repos/\(LiveSmoke.slug)/pulls/\(seeded.pull)/reviews",
            ]) as? [[String: Any]] ?? []
            step.expect(reviews.count == 1, "\(reviews.count) reviews after Post")
            let body = reviews.first?["body"] as? String ?? ""
            step.expect(
                body.contains(String(draft.body.prefix(40))),
                "the review's body is not the draft's: \(body.prefix(80))"
            )
            step.note("posted as \(verdict): GitHub says \(reviews.first?["state"] ?? "?")")
        }
    }

    // MARK: 6. Bulk

    func bulk(_ state: State, _: LiveSmokeWorld.Seeded) async {
        guard let bug = state.bug, let feature = state.feature else { return }
        let items = [bug, feature]
        let writer: @Sendable (BrowseBulkAction, BrowseItem) async throws -> Void = { action, item in
            try SmokeGH.requireSmoke(item.repo)
            try await BrowseBulk.write(action, item: item)
        }
        func issue(_ number: Int) async throws -> [String: Any] {
            try await SmokeGH.readJSON(["api", "repos/\(LiveSmoke.slug)/issues/\(number)"]) as? [String: Any] ?? [:]
        }

        await Smoke.step("E2E 6", "bulk: label, assign to me, comment (re-read through gh api GET)") { step in
            let labelPlan = BrowseBulk.plan(.label(["question"]), items: items)
            let report = await BrowseBulk.run(labelPlan, items: items, write: writer)
            step.expect(report.clean && report.done == 2, "label: \(report.lines)")
            let assignPlan = BrowseBulk.plan(.assignMe(state.viewer), items: items)
            step.expect(assignPlan.blocked == nil, "assign plan blocked: \(assignPlan.blocked ?? "")")
            let assigned = await BrowseBulk.run(assignPlan, items: items, write: writer)
            step.expect(assigned.clean && assigned.done == 2, "assign: \(assigned.lines)")
            let text = "heed live smoke comment \(LiveSmoke.runID)"
            let commented = await BrowseBulk.run(
                BrowseBulk.plan(.comment(text), items: items),
                items: items,
                write: writer
            )
            step.expect(commented.clean && commented.done == 2, "comment: \(commented.lines)")
            for item in items {
                let json = try await issue(item.number)
                let labels = (json["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
                step.expect(
                    labels.contains("question") && labels.contains(LiveSmoke.label),
                    "#\(item.number) labels \(labels)"
                )
                let assignees = (json["assignees"] as? [[String: Any]] ?? []).compactMap { $0["login"] as? String }
                step.expect(
                    assignees.map { $0.lowercased() }.contains(state.viewer.lowercased()),
                    "#\(item.number) assignees \(assignees)"
                )
                let comments = try await SmokeGH.readJSON([
                    "api",
                    "repos/\(LiveSmoke.slug)/issues/\(item.number)/comments",
                ]) as? [[String: Any]] ?? []
                step.expect(
                    comments.contains { ($0["body"] as? String) == text },
                    "#\(item.number) has no comment '\(text)'"
                )
            }
        }

        await Smoke.step("E2E 6", "bulk: close with a state_reason (not planned, completed)") { step in
            let notPlanned = await BrowseBulk.run(
                BrowseBulk.plan(.close(.notPlanned), items: [feature]),
                items: [feature],
                write: writer
            )
            step.expect(notPlanned.clean && notPlanned.done == 1, "close not planned: \(notPlanned.lines)")
            let completed = await BrowseBulk.run(
                BrowseBulk.plan(.close(.completed), items: [bug]),
                items: [bug],
                write: writer
            )
            step.expect(completed.clean && completed.done == 1, "close completed: \(completed.lines)")
            let one = try await issue(feature.number), two = try await issue(bug.number)
            step.expect(
                one["state"] as? String == "closed" && one["state_reason"] as? String == "not_planned",
                "feature: \(one["state"] ?? "?") / \(one["state_reason"] ?? "?")"
            )
            step.expect(
                two["state"] as? String == "closed" && two["state_reason"] as? String == "completed",
                "bug: \(two["state"] ?? "?") / \(two["state_reason"] ?? "?")"
            )
        }

        await Smoke.step("E2E 6", "bulk writes refuse any other repository") { step in
            var other = bug
            other.repo = Repo(org: "cli", name: "cli")
            let report = await BrowseBulk.run(
                BrowseBulk.plan(.comment("must never be written"), items: [other]), items: [other], write: writer
            )
            step.expect(report.done == 0 && !report.clean, "a write to cli/cli was not refused: \(report.lines)")
        }
    }

    // MARK: 7. Resume

    func resume(_ state: State) async {
        await Smoke.step("E2E 7", "ResumeCopy.line for a throwaway session") { step in
            let support = state.scratch.appendingPathComponent("Heed Support")
            let files = IntegrationFiles(directory: support)
            let session = Session(
                id: "live-smoke", title: "live smoke", prompt: "do it", repos: [LiveSmoke.repo],
                branch: "heed/browse/issue-1-abc123",
                agent: "claude", agentSessionID: "3f2a0000-0000-0000-0000-000000000000", state: ObservedState(.working)
            )
            let command = try #require(ResumePlan.command(
                .forcedResume(conversation: "3f2a0000-0000-0000-0000-000000000000"), session: session,
                settings: .default, integration: files
            ))
            for shell in [PaneShell.posix, .fish] {
                let line = ResumeCopy.line(command: command, directory: "/tmp/heed live/wt dir", shell: shell)
                step.expect(line.text.hasPrefix("cd "), "the line does not start with cd: \(line.text.prefix(60))")
                step.expect(
                    line.text.contains("claude") && line.text.contains("--resume") && line.text.contains("3f2a0000"),
                    "no resume in: \(line.text)"
                )
                step.expect(
                    line.text.contains(files.claudeSettings),
                    "the hooks settings path is not on the line: \(line.text)"
                )
                step.expect(line.text.contains("claude-hooks.json"), "no claude-hooks.json on the line")
                let upper = line.text.uppercased()
                step.expect(
                    !upper.contains("HEED_SESSION_TOKEN") && !upper.contains("GH_TOKEN") && !upper
                        .contains("API_KEY") && !upper.contains("gho_".uppercased()),
                    "a secret-looking name is on the line: \(line.text)"
                )
                step.expect(!line.text.contains("\n"), "the line spans several lines")
                step.note("\(shell): \(line.text)")
            }
        }
    }

    // MARK: Plumbing

    static func describe(_ step: SmokeStep, _ run: LiveBrowseRun) {
        step
            .note(
                "verdict: \(run.verdict?.text ?? "?"); phase \(run.run.phase.text); stop \(String(describing: run.stop)); cap hit: \(run.capped ?? "no"); \(String(format: "%.0f", run.seconds)) s; \(run.usage)"
            )
        step
            .note(
                "tool calls: \(run.run.story.feed.count { if case .tool = $0.body { true } else { false } }); permission asks: \(run.asked.count), refused \(run.refused.count)"
            )
    }

    /// The run's asks and feed, in the report: every command, allowed or refused.
    static func record(_ run: LiveBrowseRun, _ title: String) async {
        var lines = [
            "- verdict: \(run.verdict?.text ?? "?")",
            "- \(String(format: "%.0f", run.seconds)) s, \(run.usage), cap hit: \(run.capped ?? "no")",
            "",
            "Permission asks, in order:",
            "",
        ]
        lines += run.askLines.map { "    \($0)" }
        lines += ["", "Feed:", ""]
        lines += run.lines
            .map {
                "    \($0.kind.rawValue): \($0.text.prefix(240).replacingOccurrences(of: "\n", with: " ")) \($0.detail.map { "(\($0.prefix(160)))" } ?? "")"
            }
        SmokeReport.shared.extra("Run: \(title)", lines)
    }
}
