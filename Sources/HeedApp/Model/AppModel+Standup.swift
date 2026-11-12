import AppKit
import Foundation
import HeedCore

/// History's Standup: a report per Mindmap on the days `[standup]` names, each question answered by a cheap model
/// from that Mindmap alone.
extension AppModel {
    func startStandup() {
        guard !isFixture else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(60))
            guard let self else { return }
            for instance in mindmap.instances {
                await standup.replace(mindmap.reports(instance), for: instance)
            }
            while !Task.isCancelled {
                await writeDueStandups()
                try? await Task.sleep(for: .seconds(600))
            }
        }
    }

    /// Every Mindmap whose report is due and that had work in its range.
    private func writeDueStandups() async {
        guard config.standup.enabled, config.llm.enabled else { return }
        let now = Date()
        for instance in mindmap.instances {
            let last = standup.reports[instance]?.first?.at
            guard StandupSchedule.due(now: now, last: last, settings: config.standup) else { continue }
            await writeStandup(instance, now: now, priority: .background)
        }
    }

    /// One report for `instance`: each question answered from its Mindmap's work since `from`.
    func writeStandup(_ instance: String, now: Date = Date(), priority: LLMRequest.Priority) async {
        guard !standup.writing.contains(instance), !config.standup.questions(for: instance).isEmpty else { return }
        standup.writing.insert(instance)
        defer { standup.writing.remove(instance) }
        let from = StandupSchedule.from(now: now, last: standup.reports[instance]?.first?.at, settings: config.standup)
        let inputs = StandupInputs.make(
            instance: instance, tree: mindmap.tree(instance), ledger: ledger.entries, from: from, now: now
        )
        var answers: [StandupReport.Answer] = []
        for question in config.standup.questions(for: instance) {
            let text = await inputs.known.isEmpty ? "- nothing to report" : (try? summarizer.summarize(
                kind: .standup, inputs: inputs, instructions: "The question: \(question)", caller: "standup.answer",
                priority: priority
            )) ?? "- could not be written (see :log)"
            answers.append(.init(question: question, text: text))
        }
        let report = StandupReport(
            id: "\(Int(now.timeIntervalSince1970))", instance: instance, at: now, from: from, answers: answers
        )
        standup.add(report)
        await mindmap.save(report)
        notifyStandup(report)
    }

    private func notifyStandup(_ report: StandupReport) {
        flash = "standup for \(MindmapInstance.title(report.instance)) is ready (History › Standup)"
        let first = report.answers.first.map { "\($0.question) \($0.text)" } ?? ""
        Notifier.shared.announceStandup(
            instance: report.instance, title: "Standup for \(MindmapInstance.title(report.instance))",
            body: String(first.replacingOccurrences(of: "\n", with: " ").prefix(180))
        )
    }

    /// A standup notification's Open: History › Standup on that org's report.
    func showStandup(instance: String) {
        view = .standup
        standup.instance = instance
        standup.setCursor(0)
    }

    func performStandup(_ command: CommandInvocation) {
        let plain = command.arguments.first == "plain"
        switch command.name {
        case "standup.run":
            guard config.llm.enabled else { return say("standup reports need model calls ([llm])") }
            let instance = standup.instance
            say("writing the standup for \(MindmapInstance.title(instance))")
            Task { await writeStandup(instance, priority: .interactive) }
        case "standup.copy", "standup.copy.all":
            guard let report = standup.selected else { return say("no report here") }
            let only = command.name == "standup.copy" ? standup.question : nil
            let text = report.text(markdown: !plain, only: only)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            say("copied " + (only == nil ? "the report" : "the answer") + (plain ? " as plain text" : ""))
        case "standup.question": standup.cycleQuestion()
        case "standup.org.next": standup.cycleInstance(by: 1, among: mindmap.instances)
        case "standup.org.prev": standup.cycleInstance(by: -1, among: mindmap.instances)
        default: break
        }
    }
}
