import Foundation
import HeedCore
import Observation

/// History's Standup: each Mindmap's reports, newest first, the one shown, and what narrows it.
@MainActor
@Observable
final class StandupModel {
    private(set) var reports: [String: [StandupReport]] = [:]
    var instance = MindmapInstance.personal
    private(set) var cursor = 0
    /// Only this question's answers (`t` cycles); nil: every question.
    var question: String?
    /// Reports being written now, by instance.
    var writing: Set<String> = []

    init(fixture: Bool) {
        guard fixture else { return }
        reports = Fixtures.standups
        instance = reports.keys.sorted().first ?? MindmapInstance.personal
    }

    var instances: [String] {
        let all = Set(reports.keys).union([instance])
        return all.filter { $0 != MindmapInstance.personal }.sorted()
            + (all.contains(MindmapInstance.personal) ? [MindmapInstance.personal] : [])
    }

    var rows: [StandupReport] { reports[instance] ?? [] }
    var selected: StandupReport? { rows.indices.contains(cursor) ? rows[cursor] : nil }

    func setCursor(_ index: Int) { cursor = min(max(index, 0), max(rows.count - 1, 0)) }

    func replace(_ list: [StandupReport], for instance: String) {
        reports[instance] = list.sorted { $0.at > $1.at }
    }

    func add(_ report: StandupReport) {
        replace([report] + (reports[report.instance] ?? []).filter { $0.id != report.id }, for: report.instance)
    }

    func cycleInstance(by step: Int, among all: [String]) {
        let list = Array(Set(all + instances)).sorted { a, b in
            a == MindmapInstance.personal ? false : b == MindmapInstance.personal ? true : a < b
        }
        guard let index = list.firstIndex(of: instance), list.count > 1 else { return }
        instance = list[(index + step + list.count) % list.count]
        cursor = 0
    }

    /// The questions the shown reports answer, for `t`.
    var questions: [String] {
        var seen: [String] = []
        for answer in rows.flatMap(\.answers) where !seen.contains(answer.question) {
            seen.append(answer.question)
        }
        return seen
    }

    func cycleQuestion() {
        let all = questions
        guard !all.isEmpty else { return }
        if let question, let index = all.firstIndex(of: question) {
            self.question = index + 1 < all.count ? all[index + 1] : nil
        } else {
            question = all.first
        }
    }
}
