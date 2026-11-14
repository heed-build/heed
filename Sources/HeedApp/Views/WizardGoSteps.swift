import HeedCore
import SwiftUI

// MARK: Step 5, How careful

/// Step 5: Quick, Standard and Thorough as three cards (what each checks as glyphs, what its reviews cost, who it
/// suits), heed's suggestion and why, and the legend. `1 2 3` pick, `Q` the details, `⌘↩` on.
struct WizardCarefulStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let goal = wizard.goal
        let suggestion = model.careSuggestion(goal)
        let level = model.careLevel(goal)
        let parts = wizard.split?.active.count ?? 0
        let profile = model.goalProfile(goal)
        VStack(alignment: .leading, spacing: 18) {
            StepHeader(title: "How careful", subtitle: "what has to pass before a part merges")
            HStack(alignment: .top, spacing: 16) {
                ForEach(CareLevel.allCases, id: \.self) { option in
                    CareCard(
                        level: option, plan: CarePlan.of(option, profile: profile), parts: parts,
                        picked: option == level, suggested: option == suggestion.level
                    )
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: "eye").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                (Text("Suggested \(suggestion.level.title): ").foregroundStyle(Theme.fg)
                    + Text(suggestion.reason + ". The bars, lenses and reviewers behind each level are under ")
                    .foregroundStyle(Theme.fg2)
                    + Text(model.keyText(for: "careful.details", in: "wizardcareful")).font(Theme.mono(12))
                    .foregroundStyle(Theme.fg) + Text(".").foregroundStyle(Theme.fg2))
                    .font(Theme.ui(13.5))
                    .fixedSize(horizontal: false, vertical: true)
                    .clickRuns(CommandInvocation(name: "careful.details"))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18).padding(.vertical, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Theme.line))
            HStack(spacing: 14) {
                ForEach(CareCheck.allCases, id: \.self) { check in
                    HStack(spacing: 5) {
                        Image(systemName: check.symbol).font(.system(size: 10))
                        Text(check.title)
                    }
                }
            }
            .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack(spacing: 12) {
                PrimaryAction(label: "\(level.title) · go on", command: "wizard.next", scope: "wizardcareful")
                KeyCap(text: "1 2 3")
                BusyLine(goal: goal)
                Spacer()
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .shotRegion(.wizardCareful)
    }
}

private struct CareCard: View {
    let level: CareLevel
    let plan: CarePlan
    let parts: Int
    let picked: Bool
    let suggested: Bool

    var body: some View {
        let tint = Self.tint(level)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: level.symbol).font(.system(size: 16, weight: .medium)).foregroundStyle(tint)
                    .frame(width: 36, height: 36)
                    .background(RoundedRectangle(cornerRadius: 5).fill(tint.opacity(0.14)))
                Text(level.title).font(Theme.ui(17, weight: .bold)).foregroundStyle(Theme.fg)
                if suggested {
                    Text("suggested").font(Theme.mono(11)).foregroundStyle(Theme.block)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 3).fill(Theme.block.opacity(0.14)))
                }
                Spacer(minLength: 0)
                Text("\(level.number)").font(Theme.mono(10.5)).foregroundStyle(Theme.fg3)
            }
            HStack(spacing: 6) {
                ForEach(level.checks, id: \.self) { check in
                    Image(systemName: check.symbol).font(.system(size: 11)).foregroundStyle(Theme.fg2)
                        .frame(width: 28, height: 28)
                        .background(RoundedRectangle(cornerRadius: 4).fill(Theme.chip))
                        .help(check.title)
                }
            }
            Text(level.line).font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 18)
            HStack(spacing: 6) {
                Image(systemName: "cylinder").font(.system(size: 10))
                Text("\(CarePlan.dollarsText(plan.dollars(parts: parts))) in reviews · \(level.suits)")
                    .lineLimit(1).truncationMode(.tail)
            }
            .font(Theme.mono(11.5)).foregroundStyle(Theme.fg3)
            .help(plan.lenses.isEmpty ? "CI and one Copilot review on each PR"
                : "reviewers: " + plan.lenses.map(\.title).joined(separator: ", "))
        }
        .padding(18)
        .frame(maxWidth: .infinity, minHeight: 230, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 6).fill(picked ? Theme.block.opacity(0.07) : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(picked ? Theme.block.opacity(0.85) : Theme.line))
        .contentShape(Rectangle())
        .clickRuns(CommandInvocation(name: "careful.pick", arguments: [level.rawValue]))
    }

    static func tint(_ level: CareLevel) -> Color {
        switch level {
        case .quick: Theme.busy
        case .standard: Theme.done
        case .thorough: Theme.block
        }
    }
}

// MARK: Step 6, Go

