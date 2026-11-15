import AppKit
import WebKit
import PDFKit
import Quartz

/// Watches one file. Survives atomic saves (write temp + rename), which is how
/// most tools and Claude Code write files: on delete/rename we re-open the path.
final class FileWatcher {
    private var source: DispatchSourceFileSystemObject?
    private let url: URL
    private let onChange: () -> Void
    init(url: URL, onChange: @escaping () -> Void) {
        self.url = url; self.onChange = onChange
        arm()
    }
    private func arm() {
        let fd = open(url.path, O_EVTONLY)
        guard fd >= 0 else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in self?.arm() }
            return
        }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .delete, .rename, .attrib], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            let ev = s.data
            if ev.contains(.delete) || ev.contains(.rename) {
                s.cancel()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { self.arm(); self.onChange() }
            } else {
                self.onChange()
            }
        }
        s.setCancelHandler { close(fd) }
        s.resume()
        source = s
    }
    deinit { source?.cancel() }
}

final class ViewerController: NSObject, WKNavigationDelegate {
    let container = NSView()
    private let body = NSView()
    private var web: WKWebView?
    private var webReady = false
    private var pendingJS: String?
    private var pdf: PDFView?
    private var ql: QLPreviewView?
    private var watcher: FileWatcher?
    private(set) var current: URL?
    /// The artifact on show, when the viewer shows one instead of a file.
    private(set) var currentArtifact: ArtifactLink?
    let artifact = ArtifactView(frame: .zero)
    var onRendered: ((String) -> Void)?
    private var themeJS: String?
    /// A web link clicked in a rendered file: artifacts open beside it, the rest in the browser.
    var onLink: ((URL) -> Void)?
    /// A relative link in a rendered file: it opens in the viewer, as a tab.
    var onFileLink: ((URL) -> Void)?

