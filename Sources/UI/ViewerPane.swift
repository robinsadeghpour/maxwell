import AppKit

/// Right pane: the selected session's open files and artifacts. Its tabs and buttons are in the
/// title bar (`header`, placed by `TitleBar`), so the page starts right under it. The folder sits
/// beside the page while it is switched on, the way VS Code's explorer does.
final class ViewerPane: MXView {
    let viewer = ViewerController()
    /// The tabs and buttons, shown in the title bar over the pane.
    let header = ViewerHeader(frame: .zero)
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
    var showTree = false { didSet { if showTree != oldValue { ensureTree(); needsLayout = true; superview?.needsLayout = true; showHeader() } } }
    private var treeShown: Bool { rootPath != nil && showTree }
    /// The folder as wide as it was dragged, and a readable page: showing the folder widens the right
    /// side by its width instead of squeezing the page.
    var leastWidth: CGFloat { treeShown ? treeWidth + 1 + Self.pageMin : Self.pageMin }
    /// The folder's width in a viewer this wide: as dragged, but never squeezing the page.
    private var treeColumn: CGFloat { max(Self.treeMin, min(treeWidth, bounds.width - 1 - Self.pageMin)) }

    func toggleTree(save: (Bool) -> Void) { save(!showTree) }

    /// A file picked in the folder: a click previews it, a double-click or ⏎ keeps its tab.
    var onTreeSelect: ((URL, Bool) -> Void)?
    /// The page named itself: the tab takes that title.
    var onArtifactTitle: ((ArtifactLink, String) -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        [viewer.container, empty, treeHead, treeLine, treeSplit].forEach(addSubview)
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
        show(ViewerTabs(), account: nil)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Empty, the viewer still takes the keyboard (⌥⌘3), so ⇧⌘↩ and Esc act on it.
    override var acceptsFirstResponder: Bool { true }

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
        viewer.container.isHidden = item == nil
        empty.isHidden = item != nil
        showHeader()
        needsLayout = true
        superview?.needsLayout = true
    }

    private func showHeader() {
        header.show(tabs, account: account, hasFolder: rootPath != nil, folderShown: treeShown)
    }

    /// The session's folder, for the tree. The tree itself is only built once it shows.
    func setRoot(_ cwd: String?) {
        guard cwd != rootPath else { return }
        rootPath = cwd
        ensureTree()
        showHeader()
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
        let w = bounds.width, h = bounds.height
        var x0: CGFloat = 0
        treeLine.isHidden = true
        treeSplit.isHidden = true
        treeHead.isHidden = true
        if treeShown, let tree {
            // Beside the page, full height, like VS Code's explorer, with the folder's name on top.
            let tw = treeColumn, top = TreeHeader.height
            treeHead.isHidden = false
            treeHead.title = rootPath.map { ($0 as NSString).lastPathComponent } ?? ""
            treeHead.frame = NSRect(x: 0, y: 0, width: tw, height: top)
            tree.scroll.isHidden = false
            tree.scroll.frame = NSRect(x: 0, y: top, width: tw, height: h - top)
            treeLine.frame = NSRect(x: tw, y: 0, width: 1, height: h)
            treeLine.isHidden = false
            treeSplit.isHidden = false
            treeSplit.frame = NSRect(x: tw - 4, y: 0, width: 9, height: h)
            x0 = tw + 1
        } else {
            tree?.scroll.isHidden = true
        }
        viewer.container.frame = NSRect(x: x0, y: 0, width: w - x0, height: h)
        empty.frame = viewer.container.frame
        if let tree, !tree.scroll.isHidden, revealed != item?.file { revealed = item?.file; tree.reveal(item?.file) }
    }
}

/// Its header is in the title bar: there is nothing to drag, and it stays on the right.
extension ViewerPane: PanelContent {
    var gripRect: NSRect { .zero }
    func preferredExtent(along d: Dock) -> CGFloat? { nil }
}

/// The folder's name over its column.
final class TreeHeader: MXView {
    static let height: CGFloat = 24
    var title = "" { didSet { if title != oldValue { needsDisplay = true } } }
    override func draw(_ r: NSRect) {
        t.plane.setFill(); bounds.fill()
        // The label style of every panel header ("SLACK 2", "USAGE").
        Text.draw(title.uppercased(), in: NSRect(x: 12, y: 0, width: bounds.width - 24, height: bounds.height), color: t.fg2, font: Fonts.mono(Metrics.fontSize - 2.5, .medium))
    }
}
