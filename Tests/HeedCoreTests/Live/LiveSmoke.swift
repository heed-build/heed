import Foundation
@testable import HeedCore
import Testing

/// The live smoke suite for Browse (`mise run live-browse`): the contract tests read real GitHub with the owner's `gh`,
/// the end-to-end test drives HeedCore's Browse pieces against one throwaway repository. This file is what both stand
/// on: the one slug anything is ever written to, the `gh` helpers that refuse every other, the world that seeds and
/// cleans that repository, and the report the run writes.
///
/// Safety, in the order it matters:
/// - Writes go to `LiveSmoke.slug` and nowhere else. `SmokeGH.write` throws for any argument that names another
///   repository, and for a write that names none. Reads may name any public repository.
/// - Models: haiku only (`LiveSmoke.model`), a spend and tool-call cap per run, a wall-clock cap for the whole run.
/// - Everything the run creates is closed or deleted when it ends, and the next run sweeps what a crash left.
/// - Nothing here touches the real data directory, the real worktree root or prints a token.
enum LiveSmoke {
    /// The only repository the suite writes to: private, owner-approved, a throwaway.
    static let slug = "Mpdreamz/heed-smoke"
    static let repo = Repo(org: "Mpdreamz", name: "heed-smoke")
    /// Marks every issue and pull request the suite makes, so a sweep finds what a crashed run left.
    static let label = "heed-live-smoke"
    /// Haiku, the only model any live check may use.
    static let model = "claude-haiku-4-5"

    /// Both the general switch and this one: `mise run live` (HEED_LIVE only) never reaches these suites.
    static var enabled: Bool {
        let environment = ProcessInfo.processInfo.environment
        return environment["HEED_LIVE"] == "1" && environment["HEED_LIVE_BROWSE"] == "1"
    }

    static let enabledNote: Comment = "live: HEED_LIVE=1 mise run live-browse calls a model and writes to Mpdreamz/heed-smoke"

    /// `heed-live-<hex>`: in every title and branch this run makes.
    static let runID = "heed-live-" + String(UUID().uuidString.prefix(6)).lowercased()
    static let startedAt = Date()

    /// The whole run's wall clock. A step that starts after it, or a run that is still going, fails.
    static let wallClockCap: TimeInterval = 40 * 60
    /// What one agent run may spend (the app's `[helpers] spend_cap` is the same idea) and how many tools it may call.
    static let spendCap = 0.60
    static let toolCallCap = 45
    static let runTimeout: TimeInterval = 8 * 60

    static func checkWallClock() throws {
        let used = Date().timeIntervalSince(startedAt)
        if used >
            wallClockCap
        { throw SmokeFailure("the run's wall-clock cap of \(Int(wallClockCap / 60)) minutes is spent")
        }
    }

    /// The temp folder everything local goes in: never the user's data directory or worktree root.
    static func scratch(_ name: String) throws -> URL { try Live.scratch(name) }
}

struct SmokeFailure: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// A write that named a repository other than `LiveSmoke.slug` (or none).
struct SmokeRefusal: Error, CustomStringConvertible {
    let description: String
}

// MARK: - gh

