import HeedCore
import SwiftUI

// Settings › Work: Worktrees, Goals, History.

struct WorktreesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.config.work
        let rule = model.config.cleanup
        SettingsCard(title: "Worktrees") {
            SettingRow("worktrees.root") {
                ConfigTextField(path: ["worktrees", "root"], value: work.worktreeRoot)
            }
            SettingRow("worktrees.repo_roots") {
                ListField(path: ["worktrees", "repo_roots"], values: work.repoRoots)
            }
            SettingRow("worktrees.repo_paths", defaultText: "none") {
                ListField(path: ["worktrees", "repo_paths"], values: work.repoPaths)
            }
            SettingRow("worktrees.offer_trust") {
                ConfigSwitch(path: ["worktrees", "offer_trust"], isOn: work.offerTrust)
            }
            SettingRow("worktrees.after_add") {
                SegmentedChoice(
                    path: ["worktrees", "after_add"], value: work.afterAdd,
                    options: AfterAdd.allCases.map { ($0, $0.title) }, name: \.rawValue, width: 300
                )
            }
        }
        SettingsCard(title: "Branch names") {
            SettingRow("worktrees.default_prefix") {
                ConfigTextField(path: ["worktrees", "default_prefix"], value: work.prefixes.defaultPrefix, width: 120)
            }
            SettingRow("worktrees.prefixes", defaultText: "fix, feature, docs and the rest heed ships") {
                TableSummary(count: work.prefixes.prefixes.count, noun: "prefix")
            }
        }
        SettingsCard(title: "Start work") {
            SettingRow(
                "start_work.smart_guesses",
                detail: "The on-device model suggests the repo, the branch name and its prefix as you type; your own "
                    + "picks always win. \(model.isFixture ? "Apple's on-device model is ready." : SmartGuesses.status)"
            ) {
                ConfigSwitch(path: ["start_work", "smart_guesses"], isOn: model.config.startWork.smartGuesses)
            }
        }
        SettingsCard(title: "Cleanup") {
            SettingRow("cleanup.enabled") {
                ConfigSwitch(path: ["cleanup", "enabled"], isOn: rule.enabled)
            }
            SettingRow("cleanup.idle_days", unit: "days") {
                NumberField(path: ["cleanup", "idle_days"], value: rule.idleDays, unit: "days", range: 1 ... 365)
            }
            SettingRow("cleanup.delete_branch") {
                ConfigSwitch(path: ["cleanup", "delete_branch"], isOn: rule.deleteBranch)
            }
            SettingRow("cleanup.ask_before_sweep") {
                ConfigSwitch(path: ["cleanup", "ask_before_sweep"], isOn: rule.askBeforeSweep)
            }
        }
        SettingsCard(title: "Saved work") {
            SettingRow("cleanup.keep_archive_days", unit: "days") {
                NumberField(
                    path: ["cleanup", "keep_archive_days"], value: rule.keepArchiveDays, unit: "days",
                    range: 0 ... 3650, step: 30
                )
            }
        }
    }
}

