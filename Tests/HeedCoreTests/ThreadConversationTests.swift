import Foundation
@testable import HeedCore
import Testing

struct ThreadConversationParsingTests {
    let repo = Repo(org: "acme", name: "docs-toolkit")

    @Test func pullWithCommentsAndReviews() throws {
        let json = """
        {"data":{"rateLimit":{"cost":1,"remaining":4999},"repository":{"issueOrPullRequest":{
          "__typename":"PullRequest","number":2845,"title":"Add link validation","url":"https://github.com/acme/docs-toolkit/pull/2845",
          "state":"OPEN","isDraft":true,"createdAt":"2026-10-10T08:00:00Z",
          "bodyHTML":"<p>Validates <code>links</code></p>",
          "author":{"__typename":"User","login":"reviewer","avatarUrl":"https://avatars.githubusercontent.com/u/1?v=4"},
          "labels":{"nodes":[{"name":"feature"}]},
          "reactionGroups":[{"content":"THUMBS_UP","reactors":{"totalCount":3}},{"content":"EYES","reactors":{"totalCount":0}}],
          "comments":{"totalCount":250,"pageInfo":{"hasPreviousPage":true,"startCursor":"Y3Vyc29y"},"nodes":[
            {"id":"IC_2","url":"https://github.com/acme/docs-toolkit/pull/2845#issuecomment-2","createdAt":"2026-10-12T10:00:00Z",
             "bodyHTML":"<p>second</p>","isMinimized":false,"minimizedReason":null,
             "author":{"__typename":"Bot","login":"docs-bot","avatarUrl":"https://avatars.githubusercontent.com/in/2"},
             "reactionGroups":[]},
            {"id":"IC_1","url":null,"createdAt":"2026-10-11T10:00:00Z","bodyHTML":"<p>spam</p>","isMinimized":true,
             "minimizedReason":"OFF_TOPIC","author":null,"reactionGroups":[{"content":"HOORAY","reactors":{"totalCount":2}}]}
          ]},
          "reviews":{"nodes":[
            {"id":"R_1","url":"u","state":"APPROVED","submittedAt":"2026-10-11T12:00:00Z","bodyHTML":"","author":{"login":"you"},"reactionGroups":[]},
            {"id":"R_2","url":"u","state":"COMMENTED","submittedAt":"2026-10-11T13:00:00Z","bodyHTML":"","author":{"login":"you"},"reactionGroups":[]},
            {"id":"R_3","url":"u","state":"PENDING","submittedAt":null,"bodyHTML":"<p>draft</p>","author":{"login":"you"},"reactionGroups":[]},
            {"id":"R_4","url":"u","state":"COMMENTED","submittedAt":"2026-10-11T14:00:00Z","bodyHTML":"<p>nit</p>","author":{"login":"you"},"reactionGroups":[]}
          ]}
        }}}}
        """
        let page = try #require(GitHub.parseConversation(Data(json.utf8), repo: repo, number: 2845, now: Date()))
        let conversation = page.conversation
        #expect(page.before == "Y3Vyc29y")
        #expect(conversation.kind == .pr)
        #expect(conversation.stateText == "draft")
        #expect(conversation.bodyHTML == "<p>Validates <code>links</code></p>")
        #expect(conversation.author == ThreadAuthor(
            login: "reviewer", avatarURL: "https://avatars.githubusercontent.com/u/1?v=4"
        ))
        #expect(conversation.labels == ["feature"])
        // Reactions nobody gave are left out.
        #expect(conversation.reactions == [ThreadReaction(content: "THUMBS_UP", count: 3)])
        // Oldest first; reviews join when they approve or say something, never a pending draft or an empty comment.
        #expect(conversation.comments.map(\.id) == ["IC_1", "R_1", "R_4", "IC_2"])
        #expect(conversation.comments[0].minimizedReason == "off topic")
        #expect(conversation.comments[0].author == nil)
        #expect(conversation.comments[1].verb == "approved")
        #expect(conversation.comments[3].author?.isBot == true)
        #expect(conversation.totalComments == 250)
        #expect(conversation.olderNotLoaded == 248)
    }

    @Test func closedIssueOnItsLastPage() throws {
        let json = """
        {"data":{"repository":{"issueOrPullRequest":{"__typename":"Issue","number":2830,"title":"Anchors lost",
          "url":"https://github.com/acme/docs-toolkit/issues/2830","state":"CLOSED","stateReason":"NOT_PLANNED",
          "createdAt":"2026-10-10T08:00:00Z","bodyHTML":"","author":{"login":"reviewer"},"labels":{"nodes":[]},
          "reactionGroups":[],"comments":{"totalCount":0,"pageInfo":{"hasPreviousPage":false,"startCursor":null},"nodes":[]}}}}}
        """
        let page = try #require(GitHub.parseConversation(Data(json.utf8), repo: repo, number: 2830, now: Date()))
        #expect(page.before == nil)
        #expect(page.conversation.kind == .issue)
        #expect(page.conversation.stateText == "closed as not planned")
        #expect(page.conversation.comments.isEmpty)
    }

    @Test func invisibleThread() {
        let json = #"{"data":{"repository":{"issueOrPullRequest":null}},"errors":[{"type":"NOT_FOUND"}]}"#
        #expect(GitHub.parseConversation(Data(json.utf8), repo: repo, number: 1, now: Date()) == nil)
    }
}

