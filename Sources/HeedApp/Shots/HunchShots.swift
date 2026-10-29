import Foundation
import HeedCore

/// Settings › Inference & decisions with Hunch chosen, in each of its states, from invented values: no IO, no model.
@MainActor
enum HunchShots {
    enum State {
        case noModel, downloading, ready, learning
    }

    static func prepare(_ model: AppModel, _ state: State) {
        model.applyConfig(source: "[llm]\nagent = \"claude\"\n[decisions]\ndecider = \"hunch\"\n")
        model.llmTests["claude"] = LLMTest(answer: "Hello there!", model: "claude-haiku", seconds: 2.4, cost: 0.00031)
        let hunch = model.hunch
        let english = hunch.catalogue.first { $0.id == "english" }
        let total = english?.totalSize ?? 0
        let size = english.map { [$0.id: $0.totalSize] } ?? [:]
        let now = Clock.now
        let counts: [HunchFamily: Int] = [.attention: 96, .attach: 41, .screens: 187]
        switch state {
        case .noModel:
            hunch.show(downloads: [:], usage: HunchDiskUsage())
        case .downloading:
            let done = Int64(Double(total) * 0.42)
            hunch.show(
                downloads: ["english": .downloading(done: done, total: total, file: "model.safetensors")],
                usage: HunchDiskUsage(partial: done)
            )
        case .ready:
            hunch.show(
                downloads: ["english": .ready], counts: counts, heldOut: 63,
                record: HunchLearningRecord(
                    trainedAt: now.addingTimeInterval(-5 * 3600), checkpoint: "english", trained: 261, heldOut: 63,
                    before: HunchScore(count: 63, correct: 44, loss: 0.82),
                    after: HunchScore(count: 63, correct: 53, loss: 0.47), adopted: true, seconds: 74,
                    head: "english-1700000000.safetensors", examplesAtRun: 324
                ),
                usage: HunchDiskUsage(checkpoints: size, examples: 1_240_000, heads: 52_480_000),
                note: "next run after 20 new examples (6 so far)"
            )
            model.decisionTest = DecisionTest(answer: "done (confidence 93%)", seconds: 0.04)
            model.screenReadings["fixture-pane"] = HunchScreen.Reading(
                state: .waiting, confidence: 0.87, at: now.addingTimeInterval(-120)
            )
        case .learning:
            hunch.show(
                downloads: ["english": .ready], counts: counts.merging([.attention: 118]) { $1 }, heldOut: 68,
                record: HunchLearningRecord(
                    trainedAt: now.addingTimeInterval(-26 * 3600), checkpoint: "english", trained: 240, heldOut: 58,
                    before: HunchScore(count: 58, correct: 40, loss: 0.85),
                    after: HunchScore(count: 58, correct: 39, loss: 0.80), adopted: false,
                    kept: "worse on held-out examples: 67% (39 of 58) against 69% (40 of 58)", seconds: 70,
                    examplesAtRun: 298
                ),
                training: .some(0.35),
                usage: HunchDiskUsage(checkpoints: size, examples: 1_390_000)
            )
        }
    }
}
