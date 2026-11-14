import AppKit
import WebKit

/// A claude.ai artifact in the viewer, signed in to the session's account.
/// One web view at a time, on the account's own data store: each one costs a WebContent process of
/// 200+ MB (claude.ai's pages; measured), so showing another account's artifact closes the previous
/// view, and a view hidden behind a file is let go after a minute. Logins live in the data stores, not the views.
/// Signing in happens right here on claude.ai's own page; Maxwell only draws the strip above it.
final class ArtifactView: MXView, WKNavigationDelegate, WKUIDelegate {
    enum State: Equatable { case idle, loading, ready, signedOut, signingIn, offline, noAccess, failed(String) }

    private(set) var state = State.idle { didSet { if state != oldValue { layoutState(); onState?(state) } } }
    private(set) var link: ArtifactLink?
    private(set) var account: Account?
    /// The page's own title once it has one.
    var onTitle: ((String) -> Void)?
    var onState: ((State) -> Void)?
    /// "Open in browser": the account's browser choice.
    var onOpenExternal: ((URL, Account) -> Void)?

    private var webs: [String: WKWebView] = [:]
    private var lastShown: [String: Date] = [:]
    private var popups: [PopupWindow] = []
    private let card = StateCard(frame: .zero)
    private let strip = SignInStrip(frame: .zero)
    private let progress = Fill { $0.fg3 }
    private var progressWatch: NSKeyValueObservation?
    private var classifyTimer: Timer?
    private var sweep: Timer?
    /// A hidden web view is closed after this long (its WebContent process goes with it).
    static let keepHidden: TimeInterval = 60

