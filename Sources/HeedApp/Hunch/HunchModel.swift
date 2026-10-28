import Foundation
import HeedCore
import Observation

/// Hunch in the app: the checkpoints it can download and where each stands, the training set and the last run, and a
/// run in progress. Settings › Inference & decisions renders it; `AppModel+Hunch` drives it. All IO runs off the main
/// actor; fixtures (and shots) set its values and do none.
@MainActor
@Observable
final class HunchModel {
    let catalogue: [HunchCheckpoint]
    let folder: HunchFolder
    /// MLX needs Apple silicon.
    let supported: Bool

    private(set) var downloads: [String: HunchDownloadState] = [:]
    private(set) var usage = HunchDiskUsage()
    /// The training set: examples per family, and how many are held out.
    private(set) var counts: [HunchFamily: Int] = [:]
    private(set) var heldOut = 0
    private(set) var record = HunchLearningRecord()
    /// A run in progress: how far (nil: starting); nil when none runs.
    private(set) var training: Double??
    /// Why no run is going now, or how the last attempt ended.
    var note: String?
    /// A downloaded checkpoint's directory; nil until one is.
    var directory: URL? { downloads[checkpointID] == .ready ? checkpoint.map(folder.checkpoint) : nil }

    /// `[hunch] checkpoint`, set by the app from config.
    var checkpointID = HunchSettings.defaultCheckpoint
    let runtime = HunchRuntime()

    @ObservationIgnored private var downloadTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored private(set) var trainTask: Task<Void, Never>?
    @ObservationIgnored let fixture: Bool

