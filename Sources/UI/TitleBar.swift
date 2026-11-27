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
        /// The session fills the window: its tabs, then the document on show (to click back).
        case peek
    }
    var tabs: [Tab] = [] { didSet { needsLayout = true; needsDisplay = true } }
    var current: SessionID? { didSet { needsLayout = true; needsDisplay = true } }
    var docs = Docs.none {
        didSet {
            guard docs != oldValue else { return }
            docTabs?.peek = docs == .peek
            needsLayout = true; needsDisplay = true
        }
    }
    /// The viewer's tabs and buttons, placed after the line.
    var docTabs: ViewerHeader? {
        didSet {
            oldValue?.removeFromSuperview()
            if let v = docTabs { addSubview(v) }
            needsLayout = true
        }
    }
    /// What a click lands on in the row.
    enum ClickTarget: Equatable { case session(SessionID), doc(Int), control }
    /// The first click of a possible double-click and what it was on. A first click can move the
    /// row under the pointer (the split coming back, a tab growing, a tab closing), so the second
    /// click goes to what the first one was on, never to what moved there.
    private var firstClick: (target: ClickTarget, at: NSPoint, time: TimeInterval)?
    /// A press the guard took: its release goes nowhere either, or a button would fire on it.
    private var tookPress = false
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
    private var hoverList = false
    /// Where search, settings and the right side's button begin.
    private var buttonsStart: CGFloat = 0
    /// Room for the traffic lights; full screen hides them, so the tabs start at the edge.
    var fullScreen = false { didSet { needsDisplay = true; needsLayout = true } }
    private var leftInset: CGFloat { (fullScreen ? 8 : 84) + (leftToggle.isHidden ? 0 : 30) }
    private static let plusWidth: CGFloat = 30
    /// Between the viewer's buttons and search, settings and the right side's button.
    private static let gap: CGFloat = 10

    /// The row as laid out: the line, the session tabs on show and where, and the ⌄ for the rest.
    private struct Plan {
        var split: CGFloat?
        var shown: [Tab] = []
        var rects: [NSRect] = []
        var list: NSRect?
        var hidden: [Tab] = []
    }
    private var plan = Plan()

    override init(frame: NSRect) {
        super.init(frame: frame)
        [leftToggle, plus, palette, gear, rightToggle].forEach(addSubview)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

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
        plan = makePlan()
        plus.isHidden = docs == .filling
        plus.frame = NSRect(x: (plan.list ?? plan.rects.last)?.maxX ?? leftInset, y: y, width: 26, height: Metrics.control).offsetBy(dx: 2, dy: 0)
        docTabs?.isHidden = plan.split == nil
        if let s = plan.split { docTabs?.frame = NSRect(x: s + 1, y: 0, width: max(0, buttonsStart - Self.gap - s - 1), height: bounds.height) }
        needsDisplay = true
    }

    private func makePlan() -> Plan {
        let end = buttonsStart - Self.gap, least = docTabs?.leastWidth ?? 0
        let h = bounds.height - 1
        switch docs {
        case .filling:
            let mine = tabs.filter { $0.id == current }
            return Plan(split: leftInset + (mine.isEmpty ? 0 : TitleRow.sessionMost), shown: mine,
                        rects: mine.map { _ in NSRect(x: leftInset, y: 0, width: TitleRow.sessionMost, height: h) })
        case .none, .beside, .peek:
            var plan = Plan()
            switch docs {
            case .beside(let line): plan.split = line
            case .peek: plan.split = TitleRow.peekSplit(start: leftInset, end: end, docsLeast: least, reserve: Self.plusWidth)
            default: plan.split = nil
            }
            let room = (plan.split ?? buttonsStart - 8) - Self.plusWidth - leftInset
            let fit = TitleRow.sessions(count: tabs.count, current: tabs.firstIndex { $0.id == current }, room: room)
            plan.shown = fit.shown.map { tabs[$0] }
            plan.rects = fit.shown.indices.map { NSRect(x: leftInset + CGFloat($0) * fit.width, y: 0, width: fit.width, height: h) }
            if fit.overflow {
                plan.list = NSRect(x: leftInset + CGFloat(fit.shown.count) * fit.width, y: 0, width: TitleRow.list, height: h)
                plan.hidden = tabs.indices.filter { !fit.shown.contains($0) }.map { tabs[$0] }
            }
            return plan
        }
    }

    override func draw(_ r: NSRect) {
        t.hair.setFill()
        NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1).fill()
        if let s = plan.split { NSRect(x: s, y: 0, width: 1, height: bounds.height).fill() }
        for (i, tab) in plan.shown.enumerated() {
            let rr = plan.rects[i]
            let sel = tab.id == current, hot = hoverTab == i
            if sel { t.hover.setFill(); rr.fill() } else if hot { t.hover.withAlphaComponent(0.5).setFill(); rr.fill() }
            t.hair2.setFill()
            NSRect(x: rr.minX, y: 0, width: 1, height: rr.height).fill()
            if i == plan.shown.count - 1 { NSRect(x: rr.maxX - 1, y: 0, width: 1, height: rr.height).fill() }
            if let g = tab.group {
                Glyph.draw(g, at: NSPoint(x: rr.minX + 16, y: rr.midY), color: t.color(for: g))
            } else {
                Text.draw("❯", in: NSRect(x: rr.minX + 10, y: 0, width: 12, height: rr.height), color: sel ? t.fg : t.fg2, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
            }
            let closeW: CGFloat = hot ? 18 : 0
            Text.draw(tab.title, in: NSRect(x: rr.minX + 28, y: 0, width: rr.width - 36 - closeW, height: rr.height),
                      color: sel ? t.fg : hot ? t.fg2 : t.fg3)
            if hot { Text.draw("×", in: NSRect(x: rr.maxX - 20, y: 0, width: 14, height: rr.height), color: t.fg3, align: .center) }
        }
        if let lr = plan.list {
            if hoverList { t.hover.setFill(); NSBezierPath(roundedRect: lr.insetBy(dx: 2, dy: 6), xRadius: 4, yRadius: 4).fill() }
            // A tab out of sight that needs you: ⌄ takes its colour.
            let needs = plan.hidden.contains { $0.group == .needsYou }
            ViewerTabStrip.drawList(in: lr, color: needs ? t.color(for: .needsYou) : hoverList ? t.fg : t.fg2)
        }
    }

    override func mouseMoved(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        let i = plan.rects.firstIndex { $0.contains(p) }
        let onList = plan.list?.contains(p) ?? false
        if i != hoverTab || onList != hoverList { hoverTab = i; hoverList = onList; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hoverTab = nil; hoverList = false; needsDisplay = true }

    /// A tab: the close mark, the state glyph, or the full title (tabs cut long ones short).
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if let lr = plan.list, lr.contains(p) { return (Tip("More tabs").adding("\(plan.hidden.count) out of sight"), lr) }
        let rects = plan.rects
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else { return nil }
        let r = rects[i], tab = plan.shown[i]
        if p.x > r.maxX - 22 {
            let keeps = tab.group == nil ? "The terminal keeps running in the sidebar" : "The session keeps running"
            return (Tip("Close tab", action: tab.id == current ? "close-tab" : nil).adding(keeps), NSRect(x: r.maxX - 22, y: r.minY, width: 22, height: r.height))
        }
        if p.x < r.minX + 26 { return (tab.group?.tip ?? Tip("Terminal"), NSRect(x: r.minX + 6, y: r.minY, width: 20, height: r.height)) }
        let fill = docs == .filling ? "Click to show the session beside it again" : "Double-click to fill the window"
        return (Tip(tab.title).adding(fill), NSRect(x: r.minX + 26, y: r.minY, width: r.width - 48, height: r.height))
    }

    private func clickTarget(at p: NSPoint) -> ClickTarget? {
        if let lr = plan.list, lr.contains(p) { return .control }
        if let i = plan.rects.firstIndex(where: { $0.contains(p) }) { return p.x > plan.rects[i].maxX - 22 ? .control : .session(plan.shown[i].id) }
        if let d = docTabs, !d.isHidden, d.frame.contains(p) { return d.clickTarget(at: convert(p, to: d)) }
        if [leftToggle, plus, palette, gear, rightToggle].contains(where: { !$0.isHidden && $0.frame.contains(p) }) { return .control }
        return nil
    }

    /// Sees every press and release in the window before any view does (`MXWindow.onClick`). Notes
    /// what a first click lands on, and takes the clicks that follow it within the double-click
    /// time: AppKit sends those to the view that got the first click, at the same window point,
    /// even when that point now shows something else. Returns whether it took the event.
    func guardClick(_ e: NSEvent) -> Bool {
        if e.type == .leftMouseUp { defer { tookPress = false }; return tookPress }
        tookPress = guardPress(e)
        return tookPress
    }

    private func guardPress(_ e: NSEvent) -> Bool {
        let p = convert(e.locationInWindow, from: nil)
        guard e.clickCount >= 2 else {
            firstClick = bounds.contains(p) ? clickTarget(at: p).map { ($0, e.locationInWindow, e.timestamp) } : nil
            return false
        }
        guard let f = firstClick, e.timestamp - f.time <= NSEvent.doubleClickInterval * Double(e.clickCount - 1),
              hypot(e.locationInWindow.x - f.at.x, e.locationInWindow.y - f.at.y) < 6 else { return false }
        // A double-click on a tab fills the window with its half; a button already had its click.
        guard e.clickCount == 2 else { return true }
        switch f.target {
        case .session(let id): onFill?(id)
        case .doc(let i): docTabs?.onTab?(.fill(i))
        case .control: break
        }
        return true
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let lr = plan.list, lr.contains(p) { return showHidden(below: lr) }
        let rects = plan.rects
        guard let i = rects.firstIndex(where: { $0.contains(p) }) else {
            if e.clickCount == 2 { window?.performZoom(nil) } else { window?.performDrag(with: e) }
            return
        }
        let id = plan.shown[i].id
        if p.x > rects[i].maxX - 22 { onCloseTab?(id) } else { onSelect?(id) }
    }
    /// ⌄: the tabs out of sight; picking one shows it.
    private func showHidden(below lr: NSRect) {
        let m = NSMenu()
        for tab in plan.hidden {
            let item = MenuAction(tab.title) { [weak self] in self?.onSelect?(tab.id) }
            item.image = Self.glyphImage(tab, theme: t)
            m.addItem(item)
        }
        m.popUp(positioning: nil, at: NSPoint(x: lr.minX, y: lr.maxY + 2), in: self)
    }

    /// A tab's state glyph in its colour (a terminal's prompt mark), for the ⌄ menu.
    private static func glyphImage(_ tab: Tab, theme t: Theme) -> NSImage {
        NSImage(size: NSSize(width: 14, height: 14), flipped: true) { r in
            if let g = tab.group {
                Glyph.draw(g, at: NSPoint(x: r.midX, y: r.midY), color: t.color(for: g))
            } else {
                Text.draw("❯", in: r, color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
            }
            return true
        }
    }

    override func mouseDragged(with e: NSEvent) {}
    override var mouseDownCanMoveWindow: Bool { false }
}
