import HeedCore
import SwiftUI

/// Settings › Inference & decisions › Hunch: the Laya checkpoints Hunch runs (size, license, source; download with
/// progress, stop, resume, delete), what the models folder holds, which questions Hunch answers and which go elsewhere,
/// and learning from your corrections. Nothing downloads until you press Download; nothing here leaves the Mac.
struct HunchGroup: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let hunch = model.hunch
        GroupLabel(title: "Hunch")
        Text(
            "Hunch answers typed questions on this Mac with a small Laya checkpoint (tens of milliseconds, no "
                + "network), and learns from your corrections. The model, your examples and what it learns stay in "
                + "~/Library/Application Support/Heed/models and never leave this Mac."
        )
        .font(Theme.ui(11.5))
        .foregroundStyle(Theme.fg3)
        .fixedSize(horizontal: false, vertical: true)
        if !hunch.supported {
            Text("Hunch needs a Mac with Apple silicon.").font(Theme.ui(12)).foregroundStyle(Theme.err)
        } else {
            Field(
                label: "Model",
                detail: "Downloaded from its origin at a pinned revision, every file checked by sha256."
            ) {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(hunch.catalogue) { checkpoint in
                        CheckpointRow(checkpoint: checkpoint, chosen: checkpoint.id == hunch.checkpointID)
                    }
                }
            }
            Field(label: "On disk", detail: "Everything Hunch keeps, in the models folder.") {
                Text(hunch.usage.summary(titles: Dictionary(uniqueKeysWithValues: hunch.catalogue.map {
                    ($0.id, $0.title)
                })))
                .font(Theme.mono(12))
                .fixedSize(horizontal: false, vertical: true)
            }
            Field(label: "Questions", detail: "Which decisions Hunch takes, and where the rest go.") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(HunchRouting.summary(
                        localReady: model.localModel.ready, modelCalls: model.config.llm.enabled
                    ))
                    .font(Theme.ui(12))
                    .foregroundStyle(Theme.fg2)
                    .fixedSize(horizontal: false, vertical: true)
                    ScreenReadingLine()
                }
            }
            HunchLearningGroup()
        }
    }
}

/// Agent screens: what Hunch reads of agents' panes, whether it does now, and its newest reading.
private struct ScreenReadingLine: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(
                "Agent screens: Hunch reads the last \(HunchScreen.lines) lines of a swarm worker's pane, and of "
                    + "agents whose hooks miss a state, as working, waiting for input, stuck or done: at most once a "
                    + "minute per pane, only when its screen changed. The agents pane's stuck signal says whether "
                    + "Hunch or heed's guess read it."
            )
            .font(Theme.ui(12))
            .foregroundStyle(Theme.fg2)
            .fixedSize(horizontal: false, vertical: true)
            Text(status).font(Theme.mono(11.5)).foregroundStyle(model.hunchReadsScreens ? Theme.done : Theme.fg3)
        }
    }

    private var status: String {
        guard model.hunchReadsScreens else {
            return model.config.decisions.decider == .hunch
                ? "off until a model is downloaded: heed's guess reads screens"
                : "off: Hunch is not the decider, heed's guess reads screens"
        }
        guard let reading = model.latestScreenReading else { return "on · nothing read yet" }
        return "on · last read \(Clock.relative(reading.at)): \(reading.line)"
    }
}

/// One checkpoint: what it is, its size and license, and its download.
private struct CheckpointRow: View {
    @Environment(AppModel.self) private var model
    let checkpoint: HunchCheckpoint
    let chosen: Bool
    @State private var confirmDelete = false

    var body: some View {
        let state = model.hunch.downloads[checkpoint.id] ?? .absent
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(checkpoint.title).font(Theme.ui(13, weight: .semibold))
                if checkpoint.recommended {
                    Text("recommended").font(Theme.ui(11)).foregroundStyle(Theme.done)
                }
                if chosen { Text("[hunch] checkpoint").font(Theme.mono(11)).foregroundStyle(Theme.fg3) }
            }
            Text(
                "\(HunchCatalogue.size(checkpoint.totalSize)) · \(checkpoint.encoder) · \(checkpoint.languages) · "
                    + "weights \(checkpoint.license)"
            )
            .font(Theme.mono(11.5))
            .foregroundStyle(Theme.fg2)
            Text(checkpoint.note).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Link(checkpoint.repository, destination: checkpoint.sourceURL).font(Theme.ui(11.5))
                Link("license", destination: checkpoint.licenseURL).font(Theme.ui(11.5))
            }
            action(state)
        }
        .padding(10)
        .frame(maxWidth: 560, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(chosen ? Theme.line : Theme.line.opacity(0.5)))
    }

    @ViewBuilder private func action(_ state: HunchDownloadState) -> some View {
        let size = HunchCatalogue.size(checkpoint.totalSize)
        switch state {
        case .absent:
            Button("Download (\(size))") { model.perform(CommandInvocation(
                name: "hunch.download",
                arguments: [checkpoint.id]
            )) }
        case let .partial(done, total), let .failed(_, done, total):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 320)
                HStack(spacing: 10) {
                    Button("Resume (\(HunchCatalogue.size(total - done)) left)") {
                        model.perform(CommandInvocation(name: "hunch.download", arguments: [checkpoint.id]))
                    }
                    deleteButton(partial: true)
                    if case let .failed(reason, _, _) = state {
                        Text(reason).font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                    }
                }
            }
        case let .downloading(done, total, file):
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: Double(done), total: Double(max(total, 1))).frame(width: 320)
                HStack(spacing: 10) {
                    Text("\(HunchCatalogue.size(done)) of \(HunchCatalogue.size(total)) · \(file)")
                        .font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
                    Button("Stop") { model.perform(CommandInvocation(name: "hunch.cancel", arguments: [checkpoint.id]))
                    }
                }
            }
        case let .verifying(file, _, _):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("checking \(file)'s sha256").font(Theme.mono(11.5)).foregroundStyle(Theme.fg2)
            }
        case .ready:
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Circle().fill(Theme.done).frame(width: 7, height: 7)
                    Text("downloaded, checked").font(Theme.mono(11.5)).foregroundStyle(Theme.done)
                }
                deleteButton(partial: false)
            }
        }
    }

    private func deleteButton(partial: Bool) -> some View {
        Button(partial ? "Discard" : "Delete…") { confirmDelete = true }
            .confirmationDialog(
                "Delete \(checkpoint.title)\(partial ? "'s partial download" : "")?", isPresented: $confirmDelete
            ) {
                Button("Delete", role: .destructive) { model.perform(CommandInvocation(
                    name: "hunch.delete",
                    arguments: [checkpoint.id]
                )) }
            } message: {
                Text(partial ? "What was fetched goes; Download starts again."
                    : "The model and the head trained on it go; your examples stay. Download brings the model back.")
            }
    }
}

