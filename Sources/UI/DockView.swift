import AppKit


/// One area's container: stacks its panels (vertically on the sides, side by side at the
/// bottom) and slides them in from its outer edge while it opens.
final class DockView: MXView {
    let dock: Dock
    var showing: [PanelID] = []
    var reveal: CGFloat = 1
    var extent: CGFloat = 0
    var contentFor: ((PanelID) -> PanelContent?)?
    var grips: [PanelID: PanelGrip] = [:]
    var controls: [PanelID: PanelControls] = [:]
    var split: CGFloat?
    /// Between two lists or documents stacked in this area: drag to share the room differently.
    let innerSplit = Splitter(vertical: false)
    private var lines: [NSRect] = []

    init(dock: Dock) {
        self.dock = dock
        super.init(frame: .zero)
        innerSplit.vertical = dock == .bottom
        addSubview(innerSplit)
    }
    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let views = showing.compactMap { p in contentFor?(p).map { (p, $0) } }
        for case let v as PanelContent in subviews where !views.contains(where: { $0.1 === v }) { v.isHidden = true }
        for case let g as PanelGrip in subviews where !showing.contains(g.panel) { g.isHidden = true }
        for case let c as PanelControls in subviews where !showing.contains(c.panel) { c.isHidden = true }
        innerSplit.isHidden = true
        // Slide: offset everything toward the outer edge by what is not revealed yet.
        let hidden = (1 - reveal) * extent
        let off: NSPoint = dock == .left ? NSPoint(x: -hidden, y: 0) : dock == .right ? NSPoint(x: hidden, y: 0) : NSPoint(x: 0, y: hidden)
        let along = dock == .bottom ? bounds.width : bounds.height
        // A widget's preferred extent is its height; next to a list or document in the bottom area
        // it gets a fixed share of the width instead, so its columns never collapse.
        let fixed: [CGFloat?] = views.map { p, v in
            guard let e = v.preferredExtent(along: dock) else { return nil }
            return dock == .bottom ? min(460, along / CGFloat(views.count)) : e
        }
        let flexCount = CGFloat(fixed.filter { $0 == nil }.count)
        let gaps = CGFloat(max(0, views.count - 1))
        let fixedSum = fixed.compactMap { $0 }.reduce(0, +)
        // Without a flexible panel, widgets at the bottom share the width; on the sides they stack from the top.
        let flexSize = flexCount > 0 ? max(80, (along - fixedSum - gaps) / flexCount) : 0
        var pos: CGFloat = 0
        lines = []
        let flexIndices = fixed.indices.filter { fixed[$0] == nil }
        let flexRoom = along - fixedSum - gaps
        for (i, (p, v)) in views.enumerated() {
            var size = fixed[i] ?? flexSize
            // A document next to a list gets two thirds of the room until the divider is dragged.
            let docShare: CGFloat? = flexIndices.count == 2 ? (views[flexIndices[0]].0 == .viewer ? 0.66 : views[flexIndices[1]].0 == .viewer ? 0.34 : nil) : nil
            if flexIndices.count == 2, let r = split ?? docShare {
                size = (i == flexIndices[0] ? r : 1 - r) * flexRoom
            }
            if flexCount == 0, dock == .bottom { size = (along - gaps) / CGFloat(views.count) }
            let r = dock == .bottom
                ? NSRect(x: pos, y: 0, width: size, height: bounds.height)
                : NSRect(x: 0, y: pos, width: bounds.width, height: size)
            v.isHidden = false
            v.frame = r.offsetBy(dx: off.x, dy: off.y)
            if let g = grips[p] {
                g.isHidden = false
                g.frame = v.gripRect.offsetBy(dx: v.frame.minX, dy: v.frame.minY)
                addSubview(g, positioned: .above, relativeTo: v)
            }
            if let c = controls[p] {
                let grip = v.gripRect
                let w = c.preferredWidth
                (v as? Sidebar)?.headerReserve = w + 4
                (v as? ViewerPane)?.headerReserve = w + 4
                (v as? PluginPanel)?.headerReserve = w + 4
                c.isHidden = false
                c.frame = NSRect(x: v.frame.maxX - v.controlsInset - w - 4, y: v.frame.minY + grip.minY + (grip.height - Metrics.control) / 2, width: w, height: Metrics.control)
                addSubview(c, positioned: .above, relativeTo: nil)
            }
            pos += size
            if i < views.count - 1 {
                lines.append(dock == .bottom ? NSRect(x: pos + off.x, y: 0, width: 1, height: bounds.height) : NSRect(x: off.x, y: pos + off.y, width: bounds.width, height: 1))
                if flexIndices.count == 2, i == flexIndices[0] {
                    innerSplit.isHidden = false
                    innerSplit.frame = dock == .bottom ? NSRect(x: pos + off.x - 4, y: 0, width: 9, height: bounds.height) : NSRect(x: off.x, y: pos + off.y - 4, width: bounds.width, height: 9)
                    addSubview(innerSplit, positioned: .above, relativeTo: nil)
                }
                pos += 1
            }
        }
        for case let d as Dimmer in subviews { d.frame = views.first { $0.0 == .viewer }?.1.frame ?? .zero }
    }

    override func draw(_ r: NSRect) {
        if dock == .left || dock == .bottom { t.plane.setFill(); bounds.fill() }
        t.hair.setFill(); lines.forEach { $0.fill() }
    }
}

/// A divider's handle: 8 pt to grab around the 1 px hairline, a resize cursor, the line lit
/// while hovered or dragged, double-click for the default size.
final class Splitter: MXView {
    var vertical: Bool
    var onBegin: (() -> Void)?
    var onDrag: ((NSPoint) -> Void)?
    var onEnd: (() -> Void)?
    var onReset: (() -> Void)?
    private var hot = false
    private var dragging = false

    init(vertical: Bool) {
        self.vertical = vertical
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    override func resetCursorRects() { addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown) }
    override func mouseEntered(with e: NSEvent) { hot = true; needsDisplay = true }
    override func mouseExited(with e: NSEvent) { hot = false; needsDisplay = true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }

    override func mouseDown(with e: NSEvent) {
        if e.clickCount == 2 { onReset?(); return }
        dragging = true; needsDisplay = true
        onBegin?()
        while let next = window?.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), next.type == .leftMouseDragged {
            if let root = superview?.window?.contentView?.subviews.first(where: { $0 is RootView }) {
                onDrag?(root.convert(next.locationInWindow, from: nil))
            }
        }
        dragging = false; needsDisplay = true
        onEnd?()
    }

    override func draw(_ r: NSRect) {
        guard hot || dragging else { return }
        (dragging ? t.fg2 : t.fg3).setFill()
        vertical ? NSRect(x: bounds.midX - 1, y: 0, width: 2, height: bounds.height).fill()
                 : NSRect(x: 0, y: bounds.midY - 1, width: bounds.width, height: 2).fill()
    }
}