/// Step 6: five rows with their defaults on the left, what happens on the right, Start and Save, start later.
struct WizardGoStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let goal = wizard.goal
        let choices = model.goChoices(goal)
        let forecast = model.goForecast(goal)
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                StepHeader(title: "Go", subtitle: "every choice has a default · ⌘↩ starts the first parts")
                ForEach(Array(GoChoices.Row.allCases.enumerated()), id: \.offset) { index, row in
                    GoRow(row: row, choices: choices, cursor: index == model.goals.wizard.goRow)
                }
                Spacer(minLength: 0)
                Theme.line.frame(height: 1)
                HStack(spacing: 12) {
                    PrimaryAction(label: Self.startLabel(forecast), command: "go.start", scope: "wizardgo")
                    WizardButton(label: "Save, start later", command: "go.save", scope: "wizardgo")
                    BusyLine(goal: goal)
                    Spacer()
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 22)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            WhatHappens(forecast: forecast)
                .frame(width: 420)
                .frame(maxHeight: .infinity, alignment: .top)
                .background(Theme.bg2.opacity(0.4))
                .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
                .shotRegion(.goWhatHappens)
        }
        .shotRegion(.wizardGo)
    }
}

extension WizardGoStep {
    /// What ⌘↩ starts now, as the right side says it: `Start 4 parts` when they all start at once, else `Start · 2
    /// now, 15 in all`.
    static func startLabel(_ forecast: GoForecast?) -> String {
        guard let forecast else { return "Start" }
        if forecast.startNow == forecast.pulls {
            return "Start \(forecast.pulls) part\(forecast.pulls == 1 ? "" : "s")"
        }
        return "Start · \(forecast.startNow) now, \(forecast.pulls) in all"
    }
}

private struct GoRow: View {
    let row: GoChoices.Row
    let choices: GoChoices
    let cursor: Bool

    var body: some View {
        let picked = choices.picked(row)
        HStack(spacing: 16) {
            Image(systemName: row.symbol).font(.system(size: 14)).foregroundStyle(Theme.fg2)
                .frame(width: 40, height: 40)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.chip))
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title).font(Theme.ui(15, weight: .semibold)).foregroundStyle(Theme.fg)
                Text(row.line).font(Theme.ui(12.5)).foregroundStyle(Theme.fg3).lineLimit(1)
                    .truncationMode(.tail)
            }
            .layoutPriority(1)
            Spacer(minLength: 12)
            HStack(spacing: 4) {
                ForEach(Array(choices.options(row).enumerated()), id: \.offset) { index, option in
                    let on = index == picked
                    Text(option).font(Theme.ui(13.5, weight: on ? .semibold : .regular))
                        .foregroundStyle(on ? Theme.ink : Theme.fg2)
                        .padding(.horizontal, 12).frame(height: 30)
                        .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.inverse : .clear))
                        .fixedSize()
                        .clickRuns(CommandInvocation(name: "go.pick", arguments: ["\(index + 1)"]))
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 5).fill(cursor ? Theme.bg3 : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(cursor ? Theme.keyCapBorder : .clear))
    }
}

/// What Go comes to: parts now on how many agents, the time and the end, the extra against the cap, the PRs, the
/// agents (a ring where heed knows the quota), and what follows.
private struct WhatHappens: View {
    @Environment(AppModel.self) private var model
    let forecast: GoForecast?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "eye").font(.system(size: 11))
                SectionHeader(title: "What happens")
            }
            .foregroundStyle(Theme.fg3)
            if let forecast {
                line(
                    "square.3.layers.3d",
                    "\(forecast.startNow) part\(forecast.startNow == 1 ? "" : "s")",
                    "start now, on \(forecast.agentsNow) agent\(forecast.agentsNow == 1 ? "" : "s")"
                )
                line("clock", forecast.hoursText, GoForecast.endText(forecast.endsAt))
                line(
                    "cylinder", (forecast.unpriced > 0 ? "≥" : "") + CarePlan.dollarsText(forecast.extra),
                    "extra, cap $\(Int(forecast.budget))", warn: forecast.overBudget
                )
                line(
                    "arrow.triangle.branch",
                    "\(forecast.pulls) PRs",
                    "in \(forecast.repos) repo\(forecast.repos == 1 ? "" : "s")"
                )
                HStack(spacing: 10) {
                    ForEach(forecast.agents) { agent in
                        VStack(spacing: 4) {
                            if let quota = agent.quota {
                                QuotaRing(quota: quota, tint: AgentLook.tint(agent.id), size: 40)
                            } else {
                                AgentTile(id: agent.id, size: 40)
                                    .help("\(agent.name): heed has no quota for it")
                            }
                            Text(agent.name).font(Theme.mono(10)).foregroundStyle(AgentLook.tint(agent.id))
                                .lineLimit(1).frame(maxWidth: 52)
                        }
                    }
                }
                .padding(.top, 6)
            }
            (Text("Then: the goal's page shows the board moving and one next step for you; anything that needs you "
                    + "lands in Attention and ")
                + Text(model.keyText(for: "approvals.open")).font(Theme.mono(11.5)) + Text("."))
                .font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 8)
            Spacer()
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 26)
    }

    private func line(_ symbol: String, _ value: String, _ rest: String, warn: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.fg3).frame(width: 18)
            Text(value).font(Theme.ui(18, weight: .bold)).foregroundStyle(warn ? Theme.block : Theme.fg)
            Text(rest).font(Theme.ui(13)).foregroundStyle(warn ? Theme.block : Theme.fg3).lineLimit(1)
        }
    }
}
