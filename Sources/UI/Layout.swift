import AppKit

/// A tint laid over an unfocused pane. Clicks go through to the pane.
final class Dimmer: Fill {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
}

/// The panels that live around the terminal, JetBrains tool-window style.
enum PanelID: String, CaseIterable, Codable {
    case sessions, viewer, usage, system, plugins

    var title: String { rawValue.capitalized }
    /// ⌥⌘ and this number shows, focuses or hides the panel (⌥⌘2 is the terminal).
    var key: Int { switch self { case .sessions: return 1; case .viewer: return 3; case .usage: return 4; case .system: return 5; case .plugins: return 6 } }
    /// Lists and documents take what room there is; widgets take what they need.
    var flexible: Bool { self == .sessions || self == .viewer || self == .plugins }
}

enum Dock: String, CaseIterable, Codable {
    case left, right, bottom
    var title: String { rawValue.capitalized }
}

/// Where every panel sits, which are collapsed to a stripe, and how big each area is.
/// Saved per screen, so the laptop and the external display keep their own arrangement.
struct PanelLayout: Codable, Equatable {
    var place: [PanelID: Dock] = [.sessions: .left, .viewer: .right, .usage: .bottom, .system: .bottom, .plugins: .right]
    var order: [PanelID] = PanelID.allCases
    var hidden: Set<PanelID> = []
    var size: [Dock: CGFloat] = [.left: Metrics.side, .right: Metrics.viewer, .bottom: 220]
    /// Share of the first of two lists or documents stacked in one area (sessions over viewer).
    var split: [Dock: CGFloat]?
    /// Height of a bottom area that holds only widgets, once dragged; nil fits the widgets.
    var widgetBottom: CGFloat?
    /// The bottom area fills the terminal's place (VS Code's Maximize Panel Size).
    var bottomMaximized: Bool?

    func panels(_ d: Dock) -> [PanelID] { order.filter { place[$0] == d } }

    mutating func move(_ p: PanelID, to d: Dock) {
        place[p] = d
        hidden.remove(p)
        order.removeAll { $0 == p }
        order.append(p)
    }

    private static func key(_ screen: String) -> String { "Maxwell.layout.\(screen)" }
    static func load(screen: String) -> PanelLayout {
        guard let d = UserDefaults.standard.data(forKey: key(screen)), var l = try? JSONDecoder().decode(PanelLayout.self, from: d) else { return PanelLayout() }
        for p in PanelID.allCases where l.place[p] == nil { l.place[p] = PanelLayout().place[p]; l.order.append(p) }
        return l
    }
    func save(screen: String) {
        if let d = try? JSONEncoder().encode(self) { UserDefaults.standard.set(d, forKey: Self.key(screen)) }
    }
}

/// A panel's content: where its header is, so the header can be dragged to another area.
protocol PanelContent: NSView {
    var gripRect: NSRect { get }
    /// Height (side areas) or width (bottom) a widget needs; flexible panels return nil.
    func preferredExtent(along d: Dock) -> CGFloat?
    /// Room the panel's own header buttons take on the right; the panel controls sit left of them.
    var controlsInset: CGFloat { get }
}

extension PanelContent {
    var controlsInset: CGFloat { 0 }
}

/// Root view: glass behind everything, one flat theme tint on it, areas laid out by hand.
///   rail · left stripe · left area · terminal (bottom area under it) · right area · right stripe
/// An area that opens takes its room at once (one terminal reflow) and its panels slide in;
/// one that closes slides out first and gives the room back at the end.
final class RootView: MXView {
    let titleBar = TitleBar(frame: .zero)
    let rail = ProjectRail(frame: .zero)
    let sidebar = Sidebar(frame: .zero)
    let sessionPane = SessionPane(frame: .zero)
    let viewerPane = ViewerPane(frame: .zero)
    let usage = UsagePanel(frame: .zero)
    let system = SystemPanel(frame: .zero)
    let pluginPanel = PluginPanel(frame: .zero)
    /// A plugin contributes a panel: only then does the Plugins panel exist.
    private(set) var hasPluginPanels = false
    func setPluginPanels(_ on: Bool) {
        guard on != hasPluginPanels else { return }
        hasPluginPanels = on
        sync(animated: window != nil)
    }
    let status = StatusBar(frame: .zero)
    let sessionDim = Dimmer { $0.dim }
    let viewerDim = Dimmer { $0.dim }
    private let tint = CALayer()
    /// Under the panes with text, the tint never drops below `textFloor`, whatever the glass is set to.
    private let textTint = CALayer()
    static let textFloor: CGFloat = 0.72
    private var docks: [Dock: DockView] = [:]
    private let leftStripe = Stripe(side: .left)
    private let rightStripe = Stripe(side: .right)
    private let drop = DropPreview(frame: .zero)
    private let railLine = Fill { $0.hair }
    private var reveal: [Dock: Tween] = [:]
    private var closing = Set<Dock>()
    private var grips: [PanelID: PanelGrip] = [:]
    private var controls: [PanelID: PanelControls] = [:]
    private var splitters: [Dock: Splitter] = [:]
    /// While a divider is dragged the terminal follows at most 20 times a second.
    private var resizing = false
    private var lastCenterFrame = NSRect.zero
    private var lastCenterAt = Date.distantPast
    private var trailingLayout: Timer?

