import HeedCore
import SwiftUI

/// Step 4, Split: the board of your agents with the plan's parts on them, Balance for on top with the stats, and
/// under the board either who should do the selected part (and what the plan uses), or defining it with its agent.
struct WizardSplitStep: View {
    @Environment(AppModel.self) private var model
    let wizard: GoalWizard

    var body: some View {
        let browser = model.goals.wizard
        VStack(alignment: .leading, spacing: 12) {
            StepHeader(
                title: "Split it across your agents", subtitle: wizard.plan.current?.title ?? ""
            ) {
                if let draft = wizard.split, draft.drafted { BalancePicker(balance: draft.balance) }
            }
            if let draft = wizard.split, draft.drafted {
                let rows = model.splitRows(draft)
                let schedule = model.splitSchedule(draft)
                SplitStatsRow(stats: SplitStats(draft: draft, schedule: schedule, fleet: browser.fleet))
                SplitBoardView(
                    draft: draft, rows: rows, schedule: schedule, selected: browser.part, folded: browser.folded,
                    compact: browser.defining != nil
                ) { part, _ in
                    PartFoldCard(part: part, draft: draft, live: nil)
                }
                .padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                .shotRegion(.splitBoard)
                // A fold-out reaches over what is under the board.
                .zIndex(2)
                if let definition = browser.defining {
                    DefinePane(definition: definition, draft: draft)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .shotRegion(.splitDefine)
                } else {
                    WhoShouldDoIt(draft: draft).shotRegion(.splitWho)
                    Spacer(minLength: 0)
                    HStack(spacing: 12) {
                        PrimaryAction(label: "Good · how careful", command: "wizard.next", scope: "wizardsplit")
                        WizardButton(label: "Re-split", command: "split.resplit", scope: "wizardsplit")
                        BusyLine(goal: wizard.goal)
                        Spacer()
                        Text("drag a part to another agent").font(Theme.ui(12)).foregroundStyle(Theme.fg3)
                        KeyHint("split.agent", scope: "wizardsplit", label: "agent")
                        KeyHint("split.split", scope: "wizardsplit", label: "split")
                        KeyHint("split.shift", ["1"], key: "J K", scope: "wizardsplit", label: "move")
                    }
                }
            } else {
                BusyLine(goal: wizard.goal)
                Spacer()
                HStack(spacing: 12) {
                    PrimaryAction(label: "Split the plan", command: "wizard.next", scope: "wizardsplit")
                }
            }
        }
        .padding(.horizontal, 32)
        .padding(.top, 22)
        .padding(.bottom, 14)
        .shotRegion(.wizardSplit)
    }
}

/// Balance for: the credits you have, speed, the fewest agents.
private struct BalancePicker: View {
    let balance: SplitBalance

    var body: some View {
        HStack(spacing: 6) {
            Text("Balance for").font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            ForEach(SplitBalance.allCases, id: \.self) { option in
                let on = option == balance
                Text(option.title).font(Theme.ui(13, weight: on ? .semibold : .regular))
                    .foregroundStyle(on ? Theme.ink : Theme.fg2)
                    .padding(.horizontal, 10).frame(height: 26)
                    .background(RoundedRectangle(cornerRadius: 4).fill(on ? Theme.inverse : .clear))
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(on ? .clear : Theme.keyCapBorder))
                    .clickRuns(CommandInvocation(name: "split.balance", arguments: [option.rawValue]))
            }
        }
        .fixedSize()
    }
}

/// Parts, agents, hours together, extra spend, and the hours alone struck through.
struct SplitStatsRow: View {
    let stats: SplitStats

    var body: some View {
        HStack(spacing: 22) {
            stat("square.3.layers.3d", "\(stats.parts)", "parts")
            stat("person.2", "\(stats.agents)", "agents")
            stat("clock", SplitSchedule.text(stats.together), "together")
            stat(
                "cylinder.split.1x2", stats.extraText,
                stats.unpriced > 0 ? "extra spend; \(stats.unpriced) parts on agents heed cannot price"
                    : "extra spend, beyond what you pay already"
            )
            HStack(spacing: 5) {
                Image(systemName: "clock").font(.system(size: 11))
                Text(SplitSchedule.text(stats.alone) + " alone").strikethrough()
            }
            .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            .help("what one agent alone would take")
        }
    }