/// `gh` as the suite uses it. Reads go anywhere; writes only to the smoke repository.
enum SmokeGH {
    /// Every `owner/name` a `gh` argument list names: `repos/o/n/...` paths, `-R o/n`, `--repo o/n`, github.com URLs.
    static func slugs(in arguments: [String]) -> [String] {
        var found: [String] = []
        func add(_ owner: Substring, _ name: Substring) { found.append("\(owner)/\(name)") }
        let path = try? NSRegularExpression(pattern: #"(?:^|[^A-Za-z0-9])repos/([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)"#)
        let url = try? NSRegularExpression(pattern: #"github\.com[/:]([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)"#)
        let plain = try? NSRegularExpression(pattern: #"^([A-Za-z0-9._-]+)/([A-Za-z0-9._-]+)$"#)
        for (index, argument) in arguments.enumerated() {
            for expression in [path, url].compactMap({ $0 }) {
                let range = NSRange(argument.startIndex..., in: argument)
                for match in expression.matches(in: argument, range: range) {
                    if let owner = Range(match.range(at: 1), in: argument), let name = Range(
                        match.range(at: 2),
                        in: argument
                    ) {
                        add(argument[owner], argument[name])
                    }
                }
            }
            // The value of -R / --repo, and an owner/name given bare after them.
            let takesRepo = index > 0 && ["-R", "--repo"].contains(arguments[index - 1])
            if takesRepo || argument.hasPrefix("--repo=") {
                let value = argument.hasPrefix("--repo=") ? String(argument.dropFirst("--repo=".count)) : argument
                let range = NSRange(value.startIndex..., in: value)
                if let match = plain?.firstMatch(in: value, range: range),
                   let owner = Range(match.range(at: 1), in: value), let name = Range(match.range(at: 2), in: value)
                {
                    add(value[owner], value[name])
                } else {
                    found.append(value)
                }
            }
        }
        return found
    }

    /// Throws unless `arguments` name `LiveSmoke.slug` and nothing else.
    static func requireSmoke(_ arguments: [String]) throws {
        let named = slugs(in: arguments)
        guard !named.isEmpty else {
            throw SmokeRefusal(
                description: "refused: a write must name \(LiveSmoke.slug), this one names no repository: gh \(arguments.joined(separator: " "))"
            )
        }
        if let other = named.first(where: { $0.lowercased() != LiveSmoke.slug.lowercased() }) {
            throw SmokeRefusal(description: "refused: a write may only go to \(LiveSmoke.slug), not \(other)")
        }
    }

    /// Throws unless `repo` is the smoke repository.
    static func requireSmoke(_ repo: Repo) throws {
        guard repo.slug.lowercased() == LiveSmoke.slug.lowercased() else {
            throw SmokeRefusal(description: "refused: a write may only go to \(LiveSmoke.slug), not \(repo.slug)")
        }
    }

    static func executable() async throws -> String {
        if let found = await ToolLocator.shared.executable("gh").0 { return found }
        throw LiveError.missing("gh")
    }

    /// A read: any repository.
    @discardableResult
    static func read(_ arguments: [String], timeout: Duration = .seconds(60)) async throws -> String {
        let result = try await ProcessRunner.run(
            executable(), arguments, timeout: timeout, caller: "live.smoke.read"
        )
        guard result.succeeded else {
            throw SmokeFailure("gh \(arguments.prefix(4).joined(separator: " ")) failed: \(result.stderr.prefix(300))")
        }
        return result.stdout
    }

    static func readJSON(_ arguments: [String]) async throws -> Any {
        let text = try await read(arguments)
        return try JSONSerialization.jsonObject(with: Data(text.utf8), options: [.fragmentsAllowed])
    }

    /// A write: only to the smoke repository, checked before gh starts.
    @discardableResult
    static func write(_ arguments: [String], timeout: Duration = .seconds(60)) async throws -> String {
        try requireSmoke(arguments)
        let result = try await ProcessRunner.run(
            executable(), arguments, timeout: timeout, caller: "live.smoke.write"
        )
        guard result.succeeded else {
            throw SmokeFailure("gh \(arguments.prefix(4).joined(separator: " ")) failed: \(result.stderr.prefix(300))")
        }
        return result.stdout
    }

    /// `gh api -X DELETE repos/<smoke>/git/refs/heads/<branch>`: a branch of the smoke repository only.
    static func deleteBranch(_ branch: String) async throws {
        guard !branch.isEmpty,
              branch != "main" else { throw SmokeRefusal(description: "refused: never delete \(branch)") }
        let encoded = branch.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? branch
        try await write(["api", "-X", "DELETE", "repos/\(LiveSmoke.slug)/git/refs/heads/\(encoded)"])
    }

    /// The version line and the token's scopes (never the token), for the top of the report.
    static func environment() async -> (version: String, scopes: String) {
        let version = await ((try? read(["--version"])) ?? "?").split(separator: "\n").first.map(String.init) ?? "?"
        let status = await (try? ProcessRunner.run(
            executable(), ["auth", "status"], timeout: .seconds(20), caller: "live.smoke.read"
        ))
        let text = (status?.stdout ?? "") + (status?.stderr ?? "")
        let scopes = text.split(separator: "\n").first { $0.contains("Token scopes") }.map {
            $0.replacingOccurrences(of: "- Token scopes:", with: "").trimmingCharacters(in: .whitespaces)
        } ?? "unknown"
        return (version, scopes)
    }
}

// MARK: - The report

/// What a run did, step by step, written as markdown (`live-smoke-<date>.md`). Both suites record into the one
/// shared report; each rewrites the whole file when it ends, so the last one to finish has everything.
final class SmokeReport: @unchecked Sendable {
    static let shared = SmokeReport()

    enum Verdict: String { case pass = "PASS", fail = "FAIL", known = "KNOWN BUG", skipped = "SKIPPED" }

    struct Entry {
        var section: String
        var name: String
        var verdict: Verdict
        var seconds: Double
        var notes: [String]
        var failures: [String]
    }

    private let lock = NSLock()
    private var entries: [Entry] = []
    private var extras: [(title: String, lines: [String])] = []
    private var header: [String] = []

    func add(_ entry: Entry) { lock.withLock { entries.append(entry) } }
    func extra(_ title: String, _ lines: [String]) { lock.withLock { extras.append((title, lines)) } }
    func setHeader(_ lines: [String]) { lock.withLock { header = lines } }

    var path: String {
        if let custom = ProcessInfo.processInfo.environment["HEED_LIVE_REPORT"], !custom.isEmpty { return custom }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return "/Users/mpdreamz/Projects/heed-plans/browse/audit/live-smoke-\(formatter.string(from: Date())).md"
    }

    func write() {
        let (entries, extras, header) = lock.withLock { (self.entries, self.extras, self.header) }
        var out = ["# Browse live smoke run \(LiveSmoke.runID)", ""] + header + [""]
        out += ["## Steps", "", "| | section | step | seconds |", "|---|---|---|---|"]
        for entry in entries {
            out
                .append(
                    "| \(entry.verdict.rawValue) | \(entry.section) | \(entry.name) | \(String(format: "%.1f", entry.seconds)) |"
                )
        }
        out += ["", "## Details", ""]
        for entry in entries {
            out.append("### \(entry.verdict.rawValue): \(entry.section): \(entry.name)")
            for failure in entry.failures {
                out.append("- FAILED: \(failure)")
            }
            for note in entry.notes {
                out.append("- \(note)")
            }
            out.append("")
        }
        for extra in extras {
            out += ["## \(extra.title)", ""] + extra.lines + [""]
        }
        let text = out.joined(separator: "\n")
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true
        )
        try? text.write(toFile: path, atomically: true, encoding: .utf8)
        Live.keep("live-smoke-report.md", text)
    }
}

/// One step as a test body sees it: notes for the report, expectations that fail the step (and the test) with a clear
/// message, and a way to mark a real product bug so the suite stays runnable.
final class SmokeStep: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var notes: [String] = []
    private(set) var failures: [String] = []
    private(set) var known: [String] = []

    func note(_ text: String) { lock.withLock { notes.append(text) } }

    /// An expectation. A failure is recorded as a test issue at the caller's line and in the report.
    func expect(
        _ condition: Bool, _ message: @autoclosure () -> String,
        fileID: String = #fileID, filePath: String = #filePath, line: Int = #line, column: Int = #column
    ) {
        guard !condition else { return }
        let text = message()
        lock.withLock { failures.append(text) }
        Issue.record(Comment(rawValue: text), sourceLocation: SourceLocation(
            fileID: fileID, filePath: filePath, line: line, column: column
        ))
    }

    /// A product bug this step found. `reproduced` says whether it showed up now: when it did, the message is
    /// recorded as a known issue (the suite stays green, the report says KNOWN BUG); when it did not, the bug is fixed
    /// and the report says so. Every one of these is listed in the run's final report with its repro.
    func productBug(_ id: String, _ message: String, reproduced: Bool) {
        if reproduced {
            withKnownIssue("product bug \(id): \(message)") { Issue.record(Comment(rawValue: message)) }
            lock.withLock { known.append("\(id): \(message)") }
        } else {
            note("product bug \(id) did not reproduce (fixed?): \(message)")
        }
    }
}

enum Smoke {
    /// Runs one step: timed, recorded in the report, the wall-clock cap checked first, a thrown error recorded as a
    /// failure and not allowed to stop the steps after it.
    @discardableResult
    static func step(
        _ section: String, _ name: String, fileID: String = #fileID, filePath: String = #filePath,
        line: Int = #line, column: Int = #column,
        _ body: (SmokeStep) async throws -> Void
    ) async -> Bool {
        let step = SmokeStep()
        let started = Date()
        do {
            try LiveSmoke.checkWallClock()
            try await body(step)
        } catch {
            let text = "\(error)"
            step.expect(false, "threw: \(text)", fileID: fileID, filePath: filePath, line: line, column: column)
        }
        let verdict: SmokeReport.Verdict = !step.failures.isEmpty ? .fail : (step.known.isEmpty ? .pass : .known)
        SmokeReport.shared.add(.init(
            section: section, name: name, verdict: verdict, seconds: Date().timeIntervalSince(started),
            notes: step.notes + step.known.map { "KNOWN BUG " + $0 }, failures: step.failures
        ))
        return verdict != .fail
    }
}

// MARK: - The world on the smoke repository

/// What a run seeds on the smoke repository, and how it cleans up. Seeding is idempotent (the default branch gets its
/// files once); everything else is new per run, named with `LiveSmoke.runID` and labelled `heed-live-smoke`.
final class LiveSmokeWorld: @unchecked Sendable {
    struct Seeded {
        var bugIssue: Int
        var featureIssue: Int
        var pull: Int
        var pullBranch: String
        var pullHeadSHA: String
    }

