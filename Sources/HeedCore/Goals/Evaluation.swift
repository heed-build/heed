import Foundation

/// What a stranger walk judges: the same walk through a fresh clone, seen through a different lens. Each lens is an
/// evaluator (a reviewer whose run is a walk) scoring one of the goal's quality lenses: DX first run and DX API and
/// config score `dx`, the screens and accessibility score `ux`, the docs walk scores `docs`.
public enum EvaluationLens: String, Hashable, Sendable, Codable, CaseIterable, Comparable {
    case dxFirstRun = "dx-first-run"
    case dxApiConfig = "dx-api-config"
    case uxScreens = "ux-screens"
    case accessibility
    case docsWalk = "docs-walk"

    public var title: String {
        switch self {
        case .dxFirstRun: "DX: first run"
        case .dxApiConfig: "DX: API and config"
        case .uxScreens: "UX: the screens"
        case .accessibility: "Accessibility"
        case .docsWalk: "Docs walk"
        }
    }

    /// What it looks at, under its name in the lens picker.
    public var checks: String {
        switch self {
        case .dxFirstRun: "CLI, README, errors"
        case .dxApiConfig: "naming, defaults, surprises"
        case .uxScreens: "flows, keys, empty states"
        case .accessibility: "contrast, keys, screen reader"
        case .docsWalk: "can a newcomer finish the task"
        }
    }

    /// The quality lens its score counts for.
    public var lens: GoalLens {
        switch self {
        case .dxFirstRun, .dxApiConfig: .dx
        case .uxScreens, .accessibility: .ux
        case .docsWalk: .docs
        }
    }

    /// The reviewer kind it runs as.
    public var kind: ReviewerKind {
        switch self {
        case .dxFirstRun, .dxApiConfig: .dxEvaluator
        case .uxScreens, .accessibility: .uxEvaluator
        case .docsWalk: .docsReader
        }
    }

    /// The walk a reviewer kind does when its config names none: the DX evaluator walks a first run, the UX evaluator
    /// the screens; other kinds review.
    public static func defaultWalk(of kind: ReviewerKind) -> EvaluationLens? {
        switch kind {
        case .dxEvaluator: .dxFirstRun
        case .uxEvaluator: .uxScreens
        default: nil
        }
    }

    /// The id of the evaluator heed spawns for it: the kind's own for its default walk (`dx-evaluator`), else one of
    /// its own.
    public var reviewerID: String {
        switch self {
        case .dxFirstRun: ReviewerKind.dxEvaluator.rawValue
        case .uxScreens: ReviewerKind.uxEvaluator.rawValue
        case .dxApiConfig: "dx-evaluator-api"
        case .accessibility: "ux-evaluator-a11y"
        case .docsWalk: "docs-walk"
        }
    }

    public var evaluatorTitle: String {
        switch self {
        case .dxFirstRun: "DX evaluator"
        case .dxApiConfig: "DX evaluator: API and config"
        case .uxScreens: "UX evaluator"
        case .accessibility: "Accessibility evaluator"
        case .docsWalk: "Docs walker"
        }
    }

    /// The stranger it plays, in a sentence or two (the card says it, the run is told it).
    public var persona: String {
        switch self {
        case .dxFirstRun:
            "Plays a developer who has never seen this tool. Works only from the README and the CLI. Writes down "
                + "where it hesitated."
        case .dxApiConfig:
            "Plays a developer wiring this into their own work: its flags, config and API, from the README and the "
                + "CLI's help only. Writes down what surprised it."
        case .uxScreens:
            "Plays someone opening the product for the first time. Uses its screens as the README says to start "
                + "them, and writes down where a flow, a key or an empty state lost it."
        case .accessibility:
            "Plays someone who uses the keyboard only and a screen reader. Starts the product as the README says, "
                + "and writes down what it could not reach, read or tell apart."
        case .docsWalk:
            "Plays a newcomer with the docs open and nothing else. Tries to finish the task from them alone, and "
                + "writes down where the docs ran out."
        }
    }

    /// The marks on the card: what the stranger had.
    public var tags: [String] {
        switch self {
        case .uxScreens, .accessibility: ["fresh clone", "no prior context", "README and the app"]
        case .docsWalk: ["fresh clone", "no prior context", "docs only"]
        case .dxFirstRun, .dxApiConfig: ["fresh clone", "no prior context", "README only"]
        }
    }