    var panels = PanelLayout() { didSet { if panels != oldValue { sync(animated: true); onLayoutChanged?() } } }
    var onLayoutChanged: (() -> Void)?
    var onWidthsChanged: (() -> Void)?
    /// Called when a stripe or menu shows a panel, so the controller can focus it.
    var onShowPanel: ((PanelID) -> Void)?

    enum RailMode { case auto, shown, off }
    var railMode = RailMode.auto { didSet { railReveal.set(railMode == .shown ? 1 : 0, animated: false); needsLayout = true } }
    private let railReveal = Tween(0)
    var railDelay: TimeInterval = 0.18
    private var railHideTimer: Timer?
    private var railShowTimer: Timer?
    /// The edge strip that opens a hidden rail, like the Dock's: wide enough to hit without aiming.
    static let railEdge: CGFloat = 10
    private let railHandle = RailHandle(frame: .zero)
    private var lastPointer = NSPoint(x: 999, y: 0)

    /// Whether the viewer has something to show (a file, or ⌘\ forced it open).
    private(set) var viewerOpen = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.addSublayer(tint)
        layer?.addSublayer(textTint)
        lookChanged()
        for d in Dock.allCases {
            let v = DockView(dock: d)
            docks[d] = v
            let t = Tween(0)
            t.step = { [weak self] _ in self?.needsLayout = true }
            t.done = { [weak self] in self?.closing.remove(d); self?.needsLayout = true; self?.onSettled?() }
            reveal[d] = t
        }
        for p in PanelID.allCases {
            let g = PanelGrip(panel: p)
            g.root = self
            grips[p] = g
            let c = PanelControls(panel: p)
            c.root = self
            controls[p] = c
        }
        for d in Dock.allCases {
            let sp = Splitter(vertical: d != .bottom)
            sp.onDrag = { [weak self] pt in self?.resize(d, to: pt) }
            sp.onBegin = { [weak self] in self?.resizing = true }
            sp.onEnd = { [weak self] in self?.endResize() }
            sp.onReset = { [weak self] in self?.resetSize(d) }
            splitters[d] = sp
        }
        ([sessionPane, sessionDim] + Dock.allCases.map { docks[$0]! } + [leftStripe, rightStripe, titleBar, status, railLine] + Dock.allCases.map { splitters[$0]! } + [railHandle, rail, drop]).forEach(addSubview)
        railHandle.onOpen = { [weak self] in self?.peekRail() }
        sessionDim.isHidden = true
        viewerDim.isHidden = true
        drop.isHidden = true
        for s in [leftStripe, rightStripe] {
            s.onToggle = { [weak self] p in self?.setHidden(p, false); self?.onShowPanel?(p) }
            s.onMenu = { [weak self] p, e in self?.showMenu(for: p, event: e) }
        }
        railReveal.step = { [weak self] _ in self?.needsLayout = true }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
        sync(animated: false)
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Lets the controller know when an area finished moving (to update focus dimming).
    var onSettled: (() -> Void)?

    var opacity: CGFloat? { didSet { lookChanged() } }

