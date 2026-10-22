import Foundation
@testable import HeedCore
import Testing

struct QuietHoursTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-10-22 at `hour`:`minute` UTC.
    private func time(_ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 10, day: 22, hour: hour, minute: minute))!
    }

    @Test func parses() {
        #expect(QuietHours(parsing: "22:00-07:00") == QuietHours(start: 22 * 60, end: 7 * 60))
        #expect(QuietHours(parsing: " 09:30 - 17:15 ")?.description == "09:30-17:15")
        for bad in ["", "22-07", "22:00", "24:00-07:00", "22:60-07:00", "7:00-9:00", "22:00-22:00", "a:bc-07:00"] {
            #expect(QuietHours(parsing: bad) == nil, "\(bad)")
        }
    }

    @Test func acrossMidnight() {
        let quiet = QuietHours(parsing: "22:00-07:00")!
        #expect(quiet.contains(time(22), calendar: utc))
        #expect(quiet.contains(time(3), calendar: utc))
        #expect(quiet.contains(time(6, 59), calendar: utc))
        #expect(!quiet.contains(time(7), calendar: utc))
        #expect(!quiet.contains(time(21, 59), calendar: utc))
    }

    @Test func withinADay() {
        let quiet = QuietHours(parsing: "12:00-13:30")!
        #expect(quiet.contains(time(12), calendar: utc) && quiet.contains(time(13, 29), calendar: utc))
        #expect(!quiet.contains(time(13, 30), calendar: utc) && !quiet.contains(time(11, 59), calendar: utc))
    }

    @Test func configDecodes() {
        #expect(HeedConfig.default.attention.quiet == nil)
        #expect(ConfigLoader.decode(ConfigLoader.defaultSource).config?.attention == AttentionSettings())
        let (config, problems) = ConfigLoader.decode("[attention]\nquiet = \"23:00-06:30\"\n")
        #expect(problems.isEmpty)
        #expect(config?.attention.quiet == QuietHours(start: 23 * 60, end: 6 * 60 + 30))
        let bad = ConfigLoader.decode("[attention]\nquiet = \"late\"\n")
        #expect(bad.problems.map(\.path) == ["attention.quiet"])
        #expect(bad.config?.attention.quiet == nil)
    }

    // MARK: Notices in quiet hours

    private let start = Date(timeIntervalSince1970: 1000)
    private let settings = NotificationSettings(graceSeconds: 30, reminderMinutes: 15)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    private func enter(_ notices: inout Notices, _ id: String, after seconds: TimeInterval = 0) {
        notices.note(
            id: id, title: "t-\(id)", agent: "claude", from: .working, to: ObservedState(.blocked),
            settings: settings, at: at(seconds)
        )
    }

    @Test func nothingInQuietHoursNorWhenTheyEnd() {
        var notices = Notices()
        enter(&notices, "a")
        #expect(notices.drain(at: at(33), quiet: true) == nil)
        #expect(notices.stage(of: "a") == .done)
        #expect(notices.next == nil)
        #expect(notices.drain(at: at(33 + 15 * 60 + 3)) == nil)
    }

    @Test func aReminderDueInQuietHoursIsDropped() {
        var notices = Notices()
        enter(&notices, "a")
        #expect(notices.drain(at: at(33)) != nil)
        #expect(notices.drain(at: at(33 + 15 * 60 + 3), quiet: true) == nil)
        #expect(notices.next == nil)
    }

    @Test func afterQuietHoursNewChangesNotifyAgain() {
        var notices = Notices()
        enter(&notices, "a")
        _ = notices.drain(at: at(33), quiet: true)
        enter(&notices, "b", after: 100)
        #expect(notices.drain(at: at(133))?.session == "b")
        notices.note(
            id: "a", title: "t-a", agent: "claude", from: .blocked, to: ObservedState(.working), settings: settings,
            at: at(200)
        )
        enter(&notices, "a", after: 300)
        #expect(notices.drain(at: at(333))?.session == "a")
    }
}
