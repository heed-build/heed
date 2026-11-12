import Foundation
import HeedCore

/// Start work's attachments (big pastes, written beside the session) and its links (the PRs and issues the prompt
/// names, whose titles heed fetches for the chips and the branch name).
extension AppModel {
    /// `Application Support/Heed/sessions`: one folder per session for what it was started with.
    static var sessionFilesRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Heed").appendingPathComponent("sessions")
    }

    /// The plan with its attachments written out and the agent told where they are. Work on a host gets their text
    /// in the prompt instead (the files would be on this Mac), and so does any attachment that could not be written.
    func withAttachments(_ plan: StartWorkPlan) async -> StartWorkPlan {
        guard !plan.attachments.isEmpty else { return plan }
        var plan = plan
        let folder = Self.sessionFilesRoot.appendingPathComponent(plan.sessionID)
        let local = plan.location.hostName == nil
        let attachments = plan.attachments
        let written: [(PromptAttachment, path: String?)] = await Task.detached {
            attachments.map { attachment in
                guard local else { return (attachment, nil) }
                let url = folder.appendingPathComponent(attachment.fileName)
                do {
                    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                    try attachment.text.write(to: url, atomically: true, encoding: .utf8)
                    return (attachment, url.path)
                } catch {
                    return (attachment, nil)
                }
            }
        }.value
        plan.prompt = PromptAttachments.prompt(plan.prompt, attachments: written)
        return plan
    }

    /// The session's own folder goes with it.
    func removeSessionFiles(_ id: String) {
        let folder = Self.sessionFilesRoot.appendingPathComponent(id)
        Task.detached { try? FileManager.default.removeItem(at: folder) }
    }

    /// Titles for the prompt's links that heed does not have yet: from the PRs it knows, else one fetch each kind.
    func lookUpStartWorkLinks() {
        guard let form = startWork, !isFixture else { return }
        var titles = form.linkTitles
        var pulls: [PullRef] = []
        var issues: [IssueRef] = []
        for link in form.links where titles[link.url] == nil {
            switch link.ref {
            case let .pull(ref):
                if let known = github.pulls.first(where: { $0.ref == ref })?.title ?? pullDetails[ref.description]?
                    .title
                {
                    titles[link.url] = known
                } else {
                    pulls.append(ref)
                }
            case let .issue(ref):
                if let known = issueInfo[ref]?.title { titles[link.url] = known } else { issues.append(ref) }
            }
        }
        if titles != form.linkTitles { startWork?.setLinkTitles(titles) }
        let wanted = Set(pulls.map(\.description) + issues.map { "\($0.repo.slug)#\($0.number)" })
        let fresh = wanted.subtracting(linkLookups)
        guard !fresh.isEmpty else { return }
        linkLookups.formUnion(fresh)
        Task { [weak self] in
            var fetched: [String: String] = [:]
            for ref in pulls where fresh.contains(ref.description) {
                if let detail = try? await GitHub
                    .pullDetail(ref, caller: "work.start") { fetched[ref.url] = detail.title }
            }
            let asked = issues.filter { fresh.contains("\($0.repo.slug)#\($0.number)") }
            if let infos = try? await GitHub.issueInfo(asked, caller: "work.start") {
                for (ref, info) in infos {
                    fetched["https://github.com/\(ref.repo.slug)/issues/\(ref.number)"] = info.title
                }
            }
            guard let self, var form = startWork else { return }
            // A link pasted as a URL with a trailing path still matches its title.
            var titles = form.linkTitles
            for link in form.links {
                if let title = fetched[link.url] ?? fetched.first(where: { link.url.hasPrefix($0.key) })?.value {
                    titles[link.url] = title
                }
            }
            form.setLinkTitles(titles)
            startWork = form
        }
    }
}
