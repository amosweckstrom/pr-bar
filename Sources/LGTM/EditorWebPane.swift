import AppKit
import WebKit
import UniformTypeIdentifiers

/// Resolves the vendored `WebAssets` folder in both run modes: the packaged
/// `.app` (copied into Contents/Resources by build-app.sh) and `swift run`
/// during development (SwiftPM's generated resource bundle, `Bundle.module`).
enum EditorAssets {
    static let webRoot: URL? = {
        let fm = FileManager.default
        // 1) Packaged app: Contents/Resources/WebAssets.
        if let main = Bundle.main.resourceURL?.appendingPathComponent("WebAssets"),
           fm.fileExists(atPath: main.appendingPathComponent("tree.html").path) {
            return main
        }
        // 2) Dev (`swift run`): SwiftPM resource bundle via Bundle.module.
        if let mod = Bundle.module.url(forResource: "WebAssets", withExtension: nil),
           fm.fileExists(atPath: mod.appendingPathComponent("tree.html").path) {
            return mod
        }
        return nil
    }()
}

/// Serves the vendored web assets under a custom `app://app/…` scheme. A custom
/// scheme gives the page a real, stable, same-origin URL — unlike `file://`,
/// whose opaque origin makes WebKit reject ES modules, import maps and `fetch()`.
/// Synchronous (reads bundled files), so there is nothing to cancel on `stop`.
final class EditorSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = "app"
    static let host = "app"

    private let webRoot: URL
    init(webRoot: URL) { self.webRoot = webRoot.standardizedFileURL }

    func webView(_ webView: WKWebView, start task: WKURLSchemeTask) {
        guard let url = task.request.url else {
            task.didFailWithError(URLError(.badURL)); return
        }
        var rel = url.path
        if rel.hasPrefix("/") { rel.removeFirst() }
        if rel.isEmpty || rel.hasSuffix("/") { rel += "index.html" }

        let fileURL = webRoot.appendingPathComponent(rel).standardizedFileURL
        // Guard against path traversal escaping the web root.
        guard fileURL.path.hasPrefix(webRoot.path) else {
            task.didFailWithError(URLError(.noPermissionsToReadFile)); return
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            task.didFailWithError(URLError(.fileDoesNotExist)); return
        }

        let headers = [
            "Content-Type": Self.mimeType(for: fileURL),
            "Content-Length": String(data.count),
            "Access-Control-Allow-Origin": "*",
            "Cache-Control": "no-cache",
        ]
        let response = HTTPURLResponse(url: url, statusCode: 200,
                                       httpVersion: "HTTP/1.1", headerFields: headers)!
        task.didReceive(response)
        task.didReceive(data)
        task.didFinish()
    }

    func webView(_ webView: WKWebView, stop task: WKURLSchemeTask) {}

    /// `.js`/`.mjs` MUST be a JavaScript MIME type or WebKit refuses to execute
    /// the module ("disallowed MIME type") — the usual cause of a blank pane.
    static func mimeType(for url: URL) -> String {
        switch url.pathExtension.lowercased() {
        case "js", "mjs": return "text/javascript"
        case "css":       return "text/css"
        case "html", "htm": return "text/html"
        case "json", "map": return "application/json"
        case "wasm":      return "application/wasm"
        case "svg":       return "image/svg+xml"
        default:
            if let t = UTType(filenameExtension: url.pathExtension),
               let m = t.preferredMIMEType { return m }
            return "application/octet-stream"
        }
    }
}

/// An `NSViewController` hosting a `WKWebView` that loads one vendored page
/// (`tree.html` / `diff.html`) over the `app://` scheme, forces a light
/// appearance, and bridges named messages from JS to a callback. Calls into the
/// page are queued until the page's `paneReady` message arrives, so data sent
/// right after construction isn't lost to a navigation race.
final class EditorWebPane: NSViewController, WKNavigationDelegate, WKScriptMessageHandler {

    private(set) var webView: WKWebView!
    private let page: String
    private let messageNames: [String]
    /// (name, body) for every JS → Swift message except the internal `paneReady`.
    var onMessage: ((String, Any) -> Void)?

    private var ready = false
    private var pending: [String] = []   // JS snippets queued until ready

    /// - Parameters:
    ///   - page: the entry file under WebAssets, e.g. "tree.html".
    ///   - messageNames: webkit.messageHandlers names the page posts to.
    init(page: String, messageNames: [String]) {
        self.page = page
        self.messageNames = messageNames
        super.init(nibName: nil, bundle: nil)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) not used") }

    override func loadView() {
        let config = WKWebViewConfiguration()
        if let root = EditorAssets.webRoot {
            config.setURLSchemeHandler(EditorSchemeHandler(webRoot: root),
                                       forURLScheme: EditorSchemeHandler.scheme)
        }
        let ucc = WKUserContentController()
        for name in messageNames + ["paneReady", "lgtmLog"] { ucc.add(self, name: name) }
        config.userContentController = ucc

        let wv = WKWebView(frame: .zero, configuration: config)
        wv.navigationDelegate = self
        wv.appearance = NSAppearance(named: .aqua)   // keep web UI light in Dark Mode
        wv.underPageBackgroundColor = .white          // light backdrop, no dark flash
        wv.translatesAutoresizingMaskIntoConstraints = false
        self.webView = wv

        let container = NSView()
        container.addSubview(wv)
        NSLayoutConstraint.activate([
            wv.topAnchor.constraint(equalTo: container.topAnchor),
            wv.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            wv.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            wv.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        guard EditorAssets.webRoot != nil,
              let entry = URL(string: "\(EditorSchemeHandler.scheme)://\(EditorSchemeHandler.host)/\(page)")
        else { return }
        webView.load(URLRequest(url: entry))
    }

    /// Evaluate JS in the page, queueing until the page signals readiness.
    func callJS(_ js: String) {
        if ready {
            webView.evaluateJavaScript(js, completionHandler: nil)
        } else {
            pending.append(js)
        }
    }

    // MARK: WKScriptMessageHandler
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        if message.name == "paneReady" {
            ready = true
            let queued = pending; pending.removeAll()
            for js in queued { webView.evaluateJavaScript(js, completionHandler: nil) }
            return
        }
        if message.name == "lgtmLog" {
            NSLog("lgtm webview[\(page)]: \(message.body)")
            return
        }
        onMessage?(message.name, message.body)
    }

    // MARK: WKNavigationDelegate
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        NSLog("lgtm: editor pane '\(page)' navigation failed: \(error.localizedDescription)")
    }
}
