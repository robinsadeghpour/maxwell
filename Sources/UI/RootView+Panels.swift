import AppKit

extension RootView {
    // MARK: moving panels

    func menu(for p: PanelID) -> NSMenu {
        let m = NSMenu()
        for d in Dock.allCases where p.movable {
            let i = MenuAction("Move to \(d.title)") { [weak self] in self?.move(p, to: d) }
            i.state = panels.place[p] == d ? .on : .off
            m.addItem(i)
        }
        if p.movable { m.addItem(.separator()) }
        let shownNow = isShown(p)
        let hide = MenuAction(shownNow ? "Hide \(title(p))" : "Show \(title(p))") { [weak self] in self?.setHidden(p, shownNow) }
        if let k = p.key {
            hide.keyEquivalent = "\(k)"
            hide.keyEquivalentModifierMask = [.command, .option]
        }
        m.addItem(hide)
        if let d = panels.place[p], d != .left {
            let area = MenuAction("Hide \(d.title) Area") { [weak self] in self?.toggleArea(d) }
            area.keyEquivalent = d == .bottom ? "j" : "b"
            area.keyEquivalentModifierMask = [.command, .option]
            m.addItem(area)
        }
        if let d = panels.place[p], shownNow, p.canFill {
            let fill = MenuAction(filling == .panel(d) ? "Back to Normal Size" : "Fill the Window") { [weak self] in self?.toggleFill(.panel(d)) }
            fill.keyEquivalent = "\r"
            fill.keyEquivalentModifierMask = [.command, .shift]
            m.addItem(fill)
        }
        m.addItem(.separator())
        m.addItem(MenuAction("Reset Panel Layout") { [weak self] in self?.panels = PanelLayout() })
        return m
    }

    func showMenu(for p: PanelID, event e: NSEvent) {
        NSMenu.popUpContextMenu(menu(for: p), with: e, for: self)
    }

    /// The ⋯ button: the same menu, dropped below the button.
    func showMenu(for p: PanelID, below v: NSView) {
        menu(for: p).popUp(positioning: nil, at: NSPoint(x: 0, y: v.bounds.maxY + 4), in: v)
    }