    override init() {
        super.init()
        body.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(body)
        NSLayoutConstraint.activate([
            body.topAnchor.constraint(equalTo: container.topAnchor),
            body.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            body.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            body.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    private func show(_ v: NSView) {
        for s in body.subviews where s !== v { s.isHidden = true }
        if v.superview == nil {
            v.translatesAutoresizingMaskIntoConstraints = false
            body.addSubview(v)
            NSLayoutConstraint.activate([
                v.topAnchor.constraint(equalTo: body.topAnchor), v.bottomAnchor.constraint(equalTo: body.bottomAnchor),
                v.leadingAnchor.constraint(equalTo: body.leadingAnchor), v.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            ])
        }
        v.isHidden = false
    }

    static let codeLangs: [String: String] = [
        "swift": "swift", "js": "javascript", "mjs": "javascript", "ts": "typescript", "tsx": "typescript", "jsx": "javascript",
        "py": "python", "rb": "ruby", "go": "go", "rs": "rust", "zig": "plaintext", "c": "c", "h": "c", "m": "objectivec",
        "cpp": "cpp", "java": "java", "kt": "kotlin", "sh": "bash", "zsh": "bash", "bash": "bash", "json": "json",
        "yml": "yaml", "yaml": "yaml", "toml": "ini", "html": "xml", "xml": "xml", "css": "css", "sql": "sql", "tsv": "plaintext",
        "csv": "plaintext", "txt": "plaintext", "log": "plaintext",
    ]

    func clear() {
        current = nil
        currentArtifact = nil
        watcher = nil
        artifact.hide()
        for s in body.subviews { s.isHidden = true }
    }

    /// A claude.ai artifact, signed in to `account`. `reload` re-fetches it when it already shows (a republish).
    func openArtifact(_ link: ArtifactLink, account: Account, reload: Bool = false) {
        current = nil
        watcher = nil
        currentArtifact = link
        show(artifact)
        artifact.show(link, account: account, reload: reload)
        onRendered?("artifact")
    }

    /// Markdown and code take their colours and font size from the theme tokens.
    func setTheme(_ t: Theme, fontSize: CGFloat, prose: String = "mono") {
        let vars: [String: Any] = [
            "scheme": t.dark ? "dark" : "light", "fg": t.fg.cssRGBA, "dim": t.fg2.cssRGBA, "faint": t.fg3.cssRGBA,
            "line": t.hair.cssRGBA, "code": t.hover.cssRGBA, "accent": t.chk.cssRGBA, "size": fontSize, "prose": prose,
        ]
        let json = String(data: try! JSONSerialization.data(withJSONObject: vars), encoding: .utf8)!
        themeJS = "setTheme(\(json))"
        if webReady, let web, let js = themeJS { web.evaluateJavaScript(js) }
    }

    func open(_ url: URL) {
        current = url
        currentArtifact = nil
        artifact.hide()
        watcher = nil
        let ext = url.pathExtension.lowercased()
        switch ext {
        case "md", "markdown", "mdx":
            renderText(url, kind: "md", lang: "")
            watcher = FileWatcher(url: url) { [weak self] in self?.renderText(url, kind: "md", lang: "", reload: true) }
        case "pdf":
            let v = pdf ?? { let p = PDFView(); p.autoScales = true; p.displayMode = .singlePageContinuous; p.backgroundColor = .clear; pdf = p; return p }()
            v.document = PDFDocument(url: url)
            show(v)
            body.layoutSubtreeIfNeeded()
            DispatchQueue.main.async { if let first = v.document?.page(at: 0) { v.go(to: first) } }
            onRendered?("pdf")
            watcher = FileWatcher(url: url) { [weak self] in self?.pdf?.document = PDFDocument(url: url) }
        default:
            if let lang = Self.codeLangs[ext] ?? (isText(url) ? "plaintext" : nil) {
                renderText(url, kind: "code", lang: lang)
                watcher = FileWatcher(url: url) { [weak self] in self?.renderText(url, kind: "code", lang: lang, reload: true) }
            } else {
                let v = ql ?? { let q = QLPreviewView(frame: .zero, style: .normal)!; ql = q; return q }()
                v.previewItem = url as NSURL
                show(v)
                onRendered?("quicklook")
            }
        }
    }

    private func isText(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let d = h.readData(ofLength: 8192)
        return !d.contains(0) && String(data: d, encoding: .utf8) != nil
    }

    private func makeWeb() -> WKWebView {
        if let web { return web }
        let cfg = WKWebViewConfiguration()
        cfg.suppressesIncrementalRendering = true
        let w = WKWebView(frame: .zero, configuration: cfg)
        w.setValue(false, forKey: "drawsBackground")
        w.navigationDelegate = self
        let res = Bundle.main.resourceURL!.appendingPathComponent("web")
        w.loadFileURL(res.appendingPathComponent("viewer.html"), allowingReadAccessTo: URL(fileURLWithPath: "/"))
        web = w
        return w
    }

    private func renderText(_ url: URL, kind: String, lang: String, reload: Bool = false) {
        guard current == url else { return }
        guard let data = try? Data(contentsOf: url) else { return }
        let text = String(decoding: data, as: UTF8.self)
        let payload: [String: Any] = ["kind": kind, "lang": lang, "text": text, "base": url.deletingLastPathComponent().path + "/", "reload": reload]
        let json = String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
        let js = "render(\(json))"
        let w = makeWeb()
        show(w)
        if webReady { w.evaluateJavaScript(js) { _, _ in self.onRendered?(kind) } } else { pendingJS = js }
    }

    func webView(_ w: WKWebView, didFinish navigation: WKNavigation!) {
        webReady = true
        if let js = themeJS { w.evaluateJavaScript(js) }
        if let js = pendingJS { pendingJS = nil; w.evaluateJavaScript(js) { _, _ in self.onRendered?("first-web") } }
    }

    /// Test hook: what the page shows (element counts, text, size) and WebKit's own snapshot,
    /// which works while the screen is locked and window captures come back without web content.
    func probe(png: URL, done: @escaping (String) -> Void) {
        guard let web, webReady else { return done("no web view (current: \(current?.lastPathComponent ?? "none"))") }
        let js = "JSON.stringify({h: document.querySelectorAll('h1,h2,h3').length, tables: document.querySelectorAll('table').length, code: document.querySelectorAll('pre code').length, chars: document.body.innerText.length, first: document.body.innerText.slice(0, 80)})"
        web.evaluateJavaScript(js) { r, e in
            let info = "file \(self.current?.lastPathComponent ?? "none") frame \(Int(web.frame.width))x\(Int(web.frame.height)) hidden \(web.isHiddenOrHasHiddenAncestor) dom \(r as? String ?? "error \(String(describing: e))")"
            web.takeSnapshot(with: nil) { img, _ in
                if let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) { try? rep.representation(using: .png, properties: [:])?.write(to: png) }
                done(info + (img == nil ? " · no snapshot" : " · snapshot \(png.path)"))
            }
        }
    }

    // Relative links in Markdown open in this viewer; http(s) goes to the browser.
    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard a.navigationType == .linkActivated, let u = a.request.url else { return decisionHandler(.allow) }
        decisionHandler(.cancel)
        if u.isFileURL { onFileLink?(URL(fileURLWithPath: u.path)) } else { onLink?(u) }
    }
}
