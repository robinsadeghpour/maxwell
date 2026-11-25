import AppKit
import CoreServices

/// One file or folder in the tree. A folder reads its children when first opened, and again when
/// it changes on disk.
final class FileNode {
    let url: URL
    let isDir: Bool
    private var _children: [FileNode]?
    init(url: URL, isDir: Bool) { self.url = url; self.isDir = isDir }

    static let skip: Set<String> = [".git", "node_modules", ".DS_Store", ".next", ".turbo", "zig-out", ".zig-cache"]

    var loaded: Bool { _children != nil }
    var children: [FileNode] {
        if let c = _children { return c }
        let c = Self.read(url, keeping: [])
        _children = c
        return c
    }

    /// Reads the folder again. Entries still there keep their nodes, so open folders stay open.
    /// Returns whether anything was added or removed.
    @discardableResult
    func reload() -> Bool {
        guard let old = _children else { return false }
        let fresh = Self.read(url, keeping: old)
        _children = fresh
        return fresh.map(\.url) != old.map(\.url)
    }

    private static func read(_ url: URL, keeping old: [FileNode]) -> [FileNode] {
        let items = (try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let byURL = Dictionary(old.map { ($0.url.standardizedFileURL, $0) }, uniquingKeysWith: { a, _ in a })
        return items.filter { !skip.contains($0.lastPathComponent) }.map { u in
            byURL[u.standardizedFileURL] ?? FileNode(url: u, isDir: (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
    }
}

/// The session's folder beside the viewer's page, the way VS Code's explorer and JetBrains'
/// Project view work: a click previews a file, a double-click or ⏎ keeps its tab, a click on a
/// folder opens or closes it. It follows the disk: files Claude writes appear as they land.
final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
    let outline = TreeOutline()
    let scroll = NSScrollView()
    var root: FileNode
    /// A file picked: `keep` is a double-click or ⏎, a plain click previews.
    var onSelect: ((URL, Bool) -> Void)?
    private var watcher: FolderWatcher?
    /// Paths git ignores, shown dimmed as VS Code does.
    private var ignored = GitIgnored()

    init(rootURL: URL) {
        root = FileNode(url: rootURL, isDir: true)
        super.init()
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .plain
        outline.rowHeight = 22
        outline.intercellSpacing = .zero
        outline.indentationPerLevel = 0
        outline.backgroundColor = .clear
        outline.focusRingType = .none
        outline.dataSource = self
        outline.delegate = self
        outline.target = self
        outline.action = #selector(clicked)
        outline.doubleAction = #selector(doubleClicked)
        outline.onReturn = { [weak self] in self?.openSelected() }
        outline.menu = NSMenu()
        outline.menu?.delegate = self
        scroll.documentView = outline
        scroll.drawsBackground = false
        scroll.useThinScroller()
        watcher = FolderWatcher(root: rootURL) { [weak self] paths in self?.changed(paths) }
        refreshIgnored()
    }

    // MARK: data

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int { ((item as? FileNode) ?? root).children.count }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any { ((item as? FileNode) ?? root).children[index] }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! FileNode).isDir }
    func outlineView(_ o: NSOutlineView, typeSelectStringFor tableColumn: NSTableColumn?, item: Any) -> String? { (item as? FileNode)?.url.lastPathComponent }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! FileNode
        let cell = (o.makeView(withIdentifier: FileCell.id, owner: nil) as? FileCell) ?? FileCell()
        cell.node = node
        cell.level = o.level(forItem: node)
        cell.expanded = o.isItemExpanded(node)
        cell.dimmed = ignored.contains(node.url, under: root.url)
        cell.needsDisplay = true
        return cell
    }

    func outlineView(_ o: NSOutlineView, rowViewForItem item: Any) -> NSTableRowView? { TreeRow() }

    func outlineViewItemDidExpand(_ n: Notification) { redrawChevron(n) }
    func outlineViewItemDidCollapse(_ n: Notification) { redrawChevron(n) }
    private func redrawChevron(_ n: Notification) {
        guard let node = n.userInfo?["NSObject"] as? FileNode else { return }
        let row = outline.row(forItem: node)
        if row >= 0, let c = outline.view(atColumn: 0, row: row, makeIfNecessary: false) as? FileCell { c.expanded = outline.isItemExpanded(node); c.needsDisplay = true }
    }

