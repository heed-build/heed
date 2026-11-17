import Foundation
@testable import HeedCore
import Testing

/// Panes heed cannot hear: why a message is not taken, what the session records of it, how it is filed, and the
/// session key's read that decides whether panes started now are heard after a restart.
struct UnheardTests {
    private let keys = SessionKeys(key: Data(repeating: 3, count: 32))
    private let now = Date(timeIntervalSince1970: 1_000_000)

    private func session(_ state: AgentState, unheard: Unheard? = nil) -> Session {
        var session = Session(
            id: "s", title: "s", repos: [Repo(org: "o", name: "r")], branch: "b", agent: "claude",
            state: ObservedState(state)
        )
        session.unheard = unheard
        return session
    }

    @Test func aMessageWithoutATokenOrWithOneHeedCannotCheckIsNotTaken() {
        let own = keys.token(session: "s", pane: "p")
        #expect(Unheard.reason(token: own, session: "s", pane: "p", keys: keys) == nil)
        #expect(Unheard.reason(token: nil, session: "s", pane: "p", keys: keys) == .noToken)
        #expect(Unheard.reason(token: "", session: "s", pane: "p", keys: keys) == .noToken)
        // Another key's token, and this key's token for another pane, are not this pane's.
        let other = SessionKeys(key: Data(repeating: 4, count: 32)).token(session: "s", pane: "p")
        #expect(Unheard.reason(token: other, session: "s", pane: "p", keys: keys) == .unverified)
        #expect(Unheard.reason(token: keys.token(session: "s", pane: "q"), session: "s", pane: "p", keys: keys)
            == .unverified)
        #expect(Unheard.reason(token: "not.a.token", session: "s", pane: "p", keys: keys) == .unverified)
    }

    @Test func onlyAKnownSessionsAgentPaneIsRecorded() {
        // No such session: nothing is made.
        #expect(Unheard.noting(.noToken, pane: "p", agentPane: nil, on: nil, at: now) == nil)
        // Another pane of the session, or none named: nothing.
        #expect(Unheard.noting(.noToken, pane: "shell", agentPane: "p", on: nil, at: now) == nil)
        #expect(Unheard.noting(.noToken, pane: nil, agentPane: "p", on: nil, at: now) == nil)
        let first = Unheard.noting(.noToken, pane: "p", agentPane: "p", on: nil, at: now)
        #expect(first == Unheard(pane: "p", reason: .noToken, firstSeen: now))
    }

    @Test func laterMessagesCountAndKeepTheFirstTime() throws {
        let first = try #require(Unheard.noting(.noToken, pane: "p", agentPane: "p", on: nil, at: now))
        let later = now.addingTimeInterval(60)
        let second = try #require(Unheard.noting(.unverified, pane: "p", agentPane: "p", on: first, at: later))
        #expect(second.count == 2 && second.firstSeen == now && second.lastSeen == later)
        #expect(second.reason == .unverified)
        // A new agent pane (a handoff) starts over.
        let moved = try #require(Unheard.noting(.noToken, pane: "p2", agentPane: "p2", on: second, at: later))
        #expect(moved == Unheard(pane: "p2", reason: .noToken, firstSeen: later))
    }

    @Test func aTakenMessageFromThePaneClearsIt() {
        let unheard = Unheard(pane: "p", reason: .noToken, firstSeen: now)
        #expect(Unheard.heard(pane: "p", on: unheard) == nil)
        // A shell split's message says nothing about the agent pane.
        #expect(Unheard.heard(pane: "shell", on: unheard) == unheard)
        #expect(Unheard.heard(pane: nil, on: unheard) == unheard)
        #expect(Unheard.heard(pane: "p", on: nil) == nil)
    }

    @Test func anUnheardSessionIsWorkingWhateverItsStaleStateSays() {
        let unheard = Unheard(pane: "p", reason: .noToken, firstSeen: now)
        for state in AgentState.allCases {
            #expect(SessionGroup.of(session(state, unheard: unheard)) == .working, "\(state)")
        }
        // Heard, the state decides as before.
        #expect(SessionGroup.of(session(.done)) == .parked)
        #expect(SessionGroup.of(session(.asking)) == .needsYou)
        // What you chose, and what the pilot knows, still win.
        var pinned = session(.done, unheard: unheard)
        pinned.pinned = true
        #expect(SessionGroup.of(pinned) == .pinned)
        var parked = session(.working, unheard: unheard)
        parked.parked = true
        #expect(SessionGroup.of(parked) == .parked)
        #expect(SessionGroup.of(session(.idle, unheard: unheard), pilot: SessionPilot(helperNeedsYou: true))
            == .needsYou)
    }

    @Test func theMarkIsNeverKept() throws {
        let marked = session(.working, unheard: Unheard(pane: "p", reason: .noToken, firstSeen: now))
        let data = try JSONEncoder().encode(marked)
        #expect(!String(decoding: data, as: UTF8.self).contains("unheard"))
        #expect(try JSONDecoder().decode(Session.self, from: data).unheard == nil)
    }

    @Test func theMenusOfferReconnectOnlyForAnUnheardSession() {
        var facts = ContextMenus.SessionFacts(id: "s", title: "s")
        let names = { (facts: ContextMenus.SessionFacts) in
            MenuBar.Menu("", ContextMenus.session(facts)).items.map(\.command.name)
        }
        #expect(!names(facts).contains("session.reconnect"))
        facts.unheard = true
        #expect(names(facts).contains("session.reconnect"))
    }

    @Test func reconnectIsBoundInTheSessionsScopeWithoutAClash() {
        let sessions = Dictionary(DefaultKeys.sessions, uniquingKeysWith: { first, _ in first })
        #expect(sessions["gk"] == "session.reconnect")
        // Scopes laid over the sessions' (a helper's split) carry it too; nothing else is on gk.
        let everywhere = DefaultKeys.normal + DefaultKeys.scoped.filter { $0.key != "sessions" }.flatMap(\.value)
        #expect(!everywhere.contains { $0.0 == "gk" && $0.1 != "session.reconnect" }, "gk clashes")
        #expect(DefaultKeys.sessions.count(where: { $0.0 == "gk" }) == 1)
        #expect(Commands.all.contains { $0.name == "session.reconnect" })
    }
}

