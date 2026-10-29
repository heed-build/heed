import Foundation

/// How far a goal is, in one place: its done-when criteria met (each with what showed it), its items done, each
/// required lens against its bar, and the confidence ring with what it is made of. `left` is what is still to do, at
/// a glance: the criteria not met and the bars not reached.
public struct GoalProgress: Hashable, Sendable {
    public struct Criterion: Hashable, Sendable {
        public var text: String
        public var met: Bool
        public var evidence: String?
    }

    public var criteria: [Criterion]
    /// Work items (questions and items dropped from a swarm's plan do not count), and those on Done.
    public var itemsDone: Int
    public var itemsTotal: Int
    /// The required lenses with their bars and scores, lowest first among those under their bar.
    public var lenses: [GoalScore.Lens]
    /// The ring: half criteria, half lenses (`GoalScore.confidence`); nil while nothing counts.
    public var confidence: GoalScore?

    public var criteriaMet: Int { criteria.count { $0.met } }
    public var unmet: [Criterion] { criteria.filter { !$0.met } }
    /// The lenses under their bar.
    public var short: [GoalScore.Lens] { lenses.filter { !$0.met } }
    public var barsMet: Int { lenses.count { $0.met } }

    public static func of(
        doc: GoalDoc?, items: [GoalItem], evidence: [GoalEvidence], quality: GoalQuality?
    ) -> GoalProgress {
        let work = items.filter { $0.kind == .work && !SwarmDropped.isDropped($0) }
        let done = work.count { Board.column($0, evidence: evidence) == .done }
        let lenses = (quality?.lenses ?? []).sorted { $0.lens < $1.lens }
        let criteria = (doc?.doneWhen ?? []).map { Criterion(text: $0.text, met: $0.met, evidence: $0.evidence) }
        let met = criteria.count { $0.met }
        return GoalProgress(
            criteria: criteria, itemsDone: done, itemsTotal: work.count, lenses: lenses,
            confidence: quality?.confidence ?? GoalScore.confidence(met: met, total: criteria.count, lenses: lenses)
        )
    }

    /// What is left, in words: no criteria yet, each criterion not met, each lens under its bar.
    public var left: [String] {
        var lines: [String] = []
        if criteria.isEmpty { lines.append("No done-when criteria yet: nothing says when it is done") }
        lines += unmet.map(\.text)
        lines += short.map { lens in
            "\(lens.lens.title) \(lens.score.map(GoalBarTable.number) ?? "–") under its bar \(GoalBarTable.number(lens.bar))"
        }
        return lines
    }

    /// `2/3 criteria · 4/11 items · 1/4 bars`, a part only when it has something to count.
    public var line: String {
        var parts: [String] = []
        parts.append(criteria.isEmpty ? "no criteria" : "\(criteriaMet)/\(criteria.count) criteria")
        if itemsTotal > 0 { parts.append("\(itemsDone)/\(itemsTotal) items") }
        if !lenses.isEmpty { parts.append("\(barsMet)/\(lenses.count) bars") }
        return parts.joined(separator: " · ")
    }
}

/// What a GOAL.md still lacks, by section: an empty or thin statement, nothing out of scope, no done-when criteria, and
/// criteria too vague to check. The GOAL.md pane shows these as prompts where the text would be, so an unfinished
/// goal looks unfinished.
public enum GoalDocGaps {
    public enum Gap: Hashable, Sendable {
        /// No statement at all, or one too short to say for whom and what changes.
        case noStatement, thinStatement
        case noNotTheGoal
        case noDoneWhen
        /// A criterion (by its index) that nothing could check: "faster", "better" with no number or test.
        case vagueCriterion(Int)
    }

    /// Fewer words than this and the statement is thin.
    public static let thinWords = 8

    /// Words that make a criterion a wish unless something measurable is said with them.
    static let vagueWords: Set = [
        "better", "improve", "improved", "improves", "nicer", "cleaner", "faster", "good", "properly", "easier",
        "smoother", "nice", "robust", "works", "well",
    ]

    public static func of(_ doc: GoalDoc) -> [Gap] {
        var gaps: [Gap] = []
        let words = doc.goal.split { $0.isWhitespace }.count
        if words == 0 { gaps.append(.noStatement) } else if words < thinWords { gaps.append(.thinStatement) }
        if doc.notTheGoal.isEmpty { gaps.append(.noNotTheGoal) }
        if doc.doneWhen.isEmpty { gaps.append(.noDoneWhen) }
        for (index, criterion) in doc.doneWhen.enumerated() where isVague(criterion.text) {
            gaps.append(.vagueCriterion(index))
        }
        return gaps
    }

