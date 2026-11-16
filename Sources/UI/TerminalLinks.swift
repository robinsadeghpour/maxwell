// Links in a terminal that a plain click opens in Maxwell: finding them under the pointer through
// Ghostty, showing them as links (a hand and an underline), and the test hooks that click them.
import AppKit
import GhosttyKit

/// The claimed link under the pointer and the grid cell it was found from.
struct LinkHover {
    var link: String?
    var cell: TerminalCell?
    /// Where the pointer is (points from the top left) and what its row said, to notice the text
    /// moving under a pointer that stays put.
    var point = (x: 0.0, y: 0.0)
    var row = ""
    /// The terminal with a link under the pointer, if any.
    static weak var view: TerminalView?
    /// The underline Maxwell draws, over exactly what opens.
    let underline: CALayer = {
        let l = CALayer()
        l.zPosition = 10
        l.isHidden = true
        l.actions = ["position": NSNull(), "bounds": NSNull(), "hidden": NSNull()]
        return l
    }()
    /// A link that wraps onto another row can't be measured from one row: Ghostty's own underline
    /// shows it, as long as the modifiers it found the link with are held.
    var ghosttyMods: ghostty_input_mods_e?
}

struct TerminalCell: Equatable { let row: Int, col: Int }

extension TerminalView {
    /// The pointer moved: when it reaches another cell, look for a claimed link there.
    func hoverMoved(_ e: NSEvent) {
        guard claimsLink != nil, let surface else { return }
        let p = convert(e.locationInWindow, from: nil), y = bounds.height - p.y
        let cell = cellAt(x: p.x, y: y)
        if cell == hover.cell, hover.link != nil {
            if let m = hover.ghosttyMods { ghostty_surface_mouse_pos(surface, p.x, y, m) }
            return
        }
        let plain = e.modifierFlags.intersection([.command, .shift, .option, .control]).isEmpty
        lookAgain(at: cell, x: p.x, y: y, mods: plain ? nil : Self.mouseMods(e.modifierFlags))
    }

    /// After Ghostty draws: output that moved the text under a resting pointer moves the link too.
    static func recheckHover() {
        guard let v = LinkHover.view, let cell = v.hover.cell, v.rowText(cell.row) != v.hover.row else { return }
        v.lookAgain(at: cell, x: v.hover.point.x, y: v.hover.point.y, mods: nil)
    }

    /// `mods`: the modifiers held, which mean no plain-click link.
    private func lookAgain(at cell: TerminalCell?, x: Double, y: Double, mods: ghostty_input_mods_e?) {
        hover.cell = cell
        hover.point = (x, y)
        hover.row = cell.map { rowText($0.row) } ?? ""
        let found = mods == nil ? linkAt(x: x, y: y, restoring: Self.mouseMods([])) : nil
        showHover(found.flatMap { claimsLink?($0) == true ? $0 : nil }, at: cell, x: x, y: y)
    }

    /// The pointer left, or the text scrolled under it.
    func endHover() {
        if hover.link != nil { showHover(nil, at: nil, x: -1, y: -1) }
        hover.cell = nil
    }

    private func showHover(_ link: String?, at cell: TerminalCell?, x: Double, y: Double) {
        let was = hover.link
        if (link == nil) != (was == nil) { (link == nil ? NSCursor.arrow : NSCursor.pointingHand).set() }
        hover.link = link
        LinkHover.view = link == nil ? (LinkHover.view === self ? nil : LinkHover.view) : self
        hover.underline.isHidden = true
        if was != nil, hover.ghosttyMods != nil, let surface {
            // Shift alone makes Ghostty look again without the link modifier: its underline goes.
            ghostty_surface_mouse_pos(surface, x, y, Self.mods(.shift))
            ghostty_surface_mouse_pos(surface, x, y, Self.mouseMods([]))
        }
        hover.ghosttyMods = nil
        guard let link, let cell, let surface else { return }
        if let frame = underlineFrame(FileLink.withoutTrailingPunctuation(link), around: cell) {
            if hover.underline.superlayer == nil { layer?.addSublayer(hover.underline) }
            hover.underline.backgroundColor = Look.theme.terminalForeground.withAlphaComponent(0.75).cgColor
            hover.underline.frame = frame
            hover.underline.isHidden = false
        } else {
            hover.ghosttyMods = linkMods
            ghostty_surface_mouse_pos(surface, x, y, linkMods)
        }
    }

