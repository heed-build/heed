import Foundation

/// A merged PR heed could try a persona on.
public struct PullListing: Hashable, Sendable {
    public var number: Int
    public var title: String
    public var mergedAt: Date?
    /// Lines added and deleted.
    public var size: Int

    public init(number: Int, title: String, mergedAt: Date? = nil, size: Int = 0) {
        self.number = number
        self.title = title
        self.mergedAt = mergedAt
        self.size = size
    }

    /// `gh pr list --state merged --json number,title,mergedAt,additions,deletions`.
    public static func parse(_ data: Data) -> [PullListing] {
        guard let rows = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] else { return [] }
        let iso = ISO8601DateFormatter()
        return rows.compactMap { row in
            guard let number = row["number"] as? Int else { return nil }
            let size = (row["additions"] as? Int ?? 0) + (row["deletions"] as? Int ?? 0)
            return PullListing(
                number: number, title: row["title"] as? String ?? "",
                mergedAt: (row["mergedAt"] as? String).flatMap(iso.date(from:)), size: size
            )
        }
    }
}

/// The PR a trial reads: its diff (cut), and what its review said, where.
public struct PullSample: Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var mergedAt: Date?
    public var diff: String
    /// What reviewers wrote, first lines.
    public var reviewSaid: [String]
    /// The files review commented on.
    public var reviewPaths: Set<String>

    public init(
        repo: String, number: Int, title: String, mergedAt: Date? = nil, diff: String, reviewSaid: [String] = [],
        reviewPaths: Set<String> = []
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.mergedAt = mergedAt
        self.diff = diff
        self.reviewSaid = reviewSaid
        self.reviewPaths = reviewPaths
    }

    /// The files the diff changes.
    public var files: [String] {
        diff.split(separator: "\n").compactMap { line in
            guard line.hasPrefix("diff --git a/") else { return nil }
            return line.components(separatedBy: " b/").last
        }
    }
}

/// A persona tried on a real PR: what it would have said, and where it points.
public struct PersonaTrial: Hashable, Sendable {
    public var repo: String
    public var number: Int
    public var title: String
    public var mergedAt: Date?
    public var verdict: PanelVerdict.Kind
    public var quote: String
    /// `redirects/legacy.yml:41, 88`: only files the diff changes.
    public var lines: [String]
    /// What review actually said, when it said something.
    public var reviewSaid: String?
    /// It pointed at a file review commented on too; nil when review said nothing about files.
    public var agrees: Bool?

    public init(
        repo: String, number: Int, title: String, mergedAt: Date? = nil, verdict: PanelVerdict.Kind, quote: String,
        lines: [String] = [], reviewSaid: String? = nil, agrees: Bool? = nil
    ) {
        self.repo = repo
        self.number = number
        self.title = title
        self.mergedAt = mergedAt
        self.verdict = verdict
        self.quote = quote
        self.lines = lines
        self.reviewSaid = reviewSaid
        self.agrees = agrees
    }

    /// The most diff a trial reads.
    public static let diffLimit = 14000

    /// The next PR to try: merged, the newest first, not tried yet, big enough to say something about and small
    /// enough to read (5 to 1500 lines); else any not tried.
    public static func pick(_ pulls: [PullListing], tried: Set<Int>) -> PullListing? {
        let fresh = pulls.filter { !tried.contains($0.number) }
            .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        return fresh.first { (5 ... 1500).contains($0.size) } ?? fresh.first
    }

    static let system = """
    You review a merged pull request as one persona, in its voice, as if before it merged. Say whether this persona \
    would be happy (fine as it is), have a concern (fine if one thing changes) or say not (should not merge like \
    this). Quote what it would say in at most twenty-five words, first person, concrete. Point at the lines it means \
    as "path:line" from the diff (new line numbers), at most three. Reply with only JSON: {"verdict": \
    "happy|concern|not", "quote": "...", "lines": ["path:41, 88"]}.
    """

    public static func prompt(_ persona: Persona, pull: PullSample) -> String {
        let diff = pull.diff.count <= diffLimit ? pull.diff : String(pull.diff.prefix(diffLimit)) + "\n… (cut)"
        return "# The persona\n\(persona.brief)\n\n# PR #\(pull.number) in \(pull.repo): \(pull.title)\n\n\(diff)"
    }

    /// The model's answer, against the PR: lines that name a file the diff does not change are dropped.
    public static func parse(_ text: String, pull: PullSample) -> PersonaTrial? {
        guard let data = LLMDialect.jsonObject(in: text),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = PanelVerdict.Kind(word: object["verdict"] as? String ?? "")
        else { return nil }
        let files = pull.files
        let lines = SwarmPlanInput.strings(object["lines"]).map(GoalDoc.oneLine).filter { line in
            let path = line.split(separator: ":").first.map(String.init) ?? line
            return files.contains { $0 == path || $0.hasSuffix("/" + path) }
        }
        let quote = GoalDoc.oneLine(object["quote"] as? String ?? "").trimmingCharacters(in: CharacterSet(
            charactersIn: "\"“”"
        ))
        let pointed = Set(lines.compactMap { $0.split(separator: ":").first.map(String.init) })
        let agrees: Bool? = pull.reviewPaths.isEmpty ? nil : pointed.contains { path in
            pull.reviewPaths.contains { $0 == path || $0.hasSuffix("/" + path) }
        }
        return PersonaTrial(
            repo: pull.repo, number: pull.number, title: pull.title, mergedAt: pull.mergedAt, verdict: kind,
            quote: quote, lines: Array(lines.prefix(3)), reviewSaid: pull.reviewSaid.first, agrees: agrees
        )
    }