    private func stat(_ symbol: String, _ value: String, _ help: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(Theme.fg3)
            Text(value).font(Theme.ui(18, weight: .bold)).foregroundStyle(Theme.fg)
        }
        .help(help)
    }
}

// MARK: Who should do it

/// The selected part (else the first), the agents who could do it ranked by fit, and what the plan uses of each.
private struct WhoShouldDoIt: View {
    @Environment(AppModel.self) private var model
    let draft: SplitDraft

    var body: some View {
        let browser = model.goals.wizard
        let part = browser.part.flatMap(draft.part) ?? draft.active.first
        HStack(alignment: .top, spacing: 12) {
            if let part {
                PartSummary(part: part, draft: draft)
                    .frame(width: 270, alignment: .topLeading)
                    .padding(16)
                    .frame(maxHeight: .infinity, alignment: .topLeading)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
                let ranked = SplitAssign.candidates(
                    for: part, fleet: browser.fleet, records: browser.records, draft: draft
                )
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(ranked.prefix(4)) { candidate in // the best four
                        CandidateCard(candidate: candidate, on: candidate.agent.id == part.agent)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            PlanUses(draft: draft)
                .frame(width: 270, alignment: .topLeading)
                .padding(16)
                .frame(maxHeight: .infinity, alignment: .topLeading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct PartSummary: View {
    @Environment(AppModel.self) private var model
    let part: SplitPart
    let draft: SplitDraft

    var body: some View {
        let number = draft.number(of: part.id) ?? 0
        let numbers = model.splitNumbers(draft)
        let after = part.task.after.compactMap { numbers[$0].map(String.init) }
        let chain = model.splitSchedule(draft).chain.contains(part.id)
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "Part \(number) · who should do it")
            Text(part.title).font(Theme.ui(16, weight: .semibold)).foregroundStyle(Theme.fg).lineLimit(2)
            Text(([part.repoName, part.size.rawValue, "~" + SplitSchedule.text(part.hours)].compactMap(\.self)
                    + (after.isEmpty ? [] : ["after " + after.joined(separator: ", ")])
                    + (chain ? ["on the longest chain"] : [])
                    + part.task.doneWhen.prefix(1).map { "done when \($0)" }).joined(separator: " · "))
                .font(Theme.ui(12.5)).foregroundStyle(Theme.fg2).fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// One agent for the part: tile, name and model, its fit as a meter with the score, its merged PRs here, its quota
/// (when known), its extra cost, and its one reason.
private struct CandidateCard: View {
    let candidate: SplitAssign.Candidate
    let on: Bool

    var body: some View {
        let tint = AgentLook.tint(candidate.agent.id)
        HStack(alignment: .top, spacing: 10) {
            AgentTile(id: candidate.agent.id, size: 26)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(candidate.agent.name).font(Theme.ui(14, weight: .semibold)).foregroundStyle(Theme.fg)
                        .lineLimit(1).fixedSize()
                    Text(candidate.agent.model ?? "").font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                HStack(spacing: 8) {
                    GeometryReader { geometry in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2).fill(Theme.line)
                            RoundedRectangle(cornerRadius: 2).fill(tint)
                                .frame(width: geometry.size.width * candidate.fit)
                        }
                    }
                    .frame(height: 5)
                    Text("\(candidate.score)").font(Theme.mono(11, weight: .semibold)).foregroundStyle(tint)
                }
                .help("fit: its merged PRs in this repo, how many it left, against what it would take")
                HStack(spacing: 10) {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.triangle.merge").font(.system(size: 10))
                        Text("\(candidate.merged)").font(Theme.mono(11))
                    }
                    .fixedSize()
                    .help("its merged PRs in this repo")
                    if let quota = candidate.agent.quota {
                        HStack(spacing: 4) {
                            QuotaRing(quota: quota, tint: tint, size: 15, showsNumber: false)
                            Text("\(Int((quota.left * 100).rounded()))%").font(Theme.mono(11))
                        }
                        .fixedSize()
                    }
                    HStack(spacing: 4) {
                        Image(systemName: "cylinder.split.1x2").font(.system(size: 10))
                        Text(candidate.extra.map { $0 == 0 ? "$0" : AgentUsage.dollars($0) } ?? "?")
                            .font(Theme.mono(11))
                    }
                    .fixedSize()
                    .help(candidate.extra == nil ? "heed has not seen what it costs" : "extra cost of this part on it")
                    if let note = candidate.note {
                        Text(note).font(Theme.ui(12)).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
                            .help(note)
                    }
                }
                .foregroundStyle(Theme.fg2)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 6).fill(on ? tint.opacity(0.10) : Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(on ? tint.opacity(0.7) : Theme.line))
        .clickRuns(CommandInvocation(name: "split.agent", arguments: [candidate.agent.id]))
    }
}

/// What the plan uses of each agent: its ring (when known), its hours, and the extra spend.
private struct PlanUses: View {
    @Environment(AppModel.self) private var model
    let draft: SplitDraft

    var body: some View {
        let rows = model.splitRows(draft)
        let stats = SplitStats(draft: draft, schedule: model.splitSchedule(draft), fleet: model.goals.wizard.fleet)
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "This plan uses")
            HStack(spacing: 10) {
                ForEach(rows) { agent in
                    let tint = AgentLook.tint(agent.id)
                    let hours = draft.active.filter { $0.agent == agent.id }.reduce(0) { $0 + $1.hours }
                    VStack(spacing: 4) {
                        if let quota = agent.quota {
                            QuotaRing(quota: quota, tint: tint, size: 32)
                        } else {
                            AgentTile(id: agent.id, size: 32)
                        }
                        Text(SplitSchedule.text(hours)).font(Theme.mono(10)).foregroundStyle(tint).lineLimit(1)
                            .fixedSize()
                    }
                    .help("\(agent.name): \(SplitSchedule.text(hours)) of parts")
                }
            }
            HStack(spacing: 6) {
                Image(systemName: "cylinder.split.1x2").font(.system(size: 12)).foregroundStyle(Theme.block)
                Text(stats.extraText + " extra").font(Theme.ui(13, weight: .semibold)).foregroundStyle(Theme.fg)
                if stats.unpriced > 0 {
                    Text("· \(stats.unpriced) unpriced").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                }
            }
        }
    }
}

// MARK: The fold-out

/// A part folded out of the board: its done when, its context, the agents who could do it with their fit (a click
/// puts it on one), what to tell its agent, and its actions. On the goal's page (`live`), Steer instead of Define.
struct PartFoldCard: View {
    @Environment(AppModel.self) private var model
    let part: SplitPart
    let draft: SplitDraft
    /// The part's state on the goal's page; nil in the wizard.
    let live: PartState?

    var body: some View {
        let browser = model.goals.wizard
        let number = draft.number(of: part.id) ?? 0
        let numbers = model.splitNumbers(draft)
        let after = part.task.after.compactMap { numbers[$0].map(String.init) }
        let ranked = SplitAssign.candidates(for: part, fleet: browser.fleet, records: browser.records, draft: draft)
        let chain = model.splitSchedule(draft).chain.contains(part.id)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                AgentTile(id: part.agent ?? "", size: 34)
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        if chain {
                            Image(systemName: "diamond.fill").font(.system(size: 9)).foregroundStyle(Theme.block)
                        }
                        Text("\(number) · \(part.title)").font(Theme.ui(16, weight: .semibold))
                            .foregroundStyle(Theme.fg)
                            .lineLimit(1)
                    }
                    HStack(spacing: 8) {
                        RepoSwatch(repo: part.repo)
                        Text(part.repoName ?? "any repo").font(Theme.mono(11))
                        SizePips(size: part.size)
                        Image(systemName: "clock").font(.system(size: 10))
                        Text(SplitSchedule.text(part.hours)).font(Theme.mono(11))
                        if !after.isEmpty {
                            Image(systemName: "arrow.triangle.branch").font(.system(size: 10))
                            Text("after " + after.joined(separator: " · ")).font(Theme.mono(11))
                        }
                    }
                    .foregroundStyle(Theme.fg2)
                }
                Spacer()
            }
            .padding(16)
            .background(AgentLook.tint(part.agent ?? "").opacity(0.07))
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.done)
                    (Text("Done when ").bold() + Text(part.task.doneWhen.joined(separator: "; ")))
                        .font(Theme.ui(13.5)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    FlowChips(items: part.context, added: [])
                }
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "person.2").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    HStack(spacing: 6) {
                        ForEach(ranked.prefix(5)) { candidate in
                            VStack(spacing: 3) {
                                AgentTile(id: candidate.agent.id, size: 28, selected: candidate.agent.id == part.agent)
                                Text("\(candidate.score)").font(Theme.mono(10)).foregroundStyle(Theme.fg3)
                            }
                            .clickRuns(live == nil
                                ? CommandInvocation(name: "split.agent", arguments: [candidate.agent.id]) : nil)
                        }
                    }
                    if let best = ranked.first {
                        Text(reason(best)).font(Theme.ui(12.5)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                if live == nil {
                    SteerBox(part: part)
                }
            }
            .padding(16)
            HStack(spacing: 6) {
                if let live {
                    if case .running = live { action("Steer", "play", "page.steer") }
                } else {
                    action("Define", "play", "split.define", primary: true)
                    action("Agent", "person.2", "split.agent")
                    action("Split", "square.3.layers.3d", "split.split")
                    action("Waits on", "arrow.triangle.branch", "split.waits")
                    action("Size", "scalemass", "split.size")
                    action("Later", "clock", "split.later")
                }
            }
            .padding([.horizontal, .bottom], 16)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg3))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.keyCapBorder))
        .shadow(color: .black.opacity(0.45), radius: 18, y: 8)
        .shotRegion(.splitFold)
    }

    private func reason(_ best: SplitAssign.Candidate) -> String {
        var words = ["\(best.agent.name) · \(best.merged) merged here"]
        if let quota = best.agent.quota { words.append("\(Int((quota.left * 100).rounded()))% of its window left") }
        return words.joined(separator: " · ")
    }

    private func action(_ label: String, _ symbol: String, _ command: String, primary: Bool = false) -> some View {
        let scope = live == nil ? "splitfold" : "goals"
        return VStack(spacing: 4) {
            Image(systemName: symbol).font(.system(size: 13))
            Text(label).font(Theme.ui(12.5)).lineLimit(1)
            Text(model.keyText(for: command, in: scope)).font(Theme.mono(10)).foregroundStyle(
                primary ? Theme.ink.opacity(0.6) : Theme.fg3
            )
        }
        .foregroundStyle(primary ? Theme.ink : Theme.fg)
        .frame(maxWidth: .infinity)
        .frame(height: 64)
        .background(RoundedRectangle(cornerRadius: 5).fill(primary ? Theme.inverse : .clear))
        .clickRuns(CommandInvocation(name: command))
    }
}

