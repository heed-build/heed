import HeedCore
import SwiftUI

/// An agent's look on the board: its tint (identity) and its mark.
enum AgentLook {
    static func tint(_ id: String) -> Color {
        switch id {
        case "claude": Color.adaptive(0xD9A47A)
        case "codex": Color.adaptive(0x7FD3B0)
        case AgentFleet.copilot: Color.adaptive(0x8FB7F5)
        case "gemini": Color.adaptive(0xA9A3F2)
        case "cursor": Color.adaptive(0xC8CDD3)
        case "opencode": Color.adaptive(0xE8C27A)
        default: OrgPalette.automatic(for: id).swatch
        }
    }

    /// A letter, or an SF Symbol for the agents whose mark is a shape.
    static func mark(_ id: String) -> (text: String?, symbol: String?) {
        switch id {
        case "claude": ("C", nil)
        case "codex": ("X", nil)
        case AgentFleet.copilot: ("G", nil)
        case "gemini": (nil, "sparkle")
        case "cursor": (nil, "triangle.fill")
        default: (String(id.prefix(1)).uppercased(), nil)
        }
    }

    static func planSymbol(_ plan: FleetPlan) -> String? {
        switch plan {
        case .subscription: "repeat"
        case .included: "gift"
        case .metered: "dollarsign.circle"
        case .unknown: nil
        }
    }
}

/// An agent's tile: its mark on its tint.
struct AgentTile: View {
    let id: String
    var size: CGFloat = 30
    var selected = false

    var body: some View {
        let tint = AgentLook.tint(id)
        let mark = AgentLook.mark(id)
        ZStack {
            RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.14))
            if let symbol = mark.symbol {
                Image(systemName: symbol).font(.system(size: size * 0.42, weight: .bold))
            } else {
                Text(mark.text ?? "").font(Theme.ui(size * 0.42, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .frame(width: size, height: size)
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(selected ? tint : .clear, lineWidth: 1.5))
    }
}

/// What is left of an agent's limit: a ring filled that far, the percent in it. Drawn only where heed knows it.
struct QuotaRing: View {
    let quota: FleetQuota
    let tint: Color
    var size: CGFloat = 34
    var showsNumber = true

    var body: some View {
        ZStack {
            Circle().stroke(Theme.line, lineWidth: size > 24 ? 3 : 2.5)
            Circle().trim(from: 0, to: quota.left)
                .stroke(tint, style: StrokeStyle(lineWidth: size > 24 ? 3 : 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if showsNumber {
                Text("\(Int((quota.left * 100).rounded()))").font(Theme.mono(size * 0.28, weight: .semibold))
                    .foregroundStyle(Theme.fg)
            }
        }
        .frame(width: size, height: size)
        .help(quota.text())
    }
}

/// Seven days of an agent's use, one bar a day, today last; a dashed line for days it did nothing.
struct UsageSpark: View {
    let week: [Int]
    let tint: Color

    var body: some View {
        let top = Double(week.max() ?? 0)
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(week.enumerated()), id: \.offset) { _, value in
                if value > 0, top > 0 {
                    RoundedRectangle(cornerRadius: 1).fill(tint.opacity(0.75))
                        .frame(width: 5, height: max(3, 20 * Double(value) / top))
                } else {
                    Rectangle().fill(tint.opacity(0.45)).frame(width: 5, height: 1.5)
                }
            }
        }
        .frame(height: 20, alignment: .bottom)
        .help("tokens each day of the last seven, today last, from what its sessions reported")
    }
}

/// Filled pips of three: a part's size.
struct SizePips: View {
    let size: PartSize
    var color: Color = Theme.fg2

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0 ..< 3, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1).fill(index < size.pips ? color : color.opacity(0.25))
                    .frame(width: 5, height: 5)
            }
        }
        .help("size \(size.rawValue)")
    }
}

/// A repo's swatch: a small square in its colour.
struct RepoSwatch: View {
    let repo: String?

