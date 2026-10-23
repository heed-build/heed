import Foundation
import HeedCore

/// Start work's smart guesses and what it learns from: the on-device model asked once typing pauses (`SmartGuesses`),
/// and what was guessed against what was chosen, kept in heed.sqlite. Fixtures and the tutor never ask the model, so
/// screenshots and lessons stay the same on every Mac.
extension AppModel {
    /// Start work opened: a scheduler when smart guesses are on and the model can run, and what the model is told.
    func prepareStartWorkSmarts() {
        startWorkAdvice?.cancel()
        startWorkAdvice = nil
        guard config.startWork.smartGuesses, !isFixture, tutor == nil, let advisor = SmartGuesses.advisor() else {
            return
        }
        advisor.prewarm()
        startWorkAdvice = StartWorkAdviceScheduler(advisor: advisor)
        var hints = StartWorkHints.from(sessions: sessions, closed: history)
        hints.about = readmeAbout
        startWork?.hints = hints
        readReadmes()
    }

    /// After every change to the dialog: asks what is open now (nothing, if the question did not change), and drops
    /// a question no longer open. Typing never waits on it.
    func adviseStartWork() {
        guard let form = startWork else {
            startWorkAdvice?.cancel()
            return
        }
        guard let scheduler = startWorkAdvice else { return }
        let question = form.question
        if scheduler.ask(question, deliver: { [weak self] question, advice in
            self?.startWork?.apply(advice, for: question)
        }) != nil {
            startWork?.thinking = true
        } else if question == nil, form.thinking {
            startWork?.thinking = false
        }
    }

    /// The first line of each local repo's README, read off the main actor once per run and kept: what the model is
    /// told a repo is.
    private func readReadmes() {
        let paths = repos.filter { $0.location == .local && readmeAbout[$0.id] == nil }.map { ($0.id, $0.path) }
        guard !paths.isEmpty else { return }
        Task.detached(priority: .userInitiated) {
            var found: [String: String] = [:]
            for (id, path) in paths {
                found[id] = Self.readmeSummary(in: path) ?? ""
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                readmeAbout.merge(found) { _, new in new }
                startWork?.hints.about = readmeAbout
            }
        }
    }

    private nonisolated static func readmeSummary(in path: String) -> String? {
        for name in ["README.md", "README", "readme.md", "README.markdown", "README.rst", "README.txt"] {
            guard let handle = FileHandle(forReadingAtPath: "\(path)/\(name)") else { continue }
            defer { try? handle.close() }
            let data = (try? handle.read(upToCount: 8192)) ?? Data()
            return StartWorkHints.readmeSummary(String(decoding: data, as: UTF8.self))
        }
        return nil
    }

    /// Work started from the dialog: what was guessed and chosen, kept for `[local] keep_days`.
    func recordStartOutcome() {
        guard !isFixture, tutor == nil, let log = eventLog, let outcome = startWork?.outcome(at: Date()) else { return }
        let keepDays = config.local.keepDays
        Task.detached(priority: .utility) { await log.record(outcome, keepDays: keepDays) }
    }

    /// Settings › Agents › Local decisions: how many outcomes are kept. Fixtures keep their invented count.
    func refreshStartOutcomeCount() async {
        guard !isFixture, let log = eventLog else { return }
        startOutcomeCount = try? await log.startOutcomeCount()
    }
}