    /// Where the underline goes, in layer coordinates: under `shown` on the pointer's row, when the
    /// row holds the whole of it and the pointer is on it. Nil for a link that wraps.
    private func underlineFrame(_ shown: String, around cell: TerminalCell) -> NSRect? {
        guard let surface, let scale = window?.backingScaleFactor, !shown.isEmpty else { return nil }
        let line = rowText(cell.row)
        var from = line.startIndex
        while let r = line.range(of: shown, range: from..<line.endIndex) {
            let start = line.distance(from: line.startIndex, to: r.lowerBound)
            if (start..<start + shown.count).contains(cell.col) {
                let g = grid(surface, scale)
                let bottom = g.padY + Double(cell.row + 1) * g.ch
                return NSRect(x: g.padX + Double(start) * g.cw, y: bounds.height - bottom + 2, width: Double(shown.count) * g.cw, height: 1)
            }
            from = line.index(after: r.lowerBound)
        }
        return nil
    }

    private func grid(_ surface: ghostty_surface_t, _ scale: CGFloat) -> (cw: Double, ch: Double, padX: Double, padY: Double, size: ghostty_surface_size_s) {
        let sz = ghostty_surface_size(surface)
        let cw = Double(sz.cell_width_px) / scale, ch = Double(sz.cell_height_px) / scale
        return (cw, ch, (Double(sz.width_px) / scale - Double(sz.columns) * cw) / 2, (Double(sz.height_px) / scale - Double(sz.rows) * ch) / 2, sz)
    }

    /// The grid cell at x, y (points from the top left), or nil in the padding.
    func cellAt(x: Double, y: Double) -> TerminalCell? {
        guard let surface, let scale = window?.backingScaleFactor else { return nil }
        let g = grid(surface, scale)
        guard g.cw > 0, g.ch > 0 else { return nil }
        let col = Int(((x - g.padX) / g.cw).rounded(.down)), row = Int(((y - g.padY) / g.ch).rounded(.down))
        return (0..<Int(g.size.columns)).contains(col) && (0..<Int(g.size.rows)).contains(row) ? TerminalCell(row: row, col: col) : nil
    }

