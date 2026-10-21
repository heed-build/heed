import AppKit
import SwiftUI
import WebKit

/// A web page, drawn from the web view `BrowserSurfaces` keeps for `id`, so it survives re-layout as a terminal does.
struct BrowserView: NSViewRepresentable {
    let id: String
    /// Loaded when the page's web view is first made.
    let url: String?
    /// True when the page should own the keyboard.
    let isFocused: Bool

    func makeNSView(context _: Context) -> NSView {
        BrowserSurfaces.shared.view(id, url: url)
    }

    func updateNSView(_ view: NSView, context _: Context) {
        if isFocused, let window = view.window, window.firstResponder !== view { window.makeFirstResponder(view) }
    }
}

/// What a page is doing right now, for whatever draws its controls.
@MainActor @Observable
final class BrowserPage {
    var url: String
    var title = ""
    var loading = false
    var progress = 0.0
    var canGoBack = false
    var canGoForward = false
    /// The page's HTTP status when it is an error: a 502 with an empty body is otherwise just a white page.
    var status: Int?
    /// Why the page could not load at all (no server, bad address); nil once a load starts.
    var failure: String?

    init(url: String?) {
        self.url = url ?? ""
    }
}

/// Owns every page's web view and state, keyed by an id of the caller's (a pane's). One cookie store for all of them:
/// you sign in once.
@MainActor
final class BrowserSurfaces {
    static let shared = BrowserSurfaces()
    private var views: [String: PageWebView] = [:]
    private var pages: [String: BrowserPage] = [:]
    private var observations: [String: [NSKeyValueObservation]] = [:]
    private lazy var delegate = BrowserDelegate(surfaces: self)

    /// A click in a page.
    var onClick: ((String) -> Void)?
    /// A page went somewhere or got a title: id, address, title.
    var onNavigated: ((String, String, String) -> Void)?
    /// A page asked for a new tab: id, address, and whether to show it (a link with a target) or open it behind
    /// (⌘-click).
    var onOpenTab: ((String, URL, Bool) -> Void)?

    func page(_ id: String, url: String? = nil) -> BrowserPage {
        if let page = pages[id] { return page }
        let page = BrowserPage(url: url)
        pages[id] = page
        return page
    }

    func view(_ id: String, url: String?) -> NSView {
        if let existing = views[id] {
            existing.removeFromSuperview()
            return existing
        }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        // Without Safari's tokens some sites (Google sign-in) turn an embedded browser away.
        configuration.applicationNameForUserAgent = "Version/26.0 Safari/605.1.15"
        let view = PageWebView(frame: .zero, configuration: configuration)
        view.allowsBackForwardNavigationGestures = true
        // Safari's Develop menu can inspect it.
        view.isInspectable = true
        view.navigationDelegate = delegate
        view.uiDelegate = delegate
        view.onClick = { [weak self] in self?.onClick?(id) }
        views[id] = view
        _ = page(id, url: url)
        observe(view, id: id)
        if let url = url.flatMap(URL.init(string:)) { view.load(URLRequest(url: url)) }
        return view
    }

    func isBrowserView(_ view: NSView) -> Bool {
        views.values.contains { $0 === view }
    }

    func load(_ address: String, in id: String) {
        guard let url = URL(string: address) else { return }
        views[id]?.load(URLRequest(url: url))
    }

    func back(_ id: String) { views[id]?.goBack() }
    func forward(_ id: String) { views[id]?.goForward() }

    func reloadOrStop(_ id: String) {
        guard let view = views[id] else { return }
        if view.isLoading { view.stopLoading() } else { view.reload() }
    }

    /// Multiplies the page's zoom by `factor`; nil is actual size.
    func zoom(_ id: String, by factor: Double?) {
        guard let view = views[id] else { return }
        view.pageZoom = factor.map { min(max(view.pageZoom * $0, 0.5), 3) } ?? 1
    }

    /// A page closed for good: its web view goes, and with it its web content process.
    func close(_ id: String) {
        observations.removeValue(forKey: id)
        pages.removeValue(forKey: id)
        guard let view = views.removeValue(forKey: id) else { return }
        view.stopLoading()
        view.removeFromSuperview()
    }

