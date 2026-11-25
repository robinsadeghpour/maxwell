import AppKit


/// The buttons on a panel's header: ⋯ options, ⤢ fill the window (⇧⌘↩, or double-click the
/// header), and × to hide the panel.
final class PanelControls: MXView {
    let panel: PanelID
    weak var root: RootView?
    /// The panel's name, for the tips.
    var title = "" { didSet { if title != oldValue { rebuild() } } }
    var maximized = false { didSet { if maximized != oldValue { rebuild() } } }
    private var buttons: [IconButton] = []

    init(panel: PanelID) {
        self.panel = panel
        super.init(frame: .zero)
        rebuild()
    }
    required init?(coder: NSCoder) { fatalError() }

    var preferredWidth: CGFloat { CGFloat(buttons.count) * 22 }

    private func rebuild() {
        buttons.forEach { $0.removeFromSuperview() }
        let p = panel
        buttons = [
            IconButton(.more, tip: Tip("Move or hide \(title)")) { [weak self] in
                guard let self, let b = self.buttons.first else { return }
                self.root?.showMenu(for: p, below: b)
            },
        ]
        if p.canFill { buttons.append(
            IconButton(maximized ? .collapse : .expand, tip: Tip(maximized ? "Back to normal size" : "Fill the window", action: "maximize-panel")) { [weak self] in
                guard let root = self?.root, let d = root.panels.place[p] else { return }
                root.toggleMaximize(d)
            }) }
        buttons.append(
            IconButton(.minimize, tip: Tip("Hide \(title)", action: "panel-\(p.rawValue)")) { [weak self] in self?.root?.setHidden(p, true) })
        buttons.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() { b.frame = NSRect(x: CGFloat(i) * 22, y: 0, width: 22, height: bounds.height) }
    }
}

/// Invisible handle over a panel's header: drag to move the panel, double-click to fill the
/// window, right-click for "Move to".
final class PanelGrip: NSView, TipSource {
    let panel: PanelID
    weak var root: RootView?
    init(panel: PanelID) { self.panel = panel; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2, panel.canFill, let root, let d = root.panels.place[panel] { return root.toggleMaximize(d) }
        root?.dragPanel(panel, from: e)
    }
    override func rightMouseDown(with e: NSEvent) { root?.showMenu(for: panel, event: e) }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
    /// The grip lies over the panel's header; the header's own tips show through it.
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let c = root?.content(panel) as? (NSView & TipSource), let r = c.tip(at: c.convert(p, from: self)) else { return nil }
        return (r.tip, convert(r.rect, from: c))
    }
}

/// The lit-up area under a dragged panel.
final class DropPreview: MXView {
    var label = "" { didSet { needsDisplay = true } }
    override init(frame: NSRect) { super.init(frame: frame); wantsLayer = true }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ r: NSRect) {
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        t.hover.setFill(); path.fill()
        t.fg3.setStroke(); path.lineWidth = 1; path.setLineDash([4, 3], count: 2, phase: 0); path.stroke()
        Text.draw(label, in: bounds, color: t.fg2, font: Fonts.mono(Metrics.fontSize - 1), align: .center)
    }
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// A hidden rail's grip on the window's left edge: a faint mark that brightens as the pointer
/// arrives, and opens the rail on click.
final class RailHandle: MXView, TipSource {
    var onOpen: (() -> Void)?
    var lit = false { didSet { if lit != oldValue { needsDisplay = true } } }
    var tipsBeside: Bool { true }
    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        (Tip("Projects", action: "toggle-rail").adding("Rest at the left edge, or click"), bounds)
    }
    override func mouseDown(with e: NSEvent) { onOpen?() }
    override func draw(_ r: NSRect) {
        let h: CGFloat = 36
        let grip = NSRect(x: 3, y: bounds.midY - h / 2, width: 3, height: h)
        (lit ? t.fg2 : t.fg3.withAlphaComponent(0.45)).setFill()
        NSBezierPath(roundedRect: grip, xRadius: 1.5, yRadius: 1.5).fill()
    }
}

