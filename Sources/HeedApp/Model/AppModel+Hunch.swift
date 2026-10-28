import Foundation
import HeedCore

/// Hunch as a decider (`[decisions] decider = "hunch"`), its checkpoints, and learning from your corrections
/// (`[hunch] learn`). Pure rules live in HeedCore (`HunchRouting`, `HunchTrainingSet`, `HunchSchedule`, `HunchAdopt`);
/// this wires them to the stores and the model.
extension AppModel {
    /// The Decider for `.hunch`: Hunch for what it takes, the rest to Apple's on-device model or a model call
    /// (`HunchRouting`). Each part writes its own `decide` row.
    func hunchDecider(caller: String, priority: LLMRequest.Priority) -> any Decider {
        let hunchReady = hunch.status.modelReady
        let localReady = localModel.ready
        let modelCalls = config.llm.enabled
        var deciders: [DecisionRoute: any Decider] = [.local: localDecider(caller: caller)]
        if modelCalls {
            deciders[.model] = LLMDecider(caller: caller, priority: priority) { [weak self] request in
                guard let self else { throw LLMError.disabled }
                return try await runLLM(request)
            }
        }
        if hunchReady, let directory = hunch.directory {
            let (runtime, head) = (hunch.runtime, hunch.head)
            deciders[.hunch] = HunchDecider(caller: caller, model: hunch.modelName) { state, questions in
                try await runtime.answer(directory: directory, head: head, state: state, questions: questions)
            }
        }
        return RoutedDecider(deciders: deciders) { questions in
            HunchRouting.routes(questions, hunchReady: hunchReady, localReady: localReady, modelCalls: modelCalls)
        }
    }

    /// Whether `[hunch] learn` is in effect.
    var hunchLearns: Bool { config.hunch.learns(modelReady: hunch.status.modelReady) }

    // MARK: Commands

    /// `hunch.download [checkpoint]`: downloads (or resumes) a checkpoint, the configured one by default.
    func downloadHunch(_ id: String?) {
        let id = id ?? config.hunch.effectiveCheckpoint
        guard let checkpoint = hunch.catalogue.first(where: { $0.id == id }) else {
            return flash = "no checkpoint \(id): \(hunch.catalogue.map(\.id).joined(separator: ", "))"
        }
        guard hunch.supported else { return flash = "Hunch needs a Mac with Apple silicon" }
        guard !isFixture else { return flash = "fixtures download nothing" }
        if hunch.downloads[id] == .ready { return flash = "\(checkpoint.title) is already downloaded" }
        hunch.download(id)
        flash = "downloading \(checkpoint.title) (\(HunchCatalogue.size(checkpoint.totalSize)), \(checkpoint.license))"
    }

    /// `hunch.cancel [checkpoint]`: stops a download; Download resumes it.
    func cancelHunchDownload(_ id: String?) {
        guard let id = id ?? hunch.downloading.first else { return flash = "nothing is downloading" }
        hunch.cancel(id)
        flash = "download stopped; :hunch.download resumes it"
    }

    /// `hunch.delete [checkpoint]`: deletes a downloaded checkpoint and the head trained on it.
    func deleteHunchModel(_ id: String?) {
        let id = id ?? config.hunch.effectiveCheckpoint
        guard hunch.catalogue.contains(where: { $0.id == id }) else { return flash = "no checkpoint \(id)" }
        guard !isFixture else { return flash = "fixtures delete nothing" }
        Task { await hunch.delete(id) }
        flash = "deleting \(id)"
    }

    /// `hunch.retrain`: a run now, skipping the counts and the idle wait (never on battery or a hot Mac).
    func retrainHunch() {
        guard !isFixture else { return flash = "fixtures train nothing" }
        guard hunch.status.modelReady else { return flash = "Hunch has no model yet (:hunch.download)" }
        guard hunch.trainTask == nil else { return flash = "Hunch is already learning" }
        Task {
            await harvestHunchExamples()
            hunch.trainIfDue(asked: true) { MacConditions.now }
            flash = hunch.trainTask != nil ? "Hunch is learning from your corrections" : (hunch.note ?? "not now")
        }
    }

    /// `hunch.reset`: back to the checkpoint's own head; the training set stays.
    func resetHunch() {
        guard !isFixture else { return flash = "fixtures have nothing to reset" }
        Task { await hunch.resetToBase() }
        flash = "Hunch is back to its checkpoint's own head"
    }

    // MARK: Learning

    /// At launch: reads the folder, then every ten minutes gathers new corrections (hourly) and trains when due.
    func startHunch() {
        guard !isFixture else { return }
        hunch.checkpointID = config.hunch.effectiveCheckpoint
        Task { [weak self] in
            await self?.hunch.refresh()
            // Give the launch a few minutes before reading the stores.
            try? await Task.sleep(for: .seconds(180))
            var lastHarvest = Date.distantPast
            while !Task.isCancelled {
                guard let self else { return }
                if hunchLearns {
                    if Date().timeIntervalSince(lastHarvest) >= 3600 {
                        await harvestHunchExamples()
                        lastHarvest = Date()
                    }
                    hunch.trainIfDue(asked: false) { MacConditions.now }
                } else if hunch.trainTask != nil {
                    hunch.stopTraining("stopped: learning is off")
                }
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Gathers the training set from what heed recorded: Attention's labels and decide rows, goal attach decisions
    /// you answered, and labelled screen snapshots. Read off the main actor; nothing is asked of you.
    func harvestHunchExamples() async {
        guard !isFixture, hunchLearns else { return }
        var filter = CallFilter()
        filter.kinds = [.decide]
        filter.limit = 50000
        let rows = await (try? CallLog.active?.store.calls(filter)) ?? []
        let labels = rows.filter { $0.command == "label" }
        let decided = rows.filter { $0.command == "decide" && $0.caller == "attention.rank" }
        let attach = await (try? goals.ops?.decisions(limit: 5000)) ?? []
        let titles = Dictionary(goals.snapshot.goals.map { ($0.id, $0.title) }) { first, _ in first }
        let screens = await (try? eventLog?.screenSnapshots(limit: 20000)) ?? []
        let examples = await Task.detached(priority: .utility) {
            HunchTrainingSet.attention(labels: labels, decisions: decided)
                + HunchTrainingSet.attach(attach, goalTitles: titles) + HunchTrainingSet.screens(screens)
        }.value
        await hunch.keep(examples)
    }
}