    private func observe(_ view: WKWebView, id: String) {
        let sync: @Sendable () -> Void = { [weak self] in MainActor.assumeIsolated { self?.sync(id) } }
        observations[id] = [
            view.observe(\.url) { _, _ in sync() },
            view.observe(\.title) { _, _ in sync() },
            view.observe(\.isLoading) { _, _ in sync() },
            view.observe(\.estimatedProgress) { _, _ in sync() },
            view.observe(\.canGoBack) { _, _ in sync() },
            view.observe(\.canGoForward) { _, _ in sync() },
        ]
    }

    private func sync(_ id: String) {
        guard let view = views[id], let page = pages[id] else { return }
        let url = view.url?.absoluteString ?? page.url
        let title = view.title ?? ""
        let moved = url != page.url || title != page.title
        page.url = url
        page.title = title
        page.loading = view.isLoading
        page.progress = view.estimatedProgress
        page.canGoBack = view.canGoBack
        page.canGoForward = view.canGoForward
        if moved, !url.isEmpty { onNavigated?(id, url, title) }
    }

    fileprivate func id(of view: WKWebView) -> String? {
        views.first { $0.value === view }?.key
    }

    fileprivate func started(_ view: WKWebView) {
        guard let id = id(of: view), let page = pages[id] else { return }
        page.status = nil
        page.failure = nil
    }

    fileprivate func responded(_ view: WKWebView, status: Int) {
        guard let id = id(of: view) else { return }
        pages[id]?.status = status >= 400 ? status : nil
    }

    fileprivate func failed(_ view: WKWebView, _ error: Error) {
        let error = error as NSError
        // Cancelled (another load took over) and interrupted (handed to a download or another app) are not failures.
        let cancelled = error.domain == NSURLErrorDomain && error.code == NSURLErrorCancelled
        let interrupted = error.domain == "WebKitErrorDomain" && error.code == 102
        guard !cancelled, !interrupted, let id = id(of: view) else { return }
        pages[id]?.failure = error.localizedDescription
    }
}

/// A web view that says when it is clicked, as a terminal does.
private final class PageWebView: WKWebView {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onClick?()
        super.mouseDown(with: event)
    }
}

/// Where pages may go. Links to other apps (mailto:, zoommtg:) open only from a click, never from a page on its own:
/// a page must not bring another app to the front.
@MainActor
private final class BrowserDelegate: NSObject, WKNavigationDelegate, WKUIDelegate {
    private weak var surfaces: BrowserSurfaces?
    private static let schemes: Set<String> = ["http", "https", "about", "file", "data", "blob"]

    init(surfaces: BrowserSurfaces) {
        self.surfaces = surfaces
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        guard let url = navigationAction.request.url else { return .allow }
        let clicked = navigationAction.navigationType == .linkActivated
        if let scheme = url.scheme?.lowercased(), !Self.schemes.contains(scheme) {
            if clicked { NSWorkspace.shared.open(url) }
            return .cancel
        }
        if clicked, navigationAction.modifierFlags.contains(.command) {
            openTab(from: webView, url, show: false)
            return .cancel
        }
        return .allow
    }

    func webView(
        _ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        if navigationResponse.isForMainFrame, let http = navigationResponse.response as? HTTPURLResponse {
            surfaces?.responded(webView, status: http.statusCode)
        }
        return .allow
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation _: WKNavigation!) {
        surfaces?.started(webView)
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation _: WKNavigation!, withError error: Error) {
        surfaces?.failed(webView, error)
    }

    func webView(_ webView: WKWebView, didFail _: WKNavigation!, withError error: Error) {
        surfaces?.failed(webView, error)
    }

    func webView(
        _ webView: WKWebView, createWebViewWith _: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
        windowFeatures _: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url { openTab(from: webView, url, show: true) }
        return nil
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        webView.reload()
    }

    private func openTab(from webView: WKWebView, _ url: URL, show: Bool) {
        guard let surfaces, let id = surfaces.id(of: webView) else { return }
        surfaces.onOpenTab?(id, url, show)
    }
}
