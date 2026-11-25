import AppKit

/// The System panel's details, in a card over it: the last five minutes of CPU, then what each
/// running session uses with the commands it runs. A click on a session opens it. Esc, a click
/// outside, or opening a session closes the card.
final class SystemDetail: MXView, TipSource {
    struct Row: Equatable { var id: SessionID; var title: String; var load: Load }

    private var sample = SystemSample()
    private var history = SystemHistory()
    private var rows: [Row] = []
    private var hovered: Int?
    private var selected: Int?
    private let activityMonitor = MXButton("Activity Monitor", small: true)
    var onOpenSession: ((SessionID) -> Void)?
    var onActivityMonitor: (() -> Void)?
    var onClose: (() -> Void)?

    static let width: CGFloat = 460
    private static let head: CGFloat = 46, graph: CGFloat = 76, listHead: CGFloat = 26, row: CGFloat = 22, foot: CGFloat = 40
    /// More sessions than this fold into one "more" line, so the card never outgrows the window.
    static let maxRows = 10

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.masksToBounds = true
        activityMonitor.action = { [weak self] in self?.onActivityMonitor?() }
        addSubview(activityMonitor)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self))
    }
    required init?(coder: NSCoder) { fatalError() }

    /// Sessions sorted by CPU, the busiest first; past `maxRows` the rest share one line.
    func update(sample: SystemSample, history: SystemHistory, rows: [Row]) {
        self.sample = sample
        self.history = history
        self.rows = rows.sorted { ($0.load.cpu, $0.load.memory) > ($1.load.cpu, $1.load.memory) }
        if let s = selected, s >= shownRows.count { selected = shownRows.isEmpty ? nil : shownRows.count - 1 }
        needsDisplay = true
    }

    private var shownRows: [Row] { Array(rows.prefix(Self.maxRows)) }
    private var hiddenLoad: Load? { rows.count > Self.maxRows ? rows.dropFirst(Self.maxRows).map(\.load).reduce(Load(), +) : nil }
    /// Lines under the session rows: the folded rest, then Claude Code outside any session.
    private var extraLines: Int { (hiddenLoad == nil ? 0 : 1) + (sample.otherClaude.processes > 0 ? 1 : 0) }
    private var listLines: Int { max(1, shownRows.count + extraLines) }
    var contentHeight: CGFloat { Self.head + Self.graph + 14 + Self.listHead + CGFloat(listLines) * Self.row + 8 + Self.foot }

    /// Above the anchor (the System panel) when there is room, else beside it.
    func present(in host: NSView, anchor: NSRect) {
        let w = min(Self.width, host.bounds.width - 24), h = min(contentHeight, host.bounds.height - 60)
        var x = min(max(12, anchor.minX), host.bounds.width - w - 12), y = anchor.minY - 6 - h
        if y < 44 {
            y = max(44, min(anchor.minY, host.bounds.height - h - 12))
            x = anchor.maxX + 6 + w <= host.bounds.width ? anchor.maxX + 6 : max(12, anchor.minX - 6 - w)
        }
        frame = NSRect(x: x, y: y, width: w, height: h)
        selected = nil
        if superview !== host { host.addSubview(self) }
        Motion.appear(self)
        window?.makeFirstResponder(self)
        needsLayout = true
    }

    func dismiss() {
        guard superview != nil else { return }
        removeFromSuperview()
        onClose?()
    }

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for e: NSEvent?) -> Bool { true }
    override func keyDown(with e: NSEvent) {
        let n = shownRows.count
        switch e.keyCode {
        case 125 where n > 0: selected = min(n - 1, (selected ?? -1) + 1); needsDisplay = true
        case 126 where n > 0: selected = max(0, (selected ?? n) - 1); needsDisplay = true
        case 36, 76: if let s = selected, shownRows.indices.contains(s) { onOpenSession?(shownRows[s].id) }
        default: super.keyDown(with: e)
        }
    }

    private var listTop: CGFloat { Self.head + Self.graph + 14 + Self.listHead }
    private func rowIndex(at p: NSPoint) -> Int? {
        let i = Int(floor((p.y - listTop) / Self.row))
        return p.y >= listTop && shownRows.indices.contains(i) ? i : nil
    }
    override func mouseMoved(with e: NSEvent) {
        let i = rowIndex(at: convert(e.locationInWindow, from: nil))
        if i != hovered { hovered = i; needsDisplay = true }
    }
    override func mouseExited(with e: NSEvent) { if hovered != nil { hovered = nil; needsDisplay = true } }
    override func mouseDown(with e: NSEvent) {
        if let i = rowIndex(at: convert(e.locationInWindow, from: nil)) { onOpenSession?(shownRows[i].id) }
    }

    func tip(at p: NSPoint) -> (tip: Tip, rect: NSRect)? {
        if p.y < Self.head + Self.graph {
            return (Tip("Whole Mac: grey").adding("Claude Code: the bright line").adding("Last 5 minutes, a gap where the panel was hidden"), NSRect(x: 0, y: 0, width: bounds.width, height: Self.head + Self.graph))
        }
        if let i = rowIndex(at: p) {
            let l = shownRows[i].load
            return (Tip(shownRows[i].title).adding("\(l.processes == 1 ? "1 process" : "\(l.processes) processes"): Claude Code and the commands it runs").adding("Click to open"), rowRect(i))
        }
        let other = shownRows.count + (hiddenLoad == nil ? 0 : 1)
        if sample.otherClaude.processes > 0, rowRect(other).contains(p) {
            return (Tip("Claude Code outside any session").adding("Spare workers kept ready, the background service"), rowRect(other))
        }
        return nil
    }

    private func rowRect(_ i: Int) -> NSRect { NSRect(x: 0, y: listTop + CGFloat(i) * Self.row, width: bounds.width, height: Self.row) }

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
        t.hair2.setFill(); NSRect(x: 0, y: Self.head + Self.graph + 13, width: bounds.width, height: 1).fill()
        drawList()
        t.hair2.setFill(); NSRect(x: 0, y: bounds.height - Self.foot, width: bounds.width, height: 1).fill()
        drawFooter()
    }

    private func drawHeadline() {
        let big = Fonts.mono(Metrics.fontSize + 6, .semibold), small = Fonts.mono(Metrics.fontSize - 1)
        let w = Text.draw(SystemPanel.percent(sample.machineCPU), in: NSRect(x: 14, y: 8, width: 120, height: 30), color: t.fg, font: big)
        Text.draw("CPU, whole Mac · \(sample.cores) cores", in: NSRect(x: 14 + w + 8, y: 8, width: 240, height: 30), color: t.fg3, font: small)
        let claude = "Claude Code \(SystemPanel.percent(sample.claude.cpu))"
        let cw = Text.width(claude, font: small)
        Text.draw(claude, in: NSRect(x: bounds.width - 14 - cw, y: 8, width: cw, height: 30), color: t.fg, font: small)
        t.fg.setFill(); NSRect(x: bounds.width - 14 - cw - 16, y: 23, width: 10, height: 1.5).fill()
    }

    /// 0–100 % over the last five minutes; a reading more than 5 s after the one before starts a new stroke.
    private func drawGraph(in g: NSRect) {
        t.hair2.setFill()
        for f in [0.0, 0.5, 1.0] { NSRect(x: g.minX, y: g.maxY - g.height * f, width: g.width, height: 1).fill() }
        let now = sample.at
        func pt(_ at: Date, _ v: Double) -> NSPoint {
            NSPoint(x: g.maxX - g.width * CGFloat(now.timeIntervalSince(at) / SystemHistory.span), y: g.maxY - g.height * CGFloat(min(100, max(0, v)) / 100))
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
        Text.draw("5 min ago", in: NSRect(x: g.minX, y: g.maxY + 1, width: 100, height: 12), color: t.fg3, font: tiny)
        Text.draw("now", in: NSRect(x: g.maxX - 100, y: g.maxY + 1, width: 100, height: 12), color: t.fg3, font: tiny, align: .right)
        Text.draw("100%", in: NSRect(x: g.maxX - 100, y: g.minY - 1, width: 100, height: 12), color: t.fg3, font: tiny, align: .right)
    }

    private func drawList() {
        let head = Fonts.mono(Metrics.fontSize - 2.5, .medium), font = Fonts.mono(Metrics.fontSize - 1)
        let memX = bounds.width - 14 - 80, cpuX = memX - 14 - 64
        let hy = Self.head + Self.graph + 14
        Text.draw("SESSION", in: NSRect(x: 14, y: hy, width: 200, height: Self.listHead), color: t.fg3, font: head)
        Text.draw("CPU", in: NSRect(x: cpuX, y: hy, width: 64, height: Self.listHead), color: t.fg3, font: head, align: .right)
        Text.draw("MEMORY", in: NSRect(x: memX, y: hy, width: 80, height: Self.listHead), color: t.fg3, font: head, align: .right)
        func line(_ i: Int, _ title: String, _ l: Load, color: NSColor) {
            let r = rowRect(i)
            if i == selected { t.rowSel.setFill(); r.insetBy(dx: 6, dy: 1).fill() } else if i == hovered { t.hover.setFill(); r.insetBy(dx: 6, dy: 1).fill() }
            Text.draw(title, in: NSRect(x: 14, y: r.minY, width: cpuX - 24, height: r.height), color: color, font: font)
            Text.draw(SystemPanel.percent(l.cpu), in: NSRect(x: cpuX, y: r.minY, width: 64, height: r.height), color: l.cpu >= 25 ? t.fg : t.fg2, font: font, align: .right)
            Text.draw(SystemPanel.memory(l.memory), in: NSRect(x: memX, y: r.minY, width: 80, height: r.height), color: t.fg2, font: font, align: .right)
        }
        if rows.isEmpty, sample.otherClaude.processes == 0 {
            Text.draw("No Claude Code running", in: NSRect(x: 14, y: listTop, width: bounds.width - 28, height: Self.row), color: t.fg3, font: font)
            return
        }
        for (i, row) in shownRows.enumerated() { line(i, row.title, row.load, color: t.fg) }
        var i = shownRows.count
        if let more = hiddenLoad { line(i, "\(rows.count - Self.maxRows) more sessions", more, color: t.fg3); i += 1 }
        if sample.otherClaude.processes > 0 { line(i, "Other Claude Code processes", sample.otherClaude, color: t.fg3) }
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
