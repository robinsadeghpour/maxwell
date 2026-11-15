import Foundation

/// One session's viewer, as editor tabs: VS Code's model, where a file the session opens by itself
/// lands in the preview tab (italic) and the next one replaces it, and a tab you keep stays.
struct ViewerTabs: Equatable {
    var tabs: [ViewerItem] = []
    /// Showing a tab also files it as the most recent one and marks it seen.
    var active: Int? {
        didSet {
            guard let i = item else { return }
            recent.removeAll { $0.same(as: i) }
            recent.append(i)
            if recent.count > 30 { recent.removeFirst(recent.count - 30) }
            unseen.removeAll { $0.same(as: i) }
        }
    }
    /// The tab the next file or artifact the session opens replaces. nil: every tab is kept.
    var preview: Int?
    /// The transcript was read once for the last file or artifact.
    var scanned = false
    /// Tabs shown, oldest first: closing the active tab goes back to the one before, as VS Code does.
    private(set) var recent: [ViewerItem] = []
    /// Tabs that got something new behind your back (a new file in the preview tab, a republish).
    private(set) var unseen: [ViewerItem] = []

    init(tabs: [ViewerItem] = [], active: Int? = nil, preview: Int? = nil) {
        self.tabs = tabs
        self.preview = preview
        self.active = active
    }

    var item: ViewerItem? { active.flatMap { tabs.indices.contains($0) ? tabs[$0] : nil } }
    /// The active tab stays when the session opens something else.
    var kept: Bool { active != nil && active != preview }
    func index(of item: ViewerItem) -> Int? { tabs.firstIndex { $0.same(as: item) } }
    func isPreview(_ i: Int) -> Bool { preview == i }
    func isUnseen(_ i: Int) -> Bool { tabs.indices.contains(i) && unseen.contains { $0.same(as: tabs[i]) } }

    /// The session published again what a tab in the background shows: the tab says so.
    mutating func updated(_ item: ViewerItem) {
        guard let i = index(of: item), i != active, !isUnseen(i) else { return }
        unseen.append(tabs[i])
    }

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
        var landed: Int
        if let i = index(of: item) {
            retitle(i, from: item)
            landed = i
        } else if let p = preview {
            unseen.removeAll { $0.same(as: tabs[p]) }
            tabs[p] = item
            landed = p
        } else {
            tabs.append(item)
            preview = tabs.count - 1
            landed = tabs.count - 1
        }
        if front { active = landed } else if landed != active, !isUnseen(landed) { unseen.append(tabs[landed]) }
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

    /// ⌥⌘→ and ⌥⌘←: the next or previous tab, round the end.
    mutating func step(_ d: Int) {
        guard !tabs.isEmpty else { return }
        active = ((active ?? 0) + d + tabs.count) % tabs.count
    }

    /// Double-click a preview tab, or the pin: it stays when the session opens something else.
    mutating func keep(_ i: Int) { if preview == i { preview = nil } }

    /// The pin on the active tab: kept becomes the preview tab again (the old preview tab closes).
    mutating func toggleKeep() {
        guard let a = active else { return }
        if preview == a { preview = nil; return }
        if let p = preview { close(p) }
        preview = active
    }

    /// Closing the active tab goes back to the tab you had open before it (its neighbour if none).
    mutating func close(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let gone = tabs.remove(at: i)
        recent.removeAll { $0.same(as: gone) }
        unseen.removeAll { $0.same(as: gone) }
        if let p = preview { preview = p == i ? nil : p > i ? p - 1 : p }
        guard let a = active else { return }
        if tabs.isEmpty { active = nil }
        else if a > i { active = a - 1 }
        else if a == i { active = recent.reversed().lazy.compactMap(index(of:)).first ?? min(i, tabs.count - 1) }
    }

    mutating func closeOthers(_ i: Int) {
        guard tabs.indices.contains(i) else { return }
        let keepItem = tabs[i]
        tabs = [keepItem]
        preview = preview == i ? 0 : nil
        recent = []; unseen = []
        active = 0
    }

    mutating func closeAll() { tabs = []; active = nil; preview = nil; recent = []; unseen = [] }

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

    // MARK: kept across restarts

    /// What Maxwell writes down for a session's tabs: paths and artifact links, which tab shows,
    /// which is the preview tab. Files that are gone by the next launch are left out.
    struct Saved: Codable, Equatable {
        var items: [String]
        var titles: [String?]
        var active: Int?
        var preview: Int?
    }

    var saved: Saved {
        Saved(items: tabs.map { $0.file?.path ?? $0.artifact?.url.absoluteString ?? "" },
              titles: tabs.map { if case .artifact(_, let t) = $0 { return t }; return nil },
              active: active, preview: preview)
    }

    init(_ s: Saved, fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        var tabs: [ViewerItem] = [], map: [Int: Int] = [:]
        for (i, raw) in s.items.enumerated() {
            let item: ViewerItem?
            if raw.hasPrefix("/") { item = fileExists(raw) ? .file(URL(fileURLWithPath: raw)) : nil }
            else { item = ArtifactLink.parse(raw).map { .artifact($0, title: s.titles.indices.contains(i) ? s.titles[i] : nil) } }
            if let item { map[i] = tabs.count; tabs.append(item) }
        }
        let active = s.active.flatMap { map[$0] } ?? (tabs.isEmpty ? nil : 0)
        self.init(tabs: tabs, active: active, preview: s.preview.flatMap { map[$0] })
    }
}

/// Every session's tabs, in UserDefaults: the 200 sessions whose tabs changed last.
struct SavedViewerTabs: Codable {
    struct Entry: Codable { var tabs: ViewerTabs.Saved; var at: Date }
    var entries: [String: Entry] = [:]
    static let key = "Maxwell.viewerTabs"

    static func load(_ d: UserDefaults = .standard) -> SavedViewerTabs {
        d.data(forKey: key).flatMap { try? JSONDecoder().decode(SavedViewerTabs.self, from: $0) } ?? SavedViewerTabs()
    }
    func tabs(_ id: String) -> ViewerTabs.Saved? { entries[id]?.tabs }
    mutating func set(_ id: String, _ t: ViewerTabs.Saved) {
        if entries[id]?.tabs == t { return }
        if t.items.isEmpty { entries[id] = nil } else { entries[id] = Entry(tabs: t, at: Date()) }
        if entries.count > 200 {
            for (k, _) in entries.sorted(by: { $0.value.at < $1.value.at }).prefix(entries.count - 200) { entries[k] = nil }
        }
    }
    func save(_ d: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { d.set(data, forKey: Self.key) }
    }
}