    /// A criterion is vague when it is very short, or leans on a vague word with no number in it.
    public static func isVague(_ text: String) -> Bool {
        let words = text.lowercased().split { !$0.isLetter && !$0.isNumber }
        if words.count < 3 { return true }
        let measured = text.contains { $0.isNumber }
        return !measured && words.contains { vagueWords.contains(String($0)) }
    }

    /// What the pane shows in place of a missing or thin section: a question to answer, not a blank.
    public static func prompt(_ gap: Gap) -> String {
        switch gap {
        case .noStatement: "Not written yet. What changes, and for whom, once this is done? A sentence or two."
        case .thinStatement: "Thin: say who it is for and what is different for them when it is done."
        case .noNotTheGoal: "Nothing ruled out yet. What is out of scope? A line each keeps agents from wandering."
        case .noDoneWhen: "Nothing says when it is done. Lines a test, a PR or a number can check: "
            + "\"the suite runs on each PR\", \"a page loads in under 1 s\"."
        case .vagueCriterion: "vague: what would show it? a test, a number, a page"
        }
    }

    /// The statement and scope gaps: what sharpening is for.
    public static func needsSharpening(_ doc: GoalDoc) -> Bool {
        of(doc).contains { $0 == .noStatement || $0 == .thinStatement || $0 == .noNotTheGoal }
    }
}

/// The steps from a new goal to work on it, in order, each ticked off by what is true of the goal (its GOAL.md, its
/// items, its bars, its mirror, what is on it), never by a click: a step that stops being true shows again.
public enum GoalStep: String, CaseIterable, Hashable, Sendable, Codable {
    case sharpen, doneWhen, work, bars, mirror, start

    public var title: String {
        switch self {
        case .sharpen: "Sharpen it"
        case .doneWhen: "Say when it is done"
        case .work: "Add the work"
        case .bars: "Choose the quality bars"
        case .mirror: "Mirror it to GitHub"
        case .start: "Start the work"
        }
    }

    /// Why it matters, in a sentence.
    public var why: String {
        switch self {
        case .sharpen: "Every agent on the goal reads GOAL.md first. A model suggests what it is and is not; "
            + "each suggestion waits for your yes."
        case .doneWhen: "Done-when lines are what evidence checks off and what the confidence ring counts. "
            + "Without them nothing can say the goal is done."
        case .work: "Items are the pieces of work: the board moves them as sessions, PRs and merges show up."
        case .bars: "Not every goal needs a 10. Bars per lens (code review, tests, docs…) say how good is good "
            + "enough, and reviewers score against them. Look at them, then say they are right or change one."
        case .mirror: "Optional: colleagues follow the goal on GitHub, a meta issue and a sub-issue per item."
        case .start: "Start a session on an item, put one you have on the goal, or let a swarm plan and work it."
        }
    }

    /// The command its button runs, and the words on it.
    public var command: String {
        switch self {
        case .sharpen: "goal.sharpen"
        case .doneWhen: "goal.edit"
        case .work: "goal.item.add"
        case .bars: "goal.reviewers"
        case .mirror: "goal.mirror"
        case .start: "goal.board"
        }
    }

    public var action: String {
        switch self {
        case .sharpen: "sharpen"
        case .doneWhen: "edit GOAL.md"
        case .work: "add an item"
        case .bars: "the bars"
        case .mirror: "mirror"
        case .start: "the board"
        }
    }

    /// Another way to do it, when there is one: a swarm instead of a session, the planner instead of typing.
    public var alternative: (command: String, action: String)? {
        switch self {
        case .work: ("goal.plan", "ask the planner")
        case .start: ("swarm.start", "swarm it")
        default: nil
        }
    }

    /// A step the goal does fine without: it never is the next step.
    public var optional: Bool { self == .mirror }
}

/// A goal's steps with where each stands, and the next one.
public struct GoalGuide: Hashable, Sendable {
    public enum State: Hashable, Sendable {
        case todo
        /// Something waits for you to finish it (suggestions in GOAL.md); the command that gets you there.
        case waiting(String, command: String)
        /// Done, and what shows it.
        case done(String)

        public var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    public struct Step: Hashable, Sendable, Identifiable {
        public var step: GoalStep
        public var state: State
        public var id: GoalStep { step }
    }

