import Foundation
@testable import HeedCore
import Testing

/// Start work by mouse: each click lands on the field it is in and does what the keys there would.
struct StartWorkMouseTests {
    private let records = ["docs-toolkit", "markgraph"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func type(_ text: String, into form: inout StartWorkForm) {
        for char in text {
            _ = form.handle(char == " " ? KeyStroke("Space") : KeyStroke(String(char)))
        }
    }

    @Test func clickingAFieldFocusesItAndTheTextFieldsStartEditing() {
        var form = StartWorkForm(repos: records, settings: .default)
        _ = form.handle(.escape)
        #expect(!form.editing)
        form.focus(field: .agent)
        #expect(form.field == .agent)
        #expect(!form.editing)
        form.focus(field: .worktree, edit: true)
        #expect(form.field == .worktree)
        #expect(form.editing)
        type("my-name", into: &form)
        #expect(form.name == "my-name")
        form.focus(field: .prompt, edit: true)
        #expect(form.field == .prompt)
        #expect(form.editing)
        // A chip field has nothing to type into.
        form.focus(field: .options, edit: true)
        #expect(!form.editing)
    }

    @Test func clickingARepoChipPicksItAsSpaceDoes() {
        var form = StartWorkForm(repos: records, settings: .default)
        type("markgraph arrows", into: &form)
        #expect(form.selectedRepos == ["o/markgraph"])
        let docs = form.repoChoices.firstIndex { $0.repo.id == "o/docs-toolkit" } ?? -1
        form.pickRepo(at: docs)
        #expect(form.field == .repo)
        #expect(!form.editing)
        #expect(form.repoCursor == docs)
        #expect(form.selectedRepos == ["o/markgraph", "o/docs-toolkit"])
        form.pickRepo(at: docs)
        #expect(form.selectedRepos == ["o/markgraph"])
        // Out of range changes nothing.
        form.pickRepo(at: 99)
        #expect(form.selectedRepos == ["o/markgraph"])
        #expect(form.repoCursor == docs)
    }

    @Test func theSearchChipOpensSearchAndAClickedRowIsAdded() {
        var form = StartWorkForm(repos: records, settings: .default)
        type("markgraph arrows", into: &form)
        form.pickRepo(at: form.repoChoices.count)
        let search = form.repoSearch
        #expect(search != nil)
        let docs = search?.matches.firstIndex { $0.id == "o/docs-toolkit" } ?? -1
        form.pickSearchMatch(at: docs)
        #expect(form.repoSearch == nil)
        #expect(form.selectedRepos == ["o/markgraph", "o/docs-toolkit"])
    }

    @Test func theChatChipTurnsItIntoAChatAndAFolderChipPicksTheKind() {
        var form = StartWorkForm(repos: records, settings: .default, hosts: ["lab"])
        type("tidy up", into: &form)
        form.pickRepo(at: form.chatChipIndex)
        #expect(form.chat != nil)
        form.pickChatChip(1)
        #expect(form.field == .worktree)
        #expect(form.chat?.kind == .folder)
        form.pickChatChip(3)
        #expect(form.chat?.host == "lab")
        form.pickChatChip(2)
        #expect(form.chat?.host == nil)
        form.pickChatChip(9)
        #expect(form.chat?.cursor == 2)
    }

    @Test func clickingAnAgentChoosesIt() {
        var form = StartWorkForm(repos: records, settings: .default)
        let last = form.agents.count - 1
        form.pickAgent(at: last)
        #expect(form.field == .agent)
        #expect(form.agent == nil)
        form.pickAgent(at: 0)
        #expect(form.agentIndex == 0)
        form.pickAgent(at: last + 1)
        #expect(form.agentIndex == 0)
    }

    @Test func clickingAnOptionTogglesIt() {
        var form = StartWorkForm(repos: records, settings: .default)
        let planFirst = form.planFirst
        let autostart = form.autostart
        form.toggleOption(.planFirst)
        #expect(form.field == .options)
        #expect(form.optionCursor == StartWorkForm.Option.planFirst.rawValue)
        #expect(form.planFirst == !planFirst)
        #expect(form.autostart == autostart)
        form.toggleOption(.autostart)
        #expect(form.autostart == !autostart)
        // Copying files is only an option when promoting a chat that has some.
        form.toggleOption(.copyFiles)
        #expect(form.optionCursor == StartWorkForm.Option.autostart.rawValue)
        #expect(form.autostart == !autostart)
    }
}
