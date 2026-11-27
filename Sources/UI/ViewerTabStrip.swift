import AppKit

/// What a viewer tab was asked to do: from a click, a drag or its menu.
enum ViewerTabAction {
    case select(Int), close(Int), keep(Int), move(Int, Int), closeOthers(Int), closeAll, reveal(Int), copyPath(Int), openInBrowser(Int)
    /// A double-click on a tab: it stops being the preview, and the viewer fills the window or comes back.
    case fill(Int)

    /// The same action on tab `i`, for a strip that shows one tab of many.
    func on(_ i: Int) -> ViewerTabAction {
        switch self {
        case .select: return .select(i)
        case .close: return .close(i)
        case .keep: return .keep(i)
        case .closeOthers: return .closeOthers(i)
        case .reveal: return .reveal(i)
        case .copyPath: return .copyPath(i)
        case .openInBrowser: return .openInBrowser(i)
        case .fill: return .fill(i)
        case .move, .closeAll: return self
        }
    }
}

/// The viewer's tabs, the way VS Code and Cursor draw an editor's: one per open file or artifact,
/// the active one lit like the session tab on show, the preview tab in italics, a dot on a tab that
/// got something new while you were elsewhere.
/// Click to show, × or a middle click to close, double-click to fill the window, drag to reorder
/// (the other tabs make room as you go). When they don't fit, the strip scrolls and ⌄ lists them all.
final class ViewerTabStrip: MXView, TipSource {
    enum Kind: Equatable { case markdown, code, pdf, image, other, artifact }
    struct Tab: Equatable { var title: String; var detail: String; var preview: Bool; var unseen: Bool; var kind: Kind }
    var tabs: [Tab] = [] { didSet { if tabs != oldValue { needsDisplay = true; scrollToActive() } } }
    var active: Int? { didSet { if active != oldValue { scrollToActive(); needsDisplay = true } } }
    var onAction: ((ViewerTabAction) -> Void)?
    /// Builds the right-click menu for a tab (the pane knows whether it is a file or an artifact).
    var menuFor: ((Int) -> NSMenu)?
    private var hover: Int?
    private var hoverClose = false
    private var hoverList = false
    private var offset: CGFloat = 0
    /// A tab being dragged: where it was, the slot it would land in, and the pointer.
    private var drag: (index: Int, slot: Int, x: CGFloat, grab: CGFloat)?

    static let minWidth: CGFloat = 96, maxWidth: CGFloat = 220
    /// As the session tabs: the icon's middle 16 pt in, the title at 28 pt; the × keeps 6 pt from the edge.
    private static let iconX: CGFloat = 16, titleX: CGFloat = 28, closeW: CGFloat = 16, listW: CGFloat = 26

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func font(_ tab: Tab) -> NSFont {
        tab.preview ? (NSFont(name: "JetBrainsMono-Italic", size: Metrics.fontSize) ?? Fonts.mono()) : Fonts.mono()
    }

    // MARK: geometry

    /// As wide as its title. The tab on show keeps its whole title; the others stop at `maxWidth`.
    private func natural(_ i: Int) -> CGFloat {
        let w = Self.titleX + Text.width(tabs[i].title, font: font(tabs[i])) + 4 + Self.closeW + 6
        return i == active ? w : min(Self.maxWidth, w)
    }

    /// The tabs share less room than their full widths: inactive ones show × only on hover.
    private func squeezed(in width: CGFloat) -> Bool { tabs.indices.map(natural).reduce(0, +) > width + 0.5 }

    /// Each tab as wide as its title, never wider than the strip (`TabWidths`).
    private func widths(in width: CGFloat) -> [CGFloat] {
        TabWidths.fit(tabs.indices.map(natural), active: active, in: width, least: Self.minWidth)
    }

    /// The least room that shows the tab on show whole, with ⌄ for the rest.
    var leastWidth: CGFloat {
        guard let a = active, tabs.indices.contains(a) else { return 0 }
        return natural(a) + (tabs.count > 1 ? Self.listW : 0)
    }

