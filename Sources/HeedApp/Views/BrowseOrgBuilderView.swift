import HeedCore
import SwiftUI

/// "Create <org> view": a language and archived over an org, the repos they keep counted live (a look at the org
/// now, never saved), and the way to save the filters as a pinned scope. It draws a `BrowseOrgBuilder`; the keys are
/// the model's.
struct BrowseOrgBuilderView: View {
    @Environment(AppModel.self) private var model
    let builder: BrowseOrgBuilder

    var body: some View {
        ZStack(alignment: .top) {
            Theme.scrim.opacity(0.5)
            VStack(alignment: .leading, spacing: 0) {
                switch builder.stage {
                case .fields: fields
                case let .values(field): values(field)
                }
            }
            .browseCardWidth(700)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.bg2))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.5), radius: 30)
            .padding(.horizontal, sheet ? 12 : 0).padding(.top, sheet ? 62 : 100)
            .shotRegion(.browseBuilder)
        }
    }

    /// Below 640 the card is a sheet across the window (the design's third width).
    private var sheet: Bool { model.browse.layout == .third }

    private func orgMark(_ size: CGFloat) -> some View {
        Text(String(builder.owner.prefix(1)).uppercased()).font(.system(size: size * 0.5, weight: .bold))
            .foregroundStyle(Theme.ink).frame(width: size, height: size)
            .background(RoundedRectangle(cornerRadius: 5).fill(Repo(org: builder.owner, name: "").color.foreground))
    }

    private var fields: some View {
        let repos = builder.repos
        return VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 12) {
                orgMark(24)
                Text("Create \(builder.owner) view").font(Theme.ui(15, weight: .semibold))
                Spacer()
                Text("esc").font(Theme.mono(10)).foregroundStyle(Theme.fg3).padding(.horizontal, 5)
                    .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Theme.line))
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Theme.line.frame(height: 1)
            ForEach(Array(BrowseOrgBuilder.Field.allCases.enumerated()), id: \.element) { index, field in
                HStack(spacing: 14) {
                    Text(field.title).font(Theme.ui(14.5, weight: .semibold))
                        .frame(width: sheet ? 80 : 110, alignment: .leading)
                    Text(builder.summary(of: field)).font(Theme.ui(14, weight: .semibold))
                        .padding(.horizontal, 9).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.chip))
                    Text(field.hint).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                        .lineLimit(sheet ? 2 : 1).fixedSize(horizontal: false, vertical: sheet)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 20).padding(.vertical, 8)
                .background(builder.stage == .fields && builder.cursor == index ? Theme.bg3 : .clear)
            }
            Theme.line.frame(height: 1).padding(.top, 6)
            VStack(alignment: .leading, spacing: 12) {
                if builder.loading {
                    Text("Reading \(builder.owner)'s repos…").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                } else if let problem = builder.problem {
                    Label(problem, systemImage: "exclamationmark.triangle").font(Theme.ui(12.5))
                        .foregroundStyle(Theme.block)
                }
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text("\(repos.count)").font(Theme.ui(26, weight: .bold))
                    Text("of \(builder.infos.count) repos · live").font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                }
                FlowLayout(spacing: 4) {
                    ForEach(repos.prefix(24), id: \.self) { slug in
                        let parts = slug.split(separator: "/").map(String.init)
                        let repo = parts.count == 2 ? Repo(org: parts[0], name: parts[1]) : nil
                        Text(String(repo?.name.prefix(1) ?? "?").uppercased()).font(.system(
                            size: 10,
                            weight: .semibold
                        ))
                        .foregroundStyle(repo?.color.foreground ?? Theme.fg2).frame(width: 20, height: 20)
                        .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(
                            repo?.color.foreground ?? Theme.fg2,
                            lineWidth: 1.2
                        ))
                    }
                    if repos.count > 24 { Text("+\(repos.count - 24)").font(Theme.ui(13)).foregroundStyle(Theme.fg2) }
                }
                HStack(spacing: 8) {
                    Text("Create \(builder.name)").font(Theme.ui(14, weight: .semibold))
                    Text("⌘↩").font(Theme.mono(10)).padding(.horizontal, 5)
                }
                .foregroundStyle(Theme.ink).padding(.horizontal, 16).padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.white))
                .overlay(alignment: .trailing) { if builder.onCreate { Color.clear } }
                .opacity(repos.isEmpty ? 0.45 : 1)
                Text(note).font(Theme.ui(12)).foregroundStyle(Theme.fg3).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
    }

    /// What the view is made of, said once: it stores filters, never repos, and GitHub applies them on every search.
    private var note: String {
        "The view keeps only \(builder.view.qualifier). GitHub applies it on every search, so it never goes stale; "
            + "the count above is a look at \(builder.owner) now."
    }

    private func values(_ field: BrowseOrgBuilder.Field) -> some View {
        let picker = builder.picker ?? BrowsePicker(options: [], multiple: false)
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(field.title).font(Theme.ui(15, weight: .semibold))
                Spacer()
                Text("esc").font(Theme.mono(10)).foregroundStyle(Theme.fg3)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            Theme.line.frame(height: 1)
            ForEach(Array(picker.visible.prefix(10).enumerated()), id: \.element.value) { index, option in
                let on = picker.selected.contains(option.value)
                HStack(spacing: 12) {
                    Image(systemName: on ? "checkmark.square.fill" : "square")
                        .foregroundStyle(on ? Theme.busy : Theme.fg3)
                    Text(option.label).font(Theme.ui(14))
                    Spacer()
                    if let count = option.count { Text("\(count)").font(Theme.mono(12)).foregroundStyle(Theme.fg2) }
                }
                .padding(.horizontal, 20).padding(.vertical, 7)
                .background(index == picker.cursor ? Theme.bg3 : .clear)
            }
            if picker.visible.isEmpty {
                Text("Nothing to choose from.")
                    .font(Theme.ui(13)).foregroundStyle(Theme.fg3).padding(20)
            }
        }
        .padding(.bottom, 8)
    }
}
