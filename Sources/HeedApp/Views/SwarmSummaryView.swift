import HeedCore
import SwiftUI

/// A done swarm's end-of-build summary (deck p15): the outcome with its numbers, the PRs in merge order, who did what
/// when, what the agents ran into, every question with who answered it and how long it took, the decisions and the
/// follow-ups. Written by the lead over heed's record; also in History's ledger. `F` starts a follow-up swarm.
struct SwarmSummaryView: View {
    @Environment(AppModel.self) private var model
    let board: SwarmBoard
    let summary: SwarmSummary

    var body: some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 14) {
                SummaryHeader(summary: summary)
                if !summary.prs.isEmpty {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(summary.prs, id: \.task) { pr in SummaryPR(pr: pr) }
                    }
                }
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 14) {
                        Panel(title: "Who did what, when", note: "working · waiting · stuck") {
                            SummaryTimeline(summary: summary)
                        }
                        Panel(title: "What they ran into", note: "\(summary.episodes.count)") {
                            if summary.episodes.isEmpty { Quiet("Nothing: no stuck stretches, long waits or moves.") }
                            ForEach(Array(summary.episodes.enumerated()), id: \.offset) { _, episode in
                                SummaryEpisode(episode: episode)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                    VStack(alignment: .leading, spacing: 14) {
                        Panel(title: "Questions · \(summary.questions.count)", note: summary.answeredLine) {
                            SummaryQuestions(summary: summary)
                        }
                        HStack(alignment: .top, spacing: 14) {
                            Panel(title: "Decisions", note: "") {
                                if summary.decisions.isEmpty { Quiet("None recorded.") }
                                ForEach(summary.decisions, id: \.self) { line in
                                    Text("· " + line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                            }
                            Panel(title: "Follow-ups", note: "") {
                                if summary.followUps.isEmpty { Quiet("Nothing left over.") }
                                ForEach(summary.followUps, id: \.self) { line in
                                    Text("· " + line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                KeyHint("swarm.followup", scope: "goalagents", label: "start a follow-up swarm")
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                Text(summary.byLead ? "Written by the lead over heed's record of the run: its plan, the steering log "
                    + "and every agent's activity. In History's ledger too."
                    : "Assembled by heed from the run's record; the lead adds its outcome, decisions and follow-ups "
                    + "with heed swarm summary.")
                    .font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
            }
            .padding(20)
        }
    }
}

private struct SummaryHeader: View {
    let summary: SwarmSummary

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text("done").font(Theme.mono(10.5)).foregroundStyle(Theme.done)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.done.opacity(0.6)))
                    Text(summary.title).font(Theme.ui(16, weight: .semibold)).lineLimit(1)
                }
                Text(summary.outcome).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Tile(value: SwarmSummary.duration(summary.elapsed), label: "elapsed")
            Tile(value: SwarmSummary.duration(summary.agentTime), label: "agent time")
            Tile(value: "\(summary.agents)", label: "agents")
            Tile(value: "\(summary.versions)", label: "plan versions")
            if summary.dollars > 0 { Tile(value: AgentUsage.dollars(summary.dollars), label: "spent") }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.done.opacity(0.4)))
    }

    private struct Tile: View {
        let value: String
        let label: String

        var body: some View {
            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(Theme.mono(16, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(label).font(Theme.ui(11)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            .frame(minWidth: 86, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
        }
    }
}

private struct SummaryPR: View {
    let pr: SwarmSummary.PR

    var body: some View {
        let color = pr.state == "merged" || pr.state == "CI passing" ? Theme.done : Theme.busy
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(pr.order). " + (pr.pr.map { "#\($0)" } ?? "no PR")).font(Theme.mono(11, weight: .semibold))
                Spacer(minLength: 6)
                Text(pr.state).font(Theme.mono(10)).foregroundStyle(color)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6)))
            }
            Text("\(pr.number) \(pr.title)").font(Theme.ui(12.5, weight: .medium)).lineLimit(1)
            Text(pr.stackedOn.map { "stacked on \($0)" } ?? "from the default branch")
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
    }
}

