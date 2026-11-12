import HeedCore
import SwiftUI

/// History's Mindmap (`history.mindmap`): one org's work (or your personal work) as areas, campaigns and groups,
/// laid out around the cursor: what holds the node on the left, the node among its siblings, what it holds on the
/// right (with what that holds, faintly, as deep as `-` `=` say), and the node itself in the detail pane.
struct MindmapView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let mindmap = model.mindmap
        let tree = mindmap.shown
        GeometryReader { geometry in
            HStack(spacing: 0) {
                if tree.nodes.isEmpty {
                    empty.frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    columns(tree).shotRegion(.mindmapColumns)
                    if geometry.size.width >= 900, let node = mindmap.focused {
                        Theme.line.frame(width: 1)
                        MindmapDetail(node: node, tree: tree)
                            .frame(width: min(440, geometry.size.width * 0.36))
                            .shotRegion(.mindmapDetail)
                    }
                }
            }
        }
    }

    private var empty: some View {
        VStack(spacing: 10) {
            Text(model.config.mindmap.enabled ? "Nothing here yet" : "The Mindmap is off")
                .font(Theme.ui(15, weight: .semibold))
            Text(model.config.mindmap.enabled
                ? "Work lands here as the ledger writes it, grouped into campaigns, one Mindmap per org."
                : "Turn it on with [mindmap] enabled = true: finished work is grouped into campaigns, one per org.")
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private func columns(_ tree: MindmapTree) -> some View {
        let mindmap = model.mindmap
        let focus = mindmap.focused
        let path = focus.map { tree.path(to: $0.id) } ?? []
        let siblings = mindmap.siblings
        let inside = focus.map { tree.children(of: $0.id) } ?? []
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                instancePicker
                Spacer()
                Text("depth \(mindmap.depth) · \(tree.unsorted.count) unsorted")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            ListScroll {
                HStack(alignment: .top, spacing: 18) {
                    column("Path", width: 170) {
                        if path.isEmpty {
                            Text(MindmapInstance.title(mindmap.instance)).font(Theme.ui(12.5))
                                .foregroundStyle(Theme.fg2)
                        }
                        ForEach(path, id: \.id) { node in
                            MindmapCard(node: node, tree: tree, style: .path).wireAnchor(node.id)
                                .onTapGesture { model.mindmap.focus = node.id }
                        }
                    }
                    column(
                        path.last?.title ?? MindmapInstance.title(mindmap.instance),
                        count: siblings.count,
                        width: 290
                    ) {
                        ForEach(siblings, id: \.id) { node in
                            MindmapCard(node: node, tree: tree, style: node.id == focus?.id ? .focus : .sibling)
                                .wireAnchor(node.id)
                                .onTapGesture { model.mindmap.focus = node.id }
                        }
                    }
                    column("Inside", count: inside.count, width: 300) {
                        ForEach(inside, id: \.id) { node in
                            MindmapCard(node: node, tree: tree, style: .inside, depth: mindmap.depth - 1)
                                .wireAnchor(node.id)
                                .onTapGesture { model.mindmap.focus = node.id }
                        }
                    }
                    Spacer(minLength: 0)
                }
                .padding(20)
                .overlayPreferenceValue(WireAnchors.self) { anchors in
                    GeometryReader { proxy in
                        MindmapWires(
                            anchors: anchors, proxy: proxy, path: path.map(\.id), siblings: siblings.map(\.id),
                            focus: focus?.id, inside: inside.map(\.id)
                        )
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var instancePicker: some View {
        HStack(spacing: 6) {
            ForEach(model.mindmap.instances, id: \.self) { instance in
                TabLabel(title: MindmapInstance.title(instance), active: instance == model.mindmap.instance)
                    .onTapGesture {
                        model.mindmap.instance = instance
                        model.mindmap.focus = nil
                    }
            }
            Text(
                "\(model.keyText(for: "mindmap.org.prev", in: "mindmap")) \(model.keyText(for: "mindmap.org.next", in: "mindmap"))"
            )
            .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
        }
    }

    private func column(
        _ title: String, count: Int? = nil, width: CGFloat, @ViewBuilder _ content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: count.map { "\(title) · \($0)" } ?? title)
            content()
        }
        .frame(width: width, alignment: .leading)
    }
}

/// One node as a card: its title, kind or stage, and what waits in it.
private struct MindmapCard: View {
    @Environment(AppModel.self) private var model
    enum Style { case path, sibling, focus, inside }
    let node: MindNode
    let tree: MindmapTree
    let style: Style
    var depth = 0

    var body: some View {
        let open = tree.stillOpen(under: node.id).count
        VStack(alignment: .leading, spacing: 4) {
            Text(node.title)
                .font(node.kind == .work ? Theme.mono(12) : Theme.ui(style == .path ? 12 : 13, weight: .semibold))
                .foregroundStyle(style == .sibling ? Theme.fg2 : Theme.fg)
                .lineLimit(2)
            if style != .path {
                HStack(spacing: 6) {
                    MindmapTag(text: node.stage?.rawValue ?? node.kind.rawValue, tint: tint)
                    // A piece of work: what it was and how big, as on its session's row.
                    if node.kind == .work, let entry = node.entry.flatMap({ model.ledger.entries[$0] }) {
                        if let kind = entry.workKind { WorkKindBadge(kind: kind) }
                        if let size = WorkSize.of(
                            lines: entry.diff.map { $0.added + $0.removed }, files: entry.diff?.files
                        ) {
                            SizeBars(size: size)
                        }
                    }
                    if node.suggested { MindmapTag(text: "suggested", tint: Theme.ask) }
                    let pieces = tree.entries(under: node.id).count
                    if node.kind != .work { Text("\(pieces) piece\(pieces == 1 ? "" : "s")") }
                    if open > 0 { Text("● \(open) open").foregroundStyle(Theme.block) }
                    if node.unconfirmed || node.suggested {
                        Spacer(minLength: 4)
                        MindmapJudge(node: node)
                    }
                }
                .font(Theme.ui(11)).foregroundStyle(Theme.fg3)
            }
            if style == .focus, let synopsis = node.synopsis {
                Text(synopsis).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2).lineLimit(3)
            }
            if style == .inside, depth > 0 {
                let kids = tree.children(of: node.id)
                // Four at most; past that the last line counts the rest, so the └ is always the real end.
                let shown = kids.count > 4 ? 3 : kids.count
                ForEach(Array(kids.prefix(shown).enumerated()), id: \.element.id) { index, kid in
                    Text((index == shown - 1 && kids.count == shown ? "└ " : "├ ") + kid.title)
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                if kids.count > shown {
                    Text("└ \(kids.count - shown) more").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                }
                if kids.count > 4 { Text("+\(kids.count - 4) more").font(Theme.mono(11)).foregroundStyle(Theme.fg3) }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(style == .focus ? Theme.bg3 : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(style == .focus ? Theme.block : Theme.line))
        .overlay(alignment: .leading) {
            if style != .path { tint.frame(width: 3).clipShape(RoundedRectangle(cornerRadius: 1.5)) }
        }
        .opacity(node.stage == .done ? 0.6 : 1)
        .contentShape(Rectangle())
    }

    private var tint: Color {
        switch node.stage {
        case .landing: Theme.block
        case .building: Theme.done
        case .stalled: Theme.err
        case .exploring: Theme.busy
        case .done, nil: Theme.fg3
        }
    }
}

private struct MindmapTag: View {
    let text: String
    let tint: Color

    var body: some View {
        Text(text).font(Theme.mono(10.5)).foregroundStyle(tint)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(tint.opacity(0.4)))
            .fixedSize()
    }
}

/// The node in full: the same parts at every depth. Facts are counted from the ledger; the synopsis, decisions and
/// what is open are the node's.
private struct MindmapDetail: View {
    @Environment(AppModel.self) private var model
    let node: MindNode
    let tree: MindmapTree

    var body: some View {
        let facts = MindmapFacts(of: node.id, in: tree, ledger: model.ledger.entries)
        let decided = tree.decisions(of: node.id)
        let open = tree.stillOpen(under: node.id)
        ListScroll {
            VStack(alignment: .leading, spacing: 14) {
                Text(([node.kind.rawValue, MindmapInstance.title(model.mindmap.instance)] + tree.path(to: node.id)
                        .map(\.title)).joined(separator: " · "))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                Text(node.title).font(Theme.ui(18, weight: .semibold))
                if let intent = node.intent { Text(intent).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2) }
                if node.suggested || node.unconfirmed, let placement = node.placement {
                    Text("heed put it here, \(Int((placement.confidence * 100).rounded()))% sure (\(placement.route)): "
                        + "\(model.keyText(for: "mindmap.accept", in: "mindmap")) or ✓ says it is right, "
                        + "\(model.keyText(for: "mindmap.move", in: "mindmap")) or ↦ moves it")
                        .font(Theme.ui(12)).foregroundStyle(node.suggested ? Theme.ask : Theme.fg3)
                }
                section("Facts") {
                    HStack(spacing: 6) {
                        tile("\(facts.pieces)", "pieces of work")
                        tile("\(facts.pulls)", facts.openPulls > 0 ? "PRs · \(facts.openPulls) open" : "PRs")
                        tile(facts.agentTime > 0 ? Durations.short(facts.agentTime) : "–", "agent time")
                        tile(span(facts), "span")
                    }
                    if !facts.repos.isEmpty { fact(
                        "Repos · agents",
                        (facts.repos + facts.agents).joined(separator: " · ")
                    ) }
                    if let touched = facts.mostTouched { fact("Most touched", "\(touched.file) ×\(touched.times)") }
                }
                if let synopsis = node.synopsis {
                    section("Synopsis" + (node.synopsisStale ? " · being rewritten" : "")) {
                        Text(synopsis).font(Theme.ui(13)).fixedSize(horizontal: false, vertical: true)
                    }
                }
                if !decided.shown.isEmpty || decided.inside > 0 {
                    section(decisionsTitle(decided)) {
                        ForEach(decided.shown, id: \.self) { decision in
                            VStack(alignment: .leading, spacing: 1) {
                                Text((decision.pinned ? "📌 " : "") + decision.text)
                                    .strikethrough(decision.supersededBy != nil)
                                    .foregroundStyle(decision.supersededBy != nil ? Theme.fg3 : Theme.fg)
                                    .font(Theme.ui(12.5))
                                Text(source(decision.source) +
                                    (decision.supersededBy.map { " · superseded by: \($0)" } ?? ""))
                                    .font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                            }
                        }
                    }
                }
                if !open.isEmpty {
                    section("Open · \(open.count)") {
                        ForEach(open, id: \.self) { item in
                            VStack(alignment: .leading, spacing: 1) {
                                HStack(spacing: 6) {
                                    if item
                                        .kind != .followUp { MindmapTag(text: item.kind.rawValue, tint: Theme.block) }
                                    Text(item.text).font(Theme.ui(12.5))
                                }
                                Text(source(item.source)).font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
                            }
                            .padding(.leading, 8)
                            .overlay(alignment: .leading) { Theme.block.frame(width: 2) }
                        }
                    }
                }
                let links = MindmapLinks.of(node.id, in: tree, ledger: model.ledger.entries)
                if !links.isEmpty {
                    section("Linked · \(links.count)") {
                        ForEach(links, id: \.self) { link in
                            HStack(spacing: 6) {
                                MindmapTag(text: link.label, tint: Theme.fg2)
                                Text(tree[link.target]?.title ?? link.target).font(Theme.ui(12.5)).lineLimit(1)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { model.mindmap.focus = link.target }
                        }
                    }
                }
                if let brief = model.memoryBrief(on: node) {
                    section("A session started here is told") {
                        Text(brief).font(Theme.ui(11.5)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Theme.line.frame(height: 1).padding(.top, 6)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    hint("mindmap.session", "session here")
                    hint("mindmap.in", "in")
                    hint("mindmap.out", "out")
                    if node.suggested { hint("mindmap.accept", "keep") }
                    hint("mindmap.move", "move")
                    hint("mindmap.nest", "group")
                    hint("mindmap.rename", "rename")
                    if !open.isEmpty { hint("mindmap.done", "done") }
                    if node.entry != nil { hint("mindmap.open", "ledger") }
                    if !links.isEmpty { hint("mindmap.link.next", "linked") }
                    if node.kind != .work { hint("mindmap.goal", "make a goal") }
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg2)
    }

    private func decisionsTitle(_ decided: (shown: [MindNode.Decision], inside: Int)) -> String {
        if decided.shown.isEmpty { return "Decisions · \(decided.inside) in the work it holds" }
        return "Decisions · \(decided.shown.count)" + (decided.inside > 0 ? " · \(decided.inside) more inside" : "")
    }

    private func source(_ entry: String) -> String { model.ledger.entries[entry]?.title ?? entry }

    private func span(_ facts: MindmapFacts) -> String {
        guard let from = facts.from, let to = facts.to else { return "–" }
        let days = Int((to.timeIntervalSince(from) / 86400).rounded(.up))
        return days <= 1 ? "1 d" : "\(days) d"
    }

    private func tile(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(Theme.ui(15, weight: .semibold))
            Text(label).font(Theme.ui(10.5)).foregroundStyle(Theme.fg3).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    private func section(_ title: String, @ViewBuilder _ content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            SectionHeader(title: title)
            content()
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(Theme.fg3)
            Spacer()
            Text(value).foregroundStyle(Theme.fg).lineLimit(1)
        }
        .font(Theme.ui(12.5))
    }

    private func hint(_ command: String, _ text: String) -> some View {
        KeyHint(command, scope: "mindmap", label: text, color: Theme.fg2)
    }
}

// MARK: Wires

struct WireAnchors: PreferenceKey {
    static let defaultValue: [String: Anchor<CGRect>] = [:]
    static func reduce(value: inout [String: Anchor<CGRect>], nextValue: () -> [String: Anchor<CGRect>]) {
        value.merge(nextValue()) { _, new in new }
    }
}

extension View {
    func wireAnchor(_ id: String) -> some View {
        anchorPreference(key: WireAnchors.self, value: .bounds) { [id: $0] }
    }
}

/// The lines between the columns: down the path, from the path to every sibling, from the focus to what it holds.
private struct MindmapWires: View {
    let anchors: [String: Anchor<CGRect>]
    let proxy: GeometryProxy
    let path: [String]
    let siblings: [String]
    let focus: String?
    let inside: [String]

    var body: some View {
        Canvas { context, _ in
            func rect(_ id: String) -> CGRect? { anchors[id].map { proxy[$0] } }
            func curve(from: CGPoint, to: CGPoint, color: Color, width: CGFloat) {
                var line = Path()
                line.move(to: from)
                let middle = (from.x + to.x) / 2
                line.addCurve(to: to, control1: CGPoint(x: middle, y: from.y), control2: CGPoint(x: middle, y: to.y))
                context.stroke(line, with: .color(color), lineWidth: width)
            }
            for (upper, lower) in zip(path, path.dropFirst()) {
                if let top = rect(upper), let bottom = rect(lower) {
                    var line = Path()
                    line.move(to: CGPoint(x: top.minX + 14, y: top.maxY))
                    line.addLine(to: CGPoint(x: bottom.minX + 14, y: bottom.minY))
                    context.stroke(line, with: .color(Theme.fg3.opacity(0.6)), lineWidth: 1.2)
                }
            }
            if let holder = path.last.flatMap(rect) {
                for sibling in siblings {
                    guard let card = rect(sibling) else { continue }
                    let on = sibling == focus
                    curve(
                        from: CGPoint(x: holder.maxX, y: holder.midY), to: CGPoint(x: card.minX, y: card.midY),
                        color: on ? Theme.block : Theme.fg3.opacity(0.5), width: on ? 1.6 : 1.2
                    )
                }
            }
            if let focus, let card = rect(focus) {
                for child in inside {
                    guard let kid = rect(child) else { continue }
                    curve(
                        from: CGPoint(x: card.maxX, y: card.midY), to: CGPoint(x: kid.minX, y: kid.midY),
                        color: Theme.block.opacity(0.75), width: 1.4
                    )
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// On a card heed placed and nobody judged yet: how sure it was, faintly, and two quiet controls. ✓ says it is right,
/// ↦ moves it (the command line opens for where). Either is what Hunch learns from; leaving it is fine too.
private struct MindmapJudge: View {
    @Environment(AppModel.self) private var model
    let node: MindNode
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 6) {
            if let placement = node.placement {
                Text("heed · \(Int((placement.confidence * 100).rounded()))%").font(Theme.mono(10.5))
            }
            Image(systemName: "checkmark").help("heed put it in the right place (y)")
                .onTapGesture { model.judgeMindmap(node.id, keep: true) }
            Image(systemName: "arrow.turn.up.right").help("move it somewhere else (m)")
                .onTapGesture { model.judgeMindmap(node.id, keep: false) }
        }
        .font(Theme.ui(10.5))
        .foregroundStyle(hovered ? Theme.fg2 : Theme.fg3.opacity(0.7))
        .onHover { hovered = $0 }
    }
}
