@testable import HeedCore
import Testing

struct BrowseNumberTests {
    @Test func countsAreCompactWithAPointAndRoundedDown() {
        let cases: [(Int, String)] = [
            (0, "0"), (842, "842"), (999, "999"), (1000, "1K"), (1234, "1.2K"), (1999, "1.9K"), (9999, "9.9K"),
            (10000, "10K"), (579_689, "579K"), (999_999, "999K"), (1_000_000, "1M"), (1_250_000, "1.2M"),
            (143_037_165, "143M"), (2_490_000_000, "2.4B"), (-1234, "-1.2K"),
        ]
        for (value, text) in cases {
            #expect(BrowseNumber.compact(value) == text, "\(value)")
        }
    }

    @Test func theExactNumberHasThousandsSeparators() {
        #expect(BrowseNumber.exact(579_689) == "579,689")
        #expect(BrowseNumber.exact(12) == "12")
        #expect(BrowseNumber.exact(1000) == "1,000")
        #expect(BrowseNumber.exact(-1_234_567) == "-1,234,567")
    }
}

struct BrowseRailScopesTests {
    private func checkouts(_ spec: [String: Int]) -> BrowseCheckouts {
        BrowseCheckouts(records: spec.flatMap { org, count in
            (1 ... count).map { RepoRecord(repo: Repo(org: org, name: "r\($0)"), path: "/x/\(org)\($0)") }
        })
    }

    @Test func checkedOutOrgsSeedTheRailMostReposFirstWithTheCapAndAMoreCount() {
        let spec = Dictionary(uniqueKeysWithValues: (1 ... 9).map { ("org\($0)", $0) })
        let result = BrowseRailScopes.rows(pinned: [], checkouts: checkouts(spec))
        #expect(result.rows.map(\.scope.title) == ["org9", "org8", "org7", "org6", "org5", "org4"])
        #expect(result.rows.first?.checkedOut == 9)
        #expect(result.more == 3)
        #expect(BrowseRailScopes.rows(pinned: [], checkouts: checkouts(["a": 1, "b": 2]), cap: 2).more == 0)
        #expect(BrowseRailScopes.rows(pinned: [], checkouts: BrowseCheckouts(records: [])).rows.isEmpty)
    }

    @Test func pinnedScopesAlwaysShowAndAnOrgWithNoCheckoutStaysWithNoCount() {
        let pinned: [BrowseScope] = [.org("initech"), .project(owner: "acme", number: 2, title: "Board")]
        let result = BrowseRailScopes.rows(pinned: pinned, checkouts: checkouts(["acme": 2]))
        #expect(result.rows.map(\.scope.id) == ["org:initech", "org:acme", "project:acme/2"])
        #expect(result.rows[0].checkedOut == nil && result.rows[1].checkedOut == 2)
    }

    @Test func anOrgShowsItsCheckedOutReposWhenPinnedOrCurrent() {
        let all = checkouts(["acme": 2, "globex": 1])
        let plain = BrowseRailScopes.rows(pinned: [], checkouts: all)
        #expect(plain.rows.allSatisfy { !$0.indent })
        let current = BrowseRailScopes.rows(pinned: [], checkouts: all, current: .org("globex"))
        #expect(current.rows.map(\.scope.id) == ["org:acme", "org:globex", "repo:globex/r1"])
        #expect(current.rows.last?.indent == true)
        let pinned = BrowseRailScopes.rows(pinned: [.repo(Repo(org: "acme", name: "r2"))], checkouts: all)
        #expect(pinned.rows.map(\.scope.id) == ["org:acme", "repo:acme/r2", "repo:acme/r1", "org:globex"])
    }

    @Test func reposWithNothingOpenAreLeftOutExceptTheCurrentOneAndThoseNotCountedYet() {
        let a = Repo(org: "acme", name: "a"), b = Repo(org: "acme", name: "b")
        let c = Repo(org: "acme", name: "c"), d = Repo(org: "acme", name: "d")
        let rows = [BrowseRailScopes.Row(scope: .org("acme"), indent: false, checkedOut: 4)] + [a, b, c, d].map {
            BrowseRailScopes.Row(scope: .repo($0), indent: true, checkedOut: nil)
        }
        let counts: [BrowseScope: Int] = [.org("acme"): 0, .repo(a): 5, .repo(b): 0, .repo(c): 0]
        let result = BrowseRailScopes.hidingEmpty(rows, count: { counts[$0] }, keeping: .repo(c))
        // The org row stays whatever its count; b is hidden; c is where you are; d has no count yet.
        #expect(result.rows.map(\.scope.title) == ["acme", "a", "c", "d"])
        #expect(result.hidden == 1)
    }
}

struct BrowsePaletteCheckoutTests {
    private let orgs = [
        BrowsePalette.Org(name: "acme"), BrowsePalette.Org(name: "initech", checkedOut: false),
        BrowsePalette.Org(name: "initrode"),
    ]

    @Test func anOrgWithNoCheckoutShowsOnlyOnceTypedTextMatchesIt() {
        var palette = BrowsePalette(orgs: orgs, listings: [])
        #expect(palette.rows == [.org(orgs[0]), .org(orgs[2])])
        for character in "init" {
            _ = palette.handle(KeyStroke(String(character)))
        }
        // The checked-out one first, the dimmed one after.
        #expect(palette.rows == [.org(orgs[2]), .org(orgs[1])])
    }

    @Test func pickingAnOrgWithNoCheckoutNeverOffersAnOrgView() {
        var palette = BrowsePalette(orgs: orgs, listings: [])
        for character in "initech" {
            _ = palette.handle(KeyStroke(String(character)))
        }
        palette.setRepoCount(5000, of: "initech")
        #expect(palette.guidance == nil)
        #expect(palette.handle(KeyStroke("CR")) == .choose(.org("initech")))
    }
}
