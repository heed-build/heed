import Foundation
import HeedCore

/// Configure… (`:settings.configure`, the app menu, the button at the top of Settings' tree): a profile, the gaps,
/// then a review of what will be written. The draft (`configure`) holds everything until Apply, which writes the
/// changes into config.toml and records what was decided in `settingsChosen`.
extension AppModel {
    /// What Configure… needs to know about this Mac.
    var gapFacts: GapFacts { GapFacts(zmxWorks: zmxHealth?.works == true) }

    /// The settings worth deciding, most important first: the count on the Configure… button.
    var settingsGaps: [SettingsGap] {
        SettingsCatalog.gaps(in: config, chosen: settingsChosen, facts: gapFacts)
    }

    /// Opens Configure… over Settings, on its first step.
    func openConfigure() {
        configure = ConfigureDraft()
        openSettings?()
        guard !isFixture else { return }
        // Set up & test suggests from what is logged in, and persistent panes from zmx's check.
        Task { await refreshLLMStatuses() }
    }

    /// Model calls' Set up & test, as a draft: the agent and decider Settings › Model calls would pick, written and
    /// tested on Apply.
    func draftModelCallsSetup() {
        let setup = inferenceSetup
        if let agent = setup.suggestedAgent { configure?.set("llm.agent", .text(agent)) }
        configure?.set("decisions.decider", .text(setup.suggestedDecider.rawValue))
    }

    /// Check again, for persistent panes: looks for zmx and checks it, as Settings › Tools does.
    func checkZmxAgain() {
        guard !isFixture else { return }
        Task { await detectTools() }
    }

    /// Apply: every change written into config.toml, what was decided recorded, then Configure… closes. A model
    /// calls agent or decider it wrote is tested, as Set up does.
    func applyConfigure() {
        guard let draft = configure else { return }
        let changes = draft.changes(config, chosen: settingsChosen)
        let decided = draft.decided(config, chosen: settingsChosen)
        if !isFixture {
            for change in changes {
                if let value = change.to { setConfig(change.path, value.toml) } else { unsetConfig(change.path) }
            }
        }
        var chosen = settingsChosen
        for id in decided {
            chosen.choose(id)
        }
        settingsChosen = chosen
        configure = nil
        for change in changes {
            switch (change.entry.id, change.to) {
            case let ("llm.agent", .text(agent)?): testInference(chosen: agent)
            case let ("decisions.decider", .text(name)?):
                if let choice = DecisionSettings.Choice(rawValue: name), choice != .off { testDecision(choice: choice) }
            default: break
            }
        }
        let written = changes.count == 1 ? "1 setting" : "\(changes.count) settings"
        flash = "Configure: wrote \(written), \(decided.count) decided"
    }
}
