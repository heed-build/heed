import HeedCore
import SwiftUI

/// `[local]`: screen snapshots kept for a local decision model to learn from, and what is kept so far.
struct LocalDecisionsCard: View {
    @Environment(AppModel.self) private var model
    @State private var confirmDelete = false

    var body: some View {
        let local = model.config.local
        SettingsCard(
            title: "Local decisions",
            note: "Screen snapshots for a local model to learn from: what an agent's pane showed when its hooks said "
                + "what it was doing. Kept in heed.sqlite on this Mac only, never sent anywhere and never in the call "
                + "log."
        ) {
            SettingRow(
                "local.record_screens",
                detail: "At each state a hook reports, the cleaned last \(ScreenSnapshot.lines) lines of the agent's "
                    + "pane; one every \(Int(ScreenSampler.workingEvery / 60)) minutes while it works; states read "
                    + "from the screen, unlabelled. Off by default."
            ) {
                ConfigSwitch(path: ["local", "record_screens"], isOn: local.recordScreens)
            }
            SettingRow("local.keep_days", unit: "days") {
                NumberField(path: ["local", "keep_days"], value: local.keepDays, unit: "days", range: 1 ... 365)
            }
            counts
        }
        .task(id: local.recordScreens) { await model.refreshScreenCounts() }
    }

    @ViewBuilder private var counts: some View {
        if let counts = model.screenCounts {
            InfoRow(label: "Labelled", detail: "Per agent and the state its hooks reported.", stacked: true) {
                if counts.labelled.isEmpty {
                    Text("none yet").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                } else {
                    labelled(counts.labelled)
                }
            }
            InfoRow(label: "Unlabelled", detail: "States read from the screen, for agents without hooks for them.") {
                Text(Counts.text(counts.unlabelled)).font(Theme.mono(12))
            }
            InfoRow(label: "Last 7 days") {
                HStack(spacing: 14) {
                    ForEach(counts.days, id: \.day) { day in
                        VStack(spacing: 2) {
                            Text(Self.weekday.string(from: day.day)).font(Theme.ui(11)).foregroundStyle(Theme.fg3)
                            Text(Counts.text(day.count)).font(Theme.mono(12))
                                .foregroundStyle(day.count == 0 ? Theme.fg3 : Theme.fg)
                        }
                    }
                }
            }
            InfoRow(
                label: "Start work",
                detail: "What Start work guessed and what you started with, kept as long as snapshots."
            ) {
                Text("\(Counts.text(model.startOutcomeCount ?? 0)) outcomes").font(Theme.mono(12))
                    .task { await model.refreshStartOutcomeCount() }
            }
            InfoRow(label: "Kept", detail: "Text, in heed.sqlite beside domain.json.") {
                Text("\(Counts.text(counts.total)) snapshots · \(Self.size(counts.bytes))").font(Theme.mono(12))
            }
            InfoRow(label: "Delete all") {
                let outcomes = model.startOutcomeCount ?? 0
                Button("Delete all…") { confirmDelete = true }
                    .disabled(counts.total == 0 && outcomes == 0)
                    .confirmationDialog(
                        "Delete all \(Counts.text(counts.total)) screen snapshots and \(Counts.text(outcomes)) Start "
                            + "work outcomes?",
                        isPresented: $confirmDelete
                    ) {
                        Button("Delete all", role: .destructive) { Task { await model.deleteLocalDecisions() } }
                    } message: {
                        Text("They cannot be brought back. Recording goes on: snapshots if it is on, outcomes always.")
                    }
            }
        }
    }

    private func labelled(_ rows: [ScreenSnapshotCounts.Labelled]) -> some View {
        let agents = rows.map(\.agent).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(agents, id: \.self) { agent in
                HStack(spacing: 12) {
                    Text(agent).font(Theme.mono(12)).frame(width: 80, alignment: .leading)
                    ForEach(AgentState.allCases, id: \.self) { state in
                        if let row = rows.first(where: { $0.agent == agent && $0.state == state }) {
                            HStack(spacing: 5) {
                                StateGlyph(state: state, size: 10)
                                Text(state.rawValue).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                                Text(Counts.text(row.count)).font(Theme.mono(12))
                            }
                        }
                    }
                }
            }
        }
    }

    private static let weekday: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "EEE"
        return formatter
    }()

    /// `1.2 MB`, `340 KB`: the same whatever the Mac's region.
    static func size(_ bytes: Int) -> String {
        if bytes >= 1_000_000 { return String(format: "%.1f MB", Double(bytes) / 1_000_000) }
        return "\(max(bytes / 1000, bytes > 0 ? 1 : 0)) KB"
    }
}
