import Foundation

/// Work on no goal that hangs together: sessions in one repo (or chats with none) whose titles and prompts share
/// words, within a few days of each other. Unassigned offers each as a new goal.
public struct GoalSuggestion: Hashable, Sendable, Identifiable {
    public var subjects: [AttachSubject]
    /// `org/name`, or nil for chats and work outside a repo.
    public var repo: String?
    /// The words they share, most shared first.
    public var terms: [String]
    /// A title for the goal, from the words.
    public var title: String
    public var first: Date
    public var last: Date

    public init(subjects: [AttachSubject], repo: String?, terms: [String], title: String, first: Date, last: Date) {
        self.subjects = subjects
        self.repo = repo
        self.terms = terms
        self.title = title
        self.first = first
        self.last = last
    }

    /// Stable while its members are: their keys.
    public var id: String { subjects.map(\.key).sorted().joined(separator: ",") }

    /// `acme/docs-toolkit · 3 days`.
    public var place: String {
        let days = max(1, Int((last.timeIntervalSince(first) / 86400).rounded(.up)))
        return [repo ?? "no repo", days == 1 ? "1 day" : "\(days) days"].joined(separator: " · ")
    }

    /// What the Summarizer drafts the goal's `GOAL.md` from: the members' titles and first prompts.
    public var draftInputs: SummaryInputs {
        SummaryInputs(
            title: title, repo: repo,
            timeline: subjects.sorted { $0.at < $1.at }.map { subject in
                let prompt = subject.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
                return "\(subject.kind.rawValue) \(subject.title)" + (prompt.isEmpty ? "" : ": \(prompt.prefix(400))")
            }
        )
    }

    /// The draft when the model is off or failed: the title, a statement from the shared words, and the members as
    /// open questions to sharpen it with.
    public var fallbackDraft: String {
        var doc = GoalDoc.new(
            title: title, statement: "Work that keeps coming back to " + terms.prefix(3).joined(separator: ", ") + "."
        )
        doc.openQuestions = subjects.sorted { $0.at < $1.at }.map { "What did \($0.title) settle?" }
        return doc.render()
    }
}

public enum Clusters {
    /// Fewest things a suggestion holds.
    public static let minimum = 3
    /// Things further apart than this are not one piece of work.
    public static let window: TimeInterval = 7 * 86400
    /// Words two things must share to belong together.
    public static let sharedTerms = 2

    /// Suggested goals from things on no goal: grouped by repo, then linked when two share `sharedTerms` words and are
    /// within `window`; groups of `minimum` or more, the biggest and newest first.
    public static func suggest(_ subjects: [AttachSubject], minimum: Int = minimum) -> [GoalSuggestion] {
        let byRepo = Dictionary(grouping: subjects) { $0.repos.first }
        var found: [GoalSuggestion] = []
        for repo in byRepo.keys.sorted(by: { ($0 ?? "") < ($1 ?? "") }) {
            let members = byRepo[repo]!.sorted { $0.at != $1.at ? $0.at < $1.at : $0.id < $1.id }
            let terms = members.map { Set(TermIndex.terms($0.title + "\n" + $0.prompt)) }
            // Single linkage over "shares enough words and is close in time", as connected components.
            var group = Array(members.indices)
            func root(_ index: Int) -> Int {
                var index = index
                while group[index] != index {
                    index = group[index]
                }
                return index
            }
            for left in members.indices {
                for right in members.indices where right > left {
                    guard abs(members[left].at.timeIntervalSince(members[right].at)) <= window,
                          terms[left].intersection(terms[right]).count >= sharedTerms else { continue }
                    group[root(right)] = root(left)
                }
            }
            let components = Dictionary(grouping: members.indices, by: root)
            for indices in components.values where indices.count >= minimum {
                let subjects = indices.map { members[$0] }
                var counts: [String: Int] = [:]
                for index in indices {
                    for term in terms[index] {
                        counts[term, default: 0] += 1
                    }
                }
                let shared = counts.filter { $0.value >= 2 }.sorted {
                    $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key
                }.map(\.key)
                found.append(GoalSuggestion(
                    subjects: subjects, repo: repo, terms: shared, title: title(shared),
                    first: subjects.map(\.at).min()!, last: subjects.map(\.at).max()!
                ))
            }
        }
        return found.sorted {
            $0.subjects.count != $1.subjects.count ? $0.subjects.count > $1.subjects.count
                : $0.last != $1.last ? $0.last > $1.last : $0.id < $1.id
        }
    }

    /// `Table column widths`: the two or three most shared words.
    static func title(_ terms: [String]) -> String {
        let words = terms.prefix(3)
        guard let first = words.first else { return "New goal" }
        return ([first.prefix(1).uppercased() + first.dropFirst()] + words.dropFirst()).joined(separator: " ")
    }
}
