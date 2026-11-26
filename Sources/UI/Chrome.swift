import AppKit

/// Right pane: the selected session's open files and artifacts, as editor tabs. The header is the
/// tab strip, then the active tab's buttons: keep, folder tree, and for an artifact reload and
/// open-in-browser. The folder sits beside the page when there's room for both, the way VS Code's
/// explorer does; in a narrow viewer it slides over the page and gets out of the way once you pick a file.
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
    private var rootPath: String?
    private let treeHead = TreeHeader(frame: .zero)
    /// The divider between the folder and the page: drag to resize, double-click for the default.
    private let treeSplit = Splitter(vertical: true)
    /// The file last marked in the tree.
    private var revealed: URL?
    static let treeDefault: CGFloat = 220, treeMin: CGFloat = 140, pageMin: CGFloat = 280
    /// The folder's width, as dragged (saved with the panel layout).
    var treeWidth: CGFloat = ViewerPane.treeDefault { didSet { if treeWidth != oldValue { needsLayout = true } } }
    var onTreeWidth: ((CGFloat?) -> Void)?
    private(set) var tabs = ViewerTabs()
    var item: ViewerItem? { tabs.item }
    private var account: Account?
    /// The folder beside the page: on or off as you set it (⇧⌘T, saved in the config). The window's
    /// width never decides it; the right side widens to keep the page readable instead.
    var showTree = false { didSet { if showTree != oldValue { ensureTree(); needsLayout = true; superview?.needsLayout = true; treeState() } } }
    private var treeShown: Bool { rootPath != nil && showTree }
    /// The least width that fits the folder and a readable page.
    /// The folder as wide as it was dragged, and a readable page: showing the folder widens the right
    /// side by its width instead of squeezing the page.
    var leastWidth: CGFloat { treeShown ? treeWidth + 1 + Self.pageMin : Self.pageMin }
    /// The folder's width in a viewer this wide: as dragged, but never squeezing the page.
    private var treeColumn: CGFloat { max(Self.treeMin, min(treeWidth, bounds.width - 1 - Self.pageMin)) }

    private func treeState() {
        treeButton.isOn = treeShown
        treeButton.tip.text = treeShown ? "Hide the folder" : "Show the folder"
    }

    func toggleTree(save: (Bool) -> Void) { save(!showTree) }

    /// A file picked in the folder: a click previews it, a double-click or ⏎ keeps its tab.
    var onTreeSelect: ((URL, Bool) -> Void)?
    var onTab: ((ViewerTabAction) -> Void)?
    /// ⌥⌘P from the tab's menu: keep the tab, or let the session's next file replace it again.
    var onKeepToggle: (() -> Void)?
    /// The page named itself: the tab takes that title.
    var onArtifactTitle: ((ArtifactLink, String) -> Void)?
    /// Room the panel's own ⋯ and × take at the header's right edge (set by the dock).
    var headerReserve: CGFloat = 52 { didSet { if headerReserve != oldValue { needsLayout = true } } }

    override init(frame: NSRect) {
        super.init(frame: frame)
        name.font = Fonts.mono(Metrics.fontSize)
        name.text = ""
        [viewer.container, empty, strip, treeHead, name, pin, treeButton, reload, external, headerLine, treeLine, treeSplit].forEach(addSubview)
        treeSplit.onDrag = { [weak self] p in
            guard let self else { return }
            let x = self.convert(p, from: nil).x
            self.onTreeWidth?(max(Self.treeMin, min(x, self.bounds.width - 1 - Self.pageMin)))
        }
        treeSplit.onReset = { [weak self] in self?.onTreeWidth?(nil) }
        empty.lines = ["Files the session opens show up here.", "Click a path in the session to open one."]
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
        // VS Code has no keep button: double-click, ⌥⌘P or the tab's menu. The room goes to the tabs.
        pin.isHidden = true
        self.reload.isHidden = item?.artifact == nil
        external.isHidden = item?.artifact == nil
        treeButton.isHidden = rootPath == nil
        treeState()
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
                             detail: (url.path as NSString).abbreviatingWithTildeInPath, preview: tabs.isPreview(i),
                             unseen: tabs.isUnseen(i), kind: kind(url))
            case .artifact(let link, let title):
                let a = account?.name ?? "?"
                return .init(title: title ?? "artifact \(link.id.prefix(8))",
                             detail: "\(link.url.absoluteString)\nSigned in to claude.ai as \(a)", preview: tabs.isPreview(i),
                             unseen: tabs.isUnseen(i), kind: .artifact)
            }
        }
    }

    static func kind(_ url: URL) -> ViewerTabStrip.Kind {
        let ext = url.pathExtension.lowercased()
        if ["md", "markdown", "mdx"].contains(ext) { return .markdown }
        if ext == "pdf" { return .pdf }
        if ["png", "jpg", "jpeg", "gif", "webp", "heic", "svg", "tiff"].contains(ext) { return .image }
        let lang = ViewerController.codeLangs[ext]
        return lang != nil && lang != "plaintext" ? .code : .other
    }

    private func menu(for i: Int) -> NSMenu {
        let m = NSMenu()
        guard tabs.tabs.indices.contains(i) else { return m }
        let send = { [weak self] (a: ViewerTabAction) -> () -> Void in { self?.onTab?(a) } }
        if tabs.isPreview(i) {
            let keep = MenuAction("Keep Open", send(.keep(i)))
            keep.keyEquivalent = "p"; keep.keyEquivalentModifierMask = [.command, .option]
            m.addItem(keep)
        } else if i == tabs.active {
            m.addItem(MenuAction("Let the Session Replace It", { [weak self] in self?.onTab?(.select(i)); self?.onKeepToggle?() }))
        }
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
    var tabsEnd: CGFloat { tabs.tabs.isEmpty ? stripStart : stripStart + strip.usedWidth(in: stripEnd - stripStart) }
    /// With the folder beside the page, the tabs start at its divider, over the page they belong to.
    private var stripStart: CGFloat { treeShown && tree != nil ? treeColumn + 1 : 0 }

    /// The session's folder, for the tree. The tree itself is only built once it shows.
    func setRoot(_ cwd: String?) {
        guard cwd != rootPath else { return }
        rootPath = cwd
        treeButton.isHidden = cwd == nil
        ensureTree()
        treeState()
        needsLayout = true
    }

    private func ensureTree() {
        guard let rootPath, showTree else { tree?.scroll.removeFromSuperview(); tree = nil; return }
        if tree?.root.url.path == rootPath { return }
        tree?.scroll.removeFromSuperview()
        let t = FileTreeController(rootURL: URL(fileURLWithPath: rootPath))
        t.onSelect = { [weak self] url, keep in self?.onTreeSelect?(url, keep) }
        addSubview(t.scroll, positioned: .below, relativeTo: treeLine)
        tree = t
        revealed = nil
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
        let x0Strip = stripStart
        strip.frame = NSRect(x: x0Strip, y: 0, width: max(0, stripEnd - x0Strip), height: h)
        name.frame = .zero
        // The strip draws its own bottom line, open under the active tab.
        let lineFrom = strip.isHidden ? 0 : stripEnd
        headerLine.frame = NSRect(x: lineFrom, y: h - 1, width: w - lineFrom, height: 1)
        treeHead.isHidden = x0Strip == 0
        if x0Strip > 0 {
            addSubview(treeHead, positioned: .above, relativeTo: strip)
            treeHead.title = rootPath.map { ($0 as NSString).lastPathComponent } ?? ""
            treeHead.frame = NSRect(x: 0, y: 0, width: x0Strip, height: h)
        }
        let bodyH = bounds.height - h
        var x0: CGFloat = 0
        treeLine.isHidden = true
        treeSplit.isHidden = true
        if treeShown, let tree {
            // Beside the page, full height, like VS Code's explorer.
            let tw = treeColumn
            tree.scroll.isHidden = false
            tree.scroll.frame = NSRect(x: 0, y: h, width: tw, height: bodyH)
            treeLine.frame = NSRect(x: tw, y: h, width: 1, height: bodyH)
            treeLine.isHidden = false
            treeSplit.isHidden = false
            treeSplit.frame = NSRect(x: tw - 4, y: 0, width: 9, height: bounds.height)
            x0 = tw + 1
        } else {
            tree?.scroll.isHidden = true
        }
        viewer.container.frame = NSRect(x: x0, y: h, width: w - x0, height: bodyH)
        empty.frame = viewer.container.frame
        treeState()
        if let tree, !tree.scroll.isHidden, revealed != item?.file { revealed = item?.file; tree.reveal(item?.file) }
    }
}

