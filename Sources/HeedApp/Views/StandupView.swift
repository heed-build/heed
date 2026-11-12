import HeedCore
import SwiftUI

/// History's Standup (`history.standup`): one Mindmap's reports by date, and the one under the cursor in full.
struct StandupView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let standup = model.standup
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                ForEach(standup.instances, id: \.self) { instance in
                    TabLabel(title: MindmapInstance.title(instance), active: instance == standup.instance)
                        .onTapGesture {
                            model.standup.instance = instance
                            model.standup.setCursor(0)
                        }
                }
                Spacer()
                Text(standup.question.map { "only: \($0)" } ?? "every question")
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3).lineLimit(1)
            }
            .padding(.horizontal, 20)
            .frame(height: 40)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            if standup.rows.isEmpty {
                VStack(spacing: 10) {
                    Text(model.config.standup.enabled ? "No report yet" : "Standup reports are off")
                        .font(Theme.ui(15, weight: .semibold))
                    Text(model.config.standup.enabled
                        ? "The next one is written on the days [standup] names; \(model.keyText(for: "standup.run", in: "standup")) writes one now."
                        :
                        "Turn them on with [standup] enabled = true: your questions answered from each org's Mindmap.")
                        .font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    list(standup).frame(width: 260).shotRegion(.standupList)
                    Theme.line.frame(width: 1)
                    if let report = standup.selected { detail(report).shotRegion(.standupDetail) }
                }
            }
        }
    }

    private func list(_ standup: StandupModel) -> some View {
        ListScroll {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(standup.rows.enumerated()), id: \.element.id) { index, report in
                    VStack(alignment: .leading, spacing: 3) {
                        Text(report.at.formatted(.dateTime.weekday(.wide).day().month(.abbreviated)))
                            .font(Theme.ui(13, weight: .semibold))
                        Text("since " + report.from.formatted(.dateTime.weekday(.abbreviated).hour().minute())
                            + " · \(report.answers.count) answer\(report.answers.count == 1 ? "" : "s")"
                            + (report.edited ? " · edited" : ""))
                            .font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    }
                    .padding(.horizontal, 18).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(index == standup.cursor ? Theme.bg3 : .clear)
                    .overlay(alignment: .leading) { if index == standup.cursor { Theme.block.frame(width: 2) } }
                    .contentShape(Rectangle())
                    .onTapGesture { model.standup.setCursor(index) }
                }
            }
        }
    }

    private func detail(_ report: StandupReport) -> some View {
        let shown = report.answers.filter { model.standup.question == nil || $0.question == model.standup.question }
        return ListScroll {
            VStack(alignment: .leading, spacing: 18) {
                Text("standup · \(MindmapInstance.title(report.instance)) · "
                    + report.at.formatted(date: .abbreviated, time: .shortened))
                    .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
                ForEach(shown, id: \.question) { answer in
                    VStack(alignment: .leading, spacing: 7) {
                        SectionHeader(title: answer.question)
                        Text(LocalizedStringKey(answer.text)).font(Theme.ui(13))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Theme.line.frame(height: 1).padding(.top, 4)
                FlowLayout(spacing: 18, lineSpacing: 6) {
                    KeyHint("standup.copy", scope: "standup", label: "copy the answer", color: Theme.fg2)
                    KeyHint("standup.copy.all", scope: "standup", label: "copy the report", color: Theme.fg2)
                    KeyHint("standup.question", scope: "standup", label: "one question", color: Theme.fg2)
                    KeyHint("standup.run", scope: "standup", label: "write now", color: Theme.fg2)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.bg2)
    }
}