    // MARK: picking

    private var revealing = false
    private var clickedNode: FileNode? { outline.clickedRow >= 0 ? outline.item(atRow: outline.clickedRow) as? FileNode : nil }

    @objc private func clicked() {
        guard let node = clickedNode else { return }
        if node.isDir { toggle(node) } else { onSelect?(node.url, false) }
    }
    @objc private func doubleClicked() {
        guard let node = clickedNode, !node.isDir else { return }
        onSelect?(node.url, true)
    }
    private func openSelected() {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode else { return }
        if node.isDir { toggle(node) } else { onSelect?(node.url, true) }
    }
    private func toggle(_ node: FileNode) {
        if outline.isItemExpanded(node) { outline.collapseItem(node) } else { outline.expandItem(node) }
    }

    /// Marks the file on show in the tree: its folders open and its row selected (opening nothing).
    func reveal(_ url: URL?) {
        revealing = true
        defer { revealing = false }
        guard let url, url.path.hasPrefix(root.url.path + "/") else { outline.deselectAll(nil); return }
        var node = root
        let parts = url.path.dropFirst(root.url.path.count + 1).split(separator: "/").map(String.init)
        for (i, name) in parts.enumerated() {
            guard let next = node.children.first(where: { $0.url.lastPathComponent == name }) else { outline.deselectAll(nil); return }
            if i < parts.count - 1 { outline.expandItem(next) }
            node = next
        }
        let row = outline.row(forItem: node)
        guard row >= 0 else { return }
        outline.selectRowIndexes([row], byExtendingSelection: false)
        // In the middle of the view, once the tree has its size.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let clip = self.scroll.contentView
            let r = self.outline.rect(ofRow: row)
            guard !clip.documentVisibleRect.insetBy(dx: 0, dy: 22).contains(r) else { return }
            let y = max(0, min(r.midY - clip.bounds.height / 2, self.outline.bounds.height - clip.bounds.height))
            clip.scroll(to: NSPoint(x: 0, y: y))
            self.scroll.reflectScrolledClipView(clip)
        }
    }

    func collapseAll() { outline.collapseItem(nil, collapseChildren: true) }

    // MARK: the disk

    /// Folders that changed on disk: read again those the tree has open, keeping what is selected.
    private func changed(_ paths: [String]) {
        var nodes: [FileNode] = []
        func walk(_ n: FileNode) {
            guard n.isDir, n.loaded else { return }
            if paths.contains(where: { $0 == n.url.path || $0 == n.url.path + "/" }) { nodes.append(n) }
            n.children.forEach(walk)
        }
        walk(root)
        let selected = outline.item(atRow: outline.selectedRow) as? FileNode
        for n in nodes where n.reload() { outline.reloadItem(n === root ? nil : n, reloadChildren: true) }
        if let selected { let r = outline.row(forItem: selected); if r >= 0 { revealing = true; outline.selectRowIndexes([r], byExtendingSelection: false); revealing = false } }
        if paths.contains(where: { $0.hasSuffix(".gitignore") || $0.hasPrefix(root.url.path + "/.gitignore") }) || !nodes.isEmpty { refreshIgnored() }
    }

    private func refreshIgnored() {
        let rootPath = root.url.path
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = GitIgnored.read(rootPath)
            DispatchQueue.main.async {
                guard let self, found != self.ignored else { return }
                self.ignored = found
                self.outline.reloadData()
            }
        }
    }

    // MARK: menu

    func menuNeedsUpdate(_ m: NSMenu) {
        m.removeAllItems()
        guard let node = clickedNode else { return }
        if !node.isDir { m.addItem(MenuAction("Open in a Tab") { [weak self] in self?.onSelect?(node.url, true) }) }
        m.addItem(MenuAction("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([node.url]) })
        m.addItem(MenuAction("Copy Path") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(node.url.path, forType: .string)
        })
        m.addItem(.separator())
        m.addItem(MenuAction("Collapse All") { [weak self] in self?.collapseAll() })
    }
}

