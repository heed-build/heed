import HeedCore
import SwiftUI

/// Repos: the repo column on the left is a filter (All, then each repo, with how its main stands and what its setup
/// lacks); on the right, cleanup up top, the picked repo's card with its actions, then its worktrees (all of them,
/// grouped by repo, for All). The cleanup settings live in Settings › Worktrees › Cleanup.
struct ReposView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 0) {
            repoColumn.shotRegion(.repoColumn)
            VStack(spacing: 0) {
                CleanupBar(plan: model.sweepPlan).shotRegion(.cleanupBar)
                if let record = model.pickedRecord {
                    RepoCard(record: record, summary: model.repoSummaries[record.id] ?? RepoSummary())
                        .shotRegion(.repoCard)
                }
                if let (record, proposal) = setupUnderCursor {
                    SetupBanner(record: record, proposal: proposal).shotRegion(.setupBanner)
                }
                table.shotRegion(.worktreeTable)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Theme.bg)
        }
    }

    // MARK: The repo column

    private var repoColumn: some View {
        let summaries = model.repoSummaries
        let focused = model.reposFocus == .repos
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                SectionHeader(title: "Repos · \(model.sortedRepos.count)")
                Spacer(minLength: 4)
                RepoButton(label: "Add or clone", command: "repo.add", primary: true)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ListScroll {
                VStack(alignment: .leading, spacing: 0) {
                    allRow(focused: focused)
                    ForEach(model.sortedRepos) { record in
                        RepoColumnRow(
                            record: record, count: model.worktreeRowCounts[record.repo.slug] ?? 0,
                            summary: summaries[record.id] ?? RepoSummary(),
                            picked: model.pickedRepo == record.repo, focused: focused
                        )
                    }
                }
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack(spacing: 6) {
                Text("Found under \(model.settings.repoRoots.joined(separator: ", ")).")
                    .lineLimit(1).truncationMode(.tail)
                KeyCap(text: model.keyText(for: "repo.scan", in: "repos"))
                Text("rescans").fixedSize()
            }
            .font(Theme.ui(11.5))
            .foregroundStyle(Theme.fg3)
            .padding(16)
            .clickRuns(CommandInvocation(name: "repo.scan"))
        }
        .frame(width: 290)
        .background(Theme.bg2)
        .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
    }

    private func allRow(focused: Bool) -> some View {
        let picked = model.pickedRepo == nil
        return HStack(spacing: 8) {
            Color.clear.frame(width: 16, height: 1)
            Text("All worktrees").font(Theme.mono(12.5)).foregroundStyle(picked ? Theme.fg : Theme.fg2)
            Spacer()
            Text("\(model.allWorktreeRowCount)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 9)
        .background(picked ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) {
            if picked, focused { Theme.block.frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.clickRepo(nil) }
    }

    // MARK: The worktree table

    private var table: some View {
        let rows = model.worktreeRows
        let selected = model.selectedRows
        let groupStarts = model.pickedRepo == nil
            ? Dictionary(uniqueKeysWithValues: RepoFilter.groups(rows).map { ($0.index, $0.repo) }) : [:]
        return VStack(spacing: 0) {
            header(count: rows.count)
            if !rows.isEmpty {
                ScrollViewReader { proxy in
                    ListScroll {
                        ListStack(spacing: 0) {
                            ForEach(Array(rows.enumerated()), id: \.element.id) { index, worktree in
                                VStack(spacing: 0) {
                                    if let repo = groupStarts[index] { GroupHeader(repo: repo) }
                                    row(worktree, index: index, selected: selected)
                                }
                                .id(worktree.id)
                            }
                        }
                    }
                    .onChange(of: model.repoCursor) {
                        if rows.indices.contains(model.repoCursor) { proxy.scrollTo(rows[model.repoCursor].id) }
                    }
                }
            }
            if rows.isEmpty { empty }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(16)
    }

    private func row(_ worktree: Worktree, index: Int, selected: Set<String>) -> some View {
        let session = model.session(for: worktree)
        let isCursor = index == model.repoCursor && model.reposFocus == .worktrees
        return WorktreeRow(
            worktree: worktree,
            session: session,
            number: index == model.repoCursor ? index + 1 : abs(index - model.repoCursor),
            isCursor: isCursor,
            isSelected: selected.contains(worktree.id),
            roots: model.settings.pathRoots,
            query: model.filter(for: .repos),
            pilot: session.flatMap { model.pilotStatus(of: $0) },
            registration: model.registration(of: worktree),
            hostColor: worktree.location.hostName.flatMap { model.config.hosts[$0]?.color },
            age: model.worktreeAge(worktree),
            openKey: model.keyText(for: "select.open", in: "repos")
        )
        .hint(model.hintLabel(for: .row(.repos, index)))
        .contentShape(Rectangle())
        .onTapGesture {
            model.focusRepos("worktrees")
            model.clickRow(.repos, index)
        }
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            model.focusRepos("worktrees")
            model.clickRow(.repos, index, open: true)
        })
        .rightClickMenu { model.rightClickRow(.repos, index) } _: {
            model.rowMenu(.repos, index)
        }
    }

    @ViewBuilder private var empty: some View {
        if model.repos.isEmpty {
            EmptyState(
                title: "No repos found yet",
                detail: "Heed looks two levels deep in \(model.settings.repoRoots.joined(separator: ", ")) for git "
                    + "repositories. Add or clone one, add the folder yours live in, or import a worktree from "
                    + "anywhere: its repo comes with it.",
                actions: [
                    .init("add or clone a repo", "repo.add"),
                    .init("add the folder your repos are in", "settings.open", arguments: ["worktrees"]),
                    .init("import a worktree by its path", "session.import.path"),
                    .init("scan again", "repo.scan"),
                ]
            )
        } else if model.worktreeCount == 0 || (model.pickedRepo != nil && model.filter(for: .repos).isEmpty) {
            EmptyState(
                title: model.pickedRepo.map { "No worktrees in \($0.name) yet" } ?? "No worktrees yet",
                detail: "Start work makes one per task under \(model.settings.worktreeRoot), with its branch and "
                    + "agent; worktrees you made yourself can be imported.",
                actions: [
                    .init("start work in a repo", "worktree.new"), .init("import a worktree", "session.import"),
                ]
            )
        } else {
            Text("No worktrees match /\(model.filter(for: .repos)).")
                .foregroundStyle(Theme.fg2)
                .font(Theme.ui(12.5))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// The repo under the cursor, when heed has a setup to propose for it.
    private var setupUnderCursor: (RepoRecord, SetupProposal)? {
        guard let repo = model.reposUnderCursor.first,
              let record = model.repos.first(where: { $0.repo == repo && $0.location.isLocal }),
              let proposal = model.setupProposal(for: record)
        else { return nil }
        return (record, proposal)
    }

    private func header(count: Int) -> some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: 64)
            Group {
                Text("WORKTREE · \(count)").frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
                Text("SESSION").frame(width: 200, alignment: .leading)
                Text("CHANGES").frame(width: 120, alignment: .leading)
                Text("PR").frame(width: 110, alignment: .leading)
                Text("TOUCHED").frame(width: 72, alignment: .leading)
            }
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.fg3)
            FilterPill(view: .repos).padding(.leading, 8)
        }
        .padding(.trailing, 16)
        .frame(height: 34)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// A button for one of the view's commands, with its key: `Add or clone a`, `GitHub gR`.
private struct RepoButton: View {
    @Environment(AppModel.self) private var model
    let label: String
    let command: String
    var arguments: [String] = []
    var target: CommandTarget?
    var primary = false
    var scope = "repos"
    /// The cap, when it is another command's key (`⌘,` for the cleanup settings).
    var key: String?

    var body: some View {
        HStack(spacing: 7) {
            Text(label).font(Theme.ui(12.5, weight: primary ? .medium : .regular))
                .foregroundStyle(primary ? Theme.ink : Theme.fg)
            Text(key ?? model.keyText(for: command, in: scope)).font(Theme.mono(10.5))
                .foregroundStyle(primary ? Theme.ink.opacity(0.7) : Theme.fg3)
        }
        .fixedSize()
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(primary ? Theme.inverse : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(primary ? .clear : Theme.keyCapBorder))
        .clickRuns(CommandInvocation(name: command, arguments: arguments, target: target))
    }
}

/// One repo in the column: its tile, name and worktree count, and a line on how it stands.
private struct RepoColumnRow: View {
    @Environment(AppModel.self) private var model
    let record: RepoRecord
    let count: Int
    let summary: RepoSummary
    let picked: Bool
    let focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                OrgTile(org: record.repo.org, color: record.repo.color, size: 16)
                Text(record.repo.name).font(Theme.mono(12.5)).foregroundStyle(picked ? Theme.fg : Theme.fg2)
                    .lineLimit(1).truncationMode(.middle)
                Spacer()
                Text("\(count)").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            }
            SummaryText(parts: summary.parts).font(Theme.mono(11)).lineLimit(1).truncationMode(.tail)
                .padding(.leading, 24)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(picked ? Theme.bg3 : .clear)
        .overlay(alignment: .leading) {
            if picked, focused { Theme.block.frame(width: 2) }
        }
        .contentShape(Rectangle())
        .onTapGesture { model.clickRepo(record.repo) }
        .rightClickMenu { model.rightClickNamed() } _: { model.repoMenu(record.repo) }
    }
}