struct GoalsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let goals = model.config.goals
        let mirror = goals.mirror
        SettingsCard(title: "Agents") {
            SettingRow("goals.tell_agents") {
                ConfigSwitch(path: ["goals", "tell_agents"], isOn: goals.tellAgents)
            }
            CardNote {
                Text("Finding new work's goal, with its two thresholds:")
                PageLink(page: .decisions)
            }
        }
        SettingsCard(title: "Reviewers") {
            SettingRow("goals.auto_review") {
                ConfigSwitch(path: ["goals", "auto_review"], isOn: goals.autoReview)
            }
            SettingRow("goals.reviewer_runs_per_day", unit: "runs") {
                NumberField(
                    path: ["goals", "reviewer_runs_per_day"], value: goals.reviewerRunsPerDay, unit: "runs",
                    range: 0 ... 100
                )
            }
            SettingRow("goals.reviewer_agent", defaultText: "the goal's session's agent") {
                MenuChoice(
                    path: ["goals", "reviewer_agent"], value: goals.reviewerAgent,
                    options: [("", "the goal's agent")] + model.settings.agents.map { ($0.name, $0.name) },
                    width: 160
                )
            }
            SettingRow("goals.bars", defaultText: "the built-in bars") {
                TableSummary(count: goals.bars.rows.count, noun: "row")
            }
            SettingRow("goals.reviewers", defaultText: "the built-in models") {
                TableSummary(count: goals.reviewerTiers.count, noun: "reviewer")
            }
        }
        SettingsCard(title: "Items") {
            SettingRow("goals.spawn_concurrent", unit: "at once") {
                NumberField(
                    path: ["goals", "spawn_concurrent"], value: goals.spawnConcurrent, unit: "runs", range: 0 ... 50
                )
            }
            SettingRow("goals.spawn_per_day", unit: "a day") {
                NumberField(
                    path: ["goals", "spawn_per_day"], value: goals.spawnPerDay, unit: "a day", range: 0 ... 500
                )
            }
        }
        SettingsCard(title: "GitHub mirror") {
            SettingRow("goals.tracker", defaultText: "none") {
                ConfigTextField(path: ["goals", "tracker"], value: mirror.tracker, placeholder: "org/name", width: 200)
            }
            SettingRow("goals.mirror") {
                ConfigSwitch(path: ["goals", "mirror"], isOn: mirror.on)
            }
            SettingRow("goals.mirror_label") {
                ConfigTextField(path: ["goals", "mirror_label"], value: mirror.label, width: 140)
            }
            CardNote {
                Text("Orgs and repos set their own tracker and mirroring:")
                // On the tab the goal tracker is on.
                PageLink(page: .orgsAndRepos) { model.orgRepoTab = Overrides.tab(of: "goals_tracker") }
            }
        }
    }
}

struct HistoryPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let config = model.config
        let ledger = config.ledger
        let standup = config.standup
        let log = config.log
        SettingsCard(
            title: "Ledger",
            note: "A cheap model (Model calls) writes a short summary of each piece of work; S in the ledger writes "
                + "one any time. Summaries stay on this Mac."
        ) {
            SettingRow("summary.when", stacked: true) {
                ChipToggles(
                    path: ["summary", "when"], options: LedgerTrigger.configurable.map { ($0.rawValue, $0.title) },
                    chosen: Set(ledger.when.map(\.rawValue))
                )
            }
            SettingRow("summary.idle_hours", unit: "h", indented: true) {
                NumberField(path: ["summary", "idle_hours"], value: ledger.idleHours, unit: "h", range: 1 ... 720)
            }
            SettingRow("summary.include", stacked: true) {
                ChipToggles(
                    path: ["summary", "include"], options: LedgerPart.allCases.map { ($0.rawValue, $0.title) },
                    chosen: Set(ledger.include.map(\.rawValue))
                )
            }
        }
        SettingsCard(title: "While you were away") {
            SettingRow("summary.away_hours", unit: "h") {
                NumberField(
                    path: ["summary", "away_hours"],
                    value: config.summaryAwayHours,
                    unit: "h",
                    range: 0 ... 720
                )
            }
        }
        SettingsCard(title: "Mindmap") {
            SettingRow("mindmap.enabled") {
                ConfigSwitch(path: ["mindmap", "enabled"], isOn: config.mindmap.enabled)
            }
            SettingRow("mindmap.shadow") {
                ConfigSwitch(path: ["mindmap", "shadow"], isOn: config.mindmap.shadow)
            }
            CardNote {
                Text("How often heed placed work right:")
                PageLink(page: .decisions)
            }
        }
        SettingsCard(title: "Memory") {
            SettingRow("memory.brief") {
                SegmentedChoice(
                    path: ["memory", "brief"], value: config.memory.brief,
                    options: [(.nodeAndGoal, "Node and goal"), (.off, "Off")], name: \.rawValue, width: 200
                )
            }
        }
        SettingsCard(title: "Standup") {
            SettingRow("standup.enabled") {
                ConfigSwitch(path: ["standup", "enabled"], isOn: standup.enabled)
            }
            SettingRow("standup.days") {
                ChipToggles(
                    path: ["standup", "days"],
                    options: (Array(StandupSettings.dayNames.dropFirst()) + ["sun"]).map { ($0, $0.capitalized) },
                    chosen: Set(standup.days.compactMap {
                        StandupSettings.dayNames.indices.contains($0 - 1) ? StandupSettings.dayNames[$0 - 1] : nil
                    }),
                    allowNone: false
                )
            }
            SettingRow("standup.at") {
                ConfigTextField(
                    path: ["standup", "at"],
                    value: model.configValue(["standup", "at"])
                        ?? String(format: "%02d:%02d", standup.at / 60, standup.at % 60),
                    placeholder: "08:40", width: 80
                )
            }
            SettingRow("standup.range_days", defaultText: "since the last report") {
                RangeDaysChoice(value: standup.rangeDays)
            }
            SettingRow("standup.questions", stacked: true) {
                LinesField(path: ["standup", "questions"], values: standup.questions)
            }
            SettingRow("standup.personal_questions", defaultText: "the questions above", stacked: true) {
                LinesField(
                    path: ["standup", "personal_questions"],
                    values: standup.questionsByInstance[MindmapInstance.personal] ?? []
                )
            }
        }
        TelemetryCard(settings: config.telemetry)
        SettingsCard(title: "Call log", note: "How long the call log (:log) keeps each kind of call.") {
            days("log.shell_days", "shell_days", log.shellDays)
            days("log.github_read_days", "github_read_days", log.githubReadDays)
            days("log.github_write_days", "github_write_days", log.githubWriteDays)
            days("log.llm_days", "llm_days", log.llmDays)
            days("log.decide_days", "decide_days", log.decideDays)
            SettingRow("log.max_rows", unit: "rows") {
                NumberField(
                    path: ["log", "max_rows"], value: log.maxRows, unit: "rows", range: 1000 ... 1_000_000,
                    step: 10000, width: 80
                )
            }
        }
    }

    private func days(_ id: String, _ key: String, _ value: Int) -> some View {
        SettingRow(id, unit: "days") {
            NumberField(path: ["log", key], value: value, unit: "days", range: 1 ... 365)
        }
    }
}