    override func lookChanged() {
        super.lookChanged()
        let a = opacity ?? t.backgroundOpacity
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.backgroundColor = t.background.withAlphaComponent(a).cgColor
        // Stacked tints: 1 - (1 - a)(1 - b) = floor  →  b = 1 - (1 - floor) / (1 - a).
        let b = a >= Self.textFloor ? 0 : 1 - (1 - Self.textFloor) / (1 - a)
        textTint.backgroundColor = t.background.withAlphaComponent(b).cgColor
        CATransaction.commit()
    }

    func content(_ p: PanelID) -> PanelContent {
        switch p {
        case .sessions: return sidebar
        case .viewer: return viewerPane
        case .usage: return usage
        case .system: return system
        case .plugins: return pluginPanel
        }
    }

    /// Panels in an area that are on screen: not collapsed, and the viewer only with a file.
    func shown(_ d: Dock) -> [PanelID] {
        panels.panels(d).filter { !panels.hidden.contains($0) && ($0 != .viewer || viewerOpen) && ($0 != .plugins || hasPluginPanels) }
    }

    func isShown(_ p: PanelID) -> Bool { shown(panels.place[p] ?? .left).contains(p) }

    func setViewer(open: Bool, animated: Bool = true) {
        guard open != viewerOpen else { return }
        viewerOpen = open
        sync(animated: animated)
    }

    func setHidden(_ p: PanelID, _ hide: Bool) {
        if hide { panels.hidden.insert(p) } else { panels.hidden.remove(p) }
    }

    /// Hides every panel of an area, or shows them all again.
    func toggleArea(_ d: Dock) {
        let ps = panels.panels(d)
        guard !ps.isEmpty else { return }
        let anyShown = ps.contains { !panels.hidden.contains($0) }
        for p in ps { if anyShown { panels.hidden.insert(p) } else { panels.hidden.remove(p) } }
    }

    /// Reparents panels into their areas and starts the slide for areas that open or close.
    private func sync(animated: Bool) {
        for d in Dock.allCases {
            let dock = docks[d]!
            let want = shown(d)
            for p in want {
                let v = content(p)
                if v.superview !== dock { dock.addSubview(v) }
                if let g = grips[p], g.superview !== dock { dock.addSubview(g) }
                if let c = controls[p], c.superview !== dock { dock.addSubview(c) }
            }
            if want.contains(.viewer), viewerDim.superview !== dock { dock.addSubview(viewerDim) }
            let target: CGFloat = want.isEmpty ? 0 : 1
            let t = reveal[d]!
            if target != t.target {
                if target == 0 { closing.insert(d) } else { closing.remove(d) }
                t.set(target, animated: animated && window != nil)
            }
            dock.showing = want
            dock.innerSplit.onDrag = { [weak self] pt in self?.resizeSplit(d, to: pt) }
            dock.innerSplit.onBegin = { [weak self] in self?.resizing = true }
            dock.innerSplit.onEnd = { [weak self] in self?.endResize() }
            dock.innerSplit.onReset = { [weak self] in self?.panels.split?[d] = nil }
        }
        leftStripe.items = stripeItems(.left)
        rightStripe.items = stripeItems(.right)
        needsLayout = true
    }

    private func stripeItems(_ side: Dock) -> [Stripe.Item] {
        let hidden = { (d: Dock) in self.panels.panels(d).filter { self.panels.hidden.contains($0) && ($0 != .plugins || self.hasPluginPanels) } }
        var items = hidden(side).map { Stripe.Item(panel: $0, lower: false) }
        // JetBrains keeps bottom tool windows on the lower part of the left stripe.
        if side == .left { items += hidden(.bottom).map { Stripe.Item(panel: $0, lower: true) } }
        return items
    }

    // MARK: layout

    private var railWidth: CGFloat { railMode == .off ? 0 : Metrics.rail * railReveal.value }

    /// Full size of an area when open. A bottom area of widgets only is as tall as its tallest widget.
    private func extent(_ d: Dock) -> CGFloat {
        let ps = shown(d).isEmpty ? panels.panels(d) : shown(d)
        let bodyH = bounds.height - Metrics.titlebar - Metrics.status
        if d == .bottom, panels.bottomMaximized == true { return max(120, bodyH - 80) }
        if d == .bottom, !ps.isEmpty, !ps.contains(where: \.flexible) {
            let fit = ps.compactMap { content($0).preferredExtent(along: .bottom) }.max() ?? 80
            return min(max(fit, panels.widgetBottom ?? fit), bodyH * 0.6)
        }
        var s = panels.size[d] ?? 300
        // A side of widgets only needs room for their numbers, not a document's width.
        if d != .bottom, !ps.isEmpty, !ps.contains(where: \.flexible) { s = min(s, 340) }
        switch d {
        case .left: return min(max(Self.minSize[.left]!, s), bounds.width * 0.45)
        case .right: return min(max(Self.minSize[.right]!, s), max(300, bounds.width * 0.6))
        case .bottom: return min(max(Self.minSize[.bottom]!, s), bodyH * 0.6)
        }
    }

