import HeedCore
import SwiftUI

/// `:log`: every command heed ran and every GitHub call it made, newest first and live, with what each cost in time;
/// the call under the cursor in full on the right. Model runs (`llm`, `decide`) land here too, with their tokens and
/// cost, and the strip above sums today's per agent.
struct CallLogView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let log = model.callLog
        let rows = log.rows
        GeometryReader { geometry in
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    filters(log.query)
                    UsageStrip(usage: log.usage).shotRegion(.logUsage)
                    header
                    ListBody(
                        count: rows.count,
                        cursor: log.cursor,
                        ids: rows.map { String($0.id) },
                        empty: empty(log),
                        hintView: .log
                    ) { index in
                        CallRow(
                            call: rows[index],
                            index: index,
                            cursor: log.cursor,
                            compact: geometry.size.width < 1000
                        )
                    }
                    .shotRegion(.logList)
                }
                if geometry.size.width >= 1100, let call = log.selected {
                    CallDetail(call: call).shotRegion(.logDetail)
                }
            }
        }
    }

    private func empty(_ log: CallLogBrowser) -> String {
        if log.unavailable { return "The call log could not be opened; nothing is logged this run." }
        if !log.query.isEmpty || !model.filter(for: .log).isEmpty { return "No call matches." }
        return "Nothing logged yet. Every command heed runs, each GitHub call and its own model calls land here as "
            + "they happen, with how long each took and how it ended. \(model.keyText(for: "log.kind", in: "log")) "
            + "shows one kind, \(model.keyText(for: "log.failed", in: "log")) only what failed."
    }

    private func filters(_ query: CallLogQuery) -> some View {
        HStack(spacing: 8) {
            // A click on a chip does what its key does: t names the kind, x s w toggle, c and a clear.
            FilterChip(label: "All", on: query.kind == nil)
                .clickRuns(CommandInvocation(name: "log.kind", arguments: ["all"]))
            ForEach(CallKind.all, id: \.self) { kind in
                FilterChip(label: kind.rawValue, on: query.kind == kind)
                    .clickRuns(CommandInvocation(name: "log.kind", arguments: [kind.rawValue]))
            }
            Theme.line.frame(width: 1, height: 14).padding(.horizontal, 4)
            FilterChip(label: "failed", on: query.failedOnly).clickRuns(CommandInvocation(name: "log.failed"))
            FilterChip(label: "slow", on: query.slowOnly).clickRuns(CommandInvocation(name: "log.slow"))
            FilterChip(label: "github writes", on: query.githubWritesOnly)
                .clickRuns(CommandInvocation(name: "log.writes"))
            if let caller = query.caller {
                FilterChip(label: "caller \(caller)", on: true).clickRuns(CommandInvocation(name: "log.caller"))
            }
            if let agent = query.agent {
                FilterChip(label: "agent \(agent)", on: true).clickRuns(CommandInvocation(name: "log.agent"))
            }
            Spacer(minLength: 8)
            FilterPill(view: .log)
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: 24)
            Group {
                Text("TIME").frame(width: 64, alignment: .leading)
                Text("KIND").frame(width: 58, alignment: .leading)
                Text("CALLER").frame(width: 150, alignment: .leading)
                Text("COMMAND").frame(maxWidth: .infinity, alignment: .leading)
                Text("TOOK").frame(width: 56, alignment: .trailing)
                Text("EXIT").frame(width: 44, alignment: .trailing)
            }
            .font(Theme.ui(10.5, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(Theme.fg3)
        }
        .padding(.horizontal, 16)
        .frame(height: 30)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

/// Today's model calls and cost per agent, and what GitHub's rate limit had left when last seen.
private struct UsageStrip: View {
    let usage: CallUsage

    var body: some View {
        HStack(spacing: 14) {
            SectionHeader(title: "Today")
            if usage.agents.isEmpty {
                Text("no model calls").foregroundStyle(Theme.fg3)
            }
            ForEach(usage.agents, id: \.name) { agent in
                HStack(spacing: 6) {
                    Text(agent.name).foregroundStyle(Theme.fg)
                    Text("\(agent.calls) call\(agent.calls == 1 ? "" : "s")").foregroundStyle(Theme.fg2)
                    if let cost = agent.cost {
                        Text(CallUsage.money(cost, estimated: agent.estimated)).foregroundStyle(Theme.fg2)
                    }
                }
            }
            Spacer(minLength: 8)
            if let remaining = usage.rateRemaining {
                HStack(spacing: 6) {
                    Text("GitHub").foregroundStyle(Theme.fg3)
                    Text("\(Counts.text(remaining)) left").foregroundStyle(remaining < 500 ? Theme.block : Theme.fg2)
                    if let at = usage.rateAt { Text(Clock.relative(at)).foregroundStyle(Theme.fg3) }
                }
            }
        }
        .font(Theme.mono(11.5))
        .lineLimit(1)
        .padding(.horizontal, 20)
        .frame(height: 32)
        .background(Theme.bg2)
        .overlay(alignment: .bottom) { Theme.line.frame(height: 1) }
    }
}

private struct CallRow: View {
    let call: LoggedCall
    let index: Int
    let cursor: Int
    var compact = false

    var body: some View {
        HStack(spacing: 10) {
            RowNumber(index: index, cursor: cursor)
            Text(call.at, format: .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second())
                .foregroundStyle(Theme.fg3)
                .frame(width: 64, alignment: .leading)
            KindTag(call: call).frame(width: 58, alignment: .leading)
            Text(call.caller).foregroundStyle(Theme.fg2).lineLimit(1).truncationMode(.tail)
                .frame(width: 150, alignment: .leading)
            HStack(spacing: 6) {
                if let host = call.host { HostChip(location: .host(host)).fixedSize() }
                Text(CallLine.summary(call)).foregroundStyle(Theme.fg).lineLimit(1).truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(CallLine.took(call.duration))
                .foregroundStyle(call.duration >= CallFilter.slow ? Theme.block : Theme.fg2)
                .frame(width: 56, alignment: .trailing)
            Text(call.exitCode.map(String.init) ?? "–")
                .foregroundStyle(call.failed ? Theme.err : Theme.fg3)
                .frame(width: 44, alignment: .trailing)
        }
        .font(Theme.mono(12))
        .padding(.horizontal, 16)
        .frame(height: 34)
        .background(index == cursor ? Theme.bg3 : .clear)
    }
}

/// The kind, with a write to GitHub marked: it changed something there.
private struct KindTag: View {
    let call: LoggedCall

    var body: some View {
        HStack(spacing: 3) {
            Text(call.kind.rawValue).foregroundStyle(color)
            if call.write { Text("w").foregroundStyle(Theme.block) }
        }
        .font(Theme.mono(11))
    }

    private var color: Color {
        switch call.kind {
        case .github: Theme.busy
        case .llm, .decide: Theme.ask
        default: Theme.fg2
        }
    }
}

enum CallLine {
    /// What the row says: a GitHub call or a model run by its operation and the gist of its answer, a command as run.
    static func summary(_ call: LoggedCall) -> String {
        switch call.kind {
        case .github:
            let parts = [
                call.operation,
                call.items.map { "\($0) item\($0 == 1 ? "" : "s")" },
                call.hidden.flatMap { $0 > 0 ? "\($0) hidden" : nil },
            ]
            return parts.compactMap(\.self).joined(separator: " · ")
        case .llm, .decide:
            return [call.agent, call.model, call.operation].compactMap(\.self).joined(separator: " · ")
        default:
            return call.command
        }
    }

    /// `40ms`, `1.8s`, `12s`.
    static func took(_ seconds: TimeInterval) -> String {
        if seconds < 1 { return "\(Int((seconds * 1000).rounded()))ms" }
        if seconds < 10 { return String(format: "%.1fs", seconds) }
        return "\(Int(seconds.rounded()))s"
    }
}

private struct CallDetail: View {
    @Environment(AppModel.self) private var model
    let call: LoggedCall

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(
                    title: "\(call.kind.rawValue)\(call.write ? " · write" : "") · \(Clock.relative(call.at))",
                    tint: call.failed ? Theme.err : Theme.fg3
                )
                Spacer()
                if let host = call.host { HostChip(location: .host(host)) }
            }
            Text(call.operation ?? call.caller).font(Theme.ui(16, weight: .semibold))
            block(call.command, tint: Theme.fg)
            fields
            if let stderr = call.stderr { output("stderr", stderr) }
            if let stdout = call.stdout { output("stdout", stdout) }
            ForEach(call.detail.sorted { $0.key < $1.key }, id: \.key) { key, value in
                output(key, value)
            }
            Spacer(minLength: 0)
            Theme.line.frame(height: 1)
            HStack(spacing: 10) {
                KeyHint("log.copy", scope: "log", spacing: 10, label: "copy the command", color: Theme.fg2)
                KeyHint("log.caller", scope: "log", spacing: 10, label: "only this caller", color: Theme.fg2)
            }
        }
        .padding(22)
        .frame(width: 420)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Theme.bg2)
        .overlay(alignment: .leading) { Theme.line.frame(width: 1) }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 5) {
            field("caller", call.caller)
            field("where", call.host.map { "@\($0)" } ?? "this Mac")
            if let cwd = call.cwd { field("in", cwd) }
            field("took", CallLine.took(call.duration))
            field("exit", call.exitCode.map(String.init) ?? (call.failed ? "did not run" : "running"))
            if let items = call.items { field("items", "\(items)") }
            if let hidden = call.hidden, hidden > 0 { field("hidden", "\(hidden) withheld by SAML") }
            if let remaining = call.rateRemaining {
                field("rate limit", "cost \(call.rateCost ?? 0) · \(Counts.text(remaining)) left")
            }
            if let agent = call
                .agent { field("agent", [agent, call.model].compactMap(\.self).joined(separator: " · ")) }
            if let tokens = call.tokens {
                field("tokens", "\(Counts.text(tokens.allInput)) in · \(Counts.text(tokens.output)) out")
            }
            if let cost = call.cost { field("cost", CallUsage.money(cost, estimated: call.costEstimated)) }
        }
        .font(Theme.mono(12))
    }

    private func field(_ name: String, _ value: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(name).foregroundStyle(Theme.fg3).frame(width: 78, alignment: .leading)
            Text(value).foregroundStyle(Theme.fg).textSelection(.enabled)
        }
    }

    private func output(_ title: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionHeader(title: title)
            block(text, tint: title == "stderr" && call.failed ? Theme.err : Theme.fg2)
        }
    }

    private func block(_ text: String, tint: Color) -> some View {
        Text(text.trimmingCharacters(in: .newlines))
            .font(Theme.mono(12))
            .foregroundStyle(tint)
            .textSelection(.enabled)
            .lineLimit(14)
            .fixedSize(horizontal: false, vertical: true)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 6).fill(Theme.pane))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line))
    }
}

enum Counts {
    /// `4,812`: grouped the same whatever the Mac's region, as the rest of the log's numbers.
    static func text(_ count: Int) -> String {
        count.formatted(.number.locale(Locale(identifier: "en_US")).grouping(.automatic))
    }
}
