import Foundation
@testable import HeedCore
import Testing

struct NotificationAllowTests {
    @Test func allowAnswersOnlyWhatTheNotificationShowed() {
        #expect(NotificationAllow.action(shown: ["a1"], waiting: ["a1", "a2"]) == .answer(["a1"]))
        // What it showed was answered already; a newer ask is not it.
        #expect(NotificationAllow.action(shown: ["a1"], waiting: ["a2"]) == .show)
        #expect(NotificationAllow.action(shown: ["a1"], waiting: []) == .show)
        // It was about a prompt in the pane: Return there, unless an ask reached heed since.
        #expect(NotificationAllow.action(shown: [], waiting: []) == .screen)
        #expect(NotificationAllow.action(shown: [], waiting: ["a3"]) == .show)
    }
}