    /// Drag a panel by its header: the area under the pointer lights up; release to move it there.
    func dragPanel(_ p: PanelID, from e: NSEvent) {
        guard p.movable else { return }
        let start = convert(e.locationInWindow, from: nil)
        var target: Dock?
        var started = false
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            let q = convert(next.locationInWindow, from: nil)
            if next.type == .leftMouseUp { break }
            if !started, hypot(q.x - start.x, q.y - start.y) < 5 { continue }
            started = true
            target = dropTarget(at: q)
            drop.frame = target.map(previewRect) ?? .zero
            drop.label = target.map { "Move \(title(p)) to \($0.title)" } ?? ""
            let wasHidden = drop.isHidden
            drop.isHidden = target == nil
            if wasHidden, !drop.isHidden { Motion.appear(drop) }
        }
        drop.isHidden = true
        if let target, target != panels.place[p] { move(p, to: target) }
    }

    private func dropTarget(at q: NSPoint) -> Dock? {
        let top = Metrics.titlebar, bottom = bounds.height - Metrics.status
        guard q.y > top, q.y < bottom + 20 else { return nil }
        if q.x < bounds.width * 0.25 { return .left }
        if q.x > bounds.width * 0.75 { return .right }
        if q.y > top + (bottom - top) * 0.6 { return .bottom }
        return nil
    }

    private func previewRect(_ d: Dock) -> NSRect {
        let top = Metrics.titlebar, bottom = bounds.height - Metrics.status
        let x0: CGFloat = railMode == .shown ? Metrics.rail + 1 : 0
        switch d {
        case .left: return NSRect(x: x0 + 4, y: top + 4, width: (panels.size[.left] ?? 288) - 8, height: bottom - top - 8)
        case .right: return NSRect(x: bounds.width - (panels.size[.right] ?? 420) + 4, y: top + 4, width: (panels.size[.right] ?? 420) - 8, height: bottom - top - 8)
        case .bottom:
            let c = sessionPane.frame
            return NSRect(x: c.minX + 4, y: bottom - 160, width: c.width - 8, height: 156)
        }
    }

    // MARK: showing, hiding and filling the window

    /// Showing a list or document in a side area hides the others there: they are its tabs.
    func setHidden(_ p: PanelID, _ hide: Bool) {
        var l = panels
        if hide { l.hidden.insert(p) } else { l.show(p, among: present) }
        panels = l
        // A panel shown while something else fills the window: back to normal so it can be seen.
        if !hide, let f = filling, l.place[p] != f.dock { filling = nil }
        endFillIfEmpty()
    }

    func move(_ p: PanelID, to d: Dock) {
        filling = nil
        panels.move(p, to: d, among: present)
    }

    /// Hides every panel of an area, or shows them all again.
    func toggleArea(_ d: Dock) {
        // Hidden by what fills the window, a side comes back as it was rather than going for good.
        if shown(d).contains(where: { fillHides($0) }) { filling = nil; return }
        let ps = panels.panels(d, among: present)
        guard !ps.isEmpty else { return }
        let anyShown = ps.contains { !panels.hidden.contains($0) }
        var l = panels
        for p in ps { if anyShown { l.hidden.insert(p) } else { l.hidden.remove(p) } }
        // Shown again, a side still shows one list or document: the first in order.
        if !anyShown, d != .bottom, let first = ps.first(where: \.flexible) { l.show(first, among: present) }
        panels = l
        // Hidden, an area that filled the window gives it back; shown, it ends whatever else fills it.
        if filling != nil, anyShown ? filling == .panel(d) : filling != .panel(d) { filling = nil }
    }

    /// Fills the window with `f`, or goes back to normal when it already does.
    func toggleFill(_ f: WindowFill) {
        if filling == f { filling = nil; return }
        if let d = f.dock, !shown(d).contains(where: \.canFill) { return }
        filling = f
    }

    /// Whether what fills the window hides `p`; nil is the session pane.
    func fillHides(_ p: PanelID?) -> Bool {
        switch filling {
        case nil: return false
        case .session?: return p != nil
        case .panel(let d)?: return p.map { panels.place[$0] != d } ?? true
        }
    }

    /// An area that filled the window and has nothing left to show gives the window back.
    func endFillIfEmpty() {
        if let d = filling?.dock, shown(d).isEmpty { filling = nil }
    }

    /// Esc that nothing else took: back to normal size.
    override func cancelOperation(_ sender: Any?) {
        if filling != nil { filling = nil } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    /// What fills the window takes `whole`, the body without the rail, and the stripes step aside.
    /// The session takes it at once (the terminal reflows); the other areas hide. An area grows over
    /// the terminal and the other areas: the terminal keeps its size, so the session doesn't reflow;
    /// it is only hidden until the area is back. Returns whether something fills (or is growing or shrinking).
    func layoutFill(whole body: NSRect) -> Bool {
        if filling == .session {
            sessionPane.isHidden = false
            sessionPane.frame = body
            sessionDim.frame = body
            for v in docks.values { v.isHidden = true }
            for v in splitters.values { v.isHidden = true }
            leftStripe.isHidden = true
            rightStripe.isHidden = true
            return true
        }
        let active = filling != nil || maxTween.isRunning
        // Shrinking back, the session shows under the area at once, so it can take the keyboard back.
        sessionPane.isHidden = filling != nil
        sessionDim.isHidden = active || sessionDim.isHidden
        guard active, maxTween.value > 0 else { return false }
        let k = maxTween.value, v = docks[growing]!, a = v.frame
        v.frame = NSRect(x: a.minX + (body.minX - a.minX) * k, y: a.minY + (body.minY - a.minY) * k,
                         width: a.width + (body.width - a.width) * k, height: a.height + (body.height - a.height) * k)
        v.isHidden = false
        for (d, o) in docks where d != growing { o.isHidden = true }
        for sp in splitters.values { sp.isHidden = true }
        leftStripe.isHidden = true
        rightStripe.isHidden = true
        return true
    }
}
