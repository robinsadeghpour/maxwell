import Foundation

/// The viewer's tabs: VS Code's preview tab for what the session opens, tabs of their own for what you open.
func viewerTabsTests() {
    let a = ViewerItem.file(URL(fileURLWithPath: "/p/a.md")), b = ViewerItem.file(URL(fileURLWithPath: "/p/b.md"))
    let c = ViewerItem.file(URL(fileURLWithPath: "/p/c.md")), d = ViewerItem.file(URL(fileURLWithPath: "/q/a.md"))

    var v = ViewerTabs()
    v.sessionOpened(a)
    check(v.tabs == [a] && v.active == 0 && v.preview == 0, "the session's first file opens in the preview tab")
    v.sessionOpened(b)
    check(v.tabs == [b] && v.active == 0 && v.preview == 0, "its next file replaces the preview tab")
    v.keep(0)
    check(v.preview == nil && v.kept, "double-click keeps the tab")
    let moved = v.sessionOpened(c)
    check(v.tabs == [b, c] && v.active == 0 && v.preview == 1 && !moved, "reading a kept tab: the next file waits in a new preview tab behind it")
    v.select(1)
    v.sessionOpened(a)
    check(v.tabs == [b, a] && v.active == 1, "in front on the preview tab: the next file replaces it and shows")
    v.sessionOpened(b)
    check(v.tabs == [b, a] && v.active == 0, "a file that already has a tab: that tab comes to the front")

    var w = ViewerTabs()
    w.open(a, keep: true)
    w.open(b, keep: true)
    check(w.tabs == [a, b] && w.active == 1 && w.preview == nil, "⌘-click opens a tab of its own")
    w.select(0)
    w.open(c, keep: false)
    check(w.tabs == [a, c, b] && w.active == 1 && w.preview == 1, "the tree opens a preview tab next to the active one")
    w.open(d, keep: false)
    check(w.tabs == [a, d, b] && w.preview == 1, "browsing the tree reuses the preview tab")
    w.open(d, keep: true)
    check(w.preview == nil && w.tabs.count == 3, "opening the preview tab's file for real keeps it")

    w.close(1)
    check(w.tabs == [a, b] && w.active == 0, "closing the active tab goes back to the one shown before it")
    w.select(1)
    w.close(1)
    check(w.tabs == [a] && w.active == 0, "and again")
    w.close(0)
    check(w.tabs.isEmpty && w.active == nil && w.item == nil, "closing the last tab empties the viewer")

    var m = ViewerTabs(tabs: [a, b, c], active: 2, preview: 0)
    m.move(2, to: 0)
    check(m.tabs == [c, a, b] && m.active == 0 && m.preview == 1, "dragging a tab keeps which one is active and which is the preview")
    m.close(0)
    check(m.tabs == [a, b] && m.active == 0 && m.preview == 0, "closing before the preview tab shifts it")
    m.select(1)
    m.toggleKeep()
    check(m.tabs == [b] && m.preview == 0 && m.active == 0, "un-keeping a tab makes it the preview tab; the old preview tab closes")
    m.toggleKeep()
    check(m.preview == nil && m.kept, "the pin keeps it again")

    var u = ViewerTabs()
    u.open(a, keep: true)
    u.sessionOpened(b)
    check(u.active == 0 && u.isUnseen(1) && !u.isUnseen(0), "a file that waits behind a kept tab is marked new")
    u.sessionOpened(c)
    check(u.tabs == [a, c] && u.isUnseen(1), "and stays marked when the next one replaces it")
    u.select(1)
    check(!u.isUnseen(1), "showing the tab clears the mark")
    u.select(0)
    u.updated(c)
    check(u.isUnseen(1), "a republish of a tab in the background marks it")
    u.updated(a)
    check(!u.isUnseen(0), "but never the tab on show")
    u.step(1); check(u.active == 1, "⌥⌘→ steps right")
    u.step(1); check(u.active == 0, "and wraps round")
    u.step(-1); check(u.active == 1, "⌥⌘← steps left and wraps")

    let link2 = ArtifactLink.parse("https://claude.ai/artifact/Dez5d8DPYa2wrqBrR3W2gs")!
    let saved = ViewerTabs(tabs: [a, .artifact(link2, title: "Plan"), d], active: 2, preview: 1).saved
    let back = ViewerTabs(saved, fileExists: { $0 != "/p/a.md" })
    check(back.tabs == [.artifact(link2, title: "Plan"), d] && back.active == 1 && back.preview == 0, "saved tabs come back, without files that are gone")
    let json = try? JSONEncoder().encode(saved)
    check(json.flatMap { try? JSONDecoder().decode(ViewerTabs.Saved.self, from: $0) } == saved, "saved tabs survive JSON")

    let suite = UserDefaults(suiteName: "maxwell-tests-\(UUID().uuidString)")!
    var store = SavedViewerTabs()
    store.set("s1", saved)
    store.set("s2", ViewerTabs().saved)
    store.save(suite)
    let reread = SavedViewerTabs.load(suite)
    check(reread.tabs("s1") == saved && reread.tabs("s2") == nil, "tabs are written down per session; a session without tabs leaves no entry")
    for i in 0..<205 { store.set("x\(i)", saved) }
    check(store.entries.count == 200, "only the 200 sessions changed last are kept")

    var o = ViewerTabs(tabs: [a, b, c], active: 2, preview: 1)
    o.closeOthers(1)
    check(o.tabs == [b] && o.active == 0 && o.preview == 0, "close others keeps the one you right-clicked")

    let link = ArtifactLink.parse("https://claude.ai/artifact/Dez5d8DPYa2wrqBrR3W2gs")!
    var t = ViewerTabs()
    t.sessionOpened(.artifact(link, title: nil))
    t.sessionOpened(.artifact(link, title: "Ada owns the goal"))
    check(t.tabs == [.artifact(link, title: "Ada owns the goal")] && t.tabs.count == 1, "the transcript names an untitled artifact tab")
    t.setTitle("Something else", for: link)
    check(t.tabs == [.artifact(link, title: "Ada owns the goal")], "a title only fills in a tab without one")
}

