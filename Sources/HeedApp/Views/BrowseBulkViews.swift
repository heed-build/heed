import HeedCore
import SwiftUI

// Browse with two items picked or more: the reader becomes the bulk panel (wide), or a sheet over the list (half and
// third widths). Everything it says comes from local reads (`BrowseGrouping`); every GitHub write goes through a
// confirm step that lists what will change (`BrowseBulkForm`).

struct BrowseBulkPanel: View {
    @Environment(AppModel.self) private var model
    /// A sheet over the list (half and third widths) rather than the reader's pane.
    var sheet = false

    var body: some View {
        let items = model.browseBulkItems
        let reads = model.browse.reads
        let group = BrowseGrouping.suggest(items, reads: reads)
        Group {
            if sheet {
                compact(items, reads: reads, group: group)
            } else {
                wide(items, reads: reads, group: group)
            }
        }
        .shotRegion(.browseBulk)
    }

    // MARK: Wide

    private func wide(_ items: [BrowseItem], reads: BrowseReads, group: BrowseGroup?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Scrolling {
                VStack(alignment: .leading, spacing: 18) {
                    header(items, reads: reads)
                    titles(items, reads: reads)
                    if let form = model.browse.bulk {
                        BrowseBulkStep(form: form)
                    } else {
                        note(items, group: group)
                        whatNow(items)
                        onGitHub(items, reads: reads)
                    }
                }
                .padding(.horizontal, 28).padding(.vertical, 22)
                .frame(maxWidth: 900, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            Text("Agent actions work on one item at a time. Select one to use them.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                .padding(.horizontal, 28).padding(.vertical, 14)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func header(_ items: [BrowseItem], reads: BrowseReads) -> some View {
        let repos = items.reduce(into: [Repo]()) { if !$0.contains($1.repo) { $0.append($1.repo) } }
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(items.count) selected").font(Theme.ui(18, weight: .semibold)).fixedSize()
                ForEach(repos, id: \.slug) { RepoChip(repo: $0).fixedSize() }
                Spacer(minLength: 0)
                clear
            }
            Text(BrowseGrouping.summary(items, reads: reads)).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
        }
    }

    private var clear: some View {
        HStack(spacing: 6) {
            KeyCap(text: "esc")
            Text("clear").font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
        }
        .clickRuns(CommandInvocation(name: "browse.run.close"))
    }

    private func titles(_ items: [BrowseItem], reads: BrowseReads) -> some View {
        VStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: 10) {
                    if let kind = BrowseGrouping.kind(of: item, read: reads[item.id]) {
                        Image(systemName: kind.symbol).font(.system(size: 12.5)).foregroundStyle(kind.tint)
                            .frame(width: 18)
                    } else {
                        Image(systemName: "circle.dotted").font(.system(size: 12.5)).foregroundStyle(Theme.fg3)
                            .frame(width: 18)
                    }
                    Text(item.title.display).font(Theme.ui(13.5)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(verbatim: "\(item.repo.name) #\(item.number)").font(Theme.mono(11.5))
                        .foregroundStyle(Theme.fg3).lineLimit(1)
                }
                .padding(.horizontal, 14).padding(.vertical, 8)
                if item.id != items.last?.id { Theme.line.opacity(0.6).frame(height: 1) }
            }
        }
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    @ViewBuilder private func note(_ items: [BrowseItem], group: BrowseGroup?) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkle").font(.system(size: 13)).foregroundStyle(Theme.busy).padding(.top, 2)
            Text(group.map { BrowseGrouping.note($0, items: items) }
                ?? "heed found nothing that ties these together. One session can still take them all.")
                .font(Theme.ui(13.5)).fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }

    private func whatNow(_ items: [BrowseItem]) -> some View {
        let choices = BrowseBulk.sessionChoices(for: items)
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("What now?")
            card(
                "arrow.triangle.branch", choices.one.title, choices.one.detail,
                key: model.keyText(for: "browse.bulk.session", in: "browsebulk"), primary: true,
                command: "browse.bulk.session"
            )
            card(
                "square.on.square", choices.perRepo.title, choices.perRepo.detail,
                key: model.keyText(for: "browse.bulk.each", in: "browsebulk"), dimmed: !choices.perRepo.available,
                command: "browse.bulk.each"
            )
            card(
                "scope", "A goal from all \(items.count)",
                "heed plans it with you first, and each item goes on the goal.",
                key: model.keyText(for: "browse.bulk.goal", in: "browsebulk"), command: "browse.bulk.goal"
            )
        }
    }

    private func card(
        _ symbol: String, _ title: String, _ detail: String, key: String, primary: Bool = false, dimmed: Bool = false,
        command: String
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(primary ? Theme.busy : Theme.fg2)
                .frame(width: 24, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.ui(14.5, weight: .semibold))
                Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
            }
            Spacer(minLength: 8)
            KeyCap(text: key)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Theme.busy.opacity(0.07) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(
            primary ? Theme.busy : Theme.line,
            lineWidth: primary ? 1.5 : 1
        ))
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: command))
    }

    private func onGitHub(_ items: [BrowseItem], reads: BrowseReads) -> some View {
        let unread = items.count(where: { reads[$0.id] == nil })
        return VStack(alignment: .leading, spacing: 8) {
            sectionTitle("On GitHub")
            FlowLayout(spacing: 8) {
                chip("Label", "browse.bulk.label")
                chip("Assign to me", "browse.bulk.assign")
                chip("Comment on all", "browse.bulk.comment")
                chip("Close as…", "browse.bulk.close")
                if unread > 0 { chip(
                    "Read the \(unread) unread",
                    "browse.read",
                    key: model.keyText(for: "browse.read", in: "browse")
                ) }
            }
            Text("Each asks first and lists exactly what it will change.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
        }
    }

    private func chip(_ title: String, _ command: String, key: String? = nil) -> some View {
        HStack(spacing: 8) {
            Text(title).font(Theme.ui(13))
            KeyCap(text: key ?? model.keyText(for: command, in: "browsebulk"))
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.keyCapBorder))
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: command))
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.mono(10.5, weight: .semibold)).tracking(1).foregroundStyle(Theme.fg3)
    }

    // MARK: Sheet (half and third widths)

    private func compact(_ items: [BrowseItem], reads: BrowseReads, group: BrowseGroup?) -> some View {
        let unread = items.count(where: { reads[$0.id] == nil })
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(items.count) selected").font(Theme.ui(17, weight: .semibold)).fixedSize()
                Text(BrowseGrouping.summary(items, reads: reads)).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    .lineLimit(1)
                Spacer(minLength: 0)
                clear
            }
            if let form = model.browse.bulk {
                BrowseBulkStep(form: form)
            } else {
                if let group {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "sparkle").font(.system(size: 12)).foregroundStyle(Theme.busy)
                            .padding(.top, 2)
                        Text(BrowseGrouping.note(group, items: items)).font(Theme.ui(13.5))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                let choices = BrowseBulk.sessionChoices(for: items)
                button(choices.one.title, "browse.bulk.session", primary: true)
                HStack(spacing: 10) {
                    button("One per repo", "browse.bulk.each", dimmed: !choices.perRepo.available)
                    button("Goal", "browse.bulk.goal")
                    ShotSafeMenu {
                        Button("Label…") { model.perform(CommandInvocation(name: "browse.bulk.label")) }
                        Button("Assign to me") { model.perform(CommandInvocation(name: "browse.bulk.assign")) }
                        Button("Comment on all…") { model.perform(CommandInvocation(name: "browse.bulk.comment")) }
                        Button("Close as…") { model.perform(CommandInvocation(name: "browse.bulk.close")) }
                        if unread > 0 {
                            Button("Read the \(unread) unread") { model.perform(CommandInvocation(name: "browse.read"))
                            }
                        }
                    } label: {
                        Text("···").font(Theme.ui(15, weight: .semibold)).frame(width: 44, height: 40)
                            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.keyCapBorder))
                    }
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.bg2)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func button(_ title: String, _ command: String, primary: Bool = false, dimmed: Bool = false) -> some View {
        HStack(spacing: 10) {
            Text(title).font(Theme.ui(15, weight: .semibold)).lineLimit(1).minimumScaleFactor(0.7)
            Text(model.keyText(for: command, in: "browsebulk")).font(Theme.mono(11))
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(primary ? Theme.ink : Theme.keyCap))
                .foregroundStyle(primary ? Color.white : Theme.fg2)
        }
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .frame(maxWidth: .infinity, minHeight: 40)
        .background(RoundedRectangle(cornerRadius: 8).fill(primary ? Color.white : .clear))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(primary ? .clear : Theme.keyCapBorder))
        .opacity(dimmed ? 0.5 : 1)
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: command))
    }
}

