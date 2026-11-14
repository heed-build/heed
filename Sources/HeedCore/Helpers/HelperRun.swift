import Foundation

/// What a helper is for: the one thing heed starts it to do on your behalf.
public enum HelperKind: String, Hashable, Sendable, Codable, CaseIterable {
    /// Your PR's failing checks and review comments: fixed in the helper's worktree, pushed and replied to once
    /// you approve.
    case green
    /// Your PR's conflict with its base: merged or rebased in the helper's worktree.
    case conflict
    /// Someone else's PR: read against its issue, its tests run, review comments drafted. Nothing is posted until you
    /// send it.
    case review

    /// `Getting #2841 green`.
    public func title(_ number: Int) -> String {
        switch self {
        case .green: "Getting #\(number) green"
        case .conflict: "Resolving #\(number)'s conflict"
        case .review: "Reviewing #\(number) for you"
        }
    }

    /// The goal a run of this kind is recorded under (`PilotRun`), for the PR's history and Autopilot's Done.
    public var goal: RunGoal { self == .conflict ? .merged : .green }

    /// The branch slug its worktree's branch takes: `heed/get-it-green/<branch>`, `heed/review/…`.
    public var slug: String {
        switch self {
        case .green: RunGoal.green.slug
        case .conflict: RunGoal.merged.slug
        case .review: "review"
        }
    }
}

/// One line of a helper's story, in the order it happened: what the agent said, a tool call (with the diffs it
/// made), a permission it asked for, something you told it, or something heed did.
public struct HelperEntry: Identifiable, Hashable, Sendable {
    public enum Body: Hashable, Sendable {
        case message(String)
        case tool(HelperTool)
        case permission(title: String, answer: String?)
        case steer(String)
        case note(String)
    }

    public let id: String
    public var at: Date
    public var body: Body

    public init(id: String, at: Date, body: Body) {
        self.id = id
        self.at = at
        self.body = body
    }
}

/// A tool call as the feed draws it: its title, kind and status, the files it touched, and the diffs it made.
public struct HelperTool: Hashable, Sendable {
    public var id: String
    public var title: String
    public var kind: ACPToolKind
    public var status: ACPToolStatus
    public var paths: [String]
    public var diffs: [HelperDiff]
    /// The first lines of what it printed, when the agent sent text.
    public var output: String?

    public init(
        id: String, title: String, kind: ACPToolKind = .other, status: ACPToolStatus = .pending,
        paths: [String] = [], diffs: [HelperDiff] = [], output: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.status = status
        self.paths = paths
        self.diffs = diffs
        self.output = output
    }
}

/// One edit's diff: the lines it took out and put in, as the agent reported them.
public struct HelperDiff: Hashable, Sendable {
    public var path: String
    public var lines: [DiffLine]

    public init(path: String, lines: [DiffLine]) {
        self.path = path
        self.lines = lines
    }

    public init(path: String, oldText: String?, newText: String) {
        self.path = path
        lines = LineDiff.lines(old: oldText ?? "", new: newText)
    }

    public var added: Int { lines.count { $0.kind == .added } }
    public var removed: Int { lines.count { $0.kind == .deleted } }
}

/// A file the helper changed, with its lines added and removed.
public struct HelperFile: Hashable, Sendable {
    public var path: String
    public var added: Int
    public var removed: Int