    override init(frame: NSRect) {
        super.init(frame: frame)
        [card, strip, progress].forEach(addSubview)
        card.isHidden = true; strip.isHidden = true; progress.isHidden = true
        strip.onCancel = { [weak self] in self?.cancelSignIn() }
        strip.onPaste = { [weak self] in self?.pasteLink() }
        NotificationCenter.default.addObserver(forName: ClaudeWeb.changed, object: nil, queue: .main) { [weak self] n in
            if let name = n.object as? String { self?.accountChanged(name) }
        }
        sweep = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in self?.releaseIdle() }
    }
    required init?(coder: NSCoder) { fatalError() }

    private var web: WKWebView? { account.flatMap { webs[$0.name] } }

    /// Shows `link` as `account`. `reload` re-fetches it even when it is already showing (a republish).
    func show(_ link: ArtifactLink, account: Account, reload: Bool = false) {
        let sameAccount = self.account?.name == account.name
        let same = sameAccount && self.link == link
        self.link = link
        self.account = account
        for (name, other) in webs where name != account.name { close(name, other) }
        let w = webs[account.name] ?? make(account)
        w.isHidden = false
        lastShown[account.name] = Date()
        watchProgress(w)
        if same && !reload && state != .idle { needsLayout = true; return }
        if state == .signingIn && sameAccount && !reload { return }
        load()
    }

    func reload() { load() }

    /// Hidden (another file or nothing in the viewer): web views stay warm for `keepHidden`.
    func hide() {
        if let a = account { lastShown[a.name] = Date() }
    }

    private func load() {
        guard let link, let account, let w = web else { return }
        classifyTimer?.invalidate()
        ClaudeWeb.shared.refresh(account) { [weak self] s in
            guard let self, self.link == link, self.account?.name == account.name else { return }
            if s == .signedOut, self.state != .signingIn { self.state = .signedOut; return }
            self.state = .loading
            w.load(URLRequest(url: link.url))
        }
    }

    private func make(_ a: Account) -> WKWebView {
        let w = WKWebView(frame: bounds, configuration: ClaudeWeb.shared.configuration(a))
        w.navigationDelegate = self
        w.uiDelegate = self
        w.allowsBackForwardNavigationGestures = false
        w.setValue(false, forKey: "drawsBackground")
        addSubview(w, positioned: .below, relativeTo: card)
        webs[a.name] = w
        return w
    }

    private func releaseIdle() {
        guard isHiddenOrHasHiddenAncestor || window == nil else { return }
        for (name, w) in webs where Date().timeIntervalSince(lastShown[name] ?? .distantPast) > Self.keepHidden { close(name, w) }
    }

    private func close(_ name: String, _ w: WKWebView) {
        w.stopLoading()
        w.navigationDelegate = nil
        w.uiDelegate = nil
        w.removeFromSuperview()
        webs[name] = nil
        if name == account?.name { classifyTimer?.invalidate(); state = .idle }
    }

    // MARK: sign in

    func signIn() {
        guard let w = web, let account else { return }
        state = .signingIn
        strip.account = account.name
        strip.email = ClaudeWeb.expectedEmail(account)
        w.load(URLRequest(url: ClaudeWeb.login))
    }

    private func cancelSignIn() {
        guard state == .signingIn else { return }
        popups.forEach { $0.close() }
        load()
    }

    /// A sign-in link from the email, pasted: it has to open in this account's web view, not the browser.
    private func pasteLink() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: s), u.scheme == "https", u.host?.hasSuffix("claude.ai") == true else {
            strip.flash("Copy the link from the sign-in email first.")
            return
        }
        web?.load(URLRequest(url: u))
    }

    private func accountChanged(_ name: String) {
        guard name == account?.name else { return }
        let s = ClaudeWeb.shared.status[name]
        if s == .signedIn, state == .signingIn || state == .signedOut {
            popups.forEach { $0.close() }
            state = .loading
            if let link { web?.load(URLRequest(url: link.url)) }
        } else if s == .signedOut, state == .ready || state == .noAccess {
            state = .signedOut
        }
    }

    func signOut() {
        guard let account else { return }
        ClaudeWeb.shared.signOut(account) { [weak self] in self?.state = .signedOut }
    }

    // MARK: states

    private func layoutState() {
        let a = account?.name ?? "this account"
        let email = account.flatMap(ClaudeWeb.expectedEmail)
        let who = email.map { "\(a) (\($0))" } ?? a
        let external = { [weak self] in
            guard let self, let link = self.link, let account = self.account else { return }
            self.onOpenExternal?(link.url, account)
        }
        strip.isHidden = state != .signingIn
        web?.isHidden = !(state == .ready || state == .loading || state == .signingIn)
        switch state {
        case .signedOut:
            card.show(["Sign in to see this artifact.",
                       "It belongs to \(who).",
                       "You sign in once, on claude.ai's own page."],
                      buttons: [("Sign in to claude.ai", true, { [weak self] in self?.signIn() }), ("Open in browser", false, external)])
        case .offline:
            card.show(["You're offline.", "The artifact loads when the connection is back."],
                      buttons: [("Try again", true, { [weak self] in self?.load() }), ("Open in browser", false, external)])
        case .noAccess:
            card.show(["This account can't open the artifact.",
                       "Signed in to claude.ai as someone other than \(who),",
                       "or the artifact was deleted or never shared with it."],
                      buttons: [("Sign in again", true, { [weak self] in self?.switchAccount() }), ("Open in browser", false, external)])
        case .failed(let why):
            card.show(["The artifact didn't load.", why],
                      buttons: [("Try again", true, { [weak self] in self?.load() }), ("Open in browser", false, external)])
        default:
            card.hide()
        }
        needsLayout = true
    }

    private func switchAccount() {
        guard let account else { return }
        ClaudeWeb.shared.signOut(account) { [weak self] in self?.signIn() }
    }

    private func watchProgress(_ w: WKWebView) {
        progressWatch = w.observe(\.estimatedProgress, options: [.new]) { [weak self] w, _ in
            DispatchQueue.main.async { self?.needsLayout = true }
        }
    }

    override func layout() {
        super.layout()
        let stripH: CGFloat = state == .signingIn ? Metrics.header : 0
        strip.frame = NSRect(x: 0, y: 0, width: bounds.width, height: stripH)
        for w in webs.values { w.frame = NSRect(x: 0, y: stripH, width: bounds.width, height: bounds.height - stripH) }
        card.frame = bounds
        let p = web?.estimatedProgress ?? 1
        progress.isHidden = !(state == .loading || state == .signingIn) || p >= 1 || web?.isLoading != true
        progress.frame = NSRect(x: 0, y: stripH, width: bounds.width * max(0.05, p), height: 1)
    }

    /// claude.ai answers 200 for everything and draws its states in the page, so the page is read once it settles.
    private func classifySoon(_ w: WKWebView) {
        classifyTimer?.invalidate()
        var tries = 0
        classifyTimer = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self, weak w] t in
            guard let self, let w, w === self.web else { return t.invalidate() }
            tries += 1
            let js = "JSON.stringify({p: location.pathname, t: document.title, b: (document.body ? document.body.innerText : '').slice(0, 400), f: document.querySelectorAll('iframe').length})"
            w.evaluateJavaScript(js) { r, _ in
                guard let s = r as? String, let d = s.data(using: .utf8),
                      let o = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return }
                let verdict = ArtifactPage.classify(path: o["p"] as? String ?? "", title: o["t"] as? String ?? "", body: o["b"] as? String ?? "", frames: o["f"] as? Int ?? 0)
                // A page that looks like the artifact is watched a little longer: claude.ai can still swap in its sign-in prompt.
                if let v = verdict { self.apply(v, title: o["t"] as? String); if v != .artifact || tries >= 5 { t.invalidate() } }
                else if tries > 12 { t.invalidate(); self.state = .ready }
            }
        }
    }

    private func apply(_ v: ArtifactPage.Verdict, title: String?) {
        switch v {
        case .artifact:
            state = .ready
            if let t = title?.replacingOccurrences(of: " – Claude", with: "").replacingOccurrences(of: " - Claude", with: ""), !t.isEmpty, t != "Claude" { onTitle?(t) }
        case .signedOut: state = .signedOut
        case .noAccess: state = .noAccess
        case .other: state = .ready
        }
    }

    // MARK: WebKit

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        guard w === web else { return }
        needsLayout = true
        let path = w.url?.path ?? ""
        if state == .signingIn {
            // Back on claude.ai past the login pages: signed in. The cookie watch usually notices first.
            if w.url?.host == "claude.ai", !path.hasPrefix("/login"), !path.hasPrefix("/magic-link"), let account {
                ClaudeWeb.shared.refresh(account)
            }
            return
        }
        classifySoon(w)
    }

    func webView(_ w: WKWebView, didFailProvisionalNavigation n: WKNavigation!, withError e: Error) { failed(w, e) }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { failed(w, e) }

    private func failed(_ w: WKWebView, _ e: Error) {
        guard w === web else { return }
        let ns = e as NSError
        if ns.domain == NSURLErrorDomain, ns.code == NSURLErrorCancelled { return }
        if ns.domain == "WebKitErrorDomain", ns.code == 102 { return }   // frame load interrupted by a policy change
        let offline = [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorCannotFindHost,
                       NSURLErrorCannotConnectToHost, NSURLErrorTimedOut, NSURLErrorDNSLookupFailed, NSURLErrorDataNotAllowed]
        if ns.domain == NSURLErrorDomain, offline.contains(ns.code) { state = .offline } else if state != .signingIn { state = .failed(ns.localizedDescription) }
    }

    func webView(_ w: WKWebView, decidePolicyFor a: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard let u = a.request.url, a.targetFrame?.isMainFrame != false else { return decisionHandler(.allow) }
        // While signing in, claude.ai and the providers it sends to move freely.
        if state == .signingIn { return decisionHandler(.allow) }
        // An artifact link inside the page opens here; any other link the user clicks opens in the account's browser.
        if a.navigationType == .linkActivated {
            if let l = ArtifactLink.parse(u.absoluteString), let account { decisionHandler(.cancel); show(l, account: account); return }
            if let account { decisionHandler(.cancel); onOpenExternal?(u, account); return }
        }
        decisionHandler(.allow)
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        // Google's sign-in is a popup that reports back to claude.ai through window.opener, so it gets a real child view.
        if state == .signingIn {
            let p = PopupWindow(configuration: c, parent: window)
            p.onClose = { [weak self, weak p] in self?.popups.removeAll { $0 === p } }
            popups.append(p)
            return p.web
        }
        if let u = a.request.url, let account {
            if let l = ArtifactLink.parse(u.absoluteString) { show(l, account: account) } else { onOpenExternal?(u, account) }
        }
        return nil
    }

    /// Test hook: WebKit's own snapshot of the page (window captures carry no web content when the screen is locked).
    func snapshot(png: URL, done: @escaping (String) -> Void) {
        guard let w = web, !w.isHidden else { return done("no visible web view (state \(state))") }
        w.takeSnapshot(with: nil) { img, e in
            guard let img, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return done("failed \(String(describing: e))") }
            try? rep.representation(using: .png, properties: [:])?.write(to: png)
            done(png.path)
        }
    }

    /// Test hook: what the artifact view shows.
    func probe(done: @escaping (String) -> Void) {
        guard let w = web else { return done("artifact: no web view, state \(state)") }
        let js = "JSON.stringify({p: location.href, t: document.title, b: (document.body ? document.body.innerText : '').slice(0, 120)})"
        w.evaluateJavaScript(js) { r, _ in done("artifact: state \(self.state) account \(self.account?.name ?? "-") webs \(self.webs.count) page \(r as? String ?? "?")") }
    }
}

