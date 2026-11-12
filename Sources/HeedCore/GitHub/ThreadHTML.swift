import Foundation

/// The colours a rendered GitHub body is drawn in, as RGB hex (`0x111214`). The app fills it from its Theme, so the
/// page is heed's dark look rather than GitHub's.
public struct ThreadPalette: Hashable, Sendable {
    /// What the page sits on: the card it is drawn in, so the web view's edges never show.
    public var background: UInt32
    public var text: UInt32
    public var muted: UInt32
    public var faint: UInt32
    public var line: UInt32
    /// Code blocks and table headers.
    public var code: UInt32
    /// Inline code and keyboard keys.
    public var chip: UInt32
    public var link: UInt32
    public var mention: UInt32
    public var added: UInt32
    public var removed: UInt32
    public var keyword: UInt32
    public var string: UInt32

    public init(
        background: UInt32, text: UInt32, muted: UInt32, faint: UInt32, line: UInt32, code: UInt32, chip: UInt32,
        link: UInt32, mention: UInt32, added: UInt32, removed: UInt32, keyword: UInt32, string: UInt32
    ) {
        self.background = background
        self.text = text
        self.muted = muted
        self.faint = faint
        self.line = line
        self.code = code
        self.chip = chip
        self.link = link
        self.mention = mention
        self.added = added
        self.removed = removed
        self.keyword = keyword
        self.string = string
    }

    /// The same colours on another background (the narrow Attention pane draws its cards on a darker one).
    public func on(_ background: UInt32) -> ThreadPalette {
        var palette = self
        palette.background = background
        return palette
    }
}

/// GitHub's rendered HTML (`bodyHTML`) as a page heed can show safely: no scripts (the web view runs none, and the
/// Content-Security-Policy allows none), nothing fetched but images, and those only through heed's image scheme,
/// which loads https images without any GitHub credential.
public enum ThreadHTML {
    /// The scheme images are rewritten to; the app's handler fetches the https URL in `u`.
    public static let imageScheme = "heed-image"

    /// The page's policy: no scripts, frames, fonts, media, forms or connections; images only through
    /// `imageScheme`; styles only the inline sheet heed writes.
    public static let contentSecurityPolicy =
        "default-src 'none'; img-src \(imageScheme):; style-src 'unsafe-inline'; script-src 'none'; "
            + "frame-src 'none'; form-action 'none'; base-uri 'none'"

    /// A whole document for one body: the policy, the sheet, and the body with its images rewritten. `base`
    /// resolves relative links and images (the thread's URL).
    public static func document(body: String, palette: ThreadPalette, base: URL?, fontSize: Double = 13) -> String {
        let content = body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "<p class=\"heed-empty\">No description provided.</p>" : rewriteImages(body, base: base)
        return """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="\(contentSecurityPolicy)">
        <meta name="referrer" content="no-referrer">
        <style>\(css(palette, fontSize: fontSize))</style></head>
        <body><div id="heed-root" class="markdown-body">\(content)</div></body></html>
        """
    }

    /// What the app asks the page for its height (in the client world: the page itself runs nothing).
    public static let heightScript = "Math.ceil(document.getElementById('heed-root').getBoundingClientRect().height)"

    // MARK: Images

