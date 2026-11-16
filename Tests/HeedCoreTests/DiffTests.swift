import Foundation
@testable import HeedCore
import Testing

struct DiffParserTests {
    private let sample = """
    diff --git a/src/RedirectFile.cs b/src/RedirectFile.cs
    index 1111111..2222222 100644
    --- a/src/RedirectFile.cs
    +++ b/src/RedirectFile.cs
    @@ -76,6 +76,7 @@ public sealed class RedirectFile
         public bool TryResolve(string page, string fragment)
         {
    -        if (!anchors.Contains(fragment))
    +        if (!anchors.Contains(slug, StringComparer.Ordinal))
    +        var slug = Slugify(fragment);
                 return false;
         }
    diff --git a/tests/AnchorTests.cs b/tests/AnchorTests.cs
    new file mode 100644
    index 0000000..3333333
    --- /dev/null
    +++ b/tests/AnchorTests.cs
    @@ -0,0 +1,2 @@
    +public class AnchorTests
    +{
    diff --git a/logo.png b/logo.png
    Binary files a/logo.png and b/logo.png differ

    """

    @Test func parsesFilesHunksAndNumbers() throws {
        let files = DiffParser.parse(sample, staged: ["tests/AnchorTests.cs"])
        #expect(files.map(\.path) == ["src/RedirectFile.cs", "tests/AnchorTests.cs", "logo.png"])
        #expect(files.map(\.status) == [.modified, .added, .modified])
        #expect(files[0].additions == 2)
        #expect(files[0].deletions == 1)
        #expect(files[1].staged)
        #expect(files[2].binary)
        let lines = try #require(files.first?.hunks.first?.lines)
        #expect(lines[0].oldNumber == 76 && lines[0].newNumber == 76)
        #expect(lines[2].kind == .deleted && lines[2].oldNumber == 78)
        #expect(lines[3].kind == .added && lines[3].newNumber == 78)
        #expect(lines[5].oldNumber == 79 && lines[5].newNumber == 80)
    }

    @Test func pairedLinesGetWordHighlights() throws {
        let lines = try #require(DiffParser.parse(sample).first?.hunks.first?.lines)
        let old = Array(lines[2].text)
        let new = Array(lines[3].text)
        let oldRange = try #require(lines[2].changed)
        let newRange = try #require(lines[3].changed)
        #expect(String(old[oldRange]) == "fragment")
        #expect(String(new[newRange]) == "slug, StringComparer.Ordinal")
        #expect(lines[4].changed == nil)
    }

    @Test func rewritesAreNotWordHighlighted() {
        let (old, new) = DiffParser.changedRanges("completely different", "nothing alike here")
        #expect(old == nil && new == nil)
    }

    @Test func splitRowsPairDeletionsWithAdditions() throws {
        let hunk = try #require(DiffParser.parse(sample).first?.hunks.first)
        let rows = DiffParser.splitRows(hunk)
        #expect(rows.count == 6)
        #expect(rows[2].left?.kind == .deleted && rows[2].right?.kind == .added)
        #expect(rows[3].left == nil && rows[3].right?.kind == .added)
    }

    @Test func gitDiffScopes() async throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("heed-diff-\(UUID().uuidString)").path
        defer { try? FileManager.default.removeItem(atPath: path) }
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@t"], ["config", "user.name", "t"]] {
            _ = try await ProcessRunner.output("git", ["-C", path] + args, caller: "test")
        }
        try "one\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.output("git", ["-C", path, "add", "."], caller: "test")
        _ = try await ProcessRunner.output("git", ["-C", path, "commit", "-qm", "base"], caller: "test")
        _ = try await ProcessRunner.output("git", ["-C", path, "checkout", "-qb", "feature"], caller: "test")
        try "one\ntwo\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)
        _ = try await ProcessRunner.output("git", ["-C", path, "commit", "-qam", "add two"], caller: "test")
        try "one\ntwo\nthree\n".write(toFile: path + "/a.txt", atomically: true, encoding: .utf8)

        let committed = try await Git.diff(at: path, scope: .committed, base: "main", repo: nil)
        #expect(committed.first?.additions == 1)
        let all = try await Git.diff(at: path, scope: .all, base: "main", repo: nil)
        #expect(all.first?.additions == 2)
        let unstaged = try await Git.diff(at: path, scope: .unstaged, base: "main", repo: nil)
        #expect(unstaged.first?.additions == 1)
        let commits = try await Git.commits(at: path, base: "main")
        #expect(commits.map(\.subject) == ["add two"])
        let one = try await Git.diff(at: path, scope: .commit(commits[0].sha), base: "main", repo: nil)
        #expect(one.first?.hunks.first?.lines.contains { $0.text == "two" } == true)
    }
}
