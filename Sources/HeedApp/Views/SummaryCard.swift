import HeedCore
import SwiftUI

/// The reader's catch-up card: what is new since you last looked (or the whole thread), and always its state as a
/// chip with a line: summarizing… (who, since when), up to date (for how much), stale · N new (↻ rewrites it), failed
/// (the runner's reason, `:log`), off (Turn on opens the page that turns it on).
struct SummaryCard: View {
    @Environment(AppModel.self) private var model
    let item: AttentionItem

    var body: some View {
        let state = model.summaryCard(item)
        let summary = state.summary
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionHeader(title: title(state), tint: Theme.busy)
                Spacer(minLength: 12)
                if let summary, let written = written(summary) {
                    Text(written).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            if let summary {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(summary.lines.enumerated()), id: \.offset) { _, line in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text("•").foregroundStyle(Theme.fg3)
                            Text(line).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(Theme.ui(13))
                        .foregroundStyle(dimmed(state) ? Theme.fg2 : Theme.fg)
                        .textSelection(.enabled)
                    }
                }
            }
            status(state)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.busy.opacity(0.06)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.busy.opacity(0.3)))
        .shotRegion(.attentionSummary)
    }

    /// `Since you last looked · 3 comments`, `The thread · 6 comments`, `Summary` while there is none.
    private func title(_ state: SummaryCardState) -> String {
        guard let summary = state.summary else { return "Summary" }
        let count = "\(summary.count) comment\(summary.count == 1 ? "" : "s")"
        return summary.since == nil ? "The thread · \(count)" : "Since you last looked · \(count)"
    }

    /// `written 2 min ago by claude haiku`.
    private func written(_ summary: CatchUpSummary) -> String? {
        "written \(Ages.long(summary.writtenAt))" + (summary.writer.map { " by \($0)" } ?? "")
    }

    private func dimmed(_ state: SummaryCardState) -> Bool {
        switch state {
        case .upToDate: false
        default: true
        }
    }

    /// The chip, its line, and what you can do about it.
    private func status(_ state: SummaryCardState) -> some View {
        HStack(spacing: 8) {
            Text(state.chip).font(Theme.ui(11.5)).foregroundStyle(tint(state))
                .padding(.horizontal, 8).padding(.vertical, 2)
                .background(Capsule().fill(tint(state).opacity(0.14)))
                .fixedSize()
            Text(state.line(now: Clock.now)).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(2)
            switch state {
            case .upToDate, .stale:
                action("↻ rewrite", CommandInvocation(name: "attention.summarize"), key: "attention.summarize")
            case .failed:
                action("↻ again", CommandInvocation(name: "attention.summarize"), key: "attention.summarize")
                action(":log", CommandInvocation(name: "view.log"))
            case let .off(reason):
                let words = reason.command.split(separator: " ").map(String.init)
                action("Turn on", CommandInvocation(name: words[0], arguments: Array(words.dropFirst())))
            case .summarizing:
                EmptyView()
            }
            Spacer(minLength: 0)
        }
    }

    private func action(_ label: String, _ invocation: CommandInvocation, key command: String? = nil) -> some View {
        HStack(spacing: 5) {
            Text(label).font(Theme.ui(12)).foregroundStyle(Theme.fg)
            if let command {
                Text(model.keyText(for: command, in: "attention")).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
        .fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 2)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.keyCapBorder))
        .clickRuns(invocation)
    }

    private func tint(_ state: SummaryCardState) -> Color {
        switch state {
        case .summarizing: Theme.busy
        case .upToDate: Theme.done
        case .stale: Theme.block
        case .failed: Theme.err
        case .off: Theme.fg3
        }
    }
}
