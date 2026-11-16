import CoreGraphics
import HeedCore

/// The shots the docs added in the second pass over their screenshots: Settings crops, single elements, and first
/// shots for pages that had none.
extension Shots {
    static let settingsCrops: [Shot] = [
        // The button at the top of the tree and its badge.
        Shot(
            id: "configuration/configure-button", subject: .settings(.notifications),
            size: CGSize(width: 1080, height: 620), crop: .settingsTabs, cropPadding: 0
        ),
        // A refused value: the red bar, the reason and the line heed would take.
        Shot(
            id: "configuration/modified-refused", subject: .settings(.notifications),
            size: CGSize(width: 1080, height: 860), crop: .settingsSection, cropPadding: 8, item: "Quiet hours",
            prepare: { $0.applyConfig(source: Shots.modifiedConfig) }
        ),
        Shot(
            id: "configuration/attention-rules-list", subject: .settings(.attention),
            size: CGSize(width: 1300, height: 1480), crop: .settingsSection, cropPadding: 8, item: "Rules",
            prepare: attentionRulesSeed
        ),
        Shot(
            id: "configuration/attention-rules-try", subject: .settings(.attention),
            size: CGSize(width: 1300, height: 1480), crop: .settingsSection, cropPadding: 8,
            item: "Try before you save", prepare: attentionRulesSeed
        ),
        Shot(
            id: "configuration/tools-found", subject: .settings(.tools), size: CGSize(width: 1080, height: 720),
            crop: .settingsSection, cropPadding: 8, item: "Found",
            prepare: { $0.setToolsForShots(Shots.firstRunReport.tools!) }
        ),
        Shot(
            id: "configuration/tools-zmx", subject: .settings(.tools), size: CGSize(width: 1080, height: 720),
            crop: .settingsRow, cropPadding: 8, item: "tools.zmx",
            prepare: { $0.settingsFilter.showAdvanced = true }
        ),
        Shot(
            id: "configuration/updates-settings", subject: .settings(.updates), size: CGSize(width: 1080, height: 720),
            crop: .settingsSection, cropPadding: 8, item: "Updates"
        ),
        Shot(
            id: "configuration/updates-prompt", subject: .updatePrompt, size: CGSize(width: 560, height: 420),
            crop: .dialog, cropPadding: 24
        ),
        Shot(
            id: "settings/personas-row", subject: .settings(.personas), size: CGSize(width: 1440, height: 900),
            crop: .settingsRow, cropPadding: 6, item: "docs-site-maintainer",
            prepare: { model in
                model.loadPersonaLibraryFixture()
                model.personaUI.setCursor(11, count: 13)
            }
        ),
        Shot(
            id: "settings/personas-detail", subject: .settings(.personas), size: CGSize(width: 1440, height: 760),
            crop: .settingsSection, cropPadding: 0, item: "detail",
            prepare: { model in
                model.loadPersonaLibraryFixture()
                model.personaUI.setCursor(11, count: 13)
            }
        ),
        Shot(
            id: "settings/personas-list", subject: .settings(.personas), size: CGSize(width: 1440, height: 900),
            crop: .settingsSection, cropPadding: 0, item: "list",
            prepare: { model in
                model.loadPersonaLibraryFixture()
                model.personaUI.setCursor(11, count: 13)
            }
        ),
        Shot(
            id: "agents/model-custom-conflicts", subject: .settings(.pilot), size: CGSize(width: 1180, height: 1060),
            crop: .settingsSection, cropPadding: 8, item: "Merge conflicts", prepare: modelCustomSeed
        ),
    ]

    static let modelCards: [Shot] = [
        Shot(
            id: "agents/model-calls-card", subject: .settings(.agents), size: CGSize(width: 1180, height: 720),
            crop: .settingsSection, cropPadding: 8, item: "Model calls",
            prepare: { model in
                model.agentTab = .modelCalls
                model.llmTests["claude"] = .passed(AgentTestAnswer(
                    text: "Hello!",
                    model: "claude-haiku",
                    seconds: 2.9,
                    cost: 0.00026
                ))
            }
        ),
        Shot(
            id: "agents/model-pickers-card", subject: .settings(.agents), size: CGSize(width: 1180, height: 860),
            crop: .settingsSection, cropPadding: 8, item: "Starting",
            prepare: { $0.applyConfig(source: "[agents.claude]\nmodel = \"opus\"\neffort = \"high\"\n") }
        ),
    ]

    static let attentionRulesSeed: @MainActor (AppModel) -> Void = { model in
        model.attention.ruleDraftSeed = Fixtures.attentionRules.map {
            $0.hasPrefix("ci ") ? "ci ignore" : $0
        } + ["mention team:? lower", "# the rest", "assigend boost 1"]
        model.attention.ruleFormSeed = AttentionRuleForm(
            clauses: [.reason(.review), .repo("acme/guides")], weight: .lower, notify: false
        )
    }

