import Foundation

/// How an agent on a goal keeps it, in one place: the `heed-goal` skill in heed's Claude Code plugin renders it as a
/// skill, and agents without per-session plugins (codex) get the same rules as plain sentences in their instructions.
public enum GoalGuidance {
    /// One rule: what to do, and the command that does it (none for rules that are only about judgement).
    public struct Rule: Hashable, Sendable {
        public var text: String
        public var command: String?

        init(_ text: String, _ command: String? = nil) {
            self.text = text
            self.command = command
        }
    }

    /// The rules, in the order an agent meets them. Plain words: no quotes, backticks, dollars or backslashes, so they
    /// read the same on a command line and in TOML (`GoalPointer.plain`).
    public static let rules: [Rule] = [
        Rule(
            "Before you start, read the goal: what it is, what is not the goal, when it is done, its open questions, "
                + "decisions and items.",
            "heed goal show"
        ),
        Rule(
            "Keep to the Not the goal list. When the work seems to need more than the goal says, propose the change "
                + "instead of doing it (sections: goal, not-the-goal, done-when, question): a proposal waits for the "
                + "owner, nothing changes until they say yes.",
            "heed goal propose SECTION TEXT"
        ),
        Rule("When you take a decision that others on the goal should know, record it.", "heed goal decision add TEXT"),
        Rule(
            "When you hit a question you cannot answer from the code, record it; answer one when you find out.",
            "heed goal question add TEXT, heed goal question answer ID TEXT"
        ),
        Rule(
            "When you find work the goal needs that is not an item yet, add it. Split an item before handing parts to "
                + "subagents, and register what a subagent does under its name.",
            "heed goal item add TITLE --parent ID --by-subagent NAME"
        ),
        Rule(
            "Check a Done when criterion only with evidence: a test run, a PR, a benchmark, a link. Never without.",
            "heed goal criterion check N --evidence TEXT"
        ),
        Rule("Link the PRs you open to the goal and their item.", "heed goal link pr URL --item ID"),
        Rule(
            "Spawn a session on an item only when it is separate work that can run beside yours; heed caps spawns per "
                + "goal and asks the owner past the cap.",
            "heed goal item spawn ID"
        ),
        Rule(
            "Mark an item done when its work is finished, with what shows it.",
            "heed goal item done ID --evidence TEXT"
        ),
        Rule(
            "Finish with a short summary: what you did, decisions taken, questions left open, and where the goal "
                + "stands."
        ),
    ]

    /// What a swarm's lead does: draft the plan from GOAL.md, ask what it cannot decide, re-plan on feedback, and never
    /// touch the goal or the limits. Plain words, as `rules`.
    public static let leadRules: [Rule] = [
        Rule(
            "When this session leads a swarm, read the goal and the swarm first: its team, limits and whatever plan, "
                + "questions and feedback there already are.",
            "heed goal show, heed goal plan show"
        ),
        Rule(
            "Draft the plan as tasks the team can work on in parallel, each in its own worktree. Give every task an "
                + "id, a title, a phase, an owner from the team (agent, or agent:model), an estimate (15m, 1h 30m), "
                + "the ids it waits for (after) and how we will know it is done (doneWhen, checks evidence can show). "
                + "Take in open items already on the goal by using their ids.",
            "heed goal plan propose --file plan.json --note TEXT"
        ),
        Rule(
            "Ask the owner what you cannot decide from the goal and the code, with the choices you see; do not guess "
                + "scope.",
            "heed goal ask QUESTION --option A --option B"
        ),
        Rule(
            "When the owner answers or asks you to re-plan, read it and propose the next version. Before approval "
                + "every proposal is the draft; after it, reordering, owners, phases and estimates apply, while "
                + "adding, dropping or renaming tasks, what they wait for and when they are done wait for the owner.",
            "heed goal plan show"
        ),
        Rule(
            "Never change the goal or the swarm's limits, and never approve your own plan. When the plan needs the "
                + "goal to change (a new criterion, a new non-goal), put it under scope in the plan: it becomes a "
                + "proposal the owner decides."
        ),
        Rule(
            "Do not start the work yourself: workers start on the approved plan, and nothing runs before the owner "
                + "approves it."
        ),
    ]

    /// The rules as one paragraph of plain sentences, for agents that take instructions rather than a plugin.
    public static var instructions: String {
        "Keep the goal with the heed goal command (heed goal --help lists it; exit 4 means this session is on no "
            + "goal). " + rules.map { rule in
                rule.command.map { "\(rule.text) Run: \($0)." } ?? rule.text
            }.joined(separator: " ")
    }
}

/// heed's Claude Code plugin: `Application Support/Heed/plugin/`, passed per session with `claude --plugin-dir` to
/// sessions on a goal (never installed, never written into a repo or `~/.claude`). Layout as Claude Code loads a
/// plugin directory: `.claude-plugin/plugin.json` (the manifest) and `skills/<name>/SKILL.md` (a skill with
/// `name` and `description` front matter).
public enum HeedPlugin {
    public static let name = "heed"
    public static let skill = "heed-goal"