/// The tab strip's widths: the tab on show is never cut at the strip's edge.
func tabWidthsTests() {
    let roomy = TabWidths.fit([120, 150], active: 1, in: 400, least: 96)
    check(roomy == [120, 150], "tabs that fit keep their natural widths")
    let tight = TabWidths.fit([200, 200], active: 1, in: 330, least: 96)
    check(tight[1] == 200 && tight[0] == 130, "the others shrink first; the tab on show keeps its title")
    // A long artifact title in a narrow viewer: 220 pt of tab in 191 pt of strip.
    let narrow = TabWidths.fit([120, 220], active: 1, in: 191, least: 96)
    check(narrow[1] <= 191, "the tab on show is never wider than the strip, so it is never cut off at the left")
    check(TabWidths.fit([220], active: 0, in: 150, least: 96) == [150], "a single tab fills a narrow strip")
}

/// Tabs that don't all fit: the ones on show share the room beside ⌄, no gap, the tab on show among them.
func tabLayoutTests() {
    let two = TabWidths.layout([191, 140], active: 1, in: 300, least: 90, list: 26)
    check(!two.overflow && two.shown == 0..<2 && two.widths[0] >= 90 && two.widths[1] == 140, "two docs in 300 pt: both show, the other one cut down, nothing in ⌄")
    let many = TabWidths.layout([150, 150, 150, 150, 150], active: 4, in: 330, least: 90, list: 26)
    check(many.overflow && many.shown.contains(4) && many.shown.count == 2, "too many: a run that holds the tab on show")
    check(abs(many.widths.reduce(0, +) - (330 - 26)) < 0.5, "they fill the room up to ⌄, no empty strip")
    let first = TabWidths.layout([150, 150, 150, 150], active: 0, in: 330, least: 90, list: 26)
    check(first.shown == 0..<2, "the run starts at the first tab when that reaches the one on show")
    let long = TabWidths.layout([400, 120], active: 0, in: 250, least: 90, list: 26)
    check(long.overflow && long.shown == 0..<1 && long.widths[0] == 224, "a name longer than the room: the tab on show alone, cut in the middle")
    check(TabWidths.layout([], active: nil, in: 300, least: 90, list: 26).shown.isEmpty, "no tabs")
}
