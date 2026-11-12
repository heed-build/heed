import AppKit
import HeedCore
import SwiftUI
import WebKit

/// One GitHub body (an issue's or PR's description, a comment), rendered from GitHub's own HTML in a web view that
/// runs no JavaScript, fetches nothing but images (through `ThreadImageHandler`, without any credential), opens
/// links in the default browser and never navigates itself. It is as tall as its content, so it scrolls with the
/// page around it. In docs shots, which draw offscreen, it is a picture of the same page (`ThreadSnapshots`).
struct ThreadWebView: View {
    @Environment(AppModel.self) private var model
    let html: String
    /// The thread's URL: relative links and images resolve against it.
    let base: String
    /// The card it sits on, so the page's background matches it.
    var background: UInt32 = ThreadWeb.card
    var fontSize: Double = 13

    @State private var height: CGFloat = 0

    var body: some View {
        let document = ThreadWeb.document(html, base: URL(string: base), background: background, fontSize: fontSize)
        if ShotMode.active {
            ThreadSnapshotView(document: document)
        } else {
            LiveThreadWeb(
                document: document, base: URL(string: base), fixture: model.isFixture, height: $height,
                open: { url in if !model.isFixture { NSWorkspace.shared.open(url) } }
            )
            .frame(height: max(height, ThreadWeb.heights[document] ?? 18))
        }
    }
}

/// What the readers' web views share: heed's palette, the configuration, and the documents and heights already made.
@MainActor
enum ThreadWeb {
    static let card: UInt32 = 0x15171A
    static let page: UInt32 = 0x111214

    /// Theme's colours, for the page.
    static let palette = ThreadPalette(
        background: card, text: 0xE9EAEC, muted: 0xA6ABB2, faint: 0x848B93, line: 0x272B30, code: 0x0C0D0F,
        chip: 0x23272C, link: 0x67B0F9, mention: 0xE9EAEC, added: 0x72D699, removed: 0xF97770, keyword: 0xF97770,
        string: 0x82D7FF
    )

    /// Measured heights, by document (the last width it was drawn at), so a card that is made again (scrolled back
    /// into a lazy stack, the reader reopened) starts at its height instead of growing into it.
    static var heights: [String: CGFloat] = [:]
    private static var documents: [String: String] = [:]

    static func document(_ html: String, base: URL?, background: UInt32, fontSize: Double) -> String {
        let key = "\(background):\(fontSize):\(base?.absoluteString ?? ""):\(html)"
        if let made = documents[key] { return made }
        if documents.count > 400 { documents.removeAll() }
        let made = ThreadHTML.document(body: html, palette: palette.on(background), base: base, fontSize: fontSize)
        documents[key] = made
        return made
    }

    static func remember(_ height: CGFloat, for document: String) {
        if heights.count > 400 { heights.removeAll() }
        heights[document] = height
    }

    private static var configurations: [Bool: WKWebViewConfiguration] = [:]

    /// No JavaScript from the page, no persistent cookies or storage, images only through heed's scheme. `fixture`:
    /// the image handler serves the fake world's images and touches no network.
    static func configuration(fixture: Bool) -> WKWebViewConfiguration {
        if let made = configurations[fixture] { return made }
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(ThreadImageHandler(fixture: fixture), forURLScheme: ThreadHTML.imageScheme)
        configurations[fixture] = configuration
        return configuration
    }
}

/// The web view: scroll wheel events go to the page around it (it is never taller than its content), and anything
/// that may change its height (a new width, an image arriving, a click that opens a `<details>`) measures again.
final class ThreadWKWebView: WKWebView {
    var contentChanged: (() -> Void)?

    override func scrollWheel(with event: NSEvent) {
        if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) } else { nextResponder?.scrollWheel(
            with: event
        ) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(frame.width - newSize.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged { contentChanged?() }
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { [weak self] in self?.contentChanged?() }
    }
}

