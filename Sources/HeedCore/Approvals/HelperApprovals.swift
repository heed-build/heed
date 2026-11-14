import Foundation

/// A helper's permission requests in the one approvals queue. The helper's own `permission` is the one source of
/// truth: the queue reads its asks from the live helpers (`ApprovalQueue.helperAsks`), and an answer from the queue or
/// from the helper's split settles the same request once (`HelperRun.settle`), so the other place follows.
public extension HelperPermission {
    /// The option of the agent's that `answer` stands for: allow is its allow once; allow always its allow always
    /// (else allow once); deny its reject once (else reject always). Nil when the agent offered no such option.
    func option(for answer: PermissionAnswer) -> ACPPermissionRequest.Option? {
        switch answer.decision {
        case .allow: answer.always ? option(.allowAlways) ?? option(.allowOnce) : option(.allowOnce)
        case .deny: option(.rejectOnce) ?? option(.rejectAlways)
        case .pass: nil
        }
    }
}

public extension HelperRun {
    /// The approvals' id for the permission it waits on: the helper and the agent's request id, so an answer meant
    /// for one request never settles the next.
    var askID: String? {
        permission.map { "helper-\(id)-\($0.requestID.text)" }
    }

    /// What settling a helper's permission comes to.
    enum Settled: Equatable, Sendable {
        /// Send the agent this option's id (nil: cancelled); `word` is what the story says (`allowed`).
        case send(requestID: JSONValue, optionID: String?, word: String)
        /// It no longer asks that: answered already (from the queue or the split), withdrawn, or its turn ended.
        case stale
        /// The agent offered no option for this answer; it still asks.
        case noOption
    }

    /// Settles the permission `askID` names with `answer`, once: the story records the answer and the permission is
    /// let go of. A second answer, from either place, is `stale` and sends nothing. A pass is a cancel.
    mutating func settle(_ askID: String, _ answer: PermissionAnswer) -> Settled {
        guard let permission, self.askID == askID, phase.isLive else { return .stale }
        let optionID: String?
        let word: String
        if answer.decision == .pass {
            optionID = nil
            word = "cancelled"
        } else {
            guard let option = permission.option(for: answer) else { return .noOption }
            optionID = option.id
            word = switch option.kind {
            case .allowOnce: "allowed"
            case .allowAlways: "allowed always"
            case .rejectOnce, .rejectAlways: "denied"
            }
        }
        answered(word)
        return .send(requestID: permission.requestID, optionID: optionID, word: word)
    }

    /// Its turn ended or its agent went away with a permission still open: it is let go of without an answer, and
    /// leaves the approvals.
    mutating func withdrawPermission() {
        guard permission != nil else { return }
        permission = nil
        if let index = feed.lastIndex(where: {
            if case .permission(_, nil) = $0.body { return true }
            return false
        }), case let .permission(title, _) = feed[index].body {
            feed[index].body = .permission(title: title, answer: "withdrawn")
        }
        if case .asking = phase { phase = .working }
    }
}

public extension PermissionAsk {
    /// The approvals' entry for the permission a live helper waits on; nil when it asks nothing. Its agent is
    /// `helper · claude`, its "session" the helper (`helper:<id>`), its tool read from the ACP tool call's kind, title
    /// and raw input, so the risk tags read it as they read a hook's.
    static func from(helper run: HelperRun, now: Date = Date()) -> PermissionAsk? {
        guard let permission = run.permission, let id = run.askID, run.phase.isLive else { return nil }
        let call = permission.call
        let command = permission.command ?? call?.command
        let paths = call?.paths ?? []
        let url = call?.url
        let tool: String = switch permission.kind {
        case .execute: "Bash"
        case .edit, .delete, .move: paths.count > 1 ? "MultiEdit" : "Edit"
        case .read: "Read"
        case .search: "Grep"
        case .fetch: "WebFetch"
        case .think, .switchMode, .other:
            command != nil ? "Bash" : permission.title
        }
        var ask = PermissionAsk(
            id: id, session: "helper:\(run.id)", agent: "helper · \(run.agent)", tool: tool,
            command: command.map { cap($0) }, paths: paths, patch: patch(call?.content), url: url,
            cwd: run.worktree, askedAt: permission.askedAt ?? now, channel: .helper,
            helper: HelperOrigin(
                id: run.id, repo: run.ref.repo.name, number: run.ref.number, headline: run.headline, title: run.title
            ),
            options: permission.options
        )
        // The call's own title says more than the tool when it is not just the command again.
        let title = permission.title.trimmingCharacters(in: CharacterSet(charactersIn: "` "))
        if let command, !title.isEmpty, title != command, title != "a tool call" { ask.why = title }
        return ask
    }

    /// The helper an ask came from, when it is a helper's.
    var helperID: String? { channel == .helper ? helper?.id : nil }

    /// A helper ask can be allowed always: its agent offered that.
    var offersAlways: Bool { options.contains { $0.kind == .allowAlways } }

    /// An ACP tool call's diffs as `-` and `+` lines, capped.
    private static func patch(_ content: [ACPToolContent]?) -> String? {
        var out: [String] = []
        for item in content ?? [] {
            guard case let .diff(_, old, new) = item else { continue }
            if let old { out += old.split(separator: "\n", omittingEmptySubsequences: false).map { "- " + $0 } }
            out += new.split(separator: "\n", omittingEmptySubsequences: false).map { "+ " + $0 }
        }
        return out.isEmpty ? nil : capLines(out.joined(separator: "\n"))
    }
}

public extension ApprovalQueue {
    /// The asks of the live helpers waiting on a permission, read from them each time (as screen asks are from the
    /// sessions): answered, cancelled or ended, they are gone.
    static func helperAsks(_ runs: [HelperRun], now: Date = Date()) -> [PermissionAsk] {
        runs.compactMap { PermissionAsk.from(helper: $0, now: now) }
    }
}
