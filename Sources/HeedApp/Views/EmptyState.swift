import HeedCore
import SwiftUI

/// What an empty list says, centred where its rows would be: what fills it, and the next step as buttons that run a
/// command, each with the key it is on.
struct EmptyState: View {
    @Environment(AppModel.self) private var model

    struct Action {
        let label: String
        let command: CommandInvocation
        /// The key shown; nil shows the command's key as bound (`:name` when it is on none).
        var key: String?

        init(_ label: String, _ name: String, arguments: [String] = [], key: String? = nil) {
            self.label = label
            command = CommandInvocation(name: name, arguments: arguments)
            self.key = key
        }
    }

    let title: String
    var detail: String?
    var actions: [Action] = []
    /// A quieter last line that runs a command too: the tutor.
    var pointer: Action?
    var pointerText: String?

    var body: some View {
        VStack(spacing: 12) {
            Text(title).font(Theme.ui(20, weight: .semibold)).foregroundStyle(Theme.fg)
            if let detail {
                Text(detail).font(Theme.ui(13)).foregroundStyle(Theme.fg2)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            VStack(alignment: .leading, spacing: 8) {
                ForEach(actions, id: \.label) { action in
                    row(action, text: action.label, tint: Theme.fg2)
                }
                if let pointer, let pointerText {
                    row(pointer, text: "\(pointerText) \(pointer.label.lowercased())", tint: Theme.fg3)
                        .padding(.top, 6)
                }
            }
            .padding(.top, 4)
        }
        .padding(24)
        .frame(maxWidth: 440)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A key and what it does, as the design board draws them; a click runs it as the key would (`KeyHint`).
    private func row(_ action: Action, text: String, tint: Color) -> some View {
        KeyHint(
            action.command.name, action.command.arguments, key: action.key, spacing: 10, label: text, color: tint,
            font: Theme.ui(13)
        )
    }
}
