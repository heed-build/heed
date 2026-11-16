import Foundation
import HeedCore

/// The dialogs over the window, kept in one `DialogStack` (`AppModel.dialogs`) instead of a variable each. Each still
/// has its own accessor (`startWork`, `confirmation`, `nudge`, …); `dialogOpen` is the one answer to whether a click
/// may reach what is under them. Which open dialog takes a key stays `handleKey`'s order.
extension AppModel {
    enum Modal {
        case startWork(StartWorkSession)
        case resume(ResumeForm)
        case firstRun(FirstRunReport)
        case nudge(NudgeDialog)
        case confirmation(Confirmation)
        case importPicker(Typeahead<Worktree>)
        case taskPicker(TaskPickerState)
        case hostsPicker(Typeahead<HostRow>)
        case hostRootsChooser(HostRootsChooser)
        case linkPicker(LinkPicker)
        case runReader(PilotRun)
        case pilotExplain(PullRef)
        case awaySummary(AwaySummary)
        case repoSetup(RepoSetupWizard)
        case pathImport(PathImport)
        case addRepo(AddRepoForm)

        enum Kind: Hashable, Sendable, CaseIterable {
            case startWork, resume, firstRun, nudge, confirmation, importPicker, taskPicker, hostsPicker
            case hostRootsChooser, linkPicker, runReader, pilotExplain, awaySummary, repoSetup, pathImport, addRepo
        }

        var kind: Kind {
            switch self {
            case .startWork: .startWork
            case .resume: .resume
            case .firstRun: .firstRun
            case .nudge: .nudge
            case .confirmation: .confirmation
            case .importPicker: .importPicker
            case .taskPicker: .taskPicker
            case .hostsPicker: .hostsPicker
            case .hostRootsChooser: .hostRootsChooser
            case .linkPicker: .linkPicker
            case .runReader: .runReader
            case .pilotExplain: .pilotExplain
            case .awaySummary: .awaySummary
            case .repoSetup: .repoSetup
            case .pathImport: .pathImport
            case .addRepo: .addRepo
            }
        }
    }

    /// A dialog has the keyboard: a click on a list, a hint or a terminal under it does nothing. The tutor's picker
    /// counts too.
    var dialogOpen: Bool {
        !dialogs.isEmpty || tutorPicker != nil
    }

    func setDialog(_ kind: Modal.Kind, _ dialog: Modal?) {
        dialogs.set(kind, dialog)
    }

    // MARK: Start work

    /// The Start work dialog while it is open: its form, where it shows and how far starting it got.
    var startWorkSession: StartWorkSession? {
        get { if case let .startWork(session) = dialogs[.startWork] { session } else { nil } }
        set {
            let wasStandalone = startWorkStandalone
            setDialog(.startWork, newValue.map(Modal.startWork))
            if newValue == nil, wasStandalone { StartWorkPanelController.shared.close() }
        }
    }

    /// The Start work dialog's form, while open. Set from AppModel+StartWorkSmarts too (the model's advice). Setting
    /// a form changes the open dialog's (or opens one in the window); nil closes it, and its panel.
    var startWork: StartWorkForm? {
        get { startWorkSession?.form }
        set {
            if let newValue {
                if startWorkSession == nil {
                    startWorkSession = StartWorkSession(form: newValue)
                } else {
                    startWorkSession?.form = newValue
                }
            } else {
                startWorkSession = nil
            }
            adviseStartWork()
            sizeStartWork()
        }
    }

    /// The Start work dialog is showing in its own panel over other apps (`[keys] global_start_work`).
    var startWorkStandalone: Bool { startWorkSession?.presentation == .standalone }
    /// Why the last start failed, shown in the dialog (the standalone panel has no status bar).
    var startWorkError: String? { startWorkSession?.error }
    var startingWork: Bool { startWorkSession?.isStarting ?? false }

    // MARK: The others

    /// heed's own nudge, the one shown (AppModel+Nudges).
    var nudge: NudgeDialog? {
        get { if case let .nudge(value) = dialogs[.nudge] { value } else { nil } }
        set { setDialog(.nudge, newValue.map(Modal.nudge)) }
    }

    /// The run the reader shows (`↩` on a Runs row).
    var runReader: PilotRun? {
        get { if case let .runReader(value) = dialogs[.runReader] { value } else { nil } }
        set { setDialog(.runReader, newValue.map(Modal.runReader)) }
    }

    /// While you were away (`summary`), while it shows.
    var awaySummary: AwaySummary? {
        get { if case let .awaySummary(value) = dialogs[.awaySummary] { value } else { nil } }
        set { setDialog(.awaySummary, newValue.map(Modal.awaySummary)) }
    }

    /// The PR `pilot.why` explains: what heed will do for it and what holds it back.
    var pilotExplain: PullRef? {
        get { if case let .pilotExplain(value) = dialogs[.pilotExplain] { value } else { nil } }
        set { setDialog(.pilotExplain, newValue.map(Modal.pilotExplain)) }
    }

    /// The setup wizard for a repo's get it merged and get it green (`repo.setup`), while it shows
    /// (AppModel+RepoSetup).
    var repoSetup: RepoSetupWizard? {
        get { if case let .repoSetup(value) = dialogs[.repoSetup] { value } else { nil } }
        set { setDialog(.repoSetup, newValue.map(Modal.repoSetup)) }
    }

    /// Repos › Add or clone (`a`, `:repo.add`): the field, the lists, what is picked; nil when closed.
    var addRepoDialog: AddRepoForm? {
        get { if case let .addRepo(value) = dialogs[.addRepo] { value } else { nil } }
        set { setDialog(.addRepo, newValue.map(Modal.addRepo)) }
    }
}
