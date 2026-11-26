import AppKit

extension RootView {
    // MARK: moving panels

    func menu(for p: PanelID) -> NSMenu {
        let m = NSMenu()
        for d in Dock.allCases {
            let i = MenuAction("Move to \(d.title)") { [weak self] in self?.move(p, to: d) }
            i.state = panels.place[p] == d ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
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
            let fill = MenuAction(maximized == d ? "Back to Normal Size" : "Fill the Window") { [weak self] in self?.toggleMaximize(d) }
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
        // A panel shown on another side while one fills the window: back to normal so it can be seen.
        if let m = maximized, shown(m).isEmpty || (!hide && l.place[p] != m) { maximized = nil }
    }

    func move(_ p: PanelID, to d: Dock) {
        maximized = nil
        panels.move(p, to: d, among: present)
    }

    /// Hides every panel of an area, or shows them all again.
    func toggleArea(_ d: Dock) {
        let ps = panels.panels(d, among: present)
        guard !ps.isEmpty else { return }
        let anyShown = ps.contains { !panels.hidden.contains($0) }
        var l = panels
        for p in ps { if anyShown { l.hidden.insert(p) } else { l.hidden.remove(p) } }
        // Shown again, a side still shows one list or document: the first in order.
        if !anyShown, d != .bottom, let first = ps.first(where: \.flexible) { l.show(first, among: present) }
        panels = l
        if anyShown, maximized == d { maximized = nil }
    }

    func toggleMaximize(_ d: Dock) { maximized = maximized == d || !shown(d).contains(where: \.canFill) ? nil : d }

    /// Esc that nothing else took: back to normal size.
    override func cancelOperation(_ sender: Any?) {
        if maximized != nil { maximized = nil } else { nextResponder?.tryToPerform(#selector(cancelOperation(_:)), with: sender) }
    }

    /// While an area fills the window it is laid over the terminal's place and the other areas. The
    /// terminal keeps its size, so the session doesn't reflow; it is only hidden until the area is
    /// back. Returns whether an area fills (or is growing or shrinking).
    func layoutMaximized(body: NSRect) -> Bool {
        let active = maximized != nil || maxTween.isRunning
        sessionPane.isHidden = active
        sessionDim.isHidden = active || sessionDim.isHidden
        guard active, maxTween.value > 0 else { return false }
        let k = maxTween.value, v = docks[growing]!, a = v.frame
        v.frame = NSRect(x: a.minX + (body.minX - a.minX) * k, y: a.minY + (body.minY - a.minY) * k,
                         width: a.width + (body.width - a.width) * k, height: a.height + (body.height - a.height) * k)
        v.isHidden = false
        for (d, o) in docks where d != growing { o.isHidden = true }
        for sp in splitters.values { sp.isHidden = true }
        return true
    }
}
