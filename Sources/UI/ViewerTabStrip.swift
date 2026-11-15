import AppKit

/// What a viewer tab was asked to do: from a click, a drag or its menu.
enum ViewerTabAction {
    case select(Int), close(Int), keep(Int), move(Int, Int), closeOthers(Int), closeAll, reveal(Int), copyPath(Int), openInBrowser(Int)
}

/// The viewer's tabs, the way VS Code and Cursor draw an editor's: one per open file or artifact,
/// the active one raised and joined to the page under it, the preview tab in italics.
/// Click to show, × or a middle click to close, double-click to keep, drag to reorder.
final class ViewerTabStrip: MXView, TipSource {
    struct Tab: Equatable { var title: String; var detail: String; var preview: Bool }
    var tabs: [Tab] = [] { didSet { if tabs != oldValue { needsDisplay = true; scrollToActive() } } }
    var active: Int? { didSet { if active != oldValue { needsDisplay = true; scrollToActive() } } }
    var onAction: ((ViewerTabAction) -> Void)?
    /// Builds the right-click menu for a tab (the pane knows whether it is a file or an artifact).
    var menuFor: ((Int) -> NSMenu)?
    private var hover: Int?
    private var hoverClose = false
    private var offset: CGFloat = 0
    private var dragging: (index: Int, x: CGFloat)?

    static let minWidth: CGFloat = 112, maxWidth: CGFloat = 220
    private static let pad: CGFloat = 10, closeW: CGFloat = 18

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func font(_ tab: Tab) -> NSFont {
        tab.preview ? (NSFont(name: "JetBrainsMono-Italic", size: Metrics.fontSize) ?? Fonts.mono()) : Fonts.mono()
    }

    /// Each tab as wide as its title, up to a limit; when they don't fit, they share the room down to
    /// what still reads (about ten characters), and past that the strip scrolls, as VS Code's does.
    private func widths() -> [CGFloat] { widths(in: bounds.width) }

    private func widths(in width: CGFloat) -> [CGFloat] {
        let natural = tabs.map { min(Self.maxWidth, Text.width($0.title, font: font($0)) + Self.pad * 2 + Self.closeW) }
        let total = natural.reduce(0, +)
        guard total > width, total > 0 else { return natural }
        let excess = total - width
        let room = natural.map { max(0, $0 - Self.minWidth) }.reduce(0, +)
        guard room > 0 else { return natural }
        let k = min(1, excess / room)
        return natural.map { $0 - max(0, $0 - Self.minWidth) * k }
    }

    private func rects() -> [NSRect] {
        var x = -offset
        return widths().map { w in defer { x += w }; return NSRect(x: x, y: 0, width: w, height: bounds.height) }
    }

    /// How much of a strip this wide the tabs fill: the empty rest moves the panel. Worked out from
    /// the width, not the frame, so the dock can place the panel's grip before the strip lays out.
    func usedWidth(in width: CGFloat) -> CGFloat { min(width, widths(in: width).reduce(0, +)) }

    private func closeRect(_ r: NSRect) -> NSRect { NSRect(x: r.maxX - Self.closeW - 6, y: (r.height - Self.closeW) / 2, width: Self.closeW, height: Self.closeW) }

    private func scrollToActive() {
        let total = widths().reduce(0, +)
        offset = max(0, min(offset, total - bounds.width))
        guard let a = active, a < tabs.count else { return }
        let r = rects()[a]
        if r.maxX > bounds.width { offset += r.maxX - bounds.width }
        if r.minX < 0 { offset += r.minX }
        offset = max(0, offset)
    }

    override func layout() { super.layout(); scrollToActive() }