    static let modelCustomSeed: @MainActor (AppModel) -> Void = { model in
        model.applyConfig(source: """
        [pilot]
        agent = "codex"
        model = "gpt-6-luna"
        effort = "high"
        merge_agent = "claude"
        merge_model = "team-proxy-small"
        """)
    }

    static let elements: [Shot] = [
        Shot(id: "sessions/row", size: CGSize(width: 1440, height: 640), crop: .sessionRow, cropPadding: 0, item: "s1"),
        Shot(id: "sessions/row-host", crop: .sessionRow, cropPadding: 0, item: "s7"),
        Shot(id: "sessions/foot", crop: .sessionFoot, cropPadding: 0, prepare: { model in
            model.loadSessionPanelFixture(.offer)
            model.loadHelperFixture(line: true)
        }),
        Shot(id: "sessions/inspector-prs", crop: .inspectorPR, cropPadding: 8),
        Shot(id: "sessions/inspector-issues", crop: .inspectorIssues, cropPadding: 8),
        Shot(id: "github/pr-row", keys: ":prs<CR>", crop: .prRow, cropPadding: 0, item: "2841"),
        Shot(
            id: "agents/approvals-row", keys: "gy", crop: .approvalRow, cropPadding: 0,
            item: "hook\u{1F}Bash\u{1F}dotnet publish -c Release src/Validator\u{1F}\u{1F}\u{1F}",
            prepare: { $0.approvals.queue = ApprovalQueue(asks: Fixtures.approvalAsks()) }, fixture: "approvals"
        ),
        Shot(id: "github/attention-row", keys: "gm", crop: .attentionRow, cropPadding: 0, item: "2845"),
        Shot(id: "start-work/chips", keys: "o" + prompt, crop: .startWorkChips, cropPadding: 0),
        Shot(id: "start-work/prompt", keys: "o" + prompt, crop: .startWorkPrompt, cropPadding: 8),
        Shot(
            id: "goals/split-part", crop: .splitPart, cropPadding: 6, item: "schema-v2/migrate",
            prepare: { $0.loadSplitFixture(.complex, part: "migrate") }
        ),
        Shot(id: "autopilot/checklist", keys: "gwN/moved<CR>", crop: .pilotChecklist, cropPadding: 8),
        Shot(id: "diff/note-box", keys: "gdjja" + typed(noteText), crop: .diffNote, cropPadding: 0),
        Shot(id: "diff/files", size: CGSize(width: 1440, height: 640), keys: "gd", crop: .diffFiles, cropPadding: 0),
        Shot(id: "autopilot/now-list", keys: "gwN", crop: .autopilotNow, cropPadding: 0),
        Shot(id: "autopilot/can-do-where", keys: "gw", crop: .autopilotMatrix, cropPadding: 8),
        Shot(
            id: "keyboard/menu-session", subject: .sessionMenu("s1"), size: CGSize(width: 400, height: 900),
            crop: .contextMenu, cropPadding: 20
        ),
        Shot(
            id: "keyboard/menu-pr", subject: .pullMenu(PullRef(
                repo: Repo(org: "acme", name: "docs-toolkit"),
                number: 2841
            )),
            size: CGSize(width: 400, height: 900), crop: .contextMenu, cropPadding: 20
        ),
        Shot(
            id: "keyboard/menu-bar-session", subject: .appMenu("Session"), size: CGSize(width: 500, height: 1100),
            crop: .contextMenu, cropPadding: 20
        ),
        Shot(
            id: "outside/notification", subject: .banner(
                title: "Cross-link validator for assemblies", body: "Blocked: Bash(dotnet publish)",
                actions: ["Open", "Allow"]
            ), size: CGSize(width: 480, height: 130), crop: .notificationBanner, cropPadding: 16
        ),
        Shot(
            id: "outside/notification-asking", subject: .banner(
                title: "Backpressure in ingest stage", body: "Asking: 3 questions waiting", actions: ["Open"]
            ), size: CGSize(width: 480, height: 130), crop: .notificationBanner, cropPadding: 16
        ),
        Shot(
            id: "github/track-command", keys: ":track<Space>https://github.com/acme/docs-website/pull/1934",
            crop: .commandLine, cropPadding: 16
        ),
        Shot(
            id: "agents/messages-queued", keys: "gdjja" + typed(noteText) + "<CR><Esc>go", crop: .delivery,
            cropPadding: 8
        ),
        Shot(
            id: "sessions/host-strip",
            keys: "",
            crop: .hostStrip,
            cropPadding: 0,
            prepare: { $0.select(sessionID: "s7") }
        ),
    ]
}