    public init(path: String, added: Int, removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// What a helper used, as the agent reports it (`usage_update`): context tokens and, when the agent knows it, cost.
public struct HelperUsage: Hashable, Sendable {
    public var tokens: Int
    public var window: Int
    public var cost: Double?

    public init(tokens: Int = 0, window: Int = 0, cost: Double? = nil) {
        self.tokens = tokens
        self.window = window
        self.cost = cost
    }
}

/// A permission the agent waits on: what it wants to do, and the options it offered.
public struct HelperPermission: Hashable, Sendable {
    public var requestID: JSONValue
    public var title: String
    public var command: String?
    public var kind: ACPToolKind
    public var options: [ACPPermissionRequest.Option]

    public init(
        requestID: JSONValue, title: String, command: String? = nil, kind: ACPToolKind = .other,
        options: [ACPPermissionRequest.Option]
    ) {
        self.requestID = requestID
        self.title = title
        self.command = command
        self.kind = kind
        self.options = options
    }

    public func option(_ kind: ACPPermissionRequest.Option.Kind) -> ACPPermissionRequest.Option? {
        options.first { $0.kind == kind }
    }
}

/// A helper: an agent heed started over ACP in a worktree of its own, for one PR, on your behalf. Everything it
/// shows comes from what the agent reported; nothing is made up while it works. It stays until you close it out.
public struct HelperRun: Identifiable, Hashable, Sendable {
    public enum Phase: Hashable, Sendable {
        /// Its worktree is being made, its agent started.
        case starting
        case working
        /// It asks permission (`permission`).
        case asking
        /// You paused it: its turn was cancelled; it goes on when you resume.
        case paused
        /// Its turn ended: the close-out waits for you.
        case done(ACPStopReason)
        /// It reached its spend cap or `run_timeout`, and heed stopped it.
        case stopped(String)
        /// It could not start or its agent went away: why.
        case failed(String)
        /// You closed it out: pushed, posted, thrown away or taken over.
        case closed(String)

        public var isLive: Bool {
            switch self {
            case .starting, .working, .asking, .paused: true
            case .done, .stopped, .failed, .closed: false
            }
        }

        /// Waiting for your close-out.
        public var awaitsCloseOut: Bool {
            switch self {
            case .done, .stopped: true
            default: false
            }
        }

        public var text: String {
            switch self {
            case .starting: "starting"
            case .working: "working"
            case .asking: "asks you"
            case .paused: "paused"
            case let .done(reason): reason == .endTurn ? "done" : reason.text
            case let .stopped(why): "stopped: \(why)"
            case let .failed(why): "failed: \(why)"
            case let .closed(how): how
            }
        }
    }

    public let id: String
    public let kind: HelperKind
    public let ref: PullRef
    /// The PR's title.
    public var title: String
    /// heed's agent name and how it is reached: `claude`, `claude via ACP`.
    public var agent: String
    public var adapter: String
    /// The session that tracks the PR, told about the helper (never typed into).
    public var sessionID: String?
    public var prBranch: String
    public var branch: String
    public var worktree: String
    public var startedAt: Date
    public var endedAt: Date?
    public var phase: Phase
    /// The agent's plan, as it last sent it; empty when it sends none.
    public var plan: [ACPPlanEntry]
    public var feed: [HelperEntry]
    public var usage: HelperUsage
    /// Dollars it may spend; 0: no cap.
    public var cap: Double
    public var permission: HelperPermission?
    /// How many permissions you answered.
    public var approvals: Int
    /// What it did, the replies it drafted, and what you can do with them, once its turn ended.
    public var closeOut: HelperCloseOut?
    /// The files it changed, from its diffs while it works and from git once it is done.
    public var files: [HelperFile]

    public init(
        id: String = UUID().uuidString.lowercased(), kind: HelperKind, ref: PullRef, title: String, agent: String,
        adapter: String, sessionID: String?, prBranch: String, branch: String, worktree: String, startedAt: Date,
        cap: Double
    ) {
        self.id = id
        self.kind = kind
        self.ref = ref
        self.title = title
        self.agent = agent
        self.adapter = adapter
        self.sessionID = sessionID
        self.prBranch = prBranch
        self.branch = branch
        self.worktree = worktree
        self.startedAt = startedAt
        phase = .starting
        plan = []
        feed = []
        usage = HelperUsage()
        self.cap = cap
        approvals = 0
        files = []
    }

    /// `Getting #2841 green`.
    public var headline: String { kind.title(ref.number) }

    /// `3 of 5`, when the agent sends a plan: the step under way (or the last done), and how many there are.
    public var planProgress: (step: Int, of: Int)? {
        guard !plan.isEmpty else { return nil }
        let done = plan.count { $0.status == .completed }
        let current = plan.firstIndex { $0.status == .inProgress }.map { $0 + 1 } ?? min(done + 1, plan.count)
        return (current, plan.count)
    }

    /// What it is doing now, in one line: the step under way, else the last thing it said or ran.
    public var now: String? {
        if case .asking = phase, let permission { return "wants to run " + (permission.command ?? permission.title) }
        if let step = plan.first(where: { $0.status == .inProgress }) { return step.content }
        for entry in feed.reversed() {
            switch entry.body {
            case let .message(text):
                if let line = text.split(whereSeparator: \.isNewline).last { return String(line) }
            case let .tool(tool): return tool.title
            case let .note(text): return text
            case .steer, .permission: continue
            }
        }
        return nil
    }

    /// The last few tool calls, newest last: what a live tile shows.
    public func recentTools(_ count: Int) -> [HelperTool] {
        Array(feed.compactMap { entry -> HelperTool? in
            if case let .tool(tool) = entry.body { return tool }
            return nil
        }.suffix(count))
    }

    public var addedLines: Int { files.reduce(0) { $0 + $1.added } }
    public var removedLines: Int { files.reduce(0) { $0 + $1.removed } }

    /// Whether it has spent its cap (only when the agent reports a cost).
    public var overCap: Bool {
        guard cap > 0, let cost = usage.cost else { return false }
        return cost >= cap
    }

    // MARK: What the agent reports

    /// Takes one `session/update` in: the feed, the plan, the files and the usage follow. Message chunks join the
    /// message they continue; a tool call's update changes its line in place.
    public mutating func apply(_ update: ACPUpdate, at time: Date) {
        switch update {
        case let .agentMessage(text):
            guard !text.isEmpty else { return }
            if let last = feed.indices.last, case let .message(previous) = feed[last].body {
                feed[last].body = .message(previous + text)
            } else {
                append(.message(text), at: time)
            }
        case .agentThought, .userMessage, .other:
            return
        case let .toolCall(call):
            let call = local(call)
            var tool = HelperTool(
                id: call.id, title: call.title ?? "a tool call", kind: call.kind ?? .other,
                status: call.status ?? .pending, paths: call.paths ?? []
            )
            absorb(call.content, into: &tool)
            if let index = toolIndex(call.id) {
                feed[index].body = .tool(tool)
            } else {
                feed.append(HelperEntry(id: call.id, at: time, body: .tool(tool)))
            }
            recount()
        case let .toolCallUpdate(call):
            let call = local(call)
            guard let index = toolIndex(call.id), case var .tool(tool) = feed[index].body else {
                // An update for a call heed never saw announced is the call.
                var call = call
                if call.title == nil { call.title = "a tool call" }
                apply(.toolCall(call), at: time)
                return
            }
            if let title = call.title { tool.title = title }
            if let kind = call.kind { tool.kind = kind }
            if let status = call.status { tool.status = status }
            if let paths = call.paths, !paths.isEmpty { tool.paths = paths }
            if call.content != nil {
                tool.diffs = []
                tool.output = nil
                absorb(call.content, into: &tool)
            }
            feed[index].body = .tool(tool)
            recount()
        case let .plan(entries):
            plan = entries
        case let .usage(used, size, cost, _):
            usage.tokens = used
            usage.window = size
            if let cost { usage.cost = cost }
        }
    }

    /// The agent asks before running a tool call.
    public mutating func ask(_ request: ACPPermissionRequest, id: JSONValue, at time: Date) {
        var request = request
        request.toolCall = local(request.toolCall)
        let title = request.toolCall.title ?? toolIndex(request.toolCall.id).flatMap { index -> String? in
            if case let .tool(tool) = feed[index].body { return tool.title }
            return nil
        } ?? "a tool call"
        permission = HelperPermission(
            requestID: id, title: title, command: request.toolCall.command, kind: request.toolCall.kind ?? .other,
            options: request.options
        )
        phase = .asking
        append(.permission(title: request.toolCall.command ?? title, answer: nil), at: time)
    }

    /// You answered the permission: `answer` is what the feed says (`allowed`, `denied`).
    public mutating func answered(_ answer: String) {
        permission = nil
        approvals += 1
        if let index = feed.lastIndex(where: {
            if case .permission(_, nil) = $0.body { return true }
            return false
        }), case let .permission(title, _) = feed[index].body {
            feed[index].body = .permission(title: title, answer: answer)
        }
        if case .asking = phase { phase = .working }
    }

    public mutating func append(_ body: HelperEntry.Body, at time: Date) {
        feed.append(HelperEntry(id: "\(id)-\(feed.count)", at: time, body: body))
    }

    /// A path as the feed shows it: relative to the helper's worktree when it is in it. Claude Code's adapter names
    /// every file absolutely (`Edit /Users/…/get-it-green-fix/src/a.cs`), in titles, locations and diffs alike, and
    /// on macOS a worktree under /tmp or /var comes back as /private/….
    public func local(_ path: String) -> String {
        for root in roots {
            if path == root { return "." }
            if path.hasPrefix(root + "/") { return String(path.dropFirst(root.count + 1)) }
        }
        return path
    }

    /// A tool call with its paths, its diffs' paths and the paths in its title made relative to the worktree.
    func local(_ call: ACPToolCall) -> ACPToolCall {
        guard !roots.isEmpty else { return call }
        var call = call
        call.paths = call.paths?.map(local)
        call.content = call.content?.map { item in
            if case let .diff(path, old, new) = item { return .diff(path: local(path), oldText: old, newText: new) }
            return item
        }
        if var title = call.title {
            for root in roots {
                title = title.replacingOccurrences(of: root + "/", with: "")
            }
            call.title = title
        }
        return call
    }

    /// The worktree as an agent may spell it, longest first.
    private var roots: [String] {
        let trimmed = worktree.hasSuffix("/") ? String(worktree.dropLast()) : worktree
        guard trimmed.hasPrefix("/"), trimmed.count > 1 else { return [] }
        let other = trimmed.hasPrefix("/private/") ? String(trimmed.dropFirst("/private".count)) : "/private" + trimmed
        return [trimmed, other].sorted { $0.count > $1.count }
    }

    private func toolIndex(_ id: String) -> Int? {
        feed.lastIndex { entry in
            if case let .tool(tool) = entry.body { return tool.id == id }
            return false
        }
    }

    private func absorb(_ content: [ACPToolContent]?, into tool: inout HelperTool) {
        for item in content ?? [] {
            switch item {
            case let .diff(path, old, new): tool.diffs.append(HelperDiff(path: path, oldText: old, newText: new))
            case let .text(text):
                let lines = Self.unfenced(text).split(whereSeparator: \.isNewline).prefix(4)
                if !lines.isEmpty { tool.output = lines.joined(separator: "\n") }
            case .terminal: break
            }
        }
    }

    /// Text without the Markdown code fence it came in: Claude Code's adapter sends a tool's output as
    /// "```\n…\n```", and the fence lines are no output of the tool's.
    static func unfenced(_ text: String) -> String {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard let first = lines.first, first.trimmingCharacters(in: .whitespaces).hasPrefix("```") else { return text }
        lines.removeFirst()
        if let last = lines.lastIndex(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }),
           lines[last].trimmingCharacters(in: .whitespaces) == "```"
        {
            lines.removeSubrange(last...)
        }
        return lines.joined(separator: "\n")
    }

    /// The files, from every diff in the feed: lines added and removed per path, as reported. Once it is done, git's
    /// count replaces this (`files` from `git diff --numstat`).
    private mutating func recount() {
        var order: [String] = []
        var counts: [String: (Int, Int)] = [:]
        for entry in feed {
            guard case let .tool(tool) = entry.body else { continue }
            for diff in tool.diffs {
                if counts[diff.path] == nil { order.append(diff.path) }
                let (added, removed) = counts[diff.path] ?? (0, 0)
                counts[diff.path] = (added + diff.added, removed + diff.removed)
            }
        }
        files = order.map { HelperFile(path: $0, added: counts[$0]!.0, removed: counts[$0]!.1) }
    }
}

/// The lines two texts differ in, by their longest common subsequence: what an edit's diff draws. Bounded: texts of
/// more than 400 lines a side are drawn as all out and all in.
public enum LineDiff {
    public static func lines(old: String, new: String) -> [DiffLine] {
        let left = old.isEmpty ? [] : old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let right = new.isEmpty ? [] : new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard left.count <= 400, right.count <= 400 else {
            return left.map { DiffLine(kind: .deleted, text: $0) } + right.map { DiffLine(kind: .added, text: $0) }
        }
        // lengths[i][j]: the common subsequence of left[i...] and right[j...].
        var lengths = Array(repeating: Array(repeating: 0, count: right.count + 1), count: left.count + 1)
        for i in stride(from: left.count - 1, through: 0, by: -1) {
            for j in stride(from: right.count - 1, through: 0, by: -1) {
                lengths[i][j] = left[i] == right[j] ? lengths[i + 1][j + 1] + 1 : max(
                    lengths[i + 1][j],
                    lengths[i][j + 1]
                )
            }
        }
        var out: [DiffLine] = []
        var i = 0
        var j = 0
        while i < left.count || j < right.count {
            if i < left.count, j < right.count, left[i] == right[j] {
                out.append(DiffLine(kind: .context, text: left[i]))
                i += 1
                j += 1
            } else if i < left.count, j == right.count || lengths[i + 1][j] >= lengths[i][j + 1] {
                // What goes out first, then what comes in, as git draws it.
                out.append(DiffLine(kind: .deleted, text: left[i]))
                i += 1
            } else {
                out.append(DiffLine(kind: .added, text: right[j]))
                j += 1
            }
        }
        return out
    }
}