/// A summary's parts joined with ` · `, each in its tone.
private struct SummaryText: View {
    let parts: [RepoSummary.Part]

    var body: some View {
        parts.enumerated().reduce(Text("")) { line, item in
            let part = Text(item.element.text).foregroundColor(Self.color(item.element.tone))
            return item.offset == 0 ? part : Text("\(line)\(Text(" · ").foregroundColor(Theme.fg3))\(part)")
        }
    }

    static func color(_ tone: RepoSummary.Tone) -> Color {
        switch tone {
        case .plain: Theme.fg2
        case .good: Theme.done
        case .warning: Theme.block
        case .dim: Theme.fg3
        }
    }
}

/// The picked repo: where it is, how main stands against origin, its remote and hosts, get it merged and get it green
/// with Set up, and its actions.
private struct RepoCard: View {
    @Environment(AppModel.self) private var model
    let record: RepoRecord
    let summary: RepoSummary

    var body: some View {
        let repo = record.repo
        let onGitHub = repo.org != "local"
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                OrgTile(org: repo.org, color: repo.color, size: 22)
                Text(repo.name).font(Theme.mono(17, weight: .semibold)).lineLimit(1)
                Text(record.location.hostName.map { "@\($0):\(record.path)" } ?? Paths.tilde(record.path))
                    .font(Theme.mono(12)).foregroundStyle(Theme.fg3).lineLimit(1).truncationMode(.head)
                Spacer(minLength: 8)
                if onGitHub { RepoButton(label: "GitHub", command: "open.repo", target: .repo(repo)) }
                if record.location.isLocal {
                    RepoButton(label: "Finder", command: "repo.reveal", target: .repo(repo))
                }
            }
            HStack(spacing: 16) {
                Text(summary.mainLong ?? "main: not read yet").foregroundStyle(Theme.fg2)
                fact("remote", onGitHub ? repo.slug : "none")
                if !summary.hosts.isEmpty {
                    fact("also on", summary.hosts.map { "@\($0)" }.joined(separator: " "))
                }
                if let last = summary.lastWorked { fact("last worked", last) }
            }
            .font(Theme.ui(12.5))
            if onGitHub {
                let readiness = model.setupStatus(for: repo)
                HStack(spacing: 16) {
                    ReadinessText(line: readiness.merging)
                    ReadinessText(line: readiness.green)
                    RepoButton(
                        label: readiness.merging.state == .notSetUp || readiness.green.state == .notSetUp
                            ? "Set up" : "Set up again",
                        command: "repo.setup", target: .repo(repo)
                    )
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.horizontal, 16)
        .padding(.top, 4)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Theme.fg3)
            Text(value).font(Theme.mono(12)).foregroundStyle(Theme.fg)
        }
    }
}