/// Chips in rows: folders, files, PRs and decisions (a decision with a star); `added` ones tinted green.
struct FlowChips: View {
    let items: [String]
    let added: [String]
    var plus = true

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(Array((items + added).enumerated()), id: \.offset) { index, item in
                let new = index >= items.count
                HStack(spacing: 5) {
                    Image(systemName: symbol(item)).font(.system(size: 10))
                    Text(item).font(Theme.mono(11)).lineLimit(1)
                }
                .padding(.horizontal, 8).frame(height: 24)
                .foregroundStyle(new ? Theme.done : Theme.fg2)
                .background(RoundedRectangle(cornerRadius: 4).fill(new ? Theme.done.opacity(0.14) : Theme.chip))
            }
            if plus {
                Text("+ context").font(Theme.mono(11)).foregroundStyle(Theme.fg3)
                    .padding(.horizontal, 8).frame(height: 24)
                    .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Theme.keyCapBorder))
                    .clickRuns(CommandInvocation(name: "split.note"))
            }
        }
    }

    private func symbol(_ item: String) -> String {
        if item.hasPrefix("decision:") { return "star" }
        if item.hasPrefix("#") { return "arrow.triangle.branch" }
        return "folder"
    }
}

/// "Tell its agent something before it starts…": what you typed, or the prompt to press `i`.
private struct SteerBox: View {
    @Environment(AppModel.self) private var model
    let part: SplitPart

