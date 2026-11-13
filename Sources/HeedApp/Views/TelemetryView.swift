import HeedCore
import SwiftUI

/// Insights › OpenTelemetry (`T`, `:telemetry`): the agents' own telemetry as an observability view. The filter bar
/// (range, agent, repo, model, kind, the span query typed with `/`, live), six numbers with their line across the
/// range, latency by tool, each agent's state across the range, cost and tokens by model, the spans newest first (a
/// wait for your OK going on now on top), and the selected span's trace as a waterfall. Nothing here is estimated:
/// what the agents did not send is not drawn.
struct TelemetryView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.telemetry
        let board = browser.board
        VStack(spacing: 0) {
            if browser.showsBanner, let export = browser.export {
                ProxyBanner(export: export, lines: browser.forwardingLines()).shotRegion(.telemetryBanner)
            }
            FilterBar(browser: browser, query: model.filter(for: .telemetry))
            if board.isEmpty, board.rows.isEmpty {
                Text(empty(browser))
                    .font(Theme.ui(12.5))
                    .foregroundStyle(Theme.fg3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 640)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(spacing: 14) {
                        ForEach(board.tiles) { TileView(tile: $0) }
                    }
                    .shotRegion(.telemetryTiles)
                    HStack(alignment: .top, spacing: 14) {
                        LatencyPanel(latency: board.latency)
                        StatePanel(board: board, range: browser.filter.range)
                        CostPanel(board: board, range: browser.filter.range)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .shotRegion(.telemetryPanels)
                    SpanTable(browser: browser).shotRegion(.telemetrySpans)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 16)
            }
        }
    }

    private func empty(_ browser: TelemetryBrowser) -> String {
        switch browser.receiver {
        case .off:
            return "The receiver is off ([telemetry] enabled = false). Turn it on in Settings › History to see the "
                + "agents' own spans, latency, waits and cost here."
        case let .failed(reason):
            return "heed could not listen for telemetry: \(reason). Another collector may hold the port; set "
                + "[telemetry] port to another."
        case .starting, .listening:
            if !browser.filter.query.isEmpty || browser.filter.agent != nil || browser.filter.repo != nil {
                return "No span matches."
            }
            return "Nothing received in the last \(TelemetryFilter.label(browser.filter.range)) yet. Sessions heed "
                + "starts with claude or codex send their own OpenTelemetry here, to 127.0.0.1 only; a session "
                + "started before heed listened sends it once it is reopened."
        }
    }
}

/// The receiver's state, at the end of Insights' tab strip: `● receiving · 2 agents · OTLP 127.0.0.1:4318`.
struct TelemetryReceiverPill: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let browser = model.telemetry
        let (color, text) = Self.state(browser)
        HStack(spacing: 7) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(text).font(Theme.mono(11)).foregroundStyle(Theme.fg2).lineLimit(1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .help(browser.export.map { export in
            TelemetryExport.agents.map { "\($0): \(export.summary(agent: $0))" }.joined(separator: "\n")
        } ?? "")
    }

    static func state(_ browser: TelemetryBrowser) -> (Color, String) {
        switch browser.receiver {
        case .off: return (Theme.fg3, "telemetry off")
        case .starting: return (Theme.fg3, "starting")
        case let .failed(reason): return (Theme.err, "not listening · \(reason)")
        case let .listening(port):
            let agents = browser.recentAgents.count
            let receiving = agents > 0
            return (
                receiving ? Theme.done : Theme.fg3,
                (receiving ? "receiving · \(agents) agent\(agents == 1 ? "" : "s")" : "listening")
                    + " · OTLP 127.0.0.1:\(port)"
            )
        }
    }
}

// MARK: The proxy banner

/// While heed forwards an agent's telemetry to your own collector: that heed sits in between, what stays here, who
/// goes where (hosts only), and the key that stops it.
private struct ProxyBanner: View {
    @Environment(AppModel.self) private var model
    let export: TelemetryExport
    let lines: [String]

