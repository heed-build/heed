import Foundation
@testable import HeedCore
import Testing

/// The permission hook against a heed that is slow, restarts, drops the connection, or is asked many times at once.
struct PermissionRoundTripTests {
    private static func path() -> String { "/tmp/heed-trip-\(UUID().uuidString.prefix(8)).sock" }

    private static func ask(_ id: String = "ask-1") -> PermissionAsk {
        PermissionAsk(id: id, session: "s1", agent: "claude", tool: "Bash", command: "npm test", askedAt: Date())
    }

    @Test func aReceiptKeepsTheHookWaitingPastTheReceiptWindow() async throws {
        let path = Self.path()
        let heed = FakeHeed { _ in
            try? await Task.sleep(for: .milliseconds(600))
            return PermissionAnswer(.allow)
        }
        let server = heed.server(path)
        try server.start()
        defer { server.stop() }
        let outcome = try await onThread {
            PermissionHook.exchange(Self.ask(), socket: path, ceiling: 5, receiptWait: 0.2)
        }
        #expect(outcome.answer == PermissionAnswer(.allow))
        #expect(outcome.fallback == nil)
    }

    @Test func noReceiptPassesAtOnceAndTellsHeedWhy() async throws {
        let path = Self.path()
        let notices = Box<[PermissionFallback]>([])
        // A heed too busy to queue the ask: it never sends a receipt.
        let server = ControlServer(path: path) { request in
            if let fallback = request.fallback {
                notices.update { $0.append(fallback) }
                return ControlReply()
            }
            try? await Task.sleep(for: .seconds(3))
            return ControlReply(permission: PermissionAnswer(.allow), permissionID: "ask-1")
        }
        try server.start()
        defer { server.stop() }
        let ask = Self.ask()
        let (answer, took) = try await onThread {
            let started = ContinuousClock.now
            let answer = PermissionHook.wait(for: ask, socket: path, ceiling: 5, receiptWait: 0.2)
            return (answer, ContinuousClock.now - started)
        }
        #expect(answer == .pass)
        #expect(took < .milliseconds(900))
        try await eventually { notices.value == [.noReceipt] }
    }

    @Test func theCeilingHoldsAgainstAReplyThatTricklesIn() async throws {
        // A server that sends a byte at a time and never a whole line: a per-read timeout would wait for ever.
        let path = Self.path()
        let trickle = try Trickle(path: path)
        defer { trickle.stop() }
        let ask = Self.ask()
        let (outcome, took) = try await onThread {
            let started = ContinuousClock.now
            let outcome = PermissionHook.exchange(ask, socket: path, ceiling: 0.3, receiptWait: 0.3)
            return (outcome, ContinuousClock.now - started)
        }
        #expect(outcome.answer == .pass)
        #expect(outcome.fallback == .ceiling)
        #expect(took < .milliseconds(600))
    }

    @Test func aHookRejoinsAHeedThatRestartedAndGetsItsAnswer() async throws {
        let path = Self.path()
        let first = FakeHeed { _ in nil }
        let before = first.server(path)
        try before.start()
        let ask = Self.ask()
        let hook = Task { try await onThread { PermissionHook.exchange(ask, socket: path, ceiling: 5) } }
        try await eventually { first.queued.value == 1 }
        // Heed goes away with the ask received, and comes back a moment later.
        before.stop()
        try await Task.sleep(for: .milliseconds(300))
        let second = FakeHeed { _ in PermissionAnswer(.deny, message: "after the restart") }
        let after = second.server(path)
        try after.start()
        defer { after.stop() }
        let outcome = try await hook.value
        #expect(outcome.answer == PermissionAnswer(.deny, message: "after the restart"))
        #expect(second.queued.value == 1)
    }

    @Test func theSameAskTwiceIsQueuedOnceAndAnsweredOnce() async throws {
        let path = Self.path()
        let answers = Box(0)
        let heed = FakeHeed { _ in
            try? await Task.sleep(for: .milliseconds(200))
            answers.update { $0 += 1 }
            return PermissionAnswer(.allow, always: true)
        }
        let server = heed.server(path)
        try server.start()
        defer { server.stop() }
        let ask = Self.ask()
        async let one = onThread { PermissionHook.exchange(ask, socket: path, ceiling: 5) }
        async let two = onThread { PermissionHook.exchange(ask, socket: path, ceiling: 5) }
        let both = try await [one.answer, two.answer]
        #expect(both == [PermissionAnswer(.allow, always: true), PermissionAnswer(.allow, always: true)])
        // Asked again after the answer: the same answer, at once, and still one entry in the queue.
        let again = try await onThread { PermissionHook.exchange(ask, socket: path, ceiling: 5) }
        #expect(again.answer == PermissionAnswer(.allow, always: true), "\(again)")
        #expect(heed.queued.value == 1)
        #expect(answers.value == 1)
    }