/// `[telemetry]`: the receiver, what it keeps, and per agent what heed adds to it (or why it leaves it alone).
private struct TelemetryCard: View {
    @Environment(AppModel.self) private var model
    let settings: TelemetrySettings

    var body: some View {
        SettingsCard(
            title: "OpenTelemetry",
            note: "The agents' own spans, metrics and events (Insights › OpenTelemetry, :trace), received on "
                + "127.0.0.1 only. heed points claude and codex at it only when you send theirs nowhere yourself."
        ) {
            SettingRow("telemetry.enabled") {
                ConfigSwitch(path: ["telemetry", "enabled"], isOn: settings.enabled)
            }
            SettingRow("telemetry.port", indented: true) {
                NumberField(
                    path: ["telemetry", "port"], value: settings.port, range: 1024 ... 65535, width: 70
                )
            }
            SettingRow("telemetry.days", unit: "days", indented: true) {
                NumberField(path: ["telemetry", "days"], value: settings.days, unit: "days", range: 1 ... 90)
            }
            SettingRow("telemetry.max_rows", unit: "spans", indented: true) {
                NumberField(
                    path: ["telemetry", "max_rows"], value: settings.maxRows, unit: "spans",
                    range: 1000 ... 2_000_000, step: 10000, width: 80
                )
            }
            SettingRow("telemetry.tool_details", indented: true) {
                ConfigSwitch(path: ["telemetry", "tool_details"], isOn: settings.toolDetails)
            }
            SettingRow("telemetry.prompts", indented: true) {
                ConfigSwitch(path: ["telemetry", "prompts"], isOn: settings.prompts)
            }
            CardNote {
                VStack(alignment: .leading, spacing: 3) {
                    Text(TelemetryReceiverPill.state(model.telemetry).1)
                    if let export = model.telemetry.export {
                        ForEach(TelemetryExport.agents, id: \.self) { agent in
                            Text("\(agent): \(export.summary(agent: agent))")
                        }
                    }
                }
            }
        }
    }
}

/// `[standup] range_days`: since the last report (unset), or a fixed number of days.
private struct RangeDaysChoice: View {
    @Environment(AppModel.self) private var model
    let value: Int?

    var body: some View {
        Picker("", selection: Binding(
            get: { value ?? 0 },
            set: { $0 == 0 ? model.unsetConfig(["standup", "range_days"])
                : model.setConfig(["standup", "range_days"], .integer($0))
            }
        )) {
            Text("since the last report").tag(0)
            ForEach([1, 2, 3, 7, 14], id: \.self) { Text("\($0) day\($0 == 1 ? "" : "s")").tag($0) }
            if let value, ![1, 2, 3, 7, 14].contains(value) { Text("\(value) days").tag(value) }
        }
        .labelsHidden()
        .frame(width: 180)
    }
}