/// A store that cannot be read or written, as a locked or refused Keychain, or an unreadable file.
private struct BrokenKeyStore: SessionKeyStore {
    struct Broken: Error, CustomStringConvertible {
        var description: String { "Keychain: user interaction is not allowed" }
    }

    func read() throws -> Data? { throw Broken() }
    func write(_: Data) throws { throw Broken() }
    func delete() throws { throw Broken() }
}

struct SessionKeyReadTests {
    private let old = Data(repeating: 7, count: 32)

    @Test func aKeptKeyHasNoProblem() {
        let read = SessionKeyRead.load(signing: .developerID, keychain: MemoryKeyStore(old), file: MemoryKeyStore())
        #expect(read.problem == nil && read.notice == nil)
        #expect(read.logged(signing: .developerID, at: Date()) == nil)
        #expect(read.keys.verifies(SessionKeys(key: old).token(session: "s", pane: "p"), session: "s", pane: "p"))
        let fresh = SessionKeyRead.load(signing: .adHoc, keychain: MemoryKeyStore(), file: MemoryKeyStore())
        #expect(fresh.problem == nil)
    }

    @Test func anUnreadableFileGivesThisRunsKeyAndSaysWhy() throws {
        let read = SessionKeyRead.load(signing: .adHoc, keychain: MemoryKeyStore(), file: BrokenKeyStore())
        let problem = try #require(read.problem)
        #expect(problem.contains("user interaction is not allowed"))
        #expect(read.notice == "Session key couldn't be read: \(problem); panes started this run won't be heard "
            + "after a restart")
        // The key still works for this run.
        #expect(read.keys.verifies(read.keys.token(session: "s", pane: "p"), session: "s", pane: "p"))
        let call = try #require(read.logged(signing: .adHoc, at: Date()))
        #expect(call.failed && call.caller == "session.key" && call.stderr == problem)
    }

    @Test func anUnreadableKeychainIsNotWrittenOver() throws {
        // A Keychain that cannot be read now keeps its key: heed writes nothing over it, and says why.
        let keychain = RefusingReads(MemoryKeyStore(old))
        let read = SessionKeyRead.load(signing: .developerID, keychain: keychain, file: MemoryKeyStore())
        #expect(read.problem != nil)
        #expect(keychain.inner.kept == old)
        // A key still in the file is used, and stays there.
        let file = MemoryKeyStore(Data(repeating: 9, count: 32))
        let withFile = SessionKeyRead.load(signing: .developerID, keychain: keychain, file: file)
        #expect(withFile.problem != nil)
        #expect(file.kept == Data(repeating: 9, count: 32) && keychain.inner.kept == old)
        #expect(withFile.keys.verifies(
            SessionKeys(key: Data(repeating: 9, count: 32)).token(session: "s", pane: nil), session: "s", pane: nil
        ))
    }

    @Test func aKeychainThatWillNotKeepANewKeySaysSo() {
        let new = SessionKeyRead.load(
            signing: .developerID, keychain: MemoryKeyStore(refusesWrites: true), file: MemoryKeyStore()
        )
        #expect(new.problem != nil)
        // The file's key is kept there: nothing is lost.
        let file = MemoryKeyStore(old)
        let kept = SessionKeyRead.load(
            signing: .developerID, keychain: MemoryKeyStore(refusesWrites: true), file: file
        )
        #expect(kept.problem == nil && file.kept == old)
    }
}

/// A Keychain holding a key it will not hand out.
private final class RefusingReads: SessionKeyStore, @unchecked Sendable {
    let inner: MemoryKeyStore
    init(_ inner: MemoryKeyStore) { self.inner = inner }
    func read() throws -> Data? { throw BrokenKeyStore.Broken() }
    func write(_ key: Data) throws { try inner.write(key) }
    func delete() throws { try inner.delete() }
}
