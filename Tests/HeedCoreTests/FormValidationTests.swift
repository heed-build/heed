import Foundation
@testable import HeedCore
import Testing

/// Forms say what is wrong next to the field it is about: every validator returns notes naming their field, and the
/// app's forms draw them with `FieldNoteView` instead of the status bar.
struct FormValidationTests {
    // MARK: Field notes

    @Test func whatIsMissingWaitsForATryWhatIsWrongShowsAtOnce() {
        let notes = FormChecks.goal(title: " ", tracker: "not a repo")
        #expect(notes.map(\.field) == ["title", "tracker"])
        #expect(notes.note(for: "title", tried: false) == nil)
        #expect(notes.note(for: "title", tried: true)?.text == "a goal needs a title")
        #expect(notes.note(for: "tracker", tried: false)?.text == "not a repo is not org/name: clear it for no tracker")
        // The confirm button knows why from the start, before anything is drawn red.
        #expect(notes.blocking?.field == "title")
        #expect(FormChecks.goal(title: "Faster builds", tracker: "").isEmpty)
        #expect(FormChecks.goal(title: "Faster builds", tracker: "acme/goals").isEmpty)
    }

    @Test func aFieldShowsItsProblemBeforeACheckOrAFineWord() {
        let notes = [
            FieldNote("repos", "fine", tone: .fine), FieldNote("repos", "checking", tone: .checking),
            FieldNote("repos", "wrong"),
        ]
        #expect(notes.note(for: "repos")?.text == "wrong")
        #expect(Array(notes.prefix(2)).note(for: "repos")?.text == "checking")
        #expect(Array(notes.prefix(2)).blocking?.text == "checking")
        #expect([FieldNote("repos", "fine", tone: .fine)].blocking == nil)
        #expect(notes.note(for: "title") == nil)
    }

