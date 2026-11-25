import AppKit

/// The project rail, Dock-like: All, the kept projects (with or without sessions), then the others
/// while a session in them is open. Keys that don't fit stay in the ⋯ menu.
/// Click or ⌘0–⌘9; right-click to keep or remove; drag to reorder, drag out to remove.
final class ProjectRail: MXView, TipSource {
    /// `entries[0]` is All; then kept projects in order; then the others with an open session.
    var entries: [ProjectEntry] = [] {
        didSet { if entries != oldValue { monograms = Self.unique(entries.map(\.name)); needsDisplay = true } }
    }
    /// Every project, for the overflow menu (pinned or not, needing him or not).
    var everyProject: [ProjectEntry] = []
    var selected: String? { didSet { needsDisplay = true } }
    /// Drawn over the sidebar (auto-hide) rather than beside it.
    var overlay = false { didSet { needsDisplay = true } }
    var onSelect: ((String?) -> Void)?
    /// Pin (at an index among the pinned) or unpin a project.
    var onPin: ((String, Bool, Int?) -> Void)?
    var onConfig: ((String, String) -> Void)?
    /// A session row dropped on a project's key.
    var onDropSession: ((SessionID, String) -> Void)?
    /// A session row is being dragged: the rail stays out until the drag ends.
    var sessionDrag = false { didSet { if !sessionDrag { dropTarget = nil } } }
    private var dropTarget: Int? { didSet { if dropTarget != oldValue { needsDisplay = true } } }
    var logoStyle = "engraved"
    var mode = "auto"

    private var hover: Int?
    private var pressed: Int?
    private var monograms: [String] = []
    private var drag: (index: Int, y: CGFloat, out: Bool)?
    private var menuOpen = false
    var isBusy: Bool { menuOpen || drag != nil || sessionDrag }

    static let key: CGFloat = 26
    static let pitch: CGFloat = 30

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        registerForDraggedTypes([.maxwellSession])
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Two letters per project, distinct across the rail: "Ma" for Maxwell, then "Me" for Meta agent tool.
    static func unique(_ names: [String?]) -> [String] {
        var used = Set<String>()
        return names.map { name in
            guard let name else { return "" }
            let words = name.split(separator: " ").map(String.init)
            let letters = Array(name.replacingOccurrences(of: " ", with: ""))
            var candidates: [String] = []
            if words.count > 1 { candidates.append(String(words[0].prefix(1)) + String(words[1].prefix(1))) }
            candidates += letters.dropFirst().map { String(letters[0]) + String($0) }
            let pick = candidates.map { $0.uppercased() }.first { !used.contains($0) } ?? String(name.prefix(2)).uppercased()
            used.insert(pick)
            return pick
        }
    }

    // MARK: geometry

    private var pinnedCount: Int { entries.dropFirst().filter(\.pinned).count }

    /// Slot positions: All, a hairline, pinned, a hairline, the rest. The overflow key sits at the bottom.
    private func rect(_ i: Int) -> NSRect {
        var y: CGFloat = 7 + CGFloat(i) * Self.pitch
        if i >= 1 { y += 9 }
        if i > pinnedCount, pinnedCount > 0 { y += 9 }
        return NSRect(x: (bounds.width - Self.key) / 2, y: y, width: Self.key, height: Self.key)
    }
    private var dividers: [CGFloat] {
        var out = [rect(0).maxY + 6]
        if pinnedCount > 0, shown.count > pinnedCount + 1 { out.append(rect(pinnedCount).maxY + 6) }
        return out
    }
    /// The keys that fit above the ⋯ key; the rest are only in its menu.
    private var shown: Range<Int> {
        entries.startIndex..<(entries.indices.first { rect($0).maxY > moreRect.minY - 6 } ?? entries.endIndex)
    }
    private var moreRect: NSRect { NSRect(x: (bounds.width - Self.key) / 2, y: bounds.height - Self.key - 7, width: Self.key, height: Self.key) }

    var tipsBeside: Bool { true }