/// A window.open from claude.ai's sign-in (Google): its own small window sharing the account's configuration.
final class PopupWindow: NSObject, NSWindowDelegate, WKUIDelegate {
    let web: WKWebView
    private let win: NSWindow
    var onClose: (() -> Void)?

    init(configuration c: WKWebViewConfiguration, parent: NSWindow?) {
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 480, height: 640), configuration: c)
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 640), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        win.isReleasedWhenClosed = false
        win.title = "Sign in"
        win.contentView = web
        win.delegate = self
        web.uiDelegate = self
        if let p = parent { win.setFrameOrigin(NSPoint(x: p.frame.midX - 240, y: p.frame.midY - 320)) } else { win.center() }
        win.makeKeyAndOrderFront(nil)
        titleWatch = web.observe(\.url) { [weak self] w, _ in self?.win.title = w.url?.host ?? "Sign in" }
    }
    private var titleWatch: NSKeyValueObservation?

    func close() { win.close() }
    func webViewDidClose(_ w: WKWebView) { win.close() }
    func windowWillClose(_ n: Notification) { titleWatch = nil; onClose?() }
}

/// The state shown instead of the page: a few lines and buttons, laid out like the viewer's empty state.
final class StateCard: MXView {
    private var lines: [String] = []
    private var buttons: [MXButton] = []

