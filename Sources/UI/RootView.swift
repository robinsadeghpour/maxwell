import AppKit

/// A tint laid over an unfocused pane. Clicks go through to the pane.
final class Dimmer: Fill {
    override func hitTest(_ p: NSPoint) -> NSView? { nil }
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
    /// One tool window per panel a plugin contributes, by id ("linear.tickets").
    private(set) var pluginPanels: [PanelID: PluginPanel] = [:]
    /// The panels that exist right now: Maxwell's own and the plugins' that are on.
    var present: Set<PanelID> { Set(PanelID.builtIn).union(pluginPanels.keys) }
    func title(_ p: PanelID) -> String { p.builtInTitle ?? pluginPanels[p]?.title ?? p.rawValue }

    /// The plugins' panels changed: new ones take their place (where the old Plugins panel was),
    /// gone ones leave the screen and keep their place in the saved layout.
    func setPluginPanels(_ new: [PanelID: PluginPanel]) {
        guard new.mapValues(ObjectIdentifier.init) != pluginPanels.mapValues(ObjectIdentifier.init) else { return }
        for (id, v) in pluginPanels where new[id] !== v {
            v.removeFromSuperview()
            grips.removeValue(forKey: id)?.removeFromSuperview()
            controls.removeValue(forKey: id)?.removeFromSuperview()
        }
        pluginPanels = new
        var l = panels
        for id in new.keys.sorted(by: { $0.rawValue < $1.rawValue }) { l.adopt(id) }
        endFillIfEmpty()
        if l != panels { panels = l } else { sync(animated: window != nil) }
    }
    /// The list or document each side showed last, for bringing the side back.
    private(set) var lastShown: [Dock: PanelID] = [:]
    /// A count or a dot on a panel's stripe button: what needs you in it.
    var badges: [PanelID: Stripe.Badge] = [:] { didSet { if badges != oldValue { sync(animated: false) } } }
    let status = StatusBar(frame: .zero)
    let sessionDim = Dimmer { $0.dim }
    let viewerDim = Dimmer { $0.dim }
    private let tint = CALayer()
    /// Under the panes with text, the tint never drops below `textFloor`, whatever the glass is set to.
    private let textTint = CALayer()
    static let textFloor: CGFloat = 0.72
    private(set) var docks: [Dock: DockView] = [:]
    let leftStripe = Stripe(side: .left)
    let rightStripe = Stripe(side: .right)
    let drop = DropPreview(frame: .zero)
    private let railLine = Fill { $0.hair }
    private var reveal: [Dock: Tween] = [:]
    private var closing = Set<Dock>()
    private var grips: [PanelID: PanelGrip] = [:]
    private var controls: [PanelID: PanelControls] = [:]
    private(set) var splitters: [Dock: Splitter] = [:]
    /// While a divider is dragged the terminal follows at most 20 times a second.
    private var resizing = false
    private var lastCenterFrame = NSRect.zero
    private var lastCenterAt = Date.distantPast
    private var trailingLayout: Timer?

