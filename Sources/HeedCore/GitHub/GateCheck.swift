import Foundation

/// One of `gate_checks`: a check by its name and the app that reports it. `github-actions:ci/test` names the app;
/// a bare `ci/test` takes the app that reports a check of that name on the base branch's latest commit, or
/// `github-actions` when none does there. A check of the same name from another app does not count.
public struct GateCheck: Hashable, Sendable {
    /// As written in the config.
    public let entry: String
    public let name: String
    /// The app named in the entry; nil for a bare name.
    public let app: String?

    /// `app:name` when what comes before the first `:` is an app's slug (lowercase letters, digits and `-`), else the
    /// whole entry is the name.
    public init(_ entry: String) {
        self.entry = entry
        if let colon = entry.firstIndex(of: ":") {
            let prefix = String(entry[..<colon])
            let rest = String(entry[entry.index(after: colon)...])
            let slug = !prefix.isEmpty && prefix.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" }
                && prefix.allSatisfy(\.isASCII)
            if slug, !rest.isEmpty {
                name = rest
                app = prefix
                return
            }
        }
        name = entry
        app = nil
    }

    /// The app a bare name falls back to when the base branch reports no check of that name.
    public static let defaultApp = "github-actions"

    /// The apps whose check of this name counts on `detail`.
    public func apps(on detail: PullDetail) -> Set<String> {
        if let app { return [Self.normalize(app)] }
        let base = Set((detail.baseChecks ?? []).filter { $0.name == name }.compactMap(\.app).map(Self.normalize))
        return base.isEmpty ? [Self.defaultApp] : base
    }

    /// A login or an app's slug as heed compares them: lowercase, without GitHub's `[bot]` suffix (GraphQL names a
    /// bot `dependabot`, REST `dependabot[bot]`).
    public static func normalize(_ login: String) -> String {
        let lower = login.lowercased()
        return lower.hasSuffix("[bot]") ? String(lower.dropLast(5)) : lower
    }

    public enum State: Hashable, Sendable {
        case passed(app: String)
        case failed
        case missing
    }

    /// How this gate stands on the head commit: passed by one of its apps, failed by one of them, or neither yet.
    public func state(on detail: PullDetail) -> State {
        let apps = apps(on: detail)
        let failed = detail.failingChecks.contains { check in
            check.name == name && check.summary.author.login.map { apps.contains(Self.normalize($0)) } == true
        }
        if failed { return .failed }
        let passed = (detail.passedRuns ?? []).first { run in
            run.name == name && run.app.map { apps.contains(Self.normalize($0)) } == true
        }
        if let app = passed?.app { return .passed(app: Self.normalize(app)) }
        return .missing
    }
}