    /// Room an area takes from the terminal: all of it as soon as it starts opening, and all
    /// of it until its closing slide ends.
    private func taken(_ d: Dock) -> CGFloat {
        let t = reveal[d]!
        return t.target == 1 || (closing.contains(d) && t.isRunning) ? extent(d) + 1 : 0
    }

    override func layout() {
        super.layout()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        tint.frame = bounds
        textTint.frame = NSRect(x: 0, y: Metrics.titlebar, width: bounds.width, height: bounds.height - Metrics.titlebar - Metrics.status)
        CATransaction.commit()
        let w = bounds.width, h = bounds.height
        titleBar.frame = NSRect(x: 0, y: 0, width: w, height: Metrics.titlebar)
        status.frame = NSRect(x: 0, y: h - Metrics.status, width: w, height: Metrics.status)
        let top = Metrics.titlebar, bottom = h - Metrics.status, bodyH = bottom - top

        // The rail: in the layout when shown, sliding over the sidebar when auto.
        let rw = Metrics.rail
        let rx = railMode == .shown ? 0 : -rw * (1 - railReveal.value)
        rail.isHidden = railMode == .off || railReveal.value == 0
        rail.overlay = railMode == .auto
        rail.frame = NSRect(x: rx, y: top, width: rw, height: bodyH)
        railLine.isHidden = rail.isHidden
        railHandle.isHidden = railMode != .auto || railReveal.target == 1
        railHandle.frame = NSRect(x: 0, y: top, width: Self.railEdge, height: bodyH)
        railLine.frame = NSRect(x: rx + rw, y: top, width: 1, height: bodyH)

        var x0: CGFloat = railMode == .shown ? rw + 1 : 0
        leftStripe.isHidden = leftStripe.items.isEmpty
        if !leftStripe.isHidden { leftStripe.frame = NSRect(x: x0, y: top, width: Stripe.width, height: bodyH); x0 += Stripe.width + 1 }
        var x1 = w
        rightStripe.isHidden = rightStripe.items.isEmpty
        if !rightStripe.isHidden { x1 -= Stripe.width; rightStripe.frame = NSRect(x: x1, y: top, width: Stripe.width, height: bodyH); x1 -= 1 }

        let lw = taken(.left), rwid = taken(.right)
        let left = docks[.left]!, right = docks[.right]!, bot = docks[.bottom]!
        left.frame = NSRect(x: x0, y: top, width: max(0, lw - 1), height: bodyH)
        right.frame = NSRect(x: x1 - max(0, rwid - 1), y: top, width: max(0, rwid - 1), height: bodyH)
        let cx0 = x0 + lw, cx1 = x1 - rwid
        let bh = taken(.bottom)
        bot.frame = NSRect(x: cx0, y: bottom - max(0, bh - 1), width: cx1 - cx0, height: max(0, bh - 1))
        for (d, v) in docks {
            v.reveal = reveal[d]!.value
            v.extent = extent(d)
            v.contentFor = { [weak self] in self?.content($0) }
            v.grips = grips
            v.controls = controls
            v.split = panels.split?[d]
            v.maximized = panels.bottomMaximized == true
            v.isHidden = v.frame.width <= 0 || v.frame.height <= 0
            v.needsLayout = true
            v.needsDisplay = true
        }
        let center = NSRect(x: cx0, y: top, width: cx1 - cx0, height: bodyH - bh)
        if resizing, center != lastCenterFrame, Date().timeIntervalSince(lastCenterAt) < 0.05 {
            // Throttled: the docks follow the pointer, the terminal catches up shortly after.
            if trailingLayout == nil {
                trailingLayout = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: false) { [weak self] _ in self?.trailingLayout = nil; self?.needsLayout = true }
            }
        } else {
            sessionPane.frame = center
            lastCenterFrame = center
            lastCenterAt = Date()
        }
        sessionDim.frame = sessionPane.frame
        let hit: CGFloat = 8
        let sl = splitters[.left]!, sr = splitters[.right]!, sb = splitters[.bottom]!
        sl.isHidden = lw == 0; sr.isHidden = rwid == 0; sb.isHidden = bh == 0
        sl.frame = NSRect(x: x0 + lw - 1 - hit / 2, y: top, width: hit + 1, height: bodyH)
        sr.frame = NSRect(x: x1 - rwid - hit / 2, y: top, width: hit + 1, height: bodyH)
        sb.frame = NSRect(x: cx0, y: bottom - bh - hit / 2, width: cx1 - cx0, height: hit + 1)