/// A side's tool window bar, JetBrains New UI style: one icon per panel, lit while it shows, a
/// count of what needs you in it. Only a side with two or more panels has one.
final class Stripe: MXView, TipSource {
    var tipsBeside: Bool { true }
    enum Badge: Equatable { case count(Int), dot, warning }
    struct Item: Equatable { var panel: PanelID; var title: String; var open: Bool; var badge: Badge? }
    static let width: CGFloat = 28
    let side: Dock
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var onToggle: ((PanelID) -> Void)?
    var onMenu: ((PanelID, NSEvent) -> Void)?
    private var hover: Int?
    private var pressed: Int?

    init(side: Dock) {
        self.side = side
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rects() -> [NSRect] {
        items.indices.map { NSRect(x: 3, y: Metrics.header / 2 - 12 + CGFloat($0) * 28, width: bounds.width - 6, height: 24) }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let i = index(at: p) else { return nil }
        let it = items[i]
        var tip = Tip(it.title, action: "panel-\(it.panel.rawValue)")
        if case .count(let n)? = it.badge { tip = tip.adding("\(n) waiting for you") }
        if it.badge == .dot { tip = tip.adding("Something new opened here") }
        if it.badge == .warning { tip = tip.adding("The plugin stopped") }
        return (tip, rects()[i])
    }

    override func draw(_ r: NSRect) {
        t.plane.setFill(); bounds.fill()
        for (i, (it, rr)) in zip(items, rects()).enumerated() {
            if pressed == i || it.open { t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            else if hover == i { t.hover.setFill(); NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4).fill() }
            PanelGlyph.draw(it.panel, title: it.title, in: rr, color: hover == i || it.open ? t.fg : t.fg2, theme: t)
            if let b = it.badge { PanelGlyph.badge(b, at: NSPoint(x: rr.maxX - 3, y: rr.minY + 4), theme: t) }
        }
    }

    private func index(at p: NSPoint) -> Int? { rects().firstIndex { $0.contains(p) } }
    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) { pressed = index(at: convert(e.locationInWindow, from: nil)); needsDisplay = true }
    override func mouseUp(with e: NSEvent) {
        defer { pressed = nil; needsDisplay = true }
        guard let i = pressed, index(at: convert(e.locationInWindow, from: nil)) == i else { return }
        onToggle?(items[i].panel)
    }
    override func rightMouseDown(with e: NSEvent) {
        if let i = index(at: convert(e.locationInWindow, from: nil)) { onMenu?(items[i].panel, e) }
    }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    // Drawn by hand, so each icon tells VoiceOver it is a button, what it shows and whether it is open.
    override func isAccessibilityElement() -> Bool { false }
    override func accessibilityChildren() -> [Any]? {
        zip(items, rects()).map { it, r in
            var label = it.title
            if case .count(let n)? = it.badge { label += ", \(n) waiting for you" }
            return PressElement(parent: self, frame: r, label: label, selected: it.open) { [weak self] in self?.onToggle?(it.panel) }
        }
    }
}

/// A hand-drawn control's stand-in for VoiceOver: a button that can be pressed.
final class PressElement: NSAccessibilityElement {
    private let press: () -> Void
    init(parent: NSView, frame: NSRect, label: String, selected: Bool, press: @escaping () -> Void) {
        self.press = press
        super.init()
        setAccessibilityParent(parent)
        setAccessibilityRole(.button)
        setAccessibilityLabel(label)
        setAccessibilitySelected(selected)
        setAccessibilityFrameInParentSpace(frame)
    }
    override func accessibilityPerformPress() -> Bool { press(); return true }
}