/// A lane per agent (the lead, then each task), its stretches drawn on one time axis: working blue, waiting violet,
/// stuck amber.
private struct SummaryTimeline: View {
    let summary: SwarmSummary

    var body: some View {
        let total = max(summary.elapsed, 60)
        VStack(alignment: .leading, spacing: 6) {
            ForEach(summary.lanes, id: \.name) { lane in
                HStack(spacing: 10) {
                    Text(lane.name).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).frame(
                        width: 44,
                        alignment: .leading
                    )
                    Canvas { context, size in
                        for span in lane.spans {
                            let start = size.width * span.start / total
                            let width = max(size.width * (span.end - span.start) / total, 2)
                            let inset: CGFloat = span.kind == .working ? 0 : 2
                            let rect = CGRect(x: start, y: inset, width: width, height: size.height - inset * 2)
                            context.fill(Path(roundedRect: rect, cornerRadius: 3), with: .color(color(span.kind)))
                        }
                    }
                    .frame(height: 12)
                }
            }
            HStack {
                Text("start").font(Theme.mono(9.5)).foregroundStyle(Theme.fg3).padding(.leading, 54)
                Spacer()
                Text("+\(SwarmSummary.duration(summary.elapsed))").font(Theme.mono(9.5)).foregroundStyle(Theme.fg3)
            }
        }
    }

    private func color(_ kind: SwarmSummary.Span.Kind) -> Color {
        switch kind {
        case .working: Theme.busy
        case .waiting: Theme.ask
        case .stuck: Theme.block
        }
    }
}

private struct SummaryEpisode: View {
    let episode: SwarmSummary.Episode

    var body: some View {
        let color: Color = switch episode.kind {
        case .stuck: Theme.block
        case .waited: Theme.ask
        case .conflict: Theme.err
        }
        HStack(alignment: .top, spacing: 10) {
            Text(episode.kind.rawValue).font(Theme.mono(10)).foregroundStyle(color)
                .padding(.horizontal, 5).padding(.vertical, 1)
                .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(color.opacity(0.6)))
                .frame(width: 70, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(episode.title).font(Theme.ui(12.5, weight: .medium)).fixedSize(horizontal: false, vertical: true)
                if !episode.detail.isEmpty {
                    Text(episode.detail).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 6)
            if episode.minutes > 0 {
                Text("\(episode.minutes) m").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
        }
    }
}

private struct SummaryQuestions: View {
    let summary: SwarmSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("QUESTION").frame(maxWidth: .infinity, alignment: .leading)
                Text("FROM").frame(width: 60, alignment: .leading)
                Text("ANSWERED BY").frame(width: 84, alignment: .leading)
                Text("TOOK").frame(width: 44, alignment: .trailing)
            }
            .font(Theme.mono(9.5)).foregroundStyle(Theme.fg3)
            ForEach(Array(summary.questions.enumerated()), id: \.offset) { _, question in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(question.text).font(Theme.ui(12)).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(question.from).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 60, alignment: .leading)
                    Text(question.answeredBy ?? "open").font(Theme.mono(10.5))
                        .foregroundStyle(color(question.answeredBy))
                        .frame(width: 84, alignment: .leading)
                    Text(question.seconds.map(Self.took) ?? "–").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                        .frame(width: 44, alignment: .trailing)
                }
            }
        }
    }

    static func took(_ seconds: TimeInterval) -> String {
        seconds < 60 ? "\(Int(seconds)) s" : SwarmSummary.duration(seconds)
    }

    private func color(_ who: String?) -> Color {
        switch who {
        case "you": Theme.fg
        case "controller": Theme.block
        case "peer", "lead": Theme.done
        default: Theme.err
        }
    }
}