/// The step a GitHub bulk action is on: what to type, how to close, the confirm step that lists every write, the
/// run and the per-item report.
struct BrowseBulkStep: View {
    let form: BrowseBulkForm

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            switch form.stage {
            case let .typing(kind):
                title(kind == .label ? "Which labels?" : "What should the comment say?")
                HStack {
                    CaretText(input: EditableText(form.text)).font(Theme.ui(14))
                    Spacer()
                }
                .padding(.horizontal, 12).padding(.vertical, 9)
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.busy))
                Text(kind == .label ? "Separate labels with commas. ↩ shows what will change. ⎋ cancels."
                    : "↩ shows what will change. ⎋ cancels.")
                    .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                problem
            case .closeReason:
                title("Close as…")
                choice("Completed", "1", on: form.reason == .completed)
                choice("Not planned", "2", on: form.reason == .notPlanned)
                Text("↩ shows what will change. ⎋ cancels.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            case let .confirm(plan):
                title(plan.headline)
                lines(plan.lines)
                if let body = plan.commentBody {
                    Text(body).font(Theme.ui(13)).padding(10).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg))
                }
                problem
                HStack(spacing: 14) {
                    HStack(spacing: 6) { KeyCap(text: "↩"); Text("write it").font(Theme.ui(13, weight: .semibold)) }
                        .clickRuns(nil)
                    HStack(spacing: 6) {
                        KeyCap(text: "esc"); Text("cancel").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    }
                }
            case .confirmEach:
                title("Start \(form.sessionCount) sessions, one per repo?")
                Text("That is more than \(BrowseBulk.eachCap). Start work opens for each, one after the other.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                HStack(spacing: 14) {
                    HStack(spacing: 6) { KeyCap(text: "↩"); Text("start them").font(Theme.ui(13, weight: .semibold)) }
                    HStack(spacing: 6) {
                        KeyCap(text: "esc"); Text("cancel").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    }
                }
            case .running:
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Writing to GitHub, one item at a time…").font(Theme.ui(13.5))
                }
            case let .report(report):
                HStack(spacing: 8) {
                    Image(systemName: report.clean ? "checkmark.circle" : "exclamationmark.triangle")
                        .foregroundStyle(report.clean ? Theme.done : Theme.block)
                    Text(report.summary).font(Theme.ui(14, weight: .semibold))
                }
                lines(report.lines)
                HStack(spacing: 6) { KeyCap(text: "↩"); Text("done").font(Theme.ui(13)).foregroundStyle(Theme.fg2) }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.busy.opacity(0.6)))
    }

    private func title(_ text: String) -> some View { Text(text).font(Theme.ui(14.5, weight: .semibold)) }

    @ViewBuilder private var problem: some View {
        if let text = form.problem { Text(text).font(Theme.ui(12.5)).foregroundStyle(Theme.block) }
    }

    private func lines(_ lines: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line).font(Theme.mono(11.5)).foregroundStyle(line.contains("failed") ? Theme.err : Theme.fg2)
                    .lineLimit(1).truncationMode(.tail)
            }
        }
    }

    private func choice(_ text: String, _ key: String, on: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: on ? "largecircle.fill.circle" : "circle").foregroundStyle(on ? Theme.busy : Theme.fg3)
            Text(text).font(Theme.ui(13.5))
            Spacer()
            KeyCap(text: key)
        }
    }
}
