import Foundation
@testable import HeedCore
import Testing

/// Starting a chat: `chat.new` and the chat chip in Start work, the folder it makes, and where it is listed.
@Suite(.serialized)
struct ChatStartTests {
    private let records = ["docs-builder", "mermaider"].map {
        RepoRecord(repo: Repo(org: "o", name: $0), path: "/code/\($0)", defaultBranch: "main")
    }

    private func type(_ text: String, into form: inout StartWorkForm) {
        for char in text {
            _ = form.handle(char == " " ? KeyStroke("Space") : KeyStroke(String(char)))
        }
    }

    private func press(_ keys: String..., into form: inout StartWorkForm) {
        for key in keys {
            _ = form.handle(KeyStroke(key))
        }
    }

    private func chatSession(_ state: AgentState, pinned: Bool = false, parked: Bool = false) -> Session {
        Session(
            id: "c", title: "Cron", repos: [], branch: "", agent: "claude", state: ObservedState(state),
            pinned: pinned, parked: parked, workspace: .chat(ChatFolder(.scratch, path: "/tmp/c"))
        )
    }

    // MARK: Naming

    @Test func aScratchFolderIsNamedAfterTheDayAndThePrompt() throws {
        let date = try #require(ISO8601DateFormatter().date(from: "2026-10-21T10:00:00Z"))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        #expect(Chats.scratchName(for: "What cron line runs at nine?", on: date, calendar: calendar)
            == "2026-10-21-what-cron-line-runs")
        #expect(Chats.scratchName(for: "  ", on: date, calendar: calendar) == "2026-10-21-chat")
        let taken: Set = ["/r/a", "/r/a-2"]
        #expect(Chats.unique("a", in: "/r") { taken.contains($0) } == "/r/a-3")
        #expect(Chats.unique("b", in: "/r") { taken.contains($0) } == "/r/b")
        #expect(Chats.root(on: .host("lab")) == "~/.heed/chats")
    }

    // MARK: The form

    @Test func chatNewOpensOnAScratchChatWithNoRepo() {
        var form = StartWorkForm(repos: records, settings: .default, chat: true)
        type("mermaider arrows question", into: &form)
        // A chat has no repo to guess, even when the prompt names one.
        #expect(form.selectedRepos.isEmpty)
        #expect(form.chat?.kind == .scratch)
        #expect(form.name.hasSuffix("-mermaider-arrows-question"))
        guard case let .start(plan) = form.handle(KeyStroke("CR", .command)) else {
            Testing.Issue.record("expected start")
            return
        }
        #expect(plan.repos.isEmpty)
        #expect(plan.chat?.kind == .scratch)
        #expect(plan.chat?.name == form.name)
        #expect(plan.location == .local)
        #expect(plan.command?.posix == "claude 'mermaider arrows question'")
    }

    @Test func theChatChipTurnsStartWorkIntoAChatAndARepoTurnsItBack() {
        var form = StartWorkForm(repos: records, settings: .default)
        type("mermaider arrows", into: &form)
        #expect(form.selectedRepos == ["o/mermaider"])
        press("Esc", "j", into: &form)
        // Two repos, the search chip, then the chat chip.
        #expect(form.chatChipIndex == 3)
        press("l", "l", "l", "Space", into: &form)
        #expect(form.chat != nil)
        #expect(form.selectedRepos.isEmpty)
        #expect(form.canStart)
        press("h", "h", "h", "Space", into: &form)
        #expect(form.chat == nil)
        // The repo picked, alone, even the one that was guessed before.
        #expect(form.selectedRepos == ["o/mermaider"])
    }

    @Test func aPickedFolderAndAHostAreChosenInTheFolderField() {
        var form = StartWorkForm(repos: records, settings: .default, hosts: ["lab"], chat: true)
        type("tidy this up", into: &form)
        press("Esc", "j", "j", into: &form)
        #expect(form.field == .worktree)
        #expect(form.chatChips.map(\.label) == ["scratch", "folder", "this Mac", "@lab"])
        press("l", "Space", into: &form)
        #expect(form.chat?.kind == .folder)
        // Nothing typed past `~/` is no folder yet.
        #expect(!form.canStart)
        _ = form.handle(KeyStroke("CR", .command))
        #expect(form.error == "type the folder's path first")
        press("i", into: &form)
        type("notes", into: &form)
        press("Esc", "l", "l", "Space", into: &form)
        #expect(form.chat?.host == "lab")
        let plan = form.plan
        #expect(plan.chat == ChatPlan(kind: .folder, name: "~/notes", location: .host("lab")))
        #expect(plan.location == .host("lab"))
        // On a host `~` is the host's: left for its shell.
        #expect(plan.chat?.path == "~/notes")
    }

    // MARK: Starting

    @Test func startingAScratchChatMakesItsFolderAndAnAgentPaneThere() async throws {
        let root = NSTemporaryDirectory() + "heed-chats-\(UUID().uuidString)"
        let saved = Chats.localRoot
        Chats.localRoot = root
        defer {
            Chats.localRoot = saved
            try? FileManager.default.removeItem(atPath: root)
        }
        try FileManager.default.createDirectory(atPath: root + "/2026-10-21-cron", withIntermediateDirectories: true)
        var plan = StartWorkPlan(
            prompt: "What cron line runs at nine?", repos: [], name: "", agent: AgentProfile.builtIn.first,
            sessionID: "c"
        )
        plan.chat = ChatPlan(kind: .scratch, name: "2026-10-21-cron")
        plan.shellSplit = true
        let changes = try await StartWork.execute(plan, settings: .default)
        let domain = Domain().applying(changes)
        let session = try #require(domain.session("c"))
        // The name was taken, so it gets the next free one.
        #expect(session.chat == ChatFolder(.scratch, path: root + "/2026-10-21-cron-2"))
        #expect(FileManager.default.fileExists(atPath: root + "/2026-10-21-cron-2"))
        #expect(session.repos.isEmpty)
        #expect(session.title == "What cron line runs at nine?")
        #expect(domain.worktrees.isEmpty)
        let panes = domain.layouts["c"]?.tabs.flatMap(\.tree.panes) ?? []
        #expect(panes.map(\.role) == [.agent, .shell])
        #expect(panes.allSatisfy { $0.directory == root + "/2026-10-21-cron-2" })
        #expect(panes.first?.command?.posix == "claude 'What cron line runs at nine?'")
    }

    @Test func aPickedFolderMustBeThere() async {
        var plan = StartWorkPlan(prompt: "x", repos: [], name: "", agent: nil, sessionID: "c")
        plan.chat = ChatPlan(kind: .folder, name: NSTemporaryDirectory() + "heed-missing-\(UUID().uuidString)")
        await #expect(throws: StartWorkError.self) { _ = try await StartWork.execute(plan, settings: .default) }
    }

    // MARK: Listed

    @Test func chatsHaveTheirOwnGroupButNeedsYouStaysTheOnePlaceForAsking() {
        #expect(SessionGroup.of(chatSession(.working)) == .chats)
        #expect(SessionGroup.of(chatSession(.done)) == .chats)
        #expect(SessionGroup.of(chatSession(.asking)) == .needsYou)
        #expect(SessionGroup.of(chatSession(.blocked)) == .needsYou)
        #expect(SessionGroup.of(chatSession(.idle, pinned: true)) == .pinned)
        #expect(SessionGroup.of(chatSession(.idle, parked: true)) == .parked)
        let list = SessionList([chatSession(.working)])
        #expect(list.sections.map(\.group) == [.chats])
    }

    @Test func chatIsAShortFormOfChatNew() {
        #expect(CommandAliases.resolve("chat what is a cron line") == CommandInvocation(
            name: "chat.new", arguments: ["what", "is", "a", "cron", "line"]
        ))
        #expect(CommandAliases.listed.contains { $0.name == "chat" && $0.runs == "chat.new" })
        #expect(Commands.spec("chat.new") != nil)
        #expect(DefaultKeys.normal.contains { $0 == ("gc", "chat.new") })
    }

    @Test func aChatsMenuStartsANewChatFromItsPrompt() {
        var facts = ContextMenus.SessionFacts(id: "c", title: "Cron")
        facts.chat = true
        facts.hasPrompt = true
        let again = ContextMenus.session(facts).compactMap { if case let .item(item) = $0 { item } else { nil } }
            .first { $0.command.name == "work.again" }
        #expect(again?.title == "New chat from its prompt")
        let history = ContextMenus.history(id: "c", title: "Cron", hasPrompt: true, chat: true, onGitHub: false)
            .compactMap { if case let .item(item) = $0 { item } else { nil } }
        #expect(history.map(\.title) == ["Reopen", "New chat from its prompt"])
    }
}
