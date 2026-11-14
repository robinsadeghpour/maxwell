import AppKit

/// One entry of the project switcher. `name == nil` is "All": only what needs you, everywhere.
struct ProjectEntry: Equatable {
    var name: String?
    var needsYou: Int
    var yourTurn: Int
    var total: Int
    var pinned = false
    /// ⌘ number, stable whether or not the project is on the rail right now.
    var key: Int?
    /// Repo folders its sessions run in (where its logo is looked up).
    var roots: [String] = []

    var title: String { name ?? "All" }
}

/// Draws the count badge both switchers use: amber when something needs him, violet when it is only his turn.
enum Badge {
    static func draw(_ e: ProjectEntry, at p: NSPoint, align: NSTextAlignment, theme t: Theme) -> CGFloat {
        let n = e.needsYou + e.yourTurn
        guard n > 0 else { return 0 }
        let font = Fonts.mono(Metrics.fontSize - 3, .bold)
        let s = "\(n)"
        let w = max(14, Text.width(s, font: font) + 6), h: CGFloat = 13
        let x = align == .right ? p.x - w : p.x
        let r = NSRect(x: x, y: p.y, width: w, height: h)
        (e.needsYou > 0 ? t.on : t.chk).setFill()
        NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
        Text.draw(s, in: r.offsetBy(dx: 0, dy: 0.5), color: t.dark ? t.background : t.panel, font: font, align: .center)
        return w
    }
}

/// The other switcher (`project-nav = tabs`): chips that wrap above the session list.
final class ProjectTabs: MXView {
    var entries: [ProjectEntry] = [] { didSet { if entries != oldValue { needsDisplay = true } } }
    var selected: String? { didSet { needsDisplay = true } }
    var onSelect: ((String?) -> Void)?
    private var hover: Int?
    private let font = Fonts.mono(Metrics.fontSize - 1)

    override init(frame: NSRect) {
        super.init(frame: frame)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rects(width: CGFloat) -> [NSRect] {
        var x: CGFloat = 8, y: CGFloat = 6, out: [NSRect] = []
        for e in entries {
            let n = e.needsYou + e.yourTurn
            let w = Text.width(e.title, font: font) + 16 + (n > 0 ? max(14, Text.width("\(n)", font: font) + 6) + 4 : 0)
            if x + w > width - 8, x > 8 { x = 8; y += 26 }
            out.append(NSRect(x: x, y: y, width: w, height: 21))
            x += w + 4
        }
        return out
    }

    func preferredHeight(width: CGFloat) -> CGFloat { (rects(width: width).last?.maxY ?? 0) + 6 }

    override func draw(_ r: NSRect) {
        for (i, (e, rr)) in zip(entries, rects(width: bounds.width)).enumerated() {
            let sel = e.name == selected
            let path = NSBezierPath(roundedRect: rr, xRadius: 4, yRadius: 4)
            if sel { t.rowSel.setFill(); path.fill(); t.hair.setStroke(); path.lineWidth = 1; path.stroke() }
            else if hover == i { t.hover.setFill(); path.fill() }
            let w = Text.draw(e.title, in: NSRect(x: rr.minX + 8, y: rr.minY, width: rr.width - 8, height: rr.height), color: sel ? t.fg : t.fg2, font: font)
            _ = Badge.draw(e, at: NSPoint(x: rr.minX + 8 + w + 4, y: rr.midY - 6.5), align: .left, theme: t)
        }
    }

    private func index(at p: NSPoint) -> Int? { rects(width: bounds.width).firstIndex { $0.contains(p) } }
    override func mouseMoved(with e: NSEvent) {
        let i = index(at: convert(e.locationInWindow, from: nil))
        if i != hover { hover = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { hover = nil; needsDisplay = true }
    override func mouseDown(with e: NSEvent) {
        if let i = index(at: convert(e.locationInWindow, from: nil)) { onSelect?(entries[i].name) }
    }
}
