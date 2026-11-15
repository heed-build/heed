import Foundation
import HeedCore

/// Audit's grants: what heed gave for good is recorded where it gives it, and `d` takes one back where it lives.
extension AppModel {
    // MARK: Grants

    /// Always for a Claude ask with rules: Claude writes them to the project's `settings.local.json`.
    func recordAlwaysGrant(_ ask: PermissionAsk) {
        guard ask.agent == "claude", !ask.rules.isEmpty else { return }
        let session = sessions.first { $0.id == ask.session }
        let root = session?.worktreePaths.first ?? ask.cwd ?? ""
        let file = Paths.abbreviate(AlwaysRules.file(root: root).path)
        let cause = makeCause(.key, "approvals · Always", session: session, authors: [])
        for rule in ask.rules {
            audit.record(AuditGrant(
                at: Clock.now, kind: .alwaysRule, subject: rule.text, scope: file,
                why: "Always in the approvals, on \(ask.command ?? ask.tool)", cause: cause.id, session: ask.session
            ))
        }
    }

    /// A helper's agent was told Always over ACP.
    func recordHelperAlways(_ id: String) {
        guard let run = helpers.run(id), let permission = run.permission else { return }
        let cause = Cause.current ?? keyCause(CommandInvocation(name: "helper.allow.always"))
        audit.note(cause)
        audit.record(AuditGrant(
            at: Clock.now, kind: .helperAlways, subject: permission.command ?? permission.title,
            scope: Paths.abbreviate(run.worktree), why: "Always for the helper's agent, for its run", cause: cause.id
        ))
    }

    /// Trust heed gave a repo for agents (`~/.claude.json`, mise).
    func recordTrustGrant(_ kind: AuditGrant.Kind, path: String, repo: String) {
        let cause = Cause.current ?? Cause(at: Clock.now, trigger: .key, detail: "Trust · new worktree")
        audit.note(cause)
        audit.record(AuditGrant(
            at: Clock.now, kind: kind, subject: Paths.abbreviate(path), scope: repo,
            why: kind == .claudeTrust ? "Claude Code would ask in every new worktree" : "its mise config sets [env]",
            cause: cause.id
        ))
    }

    /// A login added to a repo's `trusted_reviewers` or `trusted_authors`.
    func recordTrustedLogin(_ kind: AuditGrant.Kind, login: String, repo: Repo, why: String) {
        let cause = Cause.current ?? Cause(at: Clock.now, trigger: .key, detail: "trusted \(login)")
        audit.note(cause)
        audit.record(AuditGrant(
            at: Clock.now, kind: kind, subject: login, scope: repo.slug, why: why, cause: cause.id
        ))
    }

    /// Decisions an agent proposed, kept in the Mindmap.
    func recordMemoryGrants(_ texts: [String], node: String, title: String, instance: String) {
        let cause = Cause.current ?? Cause(at: Clock.now, trigger: .key, detail: "y · mindmap.accept")
        audit.note(cause)
        for text in texts {
            audit.record(AuditGrant(
                at: Clock.now, kind: .memory, subject: text, scope: "\(instance)|\(node)",
                why: "an agent proposed it on \(title)", cause: cause.id
            ))
        }
    }

    // MARK: Revoking

    /// `d` on a grant: asks, then takes it back where it lives.
    func revokeSelectedGrant() {
        guard audit.section == .grants
        else { return flash = "\(keyText(for: "audit.grants", in: "audit")) shows the grants" }
        guard let row = audit.selectedGrant else { return flash = "no grant here" }
        if row.revoked != nil { return flash = "already revoked" }
        let grant = row.grant
        guard grant.kind.revocable else { return flash = "a helper's Always ends with its run: nothing to revoke" }
        ask(Confirmation(
            title: "Revoke \(grant.kind.label) \(grant.subject)?", lines: revokeLines(grant), accept: "Revoke",
            action: { [weak self] in self?.revoke(grant) }
        ))
    }

    private func revokeLines(_ grant: AuditGrant) -> [String] {
        switch grant.kind {
        case .alwaysRule: ["Takes \(grant.subject) out of \(grant.scope)", "The agent asks for it again"]
        case .claudeTrust: ["Sets hasTrustDialogAccepted to false for \(grant.subject) in ~/.claude.json"]
        case .miseTrust: ["Runs mise trust --untrust in \(grant.subject)"]
        case .trustedReviewer: ["Takes \(grant.subject) out of trusted_reviewers for \(grant.scope)"]
        case .trustedAuthor: ["Takes \(grant.subject) out of trusted_authors for \(grant.scope)"]
        case .memory: ["Drops the decision from the Mindmap: sessions are no longer told it"]
        case .helperAlways: []
        }
    }

    private func revoke(_ grant: AuditGrant) {
        let cause = keyCause(CommandInvocation(name: "audit.revoke"))
        audit.note(cause)
        func done(_ result: String) {
            audit.record(AuditRevocation(grant: grant, at: Clock.now, cause: cause.id, result: result))
            flash = result
        }
        if isFixture { return done("revoked (fixture: nothing changed)") }
        switch grant.kind {
        case .alwaysRule:
            let file = URL(fileURLWithPath: Paths.expand(grant.scope))
            Task {
                let result = await Task.detached { () -> String in
                    do {
                        return try AlwaysRules.remove(grant.subject, from: file)
                            ? "took \(grant.subject) out of its settings" : "\(grant.subject) was no longer there"
                    } catch {
                        return "\(error)"
                    }
                }.value
                done(result)
            }
        case .claudeTrust:
            let path = Paths.expand(grant.subject)
            Task {
                let result = await Task.detached { () -> String in
                    do {
                        return try ClaudeTrust.untrust(path) ? "Claude no longer trusts \(grant.subject)"
                            : "Claude did not trust \(grant.subject)"
                    } catch {
                        return "\(error)"
                    }
                }.value
                done(result)
            }
        case .miseTrust:
            let path = Paths.expand(grant.subject)
            Task {
                do {
                    try await MiseTrust.untrust(path)
                    done("mise no longer trusts \(grant.subject)")
                } catch {
                    done("mise trust --untrust: \(error)")
                }
            }
        case .trustedReviewer, .trustedAuthor:
            let slug = grant.scope.split(separator: "/", maxSplits: 1).map(String.init)
            guard slug.count == 2 else { return done("no repo \(grant.scope)") }
            let repo = Repo(org: slug[0], name: slug[1])
            let settings = config.pilot.resolve(repo)
            let key = grant.kind == .trustedReviewer ? "trusted_reviewers" : "trusted_authors"
            let list = TrustedLogins.removing(
                grant.subject,
                from: grant.kind == .trustedReviewer ? settings.trustedReviewers : settings.trustedAuthors
            )
            writeAutopilot([AutopilotSwitch.Write(["repos", repo.slug, key], .array(list.map(TOMLValue.string)))])
            done("\(grant.subject) is out of \(key) for \(repo.slug)")
        case .memory:
            let parts = grant.scope.split(separator: "|", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return done("heed cannot tell where that decision is") }
            Task {
                await mindmap.change(parts[0]) { _ = $0.dropDecision(grant.subject, in: parts[1], now: Date()) }
                done("dropped the decision: sessions are no longer told it")
            }
        case .helperAlways:
            break
        }
    }
}
