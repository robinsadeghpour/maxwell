import AppKit

/// The System panel's details, in a card over it: the last five minutes of CPU, then what each
/// running session uses with the commands it runs. A click on a session opens it. Esc, a click
/// outside, or opening a session closes the card.
final class SystemDetail: MXView, TipSource {
    struct Row: Equatable { var id: SessionID; var title: String; var group: PhaseGroup?; var load: Load }

    private var sample = SystemSample()
    private var history = SystemHistory()
    /// In the order shown. It holds still while the pointer is over the card or a row is selected,
    /// so a click lands on the session it was aimed at.
    private var rows: [Row] = []
    /// CPU averaged over the last few readings, so the order follows what is busy, not one spike.
    private var smoothed: [SessionID: Double] = [:]
    private var hovered: SessionID?
    private var selected: SessionID?
    private var pointerInside = false
    /// Session rows that fit the window; the rest share one line.
    private var room = Int.max
    private weak var host: NSView?
    private var anchor = NSRect.zero
    private let activityMonitor = MXButton("Activity Monitor", small: true)
    var onOpenSession: ((SessionID) -> Void)?
    var onActivityMonitor: (() -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 460
    private static let head: CGFloat = 46, graph: CGFloat = 76, gap: CGFloat = 14, listHead: CGFloat = 26, row: CGFloat = 22, foot: CGFloat = 40
    private static var fixed: CGFloat { head + graph + gap + listHead + 8 + foot }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        activityMonitor.action = { [weak self] in self?.onActivityMonitor?() }
        addSubview(activityMonitor)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    func update(sample: SystemSample, history: SystemHistory, rows fresh: [Row]) {
        self.sample = sample
        self.history = history
        for r in fresh { smoothed[r.id] = smoothed[r.id].map { $0 * 0.7 + r.load.cpu * 0.3 } ?? r.load.cpu }
        let byId = Dictionary(fresh.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        smoothed = smoothed.filter { byId[$0.key] != nil }
        if pointerInside || selected != nil {
            let kept = rows.compactMap { byId[$0.id] }
            rows = kept + fresh.filter { r in !kept.contains { $0.id == r.id } }
        } else {
            rows = fresh.sorted { (smoothed[$0.id] ?? 0, $0.load.memory) > (smoothed[$1.id] ?? 0, $1.load.memory) }
        }
        if let s = selected, !shownRows.contains(where: { $0.id == s }) { selected = nil }
        if let h = hovered, !shownRows.contains(where: { $0.id == h }) { hovered = nil }
        setAccessibilityLabel("System details. CPU \(Int(sample.machineCPU)) percent of this Mac, Claude Code \(Int(sample.claude.cpu)) percent."
                              + (rows.first.map { " Busiest session: \($0.title)." } ?? ""))
        if superview != nil { place() }
        needsDisplay = true
    }

    private var shownRows: ArraySlice<Row> { rows.prefix(room) }
    private var hiddenRows: ArraySlice<Row> { rows.dropFirst(room) }
    /// The lines under the sessions: the ones that didn't fit, Claude Code outside any session, the rest of the Mac.
    private enum Extra { case more(Int, Load), otherClaude(Load), restOfMac(Load) }
    private var extras: [Extra] {
        var e: [Extra] = []
        if !hiddenRows.isEmpty { e.append(.more(hiddenRows.count, hiddenRows.map(\.load).reduce(Load(), +))) }
        if sample.otherClaude.processes > 0 { e.append(.otherClaude(sample.otherClaude)) }
        let claude = sample.claude
        e.append(.restOfMac(Load(cpu: max(0, sample.machineCPU - claude.cpu), memory: sample.memUsed > claude.memory ? sample.memUsed - claude.memory : 0)))
        return e
    }

    /// Above the anchor (the System panel docked at the bottom), else beside it; never taller than the window allows.
    func present(in host: NSView, anchor: NSRect) {
        self.host = host
        self.anchor = anchor
        selected = nil
        hovered = nil
        place()
        if superview !== host { host.addSubview(self) }
        Motion.appear(self)
        window?.makeFirstResponder(self)
    }

    private func place() {
        guard let host else { return }
        let w = min(Self.width, host.bounds.width - 24)
        let below = anchor.minY > host.bounds.midY
        let maxH = below ? anchor.minY - 6 - 44 : host.bounds.height - 74
        let extraLines = CGFloat(2 + (sample.otherClaude.processes > 0 ? 1 : 0))
        room = max(1, Int((maxH - Self.fixed - extraLines * Self.row) / Self.row))
        if rows.count <= room + 1 { room = rows.count }
        let lines = CGFloat(shownRows.count + extras.count + (rows.isEmpty && sample.otherClaude.processes == 0 ? 1 : 0))
        let h = min(maxH, Self.fixed + lines * Self.row)
        var f = NSRect(x: min(max(12, anchor.minX), host.bounds.width - w - 12), y: anchor.minY - 6 - h, width: w, height: h)
        if !below {
            f.origin.y = max(44, min(anchor.minY, host.bounds.height - h - 30))
            f.origin.x = anchor.maxX + 6 + w <= host.bounds.width ? anchor.maxX + 6 : max(12, anchor.minX - 6 - w)
        }
        if frame != f { frame = f; needsLayout = true }
    }

    func dismiss() {
        guard superview != nil else { return }
        removeFromSuperview()
        onClose?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func keyDown(with e: NSEvent) {
        let ids = shownRows.map(\.id), at = selected.flatMap { ids.firstIndex(of: $0) }
        let key = e.charactersIgnoringModifiers?.lowercased()
        if !ids.isEmpty, e.keyCode == 125 || key == "j" { selected = ids[min(ids.count - 1, (at ?? -1) + 1)]; needsDisplay = true; return }
        if !ids.isEmpty, e.keyCode == 126 || key == "k" { selected = ids[max(0, (at ?? ids.count) - 1)]; needsDisplay = true; return }
        if e.keyCode == 36 || e.keyCode == 76, let s = selected { return onOpenSession?(s) ?? () }
        super.keyDown(with: e)
    }

    private var listTop: CGFloat { Self.head + Self.graph + Self.gap + Self.listHead }
    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 0, y: listTop + CGFloat(i) * Self.row, width: bounds.width, height: Self.row) }
    private func line(at p: NSPoint) -> Int? { p.y >= listTop ? Int(floor((p.y - listTop) / Self.row)) : nil }
    private func session(at p: NSPoint) -> SessionID? { line(at: p).flatMap { shownRows.indices.contains($0) ? shownRows[$0].id : nil } }

    override func mouseEntered(with e: NSEvent) { pointerInside = true }
    override func mouseMoved(with e: NSEvent) {
        pointerInside = true
        let id = session(at: convert(e.locationInWindow, from: nil))
        if id != hovered { hovered = id; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) {
        pointerInside = false
        if hovered != nil { hovered = nil; needsDisplay = true }
    }
    override func mouseDown(with e: NSEvent) {
        if let id = session(at: convert(e.locationInWindow, from: nil)) { onOpenSession?(id) }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if p.y < Self.head + Self.graph {
            return (Tip("Share of the whole Mac: all \(sample.cores) cores together are 100%")
                .adding("Activity Monitor counts each core as 100%, so 10% here is \(sample.cores * 10)% there")
                .adding("Grey: the Mac. Bright line: Claude Code"), NSRect(x: 0, y: 0, width: bounds.width, height: Self.head + Self.graph))
        }
        guard let i = line(at: p) else { return nil }
        if shownRows.indices.contains(i) {
            let l = shownRows[i].load
            return (Tip(shownRows[i].title).adding("\(l.processes == 1 ? "1 process" : "\(l.processes) processes"): Claude Code and the commands it runs").adding("Click to open"), rowRect(i))
        }
        let k = i - shownRows.count
        guard extras.indices.contains(k) else { return nil }
        switch extras[k] {
        case .more: return (Tip("Sessions that don't fit").adding("Make the window taller to see each one"), rowRect(i))
        case .otherClaude: return (Tip("Claude Code outside any session").adding("Processes Maxwell can't tie to one session: the background service,").adding("spare workers, agent teammates in tmux, sessions from other apps"), rowRect(i))
        case .restOfMac: return (Tip("Everything else on this Mac").adding("Other apps, and commands that kept running after their session ended").adding("Activity Monitor names them"), rowRect(i))
        }
    }

    override func layout() {
        super.layout()
        let s = activityMonitor.intrinsicContentSize
        activityMonitor.frame = NSRect(x: bounds.width - 12 - s.width, y: bounds.height - (Self.foot + s.height) / 2, width: s.width, height: s.height)
    }

    override func draw(_ r: NSRect) {
        t.panel.setFill(); bounds.fill()
        t.hair.setStroke()
        let border = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8); border.lineWidth = 1; border.stroke()
        drawHeadline()
        drawGraph(in: NSRect(x: 14, y: Self.head, width: bounds.width - 28, height: Self.graph))
        t.hair2.setFill(); NSRect(x: 0, y: Self.head + Self.graph + Self.gap - 1, width: bounds.width, height: 1).fill()
        drawList()
        t.hair2.setFill(); NSRect(x: 0, y: bounds.height - Self.foot, width: bounds.width, height: 1).fill()
        drawFooter()
    }

    /// The CPU column: whole percents, and "<1%" for a trickle, so the column reads at a glance.
    static func cpu(_ v: Double) -> String { v > 0 && v < 1 ? "<1%" : "\(Int(v.rounded()))%" }

    private func drawHeadline() {
        let big = Fonts.mono(Metrics.fontSize + 6, .semibold), small = Fonts.mono(Metrics.fontSize - 1)
        let w = Text.draw(Self.cpu(sample.machineCPU), in: NSRect(x: 14, y: 8, width: 120, height: 30), color: t.fg, font: big)
        Text.draw("of this Mac's CPU", in: NSRect(x: 14 + w + 8, y: 8, width: 200, height: 30), color: t.fg3, font: small)
        let claude = "Claude Code \(Self.cpu(sample.claude.cpu))", mac = "Mac"
        let cw = Text.width(claude, font: small), mw = Text.width(mac, font: small)
        let cx = bounds.width - 14 - cw, mx = cx - 16 - 14 - mw
        Text.draw(claude, in: NSRect(x: cx, y: 8, width: cw, height: 30), color: t.fg, font: small)
        t.fg.setFill(); NSRect(x: cx - 14, y: 23, width: 10, height: 1.5).fill()
        Text.draw(mac, in: NSRect(x: mx, y: 8, width: mw, height: 30), color: t.fg3, font: small)
        t.fg3.withAlphaComponent(0.35).setFill(); NSRect(x: mx - 14, y: 19, width: 10, height: 8).fill()
    }

    /// 0–100 % over the last five minutes, or over what has been read so far. A reading more than
    /// 5 s after the one before (the panel was hidden) starts a new stroke.
    private func drawGraph(in g: NSRect) {
        t.hair2.setFill()
        for f in [0.0, 0.5, 1.0] { NSRect(x: g.minX, y: g.maxY - g.height * f, width: g.width, height: 1).fill() }
        let now = sample.at
        let span = max(10, min(SystemHistory.span, history.points.first.map { now.timeIntervalSince($0.at) } ?? 0))
        func pt(_ at: Date, _ v: Double) -> NSPoint {
            NSPoint(x: g.maxX - g.width * CGFloat(now.timeIntervalSince(at) / span), y: g.maxY - g.height * CGFloat(min(100, max(0, v)) / 100))
        }
        var strokes: [[SystemHistory.Point]] = []
        for p in history.points {
            if let last = strokes.last?.last, p.at.timeIntervalSince(last.at) <= 5 { strokes[strokes.count - 1].append(p) } else { strokes.append([p]) }
        }
        for s in strokes where s.count > 1 {
            let area = NSBezierPath()
            area.move(to: NSPoint(x: pt(s[0].at, 0).x, y: g.maxY))
            s.forEach { area.line(to: pt($0.at, $0.machine)) }
            area.line(to: NSPoint(x: pt(s[s.count - 1].at, 0).x, y: g.maxY)); area.close()
            t.fg3.withAlphaComponent(0.22).setFill(); area.fill()
            let claude = NSBezierPath(); claude.lineWidth = 1.5; claude.lineJoinStyle = .round
            claude.move(to: pt(s[0].at, s[0].claude))
            s.dropFirst().forEach { claude.line(to: pt($0.at, $0.claude)) }
            t.fg.setStroke(); claude.stroke()
        }
        let tiny = Fonts.mono(Metrics.fontSize - 3)
        let ago = span >= SystemHistory.span ? "5 min ago" : "\(Int(span)) s ago"
        Text.draw(ago, in: NSRect(x: g.minX, y: g.maxY + 1, width: 100, height: 12), color: t.fg3, font: tiny)
        Text.draw("now", in: NSRect(x: g.maxX - 100, y: g.maxY + 1, width: 100, height: 12), color: t.fg3, font: tiny, align: .right)
        Text.draw("100%", in: NSRect(x: g.minX + 2, y: g.minY + 1, width: 60, height: 12), color: t.fg3, font: tiny)
    }

    private func drawList() {
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium), font = Fonts.mono(Metrics.fontSize - 1)
        let memX = bounds.width - 14 - 80, cpuX = memX - 14 - 52
        let hy = Self.head + Self.graph + Self.gap
        Text.draw("SESSION", in: NSRect(x: 14, y: hy, width: 200, height: Self.listHead), color: t.fg3, font: head)
        Text.draw("CPU", in: NSRect(x: cpuX, y: hy, width: 52, height: Self.listHead), color: t.fg3, font: head, align: .right)
        Text.draw("MEMORY", in: NSRect(x: memX, y: hy, width: 80, height: Self.listHead), color: t.fg3, font: head, align: .right)
        func line(_ i: Int, _ title: String, _ l: Load, group: PhaseGroup? = nil, lit: Bool = false, color: NSColor) {
            let r = rowRect(i)
            if lit { (i < shownRows.count && shownRows[i].id == selected ? t.rowSel : t.hover).setFill(); r.insetBy(dx: 6, dy: 1).fill() }
            if let group { Glyph.draw(group, at: NSPoint(x: 20, y: r.midY), color: t.color(for: group)) }
            Text.draw(title, in: NSRect(x: 32, y: r.minY, width: cpuX - 40, height: r.height), color: color, font: font)
            Text.draw(Self.cpu(l.cpu), in: NSRect(x: cpuX, y: r.minY, width: 52, height: r.height), color: l.cpu >= 25 ? t.fg : t.fg2, font: font, align: .right)
            Text.draw(SystemPanel.memory(l.memory), in: NSRect(x: memX, y: r.minY, width: 80, height: r.height), color: t.fg2, font: font, align: .right)
        }
        if rows.isEmpty, sample.otherClaude.processes == 0 {
            Text.draw("No Claude Code running", in: NSRect(x: 32, y: listTop, width: bounds.width - 46, height: Self.row), color: t.fg3, font: font)
        }
        for (i, row) in shownRows.enumerated() {
            line(i, row.title, Load(cpu: smoothed[row.id] ?? row.load.cpu, memory: row.load.memory, processes: row.load.processes), group: row.group, lit: row.id == selected || row.id == hovered, color: t.fg)
        }
        for (k, extra) in extras.enumerated() {
            let i = (rows.isEmpty && sample.otherClaude.processes == 0 ? 1 : shownRows.count) + k
            switch extra {
            case .more(let n, let l): line(i, "\(n) more sessions", l, color: t.fg3)
            case .otherClaude(let l): line(i, "Other Claude Code processes", l, color: t.fg3)
            case .restOfMac(let l): line(i, "Everything else on this Mac", l, color: t.fg3)
            }
        }
    }

    private func drawFooter() {
        let pressure: String
        switch sample.pressure {
        case .normal: pressure = "pressure normal"
        case .high: pressure = "pressure high"
        case .critical: pressure = "pressure critical"
        case .unknown: pressure = ""
        }
        let used = "Memory \(SystemPanel.gb(sample.memUsed)) of \(SystemPanel.gb(sample.memTotal)) GB"
        let text = pressure.isEmpty ? used : "\(used) · \(pressure)"
        let color = sample.pressure == .critical ? t.on : sample.pressure == .high ? t.fg : t.fg2
        Text.draw(text, in: NSRect(x: 14, y: bounds.height - Self.foot, width: activityMonitor.frame.minX - 24, height: Self.foot), color: color, font: Fonts.mono(Metrics.fontSize - 1))
    }
}
