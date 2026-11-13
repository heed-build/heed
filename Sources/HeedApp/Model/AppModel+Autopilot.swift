import Foundation
import HeedCore

/// Autopilot (`gw`): what heed can do on its own (Can do), where it is on (Where), what it is doing (Now, the view
/// that was Watch) and what it did (Done). The counting is `HeedCore`'s (`AutopilotCoverage`, `AutopilotDone`,
/// `AutopilotNudges`, `AutopilotNow`); this gathers its inputs from the domain and runs the keys.
extension AppModel {
    // MARK: What it reads

    /// Every repo heed knows, once each (a repo on several machines is one), by name.
    var autopilotRepos: [Repo] {
        var seen: Set<String> = []
        return repos.map(\.repo).filter { seen.insert($0.slug).inserted }.sorted { $0.name < $1.name }
    }

    /// What heed has seen of each repo on GitHub: whether it allows auto-merge, whether Copilot can work there.
    var autopilotFacts: [String: AutopilotRepoFacts] {
        var facts: [String: AutopilotRepoFacts] = [:]
        for repo in autopilotRepos {
            let allows = pullDetails.values.first { $0.ref.repo == repo && $0.repoAllowsAutoMerge != nil }?
                .repoAllowsAutoMerge
            facts[repo.slug] = AutopilotRepoFacts(allowsAutoMerge: allows, copilotAvailable: copilotAvailable(repo))
        }
        return facts
    }

    func autopilotCell(_ capability: Capability, repo: Repo) -> AutopilotCell {
        AutopilotCoverage.cell(
            capability, repo: repo, config: config, facts: autopilotFacts[repo.slug] ?? AutopilotRepoFacts()
        )
    }

    func autopilotSummary(_ capability: Capability) -> AutopilotCoverage.Summary {
        AutopilotCoverage.summary(capability, repos: autopilotRepos, config: config, facts: autopilotFacts)
    }

    /// What Done tells, from what heed recorded.
    var autopilotRecord: AutopilotRecord {
        var titles: [String: String] = [:]
        for pull in github.pulls {
            titles[pull.ref.description] = pull.title
        }
        for (key, detail) in pullDetails where titles[key] == nil {
            titles[key] = detail.title
        }
        let items = Dictionary(attentionEntries.map { ($0.id, $0.item) }) { first, _ in first }
        let catchUps = attention.catchUps.map { id, summary in
            AutopilotCatchUp(
                id: id, summary: summary, title: items[id]?.title ?? "a thread", repo: items[id]?.repo?.slug
            )
        }
        let goalTitles = Dictionary(goals.snapshot.goals.map { ($0.id, $0.title) }) { first, _ in first }
        return AutopilotRecord(
            pilotLog: pilotLog, titles: titles, catchUps: catchUps, attach: goals.attach.decisions,
            goalTitles: goalTitles, sessions: sessions, continuePrompt: settings.continuePrompt
        )
    }

    /// Everything heed did, newest first.
    var autopilotEntries: [AutopilotEntry] { AutopilotDone.entries(autopilotRecord) }

    /// The last seven days of it.
    var autopilotWeek: [AutopilotEntry] { AutopilotDone.thisWeek(autopilotEntries, now: Clock.now) }

    /// Done's lines: the week narrowed by its rail, by day.
    var autopilotDays: [AutopilotDone.Day] {
        AutopilotDone.days(
            autopilotWeek, capability: autopilotBrowser.doneCapability, repo: autopilotBrowser.doneRepo, now: Clock.now
        )
    }

    var autopilotDoneLines: [AutopilotEntry] { autopilotDays.flatMap(\.entries) }

    var autopilotDoneSelected: AutopilotEntry? {
        let lines = autopilotDoneLines
        return lines.indices.contains(autopilotBrowser.doneCursor) ? lines[autopilotBrowser.doneCursor] : nil
    }

    /// What heed sees that a capability would help with.
    var autopilotSignals: AutopilotSignals {
        var signals = AutopilotSignals(sentByYou: AutopilotDone.sentByYou(pilotLog, now: Clock.now))
        for ref in Set(sessions.flatMap(\.trackedPRs)) where isOpen(ref) {
            let slug = ref.repo.slug
            let status = pilotStatus(for: ref)
            let effective = pilot(for: ref)
            if status == .green, effective.merge == .off { signals.greenWaiting[slug, default: 0] += 1 }
            if status == .unwatched { signals.unwatched[slug, default: 0] += 1 }
            if pullDetails[ref.description]?.mergeable == "CONFLICTING" { signals.conflicting[slug, default: 0] += 1 }
            let ready = pullDetails[ref.description]?.isDraft.map { !$0 } ?? (github.pull(ref)?.isDraft == false)
            if ready, feedback[ref.description]?.reviewersRequested.isEmpty ?? true {
                signals.unreviewed[slug, default: 0] += 1
            }
        }
        for removal in sweepPlanIfOn.removals {
            signals.removable[removal.worktree.repo.slug, default: 0] += 1
        }
        signals.openAsks = goals.attach.asks.count
        return signals
    }