    func show(_ lines: [String], buttons specs: [(String, Bool, () -> Void)]) {
        self.lines = lines
        buttons.forEach { $0.removeFromSuperview() }
        buttons = specs.map { MXButton($0.0, primary: $0.1, action: $0.2) }
        buttons.forEach(addSubview)
        isHidden = false
        needsLayout = true
        needsDisplay = true
    }
    func hide() { isHidden = true; buttons.forEach { $0.removeFromSuperview() }; buttons = [] }

    override func layout() {
        super.layout()
        var x: CGFloat = 16
        let y = 16 + CGFloat(lines.count) * 18 + 10
        for b in buttons {
            let w = b.intrinsicContentSize.width
            b.frame = NSRect(x: x, y: y, width: w, height: Metrics.control)
            x += w + 6
        }
    }

    override func draw(_ r: NSRect) {
        var y: CGFloat = 16
        for (i, l) in lines.enumerated() {
            Text.draw(l, in: NSRect(x: 16, y: y, width: bounds.width - 32, height: 18), color: i == 0 ? t.fg : t.fg3)
            y += 18
        }
    }
    // The page underneath must not get clicks meant for the card.
    override func hitTest(_ p: NSPoint) -> NSView? { isHidden ? nil : (super.hitTest(p) ?? self) }
}

/// Above claude.ai's sign-in page: whose login this is, a way in for emailed links, and Cancel.
final class SignInStrip: MXView {
    var account = "" { didSet { needsDisplay = true } }
    var email: String? { didSet { needsDisplay = true } }
    var onCancel: (() -> Void)?
    var onPaste: (() -> Void)?
    private let paste = MXButton("Paste link", small: true)
    private let cancel = MXButton("Cancel", small: true)
    private let line = Fill { $0.hair2 }
    private var note: String?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [paste, cancel, line].forEach(addSubview)
        paste.action = { [weak self] in self?.onPaste?() }
        paste.tip = Tip("Signing in by email? Copy the link from the email, then click here")
        cancel.action = { [weak self] in self?.onCancel?() }
    }
    required init?(coder: NSCoder) { fatalError() }

    func flash(_ s: String) {
        note = s; needsDisplay = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.note = nil; self?.needsDisplay = true }
    }

    override func layout() {
        super.layout()
        let cw = cancel.intrinsicContentSize.width, pw = paste.intrinsicContentSize.width
        let y = (bounds.height - 18) / 2
        cancel.frame = NSRect(x: bounds.width - cw - 8, y: y, width: cw, height: 18)
        paste.frame = NSRect(x: cancel.frame.minX - pw - 6, y: y, width: pw, height: 18)
        line.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
    }

    override func draw(_ r: NSRect) {
        t.panel.setFill(); bounds.fill()
        let text = note ?? "claude.ai · sign in as \(email ?? account)"
        Text.draw(text, in: NSRect(x: 12, y: 0, width: paste.frame.minX - 18, height: bounds.height), color: note == nil ? t.fg2 : t.on, font: Fonts.mono(Metrics.fontSize - 1))
    }
}