    init(fixture: Bool, root: URL? = nil) {
        catalogue = HunchRuntime.catalogue
        folder = HunchFolder(root: root ?? FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        )[0].appending(path: "Heed/models", directoryHint: .isDirectory))
        supported = MacConditions.appleSilicon
        self.fixture = fixture
        for checkpoint in catalogue {
            downloads[checkpoint.id] = .absent
        }
    }

    var checkpoint: HunchCheckpoint? { catalogue.first { $0.id == checkpointID } ?? catalogue.first }

    var total: Int { counts.values.reduce(0, +) }

    /// Where Hunch stands, for the pane's status and the reminder.
    var status: HunchStatus {
        HunchStatus.of(supported: supported, download: downloads[checkpointID] ?? .absent, training: training)
    }

    /// The head in use, as a file; nil: the checkpoint's own.
    var head: URL? {
        guard let name = record.head, record.checkpoint == checkpointID else { return nil }
        return folder.head(name)
    }

    /// What decisions are logged with: `laya-english`, or `laya-english+english-1900000000` with a trained head.
    var modelName: String {
        let base = "laya-\(checkpointID)"
        guard let name = record.head, record.checkpoint == checkpointID else { return base }
        return base + "+" + name.replacingOccurrences(of: ".safetensors", with: "")
    }

    // MARK: Reading the folder

    /// Reads what is on disk: each checkpoint's state, the folder's size, the training set's counts, the last run.
    func refresh() async {
        guard !fixture else { return }
        let (catalogue, folder) = (catalogue, folder)
        let read = await Task.detached(priority: .utility) {
            var states: [String: HunchDownloadState] = [:]
            var usage = HunchDiskUsage()
            for checkpoint in catalogue {
                states[checkpoint.id] = HunchDownloader.state(checkpoint, folder: folder)
                let size = HunchDownloader.directorySize(folder.checkpoint(checkpoint))
                if size > 0 { usage.checkpoints[checkpoint.id] = size }
            }
            usage.partial = HunchDownloader.directorySize(folder.root.appending(path: ".partial"))
            usage.examples = HunchDownloader.size(of: folder.examples) ?? 0
            usage.heads = HunchDownloader.directorySize(folder.heads)
            let examples = (try? Data(contentsOf: folder.examples)).map(HunchTrainingSet.decode) ?? []
            let record = (try? Data(contentsOf: folder.record)).flatMap {
                try? HunchModel.decoder.decode(HunchLearningRecord.self, from: $0)
            }
            return (states, usage, examples, record)
        }.value
        for (id, state) in read.0 where !(downloads[id]?.isActive ?? false) {
            downloads[id] = state
        }
        usage = read.1
        counts = HunchTrainingSet.counts(read.2)
        heldOut = read.2.count(where: \.heldOut)
        if let record = read.3 { self.record = record }
    }

    // MARK: Download

    /// Downloads (or resumes) a checkpoint. Only ever started by you: a button, or `:hunch.download`.
    func download(_ id: String) {
        guard !fixture, supported, downloadTasks[id] == nil,
              let checkpoint = catalogue.first(where: { $0.id == id })
        else { return }
        let folder = folder
        downloadTasks[id] = Task { [weak self] in
            let report: HunchDownloader.Report = { [weak self] state in
                await self?.set(id, state)
            }
            do {
                try await HunchDownloader.run(checkpoint, folder: folder, report: report)
            } catch is CancellationError {
                self?.set(id, HunchDownloader.state(checkpoint, folder: folder))
            } catch {
                let state = HunchDownloader.state(checkpoint, folder: folder)
                let done = state.fraction.map { Int64($0 * Double(checkpoint.totalSize)) } ?? 0
                self?.set(id, .failed("\(error)", done: done, total: checkpoint.totalSize))
            }
            await self?.downloadEnded(id)
        }
    }

    /// Stops a download; what was fetched stays for the next one.
    func cancel(_ id: String) {
        downloadTasks[id]?.cancel()
    }

    var downloading: [String] { downloadTasks.keys.sorted() }

    /// Deletes a downloaded checkpoint (and a partial download of it), and the head trained on it.
    func delete(_ id: String) async {
        guard !fixture, let checkpoint = catalogue.first(where: { $0.id == id }) else { return }
        cancel(id)
        await runtime.unload()
        let folder = folder
        let headName = record.checkpoint == id ? record.head : nil
        await Task.detached(priority: .utility) {
            try? FileManager.default.removeItem(at: folder.checkpoint(checkpoint))
            try? FileManager.default.removeItem(at: folder.staging(checkpoint))
            // The revision directory's parent, when it is empty now.
            let parent = folder.checkpoint(checkpoint).deletingLastPathComponent()
            if (try? FileManager.default.contentsOfDirectory(atPath: parent.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: parent)
            }
            if let headName { try? FileManager.default.removeItem(at: folder.head(headName)) }
        }.value
        if headName != nil {
            record.head = nil
            saveRecord()
        }
        await refresh()
    }

    private func set(_ id: String, _ state: HunchDownloadState) {
        // A late progress report never overwrites the end of a download.
        if case .ready = downloads[id], state.isActive { return }
        downloads[id] = state
    }

    private func downloadEnded(_ id: String) async {
        downloadTasks[id] = nil
        await refresh()
    }

    // MARK: The training set

    /// Adds `new` to the stored set (a newer label of the same thing replaces the older), within the caps.
    func keep(_ new: [HunchExample]) async {
        guard !fixture else { return }
        let folder = folder
        let kept = await Task.detached(priority: .utility) { () -> [HunchExample] in
            let existing = (try? Data(contentsOf: folder.examples)).map(HunchTrainingSet.decode) ?? []
            let merged = HunchTrainingSet.merge(existing, new)
            let data = HunchTrainingSet.encode(merged)
            if data != (try? Data(contentsOf: folder.examples)) {
                try? FileManager.default.createDirectory(at: folder.learning, withIntermediateDirectories: true)
                try? data.write(to: folder.examples, options: .atomic)
            }
            return merged
        }.value
        counts = HunchTrainingSet.counts(kept)
        heldOut = kept.count(where: \.heldOut)
        usage.examples = Int64(HunchTrainingSet.encode(kept).count)
    }

    // MARK: Training

    /// Starts a run when one is due (`asked`: Retrain now). Stops it when the Mac gets busy, unless you asked for it.
    func trainIfDue(asked: Bool, conditions: @escaping @MainActor () -> HunchConditions) {
        guard !fixture, trainTask == nil, let directory, let checkpoint else {
            if asked, directory == nil { note = "no model downloaded" }
            return
        }
        let due = HunchSchedule.due(
            now: Date(), record: record, examples: total, heldOut: heldOut, conditions: conditions(), asked: asked
        )
        guard due == .train else {
            if case let .wait(reason) = due { note = reason }
            return
        }
        note = nil
        training = .some(nil)
        let (folder, current, runtime, id) = (folder, head, runtime, checkpoint.id)
        let examplesNow = total
        let newHead = folder.head(HunchFolder.headName(checkpoint: id, at: Date()))
        trainTask = Task { [weak self] in
            // Off the main actor and at low priority; the model runs it on its own queue.
            let run = Task.detached(priority: .background) { () -> HunchRuntime.Outcome in
                let examples = (try? Data(contentsOf: folder.examples)).map(HunchTrainingSet.decode) ?? []
                let (train, heldOut) = HunchTrainingSet.split(examples)
                return try await runtime.train(
                    directory: directory, head: current, train: train, heldOut: heldOut, newHead: newHead
                ) { fraction in
                    Task { @MainActor in self?.progress(fraction) }
                }
            }
            // Stops the run as soon as the Mac is busy (or hot, or on battery).
            let watch = Task { @MainActor in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    if let reason = HunchSchedule.shouldStop(conditions(), asked: asked) {
                        self?.note = reason
                        run.cancel()
                        return
                    }
                }
            }
            let result = await run.result
            watch.cancel()
            await self?.finished(result, checkpoint: id, newHead: newHead, examples: examplesNow)
        }
    }

    /// Stops a run in progress; the head in use stays.
    func stopTraining(_ reason: String) {
        guard let trainTask else { return }
        note = reason
        trainTask.cancel()
    }

    private func progress(_ fraction: Double) {
        if training != nil { training = .some(fraction) }
    }

    private func finished(
        _ result: Result<HunchRuntime.Outcome, any Error>, checkpoint: String, newHead: URL, examples: Int
    ) async {
        training = nil
        trainTask = nil
        switch result {
        case let .success(outcome):
            var record = record
            record.trainedAt = Date()
            record.checkpoint = checkpoint
            record.trained = examples - heldOut
            record.heldOut = outcome.after.count
            record.before = outcome.before
            record.after = outcome.after
            record.seconds = outcome.seconds
            record.examplesAtRun = examples
            record.error = nil
            switch outcome.verdict {
            case .adopt:
                record.adopted = true
                record.kept = nil
                record.head = newHead.lastPathComponent
            case let .keep(reason):
                record.adopted = false
                record.kept = reason
            }
            self.record = record
            saveRecord()
            await pruneHeads()
        case let .failure(error):
            if error is CancellationError || (error as? CancellationError) != nil {
                if note == nil { note = "stopped" }
            } else {
                record.error = "\(error)"
                saveRecord()
            }
            try? FileManager.default.removeItem(at: newHead)
        }
        await refresh()
    }

    /// Back to the checkpoint's own head: the trained one is deleted, the training set kept.
    func resetToBase() async {
        guard !fixture else { return }
        stopTraining("stopped: reset")
        await runtime.unload()
        record.head = nil
        record.adopted = nil
        record.kept = nil
        record.before = nil
        record.after = nil
        record.trainedAt = nil
        record.examplesAtRun = 0
        saveRecord()
        await pruneHeads()
        await refresh()
    }

    /// Deletes every head file but the one in use.
    private func pruneHeads() async {
        let (folder, inUse) = (folder, record.head)
        await Task.detached(priority: .utility) {
            let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.heads.path)) ?? []
            for name in HunchFolder.headsToDelete(files, inUse: inUse) {
                try? FileManager.default.removeItem(at: folder.head(name))
            }
        }.value
    }

    private func saveRecord() {
        guard !fixture, let data = try? Self.encoder.encode(record) else { return }
        let folder = folder
        Task.detached(priority: .utility) {
            try? FileManager.default.createDirectory(at: folder.learning, withIntermediateDirectories: true)
            try? data.write(to: folder.record, options: .atomic)
        }
    }

    nonisolated static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    nonisolated static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    // MARK: Fixtures

    /// The pane in one of its states, for shots: no IO.
    func show(
        downloads: [String: HunchDownloadState], counts: [HunchFamily: Int] = [:], heldOut: Int = 0,
        record: HunchLearningRecord = HunchLearningRecord(), training: Double?? = nil, usage: HunchDiskUsage,
        note: String? = nil
    ) {
        for (id, state) in downloads {
            self.downloads[id] = state
        }
        self.counts = counts
        self.heldOut = heldOut
        self.record = record
        self.training = training
        self.usage = usage
        self.note = note
    }
}
