import AppKit
import HeedCore

/// The setup wizard for a repo's get it merged and get it green (`repo.setup`): it samples the repo off the main actor
/// (every call a GitHub row in the call log), proposes, validates, and writes `[repos."org/name"]` lines into
/// config.toml in place. It never changes anything on GitHub.
extension AppModel {
    /// `repo.setup [repo]` (`M` in Repos, a repo's Set up… button, its right-click menu): the named repo, the one
    /// clicked, or the one under the cursor.
    func openRepoSetup(_ argument: String?, repo explicit: Repo? = nil) {
        let named = argument.flatMap { name -> Repo? in
            if let known = repos.map(\.repo).first(where: { $0.slug == name || $0.name == name }) { return known }
            let parts = name.split(separator: "/").map(String.init)
            return parts.count == 2 ? Repo(org: parts[0], name: parts[1]) : nil
        }
        guard let repo = explicit ?? named ?? reposUnderCursor.first else {
            return flash = argument.map { "no repo \($0) here" } ?? "which repo? :repo.setup org/name"
        }
        guard repo.org != "local" else { return flash = "\(repo.name) is not on GitHub: nothing to sample" }
        repoSetupTask?.cancel()
        var wizard = RepoSetupWizard(
            repo: repo, current: config.pilot.resolve(repo), agents: settings.agents.map(\.name)
        )
        if isFixture {
            // Snapshots and the tutor never reach GitHub: an invented history for the repo.
            let sample = RepoSetupFixtures.sample(for: repo, runs: runs)
            wizard.sampled(sample)
            repoMergeSettings[repo.slug] = sample.settings
            repoSetup = wizard
            return
        }
        repoSetup = wizard
        let record = repos.first { $0.repo == repo }
        let runs = runs
        let report: @Sendable (GitHub.SampleStep, Bool) async -> Void = { [weak self] step, done in
            await self?.sampleProgress(repo, step, done: done)
        }
        repoSetupTask = Task { [weak self] in
            let tasks = if let record {
                await TaskDiscovery.discover(at: record.path, on: record.location).tasks
            } else {
                [TaskSpec]()
            }
            do {
                let sample = try await GitHub.sampleRepo(
                    repo, runs: runs, tasks: tasks, caller: "repo.setup", progress: report
                )
                guard !Task.isCancelled, let self, repoSetup?.repo == repo else { return }
                repoMergeSettings[repo.slug] = sample.settings
                repoSetup?.sampled(sample)
            } catch {
                guard !Task.isCancelled, let self, repoSetup?.repo == repo else { return }
                repoSetup?.failed("\(error)")
            }
        }
    }

    private func sampleProgress(_ repo: Repo, _ step: GitHub.SampleStep, done: Bool) {
        guard repoSetup?.repo == repo else { return }
        if done { repoSetup?.finished(step) } else { repoSetup?.began(step) }
    }

    func answerRepoSetup(_ stroke: KeyStroke) {
        guard var wizard = repoSetup else { return }
        let outcome = wizard.handle(stroke)
        repoSetup = wizard
        finish(outcome, of: wizard)
    }

    private func finish(_ outcome: RepoSetupWizard.Outcome, of wizard: RepoSetupWizard) {
        switch outcome {
        case .handled: break
        case .close: closeRepoSetup()
        case let .open(url):
            if !isFixture, let link = URL(string: url) { NSWorkspace.shared.open(link) }
        case let .write(edits): writeRepoSetup(wizard, edits)
        }
    }

    func closeRepoSetup() {
        repoSetupTask?.cancel()
        repoSetupTask = nil
        repoSetup = nil
    }

    // The mouse's way through the wizard: the same steps the keys take.
    func repoSetupNext() {
        guard var wizard = repoSetup else { return }
        let outcome = wizard.next()
        repoSetup = wizard
        finish(outcome, of: wizard)
    }

    func repoSetupBack() { repoSetup?.back() }
    func repoSetupGo(_ step: RepoSetupWizard.Step) { repoSetup?.go(to: step) }
    func repoSetupPoint(_ row: Int) { repoSetup?.point(at: row) }
    func repoSetupToggle(_ row: Int) { repoSetup?.toggle(row: row) }
    func repoSetupChoose(field: Int, choice: Int) { repoSetup?.choose(field: field, choice: choice) }

    func repoSetupOpenFix(_ index: Int) {
        guard let wizard = repoSetup, wizard.fixes.indices.contains(index), let url = wizard.fixes[index].url else {
            return
        }
        repoSetup?.point(at: index)
        finish(.open(url), of: wizard)
    }

    /// ↩ on the last step: the lines go into config.toml (off the main actor), and the watcher reloads it.
    private func writeRepoSetup(_ wizard: RepoSetupWizard, _ edits: [RepoSetupConfig.Edit]) {
        let repo = wizard.repo
        let fixes = wizard.fixes.count
        let after = fixes == 0 ? "" : "; \(fixes) GitHub setting\(fixes == 1 ? "" : "s") to change (\(keyText(for: "repo.setup", in: "repos")) shows them again)"
        closeRepoSetup()
        guard !edits.isEmpty else { return flash = "\(repo.slug): nothing to write, config.toml is unchanged" }
        let keys = edits.map(\.key).joined(separator: ", ")
        guard !isFixture else { return flash = "\(repo.slug): would write \(keys)\(after)" }
        let file = configFile
        Task { [weak self] in
            let error: String? = await Task.detached(priority: .userInitiated) {
                do {
                    let text = (try? String(contentsOf: file, encoding: .utf8)) ?? ConfigLoader.defaultSource
                    try RepoSetupConfig.apply(edits, repo: repo, to: text).write(
                        to: file,
                        atomically: true,
                        encoding: .utf8
                    )
                    return nil
                } catch {
                    return "\(error)"
                }
            }.value
            self?.flash = error.map { "could not write config.toml: \($0)" }
                ?? "\(repo.slug): wrote \(keys) to config.toml\(after)"
        }
    }

    /// The Repos column's right-click menu on a repo.
    func repoMenu(_ repo: Repo) -> [MenuEntry] {
        ContextMenus.repo(repo, allIssues: config.issues.visibility(repo) == .all)
    }

    /// Where a repo stands for merging and get it green, for the Repos view.
    func setupStatus(for repo: Repo) -> RepoSetupStatus {
        RepoSetupStatus.of(repo, rules: config.pilot, readiness: repoMergeReadiness(repo))
    }

    /// The docs' screenshot of the first step while it samples: settings read, merged PRs on their way.
    func showRepoSetupSampling(_ repo: Repo) {
        var wizard = RepoSetupWizard(repo: repo, current: config.pilot.resolve(repo))
        wizard.finished(.settings)
        wizard.began(.pulls)
        repoSetup = wizard
    }
}