    @Test func manyAsksAtOnceAreEachAnsweredAndASlowOneHoldsNoneUp() async throws {
        let path = Self.path()
        let heed = FakeHeed { ask in
            // One ask nobody answers: it must not hold up the others' replies.
            if ask.id == "slow" { return nil }
            try? await Task.sleep(for: .milliseconds(20))
            return PermissionAnswer(.deny, message: ask.id)
        }
        let server = heed.server(path)
        try server.start()
        defer { server.stop() }
        let slow = Task { try await onThread { PermissionHook.exchange(Self.ask("slow"), socket: path, ceiling: 4) } }
        try await eventually { heed.queued.value == 1 }
        let started = ContinuousClock.now
        let answers = try await withThrowingTaskGroup(of: (String, PermissionAnswer).self) { group in
            for index in 0 ..< 40 {
                group.addTask {
                    let id = "ask-\(index)"
                    return try await (
                        id,
                        onThread { PermissionHook.exchange(Self.ask(id), socket: path, ceiling: 5) }
                            .answer
                    )
                }
            }
            return try await group.reduce(into: [:]) { $0[$1.0] = $1.1 }
        }
        // Held up behind the unanswered ask, they would take its whole 4 s; a loaded CI machine needs more than 1 s.
        #expect(ContinuousClock.now - started < .seconds(3))
        #expect(answers.count == 40)
        #expect(answers.allSatisfy { $0.value == PermissionAnswer(.deny, message: $0.key) })
        #expect(heed.queued.value == 41)
        let late = try await slow.value
        #expect(late.answer == .pass)
        #expect(late.fallback == .ceiling)
    }

    @Test func anAnswerIsNotHeldBackByABusyCooperativePool() async throws {
        // Many tasks queued at the default priority (as a loaded machine, or a test run, has): heed's reply is its
        // own high-priority task, so it does not wait behind them.
        let path = Self.path()
        let server = ControlServer(path: path) { request in
            try? await Task.sleep(for: .milliseconds(20))
            return ControlReply(permission: PermissionAnswer(.deny), permissionID: request.permission?.id)
        }
        try server.start()
        defer { server.stop() }
        let busy = Task(priority: .medium) {
            await withTaskGroup(of: Void.self) { group in
                for _ in 0 ..< ProcessInfo.processInfo.activeProcessorCount * 150 {
                    group.addTask(priority: .medium) { spin(.milliseconds(3)) }
                }
            }
        }
        defer { busy.cancel() }
        let ask = Self.ask()
        let (outcome, took) = try await onThread {
            Thread.sleep(forTimeInterval: 0.05)
            let started = ContinuousClock.now
            let outcome = PermissionHook.exchange(ask, socket: path, ceiling: 1, receiptWait: 1)
            return (outcome, ContinuousClock.now - started)
        }
        #expect(outcome.answer == PermissionAnswer(.deny))
        #expect(took < .milliseconds(500))
        await busy.value
    }
}

struct PermissionBrokerTests {
    @Test func anAskJoinsOnceAndIsAnsweredOnce() async {
        let broker = PermissionBroker()
        #expect(broker.join("a") == .new)
        #expect(broker.join("a") == .rejoined)
        async let first = broker.wait("a")
        async let second = broker.wait("a")
        try? await Task.sleep(for: .milliseconds(20))
        #expect(broker.resolve("a", PermissionAnswer(.allow)))
        #expect(!broker.resolve("a", PermissionAnswer(.deny)))
        #expect(await [first, second] == [PermissionAnswer(.allow), PermissionAnswer(.allow)])
        #expect(broker.join("a") == .answered(PermissionAnswer(.allow)))
        #expect(await broker.wait("a") == PermissionAnswer(.allow))
    }

    @Test func anAskHeedNeverSawIsAnsweredWhenItArrivesLate() {
        let broker = PermissionBroker()
        #expect(broker.resolve("late", .pass))
        #expect(broker.join("late") == .answered(.pass))
    }

    @Test func itIsAbandonedOnlyWhenEveryConnectionLeft() {
        let broker = PermissionBroker()
        #expect(broker.join("a") == .new)
        #expect(broker.join("a") == .rejoined)
        #expect(!broker.detach("a"))
        #expect(!broker.abandoned("a"))
        #expect(broker.detach("a"))
        #expect(broker.abandoned("a"))
        #expect(broker.join("a") == .rejoined)
        #expect(!broker.abandoned("a"))
        broker.resolve("a", .pass)
        #expect(!broker.detach("a"))
        #expect(!broker.isOpen("a"))
    }