/// Title bar: traffic lights (system), tabs of visited sessions, and the three buttons.
final class TitleBar: MXView, TipSource {
    /// A session's tab shows its state; a plain terminal's (no group) a prompt mark.
    struct Tab { var id: SessionID; var title: String; var group: PhaseGroup? }
    var tabs: [Tab] = [] { didSet { needsDisplay = true } }
    var current: SessionID? { didSet { needsDisplay = true } }
    var onSelect: ((SessionID) -> Void)?
    /// A double-click on a tab: the session fills the window, or comes back.
    var onFill: ((SessionID) -> Void)?
    var onCloseTab: ((SessionID) -> Void)?
    let plus = IconButton(.plus, tip: Tip("New session", action: "new-session"))
    let palette = IconButton(.search, tip: Tip("Search sessions, projects and actions", action: "search"))
    let gear = IconButton(.gear, tip: Tip("Settings", action: "settings"))
    /// Show or hide the left and right areas, as in Xcode, VS Code and Cursor.
    let leftToggle = IconButton(.sidebarLeft, tip: Tip("Show or hide the left panels", action: "toggle-left"))
    let rightToggle = IconButton(.sidebarRight, tip: Tip("Show or hide the right panels", action: "toggle-right"))
    private var hoverTab: Int?
    /// Where the buttons on the right begin; the session tabs end before it.
    private var buttonsStart: CGFloat = 0
    /// Room for the traffic lights; full screen hides them, so the tabs start at the edge.
    var fullScreen = false { didSet { needsDisplay = true; needsLayout = true } }
    private var leftInset: CGFloat { (fullScreen ? 8 : 84) + (leftToggle.isHidden ? 0 : 30) }

