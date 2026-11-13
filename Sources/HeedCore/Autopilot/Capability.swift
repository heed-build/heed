/// What heed can do on your behalf, as Autopilot lists it: one per thing it does on its own once it is on. Each says
/// how it is configured (per repo through `[pilot]` and its org and repo levels, or once for everything), what it is
/// in plain words, how it goes, and what it never does. The words are the docs' and the code's, not a pitch: every
/// rail in `never` is one the code holds to.
public enum Capability: String, CaseIterable, Hashable, Sendable, Identifiable {
    case green, merge, copilot, reviewers, cleanup, goals, summaries
    case resume = "continue"
    case names

    public var id: String { rawValue }

    /// Where it is set: per repo (the `[pilot]` levels), or once for every repo.
    public enum Scope: Sendable {
        case perRepo, everywhere
    }

    public var scope: Scope {
        switch self {
        case .green, .merge, .copilot, .reviewers: .perRepo
        case .cleanup, .goals, .summaries, .resume, .names: .everywhere
        }
    }

    public var title: String {
        switch self {
        case .green: "Green"
        case .merge: "Merge"
        case .copilot: "Copilot"
        case .reviewers: "Reviewers"
        case .cleanup: "Cleanup"
        case .goals: "Goals"
        case .summaries: "Summaries"
        case .resume: "Continue"
        case .names: "Names"
        }
    }

    /// The command whose key the card shows, when it has one: what does it for one PR (or now).
    public var command: String? {
        switch self {
        case .green: "pilot.green"
        case .merge: "pilot.merge"
        case .reviewers: "pilot.reviewers"
        case .cleanup: "cleanup.run"
        case .copilot, .goals, .summaries, .resume, .names: nil
        }
    }

    /// The Settings page that sets it (`:settings.open <name>`).
    public var settingsPage: String {
        switch self {
        case .green, .merge, .copilot, .reviewers: "pilot"
        case .cleanup: "worktrees"
        case .goals: "model-calls"
        case .summaries: "attention"
        case .resume, .names: "general"
        }
    }

    /// The card's sentence.
    public var sentence: String {
        switch self {
        case .green:
            "Review comments and failing checks go to the PR's agent; heed checks again after each push."
        case .merge: "Merges a PR once it's green, by GitHub's auto-merge or heed's own rules."
        case .copilot: "Hands merge conflicts and review comments to Copilot, so your agent's tokens aren't spent."
        case .reviewers: "Asks the people, teams or Copilot you name to review once a PR is ready."
        case .cleanup: "Removes worktrees idle for a while whose work is pushed; never dirty or unpushed work."
        case .goals: "Puts each session on the goal it belongs to, and asks when it isn't sure."
        case .summaries: "Writes catch-up summaries in Attention ahead of time, within the day's model calls."
        case .resume: "After a resume, tells agents that were mid-turn to carry on."
        case .names: "Names sessions from what they turn out to be about."
        }
    }

    /// The detail's subtitle.
    public var tagline: String {
        switch self {
        case .green: "get a PR green without you in the loop"
        case .merge: "get a green PR merged, and the rest up to date"
        case .copilot: "let Copilot do the fixing"
        case .reviewers: "the right reviewers, asked on time"
        case .cleanup: "worktrees that finished go by themselves"
        case .goals: "work lands on its goal"
        case .summaries: "read the catch-up, not the thread"
        case .resume: "agents pick up where they stopped"
        case .names: "sessions called what they are"
        }
    }

    public var without: String {
        switch self {
        case .green: "You read the review, copy each comment into the agent, wait for the push, check CI, repeat."
        case .merge: "You keep checking whether the PR is green, press merge, then update the PRs that fell behind."
        case .copilot: "Your agent resolves every conflict and comment, on your tokens."
        case .reviewers: "You remember to ask the same reviewers on every PR, once it is out of draft."
        case .cleanup: "Finished worktrees pile up until you remove them one by one."
        case .goals: "You put every session on its goal by hand, or it lands on none."
        case .summaries: "You open a long thread and read it from the top to find what changed."
        case .resume: "After a restart you go through the agents that were working and tell each to go on."
        case .names: "Sessions keep the first words of their prompt as a title."
        }
    }

    public var with: String {
        switch self {
        case .green:
            "heed sends each comment and failing check, with the failed step's log, waits for the push, checks again."
        case .merge:
            "Each repo's queue turns auto-merge on for green PRs, or merges by heed's rules, and says why it holds one."
        case .copilot: "heed asks @copilot on the PR, once per conflict and comment; Copilot pushes to the branch."
        case .reviewers: "heed asks them once the PR is open and ready, each once, never its author."
        case .cleanup: "Every hour heed removes the worktrees idle past idle_days whose work is pushed, and says so."
        case .goals: "heed attaches what it is sure of and asks about the rest; your answers become its rules."
        case .summaries: "The summary of what came since you last looked is there when you open the thread."
        case .resume: "Once a resumed agent is idle, heed types continue_prompt into it."
        case .names: "heed renames a session after its first turn and when it opens a PR."
        }
    }

