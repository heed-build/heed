@testable import HeedCore
import Testing

/// `#expect` cannot call a mutating method inline.
private func observe(_ tutor: inout Tutor, _ state: TutorState) -> Bool {
    tutor.observe(state)
}

struct TutorTests {
    private func state(_ edit: (inout TutorState) -> Void) -> TutorState {
        var state = TutorState()
        state.rows = 6
        edit(&state)
        return state
    }

    @Test func theFirstLessonIsAboutTheViews() {
        var tutor = Tutor()
        #expect(tutor.current.title.contains("Views"))
        for view in ["inbox", "issues", "prs", "repos", "history", "sessions"] {
            #expect(observe(&tutor, state { $0.view = view }))
        }
        #expect(tutor.lessonDone)
        #expect(!tutor.finished)
    }

    @Test func stepsOnlyTickWhenDoneAndInOrder() {
        var tutor = Tutor()
        #expect(!observe(&tutor, state { $0.view = "history" })) // issues of order: inbox comes first
        #expect(tutor.step == 0)
        #expect(observe(&tutor, state { $0.view = "inbox" }))
        #expect(tutor.step == 1)
    }

    @Test func movingStepsCompareWithWhereTheyBegan() {
        var tutor = Tutor(lesson: 1, state: state { $0.cursor = 2 })
        #expect(!observe(&tutor, state { $0.cursor = 2 }))
        #expect(observe(&tutor, state { $0.cursor = 3 })) // j
        #expect(observe(&tutor, state { $0.cursor = 2 })) // k
        #expect(observe(&tutor, state { $0.cursor = 5 })) // G
        #expect(observe(&tutor, state { $0.cursor = 0 })) // gg
        #expect(!observe(&tutor, state { $0.cursor = 1 }))
        #expect(observe(&tutor, state { $0.cursor = 3 })) // 3j from 0
        #expect(tutor.lessonDone)
    }

    @Test func lessonsMoveAndClamp() {
        var tutor = Tutor(lesson: 99)
        #expect(tutor.lesson == tutor.lessons.count - 1)
        tutor.previous(from: TutorState())
        #expect(tutor.lesson == tutor.lessons.count - 2)
        tutor.next(from: TutorState())
        tutor.next(from: TutorState())
        #expect(tutor.lesson == tutor.lessons.count - 1)
        #expect(tutor.step == 0)
    }

    @Test func everyPlaceholderNamesARealCommand() {
        for lesson in Tutor.lessons {
            for text in [lesson.intro] + lesson.steps.map(\.instruction) {
                var rest = Substring(text)
                while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                    let command = String(rest[rest.index(after: open) ..< close])
                    #expect(Commands.spec(command) != nil, "unknown command {\(command)} in \(lesson.title)")
                    rest = rest[rest.index(after: close)...]
                }
            }
        }
    }
}
