import HeedCore
import SwiftUI

/// `HEED_TUTOR_CHECK=1`: plays every tutor lesson with the real keys on its fake world, as someone taking it would,
/// and reports each step that does not tick off, and each whose spotlight target never shows. Run with
/// `mise run tutor-check`; a lesson that cannot be finished is the worst bug the tutor can have.
@MainActor
enum TutorCheck {
    static var requested: Bool { ProcessInfo.processInfo.environment["HEED_TUTOR_CHECK"] != nil }

    /// The keys for each step, in vim notation, as a person would press them.
    static let scripts: [String: [String]] = [
        "tour": [
            "i<S-Esc>", "jk2j", "'2", "ga", "o" + Shots.typed("Fix the anchors in docs") + "<D-CR>", "<C-w>v",
            "gwgmgs", "/<Esc>:<Esc>", "?",
        ],
        "sessions": ["}}}}", "m'1", "<C-w>v", "/mer<CR>"],
        "start-work": [
            "o" + Shots.typed("Fix the broken anchors"), Shots.typed(" in the docs"), "<C-n>", "<D-CR>",
            "<S-Esc>gc" + Shots.typed("What is a cron line") + "<D-CR>", ":promote<CR><D-CR>",
        ],
        "attention": ["ttttttt", "tx", "Z"],
        "inbox": ["<CR><Esc>", "<Space>j<Space>", "x"],
        "issues": ["/a<CR>", "s", "<Esc><Esc><CR>"],
        "prs": ["<CR>", "<Space>", "s", "<Esc>"],
        "watch": ["gw", "j", "z?<Esc>", "zp", "vjzp", "zm", "gM", "<Esc>zw"],
        "repos": ["G", "o<Esc><Esc>", "ddn", "gCn", "M<CR><CR><Esc>"],
        "history": ["j", "t", "TT", "LL", "DD", "R"],
        "log": ["t", "tt", "ttx"],
        "goals": ["gG", "<CR><CR>", "'g", "E", "<Tab>jy", "B", "L", ":goal.new Faster search<CR>"],
        "hosts": [
            "gH<Esc>",
            "@dev<CR>gg",
            "o" + Shots.typed("Fix the flaky link checker in docs-toolkit"),
            "<D-CR>",
        ],
        "agents": ["ga", "i<S-Esc>", "jjzz"],
        "diff": ["gd", "n", "a"],
    ]

    static func run() async -> Int32 {
        ShotMode.active = true
        Clock.fixed = ShotRunner.instant
        var failures = 0
        for lesson in [Tutor.tour] + Tutor.viewLessons {
            let model = AppModel(domain: lesson.world.domain, isFixture: true)
            model.beginTutor(lesson: lesson.id, step: 0)
            let script = scripts[lesson.id] ?? []
            for (index, step) in lesson.steps.enumerated() {
                var targetSeen = step.target == nil
                if let target = step.target.flatMap(ShotRegion.init(rawValue:)) {
                    targetSeen = regions(model).contains(target)
                }
                for stroke in (try? KeyNotation.parse(index < script.count ? script[index] : "")) ?? [] {
                    _ = model.handle(stroke)
                    try? await Task.sleep(for: .milliseconds(20))
                    if !targetSeen, let target = step.target.flatMap(ShotRegion.init(rawValue:)) {
                        targetSeen = regions(model).contains(target)
                    }
                }
                guard let tutor = model.tutor, tutor.step > index else {
                    print(
                        "tutor-check \(lesson.id) step \(index + 1) “\(step.title)”: did not tick off"
                            + (model.flash.map { " (status: \($0))" } ?? "")
                    )
                    failures += 1
                    break
                }
                if !targetSeen {
                    print(
                        "tutor-check \(lesson.id) step \(index + 1) “\(step.title)”: target \(step.target ?? "") never on screen"
                    )
                    failures += 1
                }
            }
            if model.tutor?.finished == true { print("tutor-check \(lesson.id): finished") }
        }
        print("tutor-check: \(failures) problem\(failures == 1 ? "" : "s")")
        return failures == 0 ? 0 : 1
    }

    /// The regions the window shows right now, from an offscreen render.
    private static func regions(_ model: AppModel) -> Set<ShotRegion> {
        let frames = ShotFrames()
        let view = ShotFrame(highlight: [], frames: frames) { MainWindow() }
            .frame(width: 1440, height: 900)
            .environment(model)
            .environment(\.colorScheme, .dark)
        let renderer = ImageRenderer(content: view)
        renderer.proposedSize = ProposedViewSize(width: 1440, height: 900)
        _ = renderer.cgImage
        return Set(frames.rects.keys)
    }
}
