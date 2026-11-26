import AppKit

/// Bottom line: the bottom panels' buttons, counts per state, a transient toast, and the key hints.
final class StatusBar: MXView, TipSource {
    /// A panel of the bottom area, shown and hidden from its icon here (VS Code and Zed do the same).
    struct PanelToggle: Equatable { var panel: PanelID; var title: String; var open: Bool }
    var panels: [PanelToggle] = [] { didSet { if panels != oldValue { needsDisplay = true } } }
    var onPanel: ((PanelID) -> Void)?
    private var hoverPanel: Int?
    private func panelRects() -> [NSRect] {
        panels.indices.map { NSRect(x: 4 + CGFloat($0) * 24, y: 2, width: 22, height: bounds.height - 3) }
    }
    var counts: [(PhaseGroup, Int)] = [] { didSet { needsDisplay = true } }
    /// A warning after the counts ("! 2 unverified") and what it means on hover.
    var warning: (text: String, tip: Tip)? { didSet { if warning?.text != oldValue?.text { needsDisplay = true } } }
    private var warningRect: NSRect?
    /// Where each count was drawn, for its tooltip.
    private var countRects: [(PhaseGroup, Int, NSRect)] = []
    private(set) var toast: String?
    private var toastTimer: Timer?
    /// A toast can carry one action ("Undo"), clickable while the toast shows.
    private(set) var toastAction: (title: String, run: () -> Void)?
    private var actionRect: NSRect?
    /// "v0.1.7 ready · Restart to update", kept on the right until clicked.
    var update: String? { didSet { needsDisplay = true } }
    var onUpdate: (() -> Void)?
    private var updateRect: NSRect?

    func show(toast: String, action: (title: String, run: () -> Void)? = nil, seconds: TimeInterval = 6) {
        self.toast = toast
        toastAction = action
        needsDisplay = true
        toastTimer?.invalidate()
        toastTimer = Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { [weak self] _ in self?.clearToast() }
    }

    private func clearToast() {
        toast = nil; toastAction = nil; actionRect = nil
        needsDisplay = true
    }

    /// Runs the toast's action (the button, or ⌘Z while it shows).
    @discardableResult
    func runToastAction() -> Bool {
        guard let a = toastAction else { return false }
        clearToast()
        a.run()
        return true
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if let i = panelRects().firstIndex(where: { $0.contains(p) }) {
            let it = panels[i]
            return (Tip("\(it.open ? "Hide" : "Show") \(it.title)", action: "panel-\(it.panel.rawValue)"), panelRects()[i])
        }
        if let r = warningRect, r.contains(p), let w = warning { return (w.tip, r) }
        guard let (g, n, r) = countRects.first(where: { $0.2.contains(p) }) else { return nil }
        return (Tip(g.count(n)).adding(g.meaning), r)
    }

    override func mouseDown(with e: NSEvent) {
        let p = convert(e.locationInWindow, from: nil)
        if let i = panelRects().firstIndex(where: { $0.contains(p) }) { onPanel?(panels[i].panel) }
        else if let r = actionRect, r.contains(p) { runToastAction() }
        else if let r = updateRect, r.contains(p) { onUpdate?() }
        else { super.mouseDown(with: e) }
    }

    override func draw(_ r: NSRect) {
        t.hair.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        let font = Fonts.mono(Metrics.fontSize - 1)
        var x: CGFloat = 10
        for (i, (it, r)) in zip(panels, panelRects()).enumerated() {
            if it.open || hoverPanel == i { (it.open ? t.rowSel : t.hover).setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill() }
            PanelGlyph.draw(it.panel, title: it.title, in: r, color: it.open || hoverPanel == i ? t.fg : t.fg3, theme: t)
            x = r.maxX + 12
        }
        countRects = []
        for (g, n) in counts where n > 0 {
            let x0 = x
            Glyph.draw(g, at: NSPoint(x: x + 4, y: bounds.midY + 0.5), color: t.color(for: g))
            x += 12
            x += Text.draw("\(n)", in: NSRect(x: x, y: 1, width: 40, height: bounds.height - 1), color: [.working, .limited, .idle].contains(g) ? t.fg2 : t.color(for: g), font: Fonts.mono(Metrics.fontSize - 1, .semibold)) + 5
            x += Text.draw(g.title.lowercased(), in: NSRect(x: x, y: 1, width: 200, height: bounds.height - 1), color: t.fg3, font: font)
            countRects.append((g, n, NSRect(x: x0 - 4, y: 0, width: x - x0 + 8, height: bounds.height)))
            x += 16
        }
        warningRect = warning.map { w in
            let w0 = Text.draw(w.text, in: NSRect(x: x, y: 1, width: 200, height: bounds.height - 1), color: t.on, font: font)
            defer { x += w0 + 16 }
            return NSRect(x: x - 4, y: 0, width: w0 + 8, height: bounds.height)
        }
        if let toast {
            let room = max(0, bounds.width - x - 360)
            let aw = toastAction.map { Text.width($0.title, font: Fonts.mono(Metrics.fontSize - 1, .semibold)) + 16 } ?? 0
            x += Text.draw(toast, in: NSRect(x: x, y: 1, width: max(0, room - aw), height: bounds.height - 1), color: t.safe, font: font) + 8
            if let a = toastAction {
                let r = NSRect(x: x, y: 3, width: aw, height: bounds.height - 6)
                t.hover.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
                Text.draw(a.title, in: r, color: t.fg, font: Fonts.mono(Metrics.fontSize - 1, .semibold), align: .center)
                actionRect = r
                x = r.maxX + 14
            }
        }
        updateRect = nil
        if let update {
            let bold = Fonts.mono(Metrics.fontSize - 1, .semibold)
            let label = "v\(update) ready", button = "Restart to update"
            let bw = Text.width(button, font: bold) + 16
            let r = NSRect(x: bounds.width - bw - 8, y: 3, width: bw, height: bounds.height - 6)
            let lw = Text.width(label, font: font)
            guard r.minX - lw - 10 > x else { return }
            Text.draw(label, in: NSRect(x: r.minX - lw - 8, y: 1, width: lw, height: bounds.height - 1), color: t.safe, font: font)
            t.hover.setFill(); NSBezierPath(roundedRect: r, xRadius: 4, yRadius: 4).fill()
            Text.draw(button, in: r, color: t.fg, font: bold, align: .center)
            updateRect = r
            return
        }
        let hints = "J K move · ⏎ open · ⌘N new · ⌘K actions · ⇧⌘X close safe"
        let hw = Text.width(hints, font: font)
        if bounds.width - hw - 10 > x {
            Text.draw(hints, in: NSRect(x: bounds.width - hw - 10, y: 1, width: hw, height: bounds.height - 1), color: t.fg3, font: font)
        }
    }

    override func accessibilityChildren() -> [Any]? {
        let own = zip(panels, panelRects()).map { it, r in
            PressElement(parent: self, frame: r, label: "\(it.open ? "Hide" : "Show") \(it.title)", selected: it.open) { [weak self] in self?.onPanel?(it.panel) }
        }
        return own + (super.accessibilityChildren() ?? [])
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if trackingAreas.isEmpty { addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)) }
    }
    override func mouseMoved(with e: NSEvent) {
        let i = panelRects().firstIndex { $0.contains(convert(e.locationInWindow, from: nil)) }
        if i != hoverPanel { hoverPanel = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if hoverPanel != nil { hoverPanel = nil; needsDisplay = true } }
}
