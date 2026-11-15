import AppKit

/// Right pane: the selected session's open files and artifacts, as editor tabs. The header is the
/// tab strip, then the active tab's buttons: keep, folder tree, and for an artifact reload and
/// open-in-browser.
final class ViewerPane: MXView {
    let viewer = ViewerController()
    let strip = ViewerTabStrip(frame: .zero)
    private let name = Label(color: { $0.fg3 })
    let pin = IconButton(.pin, tip: Tip("Keep this tab open", action: "pin"))
    let treeButton = IconButton(.tree, tip: Tip("Show the folder", action: "toggle-tree"))
    let reload = IconButton(.reload, tip: Tip("Reload the artifact", action: "reload-artifact"))
    let external = IconButton(.external, tip: Tip("Open in browser", action: "open-in-browser"))
    private let headerLine = Fill { $0.hair2 }
    private let treeLine = Fill { $0.hair2 }
    private let empty = EmptyState(frame: .zero)
    private var tree: FileTreeController?
    private(set) var tabs = ViewerTabs()
    var item: ViewerItem? { tabs.item }
    private var account: Account?
    var showTree = false {
        didSet { needsLayout = true; treeButton.isOn = showTree; treeButton.tip.text = showTree ? "Hide the folder" : "Show the folder" }
    }
    var onTreeSelect: ((URL) -> Void)?
    var onTab: ((ViewerTabAction) -> Void)?
    /// The page named itself: the tab takes that title.
    var onArtifactTitle: ((ArtifactLink, String) -> Void)?
    /// Room the panel's own ⋯ and × take at the header's right edge (set by the dock).
    var headerReserve: CGFloat = 52 { didSet { if headerReserve != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = Fonts.mono(Metrics.fontSize)
        name.text = "viewer"
        [viewer.container, empty, strip, name, pin, treeButton, reload, external, headerLine, treeLine].forEach(addSubview)
        empty.lines = ["Files and artifacts open here by themselves.", "", "When the session writes or names a .md file,", "or publishes a claude.ai artifact, it shows up",
                       "here. ⌘-click a path or an artifact link in the", "terminal to open it."]
        viewer.artifact.onTitle = { [weak self] title in
            guard let self, case .artifact(let l, nil)? = self.item else { return }
            self.onArtifactTitle?(l, title)
        }
        strip.onAction = { [weak self] in self?.onTab?($0) }
        strip.menuFor = { [weak self] in self?.menu(for: $0) ?? NSMenu() }
        show(ViewerTabs(), account: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// `reload`: the session published the artifact on show again.
    func show(_ tabs: ViewerTabs, account: Account?, reload: Bool = false) {
        let item = tabs.item
        let changed = !(item?.same(as: self.item) ?? (self.item == nil)) || account?.name != self.account?.name
        self.tabs = tabs
        self.account = account
        switch item {
        case .file(let url)?:
            if viewer.current != url { viewer.open(url) }
        case .artifact(let link, _)?:
            if let account, changed || reload || viewer.currentArtifact != link { viewer.openArtifact(link, account: account, reload: reload) }
        case nil:
            viewer.clear()
        }
        strip.tabs = Self.stripTabs(tabs, account: account)
        strip.active = tabs.active
        strip.isHidden = tabs.tabs.isEmpty
        name.isHidden = !tabs.tabs.isEmpty
        viewer.container.isHidden = item == nil
        empty.isHidden = item != nil
        let what = item?.artifact != nil ? "artifact" : "file"
        pin.isOn = tabs.kept
        pin.tip.text = tabs.kept
            ? "Kept open\nThe next \(what) the session opens gets a tab of its own. Click to let it replace this one"
            : "Keep this tab open\nNow the next file or artifact the session opens replaces it"
        pin.isHidden = item == nil
        self.reload.isHidden = item?.artifact == nil
        external.isHidden = item?.artifact == nil
        treeButton.isHidden = item?.artifact != nil
        needsLayout = true
        superview?.needsLayout = true
    }

    /// Titles as VS Code shows them: the file name, with its folder when two tabs share a name.
    static func stripTabs(_ tabs: ViewerTabs, account: Account?) -> [ViewerTabStrip.Tab] {
        let names = tabs.tabs.compactMap { $0.file?.lastPathComponent }
        return tabs.tabs.enumerated().map { i, item in
            switch item {
            case .file(let url):
                let n = url.lastPathComponent
                let clash = names.filter { $0 == n }.count > 1
                return .init(title: clash ? "\(n) · \(url.deletingLastPathComponent().lastPathComponent)" : n,
                             detail: (url.path as NSString).abbreviatingWithTildeInPath, preview: tabs.isPreview(i))
            case .artifact(let link, let title):
                let a = account?.name ?? "?"
                return .init(title: title ?? "artifact \(link.id.prefix(8))",
                             detail: "\(link.url.absoluteString)\nSigned in to claude.ai as \(a)", preview: tabs.isPreview(i))
            }
        }
    }

    private func menu(for i: Int) -> NSMenu {
        let m = NSMenu()
        guard tabs.tabs.indices.contains(i) else { return m }
        let send = { [weak self] (a: ViewerTabAction) -> () -> Void in { self?.onTab?(a) } }
        if tabs.isPreview(i) { m.addItem(MenuAction("Keep Open", send(.keep(i)))) }
        m.addItem(MenuAction("Close", send(.close(i))))
        if tabs.tabs.count > 1 {
            m.addItem(MenuAction("Close Others", send(.closeOthers(i))))
            m.addItem(MenuAction("Close All", send(.closeAll)))
        }
        m.addItem(.separator())
        if tabs.tabs[i].artifact != nil {
            m.addItem(MenuAction("Open in Browser", send(.openInBrowser(i))))
            m.addItem(MenuAction("Copy Link", send(.copyPath(i))))
        } else {
            m.addItem(MenuAction("Reveal in Finder", send(.reveal(i))))
            m.addItem(MenuAction("Copy Path", send(.copyPath(i))))
        }
        return m
    }


    /// Where the tabs may run to: up to this tab's buttons, which sit left of the panel's ⋯ and ×.
    var stripEnd: CGFloat { max(0, bounds.width - 4 - headerReserve - CGFloat([pin, treeButton, external, reload].filter { !$0.isHidden }.count) * 26 - 4) }

    /// The empty end of the header, after the last tab: drag it to move the panel.
    var tabsEnd: CGFloat { tabs.tabs.isEmpty ? 12 + Text.width(name.text, font: Fonts.mono()) + 8 : strip.usedWidth(in: stripEnd) }

    func setRoot(_ cwd: String?) {
        guard showTree, let cwd else { tree?.scroll.removeFromSuperview(); tree = nil; return }
        if tree?.root.url.path == cwd { return }
        tree?.scroll.removeFromSuperview()
        let t = FileTreeController(rootURL: URL(fileURLWithPath: cwd))
        t.onSelect = { [weak self] in self?.onTreeSelect?($0) }
        addSubview(t.scroll)
        tree = t
        needsLayout = true
    }

    override func layout() {
        super.layout()
        let w = bounds.width, h = Metrics.header
        // Right to left: the panel's ⋯ and × at the edge, then this tab's buttons, the way an editor's
        // actions follow its tabs. The tabs take the rest.
        var x = w - 4 - headerReserve
        for b in [pin, treeButton, external, reload] where !b.isHidden {
            x -= 26
            b.frame = NSRect(x: x, y: 3, width: 26, height: Metrics.control)
        }
        strip.frame = NSRect(x: 0, y: 0, width: stripEnd, height: h)
        name.frame = NSRect(x: 12, y: 0, width: max(0, stripEnd - 18), height: h)
        // The strip draws its own bottom line, open under the active tab.
        let lineFrom = strip.isHidden ? 0 : stripEnd
        headerLine.frame = NSRect(x: lineFrom, y: h - 1, width: w - lineFrom, height: 1)
        var y = h
        // An artifact is a whole page: the folder doesn't squeeze in above it.
        if showTree, let tree, item?.artifact == nil {
            let th = min(220, bounds.height * 0.4)
            tree.scroll.isHidden = false
            tree.scroll.frame = NSRect(x: 0, y: y, width: w, height: th)
            treeLine.frame = NSRect(x: 0, y: y + th, width: w, height: 1)
            treeLine.isHidden = false
            y += th + 1
        } else {
            tree?.scroll.isHidden = true
            treeLine.isHidden = true
        }
        viewer.container.frame = NSRect(x: 0, y: y, width: w, height: bounds.height - y)
        empty.frame = viewer.container.frame
    }
}

/// Title bar: traffic lights (system), tabs of visited sessions, and the three buttons.
final class TitleBar: MXView, TipSource {
    struct Tab { var id: SessionID; var title: String; var group: PhaseGroup }
    var tabs: [Tab] = [] { didSet { needsDisplay = true } }
    var current: SessionID? { didSet { needsDisplay = true } }
    var onSelect: ((SessionID) -> Void)?
    var onCloseTab: ((SessionID) -> Void)?
    let plus = IconButton(.plus, tip: Tip("New session", action: "new-session"))
    let palette = IconButton(.search, tip: Tip("Search sessions, projects and actions", action: "search"))
    let gear = IconButton(.gear, tip: Tip("Settings", action: "settings"))
    private var hoverTab: Int?
    /// Room for the traffic lights; full screen hides them, so the tabs start at the edge.
    var fullScreen = false { didSet { needsDisplay = true } }
    private var leftInset: CGFloat { fullScreen ? 8 : 84 }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [plus, palette, gear].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = (bounds.height - Metrics.control) / 2
        gear.frame = NSRect(x: bounds.width - 34, y: y, width: 26, height: Metrics.control)
        palette.frame = NSRect(x: bounds.width - 62, y: y, width: 26, height: Metrics.control)
        plus.frame = NSRect(x: bounds.width - 90, y: y, width: 26, height: Metrics.control)
    }

    private func tabRects() -> [NSRect] {
        let avail = bounds.width - leftInset - 100
        guard !tabs.isEmpty, avail > 0 else { return [] }
        let w = min(220, avail / CGFloat(tabs.count))
        return tabs.indices.map { NSRect(x: leftInset + CGFloat($0) * w, y: 0, width: w, height: bounds.height - 1) }
    }

    override func draw(_ r: NSRect) {
        t.hair.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        let rects = tabRects()
        for (i, tab) in tabs.enumerated() {
            let rr = rects[i]
            let sel = tab.id == current
            if sel { t.hover.setFill(); rr.fill() }
            t.hair2.setFill()
            NSRect(x: rr.minX, y: 0, width: 1, height: rr.height).fill()
            if i == tabs.count - 1 { NSRect(x: rr.maxX - 1, y: 0, width: 1, height: rr.height).fill() }
            Glyph.draw(tab.group, at: NSPoint(x: rr.minX + 16, y: rr.midY), color: t.color(for: tab.group))
            let closeW: CGFloat = hoverTab == i ? 18 : 0
            Text.draw(tab.title, in: NSRect(x: rr.minX + 28, y: 0, width: rr.width - 36 - closeW, height: rr.height),
                      color: sel ? t.fg : hoverTab == i ? t.fg2 : t.fg3)
            if hoverTab == i {
                Text.draw("×", in: NSRect(x: rr.maxX - 20, y: 0, width: 14, height: rr.height), color: t.fg3, align: .center)
            }
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = tabRects().firstIndex { $0.contains(p) }
        if i != hoverTab { hoverTab = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverTab = nil; needsDisplay = true }

    /// A tab: the close mark, the state glyph, or the full title (tabs cut long ones short).
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let rects = tabRects()
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return nil }
        let r = rects[i], tab = tabs[i]
        if p.x > r.maxX - 22 {
            return (Tip("Close tab", action: tab.id == current ? "close-tab" : nil).adding("The session keeps running"), NSRect(x: r.maxX - 22, y: r.minY, width: 22, height: r.height))
        }
        if p.x < r.minX + 26 { return (tab.group.tip, NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height)) }
        return (Tip(tab.title), NSRect(x: r.minX + 26, y: r.minY, width: r.width - 48, height: r.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = tabRects().firstIndex(where: { $0.contains(p) }) else {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
            return
        }
        if p.x > tabRects()[i].maxX - 22 { onCloseTab?(tabs[i].id) } else { onSelect?(tabs[i].id) }
    }
    override func mouseDragged(with e: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}

/// Bottom line: counts per state, a transient toast, and the key hints.
final class StatusBar: MXView, TipSource {
    var counts: [(PhaseGroup, Int)] = [] { didSet { needsDisplay = true } }
    /// Where each count was drawn, for its tooltip.
    private var countRects: [(PhaseGroup, Int, NSRect)] = []
    private(set) var toast: String?
    private var toastTimer: Timer?
    /// A toast can carry one action ("Undo"), clickable while the toast shows.
    private(set) var toastAction: (title: String, run: () -> Void)?
    private var actionRect: NSRect?
    /// "v0.1.7 ready · Restart to update", kept on the right until clicked.
    var update: String? { didSet { needsDisplay = true } }
    var onUpdate: (() -> Void)?
    private var updateRect: NSRect?

    func show(toast: String, action: (title: String, run: () -> Void)? = nil, seconds: TimeInterval = 6) {
        self.toast = toast
        toastAction = action
        needsDisplay = true
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.clearToast() }
    }

    private func clearToast() {
        toast = nil; toastAction = nil; actionRect = nil
        needsDisplay = true
    }

    /// Runs the toast's action (the button, or ⌘Z while it shows).
    @discardableResult
    func runToastAction() -> Bool {
        guard let a = toastAction else { return false }
        clearToast()
        a.run()
        return true
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let (g, n, r) = countRects.first(where: { $0.2.contains(p) }) else { return nil }
        return (Tip(g.count(n)).adding(g.meaning), r)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let r = actionRect, r.contains(p) { runToastAction() }
        else if let r = updateRect, r.contains(p) { onUpdate?() }
        else { super.mouseDown(with: e) }
    }

    override func draw(_ r: NSRect) {
        t.hair.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let font = Fonts.mono(Metrics.fontSize - 1)
        var x: CGFloat = 10
        countRects = []
        for (g, n) in counts where n > 0 {
            let x0 = x
            Glyph.draw(g, at: NSPoint(x: x + 4, y: bounds.midY + 0.5), color: t.color(for: g))
            x += 12
            x += Text.draw("\(n)", in: NSRect(x: x, y: 1, width: 40, height: bounds.height - 1), color: [.working, .limited, .idle].contains(g) ? t.fg2 : t.color(for: g), font: Fonts.mono(Metrics.fontSize - 1, .semibold)) + 5
            x += Text.draw(g.title.lowercased(), in: NSRect(x: x, y: 1, width: 200, height: bounds.height - 1), color: t.fg3, font: font)
            countRects.append((g, n, NSRect(x: x0 - 4, y: 0, width: x - x0 + 8, height: bounds.height)))
            x += 16
        }
        if let toast {
            let room = max(0, bounds.width - x - 360)
            let aw = toastAction.map { Text.width($0.title, font: Fonts.mono(Metrics.fontSize - 1, .semibold)) + 16 } ?? 0
            x += Text.draw(toast, in: NSRect(x: x, y: 1, width: max(0, room - aw), height: bounds.height - 1), color: t.safe, font: font) + 8
            if let a = toastAction {
                let r = NSRect(x: x, y: 3, width: aw, height: bounds.height - 6)
                t.hover.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                Text.draw(a.title, in: r, color: t.fg, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
                actionRect = r
                x = r.maxX + 14
            }
        }
        updateRect = nil
        if let update {
            let bold = Fonts.mono(Metrics.fontSize - 1, .semibold)
            let label = "v\(update) ready", button = "Restart to update"
            let bw = Text.width(button, font: bold) + 16
            let r = NSRect(x: bounds.width - bw - 8, y: 3, width: bw, height: bounds.height - 6)
            let lw = Text.width(label, font: font)
            guard r.minX - lw - 10 > x else { return }
            Text.draw(label, in: NSRect(x: r.minX - lw - 8, y: 1, width: lw, height: bounds.height - 1), color: t.safe, font: font)
            t.hover.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            Text.draw(button, in: r, color: t.fg, font: bold, align: .center)
            updateRect = r
            return
        }
        let hints = "J K move · ⏎ open · ⌘N new · ⌘K actions · ⇧⌘X close safe"
        let hw = Text.width(hints, font: font)
        if bounds.width - hw - 10 > x {
            Text.draw(hints, in: NSRect(x: bounds.width - hw - 10, y: 1, width: hw, height: bounds.height - 1), color: t.fg3, font: font)
        }
    }
}
