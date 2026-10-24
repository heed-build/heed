import HeedCore
import SwiftUI

/// The PR card's `next` line: what heed would do on the next round (`PilotPlan`), the key that explains it, and on
/// hover each setting behind it with where it comes from.
struct PilotPlanLine: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef

    var body: some View {
        let step = model.pilotPlan(for: ref)
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("next").foregroundStyle(Theme.fg3).fixedSize()
            Text(PilotPlan.text(step, now: Clock.now)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            // The explainer, by click as by key.
            KeyCap(text: model.keyText(for: "pilot.why"))
                .contentShape(Rectangle())
                .onTapGesture { model.perform(CommandInvocation(name: "pilot.why", target: .pull(ref))) }
                .help("What heed will do for this PR, and what holds it back")
        }
        .font(Theme.mono(11))
        .help(PilotPlan.help(step, sources: model.pilotPlanSources(for: ref)))
    }
}

/// Get it green's progress on a PR: the round it is on and what it sent last. Nothing while get it green is off.
struct PilotGreenLine: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef

    var body: some View {
        if let text = PilotPlan.greenProgress(
            pipeline: model.feedback[ref.description], settings: model.pilotSettings(for: ref),
            log: model.pilotTimeline(ref), now: Clock.now
        ) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("green").foregroundStyle(Theme.fg3).fixedSize()
                Text(text).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(Theme.mono(11))
        }
    }
}

/// Merging, ahead of time: `Ready to merge · set up merging` with merge now while get it merged is off, or
/// `Merging misconfigured: …` when the repo cannot do what its settings ask. Nothing otherwise.
struct PilotMergeLine: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef

    var body: some View {
        if model.readyToMerge(ref) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("✓ Ready to merge").foregroundStyle(Theme.done).fixedSize()
                Text("·").foregroundStyle(Theme.fg3)
                link("set up merging", "pilot.merge.setup")
                Spacer(minLength: 4)
                action("merge now", "pilot.merge.now")
            }
            .font(Theme.mono(11))
        } else if let line = model.mergeReadiness(for: ref).line {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text("⚠ \(line)").foregroundStyle(Theme.err).fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                link("set up", "pilot.merge.setup")
            }
            .font(Theme.mono(11))
        }
    }

    private func link(_ label: String, _ command: String) -> some View {
        Text(label).foregroundStyle(Theme.fg2).underline().fixedSize()
            .contentShape(Rectangle())
            .onTapGesture { model.perform(CommandInvocation(name: command, target: .pull(ref))) }
    }

    private func action(_ label: String, _ command: String) -> some View {
        HStack(spacing: 5) {
            KeyCap(text: model.keyText(for: command))
            Text(label).foregroundStyle(Theme.fg2)
        }
        .fixedSize()
        .contentShape(Rectangle())
        .onTapGesture { model.perform(CommandInvocation(name: command, target: .pull(ref))) }
    }
}

/// `pilot.why`: what heed will do for a PR, part by part with where each setting comes from, and below it what holds
/// the PR back, rule by rule. A dialog: `j` `k` scroll it, ⎋ closes it.
struct PilotExplainerView: View {
    @Environment(AppModel.self) private var model
    let ref: PullRef
    @State private var height: CGFloat = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.45).onTapGesture { model.pilotExplain = nil }
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 8) {
                    RepoChip(repo: ref.repo)
                    Text(verbatim: "#\(ref.number)").font(Theme.mono(13)).foregroundStyle(Theme.fg2)
                    Text("What heed will do").font(Theme.ui(15, weight: .semibold))
                    Text(model.github.pull(ref)?.title ?? "").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
                        .lineLimit(1).truncationMode(.tail)
                    Spacer(minLength: 8)
                    KeyCap(text: "⎋")
                }
                scroller
            }
            .padding(20)
            .frame(width: 640, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .shotRegion(.dialog)
        }
    }

    /// Takes the height of its content, up to most of the window, and scrolls to the `j` `k` row beyond it.
    @ViewBuilder private var scroller: some View {
        if ShotMode.active {
            content
        } else {
            ScrollViewReader { proxy in
                ScrollView {
                    content
                        .fixedSize(horizontal: false, vertical: true)
                        .background(GeometryReader { geometry in
                            Color.clear.preference(key: ExplainerHeight.self, value: geometry.size.height)
                        })
                }
                .frame(height: min(max(height, 1), 560), alignment: .top)
                .onPreferenceChange(ExplainerHeight.self) { height = $0 }
                .onChange(of: model.explainRow) { _, row in
                    withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(row, anchor: .top) }
                }
            }
        }
    }

    private var content: some View {
        let rows = model.pilotPlanRows(for: ref)
        let holds = model.pilotHolds(for: ref)
        return VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                step(row).id(index)
            }
            Theme.line.frame(height: 1)
            VStack(alignment: .leading, spacing: 6) {
                Text("WHAT HOLDS IT BACK").font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.fg3)
                if holds.isEmpty {
                    Text("Not fetched yet: heed fetches a watched PR's detail when it moves.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
                ForEach(Array(holds.enumerated()), id: \.element.id) { index, rule in
                    hold(rule).id(rows.count + index)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func step(_ row: PilotPlan.Row) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(row.title).font(Theme.ui(13, weight: .medium)).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.value).font(Theme.mono(12.5)).foregroundStyle(tint(row.tone))
                Text(row.detail).font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Text(row.origin).font(Theme.mono(10.5)).foregroundStyle(row.isDefault ? Theme.fg3 : Theme.block)
        }
    }

    private func hold(_ rule: GreenVerdict.Rule) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(rule.state == .pass ? "✓" : rule.state == .fail ? "✕" : "·").font(Theme.mono(12))
                .foregroundStyle(rule.state == .pass ? Theme.done : rule.state == .fail ? Theme.err : Theme.busy)
                .frame(width: 14)
            Text(rule.name.lowercased()).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
            Text(rule.detail).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func tint(_ tone: PilotPlan.Row.Tone) -> Color {
        switch tone {
        case .on: Theme.done
        case .ask: Theme.block
        case .busy: Theme.busy
        case .plain: Theme.fg
        case .off: Theme.fg3
        }
    }
}

private struct ExplainerHeight: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}