        drawsLines = (lw > 0 ? [NSRect(x: x0 + lw - 1, y: top, width: 1, height: bodyH)] : [])
            + (rwid > 0 ? [NSRect(x: x1 - rwid, y: top, width: 1, height: bodyH)] : [])
            + (bh > 0 ? [NSRect(x: cx0, y: bottom - bh, width: cx1 - cx0, height: 1)] : [])
            + (leftStripe.isHidden ? [] : [NSRect(x: leftStripe.frame.maxX, y: top, width: 1, height: bodyH)])
            + (rightStripe.isHidden ? [] : [NSRect(x: rightStripe.frame.minX - 1, y: top, width: 1, height: bodyH)])
        planeRect = NSRect(x: 0, y: top, width: railMode == .shown ? rw + 1 : 0, height: bodyH)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    private var drawsLines: [NSRect] = []
    private var planeRect = NSRect.zero

    override func draw(_ r: NSRect) {
        t.plane.setFill(); planeRect.fill()
        t.hair.setFill(); drawsLines.forEach { $0.fill() }
    }

    // MARK: rail reveal (Dock-like)

    override func mouseMoved(with e: NSEvent) {
        guard railMode == .auto else { return }
        let p = convert(e.locationInWindow, from: nil)
        lastPointer = p
        let inBody = p.y > Metrics.titlebar && p.y < bounds.height - Metrics.status
        if railReveal.target == 0 {
            if p.x <= Self.railEdge, inBody {
                railHandle.lit = true
                guard railShowTimer == nil else { return }
                railShowTimer = Timer.scheduledTimer(withTimeInterval: railDelay, repeats: false) { [weak self] _ in
                    self?.railShowTimer = nil
                    self?.peekRail()
                }
            } else if p.x > 40 || !inBody {
                // A little drift off the edge doesn't cancel; moving away does.
                railHandle.lit = false
                railShowTimer?.invalidate(); railShowTimer = nil
            }
        } else if p.x > Metrics.rail + 12 || !inBody {
            scheduleRailHide(after: 0.35)
        } else {
            railHideTimer?.invalidate(); railHideTimer = nil
        }
    }

    override func mouseExited(with e: NSEvent) {
        railShowTimer?.invalidate(); railShowTimer = nil
        railHandle.lit = false
        // Thrown past the window's left edge, the way you'd hit the Dock at the screen edge.
        let p = convert(e.locationInWindow, from: nil)
        if railMode == .auto, railReveal.target == 0, lastPointer.x < 60, p.x < 0,
           p.y > Metrics.titlebar, p.y < bounds.height - Metrics.status { return peekRail() }
        if railMode == .auto, railReveal.target == 1 { scheduleRailHide(after: 0.35) }
    }

    func peekRail(for seconds: TimeInterval? = nil) {
        guard railMode == .auto else { return }
        railHideTimer?.invalidate(); railHideTimer = nil
        railReveal.set(1)
        railHandle.isHidden = true; railHandle.lit = false
        if let seconds { scheduleRailHide(after: seconds) }
    }

    private func scheduleRailHide(after s: TimeInterval) {
        guard railHideTimer == nil else { return }
        railHideTimer = Timer.scheduledTimer(withTimeInterval: s, repeats: false) { [weak self] _ in
            guard let self else { return }
            self.railHideTimer = nil
            // Stay while a menu or a drag on the rail is open.
            if self.rail.isBusy { return self.scheduleRailHide(after: 0.35) }
            if let w = self.window, NSMouseInRect(self.convert(w.mouseLocationOutsideOfEventStream, from: nil), self.rail.frame.insetBy(dx: -12, dy: 0), true) { return }
            self.railReveal.set(0)
            self.needsLayout = true
        }
    }