    /// Only when even shrunk tabs don't fit does the strip scroll and ⌄ appear.
    private var overflows: Bool { widths(in: bounds.width).reduce(0, +) > bounds.width + 0.5 }
    /// Room for the tabs: the ⌄ list takes the right end when they don't all fit.
    private var tabRoom: CGFloat { overflows ? bounds.width - Self.listW : bounds.width }
    private var listRect: NSRect { NSRect(x: bounds.width - Self.listW, y: 0, width: Self.listW, height: bounds.height) }

    private func widths() -> [CGFloat] { widths(in: tabRoom) }

    /// Where each tab sits, in tab order. While a tab is dragged the others close the gap and open one
    /// at the slot it would land in.
    private func rects() -> [NSRect] {
        let ws = widths()
        var order = Array(tabs.indices)
        if let d = drag { order.remove(at: d.index); order.insert(d.index, at: d.slot) }
        var out = [NSRect](repeating: .zero, count: tabs.count)
        var x = -offset
        for i in order { out[i] = NSRect(x: x, y: 0, width: ws[i], height: bounds.height); x += ws[i] }
        if let d = drag { out[d.index].origin.x = d.x - d.grab }
        return out
    }

    /// How much of a strip this wide the tabs fill: the empty rest moves the panel. Worked out from
    /// the width, not the frame, so the dock can place the panel's grip before the strip lays out.
    func usedWidth(in width: CGFloat) -> CGFloat { min(width, widths(in: width).reduce(0, +)) }

    private func closeRect(_ r: NSRect) -> NSRect { NSRect(x: r.maxX - Self.closeW - 6, y: (r.height - Self.closeW) / 2, width: Self.closeW, height: Self.closeW) }

    private func scrollToActive() {
        let total = widths().reduce(0, +)
        offset = max(0, min(offset, total - tabRoom))
        guard let a = active, a < tabs.count else { return }
        let r = rects()[a]
        if r.maxX > tabRoom { offset += r.maxX - tabRoom }
        if r.minX < 0 { offset += r.minX }
        offset = max(0, offset)
        // Snap so the first visible tab starts at the edge: never a sliver of one cut off.
        let ws = widths()
        var x: CGFloat = 0
        for w in ws { if x >= offset - 0.5 { break }; x += w }
        if x > offset, x <= (ws.prefix(a).reduce(0, +)) { offset = x }
    }

    /// One line, cut in the middle so the extension stays ("decisi…ons.tsv").
    private func drawTitle(_ s: String, in r: NSRect, color: NSColor, font: NSFont) { Self.drawName(s, in: r, color: color, font: font) }

