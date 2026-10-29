import Foundation

/// What a lead hands heed with `heed goal plan propose`: JSON, either a list of tasks or an object with `tasks`, a
/// `note` and `scope` (GOAL.md changes the plan would need, which become proposals and never apply on their own).
///
/// ```json
/// {"note": "first draft",
///  "tasks": [{"id": "profile", "title": "Profile the build", "phase": "Spike", "owner": "claude",
///             "estimate": "15m", "after": [], "doneWhen": ["a profile of every build step"]}],
///  "scope": [{"section": "not-the-goal", "text": "rewriting the bundler"}]}
/// ```
///
/// A task's `id` names it in `after`; an id of an item already on the goal takes that item into the plan. Without an id
/// a task keeps the id of the current plan's task with the same title, or gets one made from its title. `owner` is an
/// agent (`claude`), `agent:model`, or `{"agent": …, "model": …}`; `estimate` minutes or `15m`, `1h 30m`; `host` where
/// its worker runs when not where the swarm does (a host's name, or `local` for the owner's Mac).
public struct SwarmPlanInput: Hashable, Sendable {
    public struct Scope: Hashable, Sendable {
        public var section: GoalEdit.Section
        public var text: String
    }

    public var tasks: [SwarmTask]
    public var note: String?
    public var scope: [Scope]

    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// Reads `json` for `goal`. `current` is the plan as it is (ids kept by title), `items` the goal's items (ids taken
    /// in, slugs not to reuse).
    public static func parse(
        _ json: String, goal: String, current: [SwarmTask] = [], items: [GoalItem] = []
    ) throws -> SwarmPlanInput {
        guard let data = json.data(using: .utf8), !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ParseError(description: "no plan given: pass JSON with --file PATH, or on stdin with --file -")
        }
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)
        } catch {
            throw ParseError(description: "the plan is not JSON: \((error as NSError).localizedDescription)")
        }
        var note: String?
        var scope: [Scope] = []
        let rawTasks: [Any]
        if let list = object as? [Any] {
            rawTasks = list
        } else if let dictionary = object as? [String: Any] {
            guard let list = dictionary["tasks"] as? [Any] else {
                throw ParseError(description: "the plan needs \"tasks\": a list of tasks")
            }
            rawTasks = list
            note = (dictionary["note"] as? String).map(GoalDoc.oneLine).flatMap { $0.isEmpty ? nil : $0 }
            for entry in dictionary["scope"] as? [Any] ?? [] {
                guard let entry = entry as? [String: Any], let word = entry["section"] as? String,
                      let section = GoalCommandLine.section(word),
                      let text = (entry["text"] as? String).map(GoalDoc.oneLine), !text.isEmpty
                else {
                    throw ParseError(
                        description: "each scope change needs a section (\(GoalCommandLine.sections.joined(separator: ", "))) and text"
                    )
                }
                scope.append(Scope(section: section, text: text))
            }
        } else {
            throw ParseError(description: "the plan is a list of tasks, or an object with \"tasks\"")
        }
        var taken = Set(items.filter { $0.goal == goal }.map(\.slug))
        let itemIDs = Set(items.filter { $0.goal == goal }.map(\.id))
        var tasks: [SwarmTask] = []
        // Words a task names others by (its id as written, its slug, its full id) → its full id.
        var names: [String: String] = [:]
        var lastPhase = "Plan"
        for (index, raw) in rawTasks.enumerated() {
            guard let entry = raw as? [String: Any] else {
                throw ParseError(description: "task \(index + 1) is not an object")
            }
            let title = GoalDoc.oneLine(entry["title"] as? String ?? "")
            guard !title.isEmpty else { throw ParseError(description: "task \(index + 1) has no title") }
            let written = (entry["id"] as? String).map { $0.trimmingCharacters(in: .whitespaces) }
                .flatMap { $0.isEmpty ? nil : $0 }
            let id: String
            if let written, let existing = resolve(written, goal: goal, ids: itemIDs) {
                id = existing
            } else if let written {
                let slug = GoalSlug.make(written, taken: [])
                id = "\(goal)/\(slug)"
                taken.insert(slug)
            } else if let kept = current.first(where: { GoalEdits.same($0.title, title) }),
                      !tasks.contains(where: { $0.id == kept.id })
            {
                id = kept.id
                taken.insert(kept.slug)
            } else {
                let slug = GoalSlug.make(title, taken: taken.union(current.map(\.slug)))
                id = "\(goal)/\(slug)"
                taken.insert(slug)
            }
            if let written { names[written] = id }
            names[id] = id
            names[SwarmPlan.short(id)] = id
            let phase = (entry["phase"] as? String).map(GoalDoc.oneLine).flatMap { $0.isEmpty ? nil : $0 } ?? lastPhase
            lastPhase = phase
            let estimate: Int? = if let minutes = entry["estimate"] as? Double {
                minutes > 0 ? Int(minutes.rounded()) : nil
            } else if let text = entry["estimate"] as? String {
                try SwarmEstimate.minutes(text) ?? {
                    throw ParseError(description: "task \(index + 1): no estimate in \"\(text)\" (15m, 1h 30m)")
                }()
            } else { nil }
            try tasks.append(SwarmTask(
                id: id, title: title, phase: phase, owner: owner(entry["owner"], index: index),
                estimate: estimate, after: strings(entry["after"]),
                doneWhen: strings(entry["doneWhen"] ?? entry["done_when"] ?? entry["done"]).map(GoalDoc.oneLine)
                    .filter { !$0.isEmpty },
                host: host(entry["host"], index: index)
            ))
        }
        // `after` may name tasks by what the lead wrote, their slug, or items already on the goal.
        for index in tasks.indices {
            tasks[index].after = tasks[index].after.map { word in
                names[word] ?? resolve(word, goal: goal, ids: itemIDs) ?? word
            }
        }
        return SwarmPlanInput(tasks: tasks, note: note, scope: scope)
    }

    /// A goal's item by its id or slug.
    static func resolve(_ word: String, goal: String, ids: Set<String>) -> String? {
        if ids.contains(word) { return word }
        return ids.contains("\(goal)/\(word)") ? "\(goal)/\(word)" : nil
    }

    static func strings(_ value: Any?) -> [String] {
        if let text = value as? String { return text.isEmpty ? [] : [text] }
        return (value as? [Any] ?? []).compactMap { $0 as? String }.filter { !$0.isEmpty }
    }

    /// A task's `host`: a host's name (`devbox`, `@devbox`), `local`, or nothing (where the swarm runs).
    static func host(_ value: Any?, index: Int) throws -> String? {
        if value == nil || value is NSNull { return nil }
        guard let text = value as? String else {
            throw ParseError(description: "task \(index + 1): host is a host's name, or local for the owner's Mac")
        }
        switch SwarmPlace.parse(text) {
        case let .success(host): return host
        case let .failure(problem): throw ParseError(description: "task \(index + 1): \(problem.text)")
        }
    }

    static func owner(_ value: Any?, index: Int) throws -> GoalItem.Owner? {
        if value == nil || value is NSNull { return nil }
        if let text = value as? String {
            let parts = text.split(whereSeparator: { $0 == ":" || $0 == "·" }).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            guard let agent = parts.first, !agent.isEmpty else { return nil }
            return GoalItem.Owner(agent: agent, model: parts.count > 1 ? parts[1] : nil)
        }
        if let object = value as? [String: Any], let agent = object["agent"] as? String, !agent.isEmpty {
            return GoalItem.Owner(
                agent: agent, model: object["model"] as? String, effort: (object["effort"] as? String)?.lowercased()
            )
        }
        throw ParseError(
            description: "task \(index + 1): owner is an agent name, agent:model, or {agent, model, effort}"
        )
    }
}