private struct LiveThreadWeb: NSViewRepresentable {
    let document: String
    let base: URL?
    let fixture: Bool
    @Binding var height: CGFloat
    let open: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> ThreadWKWebView {
        let web = ThreadWKWebView(frame: .zero, configuration: ThreadWeb.configuration(fixture: fixture))
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.navigationDelegate = context.coordinator
        web.uiDelegate = context.coordinator
        web.contentChanged = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.web = web
        context.coordinator.load(document)
        return web
    }

    func updateNSView(_: ThreadWKWebView, context: Context) {
        context.coordinator.parent = self
        if context.coordinator.document != document { context.coordinator.load(document) }
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        var parent: LiveThreadWeb
        weak var web: ThreadWKWebView?
        var document = ""
        /// The one navigation allowed: the document heed loads. Everything after it is a link (to the browser) or
        /// refused.
        private var expectingLoad = false

        init(_ parent: LiveThreadWeb) {
            self.parent = parent
        }

        func load(_ document: String) {
            self.document = document
            expectingLoad = true
            web?.loadHTMLString(document, baseURL: parent.base)
        }

        func measure() {
            guard let web else { return }
            web.evaluateJavaScript(ThreadHTML.heightScript) { [weak self] value, _ in
                MainActor.assumeIsolated {
                    guard let self, let height = (value as? NSNumber).map({ CGFloat($0.doubleValue) }), height > 0
                    else { return }
                    ThreadWeb.remember(height, for: self.document)
                    if abs(height - self.parent.height) > 0.5 { self.parent.height = height }
                }
            }
        }

        func webView(
            _: WKWebView, decidePolicyFor action: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            if action.navigationType == .other, expectingLoad, action.targetFrame?.isMainFrame == true {
                expectingLoad = false
                return decisionHandler(.allow)
            }
            if action.navigationType == .linkActivated || action.targetFrame == nil,
               let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme?.lowercased() ?? "")
            {
                parent.open(url)
            }
            decisionHandler(.cancel)
        }

        func webView(
            _: WKWebView, createWebViewWith _: WKWebViewConfiguration, for _: WKNavigationAction,
            windowFeatures _: WKWindowFeatures
        ) -> WKWebView? { nil }

        func webView(_: WKWebView, didFinish _: WKNavigation!) {
            measure()
        }
    }
}

/// Images for the readers' pages: the https URL behind `heed-image://`, fetched with no cookies and no credential
/// (heed never puts its GitHub token in a page). Anything that is not an image, too big, or does not load (a
/// private repo's image whose link expired) is served as a box saying so; the image sits in a link to the original,
/// so a click opens it in the browser, where you are signed in. In fixtures it serves the fake world's images.
@MainActor
final class ThreadImageHandler: NSObject, WKURLSchemeHandler {
    private let fixture: Bool
    private var running: Set<ObjectIdentifier> = []
    private static let maxBytes = 15 * 1024 * 1024
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.urlCache = URLCache(memoryCapacity: 32 * 1024 * 1024, diskCapacity: 0)
        configuration.timeoutIntervalForRequest = 20
        return URLSession(configuration: configuration)
    }()

    init(fixture: Bool) {
        self.fixture = fixture
    }

    func webView(_ webView: WKWebView, start task: any WKURLSchemeTask) {
        let id = ObjectIdentifier(task)
        running.insert(id)
        let original = task.request.url.flatMap(ThreadHTML.original(of:))
        if fixture {
            let data = original.flatMap { Fixtures.threadImages[$0.absoluteString] }
            return finish(task, id: id, data: data, mime: "image/svg+xml", in: webView)
        }
        guard let original else { return finish(task, id: id, data: nil, mime: nil, in: webView) }
        Task {
            var request = URLRequest(url: original)
            request.setValue("image/*", forHTTPHeaderField: "Accept")
            let fetched = try? await Self.session.data(for: request)
            let response = fetched?.1 as? HTTPURLResponse
            let mime = response?.mimeType ?? ""
            let good = response?.statusCode == 200 && mime.hasPrefix("image/")
                && (fetched?.0.count ?? 0) <= Self.maxBytes
            finish(task, id: id, data: good ? fetched?.0 : nil, mime: mime, in: webView)
        }
    }

    func webView(_: WKWebView, stop task: any WKURLSchemeTask) {
        running.remove(ObjectIdentifier(task))
    }

    private func finish(
        _ task: any WKURLSchemeTask,
        id: ObjectIdentifier,
        data: Data?,
        mime: String?,
        in web: WKWebView
    ) {
        guard running.remove(id) != nil, let url = task.request.url else { return }
        let body = data ?? ThreadHTML.missingImage(ThreadWeb.palette)
        let type = data == nil ? "image/svg+xml" : mime ?? "image/png"
        task.didReceive(URLResponse(url: url, mimeType: type, expectedContentLength: body.count, textEncodingName: nil))
        task.didReceive(body)
        task.didFinish()
        (web as? ThreadWKWebView)?.contentChanged?()
    }
}