    /// The project, what waits on you there, and whether it stays on the rail.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard !isBusy, let i = index(at: p) else { return nil }
        if i == -1 { return (Tip("Every project, and rail settings"), moreRect) }
        let e = entries[i]
        var counts: [String] = []
        if e.needsYou > 0 { counts.append("\(e.needsYou) \(e.needsYou == 1 ? "needs" : "need") you") }
        if e.yourTurn > 0 { counts.append("\(e.yourTurn) your turn") }
        let detail: String
        if e.name == nil {
            detail = counts.isEmpty ? "What needs you, from every project" : counts.joined(separator: ", ") + ", across all projects"
        } else {
            let state = e.pinned ? "Kept in the rail" : "Shows while a session is open"
            detail = counts.isEmpty ? state : counts.joined(separator: ", ") + ". " + state
        }
        let action = e.name == nil ? "project-all" : e.key.map { "project-\($0)" }
        return (Tip(e.name ?? "All projects", action: action).adding(detail), rect(i))
    }

    // MARK: drawing

    override func draw(_ r: NSRect) {
        if overlay { t.panel.withAlphaComponent(0.97).setFill(); bounds.fill() }
        t.hair.setFill()
        for y in dividers { NSRect(x: 12, y: y, width: bounds.width - 24, height: 1).fill() }
        for i in shown where drag?.index != i {
            drawKey(i, entries[i], in: rect(i), alpha: 1)
        }
        if let d = drag {
            if !d.out, let slot = dropSlot(d.y) {
                t.fg2.setFill()
                NSRect(x: 8, y: rect(slot + 1).minY - 3, width: bounds.width - 16, height: 1.5).fill()
            }
            let k = NSRect(x: (bounds.width - Self.key) / 2, y: d.y - Self.key / 2, width: Self.key, height: Self.key)
            drawKey(d.index, entries[d.index], in: k, alpha: d.out ? 0.35 : 0.9)
        }
        let mk = moreRect
        if hover == -1 || pressed == -1 { (pressed == -1 ? t.rowSel : t.hover).setFill(); NSBezierPath(roundedRect: mk, xRadius: 4, yRadius: 4).fill() }
        (hover == -1 ? t.fg : t.fg3).setFill()
        for dx in [-5, 0, 5] { NSRect(x: mk.midX + CGFloat(dx) - 1, y: mk.midY - 1, width: 2, height: 2).fill() }
    }

    private func drawKey(_ i: Int, _ e: ProjectEntry, in k: NSRect, alpha: CGFloat) {
        let sel = e.name == selected
        let path = NSBezierPath(roundedRect: k, xRadius: 4, yRadius: 4)
        if dropTarget == i {
            t.rowSel.setFill(); path.fill()
            t.fg2.setStroke(); let p = NSBezierPath(roundedRect: k.insetBy(dx: -1.5, dy: -1.5), xRadius: 5, yRadius: 5); p.lineWidth = 1.5; p.stroke()
        } else if sel || pressed == i { t.rowSel.withAlphaComponent(t.rowSel.alphaComponent * alpha).setFill(); path.fill() }
        else { (hover == i ? t.hover : t.hair2).setFill(); path.fill() }
        if sel {
            t.hair.setStroke(); let p = NSBezierPath(roundedRect: k.insetBy(dx: 0.5, dy: 0.5), xRadius: 4, yRadius: 4); p.lineWidth = 1; p.stroke()
            t.fg.setFill()
            NSRect(x: 0, y: k.midY - 7, width: 2, height: 14).fill()
        }
        let ink = (sel || hover == i ? t.fg : t.fg2).withAlphaComponent(alpha)
        ProjectLogos.shared.drawKey(e.name, monogram: monograms.indices.contains(i) ? monograms[i] : "", roots: e.roots, in: k, ink: ink, theme: t)
        let n = e.needsYou + e.yourTurn
        guard n > 0 else { return }
        let font = Fonts.mono(8, .bold)
        let s = n > 9 ? "9+" : "\(n)"
        let w = max(10, Text.width(s, font: font) + 4)
        let b = NSRect(x: k.maxX - w + 5, y: k.minY - 4, width: w, height: 10)
        (overlay ? t.panel : t.background).setStroke()
        let bp = NSBezierPath(roundedRect: b, xRadius: 2, yRadius: 2)
        bp.lineWidth = 2; bp.stroke()
        (e.needsYou > 0 ? t.on : t.chk).setFill(); bp.fill()
        Text.draw(s, in: b.offsetBy(dx: 0, dy: 0.5), color: t.dark ? NSColor.black.withAlphaComponent(0.85) : .white, font: font, align: .center)
    }

    // MARK: mouse

    private func index(at p: NSPoint) -> Int? {
        if moreRect.insetBy(dx: -6, dy: -2).contains(p) { return -1 }
        return shown.first { rect($0).insetBy(dx: -7, dy: -2).contains(p) }
    }

    /// Where a dragged key would land among the pinned: 0 … pinnedCount.
    private func dropSlot(_ y: CGFloat) -> Int? {
        let slot = Int(((y - rect(1).minY) / Self.pitch).rounded())
        return max(0, min(pinnedCount, slot))
    }

    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }

    override func mouseDown(with e: NSEvent) {
        let start = convert(e.locationInWindow, from: nil)
        guard let i = index(at: start) else { return }
        pressed = i; needsDisplay = true
        if i == -1 { pressed = nil; return showOverflow(e) }
        var dragging = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let p = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            guard i > 0 else { continue }
            if !dragging, hypot(p.x - start.x, p.y - start.y) > 4 { dragging = true; pressed = nil }
            guard dragging else { continue }
            let out = p.x > bounds.width + 30
            drag = (i, max(Self.key / 2, min(bounds.height - Self.key / 2, p.y)), out)
            (out && entries[i].pinned ? NSCursor.disappearingItem : NSCursor.closedHand).set()
            needsDisplay = true
        }
        NSCursor.arrow.set()
        defer { pressed = nil; drag = nil; needsDisplay = true }
        if let d = drag, let name = entries[d.index].name {
            if d.out { if entries[d.index].pinned { onPin?(name, false, nil) } }
            else { onPin?(name, true, dropSlot(d.y)) }
            return
        }
        if index(at: convert(e.window?.mouseLocationOutsideOfEventStream ?? start, from: nil)) == i { onSelect?(entries[i].name) }
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let i = index(at: convert(e.locationInWindow, from: nil)) else { return }
        if i == -1 { return showOverflow(e) }
        let entry = entries[i]
        let m = NSMenu()
        if let name = entry.name {
            m.addItem(MenuAction("Open \(name)") { [weak self] in self?.onSelect?(name) })
            let keep = MenuAction("Keep in Rail") { [weak self] in self?.onPin?(name, !entry.pinned, nil) }
            keep.state = entry.pinned ? .on : .off
            m.addItem(keep)
            m.addItem(.separator())
        }
        addSettings(to: m)
        popUp(m, e)
    }

    private func showOverflow(_ e: NSEvent) {
        let m = NSMenu()
        let all = MenuAction("All: what needs you") { [weak self] in self?.onSelect?(nil) }
        all.keyEquivalent = "0"; all.keyEquivalentModifierMask = .command
        m.addItem(all)
        for p in everyProject {
            guard let name = p.name else { continue }
            let n = p.needsYou + p.yourTurn
            let item = MenuAction(n > 0 ? "\(name)  ·  \(n)" : name) { [weak self] in self?.onSelect?(name) }
            if let k = p.key { item.keyEquivalent = "\(k)"; item.keyEquivalentModifierMask = .command }
            m.addItem(item)
        }
        m.addItem(.separator())
        let keep = NSMenuItem(title: "Keep in Rail", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        for p in everyProject {
            guard let name = p.name else { continue }
            let item = MenuAction(name) { [weak self] in self?.onPin?(name, !p.pinned, nil) }
            item.state = p.pinned ? .on : .off
            sub.addItem(item)
        }
        keep.submenu = sub
        m.addItem(keep)
        addSettings(to: m)
        popUp(m, e)
    }

    private func addSettings(to m: NSMenu) {
        let rail = NSMenuItem(title: "Rail", action: nil, keyEquivalent: "")
        let rs = NSMenu()
        for (v, title) in [("auto", "Hide Until the Pointer Reaches the Edge"), ("shown", "Always Show")] {
            let i = MenuAction(title) { [weak self] in self?.onConfig?("rail", v) }
            i.state = mode == v ? .on : .off
            rs.addItem(i)
        }
        rail.submenu = rs
        m.addItem(rail)
        let logos = NSMenuItem(title: "Logos", action: nil, keyEquivalent: "")
        let ls = NSMenu()
        for (v, title) in [("engraved", "Engraved"), ("pixel", "Pixel"), ("monogram", "Monogram")] {
            let i = MenuAction(title) { [weak self] in self?.onConfig?("project-logo-style", v) }
            i.state = logoStyle == v ? .on : .off
            ls.addItem(i)
        }
        logos.submenu = ls
        m.addItem(logos)
    }

    private func popUp(_ m: NSMenu, _ e: NSEvent) {
        menuOpen = true
        NSMenu.popUpContextMenu(m, with: e, for: self)
        menuOpen = false
        hover = nil
        needsDisplay = true
    }

    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // MARK: dropping a session on a project

    private func target(_ info: NSDraggingInfo) -> Int? {
        guard let i = index(at: convert(info.draggingLocation, from: nil)), i > 0, entries[i].name != nil else { return nil }
        return i
    }
    override func draggingEntered(_ info: NSDraggingInfo) -> NSDragOperation { draggingUpdated(info) }
    override func draggingUpdated(_ info: NSDraggingInfo) -> NSDragOperation {
        dropTarget = target(info)
        return dropTarget == nil ? [] : .move
    }
    override func draggingExited(_ info: NSDraggingInfo?) { dropTarget = nil }
    override func performDragOperation(_ info: NSDraggingInfo) -> Bool {
        defer { dropTarget = nil }
        guard let i = target(info), let name = entries[i].name,
              let id = info.draggingPasteboard.string(forType: .maxwellSession) else { return false }
        onDropSession?(id, name)
        return true
    }
}

/// A project's key at header size: the same glass tile and mark as on the rail.
final class ProjectMark: MXView {
    var project: String? { didSet { if project != oldValue { needsDisplay = true } } }
    var roots: [String] = []
    var monogram = ""
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3)
        t.hair2.setFill(); path.fill()
        ProjectLogos.shared.drawKey(project, monogram: monogram, roots: roots, in: bounds, ink: t.fg, theme: t)
    }
}
