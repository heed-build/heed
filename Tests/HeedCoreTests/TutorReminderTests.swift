import Foundation
@testable import HeedCore
import Testing

struct TutorReminderTests {
    @Test func theTourFirstThenTheViewsLesson() {
        var progress = TutorProgress()
        #expect(progress.reminder(view: "prs")?.lesson == "tour")
        #expect(progress.reminder(view: "prs")?.text == "Take the tour")
        progress.done.insert("tour")
        #expect(progress.reminder(view: "prs")?.lesson == "prs")
        #expect(progress.reminder(view: "prs")?.text == "PRs lesson")
        progress.done.insert("prs")
        #expect(progress.reminder(view: "prs") == nil)
    }

    @Test func aLessonLeftHalfwayComesFirst() {
        var progress = TutorProgress()
        progress.lastLesson = "inbox"
        progress.lastStep = 1
        let reminder = progress.reminder(view: "prs")
        #expect(reminder?.lesson == "inbox")
        #expect(reminder?.text.hasPrefix("Resume the Inbox · 2/") == true)
        progress.lastLesson = "tour"
        #expect(progress.reminder(view: "prs")?.text.hasPrefix("Resume the tour · 2/9") == true)
    }

    @Test func hiding() {
        var progress = TutorProgress()
        progress.hidden.insert("tour")
        #expect(progress.reminder(view: "prs")?.lesson == "prs")
        progress.hidden.insert("all")
        #expect(progress.reminder(view: "prs") == nil)
    }

    @Test func progressSavedBeforeRemindersStillLoads() throws {
        let old = #"{"done":["tour"],"lastLesson":"prs","lastStep":2}"#
        let progress = try JSONDecoder().decode(TutorProgress.self, from: Data(old.utf8))
        #expect(progress.done == ["tour"])
        #expect(progress.lastStep == 2)
        #expect(progress.hidden.isEmpty)
    }
}