    override func draw(_ r: NSRect) {
        let rs = rects()
        for (i, tab) in tabs.enumerated() {
            let rr = rs[i]
            guard rr.maxX > 0, rr.minX < bounds.width else { continue }
            let sel = i == active
            if sel {
                // The active tab is open to the page under it (no line below), with VS Code's mark on top.
                t.fg2.setFill(); NSRect(x: rr.minX, y: 0, width: rr.width, height: 1.5).fill()
            } else {
                if hover == i { t.hover.withAlphaComponent(0.5).setFill(); rr.fill() }
                t.hair2.setFill(); NSRect(x: rr.minX, y: rr.maxY - 1, width: rr.width, height: 1).fill()
            }
            t.hair2.setFill(); NSRect(x: rr.maxX - 1, y: 0, width: 1, height: rr.height).fill()
            let showClose = sel || hover == i
            let textRect = NSRect(x: rr.minX + Self.pad, y: 0, width: rr.width - Self.pad * 2 - Self.closeW + 4, height: rr.height)
            Text.draw(tab.title, in: textRect, color: sel ? t.fg : hover == i ? t.fg2 : t.fg3, font: font(tab))
            if showClose {
                let c = closeRect(rr)
                if hover == i, hoverClose { t.hover.setFill(); NSBezierPath(roundedRect: c, xRadius: 3, yRadius: 3).fill() }
                let p = NSBezierPath(); p.lineWidth = 1.2; p.lineCapStyle = .round
                let m = NSPoint(x: c.midX, y: c.midY)
                p.move(to: NSPoint(x: m.x - 3.5, y: m.y - 3.5)); p.line(to: NSPoint(x: m.x + 3.5, y: m.y + 3.5))
                p.move(to: NSPoint(x: m.x + 3.5, y: m.y - 3.5)); p.line(to: NSPoint(x: m.x - 3.5, y: m.y + 3.5))
                (hoverClose && hover == i ? t.fg : t.fg3).setStroke(); p.stroke()
            }
        }
        let end = max(0, rs.last?.maxX ?? 0)
        if end < bounds.width { t.hair2.setFill(); NSRect(x: end, y: bounds.height - 1, width: bounds.width - end, height: 1).fill() }
        // More tabs past an edge: a short fade says the strip scrolls.
        let bg = t.background
        if offset > 0 { NSGradient(colors: [bg.withAlphaComponent(0.9), bg.withAlphaComponent(0)])?.draw(in: NSRect(x: 0, y: 0, width: 16, height: bounds.height - 1), angle: 0) }
        if end > bounds.width + 0.5 { NSGradient(colors: [bg.withAlphaComponent(0), bg.withAlphaComponent(0.9)])?.draw(in: NSRect(x: bounds.width - 16, y: 0, width: 16, height: bounds.height - 1), angle: 0) }
        if let d = dragging, let r = rs.indices.contains(d.index) ? rs[d.index] : nil {
            t.fg3.setFill(); NSRect(x: max(0, min(bounds.width - 2, d.x - 1)), y: 4, width: 2, height: r.height - 8).fill()
        }
    }

    private func index(at p: NSPoint) -> Int? { rects().firstIndex { $0.contains(p) } }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = index(at: p)
        let onClose = i.map { closeRect(rects()[$0]).contains(p) } ?? false
        if i != hover || onClose != hoverClose { hover = i; hoverClose = onClose; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; hoverClose = false; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        guard let i = index(at: p) else { return }
        if closeRect(rects()[i]).contains(p) { return onAction?(.close(i)) ?? () }
        if e.clickCount == 2 { return onAction?(.keep(i)) ?? () }
        onAction?(.select(i))
        // Drag to reorder: a line shows where the tab lands.
        var target: Int?
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let q = convert(next.locationInWindow, from: nil)
            guard abs(q.x - p.x) > 4 else { continue }
            let rs = rects()
            let slot = rs.firstIndex { q.x < $0.midX } ?? rs.count
            target = slot > i ? slot - 1 : slot
            dragging = (i, slot < rs.count ? rs[slot].minX : (rs.last?.maxX ?? 0))
            needsDisplay = true
        }
        dragging = nil
        needsDisplay = true
        if let target, target != i { onAction?(.move(i, target)) }
    }

    override func otherMouseDown(with e: NSEvent) {
        guard e.buttonNumber == 2, let i = index(at: convert(e.locationInWindow, from: nil)) else { return super.otherMouseDown(with: e) }
        onAction?(.close(i))
    }

    override func rightMouseDown(with e: NSEvent) {
        guard let i = index(at: convert(e.locationInWindow, from: nil)), let m = menuFor?(i) else { return super.rightMouseDown(with: e) }
        NSMenu.popUpContextMenu(m, with: e, for: self)
    }

    override func scrollWheel(with e: NSEvent) {
        let total = widths().reduce(0, +)
        guard total > bounds.width else { return super.scrollWheel(with: e) }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        offset = max(0, min(total - bounds.width, offset - d))
        needsDisplay = true
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let i = index(at: p) else { return nil }
        let r = rects()[i], c = closeRect(r)
        if c.contains(p) { return (Tip("Close").adding("Middle-click a tab closes it too"), c) }
        let tab = tabs[i]
        var tip = Tip(tab.detail)
        if tab.preview { tip = tip.adding("Preview: the next file the session opens replaces it. Double-click to keep it") }
        return (tip, r)
    }
}