    var body: some View {
        let typing = model.goals.wizard.typing
        let mine = typing?.kind == .note || typing?.kind == .waits
        HStack(spacing: 10) {
            Image(systemName: "bolt").font(.system(size: 12)).foregroundStyle(Theme.fg3)
            if mine, let typing {
                if ShotMode.active {
                    Text(typing.text).foregroundStyle(Theme.fg).frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    TextField(
                        typing
                            .kind == .waits ? "part numbers it waits on" : "Tell its agent something before it starts…",
                        text: Binding(
                            get: { model.goals.wizard.typing?.text ?? "" },
                            set: { model.goals.wizard.typing?.text = $0 }
                        )
                    )
                    .textFieldStyle(.plain)
                    .onSubmit { model.submitWizardTyping() }
                }
            } else {
                Text(part.note ?? "Tell its agent something before it starts…")
                    .foregroundStyle(part.note == nil ? Theme.fg3 : Theme.fg)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)
            }
            KeyCap(text: mine ? "↩" : model.keyText(for: "split.note", in: "splitfold"))
        }
        .font(Theme.ui(13.5))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(mine ? Theme.paneActive : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { if !mine { model.perform(CommandInvocation(name: "split.note")) } }
    }
}

// MARK: Defining a part

/// Defining a part with its agent, under the board: the conversation on the left, the part as it would be defined on
/// the right with what changes and what it does to the rest of the plan.
private struct DefinePane: View {
    @Environment(AppModel.self) private var model
    let definition: PartDefinition
    let draft: SplitDraft