/// `[hunch] learn`: the toggle, the training set, the last run and its held-out score, Retrain now and Reset.
private struct HunchLearningGroup: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReset = false

    var body: some View {
        let hunch = model.hunch
        let ready = hunch.status.modelReady
        Field(
            label: "Learn from my corrections",
            detail: "Your Attention actions (done, snooze, mute, boost), your answers to goal attach proposals, and "
                + "screen snapshots with the state the hooks reported become examples. Hunch trains its head on them in "
                + "the background, at low priority, only when the Mac is idle and on power. On by default once a "
                + "model is downloaded."
        ) {
            Toggle("", isOn: Binding(
                get: { model.hunchLearns }, set: { model.setConfig(["hunch", "learn"], .bool($0)) }
            ))
            .toggleStyle(.switch)
            .labelsHidden()
            .disabled(!ready)
        }
        Field(
            label: "Examples",
            detail: "Kept in the models folder, newest \(HunchTrainingSet.maxExamples) at most. One in five is held "
                + "out: never trained on, only used to judge."
        ) {
            if hunch.total == 0 {
                Text("none yet").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
            } else {
                HStack(spacing: 14) {
                    Text("\(hunch.total) · \(hunch.heldOut) held out").font(Theme.mono(12))
                    ForEach(HunchFamily.allCases, id: \.self) { family in
                        if let count = hunch.counts[family] {
                            Text("\(family.title) \(count)").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                        }
                    }
                }
            }
        }
        Field(label: "Last trained", detail: lastDetail(hunch.record)) {
            VStack(alignment: .leading, spacing: 4) {
                if let training = hunch.training {
                    HStack(spacing: 8) {
                        ProgressView(value: training ?? 0).frame(width: 200)
                        Text("learning now").font(Theme.mono(12)).foregroundStyle(Theme.block)
                    }
                } else if let at = hunch.record.trainedAt {
                    Text(Self.when.localizedString(for: at, relativeTo: Clock.now) + seconds(hunch.record))
                        .font(Theme.mono(12))
                } else {
                    Text("never").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
                }
                if let note = hunch.note {
                    Text(note).font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                }
                if let error = hunch.record.error {
                    Text(error).font(Theme.ui(11.5)).foregroundStyle(Theme.err)
                }
            }
        }
        Field(
            label: "Held-out accuracy",
            detail: "The head in use before the run, and the run's own. A new head is used only when it does no worse."
        ) {
            if let before = hunch.record.before, let after = hunch.record.after {
                VStack(alignment: .leading, spacing: 3) {
                    Text("before \(before.text) → after \(after.text)").font(Theme.mono(12))
                    if hunch.record.adopted == true {
                        Text("adopted: decisions use the new head").font(Theme.ui(11.5)).foregroundStyle(Theme.done)
                    } else if let kept = hunch.record.kept {
                        Text("kept the head in use: \(kept)").font(Theme.ui(11.5)).foregroundStyle(Theme.fg3)
                    }
                }
            } else {
                Text("not measured yet").font(Theme.mono(12)).foregroundStyle(Theme.fg3)
            }
        }
        Field(label: "Head", detail: "Reset goes back to the checkpoint's own head; the examples stay.") {
            HStack(spacing: 12) {
                Text(hunch.record.head == nil ? "the checkpoint's own" : "trained on your corrections")
                    .font(Theme.mono(12))
                Button("Retrain now") { model.perform(CommandInvocation(name: "hunch.retrain")) }
                    .disabled(!ready || hunch.training != nil)
                Button("Reset to base…") { confirmReset = true }
                    .disabled(!ready || hunch.record.head == nil)
                    .confirmationDialog("Go back to the checkpoint's own head?", isPresented: $confirmReset) {
                        Button("Reset", role: .destructive) { model.perform(CommandInvocation(name: "hunch.reset")) }
                    } message: {
                        Text(
                            "The trained head is deleted. Your examples stay, and the next run starts again from them."
                        )
                    }
            }
        }
    }

    private func lastDetail(_ record: HunchLearningRecord) -> String {
        guard record.trainedAt != nil else {
            return "A run starts once there are \(HunchSchedule.minimumExamples) examples, then after every "
                + "\(HunchSchedule.minimumNew) new ones, at most twice a day."
        }
        return "On \(record.trained) examples, judged on \(record.heldOut) held out."
    }

    private func seconds(_ record: HunchLearningRecord) -> String {
        record.seconds.map { String(format: " · took %.0fs", $0) } ?? ""
    }

    private static let when: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()
}