struct ThreadFoldTests {
    let base = Date(timeIntervalSince1970: 1_000_000)

    private func comments(_ minutes: [Double]) -> [ThreadComment] {
        minutes.enumerated().map { index, minute in
            ThreadComment(id: "c\(index)", author: nil, createdAt: base.addingTimeInterval(minute * 60), bodyHTML: "")
        }
    }

    @Test func noSeenAtShowsEverything() {
        let fold = ThreadFold.compute(comments([1, 2, 3]), seenAt: nil)
        #expect(fold == ThreadFold(folded: 0, divider: nil, newCount: 0))
    }

    @Test func readCommentsFoldAndTheDividerMarksTheFirstNew() {
        let all = comments([1, 2, 3, 4, 5, 6, 7, 8, 9])
        let fold = ThreadFold.compute(all, seenAt: base.addingTimeInterval(6 * 60))
        #expect(fold == ThreadFold(folded: 6, divider: 6, newCount: 3))
        #expect(fold.foldText == "6 earlier comments, read")
        #expect(fold.dividerText == "new · 3")
    }

    @Test func aCommentAtTheSeenInstantIsRead() {
        let fold = ThreadFold.compute(comments([1, 2]), seenAt: base.addingTimeInterval(60))
        #expect(fold == ThreadFold(folded: 1, divider: 1, newCount: 1))
        #expect(fold.foldText == "1 earlier comment, read")
    }

    @Test func nothingNewKeepsTheLastReadOne() {
        let fold = ThreadFold.compute(comments([1, 2, 3]), seenAt: base.addingTimeInterval(3600))
        #expect(fold == ThreadFold(folded: 2, divider: nil, newCount: 0))
    }

    @Test func allNewFoldsNothing() {
        let fold = ThreadFold.compute(comments([5, 6]), seenAt: base)
        #expect(fold == ThreadFold(folded: 0, divider: 0, newCount: 2))
    }

    @Test func unfoldingKeepsTheDivider() {
        let fold = ThreadFold.compute(comments([1, 2, 3]), seenAt: base.addingTimeInterval(150), unfolded: true)
        #expect(fold == ThreadFold(folded: 0, divider: 2, newCount: 1))
    }

    @Test func noComments() {
        #expect(ThreadFold.compute([], seenAt: base) == ThreadFold(folded: 0, divider: nil, newCount: 0))
    }
}