/// The small line icons that stand for a panel on a stripe and in the status bar. A plugin's
/// panel has no drawing of its own: it gets the first letter of its title.
enum PanelGlyph {
    static func draw(_ p: PanelID, title: String, in r: NSRect, color: NSColor, theme t: Theme) {
        let c = NSPoint(x: r.midX, y: r.midY)
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        color.setStroke()
        switch p {
        case .sessions:
            for dy in [-4.0, 0, 4] {
                path.appendRect(NSRect(x: c.x - 6, y: c.y + dy - 0.75, width: 1.5, height: 1.5))
                path.move(to: NSPoint(x: c.x - 2.5, y: c.y + dy)); path.line(to: NSPoint(x: c.x + 6, y: c.y + dy))
            }
        case .viewer:
            path.move(to: NSPoint(x: c.x + 1.5, y: c.y - 6.5)); path.line(to: NSPoint(x: c.x - 5, y: c.y - 6.5))
            path.line(to: NSPoint(x: c.x - 5, y: c.y + 6.5)); path.line(to: NSPoint(x: c.x + 5, y: c.y + 6.5))
            path.line(to: NSPoint(x: c.x + 5, y: c.y - 2.5)); path.line(to: NSPoint(x: c.x + 1.5, y: c.y - 6.5))
            path.line(to: NSPoint(x: c.x + 1.5, y: c.y - 2.5)); path.line(to: NSPoint(x: c.x + 5, y: c.y - 2.5))
            path.move(to: NSPoint(x: c.x - 2.5, y: c.y + 1)); path.line(to: NSPoint(x: c.x + 2.5, y: c.y + 1))
            path.move(to: NSPoint(x: c.x - 2.5, y: c.y + 3.5)); path.line(to: NSPoint(x: c.x + 2.5, y: c.y + 3.5))
        case .usage:
            // A meter: three bars of rising height on a baseline.
            for (i, h) in [3.0, 6, 9].enumerated() {
                let x = c.x - 4.5 + CGFloat(i) * 4.5
                path.move(to: NSPoint(x: x, y: c.y + 5)); path.line(to: NSPoint(x: x, y: c.y + 5 - CGFloat(h)))
            }
        case .system:
            // A chip: a square with pins on each side.
            path.appendRoundedRect(NSRect(x: c.x - 4, y: c.y - 4, width: 8, height: 8), xRadius: 1.5, yRadius: 1.5)
            for o in [-2.0, 2] {
                path.move(to: NSPoint(x: c.x + CGFloat(o), y: c.y - 4)); path.line(to: NSPoint(x: c.x + CGFloat(o), y: c.y - 6.5))
                path.move(to: NSPoint(x: c.x + CGFloat(o), y: c.y + 4)); path.line(to: NSPoint(x: c.x + CGFloat(o), y: c.y + 6.5))
                path.move(to: NSPoint(x: c.x - 4, y: c.y + CGFloat(o))); path.line(to: NSPoint(x: c.x - 6.5, y: c.y + CGFloat(o)))
                path.move(to: NSPoint(x: c.x + 4, y: c.y + CGFloat(o))); path.line(to: NSPoint(x: c.x + 6.5, y: c.y + CGFloat(o)))
            }
        default:
            let letter = String(title.first.map { String($0).uppercased() } ?? "?")
            Text.draw(letter, in: NSRect(x: c.x - 8, y: c.y - 8, width: 16, height: 16), color: color, font: Fonts.mono(12, .semibold), align: .center)
            return
        }
        path.stroke()
    }

    /// The corner mark on a panel's icon: a count in the "needs you" colour, a dot for something
    /// new, a warning colour when its plugin stopped.
    static func badge(_ b: Stripe.Badge, at p: NSPoint, theme t: Theme) {
        switch b {
        case .dot, .warning:
            t.plane.setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 4.5, y: p.y - 4.5, width: 9, height: 9)).fill()
            (b == .dot ? t.fg : t.chk).setFill()
            NSBezierPath(ovalIn: NSRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6)).fill()
        case .count(let n):
            let s = n > 99 ? "99+" : "\(n)"
            let font = Fonts.mono(8.5, .semibold)
            let w = max(12, Text.width(s, font: font) + 6)
            let r = NSRect(x: p.x - w + 4, y: p.y - 5, width: w, height: 11)
            t.plane.setFill()
            NSBezierPath(roundedRect: r.insetBy(dx: -1.5, dy: -1.5), xRadius: 7, yRadius: 7).fill()
            t.color(for: .needsYou).setFill()
            NSBezierPath(roundedRect: r, xRadius: 5.5, yRadius: 5.5).fill()
            Text.draw(s, in: r.offsetBy(dx: 0, dy: -0.5), color: t.background, font: font, align: .center)
        }
    }
}

/// A menu item that runs a closure.
final class MenuAction: NSMenuItem {
    private let handler: () -> Void
    init(_ title: String, _ handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func fire() { handler() }
}