    /// What the guide reads of a goal.
    public struct Input: Sendable {
        public var doc: GoalDoc?
        /// The goal's GOAL.md edits, any state.
        public var edits: [GoalEdit]
        public var items: [GoalItem]
        public var links: [GoalLink]
        public var quality: GoalQuality?
        public var mirror: GoalMirrorState
        public var swarms: [GoalSwarm]

        public init(
            doc: GoalDoc?, edits: [GoalEdit] = [], items: [GoalItem] = [], links: [GoalLink] = [],
            quality: GoalQuality? = nil, mirror: GoalMirrorState = .off, swarms: [GoalSwarm] = []
        ) {
            self.doc = doc
            self.edits = edits
            self.items = items
            self.links = links
            self.quality = quality
            self.mirror = mirror
            self.swarms = swarms
        }
    }

    public var steps: [Step]

    /// The first step not done that is not optional; nil once they all are.
    public var next: Step? { steps.first { !$0.step.optional && !$0.state.isDone } }
    public var done: Int { steps.count { $0.state.isDone } }
    /// The steps done now, to tell later whether one went back (`shows`).
    public var doneSteps: Set<GoalStep> { Set(steps.filter(\.state.isDone).map(\.step)) }

    /// Where each step of a goal stands.
    public static func of(_ input: Input) -> GoalGuide {
        GoalGuide(steps: GoalStep.allCases.map { Step(step: $0, state: state(of: $0, input)) })
    }

    static func state(of step: GoalStep, _ input: Input) -> State {
        let doc = input.doc ?? GoalDoc(title: "")
        switch step {
        case .sharpen:
            let sharpened = input.edits.filter { $0.from == "sharpen" }
            let waiting = sharpened.count { $0.state == .proposed }
            if waiting > 0 {
                return .waiting(
                    "\(waiting) suggestion\(waiting == 1 ? "" : "s") wait in GOAL.md", command: "goal.doc"
                )
            }
            if !sharpened.isEmpty {
                let taken = sharpened.count { $0.state == .applied }
                return .done("sharpened: \(taken) of \(sharpened.count) suggestions taken")
            }
            return GoalDocGaps.needsSharpening(doc) ? .todo : .done("GOAL.md says what it is and what it is not")
        case .doneWhen:
            if !doc.doneWhen.isEmpty {
                let count = doc.doneWhen.count
                return .done("\(count) criteri\(count == 1 ? "on" : "a") in Done when")
            }
            let waiting = input.edits.count { $0.section == .doneWhen && $0.state == .proposed }
            if waiting > 0 {
                return .waiting(
                    "\(waiting) done-when line\(waiting == 1 ? "" : "s") wait for your yes", command: "goal.doc"
                )
            }
            return .todo
        case .work:
            let work = input.items.count { $0.kind == .work }
            return work > 0 ? .done("\(work) item\(work == 1 ? "" : "s") on the board") : .todo
        case .bars:
            // Yours only: heed working the profile out sets bars, but the step waits for you to look at them.
            guard let quality = input.quality else { return .todo }
            if !quality.pins.isEmpty {
                return .done("bars pinned for " + quality.pins.keys.sorted().map(\.title).joined(separator: ", "))
            }
            let now = Dictionary(uniqueKeysWithValues: quality.lenses.map { ($0.lens, $0.bar) })
            if let mine = quality.profiles.last(where: { $0.source == .you }) {
                if mine.bars == now {
                    return .done("you confirmed \(now.count) bar\(now.count == 1 ? "" : "s")")
                }
                return .waiting("the bars changed since you confirmed them", command: "goal.reviewers")
            }
            if quality.profile != nil {
                return .waiting(
                    "heed set \(now.count) bar\(now.count == 1 ? "" : "s") from GOAL.md: confirm or change them",
                    command: "goal.reviewers"
                )
            }
            return .todo
        case .mirror:
            return input.mirror.on ? .done("mirrored to \(input.mirror.repo ?? "GitHub")") : .todo
        case .start:
            if let swarm = input.swarms.first { return .done("swarm \(swarm.number) \(swarm.status.rawValue)") }
            let on = input.links.count { $0.kind == .session || $0.kind == .chat || $0.kind == .run }
            return on > 0 ? .done("\(on) session\(on == 1 ? "" : "s") on it") : .todo
        }
    }

