import AppKit
import SwiftUI
import WebKit

/// GitHub-style preview of the open markdown file, shown in place of the editor. Re-renders when the text
/// changes (typing or a reload from disk) by replacing the content element, so the scroll position is kept.
/// Page JavaScript is disabled: only the app's own scripts (Mermaid + the update script) run, in the
/// isolated `.defaultClient` content world, so scripts inside a markdown file never execute.
struct MarkdownPreview: NSViewRepresentable {
    let controller: EditorController
    /// Directory of the file, so relative images and links resolve.
    let baseURL: URL
    /// Opens a local file link inside Sightline; returns false if it can't.
    let openLocalFile: (URL) -> Bool

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        for script in MermaidSupport.userScripts() {
            configuration.userContentController.addUserScript(script)
        }
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground") // no white flash in dark mode
        context.coordinator.attach(webView: webView, controller: controller, baseURL: baseURL)
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.openLocalFile = openLocalFile
        context.coordinator.attach(webView: webView, controller: controller, baseURL: baseURL)
    }

    static func dismantleNSView(_ webView: WKWebView, coordinator: Coordinator) {
        coordinator.detach()
    }

    func makeCoordinator() -> Coordinator { Coordinator(openLocalFile: openLocalFile) }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        private weak var webView: WKWebView?
        private weak var controller: EditorController?
        private var baseURL: URL?
        private var observer: NSObjectProtocol?
        private var pending: DispatchWorkItem?
        private var generation = 0
        var openLocalFile: (URL) -> Bool

        init(openLocalFile: @escaping (URL) -> Bool) { self.openLocalFile = openLocalFile }

        func attach(webView: WKWebView, controller: EditorController, baseURL: URL) {
            guard self.controller !== controller || self.webView !== webView else { return }
            detach()
            self.webView = webView
            self.controller = controller
            self.baseURL = baseURL
            observer = NotificationCenter.default.addObserver(
                forName: NSText.didChangeNotification, object: controller.textView, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.scheduleUpdate() }
            }
            let body = MarkdownRenderer.body(controller.text)
            webView.loadHTMLString(MarkdownPage.html(body: body), baseURL: baseURL)
        }

        func detach() {
            if let observer { NotificationCenter.default.removeObserver(observer) }
            observer = nil
            pending?.cancel()
        }

        private func scheduleUpdate() {
            pending?.cancel()
            let work = DispatchWorkItem { [weak self] in self?.update() }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: work)
        }

        private func update() {
            guard let controller else { return }
            generation += 1
            let current = generation
            let text = controller.text
            Task { [weak self] in
                let body = await Task.detached(priority: .userInitiated) { MarkdownRenderer.body(text) }.value
                guard let self, current == self.generation, let webView = self.webView else { return }
                // JSON-encode the HTML as a JS string literal.
                let literal = String(decoding: try JSONEncoder().encode([body]), as: UTF8.self).dropFirst().dropLast()
                let script = "document.getElementById('content').innerHTML = \(literal);"
                    + MermaidSupport.renderCall
                do {
                    _ = try await webView.evaluateJavaScript(script, contentWorld: .defaultClient)
                } catch {
                    webView.loadHTMLString(MarkdownPage.html(body: body), baseURL: self.baseURL)
                }
            }
        }

        // Links: in-page anchors stay, local files open in Sightline, everything else in the browser.
        func webView(
            _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void
        ) {
            guard navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url else {
                decisionHandler(.allow)
                return
            }
            if url.isFileURL, url.fragment != nil, url.path == baseURL?.path || url.lastPathComponent.isEmpty {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
            if url.isFileURL, openLocalFile(url) { return }
            NSWorkspace.shared.open(url)
        }
    }
}

/// HTML shell + GitHub-like markdown CSS (Primer colors, light and dark).
enum MarkdownPage {
    static func html(body: String) -> String {
        """
        <!doctype html>
        <html><head><meta charset="utf-8">
        <meta name="color-scheme" content="light dark">
        <style>\(css)</style></head>
        <body><article id="content" class="markdown-body">\(body)</article></body></html>
        """
    }