/// The tree's outline view: no system disclosure triangles (each row draws its own chevron), and ⏎
/// opens what is selected.
final class TreeOutline: NSOutlineView {
    var onReturn: (() -> Void)?
    override func frameOfOutlineCell(atRow row: Int) -> NSRect { .zero }
    override func keyDown(with e: NSEvent) {
        if e.keyCode == 36 || e.keyCode == 76 || e.characters == " " { onReturn?() } else { super.keyDown(with: e) }
    }
}

/// A row's background: the theme's hover and selection, as in the session list.
final class TreeRow: NSTableRowView {
    private var hover = false
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
    }
    override func mouseEntered(with e: NSEvent) { hover = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hover = false; needsDisplay = true }
    override func drawBackground(in r: NSRect) {
        guard hover, !isSelected else { return }
        Look.theme.hover.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
    override func drawSelection(in r: NSRect) {
        Look.theme.rowSel.setFill()
        NSBezierPath(roundedRect: bounds.insetBy(dx: 4, dy: 1), xRadius: 4, yRadius: 4).fill()
    }
    override var isEmphasized: Bool { get { false } set {} }
}

/// One row: a thin line for each folder level it sits in, a chevron on folders, the file's kind,
/// its name (dimmed when git ignores it).
final class FileCell: NSView {
    static let id = NSUserInterfaceItemIdentifier("file")
    static let indent: CGFloat = 12
    var node: FileNode?
    var level = 0
    var expanded = false
    var dimmed = false
    override var isFlipped: Bool { true }
    init() { super.init(frame: .zero); identifier = Self.id }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(_ r: NSRect) {
        guard let node else { return }
        let t = Look.theme
        let midY = bounds.midY
        t.hair.setFill()
        for l in 0..<level { NSRect(x: 14 + CGFloat(l) * Self.indent, y: 0, width: 1, height: bounds.height).fill() }
        var x = 8 + CGFloat(level) * Self.indent
        let ink = dimmed ? t.fg3 : t.fg2
        if node.isDir {
            let p = NSBezierPath()
            p.lineWidth = 1.2; p.lineCapStyle = .round; p.lineJoinStyle = .round
            let c = NSPoint(x: x + 6, y: midY)
            if expanded {
                p.move(to: NSPoint(x: c.x - 3, y: c.y - 1.5)); p.line(to: NSPoint(x: c.x, y: c.y + 1.5)); p.line(to: NSPoint(x: c.x + 3, y: c.y - 1.5))
            } else {
                p.move(to: NSPoint(x: c.x - 1.5, y: c.y - 3)); p.line(to: NSPoint(x: c.x + 1.5, y: c.y)); p.line(to: NSPoint(x: c.x - 1.5, y: c.y + 3))
            }
            t.fg3.setStroke(); p.stroke()
        }
        x += 14
        ViewerTabStrip.drawKind(node.isDir ? nil : ViewerPane.kind(node.url), at: NSPoint(x: x + 6, y: midY), color: ink)
        x += 17
        let name = node.url.lastPathComponent
        Text.draw(name, in: NSRect(x: x, y: 0, width: max(0, bounds.width - x - 6), height: bounds.height),
                  color: dimmed ? t.fg3 : t.fg, font: Fonts.mono(Metrics.fontSize - 0.5))
    }
}

/// FSEvents on a folder: reports the folders whose entries changed, a moment after they settle.
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let onChange: ([String]) -> Void

    init(root: URL, onChange: @escaping ([String]) -> Void) {
        self.onChange = onChange
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = (unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []).prefix(count)
            let skip = FileNode.skip
            let dirs = list.filter { p in !p.split(separator: "/").contains { skip.contains(String($0)) } }
            if !dirs.isEmpty { me.onChange(dirs.map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }) }
        }
        stream = FSEventStreamCreate(nil, cb, &ctx, [root.path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagUseCFTypes))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, .main)
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream { FSEventStreamStop(stream); FSEventStreamInvalidate(stream); FSEventStreamRelease(stream) }
    }
}