    /// Whether the card shows: there is a next step, and either it was never hidden or a step done when it was hidden
    /// is not done any more.
    public func shows(hiddenWith: Set<GoalStep>?) -> Bool {
        guard next != nil else { return false }
        guard let hiddenWith else { return true }
        return !hiddenWith.isSubset(of: doneSteps)
    }
}

/// The sharpener in the fake world (fixtures, shots, the tutor): what a model would answer for a goal, made up from
/// its GOAL.md, so `goal.sharpen` does the same thing there with no model call. Its suggestions go through
/// `GoalEditProposer` like a real answer.
public enum GoalSharpenFixture {
    public static func answer(title: String, doc: GoalDoc) -> String {
        var edits: [[String: String]] = []
        if GoalDocGaps.of(doc).contains(.noStatement) || GoalDocGaps.of(doc).contains(.thinStatement) {
            edits.append([
                "section": "goal", "op": "replace",
                "text": "\(title): what changes for the people who use it, said in a way a test can check.",
            ])
        }
        if doc.notTheGoal.isEmpty {
            edits.append([
                "section": "notTheGoal", "op": "add", "text": "Anything beyond what \(title) needs",
            ])
        }
        if doc.doneWhen.isEmpty {
            edits.append([
                "section": "doneWhen", "op": "add",
                "text": "A test covers each case the goal names, and runs on each PR",
            ])
        }
        edits.append(["section": "openQuestions", "op": "add", "text": "Who checks the result before it ships?"])
        let data = (try? JSONSerialization.data(withJSONObject: ["edits": edits], options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// The panes of a goal, as the tab strip in Goals' header shows them: each with the command (and so the key) that
/// opens it, and a count where something waits. The swarm's panes show only when the goal has a swarm.
public enum GoalPaneTabs {
    public struct Tab: Hashable, Sendable, Identifiable {
        /// `GoalsBrowser.Pane`'s raw value.
        public var pane: String
        public var title: String
        /// What opens it; `goal.overview` for the overview.
        public var command: String
        /// Something waits there: proposals, open objections, questions for you.
        public var count: Int
        public var id: String { pane }
    }

    public struct Counts: Hashable, Sendable {
        public var proposals = 0
        public var objections = 0
        public var gaps = 0
        public var questions = 0
        public var needsYou = 0
        public var asks = 0

        public init(
            proposals: Int = 0, objections: Int = 0, gaps: Int = 0, questions: Int = 0, needsYou: Int = 0,
            asks: Int = 0
        ) {
            self.proposals = proposals
            self.objections = objections
            self.gaps = gaps
            self.questions = questions
            self.needsYou = needsYou
            self.asks = asks
        }
    }

    /// `swarm`: the goal has a swarm; `approved`: its plan was approved (its agents and map have something to show).
    public static func tabs(swarm: Bool, approved: Bool, counts: Counts = Counts()) -> [Tab] {
        var tabs = [
            Tab(pane: "overview", title: "Overview", command: "goal.overview", count: 0),
            Tab(pane: "doc", title: "GOAL.md", command: "goal.doc", count: counts.proposals),
            Tab(pane: "board", title: "Board", command: "goal.board", count: 0),
            Tab(pane: "reviewers", title: "Reviewers", command: "goal.reviewers", count: counts.objections),
            Tab(pane: "personas", title: "Personas", command: "goal.personas", count: counts.gaps),
            Tab(pane: "evaluations", title: "Evaluations", command: "goal.evaluations", count: 0),
        ]
        if swarm {
            tabs.append(Tab(pane: "plan", title: "Swarm", command: "goal.swarm", count: counts.questions))
        }
        if swarm, approved {
            tabs.append(Tab(pane: "agents", title: "Agents", command: "goal.agents", count: counts.needsYou))
            tabs.append(Tab(pane: "map", title: "Map", command: "goal.map", count: 0))
        }
        tabs.append(Tab(pane: "unassigned", title: "Unassigned", command: "goal.unassigned", count: counts.asks))
        return tabs
    }

    /// The breadcrumb: `Goals › title › pane` (the overview names no pane; Unassigned belongs to no goal).
    public static func crumb(goal: String?, pane: String) -> [String] {
        if pane == "unassigned" { return ["Goals", "Unassigned"] }
        guard let goal else { return ["Goals"] }
        let title = tabs(swarm: true, approved: true).first { $0.pane == pane }?.title
        return ["Goals", goal] + (pane == "overview" ? [] : [title ?? pane])
    }
}