/// Cleanup, up top: what it does under your settings, what it would do now, and the two buttons.
private struct CleanupBar: View {
    @Environment(AppModel.self) private var model
    let plan: SweepPlan

    var body: some View {
        let rule = model.config.cleanup
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                StateGlyph(state: rule.enabled && !plan.skips.isEmpty ? .blocked : .idle)
                Group {
                    if rule.enabled {
                        Text("Cleanup removes worktrees idle \(rule.idleDays) d")
                            + Text(rule.askBeforeSweep ? ", when you say so" : ", hourly").foregroundColor(Theme.fg3)
                    } else {
                        Text("Cleanup is off") + Text(": worktrees stay until you remove them")
                            .foregroundColor(Theme.fg3)
                    }
                }
                .font(Theme.ui(12.5))
                .lineLimit(1)
                Text("dirty or unpushed work is never removed").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .lineLimit(1)
                Spacer(minLength: 8)
                RepoButton(
                    label: "Cleanup settings",
                    command: "cleanup.rules",
                    key: model.keyText(for: "settings.open")
                )
                RepoButton(label: "Clean up worktrees", command: "cleanup.run")
            }
            if rule.enabled {
                VStack(alignment: .leading, spacing: 3) {
                    Text(plan.summary).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                    ForEach(plan.skips.prefix(3), id: \.worktree.id) { skip in
                        Text("kept \(skip.worktree.repo.name)/\(skip.worktree.branch ?? ""): \(skip.reason)")
                            .foregroundStyle(Theme.block)
                    }
                    ForEach(plan.removals.prefix(3), id: \.worktree.id) { removal in
                        Text(
                            "would remove \(removal.worktree.repo.name)/\(removal.worktree.branch ?? "") "
                                + "(\(removal.idleText))"
                        )
                        .foregroundStyle(Theme.fg2)
                    }
                    ForEach(plan.chatRemovals.prefix(3), id: \.id) { removal in
                        Text("would remove chat scratch folder \(removal.name) (closed \(removal.closedDays)d)")
                            .foregroundStyle(Theme.fg2)
                    }
                    ForEach(plan.expired.prefix(3)) { archive in
                        Text(
                            "would drop \(archive.repo.name) \(archive.name) "
                                + "(saved \(archive.archivedAt.formatted(.relative(presentation: .named))))"
                        )
                        .foregroundStyle(Theme.fg2)
                    }
                }
                .font(Theme.mono(11.5))
                .padding(.leading, 30)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
        .padding(.bottom, 12)
    }
}