    var panels = PanelLayout() { didSet { if panels != oldValue { sync(animated: true); onLayoutChanged?() } } }
    var onLayoutChanged: (() -> Void)?
    var onWidthsChanged: (() -> Void)?
    /// A stripe tab was clicked: the controller shows the panel, or hides it if it is open.
    var onStripe: ((PanelID) -> Void)?

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
            s.onToggle = { [weak self] p in self?.onStripe?(p) }
            s.onMenu = { [weak self] p, e in self?.showMenu(for: p, event: e) }
        }
        status.onPanel = { [weak self] p in self?.onStripe?(p) }
        viewerPane.onTreeWidth = { [weak self] w in self?.panels.treeWidth = w }
        titleBar.docTabs = viewerPane.header
        viewerPane.header.panelMenu = { [weak self] in self?.menu(for: .viewer) ?? NSMenu() }
        railReveal.step = { [weak self] _ in self?.needsLayout = true }
        maxTween.duration = 0.2
        maxTween.step = { [weak self] _ in self?.needsLayout = true }
        maxTween.done = { [weak self] in self?.needsLayout = true; self?.onSettled?() }
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

    func content(_ p: PanelID) -> PanelContent? {
        switch p {
        case .sessions: return sidebar
        case .viewer: return viewerPane
        case .usage: return usage
        case .system: return system
        default: return pluginPanels[p]
        }
    }

    /// Panels in an area that are on screen: not hidden, and the viewer only with a file.
    /// A side area shows one list or document at a time, like tabs; widgets stack beside it.
    func shown(_ d: Dock) -> [PanelID] {
        var out = panels.panels(d, among: present).filter { !panels.hidden.contains($0) && ($0 != .viewer || viewerOpen) }
        if d != .bottom, let tab = out.first(where: \.flexible) { out.removeAll { $0.flexible && $0 != tab } }
        return out
    }

    func isShown(_ p: PanelID) -> Bool { present.contains(p) && shown(panels.place[p] ?? .left).contains(p) }

    func setViewer(open: Bool, animated: Bool = true) {
        guard open != viewerOpen else { return }
        viewerOpen = open
        endFillIfEmpty()
        sync(animated: animated)
    }

    /// Each panel's header grip and its ⋯ button, made the first time the panel shows.
    private func chrome(_ p: PanelID) -> (PanelGrip, PanelControls) {
        if let g = grips[p], let c = controls[p] { return (g, c) }
        let g = PanelGrip(panel: p), c = PanelControls(panel: p)
        g.root = self; c.root = self
        grips[p] = g; controls[p] = c
        return (g, c)
    }

    /// Reparents panels into their areas and starts the slide for areas that open or close.
    private func sync(animated: Bool) {
        for d in Dock.allCases {
            let dock = docks[d]!
            let want = shown(d)
            for p in want {
                guard let v = content(p) else { continue }
                if v.superview !== dock { dock.addSubview(v) }
                // The viewer's tabs and ⋯ are in the title bar.
                guard p != .viewer else { continue }
                let (g, c) = chrome(p)
                c.title = title(p)
                if g.superview !== dock { dock.addSubview(g) }
                if c.superview !== dock { dock.addSubview(c) }
            }
            if want.contains(.viewer), viewerDim.superview !== dock { dock.addSubview(viewerDim) }
            let target: CGFloat = want.isEmpty ? 0 : 1
            let t = reveal[d]!
            if target != t.target {
                if target == 0 { closing.insert(d) } else { closing.remove(d) }
                t.set(target, animated: animated && window != nil)
            }
            dock.showing = want
            if d != .bottom, let f = want.first(where: \.flexible) { lastShown[d] = f }
            dock.innerSplit.onDrag = { [weak self] pt in self?.resizeSplit(d, to: pt) }
            dock.innerSplit.onBegin = { [weak self] in self?.resizing = true }
            dock.innerSplit.onEnd = { [weak self] in self?.endResize() }
            dock.innerSplit.onReset = { [weak self] in self?.panels.split?[d] = nil }
        }
        viewerPane.treeWidth = panels.treeWidth ?? ViewerPane.treeDefault
        leftStripe.items = stripeItems(.left)
        rightStripe.items = stripeItems(.right)
        status.panels = panels.panels(.bottom, among: present).map {
            StatusBar.PanelToggle(panel: $0, title: title($0), open: shown(.bottom).contains($0))
        }
        // Filling the window, the sides are out of play until it comes back.
        titleBar.leftToggle.isHidden = filling != nil || panels.panels(.left, among: present).isEmpty
        titleBar.rightToggle.isHidden = filling != nil || panels.panels(.right, among: present).isEmpty
        titleBar.leftToggle.isOn = !shown(.left).isEmpty
        titleBar.rightToggle.isOn = !shown(.right).isEmpty
        titleBar.needsLayout = true
        titleBar.needsDisplay = true
        needsLayout = true
    }

    /// A side with two or more tool windows gets a stripe of their buttons, lit while open, like
    /// JetBrains' tool window bars. A side with one needs no switcher: the title bar's button and
    /// its shortcut show and hide it. Bottom panels are toggled from the status bar.
    private func stripeItems(_ side: Dock) -> [Stripe.Item] {
        let ps = panels.panels(side, among: present)
        guard ps.count >= 2 else { return [] }
        let open = shown(side)
        return ps.map { Stripe.Item(panel: $0, title: title($0), icon: pluginPanels[$0]?.icon, open: open.contains($0), badge: open.contains($0) ? nil : badges[$0]) }
    }

    // MARK: layout

    private var railWidth: CGFloat { railMode == .off ? 0 : Metrics.rail * railReveal.value }

    /// Full size of an area when open. A bottom area of widgets only is as tall as its tallest widget.
    private func extent(_ d: Dock) -> CGFloat {
        let ps = shown(d).isEmpty ? panels.panels(d, among: present) : shown(d)
        let bodyH = bounds.height - Metrics.titlebar - Metrics.status
        if d == .bottom, !ps.isEmpty, !ps.contains(where: \.flexible) {
            let fit = ps.compactMap { content($0)?.preferredExtent(along: .bottom) }.max() ?? 80
            return min(max(fit, panels.widgetBottom ?? fit), bodyH * 0.6)
        }
        var s = panels.size[d] ?? 300
        // A side of widgets only needs room for their numbers, not a document's width.
        if d != .bottom, !ps.isEmpty, !ps.contains(where: \.flexible) { s = min(s, 340) }
        switch d {
        case .left: return min(max(Self.minSize[.left]!, s), bounds.width * 0.45)
        case .right:
            // The file tree and a readable page side by side: the area widens rather than squeeze either.
            // ...but never so wide that the terminal drops under a readable width.
            let room = bounds.width - taken(.left) - 2 * Stripe.width - Self.terminalMin
            let least = ps.contains(.viewer) ? max(Self.minSize[.right]!, min(viewerPane.leastWidth, room)) : Self.minSize[.right]!
            // A narrow window: the right side gives way first, down to its minimum.
            return min(max(least, s), max(least, min(bounds.width * 0.6, room)))
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

        let railEnd: CGFloat = railMode == .shown ? rw + 1 : 0
        let filled = layoutFill(whole: NSRect(x: railEnd, y: top, width: w - railEnd, height: bodyH))
        drawsLines = filled ? [] : (lw > 0 ? [NSRect(x: x0 + lw - 1, y: top, width: 1, height: bodyH)] : [])
            + (rwid > 0 ? [NSRect(x: x1 - rwid, y: top, width: 1, height: bodyH)] : [])
            + (bh > 0 ? [NSRect(x: cx0, y: bottom - bh, width: cx1 - cx0, height: 1)] : [])
        drawsLines += [leftStripe.isHidden ? nil : NSRect(x: leftStripe.frame.maxX, y: top, width: 1, height: bodyH),
                       rightStripe.isHidden ? nil : NSRect(x: rightStripe.frame.minX - 1, y: top, width: 1, height: bodyH)].compactMap { $0 }
        titleBar.docs = docsPlace(line: x1 - rwid, open: rwid > 0)
        planeRect = NSRect(x: 0, y: top, width: railMode == .shown ? rw + 1 : 0, height: bodyH)
        needsDisplay = true
        window?.invalidateCursorRects(for: self)
    }

    /// The viewer's tabs head it in the title bar: right of the pane line beside the session, or
    /// the whole row after the session's own tab while it fills the window.
    private func docsPlace(line x: CGFloat, open: Bool) -> TitleBar.Docs {
        guard shown(.right).contains(.viewer) else { return .none }
        switch filling {
        case nil: return open ? .beside(at: x) : .none
        case .panel(.right)?: return .filling
        default: return .none
        }
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


    /// Under this the session's screen reflows into a column.
    static let terminalMin: CGFloat = 480
    static let minSize: [Dock: CGFloat] = [.left: 200, .right: 280, .bottom: 80]

    /// A divider moved to `p` (root coordinates): the area's edge follows the pointer.
    private func resize(_ d: Dock, to p: NSPoint) {
        switch d {
        case .left: panels.size[.left] = max(Self.minSize[.left]!, min(bounds.width * 0.45, p.x - docks[.left]!.frame.minX))
        case .right: panels.size[.right] = max(Self.minSize[.right]!, min(bounds.width * 0.6, docks[.right]!.frame.maxX - p.x))
        case .bottom:
            let h = max(Self.minSize[.bottom]!, min((bounds.height - Metrics.titlebar - Metrics.status) * 0.6, bounds.height - Metrics.status - p.y))
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
        if d == .bottom { panels.widgetBottom = nil }
        onWidthsChanged?()
    }

    // MARK: filling the window

    /// What fills the window, if anything. A relaunch opens at normal size.
    var filling: WindowFill? {
        didSet {
            guard filling != oldValue else { return }
            if let d = filling?.dock { growing = d }
            // An area grows over the rest and shrinks back; the session takes its room at once.
            maxTween.set(filling?.dock == nil ? 0 : 1, animated: window != nil && filling != .session && oldValue != .session)
            sync(animated: false)
            onFilling?(filling)
        }
    }
    var onFilling: ((WindowFill?) -> Void)?
    let maxTween = Tween(0)
    /// The area growing to fill the window, or shrinking back.
    var growing = Dock.right
}
