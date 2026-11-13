import HeedCore
import SwiftUI

/// A session's trace (`t` on a session, `:trace`, ↩ on a span in Insights › OpenTelemetry): its last turns from its
/// agent's own OpenTelemetry, each a line of what it did, end to end; five numbers; the span under the cursor said in
/// full; and what heed noticed against the repo's other sessions. j k move through turns, h l through spans.
struct TraceView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.telemetry
        VStack(spacing: 0) {
            crumb(browser.trace)
            if let trace = browser.trace, !trace.isEmpty {
                ListScroll {
                    VStack(alignment: .leading, spacing: 18) {
                        Tiles(trace: trace).shotRegion(.traceTiles)
                        Lanes(trace: trace, turn: browser.traceTurn, segment: browser.traceSegment)
                            .shotRegion(.traceTurns)
                        HStack(alignment: .top, spacing: 18) {
                            Selected(trace: trace, turn: browser.traceTurn, segment: browser.traceSegment)
                            Noticed(lines: trace.noticed)
                        }
                        .fixedSize(horizontal: false, vertical: true)
                        .shotRegion(.traceDetail)
                    }
                    .padding(.horizontal, 30)
                    .padding(.vertical, 22)
                }
            } else {
                Text(empty(browser))
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 620)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func empty(_ browser: TelemetryBrowser) -> String {
        guard browser.trace != nil else { return "Reading the trace…" }
        return "No turns from this session's agent yet. heed starts claude and codex with their OpenTelemetry "
            + "pointed at it (Settings › History); a session started before heed listened sends it once reopened."
    }

    private func crumb(_ trace: SessionTrace?) -> some View {
        HStack(spacing: 10) {
            Text("Session").foregroundStyle(Theme.fg2).font(Theme.ui(14))
            Text("›").foregroundStyle(Theme.fg3)
            Text(trace?.title ?? "").foregroundStyle(Theme.fg).font(Theme.ui(14, weight: .semibold)).lineLimit(1)
            Text("›").foregroundStyle(Theme.fg3)
            Text("Trace").foregroundStyle(Theme.fg).font(Theme.ui(14, weight: .semibold))
            if let trace {
                Text(
                    "\(trace.agent) · last \(trace.turns.count) turn\(trace.turns.count == 1 ? "" : "s") · from its "
                        + "OpenTelemetry spans"
                )
                .font(Theme.mono(12)).foregroundStyle(Theme.fg3).lineLimit(1)
                .padding(.leading, 14)
            }
            Spacer()
            KeyCap(text: model.keyText(for: "session.trace", in: "trace"))
                .clickRuns(CommandInvocation(name: "session.trace"))
        }
        .padding(.horizontal, 30)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct Tiles: View {
    let trace: SessionTrace

    var body: some View {
        HStack(spacing: 14) {
            tile(TelemetryWords.duration(trace.total), "\(trace.turns.count) turns", Theme.fg)
            tile(
                TelemetryWords.duration(trace.waited),
                "waiting for your OK",
                trace.waited > 0 ? Theme.block : Theme.fg
            )
            tile(TelemetryWords.duration(trace.bash), "in bash", Theme.fg)
            let cached = trace.tokens.allInput > 0
                ? " · \(Int((Double(trace.tokens.cacheRead) / Double(trace.tokens.allInput) * 100).rounded()))% cached"
                : ""
            tile(TelemetryWords.count(Double(trace.tokens.allInput + trace.tokens.output)), "tokens" + cached, Theme.fg)
            tile(
                trace.cost.map(AgentUsage.dollars) ?? "–",
                trace.cost == nil ? "no cost reported" : "reported",
                Theme.fg
            )
        }
    }

    private func tile(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(value).font(Theme.ui(20, weight: .semibold)).foregroundStyle(color).lineLimit(1)
            Text(label).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }
}

/// Each turn a line: its segments where they ran, the time between turns taken out.
private struct Lanes: View {
    @Environment(AppModel.self) private var model
    let trace: SessionTrace
    let turn: Int
    let segment: Int

    var body: some View {
        let total = max(trace.total, 0.001)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 0) {
                Color.clear.frame(width: 300, height: 16)
                GeometryReader { geometry in
                    ForEach(ticks(total), id: \.self) { tick in
                        Text(TelemetryWords.duration(tick))
                            .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                            .fixedSize()
                            .offset(x: min(geometry.size.width - 40, geometry.size.width * tick / total))
                    }
                }
                .frame(height: 16)
            }
            .padding(.bottom, 8)
            ForEach(Array(trace.turns.enumerated()), id: \.element.id) { index, line in
                HStack(spacing: 0) {
                    Text(line.title)
                        .font(Theme.ui(13.5, weight: index == turn ? .semibold : .regular))
                        .foregroundStyle(index == turn ? Theme.fg : Theme.fg2)
                        .lineLimit(1)
                        .frame(width: 300, alignment: .leading)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        ZStack(alignment: .leading) {
                            ForEach(Array(line.segments.enumerated()), id: \.element.id) { position, part in
                                let selected = index == turn && position == segment
                                let barWidth = max(4, width * part.span.duration / total - 1)
                                RoundedRectangle(cornerRadius: 3)
                                    .fill(TelemetryColors.lane(part.lane)
                                        .opacity(part.span.status == .error ? 0.5 : 0.9))
                                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                                        part.span.status == .error ? Theme.err : selected ? Theme.fg : .clear,
                                        lineWidth: selected ? 1.5 : 1
                                    ))
                                    .overlay(alignment: .leading) {
                                        if barWidth > 110 {
                                            Text(label(part)).font(Theme.mono(11)).foregroundStyle(Theme.ink)
                                                .lineLimit(1).padding(.leading, 7)
                                        }
                                    }
                                    .frame(width: barWidth, height: 26)
                                    .offset(x: width * part.offset / total)
                                    .onTapGesture { model.telemetry.setTraceCursor(turn: index, segment: position) }
                            }
                        }
                    }
                    .frame(height: 26)
                }
                .padding(.vertical, 18)
                .overlay(alignment: .bottom) { Theme.line.opacity(0.6).frame(height: 1) }
            }
            HStack(spacing: 18) {
                ForEach(["model", "read", "edit", "bash", "waiting"], id: \.self) { lane in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 1).fill(TelemetryColors.lane(lane)).frame(width: 7, height: 7)
                        Text(lane == "waiting" ? "waiting for you" : lane).font(Theme.ui(12.5))
                            .foregroundStyle(TelemetryColors.lane(lane))
                    }
                }
            }
            .padding(.top, 14)
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }

    private func label(_ part: SessionTrace.Segment) -> String {
        switch part.lane {
        case "waiting": "waiting for your OK"
        case "model": "model"
        default: "\(part.span.name == "read/grep" ? "read" : part.span.name): \(part.span.detail)"
        }
    }

    /// Six ticks, rounded to tidy seconds.
    private func ticks(_ total: TimeInterval) -> [TimeInterval] {
        let steps: [TimeInterval] = [1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 1800, 3600]
        let step = steps.first { total / $0 <= 6 } ?? 3600
        return stride(from: 0, through: total, by: step).map(\.self)
    }
}

private struct Selected: View {
    let trace: SessionTrace
    let turn: Int
    let segment: Int

    var body: some View {
        let picked = trace.segment(turn: turn, index: segment)
        let described = trace.describe(turn: turn, index: segment)
        VStack(alignment: .leading, spacing: 10) {
            Text("SELECTED · \((picked.map(lane) ?? "").uppercased())")
                .font(Theme.ui(11, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.fg3)
            if let described {
                Text(described.head).font(Theme.mono(13)).foregroundStyle(Theme.fg).lineLimit(2)
                if !described.detail.isEmpty {
                    Text(described.detail).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                }
            } else {
                Text("This turn sent no spans of its own.").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }

    private func lane(_ part: SessionTrace.Segment) -> String {
        switch part.lane {
        case "waiting": "waiting for your OK"
        case "model": "model"
        default: "\(part.span.name): \(part.span.detail)"
        }
    }
}

private struct Noticed: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("WHAT HEED NOTICED").font(Theme.ui(11, weight: .semibold)).tracking(0.8).foregroundStyle(Theme.fg3)
            if lines.isEmpty {
                Text("Nothing stood out.").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            }
            ForEach(lines, id: \.self) { line in
                Text(line).font(Theme.ui(13)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }
}
