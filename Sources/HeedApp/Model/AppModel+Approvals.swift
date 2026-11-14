import Foundation
import HeedCore
import Observation

/// The permission requests waiting on you, live: the queue, the hooks waiting on an answer, and the modal's cursor.
/// Nothing here is persisted: an ask lives as long as the hook that waits for it.
@MainActor
@Observable
final class ApprovalsLive {
    var queue = ApprovalQueue()
    /// The modal's selected row.
    var cursor = 0
    /// Blocked sessions whose prompt heed just pressed Return on: not shown again until their next hook moves them on,
    /// so a second y never presses Return on whatever came next.
    var pressed: [String: Date] = [:]
    /// The hooks waiting on each ask and the answers given, by ask id: a hook back after a drop rejoins its ask.
    @ObservationIgnored let broker = PermissionBroker()
}

/// One place to answer what agents ask (`gy`): the modal, its keys, and the round trip to the hook that waits.
extension AppModel {
    /// Everything waiting, oldest first: hook asks heed can answer, helpers' asks, and blocked sessions it can only
    /// point at.
    var approvalGroups: [ApprovalGroup] {
        let queue = approvals.queue
        let now = Clock.now
        let pressed = approvals.pressed.filter { now.timeIntervalSince($0.value) < 15 }.keys
        let screen = queue.screenAsks(sessions.filter { !pressed.contains($0.id) }, now: now)
        let runs = helpers.runs
        return queue.groups(screen: screen, helpers: ApprovalQueue.helperAsks(
            runs,
            now: now
        )) { [sessions, worktrees] id in
            if id.hasPrefix("helper:") {
                return runs.first { id == "helper:\($0.id)" }.map { [$0.worktree] } ?? []
            }
            guard let session = sessions.first(where: { $0.id == id }) else { return [] }
            return session.worktreePaths + [session.directory].compactMap(\.self)
                + worktrees.filter { session.owns($0) }.map(\.path)
        }
    }

    var approvalSummary: ApprovalSummary { ApprovalSummary(approvalGroups) }

    /// Blocked sessions with a request in the approvals (all of them but one heed just answered on its screen).
    var blockedAsking: Int {
        let waiting = Set(approvalGroups.flatMap(\.sessions))
        return sessions.count { $0.state.state == .blocked && waiting.contains($0.id) }
    }

    /// The group the modal has selected.
    var selectedApproval: ApprovalGroup? {
        let groups = approvalGroups
        guard !groups.isEmpty else { return nil }
        return groups[min(max(approvals.cursor, 0), groups.count - 1)]
    }

    /// The oldest hook ask of a session, for its pane's strip.
    func approval(forSession id: String) -> ApprovalGroup? {
        approvalGroups.first { $0.sessions.contains(id) }
    }

    // MARK: The round trip