    override init(frame: NSRect) {
        super.init(frame: frame)
        [leftToggle, plus, palette, gear, rightToggle].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let y = (bounds.height - Metrics.control) / 2
        leftToggle.frame = NSRect(x: fullScreen ? 6 : 80, y: y, width: 26, height: Metrics.control)
        var x = bounds.width - 8
        for b in [rightToggle, gear, palette, plus] where !b.isHidden {
            x -= 28
            b.frame = NSRect(x: x, y: y, width: 26, height: Metrics.control)
        }
        buttonsStart = x
    }

    private func tabRects() -> [NSRect] {
        let avail = buttonsStart - 12 - leftInset
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
            if let g = tab.group {
                Glyph.draw(g, at: NSPoint(x: rr.minX + 16, y: rr.midY), color: t.color(for: g))
            } else {
                Text.draw("❯", in: NSRect(x: rr.minX + 10, y: 0, width: 12, height: rr.height), color: sel ? t.fg : t.fg2, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
            }
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
            let keeps = tab.group == nil ? "The terminal keeps running in the sidebar" : "The session keeps running"
            return (Tip("Close tab", action: tab.id == current ? "close-tab" : nil).adding(keeps), NSRect(x: r.maxX - 22, y: r.minY, width: 22, height: r.height))
        }
        if p.x < r.minX + 26 { return (tab.group?.tip ?? Tip("Terminal"), NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height)) }
        return (Tip(tab.title), NSRect(x: r.minX + 26, y: r.minY, width: r.width - 48, height: r.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = tabRects().firstIndex(where: { $0.contains(p) }) else {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
            return
        }
        if p.x > tabRects()[i].maxX - 22 { onCloseTab?(tabs[i].id) } else if e.clickCount == 2 { onFill?(tabs[i].id) } else { onSelect?(tabs[i].id) }
    }
    override func mouseDragged(with e: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}

/// The folder's name over its column, in the band the tabs sit in.
final class TreeHeader: MXView {
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    override func draw(_ r: NSRect) {
        t.plane.setFill(); bounds.fill()
        t.hair2.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSRect(x: bounds.width - 1, y: 0, width: 1, height: bounds.height).fill()
        // The label style of every panel header ("SLACK 2", "USAGE").
        Text.draw(title.uppercased(), in: NSRect(x: 12, y: 0, width: bounds.width - 24, height: bounds.height - 1), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 2.5, .medium))
    }
}