    var autopilotNudges: [AutopilotNudge] {
        AutopilotNudges.all(repos: autopilotRepos, config: config, facts: autopilotFacts, signals: autopilotSignals)
    }

    var autopilotTabCounts: AutopilotTabs.Counts {
        let rows = pilotRows
        return AutopilotTabs.Counts(
            off: AutopilotCoverage.offCount(repos: autopilotRepos, config: config, facts: autopilotFacts),
            now: AutopilotNow.activeCount(rows.map(autopilotPull)), done: autopilotWeek.count
        )
    }

    /// `6 worktrees · 3 PRs`, under a repo in Where.
    func autopilotRepoLine(_ repo: Repo) -> String {
        let worktrees = worktrees.count { $0.repo == repo && !$0.isMain }
        let pulls = Set(sessions.flatMap(\.trackedPRs)).count { $0.repo == repo && isOpen($0) }
        return "\(worktrees) worktree\(worktrees == 1 ? "" : "s") · \(pulls) PR\(pulls == 1 ? "" : "s")"
    }

    // MARK: Clicks

    func clickAutopilotCard(_ capability: Capability) {
        guard clicksReachLists else { return }
        clickedOutsideTerminal()
        autopilotBrowser.pick(capability)
    }

    func clickAutopilotCell(row: Int, column: Int) {
        guard clicksReachLists else { return }
        clickedOutsideTerminal()
        autopilotBrowser.setCell(row: row, column: column, rows: autopilotRepos.count)
    }

    // MARK: Keys

    /// The capability under the cursor: Can do's picked card, Where's column.
    var autopilotCapability: Capability {
        view == .autopilotWhere ? autopilotBrowser.whereCapability : autopilotBrowser.capability
    }

    /// Where's repo under the cursor.
    var autopilotWhereRepo: Repo? {
        let repos = autopilotRepos
        return repos.indices.contains(autopilotBrowser.row) ? repos[autopilotBrowser.row] : nil
    }

    /// The repo `y` turns a per-repo capability on in from Can do: the strongest nudge's, else the first repo where it
    /// is off.
    func autopilotHere(_ capability: Capability) -> Repo? {
        guard capability.scope == .perRepo else { return nil }
        let repos = autopilotRepos
        if let slug = AutopilotNudges.best(capability, in: autopilotNudges)?.repo,
           let repo = repos.first(where: { $0.slug == slug }),
           autopilotCell(capability, repo: repo).state != .on
        {
            return repo
        }
        return repos.first { autopilotCell(capability, repo: $0).state == .off }
            ?? repos.first { autopilotCell(capability, repo: $0).state == .ask }
    }

    func performAutopilot(_ command: CommandInvocation) {
        let browser = autopilotBrowser
        switch command.name {
        case "view.autopilot", "view.watch", "autopilot.cando":
            if let name = command.arguments.first, let capability = Capability(rawValue: name) {
                browser.pick(capability)
            } else if command.name == "autopilot.cando", view == .autopilotWhere {
                browser.pick(browser.whereCapability)
            }
            view = .autopilot
        case "autopilot.where":
            if view == .autopilot { browser.pick(browser.capability) }
            view = .autopilotWhere
        case "autopilot.now": view = .watch
        case "autopilot.done":
            if let name = command.arguments.first { browser.doneCapability = Capability(rawValue: name) }
            browser.setDoneCursor(0, count: autopilotDoneLines.count)
            view = .autopilotDone
        case "autopilot.move":
            let direction = command.arguments.first ?? "j"
            for _ in 0 ..< max(command.count ?? 1, 1) {
                if view == .autopilotWhere {
                    browser.moveCell(direction, rows: autopilotRepos.count)
                } else {
                    browser.moveCard(direction)
                }
            }
        case "autopilot.on", "autopilot.ask", "autopilot.off":
            let choice: AutopilotSwitch.Choice = command.name == "autopilot.on" ? .on
                : command.name == "autopilot.ask" ? .ask : .off
            switchAutopilot(choice, arguments: command.arguments)
        case "autopilot.everywhere": switchAutopilotEverywhere()
        case "autopilot.open": openAutopilot()
        case "autopilot.settings":
            perform(CommandInvocation(name: "settings.open", arguments: [autopilotCapability.settingsPage]))
        case "autopilot.what":
            let all = Capability.allCases
            if let name = command.arguments.first {
                browser.doneCapability = Capability(rawValue: name)
            } else if let current = browser.doneCapability, let index = all.firstIndex(of: current) {
                browser.doneCapability = index + 1 < all.count ? all[index + 1] : nil
            } else {
                browser.doneCapability = all.first
            }
            browser.setDoneCursor(0, count: autopilotDoneLines.count)
            flash = "Done: \(browser.doneCapability?.title ?? "everything")"
        case "autopilot.repo":
            let repos = AutopilotDone.repoCounts(autopilotWeek).keys.sorted()
            if let name = command.arguments.first {
                browser.doneRepo = repos.first { $0 == name || $0.hasSuffix("/\(name)") }
            } else if let current = browser.doneRepo, let index = repos.firstIndex(of: current) {
                browser.doneRepo = index + 1 < repos.count ? repos[index + 1] : nil
            } else {
                browser.doneRepo = repos.first
            }
            browser.setDoneCursor(0, count: autopilotDoneLines.count)
            flash = "Done: \(browser.doneRepo ?? "every repo")"
        default: break
        }
    }