/// Settings › Accounts › Sign in: claude.ai's own login page in a window, on the account's data store.
/// Closes by itself once the account is signed in.
final class SignInWindow: NSObject, NSWindowDelegate, WKUIDelegate, WKNavigationDelegate {
    private static var open: [String: SignInWindow] = [:]
    private let win: NSWindow
    private let web: WKWebView
    private let strip = SignInStrip(frame: .zero)
    private let account: Account
    private var popups: [PopupWindow] = []
    private var watch: NSObjectProtocol?

    static func show(_ a: Account, near parent: NSWindow?) {
        if let w = open[a.name] { w.win.makeKeyAndOrderFront(nil); return }
        open[a.name] = SignInWindow(a, parent: parent)
    }

    private init(_ a: Account, parent: NSWindow?) {
        account = a
        web = WKWebView(frame: .zero, configuration: ClaudeWeb.shared.configuration(a))
        win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 700), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        super.init()
        win.isReleasedWhenClosed = false
        win.title = "Sign in to claude.ai · \(a.name)"
        let root = MXView(frame: NSRect(x: 0, y: 0, width: 520, height: 700))
        strip.account = a.name
        strip.email = ClaudeWeb.expectedEmail(a)
        strip.onCancel = { [weak self] in self?.win.close() }
        strip.onPaste = { [weak self] in self?.paste() }
        strip.frame = NSRect(x: 0, y: 0, width: 520, height: Metrics.header)
        strip.autoresizingMask = [.width]
        web.frame = NSRect(x: 0, y: Metrics.header, width: 520, height: 700 - Metrics.header)
        web.autoresizingMask = [.width, .height]
        root.addSubview(web)
        root.addSubview(strip)
        win.contentView = root
        win.delegate = self
        web.uiDelegate = self
        web.navigationDelegate = self
        if let p = parent { win.setFrameOrigin(NSPoint(x: p.frame.midX - 260, y: p.frame.midY - 350)) } else { win.center() }
        win.makeKeyAndOrderFront(nil)
        web.load(URLRequest(url: ClaudeWeb.login))
        watch = NotificationCenter.default.addObserver(forName: ClaudeWeb.changed, object: a.name, queue: .main) { [weak self] _ in
            if ClaudeWeb.shared.status[a.name] == .signedIn { self?.win.close() }
        }
    }

    private func paste() {
        guard let s = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let u = URL(string: s), u.scheme == "https", u.host?.hasSuffix("claude.ai") == true else {
            return strip.flash("Copy the link from the sign-in email first.")
        }
        web.load(URLRequest(url: u))
    }

    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        if w.url?.host == "claude.ai", let p = w.url?.path, !p.hasPrefix("/login"), !p.hasPrefix("/magic-link") { ClaudeWeb.shared.refresh(account) }
    }

    func webView(_ w: WKWebView, createWebViewWith c: WKWebViewConfiguration, for a: WKNavigationAction, windowFeatures f: WKWindowFeatures) -> WKWebView? {
        let p = PopupWindow(configuration: c, parent: win)
        p.onClose = { [weak self, weak p] in self?.popups.removeAll { $0 === p } }
        popups.append(p)
        return p.web
    }

    func windowWillClose(_ n: Notification) {
        popups.forEach { $0.close() }
        if let watch { NotificationCenter.default.removeObserver(watch) }
        web.stopLoading()
        Self.open[account.name] = nil
    }
}
