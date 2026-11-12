import Foundation
@testable import HeedCore
import Testing

/// Heed names sessions from what they do, at the right moments, and never over a title you gave.
struct SessionNamingTests {
    private func session(_ id: String = "s", title: String = "docs-builder, look at") -> Session {
        Session(
            id: id, title: title, prompt: "docs-builder, look at these commands", repos: [Repo(org: "o", name: "r")],
            branch: "feature/x", agent: "claude", state: ObservedState(.working)
        )
    }

    @Test func theFirstTurnAndANewPRAreTheMoments() {
        let before = session()
        var turned = before
        turned.lastMessage = "Added the release command."
        #expect(SessionNaming.moments(before: [before], after: [turned]).map(\.moment) == [.firstTurn])
        // A later message is no moment; a PR it opens is.
        var later = turned
        later.lastMessage = "Fixed the test."
        #expect(SessionNaming.moments(before: [turned], after: [later]).isEmpty)
        var opened = later
        opened.trackedPRs = [PullRef(repo: Repo(org: "o", name: "r"), number: 7)]
        #expect(SessionNaming.moments(before: [later], after: [opened]).map(\.moment) == [.pullOpened])
        // A session that just appeared has nothing to compare with.
        #expect(SessionNaming.moments(before: [], after: [opened]).isEmpty)
    }

    @Test func yourTitleAndASettledOneAreLeftAlone() {
        var mine = session()
        mine.lastMessage = nil
        var after = mine
        after.lastMessage = "done"
        after.titleBy = .you
        #expect(SessionNaming.moments(before: [mine], after: [after]).isEmpty)
        var settled = session()
        settled.namings = SessionNaming.perSession
        #expect(!SessionNaming.mayName(settled))
    }

    @Test func aReplyIsReadAsATitleAndAKind() {
        #expect(SessionNaming.parse("title: Release commands for serverless\nkind: feat")
            == SessionNaming.Answer(title: "Release commands for serverless", kind: .feat))
        #expect(SessionNaming.parse("Kind: FIX\nTitle: \"redirect check skips moved pages.\"")
            == SessionNaming.Answer(title: "Redirect check skips moved pages", kind: .fix))
        #expect(SessionNaming.parse("Retry on 429 with backoff") == SessionNaming
            .Answer(title: "Retry on 429 with backoff"))
        #expect(SessionNaming.parse("title: \nkind: fix") == nil)
        #expect(SessionNaming.parse("title: x\nkind: quest")?.kind == nil)
    }

    @Test func aLongTitleIsCutAtAWord() throws {
        let long = String(repeating: "word ", count: 30)
        let clean = try #require(SessionNaming.clean(long))
        #expect(clean.count <= SessionNaming.maxLength)
        #expect(!clean.hasSuffix(" "))
        #expect(clean.hasPrefix("Word"))
    }

    @Test func heedsNameIsRecordedAndShownAsNew() {
        var named = session()
        #expect(SessionNaming.apply(SessionNaming.Answer(title: "Release commands", kind: .feat), to: &named))
        #expect(named.title == "Release commands")
        #expect(named.titleBy == .heed)
        #expect(!named.titleSeen)
        #expect(named.namings == 1)
        #expect(named.kind == .feat)
        #expect(named.timeline.last?.text == "renamed: docs-builder, look at → Release commands")
        // The same name again changes nothing.
        #expect(!SessionNaming.apply(SessionNaming.Answer(title: "Release commands"), to: &named))
        #expect(named.namings == 1)
    }

    @Test func aKindAlreadyChosenStays() {
        var chosen = session()
        chosen.kind = .fix
        SessionNaming.apply(SessionNaming.Answer(title: "Something", kind: .feat), to: &chosen)
        #expect(chosen.kind == .fix)
    }

    @Test func yourRenameSticksAndAnEmptyOneGivesItBack() {
        var renamed = session()
        SessionNaming.rename(&renamed, to: "my own name")
        #expect(renamed.title == "My own name")
        #expect(renamed.titleBy == .you)
        #expect(!SessionNaming.apply(SessionNaming.Answer(title: "Heed's idea"), to: &renamed))
        #expect(renamed.title == "My own name")
        renamed.namings = SessionNaming.perSession
        SessionNaming.rename(&renamed, to: "  ")
        #expect(renamed.titleBy == .prompt)
        #expect(SessionNaming.mayName(renamed))
        #expect(renamed.title == "My own name")
    }

    @Test func theQuestionCarriesTheOtherTitlesButNotItsOwn() {
        let mine = session("a", title: "Mine")
        let question = SessionNaming.Question.of(
            mine,
            pullTitles: ["Add release"],
            others: [mine, session("b", title: "Theirs")]
        )
        #expect(question.others == ["Theirs"])
        #expect(question.inputs.known == ["Theirs"])
        #expect(question.inputs.pullRequest == "PR: Add release")
    }

    @Test func namingFieldsSurviveTheStoreAndOldSessionsReadAsThePrompts() throws {
        var named = session()
        SessionNaming.apply(SessionNaming.Answer(title: "Release commands"), to: &named)
        let read = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(named))
        #expect(read.titleBy == .heed)
        #expect(!read.titleSeen)
        #expect(read.namings == 1)
        let old = try JSONDecoder().decode(Session.self, from: JSONEncoder().encode(session()))
        #expect(old.titleBy == .prompt)
        #expect(old.titleSeen)
        #expect(old.namings == 0)
    }
}