    var body: some View {
        let who = TelemetryExport.agents.compactMap { agent -> String? in
            let hosts = Set(export.upstreams(agent).values.map(\.host)).sorted()
            return hosts.isEmpty ? nil : "\(agent) → \(hosts.joined(separator: ", "))"
        }
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "arrow.triangle.branch").font(.system(size: 13)).foregroundStyle(Theme.block)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 4) {
                Text("heed sits between your agents and your own collector: \(who.joined(separator: " · "))")
                    .font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(
                    "Every export goes on to it unchanged, with your headers, which heed never keeps. What heed "
                        + "keeps of it stays on this Mac. \(model.keyText(for: "telemetry.proxy.off", in: "telemetry")) "
                        + "stops it: those agents export only to their own endpoint again, from each pane's next launch."
                )
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                if !lines.isEmpty {
                    Text(lines.joined(separator: "   ")).font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            HStack(spacing: 8) {
                Text("stop forwarding").font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
                KeyCap(text: model.keyText(for: "telemetry.proxy.off", in: "telemetry"))
            }
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
            .clickRuns(CommandInvocation(name: "telemetry.proxy.off"))
            KeyCap(text: model.keyText(for: "telemetry.banner.hide", in: "telemetry"))
                .padding(.top, 4)
                .clickRuns(CommandInvocation(name: "telemetry.banner.hide"))
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 12)
        .background(Theme.block.opacity(0.07))
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

// MARK: Filter bar

private struct FilterBar: View {
    @Environment(AppModel.self) private var model
    let browser: TelemetryBrowser
    let query: String

    var body: some View {
        let filter = browser.filter
        HStack(spacing: 8) {
            chip("last", TelemetryFilter.label(filter.range), "telemetry.range")
            chip("agent", filter.agent ?? "all", "telemetry.agent")
            chip("repo", filter.repo ?? "all", "telemetry.repo")
            chip("model", filter.model ?? "all", "telemetry.model")
            chip("kind", filter.kindsLabel, "telemetry.kind")
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 10.5)).foregroundStyle(Theme.fg3)
                Text(query.isEmpty ? "filter spans: tool:bash status:error repo:markgraph" : query)
                    .font(Theme.ui(12.5))
                    .foregroundStyle(query.isEmpty ? Theme.fg3 : Theme.fg)
                    .lineLimit(1)
                Spacer(minLength: 4)
                KeyCap(text: model.keyText(for: "session.filter", in: "telemetry"))
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(model.filtering ? Theme.paneActive : Theme.line))
            .clickRuns(CommandInvocation(name: "session.filter"))
            HStack(spacing: 6) {
                Circle().fill(browser.live ? Theme.done : Theme.fg3).frame(width: 7, height: 7)
                Text(browser.live ? "live" : "paused").font(Theme.ui(12.5)).foregroundStyle(Theme.fg)
            }
            .padding(.horizontal, 10)
            .frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
            .clickRuns(CommandInvocation(name: "telemetry.live"))
        }
        .padding(.horizontal, 24)
        .frame(height: 48)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private func chip(_ label: String, _ value: String, _ command: String) -> some View {
        HStack(spacing: 5) {
            Text(label).foregroundStyle(Theme.fg2)
            Text(value).foregroundStyle(Theme.fg).lineLimit(1)
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(Theme.fg3)
        }
        .font(Theme.ui(12.5))
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        .fixedSize()
        .clickRuns(CommandInvocation(name: command))
        .help("\(model.keyText(for: command, in: "telemetry")) · \(Commands.spec(command)?.summary ?? "")")
    }
}

// MARK: Tiles and panels

enum TelemetryColors {
    static let read = Color(hex: 0x56C2D6)

    static func lane(_ lane: String) -> Color {
        switch lane {
        case "model": Theme.ask
        case "read": read
        case "edit": Theme.done
        case "bash": Theme.busy
        case "waiting": Theme.block
        case "mcp": Theme.ask.opacity(0.65)
        default: Theme.fg3
        }
    }