    private let lock = NSLock()
    private var issues: [Int] = []
    private var pulls: [Int] = []
    private var branches: [String] = []

    var trackedIssues: [Int] { lock.withLock { issues } }
    var trackedPulls: [Int] { lock.withLock { pulls } }

    func track(issue: Int) { lock.withLock { if !issues.contains(issue) { issues.append(issue) } } }
    func track(pull: Int) { lock.withLock { if !pulls.contains(pull) { pulls.append(pull) } } }
    func track(branch: String) { lock.withLock { if !branches.contains(branch) { branches.append(branch) } } }

    static let calc = """
    def add(a, b):
        return a - b


    def mul(a, b):
        return a * b

    """

    static let calcTest = """
    from calc import add, mul

    assert add(2, 3) == 5, "add(2, 3) should be 5, got %r" % add(2, 3)
    assert mul(2, 3) == 6, "mul(2, 3) should be 6, got %r" % mul(2, 3)
    print("ok")

    """

    // MARK: Seeding

    /// The label, and the files on the default branch, once.
    func ensureBase() async throws {
        let labels = try await SmokeGH.read(["api", "repos/\(LiveSmoke.slug)/labels?per_page=100", "--jq", ".[].name"])
        if !labels.split(separator: "\n").contains(Substring(LiveSmoke.label)) {
            try await SmokeGH.write([
                "api", "-X", "POST", "repos/\(LiveSmoke.slug)/labels", "-f", "name=\(LiveSmoke.label)",
                "-f", "color=ededed", "-f", "description=made by heed's live smoke suite; safe to delete",
            ])
        }
        for (path, text) in [("calc.py", Self.calc), ("test_calc.py", Self.calcTest)] {
            let existing = try? await SmokeGH.read(["api", "repos/\(LiveSmoke.slug)/contents/\(path)", "--jq", ".sha"])
            guard existing == nil || existing?.isEmpty == true else { continue }
            try await SmokeGH.write([
                "api", "-X", "PUT", "repos/\(LiveSmoke.slug)/contents/\(path)",
                "-f", "message=Seed \(path) for heed's live smoke suite", "-f",
                "content=\(Data(text.utf8).base64EncodedString())",
                "-f", "branch=main",
            ])
        }
    }

