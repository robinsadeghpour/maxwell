import Foundation

/// One session's viewer, as editor tabs: VS Code's model, where a file the session opens by itself
/// lands in the preview tab (italic) and the next one replaces it, and a tab you keep stays.
struct ViewerTabs: Equatable {
    var tabs: [ViewerItem] = []
    var active: Int?
    /// The tab the next file or artifact the session opens replaces. nil: every tab is kept.
    var preview: Int?
    /// The transcript was read once for the last file or artifact.
    var scanned = false

    var item: ViewerItem? { active.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
    /// The active tab stays when the session opens something else.
    var kept: Bool { active != nil && active != preview }
    func index(of item: ViewerItem) -> Int? { tabs.firstIndex { $0.same(as: item) } }
    func isPreview(_ i: Int) -> Bool { preview == i }

    /// You opened it (⌘-click, a link, the tree with `keep: false`): it shows now.
    /// `keep: false` puts it in the preview tab instead of a tab of its own.
    mutating func open(_ item: ViewerItem, keep: Bool) {
        if let i = index(of: item) {
            retitle(i, from: item)
            if keep, preview == i { preview = nil }
            active = i
            return
        }
        if !keep, let p = preview {
            tabs[p] = item
            active = p
            return
        }
        let at = active.map { $0 + 1 } ?? tabs.count
        tabs.insert(item, at: at)
        if let p = preview, p >= at { preview = p + 1 }
        if !keep { preview = at }
        active = at
    }

    /// The session wrote, named or published it. It goes in the preview tab, and comes to the front
    /// unless you are reading a tab you kept: then it waits behind it.
    /// Returns whether the active tab changed.
    @discardableResult
    mutating func sessionOpened(_ item: ViewerItem) -> Bool {
        let before = self.item
        let front = active == nil || active == preview
        if let i = index(of: item) {
            retitle(i, from: item)
            if front { active = i }
        } else if let p = preview {
            tabs[p] = item
            if front { active = p }
        } else {
            tabs.append(item)
            preview = tabs.count - 1
            if front { active = preview }
        }
        return !(self.item?.same(as: before) ?? (before == nil))
    }

    /// A title only fills in a tab that had none; the page's own title wins over the transcript's.
    mutating func retitle(_ i: Int, from item: ViewerItem) {
        if case .artifact(let l, let t?) = item, case .artifact(_, nil) = tabs[i] { tabs[i] = .artifact(l, title: t) }
    }

    mutating func setTitle(_ title: String, for link: ArtifactLink) {
        for i in tabs.indices { if case .artifact(let l, nil) = tabs[i], l == link { tabs[i] = .artifact(l, title: title) } }
    }

    mutating func select(_ i: Int) { if tabs.indices.contains(i) { active = i } }

    /// Double-click a preview tab, or the pin: it stays when the session opens something else.
    mutating func keep(_ i: Int) { if preview == i { preview = nil } }

    /// The pin on the active tab: kept becomes the preview tab again (the old preview tab closes).
    mutating func toggleKeep() {
        guard let a = active else { return }
        if preview == a { preview = nil; return }
        if let p = preview { close(p) }
        preview = active
    }

    /// Closing the active tab shows its right neighbour, or the left one at the end.
    mutating func close(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        tabs.remove(at: i)
        if let p = preview { preview = p == i ? nil : p > i ? p - 1 : p }
        guard let a = active else { return }
        if tabs.isEmpty { active = nil }
        else if a > i { active = a - 1 }
        else if a == i { active = min(i, tabs.count - 1) }
    }

    mutating func closeOthers(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let keepItem = tabs[i]
        tabs = [keepItem]
        preview = preview == i ? 0 : nil
        active = 0
    }

    mutating func closeAll() { tabs = []; active = nil; preview = nil }

    /// Drag a tab to another place in the strip.
    mutating func move(_ from: Int, to: Int) {
        guard tabs.indices.contains(from), from != to else { return }
        let to = max(0, min(tabs.count - 1, to))
        var order = Array(tabs.indices)
        order.remove(at: from)
        order.insert(from, at: to)
        tabs = order.map { tabs[$0] }
        let remap = { (old: Int?) in old.flatMap { o in order.firstIndex(of: o) } }
        active = remap(active)
        preview = remap(preview)
    }
}