    @Test func theSwarmFormNamesTheFieldOfEachProblem() {
        let empty = FormChecks.swarm(newGoal: true, title: "", repos: [], needsRepo: true, entry: nil, place: nil)
        #expect(empty.map(\.field) == ["title", "repos"])
        #expect(empty.allSatisfy { $0.untilTried })
        #expect(empty[1].text.hasPrefix("pick a repo for the lead to start in"))
        // The goal under the cursor has its title; the fake world starts no lead, so needs no repo.
        #expect(FormChecks.swarm(newGoal: false, title: "", repos: [], needsRepo: false, entry: nil, place: nil)
            .isEmpty)
        let entry = FieldNote("repos", "checking acme/widgets on GitHub…", tone: .checking)
        let typed = FormChecks.swarm(
            newGoal: false, title: "", repos: [], needsRepo: true, entry: entry, place: "@devbox does not answer"
        )
        #expect(typed == [entry, FieldNote("where", "the swarm cannot run there: @devbox does not answer")])
        // A problem blocks ahead of a check still running.
        #expect(typed.blocking?.field == "where")
    }

    @Test func thePlanEditorsTextIsNeeded() {
        #expect(FormChecks.steering("  ", answer: true).map(\.text) == ["type the answer"])
        #expect(FormChecks.steering("", answer: false).first?.field == "text")
        #expect(FormChecks.steering("split the docs task", answer: false).isEmpty)
    }

    @Test func aTasksProblemsNameTheirField() {
        let tasks = [SwarmTask(id: "g/a", title: "A", phase: "P")]
        func field(_ edit: (inout SwarmTaskForm) -> Void) -> String? {
            var form = SwarmTaskForm(tasks[0], in: tasks)
            edit(&form)
            guard case let .failure(problem) = form.task(id: "g/a", in: tasks, hosts: ["devbox"]) else { return nil }
            return problem.note.field
        }
        #expect(field { $0.title = "" } == "title")
        #expect(field { $0.estimate = "soon" } == "estimate")
        #expect(field { $0.after = "9.9" } == "after")
        #expect(field { $0.after = "g/a" } == "after")
        #expect(field { $0.host = "gpu" } == "host")
        #expect(field {
            $0.agent = "claude"
            $0.model = "has spaces"
        } == "owner")
        #expect(field { _ in } == nil)
    }

    // MARK: Any repo, typed

    @Test func aTypedRepoIsReadAsOwnerNameAURLOrAPath() {
        func parsed(_ text: String) -> RepoEntry.Parsed? {
            guard case let .success(value)? = RepoEntry.parse(text) else { return nil }
            return value
        }
        let widgets = RepoEntry.Parsed.slug(Repo(org: "acme", name: "widgets"))
        #expect(parsed("acme/widgets") == widgets)
        #expect(parsed("  acme/widgets ") == widgets)
        #expect(parsed("https://github.com/acme/widgets") == widgets)
        #expect(parsed("https://github.com/acme/widgets.git") == widgets)
        #expect(parsed("git@github.com:acme/widgets.git") == widgets)
        #expect(parsed("github.com/acme/widgets/") == widgets)
        #expect(parsed("initech/tps.reports_2") == .slug(Repo(org: "initech", name: "tps.reports_2")))
        #expect(parsed("~/code/widgets") == .path("~/code/widgets"))
        #expect(parsed("/Users/you/src/widgets") == .path("/Users/you/src/widgets"))
        #expect(parsed("./widgets") == .path("./widgets"))
        #expect(RepoEntry.parse("") == nil)
        #expect(RepoEntry.parse("   ") == nil)
    }

    @Test func aMisspelledRepoSaysWhatIsWrongOnTheReposField() {
        func problem(_ text: String) -> FieldNote? {
            guard case let .failure(note)? = RepoEntry.parse(text) else { return nil }
            return note
        }
        #expect(problem("widgets")?.text == "widgets is not owner/name, a GitHub URL or a path (~/code/x)")
        #expect(problem("acme/widgets/extra")?.field == "repos")
        #expect(problem("/widgets") == nil) // a path
        #expect(problem("acme/")?.text == "owner/name needs a name after the /")
        #expect(problem("-acme/widgets")?.text == "-acme cannot be a GitHub owner: letters, digits and single dashes")
        #expect(problem("ac--me/widgets") != nil)
        #expect(problem("acme corp/widgets") != nil)
        #expect(problem("acme/wid gets")?.text == "wid gets cannot be a repo's name: letters, digits, - _ and .")
        #expect(problem("acme/..") != nil)
        #expect(problem(String(repeating: "a", count: 40) + "/x") != nil)
        #expect(problem(String(repeating: "a", count: 39) + "/x") == nil)
    }

    @Test func aTypedRepoIsCheckedAgainstWhatHeedKnowsThenGitHub() {
        let widgets = RepoEntry.Parsed.slug(Repo(org: "acme", name: "widgets"))
        func note(
            _ parsed: RepoEntry.Parsed,
            here: [String] = [],
            known: [String] = [],
            lookups: [String: RepoEntry.Lookup] = [:],
            local: Bool = true
        ) -> FieldNote {
            RepoEntry.note(
                parsed, place: local ? "this Mac" : "@devbox", local: local, here: here, known: known,
                lookups: lookups, clonesInto: "~/code"
            )
        }
        // Checked out here: case does not matter on GitHub.
        #expect(note(widgets, here: ["Acme/Widgets"]) == FieldNote(
            "repos", "Acme/Widgets is on this Mac: ↩ adds it", tone: .fine
        ))
        // Seen elsewhere (a host, a PR): it exists, and is cloned when the swarm starts.
        #expect(note(widgets, known: ["acme/widgets"]).tone == .fine)
        #expect(note(widgets, known: ["acme/widgets"]).text.contains("clones it into ~/code/widgets on this Mac"))
        // Unknown: asked of GitHub, and ⌘↩ waits for the answer.
        #expect(note(widgets).tone == .checking)
        #expect(note(widgets, lookups: ["acme/widgets": .checking]).text == "checking acme/widgets on GitHub…")
        #expect(note(widgets, lookups: ["acme/widgets": .found(Repo(org: "Acme", name: "widgets"))]).tone == .fine)
        #expect(note(widgets, lookups: ["acme/widgets": .missing]) == FieldNote(
            "repos", "no repo acme/widgets on GitHub (or gh cannot see it)"
        ))
        #expect(note(widgets, lookups: ["acme/widgets": .failed("gh is not signed in (gh auth login)")]).text
            == "could not check acme/widgets on GitHub: gh is not signed in (gh auth login)")
        // A path is read on this Mac only.
        let path = RepoEntry.Parsed.path("~/src/widgets")
        #expect(note(path, local: false).tone == .problem)
        #expect(note(path).tone == .checking)
        #expect(note(path, lookups: [path.key: .missing]).text == "no git checkout at ~/src/widgets")
        #expect(note(path, lookups: [path.key: .found(Repo(org: "acme", name: "widgets"))]).tone == .fine)
    }

    @Test func whatAFineEntryAddsAndWhatIsAskedOfGitHub() {
        let widgets = RepoEntry.Parsed.slug(Repo(org: "acme", name: "widgets"))
        #expect(RepoEntry.picked(widgets, here: ["Acme/Widgets"], known: [], lookups: [:]) == "Acme/Widgets")
        #expect(RepoEntry.picked(widgets, here: [], known: [], lookups: [:]) == nil)
        #expect(RepoEntry.picked(widgets, here: [], known: [], lookups: [
            "acme/widgets": .found(Repo(org: "acme", name: "Widgets")),
        ]) == "acme/Widgets")
        #expect(RepoEntry.needsLookup(widgets, here: [], known: [], lookups: [:]))
        #expect(!RepoEntry.needsLookup(widgets, here: [], known: ["acme/widgets"], lookups: [:]))
        #expect(!RepoEntry.needsLookup(widgets, here: [], known: [], lookups: ["acme/widgets": .missing]))
        #expect(RepoEntry.needsLookup(.path("~/x"), here: [], known: [], lookups: [:]))
        #expect(RepoEntry.cloneArguments(Repo(org: "acme", name: "widgets"), into: "~/code")
            == ["repo", "clone", "acme/widgets", "~/code/widgets"])
        #expect(RepoEntry.repo("acme/widgets") == Repo(org: "acme", name: "widgets"))
    }

    @Test func ghsAnswerIsReadAsFoundMissingOrWhyNot() {
        #expect(GitHub.lookup(ProcessResult(status: 0, stdout: "Acme/widgets\n", stderr: ""))
            == .found(Repo(org: "Acme", name: "widgets")))
        #expect(GitHub.lookup(ProcessResult(
            status: 1, stdout: "", stderr: "GraphQL: Could not resolve to a Repository with the name 'acme/nope'."
        )) == .missing)
        #expect(GitHub.lookup(ProcessResult(
            status: 4, stdout: "", stderr: "To get started with GitHub CLI, please run:  gh auth login"
        )) == .failed("gh is not signed in (gh auth login)"))
        #expect(GitHub.lookup(nil) == .failed("gh did not answer"))
    }

    // MARK: Start work's repo search takes any repo too

    private static let records = ["docs-toolkit", "markgraph"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private static func searching(_ text: String) -> StartWorkForm {
        var form = StartWorkForm(repos: records, settings: .default)
        form.pickRepo(at: form.repoChoices.count)
        for char in text {
            _ = form.handle(KeyStroke(String(char)))
        }
        return form
    }

    @Test func startWorksSearchReadsAnUnknownRepoAndClonesItOnStart() {
        var form = Self.searching("acme/widgets")
        #expect(form.repoSearch?.matches.isEmpty == true)
        #expect(form.entryToLookUp == .slug(Repo(org: "acme", name: "widgets")))
        #expect(form.searchNote?.tone == .checking)
        // ↩ waits while it is checked.
        _ = form.handle(KeyStroke("CR"))
        #expect(form.typedRepos.isEmpty)
        #expect(form.repoSearch != nil)
        form.entryLookups["acme/widgets"] = .missing
        #expect(form.searchNote == FieldNote("repos", "no repo acme/widgets on GitHub (or gh cannot see it)"))
        form.entryLookups["acme/widgets"] = .found(Repo(org: "acme", name: "widgets"))
        #expect(form.entryToLookUp == nil)
        #expect(form.searchNote?.tone == .fine)
        #expect(form.searchNote?.text.hasSuffix("when the work starts") == true)
        _ = form.handle(KeyStroke("CR"))
        #expect(form.repoSearch == nil)
        #expect(form.typedRepos == ["acme/widgets"])
        #expect(form.selectedRepos.contains("acme/widgets"))
        #expect(form.plan.repos.isEmpty)
        // Cloned: the record joins the form and the plan.
        form.adopt(RepoRecord(repo: Repo(org: "acme", name: "widgets"), path: "/code/widgets"))
        #expect(form.typedRepos.isEmpty)
        #expect(form.plan.repos.map(\.repo.slug) == ["acme/widgets"])
    }

    @Test func startWorksSearchSaysWhatIsWrongWithATypedRepo() {
        #expect(Self.searching("widgets!").searchNote?
            .text == "widgets! is not owner/name, a GitHub URL or a path (~/code/x)")
        // A repo heed knows is matched as before: no note, nothing to ask.
        let known = Self.searching("o/markgraph")
        #expect(known.searchNote == nil)
        #expect(known.entryToLookUp == nil)
        // Seen elsewhere (a PR, a host): no need to ask.
        var seen = Self.searching("acme/widgets")
        seen.knownSlugs = ["Acme/Widgets"]
        #expect(seen.entryToLookUp == nil)
        _ = seen.handle(KeyStroke("CR"))
        #expect(seen.typedRepos == ["Acme/Widgets"])
        // The clone's record, spelled as git reads it, takes the typed one's place.
        var cloned = seen
        cloned.adopt(RepoRecord(repo: Repo(org: "acme", name: "widgets"), path: "/code/widgets"))
        #expect(cloned.typedRepos.isEmpty)
        #expect(cloned.selectedRepos.contains("acme/widgets"))
        seen.dropTyped("Acme/Widgets")
        #expect(seen.typedRepos.isEmpty)
        // A path is looked at on disk.
        #expect(Self.searching("~/src/widgets").entryToLookUp == .path("~/src/widgets"))
    }

    // MARK: The app's forms (read from source: the app target cannot be linked here)

    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func source(_ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// A function's body: from its declaration to the next declaration at the same indent.
    private static func body(of function: String, in text: String) -> String? {
        guard let start = text.range(of: function) else { return nil }
        let rest = text[start.upperBound...]
        let next = ["\n    func ", "\n    private func ", "\n    /// ", "\n    @discardableResult", "\n}\n"]
            .compactMap { rest.range(of: $0)?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<next])
    }

    /// Up to where the form closes, a submit says nothing in the status bar: what is wrong is drawn under its field.
    @Test func formsDoNotRouteValidationThroughTheStatusBar() throws {
        let checks: [(file: String, function: String, until: String?)] = [
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "func submitSwarmForm()", "goals.swarmForm = nil"),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "private func savePlanDraft(", nil),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "private func cloneSwarmRepos(", nil),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "func addSwarmRepoEntry()", nil),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "func setSwarmRepoEntry(", nil),
            ("Sources/HeedApp/Model/AppModel+Goals.swift", "func submitGoalForm()", "goals.form = nil"),
            ("Sources/HeedApp/Model/AppModel.swift", "private func lookUpStartWorkEntry()", nil),
            ("Sources/HeedApp/Model/AppModel.swift", "private func cloneStartWorkRepos(", nil),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "func lookUpRepoEntry(", nil),
            ("Sources/HeedApp/Model/AppModel+Swarm.swift", "func cloneRepo(", nil),
        ]
        for check in checks {
            let text = try Self.source(check.file)
            let body = try #require(Self.body(of: check.function, in: text), "\(check.function) not found")
            let checked = check.until.flatMap { body.components(separatedBy: $0).first } ?? body
            #expect(!checked.contains("say("), "\(check.function) reports through the status bar")
            #expect(!checked.contains("flash"), "\(check.function) reports through the status bar")
        }
        // swarm.host only flashes when there is no form to show it in.
        let host = try #require(Self.body(
            of: "func setSwarmHost(", in: Self.source("Sources/HeedApp/Model/AppModel+Swarm.swift")
        ))
        let afterForm = host.components(separatedBy: "guard var form = goals.swarmForm").last ?? ""
        let afterGuard = afterForm.split(separator: "\n", maxSplits: 1).last ?? ""
        #expect(!afterGuard.isEmpty)
        #expect(!afterGuard.contains("say("))
    }

    /// The validators' words never reach the status bar from anywhere in the app.
    @Test func validationWordsAreNeverFlashed() throws {
        let words = [
            // (`:goal.tracker x` still flashes "is not org/name": a command, with no form to show it in.)
            "needs a title", "pick a repo", "type the answer", "say what the lead should change",
            "cannot run there", "not owner/name", "on GitHub (or gh",
        ]
        let folder = Self.root.appendingPathComponent("Sources/HeedApp")
        let files = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil)?
            .compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" } ?? []
        #expect(files.count > 20)
        for file in files {
            let lines = try String(contentsOf: file, encoding: .utf8).components(separatedBy: "\n")
            for line in lines where line.contains("say(") || line.contains("flash =") {
                for word in words {
                    #expect(!line.contains(word), "\(file.lastPathComponent): \(line)")
                }
            }
        }
    }

    /// Each form draws its notes and greys its ⌘↩ with the reason on hover, with the one shared component.
    @Test func formsDrawTheirNotesWithTheSharedComponent() throws {
        let components = try Self.source("Sources/HeedApp/Theme/Components.swift")
        #expect(components.contains("struct FieldNoteView: View"))
        #expect(components.contains("struct ConfirmHint: View"))
        // Each field's note, drawn where the field is.
        let views: [(file: String, view: String, fields: [String])] = [
            ("Sources/HeedApp/Views/GoalsView.swift", "struct GoalFormView", [
                "FieldNoteView(note: notes.note(for: \"title\"", "FieldNoteView(note: notes.note(for: \"tracker\"",
            ]),
            ("Sources/HeedApp/Views/GoalPlanView.swift", "struct SwarmFormView", [
                "FieldNoteView(note: notes.note(for: \"title\"", "FieldNoteView(note: notes.note(for: RepoEntry.field",
                "FieldNoteView(note: whereNote)", "repoEntryField(form)",
            ]),
            ("Sources/HeedApp/Views/GoalPlanView.swift", "private struct PlanEditor", [
                "note: \"title\", notes", "note: \"host\", notes", "note: \"estimate\", notes",
                "note: \"after\", notes", "note: \"text\", notes", "notes.note(for: \"owner\"",
                "FieldNoteView(note: notes.note(for: note",
            ]),
        ]
        // Start work's repo search says what a typed repo is, and the clone, under the repo field.
        let startWork = try Self.source("Sources/HeedApp/Views/StartWorkView.swift")
        #expect(startWork.contains("repoSearch(search, note: form.searchNote)"))
        #expect(startWork.contains("FieldNoteView(note: note)"))
        #expect(startWork.contains("FieldNoteView(note: form.cloneNote)"))
        #expect(startWork.contains("ForEach(form.typedRepos"))
        for (file, view, fields) in views {
            let text = try Self.source(file)
            let start = try #require(text.range(of: view), "\(view) not found")
            let rest = text[start.upperBound...]
            let end = rest.range(of: "\n}\n")?.lowerBound ?? rest.endIndex
            let body = rest[..<end]
            for field in fields {
                #expect(body.contains(field), "\(view) does not draw \(field)")
            }
            #expect(body.contains("ConfirmHint("), "\(view)'s ⌘↩ is not a ConfirmHint")
            #expect(!body.contains("KeyHint(keys: \"<D-CR>\""), "\(view) keeps a plain ⌘↩ hint")
        }
    }
}