    /// `gh api repos/{repo}/pulls/{n}/comments` and the reviews' bodies: what review said, and on which files.
    public static func review(comments: Data?, reviews: Data?) -> (said: [String], paths: Set<String>) {
        let rows = comments.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [[String: Any]] } ?? []
        var said = rows.compactMap { ($0["body"] as? String).map(GoalDoc.oneLine) }
        let paths = Set(rows.compactMap { $0["path"] as? String })
        let object = reviews.flatMap { (try? JSONSerialization.jsonObject(with: $0)) as? [String: Any] }
        said += (object?["reviews"] as? [[String: Any]] ?? []).compactMap { ($0["body"] as? String)
            .map(GoalDoc.oneLine)
        }
        return (said.filter { !$0.isEmpty }.map { String($0.prefix(240)) }, paths)
    }
}

/// The library's cheap model calls (heed's model calls: the cheap model, tools off): proposing the people your repos
/// serve from a digest, and trying a persona on a PR. Each returns what it read and what it cost.
public struct PersonaCalls: Sendable {
    public typealias Run = @Sendable (LLMRequest) async throws -> LLMResponse
    private let run: Run

    public init(run: @escaping Run) {
        self.run = run
    }

    public static let caller = "settings.personas"

    /// What a call cost: the model, dollars (nil: not reported), seconds.
    public struct Cost: Hashable, Sendable {
        public var model: String?
        public var dollars: Double?
        public var seconds: Double

        public init(model: String?, dollars: Double?, seconds: Double) {
            self.model = model
            self.dollars = dollars
            self.seconds = seconds
        }
    }

    static let proposeSystem = """
    You read a compact digest of software repositories and name the people they serve whose view a reviewer should \
    take: maintainers of a part, the users of a file or a feature, newcomers, operators. Only people the evidence \
    points at; name the evidence from the digest (counts, files, owners, labels, checks). For each: a short name, who \
    they are in at most six words, the one question they ask first, what they are skeptical about, two to four \
    pieces of evidence, a one-line summary of the evidence (at most eight words, joined by " · "), how strongly the \
    evidence points at them from 0 to 100, its scope ("repo org/name" or "org name") and the id of a known persona it \
    overlaps or null. Three to six people. Reply with only JSON: {"personas": [{"name": "...", "who": "...", \
    "asksFirst": "...?", "skepticalAbout": ["..."], "evidence": ["..."], "summary": "...", "strength": 0, \
    "scope": "...", "overlaps": null}]}.
    """

    static let describeSystem = """
    The developer describes one person whose view a reviewer should take. Draft that persona, using the repositories' \
    digest where it says something about them. Reply with only JSON: {"personas": [{"name": "...", "who": "...", \
    "asksFirst": "...?", "skepticalAbout": ["..."], "evidence": ["..."], "summary": "...", "strength": 0, \
    "scope": "...", "overlaps": null}]} with exactly one person.
    """

    /// The people the repos serve; with `describe`, the one you described.
    public func propose(
        digest: PersonaDigest, library: [Persona], describe: String? = nil, now: Date
    ) async throws -> ([PersonaProposal], Cost) {
        let repos = digest.reads.map(\.repo)
        let known = library.map { "- \($0.id): \($0.name)" + ($0.who.isEmpty ? "" : ", \($0.who)") }
        var prompt = "# Known personas\n" + known.joined(separator: "\n") + "\n\n# The repositories\n"
            + digest.render()
        if let describe { prompt = "# The developer describes\n\(describe)\n\n" + prompt }
        let response = try await run(LLMRequest(
            call: LLMCall(system: describe == nil ? Self.proposeSystem : Self.describeSystem, prompt: prompt),
            priority: .interactive, caller: Self.caller, operation: describe == nil ? "propose personas" :
                "describe a persona"
        ))
        let proposals = PersonaProposals.parse(
            response.text, repos: repos, library: library, described: describe != nil, now: now
        )
        guard !proposals.isEmpty else { throw LLMError.unparseable(agent: response.agent, text: response.text) }
        return (proposals, Self.cost(response))
    }

    /// The persona's verdict on a PR.
    public func trial(_ persona: Persona, pull: PullSample) async throws -> (PersonaTrial, Cost) {
        let response = try await run(LLMRequest(
            call: LLMCall(system: PersonaTrial.system, prompt: PersonaTrial.prompt(persona, pull: pull)),
            priority: .interactive, caller: Self.caller, operation: "try a persona on a PR"
        ))
        guard let trial = PersonaTrial.parse(response.text, pull: pull) else {
            throw LLMError.unparseable(agent: response.agent, text: response.text)
        }
        return (trial, Self.cost(response))
    }

    static func cost(_ response: LLMResponse) -> Cost {
        Cost(model: response.model, dollars: response.fromCache ? 0 : response.cost, seconds: response.duration)
    }
}