    // MARK: resizing the areas


    static let minSize: [Dock: CGFloat] = [.left: 200, .right: 280, .bottom: 80]

    /// A divider moved to `p` (root coordinates): the area's edge follows the pointer.
    private func resize(_ d: Dock, to p: NSPoint) {
        switch d {
        case .left: panels.size[.left] = max(Self.minSize[.left]!, min(bounds.width * 0.45, p.x - docks[.left]!.frame.minX))
        case .right: panels.size[.right] = max(Self.minSize[.right]!, min(bounds.width * 0.6, docks[.right]!.frame.maxX - p.x))
        case .bottom:
            let h = max(Self.minSize[.bottom]!, min((bounds.height - Metrics.titlebar - Metrics.status) * 0.6, bounds.height - Metrics.status - p.y))
            panels.bottomMaximized = nil
            if shown(.bottom).contains(where: \.flexible) { panels.size[.bottom] = h } else { panels.widgetBottom = h }
        }
    }

    private func resizeSplit(_ d: Dock, to p: NSPoint) {
        let dock = docks[d]!
        let local = dock.convert(p, from: self)
        let r = d == .bottom ? local.x / max(1, dock.bounds.width) : local.y / max(1, dock.bounds.height)
        var split = panels.split ?? [:]
        split[d] = max(0.15, min(0.85, r))
        panels.split = split
    }

    private func endResize() {
        if ProcessInfo.processInfo.environment["MAXWELL_LOG_RESIZE"] != nil { mark("resized to \(panels.size.map { "\($0.key.rawValue) \(Int($0.value))" }.sorted())") }
        resizing = false
        trailingLayout?.invalidate(); trailingLayout = nil
        needsLayout = true
        onWidthsChanged?()
    }

    /// Double-click on a divider: back to the default size.
    private func resetSize(_ d: Dock) {
        if ProcessInfo.processInfo.environment["MAXWELL_LOG_RESIZE"] != nil { mark("reset \(d.rawValue)") }
        panels.size[d] = PanelLayout().size[d]
        if d == .bottom { panels.widgetBottom = nil; panels.bottomMaximized = nil }
        onWidthsChanged?()
    }

    func toggleMaximizeBottom() {
        panels.bottomMaximized = panels.bottomMaximized == true ? nil : true
    }

    // MARK: moving panels