    /// `y` `a` `x`: on Where the cell under the cursor; on Can do the picked card, in the repo its nudge names (else
    /// the first where it is off) for a per-repo one.
    private func switchAutopilot(_ choice: AutopilotSwitch.Choice, arguments: [String]) {
        let capability = arguments.first.flatMap(Capability.init(rawValue:)) ?? autopilotCapability
        // On Can do a per-repo one is turned on where it would help; off and ask first are per repo, on Where.
        if view == .autopilot, choice != .on, capability.scope == .perRepo, arguments.count < 2 {
            return flash = "\(capability.title) is set per repo: \(keyText(for: "autopilot.where", in: "autopilot")) "
                + "shows each repo, where a x set it"
        }
        let named = arguments.dropFirst().first.flatMap { name in
            autopilotRepos.first { $0.slug == name || $0.name == name }
        }
        let repo: Repo? = capability.scope == .perRepo
            ? named ?? (view == .autopilotWhere ? autopilotWhereRepo : autopilotHere(capability)) : nil
        if capability.scope == .perRepo, repo == nil {
            return flash = choice == .on ? "\(capability.title) is on in every repo" : "no repo to change"
        }
        do {
            let writes = try AutopilotSwitch.writes(
                capability, choice, repo: repo, config: config,
                facts: repo.flatMap { autopilotFacts[$0.slug] } ?? AutopilotRepoFacts()
            )
            writeAutopilot(writes)
            let word = choice == .on ? "on" : choice == .ask ? "asks first" : "off"
            flash = "\(capability.title) \(word)" + (repo.map { " in \($0.name)" } ?? "")
        } catch let AutopilotSwitch.Refusal.noChoice(why) {
            flash = why
        } catch {}
    }

    private func switchAutopilotEverywhere() {
        let capability = autopilotCapability
        do {
            try writeAutopilot(AutopilotSwitch.everywhere(capability, config: config, facts: autopilotFacts))
            flash = capability.scope == .perRepo ? "\(capability.title) on in every repo" : "\(capability.title) on"
        } catch let AutopilotSwitch.Refusal.noChoice(why) {
            flash = why
        } catch {}
    }

    /// `↩`: Can do shows what the card did; Where opens the repo in Repos; Now reads the PR; Done opens its PR or
    /// session.
    private func openAutopilot() {
        switch view {
        case .autopilot:
            perform(CommandInvocation(name: "autopilot.done", arguments: [autopilotBrowser.capability.rawValue]))
        case .autopilotWhere:
            guard let repo = autopilotWhereRepo else { return }
            view = .repos
            pickRepo(repo)
        case .watch:
            perform(CommandInvocation(name: "open.reader"))
        case .autopilotDone:
            guard let entry = autopilotDoneSelected else { return }
            if entry.ref != nil {
                perform(CommandInvocation(name: "open.reader"))
            } else if let id = entry.session, sessions.contains(where: { $0.id == id }) {
                view = .sessions
                select(sessionID: id)
            } else if entry.capability == .goals {
                perform(CommandInvocation(name: "view.goals"))
            } else if entry.capability == .summaries {
                perform(CommandInvocation(name: "view.attention"))
            }
        default: break
        }
    }
}
