import Foundation
import HeedCore

/// Heed names sessions as their work goes (`SessionNaming`): Apple's on-device model where the Mac has it, else a
/// model call through `[llm]` within the day's budget.
extension AppModel {
    /// After a commit: the sessions that reached a naming moment (their first turn ended, a PR opened).
    func noticeNaming(before: Domain, after: Domain) {
        guard !isFixture, settings.nameSessions else { return }
        for (id, _) in SessionNaming.moments(before: before.sessions, after: after.sessions) {
            Task { await nameSession(id) }
        }
    }

    /// Asks for a name and puts it on the session, if it is still there and still heed's to name.
    func nameSession(_ id: String) async {
        guard let session = sessions.first(where: { $0.id == id }), SessionNaming.mayName(session) else { return }
        let titles = session.trackedPRs.compactMap { ref in github.pulls.first { $0.ref == ref }?.title }
        let question = SessionNaming.Question.of(session, pullTitles: titles, others: sessions)
        guard let answer = await askName(question) else { return }
        // The session as it is now: it may have changed (or been named by you) while the model thought.
        guard var current = sessions.first(where: { $0.id == id }) else { return }
        if SessionNaming.apply(answer, to: &current) {
            commit(.sessionUpserted(current))
        } else if current.kind != session.kind {
            commit(.sessionUpserted(current))
        }
    }

    private func askName(_ question: SessionNaming.Question) async -> SessionNaming.Answer? {
        if let namer = SmartGuesses.namer(), let answer = try? await namer.name(question) { return answer }
        guard config.llm.enabled, spendNamingCall() else { return nil }
        guard let text = try? await summarizer.summarize(
            kind: .sessionName, inputs: question.inputs, caller: "sessions.name"
        ) else { return nil }
        return SessionNaming.parse(text)
    }

    /// One model call for a name, if today has any left (`SessionNaming.dailyCalls`).
    private func spendNamingCall(now: Date = Date()) -> Bool {
        let today = Calendar.current.startOfDay(for: now)
        let spent = sessionNamingCalls.day == today ? sessionNamingCalls.count : 0
        guard spent < SessionNaming.dailyCalls else { return false }
        sessionNamingCalls = (today, spent + 1)
        return true
    }

    /// `session.rename <title>` gives the session your title; with no title the command line opens with its title.
    /// `session.autoname` hands the title back to heed, which names it now.
    func renameSession(_ command: CommandInvocation) {
        let targeted: Session? = if case let .session(id)? = command.target { sessions.first { $0.id == id } } else {
            nil
        }
        guard var session = targeted ?? currentSession else { return flash = "no session here" }
        if command.name == "session.autoname" {
            SessionNaming.rename(&session, to: "")
            commit(.sessionUpserted(session))
            flash = "heed names \(session.title) from now on"
            Task { await nameSession(session.id) }
            return
        }
        guard !command.arguments.isEmpty else { return openCommandLine("session.rename " + session.title) }
        SessionNaming.rename(&session, to: command.arguments.joined(separator: " "))
        commit(.sessionUpserted(session))
        renameMindmapWork(session)
    }

    /// The cursor came to a session heed renamed: it has been seen.
    func markTitleSeen() {
        guard var session = currentSession, !session.titleSeen else { return }
        session.titleSeen = true
        commit(.sessionUpserted(session))
    }

    /// Your title on the session's Mindmap card too, wherever its work is placed.
    private func renameMindmapWork(_ session: Session) {
        for instance in mindmap.instances where mindmap.tree(instance).work(for: session.id) != nil {
            Task { await mindmap.change(instance) { $0.rename("work:\(session.id)", to: session.title, now: Date()) } }
        }
    }
}
