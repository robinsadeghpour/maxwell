import AppKit

final class FileNode {
    let url: URL
    let isDir: Bool
    private var _children: [FileNode]?
    init(url: URL, isDir: Bool) { self.url = url; self.isDir = isDir }

    // Loaded lazily on expand, so big folders cost nothing until opened.
    var children: [FileNode] {
        if let c = _children { return c }
        let skip: Set<String> = [".git", "node_modules", ".DS_Store", ".next", ".turbo", "zig-out", ".zig-cache"]
        let items = (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: [.isDirectoryKey], options: [])) ?? []
        let c = items.filter { !skip.contains($0.lastPathComponent) }.map {
            FileNode(url: $0, isDir: (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false)
        }.sorted { a, b in
            a.isDir != b.isDir ? a.isDir : a.url.lastPathComponent.localizedStandardCompare(b.url.lastPathComponent) == .orderedAscending
        }
        _children = c
        return c
    }
}

final class FileTreeController: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate {
    let outline = NSOutlineView()
    let scroll = NSScrollView()
    var root: FileNode
    var onSelect: ((URL) -> Void)?

    init(rootURL: URL) {
        root = FileNode(url: rootURL, isDir: true)
        super.init()
        let col = NSTableColumn(identifier: .init("name"))
        outline.addTableColumn(col)
        outline.outlineTableColumn = col
        outline.headerView = nil
        outline.style = .sourceList
        outline.rowHeight = 20
        outline.indentationPerLevel = 12
        outline.backgroundColor = .clear
        outline.dataSource = self
        outline.delegate = self
        scroll.documentView = outline
        scroll.useThinScroller()
    }

    func outlineView(_ o: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
        ((item as? FileNode) ?? root).children.count
    }
    func outlineView(_ o: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
        ((item as? FileNode) ?? root).children[index]
    }
    func outlineView(_ o: NSOutlineView, isItemExpandable item: Any) -> Bool { (item as! FileNode).isDir }

    func outlineView(_ o: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
        let node = item as! FileNode
        let cell = NSTableCellView()
        let icon = NSImageView(image: NSImage(systemSymbolName: node.isDir ? "folder" : "doc", accessibilityDescription: nil)!)
        icon.contentTintColor = .secondaryLabelColor
        let label = NSTextField(labelWithString: node.url.lastPathComponent)
        label.font = .monospacedSystemFont(ofSize: 11.5, weight: .regular)
        label.lineBreakMode = .byTruncatingMiddle
        for v in [icon, label] { v.translatesAutoresizingMaskIntoConstraints = false; cell.addSubview(v) }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
            icon.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
            label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
        ])
        return cell
    }

    func outlineViewSelectionDidChange(_ n: Notification) {
        guard let node = outline.item(atRow: outline.selectedRow) as? FileNode, !node.isDir else { return }
        onSelect?(node.url)
    }
}