    var body: some View {
        RoundedRectangle(cornerRadius: 2).fill(Self.color(repo)).frame(width: 9, height: 9)
            .help(repo ?? "no repo in particular")
    }

    static func color(_ repo: String?) -> Color {
        guard let repo else { return Theme.fg3 }
        let name = repo.split(separator: "/").last.map(String.init) ?? repo
        return OrgPalette.automatic(for: name).swatch
    }
}

/// Diagonal lines over a shape: waiting.
struct Hatching: View {
    var color: Color = .white.opacity(0.06)

    var body: some View {
        Canvas { context, size in
            var path = Path()
            var x = -size.height
            while x < size.width {
                path.move(to: CGPoint(x: x, y: size.height))
                path.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 7
            }
            context.stroke(path, with: .color(color), lineWidth: 3)
        }
        .allowsHitTesting(false)
    }
}

/// The Split board, in the wizard and live on the goal's page: the lead's spine with its moves, a row per agent
/// (tile, name, plan, model, week, quota), each part a block as wide as its estimate, the elbows between them, the
/// longest chain heavier. The layout is HeedCore's (`SplitBoardLayout`); this draws it and turns clicks, hovers and
/// drags into commands.
struct SplitBoardView<Fold: View>: View {
    @Environment(AppModel.self) private var model
    let draft: SplitDraft
    let rows: [FleetAgent]
    let schedule: SplitSchedule
    var selected: String?
    var folded = false
    /// The goal's page: each part's state, and the now line.
    var states: [String: PartState]?
    var now: Double?
    /// Commands a click and a drop run (`split.*` in the wizard, `page.*` on the goal's page).
    var live = false
    /// Shorter rows, while defining a part takes the room under the board.
    var compact = false
    @ViewBuilder var fold: (SplitPart, SplitBoardLayout.Rect) -> Fold

    @State private var hover: String?
    @State private var dragging: (id: String, offset: CGSize)?

    var body: some View {
        GeometryReader { geometry in
            let layout = makeLayout(width: geometry.size.width)
            ZStack(alignment: .topLeading) {
                grid(layout)
                heads(layout)
                spine(layout)
                links(layout)
                ForEach(draft.active) { part in
                    if let rect = layout.blocks[part.id] { block(part, rect, layout) }
                }
                if let now {
                    nowLine(layout, now)
                }
                if let hover = hover ?? (live ? nil : model.goals.wizard.hover), hover != selected || !folded,
                   let part = draft.part(hover), let rect = layout.blocks[hover], dragging == nil
                {
                    preview(part, rect, layout)
                }
                if folded, let selected, let part = draft.part(selected), let rect = layout.blocks[selected] {
                    fold(part, rect)
                        .frame(width: 640)
                        .offset(x: min(max(rect.x - 8, 0), max(layout.width - 640, 0)), y: rect.y - 30)
                        .zIndex(10)
                }
            }
            .frame(width: geometry.size.width, height: layout.height, alignment: .topLeading)
        }
        .frame(height: metrics.top + metrics.leadHeight + metrics.rowHeight * Double(max(rows.count, 1)) + 6)
    }

    private var metrics: SplitBoardLayout.Metrics {
        var metrics = SplitBoardLayout.Metrics()
        if compact {
            metrics.top = 28
            metrics.leadHeight = 36
            metrics.rowHeight = 46
            metrics.blockHeight = 38
        }
        return metrics
    }

    private func makeLayout(width: Double) -> SplitBoardLayout {
        var layout = SplitBoardLayout.make(
            schedule: schedule, rows: rows.map(\.id), width: width, metrics: metrics
        )
        layout.connect(draft.active, chain: schedule.chain)
        return layout
    }

    // MARK: Axis and grid

