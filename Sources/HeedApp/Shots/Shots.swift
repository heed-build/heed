import HeedCore
import SwiftUI

/// Every screenshot in the docs, generated from the fake world by `mise run shots`. A shot's id is its path under
/// docs/images/shots; pages reference them as `../images/shots/<id>.png`.
@MainActor
enum Shots {
    static let all: [Shot] = home + sessions + startWork + outside

    static let home: [Shot] = [
        Shot(id: "home/sessions"),
    ]

    static let sessions: [Shot] = [
        Shot(id: "sessions/anatomy", highlight: [.sidebar, .center, .inspector]),
        Shot(id: "sessions/sidebar", crop: .sidebar),
    ]

    static let startWork: [Shot] = [
        Shot(
            id: "start-work/dialog",
            keys: "oFix<Space>broken<Space>anchors<Space>in<Space>the<Space>redirect<Space>pages",
            crop: .dialog
        ),
        Shot(id: "start-work/panel", subject: .panel, size: CGSize(width: 1100, height: 820)),
    ]

    static let outside: [Shot] = [
        Shot(id: "outside/menu-bar", subject: .menuBar, size: CGSize(width: 520, height: 34)),
        Shot(id: "outside/menu", subject: .menu, size: CGSize(width: 620, height: 380)),
        Shot(id: "outside/dock", subject: .dock, size: CGSize(width: 420, height: 130), crop: .picker, cropPadding: 30),
    ]
}