    static func kind(_ span: AgentSpan) -> Color {
        if span.status == .error { return Theme.err }
        switch span.kind {
        case .turn: return Theme.bg3
        case .model: return Theme.ask
        case .permission: return Theme.block
        case .tool:
            switch span.name {
            case "edit": return Theme.done
            case "read/grep", "web": return read
            case let name where name.hasPrefix("mcp"): return Theme.ask.opacity(0.65)
            default: return Theme.busy
            }
        case .hook, .other: return Theme.fg3
        }
    }

    static func state(_ state: TelemetryBoard.State) -> Color {
        switch state {
        case .working: Theme.busy
        case .blocked: Theme.block
        case .error: Theme.err
        case .idle: Theme.bg3
        }
    }
}

private struct TileView: View {
    let tile: TelemetryBoard.Tile

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(tile.label).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
            Text(tile.value).font(Theme.ui(22, weight: .semibold)).foregroundStyle(valueColor).lineLimit(1)
            TelemetrySpark(values: tile.series, color: lineColor).frame(height: 26)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }

    private var valueColor: Color {
        switch tile.tone {
        case .bad: Theme.err
        case .warn: Theme.block
        default: Theme.fg
        }
    }

    private var lineColor: Color {
        switch tile.id {
        case "turns", "tokens": Theme.busy
        case "p95": Theme.ask
        case "errors": Theme.err
        case "blocked": Theme.block
        default: Theme.done
        }
    }
}

/// A line across the range, scaled to its highest bucket.
struct TelemetrySpark: View {
    let values: [Double]
    let color: Color

