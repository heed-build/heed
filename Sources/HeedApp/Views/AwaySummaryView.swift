import HeedCore
import SwiftUI

/// While you were away (`summary`, gZ): what still waits on you, pinned on top, then each day newest first, by kind.
struct AwaySummaryView: View {
    @Environment(AppModel.self) private var model
    let summary: AwaySummary

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color.black.opacity(0.45).onTapGesture { model.awaySummary = nil }
                dialog
                    .frame(width: min(640, max(geometry.size.width - 48, 360)))
                    .frame(maxHeight: max(geometry.size.height - 120, 240))
                    .fixedSize(horizontal: false, vertical: true)
                    .shotRegion(.dialog)
            }
        }
    }

    private var dialog: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("While you were away").font(Theme.ui(17, weight: .semibold))
                Text(summary.sinceText).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                Spacer()
                KeyCap(text: "⎋")
            }
            .padding(.bottom, 14)
            if !summary.waiting.isEmpty { waiting.padding(.bottom, 16) }
            if summary.days.isEmpty {
                Text("Nothing merged, ran, finished or closed \(summary.sinceText).")
                    .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
            } else {
                CappedScroll(cap: 520) {
                    ForEach(summary.days, id: \.start) { day($0) }
                }
            }
        }
        .padding(22)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.line))
        .shadow(color: .black.opacity(0.5), radius: 30)
    }

    private var waiting: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("STILL WAITING ON YOU · \(summary.waiting.count)")
                .font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.block)
                .padding(.horizontal, 6)
                .padding(.bottom, 4)
            ForEach(Array(summary.waiting.enumerated()), id: \.element.id) { index, item in
                HStack(spacing: 8) {
                    StateGlyph(state: item.state, guessed: item.guessed, size: 12)
                    Text(item.name).font(Theme.ui(13, weight: .medium)).lineLimit(1).layoutPriority(1)
                    Text(item.reason).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).lineLimit(1)
                    Spacer(minLength: 8)
                    KeyCap(text: "↩").opacity(index == summary.cursor ? 1 : 0.5)
                }
                .padding(.horizontal, 6)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 5).fill(index == summary.cursor ? Theme.bg3 : .clear))
                .contentShape(Rectangle())
                .onTapGesture { model.openAwaySession(item.id) }
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.block.opacity(0.07)))
    }

    private func day(_ day: AwaySummary.Day) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(day.title.uppercased()).font(Theme.ui(11, weight: .semibold)).foregroundStyle(Theme.fg3)
            ForEach(day.groups, id: \.kind) { group in
                VStack(alignment: .leading, spacing: 4) {
                    Text("\(group.kind.title) · \(group.rows.count)")
                        .font(Theme.ui(12.5, weight: .medium)).foregroundStyle(tint(group.kind))
                    ForEach(Array(group.rows.enumerated()), id: \.offset) { _, row in
                        HStack(spacing: 8) {
                            Text(row.subject).font(Theme.mono(12)).foregroundStyle(Theme.fg).lineLimit(1)
                                .layoutPriority(1)
                            Text(row.text).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                        }
                        .padding(.leading, 12)
                    }
                }
            }
        }
        .padding(.bottom, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tint(_ kind: AwayEvent.Kind) -> Color {
        switch kind {
        case .merged: Theme.ask
        case .runs: Theme.busy
        case .finished: Theme.done
        case .reviews: Theme.err
        case .closed: Theme.fg2
        }
    }
}
