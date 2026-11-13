import HeedCore
import SwiftUI

// Settings › GitHub: GitHub and Pilot (Orgs & repos and Attention have their own files).

struct GitHubPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        SettingsCard(title: "GitHub") {
            SettingRow("github.poll_seconds", unit: "s") {
                NumberField(
                    path: ["github", "poll_seconds"], value: model.config.githubPollSeconds, unit: "s",
                    range: 15 ... 3600, step: 15
                )
            }
        }
    }
}

/// `[pilot]`: the defaults every PR starts from, on the tabs Orgs & repos has (Get it green, with watching; Get it
/// merged; Reviews; Instructions), each with its count of modified settings.
struct PilotPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let counts = SettingsCatalog.counts(in: model.config, problems: model.configProblems)
        let (tabs, tab) = model.settingsFilter.tabs(
            SettingsPage.pilot.tabs, current: SettingsPage.pilot.tabs.contains(model.pilotTab) ? model.pilotTab : .green
        ) { counts.isChanged(.tab(.pilot, .global, $0)) }
        SettingsTabStrip(
            tabs: tabs, current: tab, count: { counts.modified(.tab(.pilot, .global, $0)) },
            pick: { model.pilotTab = $0 }
        )
        switch tab {
        case .merged: PilotMerged(pilot: model.config.pilot.defaults)
        case .reviews: PilotReviews(pilot: model.config.pilot.defaults)
        case .instructions: PilotInstructions(pilot: model.config.pilot.defaults)
        default: PilotGreen(pilot: model.config.pilot.defaults)
        }
        let orgs = model.config.pilot.orgs.count, repos = model.config.pilot.repos.count
        if !model.settingsFilter.onlyModified {
            footer(orgs: orgs, repos: repos, tab: tab)
        }
    }

    private func footer(orgs: Int, repos: Int, tab: SettingsTab) -> some View {
        HStack(spacing: 6) {
            Text(orgs + repos == 0
                ? "No org or repo overrides these."
                : "\(orgs) org\(orgs == 1 ? "" : "s") and \(repos) repo\(repos == 1 ? "" : "s") override these.")
                .font(Theme.ui(12)).foregroundStyle(Theme.fg3)
            // On the same tab of Orgs & repos.
            PageLink(page: .orgsAndRepos) {
                model.orgRepoTab = switch tab {
                case .merged: .merged
                case .reviews: .reviews
                case .instructions: .instructions
                default: .green
                }
            }
        }
    }
}

/// Search's matches on Pilot: each tab holding one, its cards with only the matching rows, under `Pilot › Reviews`.
struct PilotSearchResults: View {
    @Environment(AppModel.self) private var model
    let search: SettingsSearch

    var body: some View {
        let pilot = model.config.pilot.defaults
        let tabs = SettingsPage.pilot.tabs.filter { tab in search.matches(on: .pilot).contains { $0.entry.tab == tab } }
        ForEach(tabs, id: \.self) { tab in
            Group {
                switch tab {
                case .merged: PilotMerged(pilot: pilot)
                case .reviews: PilotReviews(pilot: pilot)
                case .instructions: PilotInstructions(pilot: pilot)
                default: PilotGreen(pilot: pilot)
                }
            }
            .environment(\.settingsCrumbs, [SettingsPage.pilot.title, tab.title])
        }
    }
}

/// The agents a run may use, by name; the empty tag is the key unset.
@MainActor private func agentOptions(_ model: AppModel, none: String) -> [(String, String)] {
    [("", none)] + model.settings.agents.map { ($0.name, $0.name) }
}

private struct PilotGreen: View {
    @Environment(AppModel.self) private var model
    let pilot: PilotSettings