    /// The evidence a walk leaves on the goal: DX walks (first run, API, docs) fill the matrix's DX column; UX walks
    /// are evidence of their own.
    public var evidence: GoalEvidence.Kind {
        switch self {
        case .dxFirstRun, .dxApiConfig, .docsWalk: .dx
        case .uxScreens, .accessibility: .ux
        }
    }

    /// What the walk is about, for the model that drafts it.
    public var focus: String {
        switch self {
        case .dxFirstRun: "a developer's first run: install it, run it, do the task, recover from a mistake"
        case .dxApiConfig: "configuring it and using its API or flags for the task: names, defaults, surprises"
        case .uxScreens: "using the product's own screens for the task: flows, keys, empty and error states"
        case .accessibility: "doing the task with the keyboard only and a screen reader: focus, labels, contrast"
        case .docsWalk: "finishing the task from the docs alone, without reading the code"
        }
    }

    /// The walk when no model drafted one: the steps a newcomer takes for this lens.
    public var defaultSteps: [String] {
        switch self {
        case .dxFirstRun:
            [
                "Read the quick start",
                "Install it",
                "Run the first command",
                "Do the goal's task",
                "Make a mistake on purpose",
                "Find out how to recover",
            ]
        case .dxApiConfig:
            [
                "Find the configuration",
                "Change a default",
                "Use the API or flags for the task",
                "Pass a wrong value on purpose",
                "Find out what went wrong",
            ]
        case .uxScreens:
            [
                "Start the app",
                "Find where the task starts",
                "Do the task",
                "Look at an empty state",
                "Undo a step",
            ]
        case .accessibility:
            [
                "Start the app",
                "Reach the task with the keyboard only",
                "Do the task with the keyboard",
                "Read the screen with a screen reader",
                "Check contrast and focus",
            ]
        case .docsWalk:
            [
                "Open the docs' first page",
                "Find the page for the task",
                "Follow it to the end",
                "Look up an error the docs mention",
            ]
        }
    }

    /// The walks a goal needs, from its profile and bars: a first run whenever DX is required, API and config too
    /// for a public API; the screens whenever UX is required (a user-facing goal, or a UX bar you pinned), and
    /// accessibility for a user-facing product; a docs walk when docs are required of a product or a public API.
    public static func required(profile: GoalProfile?, bars: [GoalLens: Double]) -> [EvaluationLens] {
        let profile = profile ?? .unknown
        let shipped = profile.stakes == .product || profile.stakes == .publicAPI
        return allCases.filter { lens in
            switch lens {
            case .dxFirstRun: bars[.dx] != nil
            case .dxApiConfig: bars[.dx] != nil && profile.stakes == .publicAPI
            case .uxScreens: bars[.ux] != nil
            case .accessibility: bars[.ux] != nil && profile.userFacing && shipped
            case .docsWalk: bars[.docs] != nil && shipped
            }
        }
    }

    // MARK: Its area

    /// Whether a change to `path` touches what this walk goes through: the README and docs, the CLI's entry points
    /// and the files that install it for DX; config files too for API and config; screens, styles and views for UX;
    /// Markdown and examples for the docs walk. A heuristic over the path alone.
    public func touches(_ path: String) -> Bool {
        let lower = path.lowercased()
        let name = lower.split(separator: "/").last.map(String.init) ?? lower
        let folders = lower.split(separator: "/").dropLast().map(String.init)
        func inFolder(_ names: Set<String>) -> Bool { folders.contains { names.contains($0) } }
        let readme = name.hasPrefix("readme") || name.hasPrefix("install") || name.hasPrefix("getting-started")
            || name.hasPrefix("quickstart") || name.hasPrefix("contributing")
        let docs = readme || inFolder(["docs", "doc", "documentation"]) || name.hasSuffix(".md")
            || name.hasSuffix(".mdx")
        let entry = Self.entryNames.contains(name) || inFolder(["cli", "cmd", "bin", "commands"])
            || name.hasPrefix("cli.") || name.hasPrefix("main.")
        let config = inFolder(["config", "configuration", "examples", "example", "settings"])
            || name.contains("config") || name.hasSuffix(".schema.json") || name.hasSuffix(".toml")
            || name.hasSuffix(".yml") || name.hasSuffix(".yaml")
        let screens = inFolder(["views", "ui", "components", "pages", "screens", "theme", "styles", "app", "design"])
            || ["css", "scss", "tsx", "jsx", "vue", "svelte", "html", "xib", "storyboard"]
            .contains { name.hasSuffix("." + $0) } || name.hasSuffix("view.swift")
        switch self {
        case .dxFirstRun: return readme || inFolder(["docs", "doc"]) || entry
        case .dxApiConfig: return readme || entry || config
        case .uxScreens, .accessibility: return screens || readme
        case .docsWalk: return docs || inFolder(["examples", "example"])
        }
    }