    var body: some View {
        GeometryReader { geometry in
            let most = max(values.max() ?? 0, 0.0001)
            let step = values.count > 1 ? geometry.size.width / CGFloat(values.count - 1) : 0
            Path { path in
                for (index, value) in values.enumerated() {
                    let point = CGPoint(
                        x: CGFloat(index) * step,
                        y: geometry.size.height - CGFloat(value / most) * (geometry.size.height - 3) - 1.5
                    )
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }
            .stroke(color, style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

private struct LatencyPanel: View {
    let latency: [TelemetryBoard.Latency]

    var body: some View {
        Panel(title: "Latency by tool", note: "p50 · p95") {
            if latency.isEmpty {
                Text("No tool calls in the range.").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            }
            let most = max(latency.map(\.p95).max() ?? 1, 0.001)
            VStack(alignment: .leading, spacing: 9) {
                ForEach(latency) { row in
                    HStack(spacing: 10) {
                        Text(row.tool).font(Theme.mono(12)).foregroundStyle(Theme.fg).lineLimit(1)
                            .frame(width: 92, alignment: .leading)
                        GeometryReader { geometry in
                            let width = geometry.size.width
                            ZStack(alignment: .leading) {
                                RoundedRectangle(cornerRadius: 2).fill(Theme.bg3)
                                RoundedRectangle(cornerRadius: 2).fill(color(row).opacity(0.45))
                                    .frame(width: max(2, width * row.p95 / most))
                                RoundedRectangle(cornerRadius: 2).fill(color(row))
                                    .frame(width: max(2, width * row.p50 / most))
                            }
                        }
                        .frame(height: 8)
                        Text("\(TelemetryWords.duration(row.p50)) · \(TelemetryWords.duration(row.p95))")
                            .font(Theme.mono(11.5)).foregroundStyle(row.errors > 0 ? Theme.fg : Theme.fg2)
                            .frame(width: 118, alignment: .trailing)
                    }
                    .help("\(row.count) calls, \(row.errors) failed, \(TelemetryWords.duration(row.total)) in all")
                }
            }
        }
    }

    private func color(_ row: TelemetryBoard.Latency) -> Color {
        switch row.tool {
        case "bash": Theme.busy
        case "edit": Theme.done
        case "read/grep", "web": TelemetryColors.read
        case "model": Theme.fg3
        case let name where name.hasPrefix("mcp"): Theme.ask
        default: Theme.fg2
        }
    }
}

private struct StatePanel: View {
    let board: TelemetryBoard
    let range: TimeInterval

    var body: some View {
        Panel(title: "Agent state, last \(TelemetryFilter.label(range))", note: "per agent") {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(board.states) { agent in
                    HStack(spacing: 10) {
                        Text(agent.agent).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                            .frame(width: 92, alignment: .leading)
                        HStack(spacing: 0) {
                            ForEach(Array(agent.states.enumerated()), id: \.offset) { _, state in
                                Rectangle().fill(TelemetryColors.state(state))
                            }
                        }
                        .frame(height: 14)
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                    }
                }
                HStack(spacing: 12) {
                    legend("working", Theme.busy)
                    legend("blocked on you", Theme.block)
                    legend("error", Theme.err)
                    legend("idle", Theme.fg3)
                }
                .padding(.top, 2)
                if let line = board.noticed.first {
                    Text(line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private func legend(_ label: String, _ color: Color) -> some View {
    HStack(spacing: 4) {
        RoundedRectangle(cornerRadius: 1).fill(color).frame(width: 7, height: 7)
        Text(label).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
    }
}

private struct CostPanel: View {
    let board: TelemetryBoard
    let range: TimeInterval

    var body: some View {
        Panel(title: "Cost and tokens", note: "by model · last \(TelemetryFilter.label(range))") {
            VStack(alignment: .leading, spacing: 12) {
                TelemetrySpark(values: board.costSeries, color: Theme.ask).frame(height: 54)
                FlowLine(items: board.models.prefix(4).map { model in
                    ("\(model.model) \(AgentUsage.dollars(model.cost))", Self.color(model.model))
                } + (board.cacheShare.map { [("cache \(Int(($0 * 100).rounded()))%", Theme.fg2)] } ?? []))
                if let line = board.noticed.dropFirst().first {
                    Text(line).font(Theme.ui(12)).foregroundStyle(Theme.fg2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    static func color(_ model: String) -> Color {
        if model.contains("opus") { return Theme.ask }
        if model.contains("sonnet") { return Theme.busy }
        if model.contains("haiku") { return TelemetryColors.read }
        return Theme.done
    }
}

/// Short labels side by side, as many as fit.
private struct FlowLine: View {
    let items: [(String, Color)]

    var body: some View {
        HStack(spacing: 14) {
            ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                Text(item.0).font(Theme.mono(11.5)).foregroundStyle(item.1).lineLimit(1).fixedSize()
            }
        }
    }
}

// MARK: Spans

private struct SpanTable: View {
    @Environment(AppModel.self) private var model
    let browser: TelemetryBrowser

    var body: some View {
        let rows = browser.board.rows
        let trace = browser.selectedTrace
        VStack(spacing: 0) {
            header
            ListBody(
                count: rows.count, cursor: browser.cursor, ids: rows.map(\.id), empty: "No span matches.",
                hintView: .telemetry
            ) { index in
                SpanRow(row: rows[index], selected: index == browser.cursor)
            }
            // However many spans, the table scrolls in what is left and the trace keeps its room under it.
            .frame(minHeight: 96, maxHeight: .infinity)
            .clipped()
            if let row = browser.selected, !trace.isEmpty {
                Waterfall(row: row, bars: trace)
                    .fixedSize(horizontal: false, vertical: true)
                    .layoutPriority(1)
                    .shotRegion(.telemetryTrace)
            }
        }
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.bg2))
        .clipShape(RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
    }

    private var header: some View {
        HStack(spacing: 12) {
            Group {
                Text("TIME").frame(width: 70, alignment: .leading)
                Text("AGENT").frame(width: 110, alignment: .leading)
                Text("REPO").frame(width: 120, alignment: .leading)
                Text("SESSION").frame(maxWidth: .infinity, alignment: .leading)
                Text("SPAN").frame(width: 280, alignment: .leading)
                Text("DURATION").frame(width: 76, alignment: .trailing)
                Text("WALL").frame(width: 76, alignment: .trailing)
                Text("STATUS").frame(width: 70, alignment: .center)
            }
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct SpanRow: View {
    let row: TelemetryRow
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Text(row.span.start, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                .font(Theme.mono(12)).foregroundStyle(Theme.fg3).frame(width: 70, alignment: .leading)
            Text(row.agentLabel).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineLimit(1)
                .frame(width: 110, alignment: .leading)
            Text(row.repo.isEmpty ? "–" : row.repo).font(Theme.mono(12)).foregroundStyle(Theme.fg2).lineLimit(1)
                .frame(width: 120, alignment: .leading)
            Text(row.title).font(Theme.ui(12.5)).foregroundStyle(Theme.fg).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.label).font(Theme.mono(12)).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
                .frame(width: 280, alignment: .leading)
            Text(row.span.status == .waiting ? "–" : TelemetryWords.duration(row.span.duration))
                .font(Theme.mono(12)).foregroundStyle(Theme.fg2).frame(width: 76, alignment: .trailing)
            Text(TelemetryWords.duration(row.wall)).font(Theme.mono(12)).foregroundStyle(Theme.fg)
                .frame(width: 76, alignment: .trailing)
            StatusTag(status: row.span.status).frame(width: 70)
        }
        .padding(.horizontal, 16)
        .frame(height: 32)
        .background(selected ? Theme.bg3 : .clear)
    }
}

private struct StatusTag: View {
    let status: SpanStatus

    var body: some View {
        Text(status.rawValue)
            .font(Theme.mono(11))
            .foregroundStyle(color)
            .frame(width: 62, height: 19)
            .background(RoundedRectangle(cornerRadius: 4).fill(color.opacity(0.12)))
    }

    private var color: Color {
        switch status {
        case .ok: Theme.done
        case .error: Theme.err
        case .waiting: Theme.block
        }
    }
}

/// The selected span's trace: each span a bar along the trace's time, indented under its parent.
private struct Waterfall: View {
    let row: TelemetryRow
    let bars: [TelemetryBoard.TraceBar]

    var body: some View {
        let total = max(bars.map { $0.offset + $0.span.duration }.max() ?? 1, 0.001)
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 0) {
                Text("trace \(String((row.span.traceID ?? "").prefix(4)))… · \(row.agentLabel) · \(row.title)")
                    .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    .frame(width: 280, alignment: .leading)
                HStack {
                    Text("0 s")
                    Spacer()
                    Text(TelemetryWords.duration(total / 2))
                    Spacer()
                    Text(TelemetryWords.duration(total))
                }
                .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
            ForEach(bars.prefix(12)) { bar in
                HStack(spacing: 0) {
                    Text(title(bar.span))
                        .font(Theme.mono(12)).foregroundStyle(bar.span.id == row.span.id ? Theme.fg : Theme.fg2)
                        .lineLimit(1).truncationMode(.middle)
                        .padding(.leading, CGFloat(min(bar.depth, 3)) * 16)
                        .frame(width: 280, alignment: .leading)
                    GeometryReader { geometry in
                        let width = geometry.size.width
                        RoundedRectangle(cornerRadius: 3)
                            .fill(TelemetryColors.kind(bar.span))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(
                                bar.span.id == row.span.id ? Theme.fg.opacity(0.6) : .clear
                            ))
                            .frame(width: max(3, width * bar.span.duration / total))
                            .offset(x: width * bar.offset / total)
                    }
                    .frame(height: 16)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Theme.line.frame(height: 1) }
    }

    private func title(_ span: AgentSpan) -> String {
        switch span.kind {
        case .turn: "turn: \(span.detail)"
        case .model: "model"
        case .tool: [span.name, span.detail].filter { !$0.isEmpty }.joined(separator: " · ")
        case .permission: "permission · \(span.detail)"
        case .hook, .other: span.detail.isEmpty ? span.name : span.detail
        }
    }
}