    func menu(for p: PanelID) -> NSMenu {
        let m = NSMenu()
        for d in Dock.allCases {
            let i = MenuAction("Move to \(d.title)") { [weak self] in self?.panels.move(p, to: d) }
            i.state = panels.place[p] == d ? .on : .off
            m.addItem(i)
        }
        m.addItem(.separator())
        let hide = MenuAction(panels.hidden.contains(p) ? "Show \(p.title)" : "Hide \(p.title)") { [weak self] in
            guard let self else { return }
            self.setHidden(p, !self.panels.hidden.contains(p))
        }
        hide.keyEquivalent = "\(p.key)"
        hide.keyEquivalentModifierMask = [.command, .option]
        m.addItem(hide)
        if let d = panels.place[p], d != .left {
            let area = MenuAction("Hide \(d.title) Area") { [weak self] in self?.toggleArea(d) }
            area.keyEquivalent = d == .bottom ? "j" : "b"
            area.keyEquivalentModifierMask = [.command, .option]
            m.addItem(area)
        }
        if panels.place[p] == .bottom {
            m.addItem(MenuAction(panels.bottomMaximized == true ? "Restore Bottom Area" : "Maximize Bottom Area") { [weak self] in self?.toggleMaximizeBottom() })
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
            drop.label = target.map { "Move \(p.title) to \($0.title)" } ?? ""
            let wasHidden = drop.isHidden
            drop.isHidden = target == nil
            if wasHidden, !drop.isHidden { Motion.appear(drop) }
        }
        drop.isHidden = true
        if let target, target != panels.place[p] { panels.move(p, to: target) }
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
}

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
    var maximized = false
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
            if flexIndices.count == 2, let r = split {
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
                c.showsMaximize = dock == .bottom && i == views.count - 1
                c.maximized = maximized
                let grip = v.gripRect
                let w = c.preferredWidth
                (v as? Sidebar)?.headerReserve = w + 4
                (v as? ViewerPane)?.headerReserve = w + 4
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

/// The buttons on a panel's header: ⋯ options, ⌃ maximize on the bottom area's last panel, and
/// × to hide this panel only (it stays on the edge stripe). ⌥⌘J still hides the whole area.
final class PanelControls: MXView {
    let panel: PanelID
    weak var root: RootView?
    var showsMaximize = false { didSet { if showsMaximize != oldValue { rebuild() } } }
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
        var list = [
            IconButton(.more, tip: Tip("Move or hide this panel")) { [weak self] in
                guard let self, let b = self.buttons.first else { return }
                self.root?.showMenu(for: p, below: b)
            },
        ]
        if showsMaximize {
            list.append(IconButton(maximized ? .restore : .maximize, tip: Tip(maximized ? "Back to normal height" : "Make the bottom panels taller")) { [weak self] in self?.root?.toggleMaximizeBottom() })
        }
        list.append(IconButton(.close, tip: Tip("Hide \(p.title)", action: "panel-\(p.rawValue)").adding("It stays on the edge, one click away")) { [weak self] in self?.root?.setHidden(p, true) })
        buttons = list
        buttons.forEach(addSubview)
        needsLayout = true
    }

    override func layout() {
        super.layout()
        for (i, b) in buttons.enumerated() { b.frame = NSRect(x: CGFloat(i) * 22, y: 0, width: 22, height: bounds.height) }
    }
}

/// Invisible handle over a panel's header: drag to move the panel, right-click for "Move to".
final class PanelGrip: NSView, TipSource {
    let panel: PanelID
    weak var root: RootView?
    init(panel: PanelID) { self.panel = panel; super.init(frame: .zero) }
    required init?(coder: NSCoder) { fatalError() }
    override var isFlipped: Bool { true }
    override func mouseDown(with e: NSEvent) { root?.dragPanel(panel, from: e) }
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

/// A collapsed area: a 20 pt column with one vertical button per hidden panel.
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

final class Stripe: MXView, TipSource {
    var tipsBeside: Bool { side != .bottom }
    struct Item: Equatable { var panel: PanelID; var lower: Bool }
    static let width: CGFloat = 20
    let side: Dock
    var items: [Item] = [] { didSet { if items != oldValue { needsDisplay = true } } }
    var onToggle: ((PanelID) -> Void)?
    var onMenu: ((PanelID, NSEvent) -> Void)?
    private var hover: Int?
    private var pressed: Int?
    private let font = Fonts.mono(Metrics.fontSize - 2)

    init(side: Dock) {
        self.side = side
        super.init(frame: .zero)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    private func rects() -> [NSRect] {
        var top: CGFloat = 6, bottom = bounds.height - 6
        return items.map { it in
            let h = Text.width(it.panel.title, font: font) + 16
            if it.lower { bottom -= h + 2; return NSRect(x: 1, y: bottom + 2, width: bounds.width - 2, height: h) }
            defer { top += h + 2 }
            return NSRect(x: 1, y: top, width: bounds.width - 2, height: h)
        }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        guard let i = index(at: p) else { return nil }
        return (Tip("Show the \(items[i].panel.title.lowercased()) panel", action: "panel-\(items[i].panel.rawValue)"), rects()[i])
    }

    override func draw(_ r: NSRect) {
        t.plane.setFill(); bounds.fill()
        for (i, (it, rr)) in zip(items, rects()).enumerated() {
            if pressed == i { t.rowSel.setFill(); NSBezierPath(roundedRect: rr, xRadius: 3, yRadius: 3).fill() }
            else if hover == i { t.hover.setFill(); NSBezierPath(roundedRect: rr, xRadius: 3, yRadius: 3).fill() }
            NSGraphicsContext.saveGraphicsState()
            let xf = NSAffineTransform()
            xf.translateX(by: rr.midX, yBy: rr.midY)
            xf.rotate(byDegrees: side == .right ? 90 : -90)
            xf.concat()
            let s = it.panel.title
            let w = Text.width(s, font: font)
            Text.draw(s, in: NSRect(x: -w / 2, y: -8, width: w + 2, height: 16), color: hover == i ? t.fg : t.fg2, font: font)
            NSGraphicsContext.restoreGraphicsState()
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
