import Foundation
import HeedCore

/// Ready to merge, merge now, force merge and whether a repo's merge settings can work: the domain's answers
/// (`MergeCandidate`, `MergeNow`, `RepoMergeReadiness`) for the views, and the `gh pr merge` behind `zM`.
extension AppModel {
    /// Whether a PR meets every merge requirement; nil until its detail is fetched.
    func mergeCandidate(for ref: PullRef) -> MergeCandidate? {
        pullDetails[ref.description].map {
            MergeCandidate.of($0, settings: pilotSettings(for: ref), now: Clock.now)
        }
    }

    /// Ready to merge while get it merged is off for it: what the row, the card and Attention offer to merge now.
    func readyToMerge(_ ref: PullRef) -> Bool {
        guard pilot(for: ref).merge == .off, github.pull(ref)?.state ?? .open == .open else { return false }
        return mergeCandidate(for: ref)?.isCandidate ?? false
    }

    /// Every PR heed has a detail for that is ready to merge with merging off.
    var readyToMergeRefs: Set<PullRef> {
        Set(pullDetails.values.map(\.ref).filter(readyToMerge))
    }

    /// What the repo allows, from the newest detail of one of its PRs.
    func repoMergeFacts(_ repo: Repo) -> RepoMergeFacts? {
        RepoMergeFacts.of(repo, details: pullDetails.values)
    }

    /// Whether get it merged is set up for a repo and can work there (the Repos view's badge and the setup flow).
    func repoMergeReadiness(_ repo: Repo) -> RepoMergeReadiness {
        RepoMergeReadiness.of(config.pilot.resolve(repo), facts: repoMergeFacts(repo))
    }

    /// The same for one PR, with its own merge choice (`zm`) when it has one.
    func mergeReadiness(for ref: PullRef) -> RepoMergeReadiness {
        RepoMergeReadiness.of(pilotSettings(for: ref), mode: pilot(for: ref).merge, facts: repoMergeFacts(ref.repo))
    }

    /// `zM`: merge the PR now. Asks first when `merge_now` (or, past what GitHub enforces, `force_merge`) says so.
    func mergeNow() {
        guard let ref = pilotTargets.first else { return flash = noOpenPR }
        guard let detail = pullDetails[ref.description] else {
            fetchDetail(ref)
            return flash = "#\(ref.number): fetching its detail first, then \(keyText(for: "pilot.merge.now")) again"
        }
        let settings = pilotSettings(for: ref)
        let offer = MergeNow.offer(
            MergeCandidate.of(detail, settings: settings, now: Clock.now), detail: detail, settings: settings
        )
        if case let .unavailable(why) = offer { return flash = "#\(ref.number) cannot merge now: \(why)" }
        guard MergeNow.asks(offer, settings: settings), let prompt = MergeNow.prompt(offer, detail: detail) else {
            return mergeNow(ref, offer, detail)
        }
        ask(Confirmation(
            title: prompt.title, lines: prompt.lines, accept: prompt.accept, destructive: prompt.destructive
        ) { [weak self] in self?.mergeNow(ref, offer, detail) })
    }

    /// `gh pr merge` on the head commit the requirements were checked on (`--admin` for a force merge).
    private func mergeNow(_ ref: PullRef, _ offer: MergeNow.Offer, _ detail: PullDetail) {
        let (method, admin): (String, Bool) = switch offer {
        case let .merge(method, _): (method, false)
        case let .force(method, _, _): (method, true)
        case .unavailable: ("", false)
        }
        guard !method.isEmpty else { return }
        let how = admin ? "\(method), --admin" : method
        if isFixture {
            logPilot(ref, .merged, "merged now by you (\(how); fixture: nothing merged)")
            return flash = "#\(ref.number): merged (\(how); fixture: nothing merged)"
        }
        flash = "#\(ref.number): merging (\(how))…"
        Task {
            do {
                try await GitHub.merge(
                    ref,
                    method: method,
                    head: detail.headSHA,
                    admin: admin,
                    caller: "pilot.mergeNow"
                )
                logPilot(ref, .merged, "merged now by you (\(how))")
                flash = "#\(ref.number): merged (\(how))"
            } catch {
                logPilot(ref, .held, "merge now refused: \(error)")
                flash = "#\(ref.number): GitHub refused the merge: \(error)"
            }
            fetchDetail(ref)
        }
    }

    /// Set up get it merged for the PR's repo: Settings › Orgs & repos on the repo, where its merge settings are. The
    /// repos setup flow takes this over once it exists.
    func setUpMerging(_ repo: Repo? = nil) {
        guard let repo = repo ?? pilotTargets.first?.repo else { return flash = noOpenPR }
        settingsScope = .repo(repo)
        settingsSection = .colors
        openSettings?()
    }
}