    /// Every `<img>` loads through `imageScheme` (https only; anything else loses its source and shows its alt
    /// text), `srcset` and `<source>` go (they would bypass the rewrite), and an image not already in a link gets
    /// one to the original, so a picture that does not load can still be opened in the browser.
    public static func rewriteImages(_ html: String, base: URL?) -> String {
        var html = html.replacingOccurrences(of: #"<source\b[^>]*>"#, with: "", options: .regularExpression)
        guard let tag = try? NSRegularExpression(pattern: #"<img\b[^>]*>"#, options: [.caseInsensitive]),
              let src = try? NSRegularExpression(pattern: #"\ssrc\s*=\s*"([^"]*)""#, options: [.caseInsensitive]),
              let srcset = try? NSRegularExpression(pattern: #"\ssrcset\s*=\s*"[^"]*""#, options: [.caseInsensitive])
        else { return html }
        let source = html as NSString
        var result = ""
        var last = 0
        for match in tag.matches(in: html, range: NSRange(location: 0, length: source.length)) {
            result += source.substring(with: NSRange(location: last, length: match.range.location - last))
            last = match.range.location + match.range.length
            var image = source.substring(with: match.range)
            image = srcset.stringByReplacingMatches(
                in: image, range: NSRange(location: 0, length: (image as NSString).length), withTemplate: ""
            )
            let imageText = image as NSString
            guard let found = src.firstMatch(in: image, range: NSRange(location: 0, length: imageText.length)) else {
                result += image
                continue
            }
            let raw = decodeEntities(imageText.substring(with: found.range(at: 1)))
            guard let url = URL(string: raw, relativeTo: base)?.absoluteURL, url.scheme?.lowercased() == "https"
            else {
                result += imageText.replacingCharacters(in: found.range, with: "")
                continue
            }
            image = imageText.replacingCharacters(in: found.range, with: " src=\"\(proxied(url))\"")
            let before = result.suffix(400)
            let linked = before.range(of: #"<a\b[^>]*>\s*$"#, options: [.regularExpression, .caseInsensitive]) != nil
            result += linked ? image : "<a href=\"\(escapeAttribute(url.absoluteString))\">\(image)</a>"
        }
        result += source.substring(from: last)
        html = result
        return html
    }

    /// `heed-image://i/?u=<the https URL>`.
    public static func proxied(_ url: URL) -> String {
        var components = URLComponents()
        components.scheme = imageScheme
        components.host = "i"
        components.path = "/"
        components.queryItems = [URLQueryItem(name: "u", value: url.absoluteString)]
        return escapeAttribute(components.string ?? "")
    }

    /// The https URL behind a proxied image request; nil for anything else.
    public static func original(of request: URL) -> URL? {
        guard request.scheme == imageScheme,
              let value = URLComponents(url: request, resolvingAgainstBaseURL: false)?.queryItems?
              .first(where: { $0.name == "u" })?.value,
              let url = URL(string: value), url.scheme?.lowercased() == "https"
        else { return nil }
        return url
    }

    /// What an image that did not load shows instead: a quiet box saying so. It sits in a link to the original.
    public static func missingImage(_ palette: ThreadPalette) -> Data {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="320" height="40" viewBox="0 0 320 40">
        <rect x="0.5" y="0.5" width="319" height="39" rx="6" fill="\(hex(palette.code))" stroke="\(hex(palette.line))"/>
        <text x="14" y="25" font-family="-apple-system, Helvetica" font-size="12.5" fill="\(hex(palette.muted))">\
        Image did not load · open it in the browser ↗</text></svg>
        """
        return Data(svg.utf8)
    }

    // MARK: The sheet

    /// The style sheet: GitHub's markdown elements in heed's colours and type. Code blocks, inline code, tables,
    /// task lists, quotes, headings, images at most the page's width, and GitHub's mention and issue links.
    public static func css(_ palette: ThreadPalette, fontSize: Double = 13) -> String {
        let bg = hex(palette.background), text = hex(palette.text), muted = hex(palette.muted)
        let faint = hex(palette.faint), line = hex(palette.line), code = hex(palette.code)
        let chip = hex(palette.chip), link = hex(palette.link), mention = hex(palette.mention)
        let mono = "'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace"
        let size = String(format: "%g", fontSize)
        let small = String(format: "%g", (fontSize * 0.9 * 10).rounded() / 10)
        return """
        :root { color-scheme: dark; }
        html, body { margin: 0; padding: 0; background: \(bg); overflow: hidden; }
        body { color: \(text); font: \(size)px/1.55 -apple-system, BlinkMacSystemFont, 'Helvetica Neue', sans-serif;
          -webkit-font-smoothing: antialiased; word-wrap: break-word; overflow-wrap: anywhere; }
        #heed-root { display: flow-root; }
        #heed-root > :first-child { margin-top: 0 !important; }
        #heed-root > :last-child { margin-bottom: 0 !important; }
        p, ul, ol, blockquote, pre, table, details, .highlight, .snippet-clipboard-content { margin: 0 0 10px; }
        h1, h2, h3, h4, h5, h6 { color: \(text); font-weight: 600; line-height: 1.3; margin: 18px 0 8px; }
        h1 { font-size: 1.45em; padding-bottom: 5px; border-bottom: 1px solid \(line); }
        h2 { font-size: 1.25em; padding-bottom: 4px; border-bottom: 1px solid \(line); }
        h3 { font-size: 1.1em; } h4, h5, h6 { font-size: 1em; } h6 { color: \(muted); }
        a { color: \(link); text-decoration: none; } a:hover { text-decoration: underline; }
        a.user-mention, a.team-mention { color: \(mention); font-weight: 600; }
        a.issue-link, a.commit-link { color: \(link); font-family: \(mono); font-size: \(small)px; }
        strong { font-weight: 600; } hr { border: 0; border-top: 1px solid \(line); margin: 16px 0; }
        ul, ol { padding-left: 22px; } li + li { margin-top: 3px; } li > ul, li > ol { margin: 3px 0 0; }
        ul.contains-task-list { padding-left: 4px; } li.task-list-item { list-style: none; }
        li.task-list-item input { margin: 0 7px 0 0; vertical-align: -1px; accent-color: \(link); }
        blockquote { margin-left: 0; padding: 0 12px; color: \(muted); border-left: 3px solid \(line); }
        code, kbd, tt, samp { font-family: \(mono); font-size: \(small)px; }
        :not(pre) > code, kbd { background: \(chip); border-radius: 4px; padding: 1px 5px; }
        kbd { border: 1px solid \(line); border-bottom-width: 2px; }
        pre { background: \(code); border: 1px solid \(line); border-radius: 6px; padding: 10px 12px;
          overflow-x: auto; line-height: 1.45; white-space: pre; }
        pre code { background: none; padding: 0; font-size: \(small)px; white-space: pre; }
        .highlight pre, .snippet-clipboard-content pre { margin: 0; }
        clipboard-copy, .zeroclipboard-container, .js-clipboard-copy { display: none !important; }
        table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow-x: auto; }
        th, td { border: 1px solid \(line); padding: 5px 11px; text-align: left; }
        th { background: \(code); font-weight: 600; } tr:nth-child(2n) td { background: \(code)80; }
        img { max-width: 100%; height: auto; border-radius: 4px; vertical-align: middle; }
        img.emoji { height: 1.2em; width: auto; vertical-align: -0.2em; }
        details { border: 1px solid \(line); border-radius: 6px; padding: 6px 10px; }
        summary { cursor: pointer; color: \(muted); } details[open] > summary { margin-bottom: 6px; }
        .markdown-alert { padding: 2px 12px; border-left: 3px solid \(link); margin-bottom: 10px; }
        .markdown-alert-title { font-weight: 600; color: \(link); }
        .markdown-alert-warning, .markdown-alert-caution { border-left-color: \(hex(palette.removed)); }
        .markdown-alert-warning .markdown-alert-title, .markdown-alert-caution .markdown-alert-title {
          color: \(hex(palette.removed)); }
        .octicon { display: none; } .heed-empty { color: \(faint); font-style: italic; }
        sup, sub { line-height: 0; } .footnotes { color: \(muted); font-size: \(small)px; border-top: 1px solid \(line);
          padding-top: 8px; } .sr-only, .visually-hidden { display: none; }
        .pl-c { color: \(faint); font-style: italic; } .pl-k, .pl-kos + .pl-k { color: \(hex(palette.keyword)); }
        .pl-s, .pl-pds, .pl-s .pl-s1, .pl-sr { color: \(hex(palette.string)); }
        .pl-en, .pl-ent { color: \(link); } .pl-c1, .pl-v, .pl-smi { color: \(mention); }
        .pl-mi1, .pl-mi1 * { color: \(hex(palette.added)); } .pl-md, .pl-md * { color: \(hex(palette.removed)); }
        .pl-mh, .pl-mh .pl-en { color: \(link); font-weight: 600; }
        """
    }

    /// `#111214`.
    public static func hex(_ value: UInt32) -> String { String(format: "#%06X", value & 0xFFFFFF) }

    static func escapeAttribute(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
    }

    static func decodeEntities(_ text: String) -> String {
        text.replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}