// MARK: Docs shots

/// A rendered page in a docs shot: ImageRenderer cannot draw a web view, so the shot runner renders each page the
/// shot asks for in a real (offscreen, never shown) web view first and takes its snapshot; this draws that picture.
private struct ThreadSnapshotView: View {
    let document: String

    var body: some View {
        Color.clear
            .frame(height: ThreadSnapshots.shared.heights[document] ?? 18)
            .frame(maxWidth: .infinity)
            .overlay {
                GeometryReader { geometry in
                    if let image = ThreadSnapshots.shared.want(document, width: geometry.size.width) {
                        Image(nsImage: image).resizable().interpolation(.high)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
    }
}

/// The pictures docs shots draw for web views, made by `render()` between two passes of the shot.
@MainActor
final class ThreadSnapshots {
    static let shared = ThreadSnapshots()
    private(set) var heights: [String: CGFloat] = [:]
    private var images: [String: NSImage] = [:]
    private var wanted: [(document: String, width: CGFloat)] = []

    private static func key(_ document: String, _ width: CGFloat) -> String { "\(Int(width.rounded())):\(document)" }

    /// The picture for this page at this width, or nil (and it is made before the shot's next pass).
    func want(_ document: String, width: CGFloat) -> NSImage? {
        guard width > 20 else { return nil }
        if let image = images[Self.key(document, width)] { return image }
        if !wanted.contains(where: { $0.document == document && Int($0.width) == Int(width) }) {
            wanted.append((document, width))
        }
        return nil
    }

    /// Renders what the last pass asked for; false when it asked for nothing new.
    func render() async -> Bool {
        let pending = wanted
        wanted = []
        guard !pending.isEmpty else { return false }
        for (document, width) in pending {
            guard let (image, height) = await snapshot(document, width: width) else { continue }
            images[Self.key(document, width)] = image
            heights[document] = height
        }
        return true
    }

    private func snapshot(_ document: String, width: CGFloat) async -> (NSImage, CGFloat)? {
        let frame = NSRect(x: 0, y: 0, width: width, height: 40)
        let web = ThreadWKWebView(frame: frame, configuration: ThreadWeb.configuration(fixture: true))
        let window = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = web
        let loaded = LoadWaiter()
        web.navigationDelegate = loaded
        web.loadHTMLString(document, baseURL: URL(string: "https://github.com/"))
        await loaded.wait()
        // Images come through the handler a moment after the page.
        try? await Task.sleep(for: .milliseconds(120))
        let measured = try? await web.evaluateJavaScript(ThreadHTML.heightScript)
        guard let height = (measured as? NSNumber).map({ CGFloat($0.doubleValue) }), height > 0 else { return nil }
        web.setFrameSize(NSSize(width: width, height: height))
        window.setContentSize(web.frame.size)
        try? await Task.sleep(for: .milliseconds(80))
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
        guard let image = try? await web.takeSnapshot(configuration: configuration) else { return nil }
        window.contentView = nil
        return (image, height)
    }

    private final class LoadWaiter: NSObject, WKNavigationDelegate {
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false

        func wait() async {
            if done { return }
            await withCheckedContinuation { continuation = $0 }
        }

        private func finish() {
            done = true
            continuation?.resume()
            continuation = nil
        }

        func webView(_: WKWebView, didFinish _: WKNavigation!) { finish() }
        func webView(_: WKWebView, didFail _: WKNavigation!, withError _: any Error) { finish() }
    }
}
