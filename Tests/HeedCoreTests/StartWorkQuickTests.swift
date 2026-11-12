import Foundation
@testable import HeedCore
import Testing

/// Start work as a quick starter: one repo, a kind that picks the prefix, names without links or repo names.
struct StartWorkQuickTests {
    private let records = ["docs-builder", "docs-website", "markgraph"].map {
        RepoRecord(repo: Repo(org: "acme", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func press(_ notation: String, into form: inout StartWorkForm) throws {
        for stroke in try KeyNotation.parse(notation) {
            _ = form.handle(stroke)
        }
    }

    @Test func kindsAndPrefixesAreTwoNamesForOneChoice() {
        #expect(WorkKind(prefix: "feature") == .feat)
        #expect(WorkKind(prefix: "bump") == .chore)
        #expect(WorkKind(prefix: "perf") == .refactor)
        #expect(WorkKind(prefix: "mine") == nil)
        #expect(WorkKind.fix.prefix(in: .default) == "fix")
        #expect(WorkKind.feat.prefix(in: .default) == "feature")
        let only = BranchPrefixes(prefixes: ["feat": ["add"]], defaultPrefix: "")
        #expect(WorkKind.feat.prefix(in: only) == "feat")
        #expect(WorkKind.docs.prefix(in: only) == "docs")
    }

    @Test func theKindIsReadFromThePrompt() {
        #expect(StartWorkForm(repos: records, settings: .default, prompt: "fix the anchors").kind == .fix)
        #expect(StartWorkForm(repos: records, settings: .default, prompt: "bump swift to 6.2").kind == .chore)
        #expect(StartWorkForm(repos: records, settings: .default, prompt: "investigate slow deploys").kind == .plan)
        #expect(StartWorkForm(repos: records, settings: .default, prompt: "release commands").kind == .feat)
    }

    @Test func choosingAKindPutsItsPrefixOnTheName() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix the anchors")
        #expect(form.name == "fix/anchors")
        try press("<Esc>j", into: &form)
        #expect(form.field == .kind)
        try press("h", into: &form)
        #expect(form.kind == .feat)
        #expect(form.name == "feature/anchors")
        // Typing more keeps the chosen kind.
        form.focus(field: .prompt, edit: true)
        try press("<Space>again", into: &form)
        #expect(form.kind == .feat)
        #expect(form.name == "feature/anchors-again")
        #expect(form.plan.kind == .feat)
    }

    @Test func aNameYouTypedKeepsItsPrefixWhenTheKindChanges() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "fix the anchors")
        form.focus(field: .worktree, edit: true)
        try press("<C-u>mine", into: &form)
        form.pickKind(.docs)
        #expect(form.name == "mine")
        #expect(form.kind == .docs)
    }

    @Test func linksAndRepoNamesStayOutOfTheName() {
        let named = StartWorkForm(
            repos: records, settings: .default, prompt: "docs-builder, look at these release commands"
        )
        #expect(named.name == "feature/look-these-release-commands")
        let slug = StartWorkForm(
            repos: records, settings: .default, prompt: "in acme/markgraph render arrowheads"
        )
        #expect(slug.name == "feature/render-arrowheads")
        let linked = StartWorkForm(
            repos: records, settings: .default,
            prompt: "https://github.com/acme/docs-builder/pull/12 broke the redirects"
        )
        #expect(linked.name == "feature/broke-redirects")
        // A prompt that is nothing but a repo's name still gets a name.
        #expect(!StartWorkForm(repos: records, settings: .default, prompt: "markgraph").name.isEmpty)
    }

    @Test func aNameAlreadyTakenInTheRepoGetsANumber() {
        let form = StartWorkForm(
            repos: records, settings: .default, prompt: "fix anchors in markgraph",
            takenBranches: ["acme/markgraph": ["fix/anchors", "fix/anchors-2"]]
        )
        #expect(form.selectedRepos == ["acme/markgraph"])
        #expect(form.name == "fix/anchors-3")
        // Elsewhere the plain name is free.
        let other = StartWorkForm(
            repos: records, settings: .default, prompt: "fix anchors in docs-website",
            takenBranches: ["acme/markgraph": ["fix/anchors"]]
        )
        #expect(other.name == "fix/anchors")
    }

    @Test func pickingAnotherRepoReplacesTheFirst() throws {
        var form = StartWorkForm(repos: records, settings: .default, prompt: "markgraph arrows")
        #expect(form.selectedRepos == ["acme/markgraph"])
        let other = form.repoChoices.firstIndex { $0.repo.id == "acme/docs-website" } ?? -1
        form.pickRepo(at: other)
        #expect(form.selectedRepos == ["acme/docs-website"])
        #expect(form.plan.repos.map(\.repo.name) == ["docs-website"])
    }

    @Test func aChatHasNoKind() {
        let form = StartWorkForm(repos: records, settings: .default, prompt: "what is this", chat: true)
        #expect(!form.fields.contains(.kind))
    }

    @Test func theSessionKeepsItsKindAndAnUnknownOneReadsAsNone() throws {
        var session = Session(title: "t", repos: [], branch: "b", agent: "claude", state: ObservedState(.idle))
        session.kind = .fix
        let data = try JSONEncoder().encode(session)
        #expect(try JSONDecoder().decode(Session.self, from: data).kind == .fix)
        let newer = try #require(String(data: data, encoding: .utf8)?
            .replacingOccurrences(of: "\"kind\":\"fix\"", with: "\"kind\":\"quest\""))
        #expect(newer.contains("quest"))
        let read = try JSONDecoder().decode(Session.self, from: Data(newer.utf8))
        #expect(read.kind == nil)
        #expect(read.title == "t")
    }
}
