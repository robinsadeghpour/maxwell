import AppKit

/// Title bar: traffic lights (system), the session and terminal tabs with + after them, the
/// current session's documents when the viewer is on screen, and search, settings and the right
/// side's button at the far right. One row of tabs for the whole window, like an IDE's editor
/// groups: the viewer's tabs head the viewer, right of the line where it begins.
final class TitleBar: MXView, TipSource {
    /// A session's tab shows its state; a plain terminal's (no group) a prompt mark.
    struct Tab { var id: SessionID; var title: String; var group: PhaseGroup? }
    /// Where the current session's documents sit in the row.
    enum Docs: Equatable {
        /// No viewer on screen: the session tabs have the row.
        case none
        /// The viewer beside the session: the row splits at the pane line, `x` in the title bar.
        case beside(at: CGFloat)
        /// The viewer fills the window: the session's own tab (to click back), then its documents.
        case filling
    }
    var tabs: [Tab] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var current: SessionID? { didSet { needsLayout = true; needsDisplay = true } }
    var docs = Docs.none { didSet { if docs != oldValue { needsLayout = true; needsDisplay = true } } }
    /// The viewer's tabs and buttons (`ViewerHeader`), placed after the line.
    var docTabs: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let v = docTabs { addSubview(v) }
            needsLayout = true
        }
    }
    var onSelect: ((SessionID) -> Void)?
    /// A double-click on a tab: the session fills the window, or comes back.
    var onFill: ((SessionID) -> Void)?
    var onCloseTab: ((SessionID) -> Void)?
    let plus = IconButton(.plus, tip: Tip("New session", action: "new-session"))
    let palette = IconButton(.search, tip: Tip("Search sessions, projects and actions", action: "search"))
    let gear = IconButton(.gear, tip: Tip("Settings", action: "settings"))
    /// Show or hide the left and right areas, as in Xcode, VS Code and Cursor.
    let leftToggle = IconButton(.sidebarLeft, tip: Tip("Show or hide the left panels", action: "toggle-left"))
    let rightToggle = IconButton(.sidebarRight, tip: Tip("Show or hide the right panels", action: "toggle-right"))
    private var hoverTab: Int?
    /// Where search, settings and the right side's button begin.
    private var buttonsStart: CGFloat = 0
    /// Room for the traffic lights; full screen hides them, so the tabs start at the edge.
    var fullScreen = false { didSet { needsDisplay = true; needsLayout = true } }
    private var leftInset: CGFloat { (fullScreen ? 8 : 84) + (leftToggle.isHidden ? 0 : 30) }
    private static let maxTab: CGFloat = 220, plusWidth: CGFloat = 30
    /// Between the viewer's buttons and search, settings and the right side's button.
    private static let gap: CGFloat = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        [leftToggle, plus, palette, gear, rightToggle].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// The tabs on show: all of them, or only the current session's while its viewer fills the window.
    private var shownTabs: [Tab] { docs == .filling ? tabs.filter { $0.id == current } : tabs }

    /// Where the line between the session's tabs and its documents is, if there is one.
    private var split: CGFloat? {
        switch docs {
        case .none: return nil
        case .beside(let x): return min(x, buttonsStart)
        case .filling: return leftInset + (shownTabs.isEmpty ? 0 : Self.maxTab)
        }
    }

    override func layout() {
        super.layout()
        let y = (bounds.height - Metrics.control) / 2
        leftToggle.frame = NSRect(x: fullScreen ? 6 : 80, y: y, width: 26, height: Metrics.control)
        var x = bounds.width - 8
        for b in [rightToggle, gear, palette] where !b.isHidden {
            x -= 28
            b.frame = NSRect(x: x, y: y, width: 26, height: Metrics.control)
        }
        buttonsStart = x
        let rects = tabRects()
        plus.isHidden = docs == .filling
        plus.frame = NSRect(x: (rects.last?.maxX ?? leftInset) + 2, y: y, width: 26, height: Metrics.control)
        docTabs?.isHidden = split == nil
        if let s = split { docTabs?.frame = NSRect(x: s + 1, y: 0, width: max(0, buttonsStart - Self.gap - s - 1), height: bounds.height) }
    }

    private func tabRects() -> [NSRect] {
        let shown = shownTabs
        let end = split ?? buttonsStart - 8
        let avail = end - leftInset - (docs == .filling ? 0 : Self.plusWidth)
        guard !shown.isEmpty, avail > 0 else { return [] }
        let w = min(Self.maxTab, avail / CGFloat(shown.count))
        return shown.indices.map { NSRect(x: leftInset + CGFloat($0) * w, y: 0, width: w, height: bounds.height - 1) }
    }

    override func draw(_ r: NSRect) {
        t.hair.setFill()
        // The documents draw their own bottom line, open under the active tab.
        let docs = docTabs.flatMap { $0.isHidden ? nil : $0.frame }
        NSRect(x: 0, y: bounds.height - 1, width: docs?.minX ?? bounds.width, height: 1).fill()
        if let docs {
            NSRect(x: docs.maxX, y: bounds.height - 1, width: bounds.width - docs.maxX, height: 1).fill()
            NSRect(x: docs.minX - 1, y: 0, width: 1, height: bounds.height).fill()
        }
        let rects = tabRects(), shown = shownTabs
        for (i, tab) in shown.enumerated() {
            let rr = rects[i]
            let sel = tab.id == current
            if sel { t.hover.setFill(); rr.fill() }
            t.hair2.setFill()
            NSRect(x: rr.minX, y: 0, width: 1, height: rr.height).fill()
            if i == shown.count - 1 { NSRect(x: rr.maxX - 1, y: 0, width: 1, height: rr.height).fill() }
            if let g = tab.group {
                Glyph.draw(g, at: NSPoint(x: rr.minX + 16, y: rr.midY), color: t.color(for: g))
            } else {
                Text.draw("❯", in: NSRect(x: rr.minX + 10, y: 0, width: 12, height: rr.height), color: sel ? t.fg : t.fg2, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
            }
            let closeW: CGFloat = hoverTab == i ? 18 : 0
            Text.draw(tab.title, in: NSRect(x: rr.minX + 28, y: 0, width: rr.width - 36 - closeW, height: rr.height),
                      color: sel ? t.fg : hoverTab == i ? t.fg2 : t.fg3)
            if hoverTab == i {
                Text.draw("×", in: NSRect(x: rr.maxX - 20, y: 0, width: 14, height: rr.height), color: t.fg3, align: .center)
            }
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = tabRects().firstIndex { $0.contains(p) }
        if i != hoverTab { hoverTab = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverTab = nil; needsDisplay = true }

    /// A tab: the close mark, the state glyph, or the full title (tabs cut long ones short).
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        let rects = tabRects()
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return nil }
        let r = rects[i], tab = shownTabs[i]
        if p.x > r.maxX - 22 {
            let keeps = tab.group == nil ? "The terminal keeps running in the sidebar" : "The session keeps running"
            return (Tip("Close tab", action: tab.id == current ? "close-tab" : nil).adding(keeps), NSRect(x: r.maxX - 22, y: r.minY, width: 22, height: r.height))
        }
        if p.x < r.minX + 26 { return (tab.group?.tip ?? Tip("Terminal"), NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height)) }
        let fill = docs == .filling ? "Click to show the session beside it again" : "Double-click to fill the window"
        return (Tip(tab.title).adding(fill), NSRect(x: r.minX + 26, y: r.minY, width: r.width - 48, height: r.height))
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let rects = tabRects()
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
            return
        }
        let id = shownTabs[i].id
        if p.x > rects[i].maxX - 22 { onCloseTab?(id) } else if e.clickCount == 2 { onFill?(id) } else { onSelect?(id) }
    }
    override func mouseDragged(with e: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}