    static let css = """
    :root { --fg:#1f2328; --muted:#59636e; --border:#d1d9e0; --bg:#ffffff; --subtle:#f6f8fa; --accent:#0969da;
      --code-bg:rgba(129,139,152,.12); --add:#1a7f37; --add-bg:#dafbe1; --del:#d1242f; --del-bg:#ffebe9;
      --kw:#cf222e; --str:#0a3069; --com:#59636e; --num:#0550ae; --type:#953800; --fn:#8250df; --tag:#116329; }
    @media (prefers-color-scheme: dark) {
      :root { --fg:#e6edf3; --muted:#9198a1; --border:#3d444d; --bg:#0d1117; --subtle:#151b23; --accent:#4493f8;
        --code-bg:rgba(101,108,118,.2); --add:#3fb950; --add-bg:rgba(46,160,67,.15); --del:#f85149;
        --del-bg:rgba(248,81,73,.1); --kw:#ff7b72; --str:#a5d6ff; --com:#9198a1; --num:#79c0ff; --type:#ffa657;
        --fn:#d2a8ff; --tag:#7ee787; } }
    html { background: var(--bg); }
    body { margin: 0; color: var(--fg); background: var(--bg);
      font: 14px/1.6 -apple-system, BlinkMacSystemFont, "Segoe UI", "Noto Sans", Helvetica, Arial, sans-serif; }
    .markdown-body { max-width: 900px; margin: 0 auto; padding: 24px 32px 64px; word-wrap: break-word; }
    .markdown-body > *:first-child { margin-top: 0; }
    h1, h2, h3, h4, h5, h6 { margin: 24px 0 16px; font-weight: 600; line-height: 1.25; }
    h1 { font-size: 2em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h2 { font-size: 1.5em; padding-bottom: .3em; border-bottom: 1px solid var(--border); }
    h3 { font-size: 1.25em; } h4 { font-size: 1em; } h5 { font-size: .875em; } h6 { font-size: .85em; color: var(--muted); }
    p, blockquote, ul, ol, table, pre, details { margin: 0 0 16px; }
    a { color: var(--accent); text-decoration: none; } a:hover { text-decoration: underline; }
    hr { height: .25em; margin: 24px 0; border: 0; background: var(--border); }
    blockquote { padding: 0 1em; color: var(--muted); border-left: .25em solid var(--border); }
    ul, ol { padding-left: 2em; } li + li { margin-top: .25em; } li > p { margin: 0; }
    ul.tasks { list-style: none; padding-left: 1.2em; } ul.tasks input { margin: 0 .3em 0 -1.2em; vertical-align: middle; }
    code, pre { font: 12.5px/1.45 ui-monospace, SFMono-Regular, Menlo, monospace; }
    code { padding: .2em .4em; border-radius: 6px; background: var(--code-bg); }
    pre { padding: 16px; overflow: auto; border-radius: 6px; background: var(--subtle); }
    pre code { padding: 0; background: none; white-space: pre; }
    table { border-collapse: collapse; display: block; width: max-content; max-width: 100%; overflow: auto; }
    th, td { padding: 6px 13px; border: 1px solid var(--border); }
    th { font-weight: 600; } tr:nth-child(2n) { background: var(--subtle); }
    img { max-width: 100%; }
    .tok-keyword { color: var(--kw); } .tok-string, .tok-code { color: var(--str); }
    .tok-comment { color: var(--com); font-style: italic; } .tok-number, .tok-constant, .tok-key { color: var(--num); }
    .tok-type, .tok-variable { color: var(--type); } .tok-function, .tok-attribute { color: var(--fn); }
    .tok-tag { color: var(--tag); } .tok-heading { color: var(--num); font-weight: 600; }
    .tok-link { color: var(--accent); } .tok-emphasis { font-weight: 600; }
    pre.mermaid { white-space: pre-wrap; color: var(--muted); }
    pre.mermaid.mermaid-error { border-left: 3px solid var(--del); }
    .mermaid-svg { margin: 0 0 16px; text-align: center; overflow: auto; }
    .mermaid-svg svg { max-width: 100%; height: auto; }
    pre.diff code span { display: block; min-height: 1.45em; }
    pre.diff .diff-add { color: var(--add); background: var(--add-bg); }
    pre.diff .diff-del { color: var(--del); background: var(--del-bg); }
    pre.diff .diff-hunk { color: var(--accent); }
    """
}

/// Mermaid diagrams (```mermaid blocks → SVG). The library is bundled (Resources/Vendor/mermaid.min.js,
/// copied into the .app) and injected into the app's isolated content world together with a small render
/// routine. Without the bundle (e.g. `swift run`), diagrams stay as source.
enum MermaidSupport {
    /// For tests: point at the vendored file instead of the app bundle.
    nonisolated(unsafe) static var sourceURLOverride: URL?

    static func librarySource() -> String? {
        let url = sourceURLOverride ?? Bundle.main.url(forResource: "mermaid.min", withExtension: "js")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
    }

    static let renderCall = "\nwindow.__sightlineRenderMermaid && window.__sightlineRenderMermaid();"

    /// Replaces each `pre.mermaid` with its rendered SVG. Errors leave the source visible, with the message
    /// as a tooltip.
    static let bootstrap = """
    (function () {
      if (typeof mermaid === 'undefined') { return; }
      let counter = 0;
      window.__sightlineRenderMermaid = async function () {
        if (!window.__sightlineMermaidReady) {
          const dark = window.matchMedia('(prefers-color-scheme: dark)').matches;
          mermaid.initialize({ startOnLoad: false, securityLevel: 'strict', theme: dark ? 'dark' : 'default' });
          window.__sightlineMermaidReady = true;
        }
        for (const element of document.querySelectorAll('pre.mermaid:not([data-done])')) {
          element.setAttribute('data-done', '1');
          try {
            const { svg } = await mermaid.render('sightline-mermaid-' + (++counter), element.textContent);
            const container = document.createElement('div');
            container.className = 'mermaid-svg';
            container.innerHTML = svg;
            element.replaceWith(container);
          } catch (error) {
            element.classList.add('mermaid-error');
            element.title = String((error && error.message) || error);
          }
        }
        document.documentElement.setAttribute('data-mermaid-rendered', String(counter));
      };
      window.__sightlineRenderMermaid();
    })();
    """

    static func userScripts() -> [WKUserScript] {
        guard let library = librarySource() else { return [] }
        return [library, bootstrap].map {
            WKUserScript(source: $0, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .defaultClient)
        }
    }
}