    /// Two issues and one pull request, all by the signed-in owner, labelled.
    func seed(cloneInto folder: URL) async throws -> Seeded {
        let id = LiveSmoke.runID
        let bug = try await newIssue(
            title: "add(2, 3) returns -1 instead of 5 [\(id)]",
            body: "`calc.add` subtracts instead of adding.\n\nRepro: `python3 test_calc.py` fails with `add(2, 3) should be 5, got -1`.\n\nThe fix is one line in `calc.py`. (Made by heed's live smoke suite, run \(id).)",
            labels: [LiveSmoke.label, "bug"]
        )
        let feature = try await newIssue(
            title: "Add a sub(a, b) function to calc.py [\(id)]",
            body: "`calc.py` has `add` and `mul`. Please add `sub(a, b)` that returns `a - b`, and a check for it in `test_calc.py`. (Made by heed's live smoke suite, run \(id).)",
            labels: [LiveSmoke.label, "enhancement"]
        )
        let clone = folder.appendingPathComponent("seed").path
        _ = try await ProcessRunner.output(
            "git", ["clone", "-q", "git@github.com:\(LiveSmoke.slug).git", clone], timeout: .seconds(90),
            caller: "live.smoke.clone"
        )
        let branch = "\(id)-pr"
        for args in [["checkout", "-q", "-b", branch]] {
            _ = try await ProcessRunner.output("git", ["-C", clone] + args, caller: "live.smoke.clone")
        }
        var calc = try String(contentsOfFile: clone + "/calc.py", encoding: .utf8)
        calc += "\n\ndef div(a, b):\n    \"\"\"a divided by b; None when b is zero.\"\"\"\n    return None if b == 0 else a / b\n"
        try calc.write(toFile: clone + "/calc.py", atomically: true, encoding: .utf8)
        // Signed as every commit on this machine is: the global config does it.
        for args in [["add", "calc.py"], ["commit", "-q", "-m", "Add div [\(id)]"]] {
            _ = try await ProcessRunner.output("git", ["-C", clone] + args, caller: "live.smoke.clone")
        }
        track(branch: branch)
        // `git push` goes to this clone's origin, which is the smoke repository: check it before pushing.
        let origin = try await ProcessRunner.output(
            "git",
            ["-C", clone, "remote", "get-url", "origin"],
            caller: "live.smoke.clone"
        )
        guard origin.lowercased().contains(LiveSmoke.slug.lowercased()) else {
            throw SmokeRefusal(description: "refused: the clone's origin is \(origin), not \(LiveSmoke.slug)")
        }
        _ = try await ProcessRunner.output(
            "git", ["-C", clone, "push", "-q", "origin", branch], timeout: .seconds(90), caller: "live.smoke.push"
        )
        let sha = try await ProcessRunner.output("git", ["-C", clone, "rev-parse", "HEAD"], caller: "live.smoke.clone")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let created = try await SmokeGH.write([
            "pr", "create", "-R", LiveSmoke.slug, "--head", branch, "--base", "main",
            "--title", "Add div to calc.py [\(id)]", "--body", "A small change for the live smoke suite, run \(id).",
            "--label", LiveSmoke.label,
        ])
        guard let number = created.split(separator: "/").last
            .flatMap({ Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        else { throw SmokeFailure("could not read the new pull request's number from: \(created)") }
        track(pull: number)
        return Seeded(bugIssue: bug, featureIssue: feature, pull: number, pullBranch: branch, pullHeadSHA: sha)
    }

    private func newIssue(title: String, body: String, labels: [String]) async throws -> Int {
        var args = ["api", "-X", "POST", "repos/\(LiveSmoke.slug)/issues", "-f", "title=\(title)", "-f", "body=\(body)"]
        for label in labels {
            args += ["-f", "labels[]=\(label)"]
        }
        let text = try await SmokeGH.write(args)
        guard let json = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let number = json["number"] as? Int else { throw SmokeFailure("no issue number in: \(text.prefix(200))") }
        track(issue: number)
        return number
    }

    // MARK: Cleaning

    /// Closes and deletes what this run made, and what a run it spawned made (a Fix's pull request and branch).
    /// Returns what was left that could not be cleaned, for the report.
    @discardableResult
    func cleanUp() async -> [String] {
        var left: [String] = []
        // What a Fix run pushed: pull requests opened since this run began, whatever their label.
        if let found = try? await SmokeGH.readJSON([
            "api",
            "repos/\(LiveSmoke.slug)/pulls?state=open&per_page=100",
        ]) as? [[String: Any]] {
            for pull in found {
                guard let number = pull["number"] as? Int, let created = pull["created_at"] as? String,
                      GitHub.date(created) >= LiveSmoke.startedAt.addingTimeInterval(-5) else { continue }
                track(pull: number)
                if let ref = (pull["head"] as? [String: Any])?["ref"] as? String { track(branch: ref) }
            }
        }
        for number in trackedPulls {
            do {
                try await SmokeGH.write([
                    "api",
                    "-X",
                    "PATCH",
                    "repos/\(LiveSmoke.slug)/pulls/\(number)",
                    "-f",
                    "state=closed",
                ])
            } catch { left.append("pull #\(number) not closed: \(error)") }
        }
        for number in trackedIssues {
            do {
                try await SmokeGH.write([
                    "api",
                    "-X",
                    "PATCH",
                    "repos/\(LiveSmoke.slug)/issues/\(number)",
                    "-f",
                    "state=closed",
                    "-f",
                    "state_reason=not_planned",
                ])
            } catch { left.append("issue #\(number) not closed: \(error)") }
        }
        // Branches: the ones tracked, and any run branch an agent pushed that is ours by name.
        var names = Set(lock.withLock { branches })
        if let refs = try? await SmokeGH.read([
            "api",
            "repos/\(LiveSmoke.slug)/git/matching-refs/heads/\(LiveSmoke.runID)",
            "--jq",
            ".[].ref",
        ]) {
            for ref in refs.split(separator: "\n") {
                names.insert(String(ref).replacingOccurrences(
                    of: "refs/heads/",
                    with: ""
                ))
            }
        }
        for issue in trackedIssues {
            if let refs = try? await SmokeGH.read([
                "api",
                "repos/\(LiveSmoke.slug)/git/matching-refs/heads/heed/browse/issue-\(issue)-",
                "--jq",
                ".[].ref",
            ]) {
                for ref in refs.split(separator: "\n") {
                    names.insert(String(ref).replacingOccurrences(
                        of: "refs/heads/",
                        with: ""
                    ))
                }
            }
        }
        for name in names.sorted() where name != "main" {
            do { try await SmokeGH.deleteBranch(name) } catch {
                // 422 when it is already gone.
                if !"\(error)".contains("Reference does not exist"),
                   !"\(error)".contains("422") { left.append("branch \(name) not deleted: \(error)") }
            }
        }
        return left
    }

    /// The start of a run: sweeps what an earlier, crashed run left (labelled `heed-live-smoke`, or a run branch,
    /// older than an hour). Returns what it removed, for the report.
    @discardableResult
    static func sweepOld(olderThan seconds: TimeInterval = 3600) async -> [String] {
        var removed: [String] = []
        let cutoff = Date().addingTimeInterval(-seconds)
        let query = "repos/\(LiveSmoke.slug)/issues?state=open&labels=\(LiveSmoke.label)&per_page=100"
        if let items = try? await SmokeGH.readJSON(["api", query]) as? [[String: Any]] {
            for item in items {
                guard let number = item["number"] as? Int, let created = item["created_at"] as? String,
                      GitHub.date(created) < cutoff else { continue }
                let isPull = item["pull_request"] != nil
                let path = isPull ? "pulls" : "issues"
                if await (try? SmokeGH.write([
                    "api",
                    "-X",
                    "PATCH",
                    "repos/\(LiveSmoke.slug)/\(path)/\(number)",
                    "-f",
                    "state=closed",
                ])) != nil {
                    removed.append("closed \(path) #\(number)")
                }
            }
        }
        for prefix in ["heed-live-", "heed/browse/"] {
            guard let refs = try? await SmokeGH.read([
                "api",
                "repos/\(LiveSmoke.slug)/git/matching-refs/heads/\(prefix)",
                "--jq",
                ".[] | [.ref, .object.sha] | @tsv",
            ])
            else { continue }
            for line in refs.split(separator: "\n") {
                let parts = line.split(separator: "\t").map(String.init)
                guard parts.count == 2 else { continue }
                let branch = parts[0].replacingOccurrences(of: "refs/heads/", with: "")
                // A branch carries no date: its tip commit's does.
                let date = await (try? SmokeGH.read([
                    "api",
                    "repos/\(LiveSmoke.slug)/commits/\(parts[1])",
                    "--jq",
                    ".commit.committer.date",
                ]))?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard let date, GitHub.date(date) < cutoff else { continue }
                if await (try? SmokeGH.deleteBranch(branch)) != nil { removed.append("deleted branch \(branch)") }
            }
        }
        return removed
    }
}