    @Test func answersAreKeptAWhileAndBounded() {
        let broker = PermissionBroker()
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        broker.resolve("old", PermissionAnswer(.allow), now: start)
        #expect(broker.join("waiting", now: start) == .new)
        for index in 0 ..< PermissionBroker.limit {
            broker.resolve(
                "n\(index)",
                PermissionAnswer(.deny),
                now: start.addingTimeInterval(Double(index + 1) / 1000)
            )
        }
        // Past the limit, the oldest answer goes; an ask still waiting never does.
        #expect(broker.join("old", now: start.addingTimeInterval(1)) == .new)
        #expect(broker.isOpen("waiting"))
        #expect(broker.join("n1", now: start.addingTimeInterval(1)) == .answered(PermissionAnswer(.deny)))
        // Past `keep`, every answer goes.
        let later = start.addingTimeInterval(PermissionBroker.keep + 10)
        #expect(broker.join("n1", now: later) == .new)
        #expect(broker.isOpen("waiting"))
    }

    @Test func aFallbackIsShownOnTheSessionsScreenAskUntilItAsksAgain() {
        var queue = ApprovalQueue()
        let session = Session(
            id: "s1", title: "t", repos: [], branch: "b", agent: "claude",
            state: ObservedState(.blocked, reason: "Bash(npm test)")
        )
        queue.fellBack("s1", .noReceipt)
        #expect(queue.screenAsks([session], now: Date()).first?.fellBack == .noReceipt)
        queue.add(PermissionAsk(id: "x", session: "s1", agent: "claude", tool: "Bash", askedAt: Date()))
        queue.remove(["x"])
        #expect(queue.screenAsks([session], now: Date()).first?.fellBack == nil)
        let row = PermissionFallback.heedWait.logged(
            PermissionAsk(id: "x", session: "s1", agent: "claude", tool: "Bash", askedAt: Date()), at: Date()
        )
        #expect(row.kind == .decide)
        #expect(row.caller == "approvals.fallback")
        #expect(row.detail["reason"] == PermissionFallback.heedWait.text)
    }
}

/// A heed as the app is to a hook: asks keyed by id in a broker, a receipt once queued, `answer` deciding each new
/// ask (nil: never answered).
private final class FakeHeed: Sendable {
    let broker = PermissionBroker()
    let queued = Box(0)
    private let answer: @Sendable (PermissionAsk) async -> PermissionAnswer?

    init(answer: @escaping @Sendable (PermissionAsk) async -> PermissionAnswer?) {
        self.answer = answer
    }

    func server(_ path: String) -> ControlServer {
        let server = ControlServer(path: path) { [self] request in
            guard let ask = request.permission else { return .failure("no") }
            if request.fallback != nil {
                broker.resolve(ask.id, .pass)
                return ControlReply()
            }
            switch broker.join(ask.id) {
            case let .answered(answer): return ControlReply(permission: answer, permissionID: ask.id)
            case .rejoined: break
            case .new:
                queued.update { $0 += 1 }
                Task { [broker, answer] in
                    if let decided = await answer(ask) { broker.resolve(ask.id, decided) }
                }
            }
            ControlServer.receipt(ask.id)
            return await ControlReply(permission: broker.wait(ask.id), permissionID: ask.id)
        }
        server.permissionGone = { [broker] id in _ = broker.detach(id) }
        return server
    }
}

/// A socket that accepts and then sends a byte every 20 ms, never a newline, for two seconds.
private final class Trickle: @unchecked Sendable {
    private let listener: Int32
    private let path: String
    private let stopped = Box(false)

    init(path: String) throws {
        self.path = path
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = HookServer.address(path)
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard listen(listener, 4) == 0 else { throw ControlClientError.closed }
        Thread { [self] in
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var byte: UInt8 = 0x7B
            // For two seconds at most: a client that waits for the line fails rather than hangs.
            let until = Date().addingTimeInterval(2)
            while !stopped.value, Date() < until, write(fd, &byte, 1) == 1 {
                Thread.sleep(forTimeInterval: 0.02)
            }
            close(fd)
        }.start()
    }

    func stop() {
        stopped.update { $0 = true }
        close(listener)
        unlink(path)
    }
}

private final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value { lock.withLock { stored } }
    func update(_ change: (inout Value) -> Void) { lock.withLock { change(&stored) } }
}

private func spin(_ duration: Duration) {
    let until = ContinuousClock.now + duration
    while ContinuousClock.now < until {}
}

private func eventually(_ condition: @escaping @Sendable () -> Bool) async throws {
    let until = ContinuousClock.now + .seconds(3)
    while !condition() {
        guard ContinuousClock.now < until else {
            Issue.record("condition never held")
            return
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func onThread<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        Thread { continuation.resume(with: Result { try body() }) }.start()
    }
}
