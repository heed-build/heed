import Foundation

public extension Fixtures {
    /// Standup reports in the fake world, one Mindmap each. Every word is invented.
    static var standups: [String: [StandupReport]] {
        let now = Clock.now
        func ago(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3600) }
        return [
            "acme": [
                StandupReport(id: "r2", instance: "acme", at: ago(2), from: ago(26), answers: [
                    .init(
                        question: "What did I finish since the last standup?",
                        text: "- Table of contents follows each folder's index file (acme/docs-toolkit#2810, merged)\n"
                            + "- Dropped the flat nav model: slower than the tree on large sites"
                    ),
                    .init(
                        question: "What am I working on next?",
                        text: "- Redirect targets checked against real headings (acme/docs-toolkit#2841)"
                    ),
                    .init(
                        question: "What is blocked or waiting on someone?",
                        text: "- acme/docs-toolkit#2841 waits on 2 review threads"
                    ),
                ]),
                StandupReport(id: "r1", instance: "acme", at: ago(26), from: ago(50), answers: [
                    .init(question: "What did I finish since the last standup?", text: "- nothing to report"),
                ]),
            ],
            "globex": [
                StandupReport(id: "r3", instance: "globex", at: ago(2), from: ago(26), answers: [
                    .init(
                        question: "What is blocked or waiting on someone?",
                        text: "- Flowchart label wrapping stalled: wrapping before measuring broke edge routing"
                    ),
                ]),
            ],
        ]
    }
}