    /// One row of the screen as shown.
    func rowText(_ row: Int) -> String {
        guard let surface else { return "" }
        let cols = UInt32(ghostty_surface_size(surface).columns)
        var text = ghostty_text_s()
        let sel = ghostty_selection_s(
            top_left: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: 0, y: UInt32(row)),
            bottom_right: ghostty_point_s(tag: GHOSTTY_POINT_VIEWPORT, coord: GHOSTTY_POINT_COORD_EXACT, x: cols - 1, y: UInt32(row)),
            rectangle: false)
        guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }

    /// The link under a plain click, found the way ⌘-click finds it. Claude Code turns on mouse
    /// reporting and opens a clicked link in the system browser itself, so without this Maxwell
    /// never hears of the click.
    func linkUnderClick(_ e: NSEvent) -> String? {
        let p = convert(e.locationInWindow, from: nil)
        return linkAt(x: p.x, y: bounds.height - p.y, restoring: Self.mouseMods(e.modifierFlags))
    }

    /// The modifiers Ghostty finds links with. With mouse reporting on (Claude Code's full-screen
    /// view) it wants ⌘⇧, without it ⌘ alone; the last that worked is tried first.
    private var linkMods: ghostty_input_mods_e { Self.linkModsFound }
    private static var linkModsFound = TerminalView.mouseMods(.command)

    /// x, y from the top left, in points. `restoring` is the modifier state Ghostty is left with.
    private func linkAt(x: Double, y: Double, restoring mods: ghostty_input_mods_e) -> String? {
        guard let surface, claimsLink != nil else { return nil }
        let ch = Double(ghostty_surface_size(surface).cell_height_px) / (window?.backingScaleFactor ?? 2)
        var found: String?
        let tries = [linkMods] + [Self.mouseMods(.command), Self.mods(.command)].filter { $0 != linkMods }
        for cmd in tries where found == nil {
            // Ghostty only looks again when the pointer changes cell, so step off the cell and back.
            ghostty_surface_mouse_pos(surface, x, y + ch < bounds.height ? y + ch : y - ch, cmd)
            linkUnderPointer = nil
            ghostty_surface_mouse_pos(surface, x, y, cmd)
            found = linkUnderPointer
            if found != nil { Self.linkModsFound = cmd }
        }
        // Leaving the view (with shift, so Claude Code isn't told) clears Ghostty's hover and marks the
        // row for redrawing; a link modifier merely let go of leaves the underline drawn.
        ghostty_surface_mouse_pos(surface, -1, -1, Self.mods(.shift))
        ghostty_surface_mouse_pos(surface, x, y, mods)
        linkUnderPointer = nil
        return found
    }

    // MARK: test hooks

    /// Test hook: Cmd+click the first on-screen occurrence of `needle` (as a user would).
    func cmdClick(on needle: String) -> Bool {
        guard let surface, let (x, y) = point(of: needle) else { return false }
        let m = Self.mouseMods(.command)
        ghostty_surface_mouse_pos(surface, x, y, m)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, m)
        _ = ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, m)
        return true
    }

    /// Test hook: a plain click (no modifiers) on the last place `needle` shows, through
    /// mouseMoved, mouseDown and mouseUp as a real click goes. The link it found, or "-" for none,
    /// and how the hover showed. "hover:<needle>" only moves the pointer there.
    func plainClick(on needle: String) -> String? {
        let hoverOnly = needle.hasPrefix("hover:")
        let needle = hoverOnly ? String(needle.dropFirst(6)) : needle
        guard let window, let (x, y) = point(of: needle) else { return nil }
        let at = window.convertPoint(toScreen: convert(NSPoint(x: x, y: bounds.height - y), to: nil))
        let loc = window.convertPoint(fromScreen: at)
        func ev(_ t: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: t, location: loc, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let move = ev(.mouseMoved), let down = ev(.leftMouseDown), let up = ev(.leftMouseUp) else { return nil }
        mouseMoved(with: move)
        let shown = hover.link == nil ? "none" : hover.underline.isHidden ? "hand, Ghostty's underline" : "hand, underline \(Int(hover.underline.frame.width))pt"
        if hoverOnly { return "hover \(shown)" }
        let link = linkUnderClick(down)
        mouseDown(with: down)
        mouseUp(with: up)
        return (link ?? "-") + ", hover " + shown
    }

    /// Middle of the cell where `needle` starts (its last showing), from the top left in points.
    /// Reads the screen row by row: counting rows from joined lines drifts when a row is exactly full.
    private func point(of needle: String) -> (Double, Double)? {
        guard let surface, let scale = window?.backingScaleFactor else { return nil }
        let g = grid(surface, scale)
        guard let (row, line) = (0..<Int(g.size.rows)).reversed().lazy.map({ ($0, self.rowText($0)) }).first(where: { $0.1.contains(needle) }),
              let r = line.range(of: needle) else { return nil }
        let col = line.distance(from: line.startIndex, to: r.lowerBound) + (needle.count > 1 ? 1 : 0)
        return (g.padX + (Double(col) + 0.5) * g.cw, g.padY + (Double(row) + 0.5) * g.ch)
    }
}