    var body: some View {
        SettingsCard(title: "Watching") {
            SettingRow("pilot.watch") {
                ConfigSwitch(path: ["pilot", "watch"], isOn: pilot.watch)
            }
        }
        SettingsCard(title: "Get it green") {
            SettingRow("pilot.green") {
                SegmentedChoice(
                    path: ["pilot", "green"], value: pilot.green, options: AutoFeed.allCases.map { ($0, $0.rawValue) },
                    name: \.configName, width: 180
                )
            }
            SettingRow("pilot.max_rounds", unit: "rounds") {
                NumberField(path: ["pilot", "max_rounds"], value: pilot.maxRounds, unit: "rounds", range: 1 ... 20)
            }
            SettingRow("pilot.run_in") {
                SegmentedChoice(
                    path: ["pilot", "run_in"], value: pilot.runIn, options: RunIn.allCases.map { ($0, $0.rawValue) },
                    name: \.configName, width: 270
                )
            }
            SettingRow("pilot.agent", defaultText: "the session's agent") {
                MenuChoice(
                    path: ["pilot", "agent"], value: pilot.agent ?? "",
                    options: agentOptions(model, none: "The session's agent"), width: 180
                )
            }
            SettingRow("pilot.model", "pilot.effort", label: "Run model and effort", defaultText: "the agent's own") {
                ConfigModelPicker(
                    agent: pilot.agent ?? model.settings.defaultAgent, modelPath: ["pilot", "model"],
                    modelValue: pilot.model, effortPath: ["pilot", "effort"], effortValue: pilot.effort
                )
            }
            SettingRow("pilot.run_timeout") {
                DurationPicker(
                    path: ["pilot", "run_timeout"], options: ["15m", "30m", "1h", "2h"],
                    current: PilotDuration.text(pilot.runTimeout)
                )
            }
            SettingRow("pilot.pause") {
                DurationPicker(
                    path: ["pilot", "pause"], options: ["30m", "1h", "4h", "1d", "forever"],
                    current: pilot.pause.map(PilotDuration.text) ?? "forever"
                )
            }
        }
        SettingsCard(title: "Helpers") {
            SettingRow("helpers.agent", defaultText: "your default agent") {
                MenuChoice(
                    path: ["helpers", "agent"], value: model.config.helpers.agent ?? "",
                    options: [("", "Your default agent")] + ACPAgents.known.map { ($0.agent, $0.agent) }, width: 180
                )
            }
            SettingRow("helpers.command", defaultText: "the adapter heed knows") {
                ConfigTextField(
                    path: ["helpers", "command"], value: model.config.helpers.command ?? "",
                    placeholder: "claude-agent-acp", emptyUnsets: true
                )
            }
            SettingRow("helpers.spend_cap", defaultText: "$\(DollarsField.text(HelperSettings().spendCap))") {
                DollarsField(path: ["helpers", "spend_cap"], value: model.config.helpers.spendCap)
            }
        }
        SettingsCard(title: "Merge conflicts") {
            SettingRow("pilot.merge_agent", defaultText: "the run agent") {
                MenuChoice(
                    path: ["pilot", "merge_agent"], value: pilot.mergeAgent ?? "",
                    options: agentOptions(model, none: "The run agent"), width: 180
                )
            }
            SettingRow(
                "pilot.merge_model", "pilot.merge_effort", label: "Conflict model and effort",
                defaultText: "the run model and effort"
            ) {
                let ownAgent = pilot.mergeAgent != nil
                ConfigModelPicker(
                    agent: pilot.mergeAgent ?? pilot.agent ?? model.settings.defaultAgent,
                    modelPath: ["pilot", "merge_model"], modelValue: pilot.mergeModel,
                    effortPath: ["pilot", "merge_effort"], effortValue: pilot.mergeEffort,
                    defaultLabel: ownAgent ? nil : "the run model",
                    effortDefaultLabel: ownAgent ? nil : "the run effort"
                )
            }
        }
    }
}

private struct PilotMerged: View {
    @Environment(AppModel.self) private var model
    let pilot: PilotSettings