/// For All: where a repo's worktrees start.
private struct GroupHeader: View {
    let repo: Repo

    var body: some View {
        HStack(spacing: 6) {
            OrgTile(org: repo.org, color: repo.color, size: 12)
            Text(repo.name).font(Theme.mono(11.5, weight: .semibold)).foregroundStyle(Theme.fg2)
            Spacer()
        }
        .padding(.leading, 64)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }
}

private struct WorktreeRow: View {
    let worktree: Worktree
    let session: Session?
    let number: Int
    let isCursor: Bool
    let isSelected: Bool
    let roots: [String]
    /// The view's filter, marked where it matches.
    let query: String
    /// The state of the session's PR, by the PR number.
    let pilot: PilotStatus?
    var registration: WorktreeRegistration = .registered
    var hostColor: String?
    var age: String?
    /// ↩'s key: it imports a worktree with no session.
    var openKey = "↩"

    var body: some View {
        HStack(spacing: 0) {
            Text("\(number)")
                .font(Theme.mono(11, weight: isCursor ? .bold : .regular))
                .foregroundStyle(isCursor ? Theme.fg : Theme.fg3)
                .frame(width: 30, alignment: .trailing)
            Group {
                if let session {
                    StateGlyph(state: session.state.state, guessed: session.state.source == .guessed)
                } else {
                    StateGlyph(state: .idle)
                }
            }
            .frame(width: 34)
            // The branch (with its host, when it is on one), and the worktree's path small below it.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 8) {
                    Highlighted(text: worktree.branch ?? "detached \(worktree.head)", query: query)
                        .font(Theme.mono(12))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !worktree.location.isLocal { HostChip(location: worktree.location, color: hostColor) }
                }
                WorktreePath(path: worktree.path, roots: roots, query: query)
            }
            .frame(minWidth: 180, maxWidth: .infinity, alignment: .leading)
            sessionCell.frame(width: 200, alignment: .leading)
            Group {
                if registration == .stale || registration == .missing {
                    RegistrationChip(registration: registration)
                } else if let status = worktree.status {
                    WorktreeStatusLine(status: status, showUpstream: false)
                } else {
                    Text("…").foregroundStyle(Theme.fg3)
                }
            }
            .frame(width: 120, alignment: .leading)
            HStack(spacing: 6) {
                Text(session?.trackedPRs.first { $0.repo == worktree.repo }.map { "#\(String($0.number))" } ?? "no PR")
                    .font(Theme.mono(12))
                    .foregroundStyle(session?.trackedPRs.isEmpty == false ? Theme.fg : Theme.fg3)
                if let pilot, pilot != .unwatched { PilotMark(status: pilot, compact: true) }
            }
            .frame(width: 110, alignment: .leading)
            Text(age ?? "—").font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).frame(width: 72, alignment: .leading)
        }
        .padding(.trailing, 16)
        .frame(height: 48)
        .background(isSelected ? Theme.block.opacity(0.18) : isCursor ? Theme.bg3 : .clear)
        .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
    }

    /// `claude · blocked`, or what ↩ does for one with no session: import it.
    @ViewBuilder private var sessionCell: some View {
        if let session {
            Text("\(session.agent) · \(session.state.state.rawValue)").font(Theme.ui(12.5))
                .foregroundStyle(Theme.fg2).lineLimit(1)
        } else {
            HStack(spacing: 6) {
                Text(registration == .discovered ? "found on the host" : "no session").font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg3)
                KeyCap(text: openKey)
                Text("import").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            }
        }
    }
}

/// One readiness line on a repo: not set up in the dim colour, off plain, ok in green, a problem in amber.
struct ReadinessText: View {
    let line: RepoSetupStatus.Line

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(line.text).font(Theme.ui(12)).foregroundStyle(line.state == .notSetUp ? Theme.fg3 : color)
                .lineLimit(1)
        }
    }

    private var color: Color {
        switch line.state {
        case .notSetUp: Theme.fg3
        case .off: Theme.fg2
        case .ok: Theme.done
        case .warning: Theme.block
        }
    }
}

/// A repo's detected setup, waiting for approval: what it would run in each new worktree, and the keys.
private struct SetupBanner: View {
    @Environment(AppModel.self) private var model
    let record: RepoRecord
    let proposal: SetupProposal

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            StateGlyph(state: .asking)
            VStack(alignment: .leading, spacing: 4) {
                Text("Set up new \(record.repo.name) worktrees?").font(Theme.ui(12.5))
                Text("detected: " + proposal.lines.joined(separator: " · "))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            }
            Spacer()
            KeyCap(text: model.keyText(for: "setup.review", in: "repos"))
            Text("approve, edit or never").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
        .padding(.horizontal, 16)
        .padding(.top, 12)
    }
}