    /// A file name on one line, cut in the middle; shared with the file tree.
    static func drawName(_ s: String, in r: NSRect, color: NSColor, font: NSFont) {
        let p = NSMutableParagraphStyle(); p.lineBreakMode = .byTruncatingMiddle
        let a = NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color, .paragraphStyle: p])
        let h = font.ascender - font.descender
        a.draw(with: NSRect(x: r.minX, y: r.minY + (r.height - h) / 2 - 0.5, width: max(0, r.width), height: h + 2), options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// New since you last looked: the "your turn" colour, so it can't pass for an unsaved dot.
    private var newColor: NSColor { t.color(for: .yourTurn) }

    override func layout() { super.layout(); scrollToActive() }

    // MARK: drawing

    private static func symbol(_ k: Kind) -> String {
        switch k {
        case .markdown: return "doc.text"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .pdf: return "doc.richtext"
        case .image: return "photo"
        case .other: return "doc"
        case .artifact: return "globe"
        }
    }

    private func drawIcon(_ k: Kind, at p: NSPoint, color: NSColor) { Self.drawKind(k, at: p, color: color) }

    /// A file's kind as a small symbol, shared with the file tree; nil is a folder.
    static func drawKind(_ k: Kind?, at p: NSPoint, color: NSColor, size: CGFloat = 10) {
        let cfg = NSImage.SymbolConfiguration(pointSize: size, weight: .regular).applying(.init(paletteColors: [color]))
        guard let img = NSImage(systemSymbolName: k.map(symbol) ?? "folder", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) else { return }
        let s = img.size
        img.draw(in: NSRect(x: p.x - s.width / 2, y: p.y - s.height / 2, width: s.width, height: s.height), from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: true, hints: nil)
    }

    private func lifted(_ i: Int) -> Bool { drag?.index == i }
    private var squeezed: Bool { squeezed(in: tabRoom) }

    override func draw(_ r: NSRect) {
        let rs = rects()
        t.hair.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        NSGraphicsContext.saveGraphicsState()
        NSRect(x: 0, y: 0, width: tabRoom, height: bounds.height).clip()
        let order = tabs.indices.sorted { a, b in a == drag?.index ? false : b == drag?.index ? true : a < b }
        for i in order {
            let tab = tabs[i], rr = rs[i]
            // Only whole tabs show at the right end (a dragged one may hang over it): no letter cut off against ⌄.
            guard rr.maxX > 0, rr.minX < tabRoom, rr.maxX <= tabRoom + 0.5 || lifted(i) || !overflows else { continue }
            let sel = i == active, lifted = i == drag?.index, hot = hover == i && drag == nil
            // Lit the way the session tab on show is, so both groups read the same.
            if sel || lifted { t.hover.setFill(); NSRect(x: rr.minX, y: 0, width: rr.width, height: rr.height - 1).fill() }
            else if hot { t.hover.withAlphaComponent(0.5).setFill(); NSRect(x: rr.minX, y: 0, width: rr.width, height: rr.height - 1).fill() }
            t.hair2.setFill()
            NSRect(x: rr.maxX - 1, y: 0, width: 1, height: rr.height - 1).fill()
            let ink = sel ? t.fg : hot ? t.fg2 : t.fg3
            drawIcon(tab.kind, at: NSPoint(x: rr.minX + Self.iconX, y: rr.midY), color: sel ? t.fg2 : t.fg3)
            // Squeezed, a tab gives its name the room the × took, and shows × only on hover.
            let compact = squeezed
            let textX = rr.minX + Self.titleX
            let textEnd = compact && !sel && !hot ? rr.maxX - (tab.unseen ? 20 : 8) : rr.maxX - Self.closeW - 10
            drawTitle(tab.title, in: NSRect(x: textX, y: 0, width: textEnd - textX, height: rr.height), color: ink, font: font(tab))
            let c = closeRect(rr)
            if sel || hot {
                if hot, hoverClose { t.hover.setFill(); NSBezierPath(roundedRect: c, xRadius: 3, yRadius: 3).fill() }
                let p = NSBezierPath(); p.lineWidth = 1.2; p.lineCapStyle = .round
                let m = NSPoint(x: c.midX, y: c.midY)
                p.move(to: NSPoint(x: m.x - 3.5, y: m.y - 3.5)); p.line(to: NSPoint(x: m.x + 3.5, y: m.y + 3.5))
                p.move(to: NSPoint(x: m.x + 3.5, y: m.y - 3.5)); p.line(to: NSPoint(x: m.x - 3.5, y: m.y + 3.5))
                (hot && hoverClose ? t.fg : t.fg3).setStroke(); p.stroke()
            } else if tab.unseen {
                // Where the × would be: something new is in this tab.
                newColor.setFill(); NSBezierPath(ovalIn: NSRect(x: c.midX - 3, y: c.midY - 3, width: 6, height: 6)).fill()
            }
        }
        NSGraphicsContext.restoreGraphicsState()
        if overflows {
            let lr = listRect
            if hoverList { t.hover.setFill(); NSBezierPath(roundedRect: lr.insetBy(dx: 2, dy: 4), xRadius: 4, yRadius: 4).fill() }
            t.hair2.setFill(); NSRect(x: lr.minX, y: 0, width: 1, height: lr.height - 1).fill()
            // A tab out of sight has something new: ⌄ takes the same colour as that tab's dot.
            let hiddenNew = tabs.indices.contains { tabs[$0].unseen && (rs[$0].maxX > tabRoom || rs[$0].minX < 0) }
            Self.drawList(in: lr, color: hiddenNew ? newColor : hoverList ? t.fg : t.fg2)
        }
    }

    /// ⌄, the list of tabs out of sight; the session tabs' too.
    static func drawList(in lr: NSRect, color: NSColor) {
        let p = NSBezierPath(); p.lineWidth = 1.1; p.lineCapStyle = .round; p.lineJoinStyle = .round
        p.move(to: NSPoint(x: lr.midX - 3.5, y: lr.midY - 1.5)); p.line(to: NSPoint(x: lr.midX, y: lr.midY + 2)); p.line(to: NSPoint(x: lr.midX + 3.5, y: lr.midY - 1.5))
        color.setStroke(); p.stroke()
    }

    // MARK: mouse

    private func index(at p: NSPoint) -> Int? {
        guard p.x < tabRoom else { return nil }
        return rects().firstIndex { $0.contains(p) && (!overflows || $0.maxX <= tabRoom + 0.5) }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = index(at: p)
        let onClose = i.map { closeRect(rects()[$0]).contains(p) } ?? false
        let onList = overflows && listRect.contains(p)
        if i != hover || onClose != hoverClose || onList != hoverList { hover = i; hoverClose = onClose; hoverList = onList; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; hoverClose = false; hoverList = false; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if overflows, listRect.contains(p) { return showList() }
        // The empty end of the row moves the window, as the rest of the title bar does.
        guard let i = index(at: p) else { return e.clickCount == 2 ? window?.performZoom(nil) ?? () : window?.performDrag(with: e) ?? () }
        let r0 = rects()[i]
        if closeRect(r0).contains(p) { return onAction?(.close(i)) ?? () }
        if e.clickCount == 2 { return onAction?(.fill(i)) ?? () }
        onAction?(.select(i))
        // Drag to reorder: the tab follows the pointer and the others make room.
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]) {
            if next.type == .leftMouseUp { break }
            let q = convert(next.locationInWindow, from: nil)
            guard drag != nil || abs(q.x - p.x) > 4 else { continue }
            let grab = drag?.grab ?? (p.x - r0.minX)
            // The slot: how many other tabs' middles lie left of the dragged tab's middle.
            let ws = widths()
            var x = -offset, slot = 0
            let mid = q.x - grab + ws[i] / 2
            for j in tabs.indices where j != i { if x + ws[j] / 2 < mid { slot += 1 }; x += ws[j] }
            drag = (i, slot, q.x, grab)
            needsDisplay = true
        }
        let landed = drag?.slot
        drag = nil
        needsDisplay = true
        if let landed, landed != i { onAction?(.move(i, landed)) }
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
        guard total > tabRoom else { return super.scrollWheel(with: e) }
        let d = abs(e.scrollingDeltaX) > abs(e.scrollingDeltaY) ? e.scrollingDeltaX : e.scrollingDeltaY
        offset = max(0, min(total - tabRoom, offset - d))
        needsDisplay = true
    }

    /// ⌄: every open tab, the one on show ticked, new ones marked.
    func showList() {
        let m = NSMenu()
        for (i, tab) in tabs.enumerated() {
            let item = MenuAction(tab.title + (tab.unseen ? "  •" : "")) { [weak self] in self?.onAction?(.select(i)) }
            item.state = i == active ? .on : .off
            item.toolTip = tab.detail
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: listRect.minX, y: bounds.maxY + 2), in: self)
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if overflows, listRect.contains(p) {
            let rs = rects()
            let hiddenNew = tabs.indices.contains { tabs[$0].unseen && (rs[$0].maxX > tabRoom || rs[$0].minX < 0) }
            return (Tip("All open tabs").adding(hiddenNew ? "A tab out of sight has something new" : "\(tabs.count) open"), listRect)
        }
        guard let i = index(at: p) else { return nil }
        let r = rects()[i], c = closeRect(r)
        if c.contains(p) { return (Tip("Close").adding("Middle-click a tab closes it too, ⌘W in the viewer closes the one on show"), c) }
        let tab = tabs[i]
        var tip = Tip(tab.detail)
        if tab.unseen { tip = tip.adding("New since you last looked") }
        if tab.preview { tip = tip.adding("Preview: the session's next file replaces it. ⌥⌘P or a double-click keeps it") }
        return (tip, r)
    }
}