    var body: some View {
        SettingsCard(title: "Get it merged") {
            SettingRow("pilot.merge") {
                SegmentedChoice(
                    path: ["pilot", "merge"], value: pilot.merge, options: MergeMode.allCases.map { ($0, $0.rawValue) },
                    name: \.configName, width: 270
                )
            }
            SettingRow("pilot.merge_method", defaultText: "the first the repo allows") {
                MenuChoice(
                    path: ["pilot", "merge_method"], value: pilot.mergeMethod ?? "",
                    options: [("", "default"), ("squash", "squash"), ("merge", "merge"), ("rebase", "rebase")],
                    width: 140
                )
            }
            SettingRow("pilot.update_branches") {
                ConfigSwitch(path: ["pilot", "update_branches"], isOn: pilot.updateBranches)
            }
            SettingRow("pilot.merge_schedule") {
                DurationPicker(
                    path: ["pilot", "merge_schedule"], options: ["15m", "30m", "1h", "4h", "manual"],
                    current: pilot.mergeSchedule.map(PilotDuration.text) ?? "manual"
                )
            }
        }
        SettingsCard(title: "Before heed merges") {
            SettingRow("pilot.quiet_minutes", unit: "min") {
                NumberField(
                    path: ["pilot", "quiet_minutes"], value: pilot.quietMinutes, unit: "min", range: 0 ... 1440
                )
            }
            SettingRow("pilot.gate_checks") {
                ListField(path: ["pilot", "gate_checks"], values: pilot.gateChecks)
            }
            SettingRow("pilot.hold_labels") {
                ListField(path: ["pilot", "hold_labels"], values: pilot.holdLabels)
            }
        }
        SettingsCard(title: "Merging by hand") {
            SettingRow("pilot.merge_now") {
                SegmentedChoice(
                    path: ["pilot", "merge_now"], value: pilot.mergeNow,
                    options: MergeNowConfirm.allCases.map { ($0, $0.rawValue) }, name: \.rawValue, width: 140
                )
            }
            SettingRow("pilot.force_merge") {
                SegmentedChoice(
                    path: ["pilot", "force_merge"], value: pilot.forceMerge,
                    options: ForceMerge.allCases.map { ($0, $0.rawValue) }, name: \.rawValue, width: 180
                )
            }
        }
    }
}

private struct PilotReviews: View {
    @Environment(AppModel.self) private var model
    let pilot: PilotSettings

    var body: some View {
        SettingsCard(title: "Reviewers") {
            SettingRow("pilot.reviewers") {
                ListField(path: ["pilot", "reviewers"], values: pilot.reviewers)
            }
            SettingRow("pilot.trusted_reviewers") {
                ListField(path: ["pilot", "trusted_reviewers"], values: pilot.trustedReviewers)
            }
            SettingRow("pilot.self_review", defaultText: "none") {
                ConfigTextField(path: ["pilot", "self_review"], value: pilot.selfReview ?? "", emptyUnsets: true)
            }
        }
        SettingsCard(title: "Copilot") {
            SettingRow("pilot.copilot_comments") {
                ConfigSwitch(path: ["pilot", "copilot_comments"], isOn: pilot.copilotComments)
            }
            SettingRow("pilot.copilot_conflicts") {
                ConfigSwitch(path: ["pilot", "copilot_conflicts"], isOn: pilot.copilotConflicts)
            }
        }
    }
}

private struct PilotInstructions: View {
    @Environment(AppModel.self) private var model
    let pilot: PilotSettings

    var body: some View {
        SettingsCard(
            title: "Extra instructions",
            note: "Added to what heed sends, never replacing it. Per org and per repo too, under Orgs & repos. The "
                + "agent still reads the repo's own AGENTS.md or CLAUDE.md."
        ) {
            SettingRow("pilot.green_instructions", defaultText: "none", stacked: true) {
                InstructionsField(path: ["pilot", "green_instructions"], value: pilot.greenInstructions)
            }
            SettingRow("pilot.review_instructions", defaultText: "none", stacked: true) {
                InstructionsField(path: ["pilot", "review_instructions"], value: pilot.reviewInstructions)
            }
            SettingRow("pilot.start_instructions", defaultText: "none", stacked: true) {
                InstructionsField(path: ["pilot", "start_instructions"], value: pilot.startInstructions)
            }
            SettingRow("pilot.summary_instructions", defaultText: "none", stacked: true) {
                InstructionsField(path: ["pilot", "summary_instructions"], value: pilot.summaryInstructions)
            }
            SettingRow("pilot.summary_sign_off") {
                ConfigSwitch(path: ["pilot", "summary_sign_off"], isOn: pilot.summarySignOff)
            }
        }
    }
}