    /// Files that start or install a tool.
    static let entryNames: Set<String> = [
        "install.sh", "makefile", "package.swift", "package.json", "cargo.toml", "pyproject.toml", "setup.py",
        "go.mod", "dockerfile", "mise.toml", "__main__.py", "main.swift", "main.go", "main.rs", "index.js",
    ]

    public static func < (lhs: EvaluationLens, rhs: EvaluationLens) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}

public extension ReviewerConfig {
    /// The walk it does: the one it was spawned for, else its kind's (`EvaluationLens.defaultWalk`); nil for a
    /// reviewer that reviews, and for a persona spawned as a reviewer (it reviews with the persona's brief).
    var walk: EvaluationLens? { evaluation ?? (persona == nil ? EvaluationLens.defaultWalk(of: kind) : nil) }
}

/// One step of a walk: what the stranger tried, how it went, and how long it took.
public struct WalkStep: Hashable, Sendable, Codable {
    public enum Outcome: String, Hashable, Sendable, Codable, CaseIterable {
        case ok, confusing, stalled, failed

        /// Other words agents use: `passed`, `unclear`, `stuck`, `error`…
        public init?(loose text: String) {
            switch text.lowercased().trimmingCharacters(in: .whitespaces) {
            case "ok", "okay", "pass", "passed", "done", "success", "succeeded", "fine", "smooth": self = .ok
            case "confusing", "confused", "unclear", "hesitated", "slow", "warning": self = .confusing
            case "stalled", "stuck", "hung", "hang", "timeout", "timed out", "waiting": self = .stalled
            case "failed", "fail", "failure", "error", "blocked", "broken", "gave up": self = .failed
            default: return nil
            }
        }

        /// The friction a step that went this way stands for when the walk wrote none for it.
        var implied: Severity? {
            switch self {
            case .ok: nil
            case .confusing: .low
            case .stalled: .med
            case .failed: .high
            }
        }
    }

    public var title: String
    public var outcome: Outcome
    public var seconds: Double?
    public var note: String?

    public init(title: String, outcome: Outcome, seconds: Double? = nil, note: String? = nil) {
        self.title = title
        self.outcome = outcome
        self.seconds = seconds
        self.note = note
    }
}

/// One entry of a walk's friction log: where the stranger got stuck and what would have helped.
public struct Friction: Hashable, Sendable, Codable {
    public var severity: Severity
    /// The step it happened at, 1-based.
    public var step: Int?
    /// A word or two on what it was about: `first build`, `flags`.
    public var area: String?
    public var finding: String
    public var suggestion: String?

    public init(severity: Severity, step: Int? = nil, area: String? = nil, finding: String, suggestion: String? = nil) {
        self.severity = severity
        self.step = step
        self.area = area
        self.finding = finding
        self.suggestion = suggestion
    }

    /// `step 3 · first build`.
    public var place: String {
        [step.map { "step \($0)" }, area].compactMap(\.self).joined(separator: " · ")
    }
}

/// A walk an evaluator made: `evaluation.json`, read leniently, with the steps' times and the friction log.
public struct EvaluationWalk: Hashable, Sendable, Codable {
    public var lens: EvaluationLens
    /// The GOAL.md version its steps were drafted from: re-walks of the same draft are compared for speed.
    public var draftVersion: Int
    public var steps: [WalkStep]
    public var friction: [Friction]
    public var summary: String
    /// The walk's time: the steps' times added up, else what heed measured.
    public var seconds: Double?
    /// What was cloned: `acme/docs-toolkit#2841`, `acme/docs-toolkit`.
    public var source: String

    public init(
        lens: EvaluationLens, draftVersion: Int, steps: [WalkStep], friction: [Friction], summary: String = "",
        seconds: Double? = nil, source: String = ""
    ) {
        self.lens = lens
        self.draftVersion = draftVersion
        self.steps = steps
        self.friction = friction
        self.summary = summary
        self.seconds = seconds ?? Self.total(steps)
        self.source = source
    }