    /// A permission hook's ask: kept in the queue until you answer it, the hook goes away, the agent moves on, or
    /// `[approvals] wait_seconds` pass (then a pass, and the agent asks in its pane). The hook hears a receipt as soon
    /// as the ask is queued. The same ask again (its hook lost the connection and came back) joins the first, or gets
    /// the answer already given. Suspends; never blocks.
    func controlPermission(_ request: ControlRequest) async -> ControlReply {
        guard var ask = request.permission else { return .failure("permission needs an ask") }
        let pass = ControlReply(permission: .pass, permissionID: ask.id)
        // Only a session heed runs, and only the one the hook ran in.
        guard request.session == ask.session, sessions.contains(where: { $0.id == ask.session }) else { return pass }
        if let fallback = request.fallback {
            permissionFellBack(ask, fallback)
            return ControlReply(permissionID: ask.id)
        }
        let wait = config.approvals.waitSeconds
        guard wait > 0, !isFixture, !PermissionAsk.isQuestion(tool: ask.tool) else { return pass }
        let id = ask.id
        let broker = approvals.broker
        switch broker.join(id) {
        case let .answered(answer): return ControlReply(permission: answer, permissionID: id)
        case .rejoined: break
        case .new:
            ask.channel = .hook
            approvals.queue.add(ask)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(wait))
                guard let self, broker.isOpen(id) else { return }
                permissionFellBack(ask, .heedWait)
            }
        }
        ControlServer.receipt(id)
        return await ControlReply(permission: broker.wait(id), permissionID: id)
    }

    /// Answers one hook ask, once: the queue lets go of it and its hook hears the answer.
    func resolvePermission(_ id: String, _ answer: PermissionAnswer) {
        approvals.queue.remove([id])
        approvals.broker.resolve(id, answer)
        clampApprovalCursor()
    }

    /// The connection a hook waited on closed. It may come back (heed's side of a hiccup): only when no hook has
    /// rejoined the ask a moment later has the agent stopped waiting, and the ask leaves the queue.
    func permissionHookLeft(_ id: String) {
        guard approvals.broker.detach(id) else { return }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(PermissionHook.rejoinWait + 1))
            guard let self, approvals.broker.abandoned(id),
                  let ask = approvals.queue.asks.first(where: { $0.id == id })
            else { return }
            permissionFellBack(ask, .hookLeft)
        }
    }

    /// The ask went back to the agent's pane: answered with a pass, the reason kept for its session's screen ask
    /// and written to the call log.
    func permissionFellBack(_ ask: PermissionAsk, _ reason: PermissionFallback) {
        let open = approvals.broker.isOpen(ask.id) || approvals.queue.asks.contains { $0.id == ask.id }
        resolvePermission(ask.id, .pass)
        // Heed's own reasons count only for an ask still open; the hook's always do (heed may never have seen it).
        guard open || reason.reportedByHook else { return }
        approvals.queue.fellBack(ask.session, reason)
        CallLog.record(reason.logged(ask, at: Clock.now))
    }

    /// A hook message that shows an ask was answered elsewhere (in the pane, the turn moved on): it leaves the queue.
    func settleApprovals(by message: HookMessage) {
        for id in approvals.queue.settled(by: message.kind, session: message.session) {
            resolvePermission(id, .pass)
        }
    }

    // MARK: Answering

    /// Answers `group`: every hook ask in it hears `answer`; a screen ask is answered in its pane where heed can
    /// tell what Return does there (allow only), else its session opens.
    @discardableResult
    func answer(_ group: ApprovalGroup, _ answer: PermissionAnswer, openUnanswerable: Bool = true) -> Bool {
        approvals.queue.record(answer.decision, for: group.asks, at: Clock.now)
        var answered = true
        for ask in group.asks {
            switch ask.channel {
            case .hook:
                resolvePermission(ask.id, answer)
                markAnswered(ask.session, answer)
            case .helper:
                guard let helper = ask.helperID else { continue }
                if !settleHelperAsk(helper, askID: ask.id, answer) { answered = false }
            case .screen:
                if answer.decision == .allow, allowOnScreen(sessionID: ask.session) { continue }
                answered = false
                if openUnanswerable {
                    showApprovals(false)
                    show(sessionID: ask.session)
                }
            }
        }
        clampApprovalCursor()
        if approvalGroups.isEmpty { showApprovals(false) }
        return answered
    }

    /// The session moves on from blocked at once (its next hook says more), so it does not linger as a screen ask.
    private func markAnswered(_ id: String, _ answer: PermissionAnswer) {
        guard var session = sessions.first(where: { $0.id == id }), session.state.state == .blocked,
              !approvals.queue.asks.contains(where: { $0.session == id })
        else { return }
        let word = answer.decision == .allow ? "allowed" : "denied"
        session.state = ObservedState(.working, reason: "\(word) in heed")
        session.record("\(word) \(answer.always ? "always " : "")from heed's approvals")
        commit(.sessionUpserted(session))
    }

    func clampApprovalCursor() {
        let count = approvalGroups.count
        approvals.cursor = count == 0 ? 0 : min(max(approvals.cursor, 0), count - 1)
    }

    /// `approvals.*`: false for any other command.
    func performApprovals(_ command: CommandInvocation) -> Bool {
        switch command.name {
        case "approvals.open":
            guard !approvalGroups.isEmpty else {
                flash = "no agent is waiting for your OK"
                return true
            }
            approvals.cursor = 0
            showApprovals(overlay != .approvals)
        case "approvals.next", "approvals.prev":
            approvals.cursor += command.name == "approvals.next" ? (command.count ?? 1) : -(command.count ?? 1)
            clampApprovalCursor()
        case "approvals.allow": answerSelected(PermissionAnswer(.allow))
        case "approvals.deny":
            let reason = command.arguments.joined(separator: " ").trimmingCharacters(in: .whitespaces)
            answerSelected(PermissionAnswer(.deny, message: reason.isEmpty ? nil : reason))
        case "approvals.deny.reason":
            guard let group = selectedApproval else { return true }
            guard group.answerable else {
                flash = "\(group.first.agent) asks in its pane: answer it there (gS)"
                return true
            }
            guard group.takesReason else {
                flash = "a helper's agent hears only allow or deny: n denies it"
                return true
            }
            openCommandLine("approvals.deny ")
        case "approvals.always":
            guard let group = selectedApproval else { return true }
            guard group.canAlways else {
                if group.first.channel == .helper {
                    flash = "the helper's agent offered no always for this one: y allows it once"
                    return true
                }
                flash = group.first.agent == "claude"
                    ? "claude offered no rule to save for this one: y allows it once"
                    : "\(group.first.agent) takes no saved rule from heed: y allows it once"
                return true
            }
            answer(group, PermissionAnswer(.allow, always: true))
        case "approvals.allow.all": answerAll(.allow) { _ in true }
        case "approvals.deny.all": answerAll(.deny) { _ in true }
        case "approvals.allow.read": answerAll(.allow) { $0.safeRead }
        case "approvals.session":
            guard let group = selectedApproval else { return true }
            showApprovals(false)
            if let helper = group.first.helperID { return openHelperFromApprovals(helper) }
            show(sessionID: group.first.session)
        default: return false
        }
        return true
    }

    /// `gS` on a helper's ask: the helper in its split, under its session's panes, else under Autopilot's tiles.
    private func openHelperFromApprovals(_ id: String) -> Bool {
        if let session = helpers.run(id)?.sessionID, sessions.contains(where: { $0.id == session }) {
            show(sessionID: session)
        } else {
            view = .watch
        }
        openHelper(id)
        return true
    }

    private func answerSelected(_ answer: PermissionAnswer) {
        guard let group = selectedApproval else { return flash = "no agent is waiting for your OK" }
        guard group.answerable || answer.decision == .allow else {
            flash = "\(group.first.agent) asks in its pane: deny it there"
            showApprovals(false)
            return show(sessionID: group.first.session)
        }
        self.answer(group, answer)
    }

    /// Y, N and r: every group `include` takes that heed can answer. Screen asks are left (Y presses Return only
    /// where the screen shows that allows), and the flash says how many.
    private func answerAll(_ decision: PermissionAnswer.Decision, include: (ApprovalGroup) -> Bool) {
        let groups = approvalGroups.filter(include)
        guard !groups.isEmpty
        else { return flash = decision == .allow ? "nothing read only waiting" : "nothing waiting" }
        var answered = 0
        for group in groups where group.answerable || decision == .allow {
            if answer(group, PermissionAnswer(decision), openUnanswerable: false) { answered += 1 }
        }
        let left = groups.count - answered
        let word = decision == .allow ? "allowed" : "denied"
        flash = "\(word) \(answered)" + (left > 0 ? " · \(left) left to answer in their panes" : "")
        if approvalGroups.isEmpty { showApprovals(false) }
    }

    /// Presses Return on the session's permission prompt when its screen shows that allows (`ScreenGuess`); false
    /// when it cannot tell.
    @discardableResult
    func allowOnScreen(sessionID: String) -> Bool {
        guard let session = sessions.first(where: { $0.id == sessionID }), session.state.state == .blocked,
              let layout = layouts[sessionID], let (_, paneID) = agentPane(in: layout),
              let screen = TerminalSurfaces.shared.visibleText(paneID: paneID),
              ScreenGuess.allowsWithReturn(agent: session.agent, screen: screen)
        else { return false }
        TerminalSurfaces.shared.typeLine("", paneID: paneID)
        approvals.pressed[sessionID] = Clock.now
        var allowed = session
        allowed.record("allowed from heed")
        commit(.sessionUpserted(allowed))
        return true
    }
}