    /// The plugin's files, by path under its folder. `version` is heed's: a new heed rewrites them.
    public static func files(version: String) -> [String: String] {
        [
            ".claude-plugin/plugin.json": manifest(version: version),
            "skills/\(skill)/SKILL.md": skillText,
        ]
    }

    static func manifest(version: String) -> String {
        let object: [String: Any] = [
            "name": name,
            "version": version,
            "description": "What heed gives agents working on a goal: the heed-goal skill.",
            "author": ["name": "heed"],
        ]
        let data = (try? JSONSerialization.data(
            withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )) ?? Data()
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    static var skillText: String {
        var lines = [
            "---",
            "name: \(skill)",
            "description: This session works on a heed goal. Use it before starting work, and whenever you take a "
                + "decision, hit an open question, find new work, split work for subagents, meet a Done when "
                + "criterion, open a PR or would go beyond what the goal says.",
            "---",
            "",
            "# Keeping the goal",
            "",
            "This session belongs to a goal in heed, the app it runs in. The goal's GOAL.md says what the goal is, what "
                + "is not the goal and when it is done; heed keeps its items, evidence and proposals. You keep it "
                + "current with the `heed goal` command, which is on your PATH in this session and talks to heed. "
                + "`heed goal --help` lists every command; add `--json` to any of them for output to parse.",
            "",
            "Records (decisions, answers, items, criteria met with evidence) apply at once and can be undone in heed. "
                + "Scope changes (the goal, Not the goal, Done when, new open questions in GOAL.md) become proposals "
                + "that wait for the owner; nothing changes until they accept.",
            "",
            "## Rules",
            "",
        ]
        for rule in GoalGuidance.rules {
            lines.append("- " + rule.text + (rule.command.map { " `\($0)`" } ?? ""))
        }
        lines += [
            "",
            "## Leading a swarm",
            "",
            "A goal can have a swarm run: a lead agent drafts a plan, the owner approves it, and a team of agents works "
                + "on it in parallel. When heed starts this session as a swarm's lead it says so in the first prompt; "
                + "these rules are then yours.",
            "",
        ]
        for rule in GoalGuidance.leadRules {
            lines.append("- " + rule.text + (rule.command.map { " `\($0)`" } ?? ""))
        }
        lines += [
            "",
            "The plan's JSON: `{\"note\": \"…\", \"tasks\": [{\"id\": \"profile\", \"title\": \"…\", "
                + "\"phase\": \"Spike\", \"owner\": \"claude\", \"estimate\": \"15m\", \"after\": [], "
                + "\"doneWhen\": [\"…\"]}], \"scope\": [{\"section\": \"not-the-goal\", \"text\": \"…\"}]}`.",
            "",
            "## Exit codes",
            "",
            "0 done or proposed, 1 refused (nothing changed, the message says why), 2 wrong usage, 3 heed not "
                + "reachable, 4 this session is on no goal (`heed goal attach <goal>` or `--goal <id>`), 5 held for "
                + "the owner in heed's Attention (a spawn over the goal's cap).",
            "",
        ]
        return lines.joined(separator: "\n")
    }

    /// Writes the plugin into `folder` when what is there differs: files changed by a new heed are rewritten, files
    /// heed no longer ships are removed. Off the main actor.
    public static func write(to folder: URL, version: String) throws {
        let wanted = files(version: version)
        let manager = FileManager.default
        if let found = manager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in found where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?
                .isRegularFile == true
            {
                let relative = String(url.standardizedFileURL.path.dropFirst(folder.standardizedFileURL.path.count + 1))
                if wanted[relative] == nil { try manager.removeItem(at: url) }
            }
        }
        for (path, content) in wanted {
            let url = folder.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? String(contentsOf: url, encoding: .utf8)) != content {
                try content.write(to: url, atomically: true, encoding: .utf8)
            }
        }
    }
}

/// The first prompt of a swarm's lead session: who it is, what to read, what to do and what never to do.
public enum SwarmLead {
    public static func prompt(goal title: String, doc path: String, swarm: GoalSwarm) -> String {
        let settings = swarm.settings
        let workers = settings.workers.isEmpty ? settings.lead.label : settings.workers.map(\.label)
            .joined(separator: ", ")
        var lines = [
            "You lead swarm \(swarm.number) on the goal \(title). Its GOAL.md is \(path).",
            "",
            "Draft the plan: the tasks that reach the goal, for a team of \(workers), within \(settings.limits.line). "
                + "Each task works in its own worktree; there is no file ownership, overlaps are sorted out at merge.",
            "",
        ]
        lines += GoalGuidance.leadRules.map { rule in
            "- " + rule.text + (rule.command.map { " Run: \($0)." } ?? "")
        }
        lines += [
            "",
            "Once the plan is proposed and your questions are asked, stop and wait: the owner reads it in heed and "
                + "answers, asks for a re-plan or approves.",
        ]
        return lines.joined(separator: "\n")
    }
}
