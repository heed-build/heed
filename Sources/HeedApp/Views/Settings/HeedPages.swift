import HeedCore
import SwiftUI

// Settings › Heed: General, Notifications, Updates.

struct GeneralPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let work = model.config.work
        SettingsCard(title: "Sessions") {
            SettingRow("sessions.default_agent") {
                Picker("", selection: Binding(
                    get: { work.defaultAgent }, set: { model.setConfig(["sessions", "default_agent"], .string($0)) }
                )) {
                    ForEach(work.agents) { Text($0.name).tag($0.name) }
                }
                .labelsHidden()
                .frame(width: 160)
            }
            SettingRow("sessions.resume_on_launch") {
                SegmentedChoice(
                    path: ["sessions", "resume_on_launch"], value: work.resumeOnLaunch,
                    options: ResumePolicy.allCases.map { ($0, $0.rawValue.capitalized) }, name: \.rawValue
                )
            }
            SettingRow("sessions.continue_prompt", stacked: true) {
                ConfigTextField(path: ["sessions", "continue_prompt"], value: work.continuePrompt, width: 420)
            }
            SettingRow("sessions.shell_split") {
                ConfigSwitch(path: ["sessions", "shell_split"], isOn: work.shellSplit)
            }
            SettingRow("sessions.persist") {
                SegmentedChoice(
                    path: ["sessions", "persist"], value: model.settings.persist,
                    options: [(.auto, "Auto"), (.zmx, "zmx"), (.none, "Off")], name: \.rawValue
                )
            }
            CardNote {
                Text("zmx's check, and where heed found it:")
                PageLink(page: .tools)
            }
        }
        SettingsCard(title: "Outside the window") {
            SettingRow("ui.menu_bar") {
                ConfigSwitch(path: ["ui", "menu_bar"], isOn: model.config.showMenuBarItem)
            }
            SettingRow("ui.dock_state") {
                ConfigSwitch(path: ["ui", "dock_state"], isOn: model.config.showDockState)
            }
        }
    }
}

struct NotificationsPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let notifications = model.config.notifications
        SettingsCard(title: "Sessions") {
            SettingRow("notifications.enabled", label: "Notify when a session needs you") {
                ConfigSwitch(path: ["notifications", "enabled"], isOn: notifications.enabled)
            }
            SettingRow("notifications.asking") {
                ConfigSwitch(path: ["notifications", "asking"], isOn: notifications.asking)
            }
            SettingRow("notifications.blocked") {
                ConfigSwitch(path: ["notifications", "blocked"], isOn: notifications.blocked)
            }
            SettingRow("notifications.grace_seconds", unit: "s") {
                NumberField(
                    path: ["notifications", "grace_seconds"], value: notifications.graceSeconds, unit: "s",
                    range: 0 ... 3600, step: 5
                )
            }
            SettingRow("notifications.reminder_minutes", unit: "min") {
                NumberField(
                    path: ["notifications", "reminder_minutes"], value: notifications.reminderMinutes, unit: "min",
                    range: 0 ... 1440, step: 5
                )
            }
        }
        SettingsCard(title: "Attention") {
            SettingRow("notifications.attention", label: "Notify for Attention items") {
                ConfigSwitch(path: ["notifications", "attention"], isOn: notifications.attention)
            }
            CardNote {
                Text("Rules and their weights:")
                PageLink(page: .attention)
            }
        }
        SettingsCard(title: "Quiet hours") {
            SettingRow(
                "attention.quiet",
                detail: "One window for sessions and Attention, like 22:00-07:00; empty for "
                    + "none. What needed you meanwhile shows in Needs you and on the Dock."
            ) {
                ConfigTextField(
                    path: ["attention", "quiet"], value: model.configValue(["attention", "quiet"])
                        ?? model.config.attention.quiet?.description ?? "",
                    placeholder: "22:00-07:00", width: 150
                )
            }
        }
        SettingsCard(title: "Nudges") {
            SettingRow("nudges.whats_new") {
                ConfigSwitch(path: ["nudges", "whats_new"], isOn: model.config.nudges.whatsNew)
            }
            SettingRow("nudges.gaps") {
                SegmentedChoice(
                    path: ["nudges", "gaps"], value: model.config.nudges.gaps,
                    options: [(.threeDays, "Every 3 days"), (.weekly, "Weekly"), (.off, "Off")], name: \.rawValue,
                    width: 270
                )
            }
        }
    }
}

struct UpdatesPage: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let updates = model.config.updates
        SettingsCard(title: "Updates") {
            SettingRow("updates.check") {
                ConfigSwitch(path: ["updates", "check"], isOn: updates.check)
            }
            SettingRow("updates.install") {
                SegmentedChoice(
                    path: ["updates", "install"], value: updates.install,
                    options: [(.ask, "Ask"), (.auto, "Auto")], name: \.rawValue
                )
            }
            CardNote {
                Text(":update checks now, whatever these say.")
            }
        }
    }
}
