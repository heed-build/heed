import Foundation
@testable import HeedCore
import Testing

struct StandupTests {
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// Wednesday 2027-01-13 at `hour`:`minute` UTC.
    private func wednesday(_ hour: Int, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: 2027, month: 1, day: 13, hour: hour, minute: minute))!
    }

    private var settings: StandupSettings {
        var settings = StandupSettings()
        settings.enabled = true
        settings.days = [2, 4, 6] // mon, wed, fri
        settings.at = 8 * 60 + 40
        return settings
    }

    @Test func aReportIsDueOnceItsSlotHasPassedAndOnlyOnce() {
        #expect(!StandupSchedule.due(
            now: wednesday(8, 30),
            last: wednesday(9) - 2 * 86400,
            settings: settings,
            calendar: calendar
        ))
        #expect(StandupSchedule.due(
            now: wednesday(8, 45),
            last: wednesday(9) - 2 * 86400,
            settings: settings,
            calendar: calendar
        ))
        #expect(!StandupSchedule.due(
            now: wednesday(15),
            last: wednesday(8, 41),
            settings: settings,
            calendar: calendar
        ))
        // Thursday is not a standup day: Wednesday's slot is the last one.
        #expect(!StandupSchedule.due(
            now: wednesday(9) + 86400,
            last: wednesday(8, 41),
            settings: settings,
            calendar: calendar
        ))
        // Asleep through Friday's and Monday's: one report when heed next looks.
        #expect(StandupSchedule.due(
            now: wednesday(9) + 6 * 86400,
            last: wednesday(8, 41),
            settings: settings,
            calendar: calendar
        ))
        var off = settings
        off.enabled = false
        #expect(!StandupSchedule.due(now: wednesday(9), last: nil, settings: off, calendar: calendar))
    }

    @Test func aReportCoversSinceTheLastOneOrTheDaysAsked() {
        let now = wednesday(9)
        #expect(StandupSchedule.from(now: now, last: wednesday(0), settings: settings) == wednesday(0))
        var days = settings
        days.rangeDays = 2
        #expect(StandupSchedule.from(now: now, last: wednesday(0), settings: days) == now - 2 * 86400)
        #expect(StandupSettings.minutes("08:40") == 520 && StandupSettings.minutes("25:00") == nil)
    }

    @Test func aReportCopiesAsMarkdownOrPlainTextWholeOrOneAnswer() {
        let report = StandupReport(id: "r", instance: "acme", at: wednesday(9), from: wednesday(0), answers: [
            .init(question: "Done?", text: "- **Merged** acme/docs#1"),
            .init(question: "Next?", text: "- Redirects"),
        ])
        #expect(report.text(markdown: true) == "**Done?**\n\n- **Merged** acme/docs#1\n\n**Next?**\n\n- Redirects")
        #expect(report.text(markdown: false, only: "Done?") == "Done?\n- Merged acme/docs#1")
    }

    @Test func aReportReadsOnlyItsOwnMindmapsWorkInRange() {
        let recent = LedgerEntry(
            id: "e1", title: "fix toc", repos: ["acme/docs"], startedAt: wednesday(2), summary: "Index order wins"
        )
        let old = LedgerEntry(id: "e2", title: "old work", repos: ["acme/docs"], startedAt: wednesday(0) - 9 * 86400)
        let tree = MindmapTree([
            MindNode(id: "c", kind: .campaign, title: "Docs nav", createdAt: wednesday(0)),
            MindNode.work(recent, parent: "c", now: wednesday(2)), MindNode.work(old, parent: "c", now: wednesday(2)),
        ])
        let inputs = StandupInputs.make(
            instance: "acme", tree: tree, ledger: ["e1": recent, "e2": old], from: wednesday(0), now: wednesday(9)
        )
        #expect(inputs.known.first == "work [Docs nav] fix toc (active): Index order wins")
        #expect(!inputs.known.contains { $0.contains("old work") })
        #expect(inputs.title == "Standup for acme")
    }
}