    private func grid(_ layout: SplitBoardLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(Array(layout.ticks.enumerated()), id: \.offset) { index, tick in
                Rectangle().fill(index % 2 == 0 ? Theme.line : Theme.line.opacity(0.5))
                    .frame(width: 1, height: layout.height - layout.metrics.top + 4)
                    .offset(x: layout.x(tick), y: layout.metrics.top - 4)
                Text(SplitBoardLayout.tickText(tick)).font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                    .fixedSize()
                    .offset(x: layout.x(tick) - (tick == 0 ? 2 : 14), y: 8)
            }
            ForEach(0 ..< rows.count, id: \.self) { index in
                Rectangle().fill(Theme.line.opacity(0.6)).frame(width: layout.width, height: 1)
                    .offset(y: layout.rowY(index))
            }
        }
    }

    // MARK: The agents' column

    private func heads(_ layout: SplitBoardLayout) -> some View {
        let spare = AgentFleet.spare(model.goals.wizard.fleet)
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5).fill(Theme.ask.opacity(0.16))
                    Image(systemName: "star").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.ask)
                }
                .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Lead").font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.ask)
                    Text(([draft.lead?.agent, draft.lead?.model].compactMap(\.self)
                            + (schedule.leadIsLight ? ["light"] : [])).joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
            }
            .offset(x: 18, y: layout.metrics.top + 4)
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, agent in
                let tint = AgentLook.tint(agent.id)
                HStack(spacing: 10) {
                    AgentTile(id: agent.id)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(agent.name).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                                .lineLimit(1)
                            if let symbol = AgentLook.planSymbol(agent.plan) {
                                Image(systemName: symbol).font(.system(size: 10)).foregroundStyle(tint)
                                    .help(agent.plan.title)
                            }
                            if spare.contains(agent.id) {
                                Image(systemName: "bolt.fill").font(.system(size: 9)).foregroundStyle(Theme.block)
                                    .help("room to spare: it did little this week")
                            }
                        }
                        Text(agent.model ?? "").font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                    .frame(width: 128, alignment: .leading)
                    UsageSpark(week: agent.week, tint: tint).frame(width: 50, alignment: .trailing)
                    if let quota = agent.quota {
                        QuotaRing(quota: quota, tint: tint)
                    } else {
                        Color.clear.frame(width: 34, height: 34)
                            .help("heed has no quota for \(agent.name): it reported no limit; the spark is its use")
                    }
                }
                .offset(x: 18, y: layout.rowY(index) + (layout.metrics.rowHeight - 34) / 2)
            }
        }
    }

    // MARK: The lead's spine

    private func spine(_ layout: SplitBoardLayout) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.ask.opacity(0.45))
                .frame(width: layout.x(schedule.makespan + 0.1) - layout.x(0), height: 1)
                .offset(x: layout.x(0), y: layout.leadY)
            ForEach(Array(layout.moves.enumerated()), id: \.offset) { _, placed in
                let ask = placed.move.kind == .ask
                let past = now.map { placed.move.at < $0 } ?? false
                ZStack {
                    Circle().fill(past ? Theme.ask : Theme.bg2)
                    Circle().strokeBorder(ask ? Theme.block : Theme.ask, lineWidth: 1.5)
                    Image(systemName: symbol(placed.move.kind)).font(.system(size: 9, weight: .bold))
                        .foregroundStyle(past ? Theme.ink : ask ? Theme.block : Theme.ask)
                }
                .frame(width: 24, height: 24)
                .help(placed.move.label)
                .offset(x: placed.x - 12, y: layout.leadY - 12)
            }
        }
    }

    private func symbol(_ kind: SplitSchedule.LeadMove.Kind) -> String {
        switch kind {
        case .start: "play.fill"
        case .check: "checkmark.shield"
        case .ask: "questionmark"
        case .replan: "arrow.left.arrow.right"
        case .done: "star"
        }
    }

    // MARK: Links

    private func links(_ layout: SplitBoardLayout) -> some View {
        Canvas { context, _ in
            for connector in layout.connectors {
                let path = Self.path(connector.points)
                context.stroke(
                    path, with: .color(connector.onChain ? Theme.block.opacity(0.85) : Theme.fg3.opacity(0.45)),
                    style: StrokeStyle(lineWidth: connector.onChain ? 2 : 1, lineCap: .round, lineJoin: .round)
                )
            }
        }
        .allowsHitTesting(false)
    }

    static func path(_ points: [SplitBoardLayout.Point]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        guard points.count == 4 else {
            for point in points.dropFirst() {
                path.addLine(to: CGPoint(x: point.x, y: point.y))
            }
            return path
        }
        // Rounded elbows: across, down or up, across.
        let radius = min(5, abs(points[2].y - points[1].y) / 2)
        let down: Double = points[2].y > points[1].y ? 1 : -1
        path.addLine(to: CGPoint(x: points[1].x - radius, y: points[1].y))
        path.addQuadCurve(
            to: CGPoint(x: points[1].x, y: points[1].y + down * radius),
            control: CGPoint(x: points[1].x, y: points[1].y)
        )
        path.addLine(to: CGPoint(x: points[2].x, y: points[2].y - down * radius))
        path.addQuadCurve(
            to: CGPoint(x: points[2].x + radius, y: points[2].y), control: CGPoint(x: points[2].x, y: points[2].y)
        )
        path.addLine(to: CGPoint(x: points[3].x - 1, y: points[3].y))
        return path
    }

    // MARK: Blocks

    private func block(_ part: SplitPart, _ rect: SplitBoardLayout.Rect, _ layout: SplitBoardLayout) -> some View {
        let tint = AgentLook.tint(part.agent ?? "")
        let label = SplitBoardLayout.Label(width: rect.width)
        let state = states?[part.id]
        let onChain = schedule.chain.contains(part.id)
        let isSelected = part.id == selected
        let number = draft.number(of: part.id) ?? 0
        let offset = dragging?.id == part.id ? dragging!.offset : .zero
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4).fill(fill(state, tint))
            if case let .running(progress) = state {
                RoundedRectangle(cornerRadius: 4).fill(tint.opacity(0.32))
                    .frame(width: rect.width * progress)
            }
            if waits(state) || part.later {
                Hatching().clipShape(RoundedRectangle(cornerRadius: 4))
            }
            VStack(alignment: .leading, spacing: compact ? 2 : 5) {
                HStack(spacing: 4) {
                    if onChain {
                        Image(systemName: "diamond.fill").font(.system(size: 8)).foregroundStyle(Theme.block)
                    }
                    Text("\(number)").font(Theme.mono(10.5, weight: .semibold)).foregroundStyle(Theme.fg2)
                    if label.title {
                        Text(part.title).font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg)
                            .lineLimit(1).truncationMode(.tail)
                    }
                    Spacer(minLength: 0)
                    if let glyph = glyph(state) {
                        Image(systemName: glyph.symbol).font(.system(size: 10, weight: .bold))
                            .foregroundStyle(glyph.color)
                    }
                }
                HStack(spacing: 5) {
                    RepoSwatch(repo: part.repo)
                    if label.repoName, let name = part.repoName {
                        Text(name).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    if label.pips { SizePips(size: part.size) }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, compact ? 4 : 6)
        }
        .frame(width: rect.width, height: rect.height)
        .overlay(
            RoundedRectangle(cornerRadius: 4).strokeBorder(
                isSelected ? Theme.fg : state == .asking ? Theme.block : tint.opacity(0.35),
                lineWidth: isSelected ? 1.5 : 1
            )
        )
        .opacity(state == .done ? 0.85 : 1)
        // Before the offset, which moves the drawing and not the frame; shots place it with padding instead.
        .shotRegion(.splitPart, item: part.id)
        .padding(.leading, ShotMode.active ? rect.x : 0)
        .padding(.top, ShotMode.active ? rect.y : 0)
        .contentShape(Rectangle())
        .onHover { inside in
            if inside { hover = part.id } else if hover == part.id { hover = nil }
        }
        .tap { model.clickSplitPart(part.id, live: live) }
        .gesture(live ? nil : DragGesture(minimumDistance: 6)
            .onChanged { dragging = (part.id, $0.translation) }
            .onEnded { value in
                dragging = nil
                if let row = layout.row(at: rect.midY + value.translation.height), rows.indices.contains(row) {
                    model.dropSplitPart(part.id, on: rows[row].id)
                }
            })
        .offset(
            x: ShotMode.active ? 0 : rect.x + offset.width, y: ShotMode.active ? 0 : rect.y + offset.height
        )
        .zIndex(dragging?.id == part.id ? 5 : 0)
    }

    private func fill(_ state: PartState?, _ tint: Color) -> Color {
        switch state {
        case .done?: tint.opacity(0.42)
        case .asking?: Theme.block.opacity(0.10)
        default: tint.opacity(0.13)
        }
    }

    private func waits(_ state: PartState?) -> Bool {
        state == .planned || state == .waiting || state == .blocked
    }

    private func glyph(_ state: PartState?) -> (symbol: String, color: Color)? {
        switch state {
        case .done?: ("checkmark", Theme.done)
        case .running?: ("arrow.trianglehead.clockwise", Theme.busy)
        case .asking?: ("questionmark", Theme.block)
        case .review?: ("eye", Theme.ask)
        case .blocked?: ("exclamationmark", Theme.err)
        default: nil
        }
    }

    // MARK: Hover and now

    private func preview(_ part: SplitPart, _ rect: SplitBoardLayout.Rect, _ layout: SplitBoardLayout) -> some View {
        let numbers = model.splitNumbers(draft)
        let after = part.task.after.compactMap { numbers[$0].map(String.init) }
        return HStack(spacing: 8) {
            RepoSwatch(repo: part.repo)
            Text(part.title).font(Theme.ui(12.5, weight: .medium)).foregroundStyle(Theme.fg).lineLimit(1)
            Image(systemName: "clock").font(.system(size: 10)).foregroundStyle(Theme.fg3)
            Text(SplitSchedule.text(part.hours)).font(Theme.mono(11)).foregroundStyle(Theme.fg2)
            if !after.isEmpty {
                Image(systemName: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(Theme.fg3)
                Text("after " + after.joined(separator: " · ")).font(Theme.mono(11)).foregroundStyle(Theme.fg2)
            }
            if let done = part.task.doneWhen.first {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.done)
                Text("done when: " + done).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.bg3))
        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
        .fixedSize()
        .offset(x: min(rect.x, max(layout.width - 560, layout.metrics.header)), y: rect.y + rect.height + 4)
        .allowsHitTesting(false)
        .zIndex(8)
    }

    private func nowLine(_ layout: SplitBoardLayout, _ now: Double) -> some View {
        let x = layout.x(min(now, layout.span))
        return ZStack(alignment: .topLeading) {
            Rectangle().fill(Theme.block).frame(width: 1.5, height: layout.height - layout.metrics.top + 2)
                .offset(x: x, y: layout.metrics.top - 2)
            Text("now").font(Theme.mono(9.5, weight: .semibold)).foregroundStyle(Theme.block)
                .fixedSize().offset(x: x + 4, y: layout.metrics.top - 12)
        }
        .allowsHitTesting(false)
    }
}

extension AppModel {
    /// A click on a block: the cursor goes there; on the part under the cursor, it folds out (again: in).
    func clickSplitPart(_ id: String, live: Bool) {
        if live {
            if goals.wizard.pagePart == id { goals.wizard.pageFolded.toggle() } else {
                goals.wizard.pagePart = id
                goals.wizard.pageFolded = true
            }
        } else {
            if goals.wizard.part == id { goals.wizard.folded.toggle() } else {
                goals.wizard.part = id
                goals.wizard.folded = true
            }
        }
        updateScope()
    }

    /// A block dropped on an agent's row.
    func dropSplitPart(_ id: String, on agent: String) {
        guard let target = goals.wizard.fleet.first(where: { $0.id == agent }) ?? Optional(FleetAgent(id: agent)),
              openSplit?.draft.part(id)?.agent != agent
        else { return }
        place(id, on: target)
        updateScope()
    }
}
