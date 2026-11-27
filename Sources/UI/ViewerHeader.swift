import AppKit

/// The viewer's tabs and buttons. They sit in the title bar, right of the line where the viewer
/// begins (`TitleBar.Docs`), the way an editor group's tabs head its documents: the current
/// session's files and artifacts, then reload for an artifact, the folder, and ⋯ for the rest
/// (keep, open in browser, hide, fill the window).
final class ViewerHeader: MXView {
    let strip = ViewerTabStrip(frame: .zero)
    let treeButton = IconButton(.tree, tip: Tip("Show the folder", action: "toggle-tree"))
    let reload = IconButton(.reload, tip: Tip("Reload the artifact", action: "reload-artifact"))
    let more = IconButton(.more, tip: Tip("Keep, open in browser, hide or fill the window"))
    var onTab: ((ViewerTabAction) -> Void)?
    /// ⌥⌘P from a menu: keep the tab, or let the session's next file replace it again.
    var onKeepToggle: (() -> Void)?
    /// The viewer's panel menu (hide, fill the window), which ⋯ ends with.
    var panelMenu: (() -> NSMenu)?
    /// The session fills the window: only the tab on show, after the line, and no buttons. A click
    /// on it brings the split back.
    var peek = false { didSet { if peek != oldValue { refresh() } } }
    private var tabs = ViewerTabs()
    private var account: Account?
    private var folder = (has: false, shown: false)
    static let button: CGFloat = 28

    override init(frame: NSRect) {
        super.init(frame: frame)
        [strip, treeButton, reload, more].forEach(addSubview)
        strip.onAction = { [weak self] a in
            guard let self else { return }
            self.onTab?(self.peek ? self.tabs.active.map(a.on) ?? a : a)
        }
        strip.menuFor = { [weak self] i in
            guard let self else { return NSMenu() }
            return self.menu(for: self.peek ? self.tabs.active ?? i : i)
        }
        more.action = { [weak self] in self?.showMore() }
    }
    required init?(coder: NSCoder) { fatalError() }

    var hasTabs: Bool { !tabs.tabs.isEmpty }
    /// The least room the row needs: the tab on show whole, ⌄ for the others, and the buttons.
    var leastWidth: CGFloat {
        strip.leastWidth + CGFloat([reload, treeButton, more].filter { !$0.isHidden }.count) * Self.button + 4
    }

    func show(_ tabs: ViewerTabs, account: Account?, hasFolder: Bool, folderShown: Bool) {
        self.tabs = tabs
        self.account = account
        folder = (hasFolder, folderShown)
        refresh()
    }

    private func refresh() {
        let all = Self.stripTabs(tabs, account: account)
        if peek, let a = tabs.active { strip.tabs = [all[a]]; strip.active = 0 } else { strip.tabs = all; strip.active = tabs.active }
        strip.isHidden = tabs.tabs.isEmpty
        reload.isHidden = peek || tabs.item?.artifact == nil
        treeButton.isHidden = peek || !folder.has
        more.isHidden = peek
        treeButton.isOn = folder.shown
        treeButton.tip.text = folder.shown ? "Hide the folder" : "Show the folder"
        needsLayout = true
        superview?.needsLayout = true
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Metrics.control) / 2
        var x = bounds.width
        for b in [more, treeButton, reload] where !b.isHidden {
            x -= Self.button
            b.frame = NSRect(x: x, y: y, width: Self.button, height: Metrics.control)
        }
        strip.frame = NSRect(x: 0, y: 0, width: max(0, x - 4), height: bounds.height)
    }

    /// The empty end of the row moves the window, as the rest of the title bar does.
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
    }
    override var mouseDownCanMoveWindow: Bool { false }

    override func draw(_ r: NSRect) {
        // The tabs draw their own bottom line, open under the active one; the buttons' part has one too.
        t.hair.setFill()
        NSRect(x: strip.isHidden ? 0 : strip.frame.maxX, y: bounds.height - 1, width: bounds.width, height: 1).fill()
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

    /// ⋯: keep or let go of the tab on show, open an artifact in the browser, then the panel's menu.
    private func showMore() {
        let m = NSMenu()
        if let a = tabs.active {
            let send = { [weak self] (x: ViewerTabAction) -> () -> Void in { self?.onTab?(x) } }
            let keep = tabs.isPreview(a) ? MenuAction("Keep Open", send(.keep(a))) : MenuAction("Let the Session Replace It") { [weak self] in self?.onKeepToggle?() }
            keep.keyEquivalent = "p"; keep.keyEquivalentModifierMask = [.command, .option]
            m.addItem(keep)
            if tabs.tabs[a].artifact != nil {
                let open = MenuAction("Open in Browser", send(.openInBrowser(a)))
                open.keyEquivalent = "o"; open.keyEquivalentModifierMask = [.command, .shift]
                m.addItem(open)
            }
            m.addItem(.separator())
        }
        for item in panelMenu?().items ?? [] {
            item.menu?.removeItem(item)
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
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
}
