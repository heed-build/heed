import Foundation
import HeedCore
import Hunch

/// Hunch's model in memory: loaded on the first decision, with the trained head in use, and unloaded after a while
/// without one (it holds about 1.8 GB). Training runs on the same model, so a decision waits for a run to finish or
/// stop. Everything here stays on this Mac.
actor HunchRuntime {
    private var model: DecisionModel?
    private var directory: URL?
    private var head: URL?
    private var lastUsed = Date.distantPast
    private var unloader: Task<Void, Never>?

    /// Unloaded after this long without a decision.
    static let idleUnload: Duration = .seconds(10 * 60)

    /// The model for `directory` with `head` (nil: the checkpoint's own), loading or switching as needed.
    private func model(directory: URL, head: URL?) async throws -> DecisionModel {
        if let model, self.directory == directory {
            if self.head != head {
                if let head { try await model.loadHead(from: head) } else { try await model.resetHead() }
                self.head = head
            }
            return model
        }
        let model = try await DecisionModel(directory: directory, options: .init(head: head))
        self.model = model
        self.directory = directory
        self.head = head
        return model
    }

    /// Answers heed's questions, mapped to Hunch's and back.
    func answer(
        directory: URL, head: URL?, state: String, questions: [String: HeedCore.Question]
    ) async throws -> [String: HeedCore.Answer] {
        let model = try await model(directory: directory, head: head)
        let answers = try await model.answer(state: state, questions: questions.mapValues(Self.question))
        touch()
        return answers.mapValues(Self.answer)
    }

    /// How a training run went.
    struct Outcome: Sendable {
        var before: HunchScore
        var after: HunchScore
        var verdict: HunchAdopt.Verdict
        var seconds: Double
    }

    /// Trains a new head from the checkpoint's own on `train`, judges it and the head in use on `heldOut`, and keeps
    /// the new one (written to `newHead`) only when `HunchAdopt` says so; otherwise the head in use is put back.
    /// Cancelling stops between steps and puts the head in use back.
    func train(
        directory: URL, head current: URL?, train: [HunchExample], heldOut: [HunchExample], newHead: URL,
        progress: @escaping @Sendable (Double) -> Void
    ) async throws -> Outcome {
        let started = Date()
        let model = try await model(directory: directory, head: current)
        let held = heldOut.map(Self.example)
        let before = try await Self.score(model.evaluate(held))
        do {
            try await model.resetHead()
            head = nil
            try await model.trainHead(on: train.map(Self.example), options: Self.training) { step in
                progress(Double(step.step) / Double(max(1, step.steps)))
            }
            let after = try await Self.score(model.evaluate(held))
            let verdict = HunchAdopt.verdict(before: before, after: after)
            if verdict == .adopt {
                try FileManager.default.createDirectory(
                    at: newHead.deletingLastPathComponent(), withIntermediateDirectories: true
                )
                try await model.saveHead(to: newHead, metadata: [
                    "heed.examples": String(train.count), "heed.held_out": String(heldOut.count),
                ])
                try await model.loadHead(from: newHead)
                head = newHead
            } else {
                try await restore(model, current)
            }
            touch()
            return Outcome(
                before: before, after: after, verdict: verdict, seconds: Date().timeIntervalSince(started)
            )
        } catch {
            try? await restore(model, current)
            throw error
        }
    }

    /// Back to `current`, or the checkpoint's own head.
    private func restore(_ model: DecisionModel, _ current: URL?) async throws {
        if let current { try await model.loadHead(from: current) } else { try await model.resetHead() }
        head = current
    }

    /// Frees the model now (a deleted checkpoint, Reset).
    func unload() async {
        unloader?.cancel()
        await model?.unload()
        model = nil
        directory = nil
        head = nil
    }

    private func touch() {
        lastUsed = Date()
        unloader?.cancel()
        unloader = Task { [weak self] in
            try? await Task.sleep(for: Self.idleUnload)
            guard !Task.isCancelled else { return }
            await self?.unload()
        }
    }

    // MARK: heed's types and Hunch's

    /// Three passes at a small learning rate: enough to move the head toward your labels without forgetting what the
    /// checkpoint knew.
    static let training = TrainingOptions(epochs: 3, learningRate: 5e-5, batchSize: 8, seed: 1)

    static func question(_ question: HeedCore.Question) -> Hunch.Question {
        switch question {
        case let .choice(instructions, options): .choice(
                instructions: instructions,
                options: options.map { Option($0) }
            )
        case let .score(instructions, levels): .score(instructions: instructions, levels: levels)
        case let .noul(instructions): .noul(instructions: instructions)
        }
    }

    static func answer(_ answer: Hunch.Answer) -> HeedCore.Answer {
        HeedCore.Answer(
            choice: answer.choice, score: answer.score, probability: answer.probability,
            probabilities: answer.probabilities, confidence: answer.calibratedConfidence
        )
    }

    static func example(_ example: HunchExample) -> TrainingExample {
        TrainingExample(
            state: example.state, question: question(example.question), answer: example.answer,
            weight: Float(example.weight)
        )
    }

    static func score(_ evaluation: Hunch.Evaluation) -> HunchScore {
        HunchScore(count: evaluation.count, correct: evaluation.correct, loss: evaluation.meanLoss)
    }

    /// Hunch's pinned checkpoints, as heed's catalogue.
    static var catalogue: [HunchCheckpoint] {
        HunchCatalogue.make([Checkpoint.english, Checkpoint.multilingual].map { checkpoint in
            (
                checkpoint.name, checkpoint.repository, checkpoint.revision,
                checkpoint.files.map { HunchCheckpoint.File(path: $0.path, size: $0.size, sha256: $0.sha256) }
            )
        })
    }
}