    /// The file's name, in the clone under `.heed/`.
    public static let fileName = "evaluation.json"

    /// The steps' times added up, when every step has one.
    static func total(_ steps: [WalkStep]) -> Double? {
        guard !steps.isEmpty, steps.allSatisfy({ $0.seconds != nil }) else { return nil }
        return steps.reduce(0) { $0 + ($1.seconds ?? 0) }
    }

    /// The friction as objections of its evaluator: the finding is the text, the suggestion its evidence.
    public var raised: [ReviewReport.Raised] {
        friction.map { .init(severity: $0.severity, text: $0.finding, evidence: $0.suggestion) }
    }

    /// `evaluation.json`, read leniently: `steps` or `walk`, each with a `title` (`step`, `name`), an `outcome`
    /// (`result`, `status`, in other words too) and `seconds` (a number, or `1m10`, `70s`, `1:10`); `friction` or
    /// `findings`, each with a `severity`, a `step` (a number or `step 3`), a `finding` (`text`, `problem`) and a
    /// `suggestion` (`fix`). A step that did not go well and has no friction gets one, as bad as it went (confusing
    /// low, stalled med, failed high). Nil when it is not a JSON object or has no steps. `measured`: the walk's time
    /// when the steps have none.
    public static func parse(
        _ data: Data, lens: EvaluationLens, draftVersion: Int, measured: Double? = nil, source: String = ""
    ) -> EvaluationWalk? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        func text(_ value: Any?) -> String? {
            guard let string = value as? String else { return nil }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let list = (object["steps"] ?? object["walk"]) as? [[String: Any]] ?? []
        let steps = list.compactMap { entry -> WalkStep? in
            guard let title = text(entry["title"] ?? entry["step"] ?? entry["name"]) else { return nil }
            let outcome = text(entry["outcome"] ?? entry["result"] ?? entry["status"]).flatMap(WalkStep.Outcome
                .init(loose:)) ?? .ok
            return WalkStep(
                title: title, outcome: outcome,
                seconds: seconds(entry["seconds"] ?? entry["duration"] ?? entry["time"]),
                note: text(entry["note"] ?? entry["notes"])
            )
        }
        guard !steps.isEmpty else { return nil }
        let entries = (object["friction"] ?? object["findings"] ?? object["frictionLog"]) as? [[String: Any]] ?? []
        var friction = entries.compactMap { entry -> Friction? in
            guard let finding = text(entry["finding"] ?? entry["text"] ?? entry["problem"]) else { return nil }
            return Friction(
                severity: text(entry["severity"]).flatMap(Severity.init(loose:)) ?? .med,
                step: step(entry["step"]).flatMap { (1 ... steps.count).contains($0) ? $0 : nil },
                area: text(entry["area"] ?? entry["tag"]),
                finding: finding,
                suggestion: text(entry["suggestion"] ?? entry["fix"])
            )
        }
        let covered = Set(friction.compactMap(\.step))
        for (index, step) in steps.enumerated() where !covered.contains(index + 1) {
            guard let severity = step.outcome.implied else { continue }
            friction.append(Friction(
                severity: severity, step: index + 1, area: nil,
                finding: "\(step.title): \(step.outcome.rawValue)" + (step.note.map { ". \($0)" } ?? "")
            ))
        }
        return EvaluationWalk(
            lens: lens, draftVersion: draftVersion, steps: steps, friction: friction,
            summary: text(object["summary"]) ?? "", seconds: total(steps) ?? measured, source: source
        )
    }

    /// `70`, `"70"`, `"70s"`, `"1m10"`, `"1m 10s"`, `"1:10"`, `"2 min"` → seconds.
    static func seconds(_ value: Any?) -> Double? {
        if let number = value as? Double { return number >= 0 ? number : nil }
        if let number = value as? Int { return number >= 0 ? Double(number) : nil }
        guard var text = (value as? String)?.lowercased().replacingOccurrences(of: " ", with: "") else { return nil }
        if let plain = Double(text) { return plain >= 0 ? plain : nil }
        if text.contains(":") {
            let parts = text.split(separator: ":").compactMap { Double($0) }
            guard parts.count == 2 else { return nil }
            return parts[0] * 60 + parts[1]
        }
        for (word, short) in [
            ("minutes", "m"),
            ("minute", "m"),
            ("mins", "m"),
            ("min", "m"),
            ("seconds", "s"),
            ("second", "s"),
            ("secs", "s"),
            ("sec", "s"),
        ] {
            text = text.replacingOccurrences(of: word, with: short)
        }
        var total = 0.0
        var number = ""
        var any = false
        for character in text {
            if character.isNumber || character == "." {
                number.append(character)
            } else if character == "m" || character == "s" || character == "h" {
                guard let value = Double(number) else { return nil }
                total += value * (character == "h" ? 3600 : character == "m" ? 60 : 1)
                number = ""
                any = true
            } else {
                return nil
            }
        }
        // `1m10`: what follows the minutes is seconds.
        if !number.isEmpty {
            guard let value = Double(number), any else { return nil }
            total += value
        }
        return any ? total : nil
    }

