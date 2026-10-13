@testable import HeedCore
import Testing

/// `#expect` cannot call a mutating method inline.
private func observe(
    _ tutor: inout Tutor, _ state: TutorState, key: String? = "x", pending: Bool = false
) -> Tutor.Event {
    tutor.observe(state, key: key, pending: pending)
}

struct TutorTests {
    private func state(_ edit: (inout TutorState) -> Void = { _ in }) -> TutorState {
        var state = TutorState()
        state.rows = 6
        edit(&state)
        return state
    }

    /// Every `{command}` in a lesson's text and keys.
    private func placeholders(_ lesson: TutorLesson) -> [String] {
        var found: [String] = []
        for text in lesson.steps.flatMap({ [$0.say, $0.doneLine] + $0.keys }) {
            var rest = Substring(text)
            while let open = rest.firstIndex(of: "{"), let close = rest[open...].firstIndex(of: "}") {
                found.append(String(rest[rest.index(after: open) ..< close]))
                rest = rest[rest.index(after: close)...]
            }
        }
        return found
    }

    @Test func aNineStepTourAndALessonPerView() {
        #expect(Tutor.tour.steps.count == 9)
        #expect(Tutor.tour.steps.first?.title == "Two modes")
        #expect(Tutor.viewLessons.map(\.id) == [
            "sessions", "start-work", "inbox", "issues", "prs", "repos", "history", "agents", "diff",
        ])
        for lesson in Tutor.viewLessons {
            #expect((2 ... 4).contains(lesson.minutes), "\(lesson.id)")
            #expect(!lesson.steps.isEmpty)
        }
    }

    @Test func everyPlaceholderIsACommandWithADefaultKey() {
        let bound = Set((DefaultKeys.normal + DefaultKeys.scoped.values.flatMap(\.self)).map(\.1))
        for lesson in [Tutor.tour] + Tutor.viewLessons {
            for command in placeholders(lesson) {
                #expect(Commands.spec(CommandInvocation(parsing: command).name) != nil, "\(command) in \(lesson.id)")
                // A card must never show `:command` for want of a key.
                #expect(bound.contains(command), "{\(command)} in \(lesson.id) has no default key")
            }
        }
    }

    @Test func everySpotlightTargetIsARegionName() {
        let regions: Set<String> = [
            "panes", "sidebar", "needsYou", "dialog", "viewTabs", "statusBar", "list", "reader", "pipeline",
            "worktreeTable", "confirm", "historyList", "diffBody",
        ]
        for lesson in [Tutor.tour] + Tutor.viewLessons {
            for step in lesson.steps {
                if let target = step.target { #expect(regions.contains(target), "\(target) in \(lesson.id)") }
            }
        }
    }

    @Test func twoModesNeedsInsertAndBack() {
        var tutor = Tutor(lesson: Tutor.tour, state: state())
        #expect(observe(&tutor, state { $0.mode = .insert }) == .none)
        #expect(observe(&tutor, state()) == .advanced)
        #expect(tutor.step == 1)
        #expect(tutor.justDone?.contains("INSERT") == true)
        // The green line goes with the next key.
        #expect(observe(&tutor, state { $0.cursor = 1 }) == .none)
        #expect(tutor.justDone == nil)
    }

    @Test func aKeyThatChangedNothingNudgesWanderingDoesNot() {
        var tutor = Tutor(lesson: Tutor.tour, state: state())
        #expect(observe(&tutor, state(), key: "j") == .nudged)
        #expect(tutor.nudge == "That was j.")
        #expect(tutor.withNudge("i is the one here.").nudge == "That was j. i is the one here.")
        // g of ga is not wrong yet; a key that moved something is wandering.
        #expect(observe(&tutor, state(), key: "g", pending: true) == .none)
        #expect(observe(&tutor, state { $0.view = "inbox" }, key: "m") == .none)
        #expect(tutor.nudge == nil)
    }

    @Test func movingStepsCompareWithWhereTheyBegan() {
        var tutor = Tutor(lesson: Tutor.tour, step: 1, state: state { $0.cursor = 2 })
        #expect(observe(&tutor, state { $0.cursor = 3 }) == .none)
        #expect(observe(&tutor, state { $0.cursor = 2 }) == .none)
        #expect(observe(&tutor, state { $0.cursor = 4 }) == .advanced)
    }

    @Test func viewsStepWantsTwoViewsAndHome() {
        var tutor = Tutor(lesson: Tutor.tour, step: 6, state: state())
        #expect(observe(&tutor, state { $0.view = "inbox" }) == .none)
        #expect(observe(&tutor, state { $0.view = "sessions" }) == .none)
        #expect(observe(&tutor, state { $0.view = "prs" }) == .none)
        #expect(observe(&tutor, state { $0.view = "sessions" }) == .advanced)
    }

    @Test func skipBackAndFinish() {
        var tutor = Tutor(lesson: Tutor.viewLessons.first { $0.id == "diff" }!, state: state())
        tutor.skip(from: state())
        #expect(tutor.step == 1)
        tutor.back(to: state())
        #expect(tutor.step == 0)
        tutor.restart(at: state())
        #expect(tutor.step == 0)
        for _ in tutor.lesson.steps {
            tutor.skip(from: state())
        }
        #expect(tutor.finished)
        #expect(tutor.current == nil)
        #expect(observe(&tutor, state()) == .none)
        #expect(tutor.keysTaught.count == Set(tutor.lesson.steps.flatMap(\.keys)).count)
    }

    @Test func thePickerStartsWithThisView() {
        var progress = TutorProgress()
        progress.lastLesson = "prs"
        var picker = TutorPicker(view: "sessions", progress: progress)
        #expect(picker.rows.first == .lesson("sessions"))
        #expect(picker.rows[1] == .lesson("tour"))
        #expect(picker.rows.last == .replay("prs"))
        #expect(picker.rows.filter { $0 == .lesson("sessions") }.count == 1)
        #expect(picker.handle(KeyStroke("j")) == .handled)
        #expect(picker.selectedLesson?.id == "tour")
        #expect(picker.handle(KeyStroke("w")) == .handled)
        #expect(picker.selectedWorld == .prStorm)
        #expect(picker.handle(KeyStroke("CR")) == .start(lesson: "tour", world: .prStorm))
        #expect(picker.handle(.escape) == .cancel)
        // A view without a lesson of its own offers the tour first, once.
        let other = TutorPicker(view: "elsewhere", progress: TutorProgress())
        #expect(other.rows.first == .lesson("tour"))
        #expect(other.rows.filter { $0 == .lesson("tour") }.count == 1)
    }

    @Test func lessonsByName() {
        #expect(Tutor.lessonID(named: "PRs") == "prs")
        #expect(Tutor.lessonID(named: "start") == "start-work")
        #expect(Tutor.lessonID(named: "tour") == "tour")
        #expect(Tutor.lessonID(named: "nope") == nil)
        #expect(Tutor.lessonID(forView: "repos") == "repos")
        #expect(Tutor.lessonID(forView: "nope") == "tour")
    }

    @Test func progressResumesWhereALessonWasLeft() {
        var progress = TutorProgress()
        progress.lastLesson = "inbox"
        progress.lastStep = 2
        #expect(progress.resumeStep("inbox") == 2)
        #expect(progress.resumeStep("prs") == 0)
    }

    @Test func worldsAreFakeAndDistinct() {
        #expect(TutorWorld.freshRepos.domain.sessions.isEmpty)
        #expect(!TutorWorld.freshRepos.domain.repos.isEmpty)
        let storm = TutorWorld.prStorm.domain
        #expect(storm.feedback.values.flatMap(\.items).allSatisfy { $0.status == .new || $0.status == .resolved })
        #expect(storm.github.pulls.first?.ref.number == 2841)
    }
}