    /// How it goes, step by step.
    public var steps: [String] {
        switch self {
        case .green: [
                "A review comment or a failing check arrives on a PR your session tracks.",
                "On auto, heed sends what is open in one prompt per round to a helper: an agent in its own worktree, over ACP.",
                "The helper pushes and replies once its work is done (or once you approve, on ask); heed checks again.",
                "Still not green after max_rounds (3) rounds without a new approval: it stops, and the PR shows stalled.",
            ]
        case .merge: [
                "A PR with merge on joins its repo's merge queue.",
                "The queue runs every hour, when a PR turns green, and after a merge.",
                "auto turns on GitHub's auto-merge; heed merges itself once its rules hold.",
                "After a merge, the queue's PRs that fell behind are brought up to date.",
            ]
        case .copilot: [
                "A watched PR conflicts with its base, or gets new review comments.",
                "Where the Copilot coding agent is on for the repo, heed asks @copilot in one comment.",
                "What it asked shows as sent, so your agent does not get it too.",
                "Copilot pushes to the branch; heed checks again as after any push.",
            ]
        case .reviewers: [
                "A PR your session tracks is open and not a draft.",
                "heed asks each name in reviewers: logins, org/team, or copilot.",
                "Each is asked once per PR; zv asks again now.",
            ]
        case .cleanup: [
                "Every hour, with [cleanup] enabled, heed goes over every worktree on this Mac.",
                "One idle for idle_days (14), with its work committed and pushed, is removed.",
                "Its session moves to History, its branch goes too (delete_branch).",
                "ask_before_sweep: it waits for you instead (gC).",
            ]
        case .goals: [
                "A session starts, or opens a PR.",
                "heed weighs what it touches (repos, files, PRs, attach.rules), and asks the model with attach_model.",
                "Sure enough (attach_auto): it attaches. Less sure (attach_ask): it asks you.",
                "Your answers in Goals › Unassigned become lines in attach.rules.",
            ]
        case .summaries: [
                "After a sync, threads in For you's New with no summary up to date are queued, newest first.",
                "heed writes them a few at a time through [llm], keeping a slot for what you open.",
                "What the day's model calls do not cover waits for the next day, or for you to open it.",
            ]
        case .resume: [
                "heed starts again, or you resume a session whose agent was mid-turn, with resume then continue.",
                "Once its agent is idle, heed types continue_prompt into it, once.",
            ]
        case .names: [
                "A session's first turn ends, or it opens a PR.",
                "heed asks the Mac's on-device model, else a model call through [llm].",
                "The new title shows in the sidebar, marked as new until you see it.",
            ]
        }
    }

    /// What it never does: its real rails.
    public var never: [String] {
        switch self {
        case .green: [
                "types into your session's agent unless run_in = \"session\", and then not while it works or "
                    + "within 5 minutes of your typing in it",
                "pushes or replies before a helper is done, or on ask before you approve its close-out",
                "sends for a paused, merged or closed PR",
                "goes past max_rounds without a new approval (zr gives one more)",
                "runs two rounds for one PR at once",
            ]
        case .merge: [
                "merges a PR your sessions do not track",
                "merges a paused PR, or one that fails a green rule (it turns auto-merge off then)",
                "with heed: merges a head commit it did not check, or a PR with a hold label",
                "retries with --admin unless admin_merge is set for the repo",
            ]
        case .copilot: [
                "asks twice for the same conflict or comment",
                "asks where Copilot cannot work in the repo: the work goes to your agent",
                "hands it failing checks, or a branch that is merely behind",
                "asks for a paused PR, or with green off",
            ]
        case .reviewers: [
                "asks the PR's author",
                "asks anyone twice on one PR",
                "asks on a draft, a closed PR or a paused one",
            ]
        case .cleanup: [
                "removes main checkouts, worktrees on hosts, or a pinned session's",
                "removes uncommitted, unpushed or never-pushed work",
                "removes your worktrees while it is off (only what heed's own runs left behind, when safe)",
            ]
        case .goals: [
                "attaches what it is less sure of than attach_auto: it asks",
                "asks the model with attach_model off: signals only",
            ]
        case .summaries: [
                "goes past [llm] daily_calls or daily_dollars",
                "writes ahead with summaries = \"open\": only what you open",
            ]
        case .resume: [
                "types into an agent that is working",
                "sends anything with continue_prompt empty",
            ]
        case .names: [
                "renames a session you titled yourself",
                "renames one session more than 6 times",
            ]
        }
    }
}