    /// `3`, `"3"`, `"step 3"` → 3.
    static func step(_ value: Any?) -> Int? {
        if let number = value as? Int { return number }
        guard let text = value as? String else { return nil }
        return Int(text.filter(\.isNumber))
    }

    /// `1m10`, `0m06`: a step's time.
    public static func clock(_ seconds: Double?) -> String {
        guard let seconds else { return "–" }
        let whole = Int(seconds.rounded())
        return "\(whole / 60)m" + String(format: "%02d", whole % 60)
    }

    /// `9 min 11 s`: a walk's time.
    public static func span(_ seconds: Double?) -> String {
        guard let seconds else { return "not timed" }
        let whole = Int(seconds.rounded())
        if whole < 60 { return "\(whole) s" }
        return "\(whole / 60) min" + (whole % 60 == 0 ? "" : " \(whole % 60) s")
    }
}

/// The steps a newcomer would take for a goal, drafted by a cheap model once per GOAL.md version and lens, and walked
/// by its evaluator until the next version.
public struct WalkDraft: Hashable, Sendable, Codable {
    public enum Source: String, Hashable, Sendable, Codable {
        /// A model drafted them from GOAL.md.
        case model
        /// No model call (`[llm]` off, or the day's budget spent): the lens's default steps.
        case defaults
    }

    public var reviewer: String
    public var lens: EvaluationLens
    public var goalVersion: Int
    public var steps: [String]
    public var source: Source

    public init(reviewer: String, lens: EvaluationLens, goalVersion: Int, steps: [String], source: Source = .model) {
        self.reviewer = reviewer
        self.lens = lens
        self.goalVersion = goalVersion
        self.steps = steps
        self.source = source
    }
}

public enum WalkDrafter {
    /// What the model reads: the goal's GOAL.md.
    public static func inputs(title: String, doc: String) -> SummaryInputs {
        SummaryInputs(title: title, goal: doc)
    }

    /// The lens, for the model: what the walk is about.
    public static func instructions(_ lens: EvaluationLens) -> String {
        "The walk is about \(lens.focus)."
    }

    /// The `- ` lines of the answer, as steps: 3 to 8, else nil (the lens's defaults are walked instead).
    public static func steps(_ answer: String) -> [String]? {
        var steps: [String] = []
        for item in GoalDoc.bullets(answer.components(separatedBy: "\n")) {
            var step = GoalDoc.oneLine(item.text).trimmingCharacters(in: CharacterSet(charactersIn: " .*_`"))
            if step.isEmpty || step.hasSuffix(":") { continue }
            if step.count > 70 { step = String(step.prefix(69)) + "…" }
            if !steps.contains(step) { steps.append(step) }
        }
        return steps.count >= 3 ? Array(steps.prefix(8)) : nil
    }

    /// The draft a walk uses now: the reviewer's for this GOAL.md version, if one was drafted.
    public static func current(_ draft: WalkDraft?, version: Int) -> WalkDraft? {
        draft.flatMap { $0.goalVersion == version ? $0 : nil }
    }
}

/// An evaluation as the Evaluations pane shows it: one lens, its evaluator (if the goal has one), whether the goal's
/// profile requires it, its bar, its walks and its friction log.
public struct Evaluation: Hashable, Sendable, Identifiable {
    /// A friction entry with what became of it: open, accepted, or fixed (a re-walk no longer met it).
    public struct Row: Hashable, Sendable, Identifiable {
        public var friction: Friction
        public var objection: Objection?

        public var id: String { objection?.id ?? ObjectionMatch.id(friction.finding) }
        public var state: Objection.State { objection?.state ?? .open }
    }