struct ThreadHTMLTests {
    let palette = ThreadPalette(
        background: 0x15171A, text: 0xE9EAEC, muted: 0xA6ABB2, faint: 0x848B93, line: 0x272B30, code: 0x0C0D0F,
        chip: 0x23272C, link: 0x67B0F9, mention: 0xE9EAEC, added: 0x72D699, removed: 0xF97770, keyword: 0xF97770,
        string: 0x82D7FF
    )
    let base = URL(string: "https://github.com/acme/docs-toolkit/issues/1")

    @Test func sheetUsesThePalette() {
        let css = ThreadHTML.css(palette, fontSize: 13)
        #expect(css.contains("background: #15171A"))
        #expect(css.contains("color: #E9EAEC"))
        #expect(css.contains("font: 13px/1.55"))
        #expect(css.contains("a { color: #67B0F9"))
        #expect(css.contains("img { max-width: 100%"))
        #expect(css.contains("pre { background: #0C0D0F"))
        #expect(css.contains("a.user-mention"))
        #expect(css.contains("li.task-list-item"))
        #expect(css.contains("th, td { border: 1px solid #272B30"))
        #expect(ThreadHTML.css(palette.on(0x111214)).contains("background: #111214"))
    }

    @Test func documentAllowsNoScriptsAndOnlyProxiedImages() {
        let document = ThreadHTML.document(body: "<p>hi</p>", palette: palette, base: base)
        #expect(document.contains("Content-Security-Policy"))
        #expect(document.contains("default-src 'none'"))
        #expect(document.contains("script-src 'none'"))
        #expect(document.contains("img-src heed-image:;"))
        #expect(!document.contains("img-src https"))
        #expect(document.contains("<div id=\"heed-root\" class=\"markdown-body\"><p>hi</p></div>"))
        #expect(ThreadHTML.document(body: "  ", palette: palette, base: base).contains("No description provided."))
    }

    @Test func imagesGoThroughTheProxyAndGetALink() throws {
        let html = """
        <p><a target="_blank" href="https://camo.githubusercontent.com/x"><img src="https://camo.githubusercontent.com/x?a=1&amp;b=2" srcset="https://evil.example/2x 2x" alt="shot"></a></p>\
        <img src="/acme/docs-toolkit/raw/main/pic.png"><img src="http://plain.example/p.png" alt="plain">\
        <picture><source srcset="https://x.example/dark.png"><img src="data:image/png;base64,AAAA"></picture>
        """
        let out = ThreadHTML.rewriteImages(html, base: base)
        #expect(!out.contains("srcset"))
        #expect(!out.contains("<source"))
        #expect(!out.contains("src=\"https://"))
        #expect(!out.contains("src=\"http://"))
        #expect(!out.contains("src=\"data:"))
        // The first was already in a link: not wrapped again.
        #expect(out.components(separatedBy: "<a ").count == 3)
        // The relative one resolved against the thread, and linked to the original.
        #expect(out
            .contains("<a href=\"https://github.com/acme/docs-toolkit/raw/main/pic.png\"><img src=\"heed-image:"))
        // The proxied URL round-trips, entities decoded.
        let sources = out.components(separatedBy: "src=\"").dropFirst().map { $0.prefix { $0 != "\"" } }
        let first = try #require(URL(string: ThreadHTML.decodeEntities(String(sources[0]))))
        #expect(ThreadHTML.original(of: first)?.absoluteString == "https://camo.githubusercontent.com/x?a=1&b=2")
    }

    @Test func proxyRefusesAnythingButHTTPS() {
        #expect(ThreadHTML.original(of: URL(string: "heed-image://i/?u=http://x.example/a.png")!) == nil)
        #expect(ThreadHTML.original(of: URL(string: "https://x.example/?u=https://x.example/a.png")!) == nil)
        #expect(ThreadHTML.original(of: URL(string: "heed-image://i/?u=file:///etc/passwd")!) == nil)
    }
}
