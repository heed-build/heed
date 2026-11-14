import Foundation

/// Defining a persona with an agent (Add a persona, ⌘↩): an ACP session in the persona's repo that reads and writes
/// nothing (`DefinePolicy`), asks what it cannot tell from the repo one question at a time, and builds the persona; the
/// lines it added or changed are marked. A trial on a real PR shows what it would have said. Nothing is in the library
/// until you save it.
public struct PersonaDefinition: Hashable, Sendable {
    public typealias Turn = PartDefinition.Turn

    /// The proposal it started from.
    public var start: Persona
    /// The persona as the agent would define it now.
    public var draft: Persona
    public var agent: String
    /// `claude via ACP`.
    public var via: String
    /// The repo it reads (`acme/docs-website`), and where it is on this Mac.
    public var repo: String?
    public var turns: [Turn]
    /// What it read: `redirects/ · 12 files`.
    public var reads: [String]
    public var seconds: Double
    public var cost: Double?
    public var working: Bool
    public var problem: String?
    /// Its last trial on a PR, and the PRs tried.
    public var trial: PersonaTrial?
    public var tried: Set<Int>
    public var trying: Bool

    public init(start: Persona, agent: String, via: String, repo: String?) {
        self.start = start
        draft = start
        self.agent = agent
        self.via = via
        self.repo = repo
        turns = []
        reads = []
        seconds = 0
        working = false
        tried = []
        trying = false
    }

    public var id: String { start.id }

    /// The agent's question waiting for you.
    public var openQuestion: Turn? {
        guard let last = turns.last, last.role == .agent, !last.options.isEmpty, last.picked == nil else { return nil }
        return last
    }

    /// The fields an agent may change, as its JSON names them.
    public struct Patch: Hashable, Sendable {
        public var who: String?
        public var about: String?
        public var asksFirst: [String]?
        public var skepticalAbout: [String]?
        public var knows: [String]?
        public var may: [String]?
        public var mayNot: [String]?

        public init(
            who: String? = nil, about: String? = nil, asksFirst: [String]? = nil, skepticalAbout: [String]? = nil,
            knows: [String]? = nil, may: [String]? = nil, mayNot: [String]? = nil
        ) {
            self.who = who
            self.about = about
            self.asksFirst = asksFirst
            self.skepticalAbout = skepticalAbout
            self.knows = knows
            self.may = may
            self.mayNot = mayNot
        }

        var isEmpty: Bool { self == Patch() }

        /// The persona with the patch in: each field it names replaced, the rest kept.
        public func applied(to persona: Persona) -> Persona {
            var persona = persona
            if let who { persona.who = who }
            if let about { persona.about = about }
            if let asksFirst { persona.asksFirst = asksFirst }
            if let skepticalAbout { persona.skepticalAbout = skepticalAbout }
            if let knows { persona.knows = knows }
            if let may { persona.may = may }
            if let mayNot { persona.mayNot = mayNot }
            return persona
        }
    }

    /// A reply: what it says, its options, and the persona as it would have it, from the JSON line it ends with.
    public static func read(_ reply: String) -> (text: String, options: [String], patch: Patch?) {
        let lines = reply.components(separatedBy: "\n")
        guard let index = lines.lastIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("{") }),
              let data = LLMDialect.jsonObject(in: lines[index...].joined(separator: "\n")),
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else { return (reply.trimmingCharacters(in: .whitespacesAndNewlines), [], nil) }
        var text = lines[..<index].joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix("```json") || text.hasSuffix("```") {
            text = String(text.dropLast(text.hasSuffix("```json") ? 7 : 3))
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let question = (object["question"] as? String).map(GoalDoc.oneLine), !question.isEmpty,
           !text.contains(question)
        {
            text += (text.isEmpty ? "" : "\n\n") + question
        }
        let options = SwarmPlanInput.strings(object["options"]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
        let fields = object["persona"] as? [String: Any] ?? [:]
        func list(_ keys: String...) -> [String]? {
            for key in keys where fields[key] != nil {
                return SwarmPlanInput.strings(fields[key]).map(GoalDoc.oneLine).filter { !$0.isEmpty }
            }
            return nil
        }
        func line(_ key: String) -> String? {
            (fields[key] as? String).map(GoalDoc.oneLine).flatMap { $0.isEmpty ? nil : $0 }
        }
        let patch = Patch(
            who: line("who"), about: line("about"), asksFirst: list("asksFirst", "asks_first"),
            skepticalAbout: list("skepticalAbout", "skeptical_about"), knows: list("knows"), may: list("may"),
            mayNot: list("mayNot", "may_not")
        )
        return (text, options, patch.isEmpty ? nil : patch)
    }

    /// The agent's reply in: its turn, and the persona as it has it now.
    public mutating func received(_ reply: String) {
        let (text, options, patch) = Self.read(reply)
        turns.append(Turn(role: .agent, text: text, options: options))
        if let patch { draft = patch.applied(to: draft) }
    }

    /// You took option `index` of its question: marked, and sent as your answer.
    @discardableResult
    public mutating func pick(_ index: Int) -> String? {
        guard let last = turns.indices.last, turns[last].role == .agent, turns[last].options.indices.contains(index)
        else { return nil }
        turns[last].picked = index
        let answer = turns[last].options[index]
        turns.append(Turn(role: .you, text: answer))
        return answer
    }

    public mutating func say(_ text: String) {
        turns.append(Turn(role: .you, text: text))
    }

    /// The lines the agent added or changed since the proposal, to mark: each new item of a list, and `who` and
    /// `about` when they changed.
    public var changed: Set<String> {
        func new(_ now: [String], _ was: [String]) -> [String] {
            now.filter { item in !was.contains { $0.lowercased() == item.lowercased() } }
        }
        var marked = Set<String>()
        marked.formUnion(new(draft.asksFirst, start.asksFirst))
        marked.formUnion(new(draft.skepticalAbout, start.skepticalAbout))
        marked.formUnion(new(draft.knows, start.knows))
        marked.formUnion(new(draft.may, start.may))
        marked.formUnion(new(draft.mayNot, start.mayNot))
        if draft.who != start.who, !draft.who.isEmpty { marked.insert(draft.who) }
        if draft.about != start.about, !draft.about.isEmpty { marked.insert(draft.about) }
        return marked
    }

    /// What the agent is told first: read, write nothing, ask one question at a time, end with the JSON line.
    public static let system = """
    You help define one persona: a kind of person whose view a reviewer takes on this repository's changes. Read the \
    repository as much as you need (read and search only: do not edit, create or delete files, and run nothing). \
    Then ask the developer one question at a time about what you cannot tell from the repository, with two or three \
    short options. After each answer, update the persona. End every reply with one line of JSON and nothing after \
    it: {"question": "..." or null, "options": ["..."], "persona": {"who": "at most six words", "about": "one or two \
    sentences", "asksFirst": ["...?"], "skepticalAbout": ["..."], "may": ["read", "comment"], "mayNot": ["..."]}}.
    """

    public static func prompt(_ persona: Persona, repo: String?) -> String {
        var lines = [system, "", "# The persona so far", persona.render()]
        if let repo { lines += ["", "# The repository", repo] }
        return lines.joined(separator: "\n")
    }
}