    var body: some View {
        let part = draft.part(definition.part)
        let number = draft.number(of: definition.part) ?? 0
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                AgentTile(id: definition.agent, size: 32)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Defining part \(number) · \(part?.title ?? "")").font(Theme.ui(15, weight: .semibold))
                        .foregroundStyle(Theme.fg).lineLimit(1)
                    Text(([definition.via, "reads the repo, writes nothing", minutes(definition.seconds)]
                            + [definition.cost.map { $0 == 0 ? "$0" : AgentUsage.dollars($0) } ?? "cost unknown"])
                        .joined(separator: " · "))
                        .font(Theme.mono(11)).foregroundStyle(Theme.fg3).lineLimit(1)
                }
                Spacer()
                WizardButton(label: "Later", icon: "clock", command: "define.later", scope: "splitdefine")
                WizardButton(label: "Close", command: "define.close", scope: "splitdefine")
            }
            .padding(14)
            .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
            HStack(alignment: .top, spacing: 0) {
                conversation
                    .frame(maxWidth: .infinity)
                    .overlay(alignment: .trailing) { Theme.line.frame(width: 1) }
                if let part { defined(part).frame(width: 520) }
            }
            .frame(maxHeight: .infinity)
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.bg2))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }

    private func minutes(_ seconds: Double) -> String {
        let whole = Int(seconds)
        return whole < 60 ? "\(whole) s" : "\(whole / 60) m \(whole % 60) s"
    }

    private var conversation: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !definition.reads.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text("read " + definition.reads.joined(separator: " · ")).font(Theme.ui(12.5))
                }
                .foregroundStyle(Theme.fg2)
            }
            ListScroll {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(definition.turns.enumerated()), id: \.offset) { _, turn in
                        if turn.role == .you {
                            HStack {
                                Spacer(minLength: 60)
                                Text(turn.text).font(Theme.ui(13.5)).foregroundStyle(Theme.fg)
                                    .padding(10)
                                    .background(RoundedRectangle(cornerRadius: 5).fill(Theme.selected))
                            }
                        } else {
                            agentTurn(turn)
                        }
                    }
                    if definition.working {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("\(definition.agent) reads the repo…").font(Theme.ui(12.5)).foregroundStyle(Theme.fg3)
                        }
                    }
                    if let problem = definition.problem {
                        Text(problem).font(Theme.ui(12.5)).foregroundStyle(Theme.err)
                    }
                }
            }
            .frame(maxHeight: .infinity)
            DefineInput()
        }
        .padding(14)
    }

    private func agentTurn(_ turn: PartDefinition.Turn) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(turn.text).font(Theme.ui(13.5)).foregroundStyle(Theme.fg).fixedSize(horizontal: false, vertical: true)
            if !turn.options.isEmpty {
                HStack(spacing: 6) {
                    ForEach(Array(turn.options.enumerated()), id: \.offset) { index, option in
                        let picked = turn.picked == index
                        HStack(spacing: 5) {
                            if picked { Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)) }
                            Text(option).font(Theme.ui(12.5)).lineLimit(1)
                        }
                        .padding(.horizontal, 10).frame(height: 28)
                        .foregroundStyle(picked ? Theme.ink : Theme.fg)
                        .background(RoundedRectangle(cornerRadius: 4).fill(picked ? Theme.inverse : .clear))
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(picked ? .clear : Theme.keyCapBorder))
                        .clickRuns(turn.picked == nil
                            ? CommandInvocation(name: "define.pick", arguments: ["\(index + 1)"]) : nil)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
    }

    private func defined(_ part: SplitPart) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            SectionHeader(title: "Part \(draft.number(of: part.id) ?? 0), as defined")
            if let proposal = definition.draft {
                let diff = PartDefinition.diff(part, proposal)
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.done)
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(diff.kept, id: \.self) { Text($0).foregroundStyle(Theme.fg) }
                        ForEach(diff.added, id: \.self) { Text("+ " + $0).foregroundStyle(Theme.done) }
                    }
                    .font(Theme.ui(13.5))
                    .fixedSize(horizontal: false, vertical: true)
                }
                HStack(spacing: 10) {
                    Image(systemName: "clock").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    if let estimate = diff.estimate {
                        Text(SplitSchedule.text(Double(estimate.old) / 60)).strikethrough().foregroundStyle(Theme.fg3)
                        Text(SplitSchedule.text(Double(estimate.new) / 60)).foregroundStyle(Theme.fg)
                    } else {
                        Text(SplitSchedule.text(part.hours)).foregroundStyle(Theme.fg)
                    }
                    SizePips(size: diff.size?.new ?? part.size)
                    Text(diff.size.map { "now \($0.new.rawValue)" } ?? "stays \(part.size.rawValue)")
                        .foregroundStyle(Theme.fg3)
                }
                .font(Theme.ui(13.5))
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "square.3.layers.3d").font(.system(size: 12)).foregroundStyle(Theme.fg3)
                    FlowChips(items: diff.keptContext, added: diff.addedContext, plus: false)
                }
                if let knock = PartDefinition.knockOn(proposal, part: part.id, in: draft) {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "arrow.left.arrow.right").font(.system(size: 12))
                            .foregroundStyle(Theme.block)
                        Text(knock.text).font(Theme.ui(13.5)).foregroundStyle(Theme.fg2)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else {
                Text("Nothing proposed yet: the agent reads the repo first, then asks.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg3)
            }
            Spacer(minLength: 0)
            HStack(spacing: 10) {
                PrimaryAction(label: "Use this definition", command: "define.use", scope: "splitdefine")
                WizardButton(label: "Keep talking", command: "define.answer", scope: "splitdefine")
            }
        }
        .padding(16)
    }
}

/// The answer field under the defining conversation.
private struct DefineInput: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let typing = model.goals.wizard.typing
        let mine = typing?.kind == .define
        HStack(spacing: 10) {
            Image(systemName: "bolt").font(.system(size: 12)).foregroundStyle(Theme.fg3)
            if mine, !ShotMode.active {
                TextField(
                    "Answer, or tell it what else matters…",
                    text: Binding(
                        get: { model.goals.wizard.typing?.text ?? "" }, set: { model.goals.wizard.typing?.text = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .onSubmit { model.submitWizardTyping() }
            } else {
                Text(mine ? typing?.text ?? "" : "Answer, or tell it what else matters…")
                    .foregroundStyle(mine ? Theme.fg : Theme.fg3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            KeyCap(text: mine ? "↩" : model.keyText(for: "define.answer", in: "splitdefine"))
        }
        .font(Theme.ui(13.5))
        .padding(.horizontal, 14)
        .frame(height: 42)
        .background(RoundedRectangle(cornerRadius: 5).fill(Theme.bg3))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(mine ? Theme.paneActive : Theme.line))
        .contentShape(Rectangle())
        .onTapGesture { if !mine { model.perform(CommandInvocation(name: "define.answer")) } }
    }
}