    public var lens: EvaluationLens
    public var evaluator: ReviewerState?
    public var required: Bool
    public var bar: Double?

    public var id: String { lens.rawValue }
    public var walks: [EvaluationWalk] { evaluator?.walks ?? [] }
    public var walk: EvaluationWalk? { walks.last }
    public var score: GoalScore? { walk == nil ? nil : evaluator?.score }

    /// The latest walk's friction (open, then accepted, worst first), then what earlier walks met that this one did
    /// not (fixed).
    public var rows: [Row] {
        guard let evaluator, let walk else { return [] }
        let byText = Dictionary(evaluator.objections.map { ($0.text, $0) }) { first, _ in first }
        var rows = walk.friction.map { Row(friction: $0, objection: byText[$0.finding]) }
        let rank: [Objection.State: Int] = [.open: 0, .acceptedRisk: 1, .fixed: 2]
        rows.sort {
            rank[$0.state]! != rank[$1.state]! ? rank[$0.state]! < rank[$1.state]!
                : $0.friction.severity != $1.friction.severity ? $0.friction.severity < $1.friction.severity
                : ($0.friction.step ?? 0) < ($1.friction.step ?? 0)
        }
        let shown = Set(rows.map(\.id))
        let earlier = Dictionary(walks.dropLast().flatMap(\.friction).map { ($0.finding, $0) }) { _, last in last }
        for objection in evaluator.objections where objection.state == .fixed && !shown.contains(objection.id) {
            let friction = earlier[objection.text] ?? Friction(
                severity: objection.severity, finding: objection.text, suggestion: objection.evidence
            )
            rows.append(Row(friction: friction, objection: objection))
        }
        return rows
    }

    /// Every lens, in order, for a goal's quality.
    public static func all(_ quality: GoalQuality) -> [Evaluation] {
        let bars = quality.lenses.reduce(into: [GoalLens: Double]()) { $0[$1.lens] = $1.bar }
        let required = Set(EvaluationLens.required(profile: quality.profile?.profile, bars: bars))
        return EvaluationLens.allCases.map { lens in
            Evaluation(
                lens: lens, evaluator: quality.live.first { $0.config.walk == lens },
                required: required.contains(lens), bar: bars[lens.lens]
            )
        }
    }
}

public extension GoalScore {
    /// What a re-walk of the same draft that went faster gives back: three times the share of time saved, at most
    /// this.
    static let rewalkCreditCap = 1.5

    /// An evaluator's score: 10, minus each open friction entry's weight by severity (high 3, med 1.5, low 0.5), minus
    /// a quarter of that for each one you accepted, plus credit for a re-walk faster than the walk before it on the
    /// same draft (three times the share of time saved, at most 1.5); clamped to 0–10 and rounded to a tenth.
    static func walk(_ objections: [Objection], seconds: Double?, previous: Double?, steps: Int) -> GoalScore {
        let open = objections.filter { $0.state == .open }
        let accepted = objections.filter { $0.state == .acceptedRisk }
        let openMinus = open.reduce(0) { $0 + $1.severity.weight }
        let acceptedMinus = accepted.reduce(0) { $0 + $1.severity.weight * acceptedShare }
        var credit = 0.0
        var saved = 0.0
        if let seconds, let previous, previous > 0, seconds < previous {
            saved = 1 - seconds / previous
            credit = rounded(min(saved * 3, rewalkCreditCap))
        }
        let value = rounded(min(max(10 - openMinus - acceptedMinus + credit, 0), 10))
        var parts = ["10"]
        if !open.isEmpty {
            parts.append("minus \(GoalBarTable.number(rounded(openMinus))) for "
                + count(open.count, "open friction entry", plural: "open friction entries"))
        }
        if !accepted.isEmpty {
            parts.append("minus \(GoalBarTable.number(rounded(acceptedMinus))) for " + count(
                accepted.count,
                "accepted"
            ))
        }
        if credit > 0 {
            parts.append("plus \(GoalBarTable.number(credit)) for a re-walk \(Int((saved * 100).rounded()))% faster")
        }
        var basis = open.isEmpty && accepted.isEmpty && credit == 0 ? "10: no friction" : parts.joined(separator: ", ")
        basis += ". A walk of \(count(steps, "step", plural: "steps")) in \(EvaluationWalk.span(seconds))."
        return GoalScore(value: value, basis: basis)
    }
}
